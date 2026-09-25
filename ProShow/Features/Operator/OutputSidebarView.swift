import SwiftUI

enum OutputLayerTab: String, CaseIterable, Identifiable {
    case audio, messages, timers, stage, props, master
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .audio: return "music.note"
        case .messages: return "text.bubble"
        case .timers: return "timer"
        case .stage: return "rectangle.split.2x1"
        case .props: return "square.on.square"
        case .master: return "m.square"
        }
    }

    var title: String {
        switch self {
        case .audio: return "Audio"
        case .messages: return "Messages"
        case .timers: return "Timers"
        case .stage: return "Stage"
        case .props: return "Props"
        case .master: return "Master"
        }
    }
}

/// Right column: program preview, output target, layer tabs (Props, etc.).
struct OutputSidebarView: View {
    @Bindable var controller: ShowController
    @State private var selectedTab: OutputLayerTab = .props
    @State private var transitionSeconds: Double = 1.0
    @State private var selectedScreen = "Screen 1"

    var body: some View {
        VStack(spacing: 0) {
            previewBlock
            PaneHairline()
            layerTabs
            PaneHairline()
            layerBody
            PaneHairline()
            footer
        }
        .background(ProShowTheme.panel)
    }

    private var previewBlock: some View {
        VStack(spacing: 8) {
            HStack {
                Text("PROGRAM")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ProShowTheme.liveRed)
                Spacer()
                outputEdgeIcons
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            AudienceView(slide: controller.liveSlide, showsChrome: false)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
                )
                .padding(.horizontal, 10)

            HStack {
                Picker("Screen", selection: $selectedScreen) {
                    Text("Screen 1").tag("Screen 1")
                    Text("Screen 2").tag("Screen 2")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 120)

                Spacer()

                mediaTransport
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private var outputEdgeIcons: some View {
        HStack(spacing: 8) {
            ForEach(["speaker.wave.2", "text.bubble", "megaphone", "photo", "video"], id: \.self) { name in
                Image(systemName: name)
                    .font(.caption2)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
        }
    }

    private var mediaTransport: some View {
        HStack(spacing: 10) {
            Image(systemName: "gobackward.15")
            Image(systemName: "pause.fill")
            Image(systemName: "goforward.15")
        }
        .font(.caption)
        .foregroundStyle(ProShowTheme.toolbarIcon)
    }

    private var layerTabs: some View {
        HStack(spacing: 0) {
            ForEach(OutputLayerTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(tab == .master ? "M" : String(tab.title.prefix(1)))
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(selectedTab == tab ? ProShowTheme.accent : ProShowTheme.secondaryLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selectedTab == tab ? ProShowTheme.well : Color.clear)
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .background(ProShowTheme.canvas)
    }

    @ViewBuilder
    private var layerBody: some View {
        switch selectedTab {
        case .props:
            propsGrid
        case .master:
            masterClears
        default:
            VStack {
                Spacer()
                Text(selectedTab.title)
                    .font(.caption)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                Text("Coming in a later slice")
                    .font(.caption2)
                    .foregroundStyle(ProShowTheme.secondaryLabel.opacity(0.7))
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var propsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 88), spacing: 10)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(DeskSampleData.props) { prop in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(ProShowTheme.well)
                            .aspectRatio(16 / 10, contentMode: .fit)
                            .overlay {
                                Image(systemName: "rectangle.on.rectangle")
                                    .foregroundStyle(ProShowTheme.secondaryLabel)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
                            )
                        Text(prop.name)
                            .font(.caption2)
                            .foregroundStyle(ProShowTheme.secondaryLabel)
                    }
                }
            }
            .padding(10)
        }
        .frame(minHeight: 120, idealHeight: 150)
    }

    private var masterClears: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLEAR")
                .font(.caption2.weight(.bold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            HStack(spacing: 8) {
                ClearChip(title: "All") { controller.clearAudience() }
                ClearChip(title: "Slide") { controller.clearAudience() }
                ClearChip(title: "Restore") { controller.restoreAudience() }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            Text(String(format: "%.1fs", transitionSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Slider(value: $transitionSeconds, in: 0...3, step: 0.1)
                .tint(ProShowTheme.accent)
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(ProShowTheme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct ClearChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ProShowTheme.well)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
