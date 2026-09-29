//
// KeychainManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Compatibility API for the fork's local identity storage.
/// Values live in shared defaults; they do not use Keychain protection.
final class KeychainManager: Sendable {
    static let shared = KeychainManager()

    private init() {}

    // UserDefaults synchronizes access internally. Keep the wrapper stateless.
    private var defaults: UserDefaults {
        UserDefaults(suiteName: "group.chat.bitchat").unsafelyUnwrapped
    }

    @discardableResult
    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        defaults.set(keyData, forKey: "identity_\(key)")
        return true
    }

    func getIdentityKey(forKey key: String) -> Data? {
        defaults.data(forKey: "identity_\(key)")
    }

    /// Clear temporary cryptographic buffers after use.
    static func secureClear(_ data: inout Data) {
        _ = data.withUnsafeMutableBytes { bytes in
            memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
        }
        data = Data()
    }
}
