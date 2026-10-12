import CoreMedia
import Foundation

/// One host-clock origin for video PTS, AAC PTS, RTMP timestamps, and passthrough recording.
final class MediaClockAnchor: @unchecked Sendable {
    static let shared = MediaClockAnchor()

    private let lock = NSLock()
    private var hostAnchor: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var inactiveAudioIndex: Int64 = 0

    init() {}

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hostAnchor.isValid
    }

    /// T0 for a stream/record session. Call once before the first media timestamp.
    func reset() {
        lock.lock()
        hostAnchor = CMClockGetTime(CMClockGetHostTimeClock())
        lastAudioPTS = .invalid
        inactiveAudioIndex = 0
        lock.unlock()
    }

    func clear() {
        lock.lock()
        hostAnchor = .invalid
        lastAudioPTS = .invalid
        inactiveAudioIndex = 0
        lock.unlock()
    }

    func currentPresentationTime() -> CMTime {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return presentationTime(atHostTime: now)
    }

    func presentationTime(atHostTime hostTime: CMTime) -> CMTime {
        lock.lock()
        let anchor = hostAnchor
        lock.unlock()
        guard anchor.isValid, hostTime.isValid else { return .zero }
        let delta = CMTimeSubtract(hostTime, anchor)
        guard delta.isValid, CMTimeCompare(delta, .zero) >= 0 else { return .zero }
        return delta
    }

    func timestampMs(_ time: CMTime) -> UInt32 {
        guard time.isValid else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt32(min(seconds * 1000, Double(UInt32.max)))
    }

    /// False when the last block is still inside its 21 ms slot. Stops a fast timer from stamping audio into the future.
    func isAudioBlockDue(now: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> Bool {
        let frame = CMTime(value: Int64(ProgramStreamAudioClock.framesPerAccessUnit), timescale: CMTimeScale(ProgramStreamAudioClock.sampleRate))
        lock.lock()
        let anchor = hostAnchor
        let last = lastAudioPTS
        lock.unlock()
        guard anchor.isValid, last.isValid else { return true }
        let due = CMTimeAdd(last, frame)
        let raw = presentationTime(atHostTime: now)
        return CMTimeCompare(raw, due) >= 0
    }

    /// Next AAC access-unit PTS on the shared timeline.
    /// Live sessions quantize host time onto the 1024-sample grid. Idle sessions count frames from zero.
    func nextAudioPresentationTime() -> CMTime {
        let frame = CMTime(value: Int64(ProgramStreamAudioClock.framesPerAccessUnit), timescale: CMTimeScale(ProgramStreamAudioClock.sampleRate))
        lock.lock()
        let anchor = hostAnchor
        let last = lastAudioPTS
        let index = inactiveAudioIndex
        lock.unlock()

        let resolved: CMTime
        if anchor.isValid {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let raw = presentationTime(atHostTime: now)
            let samples = Int64((CMTimeGetSeconds(raw) * Double(ProgramStreamAudioClock.sampleRate)).rounded(.down))
            let aligned = max(0, samples / Int64(ProgramStreamAudioClock.framesPerAccessUnit)) * Int64(ProgramStreamAudioClock.framesPerAccessUnit)
            var candidate = CMTime(value: aligned, timescale: CMTimeScale(ProgramStreamAudioClock.sampleRate))
            if last.isValid, CMTimeCompare(candidate, last) <= 0 {
                candidate = CMTimeAdd(last, frame)
            }
            resolved = candidate
        } else {
            resolved = CMTime(value: index * Int64(ProgramStreamAudioClock.framesPerAccessUnit), timescale: CMTimeScale(ProgramStreamAudioClock.sampleRate))
        }

        lock.lock()
        lastAudioPTS = resolved
        if !hostAnchor.isValid {
            inactiveAudioIndex += 1
        }
        lock.unlock()
        return resolved
    }
}
