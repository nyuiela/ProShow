import ImageIO
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
#if os(macOS)
import AppKit
import QuartzCore
import IOSurface
import Metal
#else
import UIKit
#endif

private struct ProShowVideoInputsKey: EnvironmentKey {
    static let defaultValue: VideoInputEngine? = nil
}

private struct ProShowPlaybackKey: EnvironmentKey {
    static let defaultValue: MediaPlaybackEngine? = nil
}

private struct PlaceholderResolveKey: EnvironmentKey {
    static let defaultValue: ((String) -> AssignedMediaSource?)? = nil
}

private struct PreferSharedProgramClockKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MirrorsProgramPlayerKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ProgramRenderPausedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ProShowProgramVideoInputKey: EnvironmentKey {
    static let defaultValue: VideoInputSource? = nil
}

private struct ProShowShowsProgramVideoLayerKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var proShowVideoInputs: VideoInputEngine? {
        get { self[ProShowVideoInputsKey.self] }
        set { self[ProShowVideoInputsKey.self] = newValue }
    }

    var proShowPlayback: MediaPlaybackEngine? {
        get { self[ProShowPlaybackKey.self] }
        set { self[ProShowPlaybackKey.self] = newValue }
    }

    var resolvePlaceholderSource: ((String) -> AssignedMediaSource?)? {
        get { self[PlaceholderResolveKey.self] }
        set { self[PlaceholderResolveKey.self] = newValue }
    }

    var preferSharedProgramClock: Bool {
        get { self[PreferSharedProgramClockKey.self] }
        set { self[PreferSharedProgramClockKey.self] = newValue }
    }

    var mirrorsProgramPlayer: Bool {
        get { self[MirrorsProgramPlayerKey.self] }
        set { self[MirrorsProgramPlayerKey.self] = newValue }
    }

    var programRenderPaused: Bool {
        get { self[ProgramRenderPausedKey.self] }
        set { self[ProgramRenderPausedKey.self] = newValue }
    }

    var proShowProgramVideoInput: VideoInputSource? {
        get { self[ProShowProgramVideoInputKey.self] }
        set { self[ProShowProgramVideoInputKey.self] = newValue }
    }

    var proShowShowsProgramVideoLayer: Bool {
        get { self[ProShowShowsProgramVideoLayerKey.self] }
        set { self[ProShowShowsProgramVideoLayerKey.self] = newValue }
    }
}

enum CanvasSwiftUIFont {
    static func resolve(
        family: String,
        size: CGFloat,
        weight: FontWeightToken,
        bold: Bool,
        italic: Bool
    ) -> Font {
        #if canImport(AppKit)
        Font(CanvasTypeface.nsFont(family: family, size: size, weight: weight, bold: bold, italic: italic))
        #else
        let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return .custom(name.isEmpty ? "Helvetica" : name, size: max(1, size))
        #endif
    }
}

extension View {
    /// Hides without flattening AV/Metal layers while visible. Opacity is applied only when hidden so the player stays in the tree.
    @ViewBuilder
    func hiddenKeepingAlive(_ hidden: Bool) -> some View {
        if hidden {
            self.opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        } else {
            self
        }
    }
}

#if os(macOS)
final class DeskDropNSView: NSView {
    weak var controller: ShowController?
    var role: DeskDropRole = .slides

    private static let stringTypes: [NSPasteboard.PasteboardType] = [
        .string,
        NSPasteboard.PasteboardType("public.utf8-plain-text"),
        NSPasteboard.PasteboardType("public.plain-text"),
        NSPasteboard.PasteboardType("public.json"),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .string,
            .html,
            .rtf,
            .fileURL,
            .png,
            .tiff,
            .pdf,
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
            NSPasteboard.PasteboardType("public.plain-text"),
            NSPasteboard.PasteboardType("public.json"),
            NSPasteboard.PasteboardType("public.file-url"),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), isMouseDragged else { return nil }
        return shouldIntercept(NSPasteboard(name: .drag)) ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        return controller.handleDeskDrop(
            payload: payload(from: sender.draggingPasteboard, controller: controller),
            files: fileURLs(from: sender),
            role: role
        )
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.endWorkspaceDrag()
    }

    private var isMouseDragged: Bool {
        let type = NSApp.currentEvent?.type
        return type == .leftMouseDragged || type == .periodic
    }

    private func shouldIntercept(_ board: NSPasteboard) -> Bool {
        let files = board.availableType(from: [.fileURL, NSPasteboard.PasteboardType("public.file-url")]) != nil
        let payload = payload(from: board, controller: controller)
        switch role {
        case .ignore:
            return false
        case .mediaBin:
            return files
        case .editor:
            return files || payload != nil
        case .slides:
            return files || (payload != nil && payload?.kind != .slide)
        }
    }

    private func payload(from board: NSPasteboard, controller: ShowController?) -> WorkspaceDragPayload? {
        if let active = WorkspaceDragPasteboard.active { return active }
        if let dragging = controller?.draggingPayload { return dragging }
        for type in Self.stringTypes {
            if let parsed = board.string(forType: type).flatMap(WorkspaceDragPayload.parse) {
                return parsed
            }
            if let data = board.data(forType: type) {
                if let parsed = WorkspaceDragPayload.parse(String(decoding: data, as: UTF8.self)) {
                    return parsed
                }
                if let decoded = try? JSONDecoder().decode(WorkspaceDragPayload.self, from: data) {
                    return decoded
                }
            }
        }
        return board.pasteboardItems?.compactMap { item in
            Self.stringTypes.compactMap { item.string(forType: $0) }.first
        }.compactMap(WorkspaceDragPayload.parse).first
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let board = info.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            return urls
        }
        return board.pasteboardItems?.compactMap { item in
            guard let raw = item.string(forType: .fileURL) else { return nil }
            return URL(string: raw) ?? URL(fileURLWithPath: raw)
        } ?? []
    }
}

struct DeskDropCatcher: NSViewRepresentable {
    var controller: ShowController
    var role: DeskDropRole

    func makeNSView(context: Context) -> DeskDropNSView {
        let view = DeskDropNSView()
        view.controller = controller
        view.role = role
        return view
    }

    func updateNSView(_ nsView: DeskDropNSView, context: Context) {
        nsView.controller = controller
        nsView.role = role
    }
}
#else
struct DeskDropCatcher: View {
    var controller: ShowController
    var role: DeskDropRole
    var body: some View { Color.clear.accessibilityHidden(true) }
}
#endif

#if os(macOS)
enum DeskLiveLayer {
    static func pin(_ layer: CALayer, in view: NSView) {
        lockHost(view)
        lockMediaLayer(layer)
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layout(layer, in: view.bounds)
    }

    static func layout(_ layer: CALayer, in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
    }

