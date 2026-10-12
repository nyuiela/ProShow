import Foundation

/// Production role of a themed layout slot (maps payload text onto blueprint objects).
enum ThemeSlotRole: String, CaseIterable, Codable, Sendable {
    case decor
    case primaryBody
    case title
    case subtitle
    case secondaryBody
    case reference
    case speakerName
    case speakerRole
}

enum ContentProfile: String, CaseIterable, Codable, Sendable {
    case lyricMultiLine
    case lyricTitle
    case scripture
    case talkPoint
    case lowerThird
    case picture
    case generic
}

enum ThemeApplicationMode: String, CaseIterable, Codable, Sendable {
    /// Resolve at cue time when canvas is empty / lines-only; otherwise keep author canvas.
    case auto
    /// Always use stored canvas (ignore theme layout).
    case native
    /// Always resolve theme variant over payload at cue time.
    case replace
    /// Theme decor under author canvas (Phase 1: decor objects only, no slot replace).
    case decorOnly
}

struct TextStream: Hashable, Codable, Sendable {
    var text: String
    var role: ThemeSlotRole?
    var order: Int
}

struct SlideContentPayload: Hashable, Codable, Sendable {
    var profile: ContentProfile
    var textStreams: [TextStream]
    var title: String
    var alignment: String

    static func make(from slide: Slide, variantName: String? = nil) -> SlideContentPayload {
        let profile = ContentProfile.infer(from: slide, variantName: variantName)
        var streams: [TextStream] = []
        var order = 0

        func append(_ text: String, role: ThemeSlotRole?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            streams.append(TextStream(text: trimmed, role: role, order: order))
            order += 1
        }

        let canvasText = slide.canvas
            .filter(\.isTextLike)
            .filter(\.visibleOnAudience)
            .sorted { $0.transform.y < $1.transform.y }

        if !canvasText.isEmpty {
            for object in canvasText {
                let role: ThemeSlotRole? = switch object.kind {
                case .title: .title
                case .subtitle: .subtitle
                default: object.themeSlot
                }
                append(object.displayText, role: role)
            }
        } else if !slide.elements.isEmpty {
            for element in slide.elements {
                append(element.text, role: nil)
            }
        } else {
            let title = slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyLines = slide.lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            switch profile {
            case .lyricTitle:
                if !title.isEmpty { append(title, role: .title) }
                if !bodyLines.isEmpty {
                    append(bodyLines.joined(separator: "\n"), role: .subtitle)
                }
            case .talkPoint, .scripture:
                if !title.isEmpty, bodyLines.count > 1 || profile == .talkPoint {
                    append(title, role: .title)
                    for line in bodyLines { append(line, role: .primaryBody) }
                } else if !title.isEmpty, bodyLines.isEmpty {
                    append(title, role: .title)
                } else if bodyLines.count >= 2, profile == .scripture {
                    append(bodyLines[0], role: .reference)
                    append(bodyLines.dropFirst().joined(separator: "\n"), role: .primaryBody)
                } else if profile == .lowerThird {
                    append(([title] + bodyLines).filter { !$0.isEmpty }.joined(separator: "\n"), role: .primaryBody)
                } else {
                    append(bodyLines.joined(separator: "\n"), role: .primaryBody)
                }
            default:
                if !title.isEmpty, bodyLines.isEmpty {
                    append(title, role: .primaryBody)
                } else {
                    append(bodyLines.joined(separator: "\n"), role: .primaryBody)
                }
            }
        }

        if streams.isEmpty {
            append(slide.displayText, role: .primaryBody)
        }

        return SlideContentPayload(
            profile: profile,
            textStreams: streams,
            title: slide.title,
            alignment: slide.alignment
        )
    }
}

extension ContentProfile {
    static func infer(from slide: Slide, variantName: String?) -> ContentProfile {
        if let variantName {
            switch variantName {
            case "Scripture": return .scripture
            case "Lower Third": return .lowerThird
            case "Talk Point", "Sermon Point": return .talkPoint
            case "Title & Subtitle", "Title": return .lyricTitle
            case "Picture Slide": return .picture
            case "Lyric Standard", "Lyrics": return .lyricMultiLine
            default: break
            }
        }
        if slide.theme == "Scripture" { return .scripture }
        if slide.theme == "Lower Third" { return .lowerThird }
        let title = slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = slide.lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !title.isEmpty, !lines.isEmpty { return .talkPoint }
        if lines.count >= 2 { return .lyricMultiLine }
        return .generic
    }
}

