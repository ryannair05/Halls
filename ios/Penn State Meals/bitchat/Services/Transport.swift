import Foundation
import Combine

/// Abstract mesh transport interface used by BitchatViewModel and services.
/// BLEService is the only transport implementation in the embedded app.
struct TransportPeerSnapshot: Equatable, Hashable {
    let id: String
    let nickname: String
    let isConnected: Bool
    let noisePublicKey: Data?
    let lastSeen: Date
}

protocol Transport: AnyObject {
    func setBackgroundReceptionEnabled(_ enabled: Bool)
    // Peer events (preferred over publishers for UI)
    var peerEventsDelegate: (any TransportPeerEventsDelegate)? { get set }
    // Event sink
    var delegate: (any BitchatDelegate)? { get set }

    // Identity
    var myPeerID: String { get }
    var myNickname: String { get }
    func setNickname(_ nickname: String)

    // Lifecycle
    func startServices()
    func stopServices()

    // Connectivity and peers
    func isPeerConnected(_ peerID: String) -> Bool
    func isPeerReachable(_ peerID: String) -> Bool
    func peerNickname(peerID: String) -> String?
    func getPeerNicknames() -> [String: String]

    // Protocol utilities
    func getFingerprint(for peerID: String) -> String?
    func getNoiseSessionState(for peerID: String) -> LazyHandshakeState
    func triggerHandshake(with peerID: String)
    func getNoiseService() -> NoiseEncryptionService

    // Messaging
    func sendMessage(_ content: String, mentions: [String], timestamp: Date)
    func clearPublicHistory()
    @MainActor func sendPrivateMessage(_ content: String, to peerID: String, recipientNickname: String, messageID: String)
    @MainActor func sendAttachment(data: Data, fileName: String, mimeType: String, kind: BitchatAttachmentKind, caption: String, to peerID: String, recipientNickname: String, messageID: String) -> Bool
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String)
    @MainActor func sendFavoriteNotification(to peerID: String, isFavorite: Bool)
    func sendBroadcastAnnounce()
    @MainActor func sendDeliveryAck(for messageID: String, to peerID: String)

    // Peer snapshots (for non-UI services)
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> { get }
    func currentPeerSnapshots() -> [TransportPeerSnapshot]
}

protocol TransportPeerEventsDelegate: AnyObject {
    @MainActor func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot])
}

extension BLEService: Transport {}

extension Transport {
    func sendMessage(_ content: String, mentions: [String]) {
        sendMessage(content, mentions: mentions, timestamp: Date())
    }
}
