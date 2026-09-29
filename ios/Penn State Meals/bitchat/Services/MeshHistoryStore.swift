import CryptoKit
import Foundation

/// Original signed public traffic plus its author's signed identity announcement.
/// Replaying this proof never updates the live People list.
struct MeshHistoryEntry: Codable, Sendable {
    let message: BitchatPacket
    let announcement: BitchatPacket

    var id: String {
        Self.messageID(peerID: message.senderID.hexEncodedString(), timestamp: message.timestamp, content: message.payload)
    }

    static func messageID(peerID: String, timestamp: UInt64, content: Data) -> String {
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        return "mesh:\(peerID):\(timestamp):\(digest)"
    }
}

struct MeshHistoryRequest: Codable, Sendable {
    let knownIDs: [String]
    let since: Date
}

/// Bounded, local public history. Private messages and attachments never enter gossip.
actor MeshHistoryStore {
    private struct Archive: Codable {
        var entries: [MeshHistoryEntry] = []
        var clearedBefore: Date = .distantPast
    }

    private let fileURL: URL
    private var archive: Archive
    private var lastExchange: [String: Date] = [:]
    private var activeResponses: Set<String> = []
    private static let maxEntries = 300
    private static let maxPayloadBytes = 2_000_000
    private static let lifetime: TimeInterval = 60 * 60

    init() {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("bitchat-history", isDirectory: true)
        fileURL = directory.appendingPathComponent("public.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Archive.self, from: data) {
            archive = saved
        } else {
            archive = Archive()
        }
    }

    func entries() -> [MeshHistoryEntry] {
        prune()
        return archive.entries
    }

    @discardableResult
    func insert(_ entry: MeshHistoryEntry) -> Bool {
        prune()
        let timestamp = Date(timeIntervalSince1970: Double(entry.message.timestamp) / 1000)
        guard timestamp >= max(archive.clearedBefore, Date().addingTimeInterval(-Self.lifetime)),
              timestamp <= Date().addingTimeInterval(5),
              !archive.entries.contains(where: { $0.id == entry.id }) else { return false }
        archive.entries.append(entry)
        prune(persistChanges: false)
        save()
        return true
    }

    func request(for peerID: String) -> MeshHistoryRequest? {
        guard allowExchange("request:\(peerID)") else { return nil }
        prune()
        return MeshHistoryRequest(knownIDs: archive.entries.map(\.id), since: archive.clearedBefore)
    }

    func missingEntries(for request: MeshHistoryRequest, peerID: String) -> [MeshHistoryEntry]? {
        guard request.knownIDs.count <= Self.maxEntries,
              !activeResponses.contains(peerID), allowExchange("response:\(peerID)") else { return nil }
        activeResponses.insert(peerID)
        prune()
        let known = Set(request.knownIDs)
        return archive.entries.filter {
            !known.contains($0.id) && Double($0.message.timestamp) / 1000 >= request.since.timeIntervalSince1970
        }
    }

    func finishResponse(to peerID: String) {
        activeResponses.remove(peerID)
    }

    func clear() {
        archive.entries.removeAll()
        archive.clearedBefore = Date()
        save()
    }

    private func allowExchange(_ key: String) -> Bool {
        let now = Date()
        lastExchange = lastExchange.filter { now.timeIntervalSince($0.value) < 15 }
        guard lastExchange[key] == nil else { return false }
        lastExchange[key] = now
        return true
    }

    private func prune(persistChanges: Bool = true) {
        let previousCount = archive.entries.count
        let cutoff = max(archive.clearedBefore, Date().addingTimeInterval(-Self.lifetime))
        archive.entries.removeAll { Double($0.message.timestamp) / 1000 < cutoff.timeIntervalSince1970 }
        archive.entries.sort { $0.message.timestamp < $1.message.timestamp }
        if archive.entries.count > Self.maxEntries {
            archive.entries.removeFirst(archive.entries.count - Self.maxEntries)
        }
        var bytes = archive.entries.reduce(0) { $0 + $1.message.payload.count }
        while bytes > Self.maxPayloadBytes, let first = archive.entries.first {
            bytes -= first.message.payload.count
            archive.entries.removeFirst()
        }
        if persistChanges, archive.entries.count != previousCount { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(archive).write(to: fileURL, options: .atomic)
        } catch {
            SecureLogger.logError(error, context: "Saving nearby chat history", category: SecureLogger.session)
        }
    }
}
