import Foundation

/// Per-entity revision counters aligned with the global document revision stream.
final class EntityRevisionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entityRevision: [UUID: UInt64] = [:]
    private(set) var globalRevision: UInt64 = 0

    func bump(entityId: UUID, globalRevision: UInt64) {
        lock.lock()
        self.globalRevision = max(self.globalRevision, globalRevision)
        entityRevision[entityId] = globalRevision
        lock.unlock()
    }

    func revision(for entityId: UUID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return entityRevision[entityId] ?? 0
    }

    func reset(globalRevision: UInt64 = 0) {
        lock.lock()
        entityRevision.removeAll()
        self.globalRevision = globalRevision
        lock.unlock()
    }
}
