import Foundation

// Live chat ingest, Phase 1 (YouTube). See docs/PROSHOW_LIVE_CHAT_PLAN.md.
// Isolation: all network, parsing and backoff run on the connector actor.
// Only finished message batches and state changes hop to the main actor.
// Nothing here touches audio, the encoder, or the compositor.

enum LiveChatIngestFlags {
    static let liveChatIngestV1Key = "proshow.liveChatIngestV1"

    /// Off by default. `defaults write com.kaleel.proshow proshow.liveChatIngestV1 -bool YES`.
    static var liveChatIngestV1: Bool {
        get { UserDefaults.standard.bool(forKey: liveChatIngestV1Key) }
        set { UserDefaults.standard.set(newValue, forKey: liveChatIngestV1Key) }
    }
}

/// Estimated YouTube Data API units spent per Pacific day (quota resets at
/// midnight Pacific). Local estimate only; the Cloud console is the truth.
struct YouTubeQuotaLedger: Sendable {
    static let defaultsKey = "proshow.liveChat.youtubeQuotaLedger"
    /// Default project quota is 10,000 units a day. Stop chat well before it so
    /// Go Live provisioning (same quota) still works.
    static let dailyBudget = 7000

    static func dayKey(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Adds units for today and returns today's total.
    @discardableResult
    static func spend(_ units: Int, now: Date = Date(), defaults: UserDefaults = .standard) -> Int {
        let key = dayKey(now)
        var book = defaults.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        book = book.filter { $0.key == key }
        let total = (book[key] ?? 0) + units
        book[key] = total
        defaults.set(book, forKey: defaultsKey)
        return total
    }

    static func today(now: Date = Date(), defaults: UserDefaults = .standard) -> Int {
        (defaults.dictionary(forKey: defaultsKey) as? [String: Int])?[dayKey(now)] ?? 0
    }
}

enum ChatConnectorState: Equatable, Sendable {
    case idle
    case resolving
    case streaming
    case polling
    case retrying(seconds: Int)
    case ended
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Off"
        case .resolving: return "Finding chat"
        case .streaming: return "Live"
        case .polling: return "Live (polling)"
        case .retrying(let s): return "Retrying in \(s)s"
        case .ended: return "Chat ended"
        case .failed(let reason): return reason
        }
    }

    var isActive: Bool {
        switch self {
        case .resolving, .streaming, .polling, .retrying: return true
        default: return false
        }
    }
}

enum YouTubeChatTarget: Equatable, Sendable {
    case chatID(String)
    case video(String)
    case broadcast(String)
    case autoActive

    /// Accepts a watch URL, youtu.be link, /live/ or /shorts/ link, or a bare 11 char id.
    static func videoID(from input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if isVideoID(raw) { return raw }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let comps = URLComponents(string: withScheme), let host = comps.host?.lowercased() else { return nil }
        guard host.hasSuffix("youtube.com") || host == "youtu.be" else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, isVideoID(v) { return v }
        let segments = comps.path.split(separator: "/").map(String.init)
        if host == "youtu.be", let first = segments.first, isVideoID(first) { return first }
        if segments.count >= 2, ["live", "shorts", "embed", "v"].contains(segments[0]), isVideoID(segments[1]) {
            return segments[1]
        }
        return nil
    }

    static func isVideoID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && s.allSatisfy(\.isASCII)
    }
}

enum YouTubeChatError: Error, Equatable {
    case ended
    case disabled
    case notFound
    case forbidden
    case unauthorized
    case quotaExceeded
    case rateLimited
    case noActiveChat
    case budgetReached
    case streamUnsupported
    case http(Int)
    case malformed

