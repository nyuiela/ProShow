import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

enum DataLinkMatch: Equatable {
    case unknown
    case value(String)
}

extension DataLinkCatalog {
    static func match(_ token: String, context: DynamicTextContext) -> DataLinkMatch {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "timecode" {
            return .value(context.broadcastTimecode)
        }
        if lower == "agenda" {
            return .value(agenda(context.outline.upcoming, count: 3))
        }
        if lower.hasPrefix("agenda:") {
            let count = Int(lower.dropFirst("agenda:".count)) ?? 3
            return .value(agenda(context.outline.upcoming, count: count))
        }
        if lower.hasPrefix("graph:") {
            let key = String(trimmed.dropFirst("graph:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return .value("") }
            if let value = context.graphValues[key] { return .value(value) }
            if let value = context.graphValues.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                return .value(value)
            }
            return .value("")
        }
        if let styled = suffix(in: trimmed, key: "segment.duration") {
            return .value(durationText(context.outline.plannedDurationSeconds, token: styled, active: !context.outline.segmentTitle.isEmpty))
        }
        if lower == "segment.duration" {
            return .value(durationText(context.outline.plannedDurationSeconds, token: CountdownFormatCatalog.default, active: !context.outline.segmentTitle.isEmpty))
        }
        if let styled = suffix(in: trimmed, key: "segment.end") {
            guard let end = context.outline.plannedEnd else { return .value("") }
            return .value(DynamicTextEngine.formatDate(end, format: styled, timeZone: context.timeZone))
        }
        if lower == "segment.end" {
            guard let end = context.outline.plannedEnd else { return .value("") }
            return .value(DynamicTextEngine.formatDate(end, format: "h:mm a", timeZone: context.timeZone))
        }
        let mediaActive = !context.mediaLink.name.isEmpty || context.mediaLink.durationSeconds > 0
        if let styled = suffix(in: trimmed, key: "media.remaining") {
            return .value(durationText(context.mediaLink.remainingSeconds, token: styled, active: mediaActive))
        }
        if lower == "media.remaining" {
            return .value(durationText(context.mediaLink.remainingSeconds, token: CountdownFormatCatalog.default, active: mediaActive))
        }
        if let styled = suffix(in: trimmed, key: "media.elapsed") {
            return .value(durationText(context.mediaLink.elapsedSeconds, token: styled, active: mediaActive))
        }
        if lower == "media.elapsed" {
            return .value(durationText(context.mediaLink.elapsedSeconds, token: CountdownFormatCatalog.default, active: mediaActive))
        }
        if let styled = suffix(in: trimmed, key: "media.duration") {
            return .value(durationText(context.mediaLink.durationSeconds, token: styled, active: mediaActive))
        }
        if lower == "media.duration" {
            return .value(durationText(context.mediaLink.durationSeconds, token: CountdownFormatCatalog.default, active: mediaActive))
        }
        switch lower {
        case "segment.link", "segment.url":
            return .value(context.outline.segmentLink)
        case "segment.title":
            return .value(context.outline.segmentTitle)
        case "speaker.name":
            return .value(context.outline.speakerName)
        case "speaker.role", "speaker.subtitle", "speaker.title":
            return .value(context.outline.speakerRole)
        case "speaker.org":
            return .value(context.outline.speakerOrganization)
        case "next.title":
            return .value(context.outline.nextTitle)
        case "next.speaker":
            return .value(context.outline.nextSpeakerName)
        case "media.name":
            return .value(context.mediaLink.name)
        default:
            return .unknown
        }
    }

    private static func durationText(_ seconds: Int, token: String, active: Bool) -> String {
        guard active else { return "" }
        return CountdownFormatCatalog.format(seconds, token: token)
    }

    private static func agenda(_ items: [OutlineAgendaItem], count: Int) -> String {
        let limit = max(1, min(8, count))
        return items.prefix(limit).map { item in
            item.speakerName.isEmpty ? item.title : "\(item.title) — \(item.speakerName)"
        }.joined(separator: "\n")
    }

    private static func suffix(in token: String, key: String) -> String? {
        let prefix = key + ":"
        guard token.lowercased().hasPrefix(prefix) else { return nil }
        let style = String(token.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return style.isEmpty ? nil : style
    }
}

enum DynamicTextEngine {
    static func resolve(_ object: CanvasObject, context: DynamicTextContext) -> String {
        interpolate(seed(for: object, context: context), context: context)
    }

    /// Slide + prop encode path: same evaluation as SwiftUI `dynamicText` + `TimelineView`.
    static func resolveProgramText(for object: CanvasObject, context: DynamicTextContext) -> String {
        resolve(object, context: context)
    }

    /// Accept `{{token}}` templates as well as `{token}`.
    static func normalizeBraceSyntax(_ text: String) -> String {
        text
            .replacingOccurrences(of: "{{", with: "{")
            .replacingOccurrences(of: "}}", with: "}")
    }

    static func fieldKey(for object: CanvasObject) -> String {
        let token = object.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { return token }
        let name = object.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Text" : name
    }

    static func quoteSpec(for object: CanvasObject) -> LiveQuoteRequest {
        let raw = object.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2, let kind = LiveQuoteKind(rawValue: parts[0]) {
            return LiveQuoteRequest(symbol: parts[1], kind: kind)
        }
        let symbol = raw.isEmpty ? "AAPL" : raw
        return LiveQuoteRequest(symbol: symbol, kind: .inferred(from: symbol))
    }

    static func encodeQuoteToken(_ request: LiveQuoteRequest) -> String {
        "\(request.kind.rawValue)|\(request.symbol)"
    }

    static func fieldKeys(in objects: [CanvasObject]) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for object in objects {
            if object.kind == .textField {
                insertKey(fieldKey(for: object), seen: &seen, keys: &keys)
            }
            for key in interpolationKeys(in: object.text + " " + object.token) {
                insertKey(key, seen: &seen, keys: &keys)
            }
        }
        return keys
    }

    /// Symbols this layer alone needs before showing on program output (never blocked by sibling layers).
    static func requiredLiveQuoteRequests(for object: CanvasObject, canvasObjects: [CanvasObject] = []) -> [LiveQuoteRequest] {
        _ = canvasObjects
        return quoteRequests(in: [object])
    }

    static func hasResolvedLiveQuote(_ request: LiveQuoteRequest, in context: DynamicTextContext) -> Bool {
        let trimmed = request.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = Set(
            [
                trimmed,
                trimmed.uppercased(),
                request.normalizedSymbol,
                request.normalizedSymbol.uppercased(),
                LiveQuoteCatalog.normalizedSymbol(trimmed, kind: request.kind),
            ].filter { !$0.isEmpty }
        )
        if candidates.contains(where: { context.quote(for: $0) != nil }) {
            return true
        }
        let target = request.normalizedSymbol.uppercased()
        return context.quotes.values.contains { quote in
            LiveQuoteCatalog.normalizedSymbol(quote.symbol, kind: quote.kind).uppercased() == target
                || quote.symbol.uppercased() == request.symbol.uppercased()
        }
    }

    /// Audience / stream / map: hide quote layers only until the first fetch attempt completes; then match editor placeholders if needed.
    static func shouldDeferProgramLiveQuoteOutput(
        object: CanvasObject,
        context: DynamicTextContext,
        canvasObjects: [CanvasObject]
    ) -> Bool {
        let requests = requiredLiveQuoteRequests(for: object, canvasObjects: canvasObjects)
        guard !requests.isEmpty else { return false }
        if requests.allSatisfy({ hasResolvedLiveQuote($0, in: context) }) {
            return false
        }
        return context.liveQuotesInitialLoadPending
    }

    static func quoteRequests(in objects: [CanvasObject]) -> [LiveQuoteRequest] {
        var seen = Set<String>()
        var requests: [LiveQuoteRequest] = []
        func append(_ request: LiveQuoteRequest) {
            let id = "\(request.kind.rawValue):\(request.normalizedSymbol)"
            if seen.insert(id).inserted {
                requests.append(request)
            }
        }
        for object in objects {
            if object.kind == .liveQuote {
                append(quoteSpec(for: object))
            }
            if object.kind != .liveQuote, MarketTickerRouting.usesLiveMarketDataFeed(object) {
                for symbol in MarketTickerRouting.watchSymbols(for: object, canvasObjects: objects) {
                    append(LiveQuoteRequest(symbol: symbol, kind: .inferred(from: symbol)))
                }
            }
            for symbol in interpolationQuotes(in: object.text) {
                append(LiveQuoteRequest(symbol: symbol, kind: .inferred(from: symbol)))
            }
        }
        return requests
    }

    private static func seed(for object: CanvasObject, context: DynamicTextContext) -> String {
        switch object.kind {
        case .systemClock:
            return formatDate(context.now, format: object.token.nilIfEmpty ?? "h:mm:ss a", timeZone: context.timeZone)
        case .systemDate:
            return formatDate(context.now, format: object.token.nilIfEmpty ?? "EEEE, MMMM d", timeZone: context.timeZone)
        case .liveQuote:
            return liveQuoteBody(for: object, context: context)
        case .textField:
            let key = fieldKey(for: object)
            if let filled = context.fieldValue(for: key) { return filled }
            if let typed = object.text.nilIfEmpty, !typed.hasPrefix("[") { return typed }
            return "[\(key)]"
        case .timerCountdown:
            if object.resolvedCountdownValueSource == .programMedia {
                return CountdownFormatCatalog.format(context.mediaRemainingSeconds, token: object.token)
            }
            if let timer = context.timer(matching: object.timerID) {
                return CountdownFormatCatalog.format(timer.displaySeconds, token: object.token)
            }
            if let timerText = context.timerText { return timerText }
            return CountdownFormatCatalog.format(0, token: object.token)
        case .currentSlide:
            return context.currentSlide.nilIfEmpty ?? object.displayText
        case .nextSlide:
            return context.nextSlide.nilIfEmpty ?? object.displayText
        case .stageNotes:
            return context.notes.nilIfEmpty ?? object.displayText
        case .copyrightToken:
            return context.copyright.resolvedLine(template: object.token.nilIfEmpty ?? object.text)
        default:
            return object.displayText
        }
    }

    /// Compiled once: building this regex per call ran for every text object on every program tick.
    static let braceTokenRegex = try! NSRegularExpression(pattern: #"\{([^{}]+)\}"#)

    static func interpolate(_ text: String, context: DynamicTextContext) -> String {
        let normalized = normalizeBraceSyntax(text)
        guard normalized.contains("{") else { return normalized }
        var result = normalized
        let regex = braceTokenRegex
        let matches = regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).reversed()
        for match in matches {
            guard let range = Range(match.range, in: normalized),
                  let tokenRange = Range(match.range(at: 1), in: normalized)
            else { continue }
            let token = String(normalized[tokenRange])
            let replacement = replacement(for: token, context: context)
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func replacement(for token: String, context: DynamicTextContext) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if case .value(let linked) = DataLinkCatalog.match(trimmed, context: context) {
            if !linked.isEmpty { return linked }
            if let field = context.fieldValue(for: trimmed) { return field }
            return ""
        }
        if lower == "time" {
            return formatDate(context.now, format: "h:mm:ss a", timeZone: context.timeZone)
        }
        if lower.hasPrefix("time:") {
            return formatDate(context.now, format: String(trimmed.dropFirst(5)), timeZone: context.timeZone)
        }
        if lower == "date" {
            return formatDate(context.now, format: "EEEE, MMMM d", timeZone: context.timeZone)
        }
        if lower.hasPrefix("date:") {
            return formatDate(context.now, format: String(trimmed.dropFirst(5)), timeZone: context.timeZone)
        }
        if lower.hasPrefix("quote:") {
            let symbol = String(trimmed.dropFirst(6))
            return formatQuote(
                spec: LiveQuoteRequest(symbol: symbol, kind: .inferred(from: symbol)),
                template: LiveQuoteCatalog.defaultTemplate,
                context: context
            )
        }
        if lower.hasPrefix("field:") {
            let key = String(trimmed.dropFirst(6))
            return context.fieldValue(for: key) ?? "[\(key)]"
        }
        if lower == "time.now" {
            return formatDate(context.now, format: "h:mm:ss a", timeZone: context.timeZone)
        }
        if lower == "timer.countdown" {
            if let timer = context.timers.first(where: \.isRunning) ?? context.timers.first {
                return CountdownFormatCatalog.format(timer.displaySeconds, token: CountdownFormatCatalog.default)
            }
            return context.timerText ?? CountdownFormatCatalog.format(0, token: CountdownFormatCatalog.default)
        }
        if lower == "timer.elapsed" {
            if let timer = context.timers.first(where: \.isRunning) ?? context.timers.first {
                let elapsed = max(0, timer.durationSeconds - timer.displaySeconds)
                return CountdownFormatCatalog.format(elapsed, token: CountdownFormatCatalog.default)
            }
            return CountdownFormatCatalog.format(0, token: CountdownFormatCatalog.default)
        }
        if lower == "speaker.name" {
            return context.fieldValue(for: "speaker.name")
                ?? context.fieldValue(for: "Speaker")
                ?? context.fieldValue(for: "speaker")
                ?? ""
        }
        if lower == "speaker.title" {
            return context.fieldValue(for: "speaker.title")
                ?? context.fieldValue(for: "Title")
                ?? ""
        }
        if lower == "speaker.org" {
            return context.fieldValue(for: "speaker.org")
                ?? context.fieldValue(for: "Organization")
                ?? ""
        }
        if ["title", "artist", "author", "album", "publisher", "copyright year", "license number"].contains(lower) {
            return context.copyright.resolvedLine(template: "{\(trimmed)}")
        }
        if let field = context.fieldValue(for: trimmed) {
            return field
        }
        if let quote = context.quote(for: trimmed) {
            return formatQuote(quote: quote, template: LiveQuoteCatalog.defaultTemplate)
        }
        return "{\(token)}"
    }

    static func formatDate(
        _ date: Date,
        format: String,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Text that is only `{quote:SYMBOL}` tokens (multi-symbol live quote boxes).
    static func isQuoteDirectiveTemplate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("{") else { return false }
        let regex = braceTokenRegex
        let full = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = regex.matches(in: trimmed, range: full)
        guard !matches.isEmpty else { return false }
        for match in matches {
            guard let tokenRange = Range(match.range(at: 1), in: trimmed) else { return false }
            let token = String(trimmed[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !token.hasPrefix("quote:") { return false }
        }
        let withoutTokens = regex.stringByReplacingMatches(in: trimmed, range: full, withTemplate: "")
        return withoutTokens.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Looping colored tickers should not also scroll raw `{quote:…}` directives as plain text.
    static func loopScrollText(for object: CanvasObject, resolved: String) -> String {
        #if os(macOS)
        if LiveQuoteDisplayRouting.usesTokenDisplayTemplate(object) {
            return ""
        }
        #endif
        let template = MarketTickerRouting.liveQuoteDisplayTemplate(for: object)
        if MarketTickerRouting.usesColoredStrip(object), isQuoteDirectiveTemplate(template) {
            return ""
        }
        return resolved
    }

    private static func liveQuoteBody(for object: CanvasObject, context: DynamicTextContext) -> String {
        let body = MarketTickerRouting.liveQuoteDisplayTemplate(for: object)
        if isQuoteDirectiveTemplate(body) {
            return interpolate(body, context: context)
        }
        return formatQuote(spec: quoteSpec(for: object), template: body, context: context)
    }

    static func formatQuote(spec: LiveQuoteRequest, template: String, context: DynamicTextContext) -> String {
        let resolved = template.nilIfEmpty ?? LiveQuoteCatalog.defaultTemplate
        guard let quote = context.quote(for: spec.symbol) ?? context.quote(for: spec.normalizedSymbol) else {
            return applyQuotePlaceholders(
                to: resolved,
                symbol: spec.symbol.uppercased(),
                name: spec.symbol.uppercased(),
                price: "—",
                change: "",
                currency: ""
            )
        }
        return formatQuote(quote: quote, template: resolved)
    }

    static func formatQuote(quote: LiveQuote, template: String) -> String {
        let change = String(format: "%@%.2f%%", quote.changePercent >= 0 ? "+" : "−", abs(quote.changePercent))
        return applyQuotePlaceholders(
            to: template,
            symbol: LiveQuoteCatalog.displaySymbol(quote),
            name: quote.name.nilIfEmpty ?? LiveQuoteCatalog.displaySymbol(quote),
            price: formatPrice(quote.price, currency: quote.currency),
            change: change,
            currency: quote.currency
        )
    }

    /// Substitutes `{symbol}`, `{price}`, etc. without collapsing the user's line breaks or spacing.
    private static func applyQuotePlaceholders(
        to template: String,
        symbol: String,
        name: String,
        price: String,
        change: String,
        currency: String
    ) -> String {
        template
            .replacingOccurrences(of: "{symbol}", with: symbol)
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{price}", with: price)
            .replacingOccurrences(of: "{change}", with: change)
            .replacingOccurrences(of: "{currency}", with: currency)
    }

    static func formatPrice(_ value: Double, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_US")
        if value >= 1000 {
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
        } else if value >= 1 {
            formatter.maximumFractionDigits = 2
        } else {
            formatter.maximumFractionDigits = 4
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private static func interpolationKeys(in text: String) -> [String] {
        tokens(in: text).compactMap { token in
            let lower = token.lowercased()
            if lower.hasPrefix("field:") { return String(token.dropFirst(6)) }
            if DataLinkCatalog.isReserved(token) { return nil }
            if ["time", "date"].contains(where: { lower == $0 || lower.hasPrefix("\($0):") }) { return nil }
            if lower.hasPrefix("quote:") { return nil }
            if ["title", "artist", "author", "album", "publisher", "copyright year", "license number"].contains(lower) {
                return nil
            }
            return token
        }
    }

    private static func interpolationQuotes(in text: String) -> [String] {
        tokens(in: text).compactMap { token in
            let lower = token.lowercased()
            if lower.hasPrefix("quote:") { return String(token.dropFirst(6)) }
            return nil
        }
    }

    private static func tokens(in text: String) -> [String] {
        guard text.contains("{") else { return [] }
        let regex = braceTokenRegex
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func insertKey(_ key: String, seen: inout Set<String>, keys: inout [String]) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = trimmed.lowercased()
        if seen.insert(id).inserted {
            keys.append(trimmed)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if canImport(SwiftUI)
import SwiftUI

@MainActor
enum LiveQuoteEnvironment {
    static func mergedContext(
        base: DynamicTextContext,
        engine: LiveQuoteEngine?,
        at date: Date
    ) -> DynamicTextContext {
        var context = base.ticking(now: date)
        if let engine {
            context.quotes = engine.quotes
        }
        return context
    }
}

private struct LiveQuoteEngineKey: EnvironmentKey {
    static let defaultValue: LiveQuoteEngine? = nil
}

extension EnvironmentValues {
    var liveQuoteEngine: LiveQuoteEngine? {
        get { self[LiveQuoteEngineKey.self] }
        set { self[LiveQuoteEngineKey.self] = newValue }
    }
}

/// Forces SwiftUI to track `@Observable` quote mutations outside stale `dynamicText` snapshots.
struct LiveQuoteRefreshScope<Content: View>: View {
    @Bindable var engine: LiveQuoteEngine
    @ViewBuilder var content: () -> Content

    var body: some View {
        let fingerprint = engine.quotes
            .map { "\($0.key):\($0.value.price):\($0.value.changePercent)" }
            .sorted()
            .joined(separator: "|")
        let _ = fingerprint
        content()
    }
}

private struct DynamicTextContextKey: EnvironmentKey {
    static let defaultValue = DynamicTextContext.empty
}

extension EnvironmentValues {
    var dynamicText: DynamicTextContext {
        get { self[DynamicTextContextKey.self] }
        set { self[DynamicTextContextKey.self] = newValue }
    }
}
#endif
