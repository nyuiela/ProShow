import SwiftUI

/// On-Air Audio: what the stream hears, what it does not and why, with per-row controls.
struct OnAirAudioSectionView: View {
    @Bindable var controller: ShowController
    @Bindable private var monitor = OnAirAudioMonitor.shared
    @AppStorage("proshow.inspector.onAirAudioExpanded") private var expanded = true
    @Bindable private var controls = OnAirAudioControls.shared
    @State private var pendingIsolate: OnAirAudioSource?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content
                .padding(.top, 6)
        } label: {
            header
        }
        .onAppear { monitor.attach(controller) }
        .sheet(isPresented: $controls.routingSheetOpen) { OnAirRoutingSheet(controller: controller) }
        .alert(
            "Isolate \(pendingIsolate?.name ?? "")?",
            isPresented: Binding(get: { pendingIsolate != nil }, set: { if !$0 { pendingIsolate = nil } })
        ) {
            Button("Isolate", role: .destructive) {
                if let row = pendingIsolate { controller.setOnAirIsolate(row.id, on: true, confirmed: true) }
                pendingIsolate = nil
            }
            Button("Cancel", role: .cancel) { pendingIsolate = nil }
        } message: {
            Text("Everything else goes silent on the stream.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On-Air Audio")
    }

    private var onAir: [OnAirAudioSource] { monitor.rows.filter(\.isOnAir) }

    private func requestIsolate(_ row: OnAirAudioSource) {
        if controller.onAirIsIsolated(row) {
            controller.setOnAirIsolate(row.id, on: false, confirmed: true)
        } else if controller.setOnAirIsolate(row.id, on: true, confirmed: false) == .needsConfirm {
            pendingIsolate = row
        }
    }
    private var notHeard: [OnAirAudioSource] { monitor.rows.filter { !$0.isOnAir } }

    private var header: some View {
        HStack(spacing: 6) {
            Text("On-Air Audio")
                .font(DeskType.meta.weight(.semibold))
                .foregroundStyle(ShowSidebarPalette.title)
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                Circle()
                    .fill(onAir.isEmpty ? ShowSidebarPalette.subtitle : ProShowTheme.liveRed)
                    .frame(width: 6, height: 6)
                Text("\(onAir.count) on air")
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
            }
            .accessibilityElement(children: .combine)
            if !monitor.alerts.isEmpty {
                Label("\(monitor.alerts.count)", systemImage: "exclamationmark.triangle.fill")
                    .font(DeskType.micro.weight(.semibold))
                    .foregroundStyle(ProShowTheme.statusOn)
                    .help(monitor.alerts.map(\.message).joined(separator: "\n"))
                    .accessibilityLabel("\(monitor.alerts.count) audio warnings")
            }
            OnAirAudioActionsMenu(controller: controller)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            OnAirProgramMeter()
            ForEach(monitor.alerts) { alert in
                Label(alert.message, systemImage: alert.kind == .clipping ? "waveform.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .font(DeskType.micro.weight(.semibold))
                    .foregroundStyle(alert.kind == .clipping ? ProShowTheme.liveRed : ProShowTheme.statusOn)
                    .lineLimit(2)
            }
            sectionTitle("ON AIR", count: onAir.count)
            if onAir.isEmpty {
                Text("Nothing on air")
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .padding(.leading, 4)
            } else {
                ForEach(onAir) { OnAirAudioRow(source: $0, controller: controller, onIsolate: requestIsolate).equatable() }
            }
            if !notHeard.isEmpty {
                sectionTitle("NOT HEARD", count: notHeard.count)
                ForEach(notHeard) { OnAirAudioRow(source: $0, controller: controller, onIsolate: requestIsolate).equatable() }
            }
            InspectorRowRule()
            OnAirReturnsRow(controller: controller, showRouting: $controls.routingSheetOpen)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        Text("\(title)  \(count)")
            .font(DeskType.micro.weight(.bold))
            .foregroundStyle(ShowSidebarPalette.subtitle)
            .padding(.top, 2)
    }
}

