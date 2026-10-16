#if os(macOS)
import AppKit
import SwiftUI

/// ChatGPT / Apple Intelligence style agent composer. Floats above the desk on the
/// active screen. Option-Command-A toggles; Escape dismisses.
@MainActor
@Observable
final class AgentComposerController: NSObject, NSWindowDelegate {
    static let shared = AgentComposerController()

    private(set) var isOpen = false
    private var panel: NSPanel?
    private var escapeMonitor: Any?
    private var localKeyMonitor: Any?

    private let compactSize = NSSize(width: 680, height: 92)
    private let expandedSize = NSSize(width: 720, height: 420)

    func toggle(controller: ShowController) {
        AIAgentSession.shared.attach(controller)
        if isOpen { close() } else { open() }
    }

    func open() {
        ensurePanel()
        guard let panel else { return }
        placeOnActiveScreen(expanded: hasReplySurface)
        panel.makeKeyAndOrderFront(nil)
        FloatingPanelTransparency.clearChain(panel)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitors()
        isOpen = true
        NotificationCenter.default.post(name: .agentComposerDidOpen, object: nil)
    }

    func close() {
        removeKeyMonitors()
        panel?.orderOut(nil)
        isOpen = false
    }

    func resizeForContent(expanded: Bool) {
        guard let panel, isOpen else { return }
        let size = expanded ? expandedSize : compactSize
        var frame = panel.frame
        let bottom = frame.minY
        let midX = frame.midX
        frame.size = size
        frame.origin.x = midX - size.width / 2
        // Keep the input bar anchored near the lower third while growing upward.
        frame.origin.y = bottom
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 16), visible.maxX - size.width - 16)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 24), visible.maxY - size.height - 24)
        }
        panel.setFrame(frame, display: true, animate: true)
        FloatingPanelTransparency.clearChain(panel)
    }

    private var hasReplySurface: Bool {
        let session = AIAgentSession.shared
        return session.isRunning || session.draft != nil || !session.events.isEmpty
    }

    private func ensurePanel() {
        if panel != nil { return }
        let hosting = NSHostingController(rootView: AgentComposerRoot())
        let panel = AgentComposerPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 480, height: 80)
        panel.maxSize = NSSize(width: 900, height: 640)
        hosting.view.autoresizingMask = [.width, .height]
        FloatingPanelTransparency.apply(to: panel, hosting: hosting)
        self.panel = panel
    }

    private func placeOnActiveScreen(expanded: Bool) {
        guard let panel else { return }
        let screen = screenUnderMouse() ?? NSApp.keyWindow?.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = expanded ? expandedSize : compactSize
        let x = visible.midX - size.width / 2
        // Lower third of the active display (Spotlight-adjacent).
        let y = visible.minY + max(72, visible.height * 0.18)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private func installKeyMonitors() {
        removeKeyMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.close()
                return nil
            }
            return event
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Global Escape only while we are open; does not steal text input elsewhere.
            guard self?.isOpen == true, event.keyCode == 53 else { return }
            // Global monitors cannot swallow; close only if our panel is key.
            if self?.panel?.isKeyWindow == true {
                DispatchQueue.main.async { self?.close() }
            }
        }
    }

    private func removeKeyMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitors()
        isOpen = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let panel { FloatingPanelTransparency.clearChain(panel) }
    }
}

/// Panel that can become key so the composer text field accepts typing.
private final class AgentComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    static let agentComposerDidOpen = Notification.Name("proshow.agentComposer.didOpen")
}

// MARK: - Root view

private enum ComposerInk {
    static let graphite = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255)
    static let surface = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1F / 255)
    static let raised = Color(red: 0x25 / 255, green: 0x25 / 255, blue: 0x2A / 255)
    static let accent = Color(red: 0x6B / 255, green: 0x9F / 255, blue: 0xE0 / 255)
}

private struct AgentComposerRoot: View {
    @Bindable private var session = AIAgentSession.shared
    @State private var prompt = ""
    @State private var showKeyField = false
    @State private var keyEntry = ""
    @State private var applied: Int?
    @FocusState private var inputFocused: Bool

    private var showReply: Bool {
        session.isRunning || session.draft != nil || !session.events.isEmpty
    }

