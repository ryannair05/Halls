import Foundation
@preconcurrency import CoreBluetooth
import Combine
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// BLEService — Bluetooth Mesh Transport
/// - Emits events exclusively via `BitchatDelegate` for UI.
/// - BitchatViewModel must consume delegate callbacks (`didReceivePublicMessage`, `didReceiveNoisePayload`).
/// - A lightweight `peerSnapshotPublisher` is provided for non-UI services.
final class BLEService: NSObject, @unchecked Sendable {
    
    // MARK: - Constants
    
    #if DEBUG
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A") // testnet
    #else
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C") // mainnet
    #endif
    static let characteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    
    // Default per-fragment chunk size when link limits are unknown
    private let defaultFragmentSize = TransportConfig.bleDefaultFragmentSize
    private let messageTTL: UInt8 = TransportConfig.messageTTLDefault
    // Flood/battery controls
    private let maxInFlightAssemblies = TransportConfig.bleMaxInFlightAssemblies // cap concurrent fragment assemblies
    private let highDegreeThreshold = TransportConfig.bleHighDegreeThreshold // for adaptive TTL/probabilistic relays
    
    // MARK: - Core State (5 Essential Collections)
    
    // 1. Consolidated Peripheral Tracking
    private struct PeripheralState {
        let peripheral: CBPeripheral
        var characteristic: CBCharacteristic?
        var peerID: String?
        var isConnecting: Bool = false
        var isConnected: Bool = false
        var lastConnectionAttempt: Date? = nil
    }
    private var peripherals: [String: PeripheralState] = [:]  // UUID -> PeripheralState
    private var peerToPeripheralUUID: [String: String] = [:]  // PeerID -> Peripheral UUID
    
    // 2. BLE Centrals (when acting as peripheral)
    private var subscribedCentrals: [CBCentral] = []
    private var centralToPeerID: [String: String] = [:]  // Central UUID -> Peer ID mapping
    
    // 3. Peer Information (single source of truth)
    struct PeerInfo {
        let id: String
        var nickname: String
        var isConnected: Bool
        var noisePublicKey: Data?
        var signingPublicKey: Data?
        var isVerifiedNickname: Bool
        var lastSeen: Date
    }
    private var peers: [String: PeerInfo] = [:]
    
    // 4. Efficient Message Deduplication
    private let messageDeduplicator = MessageDeduplicator()
    
    // 5. Fragment Reassembly (necessary for messages > MTU)
    private struct FragmentKey: Hashable { let sender: UInt64; let id: UInt64 }
    private var incomingFragments: [FragmentKey: [Int: Data]] = [:]
    private var fragmentMetadata: [FragmentKey: (type: UInt8, total: Int, timestamp: Date)] = [:]
    // Backoff for peripherals that recently timed out connecting
    private var recentConnectTimeouts: [String: Date] = [:] // Peripheral UUID -> last timeout
    
    // Simple announce throttling
    private var lastAnnounceSent = Date.distantPast
    private let announceMinInterval: TimeInterval = TransportConfig.bleAnnounceMinInterval
    
    // Share lifecycle policy through the transport's existing collection queue.
    private var backgroundReceptionStorage = false
    private var backgroundReceptionEnabled: Bool {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil { return backgroundReceptionStorage }
        return collectionsQueue.sync { backgroundReceptionStorage }
    }
    private var appActiveStorage = false
    private let lifecycleQueueKey = DispatchSpecificKey<Void>()
    private var isAppActive: Bool {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil { return appActiveStorage }
        return collectionsQueue.sync { appActiveStorage }
    }

    // MARK: - Core BLE Objects
    
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var bluetoothState: CBManagerState = .unknown
    
    // MARK: - Identity
    
    var myPeerID: String = ""
    var myNickname: String = "anon"
    private let noiseService = NoiseEncryptionService()
    private var myPeerIDData: Data = Data()

    // MARK: - Advertising Privacy
    // No Local Name by default for maximum privacy. No rotating alias.
    
    // MARK: - Queues
    
    private let messageQueue = DispatchQueue(label: "mesh.message", attributes: .concurrent)
    private let collectionsQueue = DispatchQueue(label: "mesh.collections", attributes: .concurrent)
    private let messageQueueKey = DispatchSpecificKey<Void>()
    private let bleQueue = DispatchQueue(label: "mesh.bluetooth", qos: .userInitiated)
    private let bleQueueKey = DispatchSpecificKey<Void>()
    
    // Queue for messages pending handshake completion
    private var pendingMessagesAfterHandshake: [String: [(content: String, messageID: String)]] = [:]
    // Noise typed payloads (ACKs, read receipts, etc.) pending handshake
    private var pendingNoisePayloadsAfterHandshake: [String: [Data]] = [:]
    // Signed identity proofs for live public messages; never replayed as presence.
    private var announcementsByPeer: [String: BitchatPacket] = [:]
    private let historyStore = MeshHistoryStore()
    private let sessionID = withUnsafeBytes(of: UUID().uuid) { Data($0) }
    
    // Queue for notifications that failed due to full queue
    // Owned by bleQueue, including the CoreBluetooth ready callback.
    private var pendingNotifications: [(data: Data, centrals: [CBCentral])] = []
    private var pendingNotificationBytes = 0

    // Accumulate long write chunks per central until a full frame decodes
    private var pendingWriteBuffers: [String: Data] = [:]
    // Relay jitter scheduling to reduce redundant floods
    private var scheduledRelays: [String: UUID] = [:]
    // Track short-lived traffic bursts to adapt announces/scanning under load
    private var recentPacketTimestamps: [Date] = []

    // Ingress link tracking for last-hop suppression
    private enum LinkID: Hashable {
        case peripheral(String)
        case central(String)
    }
    private var ingressByMessageID: [String: (link: LinkID, timestamp: Date)] = [:]

    // Backpressure-aware write queue per peripheral. Lower priorities are sent first.
    private struct OutboundPriority: Comparable {
        let level: Int
        let suborder: Int

        static let high = OutboundPriority(level: 0, suborder: 0)
        static func fragment(totalFragments: Int) -> OutboundPriority {
            OutboundPriority(level: 1, suborder: max(1, min(totalFragments, Int(UInt16.max))))
        }
        static let low = OutboundPriority(level: 2, suborder: Int.max)

        static func < (lhs: OutboundPriority, rhs: OutboundPriority) -> Bool {
            if lhs.level != rhs.level { return lhs.level < rhs.level }
            return lhs.suborder < rhs.suborder
        }
    }

    private struct PendingWrite {
        let priority: OutboundPriority
        let data: Data
    }

    private var pendingPeripheralWrites: [String: [PendingWrite]] = [:]
    // Debounce duplicate disconnect notifies
    private var recentDisconnectNotifies: [String: Date] = [:]
    // Store-and-forward for directed messages when we have no links
    // Keyed by recipient short peerID -> messageID -> (packet, enqueuedAt)
    private var pendingDirectedRelays: [String: [String: (packet: BitchatPacket, enqueuedAt: Date)]] = [:]
    // Debounce for 'reconnected' logs
    private var lastReconnectLogAt: [String: Date] = [:]
    
    // MARK: - Maintenance Timer
    
    private var maintenanceTimer: (any DispatchSourceTimer)?  // Single timer for all maintenance tasks
    private var maintenanceCounter = 0  // Track maintenance cycles

    // MARK: - Connection budget & scheduling (central role)
    private let maxCentralLinks = TransportConfig.bleMaxCentralLinks
    private let connectRateLimitInterval: TimeInterval = TransportConfig.bleConnectRateLimitInterval
    private var lastGlobalConnectAttempt: Date = .distantPast
    private struct ConnectionCandidate {
        let peripheral: CBPeripheral
        let rssi: Int
        let name: String
        let isConnectable: Bool
        let discoveredAt: Date
    }
    private var connectionCandidates: [ConnectionCandidate] = []
    private var failureCounts: [String: Int] = [:] // Peripheral UUID -> failures
    private var lastIsolatedAt: Date? = nil
    private var dynamicRSSIThreshold: Int = TransportConfig.bleDynamicRSSIThresholdDefault

    // MARK: - Adaptive scanning duty-cycle
    private var scanDutyTimer: (any DispatchSourceTimer)?
    private var dutyEnabled: Bool = true
    private var dutyOnDuration: TimeInterval = TransportConfig.bleDutyOnDuration
    private var dutyOffDuration: TimeInterval = TransportConfig.bleDutyOffDuration
    private var dutyActive: Bool = false

    // MARK: - Link capability snapshots (thread-safe via bleQueue)
    private func snapshotPeripheralStates() -> Dictionary<String, BLEService.PeripheralState>.Values {
        if DispatchQueue.getSpecific(key: bleQueueKey) != nil {
            return peripherals.values
        } else {
            return bleQueue.sync { peripherals.values }
        }
    }
    private func snapshotSubscribedCentrals() -> ([CBCentral], [String: String]) {
        if DispatchQueue.getSpecific(key: bleQueueKey) != nil {
            return (self.subscribedCentrals, self.centralToPeerID)
        } else {
            return bleQueue.sync { (self.subscribedCentrals, self.centralToPeerID) }
        }
    }

    // MARK: - Helpers: IDs, selection, and write backpressure
    private func makeMessageID(for packet: BitchatPacket) -> String {
        let senderID = packet.senderID.hexEncodedString()
        let payloadHash = SHA256.hash(data: packet.payload).map { String(format: "%02x", $0) }.joined()
        return "\(senderID)-\(packet.timestamp)-\(packet.type)-\(payloadHash)"
    }

    private func subsetSizeForFanout(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        if n <= 2 { return n }
        // approx ceil(log2(n)) + 1 without floating point
        var v = n - 1
        var bits = 0
        while v > 0 { v >>= 1; bits += 1 }
        return min(n, max(1, bits + 1))
    }

    private func selectDeterministicSubset(ids: [String], k: Int, seed: String) -> Set<String> {
        guard k > 0 && ids.count > k else { return Set(ids) }
        // Stable order by SHA256(seed || "::" || id)
        var scored: [(score: [UInt8], id: String)] = []
        for id in ids {
            let msg = (seed + "::" + id).data(using: .utf8) ?? Data()
            let digest = Array(SHA256.hash(data: msg))
            scored.append((digest, id))
        }
        scored.sort { a, b in
            for i in 0..<min(a.score.count, b.score.count) {
                if a.score[i] != b.score[i] { return a.score[i] < b.score[i] }
            }
            return a.id < b.id
        }
        return Set(scored.prefix(k).map { $0.id })
    }

    private func priority(for packet: BitchatPacket, data: Data) -> OutboundPriority {
        guard let messageType = MessageType(rawValue: packet.type) else {
            return .low
        }
        switch messageType {
        case .fragment:
            return .fragment(totalFragments: fragmentTotalCount(from: packet.payload))
        default:
            return .high
        }
    }

    private func fragmentTotalCount(from payload: Data) -> Int {
        guard payload.count >= 12 else { return Int(UInt16.max) }
        let totalHigh = Int(payload[10])
        let totalLow = Int(payload[11])
        return max((totalHigh << 8) | totalLow, 1)
    }

