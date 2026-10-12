import Foundation

enum LiveQuoteKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case stock
    case crypto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stock: "Stock"
        case .crypto: "Crypto"
        }
    }

    static func inferred(from symbol: String) -> LiveQuoteKind {
        LiveQuoteCatalog.kind(for: symbol)
    }
}

struct LiveQuoteRequest: Hashable, Sendable {
    var symbol: String
    var kind: LiveQuoteKind

    var normalizedSymbol: String { LiveQuoteCatalog.normalizedSymbol(symbol, kind: kind) }
}

struct LiveQuote: Hashable, Codable, Sendable {
    var symbol: String
    var name: String
    var price: Double
    var changePercent: Double
    var currency: String
    var kind: LiveQuoteKind
    var updatedAt: Date

    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 180
    }
}

struct ShowTextField: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var key: String
    var value: String
    var hint: String

    init(id: UUID = UUID(), key: String, value: String = "", hint: String = "") {
        self.id = id
        self.key = key
        self.value = value
        self.hint = hint.isEmpty ? key : hint
    }

    var normalizedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DynamicTextContext: Hashable, Sendable {
    var now: Date
    var timeZone: TimeZone
    var fields: [String: String]
    var quotes: [String: LiveQuote]
    var copyright: CopyrightInfo
    var currentSlide: String
    var nextSlide: String
    var notes: String
    var timerText: String?
    var timers: [InspectorTimer] = []
    var mediaRemainingSeconds: Int = 0
    var mediaDurationSeconds: Int = 0
    /// Hide live-quote layers on program until the quote engine finishes its first fetch attempt.
    var liveQuotesInitialLoadPending: Bool = false
    var outline: OutlineLinkState = OutlineLinkState()
    var mediaLink: MediaLinkState = MediaLinkState()
    var broadcastTimecode: String = "00:00:00"
    /// Values published by future graph nodes and external feeds. Read with `{graph:key}`.
    var graphValues: [String: String] = [:]

    static let empty = DynamicTextContext(
        now: Date(timeIntervalSince1970: 0),
        timeZone: TimeZone(secondsFromGMT: 0) ?? TimeZone.current,
        fields: [:],
        quotes: [:],
        copyright: CopyrightInfo(),
        currentSlide: "",
        nextSlide: "",
        notes: "",
        timerText: nil,
        timers: [],
        mediaRemainingSeconds: 0,
        mediaDurationSeconds: 0
    )

    func timer(matching id: UUID?) -> InspectorTimer? {
        if let id, let match = timers.first(where: { $0.id == id }) {
            return match
        }
        return timers.first
    }

    func ticking(now: Date) -> DynamicTextContext {
        var copy = self
        copy.now = now
        return copy
    }

    func fieldValue(for key: String) -> String? {
        let needle = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = fields[needle], !exact.isEmpty { return exact }
        if let match = fields.first(where: { $0.key.caseInsensitiveCompare(needle) == .orderedSame })?.value, !match.isEmpty {
            return match
        }
        return nil
    }

    func quote(for symbol: String) -> LiveQuote? {
        let key = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let exact = quotes[key] { return exact }
        let mapped = LiveQuoteCatalog.normalizedSymbol(symbol, kind: .inferred(from: symbol)).uppercased()
        return quotes[mapped] ?? quotes.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
    }
}

enum CountdownFormatCatalog {
    static let `default` = "mm:ss"
    static let all = ["m:ss", "mm:ss", "h:mm:ss", "HH:mm:ss", "s", "mm:ss;ff"]

    static func title(for format: String) -> String {
        switch format {
        case "m:ss": "5:00"
        case "mm:ss": "05:00"
        case "h:mm:ss": "0:05:00"
        case "HH:mm:ss": "00:05:00"
        case "s": "300"
        case "mm:ss;ff": "05:00;00"
        default: format
        }
    }

    static func resolvedToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.contains(trimmed) ? trimmed : `default`
    }

    static func format(_ seconds: Int, token: String, fps: Double = 30) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        switch resolvedToken(token) {
        case "m:ss":
            return String(format: "%d:%02d", hours * 60 + minutes, secs)
        case "mm:ss":
            return String(format: "%02d:%02d", hours * 60 + minutes, secs)
        case "h:mm:ss":
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        case "HH:mm:ss":
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        case "s":
            return "\(total)"
        case "mm:ss;ff":
            return ProgramTimecode.format(TimeInterval(total), fps: fps)
        default:
            return String(format: "%02d:%02d", hours * 60 + minutes, secs)
        }
    }
}

