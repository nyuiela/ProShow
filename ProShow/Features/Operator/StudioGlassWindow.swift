#if os(macOS)
import AppKit
import SwiftUI

enum StudioGlassViewKind: String, CaseIterable, Identifiable, Sendable {
    case outline
    case live
    case slides
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline: "Stream outline"
        case .live: "Live"
        case .slides: "Slides"
        case .audio: "Audio"
        }
    }
}

enum StudioGlassDockEdge: String, Sendable {
    case left, right, top, bottom

    var expandSymbol: String {
        switch self {
        case .left: "chevron.right"
        case .right: "chevron.left"
        case .top: "chevron.down"
        case .bottom: "chevron.up"
        }
    }
}

/// Floating studio panel. It must not become key: keying thins the Liquid Glass.
final class StudioNonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Liquid-glass operator window. Same panel rules as the prompt and outline floats.
@MainActor
@Observable
final class StudioGlassController: NSObject, NSWindowDelegate {
    static let shared = StudioGlassController()
    static let windowTitle = "ProShow Studio"

    private(set) var isOpen = false
    private(set) var isEdgeDocked = false
    var showLiveMeters = false
    var paneCount: Int = 4
    var order: [StudioGlassViewKind] = StudioGlassViewKind.allCases
    static let paneOptions = [2, 4, 6, 8]
    weak var rundown: ShowController?

    private var panel: NSPanel?
    private var edgePanel: NSPanel?
    private var rememberedFrame: NSRect?
    private var preZoomFrame: NSRect?
    private(set) var isZoomed = false
    private(set) var dockEdge: StudioGlassDockEdge = .right

    var isMainPanelShown: Bool {
        guard let panel, !isEdgeDocked else { return false }
        return panel.isVisible && !panel.isMiniaturized
    }

    func attach(_ controller: ShowController) {
        rundown = controller
    }

    func toggle(on screen: NSScreen?) {
        if isEdgeDocked {
            expandFromEdge(on: screen)
            return
        }
        if isMainPanelShown {
            close()
        } else {
            open(on: screen)
        }
    }

    func open(on screen: NSScreen?) {
        if isEdgeDocked {
            expandFromEdge(on: screen)
            return
        }
        ensurePanel()
        guard let panel else { return }
        let target = screen ?? panel.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        guard let target else { return }
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        if isMainPanelShown {
            panel.orderFrontRegardless()
            if let p = panel as NSWindow? { FloatingPanelTransparency.clearChain(p) }
            NSApp.activate(ignoringOtherApps: true)
            markOpen()
            return
        }
        isZoomed = false
        preZoomFrame = nil
        let frame = Self.resolvedFrame(remembered: rememberedFrame, on: target)
        panel.setFrame(frame, display: true)
        rememberedFrame = frame
        panel.orderFrontRegardless()
        if let p = panel as NSWindow? { FloatingPanelTransparency.clearChain(p) }
        NSApp.activate(ignoringOtherApps: true)
        markOpen()
    }

    func close() {
        if let frame = panel?.frame, !isEdgeDocked { rememberedFrame = frame }
        panel?.orderOut(nil)
        edgePanel?.orderOut(nil)
        isEdgeDocked = false
        isZoomed = false
        preZoomFrame = nil
        isOpen = false
        rundown?.isMultiViewerOn = false
    }

    func miniaturizeWindow() {
        ensurePanel()
        guard let panel else { return }
        panel.styleMask.insert(.miniaturizable)
        panel.miniaturize(nil)
        markOpen()
    }

    /// Zoom the floating panel to the screen's visible frame, then back to the previous size.
    func toggleFullScreen() {
        ensurePanel()
        if isEdgeDocked { expandFromEdge() }
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let screen else { return }
        if isZoomed {
            let restore = preZoomFrame ?? Self.defaultFrame(on: screen)
            panel.setFrame(restore, display: true, animate: false)
            rememberedFrame = restore
            isZoomed = false
            preZoomFrame = nil
        } else {
            preZoomFrame = panel.frame
            rememberedFrame = panel.frame
            panel.setFrame(screen.visibleFrame, display: true, animate: false)
            isZoomed = true
        }
        panel.orderFrontRegardless()
        if let p = panel as NSWindow? { FloatingPanelTransparency.clearChain(p) }
        markOpen()
    }

