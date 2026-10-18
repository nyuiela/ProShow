import SwiftUI

/// Right inspector: live preview, clear strip, media transport, and action tabs.
struct RightInspectorView: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            VStack(spacing: 0) {
                SidebarTitleGroupSlot(alignment: .trailing) {
                    InspectorTitleGroup(controller: controller)
                }
                LivePreviewMonitor(controller: controller)
                ActionInspectorBody(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                ActionInspectorTabBar(controller: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ShowSidebarPalette.background(scheme)
                .ignoresSafeArea(edges: .top)
        }
        .modifier(ShowSidebarSystemScheme())
        .onAppear {
            controller.sanitizeOperatorInspectorPresentation()
            controller.tickProgram()
        }
    }
}

private struct PreviewColumnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

fileprivate struct LivePreviewMonitor: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var transportHovered = false
    @State private var phoneSelected = false

    private var horizontalInset: CGFloat { InspectorPreviewLayout.horizontalInset }
    private var containerPadding: CGFloat { 8 }
    private var stripWidth: CGFloat { InspectorPreviewLayout.stripWidth }
    private var stripGap: CGFloat { InspectorPreviewLayout.stripGap }

    var body: some View {
        GeometryReader { geo in
            let columnWidth = max(geo.size.width, 1)
            monitorBody(columnWidth: columnWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { content in
                        Color.clear.preference(key: PreviewColumnHeightKey.self, value: content.size.height)
                    }
                }
                .frame(width: columnWidth, height: geo.size.height, alignment: .top)
        }
        .frame(height: columnHeight)
        .frame(maxWidth: .infinity, alignment: .top)
        .onPreferenceChange(PreviewColumnHeightKey.self) { newValue in
            guard newValue > 1 else { return }
            columnHeight = newValue
        }
    }

    @State private var columnHeight: CGFloat = 280

    @ViewBuilder
    private func monitorBody(columnWidth: CGFloat) -> some View {
        let _ = controller.liveQuotePresentationStamp
        let layout = monitorLayout(columnWidth: columnWidth)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: stripGap) {
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if let phone = layout.phone {
                            PhoneCanvasMonitorChrome(controller: controller, size: phone)
                        } else {
                            previewViewport(fitted: layout.stream)
                        }
                    }
                    // Phone sits trailing so the top-left toggle never covers it.
                    .frame(width: layout.footerWidth, alignment: .trailing)
                    .overlay(alignment: .topLeading) {
                        MonitorModeToggle(controller: controller, phoneAvailable: phoneAvailable, phoneSelected: $phoneSelected)
                            .padding(8)
                    }
                    DeskSignalProbeInspectorFooter(controller: controller)
                        .frame(width: layout.footerWidth, alignment: .leading)
                }
                ClearLayerStrip(controller: controller, layoutHeight: layout.stripHeight)
                    .frame(width: stripWidth, alignment: .top)
            }
            .padding(containerPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                ShowSidebarPalette.selection(scheme),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, horizontalInset)
            .padding(.top, InspectorPreviewLayout.monitorTopPadding)
            .padding(.bottom, 8)
        }
        .frame(width: columnWidth, alignment: .top)
    }

    private func monitorLayout(columnWidth: CGFloat) -> (stream: CGSize, phone: CGSize?, stripHeight: CGFloat, footerWidth: CGFloat) {
        let aspect = previewAspect
        let contentWidth = max(0, columnWidth - horizontalInset * 2 - containerPadding * 2)
        let previewBoxWidth = max(0, contentWidth - stripWidth - stripGap)
        let stream = InspectorPreviewLayout.fittedProgramSize(boxWidth: previewBoxWidth, programAspect: aspect)
        let rowHeight = max(stream.height, InspectorPreviewLayout.clearStripMinHeight)
        if showsPhone {
            // One canvas at a time: 9:16 fills the row height, centered in the stream box.
            let phone = CGSize(width: rowHeight * 9.0 / 16.0, height: rowHeight)
            return (stream, phone, rowHeight, stream.width)
        }
        return (stream, nil, rowHeight, stream.width)
    }

    /// Real Phone canvas on the slide this monitor shows. The From Stream fallback does not count.
    private var phoneAvailable: Bool {
        guard controller.showsPhoneCanvasMonitor else { return false }
        let slide = controller.inspector.previewFeed == .audience ? controller.operatorPreviewSlide : controller.liveSlide
        return controller.phoneCanvasBoard(on: slide) != nil
    }

    private var showsPhone: Bool { phoneSelected && phoneAvailable }

    private func previewViewport(fitted: CGSize) -> some View {
        ZStack(alignment: .top) {
            ProShowTheme.stageBlack
            previewSurface
                .aspectRatio(previewAspect, contentMode: .fit)
                .frame(width: fitted.width, height: fitted.height, alignment: .top)
        }
        .frame(width: fitted.width, height: fitted.height, alignment: .top)
        .overlay(alignment: .topTrailing) {
            ProgramPreviewExpandButton()
                .padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            DualChannelMeter(
                controller: controller,
                barHeight: max(36, fitted.height - InspectorPreviewLayout.meterInset * 2)
            )
            .padding(InspectorPreviewLayout.meterInset)
        }
        .overlay(alignment: .bottomTrailing) {
            if controller.inspector.previewFeed == .audience {
                PreviewHeadsetButton()
                    .padding(InspectorPreviewLayout.meterInset)
            }
        }
        .overlay(alignment: .bottom) {
            if showsTransport {
                MediaTransportDock(controller: controller)
                    .padding(.horizontal, 8)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .background {
                        LinearGradient(
                            colors: [Color.black.opacity(0), Color.black.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .opacity(transportHovered ? 1 : 0)
                    .allowsHitTesting(transportHovered)
                    .accessibilityHidden(!transportHovered)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: transportHovered)
            }
        }
        .background {
            #if os(macOS)
            PreviewHoverTracker { hovering in
                transportHovered = hovering
            }
            #endif
        }
        .frame(width: fitted.width, alignment: .top)
        .background(ProShowTheme.stageBlack, in: RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch controller.inspector.previewFeed {
        case .audience:
            OperatorPreviewPicture(controller: controller, playsCueAudio: true, showsCueLabel: false)
        case .stream, .stage, .matrix:
            RightPaneProgramView(controller: controller)
        }
    }

    /// File-backed video or audio on the live program. Preview plays its own cue and does not scrub the bus.
    private var showsTransport: Bool {
        controller.inspector.previewFeed == .stream && controller.playback.usesFilePlayer
    }

    private var previewAspect: CGFloat {
        let width = CGFloat(max(controller.compositor.outputWidth, 1))
        let height = CGFloat(max(controller.compositor.outputHeight, 1))
        return width / height
    }

}

#if os(macOS)
private struct PreviewHoverTracker: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> PreviewHoverNSView {
        let view = PreviewHoverNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: PreviewHoverNSView, context: Context) {
        nsView.onHover = onHover
    }
}

private final class PreviewHoverNSView: NSView {
    var onHover: (Bool) -> Void = { _ in }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }
}
#endif

