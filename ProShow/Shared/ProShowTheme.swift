import SwiftUI

/// Visual tokens matched to the ProPresenter-class operator desk reference.
enum ProShowTheme {
    /// Deep charcoal canvas (~#1A1A1A)
    static let canvas = Color(red: 0.102, green: 0.102, blue: 0.102)
    /// Raised panel (~#222)
    static let panel = Color(red: 0.133, green: 0.133, blue: 0.137)
    /// Nested well / list row (~#2A2A2C)
    static let well = Color(red: 0.165, green: 0.165, blue: 0.170)
    /// Hairline dividers
    static let hairline = Color.white.opacity(0.08)
    /// Selection / active tab blue
    static let accent = Color(red: 0.22, green: 0.55, blue: 0.95)
    /// Preview outline blue
    static let previewBlue = accent
    /// Audience / Stage “on” lamps
    static let statusOn = Color(red: 0.30, green: 0.82, blue: 0.40)
    static let statusOff = Color.white.opacity(0.25)
    static let liveRed = Color(red: 0.90, green: 0.28, blue: 0.28)
    static let stageBlack = Color.black
    static let stageInk = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let lyricWhite = Color.white.opacity(0.96)
    static let toolbarIcon = Color.white.opacity(0.78)
    static let secondaryLabel = Color.white.opacity(0.55)

    /// Legacy aliases used by earlier views
    static let operatorCanvas = canvas
    static let operatorPanel = panel

    static func groupColor(_ hex: String) -> Color {
        Color(hex: hex) ?? accent
    }
}

extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

enum DeskPaneDivider {
    static let width: CGFloat = 1
}
