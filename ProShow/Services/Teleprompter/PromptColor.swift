import SwiftUI

/// CueLog teleprompter color. Separate from the studio chroma `RGBAColor`.
struct PromptColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    static let white = PromptColor(red: 1, green: 1, blue: 1, opacity: 1)
    static let black = PromptColor(red: 0, green: 0, blue: 0, opacity: 1)
    /// Default kinetic active-word highlight (neon yellow).
    static let neonHighlight = PromptColor(red: 1, green: 0.92, blue: 0.2, opacity: 1)

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }

    var hexString: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
        opacity = 1
    }
}
