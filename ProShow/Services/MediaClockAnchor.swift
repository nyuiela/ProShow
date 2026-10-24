import CoreMedia
import Foundation

/// One host-clock origin for video PTS, AAC PTS, RTMP timestamps, and passthrough recording.
final class MediaClockAnchor: @unchecked Sendable {
    static let shared = MediaClockAnchor()

    private let lock = NSLock()
    private var hostAnchor: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var inactiveAudioIndex: Int64 = 0

    /// Audio more than this far behind host time jumps forward instead of catching up.
    static let resyncAfterSeconds: Double = 0.5
    private(set) var resyncCount = 0

    init() {}

    /// How many AAC blocks a pump tick should emit now (catch-up after a late tick), capped.
    /// Idle sessions without a host anchor always get exactly one.
    func dueAudioBlockCount(max cap: Int = 8, now: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> Int {
        let frameSeconds = Double(ProgramStreamAudioClock.framesPerAccessUnit) / Double(ProgramStreamAudioClock.sampleRate)
        lock.lock()
        let anchor = hostAnchor
        let last = lastAudioPTS
        lock.unlock()
        guard anchor.isValid else { return 1 }
        guard last.isValid else { return 1 }
        let raw = CMTimeGetSeconds(presentationTime(atHostTime: now))
        let next = CMTimeGetSeconds(last) + frameSeconds
        guard raw >= next else { return 0 }
        let due = Int((raw - next) / frameSeconds) + 1
        return min(Swift.max(1, due), Swift.max(1, cap))
    }

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
            if last.isValid {
                // Contiguous: one AU after the last. A late pump tick no longer skips grid slots
                // (that left holes in the AAC timeline). Resync only after a long stall.
                let next = CMTimeAdd(last, frame)
                let behind = CMTimeGetSeconds(CMTimeSubtract(raw, next))
                if behind > Self.resyncAfterSeconds, CMTimeCompare(candidate, next) > 0 {
                    resyncCount += 1
                } else {
                    candidate = next
                }
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
