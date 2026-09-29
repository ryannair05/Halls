import Foundation

// MARK: - Protocol TLV Packets

struct AnnouncementPacket {
    let nickname: String
    let noisePublicKey: Data            // Noise static public key (Curve25519.KeyAgreement)
    let signingPublicKey: Data          // Ed25519 public key for signing

    let sessionID: Data?

    init(nickname: String, noisePublicKey: Data, signingPublicKey: Data, sessionID: Data? = nil) {
        self.nickname = nickname
        self.noisePublicKey = noisePublicKey
        self.signingPublicKey = signingPublicKey
        self.sessionID = sessionID
    }

    // Required discriminator: upstream uses some of the same TLV and Noise payload values.
    private static let protocolMarker = Data("meet-and-eat:1".utf8)

    private enum TLVType: UInt8 {
        case nickname = 0x01
        case noisePublicKey = 0x02
        case signingPublicKey = 0x03
        case sessionID = 0x04
        case protocolMarker = 0x7F
    }

    func encode() -> Data? {
        guard noisePublicKey.count == 32, signingPublicKey.count == 32, sessionID?.count == 16 else { return nil }
        var data = Data()
        data.append(TLVType.protocolMarker.rawValue)
        data.append(UInt8(Self.protocolMarker.count))
        data.append(Self.protocolMarker)
        // Reserve: TLVs for nickname (2 + n), noise key (2 + 32), signing key (2 + 32)
        data.reserveCapacity(2 + min(nickname.count, 255) + 2 + noisePublicKey.count + 2 + signingPublicKey.count)

        // TLV for nickname
        guard let nicknameData = nickname.data(using: .utf8), nicknameData.count <= 255 else { return nil }
        data.append(TLVType.nickname.rawValue)
        data.append(UInt8(nicknameData.count))
        data.append(nicknameData)

        // TLV for noise public key
        guard noisePublicKey.count <= 255 else { return nil }
        data.append(TLVType.noisePublicKey.rawValue)
        data.append(UInt8(noisePublicKey.count))
        data.append(noisePublicKey)

        // TLV for signing public key
        guard signingPublicKey.count <= 255 else { return nil }
        data.append(TLVType.signingPublicKey.rawValue)
        data.append(UInt8(signingPublicKey.count))
        data.append(signingPublicKey)
        if let sessionID {
            guard sessionID.count == 16 else { return nil }
            data.append(TLVType.sessionID.rawValue)
            data.append(16)
            data.append(sessionID)
        }

        return data
    }

    static func decode(from data: Data) -> AnnouncementPacket? {
        var offset = 0
        var nickname: String?
        var noisePublicKey: Data?
        var signingPublicKey: Data?
        var sessionID: Data?
        var seenTypes = Set<UInt8>()
        var hasProtocolMarker = false

        while offset + 2 <= data.count {
            let typeRaw = data[offset]
            offset += 1
            let length = Int(data[offset])
            offset += 1

            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            guard seenTypes.insert(typeRaw).inserted,
                  let type = TLVType(rawValue: typeRaw) else { return nil }
            switch type {
            case .nickname:
                nickname = String(data: value, encoding: .utf8)
            case .noisePublicKey:
                guard value.count == 32 else { return nil }
                noisePublicKey = Data(value)
            case .signingPublicKey:
                guard value.count == 32 else { return nil }
                signingPublicKey = Data(value)
            case .sessionID:
                guard value.count == 16 else { return nil }
                sessionID = Data(value)
            case .protocolMarker:
                guard value == Self.protocolMarker else { return nil }
                hasProtocolMarker = true
            }
        }

        guard offset == data.count, hasProtocolMarker, sessionID != nil,
              let nickname, let noisePublicKey, let signingPublicKey else { return nil }
        return AnnouncementPacket(
            nickname: nickname,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            sessionID: sessionID
        )
    }
}

struct PrivateMessagePacket {
    let messageID: String
    let content: String

    func encode() -> Data? {
        var data = Data()
        data.appendUUID(messageID)
        data.appendString(content, maxLength: TransportConfig.attachmentCaptionMaxLength)
        return data
    }

    static func decode(from data: Data) -> PrivateMessagePacket? {
        var offset = 0
        guard let messageID = data.readUUID(at: &offset),
              let content = data.readString(at: &offset, maxLength: TransportConfig.attachmentCaptionMaxLength),
              offset == data.count else {
            return nil
        }
        return PrivateMessagePacket(messageID: messageID, content: content)
    }
}

struct AttachmentPacket {
    let messageID: String
    let fileName: String
    let mimeType: String
    let caption: String
    let kind: BitchatAttachmentKind
    let fileData: Data

    func encode() -> Data? {
        guard fileData.count <= TransportConfig.attachmentMaxPayloadBytes else {
            return nil
        }

        var data = Data()
        data.appendUUID(messageID)
        data.appendUInt8(kind == .image ? 1 : 2)
        data.appendString(fileName, maxLength: 255)
        data.appendString(mimeType, maxLength: 255)
        data.appendString(caption, maxLength: TransportConfig.attachmentCaptionMaxLength)
        data.appendData(fileData, maxLength: TransportConfig.attachmentMaxPayloadBytes)
        return data
    }

    static func decode(from data: Data) -> AttachmentPacket? {
        var offset = 0
        guard let messageID = data.readUUID(at: &offset),
              let kindRaw = data.readUInt8(at: &offset),
              let fileName = data.readString(at: &offset, maxLength: 255),
              let mimeType = data.readString(at: &offset, maxLength: 255),
              let caption = data.readString(at: &offset, maxLength: TransportConfig.attachmentCaptionMaxLength),
              let fileData = data.readData(at: &offset, maxLength: TransportConfig.attachmentMaxPayloadBytes),
              offset == data.count else {
            return nil
        }

        let kind: BitchatAttachmentKind
        switch kindRaw {
        case 1:
            kind = .image
        case 2:
            kind = .file
        default:
            return nil
        }

        return AttachmentPacket(
            messageID: messageID,
            fileName: fileName,
            mimeType: mimeType,
            caption: caption,
            kind: kind,
            fileData: fileData
        )
    }
}