enum ClockFormatCatalog {
    static let time = ["h:mm a", "h:mm:ss a", "HH:mm", "HH:mm:ss"]
    static let date = ["EEEE, MMMM d", "MMMM d, yyyy", "MMM d", "M/d/yy", "EEEE"]

    static func title(for format: String) -> String {
        switch format {
        case "h:mm a": "1:15 PM"
        case "h:mm:ss a": "1:15:03 PM"
        case "HH:mm": "13:15"
        case "HH:mm:ss": "13:15:03"
        case "EEEE, MMMM d": "Saturday, September 26"
        case "MMMM d, yyyy": "September 26, 2026"
        case "MMM d": "Sep 26"
        case "M/d/yy": "9/26/26"
        case "EEEE": "Saturday"
        default: format
        }
    }
}

enum LiveQuoteCatalog {
    static let defaultTemplate = "{symbol}  {price}  {change}"
    static let templates = [
        "{symbol}  {price}  {change}",
        "{symbol}\n{price}\n{change}",
        "{symbol}  {price}",
        "{symbol}",
        "{name}  {price}",
        "{price}",
        "{change}",
    ]

    /// Ticker or alias → CoinGecko `ids` query parameter (see api.coingecko.com coin list).
    static let cryptoIDs: [String: String] = [
        "btc": "bitcoin",
        "bitcoin": "bitcoin",
        "eth": "ethereum",
        "ethereum": "ethereum",
        "sol": "solana",
        "solana": "solana",
        "doge": "dogecoin",
        "dogecoin": "dogecoin",
        "xrp": "ripple",
        "ripple": "ripple",
        "ada": "cardano",
        "cardano": "cardano",
        "xlm": "stellar",
        "stellar": "stellar",
        "usdc": "usd-coin",
        "usdt": "tether",
        "link": "chainlink",
        "chainlink": "chainlink",
        "ltc": "litecoin",
        "litecoin": "litecoin",
        "bnb": "binancecoin",
        "avax": "avalanche-2",
        "avalanche": "avalanche-2",
        "dot": "polkadot",
        "polkadot": "polkadot",
        "matic": "polygon-ecosystem-token",
        "polygon": "polygon-ecosystem-token",
        "shib": "shiba-inu",
        "trx": "tron",
        "tron": "tron",
    ]

    static func kind(for symbol: String) -> LiveQuoteKind {
        cryptoIDs[symbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] == nil ? .stock : .crypto
    }

    static func normalizedSymbol(_ symbol: String, kind: LiveQuoteKind) -> String {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .crypto:
            return cryptoIDs[trimmed.lowercased()] ?? trimmed.lowercased()
        case .stock:
            return trimmed.uppercased()
        }
    }

    static func displaySymbol(_ quote: LiveQuote) -> String {
        switch quote.kind {
        case .stock: return quote.symbol.uppercased()
        case .crypto:
            switch quote.symbol.lowercased() {
            case "bitcoin": return "BTC"
            case "ethereum": return "ETH"
            case "solana": return "SOL"
            case "dogecoin": return "DOGE"
            case "ripple": return "XRP"
            case "cardano": return "ADA"
            case "stellar": return "XLM"
            case "usd-coin": return "USDC"
            case "tether": return "USDT"
            case "chainlink": return "LINK"
            case "litecoin": return "LTC"
            case "binancecoin": return "BNB"
            case "avalanche-2": return "AVAX"
            case "polkadot": return "DOT"
            case "polygon-ecosystem-token": return "MATIC"
            case "shiba-inu": return "SHIB"
            case "tron": return "TRX"
            default: return quote.symbol.uppercased()
            }
        }
    }
}

struct OutlineAgendaItem: Hashable, Sendable {
    var title: String
    var speakerName: String
}

struct OutlineLinkState: Hashable, Sendable {
    /// Resolved URL for the active outline segment (program page / browser link on the segment slide).
    var segmentLink: String = ""
    var segmentTitle: String = ""
    var speakerName: String = ""
    var speakerRole: String = ""
    var speakerOrganization: String = ""
    var plannedDurationSeconds: Int = 0
    var plannedEnd: Date?
    var nextTitle: String = ""
    var nextSpeakerName: String = ""
    var upcoming: [OutlineAgendaItem] = []
}

struct MediaLinkState: Hashable, Sendable {
    var name: String = ""
    var remainingSeconds: Int = 0
    var elapsedSeconds: Int = 0
    var durationSeconds: Int = 0
}

