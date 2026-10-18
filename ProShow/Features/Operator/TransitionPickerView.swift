import SwiftUI

/// Categorized transition grid with a live thumbnail hover preview.
struct TransitionPickerView: View {
    @Binding var selection: String
    var compact: Bool = false
    var onSelect: (TransitionPreset) -> Void = { _ in }

    @State private var previewID: String?
    @State private var previewStarted: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if compact {
                StableMenuContent(key: selection) { compactMenuPicker }
                    .equatable()
            } else {
                transitionGrid
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transitions")
    }

    private var transitionGrid: some View {
        VStack(alignment: .leading, spacing: DeskSpace.xs) {
            ForEach(TransitionEngineKind.allCases, id: \.self) { kind in
                let presets = TransitionCatalog.all.filter { $0.category == kind }
                if !presets.isEmpty {
                    DeskSectionTitle(title: kind.title)
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(presets) { preset in
                            card(preset)
                        }
                    }
                }
            }
        }
    }

    private var compactMenuPicker: some View {
        let current = TransitionCatalog.preset(id: selection)
        return Menu { let _ = MenuRenderProbe.hit("TransitionPickerView:43:TransitionPickerView.compactMenuPicker");
            ForEach(TransitionEngineKind.allCases, id: \.self) { kind in
                let presets = TransitionCatalog.all.filter { $0.category == kind }
                if !presets.isEmpty {
                    Menu(kind.title) { let _ = MenuRenderProbe.hit("TransitionPickerView:47:TransitionPickerView.compactMenuPicker");
                        ForEach(presets) { preset in
                            Button {
                                selection = preset.id
                                onSelect(preset)
                            } label: {
                                if preset.id == current.id {
                                    Label(preset.name, systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(current.name)
                    .font(InspectorTokens.labelFont)
                    .foregroundStyle(ProShowTheme.lyricWhite)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: InspectorTokens.controlHeight)
            .background(ThemeTokens.bgControl, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(ThemeTokens.borderSubtle, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .help("Slide transition")
        .accessibilityValue(current.name)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: compact ? 72 : 84), spacing: 6)]
    }

    private func card(_ preset: TransitionPreset) -> some View {
        let selected = TransitionCatalog.preset(id: selection).id == preset.id
        return Button {
            selection = preset.id
            onSelect(preset)
        } label: {
            VStack(spacing: 6) {
                thumbnail(preset, selected: selected)
                    .frame(height: compact ? 36 : 44)
                Text(preset.name)
                    .font(DeskType.micro)
                    .foregroundStyle(selected ? ProShowTheme.accent : ProShowTheme.lyricWhite)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 64 : 76)
            .padding(6)
            .background(selected ? ProShowTheme.accent.opacity(0.16) : ProShowTheme.well)
            .overlay {
                RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                    .strokeBorder(selected ? ProShowTheme.accent : ProShowTheme.hairline, lineWidth: selected ? 1.5 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        }
        .buttonStyle(DeskPressButtonStyle())
        .help("Preview \(preset.name)")
        .accessibilityLabel(preset.name)
        .accessibilityValue(preset.category.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering in
            if reduceMotion { return }
            if hovering {
                previewID = preset.id
                previewStarted = Date()
            } else if previewID == preset.id {
                previewID = nil
                previewStarted = nil
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ preset: TransitionPreset, selected: Bool) -> some View {
        let playing = previewID == preset.id && !reduceMotion
        TimelineView(.animation(minimumInterval: playing ? 1.0 / 30.0 : 1, paused: !playing)) { context in
            let progress = playing ? previewProgress(now: context.date, durationMs: max(preset.defaultDurationMs, 400)) : (selected ? 1 : 0)
            TransitionPreviewThumb(preset: preset, progress: progress)
        }
    }

    private func previewProgress(now: Date, durationMs: Int) -> Double {
        let elapsed = now.timeIntervalSince(previewStarted ?? now)
        let span = Double(durationMs) / 1000
        let cycle = elapsed.truncatingRemainder(dividingBy: span)
        return min(1, max(0, cycle / max(span, 0.001)))
    }
}

private struct TransitionPreviewThumb: View {
    let preset: TransitionPreset
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(red: 0.18, green: 0.22, blue: 0.30))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(red: 0.42, green: 0.62, blue: 0.88))
                    .frame(width: width * previewWidth(progress))
                    .opacity(previewOpacity(progress))
                    .offset(x: previewOffset(width: width, progress: progress))
                Image(systemName: preset.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ProShowTheme.lyricWhite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }

    private func previewWidth(_ t: Double) -> CGFloat {
        switch preset.category {
        case .standard where preset.id == "cut": t >= 1 ? 1 : 0
        case .alphaStinger: t >= 0.5 ? 1 : 0.15
        default: CGFloat(0.35 + 0.65 * t)
        }
    }

    private func previewOpacity(_ t: Double) -> Double {
        switch preset.id {
        case "cut": t >= 1 ? 1 : 0
        case "dissolve", "fade", "light_leak": t
        default: 1
        }
    }

    private func previewOffset(width: CGFloat, progress t: Double) -> CGFloat {
        switch preset.id {
        case "push", "whip_pan": width * (1 - t) * -0.35
        case "glitch": width * sin(t * 18) * 0.04
        default: 0
        }
    }
}
