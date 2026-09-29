//
// SecureIdentityStateManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Maintains peer identity mappings and persists them in shared defaults.
class SecureIdentityStateManager: @unchecked Sendable {
    static let shared = SecureIdentityStateManager()
    
    private let storage = KeychainManager.shared
    private let cacheKey = "bitchat.identityCache.v2"
    private let signingPinsKey = "bitchat.signingKeyPins.v1"
    private var signingKeyPins: [String: Data] = [:]
    
    // In-memory state
    private var ephemeralSessions: [String: EphemeralIdentity] = [:]
    private var cryptographicIdentities: [String: CryptographicIdentity] = [:]
    private var cache: IdentityCache = IdentityCache()
    
    // Pending actions before handshake
    private var pendingActions: [String: PendingActions] = [:]
    
    // Thread safety
    private let queue = DispatchQueue(label: "bitchat.identity.state", attributes: .concurrent)
    
    private init() {
        loadIdentityCache()
        if let data = storage.getIdentityKey(forKey: signingPinsKey),
           let pins = try? JSONDecoder().decode([String: Data].self, from: data) {
            signingKeyPins = pins
        }
    }

    // MARK: - Persistence
    
    private func loadIdentityCache() {
        guard let data = storage.getIdentityKey(forKey: cacheKey) else {
            // No existing cache, start fresh
            return
        }
        
        do {
            cache = try JSONDecoder().decode(IdentityCache.self, from: data)
        } catch {
            // Log error but continue with empty cache
            SecureLogger.logError(error, context: "Failed to load identity cache", category: SecureLogger.security)
        }
    }
    
    // Called from the existing state queue's mutation barriers. UserDefaults
    // handles disk persistence, so no run-loop timer or encrypted cache is needed.
    private func saveIdentityCache() {
        do {
            let data = try JSONEncoder().encode(cache)
            let saved = storage.saveIdentityKey(data, forKey: cacheKey)
            if saved {
                SecureLogger.log("Identity cache saved to shared defaults", category: SecureLogger.security, level: .debug)
            }
        } catch {
            SecureLogger.logError(error, context: "Failed to save identity cache", category: SecureLogger.security)
        }
    }
    
    /// Wait for queued identity updates to reach UserDefaults before termination.
    func forceSave() {
        queue.sync(flags: .barrier) {}
    }