    static func lockHost(_ view: NSView, color: NSColor = .black) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.isOpaque = true
        view.layer?.contentsGravity = .resize
        view.layer?.drawsAsynchronously = true
        if let metal = view.layer as? CAMetalLayer {
            metal.presentsWithTransaction = false
            metal.backgroundColor = color.cgColor
            metal.isOpaque = true
        }
        lockMediaLayer(view.layer)
    }

    static func lockMediaLayer(_ layer: CALayer?) {
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        if let metal = layer as? CAMetalLayer {
            metal.presentsWithTransaction = false
        }
        #if canImport(AVFoundation)
        if let player = layer as? AVPlayerLayer {
            player.backgroundColor = NSColor.black.cgColor
        }
        if let preview = layer as? AVCaptureVideoPreviewLayer {
            preview.backgroundColor = NSColor.black.cgColor
        }
        if let sample = layer as? AVSampleBufferDisplayLayer {
            sample.backgroundColor = NSColor.black.cgColor
        }
        #endif
    }

    static func applyFrameStyle(_ view: NSView, style: MediaFrameStyle) {
        view.wantsLayer = true
        if let layer = view.layer {
            MediaFrameEngine.apply(to: layer, style: style)
        }
    }

    static func lockPresentation(in view: NSView, active: Bool) {
        func walk(_ node: NSView) {
            freezeMediaLayers(node.layer, frozen: active)
            if let metal = node.layer as? CAMetalLayer {
                metal.presentsWithTransaction = active
            }
            for child in node.subviews { walk(child) }
        }
        walk(view)
    }

    static func freezeMediaLayers(_ layer: CALayer?, frozen: Bool) {
        guard let layer else { return }
        layer.needsDisplayOnBoundsChange = !frozen
        if let metal = layer as? CAMetalLayer {
            metal.presentsWithTransaction = frozen
        }
        for child in layer.sublayers ?? [] {
            freezeMediaLayers(child, frozen: frozen)
        }
    }

    static func syncMetalDrawable(in view: NSView, size: NSSize) {
        guard let metal = view.layer as? CAMetalLayer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        metal.drawableSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }
}

enum DeskWindowChrome {
    static func lock(_ window: NSWindow?) {
        guard let window else { return }
        window.backgroundColor = DeskNSColor.canvas
        window.isOpaque = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = DeskNSColor.canvas.cgColor
        window.contentView?.layer?.isOpaque = true
        window.contentView?.layer?.drawsAsynchronously = true
    }
}

/// Traffic lights stay. The system title bar, its title, and its bottom separator do not.
enum DeskMergedTitlebar {
    static var titleVisibility: NSWindow.TitleVisibility = .hidden

    @discardableResult
    static func restore(_ window: NSWindow?) -> Bool {
        guard let window, window.sheetParent == nil else { return false }
        var changed = false
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
            changed = true
        }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
            changed = true
        }
        if window.titlebarAppearsTransparent != true {
            window.titlebarAppearsTransparent = true
            changed = true
        }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
            changed = true
        }
        if window.toolbar?.items.isEmpty == true {
            window.toolbar = nil
            changed = true
        }
        if stripChrome(window) {
            changed = true
        }
        #if os(macOS)
        if ProShowStreamCapturePrivacy.deskConcealmentActive,
           !ProShowStreamCapturePrivacy.isSuspendingConcealment {
            window.sharingType = .none
        }
        #endif
        return changed
    }

    /// AppKit keeps a separator view after the title bar is hidden. That view is the black line.
    @discardableResult
    private static func stripChrome(_ window: NSWindow) -> Bool {
        guard let close = window.standardWindowButton(.closeButton) else { return false }
        var changed = false
        var view: NSView? = close
        var depth = 0
        while let current = view, depth < 6 {
            for subview in current.subviews {
                let name = NSStringFromClass(type(of: subview))
                let isSeparator = name.contains("Separator") || name.contains("TitlebarDecoration")
                let isLeftoverTitle = subview is NSTextField && current !== window.contentView
                if isSeparator || isLeftoverTitle {
                    if !subview.isHidden || subview.alphaValue > 0 {
                        subview.isHidden = true
                        subview.alphaValue = 0
                        changed = true
                    }
                }
            }
            view = current.superview
            depth += 1
        }
        return changed
    }
}

/// Re-applies the merged title bar on the desk window that owns this view, including while a sheet is up.
struct DeskTitlebarMergeGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> DeskTitlebarMergeGuardView {
        DeskTitlebarMergeGuardView()
    }

    func updateNSView(_ view: DeskTitlebarMergeGuardView, context: Context) {
        view.restore()
    }
}

final class DeskTitlebarMergeGuardView: NSView {
    private var observers: [NSObjectProtocol] = []
    private weak var observed: NSWindow?
    private var sheetTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
        restore()
        if deskWindow?.attachedSheet != nil {
            watchSheet()
        }
    }

    override func layout() {
        super.layout()
        restore()
    }

    func restore() {
        _ = DeskMergedTitlebar.restore(deskWindow)
    }

    private var deskWindow: NSWindow? {
        window?.sheetParent ?? window
    }

    private func install() {
        guard let desk = deskWindow, desk !== observed else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        observed = desk
        for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: desk, queue: .main) { [weak self] note in
                self?.restore()
                if note.name == NSWindow.willBeginSheetNotification {
                    self?.watchSheet()
                } else if note.name == NSWindow.didEndSheetNotification {
                    self?.sheetTimer?.invalidate()
                    self?.sheetTimer = nil
                    self?.restore()
                }
            })
        }
    }

    private func watchSheet() {
        sheetTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let desk = self.window?.sheetParent ?? self.window
            _ = DeskMergedTitlebar.restore(desk)
            if desk?.attachedSheet == nil {
                timer.invalidate()
                self.sheetTimer = nil
            }
        }
        sheetTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        sheetTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

/// Solid dark host so AppKit never flashes window-white under AV/Metal layers.
class ProShowLayerHostView: NSView {
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        DeskLiveLayer.lockHost(self)
    }

    required init?(coder: NSCoder) { nil }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        DeskLiveLayer.lockPresentation(in: self, active: true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        DeskLiveLayer.lockPresentation(in: self, active: false)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        DeskLiveLayer.syncMetalDrawable(in: self, size: newSize)
    }
}

/// Shared program frame host. Binds `CVPixelBuffer` contents each generation.
class ProShowMetalHostView: ProShowLayerHostView {
    var lastStyle: MediaFrameStyle?
    private var lastGeneration: UInt64 = 0
    private var consumerID: ObjectIdentifier { ObjectIdentifier(self) }

    override func makeBackingLayer() -> CALayer {
        let host = CALayer()
        host.backgroundColor = NSColor.black.cgColor
        host.isOpaque = true
        host.contentsGravity = .resizeAspect
        host.drawsAsynchronously = true
        return host
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            SharedTexturePublisher.shared.removeConsumer(consumerID)
        } else {
            attachPublisher()
        }
    }

    func attachPublisher() {
        SharedTexturePublisher.shared.addConsumer(consumerID) { [weak self] in
            self?.presentSharedTexture()
        }
        presentSharedTexture()
    }

    func presentSharedTexture() {
#if canImport(CoreVideo)
        guard let frame = SharedTexturePublisher.shared.takeFrameForPresentation(
            lastSeenGeneration: lastGeneration,
            needsInitialBind: layer?.contents == nil
        ) else { return }
        lastGeneration = frame.generation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = frame.pixelBuffer
        CATransaction.commit()
#endif
    }

    deinit {
        let id = consumerID
        Task { @MainActor in
            SharedTexturePublisher.shared.removeConsumer(id)
        }
    }
}
#endif

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

