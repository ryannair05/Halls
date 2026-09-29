import Foundation

enum PrivateConversationConnectivity: Equatable, Sendable {
    case direct
    case multiHop
    case handshaking
    case offline

    var statusText: String {
        switch self {
        case .direct:
            return "Nearby"
        case .multiHop:
            return "Reachable via mesh"
        case .handshaking:
            return "Securing connection"
        case .offline:
            return "Offline"
        }
    }

    var systemImageName: String {
        switch self {
        case .direct:
            return "dot.radiowaves.left.and.right"
        case .multiHop:
            return "point.3.filled.connected.trianglepath.dotted"
        case .handshaking:
            return "lock.rotation"
        case .offline:
            return "wifi.slash"
        }
    }
}

struct PrivateConversationSummary: Identifiable, Equatable, Sendable {
    let id: String
    let peerID: String
    let displayName: String
    let previewText: String
    let timestamp: Date?
    let hasUnread: Bool
    let isFavorite: Bool
    let connectivity: PrivateConversationConnectivity
    let draftPreview: String?
}
