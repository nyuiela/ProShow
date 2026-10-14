import Foundation

/// Layer 3 decision when a slide cue fires.
enum MediaLayerDecision: Equatable, Sendable {
    case preserve
    case replace(MediaAction)
    case clear
}

/// Identity + playhead rules for Layer 3 against an incoming slide media action.
///
/// Media belongs to the Action Stack, not the slide. A lyric or scripture card
/// with no Layer 3 action leaves the running clip and playhead untouched.
/// Same file keeps the clock. A different file cross-dissolves. Explicit
/// "Clear Media" unloads. A locked layer ignores every incoming slide action.
enum MediaActionEvaluator {
    static func evaluate(
        current: MediaAction?,
        incoming: MediaAction?,
        projectRoot: URL? = nil,
        layerLocked: Bool = false
    ) -> MediaLayerDecision {
        if layerLocked { return .preserve }
        // Take match rule: same source stays, different source replaces,
        // nothing on the next slide clears unless the live media is marked Hold.
        guard let incoming else {
            guard let current else { return .clear }
            if current.id == RundownPageMedia.id { return .clear }
            return current.hold ? .preserve : .clear
        }
        if incoming.clearsLayer { return .clear }
        if let current, isSameAsset(current, incoming, projectRoot: projectRoot) {
            if current.hold, incoming.hold { return .preserve }
            return incoming.forceReset ? .replace(incoming) : .preserve
        }
        return .replace(incoming)
    }

    static func isSameAsset(_ lhs: MediaAction, _ rhs: MediaAction, projectRoot: URL? = nil) -> Bool {
        if lhs.id == rhs.id { return true }
        let leftURL = lhs.resolvedFileURL(projectRoot: projectRoot)
        let rightURL = rhs.resolvedFileURL(projectRoot: projectRoot)
        if let leftURL, let rightURL {
            return leftURL.standardizedFileURL.path == rightURL.standardizedFileURL.path
        }
        if let left = lhs.filePath, let right = rhs.filePath, !left.isEmpty, left == right {
            return true
        }
        if let letter = lhs.placeholderLetter, letter == rhs.placeholderLetter, !letter.isEmpty {
            return true
        }
        if lhs.title.caseInsensitiveCompare(rhs.title) == .orderedSame, !lhs.title.isEmpty {
            if let left = lhs.filePath, let right = rhs.filePath, !left.isEmpty, !right.isEmpty {
                return left == right
            }
            return true
        }
        return false
    }
}

extension Slide {
    var clearsProgramMedia: Bool {
        actions.contains { $0.caseInsensitiveCompare("Clear Media") == .orderedSame }
    }

    func associatedMediaAction() -> MediaAction? {
        if clearsProgramMedia {
            return .clearLayerCue()
        }
        if var mediaAction {
            mediaAction.forceReset = mediaAction.forceReset || forceResetMedia
            return mediaAction
        }
        let videos = canvas.compactMap { object -> MediaAction? in
            guard let media = object.programMediaAction() else { return nil }
            var next = media
            next.forceReset = forceResetMedia
            return next
        }
        if let plate = canvas.first(where: {
            $0.isFullBleedBackground(canvasWidth: CanvasConfig.width, canvasHeight: CanvasConfig.height)
                && $0.programMediaAction() != nil
        }) {
            return videos.first(where: { $0.id == plate.id || $0.filePath == plate.fill.imageURI }) ?? videos.first
        }
        return videos.first
    }
}