/// Pressable control: 0.97 on pointer-down, 120ms ease-out. Skips scale when Reduce Motion is on.
struct DeskPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : DeskMotion.easeOut, value: configuration.isPressed)
    }
}

/// Speaker / speaker-slash control used by the editor object list and program layers.
struct DeskMuteButton: View {
    var isMuted: Bool
    var label: String
    var enabled: Bool = true
    var compact: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                .font(compact ? .caption2.weight(.semibold) : .system(size: 12, weight: .semibold))
                .foregroundStyle(isMuted ? ProShowTheme.liveRed : (compact ? ProShowTheme.secondaryLabel : ProShowTheme.toolbarIcon))
                .frame(width: compact ? 22 : DeskLayout.hit, height: compact ? 22 : DeskLayout.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(isMuted ? "Unmute \(label)" : "Mute \(label)")
        .accessibilityLabel(isMuted ? "Unmute \(label)" : "Mute \(label)")
        .accessibilityValue(isMuted ? "Muted" : "Unmuted")
    }
}

/// Icon-only control with a name for VoiceOver / help, 28pt hit.
struct DeskIconButton: View {
    let systemImage: String
    let label: String
    var isOn: Bool = false
    var tint: Color? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DeskControlSize.regular.iconFont)
                .foregroundStyle(tint ?? (isOn ? Color.white : ProShowTheme.toolbarIcon))
                .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                .background(
                    RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                        .fill(isOn ? ProShowTheme.accent.opacity(0.28) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Left accent mark for a selected inspector row. The row itself stays transparent.
struct InspectorSelectionRibbon: View {
    var selected: Bool
    var color: Color = ProShowTheme.accent

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(selected ? color : Color.clear)
            .frame(width: 3)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}

/// Sentence-case pane title. Not tracked all-caps.
struct DeskSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ShowSidebarPalette.subtitle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DeskChip: View {
    let text: String
    var color: Color = ProShowTheme.well

    var body: some View {
        Text(text)
            .font(DeskType.micro)
            .foregroundStyle(ProShowTheme.primaryLabel)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule(style: .continuous))
    }
}

struct DeskEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.xs) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.title)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum SettingsModalLayout {
    static let width: CGFloat = 900
    static let height: CGFloat = 620
    static let sidebarWidth: CGFloat = 220
    static let labelWidth: CGFloat = 108
}

/// Label column + control, aligned like broadcast setup and the editor inspector.
struct SettingsAlignedRow<Control: View>: View {
    var label: String
    var detail: String? = nil
    var labelWidth: CGFloat = SettingsModalLayout.labelWidth
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DeskSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                if let detail {
                    Text(detail)
                        .font(DeskType.micro)
                        .foregroundStyle(ProShowTheme.secondaryLabel.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: InspectorTokens.rowHeight)
        .accessibilityElement(children: .contain)
    }
}

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DeskType.title)
                .tracking(-0.2)
                .foregroundStyle(ProShowTheme.primaryLabel)
            Text(subtitle)
                .font(DeskType.body)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Settings and modal navigation row. Selected state is a left ribbon and accent icon, not a fill.
struct DeskModalNavRow: View {
    let title: String
    let systemImage: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(selected ? ProShowTheme.accent : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .accessibilityHidden(true)
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? ProShowTheme.accent : ShowSidebarPalette.symbol)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(ShowSidebarPalette.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.trailing, 8)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        // A min-only frame accepts any taller proposal; without this a row (e.g. Cancel) swallows the
        // sidebar's spare height and centres its label mid-modal.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ShowSidebarPalette.title)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 2) {
                content()
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 12))
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: DeskSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(ShowSidebarPalette.title)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
    }
}

struct SettingsHairline: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .accessibilityHidden(true)
    }
}

/// Platform brand or connected account profile for stream destinations.
struct StreamDestinationAvatar: View {
    var account: StreamAccount
    var size: CGFloat = 36

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarBody
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(6, size * 0.22), style: .continuous))
            if account.profileImageUrl != nil {
                platformBadge
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatarBody: some View {
        if let urlString = account.profileImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    platformPlate
                default:
                    platformPlate.opacity(0.7)
                }
            }
        } else {
            platformPlate
        }
    }

    @ViewBuilder
    private var platformPlate: some View {
        switch account.platform {
        case .customRtmp, .srt:
            ZStack {
                (Color(hex: account.platform.tintHex) ?? ProShowTheme.accent)
                StreamPlatformBrandIcon(platform: account.platform, size: size * 0.55)
            }
        default:
            StreamPlatformBrandIcon(platform: account.platform, size: size)
        }
    }

    private var platformBadge: some View {
        Circle()
            .fill(Color(hex: account.platform.tintHex) ?? ProShowTheme.accent)
            .frame(width: max(12, size * 0.32), height: max(12, size * 0.32))
            .overlay {
                Circle().strokeBorder(ProShowTheme.canvas, lineWidth: 1.5)
            }
    }
}

struct SettingsMark: View {
    var hex: String
    var systemImage: String? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill((Color(hex: hex) ?? ProShowTheme.accent).opacity(0.22))
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: hex) ?? ProShowTheme.accent)
            } else {
                Circle()
                    .fill(Color(hex: hex) ?? ProShowTheme.accent)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// Hairline + short contact + long ambient. Neutral only.
struct DeskElevation: ViewModifier {
    enum Strength { case sm, md }

    var strength: Strength

    func body(content: Content) -> some View {
        content.shadow(color: Color.black.opacity(strength == .md ? 0.28 : 0.18), radius: strength == .md ? 12 : 4, y: strength == .md ? 6 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: DeskRadius.card, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5)
            }
    }
}

enum DeskChromePlaneDividerEdge {
    case leading
    case trailing
    case top
    case bottom
}

/// Flat pane background with optional hairline edge (inspector rail, media bin, etc.).
struct DeskChromePlaneModifier: ViewModifier {
    var elevation: DeskPaneElevation = .window
    var dividerEdge: DeskChromePlaneDividerEdge?

    private var fill: Color {
        switch elevation {
        case .window, .workspace, .sidebar, .inspector:
            ThemeTokens.bgWindow
        }
    }

    func body(content: Content) -> some View {
        content
            .background(fill)
            .overlay {
                if let dividerEdge {
                    divider(for: dividerEdge)
                }
            }
    }

    @ViewBuilder
    private func divider(for edge: DeskChromePlaneDividerEdge) -> some View {
        switch edge {
        case .leading:
            HStack(spacing: 0) {
                Rectangle().fill(ThemeTokens.dividerLine).frame(width: 1)
                Spacer(minLength: 0)
            }
        case .trailing:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(ThemeTokens.dividerLine).frame(width: 1)
            }
        case .top:
            VStack(spacing: 0) {
                Rectangle().fill(ThemeTokens.dividerLine).frame(height: 1)
                Spacer(minLength: 0)
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(ThemeTokens.dividerLine).frame(height: 1)
            }
        }
    }
}

