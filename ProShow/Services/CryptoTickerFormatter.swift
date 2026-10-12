import Foundation
import CoreText
#if os(macOS)
import AppKit
#endif

#if os(macOS)
enum CryptoTickerFormatter {
    static func makeTickerAttributedString(
        items: [MarketTickerItem],
        object: CanvasObject,
        scale: CGFloat,
        colorConfig: TickerColorConfig,
        spacingSeparator: String = "   •   "
    ) -> NSAttributedString {
        let base = SlideTextAttributes.from(object: object, text: " ", scale: scale)
        let font = base.font
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let bodyColor = base.textColor
        let separatorColor = bodyColor.withAlphaComponent(0.45)

        let result = NSMutableAttributedString()
        let numFormatter = NumberFormatter()
        numFormatter.numberStyle = .currency
        numFormatter.currencySymbol = "$"
        numFormatter.maximumFractionDigits = priceFractionDigits(for: items)

        for (index, item) in items.enumerated() {
            result.append(TextAttributeConverter.attributedRun(
                text: "\(item.symbol) ",
                baseStyle: base,
                font: boldFont,
                foregroundColor: bodyColor
            ))

            numFormatter.maximumFractionDigits = priceFractionDigits(for: item.price)
            let priceStr = numFormatter.string(from: NSNumber(value: item.price)) ?? "$\(item.price)"
            result.append(TextAttributeConverter.attributedRun(
                text: "\(priceStr) ",
                baseStyle: base,
                foregroundColor: bodyColor
            ))

            let deltaColor: NSColor
            let arrowPrefix: String
            switch item.direction {
            case .positive:
                deltaColor = colorConfig.upColor
                arrowPrefix = "▲ +"
            case .negative:
                deltaColor = colorConfig.downColor
                arrowPrefix = "▼ "
            case .neutral:
                deltaColor = colorConfig.neutralColor
                arrowPrefix = " "
            }

            let percentStr = String(format: "%@%.2f%%", arrowPrefix, item.changePercent24h)
            result.append(TextAttributeConverter.attributedRun(
                text: percentStr,
                baseStyle: base,
                font: boldFont,
                foregroundColor: deltaColor
            ))

            if index < items.count - 1 {
                result.append(TextAttributeConverter.attributedRun(
                    text: spacingSeparator,
                    baseStyle: base,
                    foregroundColor: separatorColor
                ))
            }
        }

        return result
    }

    /// Legacy entry for tests — uses typography color only (no object stroke/shadow).
    static func makeTickerAttributedString(
        items: [MarketTickerItem],
        font: NSFont,
        colorConfig: TickerColorConfig,
        spacingSeparator: String = "   •   "
    ) -> NSAttributedString {
        let base = SlideTextAttributes(
            text: " ",
            font: font,
            textColor: colorConfig.textColor,
            strokeColor: nil,
            strokeWidth: 0,
            shadowColor: nil,
            shadowRadius: 0,
            shadowOffset: .zero,
            kerning: 0,
            underline: false,
            strikethrough: false,
            backgroundColor: nil
        )
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let result = NSMutableAttributedString()
        let numFormatter = NumberFormatter()
        numFormatter.numberStyle = .currency
        numFormatter.currencySymbol = "$"
        numFormatter.maximumFractionDigits = priceFractionDigits(for: items)

        for (index, item) in items.enumerated() {
            result.append(TextAttributeConverter.attributedRun(
                text: "\(item.symbol) ",
                baseStyle: base,
                font: boldFont,
                foregroundColor: colorConfig.textColor
            ))
            numFormatter.maximumFractionDigits = priceFractionDigits(for: item.price)
            let priceStr = numFormatter.string(from: NSNumber(value: item.price)) ?? "$\(item.price)"
            result.append(TextAttributeConverter.attributedRun(
                text: "\(priceStr) ",
                baseStyle: base,
                foregroundColor: colorConfig.textColor
            ))
            let (deltaColor, arrowPrefix): (NSColor, String) = switch item.direction {
            case .positive: (colorConfig.upColor, "▲ +")
            case .negative: (colorConfig.downColor, "▼ ")
            case .neutral: (colorConfig.neutralColor, " ")
            }
            let percentStr = String(format: "%@%.2f%%", arrowPrefix, item.changePercent24h)
            result.append(TextAttributeConverter.attributedRun(
                text: percentStr,
                baseStyle: base,
                font: boldFont,
                foregroundColor: deltaColor
            ))
            if index < items.count - 1 {
                result.append(TextAttributeConverter.attributedRun(
                    text: spacingSeparator,
                    baseStyle: base,
                    foregroundColor: NSColor.gray.withAlphaComponent(0.6)
                ))
            }
        }
        return result
    }

    static func measureHorizontalCycleExtent(
        for attributed: NSAttributedString,
        decorationPadding: CGFloat = 0
    ) -> CGFloat {
        TextAttributeConverter.measureHorizontalCycleExtent(
            for: attributed,
            decorationPadding: decorationPadding
        )
    }

    private static func priceFractionDigits(for items: [MarketTickerItem]) -> Int {
        items.contains { $0.price < 1 && $0.price > 0 } ? 4 : 2
    }

    private static func priceFractionDigits(for price: Double) -> Int {
        price < 1 && price > 0 ? 4 : 2
    }
}
#endif

enum MarketTickerTokenParser {
    /// `market`, `market:live`, or `market:BTC/USD,ETH/USD`
    static func isMarketToken(_ token: String) -> Bool {
        normalized(token).hasPrefix("market")
    }

    static func watchSymbols(from object: CanvasObject, fallback: [String]) -> [String] {
        let token = normalized(object.token)
        guard token.hasPrefix("market") else { return fallback }
        let payload = token.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        if payload.isEmpty || payload.lowercased() == "live" {
            let fromText = object.text
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return fromText.isEmpty ? fallback : fromText
        }
        return payload
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalized(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
