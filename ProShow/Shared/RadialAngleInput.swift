import SwiftUI

/// Compact rotation control: dial, ±90° steps, and scrubbable degree field.
public struct RadialAngleInput: View {
    @Binding public var angleDegrees: Double
    public var range: ClosedRange<Double>

    public init(angleDegrees: Binding<Double>, range: ClosedRange<Double> = -180...180) {
        self._angleDegrees = angleDegrees
        self.range = range
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("Rotate")
                .font(InspectorTokens.labelFont)
                .foregroundStyle(ThemeTokens.textSecondary)
                .frame(width: InspectorTokens.labelColumnWidth, alignment: .leading)

            Spacer(minLength: 0)

            angleDial

            Button {
                angleDegrees = wrapped(angleDegrees - 90)
            } label: {
                Image(systemName: "rotate.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Rotate −90°")

            Button {
                angleDegrees = wrapped(angleDegrees + 90)
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Rotate +90°")

            ScrubbableComboInput(
                label: "",
                value: $angleDegrees,
                range: range,
                step: 1,
                unit: "°",
                labelWidth: 0,
                fieldWidth: 40
            )
        }
        .frame(minHeight: InspectorTokens.rowHeight)
    }

    private var angleDial: some View {
        ZStack {
            Circle()
                .stroke(ThemeTokens.borderSubtle, lineWidth: 1.5)
                .background(Circle().fill(ThemeTokens.bgControl))
                .frame(width: 22, height: 22)
            Rectangle()
                .fill(ThemeTokens.accentCyan)
                .frame(width: 1.5, height: 8)
                .offset(y: -4)
                .rotationEffect(.degrees(normalizedDisplay(angleDegrees)))
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = CGPoint(x: 11, y: 11)
                    let vector = CGVector(dx: value.location.x - center.x, dy: value.location.y - center.y)
                    var degrees = atan2(vector.dy, vector.dx) * 180 / .pi + 90
                    if degrees < 0 { degrees += 360 }
                    angleDegrees = wrapped(degrees.rounded())
                }
        )
        .accessibilityLabel("Rotation dial")
    }

    private func normalizedDisplay(_ angle: Double) -> Double {
        var degrees = angle.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private func wrapped(_ angle: Double) -> Double {
        min(max(angle, range.lowerBound), range.upperBound)
    }
}