    /// Terse operator facing reason.
    var reason: String {
        switch self {
        case .ended: return "Chat ended"
        case .disabled: return "Chat disabled"
        case .notFound: return "Chat not found"
        case .forbidden: return "No access to this chat"
        case .unauthorized: return "Sign-in expired"
        case .quotaExceeded: return "YouTube quota exceeded"
        case .rateLimited: return "Rate limited"
        case .noActiveChat: return "No live chat on this video"
        case .budgetReached: return "Daily quota budget reached"
        case .streamUnsupported: return "Stream unavailable"
        case .http(let code): return "YouTube error \(code)"
        case .malformed: return "Bad response"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .ended, .disabled, .notFound, .forbidden, .quotaExceeded, .noActiveChat, .budgetReached: return true
        default: return false
        }
    }
}

struct YouTubeChatPage: Equatable, Sendable {
    var messages: [LiveChatMessage] = []
    var removedMessageIDs: [String] = []
    var bannedAuthorIDs: [String] = []
    var nextPageToken: String?
    var pollingIntervalMillis: Int?
    var offline: Bool = false
    var chatEnded: Bool = false
}

/// Pure request builders and parsers. No state, easy to test with fixtures.
enum YouTubeChatAPI {
    static let base = "https://youtube.googleapis.com/youtube/v3"

    static func videoRequest(videoID: String, token: String) -> URLRequest {
        request("\(base)/videos", ["part": "snippet,liveStreamingDetails", "id": videoID], token: token)
    }

    static func broadcastRequest(broadcastID: String, token: String) -> URLRequest {
        request("\(base)/liveBroadcasts", ["part": "snippet", "id": broadcastID], token: token)
    }

    static func activeBroadcastsRequest(token: String) -> URLRequest {
        request("\(base)/liveBroadcasts", ["part": "snippet", "broadcastStatus": "active", "broadcastType": "all"], token: token)
    }

    static func listRequest(liveChatID: String, pageToken: String?, token: String) -> URLRequest {
        var q = ["liveChatId": liveChatID, "part": "id,snippet,authorDetails", "maxResults": "2000", "profileImageSize": "64"]
        if let pageToken { q["pageToken"] = pageToken }
        return request("\(base)/liveChat/messages", q, token: token)
    }

    static func streamRequest(liveChatID: String, pageToken: String?, token: String) -> URLRequest {
        var q = ["liveChatId": liveChatID, "part": "id,snippet,authorDetails", "maxResults": "2000", "profileImageSize": "64"]
        if let pageToken { q["pageToken"] = pageToken }
        var r = request("\(base)/liveChat/messages/stream", q, token: token)
        r.timeoutInterval = 600
        return r
    }

    private static func request(_ url: String, _ query: [String: String], token: String) -> URLRequest {
        var comps = URLComponents(string: url)!
        comps.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        var r = URLRequest(url: comps.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 20
        return r
    }

    /// Chat id and title for a video. Nil chat id means the video has no active chat.
    static func parseVideo(_ data: Data) throws -> (chatID: String?, title: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YouTubeChatError.malformed }
        guard let item = (obj["items"] as? [[String: Any]])?.first else { throw YouTubeChatError.notFound }
        let details = item["liveStreamingDetails"] as? [String: Any]
        let title = (item["snippet"] as? [String: Any])?["title"] as? String
        return (details?["activeLiveChatId"] as? String, title)
    }

