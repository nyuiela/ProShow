import SwiftUI
#if canImport(AudioKit)
import AudioKit
#endif
#if canImport(AudioKitUI)
import AudioKitUI
#endif
#if canImport(Controls)
import Controls
#endif

/// One mixer strip: AudioKit meter/knob when a live node exists, desk tokens everywhere.
struct FairlightChannelStrip: View {
    var channel: AudioMatrixChannel
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 6) {
            Text(channel.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(peakLabel)
                .font(DeskType.mono)
                .foregroundStyle(channel.peak >= 0 ? ProShowTheme.liveRed : ShowSidebarPalette.subtitle)
            liveMeter
                .frame(height: 96)
            #if canImport(Controls)
            ArcKnob(
                "Gain",
                value: gainBinding,
                range: -60...12,
                origin: 0
            )
            .foregroundColor(ProShowTheme.accent)
            .backgroundColor(ShowSidebarPalette.field(scheme))
            .frame(width: 44, height: 44)
            .accessibilityLabel("\(channel.name) gain")
            .accessibilityValue(String(format: "%+.1f dB", channel.gainDb))
            #else
            Slider(value: faderBinding, in: -60...12)
                .controlSize(.mini)
                .tint(ProShowTheme.accent)
                .accessibilityLabel("\(channel.name) fader")
            #endif
            Text(String(format: "%+.1f", channel.gainDb))
                .font(DeskType.mono)
                .foregroundStyle(ShowSidebarPalette.subtitle)
            #if canImport(Controls)
            ArcKnob(
                "Trim",
                value: trimKnobBinding,
                range: -12...12,
                origin: 0
            )
            .foregroundColor(ProShowTheme.statusOn)
            .backgroundColor(ShowSidebarPalette.field(scheme))
            .frame(width: 36, height: 36)
            .accessibilityLabel("\(channel.name) trim")
            #else
            Slider(value: trimBinding, in: -12...12)
                .controlSize(.mini)
                .tint(ProShowTheme.statusOn)
                .accessibilityLabel("\(channel.name) trim")
            #endif
            HStack(spacing: 4) {
                stripButton("M", on: channel.muted, color: ProShowTheme.liveRed) {
                    controller.audioMatrix.toggleMute(id: channel.id)
                    controller.tickProgram()
                }
                stripButton("S", on: channel.solo, color: ProShowTheme.statusOn) {
                    controller.audioMatrix.toggleSolo(id: channel.id)
                    controller.tickProgram()
                }
                stripButton("D", on: channel.isDuckTarget, color: ProShowTheme.accent) {
                    controller.audioMatrix.toggleDuckTarget(id: channel.id)
                    controller.tickProgram()
                }
                .accessibilityLabel(channel.isDuckTarget ? "Disable ducking target" : "Duck when mic speaks")
            }
            if channel.role == .microphone || channel.role == .desktop {
                Button {
                    controller.detachHardwareAudio(for: channel.role)
                } label: {
                    Label("Detach", systemImage: "trash.fill")
                        .labelStyle(.iconOnly)
                        .font(DeskControlSize.compact.iconFont)
                        .foregroundStyle(ShowSidebarPalette.symbol)
                        .frame(width: DeskLayout.hit, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .help("Stop hardware capture for this bus")
                .accessibilityLabel("Detach \(channel.name) capture")
            }
            Button {
                controller.studioAudio.openEQ(for: channel.id)
            } label: {
                Label("EQ", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
                    .font(DeskControlSize.compact.iconFont)
                    .foregroundStyle(ShowSidebarPalette.symbol)
                    .frame(width: DeskLayout.hit, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help("Open 6-band EQ")
            .accessibilityLabel("\(channel.name) equalizer")
        }
        .padding(6)
        .frame(width: 84)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(channel.muted ? 0.72 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(channel.name)
    }

    @ViewBuilder
    private var liveMeter: some View {
        #if canImport(AudioKit) && canImport(AudioKitUI)
        if let node = hardwareNode {
            AmplitudeView(
                node,
                colors: Gradient(colors: [ProShowTheme.liveRed, ProShowTheme.meterWarn, ProShowTheme.meterSafe]),
                analysisMode: .peak,
                backgroundColor: ProShowTheme.canvas,
                numberOfSegments: 18
            )
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("\(channel.name) peak meter")
        } else {
            DualLEDMeter(
                left: channel.peakLeft ?? channel.peak,
                right: channel.peakRight ?? channel.peak,
                hold: channel.peakHoldDb ?? channel.peak
            )
        }
        #else
        DualLEDMeter(
            left: channel.peakLeft ?? channel.peak,
            right: channel.peakRight ?? channel.peak,
            hold: channel.peakHoldDb ?? channel.peak
        )
        #endif
    }

    #if canImport(AudioKit)
    private var hardwareNode: Node? {
        switch channel.role {
        case .microphone: return controller.audioIO.meterNode
        default: return nil
        }
    }
    #endif

    private var peakLabel: String {
        channel.peak <= -80 ? "OFF" : String(format: "%+.0f dB", channel.peak)
    }

    #if canImport(Controls)
    private var gainBinding: Binding<Float> {
        Binding(
            get: { Float(channel.gainDb) },
            set: { controller.audioMatrix.setGain(id: channel.id, db: Double($0)) }
        )
    }

    private var trimKnobBinding: Binding<Float> {
        Binding(
            get: { Float(channel.resolvedTrimDb) },
            set: { controller.audioMatrix.setTrim(id: channel.id, db: Double($0)) }
        )
    }
    #endif

    private var faderBinding: Binding<Double> {
        Binding(
            get: { channel.gainDb },
            set: { controller.audioMatrix.setGain(id: channel.id, db: $0) }
        )
    }

    private var trimBinding: Binding<Double> {
        Binding(
            get: { channel.resolvedTrimDb },
            set: { controller.audioMatrix.setTrim(id: channel.id, db: $0) }
        )
    }

    private func stripButton(_ title: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(on ? Color.white : ShowSidebarPalette.symbol)
                .frame(minWidth: 28, minHeight: 28)
                .background(on ? color : ShowSidebarPalette.field(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(accessibilityTitle(title, on: on))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func accessibilityTitle(_ title: String, on: Bool) -> String {
        switch title {
        case "M": on ? "Unmute \(channel.name)" : "Mute \(channel.name)"
        case "S": on ? "Unsolo \(channel.name)" : "Solo \(channel.name)"
        default: on ? "Disable ducking" : "Enable ducking"
        }
    }
}

struct FairlightMasterStrip: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let master = controller.audioMatrix.master
        VStack(spacing: 6) {
            Text("Main")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.title)
            Text(master.limiterEnabled ? "LIM ON" : "LIM OFF")
                .font(DeskType.mono)
                .foregroundStyle(master.limiterEnabled ? ProShowTheme.meterSafe : ShowSidebarPalette.subtitle)
            masterMeter
                .frame(height: 96)
            #if canImport(Controls)
            ArcKnob(
                "Main",
                value: masterGainBinding,
                range: -60...12,
                origin: 0
            )
            .foregroundColor(ProShowTheme.accent)
            .backgroundColor(ShowSidebarPalette.field(scheme))
            .frame(width: 44, height: 44)
            .accessibilityLabel("Master fader")
            #else
            Slider(
                value: Binding(
                    get: { master.gainDb },
                    set: { controller.audioMatrix.master.gainDb = min(12, max(-60, $0)) }
                ),
                in: -60...12
            )
            .controlSize(.mini)
            .tint(ProShowTheme.accent)
            .accessibilityLabel("Master fader")
            #endif
            HStack(spacing: 4) {
                Button {
                    controller.audioMatrix.master.limiterEnabled.toggle()
                } label: {
                    Text("LIM")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(master.limiterEnabled ? Color.white : ShowSidebarPalette.symbol)
                        .frame(width: 28, height: 18)
                        .background(master.limiterEnabled ? ProShowTheme.meterSafe : ShowSidebarPalette.field(scheme))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(DeskPressButtonStyle())
                .accessibilityLabel(master.limiterEnabled ? "Disable master limiter" : "Enable master limiter")
                Button {
                    controller.toggleAudioMute()
                } label: {
                    Text("M")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(master.muted || controller.audioIO.programMuted ? Color.white : ShowSidebarPalette.symbol)
                        .frame(width: 18, height: 18)
                        .background(master.muted || controller.audioIO.programMuted ? ProShowTheme.liveRed : ShowSidebarPalette.field(scheme))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(DeskPressButtonStyle())
                .accessibilityLabel((master.muted || controller.audioIO.programMuted) ? "Unmute master" : "Mute master")
            }
            Text("Program")
                .font(DeskType.micro)
                .foregroundStyle(ShowSidebarPalette.subtitle)
        }
        .padding(6)
        .frame(width: 84)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var masterMeter: some View {
        #if canImport(AudioKit) && canImport(AudioKitUI)
        if let node = controller.audioIO.outputNode {
            AmplitudeView(
                node,
                colors: Gradient(colors: [ProShowTheme.liveRed, ProShowTheme.meterWarn, ProShowTheme.meterSafe]),
                analysisMode: .peak,
                backgroundColor: ProShowTheme.canvas,
                numberOfSegments: 18
            )
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("Master peak meter")
        } else {
            DualLEDMeter(left: controller.audioMatrix.master.peakLeft, right: controller.audioMatrix.master.peakRight, hold: controller.audioMatrix.master.peakHoldDb)
        }
        #else
        DualLEDMeter(left: controller.audioMatrix.master.peakLeft, right: controller.audioMatrix.master.peakRight, hold: controller.audioMatrix.master.peakHoldDb)
        #endif
    }

    #if canImport(Controls)
    private var masterGainBinding: Binding<Float> {
        Binding(
            get: { Float(controller.audioMatrix.master.gainDb) },
            set: { controller.audioMatrix.master.gainDb = min(12, max(-60, Double($0))) }
        )
    }
    #endif
}
