import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore
#endif

/// One meter channel sampled off the SwiftUI body path.
struct AudioMeterSample: Equatable, Sendable {
    var id: String
    var name: String
    var db: Double
    var holdDb: Double
    var isMuted: Bool
}

/// CALayer VU meters. Display-link ticks update layer frames without invalidating SwiftUI.
struct AudioMeterBridgeView: View {
    var orientation: Orientation = .horizontal
    var sample: () -> [AudioMeterSample]

    enum Orientation {
        case horizontal
        case vertical
    }

    var body: some View {
        #if os(macOS)
        AudioMeterBridgeRepresentable(orientation: orientation, sample: sample)
        #else
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { _ in
            let channels = sample()
            VStack(spacing: 4) {
                ForEach(channels, id: \.id) { channel in
                    HStack {
                        Text(channel.name).font(DeskType.micro)
                        Capsule()
                            .fill(channel.isMuted ? ProShowTheme.well : ProShowTheme.meterSafe)
                            .frame(width: max(2, 80 * AudioMeterBridgeView.normalized(channel.db)), height: 6)
                    }
                }
            }
        }
        #endif
    }

    static func normalized(_ db: Double) -> CGFloat {
        CGFloat(min(1, max(0, (db + 60) / 63)))
    }

    static func decibels(fromLinear linear: Double) -> Double {
        20 * log10(max(linear, 0.0001))
    }
}

#if os(macOS)
private struct AudioMeterBridgeRepresentable: NSViewRepresentable {
    var orientation: AudioMeterBridgeView.Orientation
    var sample: () -> [AudioMeterSample]

    func makeNSView(context: Context) -> AudioMeterBridgeNSView {
        let view = AudioMeterBridgeNSView()
        view.orientation = orientation
        view.sample = sample
        return view
    }

    func updateNSView(_ nsView: AudioMeterBridgeNSView, context: Context) {
        nsView.orientation = orientation
        nsView.sample = sample
    }

    static func dismantleNSView(_ nsView: AudioMeterBridgeNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class AudioMeterBridgeNSView: NSView {
    var orientation: AudioMeterBridgeView.Orientation = .horizontal
    var sample: () -> [AudioMeterSample] = { [] }
    private var rows: [Row] = []
    private var link: CADisplayLink?

    private struct Row {
        var id: String
        var name: CATextLayer
        var track: CALayer
        var fill: CALayer
        var hold: CALayer
        var peak: CATextLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            start()
        }
    }

    override func layout() {
        super.layout()
        render(sample())
    }

    func start() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        render(sample())
    }

