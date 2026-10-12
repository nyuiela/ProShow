import Foundation

/// Vocal delivery style for Caption-with-Intention kinetic typography.
/// Add new cases + tag aliases + keyframe tracks without touching the scroll engine.
enum VocalStyle: String, CaseIterable, Equatable, Sendable, Codable {
    case normal
    // Energy & volume
    case shout
    case whisper
    case fast
    case stretch
    // Emotion & tone
    case tremble
    case heavy
    case bounce
    case slant
    // Rhythm & breath
    case gasp
    case stutter
    case melody
    case robotic

    /// Markup aliases → style. Extend this table to grow the library.
    static let tagAliases: [String: VocalStyle] = [
        "SHOUT": .shout, "LOUD": .shout, "BANG": .shout,
        "WHISPER": .whisper, "SOFT": .whisper, "SECRET": .whisper,
        "FAST": .fast, "QUICK": .fast, "DROP": .fast,
        "STRETCH": .stretch, "LONG": .stretch, "DRAWL": .stretch,
        "TREMBLE": .tremble, "SHAKE": .tremble, "NERVOUS": .tremble,
        "HEAVY": .heavy, "GRAVE": .heavy, "SERIOUS": .heavy,
        "BOUNCE": .bounce, "JOY": .bounce, "EXCITED": .bounce,
        "SLANT": .slant, "SARCASTIC": .slant, "MOCK": .slant,
        "GASP": .gasp, "BREATH": .gasp,
        "STUTTER": .stutter, "HESITATE": .stutter,
        "MELODY": .melody, "SING": .melody,
        "ROBOT": .robotic, "ROBOTIC": .robotic, "FLAT": .robotic,
        "NORMAL": .normal, "RESET": .normal
    ]

    static func resolve(tag name: String) -> VocalStyle? {
        tagAliases[name.uppercased()]
    }

    /// Multiplier applied to base word hold time.
    var durationScale: Double {
        switch self {
        case .stretch: return 1.65
        case .fast: return 0.55
        case .gasp: return 0.7
        case .stutter: return 1.25
        case .melody: return 1.35
        case .heavy: return 1.2
        case .whisper: return 1.1
        default: return 1.0
        }
    }

    var prefersHeavyWeight: Bool {
        self == .shout || self == .heavy
    }

    var prefersLightWeight: Bool {
        self == .whisper
    }

    var prefersItalic: Bool {
        self == .whisper || self == .slant
    }

    var prefersMonospaced: Bool {
        self == .robotic
    }

    var prefersRounded: Bool {
        self == .shout || self == .bounce || self == .melody
    }
}
