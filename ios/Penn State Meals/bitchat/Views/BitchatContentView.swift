//
// BitchatContentView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import FirebaseAnalytics
import PhotosUI

// MARK: - Main Content View

struct BitchatContentView: View {
    // MARK: - Properties
    @EnvironmentObject var viewModel: BitchatViewModel
    @State private var messageText = ""
    @State private var nearbyDraft = ""
    private enum Composer: Hashable {
        case nearby
        case direct(String)
    }

    @FocusState private var focusedComposer: Composer?
    @Environment(\.colorScheme) var colorScheme
    @State private var showSidebar = false
    @State private var sidebarSearchText = ""
    @GestureState private var dragOffset: CGFloat = .zero
    @State private var showAppInfo = false
    @State private var commandSuggestions: [String] = []
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: String?
    @FocusState private var isNicknameFieldFocused: Bool
    @State private var isAtBottomPublic: Bool = true
    @State private var isAtBottomPrivate: Bool = true
    @State private var scrollThrottleTimer: Task<Void, Never>?
    @State private var autocompleteDebounceTimer: Task<Void, Never>?
    @State private var expandedMessageIDs: Set<String> = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var isLoadingPhoto = false
    @State private var photoError: String?
    @State private var previewAttachment: PreviewAttachmentItem?
    @State private var messageDetailsItem: MessageDetailsItem?
    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 30
    // Window sizes for rendering (infinite scroll up)
    @State private var windowCountPublic: Int = 300
    @State private var windowCountPrivate: [String: Int] = [:]
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var publicComposerCapture = ChatComposerCapture()
    @State private var privateComposerCapture = ChatComposerCapture()
    @State private var composerFrames: [Bool: CGRect] = [:]
    @State private var sentPrivatePeer: String?
    @State private var pendingThrow: PendingChatThrow?
    @State private var throwRequest: ChatThrowRequest?
    @State private var throwTargetFrame: CGRect?
    @State private var throwLayoutTask: Task<Void, Never>?
    @State private var throwTimeoutTask: Task<Void, Never>?
    @State private var containerWidth: CGFloat = .zero
    
    // MARK: - Computed Properties
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        Color.primary
    }
    
    private var secondaryTextColor: Color {
        Color.secondary
    }

    private var filteredConversationSummaries: [PrivateConversationSummary] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return viewModel.conversationSummaries
        }
        return viewModel.conversationSummaries.filter { summary in
            summary.displayName.localizedCaseInsensitiveContains(query) ||
            summary.previewText.localizedCaseInsensitiveContains(query)
        }
    }
    
    // MARK: - Body
    var body: some View {
        // This binding drives the NavigationStack
        let isPrivateChatPresented = Binding(
            get: { viewModel.selectedPrivateChatPeer != nil },
            set: { isPresented in
                if !isPresented {
                    focusedComposer = nil
                    viewModel.endPrivateChat()
                }
            }
        )
        ZStack {
            mainChatView
                .onAppear {
                    viewModel.currentColorScheme = colorScheme
                }
                .onChange(of: colorScheme) {
                    viewModel.currentColorScheme = colorScheme
                }
                .simultaneousGesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            state = showSidebar ? max(0, value.translation.width) : max(-containerWidth * 0.7, min(0, value.translation.width))
                        }
                        .onEnded { value in
                            // Ensure the gesture is predominantly horizontal
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            
                            let sidebarWidth = containerWidth * 0.7
                            let translation = value.translation.width
                            
                            if showSidebar {
                                // If sidebar is open, check for a closing gesture (drag right)
                                if translation > sidebarWidth / 3 {
                                    showSidebar = false
                                }
                            } else {
                                // If sidebar is closed, check for an opening gesture (drag left from anywhere)
                                if translation < -sidebarWidth {
                                    showSidebar = true
                                }
                            }
                        }
                )
                .navigationDestination(isPresented: isPrivateChatPresented) {
                    privateChatDetailView
                }
                .navigationBarHidden(true)
            
            // Sidebar overlay (unchanged)
            HStack(spacing: 0) {
                // Tap to dismiss area
                Color.black.opacity(showSidebar ? 0.18 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            showSidebar = false
                        }
                    }
                
                // Always render sidebar to avoid layout recalculation during drag
                sidebarView
                    .frame(width: containerWidth * 0.7)
                    .background(backgroundColor)
                    .shadow(color: .black.opacity(0.12), radius: 12, x: -4)
            }
            .offset(x: (showSidebar ? 0 : containerWidth) + dragOffset)
            .animation(.interactiveSpring(), value: showSidebar)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            if containerWidth != newWidth { cancelThrow() }
            containerWidth = newWidth
        }
