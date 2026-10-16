import SwiftUI

/// Custom title bar: grouped capsules with an icon and name under each tool.
struct TopToolbarView: View {
    @Bindable var controller: ShowController
    @Bindable private var userSettings = UserSettingsStore.shared
    var projectName: String = ""
    var projectIsDirty: Bool = false
    var onOpenAudience: () -> Void
    var onOpenStage: () -> Void = {}
    var onOpenStream: () -> Void = {}
    var onOpenMultiViewer: () -> Void = {}

    private var libraryColumnWidth: CGFloat {
        max(DeskLayout.sidebarMin, CGFloat(userSettings.libraryWidth))
    }

    private var inspectorColumnWidth: CGFloat {
        max(DeskLayout.inspectorMin, CGFloat(userSettings.inspectorWidth))
    }

    var body: some View {
        #if os(macOS)
        ProjectTitleHeaderView(
            projectName: projectName,
            isDirty: projectIsDirty
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: TaskMenuMetrics.barHeight)
        .background { TitlebarDragRegion() }
        #else
        titleGroupsInBar
        #endif
    }

    private var titleGroupsInBar: some View {
        let _ = controller.streaming.isLive
        let _ = controller.isoRecorder.isRecording
        let _ = controller.isBroadcasting
        return HStack(spacing: 0) {
            SidebarTitleGroupSlot {
                WorkspaceTitleGroup(controller: controller)
            }
            .frame(width: libraryColumnWidth, alignment: .leading)

            ProjectTitleHeaderView(
                projectName: projectName,
                isDirty: projectIsDirty
            )
            .frame(maxWidth: .infinity)
            .layoutPriority(0)

            SidebarTitleGroupSlot(alignment: .trailing) {
                InspectorTitleGroup(controller: controller)
            }
            .frame(width: inspectorColumnWidth, alignment: .trailing)
        }
        .padding(.trailing, 12)
        .frame(height: TaskMenuMetrics.barHeight)
    }
}

struct DeskWindowActions {
    var openAudience: () -> Void = {}
    var openStage: () -> Void = {}
    var openStream: () -> Void = {}
    var openMultiViewer: () -> Void = {}
}

private struct DeskWindowActionsKey: EnvironmentKey {
    static let defaultValue = DeskWindowActions()
}

extension EnvironmentValues {
    var deskWindowActions: DeskWindowActions {
        get { self[DeskWindowActionsKey.self] }
        set { self[DeskWindowActionsKey.self] = newValue }
    }
}

/// Title-bar row on the runtime desk: sidebar icon, then the project name.
struct RuntimeTitlebarCluster: View {
    @Bindable var controller: ShowController
    @State private var metrics = TitlebarMetrics(leadingInset: 78, height: 28, climb: 0)

    var body: some View {
        HStack(spacing: 8) {
            DeskLibrarySidebarToggle()
            Text(controller.projectDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 280, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(controller.projectDisplayName)
        }
        .padding(.leading, metrics.leadingInset)
        .frame(height: metrics.height, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .offset(y: -metrics.climb)
        .background {
            #if os(macOS)
            TitlebarMetricsReader { metrics = $0 }
            #endif
        }
    }

}

/// Toggles the Show desk library column. On Rundown, lives above the item clock bar instead of the title bar.
struct DeskLibrarySidebarToggle: View {
    @Bindable private var userSettings = UserSettingsStore.shared

    var body: some View {
        let hidden = userSettings.librarySidebarHidden
        Button {
            userSettings.librarySidebarHidden.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .modifier(TitlebarSidebarButtonChrome())
        .help(hidden ? "Show sidebar" : "Hide sidebar")
        .accessibilityLabel("Sidebar")
        .accessibilityValue(hidden ? "Hidden" : "Shown")
    }
}

private struct TitlebarSidebarButtonChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
        } else {
            content
                .buttonStyle(DeskPressButtonStyle())
                .labelStyle(.iconOnly)
        }
    }
}

struct TitlebarMetrics: Equatable {
    var leadingInset: CGFloat
    var height: CGFloat
    /// How far the row must move up to sit with the traffic lights. Zero when the system title bar is gone.
    var climb: CGFloat
}

#if os(macOS)
struct TitlebarMetricsReader: NSViewRepresentable {
    var onChange: (TitlebarMetrics) -> Void

    func makeNSView(context: Context) -> TitlebarMetricsView {
        let view = TitlebarMetricsView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TitlebarMetricsView, context: Context) {
        view.onChange = onChange
        view.publish()
    }
}

