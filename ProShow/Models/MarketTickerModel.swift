import Foundation
#if os(macOS)
import AppKit
#endif

enum DeltaDirection: String, Codable, Sendable {
    case positive
    case negative
    case neutral
}

struct MarketTickerItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var symbol: String
    var price: Double
    var changePercent24h: Double

    init(
        id: String,
        symbol: String,
        price: Double,
        changePercent24h: Double
    ) {
        self.id = id
        self.symbol = symbol
        self.price = price
        self.changePercent24h = changePercent24h
    }

    var direction: DeltaDirection {
        if changePercent24h > 0.001 { return .positive }
        if changePercent24h < -0.001 { return .negative }
        return .neutral
    }
}

struct TickerColorConfig: Codable, Equatable, Sendable {
    var upColorHex: String = "#34C759"
    var downColorHex: String = "#FF3B30"
    var neutralColorHex: String = "#999999"
    var textColorHex: String = "#FFFFFF"

    #if os(macOS)
    var upColor: NSColor { NSColor(marketHex: upColorHex) ?? .systemGreen }
    var downColor: NSColor { NSColor(marketHex: downColorHex) ?? .systemRed }
    var neutralColor: NSColor { NSColor(marketHex: neutralColorHex) ?? .secondaryLabelColor }
    var textColor: NSColor { NSColor(marketHex: textColorHex) ?? .white }
    #endif
}

#if os(macOS)
extension NSColor {
    convenience init?(marketHex hex: String) {
        var cString = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cString.hasPrefix("#") { cString.removeFirst() }
        guard cString.count == 6, let rgbValue = UInt64(cString, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
#endif