#if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
#endif
        .sheet(isPresented: $showAppInfo) {
            AppInfoView()
        }
        .sheet(item: $messageDetailsItem) { item in
            MessageDetailsSheet(item: item)
        }
        .sheet(item: $previewAttachment) { item in
            AttachmentQuickLookPreview(url: item.attachment.localURL)
                .presentationDragIndicator(.visible)
        }
        .onChange(of: selectedPhotoItem) {
            photoLoadTask?.cancel()
            guard let item = selectedPhotoItem, let peerID = viewModel.selectedPrivateChatPeer else {
                isLoadingPhoto = false
                return
            }
            let caption = messageText
            isLoadingPhoto = true
            focusedComposer = nil
            photoLoadTask = Task { @MainActor in
                defer {
                    if self.selectedPhotoItem == item {
                        self.selectedPhotoItem = nil
                        isLoadingPhoto = false
                    }
                }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        guard !Task.isCancelled else { return }
                        photoError = "This photo could not be loaded. Please choose another photo."
                        return
                    }
                    guard !Task.isCancelled, viewModel.selectedPrivateChatPeer == peerID else { return }
                    if await viewModel.sendImageAttachment(data, to: peerID, caption: caption),
                       viewModel.selectedPrivateChatPeer == peerID, messageText == caption {
                        messageText = ""
                    }
                } catch {
                    if !Task.isCancelled {
                        photoError = "This photo could not be loaded. If it is stored in iCloud, download it in Photos and try again."
                    }
                }
            }
        }
        .alert("Message Not Sent", isPresented: Binding(
            get: { viewModel.messageSendError != nil },
            set: { if !$0 { viewModel.messageSendError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.messageSendError = nil }
        } message: {
            Text(viewModel.messageSendError ?? "")
        }
        .alert("Photo Unavailable", isPresented: Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )) {
            Button("OK", role: .cancel) { photoError = nil }
        } message: {
            Text(photoError ?? "")
        }
        .onChange(of: viewModel.selectedPrivateChatPeer) { oldPeer, newPeer in
            // Sending can resolve a reconnected peer's ID without navigating away.
            if oldPeer != nil, newPeer == sentPrivatePeer, pendingThrow?.message.isPrivate == true {
                focusedComposer = newPeer.map(Composer.direct)
                return
            }
            cancelThrow()
            focusedComposer = nil
            isNicknameFieldFocused = false
            autocompleteDebounceTimer?.cancel()
            photoLoadTask?.cancel()
            selectedPhotoItem = nil
            isLoadingPhoto = false
            commandSuggestions = []
            if let oldPeer {
                viewModel.setDraft(messageText, for: oldPeer)
            } else {
                nearbyDraft = messageText
            }
            syncComposerDraft(with: newPeer)
        }
        .onChange(of: showSidebar) {
            if showSidebar {
                cancelThrow()
                focusedComposer = nil
                isNicknameFieldFocused = false
            }
        }
        .analyticsScreen(name: "BitchatContentView")
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            syncComposerDraft(with: viewModel.selectedPrivateChatPeer)
        }
        .alert(viewModel.bluetoothAlertTitle, isPresented: $viewModel.showBluetoothAlert) {
            if let actionTitle = viewModel.bluetoothPresentation.actionTitle {
                Button(actionTitle, action: openBluetoothPermissionSettings)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.bluetoothAlertMessage)
        }
        .onDisappear {
            focusedComposer = nil
            cancelThrow()
            // Clean up timers
            scrollThrottleTimer?.cancel()
            autocompleteDebounceTimer?.cancel()
        }
    }
    
    
    private func messagesShareGroup(_ first: BitchatMessage?, _ second: BitchatMessage?) -> Bool {
        guard let first, let second else { return false }
        return first.sender != "system" && first.sender == second.sender &&
            first.senderPeerID == second.senderPeerID &&
            Calendar.current.isDate(first.timestamp, equalTo: second.timestamp, toGranularity: .minute)
    }

    private func deliveryStatusForGroup(endingAt index: Int, messages: [BitchatMessage]) -> DeliveryStatus? {
        guard messages[index].isPrivate else { return nil }
        func rank(_ status: DeliveryStatus) -> Int {
            switch status {
            case .failed: 0
            case .sending: 1
            case .sent: 2
            case .partiallyDelivered: 3
            case .delivered: 4
            case .read: 5
            }
        }
        var status = messages[index].deliveryStatus
        var cursor = index
        while cursor > 0, messagesShareGroup(messages[cursor - 1], messages[cursor]) {
            cursor -= 1
            if let candidate = messages[cursor].deliveryStatus,
               rank(candidate) < (status.map(rank) ?? Int.max) {
                status = candidate
            }
        }
        return status
    }

    // MARK: - Message List View
    private func messagesView(privatePeer: String?, isAtBottom: Binding<Bool>) -> some View {
        let contextKey = privatePeer.map { "dm:\($0)" } ?? "mesh"

        func latestTargetID() -> String? {
            if let privatePeer {
                let count = windowCountPrivate[privatePeer] ?? TransportConfig.uiWindowInitialCountPrivate
                return viewModel.getPrivateChatMessages(for: privatePeer).suffix(count).last.map { "dm:\(privatePeer)|\($0.id)" }
            }
            return viewModel.messages.suffix(windowCountPublic).last.map { "mesh|\($0.id)" }
        }

        func scrollToLatest(using proxy: ScrollViewProxy, after delay: Duration? = nil) {
            scrollThrottleTimer?.cancel()
            scrollThrottleTimer = Task { @MainActor in
                if let delay {
                    try? await Task.sleep(for: delay)
                }
                guard !Task.isCancelled else { return }
                if let target = latestTargetID() {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
        }

        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let messages: [BitchatMessage] = {
                            if let privatePeer {
                                return viewModel.getPrivateChatMessages(for: privatePeer)
                            }
                            return viewModel.messages
                        }()
                        let currentWindowCount = privatePeer.map { windowCountPrivate[$0] ?? TransportConfig.uiWindowInitialCountPrivate } ?? windowCountPublic
                        let windowedMessages = messages.suffix(currentWindowCount)
                        let items = windowedMessages.map { (uiID: "\(contextKey)|\($0.id)", message: $0) }
                        let filteredItems = items.filter { $0.message.hasVisibleBody }

                        if filteredItems.isEmpty {
                            emptyStateView(for: privatePeer)
                                .frame(maxWidth: .infinity, minHeight: 260)
                                .padding(.horizontal, 24)
                                .padding(.top, 36)
                        }

                        let groupMessages = filteredItems.map(\.message)
                        ForEach(Array(filteredItems.enumerated()), id: \.element.uiID) { index, item in
                            let message = item.message
                            let previous = index > 0 ? filteredItems[index - 1].message : nil
                            let next = index + 1 < filteredItems.count ? filteredItems[index + 1].message : nil
                            let repeatsHeader = messagesShareGroup(previous, message)
                            let endsGroup = !messagesShareGroup(message, next)
                            let groupStatus: DeliveryStatus? = endsGroup ? deliveryStatusForGroup(
                                endingAt: index, messages: groupMessages
                            ) : nil
                            let isOutgoing = message.senderPeerID.map { $0 == viewModel.meshService.myPeerID } ?? (message.sender == viewModel.nickname)
                            let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                            let isLong = trimmedContent.count > TransportConfig.uiLongMessageLengthThreshold || trimmedContent.hasVeryLongToken(threshold: TransportConfig.uiVeryLongTokenThreshold)
                            let isExpanded = expandedMessageIDs.contains(message.id)

                            VStack(alignment: .leading, spacing: 3) {
                                if message.sender == "system" {
                                    Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
                                        .font(.caption)
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(Color.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 4)
                                } else {
                                    if !repeatsHeader {
                                        HStack {
                                            if isOutgoing {
                                                Spacer()
                                                Text(message.sender)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                Text(message.sender)
                                                    .font(.caption)
                                                    .foregroundStyle(viewModel.peerColor(for: message, isDark: colorScheme == .dark))
                                                    .contextMenu {
                                                        Button {
                                                            messageText = "@\(message.sender) "
                                                            focusedComposer = privatePeer.map(Composer.direct) ?? .nearby
                                                        } label: {
                                                            Label("Mention", systemImage: "person.bubble")
                                                        }

                                                        if let peerID = message.senderPeerID {
                                                            Button {
                                                                viewModel.startPrivateChat(with: peerID)
                                                                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                                                                    showSidebar = false
                                                                }
                                                            } label: {
                                                                Label("Direct Message", systemImage: "square.and.pencil")
                                                            }
                                                        }

                                                        Button {
                                                            viewModel.sendMessage("/hug @\(message.sender)")
                                                        } label: {
                                                            Label("Hug", systemImage: "person.line.dotted.person")
                                                        }

                                                        Button {
                                                            viewModel.sendMessage("/slap @\(message.sender)")
                                                        } label: {
                                                            Label("Slap", systemImage: "hands.clap")
                                                        }

                                                        Button(role: .destructive) {
                                                            viewModel.sendMessage("/block \(message.sender)")
                                                        } label: {
                                                            Label("Block", systemImage: "nosign")
                                                        }
                                                    }
                                                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                            }
                                        }
                                        .onTapGesture {
                                            messageText = "@\(message.sender) "
                                            focusedComposer = privatePeer.map(Composer.direct) ?? .nearby
                                        }
                                    }

                                    HStack(alignment: .bottom, spacing: 0) {
                                        if !isOutgoing {
                                            messageBubbleContent(for: message, isOutgoing: false, isLong: isLong, isExpanded: isExpanded)
                                            Spacer()
                                        } else {
                                            Spacer()
                                            messageBubbleContent(for: message, isOutgoing: true, isLong: isLong, isExpanded: isExpanded)
                                        }
                                    }
                                    .contextMenu {
                                        messageContextMenu(for: message, privatePeer: privatePeer)
                                    }
                                    .frame(maxWidth: .infinity)

                                    if isOutgoing, message.isPrivate, let status = groupStatus {
                                        DeliveryStatusView(status: status)
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                            .padding(.trailing, 12)
                                    }

                                    if isLong {
                                        HStack {
                                            if !isOutgoing {
                                                Button(isExpanded ? "show less" : "show more") {
                                                    if isExpanded {
                                                        expandedMessageIDs.remove(message.id)
                                                    } else {
                                                        expandedMessageIDs.insert(message.id)
                                                    }
                                                }
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(Color.blue)
                                                .padding(.top, 4)
                                                Spacer()
                                            } else {
                                                Spacer()
                                                Button(isExpanded ? "show less" : "show more") {
                                                    if isExpanded {
                                                        expandedMessageIDs.remove(message.id)
                                                    } else {
                                                        expandedMessageIDs.insert(message.id)
                                                    }
                                                }
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(Color.blue)
                                                .padding(.top, 4)
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                            .onAppear {
                                if message.id == windowedMessages.last?.id {
                                    isAtBottom.wrappedValue = true
                                    if let privatePeer {
                                        viewModel.markPrivateMessagesAsRead(from: privatePeer)
                                    }
                                }

                                if message.id == windowedMessages.first?.id, messages.count > windowedMessages.count {
                                    let step = TransportConfig.uiWindowStepCount
                                    let preserveID = "\(contextKey)|\(message.id)"
                                    if let privatePeer {
                                        let current = windowCountPrivate[privatePeer] ?? TransportConfig.uiWindowInitialCountPrivate
                                        let newCount = min(messages.count, current + step)
                                        if newCount != current {
                                            windowCountPrivate[privatePeer] = newCount
                                            Task { @MainActor in
                                                proxy.scrollTo(preserveID, anchor: .top)
                                            }
                                        }
                                    } else {
                                        let current = windowCountPublic
                                        let newCount = min(messages.count, current + step)
                                        if newCount != current {
                                            windowCountPublic = newCount
                                            Task { @MainActor in
                                                proxy.scrollTo(preserveID, anchor: .top)
                                            }
                                        }
                                    }
                                }
                            }
                            .onDisappear {
                                if message.id == windowedMessages.last?.id {
                                    isAtBottom.wrappedValue = false
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                    }
                    .transaction { tx in
                        if viewModel.isBatchingPublic {
                            tx.disablesAnimations = true
                        }
                    }
                    .padding(.bottom, 12)
                }

            }
            .background(backgroundColor)
            .onOpenURL { url in
                guard url.scheme == "bitchat", url.host == "user" else { return }
                let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let peerID = id.removingPercentEncoding ?? id
                selectedMessageSenderID = peerID
                selectedMessageSender = viewModel.messages.last(where: { $0.senderPeerID == peerID })?.sender
            }
            .onAppear {
                isAtBottom.wrappedValue = true
                if let privatePeer {
                    viewModel.markPrivateMessagesAsRead(from: privatePeer)
                }
                scrollToLatest(using: proxy)
                scrollToLatest(using: proxy, after: .milliseconds(50))
            }
            .onChange(of: privatePeer) {
                isAtBottom.wrappedValue = true
                if let privatePeer {
                    viewModel.markPrivateMessagesAsRead(from: privatePeer)
                }
                scrollToLatest(using: proxy)
            }
            .onChange(of: latestTargetID()) { _, target in
                guard target != nil else { return }
                let latestMessage = if let privatePeer {
                    viewModel.getPrivateChatMessages(for: privatePeer).last
                } else {
                    viewModel.messages.last
                }
                guard let latestMessage else { return }
                let isFromSelf = latestMessage.senderPeerID.map { $0 == viewModel.meshService.myPeerID } ??
                    (latestMessage.sender == viewModel.nickname)
                guard isFromSelf || isAtBottom.wrappedValue else { return }
                isAtBottom.wrappedValue = true
                // Receipt/status changes do not move the transcript. Scroll once for a new last message.
                scrollToLatest(using: proxy)
                if let privatePeer { viewModel.markPrivateMessagesAsRead(from: privatePeer) }
            }
        }
    }
    
    // MARK: - Sidebar View
    
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.system(size: 16, weight: .bold, design: .default))
                    .foregroundStyle(textColor)
                Spacer()
                Button {
                    withAnimation(.smooth(duration: 0.25)) { showSidebar = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .accessibilityLabel("Close chats")
            }
            .frame(height: 44)
            .padding(.horizontal, 12)
            .background(backgroundColor.opacity(0.95))

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(secondaryTextColor)
                TextField("Search", text: $sidebarSearchText)
                    .font(.subheadline)
                    .textFieldStyle(.plain)
                    .foregroundStyle(textColor)
                    .autocorrectionDisabled(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !filteredConversationSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Direct Messages")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(secondaryTextColor)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)

                            ForEach(filteredConversationSummaries) { summary in
                                conversationRow(summary)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("People")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(secondaryTextColor)
                            .padding(.horizontal, 12)

                        MeshPeerList(
                            viewModel: viewModel,
                            textColor: textColor,
                            secondaryTextColor: secondaryTextColor,
                            searchText: sidebarSearchText,
                            onTapPeer: { peerID in
                                viewModel.startPrivateChat(with: peerID)
                                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                                    showSidebar = false
                                }
                            },
                            onToggleFavorite: { peerID in
                                viewModel.toggleFavorite(peerID: peerID)
                            }
                        )
                    }

                    if filteredConversationSummaries.isEmpty && viewModel.allPeers.isEmpty {
                        sidebarEmptyState
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .background(backgroundColor)
    }
    
    // MARK: - Input View
    
    private func inputView(for peerID: String?) -> some View {
        VStack(spacing: nil) {
            // @mentions autocomplete
            if viewModel.showAutocomplete && !viewModel.autocompleteSuggestions.isEmpty {
                ForEach(viewModel.autocompleteSuggestions.prefix(4), id: \.self) { suggestion in
                    Button(action: {
                        _ = viewModel.completeNickname(suggestion, in: &messageText)
                    }) {
                        Text(suggestion)
                            .font(.system(size: 11, design: .default))
                            .foregroundStyle(textColor)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .background(Color.gray.opacity(0.1))
                }
                .background(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(secondaryTextColor.opacity(0.3), lineWidth: 1)
                }
                .padding(.horizontal, 12)
            }
            
            // Command suggestions
            if !commandSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // Define commands with aliases and syntax
                    let allCommands: [(commands: [String], syntax: String?, description: String)] = [
                        (["/block"], "[nickname]", "block or list blocked peers"),
                        (["/clear"], nil, "clear chat messages"),
                        (["/hug"], "<nickname>", "send someone a warm hug"),
                        (["/m", "/msg"], "<nickname> [message]", "send private message"),
                        (["/slap"], "<nickname>", "slap someone with a trout"),
                        (["/unblock"], "<nickname>", "unblock a peer"),
                        (["/w"], nil, "see who's online"),
                        (["/fav"], "<nickname>", "add to favorites"),
                        (["/unfav"], "<nickname>", "remove from favorites")
                    ]
                    
                    // Show matching commands
                    ForEach(commandSuggestions, id: \.self) { command in
                        // Find the command info for this suggestion
                        if let info = allCommands.first(where: { $0.commands.contains(command) }) {
                            Button(action: {
                                // Replace current text with selected command
                                messageText = command + " "
                                self.commandSuggestions = []
                            }) {
                                HStack {
                                    // Show all aliases together
                                    Text(info.commands.joined(separator: ", "))
                                        .font(.system(size: 11, design: .default))
                                        .foregroundStyle(textColor)
                                        .fontWeight(.medium)
                                    
                                    // Show syntax if any
                                    if let syntax = info.syntax {
                                        Text(syntax)
                                            .font(.system(size: 10, design: .default))
                                            .foregroundStyle(secondaryTextColor.opacity(0.8))
                                    }
                                    
                                    Spacer()
                                    
                                    // Show description
                                    Text(info.description)
                                        .font(.system(size: 10, design: .default))
                                        .foregroundStyle(secondaryTextColor)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .background(Color.gray.opacity(0.1))
                        }
                    }
                }
                .background(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(secondaryTextColor.opacity(0.3), lineWidth: 1)
                }
                .padding(.horizontal, 12)
            }
            
            HStack(alignment: .bottom, spacing: 8) {
                if peerID != nil {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images, preferredItemEncoding: .compatible) {
                        Image(systemName: "photo")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attach photo")
                    .disabled(isLoadingPhoto || !viewModel.bluetoothPresentation.isAvailable)

                    if isLoadingPhoto {
                        ProgressView()
                            .frame(width: 28, height: 32)
                            .accessibilityLabel("Preparing photo")
                    }
                }

                TextField("Message", text: $messageText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(textColor)
                    .focused($focusedComposer, equals: peerID.map(Composer.direct) ?? .nearby)
                    .padding(.leading, 11)
                    .padding(.trailing, 40)
                    .padding(.vertical, 7)
                    .frame(minHeight: 36)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(peerID == nil ? "publicChatThrow" : "privateChatThrow"))
                    } action: { composerFrames[peerID != nil] = $0 }

                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
                    }
                // iOS keyboard autocomplete and capitalization enabled by default
                    .onChange(of: messageText) {
                        if let peerID {
                            viewModel.setDraft(messageText, for: peerID)
                        } else if viewModel.selectedPrivateChatPeer == nil {
                            nearbyDraft = messageText
                        }
                        // Cancel previous debounce timer
                        autocompleteDebounceTimer?.cancel()
                        
                        // Debounce ALL autocomplete updates to reduce calls during rapid typing
                        autocompleteDebounceTimer = Task {
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else {
                                return
                            }
                            
                            await MainActor.run {
                                // --- 1. Nickname Autocomplete (existing logic) ---
                                let newValue = messageText
                                let cursorPosition = newValue.count
                                viewModel.updateAutocomplete(for: newValue, cursorPosition: cursorPosition)
                                
                                // --- 2. Command Autocomplete (moved inside the timer) ---
                                if newValue.hasPrefix("/") && cursorPosition >= 1 {
                                    var commandDescriptions = [
                                        ("/block", "block or list blocked peers"),
                                        ("/clear", "clear chat messages"),
                                        ("/hug", "send someone a warm hug"),
                                        ("/m", "send private message"),
                                        ("/slap", "slap someone with a trout"),
                                        ("/unblock", "unblock a peer"),
                                        ("/w", "see who's online")
                                    ]
                                    commandDescriptions.append(("/fav", "add to favorites"))
                                    commandDescriptions.append(("/unfav", "remove from favorites"))
                                    
                                    let input = newValue.lowercased()
                                    
                                    // Map of aliases to primary commands
                                    let aliases: [String: String] = [
                                        "/join": "/j",
                                        "/msg": "/m"
                                    ]
                                    
                                    // Filter commands, but convert aliases to primary
                                    var commandSuggestions = commandDescriptions
                                        .filter { $0.0.starts(with: input) }
                                        .map { $0.0 }
                                    
                                    // Also check if input matches an alias
                                    for (alias, primary) in aliases {
                                        if alias.starts(with: input) && !commandSuggestions.contains(primary) {
                                            if commandDescriptions.contains(where: { $0.0 == primary }) {
                                                commandSuggestions.append(primary)
                                            }
                                        }
                                    }
                                    
                                    // Remove duplicates and sort
                                    self.commandSuggestions = Set(commandSuggestions).sorted()
                                } else {
                                    self.commandSuggestions = []
                                }

                            }
                        }
                    }
                    .onSubmit {
                        sendMessage()
                    }
                    .submitLabel(.send)
                    .autocorrectionDisabled(!viewModel.showAutocomplete)
                    .overlay(alignment: .bottomTrailing) {
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.accentColor)
                        }
                        .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.bluetoothPresentation.isAvailable)
                        .accessibilityLabel("Send message")
                        .padding(4)
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(uiColor: .systemBackground))
        }
    }
    
    private func sendMessage() {
        let currentPeer = viewModel.selectedPrivateChatPeer
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, viewModel.bluetoothPresentation.isAvailable else { return }
        if currentPeer == nil, !text.hasPrefix("/"), !viewModel.validatePublicMessageLength(text) { return }
        cancelThrow()
        let sourceFrame = composerFrames[currentPeer != nil] ?? .zero
        let composerCapture = currentPeer == nil ? publicComposerCapture : privateComposerCapture
        let source = reduceMotion ? nil : composerCapture.capture(text: messageText, frame: sourceFrame)
        let sent = viewModel.sendMessage(messageText)
        sentPrivatePeer = viewModel.selectedPrivateChatPeer
        if !reduceMotion, let sent, let source {
            pendingThrow = PendingChatThrow(message: sent, sourceFrame: sourceFrame,
                                           sourceText: source.image, sourceTextOrigin: source.origin)
            // Never leave a row concealed if it cannot be laid out (navigation, backgrounding, or window changes).
            throwTimeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                cancelThrow()
            }
        }
        messageText = ""
        if let currentPeer { viewModel.clearDraft(for: currentPeer) }
    }

    private func sendThrowOverlay(isPrivate: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if let pendingThrow, throwRequest == nil {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(uiColor: .systemBlue))
                    .frame(width: pendingThrow.sourceFrame.width, height: pendingThrow.sourceFrame.height)
                    .overlay(alignment: .topLeading) {
                        Image(uiImage: pendingThrow.sourceText)
                            .offset(x: pendingThrow.sourceTextOrigin.x, y: pendingThrow.sourceTextOrigin.y)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .position(x: pendingThrow.sourceFrame.midX, y: pendingThrow.sourceFrame.midY)
            }
            ChatThrowOverlay(request: throwRequest, composerCapture: isPrivate ? privateComposerCapture : publicComposerCapture) { id in
                if pendingThrow?.message.id == id { cancelThrow() }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cancelThrow() {
        throwLayoutTask?.cancel()
        throwLayoutTask = nil
        throwTargetFrame = nil
        throwTimeoutTask?.cancel()
        throwRequest = nil
        pendingThrow = nil
    }

    private func prepareThrow(for message: BitchatMessage, frame: CGRect, isLong: Bool, isExpanded: Bool) {
        if let request = throwRequest, request.id == message.id {
            // Preserve the active flight when the keyboard or transcript shifts its landing point.
            if abs(request.target.minX - frame.minX) >= 1 / displayScale ||
                abs(request.target.minY - frame.minY) >= 1 / displayScale {
                throwRequest = ChatThrowRequest(id: request.id, source: request.source, target: frame,
                                                sourceText: request.sourceText, targetText: request.targetText,
                                                sourceTextOrigin: request.sourceTextOrigin)
            }
            return
        }
        guard let pending = pendingThrow, pending.message.id == message.id,
              throwRequest == nil, frame.width > 0, frame.height > 0 else { return }
        throwTargetFrame = frame
        guard throwLayoutTask == nil else { return }
        throwLayoutTask = Task { @MainActor in
            // Leave the geometry callback without adding an artificial frame delay.
            await Task.yield()
            guard !Task.isCancelled, pendingThrow?.message.id == message.id,
                  let frame = throwTargetFrame else { return }
            let renderer = ImageRenderer(content:
                messageTextLabel(for: message, isLong: isLong, isExpanded: isExpanded)
                    .frame(width: max(1, frame.width - 28), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.colorScheme, colorScheme)
            )
            renderer.scale = displayScale
            guard let image = renderer.uiImage else { cancelThrow(); return }
            throwTimeoutTask?.cancel()
            throwTimeoutTask = nil
            throwRequest = ChatThrowRequest(id: message.id, source: pending.sourceFrame, target: frame,
                                            sourceText: pending.sourceText, targetText: image,
                                            sourceTextOrigin: pending.sourceTextOrigin)
        }
    }

    private func messageTextLabel(for message: BitchatMessage, isLong: Bool, isExpanded: Bool) -> some View {
        Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(isLong && !isExpanded ? TransportConfig.uiLongMessageLineLimit : nil)
    }

    @ViewBuilder
    private func messageBubbleContent(for message: BitchatMessage, isOutgoing: Bool, isLong: Bool, isExpanded: Bool) -> some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 8) {
            if let attachment = message.attachment {
                attachmentPreview(for: attachment, isOutgoing: isOutgoing)
            }

            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messageTextLabel(for: message, isLong: isLong, isExpanded: isExpanded)
                    .padding(.top, 6)
                    .padding(.bottom, 7)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 48, minHeight: 35)
                    .background(
                        RoundedRectangle(cornerRadius: 17.5)
                            .fill(isOutgoing ? Color(uiColor: .systemBlue) : Color(uiColor: colorScheme == .dark ? .secondarySystemFill : .systemGray5))
                    )
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(message.isPrivate ? "privateChatThrow" : "publicChatThrow"))
                    } action: { frame in
                        prepareThrow(for: message, frame: frame, isLong: isLong, isExpanded: isExpanded)
                    }
                    .opacity(pendingThrow?.message.id == message.id ? 0 : 1)
            }
        }
        // Both the real bubble and the throw replica use this final text width.
        .frame(maxWidth: max(48, (containerWidth - 32) * 0.85), alignment: isOutgoing ? .trailing : .leading)
    }

    @ViewBuilder
    private func attachmentPreview(for attachment: BitchatAttachment, isOutgoing: Bool) -> some View {
        switch attachment.kind {
        case .image:
            if let image = UIImage(contentsOfFile: attachment.localPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: max(48, (containerWidth - 32) * 0.715), maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                    .onTapGesture {
                        previewAttachment = PreviewAttachmentItem(attachment: attachment)
                    }
                    .accessibilityLabel("Image attachment: \(attachment.fileName), \(attachment.displayFileSize)")
            } else {
                attachmentFallbackCard(for: attachment, isOutgoing: isOutgoing)
            }
        case .file:
            attachmentFallbackCard(for: attachment, isOutgoing: isOutgoing)
        }
    }

    private func attachmentFallbackCard(for attachment: BitchatAttachment, isOutgoing: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.kind.systemImageName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isOutgoing ? Color.white : Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOutgoing ? Color.white : textColor)
                    .lineLimit(2)

                Text(attachment.displayFileSize)
                    .font(.system(size: 12))
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.8) : secondaryTextColor)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minWidth: 180, maxWidth: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isOutgoing ? Color.blue : Color(uiColor: .systemGray5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            previewAttachment = PreviewAttachmentItem(attachment: attachment)
        }
        .accessibilityLabel("\(attachment.kind == .image ? "Image" : "File") attachment: \(attachment.fileName), \(attachment.displayFileSize)")
    }
    
    // MARK: - View Components
    private var mainChatView: some View {
        VStack(spacing: 0) {
            mainHeaderView
            Divider()
            bluetoothBannerIfNeeded
            messagesView(privatePeer: nil, isAtBottom: $isAtBottomPublic)
            Divider()
            if viewModel.selectedPrivateChatPeer == nil {
                inputView(for: nil)
            }
        }
        .coordinateSpace(name: "publicChatThrow")
        .overlay {
            if viewModel.selectedPrivateChatPeer == nil { sendThrowOverlay(isPrivate: false) }
        }
        .background(backgroundColor)
        .foregroundStyle(textColor)
    }
    
    // Compute channel-aware people count and color for toolbar (cross-platform)
    private func channelPeopleCountAndColor() -> (Int, Color) {
        let counts = viewModel.allPeers.reduce(into: (others: 0, mesh: 0)) { counts, peer in
            guard peer.id != viewModel.meshService.myPeerID else { return }
            if peer.isConnected { counts.mesh += 1; counts.others += 1 }
            else if peer.isReachable { counts.others += 1 }
        }
        let color: Color = counts.mesh > 0 ? Color.accentColor : Color.secondary
        return (counts.others, color)
    }
    
    private var mainHeaderView: some View {
        HStack(spacing: 0) {
            Text("BTChat ")
                .font(.system(size: 18, weight: .medium, design: .default))
                .foregroundStyle(.tint)
                .onTapGesture(count: 1) {
                    // Single tap for app info
                    showAppInfo = true
                }
            
            HStack(spacing: 0) {
                Text("@")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(secondaryTextColor)
                
                TextField("nickname", text: $viewModel.nickname)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(maxWidth: 100)
                    .foregroundStyle(textColor)
                    .focused($isNicknameFieldFocused)
                    .autocorrectionDisabled(true)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .onChange(of: isNicknameFieldFocused) {
                        if !isNicknameFieldFocused {
                            // Only validate when losing focus
                            viewModel.validateAndSaveNickname()
                        }
                    }
                    .onSubmit {
                        viewModel.validateAndSaveNickname()
                    }
            }
            
            Spacer()
            
            // Channel badge + dynamic spacing + people counter
            // Precompute header count and color outside the ViewBuilder expressions
            let cc = channelPeopleCountAndColor()
            let headerCountColor: Color = cc.1
            let headerOtherPeersCount: Int = cc.0
            
            HStack(spacing: 10) {
                // Unread indicator (now shown on iOS and macOS)
                if viewModel.hasAnyUnreadMessages {
                    Button(action: { viewModel.openMostRelevantPrivateChat() }) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open unread private chat")
                    .onChange(of: viewModel.unreadPrivateMessages, initial: true) { oldValue, newValue in
                        guard newValue.count > oldValue.count else { return }
                        let feedback = UINotificationFeedbackGenerator()
                        feedback.notificationOccurred(.success)
                    }
                }
                
                HStack(spacing: 4) {
                    // People icon with count
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 12))
                        .accessibilityLabel("\(headerOtherPeersCount) people")
                    Text("\(headerOtherPeersCount)")
                        .font(.system(size: 14, design: .default))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(headerCountColor)
                
                // QR moved to the PEOPLE header in the sidebar when on mesh channel
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                    showSidebar.toggle()
                }
            }
            .accessibilityLabel("Open chats and people")
        }
        .frame(height: headerHeight)
        .padding(.horizontal, 12)
        .background(backgroundColor.opacity(0.95))
    }
    
    private var privateChatDetailView: some View {
        VStack(spacing: 0) {
            bluetoothBannerIfNeeded
            messagesView(privatePeer: viewModel.selectedPrivateChatPeer, isAtBottom: $isAtBottomPrivate)
            Divider()
            inputView(for: viewModel.selectedPrivateChatPeer)
        }
        .coordinateSpace(name: "privateChatThrow")
        .overlay { sendThrowOverlay(isPrivate: true) }
        .background(backgroundColor)
        .foregroundStyle(textColor)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let peerID = viewModel.selectedPrivateChatPeer {
                // Add the centered content
                ToolbarItem(placement: .principal) {
                    privateHeaderPrincipal(for: peerID)
                }
                // Add the star button
                ToolbarItem(placement: .navigationBarTrailing) {
                    privateHeaderTrailing(for: peerID)
                }
            }
        }
        .onDisappear {
            focusedComposer = nil
        }
    }
    
    // MARK: - Private Chat Header Helpers
    
    // Helper to get the canonical Peer ID for header display
    private func getHeaderPeerID(for privatePeerID: String) -> String {
        if privatePeerID.count == 64 {
            // Map stable Noise key to short ID if we know it
            if let short = viewModel.getShortIDForNoiseKey(privatePeerID) { return short }
        }
        return privatePeerID
    }
    
    // Helper to resolve the display nickname
    private func getPeerNickname(for headerPeerID: String, peer: BitchatPeer?) -> String {
        // Try mesh/unified peer display
        if let name = peer?.displayName { return name }
        // Try direct mesh nickname (connected-only)
        if let name = viewModel.meshService.peerNickname(peerID: headerPeerID) { return name }
        // Try favorite nickname by stable Noise key
        if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: Data(hexString: headerPeerID) ?? Data()),
           !fav.peerNickname.isEmpty { return fav.peerNickname }
        // Fallback: resolve from persisted social identity via fingerprint mapping
        if headerPeerID.count == 16 {
            let candidates = SecureIdentityStateManager.shared.getCryptoIdentitiesByPeerIDPrefix(headerPeerID)
            if let id = candidates.first,
               let social = SecureIdentityStateManager.shared.getSocialIdentity(for: id.fingerprint) {
                if let pet = social.localPetname, !pet.isEmpty { return pet }
                if !social.claimedNickname.isEmpty { return social.claimedNickname }
            }
        } else if headerPeerID.count == 64, let keyData = Data(hexString: headerPeerID) {
            let fp = keyData.sha256Fingerprint()
            if let social = SecureIdentityStateManager.shared.getSocialIdentity(for: fp) {
                if let pet = social.localPetname, !pet.isEmpty { return pet }
                if !social.claimedNickname.isEmpty { return social.claimedNickname }
            }
        }
        return "Unknown"
    }
    
    // NEW: ToolbarItem for the center (principal) content
    @ViewBuilder
    private func privateHeaderPrincipal(for privatePeerID: String) -> some View {
        let headerPeerID = getHeaderPeerID(for: privatePeerID)
        let peer = viewModel.getPeer(byID: headerPeerID)
        let privatePeerNick = getPeerNickname(for: headerPeerID, peer: peer)
        let summary = viewModel.conversationSummary(for: privatePeerID)
        let connectivity = summary?.connectivity ?? viewModel.conversationConnectivity(for: privatePeerID)
        let statusPeerID: String = {
            if privatePeerID.count == 64, let short = viewModel.getShortIDForNoiseKey(privatePeerID) {
                return short
            }
            return headerPeerID
        }()
        let encryptionStatus = viewModel.getEncryptionStatus(for: statusPeerID)

        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: connectivity.systemImageName)
                    .font(.system(size: 13))
                    .foregroundStyle(textColor)
                    .accessibilityHidden(true)

                Text(privatePeerNick)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(textColor)

                if let icon = encryptionStatus.icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(encryptionStatus == .noiseVerified ? textColor :
                                            encryptionStatus == .noiseSecured ? textColor :
                                            Color.red)
                        .accessibilityLabel("Encryption status: \(encryptionStatus == .noiseVerified ? "verified" : encryptionStatus == .noiseSecured ? "secured" : "not encrypted")")
                }
            }

            Text(connectivity.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondaryTextColor)
        }
        .accessibilityLabel("Private chat with \(privatePeerNick), \(connectivity.statusText)")
    }
    
    // NEW: ToolbarItem for the trailing (star) button
    @ViewBuilder
    private func privateHeaderTrailing(for privatePeerID: String) -> some View {
        let headerPeerID = getHeaderPeerID(for: privatePeerID)
        
        Button(action: {
            viewModel.toggleFavorite(peerID: headerPeerID)
        }) {
            Image(systemName: viewModel.isFavorite(peerID: headerPeerID) ? "star.fill" : "star")
                .font(.system(size: 16))
                .foregroundStyle(viewModel.isFavorite(peerID: headerPeerID) ? Color.yellow : textColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isFavorite(peerID: headerPeerID) ? "Remove from favorites" : "Add to favorites")
        .accessibilityHint("Double tap to toggle favorite status")
    }

    private func syncComposerDraft(with peerID: String?) {
        messageText = peerID.map { viewModel.draftText(for: $0) } ?? nearbyDraft
    }

    @ViewBuilder
    private var bluetoothBannerIfNeeded: some View {
        if viewModel.bluetoothPresentation.shouldShowBanner {
            BluetoothStatusBanner(
                presentation: viewModel.bluetoothPresentation,
                onAction: openBluetoothPermissionSettings
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func openBluetoothPermissionSettings() {
        guard viewModel.bluetoothPresentation.canOpenSettings else { return }
#if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
#else
        viewModel.promptBluetoothRecovery()
#endif
    }

    @ViewBuilder
    private func emptyStateView(for privatePeer: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: privatePeer == nil ? "bubble.left.and.bubble.right" : "lock.circle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)

            if let privatePeer {
                Text("Start the conversation")
                    .font(.headline)
                Text("Direct messages stay on the nearby mesh. Photos only send here, and only while \(viewModel.resolveNickname(for: privatePeer)) is reachable.")
                    .font(.system(size: 14))
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nearby mesh chat")
                    .font(.headline)
                Text("Discovery happens nearby over Bluetooth mesh. Open a direct message for private conversations and attachments.")
                    .font(.system(size: 14))
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 320)
    }

    private var sidebarEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People show up when they’re nearby.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textColor)
            Text("Direct messages are mesh-only, and attachments only work inside those private chats.")
                .font(.system(size: 13))
                .foregroundStyle(secondaryTextColor)
        }
    }

    @ViewBuilder
    private func conversationRow(_ summary: PrivateConversationSummary) -> some View {
        Button {
            viewModel.startPrivateChat(with: summary.peerID)
            withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                showSidebar = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: summary.connectivity.systemImageName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(summary.hasUnread ? Color.accentColor : secondaryTextColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(summary.displayName)
                            .font(.system(size: 14, weight: summary.hasUnread ? .semibold : .medium, design: .monospaced))
                            .foregroundStyle(textColor)
                            .lineLimit(1)

                        if summary.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                        }

                        Spacer(minLength: 8)

                        if let timestamp = summary.timestamp {
                            Text(timestamp, format: .dateTime.hour().minute())
                                .font(.system(size: 11))
                                .foregroundStyle(secondaryTextColor)
                                .lineLimit(1)
                        }
                    }

                    Text(summary.previewText)
                        .font(.system(size: 12))
                        .foregroundStyle(summary.hasUnread ? textColor : secondaryTextColor)
                        .lineLimit(2)
                }

                if summary.hasUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(viewModel.selectedPrivateChatPeer == summary.peerID ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(summary.displayName), \(summary.connectivity.statusText)\(summary.hasUnread ? ", unread" : "")")
    }

    @ViewBuilder
    private func messageContextMenu(for message: BitchatMessage, privatePeer: String?) -> some View {
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContent.isEmpty {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                if #available(iOS 18, *) {
                    Label("Copy", systemImage: "document.on.document")
                } else {
                    Label("Copy", systemImage: "clipboard")
                }
            }
        }

        if let attachment = message.attachment {
            Button {
                presentAttachment(attachment)
            } label: {
                Label("Open Attachment", systemImage: attachment.kind == .image ? "photo" : "doc")
            }

            if FileManager.default.fileExists(atPath: attachment.localPath) {
                ShareLink(item: attachment.localURL) {
                    Label("Share Attachment", systemImage: "square.and.arrow.up")
                }
            }
        }

        if let privatePeer,
           message.sender == viewModel.nickname,
           case .failed = message.deliveryStatus {
            Button {
                viewModel.retryMessage(id: message.id, peerID: privatePeer)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }

        Button {
            messageDetailsItem = makeMessageDetailsItem(for: message, privatePeer: privatePeer)
        } label: {
            Label("Details", systemImage: "info.circle")
        }
    }

    private func presentAttachment(_ attachment: BitchatAttachment) {
        guard viewModel.openAttachment(attachment) != nil else {
            return
        }
        previewAttachment = PreviewAttachmentItem(attachment: attachment)
    }

    private func makeMessageDetailsItem(for message: BitchatMessage, privatePeer: String?) -> MessageDetailsItem {
        let routingStatus = privatePeer.map { viewModel.conversationConnectivity(for: $0).statusText } ?? "Nearby mesh timeline"
        let deliveryText = message.deliveryStatus?.displayText ?? "Delivered in nearby mesh timeline"
        return MessageDetailsItem(
            sender: message.sender,
            timestamp: message.timestamp,
            deliveryText: deliveryText,
            routingText: routingStatus,
            attachmentName: message.attachment?.fileName
        )
    }
}