/// Rounded group surface inside the right inspector stack.
struct DeskInspectorGroupModifier: ViewModifier {
    var padding: CGFloat = 10
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Compact floating toolbar (canvas selection context bar).
struct DeskFloatingToolbarCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .deskChromeGlass(in: Capsule(style: .continuous), interactive: true)
    }
}

extension View {
    func deskFloatingToolbarCapsule() -> some View {
        modifier(DeskFloatingToolbarCapsule())
    }

    func deskElevation(_ strength: DeskElevation.Strength = .sm) -> some View {
        modifier(DeskElevation(strength: strength))
    }

    func deskCard(radius: CGFloat = DeskRadius.card) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Flat desk background — same plane as split panes and sidebars.
    func deskChromePlane(
        elevation: DeskPaneElevation = .window,
        dividerEdge: DeskChromePlaneDividerEdge? = nil
    ) -> some View {
        modifier(DeskChromePlaneModifier(elevation: elevation, dividerEdge: dividerEdge))
    }

    func deskInspectorGroup(padding: CGFloat = 10) -> some View {
        modifier(DeskInspectorGroupModifier(padding: padding))
    }

    func deskFocusRing(isFocused: Bool) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                .strokeBorder(isFocused ? ProShowTheme.accent : Color.clear, lineWidth: 2)
        }
    }
}

/// Home / picker surfaces. Aliased onto `ProShowTheme` so the desk has one accent and one graphite stack.
enum StartHome {
    static let page = ProShowTheme.canvas
    static let sidebar = ProShowTheme.panel
    static let dock = ProShowTheme.well
    static let lemon = ProShowTheme.accent
    static let tangerine = ProShowTheme.sandboxOrange
    static let blush = ProShowTheme.liveRed
    static let aqua = ProShowTheme.accent
    static let coral = ProShowTheme.liveRed
    static let butter = ProShowTheme.statusOn
    static let ink = Color(red: 0.07, green: 0.07, blue: 0.08)

    static func rowTint(_ index: Int) -> Color {
        let tints = [blush, aqua, lemon, tangerine, coral, butter]
        let wrapped = ((index % tints.count) + tints.count) % tints.count
        return tints[wrapped]
    }
}

/// Start-menu beam mark. Used for the home wordmark and any chrome that stands in for the app.
struct ProShowMark: View {
    var side: CGFloat = 28

    var body: some View {
        Image("ProShowLogo")
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            .accessibilityLabel("ProShow")
    }
}

/// Letter slot card — mint field, diagonal stripes, one glyph. Used until the slot is mapped.
enum ResolvedCanvasMedia {
    static func image(at uri: String) -> Image? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let resolved = MediaPath.resolve(trimmed) {
            return image(atPath: resolved.path) ?? poster(for: resolved)
        }
        return image(atPath: trimmed) ?? poster(for: URL(fileURLWithPath: trimmed))
    }

    static func thumbnail(at uri: String) -> Image? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let resolved = MediaPath.resolve(trimmed) {
            return thumbnail(atPath: resolved.path) ?? poster(for: resolved)
        }
        return thumbnail(atPath: trimmed) ?? poster(for: URL(fileURLWithPath: trimmed))
    }

    static let thumbnailMaxLongSide = 512

    /// Bin and poster stills. A 4K file is stored at most 512 px on the long side.
    static func thumbnail(atPath path: String) -> Image? {
        let key = path + "#thumb512"
        #if os(macOS)
        if let cached = AssetCacheManager.shared.object(forKey: key) as? NSImage {
            return Image(nsImage: cached)
        }
        guard let cg = downsampledCGImage(path: path, maxLongSide: thumbnailMaxLongSide) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        AssetCacheManager.shared.setObject(image, forKey: key, cost: imageCost(image.size))
        return Image(nsImage: image)
        #else
        if let cached = AssetCacheManager.shared.object(forKey: key) as? UIImage {
            return Image(uiImage: cached)
        }
        guard let cg = downsampledCGImage(path: path, maxLongSide: thumbnailMaxLongSide) else { return nil }
        let image = UIImage(cgImage: cg)
        AssetCacheManager.shared.setObject(image, forKey: key, cost: imageCost(image.size))
        return Image(uiImage: image)
        #endif
    }

    private static func downsampledCGImage(path: String, maxLongSide: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func image(atPath path: String) -> Image? {
        #if os(macOS)
        if let cached = AssetCacheManager.shared.object(forKey: path) as? NSImage {
            return Image(nsImage: cached)
        }
        // Previews draw at window size: keep a decoded, display-sized bitmap so SwiftUI never re-decodes the PNG.
        if let cg = DecodedImageCache.shared.image(atPath: path, maxLongSide: DecodedImageCache.previewLongSide) {
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            AssetCacheManager.shared.setObject(image, forKey: path, cost: cg.width * cg.height * 4)
            return Image(nsImage: image)
        }
        #else
        if let cached = AssetCacheManager.shared.object(forKey: path) as? UIImage {
            return Image(uiImage: cached)
        }
        if let image = UIImage(contentsOfFile: path) {
            AssetCacheManager.shared.setObject(image, forKey: path, cost: Self.imageCost(image.size))
            return Image(uiImage: image)
        }
        #endif
        return nil
    }

    private static func imageCost(_ size: CGSize) -> Int {
        max(1, Int(size.width * size.height * 4))
    }

    static func poster(for mediaURL: URL) -> Image? {
        for thumb in posterCandidates(for: mediaURL) {
            if let image = thumbnail(atPath: thumb.path) {
                return image
            }
        }
        guard let dest = posterCandidates(for: mediaURL).first else { return nil }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ext = mediaURL.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext) {
            _ = try? AssetPreview.writeVideoPoster(from: mediaURL, to: dest)
        } else {
            _ = try? AssetPreview.writeThumbnail(from: mediaURL, to: dest)
        }
        return thumbnail(atPath: dest.path)
    }

    static func posterCandidates(for mediaURL: URL) -> [URL] {
        let name = mediaURL.deletingPathExtension().lastPathComponent + ".png"
        var urls: [URL] = []
        if let thumbs = MediaPath.currentProjectRoot?.appendingPathComponent("Transcoded/Thumbnails", isDirectory: true) {
            urls.append(thumbs.appendingPathComponent(name))
        }
        let sidecar = mediaURL.deletingLastPathComponent().appendingPathComponent("Thumbs", isDirectory: true).appendingPathComponent(name)
        if sidecar != mediaURL {
            urls.append(sidecar)
        }
        let neighbor = mediaURL.deletingLastPathComponent().appendingPathComponent(name)
        if neighbor != mediaURL {
            urls.append(neighbor)
        }
        return urls
    }
}

struct DeskTransparencyGrid: View {
    var cell: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.42)))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    if (row + col).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: cell, height: cell)),
                            with: .color(Color.white.opacity(0.10))
                        )
                    }
                    x += cell
                    col += 1
                }
                y += cell
                row += 1
            }
        }
        .accessibilityHidden(true)
    }
}

