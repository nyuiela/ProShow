import Foundation

enum ThemeOutputTarget: Hashable, Codable, Sendable {
    case outputScreen(id: String)
    case streamDestination(id: String)
    case mapPlaceholder(id: String)
}

enum ThemeStreamBinding {
    /// Single encode path — stream / ISO theme override in project settings.
    static let programDestinationID = "program"
}

enum ThemeLayoutKind: String, Codable, CaseIterable, Sendable {
    /// Program / audience slide themes (resolved at cue time).
    case program
    /// Stage confidence monitor layouts (live tokens).
    case stage
}

struct ThemeOutputBinding: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var target: ThemeOutputTarget
    var variantID: UUID
    var lookName: String?

    init(id: UUID = UUID(), target: ThemeOutputTarget, variantID: UUID, lookName: String? = nil) {
        self.id = id
        self.target = target
        self.variantID = variantID
        self.lookName = lookName
    }
}

struct ThemeProjectSettings: Hashable, Codable, Sendable {
    var activePackID: UUID?
    /// `ContentProfile.rawValue` → default variant id for new / auto-themed slides.
    var profileDefaults: [String: UUID]
    var outputBindings: [ThemeOutputBinding]
    /// Active stage layout variant from the theme pack (`layoutKind: .stage`).
    var activeStageVariantID: UUID?

    init(
        activePackID: UUID? = ProShowThemePack.builtInID,
        profileDefaults: [String: UUID] = [:],
        outputBindings: [ThemeOutputBinding] = [],
        activeStageVariantID: UUID? = ActionSeedID.layoutGrid
    ) {
        self.activePackID = activePackID
        self.profileDefaults = profileDefaults
        self.outputBindings = outputBindings
        self.activeStageVariantID = activeStageVariantID
    }

    static let `default` = ThemeProjectSettings()

    func defaultVariantID(for profile: ContentProfile) -> UUID? {
        profileDefaults[profile.rawValue]
    }

    mutating func setDefault(_ variantID: UUID?, for profile: ContentProfile) {
        if let variantID {
            profileDefaults[profile.rawValue] = variantID
        } else {
            profileDefaults.removeValue(forKey: profile.rawValue)
        }
    }

    func variantID(for target: ThemeOutputTarget) -> UUID? {
        outputBindings.first(where: { $0.target == target })?.variantID
    }

    mutating func setBinding(_ variantID: UUID?, for target: ThemeOutputTarget) {
        outputBindings.removeAll { $0.target == target }
        if let variantID {
            outputBindings.append(ThemeOutputBinding(target: target, variantID: variantID))
        }
    }

    enum CodingKeys: String, CodingKey {
        case activePackID, profileDefaults, outputBindings, activeStageVariantID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activePackID = try container.decodeIfPresent(UUID.self, forKey: .activePackID)
        profileDefaults = try container.decodeIfPresent([String: UUID].self, forKey: .profileDefaults) ?? [:]
        outputBindings = try container.decodeIfPresent([ThemeOutputBinding].self, forKey: .outputBindings) ?? []
        activeStageVariantID = try container.decodeIfPresent(UUID.self, forKey: .activeStageVariantID)
            ?? ActionSeedID.layoutGrid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(activePackID, forKey: .activePackID)
        try container.encode(profileDefaults, forKey: .profileDefaults)
        try container.encode(outputBindings, forKey: .outputBindings)
        try container.encodeIfPresent(activeStageVariantID, forKey: .activeStageVariantID)
    }
}

