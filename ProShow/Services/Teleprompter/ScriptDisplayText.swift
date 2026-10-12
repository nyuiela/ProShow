import Foundation

/// Scroll-mode script text. Tags are consumed as typography and never shown literally.
enum ScriptDisplayText {
    /// Plain string with all `[TAG]` markup removed (and pause units dropped).
    /// Script newlines are preserved as hard line breaks.
    static func plain(from body: String, includeLongPauseMarkers: Bool = false) -> String {
        let words = ScriptTokenizer.tokenize(body, baseWPM: 150).filter { !$0.isPauseOnly || (includeLongPauseMarkers && $0.isLongPause) }
        var out = ""
        for (index, word) in words.enumerated() {
            out += word.isLongPause ? "[\(word.longPauseLabel)]" : word.text
            if index < words.count - 1 {
                if word.lineBreaksAfter > 0 {
                    out += String(repeating: "\n", count: min(word.lineBreaksAfter, 2))
                } else {
                    out += " "
                }
            }
        }
        return out
    }
}
