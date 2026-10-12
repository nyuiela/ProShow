#if os(macOS)
import AppKit
import SwiftUI

final class ProShowFlippedSplitView: NSSplitView {
    /// When set, replaces the default 7pt drag gutter.
    var dividerThicknessOverride: CGFloat?
    /// Divider indexes that should not paint a rule. Hit-testing stays.
    var undrawnDividerIndexes: Set<Int> = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// Thin visible rule; extra width is for drag hit-testing only.
    override var dividerThickness: CGFloat { dividerThicknessOverride ?? 7 }
    override var dividerColor: NSColor { DeskNSColor.canvas }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = DeskNSColor.canvas.cgColor
        layer?.isOpaque = true
        layer?.drawsAsynchronously = true
        dividerStyle = .thin
    }

    required init?(coder: NSCoder) { nil }

    override func drawDivider(in rect: NSRect) {
        if let index = dividerIndex(forDrawnRect: rect), undrawnDividerIndexes.contains(index) {
            return
        }
        DeskNSColor.canvas.setFill()
        rect.fill()
        let line = isVertical
            ? NSRect(x: floor(rect.midX - 0.5), y: rect.minY, width: 1, height: rect.height)
            : NSRect(x: rect.minX, y: floor(rect.midY - 0.5), width: rect.width, height: 1)
        DeskNSColor.dividerLine.setFill()
        line.fill()
    }

    private func dividerIndex(forDrawnRect rect: NSRect) -> Int? {
        let panes = arrangedSubviews
        guard panes.count >= 2 else { return nil }
        for index in 0..<(panes.count - 1) {
            let leading = panes[index].frame
            let trailing = panes[index + 1].frame
            let seam = isVertical
                ? NSRect(x: leading.maxX, y: bounds.minY, width: max(trailing.minX - leading.maxX, 1), height: bounds.height)
                : NSRect(x: bounds.minX, y: leading.maxY, width: bounds.width, height: max(trailing.minY - leading.maxY, 1))
            if seam.intersects(rect) || rect.contains(NSPoint(x: seam.midX, y: seam.midY)) {
                return index
            }
        }
        return nil
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        DeskLiveLayer.lockPresentation(in: self, active: true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        DeskLiveLayer.lockPresentation(in: self, active: false)
        needsDisplay = true
    }

    func dividerIndexContainingMouse(_ event: NSEvent?) -> Int? {
        guard let event else { return nil }
        return dividerIndex(at: convert(event.locationInWindow, from: nil))
    }

    func dividerIndex(at point: NSPoint) -> Int? {
        let panes = arrangedSubviews
        guard panes.count >= 2 else { return nil }
        for index in 0..<(panes.count - 1) {
            let leading = panes[index].frame
            let trailing = panes[index + 1].frame
            let rect: NSRect
            if isVertical {
                let x = min(leading.maxX, trailing.minX)
                let width = max(dividerThickness, abs(trailing.minX - leading.maxX))
                rect = NSRect(x: x - 2, y: bounds.minY, width: width + 4, height: bounds.height)
            } else {
                let y = min(leading.maxY, trailing.minY)
                let height = max(dividerThickness, abs(trailing.minY - leading.maxY))
                rect = NSRect(x: bounds.minX, y: y - 2, width: bounds.width, height: height + 4)
            }
            if rect.contains(point) { return index }
        }
        return nil
    }
}

final class DeskStudioHost<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        DeskStudioHost.paint(self)
        if #available(macOS 14.0, *) {
            sizingOptions = [.standardBounds]
        } else if #available(macOS 13.0, *) {
            sizingOptions = [.minSize]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        DeskLiveLayer.lockPresentation(in: self, active: true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        DeskLiveLayer.lockPresentation(in: self, active: false)
        needsDisplay = true
    }

    static func paint(_ view: NSView) {
        DeskStudioPaint.apply(view)
    }
}

enum DeskStudioPaint {
    static func apply(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = DeskNSColor.canvas.cgColor
        view.layer?.isOpaque = true
        view.layer?.drawsAsynchronously = true
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
    }
}

final class DeskStudioHostController<Content: View>: NSViewController {
    let host: DeskStudioHost<Content>

    init(rootView: Content) {
        host = DeskStudioHost(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = host
    }

    func updateRootView(_ view: Content) {
        host.rootView = view
    }
}
#endif
