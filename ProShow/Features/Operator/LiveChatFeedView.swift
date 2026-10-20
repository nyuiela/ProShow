import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension Notification.Name {
    static let proShowOpenChatWindow = Notification.Name("proshow.open-chat-window")
    static let proShowCloseChatWindow = Notification.Name("proshow.close-chat-window")
}

/// Live chat feed, moderation and reply box. Used in the Backstage panel and in
/// the detached chat window. Read only unless the operator presses Send or Return.
struct LiveChatFeedView: View {
    enum Style { case panel, window }

    @Bindable var controller: ShowController
    var style: Style

    @State private var youtubeChatInput = ""

    private var chatStream: LiveChatStreamManager? { controller.chatStream }
    private var hub: ChatIngestHub? { controller.chatIngest }
    private var hubEnabled: Bool { hub?.isEnabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.sm) {
            header
            if let hub, hubEnabled, hub.youtubeState != .idle {
                youtubeStatusLine(hub)
            }
            if style == .panel, controller.isChatDetached {
                Text("Open in its own window")
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
            } else if let chatStream {
                if let active = chatStream.activeOverlay {
                    activeOverlayCard(active, chatStream: chatStream)
                }
                if style == .window {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(chatStream.inbox.prefix(200), id: \.id) { message in
                                chatMessageRow(message, chatStream: chatStream)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ForEach(chatStream.inbox.prefix(12), id: \.id) { message in
                        chatMessageRow(message, chatStream: chatStream)
                    }
                }
                if let hub, hubEnabled {
                    ChatReplyComposer(hub: hub)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            DeskSectionTitle(title: "Live chat stream")
            detachButton
            if let chatStream {
                moreButton(chatStream)
            }
        }
    }

    private var detachButton: some View {
        let detached = controller.isChatDetached
        return Button {
            #if os(macOS)
            NotificationCenter.default.post(name: detached ? .proShowCloseChatWindow : .proShowOpenChatWindow, object: nil)
            #endif
        } label: {
            Image(systemName: detached ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.subtitle)
        }
        .buttonStyle(.borderless)
        .help(detached ? "Reattach chat" : "Open chat in its own window")
        .accessibilityLabel(detached ? "Reattach chat" : "Detach chat")
    }

    private func moreButton(_ chatStream: LiveChatStreamManager) -> some View {
        Button {
            hub?.moreMenuOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                Text("More")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(DeskType.micro)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .popover(isPresented: Binding(
            get: { (hub?.moreMenuOpen ?? false) && (style == .window) == controller.isChatDetached },
            set: { hub?.moreMenuOpen = $0 }
        ), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let hub, hubEnabled {
                    youtubeChatRow(hub)
                    Divider()
                }
                chatSourceToggles(chatStream)
            }
            .padding(12)
            .frame(width: 290)
        }
    }

    private func chatSourceToggles(_ chatStream: LiveChatStreamManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chatSourcePlatforms, id: \.self) { platform in
                Toggle(platform.displayTitle, isOn: Binding(
                    get: { chatStream.enabledSources.contains(platform) },
                    set: { chatStream.setSourceEnabled(platform, enabled: $0) }
                ))
                .font(DeskType.micro)
            }
        }
    }

    private var chatSourcePlatforms: [ChatPlatform] {
        var list: [ChatPlatform] = [.zoom, .googleMeet, .backstage]
        if hubEnabled { list.insert(.youtube, at: 0) }
        return list
    }