struct ThemeVariantRecord: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var profile: ContentProfile
    var layoutKind: ThemeLayoutKind
    var objects: [CanvasObject]
    var audienceLookName: String?

    init(
        id: UUID,
        name: String,
        profile: ContentProfile,
        layoutKind: ThemeLayoutKind = .program,
        objects: [CanvasObject],
        audienceLookName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.profile = profile
        self.layoutKind = layoutKind
        self.objects = objects
        self.audienceLookName = audienceLookName
    }

    enum CodingKeys: String, CodingKey {
        case id, name, profile, layoutKind, objects, audienceLookName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        profile = try container.decodeIfPresent(ContentProfile.self, forKey: .profile) ?? .generic
        layoutKind = try container.decodeIfPresent(ThemeLayoutKind.self, forKey: .layoutKind) ?? .program
        objects = try container.decodeIfPresent([CanvasObject].self, forKey: .objects) ?? []
        audienceLookName = try container.decodeIfPresent(String.self, forKey: .audienceLookName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(profile, forKey: .profile)
        try container.encode(layoutKind, forKey: .layoutKind)
        try container.encode(objects, forKey: .objects)
        try container.encodeIfPresent(audienceLookName, forKey: .audienceLookName)
    }

    func definition() -> ThemeVariantDefinition {
        ThemeVariantDefinition(id: id, name: name, profile: profile, layoutKind: layoutKind, blueprint: objects)
    }
}

struct ProShowThemePack: Identifiable, Hashable, Codable, Sendable {
    static let schemaVersion = "1.1.0"
    static let builtInID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!

    var id: UUID
    var name: String
    var collectionName: String
    var schemaVersion: String
    var variants: [ThemeVariantRecord]

    init(
        id: UUID = UUID(),
        name: String,
        collectionName: String,
        schemaVersion: String = ProShowThemePack.schemaVersion,
        variants: [ThemeVariantRecord] = []
    ) {
        self.id = id
        self.name = name
        self.collectionName = collectionName
        self.schemaVersion = schemaVersion
        self.variants = variants
    }

    static var builtIn: ProShowThemePack {
        ProShowThemePack(
            id: builtInID,
            name: "ProShow Built-In",
            collectionName: "Default",
            variants: programBuiltInVariants + stageBuiltInVariants
        )
    }

    private static var programBuiltInVariants: [ThemeVariantRecord] {
        [
            variantRecord(
                id: UUID(uuidString: "00000001-0001-4000-8000-000000000001")!,
                name: "Lyric Standard",
                profile: .lyricMultiLine,
                objects: DefaultSeedData.themeObjects(for: "Lyric Standard"),
                look: "Lyrics"
            ),
            variantRecord(
                id: UUID(uuidString: "00000001-0001-4000-8000-000000000002")!,
                name: "Lower Third",
                profile: .lowerThird,
                objects: DefaultSeedData.themeObjects(for: "Lower Third")
            ),
            variantRecord(
                id: UUID(uuidString: "00000001-0001-4000-8000-000000000003")!,
                name: "Talk Point",
                profile: .talkPoint,
                objects: DefaultSeedData.themeObjects(for: "Talk Point")
            ),
            variantRecord(
                id: UUID(uuidString: "00000001-0001-4000-8000-000000000004")!,
                name: "Title & Subtitle",
                profile: .lyricTitle,
                objects: DefaultSeedData.themeObjects(for: "Title & Subtitle")
            ),
            variantRecord(
                id: UUID(uuidString: "00000001-0001-4000-8000-000000000005")!,
                name: "Scripture",
                profile: .scripture,
                objects: DefaultSeedData.themeObjects(for: "Scripture"),
                look: "Scripture"
            ),
            variantRecord(
                id: UUID(uuidString: "00000001-0001-4000-8000-000000000006")!,
                name: "Picture Slide",
                profile: .picture,
                objects: DefaultSeedData.themeObjects(for: "Picture Slide")
            ),
        ]
    }

    private static var stageBuiltInVariants: [ThemeVariantRecord] {
        StageLayoutPreset.all.map { preset in
            variantRecord(
                id: preset.id,
                name: preset.name,
                profile: .generic,
                layoutKind: .stage,
                objects: DefaultSeedData.stageLayoutObjects(for: preset)
            )
        }
    }

    private static func variantRecord(
        id: UUID,
        name: String,
        profile: ContentProfile,
        layoutKind: ThemeLayoutKind = .program,
        objects: [CanvasObject],
        look: String? = nil
    ) -> ThemeVariantRecord {
        ThemeVariantRecord(
            id: id,
            name: name,
            profile: profile,
            layoutKind: layoutKind,
            objects: objects,
            audienceLookName: look
        )
    }
}