struct MediaPreviewFrame: View {
    var filePath: String?
    var artworkURL: URL?
    var kind: MediaBinItem.Kind = .image
    var tintHex: String = "#1B3A4B"
    var cornerRadius: CGFloat = DeskRadius.control

    var body: some View {
        ZStack {
            (Color(hex: tintHex) ?? ProShowTheme.well)
            if let image = previewImage {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var previewImage: Image? {
        if let artworkURL, let image = ResolvedCanvasMedia.thumbnail(at: artworkURL.path) {
            return image
        }
        guard let filePath, !filePath.isEmpty else { return nil }
        return ResolvedCanvasMedia.thumbnail(at: filePath)
    }

    private var fallbackSymbol: String {
        switch kind {
        case .video: "film"
        case .audio: "waveform"
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .placeholder: "square.dashed"
        case .image: "photo"
        }
    }
}

#if os(macOS)
private struct BrowserAssignedSourcePreview: View {
    let urlString: String
    let label: String
    let style: MediaFrameStyle
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { _ in
            let raster = ProgramPageRaster.shared
            let _ = raster.refreshIfNeeded()
            ZStack {
                Color.black
                if urlString.isEmpty {
                    browserPlaceholder
                } else {
                    LivePixelPreview(
                        pixelBuffer: raster.displayBuffer(for: urlString),
                        stamp: raster.presentationStamp,
                        style: style,
                        isPaused: reduceMotion
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: style.continuous ? .continuous : .circular))
        }
    }

    private var browserPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.title2)
            Text(label.isEmpty ? "Browser" : label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(8)
    }
}
#endif

struct AssignedSourcePreview: View {
    let source: AssignedMediaSource
    var canvasObjectKind: CanvasObjectKind? = nil
    var cornerRadius: CGFloat = 0
    var playsVideo: Bool = false
    var mutesVideo: Bool = true
    var preferSharedProgramClock: Bool = false
    var style: MediaFrameStyle? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.proShowVideoInputs) private var videoInputs
    @Environment(\.proShowPlayback) private var playback
    @Environment(\.mirrorsProgramPlayer) private var mirrorsProgramPlayer
    @Environment(\.programRenderPaused) private var programRenderPaused
    @Environment(\.proShowProgramVideoInput) private var programVideoInput
    @Environment(\.proShowShowsProgramVideoLayer) private var showsProgramVideoLayer

    private var sharedPresentation: SharedProgramPresentation {
        mirrorsProgramPlayer ? .mirroredFrame : .playerLayer
    }

    private var resolvedStyle: MediaFrameStyle {
        style ?? MediaFrameStyle(
            cornerRadius: cornerRadius,
            continuous: true,
            scaleMode: .fill,
            opacity: 1,
            cropX: 0.5,
            cropY: 0.5,
            cropZoom: 1
        )
    }

    var body: some View {
        switch source.sourceType {
        case .mediaFile, .libraryShow:
            if playsVideo, !reduceMotion, let playback, playback.canPresentVideo,
               preferSharedProgramClock || playback.sharesClock(with: source) {
                SharedProgramPlayerView(playback: playback, presentation: sharedPresentation, style: resolvedStyle)
                    .opacity(resolvedStyle.opacity)
                    .accessibilityLabel(source.name)
            } else if playsVideo, !reduceMotion, source.looksLikeVideo, let path = source.connectionString {
                programOrSlotVideo(path: path)
                    .accessibilityLabel(source.name)
            } else if let uri = source.connectionString, let image = ResolvedCanvasMedia.image(at: uri) {
                croppedImage(image)
            } else {
                MediaPreviewFrame(
                    filePath: source.connectionString,
                    kind: source.looksLikeVideo ? .video(duration: "") : .image,
                    tintHex: source.tintHex ?? "#1B3A4B",
                    cornerRadius: resolvedStyle.cornerRadius
                )
            }
        case .systemCamera, .ndiSource, .srtStream, .rendezvousGuest, .systemAudioCapture, .systemDisplay, .systemWindow:
            ZStack {
                Color.black
                liveDevicePreview
            }
            .opacity(resolvedStyle.opacity)
            .accessibilityLabel(source.name)
        case .webPage:
            BrowserAssignedSourcePreview(
                urlString: source.connectionString ?? "",
                label: source.name,
                style: resolvedStyle,
                reduceMotion: reduceMotion
            )
            .opacity(resolvedStyle.opacity)
            .accessibilityLabel(source.name)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func programOrSlotVideo(path: String) -> some View {
        let muted = mutesVideo || source.audioMuted == true
        if let playback, preferSharedProgramClock || playback.sharesClock(withPath: path) || playback.sharesClock(with: source) {
            SharedProgramPlayerView(playback: playback, presentation: sharedPresentation, style: resolvedStyle)
                .opacity(resolvedStyle.opacity)
        } else {
            SlotVideoPlayerView(
                path: path,
                tintHex: source.tintHex ?? "#1B3A4B",
                cornerRadius: resolvedStyle.cornerRadius,
                isMuted: muted,
                startAt: playback?.playhead ?? 0,
                style: resolvedStyle
            )
        }
    }

    private func croppedImage(_ image: Image) -> some View {
        GeometryReader { proxy in
            let offset = MediaFrameEngine.imageOffset(
                style: resolvedStyle,
                width: proxy.size.width,
                height: proxy.size.height
            )
            image
                .resizable()
                .aspectRatio(contentMode: resolvedStyle.scaleMode == .fit ? .fit : .fill)
                .scaleEffect(resolvedStyle.scaleMode == .crop ? resolvedStyle.cropZoom : 1)
                .offset(x: offset.width, y: offset.height)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: resolvedStyle.cornerRadius, style: resolvedStyle.continuous ? .continuous : .circular))
        .opacity(resolvedStyle.opacity)
    }

    private var usesProgramVideoInput: Bool {
        ProgramLiveVideoRouting.canvasUsesProgramInput(
            assigned: source,
            objectKind: canvasObjectKind,
            programInput: programVideoInput,
            showsProgramVideoLayer: showsProgramVideoLayer
        )
    }

    private var livePreviewEndpoint: String? {
        usesProgramVideoInput ? programVideoInput?.endpoint : source.connectionString
    }

    private var livePreviewSourceID: String? {
        usesProgramVideoInput ? programVideoInput?.id.uuidString : source.sourceID
    }

    @ViewBuilder
    private var liveDevicePreview: some View {
        ZStack {
            cameraFallback
            LivePixelPreview(
                endpoint: livePreviewEndpoint,
                sourceID: livePreviewSourceID,
                style: resolvedStyle,
                isPaused: programRenderPaused
            )
        }
    }

    private var cameraFallback: some View {
        VStack(spacing: 6) {
            Image(systemName: source.sourceType == .systemDisplay || source.sourceType == .systemWindow
                ? "rectangle.dashed"
                : (source.sourceType == .ndiSource ? "dot.radiowaves.left.and.right" : "video.fill"))
                .font(.title2)
            Text(source.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(8)
    }

}

struct LivePixelPreview: View {
    var endpoint: String? = nil
    var sourceID: String? = nil
    var pixelBuffer: CVPixelBuffer? = nil
    var stamp: TimeInterval = 0
    var style: MediaFrameStyle = .plain
    var isPaused: Bool = false

    var body: some View {
        LivePixelRepresentable(
            endpoint: endpoint,
            sourceID: sourceID,
            pixelBuffer: pixelBuffer,
            stamp: stamp,
            style: style,
            isPaused: isPaused
        )
        .accessibilityHidden(true)
        .overlay { guestNameplate }
    }

    /// LiveKit guest with no live camera: show their nameplate card instead of a black pane.
    @ViewBuilder
    private var guestNameplate: some View {
        if let endpoint, endpoint.hasPrefix("livekit://"), endpoint.hasSuffix("/camera"),
           let identity = LiveKitGuestEndpoint.identity(from: endpoint),
           let profile = GuestProfileStore.shared.profile(identity: identity),
           !profile.cameraLive {
            GuestNameplateCard(profile: profile)
        }
    }
}

/// Camera-off card for a guest: avatar circle, name, title. Desk graphite + accent.
struct GuestNameplateCard: View {
    var profile: GuestProfile

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let avatar = max(28, side * 0.34)
            ZStack {
                Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255)
                VStack(spacing: max(4, side * 0.04)) {
                    avatarView
                        .frame(width: avatar, height: avatar)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(red: 0x6B / 255, green: 0x9F / 255, blue: 0xE0 / 255), lineWidth: max(1.5, avatar * 0.035)))
                    Text(profile.name)
                        .font(.system(size: max(11, side * 0.085), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !profile.title.isEmpty {
                        Text(profile.title)
                            .font(.system(size: max(9, side * 0.06)))
                            .foregroundStyle(Color(red: 0x6B / 255, green: 0x9F / 255, blue: 0xE0 / 255))
                            .lineLimit(1)
                    }
                }
                .padding(8)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.title.isEmpty ? profile.name : "\(profile.name), \(profile.title)")
    }

    @ViewBuilder
    private var avatarView: some View {
        #if canImport(AppKit)
        if let image = GuestProfileStore.shared.avatarImage(for: profile.avatarSource), image.size.width > 0 {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            initials
        }
        #else
        initials
        #endif
    }

    private var initials: some View {
        ZStack {
            Color(red: 0x6B / 255, green: 0x9F / 255, blue: 0xE0 / 255).opacity(0.25)
            Text(profile.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

#if os(macOS)
private struct LivePixelRepresentable: NSViewRepresentable {
    var endpoint: String?
    var sourceID: String?
    var pixelBuffer: CVPixelBuffer?
    var stamp: TimeInterval
    var style: MediaFrameStyle
    var isPaused: Bool

    func makeNSView(context: Context) -> PixelBufferHostView {
        let view = PixelBufferHostView()
        context.coordinator.view = view
        context.coordinator.bind(endpoint: endpoint, sourceID: sourceID, style: style, paused: isPaused)
        if let pixelBuffer {
            view.setPixelBuffer(pixelBuffer, style: style)
        }
        return view
    }

    func updateNSView(_ nsView: PixelBufferHostView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.bind(endpoint: endpoint, sourceID: sourceID, style: style, paused: isPaused)
        if let pixelBuffer {
            nsView.setPixelBuffer(pixelBuffer, style: style)
        }
        context.coordinator.stamp = stamp
    }

    static func dismantleNSView(_ nsView: PixelBufferHostView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: PixelBufferHostView?
        var token: UUID?
        var stamp: TimeInterval = 0
        private var boundEndpoint: String?
        private var boundSourceID: String?
        private var boundPaused = false
        var style: MediaFrameStyle = .plain

        func bind(endpoint: String?, sourceID: String?, style: MediaFrameStyle, paused: Bool) {
            self.style = style
            if token != nil, boundEndpoint == endpoint, boundSourceID == sourceID, boundPaused == paused {
                return
            }
            unbind()
            boundEndpoint = endpoint
            boundSourceID = sourceID
            boundPaused = paused
            let hasLane = (endpoint?.isEmpty == false) || (sourceID?.isEmpty == false)
            guard !paused, hasLane else { return }
            token = LivePixelHub.shared.add(
                endpoint: endpoint,
                sourceID: sourceID,
                deliverOnCaptureQueue: true
            ) { [weak self] buffer in
                guard let self, let view = self.view else { return }
                #if canImport(CoreVideo)
                if let layer = view.layer {
                    LowLatencyIngestPipeline.shared.presentIOSurface(buffer, on: layer)
                } else {
                    view.setPixelBuffer(buffer, style: self.style)
                }
                #else
                view.setPixelBuffer(buffer, style: self.style)
                #endif
            }
            if let current = LivePixelHub.shared.current(endpoint: endpoint, sourceID: sourceID) {
                view?.setPixelBuffer(current, style: style)
            }
        }

        func unbind() {
            if let token {
                LivePixelHub.shared.remove(token)
            }
            token = nil
        }

        deinit { unbind() }
    }
}

final class PixelBufferHostView: ProShowLayerHostView {
    func setPixelBuffer(_ buffer: CVPixelBuffer?, style: MediaFrameStyle = .plain) {
        wantsLayer = true
        if let buffer, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            layer?.contents = surface
        } else if let buffer, let image = InputPreviewImaging.cgImage(from: buffer) {
            layer?.contents = image
        } else {
            layer?.contents = nil
        }
        DeskLiveLayer.applyFrameStyle(self, style: style)
    }
}
#else
private struct LivePixelRepresentable: View {
    var endpoint: String?
    var sourceID: String?
    var pixelBuffer: CVPixelBuffer?
    var stamp: TimeInterval
    var style: MediaFrameStyle
    var isPaused: Bool

    var body: some View {
        Color.black
    }
}
#endif

#if canImport(AVFoundation)
#if os(macOS)
final class LiveCaptureNSView: ProShowLayerHostView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
        DeskLiveLayer.pin(previewLayer, in: self)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        DeskLiveLayer.layout(previewLayer, in: bounds)
    }
}

struct LiveCapturePreview: NSViewRepresentable {
    var session: AVCaptureSession
    var style: MediaFrameStyle = .plain

    func makeNSView(context: Context) -> LiveCaptureNSView {
        let view = LiveCaptureNSView()
        view.previewLayer.session = session
        DeskLiveLayer.applyFrameStyle(view, style: style)
        return view
    }

    func updateNSView(_ nsView: LiveCaptureNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        DeskLiveLayer.applyFrameStyle(nsView, style: style)
        DeskLiveLayer.layout(nsView.previewLayer, in: nsView.bounds)
    }
}
#else
struct LiveCapturePreview: UIViewRepresentable {
    var session: AVCaptureSession
    var style: MediaFrameStyle = .plain

    func makeUIView(context: Context) -> CaptureFitUIView {
        let view = CaptureFitUIView()
        view.previewLayer.session = session
        MediaFrameEngine.apply(to: view.layer, style: style)
        return view
    }

    func updateUIView(_ uiView: CaptureFitUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        MediaFrameEngine.apply(to: uiView.layer, style: style)
    }
}

final class CaptureFitUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
#endif
#endif

struct PlaceholderLetterCard: View {
    var letter: String
    var tintHex: String
    var cornerRadius: CGFloat = 18

    var body: some View {
        let fill = Color(hex: tintHex) ?? Color(red: 0.85, green: 0.96, blue: 0.81)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .overlay {
                PlaceholderStripeField()
                    .opacity(0.22)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                Text(letter)
                    .font(.system(size: 86, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.13, green: 0.13, blue: 0.13))
                    .minimumScaleFactor(0.25)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Placeholder \(letter)")
    }
}

struct SolidColorCard: View {
    var hex: String
    var cornerRadius: CGFloat = 18

    var body: some View {
        let fill = Color(hex: hex) ?? .black
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(hex.uppercased() == "#FFFFFF" || hex.uppercased() == "#F4E8D0" ? 0.28 : 0.08), lineWidth: 1)
            }
            .accessibilityLabel("Color \(hex)")
    }
}

private struct PlaceholderStripeField: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 11)
                x += spacing
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum SharedProgramPresentation {
    case playerLayer
    case mirroredFrame
}

struct SharedProgramPlayerView: View {
    var playback: MediaPlaybackEngine
    var presentation: SharedProgramPresentation? = nil
    var style: MediaFrameStyle = .plain
    @Environment(\.mirrorsProgramPlayer) private var mirrorsProgramPlayer

