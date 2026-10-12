import SwiftUI
#if canImport(AudioKitUI)
import AudioKitUI
#endif
#if os(macOS)
import AppKit
#endif

/// 60 Hz log-frequency curve from the studio FFT (20 Hz–20 kHz).
struct FFTSpectrumView: View {
    var frequencyMagnitudes: [Float]
    var accentColor: Color = ProShowTheme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack {
                grid(in: geo.size)
                Path { path in
                    guard frequencyMagnitudes.count > 1 else { return }
                    let stepX = geo.size.width / CGFloat(frequencyMagnitudes.count - 1)
                    for (index, magnitude) in frequencyMagnitudes.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = CGFloat(1 - max(0, min(1, magnitude))) * geo.size.height
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(
                    LinearGradient(colors: [accentColor.opacity(0.55), ProShowTheme.meterSafe], startPoint: .bottom, endPoint: .top),
                    lineWidth: 1.6
                )
            }
        }
        .background(ProShowTheme.stageInk)
        .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spectrum analyzer")
        .accessibilityValue(spectrumSummary)
    }

    private var spectrumSummary: String {
        let peak = frequencyMagnitudes.max() ?? 0
        if peak < 0.05 { return "Silent" }
        if peak < 0.4 { return "Low" }
        if peak < 0.75 { return "Present" }
        return "Hot"
    }

    private func grid(in size: CGSize) -> some View {
        Canvas { context, canvas in
            for fraction in [0.25, 0.5, 0.75] {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: canvas.height * fraction))
                line.addLine(to: CGPoint(x: canvas.width, y: canvas.height * fraction))
                context.stroke(line, with: .color(Color.white.opacity(0.06)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// AudioKit waveform layer when available, with a live playhead for Layer 3 media.
struct AudioKitWaveformScrubber: View {
    var url: URL
    var peaks: [Double]
    var playhead: TimeInterval
    var duration: TimeInterval
    var onSeek: ((TimeInterval) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let progress = duration > 0 ? min(1, max(0, playhead / duration)) : 0
            ZStack(alignment: .leading) {
                #if canImport(AudioKitUI)
                AudioKitWaveformLayerView(samples: peaks.map { Float($0) })
                #else
                AudioWaveformScrubber(peaks: peaks, playhead: playhead, duration: duration, onSeek: nil)
                #endif
                Rectangle()
                    .fill(ProShowTheme.statusOn)
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: geo.size.width * progress)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                        onSeek?(fraction * duration)
                    }
            )
        }
        .background(ProShowTheme.stageInk)
        .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
        }
        .accessibilityLabel("Media waveform")
        .accessibilityValue(duration > 0 ? ProgramTimecode.format(playhead) : "Idle")
        .accessibilityHint(url.lastPathComponent)
    }
}

#if canImport(AudioKitUI)
#if os(macOS)
private struct AudioKitWaveformLayerView: NSViewRepresentable {
    var samples: [Float]

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        let waveform = Waveform(
            channels: 1,
            size: CGSize(width: 240, height: 40),
            waveformColor: NSColor(ProShowTheme.accent).cgColor,
            backgroundColor: NSColor.clear.cgColor
        )
        waveform.allowActions = false
        view.layer?.addSublayer(waveform)
        context.coordinator.waveform = waveform
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        context.coordinator.waveform?.frame = nsView.bounds
        if !samples.isEmpty {
            context.coordinator.waveform?.fill(with: [samples])
        }
        CATransaction.commit()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var waveform: Waveform?
    }
}
#else
private struct AudioKitWaveformLayerView: View {
    var samples: [Float]
    var body: some View {
        AudioWaveformScrubber(peaks: samples.map(Double.init), playhead: 0, duration: 0)
    }
}
#endif
#endif

/// Precomputed peak buckets with a live playhead for Layer 3 media.
struct AudioWaveformScrubber: View {
    var peaks: [Double]
    var playhead: TimeInterval
    var duration: TimeInterval
    var onSeek: ((TimeInterval) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let progress = duration > 0 ? min(1, max(0, playhead / duration)) : 0
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 1) {
                    ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                        Capsule()
                            .fill(ProShowTheme.toolbarIcon.opacity(0.45))
                            .frame(width: 2, height: max(3, geo.size.height * CGFloat(max(0.08, peak))))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle()
                    .fill(ProShowTheme.statusOn)
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: geo.size.width * progress)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                        onSeek?(fraction * duration)
                    }
            )
        }
        .accessibilityLabel("Media waveform")
        .accessibilityValue(duration > 0 ? ProgramTimecode.format(playhead) : "Idle")
    }
}
