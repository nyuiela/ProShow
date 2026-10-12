import SwiftUI
#if canImport(AudioKit)
import AudioKit
#endif
#if canImport(AudioKitUI)
import AudioKitUI
#endif

/// Fairlight-style multi-track desk: AudioKit meters/FFT when live I/O is up.
struct AudioMixerView: View {
    @Bindable var controller: ShowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var studio: ShowAudioController { controller.studioAudio }
    private var matrix: AudioMatrixEngine { controller.audioMatrix }

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.xs) {
            HStack {
                DeskSectionTitle(title: "Live audio devices")
                Spacer(minLength: 8)
                Button {
                    controller.refreshAndFlushAudioDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ShowSidebarPalette.symbol)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .help("Refresh audio devices.")
                .accessibilityLabel("Refresh and flush audio devices")
            }
            ProgramSpectrumPane(controller: controller, reduceMotion: reduceMotion)
                .frame(height: 72)
                .deskInspectorGroup(padding: 6)
            if controller.playback.usesFilePlayer, let url = controller.playback.fileURL {
                AudioKitWaveformScrubber(
                    url: url,
                    peaks: studio.waveform,
                    playhead: controller.playback.playhead,
                    duration: controller.playback.duration
                ) { seconds in
                    controller.playback.seek(to: seconds)
                    controller.tickProgram()
                }
                .frame(height: 40)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(matrix.channels) { channel in
                        FairlightChannelStrip(channel: channel, controller: controller)
                    }
                    FairlightMasterStrip(controller: controller)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 300)
            if !controller.inspector.audioTracks.isEmpty {
                inspectorBeds
            }
        }
        .padding(DeskSpace.xs)
        .popover(item: eqBinding, arrowEdge: .leading) { channel in
            ParametricEQView(eq: channel.resolvedEQ) { band in
                controller.studioAudio.setBand(band, on: channel.id)
            }
        }
    }

    private var eqBinding: Binding<AudioMatrixChannel?> {
        Binding(
            get: { studio.eqChannelID.flatMap(matrix.channel(id:)) },
            set: { value in
                if let value {
                    studio.openEQ(for: value.id)
                } else {
                    studio.closeEQ()
                }
            }
        )
    }

    private var inspectorBeds: some View {
        VStack(alignment: .leading, spacing: 2) {
            DeskSectionTitle(title: "Beds")
            ForEach(controller.inspector.audioTracks) { track in
                HStack(spacing: 8) {
                    InspectorSelectionRibbon(selected: track.isPlaying)
                    Button(track.title) {
                        controller.applyMacroAction(.playAudioTrack(trackId: track.id))
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .font(.system(size: 13))
                    .foregroundStyle(ShowSidebarPalette.title)
                    .frame(height: 28)
                    Spacer(minLength: 8)
                    Text(track.destination == .both ? "Both" : (track.destination == .stream ? "Program" : "House"))
                        .font(.system(size: 12))
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ProgramSpectrumPane: View {
    @Bindable var controller: ShowController
    var reduceMotion: Bool

    var body: some View {
        #if canImport(AudioKit) && canImport(AudioKitUI)
        if !reduceMotion, let node = controller.audioIO.fftNode {
            FFTView(
                node,
                linearGradient: LinearGradient(
                    colors: [ProShowTheme.liveRed, ProShowTheme.meterWarn, ProShowTheme.meterSafe],
                    startPoint: .top,
                    endPoint: .center
                ),
                barCount: 48,
                maxAmplitude: -10,
                minAmplitude: -90,
                backgroundColor: ProShowTheme.stageInk
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("Spectrum analyzer")
        } else {
            FFTSpectrumView(frequencyMagnitudes: controller.studioAudio.spectrum)
        }
        #else
        FFTSpectrumView(frequencyMagnitudes: controller.studioAudio.spectrum)
        #endif
    }
}

struct DualLEDMeter: View {
    var left: Double
    var right: Double
    var hold: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ledColumn(left, hold: hold)
            ledColumn(right, hold: hold)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Peak meters")
        .accessibilityValue(String(format: "Left %.0f dB, right %.0f dB", left, right))
    }

    private func ledColumn(_ db: Double, hold: Double) -> some View {
        GeometryReader { geo in
            let level = AudioDSP.meterLevel(fromDb: db)
            let holdLevel = AudioDSP.meterLevel(fromDb: hold)
            ZStack(alignment: .bottom) {
                Capsule().fill(ProShowTheme.canvas)
                Capsule()
                    .fill(meterColor(db))
                    .frame(height: max(3, geo.size.height * CGFloat(level)))
                Rectangle()
                    .fill(hold >= 0 ? ProShowTheme.liveRed : ProShowTheme.lyricWhite)
                    .frame(height: 2)
                    .offset(y: -(geo.size.height * CGFloat(holdLevel) - 2))
            }
        }
        .frame(width: 8)
        .clipShape(Capsule())
    }

    private func meterColor(_ db: Double) -> Color {
        if db >= 0 { return ProShowTheme.liveRed }
        if db > -6 { return ProShowTheme.meterWarn }
        return ProShowTheme.meterSafe
    }
}

/// Studio-tile mixer. Opaque graphite on the liquid-glass panel. Numbers are live peaks, not estimated loudness.
struct StudioAudioGlass: View {
    @Bindable var controller: ShowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: StudioAudioPage = .mixer
    @State private var peakHistory: [Double] = []

    private var matrix: AudioMatrixEngine { controller.audioMatrix }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            StudioAudioGlassBody(
                controller: controller,
                page: $page,
                peakHistory: $peakHistory,
                tick: context.date
            )
        }
        .popover(item: eqBinding, arrowEdge: .leading) { channel in
            ParametricEQView(eq: channel.resolvedEQ) { band in
                controller.studioAudio.setBand(band, on: channel.id)
            }
        }
    }

    private var eqBinding: Binding<AudioMatrixChannel?> {
        Binding(
            get: { controller.studioAudio.eqChannelID.flatMap(matrix.channel(id:)) },
            set: { value in
                if let value {
                    controller.studioAudio.openEQ(for: value.id)
                } else {
                    controller.studioAudio.closeEQ()
                }
            }
        )
    }
}

private enum StudioAudioPage: String, CaseIterable, Identifiable {
    case mixer, loudness, devices
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mixer: "Mixer"
        case .loudness: "Loudness"
        case .devices: "Devices"
        }
    }
}

private struct StudioAudioGlassBody: View {
    @Bindable var controller: ShowController
    @Binding var page: StudioAudioPage
    @Binding var peakHistory: [Double]
    var tick: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var matrix: AudioMatrixEngine { controller.audioMatrix }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let probe = StreamAudioPipelineDiagnostics.deskProbeSnapshot(), controller.streaming.isLive {
                Text(probe.text)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(probe.severity == .critical ? ProShowTheme.liveRed : ProShowTheme.secondaryLabel)
                    .lineLimit(2)
                    .accessibilityLabel(probe.text)
            }
            GeometryReader { proxy in
                let sideBySide = proxy.size.width >= 720 && page != .devices
                if page == .devices {
                    devices
                } else if sideBySide {
                    HStack(alignment: .top, spacing: 10) {
                        mixer.frame(maxWidth: .infinity, maxHeight: .infinity)
                        loudness
                            .frame(width: min(280, proxy.size.width * 0.34))
                    }
                } else if page == .loudness {
                    loudness
                } else {
                    mixer
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: matrix.master.peakLeft) { _, peak in
            peakHistory.append(peak)
            if peakHistory.count > 120 {
                peakHistory.removeFirst(peakHistory.count - 120)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Studio audio")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Audio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProShowTheme.primaryLabel)
            pagePicker
            Spacer(minLength: 4)
            if controller.streaming.isLive {
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ProShowTheme.liveRed)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ProShowTheme.liveRed.opacity(0.16), in: Capsule())
                    .accessibilityLabel("Stream is live")
            }
            Text("48k · \(ProgramStreamAudioClock.framesPerAccessUnit)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(RundownChrome.mutedLabel)
            Button {
                matrix.clearPeakHolds()
            } label: {
                Text("Clear")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ProShowTheme.liveRed, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help("Clear peak holds")
            .accessibilityLabel("Clear peak holds")
        }
    }

    private var pagePicker: some View {
        HStack(spacing: 2) {
            ForEach(StudioAudioPage.allCases) { item in
                let selected = page == item
                Button {
                    page = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? ProShowTheme.primaryLabel : RundownChrome.mutedLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                Capsule().fill(Color.white.opacity(0.10))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(DeskPressButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.28)))
    }

    private var mixer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(matrix.channels) { channel in
                    StudioAudioStrip(channel: channel, controller: controller)
                }
                StudioProgramStrip(controller: controller)
            }
            .padding(.vertical, 2)
        }
    }

    private var loudness: some View {
        let peak = max(matrix.master.peakLeft, matrix.master.peakRight)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Program peak")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RundownChrome.mutedLabel)
                Spacer(minLength: 4)
                Text("Limit \(formatDb(matrix.master.ceilingDb))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(RundownChrome.mutedLabel)
            }
            HStack(alignment: .center, spacing: 12) {
                StudioPeakDial(db: peak)
                VStack(alignment: .leading, spacing: 6) {
                    readout("L", matrix.master.peakLeft)
                    readout("R", matrix.master.peakRight)
                    readout("Hold", matrix.master.peakHoldDb)
                }
            }
            Text("Recent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RundownChrome.mutedLabel)
            StudioPeakHistory(samples: peakHistory)
                .frame(height: 64)
            Text("Spectrum")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RundownChrome.mutedLabel)
            StudioBarSpectrum(magnitudes: controller.studioAudio.spectrum, reduceMotion: reduceMotion)
                .frame(minHeight: 72)
                .accessibilityLabel("Spectrum")
            Text(tick, format: .dateTime.hour().minute().second())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(RundownChrome.mutedLabel)
                .accessibilityHidden(true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ProShowTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func readout(_ title: String, _ db: Double) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RundownChrome.mutedLabel)
                .frame(width: 28, alignment: .leading)
            Text(formatDb(db))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(ProShowTheme.primaryLabel)
        }
        .accessibilityElement(children: .combine)
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Buses")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProShowTheme.primaryLabel)
                Spacer()
                Button {
                    controller.refreshAndFlushAudioDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(DeskPressButtonStyle())
                .help("Refresh audio devices")
                .accessibilityLabel("Refresh audio devices")
            }
            if matrix.channels.isEmpty {
                Text("No buses")
                    .font(DeskType.body)
                    .foregroundStyle(RundownChrome.mutedLabel)
            } else {
                ForEach(matrix.channels) { channel in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(channel.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ProShowTheme.primaryLabel)
                            Text(channel.role.studioSubtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(RundownChrome.mutedLabel)
                        }
                        Spacer()
                        Text(channel.muted ? "Muted" : channel.bus.rawValue.capitalized)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(channel.muted ? ProShowTheme.liveRed : RundownChrome.mutedLabel)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func formatDb(_ db: Double) -> String {
        if db <= -90 { return "— dB" }
        return String(format: "%+.1f dB", db)
    }
}

private struct StudioAudioStrip: View {
    var channel: AudioMatrixChannel
    @Bindable var controller: ShowController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var gateOn: Bool {
        controller.audioMatrix.isNoiseGateOn(channel.id)
    }

    private var inHeadphones: Bool {
        switch channel.bus {
        case .stream, .stage: false
        default: true
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(channel.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ProShowTheme.primaryLabel)
                .lineLimit(1)
            Text(channel.role.studioSubtitle)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(RundownChrome.mutedLabel)
                .lineLimit(1)
            HStack {
                Text("Gain")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(RundownChrome.mutedLabel)
                Spacer(minLength: 2)
                Text(String(format: "%+.0f dB", channel.gainDb))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ProShowTheme.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(channel.name) gain")
            .accessibilityValue(String(format: "%+.0f decibels", channel.gainDb))
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    chip("HPF", on: channel.resolvedEQ.bands.first { $0.filter == .highPass }?.enabled == true, hint: "High-pass filter") {
                        let enabled = channel.resolvedEQ.bands.first { $0.filter == .highPass }?.enabled == true
                        controller.audioMatrix.setHighPassEnabled(id: channel.id, enabled: !enabled)
                    }
                    chip("Gate", on: gateOn, hint: "Noise gate. Quiet audio on this bus is kept out of the stream and headphones.") {
                        controller.audioMatrix.toggleNoiseGate(id: channel.id)
                        if channel.role == .microphone {
                            controller.audioMatrix.duckingEnabled = controller.audioMatrix.isNoiseGateOn(channel.id)
                        }
                        controller.tickProgram()
                    }
                }
                HStack(spacing: 3) {
                    chip("EQ", on: controller.studioAudio.eqChannelID == channel.id || channel.resolvedEQ.bands.contains { abs($0.gainDb) > 0.05 }, hint: "Equalizer") {
                        controller.studioAudio.openEQ(for: channel.id)
                    }
                    chip("Comp", on: controller.audioMatrix.isChannelLimited(channel.id), hint: "Compress peaks on this bus before the stream and headphones") {
                        controller.audioMatrix.toggleChannelLimiter(id: channel.id)
                        controller.tickProgram()
                    }
                }
            }
            StudioFaderMeter(
                peak: channel.stereoPeak,
                hold: channel.peakHoldDb ?? channel.stereoPeak,
                gainDb: channel.gainDb,
                name: channel.name,
                solid: reduceTransparency
            ) { db in
                controller.audioMatrix.setGain(id: channel.id, db: db)
                controller.tickProgram()
            }
            Text(channel.stereoPeak <= -90 ? "—" : String(format: "%+.1f", channel.stereoPeak))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(channel.stereoPeak >= 0 ? ProShowTheme.liveRed : RundownChrome.mutedLabel)
            HStack(spacing: 4) {
                flag("M", on: channel.muted, tint: ProShowTheme.liveRed, label: "\(channel.name) mute") {
                    controller.audioMatrix.toggleMute(id: channel.id)
                    controller.tickProgram()
                }
                flag("S", on: channel.solo, tint: ProShowTheme.statusOn, label: "\(channel.name) solo") {
                    controller.audioMatrix.toggleSolo(id: channel.id)
                    controller.tickProgram()
                }
                iconFlag("headphones", on: inHeadphones, label: "\(channel.name) headphones") {
                    controller.audioMatrix.setHeadphoneMix(id: channel.id, included: !inHeadphones)
                    controller.tickProgram()
                }
            }
        }
        .padding(8)
        .frame(width: 104)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ProShowTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    controller.studioAudio.eqChannelID == channel.id ? ProShowTheme.accent.opacity(0.7) : Color.white.opacity(0.06),
                    lineWidth: 1
                )
        }
        .opacity(channel.muted ? 0.72 : 1)
        .accessibilityElement(children: .contain)
    }

    private func chip(_ title: String, on: Bool, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(on ? ProShowTheme.accent : RundownChrome.mutedLabel)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(on ? ProShowTheme.accent.opacity(0.16) : Color.white.opacity(0.05))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(on ? ProShowTheme.accent.opacity(0.55) : Color.white.opacity(0.06), lineWidth: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .help(hint)
        .accessibilityLabel("\(channel.name) \(title)")
        .accessibilityHint(hint)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func flag(_ title: String, on: Bool, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(on ? Color.black : ProShowTheme.primaryLabel)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(on ? tint : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func iconFlag(_ symbol: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? ProShowTheme.accent : RundownChrome.mutedLabel)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(Color.white.opacity(on ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct StudioProgramStrip: View {
    @Bindable var controller: ShowController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var master: MixerMasterState { controller.audioMatrix.master }
    private var peak: Double { max(master.peakLeft, master.peakRight) }

    var body: some View {
        VStack(spacing: 6) {
            Text("Program")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ProShowTheme.primaryLabel)
            Text("Stream")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(RundownChrome.mutedLabel)
            HStack {
                Text("Gain")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(RundownChrome.mutedLabel)
                Spacer(minLength: 2)
                Text(String(format: "%+.0f dB", master.gainDb))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ProShowTheme.accent)
            }
            Text(master.limiterEnabled ? "Limit \(String(format: "%+.1f", master.ceilingDb))" : "Limit off")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(master.limiterEnabled ? ProShowTheme.accent : RundownChrome.mutedLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            StudioFaderMeter(
                peak: peak,
                hold: master.peakHoldDb,
                gainDb: master.gainDb,
                name: "Program",
                solid: reduceTransparency
            ) { db in
                controller.audioMatrix.setMasterGain(db: db)
                controller.tickProgram()
            }
            Text(peak <= -90 ? "—" : String(format: "%+.1f", peak))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(peak >= 0 ? ProShowTheme.liveRed : RundownChrome.mutedLabel)
            HStack(spacing: 4) {
                Button {
                    controller.audioMatrix.muteProgram(!controller.audioMatrix.programMuted)
                    controller.tickProgram()
                } label: {
                    Text("M")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(controller.audioMatrix.programMuted ? Color.black : ProShowTheme.primaryLabel)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(
                            controller.audioMatrix.programMuted ? ProShowTheme.liveRed : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .accessibilityLabel("Mute program mix")
                .accessibilityAddTraits(controller.audioMatrix.programMuted ? .isSelected : [])
                Button {
                    AudioMonitoringEngine.shared.toggleLocalSpeakerMuted()
                } label: {
                    Image(systemName: "headphones")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AudioMonitoringEngine.shared.localSpeakerMuted ? RundownChrome.mutedLabel : ProShowTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .help("Mute this Mac's speakers. The stream stays up.")
                .accessibilityLabel("Program headphones")
                .accessibilityAddTraits(AudioMonitoringEngine.shared.localSpeakerMuted ? [] : .isSelected)
            }
        }
        .padding(8)
        .frame(width: 104)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ProShowTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ProShowTheme.accent.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct StudioFaderMeter: View {
    var peak: Double
    var hold: Double
    var gainDb: Double
    var name: String
    var solid: Bool
    var onGain: (Double) -> Void

    private let marks: [Double] = [6, 0, -6, -12, -18, -24, -48]

    var body: some View {
        GeometryReader { geo in
            let level = AudioDSP.meterLevel(fromDb: peak)
            let holdLevel = AudioDSP.meterLevel(fromDb: hold)
            let gainLevel = AudioDSP.meterLevel(fromDb: gainDb)
            HStack(alignment: .bottom, spacing: 4) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(marks, id: \.self) { mark in
                        Text(mark > 0 ? "+\(Int(mark))" : "\(Int(mark))")
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundStyle(RundownChrome.mutedLabel)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 16)
                .accessibilityHidden(true)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                    segmentMeter(height: geo.size.height, level: level)
                    Rectangle()
                        .fill(ProShowTheme.lyricWhite)
                        .frame(height: 1)
                        .offset(y: -(geo.size.height * holdLevel - 1))
                    faderCap(at: gainLevel, height: geo.size.height)
                }
                .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let y = min(max(0, value.location.y), geo.size.height)
                        let t = 1 - (y / max(geo.size.height, 1))
                        let db = AudioDSP.meterFloorDb + (AudioDSP.meterCeilDb - AudioDSP.meterFloorDb) * Double(t)
                        onGain(db)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("\(name) fader")
            .accessibilityValue(String(format: "%+.1f decibels", gainDb))
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 1 : -1
                onGain(gainDb + step)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) meter")
        .accessibilityValue(String(format: "%.1f decibels", peak))
    }

    private func segmentMeter(height: CGFloat, level: Double) -> some View {
        let count = 28
        return VStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { index in
                let fromTop = Double(index) / Double(count - 1)
                let lit = (1 - fromTop) <= level
                RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                    .fill(lit ? segmentColor(fromTop) : Color.white.opacity(0.06))
            }
        }
        .padding(.vertical, 2)
        .frame(height: height)
    }

    private func segmentColor(_ fromTop: Double) -> Color {
        if fromTop < 0.12 { return ProShowTheme.liveRed }
        if fromTop < 0.28 { return ProShowTheme.meterWarn }
        return ProShowTheme.meterSafe
    }

    private func faderCap(at gainLevel: Double, height: CGFloat) -> some View {
        let travel = max(0, height - 12)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(solid ? ProShowTheme.panel : ProShowTheme.well)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.6)
            }
            .frame(height: 12)
            .padding(.horizontal, 2)
            .offset(y: -(travel * gainLevel))
            .accessibilityHidden(true)
    }
}

private struct StudioPeakDial: View {
    var db: Double

    var body: some View {
        let level = AudioDSP.meterLevel(fromDb: db)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 8)
            Circle()
                .trim(from: 0.12, to: 0.12 + 0.76 * level)
                .stroke(
                    AngularGradient(
                        colors: [ProShowTheme.meterSafe, ProShowTheme.meterWarn, ProShowTheme.liveRed],
                        center: .center
                    ),
                    style: SwiftUI.StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
            VStack(spacing: 1) {
                Text(db <= -90 ? "—" : String(format: "%+.1f", db))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(db >= 0 ? ProShowTheme.liveRed : ProShowTheme.primaryLabel)
                    .minimumScaleFactor(0.7)
                Text("dBFS")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(RundownChrome.mutedLabel)
            }
        }
        .frame(width: 92, height: 92)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Program peak")
        .accessibilityValue(db <= -90 ? "Silent" : String(format: "%.1f dBFS", db))
    }
}

private struct StudioPeakHistory: View {
    var samples: [Double]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard samples.count > 1 else { return }
                let step = geo.size.width / CGFloat(max(samples.count - 1, 1))
                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * step
                    let y = (1 - AudioDSP.meterLevel(fromDb: sample)) * geo.size.height
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(ProShowTheme.accent, lineWidth: 1.5)
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Recent program peak")
    }
}

private struct StudioBarSpectrum: View {
    var magnitudes: [Float]
    var reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            let count = max(magnitudes.count, 1)
            let gap: CGFloat = 1
            let width = max(1, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(magnitudes.enumerated()), id: \.offset) { _, magnitude in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(ProShowTheme.accent.opacity(0.85))
                        .frame(width: width, height: max(2, geo.size.height * CGFloat(min(1, max(0, magnitude)))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .transaction { transaction in
            if reduceMotion { transaction.disablesAnimations = true }
        }
    }
}

private extension AudioChannelRole {
    var studioSubtitle: String {
        switch self {
        case .microphone: "Mic"
        case .desktop: "System"
        case .guest: "Guest"
        case .slide: "Media"
        case .soundboard: "Board"
        }
    }
}
