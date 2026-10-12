import Foundation
import Observation

/// One live occupant of a compositor layer.
struct LiveLayerItem: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var thumbnailURI: String?
    var isLive: Bool
    var triggeredAt: Date

    init(
        id: UUID,
        name: String,
        thumbnailURI: String? = nil,
        isLive: Bool = true,
        triggeredAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.thumbnailURI = thumbnailURI
        self.isLive = isLive
        self.triggeredAt = triggeredAt
    }
}

/// Compound program state: many layers can be live at once.
@MainActor
@Observable
final class LiveStackState {
    var activeBaseColor: String = "#000000"
    var activeVideoInput: LiveLayerItem?
    var activeMedia: LiveLayerItem?
    var activeSlide: LiveLayerItem?
    var activePip: LiveLayerItem?
    var activeProps: [LiveLayerItem] = []
    var activeMessages: [LiveLayerItem] = []
    var activeOverlays: [LiveLayerItem] = []

    func isSlideActive(slideID: UUID) -> Bool {
        activeSlide?.id == slideID && activeSlide?.isLive == true
    }

    func isMediaActive(mediaID: UUID) -> Bool {
        activeMedia?.id == mediaID && activeMedia?.isLive == true
    }

    func isMediaNamed(_ name: String) -> Bool {
        guard let activeMedia, activeMedia.isLive else { return false }
        return activeMedia.name.caseInsensitiveCompare(name) == .orderedSame
    }

    func reset() {
        activeVideoInput = nil
        activeMedia = nil
        activeSlide = nil
        activePip = nil
        activeProps = []
        activeMessages = []
        activeOverlays = []
    }
}
