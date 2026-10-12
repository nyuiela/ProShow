import Foundation

/// Hardware / IP ingest stall detection — triggers backup routing without dropping program encode.
final class InputFailoverEngine: @unchecked Sendable {
    static let shared = InputFailoverEngine()

    /// Live broadcast target: failover before operators notice a frozen frame.
    var stallThresholdSeconds: TimeInterval = 0.5

    private let lock = NSLock()
    private var lastFrameAt: [String: Date] = [:]

    func noteFrame(sourceKey: String, now: Date = Date()) {
        guard !sourceKey.isEmpty else { return }
        lock.lock()
        lastFrameAt[sourceKey] = now
        lock.unlock()
    }

    func isStalled(sourceKey: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastFrameAt[sourceKey] else { return true }
        return now.timeIntervalSince(last) >= stallThresholdSeconds
    }

    func elapsedSinceLastFrame(sourceKey: String, now: Date = Date()) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastFrameAt[sourceKey] else { return nil }
        return now.timeIntervalSince(last)
    }

    /// Placeholder IDs whose primary source has stalled beyond the threshold.
    func stalledPlaceholderIDs(
        placeholders: [PlaceholderConfiguration],
        alreadyOnFailover: Set<String>,
        now: Date = Date()
    ) -> [String] {
        placeholders.compactMap { placeholder in
            guard placeholder.autoFailoverEnabled,
                  let primary = placeholder.primarySourceId,
                  !alreadyOnFailover.contains(placeholder.id),
                  isStalled(sourceKey: primary, now: now)
            else { return nil }
            return placeholder.id
        }
    }

    func reset(sourceKey: String) {
        lock.lock()
        lastFrameAt.removeValue(forKey: sourceKey)
        lock.unlock()
    }

    func resetAll() {
        lock.lock()
        lastFrameAt.removeAll()
        lock.unlock()
    }
}
