import Foundation
import Observation

/// Rolling RTMP video bitrate and drop stats for the desk toolbar while live.
@Observable
final class StreamTelemetryMonitor: @unchecked Sendable {
    private(set) var measuredVideoBitrateKbps: Int = 0
    private(set) var targetVideoBitrateKbps: Int = 2_500
    private(set) var ceilingVideoBitrateKbps: Int = 3_000
    private(set) var encodedFrameCount: UInt64 = 0
    private(set) var droppedFrameCount: Int = 0
    private(set) var skippedCompositeFrameCount: Int = 0
    /// Composite backlog hold — last frame re-encoded to preserve CFR packet cadence.
    private(set) var streamCFRHoldFrameCount: Int = 0
    private(set) var stabilityLabel: String = "Idle"

    private let lock = NSLock()
    private var windowBytes: Int = 0
    private var windowStarted = CFAbsoluteTimeGetCurrent()

    @MainActor
    func bind(config: StreamEncoderConfig) {
        targetVideoBitrateKbps = config.targetBitrateKbps
        ceilingVideoBitrateKbps = config.maxBitrateCeilingKbps
    }

    /// Called from the VideoToolbox output path — must not hop through MainActor for byte accounting.
    nonisolated func recordVideoAccessUnit(byteCount: Int) {
        lock.lock()
        windowBytes += max(0, byteCount)
        encodedFrameCount += 1
        let kbps = closeBitrateWindowIfElapsed(minimumInterval: 0.95)
        lock.unlock()
        guard let kbps else { return }
        Task { @MainActor [weak self] in
            self?.applyMeasuredBitrate(kbps)
        }
    }

    @MainActor
    func recordSkippedCompositeFrame() {
        skippedCompositeFrameCount += 1
    }

    @MainActor
    func recordStreamCFRHoldFrame() {
        streamCFRHoldFrameCount += 1
    }

    @MainActor
    func recordDroppedFrames(_ count: Int) {
        guard count > 0 else { return }
        droppedFrameCount += count
    }

    @MainActor
    func reset() {
        lock.lock()
        windowBytes = 0
        windowStarted = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        measuredVideoBitrateKbps = 0
        encodedFrameCount = 0
        droppedFrameCount = 0
        skippedCompositeFrameCount = 0
        streamCFRHoldFrameCount = 0
        stabilityLabel = "Idle"
    }

    /// Flush a stale measurement window (desk probe / toolbar poll).
    @MainActor
    func refreshMeasurementWindowIfNeeded() {
        lock.lock()
        let kbps = closeBitrateWindowIfElapsed(minimumInterval: 0.95)
        lock.unlock()
        if let kbps {
            applyMeasuredBitrate(kbps)
        }
    }

    var droppedPercent: Double {
        let encoded = encodedFrameCount
        let dropped = droppedFrameCount
        let total = encoded + UInt64(dropped)
        guard total > 0 else { return 0 }
        return (Double(dropped) / Double(total)) * 100
    }

    var summaryLine: String {
        "\(measuredVideoBitrateKbps) Kbps · \(stabilityLabel) · \(droppedFrameCount) dropped"
    }

    private func closeBitrateWindowIfElapsed(minimumInterval: TimeInterval) -> Int? {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - windowStarted
        guard elapsed >= minimumInterval else { return nil }
        let bytes = windowBytes
        windowBytes = 0
        windowStarted = now
        guard elapsed > 0 else { return 0 }
        return Int(Double(bytes * 8) / elapsed / 1000.0)
    }

    @MainActor
    private func applyMeasuredBitrate(_ kbps: Int) {
        measuredVideoBitrateKbps = kbps
        updateStability()
    }

    @MainActor
    private func updateStability() {
        let target = Double(targetVideoBitrateKbps)
        let measured = Double(measuredVideoBitrateKbps)
        guard target > 0, measured > 0 else {
            stabilityLabel = measured <= 0 ? "Low" : "Stable"
            return
        }
        let ratio = measured / target
        if ratio > 1.12 {
            stabilityLabel = "Near cap"
        } else if ratio < 0.65 {
            stabilityLabel = "Low"
        } else {
            stabilityLabel = "Stable"
        }
    }
}