    private func writeOrEnqueue(_ data: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic, priority: OutboundPriority = .high) {
        // BLE operations run on bleQueue; keep queue affinity
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
                SecureLogger.log("Rejected Bluetooth write exceeding link limit", category: SecureLogger.session, level: .error)
                return
            }
            let uuid = peripheral.identifier.uuidString
            if self.isAppActive && peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            } else {
                self.collectionsQueue.async(flags: .barrier) {
                    var queue = self.pendingPeripheralWrites[uuid] ?? []
                    let capBytes = TransportConfig.blePendingWriteBufferCapBytes
                    let newSize = data.count
                    // If single chunk exceeds cap, drop it immediately
                    if newSize > capBytes {
                        SecureLogger.log("⚠️ Dropping oversized write chunk (\(newSize)B) for peripheral \(uuid)",
                                         category: SecureLogger.session, level: .warning)
                    } else {
                        let item = PendingWrite(priority: priority, data: data)
                        var total = queue.reduce(0) { $0 + $1.data.count } + newSize
                        let insertIndex = queue.firstIndex { item.priority < $0.priority } ?? queue.count
                        queue.insert(item, at: insertIndex)
                        if total > capBytes {
                            var removedBytes = 0
                            while total > capBytes && !queue.isEmpty {
                                let removed = queue.removeLast()
                                removedBytes += removed.data.count
                                total -= removed.data.count
                            }
                            SecureLogger.log("📉 Trimmed pending write buffer for \(uuid) by \(removedBytes)B to \(total)B",
                                             category: SecureLogger.session, level: .warning)
                        }
                        self.pendingPeripheralWrites[uuid] = queue.isEmpty ? nil : queue
                    }
                }
            }
        }
    }

    private func drainPendingWrites(for peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        bleQueue.async { [weak self] in
            guard let self, self.isAppActive else { return }
            guard let state = self.peripherals[uuid], let ch = state.characteristic else { return }
            let itemsToSend: [PendingWrite] = self.collectionsQueue.sync(flags: .barrier) {
                let items = self.pendingPeripheralWrites[uuid] ?? []
                self.pendingPeripheralWrites[uuid] = nil
                return items
            }
            guard !itemsToSend.isEmpty else { return }
            var sent = 0
            for item in itemsToSend {
                guard item.data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
                    sent += 1
                    continue
                }
                if peripheral.canSendWriteWithoutResponse {
                    peripheral.writeValue(item.data, for: ch, type: .withoutResponse)
                    sent += 1
                } else {
                    break
                }
            }
            let unsent = Array(itemsToSend.dropFirst(sent))
            if !unsent.isEmpty {
                self.collectionsQueue.async(flags: .barrier) {
                    var existing = self.pendingPeripheralWrites[uuid] ?? []
                    existing.insert(contentsOf: unsent, at: 0)
                    self.pendingPeripheralWrites[uuid] = existing
                }
            }
        }
    }

    private func drainAllPendingWrites() {
        let uuids = collectionsQueue.sync { Array(pendingPeripheralWrites.keys) }
        for uuid in uuids {
            guard let state = peripherals[uuid], state.isConnected else { continue }
            drainPendingWrites(for: state.peripheral)
        }
    }
    
    // MARK: - Peer snapshots publisher (non-UI convenience)
    private let peerSnapshotSubject = PassthroughSubject<[TransportPeerSnapshot], Never>()
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        peerSnapshotSubject.eraseToAnyPublisher()
    }

    func currentPeerSnapshots() -> [TransportPeerSnapshot] {
        collectionsQueue.sync {
            let snapshot = peers.values
            let resolvedNames = PeerDisplayNameResolver.resolve(
                snapshot.map { ($0.id, $0.nickname, $0.isConnected) },
                selfNickname: myNickname
            )
            return snapshot.map { info in
                TransportPeerSnapshot(
                    id: info.id,
                    nickname: resolvedNames[info.id] ?? info.nickname,
                    isConnected: info.isConnected,
                    noisePublicKey: info.noisePublicKey,
                    lastSeen: info.lastSeen
                )
            }
        }
    }
    
    // MARK: - Delegate
    
    weak var delegate: (any BitchatDelegate)? {
        didSet {
            delegate?.updateBluetoothState(bluetoothState)
            if delegate != nil {
                Task { @concurrent [weak self] in
                    guard let self else { return }
                    for entry in await historyStore.entries() {
                        await deliverHistoryEntry(entry)
                    }
                }
            }
        }
    }
    weak var peerEventsDelegate: (any TransportPeerEventsDelegate)?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        collectionsQueue.setSpecific(key: lifecycleQueueKey, value: ())
        // Derive stable peer ID from Noise static public key fingerprint (first 8 bytes → 16 hex chars)
        let fingerprint = noiseService.getIdentityFingerprint() // 64 hex chars
        self.myPeerID = String(fingerprint.prefix(16))
        self.myPeerIDData = Data(hexString: myPeerID) ?? Data()
        
        // Set queue key for identification
        messageQueue.setSpecific(key: messageQueueKey, value: ())
        
        // Set up Noise session establishment callback
        // This ensures we send pending messages only when session is truly established
        noiseService.onPeerAuthenticated = { [weak self] peerID, fingerprint in
            SecureLogger.log("🔐 Noise session authenticated with \(peerID), fingerprint: \(fingerprint.prefix(16))...", 
                            category: SecureLogger.noise, level: .debug)
            // Send any messages that were queued during handshake
            self?.messageQueue.async { [weak self] in
                self?.sendPendingMessagesAfterHandshake(for: peerID)
                self?.sendPendingNoisePayloadsAfterHandshake(for: peerID)
            }
            self?.requestHistory(from: peerID)
            // Proactive presence nudge: announce immediately after handshake
            self?.messageQueue.async { [weak self] in
                self?.sendAnnounce(forceSend: true)
            }
        }
        
        // Set up application state tracking (iOS only)
        #if os(iOS)
        // Check initial state on main thread
        Task { @MainActor in
            setApplicationActive(UIApplication.shared.applicationState == .active)
        }
        
        // Observe application state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        #endif
        
        #if !os(iOS)
        collectionsQueue.sync(flags: .barrier) { appActiveStorage = true }
        #endif

        // Tag BLE queue for re-entrancy detection
        bleQueue.setSpecific(key: bleQueueKey, value: ())

        // Initialize BLE on background queue to prevent main thread blocking
        // This prevents app freezes during BLE operations
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
        peripheralManager = CBPeripheralManager(delegate: self, queue: bleQueue)
        
        bleQueue.async { [weak self] in self?.startMaintenance() }

        // Publish initial empty state
        requestPeerDataPublish()
    }
    
    func setNickname(_ nickname: String) {
        self.myNickname = nickname
        // Send announce to notify peers of nickname change (force send)
        sendAnnounce(forceSend: true)
    }

    // No advertising policy to set; we never include Local Name in adverts.
    
    deinit {
        maintenanceTimer?.cancel()
        scanDutyTimer?.cancel()
        scanDutyTimer = nil
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        #endif
    }
    
    // MARK: - Application State Handlers

    private func startMaintenance() {
        guard isAppActive, maintenanceTimer == nil else { return }
        // Single maintenance timer for all periodic tasks (dispatch-based for determinism)
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + TransportConfig.bleMaintenanceInterval,
                       repeating: TransportConfig.bleMaintenanceInterval,
                       leeway: .seconds(TransportConfig.bleMaintenanceLeewaySeconds))
        timer.setEventHandler { [weak self] in
            self?.performMaintenance()
        }
        timer.resume()
        maintenanceTimer = timer
    }

    func setBackgroundReceptionEnabled(_ enabled: Bool) {
        collectionsQueue.sync(flags: .barrier) { backgroundReceptionStorage = enabled }
    }

    /// Release both Bluetooth roles when background reception was not requested.
    /// Removing only scans/advertising would leave subscribed central connections alive.
    private func disconnectBackgroundTransport() {
        let peerIDs = collectionsQueue.sync { Array(peers.keys) }
        centralManager?.delegate = nil
        peripheralManager?.delegate = nil
        for state in peripherals.values {
            state.peripheral.delegate = nil
            centralManager?.cancelPeripheralConnection(state.peripheral)
        }
        if peripheralManager?.state == .poweredOn { peripheralManager?.removeAllServices() }
        centralManager = nil
        peripheralManager = nil
        characteristic = nil
        peripherals.removeAll()
        subscribedCentrals.removeAll()
        centralToPeerID.removeAll()
        peerToPeripheralUUID.removeAll()
        connectionCandidates.removeAll()
        pendingNotifications.removeAll()
        pendingNotificationBytes = 0
        pendingWriteBuffers.removeAll()
        collectionsQueue.sync(flags: .barrier) {
            pendingPeripheralWrites.removeAll()
            pendingDirectedRelays.removeAll()
            incomingFragments.removeAll()
            fragmentMetadata.removeAll()
        }
        for peerID in peerIDs { retireUnlinkedPeer(peerID) }
    }

    private func setApplicationActive(_ active: Bool) {
        collectionsQueue.sync(flags: .barrier) { appActiveStorage = active }
        bleQueue.async { [weak self] in
            guard let self, self.isAppActive == active else { return }
            self.centralManager?.stopScan()
            self.scanDutyTimer?.cancel()
            self.scanDutyTimer = nil
            self.dutyActive = false
            if active {
                if self.centralManager == nil {
                    self.centralManager = CBCentralManager(delegate: self, queue: self.bleQueue)
                }
                if self.peripheralManager == nil {
                    self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.bleQueue)
                }
                self.startMaintenance()
                self.startServices()
                if let peripheral = self.peripheralManager, peripheral.state == .poweredOn,
                   self.characteristic != nil, !peripheral.isAdvertising {
                    peripheral.startAdvertising(self.buildAdvertisementData())
                }
                self.drainAllPendingWrites()
                if let peripheral = self.peripheralManager {
                    self.peripheralManagerIsReady(toUpdateSubscribers: peripheral)
                }
                let peers = self.collectionsQueue.sync { Array(self.announcementsByPeer.keys) }
                for peer in peers where self.noiseService.hasEstablishedSession(with: peer) {
                    self.requestHistory(from: peer)
                }
            } else {
                self.peripheralManager?.stopAdvertising()
                self.maintenanceTimer?.cancel()
                self.maintenanceTimer = nil
                if !self.backgroundReceptionEnabled {
                    self.disconnectBackgroundTransport()
                }
                // Preserve established subscriptions only when BTChat was selected.
                for state in self.peripherals.values where state.peripheral.state == .connecting {
                    self.centralManager?.cancelPeripheralConnection(state.peripheral)
                }
                self.collectionsQueue.async(flags: .barrier) {
                    self.scheduledRelays.removeAll()
                }
            }
        }
    }

    #if os(iOS)
    @objc private func appDidBecomeActive() {
        setApplicationActive(true)
    }

    @objc private func appDidEnterBackground() {
        setApplicationActive(false)
    }
    #endif

    // MARK: - Core Public API
    
    func startServices() {
        guard isAppActive else { return }
        // Start BLE services if not already running
        if centralManager?.state == .poweredOn {
            centralManager?.scanForPeripherals(
                withServices: [BLEService.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        
        // Send initial announce after services are ready
        // Use longer delay to avoid conflicts with other announces
        messageQueue.asyncAfter(deadline: .now() + TransportConfig.bleInitialAnnounceDelaySeconds) { [weak self] in
            self?.sendAnnounce(forceSend: true)
        }
    }

    // Transport protocol conformance helper: simplified public message send
    func sendMessage(_ content: String, mentions: [String]) {
        // Delegate to the full API with default routing
        sendMessage(content, mentions: mentions, to: nil, messageID: nil, timestamp: nil)
    }
    
    func stopServices() {
        // Send leave message synchronously to ensure delivery
        let leavePacket = BitchatPacket(
            type: MessageType.leave.rawValue,
            senderID: myPeerIDData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(),
            signature: nil,
            ttl: messageTTL
        )
        
        // Send immediately to all connected peers
        if let data = leavePacket.toBinaryData(padding: false) {
            // Send to peripherals we're connected to as central
            for state in peripherals.values where state.isConnected {
                if let characteristic = state.characteristic {
                    writeOrEnqueue(data, to: state.peripheral, characteristic: characteristic, priority: .high)
                }
            }
            
            // Send to centrals subscribed to us as peripheral
            if isAppActive && subscribedCentrals.count > 0 && characteristic != nil {
                peripheralManager?.updateValue(data, for: characteristic!, onSubscribedCentrals: nil)
            }
        }
        
        // Give leave message a moment to send
        Thread.sleep(forTimeInterval: TransportConfig.bleThreadSleepWriteShortDelaySeconds)
        
        // Clear pending notifications
        if DispatchQueue.getSpecific(key: bleQueueKey) != nil {
            pendingNotifications.removeAll()
            pendingNotificationBytes = 0
        } else {
            bleQueue.sync {
                pendingNotifications.removeAll()
                pendingNotificationBytes = 0
            }
        }
        
        // Stop timer
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        scanDutyTimer?.cancel()
        scanDutyTimer = nil
        
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        
        // Disconnect all peripherals
        for state in peripherals.values {
            centralManager?.cancelPeripheralConnection(state.peripheral)
        }
    }
    
    func isPeerConnected(_ peerID: String) -> Bool {
        // Accept both 16-hex short IDs and 64-hex Noise keys
        let shortID: String = {
            if peerID.count == 64, let key = Data(hexString: peerID) {
                return PeerIDUtils.derivePeerID(fromPublicKey: key)
            }
            return peerID
        }()
        return collectionsQueue.sync { peers[shortID]?.isConnected ?? false }
    }

    func isPeerReachable(_ peerID: String) -> Bool {
        // Accept both 16-hex short IDs and 64-hex Noise keys
        let shortID: String = {
            if peerID.count == 64, let key = Data(hexString: peerID) {
                return PeerIDUtils.derivePeerID(fromPublicKey: key)
            }
            return peerID
        }()
        return collectionsQueue.sync {
            // Must be mesh-attached: at least one live direct link to the mesh
            let meshAttached = peers.values.contains { $0.isConnected }
            guard let info = peers[shortID] else { return false }
            if info.isConnected { return true }
            guard meshAttached else { return false }
            // Apply reachability retention window
            let isVerified = info.isVerifiedNickname
            let retention: TimeInterval = isVerified ? TransportConfig.bleReachabilityRetentionVerifiedSeconds : TransportConfig.bleReachabilityRetentionUnverifiedSeconds
            return Date().timeIntervalSince(info.lastSeen) <= retention
        }
    }

    func peerNickname(peerID: String) -> String? {
        collectionsQueue.sync {
            guard let peer = peers[peerID], peer.isConnected else { return nil }
            return peer.nickname
        }
    }

    func getPeerNicknames() -> [String: String] {
        return collectionsQueue.sync {
            let connected = peers.filter { $0.value.isConnected }
            let tuples = connected.map { ($0.key, $0.value.nickname, true) }
            return PeerDisplayNameResolver.resolve(tuples, selfNickname: myNickname)
        }
    }
    
    func sendPrivateMessage(_ content: String, to recipientID: String, recipientNickname: String, messageID: String) {
        sendPrivateMessage(content, to: recipientID, messageID: messageID)
    }

    func sendAttachment(data: Data, fileName: String, mimeType: String, kind: BitchatAttachmentKind, caption: String, to peerID: String, recipientNickname: String, messageID: String) -> Bool {
        guard kind == .image else { return false }
        let packet = AttachmentPacket(
            messageID: messageID,
            fileName: fileName,
            mimeType: mimeType,
            caption: caption,
            kind: kind,
            fileData: data
        )

        guard let encoded = packet.encode() else {
            SecureLogger.log("Failed to encode attachment payload", category: SecureLogger.noise, level: .error)
            return false
        }

        var payload = Data([NoisePayloadType.attachment.rawValue])
        payload.append(encoded)
        return sendNoisePayload(payload, to: peerID, queueIfNeeded: false)
    }
    
    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        SecureLogger.log("🔔 sendFavoriteNotification called - peerID: \(peerID), isFavorite: \(isFavorite)",
                        category: SecureLogger.session, level: .debug)
        
        let content = isFavorite ? "[FAVORITED]" : "[UNFAVORITED]"
        
        SecureLogger.log("📤 Sending favorite notification to \(peerID): \(content)",
                        category: SecureLogger.session, level: .debug)
        sendPrivateMessage(content, to: peerID, messageID: UUID().uuidString)
    }
    
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String) {
        // Create typed payload: [type byte] + [message ID]
        var payload = Data([NoisePayloadType.readReceipt.rawValue])
        payload.append(contentsOf: receipt.originalMessageID.utf8)

        if sendNoisePayload(payload, to: peerID, queueIfNeeded: true) {
            SecureLogger.log("📤 Sending READ receipt for message \(receipt.originalMessageID) to \(peerID)", 
                            category: SecureLogger.session, level: .debug)
        } else {
            SecureLogger.log("🕒 Queued READ receipt for \(peerID) until handshake completes", 
                            category: SecureLogger.session, level: .debug)
        }
    }
    
    func sendBroadcastAnnounce() {
        sendAnnounce()
    }

    func getPeerFingerprint(_ peerID: String) -> String? {
        return collectionsQueue.sync {
            if let publicKey = peers[peerID]?.noisePublicKey {
                // Use the same fingerprinting method as NoiseEncryptionService/UnifiedPeerService (SHA-256 of raw key)
                let hash = SHA256.hash(data: publicKey)
                return hash.map { String(format: "%02x", $0) }.joined()
            }
            return nil
        }
    }

    // Transport compatibility: generic naming
    
    
    func getNoiseSessionState(for peerID: String) -> LazyHandshakeState {
        if noiseService.hasEstablishedSession(with: peerID) {
            return .established
        } else if noiseService.hasSession(with: peerID) {
            return .handshaking
        } else {
            return .none
        }
    }
    
    func triggerHandshake(with peerID: String) {
        initiateNoiseHandshake(with: peerID)
    }
    
    func getNoiseService() -> NoiseEncryptionService {
        return noiseService
    }
    
    func getFingerprint(for peerID: String) -> String? {
        return getPeerFingerprint(peerID)
    }
    
    func sendMessage(_ content: String, mentions: [String] = [], to recipientID: String? = nil, messageID: String? = nil, timestamp: Date? = nil) {
        // Ensure this runs on message queue to avoid main thread blocking
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard content.utf8.count <= TransportConfig.publicMessageMaxUTF8Bytes else {
                SecureLogger.log("Message too long: \(content.utf8.count) bytes", category: SecureLogger.session, level: .error)
                return
            }
            
            let finalMessageID = messageID ?? UUID().uuidString
            let _ = UInt64(Date().timeIntervalSince1970 * 1000)
            
            if let recipientID = recipientID {
                // Private message
                self.sendPrivateMessage(content, to: recipientID, messageID: finalMessageID)
            } else {
                // Public broadcast
                // Create packet with explicit fields so we can sign it
                let basePacket = BitchatPacket(
                    type: MessageType.message.rawValue,
                    senderID: Data(hexString: self.myPeerID) ?? Data(),
                    recipientID: nil,
                    timestamp: UInt64((timestamp ?? Date()).timeIntervalSince1970 * 1000),
                    payload: Data(content.utf8),
                    signature: nil,
                    ttl: self.messageTTL
                )
                guard let signedPacket = self.noiseService.signPacket(basePacket) else {
                    SecureLogger.log("❌ Failed to sign public message", category: SecureLogger.security, level: .error)
                    return
                }
                // Pre-mark our own broadcast as processed to avoid handling relayed self copy
                let dedupID = self.makeMessageID(for: signedPacket)
                self.messageDeduplicator.markProcessed(dedupID)
                // Call synchronously since we're already on background queue
                self.broadcastPacket(signedPacket)
                if let announcement = self.ownHistoryAnnouncement() {
                    let entry = MeshHistoryEntry(message: signedPacket, announcement: announcement)
                    Task { @concurrent in await self.historyStore.insert(entry) }
                }
            }
        }
    }

    //
    
    // MARK: - Private Message Handling
    
    private func sendPrivateMessage(_ content: String, to recipientID: String, messageID: String) {
        SecureLogger.log("📨 Sending PM to \(recipientID): \(content.prefix(30))...", category: SecureLogger.session, level: .debug)
        
        // Check if we have an established Noise session
        if noiseService.hasEstablishedSession(with: recipientID) {
            // Encrypt and send
            do {
                // Create TLV-encoded private message
                let privateMessage = PrivateMessagePacket(messageID: messageID, content: content)
                guard let tlvData = privateMessage.encode() else {
                    SecureLogger.log("Failed to encode private message with TLV", category: SecureLogger.noise, level: .error)
                    return
                }
                
                // Create message payload with TLV: [type byte] + [TLV data]
                var messagePayload = Data([NoisePayloadType.privateMessage.rawValue])
                messagePayload.append(tlvData)
                
                let encrypted = try noiseService.encrypt(messagePayload, for: recipientID)
                
                // Convert recipientID to Data (assuming it's a hex string)
                var recipientData = Data()
                var tempID = recipientID
                while tempID.count >= 2 {
                    let hexByte = String(tempID.prefix(2))
                    if let byte = UInt8(hexByte, radix: 16) {
                        recipientData.append(byte)
                    }
                    tempID = String(tempID.dropFirst(2))
                }
                if tempID.count == 1 {
                    if let byte = UInt8(tempID, radix: 16) {
                        recipientData.append(byte)
                    }
                }
                
            let packet = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: myPeerIDData,
                recipientID: recipientData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encrypted,
                signature: nil,
                ttl: messageTTL
            )
                // Call directly if already on messageQueue, otherwise dispatch
                if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
                    broadcastPacket(packet)
                } else {
                    messageQueue.async { [weak self] in
                        self?.broadcastPacket(packet)
                    }
                }
                
                // Notify delegate that message was sent
                Task { @MainActor in
                    self.delegate?.didUpdateMessageDeliveryStatus(messageID, status: .sent)
                }
            } catch {
                SecureLogger.log("Failed to encrypt message: \(error)", category: SecureLogger.noise, level: .error)
            }
        } else {
            // Queue message for sending after handshake completes
            SecureLogger.log("🤝 No session with \(recipientID), initiating handshake and queueing message", category: SecureLogger.session, level: .debug)
            
            // Queue the message (especially important for favorite notifications)
            collectionsQueue.sync(flags: .barrier) {
                if pendingMessagesAfterHandshake[recipientID] == nil {
                    pendingMessagesAfterHandshake[recipientID] = []
                }
                pendingMessagesAfterHandshake[recipientID]?.append((content, messageID))
            }
            
            initiateNoiseHandshake(with: recipientID)
            
            // Notify delegate that message is pending
            Task { @MainActor in
                self.delegate?.didUpdateMessageDeliveryStatus(messageID, status: .sending)
            }
        }
    }

    @discardableResult
    private func sendNoisePayload(_ payload: Data, to peerID: String, queueIfNeeded: Bool) -> Bool {
        guard isAppActive else { return false }
        if noiseService.hasEstablishedSession(with: peerID) {
            do {
                let encrypted = try noiseService.encrypt(payload, for: peerID)
                let packet = BitchatPacket(
                    type: MessageType.noiseEncrypted.rawValue,
                    senderID: myPeerIDData,
                    recipientID: Data(hexString: peerID),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: encrypted,
                    signature: nil,
                    ttl: messageTTL
                )
                if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
                    broadcastPacket(packet)
                } else {
                    messageQueue.async { [weak self] in
                        self?.broadcastPacket(packet)
                    }
                }
                return true
            } catch {
                SecureLogger.log("Failed to send noise payload: \(error)", category: SecureLogger.noise, level: .error)
                return false
            }
        }

        guard queueIfNeeded else {
            return false
        }

        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.pendingNoisePayloadsAfterHandshake[peerID, default: []].append(payload)
        }
        if !noiseService.hasSession(with: peerID) {
            initiateNoiseHandshake(with: peerID)
        }
        return false
    }
    
    private func initiateNoiseHandshake(with peerID: String) {
        guard isAppActive else { return }
        // Use NoiseEncryptionService for handshake
        guard !noiseService.hasSession(with: peerID) else { return }
        
        do {
            let handshakeData = try noiseService.initiateHandshake(with: peerID)
            
            // Send handshake init
            let packet = BitchatPacket(
                type: MessageType.noiseHandshake.rawValue,
                senderID: myPeerIDData,
                recipientID: Data(hexString: peerID),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: handshakeData,
                signature: nil,
                ttl: messageTTL
            )
            // Call directly if on messageQueue, otherwise dispatch
            if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
                broadcastPacket(packet)
            } else {
                messageQueue.async { [weak self] in
                    self?.broadcastPacket(packet)
                }
            }
        } catch {
            SecureLogger.log("Failed to initiate handshake: \(error)", category: SecureLogger.noise, level: .error)
        }
    }
    
    private func sendPendingMessagesAfterHandshake(for peerID: String) {
        // Get and clear pending messages for this peer
        let pendingMessages = collectionsQueue.sync(flags: .barrier) { () -> [(content: String, messageID: String)]? in
            let messages = pendingMessagesAfterHandshake[peerID]
            pendingMessagesAfterHandshake.removeValue(forKey: peerID)
            return messages
        }
        
        guard let messages = pendingMessages, !messages.isEmpty else { return }
        
        SecureLogger.log("📤 Sending \(messages.count) pending messages after handshake to \(peerID)", 
                        category: SecureLogger.session, level: .debug)
        
        // Send each pending message directly (we know session is established)
        for (content, messageID) in messages {
            do {
                // Use the same TLV format as normal sends to keep receiver decoding consistent
                let privateMessage = PrivateMessagePacket(messageID: messageID, content: content)
                guard let tlvData = privateMessage.encode() else {
                    SecureLogger.log("Failed to encode pending private message TLV", category: SecureLogger.noise, level: .error)
                    continue
                }

                var messagePayload = Data([NoisePayloadType.privateMessage.rawValue])
                messagePayload.append(tlvData)

                let encrypted = try noiseService.encrypt(messagePayload, for: peerID)

                let packet = BitchatPacket(
                    type: MessageType.noiseEncrypted.rawValue,
                    senderID: myPeerIDData,
                    recipientID: Data(hexString: peerID),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: encrypted,
                    signature: nil,
                    ttl: messageTTL
                )

                // We're already on messageQueue from the callback
                broadcastPacket(packet)

                // Notify delegate that message was sent
                Task { @MainActor in
                    self.delegate?.didUpdateMessageDeliveryStatus(messageID, status: .sent)
                }

                SecureLogger.log("✅ Sent pending message \(messageID) to \(peerID) after handshake", 
                                category: SecureLogger.session, level: .debug)
            } catch {
                SecureLogger.log("Failed to send pending message after handshake: \(error)", 
                                category: SecureLogger.noise, level: .error)

                // Notify delegate of failure
                Task { @MainActor in
                    self.delegate?.didUpdateMessageDeliveryStatus(messageID, status: .failed(reason: "Encryption failed"))
                }
            }
        }
    }
    
    // MARK: - Packet Broadcasting
    
    private func broadcastPacket(_ packet: BitchatPacket) {
        guard isAppActive else { return }
        // Encode once using a small per-type padding policy, then delegate by type
        let padForBLE = padPolicy(for: packet.type)
        guard let data = packet.toBinaryData(padding: padForBLE) else {
            SecureLogger.log("❌ Failed to convert packet to binary data", category: SecureLogger.session, level: .error)
            return
        }
        if packet.type == MessageType.noiseEncrypted.rawValue {
            sendEncrypted(packet, data: data, pad: padForBLE)
            return
        }
        sendGenericBroadcast(packet, data: data, pad: padForBLE)
    }

    // MARK: - Broadcast helpers (single responsibility)
    private func padPolicy(for type: UInt8) -> Bool {
        switch MessageType(rawValue: type) {
        case .noiseEncrypted, .noiseHandshake:
            return true
        default:
            return false
        }
    }

    private func sendEncrypted(_ packet: BitchatPacket, data: Data, pad: Bool) {
        guard let recipientID = packet.recipientID else { return }
        let recipientPeerID = recipientID.hexEncodedString()
        var sentEncrypted = false

        // Per-link limits for the specific peer
        var peripheralMaxLen: Int?
        if let perUUID = (DispatchQueue.getSpecific(key: bleQueueKey) != nil) ? peerToPeripheralUUID[recipientPeerID] : bleQueue.sync(execute: { peerToPeripheralUUID[recipientPeerID] }) {
            if let state = (DispatchQueue.getSpecific(key: bleQueueKey) != nil) ? peripherals[perUUID] : bleQueue.sync(execute: { peripherals[perUUID] }) {
                peripheralMaxLen = state.peripheral.maximumWriteValueLength(for: .withoutResponse)
            }
        }
        var centralMaxLen: Int?
        do {
            let (centrals, mapping) = snapshotSubscribedCentrals()
            if let central = centrals.first(where: { mapping[$0.identifier.uuidString] == recipientPeerID }) {
                centralMaxLen = central.maximumUpdateValueLength
            }
        }
        if let pm = peripheralMaxLen, data.count > pm {
            let overhead = BinaryProtocol.headerSize + BinaryProtocol.senderIDSize + BinaryProtocol.recipientIDSize + 13
            let chunk = max(1, pm - overhead)
            sendFragmentedPacket(packet, pad: pad, maxChunk: chunk, directedOnlyPeer: recipientPeerID)
            return
        }
        if let cm = centralMaxLen, data.count > cm {
            let overhead = BinaryProtocol.headerSize + BinaryProtocol.senderIDSize + BinaryProtocol.recipientIDSize + 13
            let chunk = max(1, cm - overhead)
            sendFragmentedPacket(packet, pad: pad, maxChunk: chunk, directedOnlyPeer: recipientPeerID)
            return
        }

        // Direct write via peripheral link
        if let peripheralUUID = (DispatchQueue.getSpecific(key: bleQueueKey) != nil) ? peerToPeripheralUUID[recipientPeerID] : bleQueue.sync(execute: { peerToPeripheralUUID[recipientPeerID] }),
           let state = (DispatchQueue.getSpecific(key: bleQueueKey) != nil) ? peripherals[peripheralUUID] : bleQueue.sync(execute: { peripherals[peripheralUUID] }),
           state.isConnected,
           let characteristic = state.characteristic {
            writeOrEnqueue(data, to: state.peripheral, characteristic: characteristic, priority: priority(for: packet, data: data))
            sentEncrypted = true
        }

        // Notifications must retain fragments when CoreBluetooth applies backpressure.
        if !sentEncrypted {
            let (centrals, mapping) = snapshotSubscribedCentrals()
            let targets = centrals.filter { mapping[$0.identifier.uuidString] == recipientPeerID }
            if !targets.isEmpty {
                notifyOrEnqueue(data, to: targets)
                sentEncrypted = true
            }
        }

        if !sentEncrypted {
            // Flood as last resort with recipient set; link aware
            sendOnAllLinks(packet: packet, data: data, pad: pad, directedOnlyPeer: recipientPeerID)
        }
    }

    private func sendGenericBroadcast(_ packet: BitchatPacket, data: Data, pad: Bool) {
        sendOnAllLinks(packet: packet, data: data, pad: pad, directedOnlyPeer: nil)
    }

    private func sendOnAllLinks(packet: BitchatPacket, data: Data, pad: Bool, directedOnlyPeer: String?) {
        // Determine last-hop link for this message to avoid echoing back
        let messageID = makeMessageID(for: packet)
        let ingressLink: LinkID? = collectionsQueue.sync { ingressByMessageID[messageID]?.link }

        let states = snapshotPeripheralStates()
        var minCentralWriteLen: Int?
        for s in states where s.isConnected {
            let m = s.peripheral.maximumWriteValueLength(for: .withoutResponse)
            minCentralWriteLen = minCentralWriteLen.map { min($0, m) } ?? m
        }
        var snapshotCentrals: [CBCentral] = []
        if let _ = characteristic {
            let (centrals, _) = snapshotSubscribedCentrals()
            snapshotCentrals = centrals
        }
        var minNotifyLen: Int?
        if !snapshotCentrals.isEmpty {
            minNotifyLen = snapshotCentrals.map { $0.maximumUpdateValueLength }.min()
        }
        // Avoid re-fragmenting fragment packets
        if packet.type != MessageType.fragment.rawValue,
           let minLen = [minCentralWriteLen, minNotifyLen].compactMap({ $0 }).min(),
           data.count > minLen {
            let overhead = BinaryProtocol.headerSize + BinaryProtocol.senderIDSize + BinaryProtocol.recipientIDSize + 13
            let chunk = max(1, minLen - overhead)
            sendFragmentedPacket(packet, pad: pad, maxChunk: chunk, directedOnlyPeer: directedOnlyPeer)
            return
        }
        // Build link lists and apply K-of-N fanout for broadcasts; always exclude ingress link
        let connectedPeripheralIDs: [String] = states.filter { $0.isConnected }.map { $0.peripheral.identifier.uuidString }
        let subscribedCentrals: [CBCentral]
        var centralIDs: [String] = []
        if let _ = characteristic {
            let (centrals, _) = snapshotSubscribedCentrals()
            subscribedCentrals = centrals
            centralIDs = centrals.map { $0.identifier.uuidString }
        } else {
            subscribedCentrals = []
        }

        // Exclude ingress link
        var allowedPeripheralIDs = connectedPeripheralIDs
        var allowedCentralIDs = centralIDs
        if let ingress = ingressLink {
            switch ingress {
            case .peripheral(let id):
                allowedPeripheralIDs.removeAll { $0 == id }
            case .central(let id):
                allowedCentralIDs.removeAll { $0 == id }
            }
        }

        // For broadcast (no directed peer) and non-fragment, choose a subset deterministically
        // Special-case announces: do NOT subset to maximize reach for presence
        var selectedPeripheralIDs = Set(allowedPeripheralIDs)
        var selectedCentralIDs = Set(allowedCentralIDs)
        if directedOnlyPeer == nil && packet.type != MessageType.fragment.rawValue && packet.type != MessageType.announce.rawValue {
            let kp = subsetSizeForFanout(allowedPeripheralIDs.count)
            let kc = subsetSizeForFanout(allowedCentralIDs.count)
            selectedPeripheralIDs = selectDeterministicSubset(ids: allowedPeripheralIDs, k: kp, seed: messageID)
            selectedCentralIDs = selectDeterministicSubset(ids: allowedCentralIDs, k: kc, seed: messageID)
        }

        // If directed and we currently have no links to forward on, spool for a short window
        if let only = directedOnlyPeer,
           selectedPeripheralIDs.isEmpty && selectedCentralIDs.isEmpty,
           (packet.type == MessageType.noiseEncrypted.rawValue || packet.type == MessageType.noiseHandshake.rawValue) {
            spoolDirectedPacket(packet, recipientPeerID: only)
        }

        // Writes to selected connected peripherals
        for s in states where s.isConnected {
            let pid = s.peripheral.identifier.uuidString
            guard selectedPeripheralIDs.contains(pid) else { continue }
            if let ch = s.characteristic {
                writeOrEnqueue(data, to: s.peripheral, characteristic: ch, priority: priority(for: packet, data: data))
            }
        }
        let targets = subscribedCentrals.filter { selectedCentralIDs.contains($0.identifier.uuidString) }
        if !targets.isEmpty {
            notifyOrEnqueue(data, to: targets)
        }
    }

    /// Uses the existing CoreBluetooth delegate queue to preserve notification order.
    private func notifyOrEnqueue(_ data: Data, to centrals: [CBCentral]) {
        bleQueue.async { [weak self] in
            guard let self, let characteristic = self.characteristic,
                  centrals.allSatisfy({ data.count <= $0.maximumUpdateValueLength }) else { return }
            if self.isAppActive, self.pendingNotifications.isEmpty,
               self.peripheralManager?.updateValue(data, for: characteristic, onSubscribedCentrals: centrals) == true {
                return
            }
            guard self.pendingNotificationBytes + data.count <= TransportConfig.blePendingNotificationBufferCapBytes else {
                SecureLogger.log("Bluetooth notification buffer exhausted", category: SecureLogger.session, level: .error)
                return
            }
            self.pendingNotifications.append((data, centrals))
            self.pendingNotificationBytes += data.count
        }
    }

    // MARK: - Directed store-and-forward
    private func spoolDirectedPacket(_ packet: BitchatPacket, recipientPeerID: String) {
        let msgID = makeMessageID(for: packet)
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            var byMsg = self.pendingDirectedRelays[recipientPeerID] ?? [:]
            if byMsg[msgID] == nil {
                byMsg[msgID] = (packet: packet, enqueuedAt: Date())
                self.pendingDirectedRelays[recipientPeerID] = byMsg
                SecureLogger.log("🧳 Spooling directed packet for \(recipientPeerID) mid=\(msgID.prefix(8))…", category: SecureLogger.session, level: .debug)
            }
        }
    }

    private func flushDirectedSpool() {
        guard isAppActive else { return }
        // Move items out and attempt broadcast; if still no links, they'll be re-spooled
        let toSend: [(String, BitchatPacket)] = collectionsQueue.sync(flags: .barrier) {
            var out: [(String, BitchatPacket)] = []
            let now = Date()
            for (recipient, dict) in pendingDirectedRelays {
                for (_, entry) in dict {
                    if now.timeIntervalSince(entry.enqueuedAt) <= TransportConfig.bleDirectedSpoolWindowSeconds {
                        out.append((recipient, entry.packet))
                    }
                }
                // Clear recipient bucket; items will be re-spooled if still no links
                pendingDirectedRelays.removeValue(forKey: recipient)
            }
            return out
        }
        guard !toSend.isEmpty else { return }
        for (_, packet) in toSend {
            messageQueue.async { [weak self] in self?.broadcastPacket(packet) }
        }
    }

    private func sendData(_ data: Data, to peripheral: CBPeripheral) {
        // Fire-and-forget: Simple send without complex fallback logic
        guard peripheral.state == .connected else { return }
        
        let peripheralUUID = peripheral.identifier.uuidString
        guard let state = peripherals[peripheralUUID],
              let characteristic = state.characteristic else { return }
        
        // Fire-and-forget principle: always use .withoutResponse for speed
        // CoreBluetooth will handle fragmentation at L2CAP layer
        writeOrEnqueue(data, to: peripheral, characteristic: characteristic, priority: .high)
    }
    
    // MARK: - Fragmentation (Required for messages > BLE MTU)
    
    private func sendFragmentedPacket(_ packet: BitchatPacket, pad: Bool, maxChunk: Int? = nil, directedOnlyPeer: String? = nil) {
        guard let fullData = packet.toBinaryData(padding: pad) else { return }
        // Fragment the unpadded frame; each fragment will be encoded independently
        
        let fragmentID = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let chunk = maxChunk ?? defaultFragmentSize
        let overhead = BinaryProtocol.headerSize + BinaryProtocol.senderIDSize + 13 +
            ((directedOnlyPeer != nil || packet.recipientID != nil) ? BinaryProtocol.recipientIDSize : 0)
        // Fragments are forwarded on every eligible link, including links with a smaller MTU.
        let writeLimits = snapshotPeripheralStates().filter(\.isConnected).map {
            $0.peripheral.maximumWriteValueLength(for: .withoutResponse)
        }
        let notificationLimits = snapshotSubscribedCentrals().0.map(\.maximumUpdateValueLength)
        let linkLimit = (writeLimits + notificationLimits).min() ?? (overhead + chunk)
        guard linkLimit > overhead else { return }
        let safeChunk = max(1, min(chunk, linkLimit - overhead))
        let fragments = stride(from: 0, to: fullData.count, by: safeChunk).map { offset in
            Data(fullData[offset..<min(offset + safeChunk, fullData.count)])
        }
        guard fragments.count <= Int(UInt16.max) else { return }
        // Lightweight pacing to reduce floods and allow BLE buffers to drain
        // Also briefly pause scanning during long fragment trains to save battery
        let totalFragments = fragments.count
        if totalFragments > 4 {
            bleQueue.async { [weak self] in
                guard let self = self, let c = self.centralManager, c.state == .poweredOn else { return }
                if c.isScanning { c.stopScan() }
                // Resume scanning after we expect last fragment to be sent
            let expectedMs = min(TransportConfig.bleExpectedWriteMaxMs, totalFragments * TransportConfig.bleExpectedWritePerFragmentMs) // ~8ms per fragment
                self.bleQueue.asyncAfter(deadline: .now() + .milliseconds(expectedMs)) { [weak self] in
                    self?.startScanning()
                }
            }
        }

        for (index, fragment) in fragments.enumerated() {
            var payload = Data()
            payload.append(fragmentID)
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(index).bigEndian) { Data($0) })
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(fragments.count).bigEndian) { Data($0) })
            payload.append(packet.type)
            payload.append(fragment)
            
            // Choose recipient for the fragment: directed override if provided
            let fragmentRecipient: Data? = {
                if let only = directedOnlyPeer { return Data(hexString: only) }
                return packet.recipientID
            }()

            let fragmentPacket = BitchatPacket(
                type: MessageType.fragment.rawValue,
                senderID: packet.senderID,
                recipientID: fragmentRecipient,
                timestamp: packet.timestamp,
                payload: payload,
                signature: nil,
                ttl: packet.ttl
            )
            // Pace fragments with small jitter to avoid bursts
            let perFragMs = (directedOnlyPeer != nil || packet.recipientID != nil) ? TransportConfig.bleFragmentSpacingDirectedMs : TransportConfig.bleFragmentSpacingMs
            let delayMs = index * perFragMs
            messageQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                self?.broadcastPacket(fragmentPacket)
            }
        }
    }
    
    private func handleFragment(_ packet: BitchatPacket, from peerID: String) {
        // Don't process our own fragments
        if peerID == myPeerID {
            return
        }
        
        // Minimum header: 8 bytes ID + 2 index + 2 total + 1 type
        guard packet.payload.count >= 13 else { return }

        // Compute compact fragment key (sender: 8 bytes, id: 8 bytes), big-endian
        var senderU64: UInt64 = 0
        for b in packet.senderID.prefix(8) { senderU64 = (senderU64 << 8) | UInt64(b) }
        var fragU64: UInt64 = 0
        for b in packet.payload.prefix(8) { fragU64 = (fragU64 << 8) | UInt64(b) }
        // Parse big-endian UInt16 safely without alignment assumptions
        let idxHi = UInt16(packet.payload[8])
        let idxLo = UInt16(packet.payload[9])
        let index = Int((idxHi << 8) | idxLo)
        let totHi = UInt16(packet.payload[10])
        let totLo = UInt16(packet.payload[11])
        let total = Int((totHi << 8) | totLo)
        let originalType = packet.payload[12]
        let fragmentData = packet.payload.suffix(from: 13)

        // Sanity checks
        guard total > 0 && index >= 0 && index < total else { return }

        // Arrivals and expiry both use the collections barrier. A photo can have
        // hundreds of fragments arriving concurrently on the message queue.
        let reassembled: Data? = collectionsQueue.sync(flags: .barrier) {
            let key = FragmentKey(sender: senderU64, id: fragU64)
            if let metadata = fragmentMetadata[key] {
                guard metadata.type == originalType, metadata.total == total else { return nil }
            } else {
                if incomingFragments.count >= maxInFlightAssemblies,
                   let oldest = fragmentMetadata.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                    incomingFragments.removeValue(forKey: oldest)
                    fragmentMetadata.removeValue(forKey: oldest)
                }
                incomingFragments[key] = [:]
                fragmentMetadata[key] = (originalType, total, Date())
            }
            incomingFragments[key]?[index] = Data(fragmentData)
            guard let fragments = incomingFragments[key], fragments.count == total else { return nil }

            var data = Data()
            for i in 0..<total {
                guard let fragment = fragments[i] else { return nil }
                data.append(fragment)
            }
            incomingFragments.removeValue(forKey: key)
            fragmentMetadata.removeValue(forKey: key)
            return data
        }
        // Decode outside the barrier; packet handling also uses collectionsQueue.
        if let reassembled {
            if let originalPacket = BinaryProtocol.decode(reassembled) {
                handleReceivedPacket(originalPacket, from: peerID)
            } else {
                SecureLogger.log("Failed to decode reassembled packet (type=\(originalType), total=\(total))", category: SecureLogger.session, level: .error)
            }
        }
    }

    private func handleReceivedPacket(_ packet: BitchatPacket, from peerID: String) {
        guard isAppActive || backgroundReceptionEnabled else { return }
        guard packet.version == 1, MessageType(rawValue: packet.type) != nil else { return }
        // Reject incompatible announcements before they affect deduplication or get relayed.
        if packet.type == MessageType.announce.rawValue, !isValidLiveAnnouncement(packet) { return }
        // Deduplication (thread-safe)
        let senderID = packet.senderID.hexEncodedString()
        // Payload identity also distinguishes fragments and same-millisecond messages.
        let messageID = makeMessageID(for: packet)
        
        // Only log non-announce packets to reduce noise
        if packet.type != MessageType.announce.rawValue {
            // Log packet details for debugging
            SecureLogger.log("📦 Handling packet type \(packet.type) from \(senderID), messageID: \(messageID)", 
                            category: SecureLogger.session, level: .debug)
        }
        
        // Efficient deduplication
        // Important: do not dedup fragment packets globally (each piece must pass)
        if packet.type != MessageType.fragment.rawValue && messageDeduplicator.isDuplicate(messageID) {
            // Announce packets (type 1) are sent every 10 seconds for peer discovery
            // It's normal to see these as duplicates - don't log them to reduce noise
            if packet.type != MessageType.announce.rawValue {
                SecureLogger.log("⚠️ Duplicate packet ignored: \(messageID)", 
                                category: SecureLogger.session, level: .debug)
            }
            // In sparse graphs (<=2 neighbors), keep the pending relay to ensure bridging.
            // In denser graphs, cancel the pending relay to reduce redundant floods.
            let connectedCount = collectionsQueue.sync { peers.values.filter { $0.isConnected }.count }
            if connectedCount > 2 {
                collectionsQueue.async(flags: .barrier) { [weak self] in
                    _ = self?.scheduledRelays.removeValue(forKey: messageID)
                }
            }
            return // Duplicate ignored
        }
        
        // Update peer info without verbose logging - update the peer we received from, not the original sender
        if packet.type != MessageType.announce.rawValue { updatePeerLastSeen(peerID) }

        // Track recent traffic timestamps for adaptive behavior
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let now = Date()
            self.recentPacketTimestamps.append(now)
            // keep last N timestamps within window
            let cutoff = now.addingTimeInterval(-TransportConfig.bleRecentPacketWindowSeconds)
            if self.recentPacketTimestamps.count > TransportConfig.bleRecentPacketWindowMaxCount {
                self.recentPacketTimestamps.removeFirst(self.recentPacketTimestamps.count - TransportConfig.bleRecentPacketWindowMaxCount)
            }
            self.recentPacketTimestamps.removeAll { $0 < cutoff }
        }

        
        // Process by type
        switch MessageType(rawValue: packet.type) {
        case .announce:
            handleAnnounce(packet, from: senderID)
            
        case .message:
            handleMessage(packet, from: senderID)
            
        case .noiseHandshake:
            handleNoiseHandshake(packet, from: senderID)
            
        case .noiseEncrypted:
            handleNoiseEncrypted(packet, from: senderID)
            
        case .fragment:
            handleFragment(packet, from: senderID)
            
        case .leave:
            handleLeave(packet, from: senderID)
            
        default:
            SecureLogger.log("⚠️ Unknown message type: \(packet.type)", category: SecureLogger.session, level: .warning)
            break
        }
        
        if isAppActive, packet.ttl > 1, senderID != myPeerID {
            let delayMs = packet.type == MessageType.fragment.rawValue ? 8 : Int.random(in: 12...48)
            let relayToken = UUID()
            collectionsQueue.async(flags: .barrier) { [weak self] in
                self?.scheduledRelays[messageID] = relayToken
            }
            messageQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self = self else { return }
                let shouldRelay = self.collectionsQueue.sync(flags: .barrier) {
                    guard self.scheduledRelays[messageID] == relayToken else {
                        return false
                    }
                    self.scheduledRelays.removeValue(forKey: messageID)
                    return true
                }
                guard shouldRelay else { return }
                var relayPacket = packet
                relayPacket.ttl = packet.ttl - 1
                self.broadcastPacket(relayPacket)
            }
        }
    }
    
    private func handleAnnounce(_ packet: BitchatPacket, from peerID: String) {
        guard let announcement = AnnouncementPacket.decode(from: packet.payload) else {
            SecureLogger.log("❌ Failed to decode announce packet from \(peerID)", category: SecureLogger.session, level: .error)
            return
        }
        
        guard isValidLiveAnnouncement(packet), peerID != myPeerID else { return }
        let liveLinks = directlyConnectedPeerIDs()
        let previous = collectionsQueue.sync { announcementsByPeer[peerID] }
        if let previous {
            // Older relays must not replace a newer process announcement.
            guard packet.timestamp >= previous.timestamp else { return }
            if let previousAuthor = AnnouncementPacket.decode(from: previous.payload),
               let newSession = announcement.sessionID, previousAuthor.sessionID != newSession {
                noiseService.removePeer(peerID)
            }
        }

        // Track if this is a new or reconnected peer
        var isNewPeer = false
        var isReconnectedPeer = false
        
        collectionsQueue.sync(flags: .barrier) {
            let isDirectAnnounce = liveLinks.contains(peerID)

            // Check if we already have this peer (might be reconnecting)
            let existingPeer = peers[peerID]
            let wasDisconnected = existingPeer?.isConnected == false
            
            // Set flags for use outside the sync block
            isNewPeer = (existingPeer == nil)
            isReconnectedPeer = wasDisconnected
            
            peers[peerID] = PeerInfo(
                id: peerID,
                nickname: announcement.nickname,
                isConnected: isDirectAnnounce,
                noisePublicKey: announcement.noisePublicKey,
                signingPublicKey: announcement.signingPublicKey,
                isVerifiedNickname: true,
                lastSeen: Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
            )

            // Log connection status only for direct connectivity changes; debounce to reduce spam
            if isDirectAnnounce {
                let now = Date()
                if existingPeer == nil {
                    SecureLogger.log("🆕 New peer: \(announcement.nickname)", category: SecureLogger.session, level: .debug)
                } else if wasDisconnected {
                    // Debounce 'reconnected' logs within short window
                    if let last = lastReconnectLogAt[peerID], now.timeIntervalSince(last) < TransportConfig.bleReconnectLogDebounceSeconds {
                        // Skip duplicate log
                    } else {
                        SecureLogger.log("🔄 Peer \(announcement.nickname) reconnected", category: SecureLogger.session, level: .debug)
                        lastReconnectLogAt[peerID] = now
                    }
                } else if existingPeer?.nickname != announcement.nickname {
                    SecureLogger.log("🔄 Peer \(peerID) changed nickname: \(existingPeer?.nickname ?? "Unknown") -> \(announcement.nickname)", category: SecureLogger.session, level: .debug)
                }
            }
        }

        // Persist cryptographic identity and signing key for robust offline verification
        do {
            // Derive fingerprint from Noise public key
            let hash = SHA256.hash(data: announcement.noisePublicKey)
            let fingerprint = hash.map { String(format: "%02x", $0) }.joined()
            SecureIdentityStateManager.shared.upsertCryptographicIdentity(
                fingerprint: fingerprint,
                noisePublicKey: announcement.noisePublicKey,
                signingPublicKey: announcement.signingPublicKey,
                claimedNickname: announcement.nickname
            )
        }

        collectionsQueue.sync(flags: .barrier) {
            announcementsByPeer[peerID] = packet
        }
        if liveLinks.contains(peerID) {
            // One deterministic initiator avoids simultaneous Noise handshakes.
            if myPeerID < peerID { initiateNoiseHandshake(with: peerID) }
            if noiseService.hasEstablishedSession(with: peerID) { requestHistory(from: peerID) }
        }

        // Notify UI on main thread
        Task { @MainActor [isNewPeer, isReconnectedPeer]  in
            
            // Get current peer list (after addition)
            let currentPeerIDs = self.collectionsQueue.sync { self.peers.keys }
            
            // Only notify of connection for new or reconnected peers when it is a direct announce
            if (packet.ttl == self.messageTTL) && (isNewPeer || isReconnectedPeer) {
                await self.delegate?.didConnectToPeer(peerID)
            }
            
            self.requestPeerDataPublish()
            self.delegate?.didUpdatePeerList(currentPeerIDs)
        }
        
        // Send announce back for bidirectional discovery (only once per peer)
        let announceBackID = "announce-back-\(peerID)"
        let shouldSendBack = !messageDeduplicator.contains(announceBackID)
        if shouldSendBack {
            messageDeduplicator.markProcessed(announceBackID)
        }
        
        if shouldSendBack {
            // Reciprocate announce for bidirectional discovery
            // Force send to ensure the peer receives our announce
            sendAnnounce(forceSend: true)
        }

        // Afterglow: on first-seen peers, schedule a short re-announce to push presence one more hop
        if isNewPeer {
            let delay = Double.random(in: 0.3...0.6)
            messageQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendAnnounce(forceSend: true)
            }
        }
    }
    
    // Mention parsing moved to BitchatViewModel
    
    private func handleMessage(_ packet: BitchatPacket, from peerID: String) {
        guard peerID != myPeerID,
              let announcement = collectionsQueue.sync(execute: { announcementsByPeer[peerID] }) else { return }
        let entry = MeshHistoryEntry(message: packet, announcement: announcement)
        guard let author = verifiedHistoryAuthor(entry),
              let content = String(data: packet.payload, encoding: .utf8) else { return }
        Task { @concurrent [weak self] in
            guard let self else { return }
            _ = await historyStore.insert(entry)
            await delegate?.didReceivePublicMessage(
                from: peerID, nickname: author.nickname, content: content,
                timestamp: Date(timeIntervalSince1970: Double(packet.timestamp) / 1000),
                messageID: entry.id, isHistorical: false
            )
        }
    }

    private func handleNoiseHandshake(_ packet: BitchatPacket, from peerID: String) {
        // Use NoiseEncryptionService for handshake processing
        if let recipientID = packet.recipientID,
           recipientID.hexEncodedString() == myPeerID {
            // Handshake is for us
            do {
                if let response = try noiseService.processHandshakeMessage(from: peerID, message: packet.payload) {
                    // Send response
                    let responsePacket = BitchatPacket(
                        type: MessageType.noiseHandshake.rawValue,
                        senderID: myPeerIDData,
                        recipientID: Data(hexString: peerID),
                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                        payload: response,
                        signature: nil,
                        ttl: messageTTL
                    )
                    // We're on messageQueue from delegate callback
                    broadcastPacket(responsePacket)
                }
                
                // Session establishment will trigger onPeerAuthenticated callback
                // which will send any pending messages at the right time
            } catch {
                SecureLogger.log("Failed to process handshake: \(error)", category: SecureLogger.noise, level: .error)
                // Try initiating a new handshake
                if !noiseService.hasSession(with: peerID) {
                    initiateNoiseHandshake(with: peerID)
                }
            }
        }
    }
    
    private func handleNoiseEncrypted(_ packet: BitchatPacket, from peerID: String) {
        guard collectionsQueue.sync(execute: { announcementsByPeer[peerID] != nil }) else { return }
        SecureLogger.log("🔐 handleNoiseEncrypted called for packet from \(peerID)", 
                        category: SecureLogger.noise, level: .debug)
        
        guard let recipientID = packet.recipientID else {
            SecureLogger.log("⚠️ Encrypted message has no recipient ID", category: SecureLogger.session, level: .warning)
            return
        }
        
        let recipientHex = recipientID.hexEncodedString()
        if recipientHex != myPeerID {
            SecureLogger.log("🔐 Encrypted message not for me (for \(recipientHex), I am \(myPeerID))", category: SecureLogger.session, level: .debug)
            return
        }
        
        // Update lastSeen for the peer we received from (important for private messages)
        updatePeerLastSeen(peerID)
        
        do {
            let decrypted = try noiseService.decrypt(packet.payload, from: peerID)
            guard !decrypted.isEmpty else { return }
            
            // First byte indicates the payload type
            let payloadType = decrypted[0]
            let payloadData = decrypted.dropFirst()
            
            if let noisePayloadType = NoisePayloadType(rawValue: payloadType) {
                if noisePayloadType == .historyRequest || noisePayloadType == .historyEntry {
                    handleHistoryPayload(Data(payloadData), type: noisePayloadType, from: peerID)
                    return
                }
                let ts = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
                Task { @MainActor in
                    self.delegate?.didReceiveNoisePayload(from: peerID, type: noisePayloadType, payload: Data(payloadData), timestamp: ts)
                }
            }
            else {
                SecureLogger.log("⚠️ Unknown noise payload type: \(payloadType)", category: SecureLogger.noise, level: .warning)
            }
        } catch NoiseEncryptionError.sessionNotEstablished {
            // We received an encrypted message before establishing a session with this peer.
            // Trigger a handshake so future messages can be decrypted.
            SecureLogger.log("🔑 Encrypted message from \(peerID) without session; initiating handshake", 
                            category: SecureLogger.noise, level: .debug)
            if !noiseService.hasSession(with: peerID) {
                initiateNoiseHandshake(with: peerID)
            }
        } catch {
            SecureLogger.log("❌ Failed to decrypt message from \(peerID): \(error)", 
                            category: SecureLogger.noise, level: .error)
        }
    }
    
    private func handleLeave(_ packet: BitchatPacket, from peerID: String) {
        _ = collectionsQueue.sync(flags: .barrier) {
            // Remove the peer when they leave
            peers.removeValue(forKey: peerID)
        }
        // Send on main thread
        Task { @MainActor in
            
            // Get current peer list (after removal)
            let currentPeerIDs = self.collectionsQueue.sync { self.peers.keys }
            
            self.delegate?.didDisconnectFromPeer(peerID)
            self.delegate?.didUpdatePeerList(currentPeerIDs)
        }
    }
    
    // MARK: - Helper Functions
    
    private func sendLeave() {
        SecureLogger.log("👋 Sending leave announcement", category: SecureLogger.session, level: .debug)
        let packet = BitchatPacket(
            type: MessageType.leave.rawValue,
            ttl: messageTTL,
            senderID: myPeerID,
            payload: Data(myNickname.utf8)
        )
        broadcastPacket(packet)
    }
    
    private func sendAnnounce(forceSend: Bool = false) {
        guard isAppActive else { return }
        // Throttle announces to prevent flooding
        let now = Date()
        let timeSinceLastAnnounce = now.timeIntervalSince(lastAnnounceSent)
        
        // Even forced sends should respect a minimum interval to avoid overwhelming BLE
        let minInterval = forceSend ? TransportConfig.bleForceAnnounceMinIntervalSeconds : announceMinInterval
        
        if timeSinceLastAnnounce < minInterval {
            // Skipping announce (rate limited)
            return
        }
        lastAnnounceSent = now
        
        // Reduced logging - only log errors, not every announce
        
        // Create announce payload with both noise and signing public keys
        let noisePub = noiseService.getStaticPublicKeyData()  // For noise handshakes and peer identification
        let signingPub = noiseService.getSigningPublicKeyData()  // For signature verification
        
        let announcement = AnnouncementPacket(
            nickname: myNickname,
            noisePublicKey: noisePub,
            signingPublicKey: signingPub,
            sessionID: sessionID
        )
        
        guard let payload = announcement.encode() else {
            SecureLogger.log("❌ Failed to encode announce packet", category: SecureLogger.session, level: .error)
            return
        }
        
        // Create packet with signature using the noise private key
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: myPeerIDData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil, // Will be set by signPacket below
            ttl: messageTTL
        )
        
        // Sign the packet using the noise private key
        guard let signedPacket = noiseService.signPacket(packet) else {
            SecureLogger.log("❌ Failed to sign announce packet", category: SecureLogger.security, level: .error)
            return
        }
        
        // Call directly if on messageQueue, otherwise dispatch
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            broadcastPacket(signedPacket)
        } else {
            messageQueue.async { [weak self] in
                self?.broadcastPacket(signedPacket)
            }
        }
    }
    
    func sendDeliveryAck(for messageID: String, to peerID: String) {
        // Create typed payload: [type byte] + [message ID]
        var payload = Data([NoisePayloadType.delivered.rawValue])
        payload.append(contentsOf: messageID.utf8)

        if sendNoisePayload(payload, to: peerID, queueIfNeeded: true) {
            return
        } else {
            SecureLogger.log("🕒 Queued DELIVERED ack for \(peerID) until handshake completes", 
                            category: SecureLogger.session, level: .debug)
        }
    }

    private func sendPendingNoisePayloadsAfterHandshake(for peerID: String) {
        let payloads = collectionsQueue.sync(flags: .barrier) { () -> [Data] in
            let list = pendingNoisePayloadsAfterHandshake[peerID] ?? []
            pendingNoisePayloadsAfterHandshake.removeValue(forKey: peerID)
            return list
        }
        guard !payloads.isEmpty else { return }
        SecureLogger.log("📤 Sending \(payloads.count) pending noise payloads to \(peerID) after handshake",
                        category: SecureLogger.session, level: .debug)
        for payload in payloads {
            do {
                let encrypted = try noiseService.encrypt(payload, for: peerID)
                let packet = BitchatPacket(
                    type: MessageType.noiseEncrypted.rawValue,
                    senderID: myPeerIDData,
                    recipientID: Data(hexString: peerID),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: encrypted,
                    signature: nil,
                    ttl: messageTTL
                )
                broadcastPacket(packet)
            } catch {
                SecureLogger.log("❌ Failed to send pending noise payload to \(peerID): \(error)", 
                                category: SecureLogger.noise, level: .error)
            }
        }
    }
    
    private func updatePeerLastSeen(_ peerID: String) {
        // Use async to avoid deadlock - we don't need immediate consistency for last seen updates
        collectionsQueue.async(flags: .barrier) {
            if var peer = self.peers[peerID] {
                peer.lastSeen = Date()
                self.peers[peerID] = peer
            }
        }
    }

    // Debounced disconnect notifier to avoid duplicate disconnect callbacks within a short window
    private func notifyPeerDisconnectedDebounced(_ peerID: String) {
        let now = Date()
        let last = recentDisconnectNotifies[peerID]
        if last == nil || now.timeIntervalSince(last!) >= TransportConfig.bleDisconnectNotifyDebounceSeconds {
            delegate?.didDisconnectFromPeer(peerID)
            recentDisconnectNotifies[peerID] = now
        } else {
            // Suppressed duplicate disconnect notification
        }
    }
    
    // NEW: Publish peer snapshots to subscribers and notify Transport delegates
    private func publishFullPeerData() {
        let transportPeers: [TransportPeerSnapshot] = collectionsQueue.sync {
            // Compute nickname collision counts for connected peers
            let connected = peers.values.filter { $0.isConnected }
            var counts: [String: Int] = [:]
            for p in connected { counts[p.nickname, default: 0] += 1 }
            counts[myNickname, default: 0] += 1
            return peers.values.map { info in
                var display = info.nickname
                if info.isConnected, (counts[info.nickname] ?? 0) > 1 {
                    display += "#" + String(info.id.prefix(4))
                }
                return TransportPeerSnapshot(
                    id: info.id,
                    nickname: display,
                    isConnected: info.isConnected,
                    noisePublicKey: info.noisePublicKey,
                    lastSeen: info.lastSeen
                )
            }
        }
        // Notify non-UI listeners
        peerSnapshotSubject.send(transportPeers)
        // Notify UI on MainActor via delegate
        Task { @MainActor [weak self] in
            self?.peerEventsDelegate?.didUpdatePeerSnapshots(transportPeers)
        }
    }

    // Debounced publish to coalesce rapid changes
    private var lastPeerPublishAt: Date = .distantPast
    private var peerPublishPending: Bool = false
    private let peerPublishMinInterval: TimeInterval = 0.1
    private func requestPeerDataPublish() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPeerPublishAt)
        if elapsed >= peerPublishMinInterval {
            lastPeerPublishAt = now
            publishFullPeerData()
        } else if !peerPublishPending {
            peerPublishPending = true
            let delay = peerPublishMinInterval - elapsed
            messageQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.lastPeerPublishAt = Date()
                self.peerPublishPending = false
                self.publishFullPeerData()
            }
        }
    }
    
    // MARK: - Consolidated Maintenance
    
    private func performMaintenance() {
        guard isAppActive else { return }
        maintenanceCounter += 1
        
        // Adaptive announce: reduce frequency when we have connected peers
        let now = Date()
        let connectedCount = collectionsQueue.sync { peers.values.filter { $0.isConnected }.count }
        let elapsed = now.timeIntervalSince(lastAnnounceSent)
        if connectedCount == 0 {
            // Discovery mode: keep frequent announces
            if elapsed >= TransportConfig.bleAnnounceIntervalSeconds { sendAnnounce(forceSend: true) }
        } else {
            // Connected mode: announce less often; much less in dense networks
            let base = connectedCount >= TransportConfig.bleHighDegreeThreshold ?
                TransportConfig.bleConnectedAnnounceBaseSecondsDense : TransportConfig.bleConnectedAnnounceBaseSecondsSparse
            let jitter = connectedCount >= TransportConfig.bleHighDegreeThreshold ?
                TransportConfig.bleConnectedAnnounceJitterDense : TransportConfig.bleConnectedAnnounceJitterSparse
            let target = base + Double.random(in: -jitter...jitter)
            if elapsed >= target { sendAnnounce(forceSend: true) }
        }

        // Activity-driven quick-announce: if we've seen any packet in last 5s and it has
        // been >=10s since the last announce, send a presence nudge.
        let recentSeen = collectionsQueue.sync { () -> Bool in
            let cutoff = now.addingTimeInterval(-5.0)
            return recentPacketTimestamps.contains(where: { $0 >= cutoff })
        }
        if recentSeen && elapsed >= 10.0 {
            sendAnnounce(forceSend: true)
        }
        
        // If we have no peers, ensure we're scanning and advertising
        if peers.isEmpty {
            // Ensure we're advertising as peripheral
            if let pm = peripheralManager, pm.state == .poweredOn && !pm.isAdvertising {
                pm.startAdvertising(buildAdvertisementData())
            }
        }
        
        // Update scanning duty-cycle based on connectivity
        updateScanningDutyCycle(connectedCount: connectedCount)
        updateRSSIThreshold(connectedCount: connectedCount)
        
        // Check peer connectivity every cycle for snappier UI updates
        checkPeerConnectivity()
        
        // Every 30 seconds (3 cycles): Cleanup
        if maintenanceCounter % 3 == 0 {
            performCleanup()
        }

        // Attempt to flush any spooled directed messages periodically (~every 5 seconds)
        if maintenanceCounter % 2 == 1 {
            flushDirectedSpool()
        }

        // Backup drain in case CoreBluetooth readiness callbacks are delayed.
        drainPendingWritesIfNeeded()
        
        // No rotating alias: nothing to refresh
        
        // Reset counter to prevent overflow (every 60 seconds)
        if maintenanceCounter >= 6 {
            maintenanceCounter = 0
        }
    }

    private func drainPendingWritesIfNeeded() {
        let hasPendingWrites = collectionsQueue.sync { !pendingPeripheralWrites.isEmpty }
        guard hasPendingWrites else { return }
        drainAllPendingWrites()
    }
    
    private func checkPeerConnectivity() {
        let now = Date()
        let liveLinks = directlyConnectedPeerIDs()
        var disconnectedPeers: [String] = []
        
        var removedOfflineCount = 0
        collectionsQueue.sync(flags: .barrier) {
            for (peerID, peer) in peers {
                let age = now.timeIntervalSince(peer.lastSeen)
                let retention: TimeInterval = peer.isVerifiedNickname ? TransportConfig.bleReachabilityRetentionVerifiedSeconds : TransportConfig.bleReachabilityRetentionUnverifiedSeconds
                if peer.isConnected && age > TransportConfig.blePeerInactivityTimeoutSeconds {
                    // Check if we still have an active BLE connection to this peer
                    // A receive-only background peer can be silent while its link stays healthy.
                    if !liveLinks.contains(peerID) {
                        var updated = peer
                        updated.isConnected = false
                        peers[peerID] = updated
                        disconnectedPeers.append(peerID)
                    }
                }
                // Cleanup: remove peers that are not connected and past reachability retention
                if peers[peerID]?.isConnected == false {
                    if age > retention {
                        SecureLogger.log("🗑️ Removing stale peer after reachability window: \(peerID) (\(peer.nickname))",
                                         category: SecureLogger.session, level: .debug)
                        peers.removeValue(forKey: peerID)
                        announcementsByPeer.removeValue(forKey: peerID)
                        removedOfflineCount += 1
                    }
                }
            }
        }
        
        // Update UI if there were direct disconnections or offline removals
        if !disconnectedPeers.isEmpty || removedOfflineCount > 0 {
            Task { @MainActor in
                
                // Get current peer list (after removal)
                let currentPeerIDs = self.collectionsQueue.sync { self.peers.keys }
                
                for peerID in disconnectedPeers {
                    self.delegate?.didDisconnectFromPeer(peerID)
                }
                // Publish snapshots so UnifiedPeerService updates connection/reachability icons
                self.requestPeerDataPublish()
                self.delegate?.didUpdatePeerList(currentPeerIDs)
            }
        }
    }
    
    private func performCleanup() {
        let now = Date()
        
        // Clean old processed messages efficiently
        messageDeduplicator.cleanup()
        
        // Clean old fragments (> configured seconds old)
        collectionsQueue.sync(flags: .barrier) {
            let cutoff = now.addingTimeInterval(-TransportConfig.bleFragmentLifetimeSeconds)
            let oldFragments = fragmentMetadata.filter { $0.value.timestamp < cutoff }.map { $0.key }
            for fragmentID in oldFragments {
                incomingFragments.removeValue(forKey: fragmentID)
                fragmentMetadata.removeValue(forKey: fragmentID)
            }
        }

        // Clean old connection timeout backoff entries (> window)
        let timeoutCutoff = now.addingTimeInterval(-TransportConfig.bleConnectTimeoutBackoffWindowSeconds)
        recentConnectTimeouts = recentConnectTimeouts.filter { $0.value >= timeoutCutoff }

        // Clean up stale scheduled relays that somehow persisted (> 2s)
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if !self.scheduledRelays.isEmpty {
                // Nothing to compare times to; just cap the size defensively
                if self.scheduledRelays.count > 512 {
                    self.scheduledRelays.removeAll()
                }
            }
        }

        // Clean ingress link records older than configured seconds
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let cutoff = now.addingTimeInterval(-TransportConfig.bleIngressRecordLifetimeSeconds)
            if !self.ingressByMessageID.isEmpty {
                self.ingressByMessageID = self.ingressByMessageID.filter { $0.value.timestamp >= cutoff }
            }
            // Clean expired directed spooled items
            if !self.pendingDirectedRelays.isEmpty {
                var cleaned: [String: [String: (packet: BitchatPacket, enqueuedAt: Date)]] = [:]
                for (recipient, dict) in self.pendingDirectedRelays {
                    let pruned = dict.filter { now.timeIntervalSince($0.value.enqueuedAt) <= TransportConfig.bleDirectedSpoolWindowSeconds }
                    if !pruned.isEmpty { cleaned[recipient] = pruned }
                }
                self.pendingDirectedRelays = cleaned
            }
        }
    }

    private func updateScanningDutyCycle(connectedCount: Int) {
        guard let central = centralManager, central.state == .poweredOn else { return }
        // Duty cycle only when app is active and at least one peer connected
        #if os(iOS)
        let active = isAppActive
        #else
        let active = true
        #endif
        // Force full-time scanning if we have very few neighbors or very recent traffic
        let hasRecentTraffic: Bool = collectionsQueue.sync {
            let cutoff = Date().addingTimeInterval(-TransportConfig.bleRecentTrafficForceScanSeconds)
            return recentPacketTimestamps.contains(where: { $0 >= cutoff })
        }
        let forceScanOn = (connectedCount <= 2) || hasRecentTraffic
        let shouldDuty = dutyEnabled && active && connectedCount > 0 && !forceScanOn
        if shouldDuty {
            if scanDutyTimer == nil {
                // Start timer to toggle scanning on/off
                let t = DispatchSource.makeTimerSource(queue: bleQueue)
                // Start with scanning ON; we'll turn OFF after onDuration
                if !central.isScanning { startScanning() }
                dutyActive = true
                // Adjust duty cycle under dense networks to save battery
                if connectedCount >= TransportConfig.bleHighDegreeThreshold {
                    dutyOnDuration = TransportConfig.bleDutyOnDurationDense
                    dutyOffDuration = TransportConfig.bleDutyOffDurationDense
                } else {
                    dutyOnDuration = TransportConfig.bleDutyOnDuration
                    dutyOffDuration = TransportConfig.bleDutyOffDuration
                }
                t.schedule(deadline: .now() + dutyOnDuration, repeating: dutyOnDuration + dutyOffDuration)
                t.setEventHandler { [weak self] in
                    guard let self = self, let c = self.centralManager else { return }
                    if self.dutyActive {
                        // Turn OFF scanning for offDuration
                        if c.isScanning { c.stopScan() }
                        self.dutyActive = false
                        // Schedule turning back ON after offDuration
                        self.bleQueue.asyncAfter(deadline: .now() + self.dutyOffDuration) {
                            if self.centralManager?.state == .poweredOn { self.startScanning() }
                            self.dutyActive = true
                        }
                    }
                }
                t.resume()
                scanDutyTimer = t
            }
        } else {
            // Cancel duty cycle and ensure scanning is ON for discovery
            scanDutyTimer?.cancel()
            scanDutyTimer = nil
            if !central.isScanning { startScanning() }
        }
    }

    private func updateRSSIThreshold(connectedCount: Int) {
        // Adjust RSSI threshold based on connectivity, candidate pressure, and failures
        if connectedCount == 0 {
            // Isolated: relax floor slowly to hunt for distant nodes
            if lastIsolatedAt == nil { lastIsolatedAt = Date() }
            let iso = lastIsolatedAt ?? Date()
            let elapsed = Date().timeIntervalSince(iso)
            if elapsed > TransportConfig.bleIsolationRelaxThresholdSeconds {
                dynamicRSSIThreshold = TransportConfig.bleRSSIIsolatedRelaxed
            } else {
                dynamicRSSIThreshold = TransportConfig.bleRSSIIsolatedBase
            }
            return
        }
        lastIsolatedAt = nil
        // Base threshold when connected
        var threshold = TransportConfig.bleDynamicRSSIThresholdDefault
        // If we're at budget or queue is large, prefer closer peers
        let linkCount = peripherals.values.filter { $0.isConnected || $0.isConnecting }.count
        if linkCount >= maxCentralLinks || connectionCandidates.count > TransportConfig.bleConnectionCandidatesMax {
            threshold = TransportConfig.bleRSSIConnectedThreshold
        }
        // If we have many recent timeouts, raise further
        let recentTimeouts = recentConnectTimeouts.filter { Date().timeIntervalSince($0.value) < TransportConfig.bleRecentTimeoutWindowSeconds }.count
        if recentTimeouts >= TransportConfig.bleRecentTimeoutCountThreshold {
            threshold = max(threshold, TransportConfig.bleRSSIHighTimeoutThreshold)
        }
        dynamicRSSIThreshold = threshold
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === centralManager else { return }
        bluetoothState = central.state
        delegate?.updateBluetoothState(bluetoothState)
        
        if bluetoothState == .poweredOn {
            // Start scanning - use allow duplicates for faster discovery when active
            startScanning()
        }
    }
    
    private func startScanning() {
        guard isAppActive else { return }
        guard let central = centralManager,
              central.state == .poweredOn,
              !central.isScanning else { return }
        
        // Use allow duplicates = true for faster discovery in foreground
        // This gives us discovery events immediately instead of coalesced
        #if os(iOS)
        let allowDuplicates = isAppActive  // Use our tracked state (thread-safe)
        #else
        let allowDuplicates = true  // macOS doesn't have background restrictions
        #endif
        
        central.scanForPeripherals(
                withServices: [BLEService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
        
        // Started BLE scanning
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === centralManager else { return }
        guard isAppActive else { return }
        let peripheralID = peripheral.identifier.uuidString
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? (peripheralID.prefix(6) + "…")
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let rssiValue = RSSI.intValue
        
        // Skip if peripheral is not connectable (per advertisement data)
        guard isConnectable else { return }

        // Skip immediate connect if signal too weak for current conditions; enqueue instead
        if rssiValue <= dynamicRSSIThreshold {
            connectionCandidates.append(ConnectionCandidate(peripheral: peripheral, rssi: rssiValue, name: String(advertisedName), isConnectable: isConnectable, discoveredAt: Date()))
            // Keep list tidy
            connectionCandidates.sort { (a, b) in
                if a.rssi != b.rssi { return a.rssi > b.rssi }
                return a.discoveredAt < b.discoveredAt
            }
            if connectionCandidates.count > TransportConfig.bleConnectionCandidatesMax {
                connectionCandidates.removeLast(connectionCandidates.count - TransportConfig.bleConnectionCandidatesMax)
            }
            return
        }
        
        // Budget: limit simultaneous central links (connected + connecting)
        let currentCentralLinks = peripherals.values.filter { $0.isConnected || $0.isConnecting }.count
        if currentCentralLinks >= maxCentralLinks {
            // Enqueue as candidate; we'll attempt later as slots open
            connectionCandidates.append(ConnectionCandidate(peripheral: peripheral, rssi: rssiValue, name: String(advertisedName), isConnectable: isConnectable, discoveredAt: Date()))
            // Keep candidate list tidy: prefer stronger RSSI, then recency; cap list
            connectionCandidates.sort { (a, b) in
                if a.rssi != b.rssi { return a.rssi > b.rssi }
                return a.discoveredAt < b.discoveredAt
            }
            if connectionCandidates.count > TransportConfig.bleConnectionCandidatesMax {
                connectionCandidates.removeLast(connectionCandidates.count - TransportConfig.bleConnectionCandidatesMax)
            }
            return
        }

        // Rate limit global connect attempts
        let sinceLast = Date().timeIntervalSince(lastGlobalConnectAttempt)
        if sinceLast < connectRateLimitInterval {
            connectionCandidates.append(ConnectionCandidate(peripheral: peripheral, rssi: rssiValue, name: String(advertisedName), isConnectable: isConnectable, discoveredAt: Date()))
            connectionCandidates.sort { (a, b) in
                if a.rssi != b.rssi { return a.rssi > b.rssi }
                return a.discoveredAt < b.discoveredAt
            }
            // Schedule a deferred attempt after rate-limit interval
            let delay = connectRateLimitInterval - sinceLast + 0.05
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tryConnectFromQueue()
            }
            return
        }

        // Check if we already have this peripheral
        if let state = peripherals[peripheralID] {
            if state.isConnected || state.isConnecting {
                return // Already connected or connecting
            }
            
        // Add backoff for reconnection attempts
        if let lastAttempt = state.lastConnectionAttempt {
            let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
            if timeSinceLastAttempt < 2.0 {
                return // Wait at least 2 seconds between connection attempts
            }
        }
        }
        
        // Backoff if this peripheral recently timed out connection within the last 15 seconds
        if let lastTimeout = recentConnectTimeouts[peripheralID], Date().timeIntervalSince(lastTimeout) < 15 {
            return
        }

        // Check peripheral state - but cancel if stale
        if peripheral.state == .connecting || peripheral.state == .connected {
            // iOS might have stale state - force disconnect and retry
            central.cancelPeripheralConnection(peripheral)
            // Will retry on next discovery
            return
        }
        
        // Only log when we're actually attempting connection
        // Discovered BLE peripheral
        
        // Store the peripheral and mark as connecting
        peripherals[peripheralID] = PeripheralState(
            peripheral: peripheral,
            characteristic: nil,
            peerID: nil,
            isConnecting: true,
            isConnected: false,
            lastConnectionAttempt: Date()
        )
        peripheral.delegate = self
        
        // Connect to the peripheral with options for faster connection
        SecureLogger.log("📱 Connect: \(advertisedName) [RSSI:\(rssiValue)]",
                        category: SecureLogger.session, level: .debug)
        
        // Use connection options for faster reconnection
        let options: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ]
        central.connect(peripheral, options: options)
        lastGlobalConnectAttempt = Date()
        
        // Set a timeout for the connection attempt (slightly longer for reliability)
        // Use BLE queue to mutate BLE-related state consistently
        bleQueue.asyncAfter(deadline: .now() + TransportConfig.bleConnectTimeoutSeconds) { [weak self] in
            guard let self = self,
                  let state = self.peripherals[peripheralID],
                  state.isConnecting && !state.isConnected else { return }
            
            // Connection timed out - cancel it
            SecureLogger.log("⏱️ Timeout: \(advertisedName)",
                            category: SecureLogger.session, level: .debug)
        central.cancelPeripheralConnection(peripheral)
        self.peripherals[peripheralID] = nil
        self.recentConnectTimeouts[peripheralID] = Date()
        self.failureCounts[peripheralID, default: 0] += 1
        // Try next candidate if any
        self.tryConnectFromQueue()
        }
    }
    
