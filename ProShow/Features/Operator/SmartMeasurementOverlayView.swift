import SwiftUI

/// Figma-style Option-key distance overlay. Decorative; does not take hits.
struct SmartMeasurementOverlayView: View {
    var state: SmartMeasurementOverlayState
    var scale: CGFloat

    private let measure = Color(red: 1, green: 45 / 255, blue: 85 / 255)
    private let dimensionFill = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255).opacity(0.8)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawProjections(in: &context)
                drawVectors(in: &context)
            }
            ForEach(state.measurementVectors) { vector in
                badge(vector.labelText, fill: measure)
                    .position(scaled(midpoint(vector)))
            }
            if let label = state.targetDimensionLabel {
                badge(label, fill: dimensionFill)
                    .position(scaled(state.targetDimensionPosition))
            }
        }
        .opacity(state.isActive ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawProjections(in context: inout GraphicsContext) {
        var index = 0
        let pairs = state.projectionLines
        while index + 1 < pairs.count {
            var path = Path()
            path.move(to: scaled(pairs[index]))
            path.addLine(to: scaled(pairs[index + 1]))
            context.stroke(
                path,
                with: .color(measure),
                style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [2, 2])
            )
            index += 2
        }
    }

    private func drawVectors(in context: inout GraphicsContext) {
        for vector in state.measurementVectors {
            let start = scaled(vector.startPoint)
            let end = scaled(vector.endPoint)
            var line = Path()
            line.move(to: start)
            line.addLine(to: end)
            context.stroke(line, with: .color(measure), lineWidth: 1)
            drawTick(in: &context, at: start, vertical: vector.isVertical)
            drawTick(in: &context, at: end, vertical: vector.isVertical)
        }
    }

    private func drawTick(in context: inout GraphicsContext, at point: CGPoint, vertical: Bool) {
        var tick = Path()
        if vertical {
            tick.move(to: CGPoint(x: point.x - 3, y: point.y))
            tick.addLine(to: CGPoint(x: point.x + 3, y: point.y))
        } else {
            tick.move(to: CGPoint(x: point.x, y: point.y - 3))
            tick.addLine(to: CGPoint(x: point.x, y: point.y + 3))
        }
        context.stroke(tick, with: .color(measure), lineWidth: 1)
    }

    private func badge(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func scaled(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private func midpoint(_ vector: SmartMeasurementVector) -> CGPoint {
        CGPoint(
            x: (vector.startPoint.x + vector.endPoint.x) / 2,
            y: (vector.startPoint.y + vector.endPoint.y) / 2
        )
    }
}