    private var resolvedPresentation: SharedProgramPresentation {
        if let presentation { return presentation }
        #if os(macOS)
        return mirrorsProgramPlayer ? .mirroredFrame : .playerLayer
        #else
        return .playerLayer
        #endif
    }

    var body: some View {
        switch resolvedPresentation {
        case .playerLayer:
            SharedProgramPlayerLayerView(playback: playback, style: style)
        case .mirroredFrame:
            SharedProgramFrameMirrorView(playback: playback, style: style)
        }
    }
}

/// The program `AVPlayer` lives on `MediaPlaybackEngine`. A hidden `AVPlayerLayer` here
/// competed with `AVPlayerItemVideoOutput` for the same decode pool and froze playback
/// after a few seconds. Mirrored previews read `SharedTexturePublisher` instead.
struct ProgramPlayerOwnerView: View {
    var playback: MediaPlaybackEngine

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .onAppear { _ = playback.player }
    }
}

struct SharedProgramFrameMirrorView: View {
    var playback: MediaPlaybackEngine
    var style: MediaFrameStyle = .plain

    var body: some View {
        ProgramFrameStreamView(playback: playback, style: style)
            .accessibilityLabel(playback.title)
    }
}

struct ProgramFrameStreamView: View {
    var playback: MediaPlaybackEngine
    var style: MediaFrameStyle = .plain

