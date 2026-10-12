import Foundation

enum ThemeRundownBridge {
    private static let variantKey = "proshow.themeVariantID"
    private static let applicationKey = "proshow.themeApplication"
    private static let profileKey = "proshow.contentProfile"

    static func themeVariantID(for block: RundownBlock) -> UUID? {
        block.extensions[variantKey].flatMap(UUID.init(uuidString:))
    }

    static func setThemeVariantID(_ id: UUID?, on block: inout RundownBlock) {
        if let id {
            block.extensions[variantKey] = id.uuidString
        } else {
            block.extensions.removeValue(forKey: variantKey)
        }
    }

    static func themeApplication(for block: RundownBlock) -> ThemeApplicationMode? {
        block.extensions[applicationKey].flatMap(ThemeApplicationMode.init(rawValue:))
    }

    static func setThemeApplication(_ mode: ThemeApplicationMode?, on block: inout RundownBlock) {
        if let mode {
            block.extensions[applicationKey] = mode.rawValue
        } else {
            block.extensions.removeValue(forKey: applicationKey)
        }
    }

    static func contentProfile(for block: RundownBlock) -> ContentProfile {
        if let raw = block.extensions[profileKey], let profile = ContentProfile(rawValue: raw) {
            return profile
        }
        switch block.segmentType {
        case .worship: return .lyricMultiLine
        case .keynote, .panel, .qAndA: return .lowerThird
        case .mediaVideo: return .picture
        case .opener, .closer: return .lyricTitle
        case .breakItem: return .generic
        }
    }

    static func shouldUseDecorOnly(block: RundownBlock, slide: Slide) -> Bool {
        switch RundownBlockSlideSource.resolve(block) {
        case .camera, .webPage, .mediaBin, .mediaFile:
            return true
        default:
            break
        }
        if slide.canvas.contains(where: { $0.kind == .videoInput }) { return true }
        if slide.canvas.contains(where: { $0.kind.isBrowserLike }) { return true }
        if ProgramOutlinePresentation.pageURL(in: slide) != nil { return true }
        return false
    }

    static func prepareSlide(
        _ slide: Slide,
        block: RundownBlock?,
        profileDefaults: [ContentProfile: UUID]
    ) -> Slide {
        guard let block else { return slide }
        // The operator cleared this slide. Do not stamp the outline theme back on.
        if slide.themeApplication == .native { return slide }
        if slide.canvas.isEmpty && slide.themeVariantID == nil && slide.theme == "Default" {
            let title = slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = slide.lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if body.isEmpty || body.allSatisfy({ $0 == title }) { return slide }
        }
        var copy = slide

        if let explicit = themeVariantID(for: block),
           let variant = ThemeVariantRegistry.variant(id: explicit) {
            copy.themeVariantID = variant.id
            copy.theme = variant.name
        } else if let defaultID = profileDefaults[contentProfile(for: block)],
                  let variant = ThemeVariantRegistry.variant(id: defaultID) {
            copy.themeVariantID = variant.id
            copy.theme = variant.name
        }

        if let application = themeApplication(for: block) {
            copy.themeApplication = application
        } else if shouldUseDecorOnly(block: block, slide: copy) {
            copy.themeApplication = .decorOnly
        } else if copy.themeVariantID != nil, copy.themeApplication == .auto {
            copy.themeApplication = copy.canvas.isEmpty ? .auto : .decorOnly
        }

        if shouldUseDecorOnly(block: block, slide: copy), copy.themeVariantID == nil {
            if let lower = ThemeVariantRegistry.variant(named: "Lower Third") {
                copy.themeVariantID = lower.id
                copy.theme = lower.name
                copy.themeApplication = .decorOnly
            }
        }

        return copy
    }

    static func block(forSlideID slideID: SlideID, in doc: ProgramDocumentModel) -> RundownBlock? {
        doc.rundownBlocks.first { $0.programSlideID == slideID }
    }
}