    private func render(_ channels: [AudioMeterSample]) {
        if rows.map(\.id) != channels.map(\.id) {
            rebuild(channels)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = bounds
        switch orientation {
        case .vertical:
            layoutVertical(channels, in: bounds)
        case .horizontal:
            layoutHorizontal(channels, in: bounds)
        }
        CATransaction.commit()
    }

    private func layoutVertical(_ channels: [AudioMeterSample], in bounds: CGRect) {
        let count = max(channels.count, 1)
        let gap: CGFloat = 2
        let barWidth = max(2, (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count))
        for (index, channel) in channels.enumerated() {
            guard rows.indices.contains(index) else { continue }
            let row = rows[index]
            let x = CGFloat(index) * (barWidth + gap)
            let trackFrame = CGRect(x: x, y: 0, width: barWidth, height: bounds.height)
            let level = channel.isMuted ? 0 : AudioMeterBridgeView.normalized(channel.db)
            row.track.frame = trackFrame
            row.track.cornerRadius = barWidth / 2
            row.fill.frame = CGRect(
                x: x,
                y: 0,
                width: barWidth,
                height: max(2, trackFrame.height * max(0.05, level))
            )
            row.fill.cornerRadius = barWidth / 2
            row.fill.backgroundColor = barColor(level: level, muted: channel.isMuted)
            row.hold.isHidden = true
            row.name.isHidden = true
            row.peak.isHidden = true
        }
    }

    private func layoutHorizontal(_ channels: [AudioMeterSample], in bounds: CGRect) {
        let rowHeight = max(16, bounds.height / CGFloat(max(channels.count, 1)))
        let nameWidth: CGFloat = 64
        let peakWidth: CGFloat = 36
        for (index, channel) in channels.enumerated() {
            guard rows.indices.contains(index) else { continue }
            let row = rows[index]
            let y = bounds.height - CGFloat(index + 1) * rowHeight
            let trackFrame = CGRect(
                x: nameWidth,
                y: y + (rowHeight - 8) / 2,
                width: max(4, bounds.width - nameWidth - peakWidth),
                height: 8
            )
            let level = channel.isMuted ? 0 : AudioMeterBridgeView.normalized(channel.db)
            let hold = channel.isMuted ? 0 : AudioMeterBridgeView.normalized(channel.holdDb)
            row.name.isHidden = false
            row.peak.isHidden = false
            row.name.frame = CGRect(x: 0, y: y, width: nameWidth, height: rowHeight)
            row.name.string = channel.name
            row.track.frame = trackFrame
            row.track.cornerRadius = 1
            row.fill.frame = CGRect(
                x: trackFrame.minX,
                y: trackFrame.minY,
                width: max(2, trackFrame.width * level),
                height: trackFrame.height
            )
            row.fill.cornerRadius = 1
            row.fill.backgroundColor = barColor(level: level, muted: channel.isMuted)
            row.hold.isHidden = channel.isMuted
            row.hold.frame = CGRect(
                x: trackFrame.minX + max(0, trackFrame.width * hold - 1),
                y: trackFrame.minY,
                width: 1,
                height: trackFrame.height
            )
            row.peak.frame = CGRect(x: bounds.width - peakWidth, y: y, width: peakWidth, height: rowHeight)
            row.peak.string = channel.isMuted ? "OFF" : (channel.db <= -80 ? "—" : String(format: "%+.0f", channel.db))
            row.peak.foregroundColor = (!channel.isMuted && channel.db >= -3
                ? NSColor(ProShowTheme.liveRed)
                : NSColor(ProShowTheme.secondaryLabel)).cgColor
        }
    }

    private func rebuild(_ channels: [AudioMeterSample]) {
        rows.forEach { row in
            row.name.removeFromSuperlayer()
            row.track.removeFromSuperlayer()
            row.fill.removeFromSuperlayer()
            row.hold.removeFromSuperlayer()
            row.peak.removeFromSuperlayer()
        }
        let scale = window?.backingScaleFactor ?? 2
        rows = channels.map { channel in
            let name = CATextLayer()
            name.contentsScale = scale
            name.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            name.fontSize = 10
            name.foregroundColor = NSColor(ProShowTheme.primaryLabel).cgColor
            name.alignmentMode = .left
            name.truncationMode = .end
            let track = CALayer()
            track.backgroundColor = NSColor(ProShowTheme.well).cgColor
            let fill = CALayer()
            let hold = CALayer()
            hold.backgroundColor = NSColor.white.cgColor
            let peak = CATextLayer()
            peak.contentsScale = scale
            peak.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            peak.fontSize = 10
            peak.alignmentMode = .right
            layer?.addSublayer(name)
            layer?.addSublayer(track)
            layer?.addSublayer(fill)
            layer?.addSublayer(hold)
            layer?.addSublayer(peak)
            return Row(id: channel.id, name: name, track: track, fill: fill, hold: hold, peak: peak)
        }
    }

    private func barColor(level: CGFloat, muted: Bool) -> CGColor {
        if muted { return NSColor(ProShowTheme.well).cgColor }
        if level > 0.9 { return NSColor(ProShowTheme.liveRed).cgColor }
        if level > 0.7 { return NSColor(ProShowTheme.meterWarn).cgColor }
        return NSColor(ProShowTheme.meterSafe).cgColor
    }
}
#endif
