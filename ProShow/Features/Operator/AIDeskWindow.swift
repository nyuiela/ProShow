#if os(macOS)
import AppKit
import SwiftUI

/// Floating AI desk: prompt, desk update, live agent stream, draft review. Apply is operator only.
@MainActor
final class AIDeskWindowController: NSObject, NSWindowDelegate {
    static let shared = AIDeskWindowController()
    private var panel: NSPanel?

    func toggle(controller: ShowController) {
        AIAgentSession.shared.attach(controller)
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        if panel == nil {
            let hosting = NSHostingController(rootView: AIDeskView())
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "AI Desk"
            panel.titlebarAppearsTransparent = true
            panel.contentViewController = hosting
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.sharingType = .none
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.minSize = NSSize(width: 420, height: 420)
            panel.delegate = self
            FloatingPanelTransparency.apply(to: panel, hosting: hosting)
            panel.center()
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
        if let p = panel as NSWindow? { FloatingPanelTransparency.clearChain(p) }
    }
}

private enum DeskInk {
    static let graphite = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255)
    static let surface = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1F / 255)
    static let raised = Color(red: 0x25 / 255, green: 0x25 / 255, blue: 0x2A / 255)
    static let accent = Color(red: 0x6B / 255, green: 0x9F / 255, blue: 0xE0 / 255)
}

struct AIDeskView: View {
    @Bindable private var session = AIAgentSession.shared
    @State private var prompt = ""
    @State private var keyEntry = ""
    @State private var showKeyField = false
    @State private var appliedLabel: String?
    @State private var flagOn = ProShowFeatureFlags.aiComposeV1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !flagOn {
                HStack {
                    Text("AI compose is off.").font(.system(size: 12))
                    Button("Turn on") { ProShowFeatureFlags.aiComposeV1 = true; flagOn = true }
                }
            }
            if showKeyField || !session.keyConnected && session.provider == .xai { keyRow }
            stream
            if let draft = session.draft { draftCard(draft) }
            inputs
        }
        .padding(14)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(DeskInk.graphite.opacity(0.94)))
        .foregroundStyle(.white.opacity(0.92))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AI Desk").font(.system(size: 15, weight: .semibold))
            Picker("", selection: $session.provider) {
                ForEach(AIAgentSession.ProviderChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            Spacer()
            Label(session.keyConnected ? "xAI Connected" : "xAI Missing", systemImage: session.keyConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(session.keyConnected ? DeskInk.accent : .white.opacity(0.5))
            Button { showKeyField.toggle() } label: { Image(systemName: "key") }
                .buttonStyle(.borderless)
                .help("xAI key")
            Button { session.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("New session")
        }
    }

    private var keyRow: some View {
        HStack {
            SecureField("xAI API key", text: $keyEntry)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                if session.saveKey(keyEntry) { keyEntry = ""; showKeyField = false }
            }
            .disabled(keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            if session.keyConnected {
                Button("Remove") { session.clearKey() }
            }
        }
        .font(.system(size: 12))
    }

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        AgentRowView(row: row).id(row.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(DeskInk.surface))
            .onChange(of: session.events.count) { _, _ in
                if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func draftCard(_ draft: ComposePatch) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Draft: \(draft.slides.count) slides").font(.system(size: 13, weight: .semibold))
                Text(draft.summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
            Spacer()
            Button("Discard") { session.discardDraft() }
            Button("Apply to AI Draft") {
                    if let placement = session.applyDraft() {
                        appliedLabel = placement.label
                    } else {
                        appliedLabel = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DeskInk.accent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(DeskInk.raised))
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Desk update for the next turn (optional)", text: $session.deskUpdate)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            HStack {
                TextField("Describe the slides you want", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                if session.isRunning {
                    Button("Stop") { session.cancel() }
                } else {
                    Button("Send", action: send)
                        .buttonStyle(.borderedProminent)
                        .tint(DeskInk.accent)
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let appliedLabel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appliedLabel).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                    if let placement = session.lastPlacement {
                        HStack(spacing: 8) {
                            Button("Open") { session.openPlacement(placement) }
                            Button("Copy link") {
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(placement.deepLink, forType: .string)
                                #endif
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                }
            }
        }
    }

    private func send() {
        appliedLabel = nil
        session.send(prompt)
        prompt = ""
    }

    /// Collapse consecutive deltas into one text row.
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

struct AgentRow: Identifiable {
    enum Kind { case text, tool, warn, info, error }
    let id: Int
    var kind: Kind
    var text: String

    init(event: AgentEvent) {
        id = event.seq
        switch event.kind {
        case .turnStarted: kind = .info; text = "Turn started"
        case let .delta(t): kind = .text; text = t
        case let .toolCall(n, _): kind = .tool; text = "Calling \(n)"
        case let .toolResult(n, _, ok, s): kind = ok ? .tool : .warn; text = "\(n): \(s)"
        case let .confirmRequired(t, r): kind = .warn; text = "Needs you: \(t). \(r)"
        case let .draftReady(n, _): kind = .info; text = "Draft ready: \(n) slides"
        case let .slidesCreated(_, _, label, link, _): kind = .info; text = "\(label) · \(link)"
        case let .contextPackUpdated(v, p): kind = .info; text = "Context updated \(p) to \(v)"
        case .done: kind = .info; text = "Done"
        case .cancelled: kind = .warn; text = "Stopped"
        case let .error(m): kind = .error; text = m
        }
    }
}

private struct AgentRowView: View {
    let row: AgentRow

    var body: some View {
        switch row.kind {
        case .text:
            Text(row.text).font(.system(size: 13)).textSelection(.enabled)
        default:
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(row.text).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var color: Color {
        switch row.kind {
        case .tool: Color(red: 0x6B / 255, green: 0x9F / 255, blue: 0xE0 / 255)
        case .warn: .orange
        case .error: .red
        default: .white.opacity(0.4)
        }
    }
}
#endif