    func dockToEdge(preferredEdge: StudioGlassDockEdge? = nil) {
        guard let panel, !isEdgeDocked else { return }
        rememberedFrame = panel.frame
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        dockEdge = preferredEdge ?? Self.nearestHorizontalEdge(for: panel.frame, in: screen.visibleFrame)
            ?? Self.nearestEdge(for: panel.frame, in: screen.visibleFrame)
        panel.orderOut(nil)
        isEdgeDocked = true
        ensureEdgePanel()
        placeEdgePanel(on: screen)
        edgePanel?.orderFrontRegardless()
        if let p = edgePanel as NSWindow? { FloatingPanelTransparency.clearChain(p) }
        markOpen()
    }

    /// When the window is dragged flush to the left or right edge, dock and show the expand pill.
    func snapAfterDrag() {
        guard let panel, !isEdgeDocked, !isZoomed else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        guard let edge = Self.horizontalSnapEdge(for: panel.frame, in: screen.visibleFrame) else { return }
        dockToEdge(preferredEdge: edge)
    }

    /// Only snap when the window is clearly hugging one side, not when it spans the display.
    static func horizontalSnapEdge(for frame: NSRect, in visible: NSRect, threshold: CGFloat = 48) -> StudioGlassDockEdge? {
        let left = frame.minX - visible.minX
        let right = visible.maxX - frame.maxX
        if frame.width >= visible.width - threshold * 2 { return nil }
        if left < threshold, right > threshold * 2 { return .left }
        if right < threshold, left > threshold * 2 { return .right }
        return nil
    }

