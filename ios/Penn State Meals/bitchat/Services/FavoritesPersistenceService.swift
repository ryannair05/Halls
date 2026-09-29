import Foundation

/// Manages persistent favorite relationships between peers.
@MainActor
final class FavoritesPersistenceService {

    struct FavoriteRelationship: Codable {
        let peerNoisePublicKey: Data
        let peerNickname: String
        let isFavorite: Bool
        let theyFavoritedUs: Bool
        let favoritedAt: Date
        let lastUpdated: Date

        var isMutual: Bool {
            isFavorite && theyFavoritedUs
        }
    }

    private static let storageKey = "chat.bitchat.favorites"
    private(set) var favorites: [Data: FavoriteRelationship] = [:]
    private let userDefaults = UserDefaults(suiteName: "group.chat.bitchat")

    static let shared = FavoritesPersistenceService()

    private init() {
        loadFavorites()
    }

    func addFavorite(peerNoisePublicKey: Data, peerNickname: String) {
        let existing = favorites[peerNoisePublicKey]
        favorites[peerNoisePublicKey] = FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNickname: peerNickname,
            isFavorite: true,
            theyFavoritedUs: existing?.theyFavoritedUs ?? false,
            favoritedAt: existing?.favoritedAt ?? Date(),
            lastUpdated: Date()
        )

        saveFavorites()
        postFavoriteStatusChanged(for: peerNoisePublicKey)
    }

    func removeFavorite(peerNoisePublicKey: Data) {
        guard let existing = favorites[peerNoisePublicKey] else { return }

        if existing.theyFavoritedUs {
            favorites[peerNoisePublicKey] = FavoriteRelationship(
                peerNoisePublicKey: existing.peerNoisePublicKey,
                peerNickname: existing.peerNickname,
                isFavorite: false,
                theyFavoritedUs: true,
                favoritedAt: existing.favoritedAt,
                lastUpdated: Date()
            )
        } else {
            favorites.removeValue(forKey: peerNoisePublicKey)
        }

        saveFavorites()
        postFavoriteStatusChanged(for: peerNoisePublicKey)
    }

    func updatePeerFavoritedUs(
        peerNoisePublicKey: Data,
        favorited: Bool,
        peerNickname: String? = nil
    ) {
        let existing = favorites[peerNoisePublicKey]
        let nickname = peerNickname ?? existing?.peerNickname ?? "Unknown"

        let relationship = FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNickname: nickname,
            isFavorite: existing?.isFavorite ?? false,
            theyFavoritedUs: favorited,
            favoritedAt: existing?.favoritedAt ?? Date(),
            lastUpdated: Date()
        )

        if !relationship.isFavorite && !relationship.theyFavoritedUs {
            favorites.removeValue(forKey: peerNoisePublicKey)
        } else {
            favorites[peerNoisePublicKey] = relationship
        }

        saveFavorites()
        postFavoriteStatusChanged(for: peerNoisePublicKey)
    }

    func isFavorite(_ peerNoisePublicKey: Data) -> Bool {
        favorites[peerNoisePublicKey]?.isFavorite ?? false
    }

    func isMutualFavorite(_ peerNoisePublicKey: Data) -> Bool {
        favorites[peerNoisePublicKey]?.isMutual ?? false
    }

    func getFavoriteStatus(for peerNoisePublicKey: Data) -> FavoriteRelationship? {
        favorites[peerNoisePublicKey]
    }

    func getFavoriteStatus(forPeerID peerID: String) -> FavoriteRelationship? {
        guard peerID.count == 16 else { return nil }
        for (pubkey, relationship) in favorites where PeerIDUtils.derivePeerID(fromPublicKey: pubkey) == peerID {
            return relationship
        }
        return nil
    }

    func updateNickname(for peerNoisePublicKey: Data, newNickname: String) {
        guard let existing = favorites[peerNoisePublicKey], existing.peerNickname != newNickname else { return }

        favorites[peerNoisePublicKey] = FavoriteRelationship(
            peerNoisePublicKey: existing.peerNoisePublicKey,
            peerNickname: newNickname,
            isFavorite: existing.isFavorite,
            theyFavoritedUs: existing.theyFavoritedUs,
            favoritedAt: existing.favoritedAt,
            lastUpdated: Date()
        )

        saveFavorites()
        postFavoriteStatusChanged(for: peerNoisePublicKey)
    }

    func updateNoisePublicKey(from oldKey: Data, to newKey: Data, peerNickname: String) {
        guard let existing = favorites[oldKey] else { return }

        favorites.removeValue(forKey: oldKey)
        favorites[newKey] = FavoriteRelationship(
            peerNoisePublicKey: newKey,
            peerNickname: peerNickname,
            isFavorite: existing.isFavorite,
            theyFavoritedUs: existing.theyFavoritedUs,
            favoritedAt: existing.favoritedAt,
            lastUpdated: Date()
        )

        saveFavorites()
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: [
                "peerPublicKey": newKey,
                "oldPeerPublicKey": oldKey,
                "isKeyUpdate": true
            ]
        )
    }

    private func saveFavorites() {
        do {
            let data = try JSONEncoder().encode(Array(favorites.values))
            userDefaults?.set(data, forKey: Self.storageKey)
        } catch {
            SecureLogger.log("Failed to save favorites: \(error)", category: SecureLogger.session, level: .error)
        }
    }

    private func loadFavorites() {
        guard let data = userDefaults?.data(forKey: Self.storageKey) else {
            return
        }

        do {
            let relationships = try JSONDecoder().decode([FavoriteRelationship].self, from: data)
            favorites = Dictionary(uniqueKeysWithValues: relationships.map { ($0.peerNoisePublicKey, $0) })
        } catch {
            SecureLogger.log("Failed to load favorites: \(error)", category: SecureLogger.session, level: .error)
        }
    }

    private func postFavoriteStatusChanged(for peerNoisePublicKey: Data) {
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: ["peerPublicKey": peerNoisePublicKey]
        )
    }
}

extension Notification.Name {
    static let favoriteStatusChanged = Notification.Name("FavoriteStatusChanged")
}