    private func youtubeChatRow(_ hub: ChatIngestHub) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("YouTube URL or video ID", text: $youtubeChatInput)
                    .textFieldStyle(.roundedBorder)
                    .font(DeskType.micro)
                    .disabled(hub.youtubeState.isActive)
                if hub.youtubeState.isActive {
                    Button("Stop") { hub.stopYouTube() }
                        .controlSize(.small)
                } else {
                    Button("Connect") {
                        let input = youtubeChatInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        hub.connectYouTube(input.isEmpty ? .autoActive : .video(input))
                    }
                    .controlSize(.small)
                }
            }
            youtubeStatusLine(hub)
        }
    }

    private func youtubeStatusLine(_ hub: ChatIngestHub) -> some View {
        HStack(spacing: 6) {
            Text("YouTube: \(hub.youtubeState.label)")
            if let title = hub.youtubeTitle, !title.isEmpty {
                Text(title).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(DeskType.micro)
        .foregroundStyle(ShowSidebarPalette.subtitle)
        .help("\(hub.youtubeMessageCount) messages. Quota today about \(hub.youtubeDayUnits) of \(YouTubeQuotaLedger.dailyBudget) units")
    }

    // MARK: Rows

    private func chatMessageRow(_ message: LiveChatMessage, chatStream: LiveChatStreamManager) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                ChatAvatarView(url: message.senderAvatarUrl, name: message.senderName, size: 22)
                Text(message.senderName)
                    .font(DeskType.bodyEmph)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(message.platformSource)
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 4)
                if let hub, hubEnabled {
                    rowIcon(
                        hub.replyTarget?.id == message.id ? "arrowshape.turn.up.left.fill" : "arrowshape.turn.up.left",
                        help: "Reply",
                        on: hub.replyTarget?.id == message.id
                    ) {
                        hub.setReplyTarget(hub.replyTarget?.id == message.id ? nil : message)
                    }
                }
                rowIcon(message.isFeaturedOnScreen ? "tv.fill" : "tv", help: "Display on screen", on: message.isFeaturedOnScreen) {
                    controller.triggerChatOverlay(message)
                }
                rowIcon(message.isStarred ? "star.fill" : "star", help: message.isStarred ? "Unstar" : "Star", on: message.isStarred) {
                    chatStream.toggleStar(id: message.id)
                }
            }
            Text(message.messageText)
                .font(DeskType.body)
                .foregroundStyle(ShowSidebarPalette.title)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Hide") {
                if chatStream.hide(id: message.id) { controller.dismissChatOverlay() }
            }
            if message.authorID != nil {
                Button("Block \(message.senderName)") {
                    if chatStream.blockAuthor(of: message.id) { controller.dismissChatOverlay() }
                }
            }
        }
    }

    private func rowIcon(_ symbol: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(on ? ProShowTheme.statusOn : ShowSidebarPalette.subtitle)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private func activeOverlayCard(_ message: LiveChatMessage, chatStream: LiveChatStreamManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On-air overlay")
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.liveRed)
            Text("\(message.senderName): \(message.messageText)")
                .font(DeskType.body)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Button("Dismiss") { controller.dismissChatOverlay() }
                    .controlSize(.small)
                Stepper("Auto-clear \(chatStream.autoClearSeconds)s", value: Binding(
                    get: { chatStream.autoClearSeconds },
                    set: { chatStream.autoClearSeconds = $0 }
                ), in: 0...120, step: 5)
                .font(DeskType.micro)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            InspectorSelectionRibbon(selected: true, color: ProShowTheme.liveRed)
        }
    }
}

/// Reply pill, styled like the Ask AI composer. Return or the send button posts;
/// nothing else does.
struct ChatReplyComposer: View {
    @Bindable var hub: ChatIngestHub

    private var canSend: Bool {
        hub.replyBlockedReason == nil && !hub.replySending
            && YouTubeChatAPI.replyText(hub.replyDraft) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let target = hub.replyTarget {
                    HStack(spacing: 3) {
                        Text(target.senderName.hasPrefix("@") ? target.senderName : "@\(target.senderName)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Button {
                            hub.setReplyTarget(nil)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help("Clear reply")
                        .accessibilityLabel("Clear reply")
                    }
                    .font(DeskType.micro)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.10), in: Capsule(style: .continuous))
                    .frame(maxWidth: 130, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                }
                TextField("Reply", text: $hub.replyDraft)
                    .textFieldStyle(.plain)
                    .font(DeskType.body)
                    .disabled(hub.replySending)
                    .onSubmit(send)
                if hub.replySending {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(canSend ? ProShowTheme.statusOn : ShowSidebarPalette.subtitle.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
                .accessibilityLabel("Send reply")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .deskChromeGlass(in: Capsule(style: .continuous), interactive: false)
            if let reason = hub.replyError ?? (hub.replyDraft.isEmpty ? nil : hub.replyBlockedReason) {
                Text(reason)
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .padding(.leading, 12)
            }
        }
    }

    private func send() {
        guard canSend else {
            if hub.replyError == nil { hub.replyError = hub.replyBlockedReason }
            return
        }
        Task { await hub.sendReply() }
    }
}

/// Detached chat window body.
struct LiveChatWindowView: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LiveChatFeedView(controller: controller, style: .window)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ShowSidebarPalette.selection(scheme))
    }
}
