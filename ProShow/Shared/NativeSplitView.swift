import SwiftUI

struct RowSplitLimits: Equatable {
    var minBottom: CGFloat
    var maxBottom: CGFloat
    var minTop: CGFloat

    static let mediaDrawer = RowSplitLimits(minBottom: 120, maxBottom: 400, minTop: 200)
    static var inspectorPaneFallback: RowSplitLimits {
        RowSplitLimits(
            minBottom: DeskLayout.inspectorPaneMinBottom,
            maxBottom: DeskLayout.inspectorPaneMaxHeight,
            minTop: DeskLayout.inspectorPaneMinTop
        )
    }
}

enum DeskStudioGeometry {
    struct ThreeColumn: Equatable {
        var leftOrigin: CGFloat
        var leftWidth: CGFloat
        var centerOrigin: CGFloat
        var centerWidth: CGFloat
        var rightOrigin: CGFloat
        var rightWidth: CGFloat
    }

    struct TwoRow: Equatable {
        var topOrigin: CGFloat
        var topHeight: CGFloat
        var bottomOrigin: CGFloat
        var bottomHeight: CGFloat
    }

    static func allocateThreeColumns(
        total: CGFloat,
        divider: CGFloat,
        library: CGFloat,
        inspector: CGFloat,
        minLibrary: CGFloat = 200,
        maxLibrary: CGFloat = 360,
        minInspector: CGFloat = DeskLayout.inspectorMin,
        maxInspector: CGFloat = DeskLayout.inspectorMax,
        minCenter: CGFloat = 320
    ) -> ThreeColumn {
        let gutters = divider * 2
        let available = max(0, total - gutters)
        var minL = max(0, minLibrary)
        var minR = max(0, minInspector)
        var minC = max(0, minCenter)
        if minL + minR + minC > available, minL + minR + minC > 0 {
            let scale = available / (minL + minR + minC)
            minL *= scale
            minR *= scale
            minC *= scale
        }
        var left = min(max(library, minL), min(maxLibrary, available - minR - minC))
        var right = min(max(inspector, minR), min(maxInspector, available - left - minC))
        var center = available - left - right
        if center < minC {
            center = minC
            let leftover = max(0, available - center)
            if leftover <= 0 {
                left = 0
                right = 0
            } else if left + right > leftover {
                let scale = leftover / (left + right)
                left *= scale
                right = leftover - left
            }
        }
        return ThreeColumn(
            leftOrigin: 0,
            leftWidth: left,
            centerOrigin: left + divider,
            centerWidth: center,
            rightOrigin: left + divider + center + divider,
            rightWidth: right
        )
    }

    /// Right-column program preview sizing (shared with `LivePreviewMonitor`).
    static func inspectorPaneLimits(
        columnWidth: CGFloat,
        totalHeight: CGFloat,
        programAspect: CGFloat
    ) -> RowSplitLimits {
        let minBottom = DeskLayout.inspectorPaneMinBottom
        let minTopHard = DeskLayout.inspectorPaneMinTop
        let idealTop = InspectorPreviewLayout.idealTopPaneHeight(
            columnWidth: columnWidth,
            programAspect: programAspect
        )
        let available = max(0, totalHeight - 1)
        let cappedIdealTop = min(idealTop, max(minTopHard, available - minBottom))
        let maxBottom = max(minBottom, available - cappedIdealTop)
        return RowSplitLimits(
            minBottom: minBottom,
            maxBottom: maxBottom,
            minTop: minTopHard
        )
    }

    /// Bottom pane height that leaves a width-fitted program preview in the top pane.
    static func inspectorPreferredBottomHeight(
        columnWidth: CGFloat,
        totalHeight: CGFloat,
        programAspect: CGFloat
    ) -> CGFloat {
        let limits = inspectorPaneLimits(
            columnWidth: columnWidth,
            totalHeight: totalHeight,
            programAspect: programAspect
        )
        let idealTop = InspectorPreviewLayout.idealTopPaneHeight(
            columnWidth: columnWidth,
            programAspect: programAspect
        )
        let available = max(0, totalHeight - 1)
        let bottom = available - min(idealTop, available - limits.minBottom)
        return min(max(bottom, limits.minBottom), limits.maxBottom)
    }

    static func allocateTwoRows(
        total: CGFloat,
        divider: CGFloat,
        mediaDrawer: CGFloat,
        minDrawer: CGFloat = 120,
        maxDrawer: CGFloat = 400,
        minTop: CGFloat = 200
    ) -> TwoRow {
        let available = max(0, total - divider)
        var minB = max(0, minDrawer)
        var minT = max(0, minTop)
        if minB + minT > available, minB + minT > 0 {
            let scale = available / (minB + minT)
            minB *= scale
            minT *= scale
        }
        var bottom = min(max(mediaDrawer, minB), min(maxDrawer, available - minT))
        var top = available - bottom
        if top < minT {
            top = minT
            bottom = max(minB, available - top)
        }
        return TwoRow(
            topOrigin: 0,
            topHeight: top,
            bottomOrigin: top + divider,
            bottomHeight: bottom
        )
    }
}

#if os(macOS)
import AppKit

enum DeskNSColor {
    static let canvas = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
    static let panel = canvas
    static let hairline = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
    static let dividerLine = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06)
}

private struct FlickerFreeBackgroundRepresentable: NSViewRepresentable {
    var backgroundColor: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.cgColor
        view.layer?.isOpaque = true
        view.layer?.drawsAsynchronously = true
        DispatchQueue.main.async { DeskWindowChrome.lock(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = backgroundColor.cgColor
        nsView.layer?.isOpaque = true
        DeskWindowChrome.lock(nsView.window)
    }
}
#endif

extension View {
    /// Solid opaque backing so AppKit never clears a dirty-rect to window-white.
    func lockFlickerFreeBackground() -> some View {
        #if os(macOS)
        background(FlickerFreeBackgroundRepresentable(backgroundColor: DeskNSColor.canvas))
        #else
        background(Color(red: 0.071, green: 0.071, blue: 0.078))
        #endif
    }
}