    static func defaultFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(1280, max(800, visible.width - 80))
        let height = min(800, max(480, visible.height - 80))
        let size = NSSize(width: width, height: height)
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        return NSRect(origin: origin, size: size)
    }

    static func resolvedFrame(remembered: NSRect?, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        if let remembered, visible.intersects(remembered) {
            var frame = remembered
            if frame.width < 800 || frame.height < 480 {
                frame = defaultFrame(on: screen)
            }
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            return frame
        }
        return defaultFrame(on: screen)
    }

    func expandFromEdge(on screen: NSScreen? = nil) {
        guard isEdgeDocked else { return }
        edgePanel?.orderOut(nil)
        isEdgeDocked = false
        ensurePanel()
        guard let panel else { return }
        let target = screen ?? panel.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        guard let target else { return }
        let frame = Self.resolvedFrame(remembered: rememberedFrame, on: target)
        panel.setFrame(frame, display: true)
        rememberedFrame = frame
        panel.orderFrontRegardless()
        if let p = panel as NSWindow? { FloatingPanelTransparency.clearChain(p) }
        NSApp.activate(ignoringOtherApps: true)
        markOpen()
    }

    func toggleEdgeDock(on screen: NSScreen? = nil) {
        if isEdgeDocked {
            expandFromEdge(on: screen)
            return
        }
        if !isMainPanelShown {
            open(on: screen)
        }
        guard isMainPanelShown else { return }
        dockToEdge()
    }

    private func markOpen() {
        isOpen = true
        rundown?.isMultiViewerOn = true
    }

    static func nearestHorizontalEdge(for frame: NSRect, in visible: NSRect) -> StudioGlassDockEdge? {
        horizontalSnapEdge(for: frame, in: visible)
    }

    static func nearestEdge(for frame: NSRect, in visible: NSRect) -> StudioGlassDockEdge {
        let left = abs(frame.minX - visible.minX)
        let right = abs(visible.maxX - frame.maxX)
        let top = abs(visible.maxY - frame.maxY)
        let bottom = abs(frame.minY - visible.minY)
        let best = min(left, right, top, bottom)
        if best == left { return .left }
        if best == right { return .right }
        if best == top { return .top }
        return .bottom
    }

    func move(_ source: StudioGlassViewKind, before destination: StudioGlassViewKind) {
        guard source != destination,
              let from = order.firstIndex(of: source)
        else { return }
        var to = order.firstIndex(of: destination) ?? order.count
        order.remove(at: from)
        if from < to { to -= 1 }
        let clamped = min(max(0, to), order.count)
        order.insert(source, at: clamped)
    }

    func setPaneCount(_ count: Int) {
        guard Self.paneOptions.contains(count) else { return }
        paneCount = count
    }

    func visiblePanes() -> [StudioGlassViewKind] {
        var panes: [StudioGlassViewKind] = []
        guard !order.isEmpty else { return panes }
        while panes.count < paneCount {
            for kind in order {
                guard panes.count < paneCount else { break }
                panes.append(kind)
            }
        }
        return panes
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        rundown?.isMultiViewerOn = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, !isEdgeDocked else { return }
        rememberedFrame = panel.frame
        if isZoomed, let screen = panel.screen {
            let visible = screen.visibleFrame
            if abs(panel.frame.width - visible.width) > 4 || abs(panel.frame.height - visible.height) > 4 {
                isZoomed = false
                preZoomFrame = nil
            }
        }
    }

    private func ensureEdgePanel() {
        guard edgePanel == nil else { return }
        let hosting = NSHostingController(rootView: StudioGlassEdgeRoot())
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 36, height: 112)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = Self.windowTitle
        panel.identifier = NSUserInterfaceItemIdentifier("proshow-studio-edge")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        hosting.view.autoresizingMask = [.width, .height]
        FloatingPanelTransparency.apply(to: panel, hosting: hosting)
        if let hostingView = hosting.view as? NSHostingView<StudioGlassEdgeRoot> {
            hostingView.safeAreaRegions = []
        }
        edgePanel = panel
    }

    private func placeEdgePanel(on screen: NSScreen) {
        guard let edgePanel else { return }
        let visible = screen.visibleFrame
        let vertical = NSSize(width: 36, height: 132)
        let horizontal = NSSize(width: 112, height: 36)
        let origin: NSPoint
        let size: NSSize
        switch dockEdge {
        case .left:
            size = vertical
            origin = NSPoint(x: visible.minX + 4, y: visible.midY - size.height / 2)
        case .right:
            size = vertical
            origin = NSPoint(x: visible.maxX - size.width - 4, y: visible.midY - size.height / 2)
        case .top:
            size = horizontal
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 4)
        case .bottom:
            size = horizontal
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 4)
        }
        edgePanel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingController(rootView: StudioGlassRoot())
        let panel = StudioNonKeyPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1280, height: 800)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = Self.windowTitle
        panel.identifier = NSUserInterfaceItemIdentifier("proshow-studio")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 800, height: 480)
        panel.maxSize = NSSize(width: 4000, height: 2400)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        hosting.view.autoresizingMask = [.width, .height]
        FloatingPanelTransparency.apply(to: panel, hosting: hosting)
        if let hostingView = hosting.view as? NSHostingView<StudioGlassRoot> {
            hostingView.safeAreaRegions = []
        }
        self.panel = panel
    }
}

private struct StudioGlassEdgeRoot: View {
    @Bindable private var chrome = StudioGlassController.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 6) {
            Button {
                chrome.expandFromEdge()
            } label: {
                Image(systemName: chrome.dockEdge.expandSymbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ProShowTheme.primaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(DeskPressButtonStyle())
            .help("Expand studio window")
            .accessibilityLabel("Expand studio window")
            Button {
                chrome.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RundownChrome.mutedLabel)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(DeskPressButtonStyle())
            .help("Close studio window")
            .accessibilityLabel("Close studio window")
        }
        .padding(4)
        .promptGlass(cornerRadius: 14, solid: reduceTransparency)
    }
}

private struct StudioWindowTrafficLights: View {
    @Bindable private var chrome = StudioGlassController.shared

