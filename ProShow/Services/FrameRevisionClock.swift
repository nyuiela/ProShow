import Foundation

/// Monotonic revision for program-wide visual parity (preview, audience, encode).
final class FrameRevisionClock: @unchecked Sendable {
    static let shared = FrameRevisionClock()

    private let lock = NSLock()
    private(set) var currentRevision: UInt64 = 1
    private(set) var currentHash: RenderStateHash?

    private init() {}

    /// Returns `true` when revision advanced and caches were invalidated.
    @discardableResult
    func advance(newHash: RenderStateHash) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if currentHash == newHash {
            return false
        }
        currentRevision &+= 1
        currentHash = newHash
        let revision = currentRevision
        VideoInvalidationEngine.shared.invalidateAllBuffers(upToRevision: revision)
        return true
    }

    func resetForTests() {
        lock.lock()
        currentRevision = 1
        currentHash = nil
        lock.unlock()
    }
}