    var body: some View {
        DeskGlassGroup(spacing: 12) {
            VStack(spacing: 0) {
                if showReply {
                    replyLayer
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                inputBar
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .deskChromeGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
            .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .foregroundStyle(.white.opacity(0.92))
        .onAppear {
            inputFocused = true
            AgentComposerController.shared.resizeForContent(expanded: showReply)
        }
        .onChange(of: showReply) { _, expanded in
            AgentComposerController.shared.resizeForContent(expanded: expanded)
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentComposerDidOpen)) { _ in
            inputFocused = true
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showReply)
    }

    private var replyLayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Agent")
                    .font(.system(size: 12, weight: .semibold))
                statusChip
                Spacer()
                if session.isRunning {
                    Button("Stop") { session.cancel() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ComposerInk.accent)
                }
                Button {
                    session.reset()
                    applied = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("New session")
            }
            .padding(.horizontal, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { row in
                            ComposerRowView(row: row).id(row.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ComposerInk.surface.opacity(0.55))
                )
                .onChange(of: session.events.count) { _, _ in
                    if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if let draft = session.draft {
                draftCard(draft)
            }
            if let applied {
                Text(applied > 0 ? "Added \(applied) slides to AI Draft." : "Nothing applied.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showKeyField || (!session.keyConnected && session.provider == .xai) {
                keyRow
            }
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ComposerInk.accent)
                        TextField("Ask ProShow to design slides…", text: $prompt, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .lineLimit(1...5)
                            .focused($inputFocused)
                            .onSubmit(send)
                        if !session.deskUpdate.isEmpty {
                            Text("Desk note")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(ComposerInk.accent.opacity(0.25)))
                        }
                    }
                    TextField("Desk update for next turn (optional)", text: $session.deskUpdate)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(ComposerInk.raised.opacity(0.72))
                )

                VStack(spacing: 6) {
                    Picker("", selection: $session.provider) {
                        ForEach(AIAgentSession.ProviderChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)

                    if session.isRunning {
                        Button("Stop") { session.cancel() }
                            .buttonStyle(.bordered)
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(canSend ? ComposerInk.accent : .white.opacity(0.25))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Send")
                    }

                    Button { showKeyField.toggle() } label: {
                        Image(systemName: "key")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("xAI key")
                }
            }
            HStack {
                statusChip
                Spacer()
                Text("⌥⌘A hide · Esc dismiss")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 4)
        }
    }

    private var keyRow: some View {
        HStack {
            SecureField("xAI API key", text: $keyEntry)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                if session.saveKey(keyEntry) {
                    keyEntry = ""
                    showKeyField = false
                }
            }
            .disabled(keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            if session.keyConnected {
                Button("Remove") { session.clearKey() }
            }
        }
        .font(.system(size: 12))
    }

    private var statusChip: some View {
        Label(
            session.keyConnected ? "xAI Connected" : "xAI Missing",
            systemImage: session.keyConnected ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(session.keyConnected ? ComposerInk.accent : .white.opacity(0.45))
    }

    private func draftCard(_ draft: ComposePatch) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Draft ready · \(draft.slides.count) slides")
                    .font(.system(size: 13, weight: .semibold))
                Text(draft.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
            Spacer()
            Button("Discard") { session.discardDraft() }
            Button("Apply to AI Draft") { applied = session.applyDraft() }
                .buttonStyle(.borderedProminent)
                .tint(ComposerInk.accent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ComposerInk.raised.opacity(0.85)))
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isRunning
    }

    private func send() {
        guard canSend else { return }
        if !ProShowFeatureFlags.aiComposeV1 {
            ProShowFeatureFlags.aiComposeV1 = true
        }
        applied = nil
        session.send(prompt)
        prompt = ""
    }

    private var rows: [AgentRow] {
        var out: [AgentRow] = []
        for event in session.events {
            if case let .delta(text) = event.kind, let last = out.last, last.kind == .text {
                out[out.count - 1].text += text
                continue
            }
            out.append(AgentRow(event: event))
        }
        return out
    }
}

private struct ComposerRowView: View {
    let row: AgentRow

    var body: some View {
        switch row.kind {
        case .text:
            Text(row.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
        default:
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(row.text)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var color: Color {
        switch row.kind {
        case .tool: ComposerInk.accent
        case .warn: .orange
        case .error: .red
        default: .white.opacity(0.4)
        }
    }
}
#endif
