import SwiftUI
#if canImport(Controls)
import Controls
#endif

/// Six-band parametric curve editor. Drag a node to set Hz and gain.
struct ParametricEQView: View {
    var eq: ParametricEQ
    var onChange: (ParametricEQBand) -> Void

    private let frequencies: [Double] = {
        (0..<48).map { index in
            20 * pow(20_000.0 / 20.0, Double(index) / 47.0)
        }
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.sm) {
            curve
                .frame(height: 148)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(eq.bands) { band in
                    bandRow(band)
                }
            }
        }
        .padding(DeskSpace.sm)
        .background(ProShowTheme.panel)
        .frame(minWidth: 320)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Six band parametric EQ")
    }

    private var curve: some View {
        GeometryReader { geo in
            let response = AudioDSP.eqResponse(eq: eq, frequencies: frequencies)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(ProShowTheme.hairline, lineWidth: 1)
                Path { path in
                    for (index, gain) in response.enumerated() {
                        let point = CGPoint(
                            x: geo.size.width * CGFloat(index) / CGFloat(max(response.count - 1, 1)),
                            y: yPosition(gainDb: gain, height: geo.size.height)
                        )
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(ProShowTheme.accent, lineWidth: 2)
                ForEach(eq.bands) { band in
                    Circle()
                        .fill(band.enabled ? ProShowTheme.statusOn : ProShowTheme.secondaryLabel)
                        .frame(width: 14, height: 14)
                        .scaleEffect(1)
                        .position(
                            x: xPosition(frequency: band.frequency, width: geo.size.width),
                            y: yPosition(gainDb: band.gainDb, height: geo.size.height)
                        )
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    var next = band
                                    next.frequency = frequency(atX: value.location.x, width: geo.size.width, range: band.frequencyRange)
                                    next.gainDb = gain(atY: value.location.y, height: geo.size.height)
                                    onChange(next)
                                }
                        )
                        .accessibilityLabel("\(band.filter.title) band \(band.id)")
                        .accessibilityValue(String(format: "%.0f hertz, %+.1f dB", band.frequency, band.gainDb))
                }
            }
        }
        .background(ProShowTheme.stageInk)
        .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
        }
    }

    private func bandRow(_ band: ParametricEQBand) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(band.id)  \(band.filter.title)")
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.lyricWhite)
                Spacer()
                Toggle("On", isOn: Binding(
                    get: { band.enabled },
                    set: { value in
                        var next = band
                        next.enabled = value
                        onChange(next)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Enable \(band.filter.title)")
            }
            labeledSlider("Hz", value: band.frequency, range: band.frequencyRange) { value in
                var next = band
                next.frequency = value
                onChange(next)
            }
            #if canImport(Controls)
            HStack(spacing: 8) {
                Text("dB")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .frame(width: 22, alignment: .leading)
                ArcKnob(
                    "dB",
                    value: Binding(
                        get: { Float(band.gainDb) },
                        set: { value in
                            var next = band
                            next.gainDb = Double(value)
                            onChange(next)
                        }
                    ),
                    range: -12...12,
                    origin: 0
                )
                .foregroundColor(ProShowTheme.accent)
                .backgroundColor(ProShowTheme.canvas)
                .frame(width: 36, height: 36)
                .accessibilityLabel("Gain")
                Text(String(format: "%+.1f", band.gainDb))
                    .font(DeskType.mono)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .frame(width: 48, alignment: .trailing)
            }
            #else
            labeledSlider("dB", value: band.gainDb, range: -12...12) { value in
                var next = band
                next.gainDb = value
                onChange(next)
            }
            #endif
        }
    }

    private func labeledSlider(_ title: String, value: Double, range: ClosedRange<Double>, onEdit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(DeskType.micro)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .frame(width: 22, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onEdit), in: range)
                .tint(ProShowTheme.accent)
                .accessibilityLabel(title == "Hz" ? "Frequency" : "Gain")
            Text(title == "Hz" ? String(format: "%.0f", value) : String(format: "%+.1f", value))
                .font(DeskType.mono)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func xPosition(frequency: Double, width: CGFloat) -> CGFloat {
        let minF = log2(20.0)
        let maxF = log2(20_000.0)
        let t = (log2(max(frequency, 20)) - minF) / (maxF - minF)
        return width * CGFloat(min(1, max(0, t)))
    }

    private func frequency(atX x: CGFloat, width: CGFloat, range: ClosedRange<Double>) -> Double {
        let t = min(1, max(0, x / max(width, 1)))
        let hz = pow(2, log2(20.0) + Double(t) * (log2(20_000.0) - log2(20.0)))
        return min(range.upperBound, max(range.lowerBound, hz))
    }

    private func yPosition(gainDb: Double, height: CGFloat) -> CGFloat {
        let t = (12 - gainDb) / 24
        return height * CGFloat(min(1, max(0, t)))
    }

    private func gain(atY y: CGFloat, height: CGFloat) -> Double {
        let t = min(1, max(0, y / max(height, 1)))
        return min(12, max(-12, 12 - Double(t) * 24))
    }
}
