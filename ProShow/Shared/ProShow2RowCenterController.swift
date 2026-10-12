#if os(macOS)
import AppKit
import SwiftUI

/// Index 0 = slide grid (flex), index 1 = media drawer (pinned height).
final class ProShow2RowCenterController: NSViewController, NSSplitViewDelegate {
    private var mediaDrawerHeight: CGFloat
    private let onPersistHeight: (CGFloat) -> Void
    private var fixedLimits: RowSplitLimits
    /// When set, row limits follow inspector column width and program aspect each layout pass.
    var inspectorProgramAspect: CGFloat?

    private var isDraggingDivider = false
    private var mouseUpMonitor: Any?
    private var lastInspectorColumnWidth: CGFloat = 0
    private let splitViewInstance = ProShowFlippedSplitView()

    init(
        mediaDrawerHeight: CGFloat,
        limits: RowSplitLimits = .mediaDrawer,
        onPersistHeight: @escaping (CGFloat) -> Void
    ) {
        self.mediaDrawerHeight = mediaDrawerHeight
        self.fixedLimits = limits
        self.onPersistHeight = onPersistHeight
        super.init(nibName: nil, bundle: nil)
        splitViewInstance.isVertical = false
        splitViewInstance.dividerStyle = .thin
        splitViewInstance.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func loadView() {
        view = splitViewInstance
    }

    func attach(top: NSViewController, bottom: NSViewController) {
        children.forEach { child in
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(top)
        addChild(bottom)
        DeskStudioPaint.apply(top.view)
        DeskStudioPaint.apply(bottom.view)
        splitViewInstance.addSubview(top.view)
        splitViewInstance.addSubview(bottom.view)
        splitViewInstance.setHoldingPriority(.init(250), forSubviewAt: 0)
        splitViewInstance.setHoldingPriority(.init(750), forSubviewAt: 1)
        applyFrames(on: splitViewInstance)
    }

    func refreshLayout() {
        applyFrames(on: splitViewInstance)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        _ = oldSize
        if isDraggingDivider {
            adoptFromMouse(splitView)
        }
        applyFrames(on: splitView)
    }

    func splitViewWillResizeSubviews(_ notification: Notification) {
        guard !isDraggingDivider else { return }
        guard splitViewInstance.dividerIndexContainingMouse(NSApp.currentEvent) != nil else { return }
        isDraggingDivider = true
        DeskLiveLayer.lockPresentation(in: splitViewInstance, active: true)
        installMouseUpMonitor()
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimum: CGFloat,
        ofSubviewAt subviewIndex: Int
    ) -> CGFloat {
        _ = proposedMinimum
        _ = subviewIndex
        let limits = activeLimits(for: splitView)
        return DeskStudioGeometry.allocateTwoRows(
            total: splitView.bounds.height,
            divider: splitView.dividerThickness,
            mediaDrawer: limits.maxBottom,
            minDrawer: limits.minBottom,
            minTop: limits.minTop
        ).topHeight
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximum: CGFloat,
        ofSubviewAt subviewIndex: Int
    ) -> CGFloat {
        _ = proposedMaximum
        _ = subviewIndex
        let limits = activeLimits(for: splitView)
        var maxTop = DeskStudioGeometry.allocateTwoRows(
            total: splitView.bounds.height,
            divider: splitView.dividerThickness,
            mediaDrawer: limits.minBottom,
            minDrawer: limits.minBottom,
            minTop: limits.minTop
        ).topHeight
        if let aspect = inspectorProgramAspect {
            let idealTop = InspectorPreviewLayout.idealTopPaneHeight(
                columnWidth: splitView.bounds.width,
                programAspect: aspect
            )
            maxTop = min(maxTop, idealTop)
        }
        return maxTop
    }

    private func activeLimits(for splitView: NSSplitView) -> RowSplitLimits {
        guard let aspect = inspectorProgramAspect else { return fixedLimits }
        return DeskStudioGeometry.inspectorPaneLimits(
            columnWidth: splitView.bounds.width,
            totalHeight: splitView.bounds.height,
            programAspect: aspect
        )
    }

    private func applyFrames(on splitView: NSSplitView) {
        guard splitView.subviews.count == 2, splitView.bounds.height > 1 else { return }
        let limits = activeLimits(for: splitView)
        let divider = splitView.dividerThickness
        let available = max(0, splitView.bounds.height - divider)

        let columnWidth = splitView.bounds.width
        if let aspect = inspectorProgramAspect, !isDraggingDivider {
            if abs(columnWidth - lastInspectorColumnWidth) > 0.5 {
                lastInspectorColumnWidth = columnWidth
                let idealTop = InspectorPreviewLayout.idealTopPaneHeight(
                    columnWidth: columnWidth,
                    programAspect: aspect
                )
                let preferredBottom = available - idealTop
                mediaDrawerHeight = min(max(preferredBottom, limits.minBottom), limits.maxBottom)
            } else {
                mediaDrawerHeight = min(max(mediaDrawerHeight, limits.minBottom), limits.maxBottom)
            }
        } else {
            if inspectorProgramAspect != nil {
                lastInspectorColumnWidth = columnWidth
            }
            mediaDrawerHeight = min(max(mediaDrawerHeight, limits.minBottom), limits.maxBottom)
        }

        var frames = DeskStudioGeometry.allocateTwoRows(
            total: splitView.bounds.height,
            divider: divider,
            mediaDrawer: mediaDrawerHeight,
            minDrawer: limits.minBottom,
            maxDrawer: limits.maxBottom,
            minTop: limits.minTop
        )

        if let aspect = inspectorProgramAspect {
            let idealTop = InspectorPreviewLayout.idealTopPaneHeight(
                columnWidth: splitView.bounds.width,
                programAspect: aspect
            )
            if frames.topHeight > idealTop + 0.5 {
                mediaDrawerHeight = min(max(available - idealTop, limits.minBottom), limits.maxBottom)
                frames = DeskStudioGeometry.allocateTwoRows(
                    total: splitView.bounds.height,
                    divider: divider,
                    mediaDrawer: mediaDrawerHeight,
                    minDrawer: limits.minBottom,
                    maxDrawer: limits.maxBottom,
                    minTop: limits.minTop
                )
            }
        }

        let width = splitView.bounds.width
        splitView.subviews[0].frame = NSRect(x: 0, y: frames.topOrigin, width: width, height: frames.topHeight)
        splitView.subviews[1].frame = NSRect(x: 0, y: frames.bottomOrigin, width: width, height: frames.bottomHeight)
    }

    private func adoptFromMouse(_ splitView: NSSplitView) {
        guard let event = NSApp.currentEvent else { return }
        let y = splitView.convert(event.locationInWindow, from: nil).y
        let limits = activeLimits(for: splitView)
        mediaDrawerHeight = min(max(splitView.bounds.height - y, limits.minBottom), limits.maxBottom)
    }

    private func installMouseUpMonitor() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.finishDrag()
            return event
        }
    }

    private func finishDrag() {
        guard isDraggingDivider else { return }
        isDraggingDivider = false
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        if splitViewInstance.subviews.count == 2 {
            let live = splitViewInstance.subviews[1].frame.height
            if live > 0 { mediaDrawerHeight = live }
        }
        onPersistHeight(mediaDrawerHeight)
        DeskLiveLayer.lockPresentation(in: splitViewInstance, active: false)
    }
}

#endif