final class TitlebarMetricsView: NSView {
    var onChange: ((TitlebarMetrics) -> Void)?
    private var last = TitlebarMetrics(leadingInset: -1, height: -1, climb: -1)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publish()
    }

    override func layout() {
        super.layout()
        publish()
    }

    func publish() {
        guard let window else { return }
        let band = window.frame.height - window.contentLayoutRect.height
        let climb = band > 1 ? band : 0
        let height = band > 1 ? band : 28
        var inset: CGFloat = 78
        if let zoom = window.standardWindowButton(.zoomButton) {
            inset = zoom.convert(zoom.bounds, to: nil).maxX + 10
        }
        let next = TitlebarMetrics(leadingInset: inset, height: height, climb: climb)
        guard next != last else { return }
        last = next
        onChange?(next)
    }
}
#endif

/// Liquid-glass workspace switcher. Lives at the top of the left column.
struct WorkspaceTitleGroup: View {
    @Bindable var controller: ShowController
    @Environment(\.deskWindowActions) private var windowActions

    var body: some View {
        DeskGlassGroup(spacing: DeskSpace.xs) {
            TaskMenuCapsule {
                HStack(spacing: 0) {
                    ForEach(Array(TaskMenuItem.workspaceTools.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            TaskMenuCapsuleDivider()
                        }
                        TaskMenuToolButton(
                            item: item,
                            style: .iconOnly,
                            controller: controller,
                            onOpenAudience: windowActions.openAudience,
                            onOpenStage: windowActions.openStage,
                            onOpenStream: windowActions.openStream,
                            onOpenMultiViewer: windowActions.openMultiViewer
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspaces")
    }
}

/// Liquid-glass output controls. Lives at the top of the right sidebar.
struct InspectorTitleGroup: View {
    @Bindable var controller: ShowController
    @Environment(\.deskWindowActions) private var windowActions

    var body: some View {
        let _ = controller.streaming.isLive
        let _ = controller.isoRecorder.isRecording
        let _ = controller.isBroadcasting
        broadcastCapsule
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Output")
    }

    private var broadcastCapsule: some View {
        TaskMenuCapsule {
            HStack(spacing: 0) {
                ForEach(Array(TaskMenuItem.outputTools.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        TaskMenuCapsuleDivider()
                    }
                    TaskMenuToolButton(
                        item: item,
                        style: .iconOnly,
                        controller: controller,
                        onOpenAudience: windowActions.openAudience,
                        onOpenStage: windowActions.openStage,
                        onOpenStream: windowActions.openStream,
                        onOpenMultiViewer: windowActions.openMultiViewer
                    )
                }
                TaskMenuCapsuleDivider()
                if controller.streaming.isLive {
                    CompactLiveStreamTelemetry(controller: controller)
                    TaskMenuCapsuleDivider()
                }
                DeskTitleBarLocalOutputMenu(controller: controller)
            }
        }
    }

}

#if os(macOS)
/// Opens the detachable stream-outline window (Runtime only).
struct RundownOutlineFloatToggle: View {
    @Bindable private var chrome = RundownFloatController.shared

    var body: some View {
        TaskMenuCapsule {
            Button {
                chrome.toggle()
            } label: {
                Image(systemName: chrome.isOpen ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chrome.isOpen ? ProShowTheme.accent : ProShowTheme.toolbarIcon)
                    .frame(width: TaskMenuMetrics.iconOnlyWidth, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help(chrome.isOpen ? "Close outline window" : "Open outline window")
            .accessibilityLabel("Stream outline window")
            .accessibilityValue(chrome.isOpen ? "Open" : "Closed")
        }
    }
}
#endif

/// Prompt column toggle from the Rundown middle pane — lives above the item clock bar on Runtime.
struct RundownPromptSidebarToggle: View {
    @Bindable var controller: ShowController

    var body: some View {
        TaskMenuCapsule {
            Button {
                controller.showsPromptSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(controller.showsPromptSidebar ? ProShowTheme.accent : ProShowTheme.toolbarIcon)
                    .frame(width: TaskMenuMetrics.iconOnlyWidth, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help(controller.showsPromptSidebar ? "Hide prompt" : "Show prompt")
            .accessibilityLabel("Prompt sidebar")
            .accessibilityValue(controller.showsPromptSidebar ? "Shown" : "Hidden")
            .accessibilityAddTraits(controller.showsPromptSidebar ? .isSelected : [])
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prompt")
    }
}

/// Pins a title group to the top of a sidebar and scrolls it when the column is narrower than the group.
struct SidebarTitleGroupSlot<Content: View>: View {
    var alignment: Alignment = .leading
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: geo.size.width, alignment: alignment)
            }
        }
        .frame(height: 38)
        .padding(.horizontal, DeskSpace.xs)
        .padding(.vertical, 6)
    }
}

/// Native window toolbar: glass capsules + labels under icons.
struct TaskMenuToolbarContent: ToolbarContent {
    @Bindable var controller: ShowController
    var onOpenAudience: () -> Void
    var onOpenStage: () -> Void = {}
    var onOpenStream: () -> Void = {}
    var onOpenMultiViewer: () -> Void = {}

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ForEach(TaskMenuItem.workspaceTools) { item in
                TaskMenuToolbarButton(item: item, controller: controller, onOpenAudience: onOpenAudience, onOpenStage: onOpenStage, onOpenStream: onOpenStream, onOpenMultiViewer: onOpenMultiViewer)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(TaskMenuItem.outputTools) { item in
                TaskMenuToolbarButton(item: item, controller: controller, onOpenAudience: onOpenAudience, onOpenStage: onOpenStage, onOpenStream: onOpenStream, onOpenMultiViewer: onOpenMultiViewer)
            }
            TaskMenuToolbarButton(item: .status, controller: controller, onOpenAudience: onOpenAudience, onOpenStage: onOpenStage, onOpenStream: onOpenStream, onOpenMultiViewer: onOpenMultiViewer)
        }

        if #available(macOS 26.0, iOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
    }
}

private struct DeskTitleBarProgramStatusChip: View {
    var title: String
    var color: Color

    var body: some View {
        Text(title)
            .font(DeskType.micro.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 108, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityLabel("Program output \(title)")
    }
}

private struct TaskMenuCapsuleDivider: View {
    static let barWidth: CGFloat = 1
    static let horizontalPadding: CGFloat = 2
    static var layoutWidth: CGFloat { barWidth + horizontalPadding * 2 }

    var body: some View {
        Rectangle()
            .fill(ProShowTheme.hairline.opacity(0.55))
            .frame(width: Self.barWidth, height: 18)
            .padding(.horizontal, Self.horizontalPadding)
    }
}

private struct CompactLiveStreamTelemetry: View {
    @Bindable var controller: ShowController

    private var telemetry: StreamTelemetryMonitor { controller.streaming.telemetry }

    var body: some View {
        TimelineView(.periodic(from: TimelineAnchor.start, by: 1.0)) { _ in
            HStack(spacing: 6) {
                Text("\(telemetry.measuredVideoBitrateKbps) Kbps")
                    .font(DeskType.micro.monospacedDigit())
                    .foregroundStyle(ProShowTheme.accent)
                Text(telemetry.stabilityLabel)
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Stream \(telemetry.measuredVideoBitrateKbps) kilobits per second, \(telemetry.stabilityLabel)")
        }
    }
}

private struct LiveStreamTelemetryStrip: View {
    @Bindable var controller: ShowController

    private var telemetry: StreamTelemetryMonitor { controller.streaming.telemetry }
    private var preset: StreamEncoderConfig { controller.streaming.streamEncoderConfig }

    var body: some View {
        TimelineView(.periodic(from: TimelineAnchor.start, by: 0.5)) { context in
            let _ = context.date
            let _ = telemetry.refreshMeasurementWindowIfNeeded()
            HStack(spacing: 10) {
                Text(shortPresetLabel)
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                Text("\(telemetry.measuredVideoBitrateKbps.formatted()) Kbps")
                    .font(DeskType.mono)
                    .foregroundStyle(bitrateColor)
                Text(telemetry.stabilityLabel)
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                Text("\(telemetry.droppedFrameCount) dropped")
                    .font(DeskType.micro)
                    .foregroundStyle(telemetry.droppedFrameCount > 0 ? ProShowTheme.liveRed : ProShowTheme.secondaryLabel)
                if controller.streaming.outboundNetworkAudioDropCount > 0 {
                    Text("\(controller.streaming.outboundNetworkAudioDropCount) audio drops")
                        .font(DeskType.micro)
                        .foregroundStyle(ProShowTheme.liveRed)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ProShowTheme.panel.opacity(0.92))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Stream video \(telemetry.measuredVideoBitrateKbps) kilobits per second, \(telemetry.stabilityLabel), \(telemetry.droppedFrameCount) dropped frames, \(controller.streaming.outboundNetworkAudioDropCount) audio tag drops"
            )
        }
    }

    private var shortPresetLabel: String {
        "\(preset.width)×\(preset.height) @ \(preset.frameRate)"
    }

    private var bitrateColor: Color {
        if telemetry.measuredVideoBitrateKbps > preset.maxBitrateCeilingKbps {
            return ProShowTheme.liveRed
        }
        if telemetry.stabilityLabel == "Near cap" {
            return Color.orange
        }
        return ProShowTheme.accent
    }
}

/// Mute this Mac's speakers or pick an output device (stream / layer audio unchanged).
private struct DeskTitleBarLocalOutputMenu: View {
    @Bindable var controller: ShowController
    @Bindable private var monitor = AudioMonitoringEngine.shared
    @State private var outputDevices: [StudioAudioDevice] = []

    var body: some View {
        Menu {
            Toggle(
                "Mute This Mac's Speakers",
                isOn: Binding(
                    get: { monitor.localSpeakerMuted },
                    set: { monitor.localSpeakerMuted = $0; applyLocalOutputPolicy() }
                )
            )
            Divider()
            Text("Output device")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                monitor.selectOutputDevice(uid: nil)
                applyLocalOutputPolicy()
            } label: {
                outputRow(title: "System Default", selected: monitor.preferredOutputDeviceUID == nil)
            }
            ForEach(outputDevices) { device in
                Button {
                    monitor.selectOutputDevice(uid: device.id)
                    applyLocalOutputPolicy()
                } label: {
                    outputRow(title: device.name, selected: monitor.preferredOutputDeviceUID == device.id)
                }
            }
        } label: {
            Image(systemName: monitor.localSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(monitor.localSpeakerMuted ? ProShowTheme.liveRed : ProShowTheme.toolbarIcon)
                .frame(width: TaskMenuMetrics.iconOnlyWidth, height: 28)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .buttonStyle(DeskPressButtonStyle())
        .help(localOutputHelp)
        .accessibilityLabel(monitor.localSpeakerMuted ? "Mac speakers muted" : "Mac speaker output")
        .accessibilityHint("Choose mute or output device. Does not mute stream or program layers.")
        .onAppear { refreshDeviceList() }
    }

    private var localOutputHelp: String {
        let device = monitor.outputDeviceLabel(for: monitor.preferredOutputDeviceUID)
        if monitor.localSpeakerMuted {
            return "Mac speakers muted (\(device)). Stream audio is unchanged."
        }
        return "Mac output: \(device). Click to mute speakers or change device."
    }

    @ViewBuilder
    private func outputRow(title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func refreshDeviceList() {
        outputDevices = MacAudioOutputRouting.outputDevices()
    }

    private func applyLocalOutputPolicy() {
        controller.audioIO.syncLocalSpeakerPolicy()
        controller.playback.applyMixGain(controller.playback.mixGain)
    }
}

private enum TaskMenuButtonStyle {
    case labeled
    case iconOnly
}

private enum TaskMenuMetrics {
    static let barHeight: CGFloat = DeskLayout.toolbar
    static let itemWidth: CGFloat = 58
    static let iconOnlyWidth: CGFloat = 32
    static let wideItemWidth: CGFloat = 72
    static let iconSize: CGFloat = 15
    static let capsuleHorizontalPadding: CGFloat = 8
}

/// Width of the Show / Edit / Rundown / Map / Props / More title group, including its leading inset.
enum WorkspaceTitleGroupMetrics {
    static var minimumSidebarWidth: CGFloat {
        let count = CGFloat(TaskMenuItem.workspaceTools.count)
        let dividers = max(0, count - 1)
        return count * TaskMenuMetrics.iconOnlyWidth
            + dividers * TaskMenuCapsuleDivider.layoutWidth
            + TaskMenuMetrics.capsuleHorizontalPadding * 2
            + DeskSpace.xs
    }
}

private enum TaskMenuItem: String, Identifiable {
    case search, text, theme, show, edit, reflow, rundown, widgets, map, propsEditor, more
    case live, stream, record, audience, stage, matrix
    case status

    var id: String { rawValue }

    static let workspaceTools: [TaskMenuItem] = [
        .show, .edit, .rundown, .map, .propsEditor, .more,
    ]

    /// ⌘1…⌘5 for the first five workspace capsule items (see `WorkspaceTitleBarShortcuts`).
    var workspaceCommandKeyLabel: String? {
        guard let index = Self.workspaceTools.firstIndex(of: self), index < 5 else { return nil }
        return "⌘\(index + 1)"
    }

    var workspaceHelpBase: String? {
        switch self {
        case .show: "Operator control mode"
        case .edit: "Slide canvas editor"
        case .rundown: "Live rundown, drift, and talent cues"
        case .map: "Placeholder map and source routing"
        case .propsEditor: "Props editor"
        default: nil
        }
    }

    var toolHelpText: String {
        if let key = workspaceCommandKeyLabel, let base = workspaceHelpBase {
            return "\(base) (\(key))"
        }
        switch self {
        case .search: return "Search songs, presentations, and media"
        case .text: return "Text properties"
        case .reflow: return "Batch text and slide division"
        case .widgets: return "Live chat, alerts, and overlay widgets"
        case .more: return "Editors, settings, and window shortcuts"
        default: return title
        }
    }

    static let outputTools: [TaskMenuItem] = [
        .live, .stream, .record, .matrix,
    ]

    var title: String {
        switch self {
        case .search: "Search"
        case .text: "Text"
        case .theme: "Theme"
        case .show: "Show"
        case .edit: "Edit"
        case .reflow: "Reflow"
        case .rundown: "Rundown"
        case .widgets: "Widgets"
        case .map: "Map"
        case .propsEditor: "Props"
        case .more: "More"
        case .live: "Live"
        case .stream: "Stream"
        case .record: "Record"
        case .audience: "Audience"
        case .stage: "Stage"
        case .matrix: "Studio"
        case .status: "Status"
        }
    }

    var systemImage: String? {
        switch self {
        case .search: "magnifyingglass"
        case .text: "textformat.size"
        case .theme: "rectangle.on.rectangle"
        case .show: "play.fill"
        case .edit: "pencil"
        case .reflow: "arrow.triangle.swap"
        case .rundown: "clock.fill"
        case .widgets: "rectangle.3.group.fill"
        case .map: "map.fill"
        case .propsEditor: "cube.transparent.fill"
        case .more: "ellipsis"
        case .live: "antenna.radiowaves.left.and.right"
        case .status: "exclamationmark.circle"
        case .stream, .record, .audience, .stage, .matrix: nil
        }
    }

    var itemWidth: CGFloat {
        switch self {
        case .audience: TaskMenuMetrics.wideItemWidth
        default: TaskMenuMetrics.itemWidth
        }
    }

    @MainActor
    func activate(controller: ShowController, onOpenAudience: () -> Void, onOpenStage: () -> Void = {}, onOpenStream: () -> Void = {}, onOpenMultiViewer: () -> Void = {}) {
        switch self {
        case .search:
            controller.toggleSearch()
        case .text:
            controller.toggleTextInspector()
        case .show:
            controller.setMode(.show)
        case .edit:
            controller.setMode(.edit)
        case .reflow:
            controller.setMode(.reflow)
        case .rundown:
            controller.setMode(.rundown)
        case .widgets:
            controller.setMode(.widgets)
        case .map:
            controller.setMode(.map)
        case .propsEditor:
            controller.openEditor(.props)
        case .live:
            controller.openGoLiveSetup()
        case .stream:
            onOpenStream()
        case .record:
            controller.toggleProgramRecording()
        case .audience:
            controller.toggleAudienceOutput()
            if controller.isAudienceOutputOn { onOpenAudience() }
        case .stage:
            controller.toggleStageOutput()
            if controller.isStageOutputOn { onOpenStage() }
        case .matrix:
            onOpenMultiViewer()
        default:
            break
        }
    }

    @MainActor
    func isSelected(controller: ShowController) -> Bool {
        switch self {
        case .search: controller.isSearchOpen
        case .text: controller.isTextInspectorOpen
        case .show, .edit, .rundown, .map, .propsEditor, .more:
            workspaceToolbarSelection.map { controller.workspaceToolbarSelection == $0 } ?? false
        case .reflow, .widgets:
            controller.workspaceToolbarSelection == .show
        case .live:
            controller.isGoLiveSetupPresented
                || controller.streaming.isLive
                || controller.streaming.state == .starting
        case .stream: controller.isStreamOutputOn
        case .record: controller.isoRecorder.isRecording
        case .matrix: controller.isMultiViewerOn
        default: false
        }
    }

    var workspaceToolbarSelection: WorkspaceToolbarSelection? {
        switch self {
        case .show: .show
        case .edit: .edit
        case .rundown: .rundown
        case .map: .map
        case .propsEditor: .props
        case .more: .more
        default: nil
        }
    }
}

private struct TaskMenuToolbarButton: View {
    let item: TaskMenuItem
    @Bindable var controller: ShowController
    var onOpenAudience: () -> Void
    var onOpenStage: () -> Void = {}
    var onOpenStream: () -> Void = {}
    var onOpenMultiViewer: () -> Void = {}

    var body: some View {
        switch item {
        case .theme:
            Menu { themeMenuItems } label: { toolbarLabel }
                .help("Apply a global layout / style template")
        case .more:
            Menu { moreMenuItems } label: { toolbarLabel }
                .help("Props, mask, settings, and window shortcuts")
        case .status:
            Menu { statusMenuItems } label: { toolbarLabel }
                .help("System alerts and output status")
        default:
            Button {
                item.activate(controller: controller, onOpenAudience: onOpenAudience, onOpenStage: onOpenStage, onOpenStream: onOpenStream, onOpenMultiViewer: onOpenMultiViewer)
            } label: {
                toolbarLabel
            }
            .help(helpText)
        }
    }

    private var helpText: String {
        switch item {
        case .live: return "Open broadcast setup"
        case .stream: return "Stream output — encoded feed sent to destinations"
        case .record: return controller.isoRecorder.isRecording
            ? "Stop program recording"
            : "Start program recording"
        case .audience: return "Audience screen output"
        case .stage: return "Stage display output"
        case .matrix: return "Studio window. Outline, live, slides, and audio."
        default: return item.toolHelpText
        }
    }

    @ViewBuilder
    private var toolbarLabel: some View {
        if let systemImage = item.systemImage {
            Label {
                toolbarTitle
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(iconTint)
            }
        } else {
            Label {
                toolbarTitle
            } icon: {
                TaskMenuCustomIcon(item: item, controller: controller)
            }
        }
    }

    @ViewBuilder
    private var toolbarTitle: some View {
        if item == .live, controller.streaming.isLive {
            TimelineView(.periodic(from: TimelineAnchor.start, by: 1)) { context in
                Text(ProShowCopy.liveClock(StreamingEngine.broadcastTimecode(from: controller.streaming.startedAt, now: context.date)))
                    .monospacedDigit()
            }
        } else if item == .live, controller.streaming.state == .starting {
            Text(ProShowCopy.Status.connecting)
        } else {
            Text(item.title)
        }
    }

    private var iconTint: Color {
        if item == .live, controller.streaming.isLive { return ProShowTheme.liveRed }
        if item == .status, !controller.statusAlerts.isEmpty { return Color.orange }
        if item.isSelected(controller: controller) { return ProShowTheme.accent }
        return ProShowTheme.toolbarIcon
    }

    @ViewBuilder
    private var themeMenuItems: some View {
        Button("Theme Editor") { controller.openEditor(.theme) }
        Divider()
        ForEach(controller.themeMenuVariants, id: \.id) { variant in
            Button(variant.name) { controller.applyTheme(variant.name) }
        }
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        Button("Stage Layout Editor") { controller.openEditor(.stage) }
        Button("Theme Editor") { controller.openEditor(.theme) }
        Button("Overlay Editor") { controller.openEditor(.overlays) }
        Button("Mask Editor") { controller.openEditor(.masks) }
        Button("Settings…") { controller.presentProjectSettings() }
        Button("Key Mapping") {}
        Divider()
        Button("Open Stream Window", action: onOpenStream)
        Button("Open Audience Window", action: onOpenAudience)
        Button("Open Stage Window", action: onOpenStage)
        Button("Open Studio Window", action: onOpenMultiViewer)
    }

    @ViewBuilder
    private var statusMenuItems: some View {
        Button("Pre-Flight…") { controller.openPreFlight() }
        if controller.isoRecorder.isRecording {
            Button("Stop Program Recording") { controller.stopProgramRecording() }
        } else {
            Button("Record Program Output…") { _ = controller.startProgramRecording() }
        }
        if controller.isoRecorder.isIsoMultiChannelRecording {
            Button("Stop ISO Recording") { controller.stopIsoChannelRecording() }
        } else {
            Button("Record ISO (Clean Cameras)…") { _ = controller.startIsoChannelRecording() }
        }
        Divider()
        if controller.statusAlerts.isEmpty {
            Text("All outputs OK")
            Text(controller.isStreamOutputOn ? "Stream · On" : "Stream · Off")
            Text(controller.isAudienceOutputOn ? "Audience · On" : "Audience · Off")
            Text(controller.isStageOutputOn ? "Stage · On" : "Stage · Off")
            Text(controller.isMultiViewerOn ? "Studio · On" : "Studio · Off")
        } else {
            ForEach(controller.statusAlerts) { alert in
                Text("\(alert.title) — \(alert.detail)")
            }
        }
    }
}

private struct TaskMenuToolButton: View {
    let item: TaskMenuItem
    var style: TaskMenuButtonStyle = .labeled
    @Bindable var controller: ShowController
    var onOpenAudience: () -> Void
    var onOpenStage: () -> Void = {}
    var onOpenStream: () -> Void = {}
    var onOpenMultiViewer: () -> Void = {}

    var body: some View {
        switch item {
        case .theme:
            Menu {
                Button("Theme Editor") { controller.openEditor(.theme) }
                Divider()
                ForEach(controller.themeMenuVariants, id: \.id) { variant in
                    Button(variant.name) { controller.applyTheme(variant.name) }
                }
            } label: {
                taskMenuLabel
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
            .buttonStyle(DeskPressButtonStyle())
            .help("Apply a global layout / style template")
            .accessibilityLabel("Theme")
        case .more:
            Menu {
                Button("Stage Layout Editor") { controller.openEditor(.stage) }
                Button("Theme Editor") { controller.openEditor(.theme) }
                Button("Overlay Editor") { controller.openEditor(.overlays) }
                Button("Mask Editor") { controller.openEditor(.masks) }
                Button("Settings…") { controller.presentProjectSettings() }
                Button("Key Mapping") {}
                Divider()
                Button("Open Stream Window", action: onOpenStream)
                Button("Open Audience Window", action: onOpenAudience)
                Button("Open Stage Window", action: onOpenStage)
                Button("Open Studio Window", action: onOpenMultiViewer)
            } label: {
                taskMenuLabel
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
            .buttonStyle(DeskPressButtonStyle())
            .help("Props, mask, settings, and window shortcuts")
            .accessibilityLabel("More tools")
            .accessibilityAddTraits(item.isSelected(controller: controller) ? .isSelected : [])
        case .status:
            Menu {
                Button("Pre-Flight…") { controller.openPreFlight() }
                if controller.isoRecorder.isRecording {
                    Button("Stop Program Recording") { controller.stopProgramRecording() }
                } else {
                    Button("Record Program Output…") { _ = controller.startProgramRecording() }
                }
                if controller.isoRecorder.isIsoMultiChannelRecording {
                    Button("Stop ISO Recording") { controller.stopIsoChannelRecording() }
                } else {
                    Button("Record ISO (Clean Cameras)…") { _ = controller.startIsoChannelRecording() }
                }
                Divider()
                if controller.statusAlerts.isEmpty {
                    Text("All outputs OK")
                } else {
                    ForEach(controller.statusAlerts) { alert in
                        Text(alert.title)
                    }
                }
            } label: {
                taskMenuLabel
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
            .buttonStyle(DeskPressButtonStyle())
            .help(item.title)
            .accessibilityLabel(item.title)
        default:
            Button {
                item.activate(controller: controller, onOpenAudience: onOpenAudience, onOpenStage: onOpenStage, onOpenStream: onOpenStream, onOpenMultiViewer: onOpenMultiViewer)
            } label: {
                taskMenuLabel
            }
            .buttonStyle(DeskPressButtonStyle())
            .help(item.toolHelpText)
            .accessibilityLabel(taskMenuAccessibilityLabel)
            .accessibilityAddTraits(item.isSelected(controller: controller) ? .isSelected : [])
        }
    }

    @ViewBuilder
    private var taskMenuLabel: some View {
        switch style {
        case .labeled:
            TaskMenuGlyph(item: item, controller: controller)
        case .iconOnly:
            TaskMenuIconGlyph(item: item, controller: controller)
        }
    }

    private var taskMenuAccessibilityLabel: String {
        if item == .live, controller.streaming.isLive { return "Live" }
        if item == .live, controller.streaming.state == .starting { return "Connecting to stream" }
        return item.title
    }
}

private struct TaskMenuIconGlyph: View {
    let item: TaskMenuItem
    @Bindable var controller: ShowController

    var body: some View {
        ZStack {
            if item.isSelected(controller: controller) {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 26, height: 26)
            }
            TaskMenuCustomIcon(item: item, controller: controller)
        }
        .frame(width: TaskMenuMetrics.iconOnlyWidth, height: 28)
        .contentShape(Rectangle())
    }
}

private struct TaskMenuGlyph: View {
    let item: TaskMenuItem
    @Bindable var controller: ShowController

    var body: some View {
        VStack(spacing: 4) {
            TaskMenuCustomIcon(item: item, controller: controller)
                .frame(height: 18)
            liveLabel
                .font(DeskType.micro)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(glyphColor)
        .frame(width: item.itemWidth)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var liveLabel: some View {
        if item != .live {
            Text(item.title)
        } else if controller.streaming.isLive {
            TimelineView(.periodic(from: TimelineAnchor.start, by: 1)) { context in
                Text(ProShowCopy.liveClock(StreamingEngine.broadcastTimecode(from: controller.streaming.startedAt, now: context.date)))
                    .monospacedDigit()
            }
        } else if controller.streaming.state == .starting {
            Text(ProShowCopy.Status.connecting)
        } else {
            Text(item.title)
        }
    }

    private var glyphColor: Color {
        if item == .live, controller.streaming.isLive { return ProShowTheme.liveRed }
        if item == .live, controller.streaming.state == .starting { return ProShowTheme.accent }
        if item == .record, controller.isoRecorder.isRecording { return ProShowTheme.liveRed }
        if item.isSelected(controller: controller) { return ProShowTheme.accent }
        return ProShowTheme.toolbarIcon
    }
}

private struct TaskMenuCustomIcon: View {
    let item: TaskMenuItem
    @Bindable var controller: ShowController

    var body: some View {
        switch item {
        case .record:
            Image(systemName: controller.isoRecorder.isRecording ? "record.circle.fill" : "record.circle")
                .font(.system(size: TaskMenuMetrics.iconSize + 1, weight: .semibold))
                .foregroundStyle(controller.isoRecorder.isRecording ? ProShowTheme.liveRed : ProShowTheme.toolbarIcon)
                .accessibilityLabel(controller.isoRecorder.isRecording ? "Recording" : "Record")
        case .live:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: TaskMenuMetrics.iconSize, weight: .semibold))
                .foregroundStyle(liveIconColor)
                .accessibilityLabel(controller.streaming.isLive ? "Live on air" : "Live")
        case .matrix:
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: TaskMenuMetrics.iconSize, weight: .semibold))
                .foregroundStyle(controller.isMultiViewerOn ? ProShowTheme.accent : ProShowTheme.toolbarIcon)
                .accessibilityHidden(true)
        case .stream, .audience, .stage:
            Circle()
                .fill(lampOn ? (item == .stream && controller.streaming.isLive ? ProShowTheme.liveRed : ProShowTheme.statusOn) : ProShowTheme.statusOff)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle().strokeBorder(lampOn ? ProShowTheme.statusOn.opacity(0.55) : Color.clear, lineWidth: 1)
                }
                .accessibilityLabel(lampOn ? "\(item.title) on" : "\(item.title) off")
        case .status:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: TaskMenuMetrics.iconSize, weight: .semibold))
                .foregroundStyle(controller.statusAlerts.isEmpty ? ProShowTheme.toolbarIcon : Color.orange)
        default:
            if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: TaskMenuMetrics.iconSize, weight: .medium))
                    .symbolRenderingMode(.monochrome)
            }
        }
    }

    private var liveIconColor: Color {
        if controller.streaming.isLive { return ProShowTheme.liveRed }
        if controller.streaming.state == .starting { return ProShowTheme.accent }
        return ProShowTheme.toolbarIcon
    }

    private var lampOn: Bool {
        switch item {
        case .stream:
            controller.isStreamOutputOn
        case .audience:
            controller.isAudienceOutputOn && !controller.isAudienceCleared
        case .stage:
            controller.isStageOutputOn
        case .matrix:
            controller.isMultiViewerOn
        default:
            false
        }
    }
}

private struct TaskMenuCapsule<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, TaskMenuMetrics.capsuleHorizontalPadding)
        .padding(.vertical, 5)
        .modifier(TaskMenuGlassModifier())
    }
}

