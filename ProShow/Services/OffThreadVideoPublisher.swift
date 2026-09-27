import Foundation
import CoreMedia
import CoreVideo
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

/// Pulls `AVPlayerItemVideoOutput` frames on `com.proshow.video.displaylink`.
/// Timestamp-dedupes 24/30 fps sources on 60/120 Hz displays and publishes IOSurface pointers.
final class OffThreadVideoPublisher: @unchecked Sendable {
    #if canImport(AVFoundation)
    private let videoOutput: AVPlayerItemVideoOutput
    #endif
    private let lock = NSLock()
    /// Last `itemTime(forHostTime:)` mapped frame; skips redundant 60/120 Hz pulls for 24/30 fps sources.
    private var lastMappedItemTime: CMTime = .invalid

#if canImport(AVFoundation)
    init(videoOutput: AVPlayerItemVideoOutput) {
        self.videoOutput = videoOutput
    }
#endif

    /// Drop duplicate presentation times when display refresh outruns the source cadence.
    static func shouldPublish(presentationItemTime: CMTime, lastPresentedItemTime: CMTime) -> Bool {
        guard presentationItemTime.isValid, lastPresentedItemTime.isValid else { return true }
        return CMTimeCompare(presentationItemTime, lastPresentedItemTime) != 0
    }

    func resetPresentationClock() {
        lock.lock()
        lastMappedItemTime = .invalid
        lock.unlock()
    }

    /// Called from `com.proshow.video.displaylink` only.
    func processDisplayLinkTick(displayTime: CVTimeStamp? = nil) {
        _ = displayTime
#if canImport(AVFoundation)
#if canImport(QuartzCore)
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
#else
        let itemTime = videoOutput.itemTime(forHostTime: CFAbsoluteTimeGetCurrent())
#endif
        guard itemTime.isValid, !itemTime.isIndefinite else { return }

        lock.lock()
        let lastMapped = lastMappedItemTime
        lock.unlock()
        if lastMapped.isValid, CMTimeCompare(itemTime, lastMapped) == 0 {
            return
        }
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }

        var presentationItemTime = CMTime.invalid
        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &presentationItemTime
        ) else { return }

        let stamp = presentationItemTime.isValid ? presentationItemTime : itemTime

        lock.lock()
        lastMappedItemTime = itemTime
        lock.unlock()

        SharedTexturePublisher.shared.publishFromBackgroundQueue(
            pixelBuffer: pixelBuffer,
            itemTime: stamp
        )
#endif
    }
}
