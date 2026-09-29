import Foundation

struct PeerIDResolver {
    static func isShortID(_ id: String) -> Bool {
        return id.count == 16 && Data(hexString: id) != nil
    }

    static func isNoiseKeyHex(_ id: String) -> Bool {
        return id.count == 64 && Data(hexString: id) != nil
    }
}