struct ThemeVariantDefinition: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var profile: ContentProfile
    var layoutKind: ThemeLayoutKind
    var blueprint: [CanvasObject]

    init(
        id: UUID,
        name: String,
        profile: ContentProfile,
        layoutKind: ThemeLayoutKind = .program,
        blueprint: [CanvasObject]
    ) {
        self.id = id
        self.name = name
        self.profile = profile
        self.layoutKind = layoutKind
        self.blueprint = blueprint
    }

    func taggedBlueprint() -> [CanvasObject] {
        ThemeVariantDefinition.applySlotTags(name: name, to: blueprint)
    }

    static func applySlotTags(name: String, to objects: [CanvasObject]) -> [CanvasObject] {
        var textOrder = 0
        return objects.map { object in
            var next = object
            if next.themeSlot != nil { return next }
            switch name {
            case "Lyric Standard":
                if next.isTextLike { next.themeSlot = .primaryBody }
            case "Lower Third":
                if next.isTextLike {
                    next.themeSlot = .primaryBody
                    textOrder += 1
                }
            case "Talk Point", "Sermon Point", "Scripture":
                if next.isTextLike || next.name.localizedCaseInsensitiveContains("heading") {
                    next.themeSlot = textOrder == 0 ? (name == "Scripture" ? .reference : .title) : .primaryBody
                    textOrder += 1
                }
            case "Title & Subtitle":
                if next.kind == .title { next.themeSlot = .title }
                else if next.kind == .subtitle { next.themeSlot = .subtitle }
                else if next.isTextLike { next.themeSlot = textOrder == 0 ? .title : .subtitle; textOrder += 1 }
            case "Scripture":
                if next.isTextLike {
                    next.themeSlot = textOrder == 0 ? .reference : .primaryBody
                    textOrder += 1
                }
            default:
                if next.kind == .title { next.themeSlot = .title }
                else if next.kind == .subtitle { next.themeSlot = .subtitle }
                else if next.isTextLike { next.themeSlot = .primaryBody }
            }
            return next
        }
    }
}

enum ThemeVariantRegistry {
    private static var loadedPacks: [ProShowThemePack] = [ProShowThemePack.builtIn]
    private static var loadedProfileDefaults: [ContentProfile: UUID] = [:]

    static func configure(
        packs: [ProShowThemePack],
        profileDefaults: [ContentProfile: UUID] = [:]
    ) {
        loadedPacks = packs.isEmpty ? [ProShowThemePack.builtIn] : packs
        loadedProfileDefaults = profileDefaults
    }

    static func canonicalVariantName(forThemeName name: String) -> String? {
        switch name {
        case "Default", "Full": return nil
        case "Lyrics": return "Lyric Standard"
        case "Title": return "Title & Subtitle"
        case "Scripture": return "Scripture"
        case "Sermon Point": return "Talk Point"
        default:
            if all.contains(where: { $0.name == name }) { return name }
            return nil
        }
    }

    static var all: [ThemeVariantDefinition] {
        loadedPacks.flatMap { pack in
            pack.variants.map { $0.definition() }
        }
    }

    static var programVariants: [ThemeVariantDefinition] {
        all.filter { $0.layoutKind == .program }
    }

    static var stageVariants: [ThemeVariantDefinition] {
        all.filter { $0.layoutKind == .stage }
    }

    static var collectionNames: [String] {
        Array(Set(loadedPacks.map(\.collectionName))).sorted()
    }

    static func pack(id: UUID) -> ProShowThemePack? {
        loadedPacks.first { $0.id == id }
    }

    static func variant(id: UUID) -> ThemeVariantDefinition? {
        all.first { $0.id == id }
    }

    static func stageVariant(id: UUID) -> ThemeVariantDefinition? {
        stageVariants.first { $0.id == id }
    }

    static func defaultStageVariant() -> ThemeVariantDefinition? {
        stageVariants.first { $0.id == ActionSeedID.layoutGrid } ?? stageVariants.first
    }

    static func variant(named name: String) -> ThemeVariantDefinition? {
        let canonical = canonicalVariantName(forThemeName: name) ?? name
        return all.first { $0.name == canonical }
    }

    static func variant(for slide: Slide) -> ThemeVariantDefinition? {
        if let id = slide.themeVariantID, let match = variant(id: id) { return match }
        if let named = variant(named: slide.theme) { return named }
        if slide.themeApplication == .auto || slide.theme == "Default" {
            let profile = ContentProfile.infer(from: slide, variantName: nil)
            if let defaultID = loadedProfileDefaults[profile], let match = variant(id: defaultID) {
                return match
            }
        }
        return nil
    }

    static func audienceLook(forThemeName name: String) -> AudienceLookConfig? {
        if let variant = variant(named: name),
           let record = loadedPacks.flatMap(\.variants).first(where: { $0.id == variant.id }),
           let lookName = record.audienceLookName {
            return audienceLook(named: lookName)
        }
        return audienceLook(named: name)
    }

    static func audienceLook(named name: String) -> AudienceLookConfig? {
        switch name {
        case "Scripture": return .alphaKey
        case "Lyrics", "Lyric Standard": return .slideAndMedia
        default: return nil
        }
    }
}
