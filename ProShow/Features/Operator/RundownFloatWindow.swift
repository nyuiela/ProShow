#if os(macOS)
import AppKit
import SwiftUI

/// Window sizing so the program monitor is full-width 16:9 (no letterboxing in the preview slot).
enum RundownFloatWindowLayout {
    /// Outer glass padding (6×2) + inner column padding (10×2).
    static let horizontalInset: CGFloat = 32
    /// Chrome below/above the 16:9 slot (drag bar, clocks, min outline, transport, progress).
    static let fixedChromeHeight: CGFloat = 268
    /// Minimum window height is at least this multiple of the tight 16:9 + chrome layout at `minWidth`.
    static let minHeightScale: CGFloat = 1.2
    static let minWidth: CGFloat = 300
    static let maxWidth: CGFloat = 720
    static let defaultWidth: CGFloat = 360

    static func videoWidth(forWindowWidth width: CGFloat) -> CGFloat {
        max(160, width - horizontalInset)
    }

    static func nominalWindowHeight(forWidth width: CGFloat) -> CGFloat {
        let clamped = min(max(width, minWidth), maxWidth)
        return fixedChromeHeight + videoWidth(forWindowWidth: clamped) * 9 / 16
    }

    static func windowHeight(forWidth width: CGFloat) -> CGFloat {
        let nominal = nominalWindowHeight(forWidth: width)
        let floor = nominalWindowHeight(forWidth: minWidth) * minHeightScale
        return max(nominal, floor)
    }

    static func windowWidth(forHeight height: CGFloat) -> CGFloat {
        let floor = nominalWindowHeight(forWidth: minWidth) * minHeightScale
        let videoHeight = max(90, height - fixedChromeHeight)
        let videoWidth = videoHeight * 16 / 9
        let fromHeight = min(max(videoWidth + horizontalInset, minWidth), maxWidth)
        if height <= floor + 0.5 {
            return minWidth
        }
        return fromHeight
    }

    static var defaultSize: NSSize {
        NSSize(width: defaultWidth, height: windowHeight(forWidth: defaultWidth))
    }

    static var minimumSize: NSSize {
        NSSize(width: minWidth, height: windowHeight(forWidth: minWidth))
    }

    static var maximumSize: NSSize {
        NSSize(width: maxWidth, height: windowHeight(forWidth: maxWidth))
    }

    static func fittedSize(_ size: NSSize, edge: RundownOutlineResizeEdge) -> NSSize {
        switch edge {
        case .right, .bottomRight, .left, .bottomLeft:
            let width = min(max(size.width, minWidth), maxWidth)
            return NSSize(width: width, height: windowHeight(forWidth: width))
        case .bottom:
            let height = max(windowHeight(forWidth: minWidth), size.height)
            let width = windowWidth(forHeight: height)
            return NSSize(width: width, height: windowHeight(forWidth: width))
        }
    }
}

enum RundownOutlineResizeEdge {
    case left, right, bottom, bottomLeft, bottomRight
}

/// Floating rundown outline — same panel pattern as the detached prompt.
@MainActor
@Observable
final class RundownFloatController: NSObject, NSWindowDelegate {
    static let shared = RundownFloatController()

    private(set) var isOpen = false
    /// Program level meters on the preview (off by default).
    var showPreviewAudioMeter = false
    weak var rundown: ShowController?

    private var panel: NSPanel?
    private var defaultSize: NSSize { RundownFloatWindowLayout.defaultSize }

    func attachRundown(_ controller: ShowController) {
        rundown = controller
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        if panel == nil {
            let hosting = NSHostingController(rootView: RundownFloatRoot())
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: defaultSize),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hosting
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.sharingType = .none
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isMovable = true
            panel.isMovableByWindowBackground = false
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.minSize = RundownFloatWindowLayout.minimumSize
            panel.maxSize = RundownFloatWindowLayout.maximumSize
            hosting.view.autoresizingMask = [.width, .height]
            if let hostingView = hosting.view as? NSHostingView<RundownFloatRoot> {
                hostingView.safeAreaRegions = []
            }
            self.panel = panel
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.midX - defaultSize.width / 2 + 120,
                y: visible.midY - defaultSize.height / 2 - 40
            )
            panel?.setFrame(NSRect(origin: origin, size: defaultSize), display: true)
        }
        panel?.orderFrontRegardless()
        isOpen = true
    }

    func close() {
        panel?.orderOut(nil)
        isOpen = false
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let width = min(max(frameSize.width, RundownFloatWindowLayout.minWidth), RundownFloatWindowLayout.maxWidth)
        let height = RundownFloatWindowLayout.windowHeight(forWidth: width)
        return NSSize(width: width, height: height)
    }
}

