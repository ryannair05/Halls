import Foundation

/// Routes private messaging events over the mesh transport.
@MainActor
final class MessageRouter {
    private let mesh: any Transport

    init(mesh: any Transport) {
        self.mesh = mesh
    }

    func sendPrivate(_ content: String, to peerID: String, recipientNickname: String, messageID: String) {
        if mesh.isPeerReachable(peerID) {
            SecureLogger.log("Routing PM via mesh (reachable) to \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            mesh.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        }
    }

    func sendAttachment(data: Data, fileName: String, mimeType: String, kind: BitchatAttachmentKind, caption: String, to peerID: String, recipientNickname: String, messageID: String) -> Bool {
        if mesh.isPeerReachable(peerID) {
            SecureLogger.log("Routing attachment via mesh (reachable) to \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            return mesh.sendAttachment(
                data: data,
                fileName: fileName,
                mimeType: mimeType,
                kind: kind,
                caption: caption,
                to: peerID,
                recipientNickname: recipientNickname,
                messageID: messageID
            )
        }
        return false
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String) {
        if mesh.isPeerReachable(peerID) {
            SecureLogger.log("Routing READ ack via mesh (reachable) to \(peerID.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            mesh.sendReadReceipt(receipt, to: peerID)
        }
    }

    func sendDeliveryAck(_ messageID: String, to peerID: String) {
        if mesh.isPeerReachable(peerID) {
            SecureLogger.log("Routing DELIVERED ack via mesh (reachable) to \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            mesh.sendDeliveryAck(for: messageID, to: peerID)
        }
    }

    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        if mesh.isPeerConnected(peerID) || mesh.isPeerReachable(peerID) {
            mesh.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        }
    }
}
