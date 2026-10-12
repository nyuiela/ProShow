import AppKit
import Foundation
import QuartzCore

/// CADisplayLink-driven scroll offsets for jitter-free teleprompter motion.
@Observable
@MainActor
final class ScrollEngine: NSObject, ScrollEngineProtocol {
    private(set) var offset: Double = 0
    private(set) var isRunning = false
    var speedPointsPerSecond: Double = 40 {
        didSet {
            if speedPointsPerSecond < 0 { speedPointsPerSecond = 0 }
        }
    }

    /// Measured text content height in points.
    var contentHeight: Double = 0
    /// Visible stage height in points.
    var viewportHeight: Double = 0
    /// Extra lead-in so the first line can sit on the eye-line.
    var leadIn: Double = 0

    var maxOffset: Double {
        max(0, contentHeight + leadIn - viewportHeight * 0.25)
    }

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    func start() {
        isRunning = true
        if displayLink == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            guard let link = screen?.displayLink(target: self, selector: #selector(handleDisplayLink(_:))) else {
                return
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTimestamp = 0
        }
    }

    func pause() {
        isRunning = false
        lastTimestamp = 0
    }

    func toggle() {
        if isRunning { pause() } else { start() }
    }

    func reset() {
        pause()
        offset = 0
        lastTimestamp = 0
    }

    func seek(to newOffset: Double) {
        offset = min(max(0, newOffset), maxOffset)
    }

    func nudge(by delta: Double) {
        seek(to: offset + delta)
    }

    /// Advances the scroll by `delta` seconds. Used by CADisplayLink and unit tests.
    func advance(by delta: CFTimeInterval) {
        guard isRunning, delta > 0, delta < 1 else { return }
        let proposed = offset + speedPointsPerSecond * delta
        if proposed >= maxOffset, maxOffset > 0 {
            offset = maxOffset
            pause()
        } else {
            offset = max(0, proposed)
        }
    }

    func invalidate() {
        pause()
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    private func handleDisplayLink(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        let delta = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        advance(by: delta)
    }
}
