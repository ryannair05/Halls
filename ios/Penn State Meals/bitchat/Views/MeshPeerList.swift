import SwiftUI

struct MeshPeerList: View {
    @ObservedObject var viewModel: BitchatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let searchText: String
    let onTapPeer: (String) -> Void
    let onToggleFavorite: (String) -> Void
    @Environment(\.colorScheme) var colorScheme

    @State private var orderedIDs: [String] = []

    var body: some View {
        let nearbyPeers = viewModel.allPeers.filter { $0.isConnected || $0.isReachable }
        if nearbyPeers.isEmpty {
            Text("No one nearby yet")
                .font(.subheadline)
                .foregroundStyle(secondaryTextColor)
                .padding(.horizontal)
                .padding(.top, 12)
        } else {
            let myPeerID = viewModel.meshService.myPeerID
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let filteredPeers = nearbyPeers.filter { peer in
                guard !query.isEmpty else { return true }
                return peer.nickname.localizedCaseInsensitiveContains(query) || peer.id.localizedCaseInsensitiveContains(query)
            }
            let mapped: [(peer: BitchatPeer, isMe: Bool, hasUnread: Bool, enc: EncryptionStatus)] = filteredPeers.map { peer in
                let isMe = peer.id == myPeerID
                let hasUnread = viewModel.hasUnreadMessages(for: peer.id)
                let enc = viewModel.getEncryptionStatus(for: peer.id)
                return (peer, isMe, hasUnread, enc)
            }
            if mapped.isEmpty {
                Text("No matches")
                    .font(.subheadline)
                    .foregroundStyle(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
            } else {
            // Stable visual order without mutating state here
            let currentIDs = mapped.map { $0.peer.id }
            let displayIDs = orderedIDs.filter { currentIDs.contains($0) } + currentIDs.filter { !orderedIDs.contains($0) }
            let peers: [(peer: BitchatPeer, isMe: Bool, hasUnread: Bool, enc: EncryptionStatus)] = displayIDs.compactMap { id in
                mapped.first(where: { $0.peer.id == id })
            }

            ForEach(peers, id: \.peer.id) { item in
                let peer = item.peer
                let isMe = item.isMe
                HStack(spacing: 4) {
                    let assigned = viewModel.colorForMeshPeer(id: peer.id, isDark: colorScheme == .dark)
                    let baseColor = isMe ? Color.orange : assigned
                    if isMe {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(baseColor)
                    } else if peer.isConnected {
                        // Mesh-connected peer: radio icon
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                            .foregroundStyle(baseColor)
                    } else if peer.isReachable {
                        // Mesh-reachable (relayed): point.3 icon
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 10))
                            .foregroundStyle(baseColor)
                    } else {
                        // Fallback icon for others (dimmed)
                        Image(systemName: "person")
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryTextColor)
                    }
                    
                    let displayName = isMe ? viewModel.nickname : peer.nickname
                    let (base, suffix) = splitSuffix(from: displayName)
                    HStack(spacing: 0) {
                        Text(base)
                            .font(.subheadline)
                            .foregroundStyle(baseColor)
                        if !suffix.isEmpty {
                            let suffixColor = isMe ? Color.orange.opacity(0.6) : baseColor.opacity(0.6)
                            Text(suffix)
                                .font(.subheadline)
                                .foregroundStyle(suffixColor)
                        }
                    }
                    
                    if !isMe, viewModel.isPeerBlocked(peer.id) {
                        Image(systemName: "nosign")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .help("Blocked")
                    }
                    
                    if !isMe {
                        if let icon = item.enc.icon {
                            Image(systemName: icon)
                                .font(.system(size: 10))
                                .foregroundStyle(baseColor)
                        }
                    }
                    
                    Spacer()
                    
                    // Unread message indicator for this peer
                    if !isMe, item.hasUnread {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("New messages")
                    }
                    
                    if !isMe {
                        Button(action: { onToggleFavorite(peer.id) }) {
                            Image(systemName: (peer.favoriteStatus?.isFavorite ?? false) ? "star.fill" : "star")
                                .font(.system(size: 12))
                                .foregroundStyle((peer.favoriteStatus?.isFavorite ?? false) ? .yellow : secondaryTextColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel((peer.favoriteStatus?.isFavorite ?? false) ? "Remove favorite" : "Add favorite")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { if !isMe { onTapPeer(peer.id) } }
            }
            // Seed and update order outside result builder
            .padding(.top, 10)
            .onAppear {
                let currentIDs = mapped.map { $0.peer.id }
                orderedIDs = currentIDs
            }
            .onChange(of: mapped.map { $0.peer.id }) { _, ids in
                var newOrder = orderedIDs
                newOrder.removeAll { !ids.contains($0) }
                for id in ids where !newOrder.contains(id) { newOrder.append(id) }
                if newOrder != orderedIDs { orderedIDs = newOrder }
            }
            }
        }
    }
}

// Helper to split a trailing #abcd suffix
private func splitSuffix(from name: String) -> (String, String) {
    guard name.count >= 5 else { return (name, "") }
    let suffix = String(name.suffix(5))
    if suffix.first == "#", suffix.dropFirst().allSatisfy({ c in
        ("0"..."9").contains(String(c)) || ("a"..."f").contains(String(c)) || ("A"..."F").contains(String(c))
    }) {
        let base = String(name.dropLast(5))
        return (base, suffix)
    }
    return (name, "")
}
