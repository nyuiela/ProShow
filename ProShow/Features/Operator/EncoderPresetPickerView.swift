import SwiftUI

/// Stream quality preset picker with optional custom bitrate override.
struct EncoderPresetPickerView: View {
    @Binding var config: StreamEncoderConfig
    var destinations: [StreamAccount] = []
    var onCommit: (StreamEncoderConfig) -> Void
    var showsSectionTitle: Bool = true

    @State private var customTargetKbps: Int = 2_500
    @State private var customCeilingKbps: Int = 3_000

    private var selectedPreset: StreamEncoderPreset {
        StreamEncoderPreset.named(config.presetName) ?? .saver720p30
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.sm) {
            if showsSectionTitle {
                Text("Encoding")
                    .font(DeskType.bodyEmph)
                    .foregroundStyle(ProShowTheme.primaryLabel)
                    .accessibilityAddTraits(.isHeader)
            }

            SettingsAlignedRow(label: "Preset") {
                Picker("Encoding preset", selection: presetBinding) {
                    ForEach(StreamEncoderPreset.allCases.filter { $0 != .custom }) { preset in
                        Text(preset.menuTitle).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                SettingsAlignedRow(label: "Resolution") {
                    Text("\(config.width) × \(config.height)")
                        .font(DeskType.body)
                        .foregroundStyle(ProShowTheme.primaryLabel)
                }
                SettingsAlignedRow(label: "Frame rate") {
                    Text("\(config.frameRate) fps")
                        .font(DeskType.body)
                        .foregroundStyle(ProShowTheme.primaryLabel)
                }
                SettingsAlignedRow(label: "Video") {
                    Text("\(config.targetBitrateKbps.formatted()) Kbps · cap \(config.maxBitrateCeilingKbps.formatted())")
                        .font(DeskType.body.monospacedDigit())
                        .foregroundStyle(ProShowTheme.primaryLabel)
                }
                SettingsAlignedRow(label: "Audio") {
                    Text("AAC \(config.audioBitrateKbps) Kbps · 48 kHz stereo")
                        .font(DeskType.body)
                        .foregroundStyle(ProShowTheme.primaryLabel)
                }
                SettingsAlignedRow(label: "Encoder") {
                    Text(config.useHardwareEncoder ? "VideoToolbox H.264 (hardware)" : "VideoToolbox H.264")
                        .font(DeskType.body)
                        .foregroundStyle(ProShowTheme.primaryLabel)
                }
                if let preset = StreamEncoderPreset.named(config.presetName) {
                    SettingsAlignedRow(label: "Best for") {
                        Text(preset.idealUseCase)
                            .font(DeskType.body)
                            .foregroundStyle(ProShowTheme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Encoding preset details")

            Toggle(isOn: $config.customBitrateOverrideEnabled) {
                Text("Custom bitrate override")
                    .font(DeskType.body)
                    .foregroundStyle(ProShowTheme.primaryLabel)
            }
            .toggleStyle(.checkbox)
            .onChange(of: config.customBitrateOverrideEnabled) { _, enabled in
                if enabled {
                    customTargetKbps = config.targetBitrateKbps
                    customCeilingKbps = config.maxBitrateCeilingKbps
                } else if let preset = StreamEncoderPreset.named(config.presetName), preset != .custom {
                    var next = config
                    next.applyPreset(preset)
                    commit(next)
                }
            }

            if config.customBitrateOverrideEnabled {
                SettingsAlignedRow(label: "Target") {
                    bitrateInput(value: $customTargetKbps)
                }
                SettingsAlignedRow(label: "Ceiling") {
                    bitrateInput(value: $customCeilingKbps)
                }
            }

            if let ingestAdvisory {
                Text(ingestAdvisory)
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(ingestAdvisory)
            }
        }
        .onAppear {
            customTargetKbps = config.targetBitrateKbps
            customCeilingKbps = config.maxBitrateCeilingKbps
        }
        .onChange(of: customTargetKbps) { _, _ in applyCustomIfNeeded() }
        .onChange(of: customCeilingKbps) { _, _ in applyCustomIfNeeded() }
    }

    private var presetBinding: Binding<StreamEncoderPreset> {
        Binding(
            get: { selectedPreset },
            set: { preset in
                guard preset != .custom else { return }
                var next = config
                next.customBitrateOverrideEnabled = false
                next.applyPreset(preset)
                commit(next)
            }
        )
    }

    private var ingestAdvisory: String? {
        let policies = PlatformIngestPolicy.policies(for: destinations)
        let clamped = config.clamped(to: policies)
        guard clamped.targetBitrateBps != config.targetBitrateBps
            || clamped.maxBitrateCeilingBps != config.maxBitrateCeilingBps
            || clamped.audioBitrateBps != config.audioBitrateBps
        else { return nil }
        let who = policies.map(\.name).joined(separator: " and ")
        return "\(who) limits this session to \(clamped.targetBitrateKbps.formatted()) Kbps video and AAC \(clamped.audioBitrateKbps) Kbps."
    }

    private func bitrateInput(value: Binding<Int>) -> some View {
        ScrubbableComboInput(
            label: "",
            value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0.rounded()) }
            ),
            range: 500...50_000,
            step: 250,
            unit: "Kbps",
            labelWidth: 0,
            fieldWidth: 72
        )
    }

    private func applyCustomIfNeeded() {
        guard config.customBitrateOverrideEnabled else { return }
        var next = config
        next.applyCustomTargetKbps(customTargetKbps, ceiling: max(customCeilingKbps, customTargetKbps))
        commit(next)
    }

    private func commit(_ next: StreamEncoderConfig) {
        config = next
        onCommit(next)
    }
}
