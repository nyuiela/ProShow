import Foundation

struct PropertyChangeDelta<T: Equatable>: Equatable {
    let keyPath: String
    let oldValue: T
    let newValue: T
    let timestamp: Date
}

/// Session dirty flag, tombstones, and mutation revision for the active project.
@MainActor
@Observable
final class ShowStateTracker {
    private(set) var isDirty = false
    private(set) var lastSavedAt: Date?
    private(set) var activeRevision: UInt64 = 0

    private var deletedEntityTombstones: Set<UUID> = []

    func recordMutation<T: Equatable>(entityId: UUID, property: String, old: T, new: T) {
        guard old != new else { return }
        markRevised(entityId: entityId)
    }

    func noteRevision(entityId: UUID) {
        markRevised(entityId: entityId)
    }

    func recordDeletion(entityId: UUID) {
        deletedEntityTombstones.insert(entityId)
        isDirty = true
        activeRevision &+= 1
        UnifiedCacheRegistry.shared.purgeTombstone(entityId: entityId)
    }

    func isTombstoned(entityId: UUID) -> Bool {
        deletedEntityTombstones.contains(entityId)
    }

    func markClean() {
        isDirty = false
        lastSavedAt = Date()
        deletedEntityTombstones.removeAll()
    }

    private func markRevised(entityId: UUID) {
        isDirty = true
        activeRevision &+= 1
        UnifiedCacheRegistry.shared.invalidate(entityId: entityId)
    }
}