/// Program output meter (same source as the Audio tab Program strip). Preview mode keeps program, not the cue audition bus.
struct DualChannelMeter: View {
    var controller: ShowController
    var barHeight: CGFloat = 86

    var body: some View {
        AudioMeterBridgeView(orientation: .vertical) {
            DualChannelMeter.programSamples(matrix: controller.audioMatrix)
        }
        .frame(width: InspectorPreviewLayout.meterWidth, height: barHeight)
        .accessibilityLabel("Program levels")
    }

    /// Shared with the phone monitor overlay. Reads MixerMasterState; no sample allocation beyond the two meter rows.
    static func programSamples(matrix: AudioMatrixEngine) -> [AudioMeterSample] {
        let master = matrix.master
        let silent = matrix.programMuted || master.muted
        let left = silent ? -120.0 : master.peakLeft
        let right = silent ? -120.0 : master.peakRight
        let hold = silent ? -120.0 : master.peakHoldDb
        return [
            AudioMeterSample(id: "L", name: "L", db: left, holdDb: hold, isMuted: silent),
            AudioMeterSample(id: "R", name: "R", db: right, holdDb: hold, isMuted: silent)
        ]
    }
}

/// Edit monitor. Selected cue when it is not already on air; otherwise the next program-outline slide.
struct OperatorPreviewPicture: View {
    @Bindable var controller: ShowController
    /// Right pane owns headphone audition. Multiview only shows the picture.
    var playsCueAudio: Bool = false
    var showsCueLabel: Bool = true