    var body: some View {
        HStack(spacing: 6) {
            StudioTrafficLight(
                color: Color(red: 1, green: 0.37, blue: 0.34),
                glyph: "xmark",
                label: "Close studio window"
            ) {
                chrome.close()
            }
            StudioTrafficLight(
                color: Color(red: 1, green: 0.74, blue: 0.18),
                glyph: "minus",
                label: "Minimize studio window"
            ) {
                chrome.miniaturizeWindow()
            }
            StudioTrafficLight(
                color: Color(red: 0.39, green: 0.8, blue: 0.36),
                glyph: "arrow.up.left.and.arrow.down.right",
                label: chrome.isZoomed ? "Restore studio window size" : "Zoom studio window"
            ) {
                chrome.toggleFullScreen()
            }
            StudioTrafficLight(
                color: Color(red: 0.55, green: 0.62, blue: 0.72),
                glyph: "sidebar.right",
                label: "Dock studio to screen edge"
            ) {
                chrome.toggleEdgeDock()
            }
        }
        .padding(.trailing, 4)
    }
}

struct StudioTrafficLight: View {
    let color: Color
    let glyph: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                if isHovered {
                    Image(systemName: glyph)
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.72))
                }
            }
            .frame(width: 12, height: 12)
            .padding(6)
            .contentShape(Rectangle())
            .overlay {
                Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                    .frame(width: 12, height: 12)
            }
        }
        .buttonStyle(StudioTrafficLightButtonStyle())
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct StudioTrafficLightButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct StudioGlassRoot: View {
    @Bindable private var chrome = StudioGlassController.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let controller = chrome.rundown {
                StudioGlassDesk(controller: controller)
            } else {
                Text("No rundown loaded.")
                    .font(DeskType.body)
                    .foregroundStyle(RundownChrome.mutedLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .padding(6)
        .promptGlass(cornerRadius: 28, solid: reduceTransparency)
        .overlay { StudioGlassResizeRim() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chrome.order)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chrome.paneCount)
    }
}