/// Equatable on the row data only (the isolate closure is new on every parent pass), so a parent
/// redraw does not rebuild the row's context menu.
private struct OnAirAudioRow: View, Equatable {
    static func == (lhs: OnAirAudioRow, rhs: OnAirAudioRow) -> Bool { lhs.source == rhs.source }

    let source: OnAirAudioSource
    let controller: ShowController
    var onIsolate: (OnAirAudioSource) -> Void

    @State private var showGain = false

    private var hasChannel: Bool { controller.onAirChannelExists(for: source) }
    private var isolated: Bool { controller.onAirIsIsolated(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                jumpButton
                Spacer(minLength: 2)
                if (source.type != .camera && source.type != .network) || source.via != nil {
                    OnAirRowMeter(id: source.id, dimmed: !source.isOnAir)
                        .frame(width: 36, height: 5)
                }
                controls
                stateChip
            }
            if let reason = visibleReason {
                HStack(spacing: 6) {
                    Text(reason)
                        .font(DeskType.micro)
                        .foregroundStyle(reasonColor)
                        .lineLimit(1)
                    if let fix = source.fix {
                        Button(fix.title) { controller.applyOnAirFix(fix) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .accessibilityLabel("\(fix.title) for \(source.name)")
                    }
                }
                .padding(.leading, 20)
                .help(source.help ?? reason)
            }
        }
        .padding(.vertical, 1)
        .contextMenu { let _ = MenuRenderProbe.hit("OnAirAudioSectionView:245:OnAirAudioRow.body"); menuItems }
    }

    /// Terse reason only when it adds something the chip does not already say.
    private var visibleReason: String? {
        guard let reason = source.reason else { return source.fix == nil ? nil : "" }
        if reason.caseInsensitiveCompare(source.state.chip) == .orderedSame { return source.fix == nil ? nil : "" }
        return reason
    }

