import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum InspectorTokens {
    public static let panelWidth: CGFloat = 300.0
    public static let horizontalPadding: CGFloat = 12.0
    public static let verticalPadding: CGFloat = 12.0
    public static let sectionSpacing: CGFloat = 16.0
    public static let rowSpacing: CGFloat = 6.0
    public static let labelColumnWidth: CGFloat = 90.0

    public static let headerHeight: CGFloat = 28.0
    public static let rowHeight: CGFloat = 24.0
    public static let controlHeight: CGFloat = 20.0
    public static let numericFieldWidth: CGFloat = 48.0
    public static let iconButtonSize: CGFloat = 22.0

    public static let sectionHeaderFont = Font.system(size: 11, weight: .bold)
    public static let labelFont = Font.system(size: 11, weight: .regular)
    public static let valueFont = Font.system(size: 11, weight: .regular, design: .monospaced)
    public static let iconFont = Font.system(size: 11, weight: .medium)

    public static let labelColor = ProShowTheme.secondaryLabel
    public static let headerColor = ProShowTheme.primaryLabel
    public static let dividerColor = ProShowTheme.hairline
    public static let controlBackground = ProShowTheme.well
    public static let activeAccent = ProShowTheme.accent
}

public enum InspectorHAlign: Hashable {
    case left, center, right
}

public enum InspectorVAlign: Hashable {
    case top, middle, bottom
}

public enum InspectorDistribute: Hashable {
    case horizontal, vertical
}

public struct InspectorSection<Content: View>: View {
    public let title: String
    @State private var isExpanded: Bool = true
    @ViewBuilder public let content: () -> Content

    public init(_ title: String, isExpanded: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = State(initialValue: isExpanded)
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(InspectorTokens.sectionHeaderFont)
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(InspectorTokens.labelColor)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(height: InspectorTokens.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: InspectorTokens.rowSpacing) {
                    content()
                }
                .padding(.top, 6)
                .padding(.bottom, 10)
            }

            Divider()
                .overlay(InspectorTokens.dividerColor)
        }
    }
}

/// Fixed-size swatch; full color UI opens from the invisible `ColorPicker` hit target.
public struct CompactColorSwatch: View {
    @Binding public var color: Color
    public var size: CGFloat
    public var supportsOpacity: Bool
    public var accessibilityLabel: String

    public init(
        color: Binding<Color>,
        size: CGFloat = 22,
        supportsOpacity: Bool = false,
        accessibilityLabel: String
    ) {
        self._color = color
        self.size = size
        self.supportsOpacity = supportsOpacity
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        ColorPicker(selection: $color, supportsOpacity: supportsOpacity) {
            swatch
        }
        .labelsHidden()
        .accessibilityLabel(accessibilityLabel)
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

public struct PropertyRow<Control: View>: View {
    public let label: String
    @ViewBuilder public let control: () -> Control

    public init(_ label: String, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.control = control
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(InspectorTokens.labelFont)
                .foregroundColor(InspectorTokens.labelColor)
                .frame(width: InspectorTokens.labelColumnWidth, alignment: .leading)
                .lineLimit(1)

            Spacer(minLength: 0)

            control()
        }
        .frame(minHeight: InspectorTokens.rowHeight)
    }
}

public struct NumericSliderRow: View {
    public let label: String
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let unit: String

    public init(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String = "") {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    public var body: some View {
        PropertyRow(label) {
            HStack(spacing: 6) {
                Slider(value: $value, in: range, step: step)
                    .controlSize(.small)

                TextField("", value: $value, format: .number.precision(.fractionLength(0...1)))
                    .font(InspectorTokens.valueFont)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.squareBorder)
                    .controlSize(.small)
                    .frame(width: InspectorTokens.numericFieldWidth)

                if !unit.isEmpty {
                    Text(unit)
                        .font(InspectorTokens.labelFont)
                        .foregroundColor(InspectorTokens.labelColor)
                }
            }
        }
    }
}

public struct InspectorNumericField: View {
    @Binding public var value: Double
    public var unit: String = ""
    public var fractionLength: ClosedRange<Int> = 0...1

    public init(value: Binding<Double>, unit: String = "", fractionLength: ClosedRange<Int> = 0...1) {
        self._value = value
        self.unit = unit
        self.fractionLength = fractionLength
    }

    public var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number.precision(.fractionLength(fractionLength)))
                .font(InspectorTokens.valueFont)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.squareBorder)
                .controlSize(.small)
                .frame(width: InspectorTokens.numericFieldWidth)
            if !unit.isEmpty {
                Text(unit)
                    .font(InspectorTokens.labelFont)
                    .foregroundColor(InspectorTokens.labelColor)
            }
        }
    }
}

public struct InspectorIconOption<T: Hashable>: Identifiable {
    public var id: T { value }
    public let value: T
    public let iconName: String
    public let tooltip: String

    public init(value: T, iconName: String, tooltip: String) {
        self.value = value
        self.iconName = iconName
        self.tooltip = tooltip
    }
}

public struct IconSegmentedPicker<T: Hashable>: View {
    @Binding public var selection: T
    public let options: [InspectorIconOption<T>]

    public init(selection: Binding<T>, options: [InspectorIconOption<T>]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button(action: { selection = option.value }) {
                    Image(systemName: option.iconName)
                        .font(InspectorTokens.iconFont)
                        .frame(width: InspectorTokens.iconButtonSize, height: InspectorTokens.iconButtonSize)
                        .background(selection == option.value ? InspectorTokens.activeAccent : Color.clear)
                        .foregroundColor(selection == option.value ? .white : InspectorTokens.headerColor)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help(option.tooltip)
            }
        }
        .padding(2)
        .background(ProShowTheme.well)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

public struct TransformGrid: View {
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
        keepAspectRatio: Binding<Bool> = .constant(false)
    ) {
        self._x = x
        self._y = y
        self._width = width
        self._height = height
        self._keepAspectRatio = keepAspectRatio
    }

    public var body: some View {
        BoundsMatrixInput(
            x: $x,
            y: $y,
            width: $width,
            height: $height,
            keepAspectRatio: $keepAspectRatio
        )
    }
}
