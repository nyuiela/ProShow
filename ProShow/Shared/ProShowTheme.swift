import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Control-room tokens. Liquid Glass is chrome only; content stays opaque graphite.
/// The 16:9 program is the only luminous surface.
enum ProShowTheme {
    /// Opaque window field `#121214`.
    static let canvas = ThemeTokens.bgWindow
    /// Opaque pane `#1B1B1F`.
    static let panel = ThemeTokens.bgPanel
    static let elevatedPane = ThemeTokens.bgElevated
    static let titlebar = ThemeTokens.bgWindow
    /// Opaque card / control well `#25252A`.
    static let well = ThemeTokens.bgControl
    static let hairline = ThemeTokens.borderSubtle
    static let accent = ThemeTokens.accentSystem
    static let selectionFill = ThemeTokens.selectionFill
    static let previewBlue = ThemeTokens.accentSystem
    static let statusOn = ThemeTokens.warningAmber
    static let statusOff = Color.white.opacity(0.22)
    static let liveRed = ThemeTokens.programRed
    static let sandboxOrange = ThemeTokens.sandboxOrange
    static let meterSafe = ThemeTokens.previewGreen
    static let meterWarn = ThemeTokens.warningAmber
    static let stageBlack = Color.black
    static let stageInk = ThemeTokens.bgVoid
    static let lyricWhite = ThemeTokens.textPrimary.opacity(0.96)
    static let toolbarIcon = ThemeTokens.textPrimary.opacity(0.82)
    static let secondaryLabel = ThemeTokens.textSecondary
    static let primaryLabel = ThemeTokens.textPrimary.opacity(0.94)

    static let operatorCanvas = canvas
    static let operatorPanel = panel

    static func groupColor(_ hex: String) -> Color {
        Color(hex: hex) ?? accent
    }
}

enum DeskType {
    static let display = Font.system(size: 22, weight: .semibold, design: .default)
    static let title = Font.system(size: 15, weight: .semibold, design: .default)
    static let body = Font.system(size: 13, weight: .regular, design: .default)
    static let bodyEmph = Font.system(size: 13, weight: .semibold, design: .default)
    static let meta = Font.system(size: 11, weight: .medium, design: .default)
    static let micro = Font.system(size: 10, weight: .medium, design: .default)
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
}

enum DeskSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

enum DeskRadius {
    static let control: CGFloat = 6
    static let card: CGFloat = 8
    static let sheet: CGFloat = 10
    /// Floating toolbars & glass capsules.
    static let floatingToolbar: CGFloat = 12
}

enum DeskLayout {
    static let windowWidth: CGFloat = 1440
    static let windowHeight: CGFloat = 900
    static let sidebar: CGFloat = 240
    static var sidebarMin: CGFloat { WorkspaceTitleGroupMetrics.minimumSidebarWidth }
    static let sidebarMax: CGFloat = 320
    static let inspector: CGFloat = 300
    /// Right pane: column = monitor box + 74 (insets 16, container padding 16, rail 36, gap 6).
    /// Max keeps a 16:9 monitor no taller than the 220 pt tab rail (391 x 220). Min gives a 326 x 184 monitor.
    static let inspectorMin: CGFloat = 400
    static let inspectorMax: CGFloat = 465
    static let mediaDrawer: CGFloat = 248
    static let mediaSource: CGFloat = 228
    static let toolbar: CGFloat = 56
    static let hit: CGFloat = DeskControlSize.regular.height
    static let hitPhone: CGFloat = 44
    static let programAspect: CGFloat = 16 / 9
    /// Horizontal action-inspector tab strip (Layers, Audio, …).
    static let actionInspectorTabBarHeight: CGFloat = 32
    /// Canvas composition list inside the Layers tab (scrolls above this).
    static let compositionLayersListMaxHeight: CGFloat = 220
    /// Fallback when column height is unknown; live split uses `DeskStudioGeometry.inspectorPaneLimits`.
    static let inspectorPaneDefaultHeight: CGFloat = 280
    static let inspectorPaneMinBottom: CGFloat = 160
    static let inspectorPaneMinTop: CGFloat = 200
    /// Upper bound when geometry cannot be measured; dynamic max is usually higher on tall windows.
    static let inspectorPaneMaxHeight: CGFloat = 560
}

