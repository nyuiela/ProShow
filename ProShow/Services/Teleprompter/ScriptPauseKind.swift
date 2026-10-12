import Foundation

/// Kind of scripted silence unit inserted by markup.
enum ScriptPauseKind: String, Equatable, Codable, Sendable {
    /// Not a pause unit.
    case none
    /// Short beat — `[PAUSE]` (or short timed).
    case brief
    /// Action / breath hold — `[LONGPAUSE]`, `[LONG PAUSE]`, or longer timed `[PAUSE:Ns]`.
    case long
}
