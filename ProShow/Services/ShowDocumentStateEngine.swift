import Foundation

/// Facade: dirty tracking, revision store, cache invalidation, and save coordination.
@MainActor
@Observable
final class ShowDocumentStateEngine {
    let tracker = ShowStateTracker()
    let revisions = EntityRevisionStore()

    var isDirty: Bool { tracker.isDirty }

    func recordMutation<T: Equatable>(entityId: UUID, property: String, old: T, new: T) {
        tracker.recordMutation(entityId: entityId, property: property, old: old, new: new)
        revisions.bump(entityId: entityId, globalRevision: tracker.activeRevision)
        UnifiedCacheRegistry.shared.registerGlobalRevision(tracker.activeRevision)
    }

    func noteDocumentMutation(entityId: UUID) {
        tracker.noteRevision(entityId: entityId)
        revisions.bump(entityId: entityId, globalRevision: tracker.activeRevision)
        UnifiedCacheRegistry.shared.registerGlobalRevision(tracker.activeRevision)
    }

    func recordDeletion(entityId: UUID) {
        tracker.recordDeletion(entityId: entityId)
        revisions.bump(entityId: entityId, globalRevision: tracker.activeRevision)
        UnifiedCacheRegistry.shared.registerGlobalRevision(tracker.activeRevision)
    }

    func isTombstoned(_ entityId: UUID) -> Bool {
        tracker.isTombstoned(entityId: entityId)
    }

    func markCleanAfterSuccessfulSave() {
        tracker.markClean()
        revisions.reset(globalRevision: tracker.activeRevision)
    }

    func flushAllCaches() {
        UnifiedCacheRegistry.shared.flushAll()
    }
}