    var body: some View {
        ZStack {
            ProShowTheme.stageBlack
            if let slide = controller.operatorPreviewSlide {
                picture(for: slide)
            } else {
                Text("No next cue")
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if showsCueLabel {
            Text(cueLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProShowTheme.lyricWhite)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(ProShowTheme.titlebar.opacity(0.92), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview, \(cueLabel)")
        .onAppear {
            guard playsCueAudio else { return }
            controller.followOperatorPreviewAudio(true)
        }
        .onDisappear {
            guard playsCueAudio else { return }
            controller.followOperatorPreviewAudio(false)
        }
        .onChange(of: controller.operatorPreviewSlide?.id) { _, _ in
            guard playsCueAudio else { return }
            controller.followOperatorPreviewAudio(true)
        }
    }

    private var cueLabel: String {
        guard let slide = controller.operatorPreviewSlide else { return "No next cue" }
        let name = slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? slide.previewSummary : name
        if let selected = controller.selectedSlide, selected.id == slide.id, selected.id != controller.liveSlideID {
            return "Selected · \(title)"
        }
        return "Next · \(title)"
    }

    @ViewBuilder
    private func picture(for slide: Slide) -> some View {
        let objects = controller.resolvedCanvasObjects(slide.audienceCanvas())
        ZStack {
            if let media = controller.resolvedAssociatedMedia(for: slide),
               !media.clearsLayer,
               slide.isProgramMediaCue || slide.showsLinkedProgramMediaUnderCanvas {
                if media.isImage {
                    MediaPreviewFrame(
                        filePath: media.filePath,
                        artworkURL: media.resolvedFileURL(projectRoot: controller.mediaProjectRoot),
                        kind: .image,
                        tintHex: media.tintHex,
                        cornerRadius: 0
                    )
                } else if let path = media.filePath {
                    SlotVideoPlayerView(
                        path: path,
                        tintHex: media.tintHex,
                        isMuted: true,
                        projectRoot: controller.mediaProjectRoot
                    )
                }
            }
            if !objects.isEmpty {
                ProgramSlideThumbnailPreview(
                    controller: controller,
                    slide: slide,
                    objects: objects
                )
            }
        }
    }
}

struct PreviewHeadsetButton: View {
    private var monitor: PreviewCueMonitor { PreviewCueMonitor.shared }

    var body: some View {
        Button {
            monitor.toggleHeadset()
        } label: {
            Image(systemName: monitor.headsetOn && monitor.hasCueAudio ? "headphones" : "headphones.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(monitor.headsetOn && monitor.hasCueAudio ? ProShowTheme.lyricWhite : ProShowTheme.secondaryLabel)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(DeskPressButtonStyle())
        .disabled(!monitor.hasCueAudio)
        .help(monitor.hasCueAudio
              ? "Listen to this cue on your headset. The live stream stays unchanged."
              : "This cue has no audio to preview.")
        .accessibilityLabel("Preview headphones")
        .accessibilityValue(headsetValue)
        .accessibilityAddTraits(monitor.headsetOn && monitor.hasCueAudio ? .isSelected : [])
    }

    private var headsetValue: String {
        guard monitor.hasCueAudio else { return "No audio on this cue" }
        return monitor.headsetOn ? "On" : "Off"
    }
}

fileprivate struct ClearLayerStrip: View {
    @Bindable var controller: ShowController
    var layoutHeight: CGFloat?

    private var itemSpacing: CGFloat {
        guard needsCompactLayout else { return 4 }
        return 2
    }

    private var buttonHeight: CGFloat {
        let count = CGFloat(ClearStripAction.allCases.count)
        guard count > 0 else { return DeskLayout.hit }
        guard let layoutHeight, layoutHeight > 0 else { return DeskLayout.hit }
        let gaps = itemSpacing * max(0, count - 1)
        return min(DeskLayout.hit, max(22, (layoutHeight - gaps) / count))
    }

    private var needsCompactLayout: Bool {
        guard let layoutHeight else { return false }
        let full = CGFloat(ClearStripAction.allCases.count) * DeskLayout.hit + 6 * 4
        return layoutHeight < full
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: itemSpacing) {
            ForEach(ClearStripAction.allCases) { action in
                let hidden = isHidden(action)
                let layerMuted = stripLayerMuted(action)
                Button {
                    requestClearStrip(action: action, hidden: hidden)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: action.layerIcon)
                            .font(.system(size: needsCompactLayout ? 11 : 12, weight: .semibold))
                            .foregroundStyle(stripIconColor(action: action, hidden: hidden))
                            .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight)
                        if hidden, action != .all {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(ProShowTheme.accent)
                                .padding(4)
                        } else if layerMuted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(ThemeTokens.warningAmber)
                                .padding(4)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .contextMenu {
                    Button(hidden ? action.restoreTitle : action.title) {
                        requestClearStrip(action: action, hidden: hidden)
                    }
                    if action == .audio {
                        Button(controller.audioIO.programMuted || controller.compositor.stack.audioMuted ? "Unmute Program Audio" : "Mute Program Audio") {
                            controller.toggleAudioMute()
                        }
                    } else if let layer = action.linkedRenderLayer, controller.canMuteProgramLayer(layer) {
                        Button(controller.isProgramLayerAudioMuted(layer) ? "Unmute Layer Audio" : "Mute Layer Audio") {
                            controller.toggleProgramLayerAudio(layer)
                        }
                    }
                }
                .help(stripHelp(action: action, hidden: hidden, layerMuted: layerMuted))
                .accessibilityLabel(stripHelp(action: action, hidden: hidden, layerMuted: layerMuted))
                .accessibilityAddTraits(hidden ? .isSelected : [])
                .accessibilityValue(hidden ? "Hidden" : (layerMuted ? "Muted" : "Visible"))
            }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func stripIconColor(action: ClearStripAction, hidden: Bool) -> Color {
        if action == .all { return ProShowTheme.liveRed }
        return hidden ? ProShowTheme.accent : ShowSidebarPalette.symbol
    }

    private func requestClearStrip(action: ClearStripAction, hidden: Bool) {
        if DeskDestructiveConfirmAction.clearStripHideNeedsConfirm(action, currentlyHidden: hidden) {
            controller.requestDeskDestructiveConfirm(.hideClearStripLayer(action))
        } else {
            _ = controller.clearLayer(named: action.layerName)
        }
    }

    private func isHidden(_ action: ClearStripAction) -> Bool {
        let stack = controller.compositor.stack
        switch action {
        case .audio:
            return stack.audioMuted || controller.audioIO.programMuted
        case .messages:
            return stack.isCleared(.messages)
        case .props:
            return stack.isCleared(.props)
        case .all:
            return RenderLayer.allCases.allSatisfy { stack.isCleared($0) }
                && (stack.audioMuted || controller.audioIO.programMuted)
        case .slide:
            return stack.isCleared(.slide)
        case .media:
            return stack.isCleared(.media)
        case .videoInput:
            return stack.isCleared(.videoInput)
        }
    }

    private func stripLayerMuted(_ action: ClearStripAction) -> Bool {
        if action == .audio {
            return controller.audioIO.programMuted || controller.compositor.stack.audioMuted
        }
        guard let layer = action.linkedRenderLayer else { return false }
        return controller.canMuteProgramLayer(layer) && controller.isProgramLayerAudioMuted(layer)
    }

    private func stripHelp(action: ClearStripAction, hidden: Bool, layerMuted: Bool) -> String {
        var parts = [hidden ? action.restoreTitle : action.title]
        if layerMuted { parts.append("Audio muted") }
        parts.append("Control-click for mute")
        return parts.joined(separator: " · ")
    }
}

fileprivate struct MediaTransportDock: View {
    @Bindable var controller: ShowController

    var body: some View {
        let transport = controller.playback.snapshot()
        let duration = max(transport.duration, 0)
        let canScrub = duration > 0
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                PlayheadTimecodeView(
                    playback: controller.playback,
                    clock: controller.transportClock,
                    fontSize: 11,
                    color: Color.white.opacity(0.72)
                )
                Spacer(minLength: 4)
                PlayheadTimecodeView(
                    playback: controller.playback,
                    clock: controller.transportClock,
                    showsRemaining: true,
                    alignment: .trailing,
                    fontSize: 11,
                    color: Color.white.opacity(0.72)
                )
            }
            PlayheadScrubberView(playback: controller.playback) { seconds in
                controller.inspector.seekTransport(to: seconds)
                controller.tickProgram()
            }
            .disabled(!canScrub)
            HStack(spacing: 6) {
                transportIconButton("Back 15 seconds", systemImage: "gobackward.15") {
                    controller.inspector.skipTransport(seconds: -15)
                    controller.tickProgram()
                }
                transportIconButton(
                    transport.isPlaying ? "Pause" : "Play",
                    systemImage: transport.isPlaying ? "pause.fill" : "play.fill",
                    prominent: true
                ) {
                    controller.transportPlayPause()
                }
                transportIconButton("Forward 15 seconds", systemImage: "goforward.15") {
                    controller.inspector.skipTransport(seconds: 15)
                    controller.tickProgram()
                }
                transportIconButton(
                    transport.isLooping ? "Loop on" : "Loop off",
                    systemImage: transport.isLooping ? "repeat" : "repeat.1",
                    accent: transport.isLooping
                ) {
                    controller.inspector.toggleLoop()
                }
                transportIconButton("Next marker", systemImage: "bookmark.fill") {
                    controller.inspector.jumpToNextMarker()
                    controller.tickProgram()
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(!canScrub && transport.title == MediaTransportState.idle.title)
            .accessibilityElement(children: .contain)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func transportIconButton(
        _ title: String,
        systemImage: String,
        prominent: Bool = false,
        accent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 15 : 13, weight: .semibold))
                .foregroundStyle(accent ? ProShowTheme.accent : Color.white.opacity(0.88))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }
}

fileprivate struct ActionInspectorTabBar: View {
    @Bindable var controller: ShowController

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ActionInspectorTab.deskTabs) { tab in
                let selected = controller.inspector.selectedTab == tab
                Button {
                    controller.inspector.selectedTab = tab
                } label: {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .symbolVariant(selected ? .fill : .none)
                        .foregroundStyle(selected ? ProShowTheme.accent : ShowSidebarPalette.symbol)
                        .frame(maxWidth: .infinity)
                        .frame(height: DeskControlSize.mini.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .frame(maxWidth: .infinity)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
    }
}

fileprivate struct ActionInspectorBody: View {
    @Bindable var controller: ShowController

    var body: some View {
        Group {
            switch controller.inspector.selectedTab {
            case .layers: LayersActionPane(controller: controller)
            case .audio: AudioActionPane(controller: controller)
            case .timers: TimerActionPane(inspector: controller.inspector)
            case .messages: MessageActionPane(controller: controller)
            case .props: PropActionPane(controller: controller)
            case .macros: MacroActionPane(controller: controller)
            case .backstage: BackstageControlPanelView(controller: controller)
            case .stage, .matrix:
                LayersActionPane(controller: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct InspectorMenuChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        #else
        content
        #endif
    }
}

/// Bottom edge of the on-air and live-source cards. Dimmer and thinner than a standard divider.
struct InspectorSectionBottomRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// Hairline between rows inside those cards.
struct InspectorRowRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.045))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

private struct LayersActionPane: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme
    @State private var renameLayerID: UUID?
    @State private var renameTitle = ""
    @AppStorage("proshow.inspector.masterExpanded") private var masterExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DeskSpace.sm) {
                ActionStackInspectorView(controller: controller)
                    .padding(10)
                    .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottom) { InspectorSectionBottomRule() }
                    .frame(minHeight: 200, alignment: .top)
                OnAirAudioSectionView(controller: controller)
                    .padding(10)
                    .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottom) { InspectorSectionBottomRule() }
                masterSection
                    .padding(10)
                    .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottom) { InspectorSectionBottomRule() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composition and live sources")
        .alert("Rename source", isPresented: renamePresented) {
            TextField("Name", text: $renameTitle)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {
                renameLayerID = nil
                renameTitle = ""
            }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameLayerID != nil },
            set: { if !$0 { renameLayerID = nil } }
        )
    }

    private var masterSection: some View {
        DisclosureGroup(isExpanded: $masterExpanded) {
            masterStack
                .padding(.top, 6)
        } label: {
            masterHeader
        }
    }

    private var programHeader: some View {
        HStack(spacing: 6) {
            DeskSectionTitle(title: "Program")
            MicTallyPill(live: controller.isProgramMicLive)
            if controller.soloedProgramLayer != nil {
                Button("Exit Solo") {
                    controller.endProgramSolo(restoring: true)
                }
                .font(DeskType.micro)
                .buttonStyle(DeskPressButtonStyle())
                .help("Restore the visibility from before solo")
            }
            Menu {
                Button("Hide All", systemImage: "eye.slash") {
                    controller.requestDeskDestructiveConfirm(.hideAllProgramLayers)
                }
                Button("Show All", systemImage: "eye") {
                    controller.restoreAllLayers()
                }
                if controller.soloedProgramLayer != nil {
                    Divider()
                    Button("Exit Solo", systemImage: "circle.slash") {
                        controller.endProgramSolo(restoring: true)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ShowSidebarPalette.symbol)
                    .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                    .contentShape(Rectangle())
            }
            .modifier(InspectorMenuChrome())
            .help("Program layer actions")
            .accessibilityLabel("Program layer actions")
        }
    }

    private var programStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(RenderLayer.allCases.enumerated()), id: \.element.id) { index, layer in
                programLayerRow(layer)
                if index < RenderLayer.allCases.count - 1 {
                    Divider().overlay(ThemeTokens.dividerLine)
                }
            }
        }
    }

    private var masterHeader: some View {
        HStack(spacing: 6) {
            Text("Live sources")
                .font(DeskType.meta.weight(.semibold))
                .foregroundStyle(ShowSidebarPalette.title)
            Menu {
                Button("Add Shot…", systemImage: "plus") {
                    controller.openAddShot(layerIndex: controller.addShotLayerIndex)
                }
                Button("Clear Live on Selected", systemImage: "record.circle") {
                    let index = controller.addShotLayerIndex
                    let name = controller.masterLayers.displayName(at: index)
                    controller.requestDeskDestructiveConfirm(.clearLiveShot(layerName: name, layerIndex: index))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ShowSidebarPalette.symbol)
                    .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                    .contentShape(Rectangle())
            }
            .modifier(InspectorMenuChrome())
            .help("Master layer actions")
            .accessibilityLabel("Master layer actions")
        }
    }

    private var masterStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.masterLayers.enumerated()), id: \.element.id) { index, layer in
                LiveSourceRowView(controller: controller, layer: layer, index: index) {
                    renameLayerID = layer.id
                    renameTitle = layer.hasDefaultTitle ? "" : layer.title
                }
                if index < controller.masterLayers.count - 1 {
                    InspectorRowRule()
                }
            }
        }
    }

    private func programLayerRow(_ layer: RenderLayer) -> some View {
        let stack = controller.compositor.stack
        let hidden = stack.isCleared(layer)
        let soloed = controller.soloedProgramLayer == layer
        let summary = layer.contentSummary(in: stack)
        let filled = layer.hasContent(in: stack)
        return HStack(alignment: .center, spacing: 8) {
            Capsule()
                .fill(soloed ? ProShowTheme.statusOn : Color.clear)
                .frame(width: 3, height: 28)
                .accessibilityHidden(true)

            Text("\(layer.rawValue)")
                .font(DeskType.mono.weight(.bold))
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .frame(width: 14, alignment: .trailing)
                .accessibilityHidden(true)

            Image(systemName: layer.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hidden ? ShowSidebarPalette.subtitle : ShowSidebarPalette.symbol)
                .frame(width: 14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(layer.title)
                        .font(DeskType.meta.weight(.semibold))
                        .foregroundStyle(hidden ? ShowSidebarPalette.subtitle : ShowSidebarPalette.title)
                        .lineLimit(1)
                    if soloed {
                        Text("Solo")
                            .font(DeskType.micro)
                            .foregroundStyle(ProShowTheme.canvas)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(ProShowTheme.statusOn, in: Capsule())
                    }
                }
                Text(summary)
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            outputBadge("A", on: stack.isVisible(layer, onStage: false))
            outputBadge("S", on: stack.isVisible(layer, onStage: true))

            if layer.carriesAudio {
                DeskMuteButton(
                    isMuted: controller.isProgramLayerAudioMuted(layer),
                    label: layer.title
                ) {
                    controller.toggleProgramLayerAudio(layer)
                }
            }

            Button {
                _ = controller.clearLayer(named: layer.apiName)
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hidden ? ProShowTheme.accent : ShowSidebarPalette.symbol)
                    .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help(hidden ? "Show \(layer.title)" : "Hide \(layer.title)")
            .accessibilityLabel(hidden ? "Show \(layer.title)" : "Hide \(layer.title)")
            .accessibilityValue(hidden ? "Hidden" : "Visible")

            Menu {
                Button(hidden ? "Show Layer" : "Hide Layer", systemImage: hidden ? "eye" : "eye.slash") {
                    _ = controller.clearLayer(named: layer.apiName)
                }
                Button(soloed ? "Exit Solo" : "Solo Layer", systemImage: "circle.lefthalf.filled") {
                    controller.soloProgramLayer(layer)
                }
                if layer.carriesAudio {
                    Button(
                        controller.isProgramLayerAudioMuted(layer) ? "Unmute Audio" : "Mute Audio",
                        systemImage: controller.isProgramLayerAudioMuted(layer) ? "speaker.wave.2" : "speaker.slash"
                    ) {
                        controller.toggleProgramLayerAudio(layer)
                    }
                }
                Divider()
                Button("Empty Content", systemImage: "trash") {
                    controller.requestDeskDestructiveConfirm(.emptyProgramLayer(layer))
                }
                .disabled(!filled && layer != .screenColor)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ShowSidebarPalette.symbol)
                    .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                    .contentShape(Rectangle())
            }
            .modifier(InspectorMenuChrome())
            .help("\(layer.title) actions")
            .accessibilityLabel("\(layer.title) actions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(soloed ? ProShowTheme.statusOn.opacity(0.10) : Color.clear)
        .opacity(hidden && !soloed ? 0.7 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(layer.title), layer \(layer.rawValue)")
        .accessibilityValue({
            var parts = [summary]
            if soloed { parts.insert("Solo", at: 0) }
            if layer.carriesAudio, controller.isProgramLayerAudioMuted(layer) { parts.append("Muted") }
            return parts.joined(separator: ", ")
        }())
    }


    private func outputBadge(_ letter: String, on: Bool) -> some View {
        Text(letter)
            .font(DeskType.micro.weight(.bold))
            .foregroundStyle(on ? ProShowTheme.lyricWhite : ShowSidebarPalette.subtitle)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(on ? ProShowTheme.accent.opacity(0.38) : Color.primary.opacity(0.06))
            )
            .accessibilityLabel(on ? "\(letter == "A" ? "Audience" : "Stage") on" : "\(letter == "A" ? "Audience" : "Stage") off")
    }

    private func commitRename() {
        guard let renameLayerID,
              let index = controller.masterLayers.firstIndex(where: { $0.id == renameLayerID })
        else { return }
        controller.renameMasterLayer(at: index, to: renameTitle)
        self.renameLayerID = nil
        renameTitle = ""
    }
}

