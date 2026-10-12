import SwiftUI

/// Animated highlight sweep for canvas text, shapes, and media placeholders.
struct ElementShimmerEffect: Hashable, Codable, Sendable {
    var enabled: Bool = false
    /// Seconds for one full sweep.
    var cycleDuration: Double = 2.4
    /// Highlight band width as a fraction of the longest side (0.05…0.85).
    var bandWidth: Double = 0.32
    /// Peak highlight strength (0…1).
    var intensity: Double = 0.55
    /// Sweep angle in degrees (0 = left→right).
    var angle: Double = 22
    var highlightColor: String = "#FFFFFF"

    var isActive: Bool {
        enabled && intensity > 0.01 && cycleDuration > 0.05
    }
}

extension CanvasObject {
    var resolvedShimmer: ElementShimmerEffect {
        shimmer ?? ElementShimmerEffect()
    }
}

enum CanvasShimmerMath {
    static func phase(at date: Date, cycleDuration: Double) -> Double {
        let cycle = max(0.25, cycleDuration)
        let t = date.timeIntervalSinceReferenceDate
        return (t / cycle).truncatingRemainder(dividingBy: 1)
    }
}

extension View {
    /// Masks a moving highlight band to the element’s visible pixels (text, fill, image).
    func canvasElementShimmer(_ effect: ElementShimmerEffect, scale: CGFloat = 1) -> some View {
        modifier(CanvasElementShimmerModifier(effect: effect, scale: scale))
    }
}

private struct CanvasElementShimmerModifier: ViewModifier {
    var effect: ElementShimmerEffect
    var scale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false

    func body(content: Content) -> some View {
        if !effect.isActive || reduceMotion || !onScreen {
            content
                .onAppear { onScreen = true }
                .onDisappear { onScreen = false }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                let phase = CanvasShimmerMath.phase(at: timeline.date, cycleDuration: effect.cycleDuration)
                content
                    .overlay {
                        CanvasShimmerBandView(effect: effect, phase: phase, scale: scale)
                            .mask(content)
                    }
                    .compositingGroup()
            }
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
        }
    }
}

private struct CanvasShimmerBandView: View {
    var effect: ElementShimmerEffect
    var phase: Double
    var scale: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let longest = max(proxy.size.width, proxy.size.height, 1)
            let band = max(8, longest * CGFloat(effect.bandWidth.clamped(to: 0.05...0.85)))
            let travel = longest * 2.2
            let offset = (CGFloat(phase) * (travel + band)) - band
            let highlight = Color(hex: effect.highlightColor) ?? .white
            let strength = CGFloat(effect.intensity.clamped(to: 0...1))

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: highlight.opacity(strength * 0.15), location: 0.35),
                    .init(color: highlight.opacity(strength), location: 0.5),
                    .init(color: highlight.opacity(strength * 0.15), location: 0.65),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band, height: longest * 1.8)
            .rotationEffect(.degrees(effect.angle))
            .offset(x: offset - longest * 0.5, y: 0)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
