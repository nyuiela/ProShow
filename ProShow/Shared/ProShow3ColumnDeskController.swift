#if os(macOS)
import AppKit

/// Index 0 = library, 1 = workspace, 2 = inspector. Frames are assigned by index.
final class ProShow3ColumnDeskController: NSViewController, NSSplitViewDelegate {
    private var libraryWidth: CGFloat
    private var inspectorWidth: CGFloat
    private let onPersistLibrary: (CGFloat) -> Void
    private let onPersistInspector: (CGFloat) -> Void

    private var draggingDividerIndex: Int?
    private var mouseUpMonitor: Any?
    private var sidebarObserver: NSObjectProtocol?
    private let splitViewInstance = ProShowFlippedSplitView()
    private var libraryHidden: Bool

    init(
        libraryWidth: CGFloat,
        inspectorWidth: CGFloat,
        onPersistLibrary: @escaping (CGFloat) -> Void,
        onPersistInspector: @escaping (CGFloat) -> Void
    ) {
        self.libraryWidth = libraryWidth
        self.inspectorWidth = min(max(inspectorWidth, DeskLayout.inspectorMin), DeskLayout.inspectorMax)
        self.libraryHidden = UserSettingsStore.shared.librarySidebarHidden
        self.onPersistLibrary = onPersistLibrary
        self.onPersistInspector = onPersistInspector
        super.init(nibName: nil, bundle: nil)
        splitViewInstance.isVertical = true
        splitViewInstance.dividerStyle = .thin
        splitViewInstance.dividerThicknessOverride = 0
        splitViewInstance.undrawnDividerIndexes = [0]
        splitViewInstance.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let sidebarObserver {
            NotificationCenter.default.removeObserver(sidebarObserver)
        }
    }

    override func loadView() {
        view = splitViewInstance
        sidebarObserver = NotificationCenter.default.addObserver(
            forName: .proShowLibrarySidebarChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.libraryHidden = UserSettingsStore.shared.librarySidebarHidden
            self.applyFrames(on: self.splitViewInstance)
        }
    }

    func attach(left: NSViewController, center: NSViewController, right: NSViewController) {
        children.forEach { child in
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        for child in [left, center, right] {
            addChild(child)
            DeskStudioPaint.apply(child.view)
            splitViewInstance.addSubview(child.view)
        }
        splitViewInstance.setHoldingPriority(.init(750), forSubviewAt: 0)
        splitViewInstance.setHoldingPriority(.init(250), forSubviewAt: 1)
        splitViewInstance.setHoldingPriority(.init(750), forSubviewAt: 2)
        applyFrames(on: splitViewInstance)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        _ = oldSize
        if let index = draggingDividerIndex {
            adoptFromMouse(splitView, dividerIndex: index)
        }
        applyFrames(on: splitView)
    }

    func splitViewWillResizeSubviews(_ notification: Notification) {
        guard draggingDividerIndex == nil else { return }
        guard let index = splitViewInstance.dividerIndexContainingMouse(NSApp.currentEvent) else { return }
        draggingDividerIndex = index
        DeskLiveLayer.lockPresentation(in: splitViewInstance, active: true)
        installMouseUpMonitor()
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimum: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        _ = proposedMinimum
        return dividerRange(index: dividerIndex, in: splitView).min
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximum: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        _ = proposedMaximum
        return dividerRange(index: dividerIndex, in: splitView).max
    }

    private func applyFrames(on splitView: NSSplitView) {
        guard splitView.subviews.count == 3, splitView.bounds.width > 1 else { return }
        let frames = DeskStudioGeometry.allocateThreeColumns(
            total: splitView.bounds.width,
            divider: splitView.dividerThickness,
            library: libraryHidden ? 0 : libraryWidth,
            inspector: inspectorWidth,
            minLibrary: libraryHidden ? 0 : DeskLayout.sidebarMin
        )
        let height = splitView.bounds.height
        splitView.subviews[0].frame = NSRect(x: frames.leftOrigin, y: 0, width: frames.leftWidth, height: height)
        splitView.subviews[1].frame = NSRect(x: frames.centerOrigin, y: 0, width: frames.centerWidth, height: height)
        splitView.subviews[2].frame = NSRect(x: frames.rightOrigin, y: 0, width: frames.rightWidth, height: height)
        for subview in splitView.subviews {
            subview.needsLayout = true
            subview.layoutSubtreeIfNeeded()
        }
    }

    private func adoptFromMouse(_ splitView: NSSplitView, dividerIndex: Int) {
        guard let event = NSApp.currentEvent else { return }
        let x = splitView.convert(event.locationInWindow, from: nil).x
        let total = splitView.bounds.width
        if dividerIndex == 0 {
            if libraryHidden {
                libraryHidden = false
                UserSettingsStore.shared.librarySidebarHidden = false
            }
            libraryWidth = min(max(x, DeskLayout.sidebarMin), 360)
        } else {
            inspectorWidth = min(max(total - x, DeskLayout.inspectorMin), DeskLayout.inspectorMax)
        }
    }

    private func dividerRange(index: Int, in splitView: NSSplitView) -> (min: CGFloat, max: CGFloat) {
        let divider = splitView.dividerThickness
        if index == 0 {
            let small = DeskStudioGeometry.allocateThreeColumns(
                total: splitView.bounds.width,
                divider: divider,
                library: DeskLayout.sidebarMin,
                inspector: inspectorWidth,
                minLibrary: DeskLayout.sidebarMin
            )
            let large = DeskStudioGeometry.allocateThreeColumns(
                total: splitView.bounds.width,
                divider: divider,
                library: 360,
                inspector: inspectorWidth
            )
            return (min(small.leftWidth, large.leftWidth), max(small.leftWidth, large.leftWidth))
        }
        let wide = DeskStudioGeometry.allocateThreeColumns(
            total: splitView.bounds.width,
            divider: divider,
            library: libraryWidth,
            inspector: DeskLayout.inspectorMax
        )
        let narrow = DeskStudioGeometry.allocateThreeColumns(
            total: splitView.bounds.width,
            divider: divider,
            library: libraryWidth,
            inspector: DeskLayout.inspectorMin
        )
        let minPos = wide.rightOrigin - divider
        let maxPos = narrow.rightOrigin - divider
        return (min(minPos, maxPos), max(minPos, maxPos))
    }

    private func installMouseUpMonitor() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.finishDrag()
            return event
        }
    }

    private func finishDrag() {
        guard let index = draggingDividerIndex else { return }
        draggingDividerIndex = nil
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        applyFrames(on: splitViewInstance)
        guard splitViewInstance.subviews.count == 3 else { return }
        if index == 0 {
            libraryWidth = splitViewInstance.subviews[0].frame.width
            onPersistLibrary(libraryWidth)
        } else {
            inspectorWidth = splitViewInstance.subviews[2].frame.width
            onPersistInspector(inspectorWidth)
        }
        DeskLiveLayer.lockPresentation(in: splitViewInstance, active: false)
    }
}
#endif
