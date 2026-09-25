import Foundation
import Observation
import SwiftUI

/// Live show state: selection, preview, and audience (program) output.
@MainActor
@Observable
final class ShowController {
    private(set) var show: Show
    private(set) var playlist: Playlist

    /// Operator selection / next intent.
    var selectedSlideID: SlideID?

    /// What is currently on the audience (program) surface.
    var liveSlideID: SlideID?

    var isAudienceCleared: Bool = false

    init(show: Show, playlist: Playlist) {
        self.show = show
        self.playlist = playlist
        self.selectedSlideID = show.allSlides.first?.id
    }

    static func loadSample() -> ShowController {
        let sample = SampleContent.sundayMorningService()
        return ShowController(show: sample.show, playlist: sample.playlist)
    }

    var selectedSlide: Slide? {
        guard let selectedSlideID else { return nil }
        return show.slide(id: selectedSlideID)
    }

    var liveSlide: Slide? {
        if isAudienceCleared { return nil }
        guard let liveSlideID else { return nil }
        return show.slide(id: liveSlideID)
    }

    var selectedIndex: Int? {
        guard let selectedSlideID else { return nil }
        return show.indexOfSlide(id: selectedSlideID)
    }

    var liveIndex: Int? {
        guard let liveSlideID else { return nil }
        return show.indexOfSlide(id: liveSlideID)
    }

    func select(_ slideID: SlideID) {
        selectedSlideID = slideID
    }

    func goLive(slideID: SlideID? = nil) {
        let target = slideID ?? selectedSlideID
        guard let target, show.slide(id: target) != nil else { return }
        liveSlideID = target
        selectedSlideID = target
        isAudienceCleared = false
    }

    func advance() {
        let slides = show.allSlides
        guard !slides.isEmpty else { return }
        let current = selectedIndex ?? liveIndex ?? -1
        let next = min(current + 1, slides.count - 1)
        let id = slides[next].id
        selectedSlideID = id
        goLive(slideID: id)
    }

    func goPrevious() {
        let slides = show.allSlides
        guard !slides.isEmpty else { return }
        let current = selectedIndex ?? liveIndex ?? 0
        let prev = max(current - 1, 0)
        let id = slides[prev].id
        selectedSlideID = id
        goLive(slideID: id)
    }

    func clearAudience() {
        isAudienceCleared = true
    }

    func restoreAudience() {
        isAudienceCleared = false
        if liveSlideID == nil {
            liveSlideID = selectedSlideID
        }
    }

    func reloadSample() {
        let sample = SampleContent.sundayMorningService()
        show = sample.show
        playlist = sample.playlist
        selectedSlideID = show.allSlides.first?.id
        liveSlideID = nil
        isAudienceCleared = false
    }
}
