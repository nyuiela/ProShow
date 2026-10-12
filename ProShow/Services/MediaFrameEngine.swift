import Foundation
import CoreGraphics
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

struct MediaFrameStyle: Equatable, Sendable {
    var cornerRadius: CGFloat
    var continuous: Bool
    var scaleMode: ImageScaleMode
    var opacity: Double
    var cropX: Double
    var cropY: Double
    var cropZoom: Double

    static func from(_ object: CanvasObject, scale: CGFloat) -> MediaFrameStyle {
        MediaFrameStyle(
            cornerRadius: CGFloat(object.resolvedCornerRadii.maxRadius) * scale,
            continuous: (object.stroke.cornerSmoothing ?? 0) > 0.01,
            scaleMode: object.fill.imageScaleMode,
            opacity: min(1, max(0, object.fill.opacity)),
            cropX: object.fill.resolvedCropX,
            cropY: object.fill.resolvedCropY,
            cropZoom: object.fill.resolvedCropZoom
        )
    }

    static let plain = MediaFrameStyle(
        cornerRadius: 0,
        continuous: true,
        scaleMode: .fill,
        opacity: 1,
        cropX: 0.5,
        cropY: 0.5,
        cropZoom: 1
    )
}

extension MediaFrameEngine {
    static var pageFitStyle: MediaFrameStyle {
        MediaFrameStyle(
            cornerRadius: 0,
            continuous: true,
            scaleMode: .fit,
            opacity: 1,
            cropX: 0.5,
            cropY: 0.5,
            cropZoom: 1
        )
    }
}

enum MediaFrameEngine {
    static func contentsRect(for style: MediaFrameStyle) -> CGRect {
        guard style.scaleMode == .crop else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let zoom = max(1, style.cropZoom)
        let width = 1 / zoom
        let height = 1 / zoom
        let x = min(max(0, style.cropX - width / 2), 1 - width)
        let y = min(max(0, style.cropY - height / 2), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func imageOffset(style: MediaFrameStyle, width: CGFloat, height: CGFloat) -> CGSize {
        guard style.scaleMode == .crop else { return .zero }
        let extra = max(0, style.cropZoom - 1)
        return CGSize(
            width: (0.5 - style.cropX) * width * extra,
            height: (0.5 - style.cropY) * height * extra
        )
    }

    #if canImport(QuartzCore)
    static func contentsGravity(for mode: ImageScaleMode) -> CALayerContentsGravity {
        mode.cropsToFrame ? .resizeAspectFill : .resizeAspect
    }
    #endif

    #if canImport(AVFoundation)
    static func videoGravity(for mode: ImageScaleMode) -> AVLayerVideoGravity {
        mode.cropsToFrame ? .resizeAspectFill : .resizeAspect
    }
    #endif

    #if canImport(QuartzCore)
    static func apply(to layer: CALayer, style: MediaFrameStyle) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = max(0, style.cornerRadius)
        layer.masksToBounds = true
        layer.cornerCurve = style.continuous ? .continuous : .circular
        applyMediaContents(layer, style: style)
        CATransaction.commit()
    }

    private static func applyMediaContents(_ layer: CALayer, style: MediaFrameStyle) {
        let rect = style.scaleMode == .crop
            ? contentsRect(for: style)
            : CGRect(x: 0, y: 0, width: 1, height: 1)
        layer.contentsRect = rect
        layer.contentsGravity = contentsGravity(for: style.scaleMode)
        #if canImport(AVFoundation)
        let gravity = videoGravity(for: style.scaleMode)
        if let player = layer as? AVPlayerLayer {
            player.videoGravity = gravity
        }
        if let preview = layer as? AVCaptureVideoPreviewLayer {
            preview.videoGravity = gravity
        }
        #endif
        for child in layer.sublayers ?? [] {
            applyMediaContents(child, style: style)
        }
    }
    #endif
}
