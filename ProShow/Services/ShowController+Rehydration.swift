import Foundation

extension ShowController {
    /// Strips session-tombstoned canvas objects so cached / disk state cannot resurrect them.
    func sanitizeSlide(_ slide: Slide) -> Slide {
        var copy = slide
        copy.canvas = slide.canvas.filter { !documentState.isTombstoned($0.id) }
        copy.elements = slide.elements.filter { !documentState.isTombstoned($0.id) }
        return copy
    }

    func sanitizeSlideOnDisk(id slideID: SlideID) {
        guard let slide = show.slide(id: slideID) else { return }
        let cleaned = sanitizeSlide(slide)
        guard cleaned != slide else { return }
        configureSlide(id: slideID) { $0 = cleaned }
    }

    func sanitizeAndApplyLiveSlide(_ slide: Slide) {
        let cleaned = sanitizeSlide(slide)
        applyLiveSceneDelta(for: cleaned)
    }
}