    private var jumpButton: some View {
        Button { controller.jumpToOnAirSource(source) } label: {
            HStack(spacing: 6) {
                Image(systemName: source.type.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(source.isOnAir ? ShowSidebarPalette.symbol : ShowSidebarPalette.subtitle)
                    .frame(width: 14)
                Text(source.simulated ? "\(source.name) (sim)" : source.name)
                    .font(DeskType.meta.weight(source.isOnAir ? .semibold : .regular))
                    .foregroundStyle(source.isOnAir ? ShowSidebarPalette.title : ShowSidebarPalette.subtitle)
                    .lineLimit(1)
                Text(source.origin)
                    .font(DeskType.mono)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .help(source.via.map { "\(source.name): \($0)" } ?? source.name)
        .accessibilityLabel("\(source.type.label) \(source.name), \(source.state.chip)")
        .accessibilityValue(source.reason ?? "On air")
    }

    @ViewBuilder
    private var controls: some View {
        if source.type != .network, !(source.type == .camera && source.shotID == nil) {
            iconToggle(
                source.muted ? "speaker.slash.fill" : "speaker.wave.1.fill",
                on: source.muted, onColor: ProShowTheme.statusOn,
                help: source.muted ? "Unmute" : "Mute"
            ) { controller.setOnAirMute(source.id, muted: !source.muted) }
            .accessibilityLabel(source.muted ? "Unmute \(source.name)" : "Mute \(source.name)")
        }
        if hasChannel {
            iconToggle("headphones", on: source.listening, onColor: Color.accentColor, help: "Listen") {
                controller.setOnAirListen(source.id, on: !source.listening)
            }
            .accessibilityLabel(source.listening ? "Stop listening to \(source.name)" : "Listen to \(source.name)")
            Button { showGain.toggle() } label: {
                Text(gainLabel)
                    .font(DeskType.micro.monospacedDigit())
                    .foregroundStyle(source.gainDb == 0 ? ShowSidebarPalette.subtitle : ShowSidebarPalette.title)
                    .frame(minWidth: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Gain")
            .accessibilityLabel("Gain for \(source.name), \(gainLabel) dB")
            .popover(isPresented: $showGain, arrowEdge: .trailing) {
                OnAirGainPopover(source: source, controller: controller)
            }
        }
    }

    private var gainLabel: String {
        let value = Int(source.gainDb.rounded())
        return value > 0 ? "+\(value)" : "\(value)"
    }

    @ViewBuilder
    private var menuItems: some View {
        if hasChannel {
            Button(isolated ? "Clear Isolate" : "Isolate") { onIsolate(source) }
            Button(source.listening ? "Stop Listen" : "Listen") {
                controller.setOnAirListen(source.id, on: !source.listening)
            }
        }
        if source.shotID != nil || source.type == .slide {
            Picker("Audio", selection: Binding(
                get: { source.follow ?? .alwaysOn },
                set: { controller.setOnAirFollow(source.id, mode: $0) }
            )) {
                Text("Always On").tag(AudioFollowMode.alwaysOn)
                Text("Follow Slide").tag(AudioFollowMode.followSlide)
            }
        }
        Button("Show Source") { controller.jumpToOnAirSource(source) }
    }

    private func iconToggle(_ symbol: String, on: Bool, onColor: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(on ? onColor : ShowSidebarPalette.subtitle)
                .frame(width: 16, height: 16)
                .background(on ? onColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var reasonColor: Color {
        switch source.state {
        case .soloOff, .muted, .noSignal: ProShowTheme.statusOn
        default: ShowSidebarPalette.subtitle
        }
    }

    private var stateChip: some View {
        let color: Color = {
            switch source.state {
            case .live: ProShowTheme.liveRed
            case .soloOff, .noSignal, .muted: ProShowTheme.statusOn
            default: ShowSidebarPalette.subtitle
            }
        }()
        return Text(source.state.chip)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(source.state == .live ? Color.white : color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(source.state == .live ? color : color.opacity(0.15), in: Capsule())
            .fixedSize()
            .help(source.help ?? source.reason ?? source.state.chip)
    }
}

private struct OnAirGainPopover: View {
    let source: OnAirAudioSource
    let controller: ShowController
    @State private var value: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(source.name).font(DeskType.meta.weight(.semibold))
                Spacer()
                Text(String(format: "%+.1f dB", value)).font(DeskType.micro.monospacedDigit())
            }
            Slider(value: $value, in: -60...12) { editing in
                if !editing { controller.setOnAirGain(source.id, db: value) }
            }
            .onChange(of: value) { _, db in controller.setOnAirGain(source.id, db: db) }
            HStack {
                Button("0 dB") { value = 0 }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(10)
        .frame(width: 220)
        .onAppear { value = source.gainDb }
    }
}

/// -60 to 0 dBFS bar. Reads a value the 5 Hz monitor already holds.
private struct OnAirLevelBar: View {
    let db: Double
    let dimmed: Bool

    var body: some View {
        GeometryReader { proxy in
            let fraction = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(ShowSidebarPalette.subtitle.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityHidden(true)
    }

    private var color: Color {
        if db > -3 { return ProShowTheme.liveRed }
        if db > -12 { return ProShowTheme.statusOn }
        return Color.green
    }
}

/// The ••• menu. Its own view so the section's 5 Hz rows and meters never rebuild it:
/// a menu rebuilt while open drops its open submenu.
private struct OnAirAudioActionsMenu: View {
    @Bindable var controller: ShowController
    @Bindable private var controls = OnAirAudioControls.shared

    var body: some View {
        Menu { let _ = MenuRenderProbe.hit("OnAirAudioSectionView:69:OnAirAudioSectionView.header");
            if !controller.soloedAudioChannelNames.isEmpty {
                Button("Clear Isolate", systemImage: "circle.slash") {
                    controller.clearAllAudioSolos()
                }
            }
            if controller.audioMatrix.isListening {
                Button("Clear Listen", systemImage: "headphones") {
                    controller.clearOnAirListen()
                }
            }
            Picker("Listen", selection: Binding(
                get: { controller.audioMatrix.listenMode },
                set: { controller.setListenMode($0) }
            )) {
                Text("PFL").tag(AudioListenMode.pfl)
                Text("AFL").tag(AudioListenMode.afl)
            }
            Menu("Listen Output") { let _ = MenuRenderProbe.hit("OnAirAudioSectionView:87:OnAirAudioSectionView.header");
                Button {
                    AudioMonitoringEngine.shared.listenDeviceUID = nil
                } label: {
                    checkRow("Same as Monitor", AudioMonitoringEngine.shared.listenDeviceUID == nil)
                }
                ForEach(MacAudioOutputRouting.outputDevices()) { device in
                    Button {
                        AudioMonitoringEngine.shared.listenDeviceUID = device.id
                        if controller.audioMatrix.isListening { ProgramAudioMonitorBridge.shared.refreshOutputRouting() }
                    } label: {
                        checkRow(device.name, AudioMonitoringEngine.shared.listenDeviceUID == device.id)
                    }
                }
            }
            Button("Routing", systemImage: "square.grid.3x3") { controls.routingSheetOpen = true }
            Divider()
            Button("Mic Mode...", systemImage: "mic.badge.xmark") {
                MicrophoneModeStatus.showPicker()
            }
            Button("Open Audio Tab", systemImage: "slider.vertical.3") {
                controller.inspector.selectedTab = .audio
            }
            Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                copyDiagnostics()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.symbol)
                .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("On-Air Audio actions")
        .accessibilityLabel("On-Air Audio actions")
    }

    @ViewBuilder
    private func checkRow(_ title: String, _ selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func copyDiagnostics() {
        #if os(macOS)
        let object = OnAirAudioMonitor.shared.jsonObject(controller: controller)
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        #endif
    }
}

/// PGM line. Reads the 5 Hz program reading itself so nothing above it redraws.
private struct OnAirProgramMeter: View {
    @Bindable private var monitor = OnAirAudioMonitor.shared

    var body: some View {
        let reading = monitor.program
        return HStack(spacing: 6) {
            Text("PGM")
                .font(DeskType.mono.weight(.bold))
                .foregroundStyle(ShowSidebarPalette.subtitle)
            OnAirLevelBar(db: reading.peakDb, dimmed: false)
                .frame(height: 6)
            Text(reading.measured ? String(format: "%.0f LUFS", reading.shortTermLUFS) : "-- LUFS")
                .font(DeskType.micro.monospacedDigit())
                .foregroundStyle(ShowSidebarPalette.title)
                .help("Short-term \(reading.measured ? String(format: "%.1f", reading.shortTermLUFS) : "--") LUFS, momentary \(reading.measured ? String(format: "%.1f", reading.momentaryLUFS) : "--") LUFS")
            Text(String(format: "pk %.0f", reading.peakDb))
                .font(DeskType.micro.monospacedDigit())
                .foregroundStyle(ShowSidebarPalette.subtitle)
            Circle()
                .fill(reading.clipping ? ProShowTheme.liveRed : ShowSidebarPalette.subtitle.opacity(0.3))
                .frame(width: 7, height: 7)
                .help(reading.clipping ? "Clipping" : "No clipping")
                .accessibilityLabel(reading.clipping ? "Clipping" : "No clipping")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Program meter")
    }
}

/// Row level bar. Reads the row peak itself so the row (and its context menu) does not redraw at 5 Hz.
private struct OnAirRowMeter: View {
    let id: String
    let dimmed: Bool
    @Bindable private var monitor = OnAirAudioMonitor.shared

    var body: some View {
        OnAirLevelBar(db: monitor.peaks[id] ?? -120, dimmed: dimmed)
    }
}