private struct LiveSourceRowView: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("proshow.layers.swipeDeleteDirection") private var swipeDeleteDirection = "left"
    let layer: MasterLayer
    let index: Int
    let onRename: () -> Void

    private var displayName: String { controller.masterLayers.displayName(at: index) }

    @State private var dragOffset: CGFloat = 0

    private var isSelected: Bool { controller.addShotLayerIndex == index }

    private var liveShot: LayerShot? {
        layer.shots.first { $0.id == layer.liveShotID }
    }

    private var canClearLive: Bool { liveShot != nil }

    private var deleteSign: CGFloat {
        swipeDeleteDirection == "right" ? 1 : -1
    }

    private var isAudioMuted: Bool {
        controller.isLiveShotAudioMuted(layerIndex: index)
    }

    var body: some View {
        row
            .offset(x: dragOffset)
            .background { swipeReveal }
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(swipeGesture)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("Clear live on \(displayName)")) {
                clearLive()
            }
    }

    private var row: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isSelected ? ProShowTheme.accent : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 5)
                .accessibilityHidden(true)

            Button {
                controller.selectMasterLayer(at: index)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "video.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ShowSidebarPalette.symbol)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(DeskType.meta.weight(.semibold))
                                .foregroundStyle(ShowSidebarPalette.title)
                                .lineLimit(1)
                            if liveShot != nil {
                                Circle()
                                    .fill(ProShowTheme.liveRed)
                                    .frame(width: 7, height: 7)
                                    .accessibilityLabel("Live")
                            }
                        }
                        Text(liveShot?.name ?? (layer.shots.isEmpty ? "No shots" : "\(layer.shots.count) shots"))
                            .font(DeskType.micro)
                            .foregroundStyle(ShowSidebarPalette.subtitle)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel(displayName)
            .accessibilityValue(liveShot.map { "Live \($0.name)" } ?? (layer.shots.isEmpty ? "No shots" : "\(layer.shots.count) shots"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            controlCluster
        }
        .padding(.leading, 4)
        .padding(.trailing, isSelected && canClearLive ? 34 : 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if isSelected, canClearLive {
                Button(action: clearLive) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(ProShowTheme.liveRed, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .padding(.trailing, 4)
                .help("Clear live on \(displayName)")
                .accessibilityLabel("Clear live on \(displayName)")
            }
        }
    }

    private var controlCluster: some View {
        HStack(spacing: 0) {
            shotMenu
            speakerButton
            actionsMenu
        }
        .padding(1)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        }
        .accessibilityElement(children: .contain)
    }

    private var shotMenu: some View {
        Menu {
            if layer.shots.isEmpty {
                Text("No shots")
            } else {
                ForEach(layer.shots) { shot in
                    Button {
                        controller.selectMasterLayer(at: index)
                        controller.takeShotLive(shot, layerIndex: index)
                    } label: {
                        if shot.id == layer.liveShotID {
                            Label(shot.name, systemImage: "record.circle.fill")
                        } else {
                            Text(shot.name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ShowSidebarPalette.symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .modifier(InspectorMenuChrome())
        .disabled(layer.shots.isEmpty)
        .help("Choose live shot")
        .accessibilityLabel("Live shot")
        .accessibilityValue(liveShot?.name ?? "None")
    }

    private var speakerButton: some View {
        Button {
            controller.toggleLiveShotAudio(layerIndex: index)
        } label: {
            Image(systemName: isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isAudioMuted ? ProShowTheme.liveRed : ShowSidebarPalette.symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .disabled(!controller.masterLayerLiveShotCarriesAudio(layerIndex: index))
        .opacity(controller.masterLayerLiveShotCarriesAudio(layerIndex: index) ? 1 : 0.35)
        .help(
            !controller.masterLayerLiveShotCarriesAudio(layerIndex: index)
                ? "No audio. Add a Mic layer."
                : (isAudioMuted ? "Unmute \(liveShot?.name ?? displayName)" : "Mute \(liveShot?.name ?? displayName)")
        )
        .accessibilityLabel(isAudioMuted ? "Unmute \(liveShot?.name ?? displayName)" : "Mute \(liveShot?.name ?? displayName)")
    }

    private var actionsMenu: some View {
        Menu {
            Button("Add Shot…", systemImage: "plus") {
                controller.selectMasterLayer(at: index)
                controller.openAddShot(layerIndex: index)
            }
            Menu("Shots") {
                if layer.shots.isEmpty {
                    Text("No shots")
                } else {
                    ForEach(layer.shots) { shot in
                        Menu(shot.name) {
                            Button("Take Live", systemImage: "play.circle") {
                                controller.selectMasterLayer(at: index)
                                controller.takeShotLive(shot, layerIndex: index)
                            }
                            if shot.source.sourceType.needsMainLayerShot {
                                Button("Refresh Source", systemImage: "arrow.clockwise") {
                                    controller.refreshLiveShot(shot.id, layerIndex: index)
                                }
                            }
                            Button("Replace Source…", systemImage: "arrow.triangle.2.circlepath") {
                                controller.openReplaceShot(shotID: shot.id, layerIndex: index)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                controller.removeShot(shot.id, layerIndex: index)
                            }
                        }
                    }
                }
            }
            Button("Clear Live", systemImage: "record.circle") {
                clearLive()
            }
            .disabled(!canClearLive)
            Button(
                isAudioMuted ? "Unmute Live Shot" : "Mute Live Shot",
                systemImage: isAudioMuted ? "speaker.wave.2" : "speaker.slash"
            ) {
                controller.toggleLiveShotAudio(layerIndex: index)
            }
            .disabled(layer.liveShotID == nil || !controller.masterLayerLiveShotCarriesAudio(layerIndex: index))
            if let liveShot {
                Button("Remove \(liveShot.name)", systemImage: "trash") {
                    controller.removeShot(liveShot.id, layerIndex: index)
                }
            }
            Divider()
            Button("Rename…", systemImage: "pencil") {
                onRename()
            }
            Button("Select Layer", systemImage: "checkmark.circle") {
                controller.selectMasterLayer(at: index)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ShowSidebarPalette.symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .modifier(InspectorMenuChrome())
        .help("\(displayName) actions")
        .accessibilityLabel("\(displayName) actions")
    }

    private var swipeReveal: some View {
        let revealWidth = max(0, dragOffset * deleteSign)
        return Color.clear
            .overlay(alignment: deleteSign > 0 ? .leading : .trailing) {
                ZStack {
                    ProShowTheme.liveRed
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                .frame(width: revealWidth)
                .clipped()
            }
            .accessibilityHidden(true)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                let translation = value.translation
                guard abs(translation.width) > abs(translation.height) else { return }
                let towardDelete = translation.width * deleteSign > 0
                dragOffset = towardDelete ? translation.width : translation.width * 0.2
            }
            .onEnded { value in
                let along = value.translation.width * deleteSign
                let flick = value.predictedEndTranslation.width * deleteSign
                if canClearLive, along > 56 || flick > 110 {
                    clearLive()
                }
                if reduceMotion {
                    dragOffset = 0
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func clearLive() {
        guard canClearLive else { return }
        controller.requestDeskDestructiveConfirm(
            .clearLiveShot(layerName: displayName, layerIndex: index)
        )
    }
}

private struct AudioActionPane: View {
    @Bindable var controller: ShowController

    var body: some View {
        StudioAudioGlass(controller: controller)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ProShowTheme.panel)
    }
}

private struct StageActionPane: View {
    @Bindable var controller: ShowController

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(StageLayoutPreset.all) { layout in
                    Button {
                        controller.applyStageLayout(id: layout.id)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.title3)
                            Text(layout.name)
                                .font(.caption2.weight(.semibold))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(isSelected(layout) ? ProShowTheme.accent : ShowSidebarPalette.symbol)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .padding(6)
                        .background(isSelected(layout) ? ProShowTheme.accent.opacity(0.16) : Color.primary.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(isSelected(layout) ? ProShowTheme.accent : Color.clear, lineWidth: 1.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            VStack(alignment: .leading, spacing: 8) {
                DeskSectionTitle(title: controller.scenes.activeScene?.name ?? "Scene")
                TransitionPickerView(
                    selection: Binding(
                        get: { controller.scenes.activeScene?.transitionPresetID ?? "dissolve" },
                        set: { value in
                            controller.applyTransitionPreset(TransitionCatalog.preset(id: value), workspace: .sceneManager)
                        }
                    ),
                    compact: true
                )
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 10)
            }
        }
    }

    private func isSelected(_ layout: StageLayoutPreset) -> Bool {
        controller.themeProjectSettings.activeStageVariantID == layout.id
    }
}

private struct TimerActionPane: View {
    @Bindable var inspector: ActionInspectorEngine
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(inspector.timers) { timer in
                    let selected = inspector.selectedTimerID == timer.id
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            InspectorSelectionRibbon(selected: selected)
                            Text(timer.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ShowSidebarPalette.title)
                            Spacer(minLength: 8)
                            Text(timer.kind.title)
                                .font(.system(size: 12))
                                .foregroundStyle(ShowSidebarPalette.subtitle)
                        }
                        TimelineView(.periodic(from: TimelineAnchor.start, by: 0.25)) { _ in
                            let live = inspector.timer(id: timer.id) ?? timer
                            Text(ProgramTimecode.format(TimeInterval(live.displaySeconds)))
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .foregroundStyle(live.isOverrun ? ProShowTheme.liveRed : ShowSidebarPalette.title)
                                .padding(.leading, 11)
                                .accessibilityLabel("\(live.name) time")
                                .accessibilityValue(ProgramTimecode.format(TimeInterval(live.displaySeconds)))
                        }
                        HStack(spacing: 0) {
                            timerButton("Start") { _ = inspector.startTimer(id: timer.id) }
                            timerButton("Pause") { _ = inspector.stopTimer(id: timer.id) }
                            timerButton("Reset") { _ = inspector.resetTimer(id: timer.id) }
                        }
                        .padding(2)
                        .background(ShowSidebarPalette.field(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.leading, 11)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { inspector.selectedTimerID = timer.id }
                }
                Button {
                    _ = inspector.addTimer()
                } label: {
                    Label("Add Timer", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(DeskPressButtonStyle())
                .foregroundStyle(ProShowTheme.accent)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func timerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ShowSidebarPalette.title)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(title)
    }
}

private struct MessageActionPane: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let inspector = controller.inspector
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fill-in text")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                    ForEach(controller.textFields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.key)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ShowSidebarPalette.subtitle)
                            TextField(field.hint, text: Binding(
                                get: { field.value },
                                set: { controller.setTextField(field.key, value: $0) }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(ShowSidebarPalette.title)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(ShowSidebarPalette.field(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityLabel("\(field.key) value")
                        }
                    }
                    Button {
                        controller.addTextField()
                    } label: {
                        Label("Add text field", systemImage: "plus")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .foregroundStyle(ProShowTheme.accent)
                    .accessibilityLabel("Add text field")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        _ = inspector.addMessage(
                            title: "Alert",
                            template: "{Name} to the desk — {Custom Text}"
                        )
                    } label: {
                        Label("Add message", systemImage: "plus")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .foregroundStyle(ProShowTheme.accent)
                    ForEach(inspector.messages) { message in
                        let selected = inspector.selectedMessageID == message.id
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                InspectorSelectionRibbon(selected: selected, color: message.isActive ? ProShowTheme.liveRed : ProShowTheme.accent)
                                Text(message.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(ShowSidebarPalette.title)
                                Spacer(minLength: 8)
                                Button(message.isActive ? "Hide" : "Show") {
                                    if message.isActive {
                                        controller.hideInspectorMessage(id: message.id)
                                    } else {
                                        _ = controller.showInspectorMessage(id: message.id)
                                    }
                                }
                                .buttonStyle(DeskPressButtonStyle())
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(message.isActive ? ProShowTheme.liveRed : ProShowTheme.accent)
                            }
                            Text(message.resolvedText())
                                .font(.system(size: 12))
                                .foregroundStyle(ShowSidebarPalette.subtitle)
                                .padding(.leading, 11)
                            TextField("Number", text: tokenBinding(message.id, key: "Number"))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(ShowSidebarPalette.title)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(ShowSidebarPalette.field(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(.leading, 11)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { inspector.selectMessage(id: message.id) }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func tokenBinding(_ id: UUID, key: String) -> Binding<String> {
        Binding(
            get: { controller.inspector.messages.first(where: { $0.id == id })?.dynamicValues[key] ?? "" },
            set: { controller.inspector.setMessageValue(id: id, key: key, value: $0) }
        )
    }
}

private struct PropActionPane: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme
    @State private var renameID: UUID?
    @State private var renameText = ""

    private var inspector: ActionInspectorEngine { controller.inspector }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Collection", selection: Binding(
                    get: { inspector.selectedCollection },
                    set: { controller.setSelectedPropCollection($0) }
                )) {
                    ForEach(inspector.collections, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
                Button {
                    _ = controller.addEditableProp()
                } label: {
                    Label("Add Prop", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(DeskPressButtonStyle())
                .foregroundStyle(ProShowTheme.accent)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            let columns = [GridItem(.adaptive(minimum: 88), spacing: 10)]
            let visible = inspector.props.filter { $0.collectionName == inspector.selectedCollection }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(visible) { prop in
                        let selected = inspector.selectedPropID == prop.id
                        let live = prop.isActive
                        Button {
                            _ = controller.toggleInspectorProp(id: prop.id)
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(ShowSidebarPalette.field(scheme))
                                    .aspectRatio(16 / 10, contentMode: .fit)
                                    .overlay {
                                        propThumb(prop)
                                    }
                                    .overlay(alignment: .leading) {
                                        InspectorSelectionRibbon(
                                            selected: selected || live,
                                            color: live ? ProShowTheme.liveRed : ProShowTheme.accent
                                        )
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Menu {
                                            ForEach(PropOutputTarget.allCases) { target in
                                                Button(target.title) { controller.setPropShowOn(id: prop.id, target: target) }
                                            }
                                        } label: {
                                            Text(prop.showOn.badge)
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .foregroundStyle(.white)
                                                .background(prop.showOn == .both ? Color.black.opacity(0.55) : ProShowTheme.accent, in: Capsule())
                                        }
                                        .menuStyle(.borderlessButton)
                                        .menuIndicator(.hidden)
                                        .fixedSize()
                                        .help("Show on: \(prop.showOn.title). Click to choose.")
                                        .padding(4)
                                    }
                                Text(prop.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(ShowSidebarPalette.title)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .buttonStyle(DeskPressButtonStyle())
                        .contextMenu {
                            propContextMenu(prop)
                        }
                    }
                    Button {
                        _ = controller.addEditableProp()
                    } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(ShowSidebarPalette.subtitle)
                                .aspectRatio(16 / 10, contentMode: .fit)
                                .overlay {
                                    Image(systemName: "plus")
                                        .foregroundStyle(ShowSidebarPalette.subtitle)
                                }
                            Text("Add Prop")
                                .font(.caption2)
                                .foregroundStyle(ShowSidebarPalette.subtitle)
                        }
                    }
                    .buttonStyle(DeskPressButtonStyle())
                }
                .padding(10)
                .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .alert("Rename Prop", isPresented: Binding(
            get: { renameID != nil },
            set: { if !$0 { renameID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renameID {
                    _ = inspector.renameProp(id: renameID, to: renameText)
                    if controller.editors.kind == .props,
                       let index = controller.editors.documents.firstIndex(where: { $0.id == renameID }) {
                        controller.editors.documents[index].name = renameText
                    }
                    controller.syncActivePropsToCompositor()
                    controller.persistStudio()
                }
                renameID = nil
            }
            Button("Cancel", role: .cancel) { renameID = nil }
        }
    }

    @ViewBuilder
    private func propThumb(_ prop: ProShowProp) -> some View {
        if !prop.elements.isEmpty {
            ProgramSlideCanvas(
                objects: prop.elements,
                canvasWidth: CanvasConfig.width,
                canvasHeight: CanvasConfig.height,
                evaluationMode: .thumbnailPreview
            )
            .allowsHitTesting(false)
        } else {
            Image(systemName: prop.isActive ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                .foregroundStyle(prop.isActive ? ProShowTheme.accent : ShowSidebarPalette.subtitle)
        }
    }

    @ViewBuilder
    private func propContextMenu(_ prop: ProShowProp) -> some View {
        Button(prop.isActive ? "Clear from Program" : "Take Live") {
            _ = controller.toggleInspectorProp(id: prop.id)
        }
        Button("Edit…") {
            controller.editProp(id: prop.id)
        }
        Button("Rename…") {
            renameID = prop.id
            renameText = prop.name
        }
        Button("Duplicate") {
            if let copy = inspector.duplicateProp(id: prop.id) {
                if controller.editors.kind == .props {
                    controller.editors.insertDocument(from: copy)
                }
                controller.syncActivePropsToCompositor()
                controller.persistStudio()
                _ = copy
            }
        }
        Menu("Show on") {
            ForEach(PropOutputTarget.allCases) { target in
                Button {
                    controller.setPropShowOn(id: prop.id, target: target)
                } label: {
                    if prop.showOn == target { Label(target.title, systemImage: "checkmark") } else { Text(target.title) }
                }
            }
        }
        Menu("Auto Clear") {
            Button("Never") { inspector.setPropAutoClear(id: prop.id, mode: .never); controller.persistStudio() }
            Button("On Next Slide") { inspector.setPropAutoClear(id: prop.id, mode: .onNextSlide); controller.persistStudio() }
            Button("After 5s") { inspector.setPropAutoClear(id: prop.id, mode: .afterDelay(seconds: 5)); controller.persistStudio() }
            Button("After 15s") { inspector.setPropAutoClear(id: prop.id, mode: .afterDelay(seconds: 15)); controller.persistStudio() }
        }
        Menu("Transition") {
            ForEach(DeskSampleData.slideTransitions, id: \.self) { name in
                Button(name) { inspector.setPropTransition(id: prop.id, transition: name); controller.persistStudio() }
            }
        }
        Menu("Collection") {
            ForEach(inspector.collections, id: \.self) { name in
                Button(name) { controller.assignPropCollection(id: prop.id, collection: name) }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            _ = inspector.deleteProp(id: prop.id)
            if controller.editors.kind == .props {
                controller.editors.documents.removeAll { $0.id == prop.id }
                if controller.editors.selectedDocumentID == prop.id {
                    controller.editors.selectedDocumentID = controller.editors.documents.first?.id
                }
            }
            controller.syncActivePropsToCompositor()
            controller.persistStudio()
        }
    }
}

private struct MacroActionPane: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                _ = controller.inspector.addMacro(name: "New Macro", actions: [.clearLayer(layerName: "media")])
            } label: {
                Label("Create Macro", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(DeskPressButtonStyle())
            .foregroundStyle(ProShowTheme.accent)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(controller.inspector.macros) { macro in
                        let selected = controller.inspector.selectedMacroID == macro.id
                            || controller.inspector.lastExecutedMacroID == macro.id
                        Button {
                            _ = controller.executeInspectorMacro(id: macro.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(hex: macro.colorHex) ?? ProShowTheme.accent)
                                        .frame(width: 6, height: 6)
                                        .accessibilityHidden(true)
                                    Text(macro.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(ShowSidebarPalette.title)
                                }
                                ForEach(Array(macro.actions.prefix(3).enumerated()), id: \.offset) { _, action in
                                    Text(macroActionTitle(action))
                                        .font(.system(size: 12))
                                        .foregroundStyle(ShowSidebarPalette.subtitle)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                            .padding(10)
                            .overlay(alignment: .leading) {
                                InspectorSelectionRibbon(selected: selected)
                                    .padding(.vertical, 8)
                            }
                        }
                        .buttonStyle(DeskPressButtonStyle())
                    }
                }
                .padding(10)
                .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private func macroActionTitle(_ action: MacroAction) -> String {
        switch action {
        case .clearLayer(let name): "Clear \(name)"
        case .triggerScene: "Trigger Scene"
        case .setStageLayout: "Set Stage Look"
        case .startTimer: "Start Timer"
        case .stopTimer: "Stop Timer"
        case .resetTimer: "Reset Timer"
        case .triggerProp: "Enable Prop"
        case .playAudioTrack: "Play Audio"
        case .playSoundboard: "Soundboard"
        case .playVideo: "Play Video"
        case .setAudienceLook: "Audience Look"
        case .startStream: "Start Stream"
        case .stopStream: "Stop Stream"
        case .startISO: "Start ISO"
        case .stopISO: "Stop ISO"
        case .muteAudio: "Mute Audio"
        }
    }
}

#if os(macOS)
import AppKit


fileprivate struct ProgramPreviewFeedButton: View {
    @Bindable var controller: ShowController

    var body: some View {
        Menu {
            ForEach(PreviewFeed.operatorFeeds) { feed in
                Button {
                    controller.selectPreviewFeed(feed)
                } label: {
                    if controller.inspector.previewFeed == feed {
                        Label(feed.title, systemImage: "checkmark")
                    } else {
                        Text(feed.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(controller.inspector.previewFeed.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(ShowSidebarPalette.title)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12).opacity(0.9), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .help("Switch between Preview and Live")
        .accessibilityLabel("Monitor")
        .accessibilityValue(controller.inspector.previewFeed.title)
    }
}

/// Opens the program in a resizable stream window (same picture as preview, larger).
fileprivate struct ProgramPreviewExpandButton: View {
    var body: some View {
        Button {
            #if os(macOS)
            NotificationCenter.default.post(name: .proShowOpenStreamWindow, object: nil)
            #endif
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.title)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12).opacity(0.9), lineWidth: 1)
                }
        }
        .buttonStyle(DeskPressButtonStyle())
        .help("Open program in expanded window")
        .accessibilityLabel("Expand program preview")
    }
}
#endif


/// Program mic tally. Red when a mic reaches program, room and stream.
private struct MicTallyPill: View {
    let live: Bool

    var body: some View {
        Label(live ? "Mic live" : "Mic off", systemImage: live ? "mic.fill" : "mic.slash")
            .font(DeskType.micro)
            .foregroundStyle(live ? Color.white : Color(red: 0x6B / 255, green: 0x9F / 255, blue: 0xE0 / 255))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(live ? Color.red : Color(red: 0x6B / 255, green: 0x9F / 255, blue: 0xE0 / 255).opacity(0.15))
            )
            .accessibilityLabel(live ? "Microphone live on program" : "Microphone off")
            .help(live ? "Mic is on air" : "No mic on air")
    }
}

/// Top-left monitor chrome: Preview / Live, plus Phone view when the slide has a Phone canvas.
fileprivate struct MonitorModeToggle: View {
    @Bindable var controller: ShowController
    var phoneAvailable: Bool
    @Binding var phoneSelected: Bool

    private var isLive: Bool { controller.inspector.previewFeed != .audience }

    var body: some View {
        DeskGlassGroup(spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    let next: PreviewFeed = isLive ? .audience : .stream
                    controller.selectPreviewFeed(next)
                    controller.selectPhonePreviewFeed(next)
                } label: {
                    HStack(spacing: 4) {
                        if isLive {
                            Circle().fill(ProShowTheme.liveRed).frame(width: 6, height: 6)
                        }
                        Text(isLive ? "Live" : "Preview")
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isLive ? ProShowTheme.liveRed : ThemeTokens.accentSystem)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(DeskChromeGlass(shape: Capsule(), interactive: true))
                .help(isLive ? "Showing Live. Click for Preview." : "Showing Preview. Click for Live.")
                .accessibilityLabel("Monitor")
                .accessibilityValue(isLive ? "Live" : "Preview")

                if phoneAvailable {
                    Button {
                        phoneSelected.toggle()
                    } label: {
                        Image(systemName: "iphone")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(phoneSelected ? ThemeTokens.accentSystem : ProShowTheme.lyricWhite)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .modifier(DeskChromeGlass(shape: Circle(), interactive: true))
                    .help("Phone view")
                    .accessibilityLabel("Phone view")
                    .accessibilityAddTraits(phoneSelected ? .isSelected : [])
                }
            }
        }
        .onChange(of: phoneAvailable) { _, available in
            if !available { phoneSelected = false }
        }
    }
}
