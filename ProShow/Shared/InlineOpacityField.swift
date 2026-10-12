import SwiftUI

/// Single-line opacity control: scrubbable percent field + mini track.
public struct InlineOpacityField: View {
    @Binding public var percent: Double

    public init(percent: Binding<Double>) {
        self._percent = percent
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("Opacity")
                .font(InspectorTokens.labelFont)
                .foregroundStyle(ThemeTokens.textSecondary)
                .frame(width: InspectorTokens.labelColumnWidth, alignment: .leading)

            ScrubbableComboInput(
                label: "",
                value: $percent,
                range: 0...100,
                step: 1,
                unit: "%",
                labelWidth: 0,
                fieldWidth: 40
            )

            GeometryReader { proxy in
                let fill = max(0, min(1, percent / 100))
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(ThemeTokens.borderSubtle)
                    Capsule(style: .continuous)
                        .fill(ThemeTokens.accentCyan.opacity(0.85))
                        .frame(width: max(2, proxy.size.width * fill))
                }
            }
            .frame(width: 52, height: 4)
            .accessibilityHidden(true)
        }
        .frame(minHeight: InspectorTokens.rowHeight)
    }
}
