import SwiftUI

/// Top / left ruler chrome with drag-to-spawn guideline support.
struct CanvasRulerView: View {
    var axis: GuideAxis
    var scale: Double
    var origin: Double
    var majorTick: Double
    var minorTick: Double
    var isActive: Bool = false
    /// Guides that appear as draggable handles on this ruler (`vertical` on the horizontal ruler, `horizontal` on the vertical ruler).
    var userGuides: [UserGuideLine] = []

    private var guideMarkerColor: Color {
        ThemeTokens.accentCyan.opacity(0.9)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ProShowTheme.elevatedPane.opacity(0.92)))
                drawTicks(context: &context, size: size)
                drawUserGuideMarkers(context: &context, size: size)
            }
            if isActive {
                Rectangle()
                    .fill(ProShowTheme.accent.opacity(0.18))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(axis == .horizontal ? "Horizontal ruler" : "Vertical ruler")
        .accessibilityHint("Drag onto the canvas to place a guide. Drag a cyan marker to move or remove.")
    }

    private func drawTicks(context: inout GraphicsContext, size: CGSize) {
        let span = axis == .horizontal ? size.width : size.height
        let safeScale = max(scale, 0.0001)
        let step = tickStep(for: safeScale)
        let minor = step == majorTick ? minorTick : max(step / 5, 1)
        let minValue = (0 - origin) / safeScale
        let maxValue = (Double(span) - origin) / safeScale
        let start = (minValue / minor).rounded(.down) * minor
        var value = start
        var drawn = 0
        while value <= maxValue + minor, drawn < 400 {
            let pos = origin + value * safeScale
            let isMajor = abs(value.truncatingRemainder(dividingBy: step)) < 0.001
                || abs(value.truncatingRemainder(dividingBy: step) - step) < 0.001
            var path = Path()
            if axis == .horizontal {
                path.move(to: CGPoint(x: pos, y: isMajor ? 5 : 12))
                path.addLine(to: CGPoint(x: pos, y: size.height))
            } else {
                path.move(to: CGPoint(x: isMajor ? 5 : 12, y: pos))
                path.addLine(to: CGPoint(x: size.width, y: pos))
            }
            context.stroke(path, with: .color(Color.white.opacity(isMajor ? 0.35 : 0.12)), lineWidth: 0.5)
            if isMajor {
                let label = Text(tickLabel(value))
                    .font(.system(size: 7, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(ProShowTheme.secondaryLabel)
                let at = axis == .horizontal
                    ? CGPoint(x: pos + 10, y: 7)
                    : CGPoint(x: 11, y: pos + 8)
                context.draw(label, at: at)
            }
            value += minor
            drawn += 1
        }
    }

    private func tickStep(for scale: Double) -> Double {
        if majorTick * scale >= 36 { return majorTick }
        let target = 72 / scale
        let nice = [1.0, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000]
        return nice.first { $0 >= target } ?? 5000
    }

    private func tickLabel(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(rounded) < 0.001 { return "0" }
        return String(Int(rounded))
    }

    private func drawUserGuideMarkers(context: inout GraphicsContext, size: CGSize) {
        let safeScale = max(scale, 0.0001)
        for guide in userGuides where !guide.isLocked {
            let pos = origin + Double(guide.position) * safeScale
            var path = Path()
            switch axis {
            case .horizontal:
                guard guide.axis == .vertical else { continue }
                guard pos >= -2, pos <= size.width + 2 else { continue }
                path.move(to: CGPoint(x: pos, y: size.height - 6))
                path.addLine(to: CGPoint(x: pos, y: size.height))
            case .vertical:
                guard guide.axis == .horizontal else { continue }
                guard pos >= -2, pos <= size.height + 2 else { continue }
                path.move(to: CGPoint(x: size.width - 6, y: pos))
                path.addLine(to: CGPoint(x: size.width, y: pos))
            }
            context.stroke(path, with: .color(guideMarkerColor), lineWidth: 2)
        }
    }
}