    static func parseBroadcasts(_ data: Data) throws -> (chatID: String?, title: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YouTubeChatError.malformed }
        for item in obj["items"] as? [[String: Any]] ?? [] {
            let snippet = item["snippet"] as? [String: Any]
            if let chat = snippet?["liveChatId"] as? String, !chat.isEmpty {
                return (chat, snippet?["title"] as? String)
            }
        }
        return (nil, nil)
    }

    static func parsePage(_ data: Data) throws -> YouTubeChatPage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YouTubeChatError.malformed }
        return parsePage(obj)
    }

    static func parsePage(_ obj: [String: Any]) -> YouTubeChatPage {
        var page = YouTubeChatPage()
        page.nextPageToken = obj["nextPageToken"] as? String
        page.pollingIntervalMillis = (obj["pollingIntervalMillis"] as? NSNumber)?.intValue
        page.offline = obj["offlineAt"] != nil
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        for item in obj["items"] as? [[String: Any]] ?? [] {
            let snippet = item["snippet"] as? [String: Any] ?? [:]
            let type = snippet["type"] as? String ?? ""
            switch type {
            case "chatEndedEvent":
                page.chatEnded = true
                continue
            case "messageDeletedEvent":
                if let id = (snippet["messageDeletedDetails"] as? [String: Any])?["deletedMessageId"] as? String {
                    page.removedMessageIDs.append(id)
                }
                continue
            case "userBannedEvent":
                let banned = (snippet["userBannedDetails"] as? [String: Any])?["bannedUserDetails"] as? [String: Any]
                if let channel = banned?["channelId"] as? String { page.bannedAuthorIDs.append(channel) }
                continue
            default:
                break
            }
            guard let kind = kind(for: type) else { continue }
            guard let id = item["id"] as? String else { continue }
            let author = item["authorDetails"] as? [String: Any] ?? [:]
            var text = (snippet["displayMessage"] as? String)
                ?? ((snippet["textMessageDetails"] as? [String: Any])?["messageText"] as? String)
                ?? ""
            var amount: String?
            if let sc = snippet["superChatDetails"] as? [String: Any] {
                amount = sc["amountDisplayString"] as? String
                if let comment = sc["userComment"] as? String { text = comment }
            } else if let ss = snippet["superStickerDetails"] as? [String: Any] {
                amount = ss["amountDisplayString"] as? String
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, kind == "text" { continue }
            let published = (snippet["publishedAt"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } ?? Date()
            page.messages.append(LiveChatMessage(
                id: "youtube:\(id)",
                senderName: (author["displayName"] as? String) ?? "Viewer",
                senderAvatarUrl: author["profileImageUrl"] as? String,
                platformSource: "YouTube",
                messageText: text,
                timestamp: published,
                externalID: id,
                authorID: author["channelId"] as? String,
                authorRole: role(author),
                kind: kind,
                amountDisplay: amount
            ))
        }
        return page
    }

    static func kind(for type: String) -> String? {
        switch type {
        case "textMessageEvent": return "text"
        case "superChatEvent": return "superChat"
        case "superStickerEvent": return "superSticker"
        case "newSponsorEvent", "memberMilestoneChatEvent", "membershipGiftingEvent", "giftMembershipReceivedEvent":
            return "membership"
        default: return nil
        }
    }

    static func role(_ author: [String: Any]) -> String? {
        if author["isChatOwner"] as? Bool == true { return "owner" }
        if author["isChatModerator"] as? Bool == true { return "moderator" }
        if author["isChatSponsor"] as? Bool == true { return "member" }
        if author["isVerified"] as? Bool == true { return "verified" }
        return nil
    }

    /// Maps an HTTP error to a typed error using the Google error reason.
    static func error(status: Int, body: Data) -> YouTubeChatError {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        let reasons = ((err?["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
            + [((err?["details"] as? [[String: Any]])?.first?["reason"] as? String)].compactMap { $0 }
        let message = (err?["message"] as? String ?? "").lowercased()
        func has(_ r: String) -> Bool { reasons.contains(r) || message.contains(r.lowercased()) }
        if has("liveChatEnded") { return .ended }
        if has("liveChatDisabled") { return .disabled }
        if has("liveChatNotFound") { return .notFound }
        if has("quotaExceeded") || has("dailyLimitExceeded") { return .quotaExceeded }
        if has("rateLimitExceeded") || status == 429 { return .rateLimited }
        if status == 401 { return .unauthorized }
        if status == 403 { return .forbidden }
        if status == 404 && err == nil { return .streamUnsupported }
        if status == 404 { return .notFound }
        return .http(status)
    }
}

/// Splits a byte stream into top level JSON objects. Accepts a JSON array
/// (`[{..},{..}`) or newline framed objects. Bytes outside objects are ignored.
struct JSONObjectFramer {
    private var buffer: [UInt8] = []
    private var depth = 0
    private var inString = false
    private var escaped = false
    static let maxObjectBytes = 8 * 1024 * 1024

    mutating func feed(_ byte: UInt8) -> Data? {
        if depth == 0 {
            guard byte == UInt8(ascii: "{") else { return nil }
            buffer.removeAll(keepingCapacity: true)
        }
        buffer.append(byte)
        if buffer.count > Self.maxObjectBytes {
            reset()
            return nil
        }
        if inString {
            if escaped { escaped = false }
            else if byte == UInt8(ascii: "\\") { escaped = true }
            else if byte == UInt8(ascii: "\"") { inString = false }
            return nil
        }
        switch byte {
        case UInt8(ascii: "\""): inString = true
        case UInt8(ascii: "{"): depth += 1
        case UInt8(ascii: "}"):
            depth -= 1
            if depth == 0 {
                let out = Data(buffer)
                buffer.removeAll(keepingCapacity: true)
                return out
            }
        default: break
        }
        return nil
    }

    mutating func feed(_ data: Data) -> [Data] {
        var out: [Data] = []
        for b in data { if let o = feed(b) { out.append(o) } }
        return out
    }

    mutating func reset() {
        buffer.removeAll()
        depth = 0
        inString = false
        escaped = false
    }
}

/// Byte level HTTP for the stream endpoint. Swappable in tests.
protocol ChatStreamTransport: Sendable {
    /// Returns status and an async sequence of raw chunks.
    func open(_ request: URLRequest) async throws -> (Int, AsyncThrowingStream<Data, Error>)
}

struct URLSessionChatStreamTransport: ChatStreamTransport {
    func open(_ request: URLRequest) async throws -> (Int, AsyncThrowingStream<Data, Error>) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(4096)
                    for try await b in bytes {
                        chunk.append(b)
                        // Flush on object end or at 4 KB so short messages arrive at once.
                        if b == UInt8(ascii: "}") || chunk.count >= 4096 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, stream)
    }
}

/// Events delivered to the main actor.
struct YouTubeChatUpdate: Sendable {
    var state: ChatConnectorState?
    var title: String?
    var page: YouTubeChatPage?
    var quotaUnits: Int?
    var connects: Int?
    var holdSeconds: Double?
    var dayUnits: Int?
}

actor YouTubeChatConnector {
    typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String
    typealias Sleeper = @Sendable (_ seconds: Double) async throws -> Void

    private let transport: any LiveAPITransport
    private let streamTransport: any ChatStreamTransport
    private let token: TokenProvider
    private let sleep: Sleeper
    private let onUpdate: @Sendable (YouTubeChatUpdate) async -> Void
    private let preferStream: Bool
    private let jitter: @Sendable () -> Double

    private(set) var quotaUnits = 0
    private(set) var connects = 0
    private(set) var dayUnits = 0
    private let spendUnits: @Sendable (Int) -> Int
    private let dailyBudget: Int
    private(set) var liveChatID: String?
    private(set) var pageToken: String?
    private var loop: Task<Void, Never>?

    /// Discovery retries (chat id can lag a few seconds behind going live).
    var discoveryAttempts = 6
    static let minPollSeconds = 2.0
    static let maxBackoffSeconds = 60.0

    init(
        transport: any LiveAPITransport = URLSessionLiveTransport(),
        streamTransport: any ChatStreamTransport = URLSessionChatStreamTransport(),
        preferStream: Bool = true,
        token: @escaping TokenProvider,
        sleep: @escaping Sleeper = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.25) },
        dailyBudget: Int = YouTubeQuotaLedger.dailyBudget,
        spendUnits: @escaping @Sendable (Int) -> Int = { YouTubeQuotaLedger.spend($0) },
        onUpdate: @escaping @Sendable (YouTubeChatUpdate) async -> Void
    ) {
        self.transport = transport
        self.streamTransport = streamTransport
        self.preferStream = preferStream
        self.token = token
        self.sleep = sleep
        self.jitter = jitter
        self.onUpdate = onUpdate
        self.dailyBudget = dailyBudget
        self.spendUnits = spendUnits
    }

    /// Charges units against the local daily ledger. Throws before the call
    /// would push today's total past the budget.
    private func charge(_ units: Int) throws {
        if dayUnits == 0 { dayUnits = spendUnits(0) }
        guard dayUnits + units <= dailyBudget else { throw YouTubeChatError.budgetReached }
        quotaUnits += units
        dayUnits = spendUnits(units)
    }

    func start(_ target: YouTubeChatTarget) {
        loop?.cancel()
        pageToken = nil
        liveChatID = nil
        loop = Task.detached(priority: .utility) { [weak self] in
            await self?.run(target)
        }
    }

    func stop() async {
        loop?.cancel()
        loop = nil
        await onUpdate(YouTubeChatUpdate(state: .idle))
    }

    /// Waits for the current loop to finish. Tests only.
    func waitUntilFinished() async {
        await loop?.value
    }

    static func backoff(attempt: Int, jitter: Double) -> Double {
        let base = min(maxBackoffSeconds, pow(2.0, Double(max(0, attempt - 1))))
        return min(maxBackoffSeconds, base * (1 + jitter))
    }

    private func emit(_ state: ChatConnectorState) async {
        await onUpdate(YouTubeChatUpdate(state: state, quotaUnits: quotaUnits, connects: connects, dayUnits: dayUnits))
    }

    private func run(_ target: YouTubeChatTarget) async {
        await emit(.resolving)
        let chatID: String
        do {
            chatID = try await resolve(target)
        } catch {
            if Task.isCancelled { return }
            let e = error as? YouTubeChatError ?? .malformed
            await emit(e == .ended ? .ended : .failed(e.reason))
            return
        }
        liveChatID = chatID
        var useStream = preferStream
        var attempt = 0
        var streamFailures = 0
        var refreshed = false
        while !Task.isCancelled {
            do {
                if useStream {
                    await emit(.streaming)
                    try await runStream(chatID: chatID)
                    refreshed = false
                    // Server closed cleanly. Resume from the last page token.
                    attempt = 0
                    streamFailures = 0
                    try await sleep(1)
                } else {
                    let page = try await fetchPage(chatID: chatID)
                    attempt = 0
                    refreshed = false
                    await emit(.polling)
                    if page.chatEnded || page.offline {
                        await emit(.ended)
                        return
                    }
                    let wait = max(Self.minPollSeconds, Double(page.pollingIntervalMillis ?? 5000) / 1000)
                    try await sleep(wait)
                }
            } catch is CancellationError {
                return
            } catch let e as YouTubeChatError {
                if Task.isCancelled { return }
                switch e {
                case .ended:
                    await emit(.ended); return
                case _ where e.isTerminal:
                    await emit(.failed(e.reason)); return
                case .unauthorized:
                    if refreshed { await emit(.failed(e.reason)); return }
                    refreshed = true
                    forceRefreshNext = true
                    continue
                case .streamUnsupported, .malformed:
                    if useStream { useStream = false; continue }
                    attempt += 1
                case .rateLimited:
                    attempt += 1
                default:
                    attempt += 1
                    if useStream {
                        streamFailures += 1
                        if streamFailures >= 3 { useStream = false }
                    }
                }
                let wait = Self.backoff(attempt: attempt, jitter: jitter())
                await emit(.retrying(seconds: Int(wait.rounded(.up))))
                do { try await sleep(wait) } catch { return }
            } catch {
                if Task.isCancelled { return }
                attempt += 1
                if useStream {
                    streamFailures += 1
                    if streamFailures >= 3 { useStream = false }
                }
                let wait = Self.backoff(attempt: attempt, jitter: jitter())
                await emit(.retrying(seconds: Int(wait.rounded(.up))))
                do { try await sleep(wait) } catch { return }
            }
        }
    }

    private var forceRefreshNext = false

    private func currentToken() async throws -> String {
        let force = forceRefreshNext
        forceRefreshNext = false
        do {
            return try await token(force)
        } catch {
            throw YouTubeChatError.unauthorized
        }
    }

    private func send(_ request: URLRequest, units: Int) async throws -> Data {
        try charge(units)
        let (data, response) = try await transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw YouTubeChatAPI.error(status: status, body: data) }
        return data
    }

    func resolve(_ target: YouTubeChatTarget) async throws -> String {
        switch target {
        case .chatID(let id):
            return id
        case .video(let input):
            guard let videoID = YouTubeChatTarget.videoID(from: input) else { throw YouTubeChatError.notFound }
            let data = try await send(YouTubeChatAPI.videoRequest(videoID: videoID, token: try await currentToken()), units: 1)
            let (chat, title) = try YouTubeChatAPI.parseVideo(data)
            await onUpdate(YouTubeChatUpdate(title: title, quotaUnits: quotaUnits))
            guard let chat else { throw YouTubeChatError.noActiveChat }
            return chat
        case .broadcast, .autoActive:
            for i in 0..<max(1, discoveryAttempts) {
                try Task.checkCancellation()
                let tok = try await currentToken()
                let request: URLRequest
                if case .broadcast(let id) = target, !id.isEmpty {
                    request = YouTubeChatAPI.broadcastRequest(broadcastID: id, token: tok)
                } else {
                    request = YouTubeChatAPI.activeBroadcastsRequest(token: tok)
                }
                let (chat, title) = try YouTubeChatAPI.parseBroadcasts(try await send(request, units: 1))
                if let chat {
                    await onUpdate(YouTubeChatUpdate(title: title, quotaUnits: quotaUnits))
                    return chat
                }
                if i < discoveryAttempts - 1 { try await sleep(10) }
            }
            throw YouTubeChatError.noActiveChat
        }
    }

    private func deliver(_ page: YouTubeChatPage) async {
        if let next = page.nextPageToken { pageToken = next }
        guard !page.messages.isEmpty || !page.removedMessageIDs.isEmpty || !page.bannedAuthorIDs.isEmpty else { return }
        await onUpdate(YouTubeChatUpdate(page: page, quotaUnits: quotaUnits))
    }

    private func fetchPage(chatID: String) async throws -> YouTubeChatPage {
        let request = YouTubeChatAPI.listRequest(liveChatID: chatID, pageToken: pageToken, token: try await currentToken())
        let page = try YouTubeChatAPI.parsePage(try await send(request, units: 5))
        await deliver(page)
        return page
    }

    private func runStream(chatID: String) async throws {
        let request = YouTubeChatAPI.streamRequest(liveChatID: chatID, pageToken: pageToken, token: try await currentToken())
        try charge(5)
        connects += 1
        let opened = Date()
        defer {
            let held = Date().timeIntervalSince(opened)
            let update = YouTubeChatUpdate(quotaUnits: quotaUnits, connects: connects, holdSeconds: held, dayUnits: dayUnits)
            Task { [onUpdate] in await onUpdate(update) }
        }
        let (status, chunks) = try await streamTransport.open(request)
        var framer = JSONObjectFramer()
        if !(200..<300).contains(status) {
            var body = Data()
            for try await c in chunks {
                body.append(c)
                if body.count > 64 * 1024 { break }
            }
            throw YouTubeChatAPI.error(status: status, body: body)
        }
        var gotAny = false
        for try await chunk in chunks {
            try Task.checkCancellation()
            for objectData in framer.feed(chunk) {
                guard let obj = (try? JSONSerialization.jsonObject(with: objectData)) as? [String: Any] else {
                    throw YouTubeChatError.malformed
                }
                if obj["error"] != nil {
                    throw YouTubeChatAPI.error(status: (obj["error"] as? [String: Any])?["code"] as? Int ?? 500, body: objectData)
                }
                gotAny = true
                let page = YouTubeChatAPI.parsePage(obj)
                await deliver(page)
                if page.chatEnded || page.offline { throw YouTubeChatError.ended }
            }
        }
        if !gotAny { throw YouTubeChatError.streamUnsupported }
    }
}
