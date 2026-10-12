import SwiftUI

/// 2×2 X/Y and W/H grid with integrated aspect-ratio lock.
public struct BoundsMatrixInput: View {
    @Binding public var x: Double
    @Binding public var y: Double
    @Binding public var width: Double
    @Binding public var height: Double
    @Binding public var keepAspectRatio: Bool

    public init(
        x: Binding<Double>,
        y: Binding<Double>,
        width: Binding<Double>,
        height: Binding<Double>,
        keepAspectRatio: Binding<Bool>
    ) {
        self._x = x
        self._y = y
        self._width = width
        self._height = height
        self._keepAspectRatio = keepAspectRatio
    }

    public var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ScrubbableComboInput(
                    label: "X", value: $x, range: -10_000...10_000, step: 1, unit: "px",
                    labelWidth: 16, fieldWidth: 44
                )
                ScrubbableComboInput(
                    label: "Y", value: $y, range: -10_000...10_000, step: 1, unit: "px",
                    labelWidth: 16, fieldWidth: 44
                )
            }
            HStack(spacing: 6) {
                ScrubbableComboInput(
                    label: "W",
                    value: $width,
                    range: 1...10_000,
                    step: 1,
                    unit: "px",
                    labelWidth: 16,
                    fieldWidth: 44
                )
                Button(action: { keepAspectRatio.toggle() }) {
                    Image(systemName: keepAspectRatio ? "lock.fill" : "lock.open")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(keepAspectRatio ? ThemeTokens.accentCyan : ThemeTokens.textMuted)
                        .frame(width: 18, height: InspectorTokens.controlHeight)
                }
                .buttonStyle(.plain)
                .help(keepAspectRatio ? "Aspect ratio locked" : "Aspect ratio unlocked")
                ScrubbableComboInput(
                    label: "H",
                    value: $height,
                    range: 1...10_000,
                    step: 1,
                    unit: "px",
                    labelWidth: 16,
                    fieldWidth: 44
                )
            }
        }
    }
}