func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === centralManager else { return }
        guard isAppActive else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        let peripheralID = peripheral.identifier.uuidString
        
        // Update state to connected
        if var state = peripherals[peripheralID] {
            state.isConnecting = false
            state.isConnected = true
            peripherals[peripheralID] = state
        } else {
            // Create new state if not found
            peripherals[peripheralID] = PeripheralState(
                peripheral: peripheral,
                characteristic: nil,
                peerID: nil,
                isConnecting: false,
                isConnected: true
            )
        }
        
        // Reset backoff state on success
        failureCounts[peripheralID] = 0
        recentConnectTimeouts.removeValue(forKey: peripheralID)

        SecureLogger.log("✅ Connected: \(peripheral.name ?? "Unknown") [\(peripheralID)]", category: SecureLogger.session, level: .debug)
        
        // Discover services
        peripheral.discoverServices([BLEService.serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard central === centralManager else { return }
        let peripheralID = peripheral.identifier.uuidString
        
        // Find the peer ID if we have it
        let peerID = peripherals[peripheralID]?.peerID
        
        SecureLogger.log("📱 Disconnect: \(peerID ?? peripheralID)\(error != nil ? " (\(error!.localizedDescription))" : "")",
                        category: SecureLogger.session, level: .debug)

        // If disconnect carried an error (often timeout), apply short backoff to avoid thrash
        if error != nil {
            recentConnectTimeouts[peripheralID] = Date()
        }
        
        // Clean up references
        peripherals.removeValue(forKey: peripheralID)
        
        if let peerID {
            if peerToPeripheralUUID[peerID] == peripheralID {
                peerToPeripheralUUID.removeValue(forKey: peerID)
            }
            retireUnlinkedPeer(peerID)
        }

        // Restart scanning with allow duplicates for faster rediscovery
        if centralManager?.state == .poweredOn {
            // Stop and restart scanning to ensure we get fresh discovery events
            centralManager?.stopScan()
            bleQueue.asyncAfter(deadline: .now() + TransportConfig.bleRestartScanDelaySeconds) { [weak self] in
                self?.startScanning()
            }
        }
        // Attempt to fill freed slot from queue
        bleQueue.async { [weak self] in self?.tryConnectFromQueue() }
        
        // Notify delegate about disconnection on main thread (direct link dropped)
        Task { @MainActor in
            // Get current peer list (after removal)
            let currentPeerIDs = self.collectionsQueue.sync { self.peers.keys }
            
            if let peerID, !self.directlyConnectedPeerIDs().contains(peerID) {
                self.notifyPeerDisconnectedDebounced(peerID)
            }
            self.requestPeerDataPublish()
            self.delegate?.didUpdatePeerList(currentPeerIDs)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard central === centralManager else { return }
        let peripheralID = peripheral.identifier.uuidString
        
        // Clean up the references
        peripherals.removeValue(forKey: peripheralID)
        
        SecureLogger.log("❌ Failed to connect to peripheral: \(peripheral.name ?? "Unknown") [\(peripheralID)] - Error: \(error?.localizedDescription ?? "Unknown")", category: SecureLogger.session, level: .error)
        failureCounts[peripheralID, default: 0] += 1
        // Try next candidate
        bleQueue.async { [weak self] in self?.tryConnectFromQueue() }
    }
}

// MARK: - Connection scheduling helpers
extension BLEService {
    private func tryConnectFromQueue() {
        guard isAppActive else { return }
        guard let central = centralManager, central.state == .poweredOn else { return }
        // Check budget and rate limit
        let current = peripherals.values.filter { $0.isConnected || $0.isConnecting }.count
        guard current < maxCentralLinks else { return }
        let delta = Date().timeIntervalSince(lastGlobalConnectAttempt)
        guard delta >= connectRateLimitInterval else {
            let delay = connectRateLimitInterval - delta + 0.05
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tryConnectFromQueue() }
            return
        }
        // Pull best candidate by composite score
        guard !connectionCandidates.isEmpty else { return }
        // compute score: connectable> RSSI > recency, with backoff penalty
        func score(_ c: ConnectionCandidate) -> Int {
            let uuid = c.peripheral.identifier.uuidString
            // Penalty if recently timed out (exponential)
            let fails = failureCounts[uuid] ?? 0
            let penalty = min(20, (1 << min(4, fails))) // 1,2,4,8,16 cap 16-20
            let timeoutRecent = recentConnectTimeouts[uuid]
            let timeoutBias = (timeoutRecent != nil && Date().timeIntervalSince(timeoutRecent!) < 60) ? 10 : 0
            let base = (c.isConnectable ? 1000 : 0) + (c.rssi + 100) * 2
            let rec = -Int(Date().timeIntervalSince(c.discoveredAt) * 10)
            return base + rec - penalty - timeoutBias
        }
        connectionCandidates.sort { score($0) > score($1) }
        let candidate = connectionCandidates.removeFirst()
        guard candidate.isConnectable else { return }
        let peripheral = candidate.peripheral
        let peripheralID = peripheral.identifier.uuidString
        // Weak-link cooldown: if we recently timed out and RSSI is very weak, delay retries
        if let lastTO = recentConnectTimeouts[peripheralID] {
            let elapsed = Date().timeIntervalSince(lastTO)
            if elapsed < TransportConfig.bleWeakLinkCooldownSeconds && candidate.rssi <= TransportConfig.bleWeakLinkRSSICutoff {
                // Requeue the candidate and try again later
                connectionCandidates.append(candidate)
                let remaining = TransportConfig.bleWeakLinkCooldownSeconds - elapsed
                let delay = min(max(2.0, remaining), 15.0)
                bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tryConnectFromQueue() }
                return
            }
        }
        if peripherals[peripheralID]?.isConnected == true || peripherals[peripheralID]?.isConnecting == true {
            // Already in progress; skip
            bleQueue.async { [weak self] in self?.tryConnectFromQueue() }
            return
        }
        // Initiate connection
        peripherals[peripheralID] = PeripheralState(
            peripheral: peripheral,
            characteristic: nil,
            peerID: nil,
            isConnecting: true,
            isConnected: false,
            lastConnectionAttempt: Date()
        )
        peripheral.delegate = self
        let options: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: false,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: false,
            CBConnectPeripheralOptionNotifyOnNotificationKey: false
        ]
        central.connect(peripheral, options: options)
        lastGlobalConnectAttempt = Date()
        SecureLogger.log("⏩ Queue connect: \(candidate.name) [RSSI:\(candidate.rssi)]", category: SecureLogger.session, level: .debug)
    }
}

