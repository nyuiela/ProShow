import AppKit
import SwiftUI

/// Floating prompt outside the main window. Left out of screen capture.
@MainActor
@Observable
final class PromptFloatController: NSObject, NSWindowDelegate {
    static let shared = PromptFloatController()

    private(set) var isOpen = false
    var placement: PromptFloatPlacement = .extended
    weak var rundown: ShowController?

    func attachRundown(_ controller: ShowController) {
        rundown = controller
    }

    private var panel: NSPanel?
    private let extendedSize = NSSize(width: 760, height: 340)
    private var rememberedExtendedSize = NSSize(width: 760, height: 340)

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        if panel == nil {
            let root = PromptFloatRoot()
            let hosting = NSHostingController(rootView: root)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: extendedSize),
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
            panel.minSize = NSSize(width: 360, height: 72)
            panel.maxSize = NSSize(width: 2200, height: 1400)
            hosting.view.autoresizingMask = [.width, .height]
            FloatingPanelTransparency.apply(to: panel, hosting: hosting)
            if let hostingView = hosting.view as? NSHostingView<PromptFloatRoot> {
                hostingView.safeAreaRegions = []
            }
            self.panel = panel
        }
        placement = .extended
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.midX - extendedSize.width / 2,
                y: visible.midY - extendedSize.height / 2
            )
            panel?.setFrame(NSRect(origin: origin, size: extendedSize), display: true)
        }
        panel?.orderFrontRegardless()
        isOpen = true
    }

    func close() {
        panel?.orderOut(nil)
        isOpen = false
    }

    func expand() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        placement = .extended
        let size = rememberedExtendedSize
        var frame = panel.frame
        frame.size = size
        frame.origin.x = screen.visibleFrame.midX - size.width / 2
        frame.origin.y = min(frame.origin.y, screen.visibleFrame.maxY - size.height - 8)
        frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY + 8)
        panel.setFrame(frame, display: true, animate: true)
    }

    /// Drag the window until it touches the menu bar or the Dock.
    func snapAfterDrag() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let topDistance = visible.maxY - frame.maxY
        let bottomDistance = frame.minY - visible.minY
        if topDistance < 48 {
            rememberExtendedSizeIfNeeded()
            placeCompact(on: screen, edge: .top)
        } else if bottomDistance < 48 {
            rememberExtendedSizeIfNeeded()
            placeCompact(on: screen, edge: .bottom)
        } else if placement != .extended {
            expand()
        }
    }

    func rememberExtendedSizeIfNeeded() {
        guard placement == .extended, let panel else { return }
        rememberedExtendedSize = panel.frame.size
    }

    /// A thin island: small reading type, with room for the vertical icon column.
    private var compactSize: NSSize {
        let screenWidth = (panel?.screen ?? NSScreen.main)?.visibleFrame.width ?? 1280
        let width = min(480, max(360, screenWidth - 80))
        return NSSize(width: width, height: 108)
    }

    func relayoutCompact() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        switch placement {
        case .top: placeCompact(on: screen, edge: .top)
        case .bottom: placeCompact(on: screen, edge: .bottom)
        case .extended: break
        }
    }

    private func placeCompact(on screen: NSScreen, edge: PromptFloatPlacement) {
        let visible = screen.visibleFrame
        placement = edge
        let size = compactSize
        let x = visible.midX - size.width / 2
        let y = edge == .top
            ? visible.maxY - size.height - 6
            : visible.minY + 6
        panel?.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true, animate: true)
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
    }
}

enum PromptFloatPlacement: Equatable {
    case extended
    case top
    case bottom

    var surface: PromptSurface {
        switch self {
        case .extended: .extended
        case .top, .bottom: .compact
        }
    }
}

private struct PromptFloatRoot: View {
    @Bindable private var chrome = PromptFloatController.shared
    @Bindable private var session = TeleprompterSession.shared

    var body: some View {
        RundownTeleprompterView(
            script: session.script,
            settings: .shared,
            session: session,
            surface: chrome.placement.surface
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

/// Grip that moves the floating panel. The word stage keeps its own scrub.
struct PromptWindowDragHandle: NSViewRepresentable {
    var onDragEnd: () -> Void

    func makeNSView(context: Context) -> PromptDragView {
        let view = PromptDragView()
        view.onDragEnd = onDragEnd
        return view
    }

    func updateNSView(_ nsView: PromptDragView, context: Context) {
        nsView.onDragEnd = onDragEnd
    }
}

final class PromptDragView: NSView {
    var onDragEnd: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startOrigin = window.frame.origin
        let startMouse = NSEvent.mouseLocation
        var didMove = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { next, stop in
            guard let next else {
                stop.pointee = true
                return
            }
            if next.type == .leftMouseUp {
                stop.pointee = true
                if didMove {
                    self.onDragEnd?()
                }
                return
            }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y
            if abs(dx) > 3 || abs(dy) > 3 {
                didMove = true
            }
            window.setFrameOrigin(NSPoint(
                x: startOrigin.x + dx,
                y: startOrigin.y + dy
            ))
        }
    }
}

enum PromptResizeEdge {
    case left, right, bottom, bottomLeft, bottomRight
}

struct PromptResizeHandle: NSViewRepresentable {
    var edge: PromptResizeEdge

    func makeNSView(context: Context) -> PromptResizeView {
        let view = PromptResizeView()
        view.edge = edge
        return view
    }

    func updateNSView(_ nsView: PromptResizeView, context: Context) {
        nsView.edge = edge
    }
}

final class PromptResizeView: NSView {
    var edge: PromptResizeEdge = .bottomRight
    private let minimum = NSSize(width: 420, height: 220)

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
                PromptFloatController.shared.rememberExtendedSizeIfNeeded()
                return
            }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y
            window.setFrame(self.resized(start, dx: dx, dy: dy), display: true)
        }
    }

    private func resized(_ start: NSRect, dx: CGFloat, dy: CGFloat) -> NSRect {
        var frame = start
        switch edge {
        case .right:
            frame.size.width = max(minimum.width, start.width + dx)
        case .left:
            let width = max(minimum.width, start.width - dx)
            frame.origin.x = start.maxX - width
            frame.size.width = width
        case .bottom:
            let height = max(minimum.height, start.height - dy)
            frame.origin.y = start.maxY - height
            frame.size.height = height
        case .bottomRight:
            frame.size.width = max(minimum.width, start.width + dx)
            let height = max(minimum.height, start.height - dy)
            frame.origin.y = start.maxY - height
            frame.size.height = height
        case .bottomLeft:
            let width = max(minimum.width, start.width - dx)
            frame.origin.x = start.maxX - width
            frame.size.width = width
            let height = max(minimum.height, start.height - dy)
            frame.origin.y = start.maxY - height
            frame.size.height = height
        }
        return frame
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