enum InspectorPreviewLayout {
    static let horizontalInset: CGFloat = 8
    static let stripWidth: CGFloat = 36
    static let stripGap: CGFloat = 6
    static let footerHeight: CGFloat = 56
    static let monitorTopPadding: CGFloat = 8
    /// Scrubber, timecode, and transport controls under the monitor.
    static let transportBlockHeight: CGFloat = 100
    static let meterWidth: CGFloat = 10
    static let meterInset: CGFloat = 6
    /// Matches `ClearStripAction.allCases` count × standard hit target.
    private static let clearStripButtonCount: CGFloat = 7
    private static let clearStripSpacing: CGFloat = 4

    static func previewBoxWidth(columnWidth: CGFloat) -> CGFloat {
        max(0, columnWidth - horizontalInset * 2 - stripWidth - stripGap)
    }

    /// Width-first 16:9 (or program) fit — preview row height follows this, not the full split pane.
    static func fittedProgramSize(boxWidth: CGFloat, programAspect: CGFloat) -> CGSize {
        guard boxWidth > 1, programAspect > 0.01 else {
            return CGSize(width: max(0, boxWidth), height: 120)
        }
        let height = boxWidth / programAspect
        return CGSize(width: boxWidth, height: height)
    }

    /// Stream 16:9 and Phone 9:16 share one row height; widths follow each aspect.
    static func fittedStreamAndPhone(
        boxWidth: CGFloat,
        streamAspect: CGFloat,
        phoneAspect: CGFloat = 9.0 / 16.0,
        gap: CGFloat = 6
    ) -> (stream: CGSize, phone: CGSize) {
        guard boxWidth > 1, streamAspect > 0.01, phoneAspect > 0.01 else {
            let stream = fittedProgramSize(boxWidth: boxWidth, programAspect: max(streamAspect, 0.01))
            return (stream, CGSize(width: stream.height * phoneAspect, height: stream.height))
        }
        let height = (boxWidth - gap) / (streamAspect + phoneAspect)
        return (
            CGSize(width: height * streamAspect, height: height),
            CGSize(width: height * phoneAspect, height: height)
        )
    }

    static var clearStripMinHeight: CGFloat {
        clearStripButtonCount * DeskLayout.hit + clearStripSpacing * max(0, clearStripButtonCount - 1)
    }

    static func monitorRowHeight(columnWidth: CGFloat, programAspect: CGFloat) -> CGFloat {
        let fitted = fittedProgramSize(
            boxWidth: previewBoxWidth(columnWidth: columnWidth),
            programAspect: programAspect
        )
        return max(fitted.height, clearStripMinHeight)
    }

    static let transportGap: CGFloat = 8

    static func monitorChromeHeight(columnWidth: CGFloat, programAspect: CGFloat) -> CGFloat {
        monitorTopPadding
            + monitorRowHeight(columnWidth: columnWidth, programAspect: programAspect)
            + transportGap
            + transportBlockHeight
            + footerHeight
    }

    static func idealTopPaneHeight(columnWidth: CGFloat, programAspect: CGFloat) -> CGFloat {
        monitorChromeHeight(columnWidth: columnWidth, programAspect: programAspect)
    }
}

enum DeskMotion {
    static let press: Double = 0.12
    static let toggle: Double = 0.22
    static let panel: Double = 0.28
    static let easeOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: press)
}

enum DeskPaneDivider {
    static let width: CGFloat = 1
}

extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        if cleaned.count == 6, let value = UInt64(cleaned, radix: 16) {
            let r = Double((value >> 16) & 0xFF) / 255
            let g = Double((value >> 8) & 0xFF) / 255
            let b = Double(value & 0xFF) / 255
            self.init(red: r, green: g, blue: b)
            return
        }
        if cleaned.count == 8, let value = UInt64(cleaned, radix: 16) {
            let a = Double((value >> 24) & 0xFF) / 255
            let r = Double((value >> 16) & 0xFF) / 255
            let g = Double((value >> 8) & 0xFF) / 255
            let b = Double(value & 0xFF) / 255
            self.init(red: r, green: g, blue: b, opacity: a)
            return
        }
        return nil
    }

    func hexString(includeAlpha: Bool = false) -> String {
        #if os(macOS)
        let converted = NSColor(self).usingColorSpace(.sRGB)
        let r = converted?.redComponent ?? 1
        let g = converted?.greenComponent ?? 1
        let b = converted?.blueComponent ?? 1
        let a = converted?.alphaComponent ?? 1
        #else
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        if includeAlpha {
            return String(format: "#%02X%02X%02X%02X", Int(a * 255), Int(r * 255), Int(g * 255), Int(b * 255))
        }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
