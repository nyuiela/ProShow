import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Keeps the artboard and pan origin on the device pixel grid to reduce shimmer while zooming.
enum CanvasEditorScreenAlign {
    static var backingScale: CGFloat {
        #if os(macOS)
        NSScreen.main?.backingScaleFactor ?? 2
        #else
        UIScreen.main.scale
        #endif
    }

    static func screenPoint(_ value: CGFloat) -> CGFloat {
        let scale = max(1, backingScale)
        return (value * scale).rounded() / scale
    }

    static func pixelAlignCanvasPan(
        paneWidth: Double,
        paneHeight: Double,
        canvasWidth: Double,
        canvasHeight: Double,
        zoom: Double,
        panX: inout Double,
        panY: inout Double
    ) {
        var originX = (paneWidth - canvasWidth * zoom) / 2 + panX
        var originY = (paneHeight - canvasHeight * zoom) / 2 + panY
        let alignedX = screenPoint(CGFloat(originX))
        let alignedY = screenPoint(CGFloat(originY))
        panX += Double(alignedX - CGFloat(originX))
        panY += Double(alignedY - CGFloat(originY))
    }
}