enum DataLinkDomain: String, CaseIterable, Identifiable, Sendable {
    case outline = "Outline"
    case media = "Media"
    case system = "System"
    case graph = "Graph"

    var id: String { rawValue }
}

enum DataLinkValueKind: Sendable {
    case plain
    case duration
    case clock
    case agenda
    case graph
}

struct DataLinkField: Identifiable, Sendable {
    var id: String
    var domain: DataLinkDomain
    var title: String
    var token: String
    var kind: DataLinkValueKind
}

enum DataLinkCatalog {
    static let fields: [DataLinkField] = [
        DataLinkField(id: "segment.link", domain: .outline, title: "Current Segment Link", token: "segment.link", kind: .plain),
        DataLinkField(id: "segment.title", domain: .outline, title: "Current Segment Title", token: "segment.title", kind: .plain),
        DataLinkField(id: "speaker.name", domain: .outline, title: "Current Speaker Name", token: "speaker.name", kind: .plain),
        DataLinkField(id: "speaker.role", domain: .outline, title: "Current Speaker Role", token: "speaker.role", kind: .plain),
        DataLinkField(id: "segment.duration", domain: .outline, title: "Current Segment Duration", token: "segment.duration", kind: .duration),
        DataLinkField(id: "segment.end", domain: .outline, title: "Current Segment End", token: "segment.end", kind: .clock),
        DataLinkField(id: "next.title", domain: .outline, title: "Next Up Segment Title", token: "next.title", kind: .plain),
        DataLinkField(id: "next.speaker", domain: .outline, title: "Next Up Speaker Name", token: "next.speaker", kind: .plain),
        DataLinkField(id: "agenda", domain: .outline, title: "Upcoming Agenda List", token: "agenda", kind: .agenda),
        DataLinkField(id: "media.name", domain: .media, title: "Active Media Name", token: "media.name", kind: .plain),
        DataLinkField(id: "media.remaining", domain: .media, title: "Media Time Remaining", token: "media.remaining", kind: .duration),
        DataLinkField(id: "media.elapsed", domain: .media, title: "Media Elapsed Time", token: "media.elapsed", kind: .duration),
        DataLinkField(id: "media.duration", domain: .media, title: "Media Total Duration", token: "media.duration", kind: .duration),
        DataLinkField(id: "time", domain: .system, title: "Wall-Clock Time", token: "time", kind: .clock),
        DataLinkField(id: "timecode", domain: .system, title: "Broadcast Timecode", token: "timecode", kind: .plain),
        DataLinkField(id: "graph", domain: .graph, title: "External Data Node", token: "graph", kind: .graph),
    ]

    static func fields(in domain: DataLinkDomain) -> [DataLinkField] {
        fields.filter { $0.domain == domain }
    }

    static func tag(for field: DataLinkField, format: String? = nil, agendaCount: Int = 3, graphKey: String = "") -> String {
        switch field.kind {
        case .plain:
            return "{\(field.token)}"
        case .duration:
            let style = CountdownFormatCatalog.resolvedToken(format ?? CountdownFormatCatalog.default)
            return "{\(field.token):\(style)}"
        case .clock:
            if field.token == "segment.end" {
                let style = (format?.isEmpty == false) ? format! : "h:mm a"
                return "{\(field.token):\(style)}"
            }
            let style = (format?.isEmpty == false) ? format! : "h:mm:ss a"
            return "{\(field.token):\(style)}"
        case .agenda:
            return "{agenda:\(max(1, min(8, agendaCount)))}"
        case .graph:
            let key = graphKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? "{graph:key}" : "{graph:\(key)}"
        }
    }

    static func isReserved(_ token: String) -> Bool {
        let lower = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "time" || lower.hasPrefix("time:") || lower == "time.now" { return true }
        if lower == "date" || lower.hasPrefix("date:") { return true }
        if lower == "timecode" { return true }
        if lower == "agenda" || lower.hasPrefix("agenda:") { return true }
        if lower.hasPrefix("graph:") { return true }
        if lower.hasPrefix("segment.") || lower.hasPrefix("speaker.") || lower.hasPrefix("next.") { return true }
        if lower.hasPrefix("media.") { return true }
        if lower == "timer.countdown" || lower == "timer.elapsed" { return true }
        return false
    }
}

extension CanvasObjectKind {
    var usesLiveText: Bool {
        switch self {
        case .systemClock, .systemDate, .timerCountdown, .liveQuote, .textField,
             .currentSlide, .nextSlide, .stageNotes, .copyrightToken:
            true
        default:
            false
        }
    }
}
