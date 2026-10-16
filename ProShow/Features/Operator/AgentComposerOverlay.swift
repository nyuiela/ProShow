#if os(macOS)
import AppKit
import SwiftUI

/// iOS 27 Siri / Search-or-Ask style composer. Idle = glass capsule only.
/// Option-Command-A toggles; Escape dismisses. Agent settings live in Settings > AI.
@MainActor
@Observable
final class AgentComposerController: NSObject, NSWindowDelegate {
    static let shared = AgentComposerController()

    private(set) var isOpen = false
    private var panel: NSPanel?
    private var escapeMonitor: Any?
    private var localKeyMonitor: Any?

    private let pillSize = NSSize(width: 560, height: 56)
    private let expandedSize = NSSize(width: 600, height: 360)

    func toggle(controller: ShowController) {
        AIAgentSession.shared.attach(controller)
        if isOpen { close() } else { open() }
    }

    func open() {
        ensurePanel()
        guard let panel else { return }
        placeOnActiveScreen(expanded: false)
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
        let size = expanded ? expandedSize : pillSize
        var frame = panel.frame
        let midX = frame.midX
        let bottom = frame.minY
        frame.size = size
        frame.origin.x = midX - size.width / 2
        frame.origin.y = bottom
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 16), visible.maxX - size.width - 16)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 24), visible.maxY - size.height - 24)
        }
        panel.setFrame(frame, display: true, animate: true)
        FloatingPanelTransparency.clearChain(panel)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let hosting = NSHostingController(rootView: AgentComposerRoot())
        let panel = AgentComposerPanel(
            contentRect: NSRect(origin: .zero, size: pillSize),
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
        panel.minSize = NSSize(width: 420, height: 52)
        panel.maxSize = NSSize(width: 720, height: 520)
        hosting.view.autoresizingMask = [.width, .height]
        FloatingPanelTransparency.apply(to: panel, hosting: hosting)
        self.panel = panel
    }

    private func placeOnActiveScreen(expanded: Bool) {
        guard let panel else { return }
        let screen = screenUnderMouse() ?? NSApp.keyWindow?.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = expanded ? expandedSize : pillSize
        let x = visible.midX - size.width / 2
        let y = visible.minY + max(80, visible.height * 0.22)
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
            // Return without Shift → send. Shift+Return → newline (pass through).
            if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
                NotificationCenter.default.post(name: .agentComposerSubmit, object: nil)
                return nil
            }
            return event
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.isOpen == true, event.keyCode == 53 else { return }
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

private final class AgentComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    static let agentComposerDidOpen = Notification.Name("proshow.agentComposer.didOpen")
    static let agentComposerSubmit = Notification.Name("proshow.agentComposer.submit")
}

// MARK: - Root

private enum ComposerInk {
    static let accent = Color(red: 0x6B / 255, green: 0x9F / 255, blue: 0xE0 / 255)
    static let surface = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1F / 255)
    static let raised = Color(red: 0x25 / 255, green: 0x25 / 255, blue: 0x2A / 255)
}

private struct AgentComposerRoot: View {
    @Bindable private var session = AIAgentSession.shared
    @State private var prompt = ""
    @State private var applied: Int?
    @State private var baselineSeq = 0
    @FocusState private var inputFocused: Bool

    /// Expand only for this open session's activity or a staged draft.
    private var showReply: Bool {
        if session.isRunning || session.draft != nil { return true }
        return session.events.contains { $0.seq > baselineSeq }
    }

    var body: some View {
        DeskGlassGroup(spacing: 10) {
            VStack(spacing: 8) {
                if showReply {
                    replyLayer
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                searchPill
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .foregroundStyle(.white.opacity(0.92))
        .onAppear {
            baselineSeq = session.events.last?.seq ?? 0
            inputFocused = true
            AgentComposerController.shared.resizeForContent(expanded: showReply)
        }
        .onChange(of: showReply) { _, expanded in
            AgentComposerController.shared.resizeForContent(expanded: expanded)
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentComposerDidOpen)) { _ in
            baselineSeq = session.events.last?.seq ?? 0
            prompt = ""
            applied = nil
            inputFocused = true
            AgentComposerController.shared.resizeForContent(expanded: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentComposerSubmit)) { _ in
            send()
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: showReply)
    }

    // MARK: Idle pill (reference)

    private var searchPill: some View {
        HStack(spacing: 10) {
            glowingCaret
            TextField("Search or Ask", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .lineLimit(1...4)
                .focused($inputFocused)
                .foregroundStyle(.white.opacity(0.92))
                // Enter is handled by the key monitor so Shift+Enter can newline.
                .onSubmit { /* swallowed by monitor; keep for accessibility */ }

            if session.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
                Button("Stop") { session.cancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ComposerInk.accent)
            }

            Button(action: micStub) {
                Image(systemName: "mic")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Voice coming later")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .deskChromeGlass(in: Capsule(style: .continuous), interactive: true)
        .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
    }

    private var glowingCaret: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.45, green: 0.75, blue: 1.0),
                        Color(red: 1.0, green: 0.85, blue: 0.35),
                        Color(red: 0.95, green: 0.95, blue: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 2.5, height: 22)
            .shadow(color: Color(red: 0.45, green: 0.75, blue: 1.0).opacity(0.85), radius: 4)
            .shadow(color: Color(red: 1.0, green: 0.85, blue: 0.35).opacity(0.55), radius: 6)
            .opacity(inputFocused && prompt.isEmpty ? 1 : (inputFocused ? 0.35 : 0.2))
            .accessibilityHidden(true)
    }

    // MARK: Thin reply layer

    private var replyLayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { row in
                            ComposerRowView(row: row).id(row.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: session.events.count) { _, _ in
                    if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if let draft = session.draft {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Draft · \(draft.slides.count) slides")
                            .font(.system(size: 12, weight: .semibold))
                        Text(draft.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Discard") { session.discardDraft() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                    Button("Apply") { applied = session.applyDraft() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ComposerInk.accent)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            if let applied {
                Text(applied > 0 ? "Added \(applied) to AI Draft." : "Nothing applied.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .deskChromeGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }

    private func micStub() {}

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
        for event in session.events where event.seq > baselineSeq {
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
                Circle().fill(color).frame(width: 5, height: 5)
                Text(row.text)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var color: Color {
        switch row.kind {
        case .tool: ComposerInk.accent
        case .warn: .orange
        case .error: .red
        default: .white.opacity(0.35)
        }
    }
}
#endif