    // MARK: - Social Identity Management
    
    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        queue.sync {
            return cache.socialIdentities[fingerprint]
        }
    }

    /// Call only after verifying the announcement signature. Pins survive app restarts.
    /// The barrier makes concurrent live/history first observations agree on one signing key.
    func acceptSigningKey(_ signingKey: Data, for noiseKey: Data) -> Bool {
        guard signingKey.count == 32, noiseKey.count == 32 else { return false }
        let fingerprint = noiseKey.sha256Fingerprint()
        return queue.sync(flags: .barrier) {
            if let pinned = signingKeyPins[fingerprint] { return pinned == signingKey }
            if let existing = cryptographicIdentities[fingerprint]?.signingPublicKey,
               existing != signingKey { return false }
            var updated = signingKeyPins
            updated[fingerprint] = signingKey
            guard let data = try? JSONEncoder().encode(updated),
                  storage.saveIdentityKey(data, forKey: signingPinsKey) else { return false }
            signingKeyPins = updated
            return true
        }
    }

    // MARK: - Cryptographic Identities

    /// Insert or update a cryptographic identity and optionally persist its signing key and claimed nickname.
    /// - Parameters:
    ///   - fingerprint: SHA-256 hex of the Noise static public key
    ///   - noisePublicKey: Noise static public key data
    ///   - signingPublicKey: Optional Ed25519 signing public key for authenticating public messages
    ///   - claimedNickname: Optional latest claimed nickname to persist into social identity
    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String? = nil) {
        queue.async(flags: .barrier) {
            if let pinned = self.signingKeyPins[fingerprint],
               let signingPublicKey, pinned != signingPublicKey { return }
            let now = Date()
            if var existing = self.cryptographicIdentities[fingerprint] {
                // Update keys if changed
                if existing.publicKey != noisePublicKey {
                    existing = CryptographicIdentity(
                        fingerprint: fingerprint,
                        publicKey: noisePublicKey,
                        signingPublicKey: signingPublicKey ?? existing.signingPublicKey,
                        firstSeen: existing.firstSeen,
                        lastHandshake: now
                    )
                    self.cryptographicIdentities[fingerprint] = existing
                } else {
                    // Update signing key and lastHandshake
                    existing.signingPublicKey = signingPublicKey ?? existing.signingPublicKey
                    let updated = CryptographicIdentity(
                        fingerprint: existing.fingerprint,
                        publicKey: existing.publicKey,
                        signingPublicKey: existing.signingPublicKey,
                        firstSeen: existing.firstSeen,
                        lastHandshake: now
                    )
                    self.cryptographicIdentities[fingerprint] = updated
                }
                // Persist updated state (already assigned in branches above)
            } else {
                // New entry
                let entry = CryptographicIdentity(
                    fingerprint: fingerprint,
                    publicKey: noisePublicKey,
                    signingPublicKey: signingPublicKey,
                    firstSeen: now,
                    lastHandshake: now
                )
                self.cryptographicIdentities[fingerprint] = entry
            }

            // Optionally persist claimed nickname into social identity
            if let claimed = claimedNickname {
                var identity = self.cache.socialIdentities[fingerprint] ?? SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: claimed,
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: false,
                    notes: nil
                )
                // Update claimed nickname if changed
                if identity.claimedNickname != claimed {
                    identity.claimedNickname = claimed
                    self.cache.socialIdentities[fingerprint] = identity
                } else if self.cache.socialIdentities[fingerprint] == nil {
                    self.cache.socialIdentities[fingerprint] = identity
                }
            }

            self.saveIdentityCache()
        }
    }

    /// Find cryptographic identities whose fingerprint prefix matches a peerID (16-hex) short ID
    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: String) -> [CryptographicIdentity] {
        queue.sync {
            // Defensive: ensure hex and correct length
            guard peerID.count == 16, peerID.allSatisfy({ $0.isHexDigit }) else { return [] }
            return cryptographicIdentities.values.filter { $0.fingerprint.hasPrefix(peerID) }
        }
    }
    
    func updateSocialIdentity(_ identity: SocialIdentity) {
        queue.async(flags: .barrier) {
            self.cache.socialIdentities[identity.fingerprint] = identity
            
            // Update nickname index
            if let existingIdentity = self.cache.socialIdentities[identity.fingerprint] {
                // Remove old nickname from index if changed
                if existingIdentity.claimedNickname != identity.claimedNickname {
                    self.cache.nicknameIndex[existingIdentity.claimedNickname]?.remove(identity.fingerprint)
                    if self.cache.nicknameIndex[existingIdentity.claimedNickname]?.isEmpty == true {
                        self.cache.nicknameIndex.removeValue(forKey: existingIdentity.claimedNickname)
                    }
                }
            }
            
            // Add new nickname to index
            if self.cache.nicknameIndex[identity.claimedNickname] == nil {
                self.cache.nicknameIndex[identity.claimedNickname] = Set<String>()
            }
            self.cache.nicknameIndex[identity.claimedNickname]?.insert(identity.fingerprint)
            
            // Save to shared defaults
            self.saveIdentityCache()
        }
    }
    
    // MARK: - Favorites Management
    func setFavorite(_ fingerprint: String, isFavorite: Bool) {
        queue.async(flags: .barrier) {
            if var identity = self.cache.socialIdentities[fingerprint] {
                identity.isFavorite = isFavorite
                self.cache.socialIdentities[fingerprint] = identity
            } else {
                // Create new social identity for this fingerprint
                let newIdentity = SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: "Unknown",
                    trustLevel: .unknown,
                    isFavorite: isFavorite,
                    isBlocked: false,
                    notes: nil
                )
                self.cache.socialIdentities[fingerprint] = newIdentity
            }
            self.saveIdentityCache()
        }
    }
    
    func isFavorite(fingerprint: String) -> Bool {
        queue.sync {
            return cache.socialIdentities[fingerprint]?.isFavorite ?? false
        }
    }
    
    // MARK: - Blocked Users Management
    
    func isBlocked(fingerprint: String) -> Bool {
        queue.sync {
            return cache.socialIdentities[fingerprint]?.isBlocked ?? false
        }
    }
    
    func setBlocked(_ fingerprint: String, isBlocked: Bool) {
        SecureLogger.log("User \(isBlocked ? "blocked" : "unblocked"): \(fingerprint)", category: SecureLogger.security, level: .info)
        
        queue.async(flags: .barrier) {
            if var identity = self.cache.socialIdentities[fingerprint] {
                identity.isBlocked = isBlocked
                if isBlocked {
                    identity.isFavorite = false  // Can't be both favorite and blocked
                }
                self.cache.socialIdentities[fingerprint] = identity
            } else {
                // Create new social identity for this fingerprint
                let newIdentity = SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: "Unknown",
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: isBlocked,
                    notes: nil
                )
                self.cache.socialIdentities[fingerprint] = newIdentity
            }
            self.saveIdentityCache()
        }
    }
    
    // MARK: - Ephemeral Session Management
    
    func registerEphemeralSession(peerID: String, handshakeState: HandshakeState = .none) {
        queue.async(flags: .barrier) {
            self.ephemeralSessions[peerID] = EphemeralIdentity(
                peerID: peerID,
                sessionStart: Date(),
                handshakeState: handshakeState
            )
        }
    }
    
    // MARK: - Cleanup
    
    func removeEphemeralSession(peerID: String) {
        queue.async(flags: .barrier) {
            self.ephemeralSessions.removeValue(forKey: peerID)
            self.pendingActions.removeValue(forKey: peerID)
        }
    }
    
    // MARK: - Verification
    
    func setVerified(fingerprint: String, verified: Bool) {
        SecureLogger.log("Fingerprint \(verified ? "verified" : "unverified"): \(fingerprint)", category: SecureLogger.security, level: .info)
        
        queue.async(flags: .barrier) {
            if verified {
                self.cache.verifiedFingerprints.insert(fingerprint)
            } else {
                self.cache.verifiedFingerprints.remove(fingerprint)
            }
            
            // Update trust level if social identity exists
            if var identity = self.cache.socialIdentities[fingerprint] {
                identity.trustLevel = verified ? .verified : .casual
                self.cache.socialIdentities[fingerprint] = identity
            }
            
            self.saveIdentityCache()
        }
    }
    
    func isVerified(fingerprint: String) -> Bool {
        queue.sync {
            return cache.verifiedFingerprints.contains(fingerprint)
        }
    }
    
    func getVerifiedFingerprints() -> Set<String> {
        queue.sync {
            return cache.verifiedFingerprints
        }
    }
}
