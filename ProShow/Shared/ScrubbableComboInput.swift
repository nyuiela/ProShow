import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Typeable numeric field with label scrubbing and optional preset menu.
public struct ScrubbableComboInput: View {
    public let label: String
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let unit: String
    public let presets: [Double]?
    public let fractionDigits: Int
    public let labelWidth: CGFloat
    public let fieldWidth: CGFloat

    @State private var textValue: String = ""
    @State private var isEditing = false
    @State private var scrubOrigin: Double?

    public init(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double> = 0...1000,
        step: Double = 1,
        unit: String = "pt",
        presets: [Double]? = nil,
        fractionDigits: Int = 0,
        labelWidth: CGFloat = 42,
        fieldWidth: CGFloat = InspectorTokens.numericFieldWidth
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.presets = presets
        self.fractionDigits = fractionDigits
        self.labelWidth = labelWidth
        self.fieldWidth = fieldWidth
    }

    public var body: some View {
        HStack(spacing: 4) {
            if !label.isEmpty {
                Text(label)
                    .font(InspectorTokens.valueFont.weight(.medium))
                    .foregroundStyle(ThemeTokens.textSecondary)
                    .frame(width: labelWidth, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture)
                    #if os(macOS)
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    #endif
                    .accessibilityLabel("\(label), scrub to adjust")
            }

            Spacer(minLength: 0)

            TextField("", text: textBinding, onEditingChanged: { editing in
                isEditing = editing
                if editing {
                    textValue = editableText
                } else {
                    commitText()
                }
            })
            .font(InspectorTokens.valueFont)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.plain)
            .padding(.horizontal, 5)
            .frame(width: fieldWidth)
            .frame(height: InspectorTokens.controlHeight)
            .background(ThemeTokens.bgControl)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(ThemeTokens.borderSubtle, lineWidth: 1)
            )
            .onSubmit { commitText() }

            if let presets, !presets.isEmpty {
                Menu { let _ = MenuRenderProbe.hit("ScrubbableComboInput:86:ScrubbableComboInput.?");
                    ForEach(presets, id: \.self) { preset in
                        Button(formatDisplay(preset)) {
                            value = clamped(preset)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ThemeTokens.textMuted)
                        .frame(width: 14, height: InspectorTokens.controlHeight)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("\(label) presets")
            }
        }
        .frame(minHeight: InspectorTokens.rowHeight)
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if scrubOrigin == nil { scrubOrigin = value }
                guard let origin = scrubOrigin else { return }
                let delta = Double(gesture.translation.width) * step * 0.5
                value = clamped(snapped(origin + delta))
            }
            .onEnded { _ in scrubOrigin = nil }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { isEditing ? textValue : displayText },
            set: { textValue = $0 }
        )
    }

    private var displayText: String {
        let core = formatDisplay(value)
        return unit.isEmpty ? core : "\(core)\(unit)"
    }

    private var editableText: String {
        formatDisplay(value)
    }

    private func formatDisplay(_ number: Double) -> String {
        if fractionDigits == 0 {
            return "\(Int(number.rounded()))"
        }
        return String(format: "%.\(fractionDigits)f", number)
    }

    private func commitText() {
        let stripped = textValue
            .replacingOccurrences(of: unit, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(stripped) else { return }
        value = clamped(snapped(parsed))
        textValue = formatDisplay(value)
    }

    private func clamped(_ raw: Double) -> Double {
        min(max(raw, range.lowerBound), range.upperBound)
    }

    private func snapped(_ raw: Double) -> Double {
        guard step > 0 else { return raw }
        return (raw / step).rounded() * step
    }
}
