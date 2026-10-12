import Foundation
import CoreMedia
import CoreVideo
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

/// Counts frame copies so a freeze can be split into “player stopped” vs “preview stopped”.
final class PlaybackPullStats: @unchecked Sendable {
    private let lock = NSLock()
    private var copied = 0
    private var missed = 0
    private var lastCopiedAt: CFTimeInterval = 0

    func noteCopy() {
        lock.lock()
        copied += 1
        lastCopiedAt = CACurrentMediaTime()
        lock.unlock()
    }

    func noteMiss() {
        lock.lock()
        missed += 1
        lock.unlock()
    }

    func snapshot() -> (copied: Int, missed: Int, lastCopiedAt: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (copied, missed, lastCopiedAt)
    }

    func reset() {
        lock.lock()
        copied = 0
        missed = 0
        lastCopiedAt = 0
        lock.unlock()
    }
}

/// Pulls `AVPlayerItemVideoOutput` on the display-link queue with PTS deduplication and source cadence.
final class OffThreadVideoPublisher: @unchecked Sendable {
    #if canImport(AVFoundation)
    private let videoOutput: AVPlayerItemVideoOutput
    #endif
    private let lock = NSLock()
    private var lastPresentedPTS: CMTime = .invalid
    private var sourceNominalFrameDuration: CMTime = CMTime(value: 1, timescale: 30)
    private(set) var sourceNominalFPS: Int = 30
    let pullStats = PlaybackPullStats()

    var copiedFrameCount: Int64 {
        Int64(pullStats.snapshot().copied)
    }

#if canImport(AVFoundation)
    init(videoOutput: AVPlayerItemVideoOutput) {
        self.videoOutput = videoOutput
    }

    func configureSourceNominalFrameRate(_ fps: Float) {
        let clamped = max(1, min(fps, 120))
        let scale = CMTimeScale(max(1, Int(clamped.rounded())))
        lock.lock()
        sourceNominalFPS = Int(scale)
        sourceNominalFrameDuration = CMTime(value: 1, timescale: scale)
        lock.unlock()
    }
#endif

    /// Drop duplicate presentation times when display refresh outruns the source cadence.
    static func shouldPublish(presentationItemTime: CMTime, lastPresentedItemTime: CMTime) -> Bool {
        guard presentationItemTime.isValid, lastPresentedItemTime.isValid else { return true }
        return CMTimeCompare(presentationItemTime, lastPresentedItemTime) > 0
    }

    func resetPresentationClock() {
        lock.lock()
        lastPresentedPTS = .invalid
        lock.unlock()
        pullStats.reset()
    }

    /// Called from `com.proshow.video.displaylink` only.
    func processDisplayLinkTick(hostTime: CFTimeInterval = 0) {
#if canImport(AVFoundation)
        let host = hostTime > 0 ? hostTime : CACurrentMediaTime()
        let currentItemTime = videoOutput.itemTime(forHostTime: host)
        guard currentItemTime.isValid, !currentItemTime.isIndefinite else { return }

        lock.lock()
        let frameDuration = sourceNominalFrameDuration
        let lastPTS = lastPresentedPTS
        lock.unlock()

        if lastPTS.isValid, CMTimeCompare(currentItemTime, lastPTS) > 0 {
            let delta = CMTimeSubtract(currentItemTime, lastPTS)
            if CMTimeCompare(delta, frameDuration) < 0 {
                return
            }
        }

        guard videoOutput.hasNewPixelBuffer(forItemTime: currentItemTime) else {
            // Decoder not ready yet — normal between source frames at display-link rate.
            return
        }

        var framePTS = CMTime.invalid
        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: currentItemTime,
            itemTimeForDisplay: &framePTS
        ) else {
            pullStats.noteMiss()
            return
        }

        let stamp = framePTS.isValid ? framePTS : currentItemTime
        if lastPTS.isValid, CMTimeCompare(stamp, lastPTS) <= 0 {
            return
        }

        lock.lock()
        lastPresentedPTS = stamp
        lock.unlock()

        pullStats.noteCopy()
        SharedTexturePublisher.shared.publishFromBackgroundQueue(
            pixelBuffer: pixelBuffer,
            itemTime: stamp
        )
#endif
    }
}
