import Foundation

enum ThemeResolver {
    static func shouldApplyTheme(to slide: Slide) -> Bool {
        if slide.canvas.isEmpty, isDefaultTitleOnly(slide) { return false }
        guard ThemeVariantRegistry.variant(for: slide) != nil else { return false }
        switch slide.resolvedThemeApplication {
        case .native:
            return false
        case .replace, .decorOnly:
            return true
        case .auto:
            if slide.hasLinesOnlyPayload { return true }
            // A cleared canvas stays clear. An explicit variant can still lay out
            // its own empty slots; the default theme must not invent a lower third.
            if slide.canvas.isEmpty {
                return slide.themeVariantID != nil && slide.theme != "Default"
            }
            return false
        }
    }

    /// A new slide stores its name as the only line. That is not lyric copy, and
    /// it must not pull a lower-third layout back onto a clear canvas.
    private static func isDefaultTitleOnly(_ slide: Slide) -> Bool {
        guard slide.themeVariantID == nil else { return false }
        guard slide.theme == "Default" || slide.theme.isEmpty else { return false }
        let title = slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = slide.lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return body.isEmpty || body.allSatisfy { $0 == title }
    }

    static func resolvedCanvas(for slide: Slide) -> [CanvasObject]? {
        guard shouldApplyTheme(to: slide),
              let variant = ThemeVariantRegistry.variant(for: slide)
        else { return nil }
        return resolvedCanvas(for: slide, variant: variant, application: slide.resolvedThemeApplication)
    }

    static func resolvedCanvas(
        for slide: Slide,
        variant: ThemeVariantDefinition,
        application: ThemeApplicationMode
    ) -> [CanvasObject]? {
        guard application != .native else { return nil }
        if application == .auto, slide.canvas.isEmpty == false, !slide.hasLinesOnlyPayload {
            return nil
        }

        let blueprint = variant.taggedBlueprint()
        let payload = SlideContentPayload.make(from: slide, variantName: variant.name)

        switch application {
        case .decorOnly:
            let decor = resolve(payload: payload, blueprint: blueprint, decorOnly: true)
            return mergeDecor(decor, over: slide.canvas)
        case .native:
            return nil
        default:
            return resolve(payload: payload, blueprint: blueprint, decorOnly: false)
        }
    }

    static func resolve(payload: SlideContentPayload, blueprint: [CanvasObject], decorOnly: Bool = false) -> [CanvasObject] {
        var primaryIndex = 0
        var genericIndex = 0

        return blueprint.map { template in
            var object = template
            object.id = UUID()

            guard !decorOnly || template.themeSlot == nil else {
                if template.isTextLike { object.text = "" }
                return object
            }

            guard template.isTextLike else { return object }

            let slot = template.themeSlot ?? inferredSlot(for: template, primaryIndex: &primaryIndex)
            guard let slot else { return object }

            if let text = text(for: slot, payload: payload, primaryIndex: &primaryIndex, genericIndex: &genericIndex) {
                object.text = text
            } else {
                object.text = ""
            }
            return object
        }
    }

    private static func inferredSlot(for object: CanvasObject, primaryIndex: inout Int) -> ThemeSlotRole? {
        switch object.kind {
        case .title: return .title
        case .subtitle: return .subtitle
        case .text, .textField:
            defer { primaryIndex += 1 }
            return .primaryBody
        default:
            return nil
        }
    }

    private static func text(
        for slot: ThemeSlotRole,
        payload: SlideContentPayload,
        primaryIndex: inout Int,
        genericIndex: inout Int
    ) -> String? {
        if let match = payload.textStreams.first(where: { $0.role == slot })?.text {
            return match
        }
        switch slot {
        case .primaryBody:
            defer { primaryIndex += 1 }
            let unroled = payload.textStreams.filter { $0.role == nil || $0.role == .primaryBody }
            if unroled.count == 1 { return unroled[0].text }
            if primaryIndex < unroled.count { return unroled[primaryIndex].text }
            if let joined = joinedPrimaryBody(from: payload) { return joined }
            return payload.textStreams.first?.text
        case .title:
            return payload.textStreams.first(where: { $0.role == .title })?.text
                ?? payload.title.nilIfEmpty
                ?? payload.textStreams.first?.text
        case .subtitle:
            return payload.textStreams.first(where: { $0.role == .subtitle })?.text
                ?? payload.textStreams.dropFirst().first?.text
        case .reference, .speakerName, .secondaryBody:
            if let match = payload.textStreams.first(where: { $0.role == slot })?.text { return match }
            defer { genericIndex += 1 }
            guard payload.textStreams.indices.contains(genericIndex) else { return nil }
            return payload.textStreams[genericIndex].text
        case .speakerRole:
            return payload.textStreams.first(where: { $0.role == .speakerRole })?.text
                ?? payload.textStreams.dropFirst().map(\.text).joined(separator: "\n").nilIfEmpty
        case .decor:
            return nil
        }
    }

    private static func joinedPrimaryBody(from payload: SlideContentPayload) -> String? {
        let lines = payload.textStreams
            .filter { $0.role == nil || $0.role == .primaryBody }
            .map(\.text)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func mergeDecor(_ decor: [CanvasObject], over author: [CanvasObject]) -> [CanvasObject] {
        let back = decor.filter { !$0.isTextLike }
        let front = author.isEmpty ? decor.filter(\.isTextLike) : author
        return (back + front).enumerated().map { index, object in
            var copy = object
            copy.zIndex = index
            return copy
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Slide {
    var hasLinesOnlyPayload: Bool {
        canvas.isEmpty && !lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.isEmpty
    }

    var resolvedThemeApplication: ThemeApplicationMode {
        themeApplication
    }

    func resolvedCanvasBeforeAudienceFilter() -> [CanvasObject] {
        ThemeResolver.resolvedCanvas(for: self) ?? canvas
    }
}
