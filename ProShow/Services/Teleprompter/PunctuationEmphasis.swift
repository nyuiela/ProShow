import Foundation

/// Trailing punctuation on a spoken token — drives automatic kinetic emphasis.
enum PunctuationEmphasis: Equatable, Sendable {
    case none
    case comma
    case semicolon
    case colon
    case period
    case question
    case exclamation
    case ellipsis
    case emDash

    /// Strongest trailing mark wins (ellipsis before single `.`).
    static func trailing(in text: String) -> PunctuationEmphasis {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") {
            return .ellipsis
        }
        if trimmed.hasSuffix("—") || trimmed.hasSuffix("–") || trimmed.hasSuffix("--") {
            return .emDash
        }
        guard let last = trimmed.last else { return .none }
        switch last {
        case ",": return .comma
        case ";": return .semicolon
        case ":": return .colon
        case ".": return .period
        case "?": return .question
        case "!": return .exclamation
        default: return .none
        }
    }

    var glyph: String? {
        switch self {
        case .none: return nil
        case .comma: return ","
        case .semicolon: return ";"
        case .colon: return ":"
        case .period: return "."
        case .question: return "?"
        case .exclamation: return "!"
        case .ellipsis: return "…"
        case .emDash: return "—"
        }
    }

    /// Characters to strip from the word stem when rendering glyph separately.
    var stripSuffixes: [String] {
        switch self {
        case .none: return []
        case .comma: return [","]
        case .semicolon: return [";"]
        case .colon: return [":"]
        case .period: return ["."]
        case .question: return ["?"]
        case .exclamation: return ["!"]
        case .ellipsis: return ["...", "…"]
        case .emDash: return ["—", "–", "--"]
        }
    }

    // MARK: - Animation timeline (X)

    /// Together-rise before the mid-pose hold.
    var riseSeconds: TimeInterval {
        guard self != .none else { return 0 }
        return 0.16
    }

    /// Mid-pose hold before the mark flourish.
    var holdSeconds: TimeInterval {
        guard self != .none else { return 0 }
        return 0.14
    }

    /// Mark-only flourish length.
    var flourishSeconds: TimeInterval {
        switch self {
        case .none: return 0
        case .ellipsis: return 0.55
        case .question, .exclamation: return 0.42
        case .comma, .semicolon: return 0.30
        case .period, .colon, .emDash: return 0.36
        }
    }

    /// Stem settle after the flourish.
    var settleSeconds: TimeInterval {
        guard self != .none else { return 0 }
        return 0.20
    }

    /// Full punctuation flourish sequence length **X** (rise → hold → flourish → settle).
    var animationDuration: TimeInterval {
        guard self != .none else { return 0 }
        return riseSeconds + holdSeconds + flourishSeconds + settleSeconds
    }

    /// Punctuation dwell baked into the word clock: animation **X**, then wait `max(0, N − X)`.
    /// Equals `max(N, X)` when motion is on; plain **N** when motion is off.
    static func dwellSeconds(
        holdN: TimeInterval,
        emphasis: PunctuationEmphasis,
        motionEnabled: Bool
    ) -> TimeInterval {
        guard emphasis != .none else { return 0 }
        let n = max(0, holdN)
        guard motionEnabled else { return n }
        return max(n, emphasis.animationDuration)
    }
}

extension SpokenWord {
    var punctuationEmphasis: PunctuationEmphasis {
        guard !isPauseOnly else { return .none }
        return .trailing(in: text)
    }

    /// Word body without the trailing punctuation glyph (for split render).
    var displayStem: String {
        let mark = punctuationEmphasis
        guard mark != .none else { return text }
        var stem = text
        for suffix in mark.stripSuffixes {
            if stem.hasSuffix(suffix) {
                stem = String(stem.dropLast(suffix.count))
                break
            }
        }
        return stem.isEmpty ? text : stem
    }
}
