//
//  UnifiedPeerService.swift
//  bitchat
//
//  Unified peer state management combining mesh connectivity and favorites.
//

import Combine
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class UnifiedPeerService: nonisolated ObservableObject, nonisolated TransportPeerEventsDelegate {
    @Published private(set) var peers: [BitchatPeer] = []
    @Published private(set) var connectedPeerIDs: Set<String> = []
    @Published private(set) var favorites: [BitchatPeer] = []

    private var peerIndex: [String: BitchatPeer] = [:]
    private var fingerprintCache: [String: String] = [:]
    private let meshService: any Transport
    private let favoritesService = FavoritesPersistenceService.shared
    weak var messageRouter: MessageRouter?

    init(meshService: any Transport) {
        self.meshService = meshService
        setupSubscriptions()
        updatePeers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .favoriteStatusChanged, object: nil)
    }

    private func setupSubscriptions() {
        meshService.peerEventsDelegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updatePeers),
            name: .favoriteStatusChanged,
            object: nil
        )
    }

    func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot]) {
        updatePeers()
    }

    @objc private func updatePeers() {
        let snapshots = meshService.currentPeerSnapshots()
        let favoritesMap = favoritesService.favorites
        let hasAnyConnected = snapshots.contains(where: \.isConnected)

        var enriched: [BitchatPeer] = []
        var connected: Set<String> = []
        var seenIDs: Set<String> = []

        for snapshot in snapshots where snapshot.id != meshService.myPeerID {
            var peer = BitchatPeer(
                id: snapshot.id,
                noisePublicKey: snapshot.noisePublicKey ?? Data(),
                nickname: snapshot.nickname,
                lastSeen: snapshot.lastSeen,
                isConnected: snapshot.isConnected,
                isReachable: buildReachability(for: snapshot, hasAnyConnected: hasAnyConnected, favorites: favoritesMap)
            )

            if let noiseKey = snapshot.noisePublicKey {
                peer.favoriteStatus = favoritesMap[noiseKey]
                fingerprintCache[snapshot.id] = noiseKey.sha256Fingerprint()
            }

            enriched.append(peer)
            seenIDs.insert(snapshot.id)
            if snapshot.isConnected {
                connected.insert(snapshot.id)
            }
        }

        for relationship in favoritesMap.values where relationship.isFavorite || relationship.theyFavoritedUs {
            let peerID = PeerIDUtils.derivePeerID(fromPublicKey: relationship.peerNoisePublicKey)
            guard !seenIDs.contains(peerID) else { continue }

            var peer = BitchatPeer(
                id: peerID,
                noisePublicKey: relationship.peerNoisePublicKey,
                nickname: relationship.peerNickname,
                lastSeen: relationship.lastUpdated,
                isConnected: false,
                isReachable: false
            )
            peer.favoriteStatus = relationship
            fingerprintCache[peerID] = relationship.peerNoisePublicKey.sha256Fingerprint()
            enriched.append(peer)
        }

        enriched.sort { lhs, rhs in
            func rank(_ peer: BitchatPeer) -> Int {
                if peer.isConnected { return 3 }
                if peer.isReachable { return 2 }
                if peer.isFavorite || peer.theyFavoritedUs { return 1 }
                return 0
            }

            let leftRank = rank(lhs)
            let rightRank = rank(rhs)
            if leftRank != rightRank { return leftRank > rightRank }
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        peers = enriched.filter { $0.isConnected || $0.isReachable || $0.isFavorite || $0.theyFavoritedUs }
        favorites = peers.filter(\.isFavorite)
        connectedPeerIDs = connected
        peerIndex = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0) })
    }

    private func buildReachability(
        for snapshot: TransportPeerSnapshot,
        hasAnyConnected: Bool,
        favorites: [Data: FavoritesPersistenceService.FavoriteRelationship]
    ) -> Bool {
        if snapshot.isConnected { return true }
        guard hasAnyConnected else { return false }

        let retention: TimeInterval
        if let key = snapshot.noisePublicKey, favorites[key]?.isFavorite == true || favorites[key]?.theyFavoritedUs == true {
            retention = TransportConfig.bleReachabilityRetentionVerifiedSeconds
        } else {
            retention = TransportConfig.bleReachabilityRetentionUnverifiedSeconds
        }

        return Date().timeIntervalSince(snapshot.lastSeen) <= retention
    }

    func getPeer(by id: String) -> BitchatPeer? {
        peerIndex[id]
    }

    func getPeerID(for nickname: String) -> String? {
        peers.first { $0.displayName == nickname || $0.nickname == nickname }?.id
    }

    func isOnline(_ peerID: String) -> Bool {
        connectedPeerIDs.contains(peerID)
    }

    func isBlocked(_ peerID: String) -> Bool {
        guard let fingerprint = getFingerprint(for: peerID),
              let identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprint) else {
            return false
        }
        return identity.isBlocked
    }

    func toggleFavorite(_ peerID: String) {
        guard let peer = getPeer(by: peerID) else { return }
        let nickname = peer.nickname.isEmpty ? peer.displayName : peer.nickname

        if peer.isFavorite {
            favoritesService.removeFavorite(peerNoisePublicKey: peer.noisePublicKey)
        } else {
            favoritesService.addFavorite(peerNoisePublicKey: peer.noisePublicKey, peerNickname: nickname)
        }

        messageRouter?.sendFavoriteNotification(to: peerID, isFavorite: !peer.isFavorite)
        updatePeers()
        objectWillChange.send()
    }

    func toggleBlocked(_ peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }

        var identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprint)
            ?? SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: getPeer(by: peerID)?.displayName ?? "Unknown",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )

        identity.isBlocked.toggle()
        if identity.isBlocked, let peer = getPeer(by: peerID) {
            favoritesService.removeFavorite(peerNoisePublicKey: peer.noisePublicKey)
        }

        SecureIdentityStateManager.shared.updateSocialIdentity(identity)
    }

    func getFingerprint(for peerID: String) -> String? {
        if let cached = fingerprintCache[peerID] {
            return cached
        }

        if let fingerprint = meshService.getFingerprint(for: peerID) {
            fingerprintCache[peerID] = fingerprint
            return fingerprint
        }

        if let peer = getPeer(by: peerID) {
            let fingerprint = peer.noisePublicKey.sha256Fingerprint()
            fingerprintCache[peerID] = fingerprint
            return fingerprint
        }

        return nil
    }

    var favoritePeers: Set<String> {
        Set(favorites.compactMap { getFingerprint(for: $0.id) })
    }

    var blockedUsers: Set<String> {
        Set(peers.compactMap { peer in
            isBlocked(peer.id) ? getFingerprint(for: peer.id) : nil
        })
    }
}

extension Data {
    func sha256Fingerprint() -> String {
        let hash = SHA256.hash(data: self)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
