import Foundation
import CoreGraphics

/// Seamless modulo phase math for dual-copy ticker loops (no SwiftUI animation restarts).
enum TickerEngine {
    static func unitDistance(contentExtent: CGFloat, gap: CGFloat) -> CGFloat {
        max(1, contentExtent + max(0, gap))
    }

    /// Primary copy offset along the scroll axis (negative when scrolling left/up).
    static func primaryOffset(
        elapsed: CFTimeInterval,
        speed: CGFloat,
        unitDistance: CGFloat,
        scrollForward: Bool
    ) -> CGFloat {
        guard unitDistance > 0, speed > 0 else { return 0 }
        let traveled = CGFloat(elapsed) * speed
        let remainder = traveled.truncatingRemainder(dividingBy: unitDistance)
        return scrollForward ? -remainder : remainder
    }

    static func pairedOffsets(primary: CGFloat, unitDistance: CGFloat) -> (CGFloat, CGFloat) {
        (primary, primary + unitDistance)
    }

    /// Pixel phase along the scroll axis (always in `[0, unit)`).
    static func phaseRemainder(
        startTime: CFTimeInterval,
        now: CFTimeInterval,
        speed: CGFloat,
        unitDistance: CGFloat
    ) -> CGFloat {
        guard unitDistance > 0, speed > 0 else { return 0 }
        let elapsed = max(0, now - startTime)
        return (CGFloat(elapsed) * speed).truncatingRemainder(dividingBy: unitDistance)
    }

    /// Re-anchor `startTime` so scroll phase is unchanged after live string width updates.
    static func startTimePreservingPhase(
        phase: CGFloat,
        now: CFTimeInterval,
        speed: CGFloat
    ) -> CFTimeInterval {
        guard speed > 0 else { return now }
        return now - Double(phase / speed)
    }

    /// Legacy canvas/build offset in document points (matches prior `BuildAnimationEngine.marqueeOffset`).
    static func marqueeOffset(
        elapsed: Double,
        contentWidth: Double,
        gap: Double,
        speed: Double,
        scrollForward: Bool
    ) -> Double {
        let unit = unitDistance(contentExtent: CGFloat(contentWidth), gap: CGFloat(gap))
        let offset = primaryOffset(
            elapsed: elapsed,
            speed: CGFloat(speed),
            unitDistance: unit,
            scrollForward: scrollForward
        )
        return Double(offset)
    }
}