#if DEBUG
// Test-only helper to inject packets into the receive pipeline
extension BLEService {
    func _test_handlePacket(_ packet: BitchatPacket, fromPeerID: String) {
        // Ensure the synthetic peer is known and marked verified for public-message tests
        let normalizedID = packet.senderID.hexEncodedString()
        collectionsQueue.sync(flags: .barrier) {
            if peers[normalizedID] == nil {
                peers[normalizedID] = PeerInfo(
                    id: normalizedID,
                    nickname: "TestPeer_\(fromPeerID.prefix(4))",
                    isConnected: true,
                    noisePublicKey: packet.senderID,
                    signingPublicKey: nil,
                    isVerifiedNickname: true,
                    lastSeen: Date()
                )
            } else {
                var p = peers[normalizedID]!
                p.isConnected = true
                p.isVerifiedNickname = true
                p.lastSeen = Date()
                peers[normalizedID] = p
            }
        }
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            handleReceivedPacket(packet, from: fromPeerID)
        } else {
            messageQueue.async { [weak self] in
                self?.handleReceivedPacket(packet, from: fromPeerID)
            }
        }
    }
}
#endif

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error = error {
            SecureLogger.log("❌ Error discovering services for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            // Retry service discovery after a delay
            bleQueue.asyncAfter(deadline: .now() + 0.5) {
                guard peripheral.state == .connected else { return }
                peripheral.discoverServices([BLEService.serviceUUID])
            }
            return
        }
        
        guard let services = peripheral.services else {
            SecureLogger.log("⚠️ No services discovered for \(peripheral.name ?? "Unknown")", category: SecureLogger.session, level: .warning)
            return
        }
        
        guard let service = services.first(where: { $0.uuid == BLEService.serviceUUID }) else {
            // Not a BitChat peer - disconnect
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        
        // Discovering BLE characteristics
        peripheral.discoverCharacteristics([BLEService.characteristicUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error = error {
            SecureLogger.log("❌ Error discovering characteristics for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            return
        }
        
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == BLEService.characteristicUUID }) else {
            SecureLogger.log("⚠️ No matching characteristic found for \(peripheral.name ?? "Unknown")", category: SecureLogger.session, level: .warning)
            return
        }
        
        // Found characteristic
        
        // Log characteristic properties for debugging
        var properties: [String] = []
        if characteristic.properties.contains(.read) { properties.append("read") }
        if characteristic.properties.contains(.write) { properties.append("write") }
        if characteristic.properties.contains(.writeWithoutResponse) { properties.append("writeWithoutResponse") }
        if characteristic.properties.contains(.notify) { properties.append("notify") }
        if characteristic.properties.contains(.indicate) { properties.append("indicate") }
        // Characteristic properties: \(properties.joined(separator: ", "))
        
        // Verify characteristic supports reliable writes
        if !characteristic.properties.contains(.write) {
            SecureLogger.log("⚠️ Characteristic doesn't support reliable writes (withResponse)!", category: SecureLogger.session, level: .warning)
        }
        
        // Store characteristic in our consolidated structure
        let peripheralID = peripheral.identifier.uuidString
        if var state = peripherals[peripheralID] {
            state.characteristic = characteristic
            peripherals[peripheralID] = state
        }
        
        // Subscribe for notifications
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
            SecureLogger.log("🔔 Subscribed to notifications from \(peripheral.name ?? "Unknown")", category: SecureLogger.session, level: .debug)
            
            // Send announce after subscription is confirmed (force send for new connection)
            messageQueue.asyncAfter(deadline: .now() + TransportConfig.blePostSubscribeAnnounceDelaySeconds) { [weak self] in
                self?.sendAnnounce(forceSend: true)
                // Try flushing any spooled directed packets now that we have a link
                self?.flushDirectedSpool()
            }
        } else {
            SecureLogger.log("⚠️ Characteristic does not support notifications", category: SecureLogger.session, level: .warning)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error = error {
            SecureLogger.log("❌ Error receiving notification: \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            return
        }
        
        guard let data = characteristic.value else {
            SecureLogger.log("⚠️ No data in notification", category: SecureLogger.session, level: .warning)
            return
        }
        
        // Received BLE notification
        
        // Process directly on main thread to avoid deadlocks (matches original implementation)
        guard let packet = BinaryProtocol.decode(data) else {
            // Avoid dumping entire payload; log size and short prefix for diagnostics
            let prefix = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            SecureLogger.log("❌ Failed to decode notification packet (len=\(data.count), prefix=\(prefix))",
                            category: SecureLogger.session, level: .error)
            return
        }
        
        // Use the packet's senderID as the peer identifier
        let senderID = packet.senderID.hexEncodedString()
        // Only log non-announce packets
    if packet.type != MessageType.announce.rawValue {
        SecureLogger.log("📦 Decoded notification packet type: \(packet.type) from sender: \(senderID)", category: SecureLogger.session, level: .debug)
    }
        
        let peripheralUUID = peripheral.identifier.uuidString
        
        // Update mapping ONLY for announce packets that come directly from the peer (not relayed)
        if packet.type == MessageType.announce.rawValue {
            // Only update mapping if this is a direct announce (TTL == messageTTL means not relayed)
            guard isValidLiveAnnouncement(packet) else { return }
            if packet.ttl == messageTTL {
                let previousIDs = peerToPeripheralUUID.filter { $0.value == peripheralUUID && $0.key != senderID }.map(\.key)
                for previousID in previousIDs { peerToPeripheralUUID.removeValue(forKey: previousID) }
                if var state = peripherals[peripheralUUID] {
                    state.peerID = senderID
                    peripherals[peripheralUUID] = state
                }
                peerToPeripheralUUID[senderID] = peripheralUUID
                for previousID in previousIDs { retireUnlinkedPeer(previousID) }
            }
            // Record ingress link for last-hop suppression and process
            let msgID = makeMessageID(for: packet)
            collectionsQueue.async(flags: .barrier) { [weak self] in
                self?.ingressByMessageID[msgID] = (.peripheral(peripheralUUID), Date())
            }
            // Process the announce packet regardless of whether we updated the mapping
            handleReceivedPacket(packet, from: senderID)
        } else {
            // For non-announce packets, DO NOT update mappings
            // These could be relayed packets from other peers
            // Always use the packet's original senderID
            // Record ingress link for last-hop suppression and process
            let msgID = makeMessageID(for: packet)
            collectionsQueue.async(flags: .barrier) { [weak self] in
                self?.ingressByMessageID[msgID] = (.peripheral(peripheralUUID), Date())
            }
            handleReceivedPacket(packet, from: senderID)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error = error {
            SecureLogger.log("❌ Write failed to \(peripheral.name ?? peripheral.identifier.uuidString): \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            // Don't retry - just log the error
        } else {
            SecureLogger.log("✅ Write confirmed to \(peripheral.name ?? peripheral.identifier.uuidString)", category: SecureLogger.session, level: .debug)
        }
    }
    
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Resume queued writes for this peripheral
        drainPendingWrites(for: peripheral)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        SecureLogger.log("⚠️ Services modified for \(peripheral.name ?? peripheral.identifier.uuidString)", category: SecureLogger.session, level: .warning)
        
        // Check if our service was invalidated (peer app quit)
        let hasOurService = peripheral.services?.contains { $0.uuid == BLEService.serviceUUID } ?? false
        
        if !hasOurService {
            // Service is gone - disconnect
            SecureLogger.log("❌ BitChat service removed - disconnecting from \(peripheral.name ?? peripheral.identifier.uuidString)", category: SecureLogger.session, level: .warning)
            centralManager?.cancelPeripheralConnection(peripheral)
        } else {
            // Try to rediscover
            peripheral.discoverServices([BLEService.serviceUUID])
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error = error {
            SecureLogger.log("❌ Error updating notification state: \(error.localizedDescription)", category: SecureLogger.session, level: .error)
        } else {
            SecureLogger.log("🔔 Notification state updated for \(peripheral.name ?? peripheral.identifier.uuidString): \(characteristic.isNotifying ? "ON" : "OFF")", category: SecureLogger.session, level: .debug)
            
            // If notifications are now on, send an announce to ensure this peer knows about us
            if characteristic.isNotifying {
                // Sending announce after subscription
                self.sendAnnounce(forceSend: true)
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === peripheralManager else { return }
        SecureLogger.log("📡 Peripheral manager state: \(peripheral.state.rawValue)", category: SecureLogger.session, level: .debug)
        
        if peripheral.state == .poweredOn {
            // Remove all services first to ensure clean state
            peripheral.removeAllServices()
            
            // Create characteristic
            characteristic = CBMutableCharacteristic(
                type: BLEService.characteristicUUID,
                properties: [.notify, .write, .writeWithoutResponse, .read],
                value: nil,
                permissions: [.readable, .writeable]
            )
            
            // Create service
            let service = CBMutableService(type: BLEService.serviceUUID, primary: true)
            service.characteristics = [characteristic!]
            
            // Add service (advertising will start in didAdd delegate)
            SecureLogger.log("🔧 Adding BLE service...", category: SecureLogger.session, level: .debug)
            peripheral.add(service)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        guard peripheral === peripheralManager else { return }
        if let error = error {
            SecureLogger.log("❌ Failed to add service: \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            return
        }
        
        SecureLogger.log("✅ Service added successfully, starting advertising", category: SecureLogger.session, level: .debug)
        
        // Start advertising after service is confirmed added
        let adData = buildAdvertisementData()
        if isAppActive { peripheral.startAdvertising(adData) }
        
        SecureLogger.log("📡 Started advertising (LocalName: \((adData[CBAdvertisementDataLocalNameKey] as? String) != nil ? "on" : "off"), ID: \(myPeerID.prefix(8))…)", category: SecureLogger.session, level: .debug)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        SecureLogger.log("📥 Central subscribed: \(central.identifier.uuidString)", category: SecureLogger.session, level: .debug)
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        subscribedCentrals.append(central)
        // Send announce to the newly subscribed central after a small delay to avoid overwhelming
        messageQueue.asyncAfter(deadline: .now() + TransportConfig.blePostAnnounceDelaySeconds) { [weak self] in
            self?.sendAnnounce(forceSend: true)
            // Flush any spooled directed packets now that we have a central subscribed
            self?.flushDirectedSpool()
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        SecureLogger.log("📤 Central unsubscribed: \(central.identifier.uuidString)", category: SecureLogger.session, level: .debug)
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        
        // Ensure we're still advertising for other devices to find us
        if isAppActive, peripheral.isAdvertising == false {
            SecureLogger.log("📡 Restarting advertising after central unsubscribed", category: SecureLogger.session, level: .debug)
            peripheral.startAdvertising(buildAdvertisementData())
        }
        
        // Find and disconnect the peer associated with this central
        let centralUUID = central.identifier.uuidString
        if let peerID = centralToPeerID[centralUUID] {
            centralToPeerID.removeValue(forKey: centralUUID)
            retireUnlinkedPeer(peerID)

            // Update UI immediately
            Task { @MainActor in
                // Get current peer list (after removal)
                let currentPeerIDs = self.collectionsQueue.sync { self.peers.keys }
                
                if !self.directlyConnectedPeerIDs().contains(peerID) {
                    self.notifyPeerDisconnectedDebounced(peerID)
                }
                // Publish snapshots so UnifiedPeerService can refresh icons promptly
                self.requestPeerDataPublish()
                self.delegate?.didUpdatePeerList(currentPeerIDs)
            }
        }
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard isAppActive else { return }
        guard let characteristic else { return }
        var sentCount = 0
        for notification in pendingNotifications {
            let targets = notification.centrals.filter { central in
                notification.data.count <= central.maximumUpdateValueLength &&
                    subscribedCentrals.contains { $0.identifier == central.identifier }
            }
            if !targets.isEmpty,
               !peripheral.updateValue(notification.data, for: characteristic, onSubscribedCentrals: targets) {
                break
            }
            pendingNotificationBytes -= notification.data.count
            sentCount += 1
        }
        // Keep EVERY unsent fragment, including those after the first failed retry.
        pendingNotifications.removeFirst(sentCount)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Suppress logs for single write requests to reduce noise
        if requests.count > 1 {
            SecureLogger.log("📥 Received \(requests.count) write requests from central", category: SecureLogger.session, level: .debug)
        }
        
        // IMPORTANT: Respond immediately to prevent timeouts!
        // We must respond within a few milliseconds or the central will timeout
        for request in requests {
            peripheral.respond(to: request, withResult: .success)
        }
        
        // Process writes. For long writes, CoreBluetooth may deliver multiple CBATTRequest values with offsets.
        // Combine per-central request values by offset before decoding.
        // Process directly on our message queue to match transport context
        let grouped = Dictionary(grouping: requests, by: { $0.central.identifier.uuidString })
        for (centralUUID, group) in grouped {
            // Sort by offset ascending
            let sorted = group.sorted { $0.offset < $1.offset }
            let hasMultiple = sorted.count > 1 || (sorted.first?.offset ?? 0) > 0

            // Always merge into a persistent per-central buffer to handle multi-callback long writes
            var combined = pendingWriteBuffers[centralUUID] ?? Data()
            var appendedBytes = 0
            var offsets: [Int] = []
            for r in sorted {
                guard let chunk = r.value, !chunk.isEmpty else { continue }
                offsets.append(r.offset)
                let end = r.offset + chunk.count
                if combined.count < end {
                    combined.append(Data(repeating: 0, count: end - combined.count))
                }
                // Write chunk into the correct position (supports out-of-order and overlapping writes)
                combined.replaceSubrange(r.offset..<end, with: chunk)
                appendedBytes += chunk.count
            }
            pendingWriteBuffers[centralUUID] = combined

            // Peek type byte for debug: version is at 0, type at 1 when well-formed
            if combined.count >= 2 {
                let peekType = combined[1]
                if peekType != MessageType.announce.rawValue {
                    SecureLogger.log("📥 Accumulated write from central \(centralUUID): size=\(combined.count) (+\(appendedBytes)) bytes (type=\(peekType)), offsets=\(offsets)", category: SecureLogger.session, level: .debug)
                }
            }

            // Try decode the accumulated buffer
            if let packet = BinaryProtocol.decode(combined) {
                // Clear buffer on success
                pendingWriteBuffers.removeValue(forKey: centralUUID)
                let senderID = packet.senderID.hexEncodedString()
                if packet.type != MessageType.announce.rawValue {
                    SecureLogger.log("📦 Decoded (combined) packet type: \(packet.type) from sender: \(senderID)", category: SecureLogger.session, level: .debug)
                }
                if !subscribedCentrals.contains(sorted[0].central) {
                    subscribedCentrals.append(sorted[0].central)
                }
                if packet.type == MessageType.announce.rawValue {
                    guard isValidLiveAnnouncement(packet) else { continue }
                    if packet.ttl == messageTTL {
                        let previousID = centralToPeerID.updateValue(senderID, forKey: centralUUID)
                        if let previousID, previousID != senderID { retireUnlinkedPeer(previousID) }
                    }
                    // Record ingress link for last-hop suppression then process
                    let msgID = makeMessageID(for: packet)
                    collectionsQueue.async(flags: .barrier) { [weak self] in
                        self?.ingressByMessageID[msgID] = (.central(centralUUID), Date())
                    }
                    handleReceivedPacket(packet, from: senderID)
                } else {
                    // Record ingress link for last-hop suppression then process
                    let msgID = makeMessageID(for: packet)
                    collectionsQueue.async(flags: .barrier) { [weak self] in
                        self?.ingressByMessageID[msgID] = (.central(centralUUID), Date())
                    }
                    handleReceivedPacket(packet, from: senderID)
                }
            } else {
                // If buffer grows suspiciously large, reset to avoid memory leak
                if combined.count > TransportConfig.blePendingWriteBufferCapBytes { // cap for safety
                    pendingWriteBuffers.removeValue(forKey: centralUUID)
                    SecureLogger.log("⚠️ Dropping oversized pending write buffer (\(combined.count) bytes) for central \(centralUUID)", category: SecureLogger.session, level: .warning)
                }
                // If this was a single short write and still failed, log the raw chunk for debugging
                if !hasMultiple, let only = sorted.first, let raw = only.value {
                    let prefix = raw.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                    SecureLogger.log("❌ Failed to decode packet from central (len=\(raw.count), prefix=\(prefix))", category: SecureLogger.session, level: .error)
                }
            }
        }
    }    
}

// MARK: - Advertising Builders & Alias Rotation

extension BLEService {
    private func buildAdvertisementData() -> [String: Any] {
        let data: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BLEService.serviceUUID]
        ]
        // No Local Name for privacy
        return data
    }
    
    // No alias rotation or advertising restarts required.
}

// MARK: - Public history exchange
extension BLEService {
    func sendMessage(_ content: String, mentions: [String], timestamp: Date) {
        sendMessage(content, mentions: mentions, to: nil, timestamp: timestamp)
    }

    func clearPublicHistory() {
        Task { @concurrent in await historyStore.clear() }
    }

    private func ownHistoryAnnouncement() -> BitchatPacket? {
        let announcement = AnnouncementPacket(
            nickname: myNickname,
            noisePublicKey: noiseService.getStaticPublicKeyData(),
            signingPublicKey: noiseService.getSigningPublicKeyData(),
            sessionID: sessionID
        )
        guard let payload = announcement.encode() else { return nil }
        return noiseService.signPacket(BitchatPacket(
            type: MessageType.announce.rawValue, senderID: myPeerIDData, recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000), payload: payload,
            signature: nil, ttl: messageTTL
        ))
    }

    private func verifiedHistoryAuthor(_ entry: MeshHistoryEntry) -> AnnouncementPacket? {
        guard entry.message.version == 1, entry.announcement.version == 1,
              entry.announcement.recipientID == nil,
              entry.message.type == MessageType.message.rawValue,
              entry.message.recipientID == nil,
              entry.message.payload.count <= TransportConfig.publicMessageMaxUTF8Bytes,
              entry.announcement.type == MessageType.announce.rawValue,
              entry.message.senderID == entry.announcement.senderID,
              let author = AnnouncementPacket.decode(from: entry.announcement.payload),
              PeerIDUtils.derivePeerID(fromPublicKey: author.noisePublicKey) == entry.message.senderID.hexEncodedString(),
              noiseService.verifyPacketSignature(entry.announcement, publicKey: author.signingPublicKey),
              noiseService.verifyPacketSignature(entry.message, publicKey: author.signingPublicKey),
              SecureIdentityStateManager.shared.acceptSigningKey(author.signingPublicKey, for: author.noisePublicKey) else { return nil }
        return author
    }

    private func requestHistory(from peerID: String) {
        guard isAppActive else { return }
        guard collectionsQueue.sync(execute: { announcementsByPeer[peerID] != nil }) else { return }
        Task { @concurrent [weak self] in
            guard let self, isAppActive, let request = await historyStore.request(for: peerID),
                  let data = try? JSONEncoder().encode(request) else { return }
            var payload = Data([NoisePayloadType.historyRequest.rawValue])
            payload.append(data)
            _ = sendNoisePayload(payload, to: peerID, queueIfNeeded: false)
        }
    }

    private func handleHistoryPayload(_ data: Data, type: NoisePayloadType, from peerID: String) {
        guard isAppActive else { return }
        Task { @concurrent [weak self] in
            guard let self, isAppActive else { return }
            switch type {
            case .historyRequest:
                guard data.count <= 60_000,
                      let request = try? JSONDecoder().decode(MeshHistoryRequest.self, from: data) else { return }
                guard let entries = await historyStore.missingEntries(for: request, peerID: peerID) else { return }
                defer { Task { @concurrent in await self.historyStore.finishResponse(to: peerID) } }
                for entry in entries {
                    guard !Task.isCancelled, isAppActive, noiseService.hasEstablishedSession(with: peerID),
                          let encoded = try? JSONEncoder().encode(entry), encoded.count < 60_000 else { return }
                    var payload = Data([NoisePayloadType.historyEntry.rawValue])
                    payload.append(encoded)
                    guard sendNoisePayload(payload, to: peerID, queueIfNeeded: false) else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            case .historyEntry:
                guard data.count <= 60_000,
                      let entry = try? JSONDecoder().decode(MeshHistoryEntry.self, from: data),
                      verifiedHistoryAuthor(entry) != nil,
                      await historyStore.insert(entry) else { return }
                guard isAppActive else { return }
                await deliverHistoryEntry(entry)
            default:
                break
            }
        }
    }

    @concurrent
    private func deliverHistoryEntry(_ entry: MeshHistoryEntry) async {
        guard let author = verifiedHistoryAuthor(entry),
              SecureIdentityStateManager.shared.getSocialIdentity(for: author.noisePublicKey.sha256Fingerprint())?.isBlocked != true,
              let content = String(data: entry.message.payload, encoding: .utf8) else { return }
        await delegate?.didReceivePublicMessage(
            from: entry.message.senderID.hexEncodedString(), nickname: author.nickname,
            content: content, timestamp: Date(timeIntervalSince1970: Double(entry.message.timestamp) / 1000),
            messageID: entry.id, isHistorical: true
        )
    }
}

// MARK: - Live link identity
extension BLEService {
    private func isValidLiveAnnouncement(_ packet: BitchatPacket) -> Bool {
        guard packet.version == 1, packet.type == MessageType.announce.rawValue,
              packet.recipientID == nil,
              let author = AnnouncementPacket.decode(from: packet.payload),
              PeerIDUtils.derivePeerID(fromPublicKey: author.noisePublicKey) == packet.senderID.hexEncodedString(),
              noiseService.verifyPacketSignature(packet, publicKey: author.signingPublicKey) else { return false }
        let age = Date().timeIntervalSince1970 - Double(packet.timestamp) / 1000
        return age >= -5 && age <= 45 &&
            SecureIdentityStateManager.shared.acceptSigningKey(author.signingPublicKey, for: author.noisePublicKey)
    }

    private func directlyConnectedPeerIDs() -> Set<String> {
        let snapshot = {
            var ids = Set(self.peripherals.values.compactMap { state in
                state.isConnected ? state.peerID : nil
            })
            for central in self.subscribedCentrals {
                if let id = self.centralToPeerID[central.identifier.uuidString] { ids.insert(id) }
            }
            return ids
        }
        if DispatchQueue.getSpecific(key: bleQueueKey) != nil { return snapshot() }
        return bleQueue.sync(execute: snapshot)
    }

    /// Called on bleQueue after removing or replacing the link's identity mapping.
    private func retireUnlinkedPeer(_ peerID: String) {
        guard !directlyConnectedPeerIDs().contains(peerID) else { return }
        collectionsQueue.sync(flags: .barrier) {
            peers.removeValue(forKey: peerID)
            announcementsByPeer.removeValue(forKey: peerID)
        }
        noiseService.removePeer(peerID)
        requestPeerDataPublish()
        Task { @MainActor [weak self] in
            self?.notifyPeerDisconnectedDebounced(peerID)
        }
    }
}
