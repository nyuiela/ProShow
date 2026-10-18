import SwiftUI

/// On-Air Audio: what the stream hears right now, what it does not hear, and why.
/// Visibility only. Rows jump to where the source can be fixed.
struct OnAirAudioSectionView: View {
    @Bindable var controller: ShowController
    @Bindable private var monitor = OnAirAudioMonitor.shared
    @AppStorage("proshow.inspector.onAirAudioExpanded") private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content
                .padding(.top, 6)
        } label: {
            header
        }
        .onAppear { monitor.attach(controller) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On-Air Audio")
    }

    private var onAir: [OnAirAudioSource] { monitor.sources.filter(\.isOnAir) }
    private var notHeard: [OnAirAudioSource] { monitor.sources.filter { !$0.isOnAir } }

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
            Menu {
                if !controller.soloedAudioChannelNames.isEmpty {
                    Button("Clear All Solos", systemImage: "circle.slash") {
                        controller.clearAllAudioSolos()
                    }
                }
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
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            programMeter
            ForEach(monitor.alerts) { alert in
                Label(alert.message, systemImage: alert.kind == .clipping ? "waveform.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .font(DeskType.micro.weight(.semibold))
                    .foregroundStyle(alert.kind == .clipping ? ProShowTheme.liveRed : ProShowTheme.statusOn)
                    .lineLimit(2)
            }
            sectionTitle("ON AIR", count: onAir.count)
            if onAir.isEmpty {
                Text("Nothing is reaching the stream.")
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .padding(.leading, 4)
            } else {
                ForEach(onAir) { OnAirAudioRow(source: $0) { controller.jumpToOnAirSource($0) } }
            }
            if !notHeard.isEmpty {
                sectionTitle("NOT HEARD", count: notHeard.count)
                ForEach(notHeard) { OnAirAudioRow(source: $0) { controller.jumpToOnAirSource($0) } }
            }
            InspectorRowRule()
            HStack(spacing: 6) {
                Text("Returns")
                    .font(DeskType.micro.weight(.semibold))
                    .foregroundStyle(ShowSidebarPalette.title)
                Text(controller.onAirReturnsLine)
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(controller.onAirReturnsLine)
            .accessibilityElement(children: .combine)
        }
    }

    private var programMeter: some View {
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
                .help("Short-term loudness (3 s). Momentary: \(reading.measured ? String(format: "%.1f", reading.momentaryLUFS) : "--") LUFS. Aim for about -14 LUFS.")
            Text(String(format: "pk %.0f", reading.peakDb))
                .font(DeskType.micro.monospacedDigit())
                .foregroundStyle(ShowSidebarPalette.subtitle)
            Circle()
                .fill(reading.clipping ? ProShowTheme.liveRed : ShowSidebarPalette.subtitle.opacity(0.3))
                .frame(width: 7, height: 7)
                .help(reading.clipping ? "Clipping in the last 2 s" : "No clipping")
                .accessibilityLabel(reading.clipping ? "Clipping" : "No clipping")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Program meter")
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        Text("\(title)  \(count)")
            .font(DeskType.micro.weight(.bold))
            .foregroundStyle(ShowSidebarPalette.subtitle)
            .padding(.top, 2)
    }

    private func copyDiagnostics() {
        #if os(macOS)
        let object = monitor.jsonObject(controller: controller)
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        #endif
    }
}

private struct OnAirAudioRow: View {
    let source: OnAirAudioSource
    let onJump: (OnAirAudioSource) -> Void

    var body: some View {
        Button { onJump(source) } label: {
            VStack(alignment: .leading, spacing: 1) {
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
                    Spacer(minLength: 4)
                    if source.type != .camera && source.type != .network {
                        OnAirLevelBar(db: source.peakDb, dimmed: !source.isOnAir)
                            .frame(width: 44, height: 5)
                    }
                    stateChip
                }
                if let reason = source.reason {
                    Text(reason)
                        .font(DeskType.micro)
                        .foregroundStyle(reasonColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 20)
                        .help(reason)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .help("Show where \(source.name) is set up")
        .accessibilityLabel("\(source.type.label) \(source.name), \(source.state.chip)")
        .accessibilityValue(source.reason ?? "On air")
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