private struct RundownFloatRoot: View {
    @Bindable private var chrome = RundownFloatController.shared

    var body: some View {
        Group {
            if let controller = chrome.rundown {
                RundownMiniOutlinePanel(controller: controller)
            } else {
                Text("No rundown loaded.")
                    .font(DeskType.body)
                    .foregroundStyle(RundownChrome.mutedLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

enum RundownOutlineChrome {
    /// Detached outline panel, including the program picture.
    case window
    /// Outline controls inside the studio window. The live tile owns the picture.
    case studio
}

/// Mini stream outline: previous, current, and up to five following items.
struct RundownMiniOutlinePanel: View {
    @Bindable var controller: ShowController
    var chromeStyle: RundownOutlineChrome = .window
    @Bindable private var chrome = RundownFloatController.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let _ = controller.rundownClock.activeBlockElapsedSeconds
        let _ = controller.rundownClock.activeBlockIndex
        let _ = controller.rundownClock.isShowRunning
        let _ = controller.rundownFocusedBlockIndex
        let _ = controller.programFrameRevisionStamp
        let _ = controller.streaming.isLive
        switch chromeStyle {
        case .window:
            windowChrome
        case .studio:
            studioControls
        }
    }

    private var windowChrome: some View {
        VStack(spacing: 0) {
            dragBar
            VStack(spacing: 0) {
                RundownStreamPreview(
                    controller: controller,
                    showMeters: chrome.showPreviewAudioMeter,
                    onToggleMeters: { chrome.showPreviewAudioMeter.toggle() }
                )
                itemRunTimeRow
                outlineList
                    .frame(maxHeight: .infinity)
                transportRow
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .padding(6)
        .promptGlass(cornerRadius: 28, solid: reduceTransparency)
        .overlay {
            itemProgressEdge
                .mask {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                }
        }
        .overlay {
            rundownFloatResizeRim
        }
    }

    /// Item clock, outline rows, and transport. Same actions as the detached window.
    private var studioControls: some View {
        VStack(spacing: 0) {
            itemRunTimeRow
            outlineList
                .frame(maxHeight: .infinity)
            transportRow
        }
        .overlay {
            itemProgressEdge
        }
    }

    private var blocks: [RundownBlock] {
        controller.programDocumentSnapshot().rundownBlocks
    }

    private var clock: RundownClockEngine { controller.rundownClock }

    private var anchorIndex: Int {
        guard !blocks.isEmpty else { return 0 }
        if clock.isShowRunning, let active = clock.activeBlockIndex, blocks.indices.contains(active) {
            return active
        }
        let focused = controller.rundownFocusedBlockIndex
        return min(max(0, focused), blocks.count - 1)
    }

    private var visibleIndices: [Int] {
        Self.windowIndices(anchor: anchorIndex, count: blocks.count, following: 5)
    }

    static func windowIndices(anchor: Int, count: Int, following: Int) -> [Int] {
        guard count > 0 else { return [] }
        let clamped = min(max(0, anchor), count - 1)
        var indices: [Int] = []
        if clamped > 0 { indices.append(clamped - 1) }
        indices.append(clamped)
        let last = min(count - 1, clamped + following)
        if clamped + 1 <= last {
            indices.append(contentsOf: (clamped + 1)...last)
        }
        return indices
    }

    private var itemProgress: CGFloat {
        guard clock.isShowRunning,
              let index = clock.activeBlockIndex,
              blocks.indices.contains(index)
        else { return 0 }
        let planned = max(1, blocks[index].plannedDurationSeconds)
        return CGFloat(min(1, clock.activeBlockElapsedSeconds / planned))
    }

    private var dragBar: some View {
        HStack {
            Text("Stream outline")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RundownChrome.mutedLabel)
            Spacer(minLength: 0)
            Button {
                chrome.toggle()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PromptGlassButtonStyle())
            .accessibilityLabel("Close outline window")
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background {
            PromptWindowDragHandle { }
                .accessibilityLabel("Drag outline")
        }
    }

    private var itemRunTimeRow: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(alignment: .firstTextBaseline) {
                Text("Item run time")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RundownChrome.mutedLabel)
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                Text(itemRunTimeText)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(itemRunTimeColor)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Item run time \(itemRunTimeText)")
    }

    private var itemRunTimeText: String {
        if clock.isShowRunning {
            return RundownFormat.itemRunTime(clock.activeBlockElapsedSeconds)
        }
        return "00:00:00"
    }

    private var itemRunTimeColor: Color {
        guard clock.isShowRunning,
              let index = clock.activeBlockIndex,
              blocks.indices.contains(index),
              clock.activeBlockElapsedSeconds > blocks[index].plannedDurationSeconds
        else { return ProShowTheme.lyricWhite }
        return ProShowTheme.liveRed
    }

    private var outlineList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(visibleIndices, id: \.self) { index in
                    miniOutlineRow(blocks[index], index: index)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(minHeight: 88)
    }

    private func miniOutlineRow(_ block: RundownBlock, index: Int) -> some View {
        let isCurrent = index == anchorIndex
        let isLive = clock.isShowRunning && clock.activeBlockIndex == index
        return HStack(spacing: 8) {
            Text(block.itemNumber)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isLive ? Color.white.opacity(0.9) : RundownChrome.mutedLabel)
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title)
                    .font(.system(size: isCurrent ? 13 : 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isLive ? Color.white : ProShowTheme.primaryLabel)
                    .lineLimit(2)
                if isCurrent {
                    Text(RundownFormat.duration(block.plannedDurationSeconds))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(RundownChrome.mutedLabel)
                }
            }
            Spacer(minLength: 0)
            if isLive {
                Text(ProShowCopy.Status.live)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ProShowTheme.liveRed)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isLive
                        ? RundownChrome.activeRow
                        : (isCurrent ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(count: 2) {
            controller.takeRundownBlockLive(at: index)
        }
        .onTapGesture(count: 1) {
            controller.stepRundownOutline(to: index)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(block.itemNumber), \(block.title)")
        .accessibilityHint("Double-click to take live")
    }

    private var transportRow: some View {
        HStack(spacing: 6) {
            miniTransport("chevron.up", label: "Previous outline live") {
                controller.takeAdjacentRundownBlockLive(by: -1)
            }
            miniTransport("chevron.down", label: "Next outline live") {
                controller.takeAdjacentRundownBlockLive(by: 1)
            }
            miniTransport("stop.fill", label: "Clear slide") {
                _ = controller.clearLayer(named: "slide")
            }
            if clock.isShowRunning {
                miniTransport("stop.circle", label: "Stop show") {
                    clock.stopShow()
                    controller.refreshRundownTick()
                }
            } else {
                miniTransport("play.fill", label: "Start show") {
                    controller.startRundownShow(from: anchorIndex)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func miniTransport(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(PromptGlassButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    /// Progress is the bottom edge of the outline, not a bar floating above it.
    private var itemProgressEdge: some View {
        GeometryReader { geo in
            progressEdgeColor
                .frame(width: max(0, geo.size.width * itemProgress), height: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var progressEdgeColor: Color {
        itemRunTimeColor == ProShowTheme.liveRed ? ProShowTheme.liveRed : ProShowTheme.accent
    }

    private var rundownFloatResizeRim: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0).allowsHitTesting(false)
                RundownOutlineResizeHandle(edge: .bottom)
                    .frame(height: 10)
            }
            HStack(spacing: 0) {
                RundownOutlineResizeHandle(edge: .left).frame(width: 8)
                Spacer(minLength: 0).allowsHitTesting(false)
                RundownOutlineResizeHandle(edge: .right).frame(width: 8)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0).allowsHitTesting(false)
                HStack(spacing: 0) {
                    RundownOutlineResizeHandle(edge: .bottomLeft).frame(width: 18, height: 18)
                    Spacer(minLength: 0).allowsHitTesting(false)
                    RundownOutlineResizeHandle(edge: .bottomRight).frame(width: 18, height: 18)
                }
            }
        }
    }
}

struct RundownOutlineResizeHandle: NSViewRepresentable {
    var edge: RundownOutlineResizeEdge

    func makeNSView(context: Context) -> RundownOutlineResizeView {
        let view = RundownOutlineResizeView()
        view.edge = edge
        return view
    }

    func updateNSView(_ nsView: RundownOutlineResizeView, context: Context) {
        nsView.edge = edge
    }
}

/// Program picture with the same mute and meter controls as the outline float.
struct RundownStreamPreview: View {
    @Bindable var controller: ShowController
    var showMeters: Bool
    var onToggleMeters: () -> Void

    var body: some View {
        let title = controller.streaming.isLive ? "Stream" : "Audience"
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(RundownChrome.mutedLabel)
                .tracking(0.5)
            ZStack {
                ProgramCanonicalMonitorView(
                    controller: controller,
                    outputEnabled: controller.programOutputEnabled,
                    isRenderingPaused: false
                )
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    controlBar
                    Spacer(minLength: 0)
                    if showMeters {
                        HStack(alignment: .bottom) {
                            RundownFloatProgramMeter(controller: controller)
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) output")
    }

    private var controlBar: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if controller.canMuteProgramLayer(.videoInput) {
                muteButton(
                    muted: controller.isProgramLayerAudioMuted(.videoInput),
                    label: "Camera"
                ) {
                    controller.toggleProgramLayerAudio(.videoInput)
                }
            }
            if controller.canMuteProgramLayer(.media) {
                muteButton(
                    muted: controller.isProgramLayerAudioMuted(.media),
                    label: "Media"
                ) {
                    controller.toggleProgramLayerAudio(.media)
                }
            }
            muteButton(muted: isProgramMixMuted, label: "Program") {
                controller.toggleAudioMute()
            }
            iconButton(
                systemImage: showMeters ? "waveform" : "waveform.slash",
                label: showMeters ? "Hide audio meters" : "Show audio meters",
                active: showMeters,
                action: onToggleMeters
            )
        }
        .padding(6)
        .background {
            LinearGradient(
                colors: [Color.black.opacity(0.72), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    private var isProgramMixMuted: Bool {
        controller.audioIO.programMuted || controller.compositor.stack.audioMuted
    }

    private func muteButton(muted: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(muted ? ProShowTheme.liveRed : Color.white.opacity(0.92))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(PromptGlassButtonStyle())
        .help(muted ? "Unmute \(label)" : "Mute \(label)")
        .accessibilityLabel(muted ? "Unmute \(label)" : "Mute \(label)")
    }

    private func iconButton(
        systemImage: String,
        label: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? ProShowTheme.accent : Color.white.opacity(0.92))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(PromptGlassButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct RundownFloatProgramMeter: View {
    @Bindable var controller: ShowController

    var body: some View {
        AudioMeterBridgeView(orientation: .vertical) {
            let monitor = AudioMonitoringEngine.shared
            if monitor.monitorMode == .programMix {
                return [
                    AudioMeterSample(id: "L", name: "L", db: monitor.leftPeakDb, holdDb: monitor.leftPeakDb, isMuted: false),
                    AudioMeterSample(id: "R", name: "R", db: monitor.rightPeakDb, holdDb: monitor.rightPeakDb, isMuted: false)
                ]
            }
            let fallback = controller.playback.outputLevel
            let left = AudioMeterBridgeView.decibels(fromLinear: controller.compositor.lastFrame?.leftMeter ?? fallback)
            let right = AudioMeterBridgeView.decibels(fromLinear: controller.compositor.lastFrame?.rightMeter ?? fallback)
            return [
                AudioMeterSample(id: "L", name: "L", db: left, holdDb: left, isMuted: false),
                AudioMeterSample(id: "R", name: "R", db: right, holdDb: right, isMuted: false)
            ]
        }
        .frame(width: 28, height: 56)
        .accessibilityLabel("Program audio levels")
    }
}

final class RundownOutlineResizeView: NSView {
    var edge: RundownOutlineResizeEdge = .bottomRight

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = window.frame
        let startMouse = NSEvent.mouseLocation
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { next, stop in
            guard let next else {
                stop.pointee = true
                return
            }
            if next.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y
            window.setFrame(self.resized(start, dx: dx, dy: dy), display: true)
        }
    }

    private func resized(_ start: NSRect, dx: CGFloat, dy: CGFloat) -> NSRect {
        var size = start.size
        switch edge {
        case .right:
            size.width = start.width + dx
        case .left:
            size.width = start.width - dx
        case .bottom:
            size.height = start.height - dy
        case .bottomRight:
            size.width = start.width + dx
            size.height = start.height - dy
        case .bottomLeft:
            size.width = start.width - dx
            size.height = start.height - dy
        }
        size = RundownFloatWindowLayout.fittedSize(size, edge: edge)
        var origin = start.origin
        switch edge {
        case .left, .bottomLeft:
            origin.x = start.maxX - size.width
        case .bottom, .bottomRight, .bottomLeft:
            origin.y = start.maxY - size.height
        default:
            break
        }
        return NSRect(origin: origin, size: size)
    }

    private var resizeCursor: NSCursor {
        switch edge {
        case .left, .right:
            return .resizeLeftRight
        case .bottom:
            return .resizeUpDown
        case .bottomLeft, .bottomRight:
            if #available(macOS 15.0, *) {
                return .frameResize(position: edge == .bottomRight ? .bottomRight : .bottomLeft, directions: .all)
            }
            return .crosshair
        }
    }
}

#endif
