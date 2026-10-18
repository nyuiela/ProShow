import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore
#endif

/// Isolated timecode. Updates a CATextLayer so the desk SwiftUI tree does not rebuild.
struct PlayheadTimecodeView: View {
    var playback: MediaPlaybackEngine
    var clock: LiveTransportClock?
    var showsRemaining: Bool = false
    var alignment: TextAlignment = .leading
    var fontSize: CGFloat = 11
    var color: Color = ProShowTheme.secondaryLabel

    var body: some View {
        PlayheadTimecodeRepresentable(
            playback: playback,
            clock: clock,
            showsRemaining: showsRemaining,
            alignment: alignment,
            fontSize: fontSize,
            color: color
        )
        .frame(minWidth: 52, maxWidth: .infinity, minHeight: fontSize + 4, maxHeight: fontSize + 4)
        .accessibilityLabel(showsRemaining ? "Remaining" : "Playhead")
    }
}

/// Isolated scrubber. The knob tracks the clock on a display link, not @Observable playhead.
struct PlayheadScrubberView: View {
    var playback: MediaPlaybackEngine
    var onSeek: (TimeInterval) -> Void

    var body: some View {
        PlayheadScrubberRepresentable(playback: playback, onSeek: onSeek)
            .frame(height: 14)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Playhead")
    }
}

struct PulsedBuildEnvironment<Content: View>: View {
    var isActive: Bool
    var clock: () -> BuildClock
    @ViewBuilder var content: () -> Content

    @State private var onScreen = false
    /// Last clock seen by the poll, ignoring the per-frame counter nothing reads. The content (and any
    /// menus inside it) re-evaluates only when a build actually changes, not 30 times a second.
    @State private var current: BuildClock?

    var body: some View {
        let pulsing = isActive && onScreen
        content()
            .environment(\.buildClock, pulsing ? (current ?? clock()) : clock())
            .background {
                if pulsing {
                    TimelineView(.periodic(from: TimelineAnchor.start, by: 1.0 / 30.0)) { context in
                        Color.clear
                            .onChange(of: context.date) { _, _ in poll() }
                            .onAppear { poll() }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false; current = nil }
    }

    private func poll() {
        var next = clock()
        next.frame = 0
        if next != current { current = next }
    }
}

#if os(macOS)
private struct PlayheadTimecodeRepresentable: NSViewRepresentable {
    var playback: MediaPlaybackEngine
    var clock: LiveTransportClock?
    var showsRemaining: Bool
    var alignment: TextAlignment
    var fontSize: CGFloat
    var color: Color

    func makeNSView(context: Context) -> PlayheadTimecodeNSView {
        let view = PlayheadTimecodeNSView()
        view.configure(fontSize: fontSize, alignment: alignment, color: NSColor(color))
        view.playback = playback
        view.clock = clock
        view.showsRemaining = showsRemaining
        return view
    }

    func updateNSView(_ nsView: PlayheadTimecodeNSView, context: Context) {
        nsView.playback = playback
        nsView.clock = clock
        nsView.showsRemaining = showsRemaining
        nsView.configure(fontSize: fontSize, alignment: alignment, color: NSColor(color))
    }

    static func dismantleNSView(_ nsView: PlayheadTimecodeNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class PlayheadTimecodeNSView: NSView {
    var playback: MediaPlaybackEngine?
    weak var clock: LiveTransportClock?
    var showsRemaining = false
    private let textLayer = CATextLayer()
    private var link: CADisplayLink?
    private var lastString = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        textLayer.contentsScale = 2
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        layer?.addSublayer(textLayer)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    func configure(fontSize: CGFloat, alignment: TextAlignment, color: NSColor) {
        textLayer.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = color.cgColor
        textLayer.alignmentMode = alignment == .trailing ? .right : .left
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = bounds
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        step()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        let seconds: TimeInterval
        if showsRemaining {
            seconds = playback?.remaining ?? 0
        } else {
            seconds = clock?.currentPlayheadSeconds() ?? playback?.playhead ?? 0
        }
        let next = ProgramTimecode.format(seconds)
        guard next != lastString else { return }
        lastString = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = next
        CATransaction.commit()
        setAccessibilityValue(next)
    }
}

private struct PlayheadScrubberRepresentable: NSViewRepresentable {
    var playback: MediaPlaybackEngine
    var onSeek: (TimeInterval) -> Void

    func makeNSView(context: Context) -> PlayheadScrubberNSView {
        let view = PlayheadScrubberNSView()
        view.playback = playback
        view.onSeek = onSeek
        return view
    }

    func updateNSView(_ nsView: PlayheadScrubberNSView, context: Context) {
        nsView.playback = playback
        nsView.onSeek = onSeek
    }

    static func dismantleNSView(_ nsView: PlayheadScrubberNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class PlayheadScrubberNSView: NSView {
    var playback: MediaPlaybackEngine?
    var onSeek: ((TimeInterval) -> Void)?
    private let slider = NSSlider()
    private var link: CADisplayLink?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        slider.minValue = 0
        slider.maxValue = 1
        slider.controlSize = .mini
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        addSubview(slider)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        slider.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        step()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        guard !slider.isHighlighted, let playback else { return }
        let duration = max(playback.duration, 0)
        let fraction = duration <= 0 ? 0 : min(1, max(0, playback.playhead / duration))
        if abs(slider.doubleValue - fraction) > 0.001 {
            slider.doubleValue = fraction
        }
        slider.isEnabled = duration > 0
    }

    @objc private func changed() {
        guard let playback else { return }
        onSeek?(slider.doubleValue * max(playback.duration, 1))
    }
}
#else
private struct PlayheadTimecodeRepresentable: View {
    var playback: MediaPlaybackEngine
    var clock: LiveTransportClock?
    var showsRemaining: Bool
    var alignment: TextAlignment
    var fontSize: CGFloat
    var color: Color

    var body: some View {
        TimelineView(.periodic(from: TimelineAnchor.start, by: 0.25)) { _ in
            Text(ProgramTimecode.format(showsRemaining ? playback.remaining : playback.playhead))
                .font(.system(size: fontSize).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

private struct PlayheadScrubberRepresentable: View {
    var playback: MediaPlaybackEngine
    var onSeek: (TimeInterval) -> Void

    var body: some View {
        TimelineView(.periodic(from: TimelineAnchor.start, by: 0.25)) { _ in
            Slider(
                value: Binding(
                    get: {
                        let duration = max(playback.duration, 0)
                        return duration <= 0 ? 0 : min(1, max(0, playback.playhead / duration))
                    },
                    set: { onSeek($0 * max(playback.duration, 1)) }
                ),
                in: 0...1
            )
        }
    }
}
#endif
