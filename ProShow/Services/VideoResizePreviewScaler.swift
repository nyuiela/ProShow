import CoreGraphics
import Foundation

/// GPU-friendly affine preview during handle resize — keeps decoder output at committed size.
enum VideoResizePreviewScaler {
    /// Maps one canvas rectangle to another (document space).
    static func computePreviewTransform(originalBounds: CGRect, liveBounds: CGRect) -> CGAffineTransform {
        guard originalBounds.width > 0, originalBounds.height > 0 else { return .identity }
        let scaleX = liveBounds.width / originalBounds.width
        let scaleY = liveBounds.height / originalBounds.height
        let translationX = liveBounds.minX - originalBounds.minX * scaleX
        let translationY = liveBounds.minY - originalBounds.minY * scaleY
        return CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: translationX, ty: translationY)
    }

    static func computePreviewTransform(originalBounds: CanvasBounds, liveBounds: CanvasBounds) -> CGAffineTransform {
        computePreviewTransform(originalBounds: originalBounds.cgRect, liveBounds: liveBounds.cgRect)
    }

    /// Transform for SwiftUI `transformEffect` on a view framed at `original` size × `canvasScale`.
    static func previewTransformInViewSpace(
        from original: CanvasBounds,
        to live: CanvasBounds,
        canvasScale: CGFloat
    ) -> CGAffineTransform {
        guard original.width > 0, original.height > 0, canvasScale > 0 else { return .identity }
        let scaleX = live.width / original.width
        let scaleY = live.height / original.height
        let translationX = (live.x - original.x * scaleX) * Double(canvasScale)
        let translationY = (live.y - original.y * scaleY) * Double(canvasScale)
        return CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: translationX, ty: translationY)
    }
}