private struct TaskMenuGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.deskChromeGlass(in: Capsule(style: .continuous), interactive: true)
    }
}

private struct LatinCross: Shape {
    func path(in rect: CGRect) -> Path {
        let stem = max(1.6, rect.width * 0.22)
        let bar = max(1.6, rect.height * 0.20)
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: (rect.width - stem) / 2, y: 0, width: stem, height: rect.height),
            cornerSize: CGSize(width: 0.8, height: 0.8)
        )
        path.addRoundedRect(
            in: CGRect(x: 0, y: rect.height * 0.18, width: rect.width, height: bar),
            cornerSize: CGSize(width: 0.8, height: 0.8)
        )
        return path
    }
}

private struct LocalPreviewRenderScaleButton: View {
    @Bindable var controller: ShowController
    @Bindable private var userSettings = UserSettingsStore.shared

    private var labelText: String {
        "\(Int(userSettings.localPreviewRenderPercent))%"
    }

    var body: some View {
        Menu {
            Text("Local preview quality")
                .font(DeskType.micro)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Divider()
            ForEach([25.0, 33.0, 50.0, 67.0, 100.0], id: \.self) { value in
                Button {
                    userSettings.localPreviewRenderPercent = value
                    controller.applyLocalPreviewRenderQuality()
                } label: {
                    if Int(value) == Int(userSettings.localPreviewRenderPercent) {
                        Label("\(Int(value))%", systemImage: "checkmark")
                    } else {
                        Text("\(Int(value))%")
                    }
                }
            }
        } label: {
            ZStack {
                Image(systemName: "percent")
                    .font(.system(size: TaskMenuMetrics.iconSize, weight: .semibold))
                    .foregroundStyle(ProShowTheme.toolbarIcon)
                    .accessibilityHidden(true)
                Text(labelText)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .offset(y: 7)
            }
            .frame(width: TaskMenuMetrics.iconOnlyWidth, height: 28)
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .buttonStyle(DeskPressButtonStyle())
        .help("Local preview render quality — lowers GPU/CPU on this Mac only; streams and recordings stay full resolution")
        .accessibilityLabel("Local preview quality \(labelText)")
    }
}

private struct TaskMenuTitlebarBackground: View {
    var body: some View {
        ZStack {
            ProShowTheme.titlebar
            #if os(macOS)
            TitlebarDragRegion()
            #endif
        }
    }
}

#if os(macOS)
private struct TitlebarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDraggableView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override var isOpaque: Bool { false }
}
#endif
