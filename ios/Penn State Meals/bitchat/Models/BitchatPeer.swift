import Foundation
import CoreBluetooth

/// Represents a peer in the BitChat network with all associated metadata
struct BitchatPeer: Identifiable, Equatable {
    let id: String // Hex-encoded peer ID
    let noisePublicKey: Data
    let nickname: String
    let lastSeen: Date
    let isConnected: Bool
    let isReachable: Bool
    
    // Favorite-related properties
    var favoriteStatus: FavoritesPersistenceService.FavoriteRelationship?

    // Connection state
    enum ConnectionState {
        case bluetoothConnected
        case meshReachable      // Seen via mesh recently, not directly connected
        case offline            // Not connected via any transport
    }

    var connectionState: ConnectionState {
        if isConnected {
            return .bluetoothConnected
        } else if isReachable {
            return .meshReachable
        } else {
            return .offline
        }
    }
    
    var isFavorite: Bool {
        favoriteStatus?.isFavorite ?? false
    }
    
    var isMutualFavorite: Bool {
        favoriteStatus?.isMutual ?? false
    }
    
    var theyFavoritedUs: Bool {
        favoriteStatus?.theyFavoritedUs ?? false
    }
    
    // Display helpers
    var displayName: String {
        nickname.isEmpty ? String(id.prefix(8)) : nickname
    }
    
    var statusIcon: String {
        switch connectionState {
        case .bluetoothConnected:
            return "📻" // Radio icon for mesh connection
        case .meshReachable:
            return "📡" // Antenna for mesh reachable
        case .offline:
            if theyFavoritedUs && !isFavorite {
                return "🌙" // Crescent moon - they favorited us but we didn't reciprocate
            } else {
                return ""
            }
        }
    }
    
    // Initialize from mesh service data
    init(
        id: String,
        noisePublicKey: Data,
        nickname: String,
        lastSeen: Date = Date(),
        isConnected: Bool = false,
        isReachable: Bool = false
    ) {
        self.id = id
        self.noisePublicKey = noisePublicKey
        self.nickname = nickname
        self.lastSeen = lastSeen
        self.isConnected = isConnected
        self.isReachable = isReachable
        
        // Load favorite status - will be set later by the manager
        self.favoriteStatus = nil
    }
    
    static func == (lhs: BitchatPeer, rhs: BitchatPeer) -> Bool {
        lhs.id == rhs.id
    }
}

//
