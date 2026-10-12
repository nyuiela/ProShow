import SwiftUI

/// Tahoe / iOS 26 desk palette. Glass is chrome-only; these fills are the opaque content layer.
public struct ThemeTokens {
    /// Opaque window field `#121214`.
    public static let bgWindow = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)
    public static let bgVoid = Color.black
    /// Opaque elevated pane `#1B1B1F`.
    public static let bgElevated = Color(red: 27 / 255, green: 27 / 255, blue: 31 / 255)
    public static let bgPanel = bgElevated
    /// Opaque well `#25252A` for cards sitting on glass or panel.
    public static let bgControl = Color(red: 37 / 255, green: 37 / 255, blue: 42 / 255)
    public static let bgHover = Color.white.opacity(0.08)

    public static let borderSubtle = Color.white.opacity(0.10)
    public static let borderFocus = accentSystem
    public static let dividerLine = Color.white.opacity(0.10)

    /// Steel blue `#6B9FE0`. Asset catalog `AccentColor` is the source of truth for system chrome.
    public static let accentSystem = Color("AccentColor")
    public static let accentCyan = accentSystem

    /// Live tally `#D44538`.
    public static let programRed = Color(red: 212 / 255, green: 69 / 255, blue: 56 / 255)
    public static let previewGreen = Color(red: 0.20, green: 0.78, blue: 0.35)
    /// On-air amber `#C9A24A`.
    public static let warningAmber = Color(red: 201 / 255, green: 162 / 255, blue: 74 / 255)
    /// Sandbox `#E07A2F`.
    public static let sandboxOrange = Color(red: 224 / 255, green: 122 / 255, blue: 47 / 255)

    public static let selectionFill = accentSystem.opacity(0.18)

    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.60)
    public static let textMuted = Color.white.opacity(0.35)
}

/// Control sizing — compact inspector density with native macOS tiers.
enum DeskControlSize {
    case mini
    case compact
    case regular
    case hero

    var height: CGFloat {
        switch self {
        case .mini: 24
        case .compact: 22
        case .regular: 28
        case .hero: 32
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .mini: 6
        case .compact: 4
        case .regular: 6
        case .hero: 8
        }
    }

    var iconFont: Font {
        switch self {
        case .mini: .system(size: 11, weight: .medium)
        case .compact: .system(size: 11, weight: .medium)
        case .regular: .system(size: 12, weight: .medium)
        case .hero: .system(size: 13, weight: .bold)
        }
    }

    var labelFont: Font {
        switch self {
        case .mini: .system(size: 11, weight: .medium)
        case .compact: .system(size: 11, weight: .medium)
        case .regular: .system(size: 12, weight: .semibold)
        case .hero: .system(size: 13, weight: .bold)
        }
    }
}

enum DeskPaneElevation {
    case window
    case sidebar
    case inspector
    case workspace
}

/// Which layer a surface belongs to. Feature views pick a role, never a material.
enum DeskSurface {
    /// Control / navigation layer. System or custom Liquid Glass.
    case chromeGlass
    /// Opaque graphite content (grids, rundown, inspector cards, audio).
    case content
}

extension View {
    func deskRowDivider() -> some View {
        Divider().overlay(ThemeTokens.dividerLine)
    }
}
