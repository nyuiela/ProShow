import Foundation
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// Routes `{symbol}` / `{price}` display templates vs colored `{quote:…}` strips.
enum LiveQuoteDisplayRouting {
    static func usesTokenDisplayTemplate(_ object: CanvasObject) -> Bool {
        guard object.kind == .liveQuote else { return false }
        if MarketTickerRouting.usesColoredStrip(object) || MarketTickerRouting.usesStaticColoredLiveQuote(object) {
            return false
        }
        let template = MarketTickerRouting.liveQuoteDisplayTemplate(for: object)
        return template.contains("{") && !DynamicTextEngine.isQuoteDirectiveTemplate(template)
    }
}

/// Renders Live Quote Display templates with green/red `{change}` (matches ticker colors).
enum LiveQuoteTemplateRenderer {
    private static let tokenPattern = #"\{(symbol|name|price|change|currency)\}"#

    static func makeAttributedString(
        object: CanvasObject,
        scale: CGFloat,
        context: DynamicTextContext,
        colorConfig: TickerColorConfig = TickerColorConfig()
    ) -> NSAttributedString? {
        guard object.kind == .liveQuote else { return nil }
        let template = MarketTickerRouting.liveQuoteDisplayTemplate(for: object)
        guard !DynamicTextEngine.isQuoteDirectiveTemplate(template) else { return nil }
        guard template.contains("{") else { return nil }

        let spec = DynamicTextEngine.quoteSpec(for: object)
        let quote = context.quote(for: spec.symbol) ?? context.quote(for: spec.normalizedSymbol)
        let base = SlideTextAttributes.from(object: object, text: " ", scale: scale)
        return build(template: template, spec: spec, quote: quote, baseStyle: base, colorConfig: colorConfig)
    }

    private static func build(
        template: String,
        spec: LiveQuoteRequest,
        quote: LiveQuote?,
        baseStyle: SlideTextAttributes,
        colorConfig: TickerColorConfig
    ) -> NSAttributedString {
        guard let regex = try? NSRegularExpression(pattern: tokenPattern, options: [.caseInsensitive]) else {
            return TextAttributeConverter.attributedRun(text: template, baseStyle: baseStyle)
        }

        let result = NSMutableAttributedString()
        let nsTemplate = template as NSString
        var cursor = 0
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length))

        for match in matches {
            let range = match.range
            if range.location > cursor {
                let literal = nsTemplate.substring(with: NSRange(location: cursor, length: range.location - cursor))
                appendLiteral(literal, baseStyle: baseStyle, to: result)
            }
            let tokenBody = nsTemplate.substring(with: match.range(at: 1)).lowercased()
            appendToken(tokenBody, spec: spec, quote: quote, baseStyle: baseStyle, colorConfig: colorConfig, to: result)
            cursor = range.location + range.length
        }

        if cursor < nsTemplate.length {
            let tail = nsTemplate.substring(from: cursor)
            appendLiteral(tail, baseStyle: baseStyle, to: result)
        }

        return result
    }

    private static func appendLiteral(
        _ literal: String,
        baseStyle: SlideTextAttributes,
        to result: NSMutableAttributedString
    ) {
        guard !literal.isEmpty else { return }
        result.append(TextAttributeConverter.attributedRun(text: literal, baseStyle: baseStyle))
    }

    private static func appendToken(
        _ token: String,
        spec: LiveQuoteRequest,
        quote: LiveQuote?,
        baseStyle: SlideTextAttributes,
        colorConfig: TickerColorConfig,
        to result: NSMutableAttributedString
    ) {
        if let quote {
            switch token {
            case "symbol":
                result.append(TextAttributeConverter.attributedRun(
                    text: LiveQuoteCatalog.displaySymbol(quote),
                    baseStyle: baseStyle
                ))
            case "name":
                let name = quote.name.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(TextAttributeConverter.attributedRun(
                    text: name.isEmpty ? LiveQuoteCatalog.displaySymbol(quote) : name,
                    baseStyle: baseStyle
                ))
            case "price":
                result.append(TextAttributeConverter.attributedRun(
                    text: DynamicTextEngine.formatPrice(quote.price, currency: quote.currency),
                    baseStyle: baseStyle
                ))
            case "change":
                let (text, color) = changePresentation(for: quote.changePercent, config: colorConfig)
                let bold = NSFontManager.shared.convert(baseStyle.font, toHaveTrait: .boldFontMask)
                result.append(TextAttributeConverter.attributedRun(
                    text: text,
                    baseStyle: baseStyle,
                    font: bold,
                    foregroundColor: color
                ))
            case "currency":
                result.append(TextAttributeConverter.attributedRun(text: quote.currency, baseStyle: baseStyle))
            default:
                break
            }
        } else {
            switch token {
            case "symbol":
                result.append(TextAttributeConverter.attributedRun(text: spec.symbol.uppercased(), baseStyle: baseStyle))
            case "name":
                result.append(TextAttributeConverter.attributedRun(text: spec.symbol.uppercased(), baseStyle: baseStyle))
            case "price":
                result.append(TextAttributeConverter.attributedRun(text: "—", baseStyle: baseStyle))
            case "change":
                result.append(TextAttributeConverter.attributedRun(
                    text: "",
                    baseStyle: baseStyle,
                    foregroundColor: colorConfig.neutralColor
                ))
            case "currency":
                result.append(TextAttributeConverter.attributedRun(text: "", baseStyle: baseStyle))
            default:
                break
            }
        }
    }

    private static func changePresentation(for changePercent: Double, config: TickerColorConfig) -> (String, NSColor) {
        let direction: DeltaDirection
        if changePercent > 0.001 { direction = .positive }
        else if changePercent < -0.001 { direction = .negative }
        else { direction = .neutral }

        switch direction {
        case .positive:
            return (String(format: "▲ +%.2f%%", changePercent), config.upColor)
        case .negative:
            return (String(format: "▼ %.2f%%", abs(changePercent)), config.downColor)
        case .neutral:
            return (String(format: "%.2f%%", changePercent), config.neutralColor)
        }
    }
}
#endif
