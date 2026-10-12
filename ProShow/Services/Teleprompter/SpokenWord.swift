import Foundation

/// One displayable (or silent pause) unit in the kinetic spillout stream.
struct SpokenWord: Equatable, Identifiable, Sendable {
    let id: UUID
    /// Visible token; empty when this unit is a pure pause (`[PAUSE]` / `[LONGPAUSE]`).
    let text: String
    let characterCount: Int
    /// Extra hold after this word finishes (punctuation / pause tags).
    let punctuationPause: TimeInterval
    /// Caption-with-Intention delivery style for this token.
    let vocalStyle: VocalStyle
    /// Base hold derived from WPM × character weight (before punctuation / style scale).
    let baseDuration: TimeInterval
    /// Hard line breaks from the script after this token (`1` = newline, `2+` = blank line).
    let lineBreaksAfter: Int
    /// Configurable hold for those hard breaks (from `ScriptPacing`) — not a `[PAUSE]`.
    let lineBreakHold: TimeInterval
    /// Brief vs long scripted pause (only meaningful when `isPauseOnly`).
    let pauseKind: ScriptPauseKind

    var isPauseOnly: Bool { text.isEmpty }

    var isLongPause: Bool { isPauseOnly && pauseKind == .long }

    var isBriefPause: Bool { isPauseOnly && pauseKind == .brief }

    var forcesLineBreakAfter: Bool { lineBreaksAfter > 0 }

    /// True when `[JOIN]` / underscore glue produced a multi-word display token.
    var isJoinedPhrase: Bool {
        text.contains { $0.isWhitespace }
    }

    /// Space-separated speakable parts inside a join (or `[text]` alone).
    var spokenParts: [String] {
        let parts = text.split { $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
        return parts.isEmpty ? (text.isEmpty ? [] : [text]) : parts
    }

    /// Label shown in the kinetic panel for long-pause markers.
    var longPauseLabel: String {
        let seconds = max(1, Int(punctuationPause.rounded()))
        return "Long pause · \(seconds)s"
    }

    var totalDuration: TimeInterval {
        if isPauseOnly {
            return max(0.05, punctuationPause + lineBreakHold)
        }
        let styled = baseDuration * vocalStyle.durationScale
        return max(0.05, styled + punctuationPause + lineBreakHold)
    }

    init(
        id: UUID = UUID(),
        text: String,
        characterCount: Int? = nil,
        punctuationPause: TimeInterval = 0,
        vocalStyle: VocalStyle = .normal,
        baseDuration: TimeInterval,
        lineBreaksAfter: Int = 0,
        lineBreakHold: TimeInterval = 0,
        pauseKind: ScriptPauseKind = .none
    ) {
        self.id = id
        self.text = text
        self.characterCount = characterCount ?? text.count
        self.punctuationPause = punctuationPause
        self.vocalStyle = vocalStyle
        self.baseDuration = baseDuration
        self.lineBreaksAfter = max(0, lineBreaksAfter)
        self.lineBreakHold = max(0, lineBreakHold)
        self.pauseKind = text.isEmpty ? (pauseKind == .none ? .brief : pauseKind) : .none
    }
}
