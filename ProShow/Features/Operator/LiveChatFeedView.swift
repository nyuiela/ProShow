import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension Notification.Name {
    static let proShowOpenChatWindow = Notification.Name("proshow.open-chat-window")
    static let proShowCloseChatWindow = Notification.Name("proshow.close-chat-window")
}

/// Whether the chat window is open. App level so it survives project switches,
/// which rebuild the ShowController while the window stays open.
@MainActor @Observable
final class LiveChatWindowState {
    static let shared = LiveChatWindowState()
    var isDetached = false
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

    @ViewBuilder
    private var header: some View {
        let row = HStack(spacing: 6) {
            #if os(macOS)
            if style == .window { LiveChatWindowTrafficLights() }
            #endif
            DeskSectionTitle(title: "Live chat stream")
            detachButton
            if let chatStream {
                moreButton(chatStream)
            }
            if style == .window { Spacer(minLength: 0) }
        }
        #if os(macOS)
        if style == .window {
            row.background { PromptWindowDragHandle { LiveChatGlassController.shared.saveFrame() } }
        } else {
            row
        }
        #else
        row
        #endif
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

#if os(macOS)
/// Key-capable so the reply box can type. Same glass and chrome as the studio panel.
final class LiveChatGlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Detached live chat. Liquid Glass panel, same rules as the studio window:
/// borderless, clear, floating, excluded from capture. Frame is remembered per
/// display and restored on the screen it was left on.
@MainActor
@Observable
final class LiveChatGlassController: NSObject, NSWindowDelegate {
    static let shared = LiveChatGlassController()
    static let windowTitle = "Live Chat"
    static let frameKey = "proshow.liveChat.windowFrame"
    static let minSize = NSSize(width: 320, height: 360)

    weak var controller: ShowController?
    private(set) var isOpen = false
    @ObservationIgnored private var panel: NSPanel?

    var panelFrame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    func attach(_ controller: ShowController) { self.controller = controller }

    func open() {
        ensurePanel()
        guard let panel else { return }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        if !panel.isVisible {
            panel.setFrame(Self.resolvedFrame(remembered: Self.rememberedFrame()), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        FloatingPanelTransparency.clearChain(panel)
        NSApp.activate(ignoringOtherApps: true)
        isOpen = true
        LiveChatWindowState.shared.isDetached = true
    }

    func close() {
        saveFrame()
        panel?.orderOut(nil)
        isOpen = false
        LiveChatWindowState.shared.isDetached = false
    }

    func miniaturizeWindow() {
        guard let panel else { return }
        panel.styleMask.insert(.miniaturizable)
        panel.miniaturize(nil)
    }

    func saveFrame() {
        guard let panel, panel.isVisible, !panel.isMiniaturized else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    static func rememberedFrame() -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let rect = NSRectFromString(raw)
        return rect.width >= minSize.width && rect.height >= minSize.height ? rect : nil
    }

    /// Remembered frame on whichever display still shows it, else beside the main window.
    static func resolvedFrame(remembered: NSRect?) -> NSRect {
        if let remembered,
           let screen = NSScreen.screens.max(by: {
               $0.visibleFrame.intersection(remembered).width * $0.visibleFrame.intersection(remembered).height
                   < $1.visibleFrame.intersection(remembered).width * $1.visibleFrame.intersection(remembered).height
           }),
           screen.visibleFrame.intersects(remembered) {
            let visible = screen.visibleFrame
            var frame = remembered
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            return frame
        }
        let screen = NSApp.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 380, height: min(640, visible.height - 40))
        return NSRect(x: visible.maxX - size.width - 24, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowWillClose(_ notification: Notification) {
        isOpen = false
        LiveChatWindowState.shared.isDetached = false
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingController(rootView: LiveChatGlassRoot())
        let panel = LiveChatGlassPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 380, height: 640)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = Self.windowTitle
        panel.identifier = NSUserInterfaceItemIdentifier("proshow-live-chat")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = Self.minSize
        panel.maxSize = NSSize(width: 2000, height: 2400)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        hosting.view.autoresizingMask = [.width, .height]
        FloatingPanelTransparency.apply(to: panel, hosting: hosting)
        if let hostingView = hosting.view as? NSHostingView<LiveChatGlassRoot> {
            hostingView.safeAreaRegions = []
        }
        self.panel = panel
    }
}

struct LiveChatWindowTrafficLights: View {
    var body: some View {
        HStack(spacing: 6) {
            StudioTrafficLight(color: Color(red: 1, green: 0.37, blue: 0.34), glyph: "xmark", label: "Reattach chat") {
                LiveChatGlassController.shared.close()
            }
            StudioTrafficLight(color: Color(red: 1, green: 0.74, blue: 0.18), glyph: "minus", label: "Minimize chat window") {
                LiveChatGlassController.shared.miniaturizeWindow()
            }
        }
        .padding(.trailing, 2)
        .focusEffectDisabled()
    }
}

private struct LiveChatGlassRoot: View {
    @Bindable private var chrome = LiveChatGlassController.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if let controller = chrome.controller {
                LiveChatFeedView(controller: controller, style: .window)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            } else {
                Text("No project open")
                    .font(DeskType.body)
                    .foregroundStyle(RundownChrome.mutedLabel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .padding(6)
        .promptGlass(cornerRadius: 28, solid: reduceTransparency)
        .overlay { StudioGlassResizeRim() }
    }
}
#endif
