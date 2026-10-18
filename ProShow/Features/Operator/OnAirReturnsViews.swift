import SwiftUI

/// Returns line: what the room hears, push to talk, per-guest feed. Terse; details in tooltips.
struct OnAirReturnsRow: View {
    @Bindable var controller: ShowController
    @Binding var showRouting: Bool
    @Bindable private var controls = OnAirAudioControls.shared
    @State private var pressing = false

    private var roomOn: Bool { controller.liveKitDesk.hasStartedConnection }

    var body: some View {
        HStack(spacing: 6) {
            Text("Returns")
                .font(DeskType.micro.weight(.semibold))
                .foregroundStyle(ShowSidebarPalette.title)
            Text(controller.onAirReturnsLine)
                .font(DeskType.micro)
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Mix: program without guests. Full: everything, echo risk. Intercom: talkback only.")
            Spacer(minLength: 2)
            if roomOn {
                talkButton
                feedMenu
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var talkButton: some View {
        let active = controls.talkActive
        return HStack(spacing: 3) {
            Image(systemName: active ? "mic.fill" : "mic")
                .font(.system(size: 9, weight: .bold))
            Text(talkTitle)
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(active ? Color.white : ShowSidebarPalette.title)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(active ? ProShowTheme.statusOn : ShowSidebarPalette.subtitle.opacity(0.18), in: Capsule())
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    controller.startTalkback()
                }
                .onEnded { _ in
                    pressing = false
                    controller.stopTalkback()
                }
        )
        .help("Hold to talk to guests (or hold T). Never on program.")
        .accessibilityLabel("Talk to \(talkTargetName)")
        .accessibilityAddTraits(.isButton)
    }

    private var talkTitle: String {
        controls.talkTarget == nil ? "TALK" : "TALK 1"
    }

    private var talkTargetName: String {
        guard let target = controls.talkTarget else { return "all guests" }
        return controller.liveKitDesk.guests.first { $0.identity == target }?.name ?? target
    }

    private var feedMenu: some View {
        Menu { let _ = MenuRenderProbe.hit("OnAirReturnsViews:73:OnAirReturnsRow.feedMenu");
            Section("Talk to") {
                Button { controls.talkTarget = nil } label: { check("All guests", controls.talkTarget == nil) }
                ForEach(controller.liveKitDesk.guests) { guest in
                    Button { controls.talkTarget = guest.identity } label: { check(guest.name, controls.talkTarget == guest.identity) }
                }
            }
            Menu("Talk Mic") { let _ = MenuRenderProbe.hit("OnAirReturnsViews:80:OnAirReturnsRow.feedMenu");
                Button { controls.talkDeviceID = nil } label: { check("System Default", controls.talkDeviceID == nil) }
                ForEach(TalkbackEngine.microphones(), id: \.id) { mic in
                    Button { controls.talkDeviceID = mic.id } label: { check(mic.name, controls.talkDeviceID == mic.id) }
                }
            }
            Section("Feed") {
                modePicker(title: "All Guests", identity: nil)
                ForEach(controller.liveKitDesk.guests) { guest in
                    modePicker(title: guest.name, identity: guest.identity)
                }
            }
            Button("Routing", systemImage: "square.grid.3x3") { showRouting = true }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.symbol)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Return feeds")
        .accessibilityLabel("Return feeds")
    }

    private func modePicker(title: String, identity: String?) -> some View {
        Picker(title, selection: Binding(
            get: { identity.map { controller.returnMode(for: $0) } ?? controller.backstage.returnFeedMode },
            set: { controller.setReturnMode(identity: identity, mode: $0) }
        )) {
            Text("Mix").tag(BackstageReturnFeedMode.programMixMinus)
            Text("Full").tag(BackstageReturnFeedMode.programFull)
            Text("Intercom").tag(BackstageReturnFeedMode.intercomOnly)
        }
    }

    @ViewBuilder
    private func check(_ title: String, _ selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// Sources x buses, read-only.
struct OnAirRoutingSheet: View {
    @Bindable var controller: ShowController
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [[String: Any]] = []
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private let buses: [(key: String, title: String)] = [
        ("program", "Program"), ("phone", "Phone"), ("return_mix", "Mix"),
        ("return_full", "Full"), ("intercom", "Intercom"), ("monitor", "Monitor"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Routing").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Source").font(DeskType.micro.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(buses, id: \.key) { bus in
                        Text(bus.title).font(DeskType.micro.weight(.bold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row["name"] as? String ?? "").font(DeskType.meta).lineLimit(1)
                        ForEach(buses, id: \.key) { bus in
                            cell(row[bus.key] as? String ?? "off")
                                .gridColumnAlignment(.center)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520)
        .onAppear { rows = controller.onAirRouting() }
        .onReceive(timer) { _ in rows = controller.onAirRouting() }
    }

    @ViewBuilder
    private func cell(_ value: String) -> some View {
        switch value {
        case "on":
            Image(systemName: "circle.fill").foregroundStyle(ProShowTheme.liveRed).help("On")
        case "direct":
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary).help("Direct between guests")
        case "ready":
            Image(systemName: "circle").foregroundStyle(ProShowTheme.statusOn).help("Push to talk")
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary).help("Off")
        }
    }
}