private struct StudioGlassDesk: View {
    @Bindable var controller: ShowController
    @Bindable private var chrome = StudioGlassController.shared
    @State private var dropTarget: StudioGlassViewKind?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            GeometryReader { proxy in
                let panes = chrome.visiblePanes()
                let frames = StudioGlassLayout.frames(count: panes.count, in: proxy.size)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(panes.enumerated()), id: \.offset) { index, kind in
                        if frames.indices.contains(index) {
                            tile(kind)
                                .frame(width: frames[index].width, height: frames[index].height)
                                .position(x: frames[index].midX, y: frames[index].midY)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            StudioWindowTrafficLights()
            Text("Studio")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RundownChrome.mutedLabel)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(StudioGlassController.paneOptions, id: \.self) { count in
                    paneCountButton(count)
                }
            }
            Spacer(minLength: 0)
                .frame(width: 52)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background {
            PromptWindowDragHandle {
                chrome.snapAfterDrag()
            }
                .accessibilityLabel("Drag studio window")
        }
    }

    private func paneCountButton(_ count: Int) -> some View {
        let selected = chrome.paneCount == count
        return Button {
            chrome.setPaneCount(count)
        } label: {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? ProShowTheme.accent : RundownChrome.mutedLabel)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PromptGlassButtonStyle())
        .help("\(count) studio panes")
        .accessibilityLabel("\(count) panes")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tile(_ kind: StudioGlassViewKind) -> some View {
        VStack(spacing: 0) {
            tileHeader(kind)
            Group {
                switch kind {
                case .outline:
                    RundownMiniOutlinePanel(controller: controller, chromeStyle: .studio)
                case .live:
                    StudioLiveTile(controller: controller)
                case .slides:
                    StudioSlidesTile(controller: controller)
                case .audio:
                    StudioAudioGlass(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(kind == .audio ? ProShowTheme.panel : Color.white.opacity(dropTarget == kind ? 0.10 : 0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    dropTarget == kind ? ProShowTheme.accent : Color.white.opacity(0.14),
                    lineWidth: dropTarget == kind ? 1.5 : 0.6
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onDrop(of: [.plainText], isTargeted: dropBinding(for: kind)) { providers in
            acceptDrop(providers, before: kind)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
    }

    private func tileHeader(_ kind: StudioGlassViewKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RundownChrome.mutedLabel)
                .accessibilityHidden(true)
            Text(kind.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RundownChrome.mutedLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: kind.rawValue as NSString)
        }
        .accessibilityLabel("Reorder \(kind.title)")
        .accessibilityHint("Drag onto another view")
    }

    private func dropBinding(for kind: StudioGlassViewKind) -> Binding<Bool> {
        Binding(
            get: { dropTarget == kind },
            set: { isTargeted in
                if isTargeted {
                    dropTarget = kind
                } else if dropTarget == kind {
                    dropTarget = nil
                }
            }
        )
    }

    private func acceptDrop(_ providers: [NSItemProvider], before kind: StudioGlassViewKind) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String, let source = StudioGlassViewKind(rawValue: raw) else { return }
            Task { @MainActor in
                chrome.move(source, before: kind)
                dropTarget = nil
            }
        }
        return true
    }
}

private struct StudioLiveTile: View {
    @Bindable var controller: ShowController
    @Bindable private var chrome = StudioGlassController.shared

    var body: some View {
        let _ = controller.programFrameRevisionStamp
        let _ = controller.compositor.stack
        GeometryReader { proxy in
            let metrics = StudioLiveLayout.layout(in: proxy.size)
            if metrics.sideBySide {
                HStack(alignment: .top, spacing: StudioLiveLayout.gap) {
                    livePicture
                        .frame(width: metrics.videoSize.width, height: metrics.previewHeight, alignment: .top)
                        .frame(maxHeight: .infinity, alignment: .center)
                    layerList
                        .frame(width: metrics.layersWidth, height: proxy.size.height, alignment: .top)
                }
                .padding(.horizontal, StudioLiveLayout.horizontalInset / 2)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    livePicture
                        .frame(width: metrics.videoSize.width, height: metrics.previewHeight, alignment: .top)
                        .frame(maxWidth: .infinity)
                    layerList
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live output and layers")
    }

    private var livePicture: some View {
        RundownStreamPreview(
            controller: controller,
            showMeters: chrome.showLiveMeters,
            onToggleMeters: { chrome.showLiveMeters.toggle() }
        )
    }

    private var layerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Layers")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RundownChrome.mutedLabel)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 2)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(RenderLayer.allCases.reversed()) { layer in
                        layerRow(layer)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func layerRow(_ layer: RenderLayer) -> some View {
        let hidden = controller.compositor.stack.isCleared(layer)
        let summary = layer.contentSummary(in: controller.compositor.stack)
        return HStack(spacing: 8) {
            Button {
                controller.toggleLayer(layer)
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hidden ? RundownChrome.mutedLabel : Color.white.opacity(0.92))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel(hidden ? "Show \(layer.title)" : "Hide \(layer.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hidden ? RundownChrome.mutedLabel : ProShowTheme.primaryLabel)
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RundownChrome.mutedLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct StudioSlidesTile: View {
    @Bindable var controller: ShowController

    var body: some View {
        let _ = controller.liveSlideID
        let _ = controller.selectedSlideID
        let _ = controller.selectedPlaylistItemTitle
        let _ = controller.programFrameRevisionStamp
        let _ = controller.rundownClock.activeBlockIndex
        GeometryReader { proxy in
            let metrics = StudioSlidePairLayout.layout(in: proxy.size)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlistTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RundownChrome.mutedLabel)
                    .lineLimit(1)
                    .padding(.top, 4)
                Group {
                    if metrics.sideBySide {
                        HStack(alignment: .top, spacing: StudioSlidePairLayout.pairGap) {
                            slideCard("Current", slide: currentSlide, empty: "No current slide", video: metrics.videoSize)
                            slideCard("Next", slide: nextSlide, empty: "No upcoming slide", video: metrics.videoSize)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: StudioSlidePairLayout.pairGap) {
                            slideCard("Current", slide: currentSlide, empty: "No current slide", video: metrics.videoSize)
                            slideCard("Next", slide: nextSlide, empty: "No upcoming slide", video: metrics.videoSize)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: metrics.sideBySide ? .center : .topLeading)
            }
            .padding(.horizontal, 8)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current and next slides, \(playlistTitle)")
    }

    private var playlistTitle: String {
        let selected = controller.selectedPlaylistItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        return controller.playlist.name
    }

    private var currentSlide: Slide? {
        if let live = controller.liveSlide { return live }
        return controller.selectedSlide
    }

    private var nextSlide: Slide? {
        controller.nextSlide
    }

    private func slideCard(_ title: String, slide: Slide?, empty: String, video: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(RundownChrome.mutedLabel)
                .tracking(0.5)
            slidePicture(slide, video: video)
            Text(caption(for: slide, empty: empty))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(slide == nil ? RundownChrome.mutedLabel : ProShowTheme.primaryLabel)
                .lineLimit(1)
                .frame(maxWidth: video.width, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(caption(for: slide, empty: empty))")
    }

    private func caption(for slide: Slide?, empty: String) -> String {
        guard let slide else { return empty }
        return outlineTitle(for: slide)
    }

    /// Outline row title. Blank program slides still carry that title even when the first layer is empty.
    private func outlineTitle(for slide: Slide) -> String {
        let blocks = controller.programDocumentSnapshot().rundownBlocks
        if let block = blocks.first(where: {
            $0.programSlideID == slide.id || $0.linkedPresentationSlideID == slide.id
        }) {
            let title = block.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func slidePicture(_ slide: Slide?, video: CGSize) -> some View {
        let well = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let slide {
                let preview = controller.slideGridThumbnailPreview(for: slide)
                ProgramSlideThumbnailPreview(
                    controller: controller,
                    slide: preview.slide,
                    objects: preview.canvas
                )
            } else {
                ProShowTheme.stageBlack
            }
        }
        .frame(width: video.width, height: video.height)
        .background(ProShowTheme.stageBlack)
        .clipShape(well)
    }
}

struct StudioGlassResizeRim: View {
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0).allowsHitTesting(false)
                StudioGlassResizeHandle(edge: .bottom).frame(height: 10)
            }
            HStack(spacing: 0) {
                StudioGlassResizeHandle(edge: .left).frame(width: 8)
                Spacer(minLength: 0).allowsHitTesting(false)
                StudioGlassResizeHandle(edge: .right).frame(width: 8)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0).allowsHitTesting(false)
                HStack(spacing: 0) {
                    StudioGlassResizeHandle(edge: .bottomLeft).frame(width: 18, height: 18)
                    Spacer(minLength: 0).allowsHitTesting(false)
                    StudioGlassResizeHandle(edge: .bottomRight).frame(width: 18, height: 18)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

enum StudioGlassResizeEdge {
    case left, right, bottom, bottomLeft, bottomRight
}

struct StudioGlassResizeHandle: NSViewRepresentable {
    var edge: StudioGlassResizeEdge

    func makeNSView(context: Context) -> StudioGlassResizeView {
        let view = StudioGlassResizeView()
        view.edge = edge
        return view
    }

    func updateNSView(_ nsView: StudioGlassResizeView, context: Context) {
        nsView.edge = edge
    }
}

final class StudioGlassResizeView: NSView {
    var edge: StudioGlassResizeEdge = .bottomRight

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = window.frame
        let startMouse = NSEvent.mouseLocation
        let minimum = window.minSize
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
            window.setFrame(self.resized(start, dx: now.x - startMouse.x, dy: now.y - startMouse.y, minimum: minimum), display: true)
        }
    }

    private func resized(_ start: NSRect, dx: CGFloat, dy: CGFloat, minimum: NSSize) -> NSRect {
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
        size.width = max(minimum.width, size.width)
        size.height = max(minimum.height, size.height)
        var origin = start.origin
        switch edge {
        case .left, .bottomLeft:
            origin.x = start.maxX - size.width
        default:
            break
        }
        switch edge {
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
