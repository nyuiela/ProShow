import CoreGraphics
import Foundation

#if os(macOS)
import AppKit
#endif

enum CanvasShimmerRasterizer {
    static func drawIfNeeded(
        object: CanvasObject,
        in rect: CGRect,
        context ctx: CGContext
    ) {
        let effect = object.resolvedShimmer
        guard effect.isActive else { return }
        let phase = CanvasShimmerMath.phase(at: Date(), cycleDuration: effect.cycleDuration)
        drawBand(effect: effect, phase: phase, in: rect, context: ctx)
    }

    private static func drawBand(
        effect: ElementShimmerEffect,
        phase: Double,
        in rect: CGRect,
        context ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.clip(to: rect)
        let longest = max(rect.width, rect.height, 1)
        let band = max(8, longest * CGFloat(effect.bandWidth.clamped(to: 0.05...0.85)))
        let travel = longest * 2.2
        let offset = (CGFloat(phase) * (travel + band)) - band
        let rgba = RGBA8.from(hex: effect.highlightColor)
        let strength = CGFloat(effect.intensity.clamped(to: 0...1))
        let angle = CGFloat(effect.angle) * .pi / 180
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: angle)
        let highlightRect = CGRect(x: -band / 2 + offset - rect.width, y: -rect.height, width: band, height: rect.height * 3)
        ctx.setFillColor(CGColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a * Double(strength)))
        ctx.fill(highlightRect)
        ctx.restoreGState()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