    var body: some View {
        SharedTextureHostView(style: style)
            .accessibilityLabel(playback.title)
    }
}

#if canImport(AVFoundation)
#if os(macOS)
final class ProgramPlayerNSView: ProShowLayerHostView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        DeskLiveLayer.pin(playerLayer, in: self)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        DeskLiveLayer.layout(playerLayer, in: bounds)
    }
}

struct SharedProgramPlayerLayerView: NSViewRepresentable {
    var playback: MediaPlaybackEngine
    var style: MediaFrameStyle = .plain

    func makeNSView(context: Context) -> ProgramPlayerNSView {
        let view = ProgramPlayerNSView()
        bind(view)
        return view
    }

    func updateNSView(_ nsView: ProgramPlayerNSView, context: Context) {
        bind(nsView)
    }

    private func bind(_ view: ProgramPlayerNSView) {
        if playback.canPresentVideo, view.playerLayer.player !== playback.player {
            view.playerLayer.player = playback.player
        } else if !playback.canPresentVideo, view.playerLayer.player != nil {
            view.playerLayer.player = nil
        }
        DeskLiveLayer.applyFrameStyle(view, style: style)
    }
}
#else
final class ProgramPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct SharedProgramPlayerLayerView: UIViewRepresentable {
    var playback: MediaPlaybackEngine
    var style: MediaFrameStyle = .plain

    func makeUIView(context: Context) -> ProgramPlayerUIView {
        let view = ProgramPlayerUIView()
        if playback.canPresentVideo {
            view.playerLayer.player = playback.player
        }
        MediaFrameEngine.apply(to: view.layer, style: style)
        return view
    }

    func updateUIView(_ uiView: ProgramPlayerUIView, context: Context) {
        if playback.canPresentVideo, uiView.playerLayer.player !== playback.player {
            uiView.playerLayer.player = playback.player
        } else if !playback.canPresentVideo {
            uiView.playerLayer.player = nil
        }
        MediaFrameEngine.apply(to: uiView.layer, style: style)
    }
}
#endif
#else
struct SharedProgramPlayerLayerView: View {
    var playback: MediaPlaybackEngine
    var style: MediaFrameStyle = .plain
    var body: some View { Color.black }
}
#endif

enum SlotDecodeBudget {
    static let maxActivePlayers = 3
    private static let lock = NSLock()
    private static var holders: [ObjectIdentifier: Int] = [:]
    private static var testHolders: [ObjectIdentifier: Int]?

    static func acquire(_ id: ObjectIdentifier, priority: Int, visible: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if var session = testHolders {
            if session[id] != nil { return true }
            guard visible else { return false }
            if session.count < maxActivePlayers {
                session[id] = priority
                testHolders = session
                return true
            }
            return false
        }
        if holders[id] != nil { return true }
        guard visible else { return false }
        if holders.count < maxActivePlayers {
            holders[id] = priority
            return true
        }
        return false
    }

    static func release(_ id: ObjectIdentifier) {
        lock.lock()
        if testHolders != nil {
            testHolders?[id] = nil
        } else {
            holders.removeValue(forKey: id)
        }
        lock.unlock()
    }

    static func resetForTests() {
        lock.lock()
        testHolders = [:]
        lock.unlock()
    }

    static func endTestIsolation() {
        lock.lock()
        testHolders = nil
        lock.unlock()
    }

    static var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return testHolders?.count ?? holders.count
    }
}

struct SlotVideoPlayerView: View {
    var path: String
    var tintHex: String = "#1B3A4B"
    var cornerRadius: CGFloat = 0
    var isMuted: Bool = true
    var startAt: TimeInterval = 0
    var projectRoot: URL? = nil
    var style: MediaFrameStyle? = nil
    var decodePriority: Int = 0
    var isOnScreen: Bool = true

    private var resolvedStyle: MediaFrameStyle {
        style ?? MediaFrameStyle(
            cornerRadius: cornerRadius,
            continuous: true,
            scaleMode: .fill,
            opacity: 1,
            cropX: 0.5,
            cropY: 0.5,
            cropZoom: 1
        )
    }

    var body: some View {
        ZStack {
            Color(hex: tintHex) ?? ProShowTheme.well
            if let url = MediaPath.resolve(path, projectRoot: projectRoot)
                ?? (FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil),
               MediaLoader.hasVideoTrack(at: url) {
                SlotAVPlayerLayerView(
                    url: url,
                    isMuted: isMuted,
                    startAt: startAt,
                    style: resolvedStyle,
                    decodePriority: decodePriority,
                    isOnScreen: isOnScreen
                )
            } else {
                MediaPreviewFrame(filePath: path, kind: .video(duration: ""), tintHex: tintHex, cornerRadius: resolvedStyle.cornerRadius)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: resolvedStyle.cornerRadius, style: resolvedStyle.continuous ? .continuous : .circular))
        .opacity(resolvedStyle.opacity)
        .accessibilityLabel("Video")
    }
}

#if canImport(AVFoundation)
private func applyLocalPreviewMaxResolution(to item: AVPlayerItem) {
    let stored = UserDefaults.standard.object(forKey: "proshow.preview.localRenderPercent") as? Double ?? 50
    let percent = min(100, max(25, stored.rounded()))
    guard percent < 100 else { return }
    let contract = ProgramRenderContract(width: 3840, height: 2160, frameRate: 30, colorSpace: "sRGB")
        .scaledForLocalPreview(percent: percent)
    item.preferredMaximumResolution = CGSize(width: contract.width, height: contract.height)
}

#if os(macOS)
private final class SlotPlayerNSView: ProShowLayerHostView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        DeskLiveLayer.pin(playerLayer, in: self)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        DeskLiveLayer.layout(playerLayer, in: bounds)
    }
}

private struct SlotAVPlayerLayerView: NSViewRepresentable {
    var url: URL
    var isMuted: Bool
    var startAt: TimeInterval = 0
    var style: MediaFrameStyle = .plain
    var decodePriority: Int = 0
    var isOnScreen: Bool = true

    func makeNSView(context: Context) -> SlotPlayerNSView {
        let view = SlotPlayerNSView()
        context.coordinator.sync(url: url, muted: isMuted, startAt: startAt, priority: decodePriority, visible: isOnScreen)
        view.playerLayer.player = context.coordinator.player
        DeskLiveLayer.applyFrameStyle(view, style: style)
        return view
    }

    func updateNSView(_ nsView: SlotPlayerNSView, context: Context) {
        context.coordinator.sync(url: url, muted: isMuted, startAt: startAt, priority: decodePriority, visible: isOnScreen)
        nsView.playerLayer.player = context.coordinator.player
        DeskLiveLayer.applyFrameStyle(nsView, style: style)
    }

    static func dismantleNSView(_ nsView: SlotPlayerNSView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let player = AVPlayer()
        private var endObserver: NSObjectProtocol?
        private var meterObserver: Any?
        private var currentURL: URL?

        func sync(url: URL, muted: Bool, startAt: TimeInterval, priority: Int, visible: Bool) {
            let id = ObjectIdentifier(self)
            guard SlotDecodeBudget.acquire(id, priority: priority, visible: visible) else {
                player.pause()
                return
            }
            attach(url: url, muted: muted, startAt: startAt)
        }

        func attach(url: URL, muted: Bool, startAt: TimeInterval = 0) {
            player.isMuted = muted
            player.volume = muted ? 0 : 1
            guard MediaLoader.hasVideoTrack(at: url) else {
                if currentURL != url {
                    currentURL = url
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                }
                return
            }
            guard currentURL != url else {
                if player.timeControlStatus != .playing { player.play() }
                return
            }
            currentURL = url
            let item = AVPlayerItem(url: url)
            applyLocalPreviewMaxResolution(to: item)
            player.replaceCurrentItem(with: item)
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
            if startAt > 0.05 {
                player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
            installMeter()
        }

        private func installMeter() {
            guard meterObserver == nil else { return }
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            meterObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                let audible = !self.player.isMuted
                    && self.player.volume > 0.01
                    && self.player.timeControlStatus == .playing
                AudibleVideoClock.note(
                    id: ObjectIdentifier(self),
                    url: self.currentURL,
                    playhead: seconds.isFinite ? seconds : 0,
                    audible: audible
                )
            }
        }

        func stop() {
            player.pause()
            AudibleVideoClock.note(id: ObjectIdentifier(self), url: nil, playhead: 0, audible: false)
            if let meterObserver {
                player.removeTimeObserver(meterObserver)
            }
            meterObserver = nil
            player.replaceCurrentItem(with: nil)
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
            currentURL = nil
            SlotDecodeBudget.release(ObjectIdentifier(self))
        }
    }
}
#else
private final class SlotPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct SlotAVPlayerLayerView: UIViewRepresentable {
    var url: URL
    var isMuted: Bool
    var startAt: TimeInterval = 0
    var style: MediaFrameStyle = .plain

    func makeUIView(context: Context) -> SlotPlayerUIView {
        let view = SlotPlayerUIView()
        context.coordinator.attach(url: url, muted: isMuted, startAt: startAt)
        view.playerLayer.player = context.coordinator.player
        MediaFrameEngine.apply(to: view.layer, style: style)
        return view
    }

    func updateUIView(_ uiView: SlotPlayerUIView, context: Context) {
        context.coordinator.attach(url: url, muted: isMuted, startAt: startAt)
        uiView.playerLayer.player = context.coordinator.player
        MediaFrameEngine.apply(to: uiView.layer, style: style)
    }

    static func dismantleUIView(_ uiView: SlotPlayerUIView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let player = AVPlayer()
        private var endObserver: NSObjectProtocol?
        private var currentURL: URL?

        func attach(url: URL, muted: Bool, startAt: TimeInterval = 0) {
            player.isMuted = muted
            player.volume = muted ? 0 : 1
            guard MediaLoader.hasVideoTrack(at: url) else {
                if currentURL != url {
                    currentURL = url
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                }
                return
            }
            guard currentURL != url else {
                if player.timeControlStatus != .playing { player.play() }
                return
            }
            currentURL = url
            let item = AVPlayerItem(url: url)
            applyLocalPreviewMaxResolution(to: item)
            player.replaceCurrentItem(with: item)
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
            if startAt > 0.05 {
                player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        }

        func stop() {
            player.pause()
            player.replaceCurrentItem(with: nil)
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
            currentURL = nil
        }
    }
}
#endif
#else
private struct SlotAVPlayerLayerView: View {
    var url: URL
    var isMuted: Bool
    var startAt: TimeInterval = 0
    var style: MediaFrameStyle = .plain
    var body: some View { Color.clear }
}
#endif

/// Test hook: counts how often each menu's content is rebuilt. A menu rebuilt while open
/// closes its open submenu, so menu content must not re-evaluate on meter or clock ticks.
enum MenuRenderProbe {
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    nonisolated(unsafe) static var since = Date()
    @discardableResult
    static func hit(_ name: String) -> Bool {
        counts[name, default: 0] += 1
        return true
    }
    static func snapshot(reset: Bool) -> [String: Any] {
        let secs = max(0.001, Date().timeIntervalSince(since))
        let rates = counts.mapValues { (Double($0) / secs * 10).rounded() / 10 }
        if reset { counts = [:]; since = Date() }
        return ["secs": (secs * 10).rounded() / 10, "per_sec": rates]
    }
}

/// Wraps a Menu (or menu content) so it only re-renders when `key` changes. Parents that redraw
/// often (closures, clocks, meters) otherwise rebuild the menu, and a rebuilt menu drops its open submenu.
struct StableMenuContent<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View { content() }
}
