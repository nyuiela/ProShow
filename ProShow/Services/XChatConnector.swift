import Foundation

// Live chat ingest, Phase 2 (X). See docs/PROSHOW_LIVE_CHAT_PLAN.md.
// Isolation: network, parsing, spend accounting and backoff run on the
// connector actor at utility priority. Only message batches and state changes
// hop to the main actor. Nothing here touches audio, the encoder, or the compositor.

/// The X chat sign-in is separate from the X destination account so the
/// destination's working scopes are never changed. Tokens live in the keychain
/// under this fixed account id (oauth.access/refresh/expires.<id>).
enum XChatAuth {
    static let accountID = UUID(uuidString: "6D2B8E4A-5C1F-4E7A-9B3D-0A1C2E3F4B5D")!
    /// Exact names from the X API v2 OpenAPI spec.
    static let scopes = "tweet.read users.read broadcast.read broadcast.write offline.access"
    static let usernameKey = "proshow.liveChat.xChatUsername"
    /// Author avatars need the author_id expansion: about $0.01 per new author per UTC day.
    /// `defaults write com.kaleel.proshow proshow.liveChat.xAvatars -bool NO` to save that.
    static let avatarsKey = "proshow.liveChat.xAvatars"
    static var avatars: Bool { UserDefaults.standard.object(forKey: avatarsKey) as? Bool ?? true }
}

/// Estimated X API spend per UTC day. X bills pay per use per resource returned
/// and dedupes the same resource within a UTC day, so the ledger counts unique
/// resource keys. Local estimate only; the X developer console is the truth.
struct XChatSpendLedger: Sendable {
    static let defaultsKey = "proshow.liveChat.xSpendLedger"
    static let capKey = "proshow.liveChat.xDailyCapUSD"
    /// Kaleel caps all agents' X spend under $1 a day combined. Chat gets $0.40.
    static let defaultDailyCap = 0.40
    /// No published broadcast rate. Use the Posts read rate for messages and
    /// broadcasts, the User read rate for expanded authors, Post create for sends.
    static let messageRate = 0.005
    static let userRate = 0.010
    static let broadcastRate = 0.005
    static let sendRate = 0.015
    static let maxKeys = 20_000

    static var dailyCap: Double {
        let v = UserDefaults.standard.double(forKey: capKey)
        return v > 0 ? v : defaultDailyCap
    }

    static func dayKey(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Charges each key not yet seen today at its rate. Returns today's total USD.
    @discardableResult
    static func charge(_ items: [(key: String, rate: Double)], now: Date = Date(), defaults: UserDefaults = .standard) -> Double {
        let day = dayKey(now)
        var book = defaults.dictionary(forKey: defaultsKey) ?? [:]
        if book["day"] as? String != day { book = ["day": day, "usd": 0.0, "keys": [String]()] }
        var keys = Set(book["keys"] as? [String] ?? [])
        var usd = book["usd"] as? Double ?? 0
        for item in items where !keys.contains(item.key) {
            if item.key.hasPrefix("send:") == false { keys.insert(item.key) }
            usd += item.rate
        }
        book["usd"] = usd
        book["keys"] = keys.count > maxKeys ? [] : Array(keys)
        defaults.set(book, forKey: defaultsKey)
        return usd
    }

    static func today(now: Date = Date(), defaults: UserDefaults = .standard) -> Double {
        let book = defaults.dictionary(forKey: defaultsKey) ?? [:]
        return book["day"] as? String == dayKey(now) ? (book["usd"] as? Double ?? 0) : 0
    }

    static func isNew(_ key: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        let book = defaults.dictionary(forKey: defaultsKey) ?? [:]
        guard book["day"] as? String == dayKey(now) else { return true }
        return !(book["keys"] as? [String] ?? []).contains(key)
    }
}

enum XChatError: Error, Equatable {
    case unauthorized
    case notAllowed
    case notFound
    case notLive
    case ended
    case rateLimited(resetIn: Double?)
    case budgetReached
    case notConnected
    case emptyMessage
    case rejected
    case http(Int)
    case malformed

    var reason: String {
        switch self {
        case .unauthorized: return "Sign in to X"
        case .notAllowed: return "X app lacks broadcast access"
        case .notFound: return "X broadcast not found"
        case .notLive: return "Not live on X"
        case .ended: return "X broadcast ended"
        case .rateLimited: return "X rate limited"
        case .budgetReached: return "X daily cap reached"
        case .notConnected: return "Connect X chat first"
        case .emptyMessage: return "Type a message"
        case .rejected: return "X rejected the message"
        case .http(let code): return "X error \(code)"
        case .malformed: return "Bad X response"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .notAllowed, .budgetReached, .ended: return true
        default: return false
        }
    }
}

struct XBroadcast: Equatable, Sendable {
    var id: String
    var state: String
    var title: String?
    var hostUserID: String?

    /// X does not enumerate `state`. Treat running/live/started as live.
    var isLive: Bool { ["running", "live", "started", "broadcasting"].contains(state.lowercased()) }
    var isOver: Bool { ["ended", "timed_out", "canceled", "cancelled", "stopped"].contains(state.lowercased()) }
}

struct XChatPage: Equatable, Sendable {
    var messages: [LiveChatMessage] = []
    var userIDs: [String] = []
    var nextToken: String?
}

/// Pure request builders and parsers for X API v2 broadcasts.
enum XChatAPI {
    static let defaultBase = "https://api.x.com/2"
    /// SendBroadcastChatRequest.text maxLength.
    static let maxReplyLength = 140
    /// Page size while messages flow, and while quiet. Chat reads are newest
    /// first with no since id, so each poll re-reads the newest page. X dedupes
    /// repeats within a UTC day (soft guarantee); small quiet pages bound the
    /// cost if dedup ever misses.
    static let pageSize = 10
    static let quietPageSize = 3

    static func listBroadcastsRequest(base: String, token: String) -> URLRequest {
        request("\(base)/broadcasts", [
            "max_results": "5",
            "broadcast.fields": "id,state,title,twitter_user_id,start_ms,chat_option",
        ], token: token)
    }

    static func broadcastRequest(base: String, id: String, token: String) -> URLRequest {
        request("\(base)/broadcasts/\(id)", ["broadcast.fields": "id,state,title,twitter_user_id,chat_option"], token: token)
    }

    static func chatRequest(base: String, id: String, avatars: Bool, pageSize: Int = pageSize, token: String) -> URLRequest {
        var q = [
            "max_results": String(pageSize),
            "broadcast_chat_message.fields": "id,text,author_name,author_username,created_at_ms,reply_to",
        ]
        if avatars {
            q["expansions"] = "author_id"
            q["user.fields"] = "profile_image_url,username,name"
        }
        return request("\(base)/broadcasts/\(id)/chat", q, token: token)
    }

    static func sendRequest(base: String, id: String, text: String, replyTo: String?, token: String) -> URLRequest {
        var r = request("\(base)/broadcasts/\(id)/chat", [:], token: token)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text]
        if let replyTo, isMessageID(replyTo) { body["reply_to"] = replyTo }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    static func isBroadcastID(_ s: String) -> Bool {
        (1...24).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// reply_to pattern ^[0-9]{1,19}$.
    static func isMessageID(_ s: String) -> Bool {
        (1...19).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Accepts a bare id or an x.com/i/broadcasts/<id> link.
    static func broadcastID(from input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isBroadcastID(raw) { return raw }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let comps = URLComponents(string: withScheme), let host = comps.host?.lowercased(),
              host.hasSuffix("x.com") || host.hasSuffix("twitter.com") else { return nil }
        let seg = comps.path.split(separator: "/").map(String.init)
        if let i = seg.firstIndex(of: "broadcasts"), i + 1 < seg.count, isBroadcastID(seg[i + 1]) { return seg[i + 1] }
        return nil
    }

    /// Trims, flattens newlines, caps at 140 characters. Nil when empty.
    static func replyText(_ raw: String) -> String? {
        let flat = raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        return String(flat.prefix(maxReplyLength))
    }

    private static func request(_ url: String, _ query: [String: String], token: String) -> URLRequest {
        var comps = URLComponents(string: url)!
        if !query.isEmpty { comps.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) } }
        var r = URLRequest(url: comps.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 20
        return r
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw XChatError.malformed }
        return obj
    }

    static func parseBroadcast(_ b: [String: Any]) -> XBroadcast? {
        guard let id = b["id"] as? String else { return nil }
        return XBroadcast(id: id, state: b["state"] as? String ?? "", title: b["title"] as? String,
                          hostUserID: b["twitter_user_id"] as? String)
    }

    static func parseBroadcasts(_ data: Data) throws -> [XBroadcast] {
        let obj = try object(data)
        if let list = obj["data"] as? [[String: Any]] { return list.compactMap(parseBroadcast) }
        if let one = obj["data"] as? [String: Any], let b = parseBroadcast(one) { return [b] }
        return []
    }

    static func parseChat(_ data: Data, hostUserID: String?) throws -> XChatPage {
        let obj = try object(data)
        var page = XChatPage()
        page.nextToken = (obj["meta"] as? [String: Any])?["next_token"] as? String
        var users: [String: [String: Any]] = [:]
        for u in (obj["includes"] as? [String: Any])?["users"] as? [[String: Any]] ?? [] {
            if let id = u["id"] as? String { users[id] = u; page.userIDs.append(id) }
        }
        // Newest first from X. Deliver oldest first.
        for m in (obj["data"] as? [[String: Any]] ?? []).reversed() {
            guard let id = m["id"] as? String else { continue }
            let text = (m["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let authorID = m["author_id"] as? String
            let user = authorID.flatMap { users[$0] }
            let username = (m["author_username"] as? String) ?? (user?["username"] as? String)
            let name = (m["author_name"] as? String) ?? (user?["name"] as? String)
            let created = (m["created_at_ms"] as? NSNumber)?.doubleValue
                ?? Double(m["created_at_ms"] as? String ?? "")
            page.messages.append(LiveChatMessage(
                id: "x:\(id)",
                senderName: username.map { "@\($0)" } ?? name ?? "Viewer",
                senderAvatarUrl: user?["profile_image_url"] as? String,
                platformSource: "X",
                messageText: text,
                timestamp: created.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
                externalID: id,
                authorID: authorID,
                authorRole: (authorID != nil && authorID == hostUserID) ? "owner" : nil,
                kind: "text",
                amountDisplay: nil
            ))
        }
        return page
    }

    /// Seconds until x-rate-limit-reset (epoch seconds), when present.
    static func resetIn(_ response: HTTPURLResponse?, now: Date = Date()) -> Double? {
        guard let raw = response?.value(forHTTPHeaderField: "x-rate-limit-reset"), let epoch = Double(raw) else { return nil }
        return max(1, epoch - now.timeIntervalSince1970)
    }

    static func error(status: Int, body: Data, response: HTTPURLResponse?) -> XChatError {
        let text = String(decoding: body.prefix(4096), as: UTF8.self).lowercased()
        switch status {
        case 401: return .unauthorized
        case 429: return .rateLimited(resetIn: resetIn(response))
        case 403:
            if text.contains("not live") || text.contains("not running") { return .notLive }
            return .notAllowed
        case 404: return .notFound
        case 400:
            if text.contains("not live") || text.contains("not running") || text.contains("ended") { return .notLive }
            return .rejected
        default: return .http(status)
        }
    }
}

struct XChatUpdate: Sendable {
    var state: ChatConnectorState?
    var broadcastID: String?
    var title: String?
    var page: XChatPage?
    var requests: Int?
    var dayUSD: Double?
}

actor XChatConnector {
    typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String
    typealias Sleeper = @Sendable (_ seconds: Double) async throws -> Void

    enum Target: Equatable, Sendable {
        case broadcast(String)
        case auto
    }

    private let transport: any LiveAPITransport
    private let base: String
    private let token: TokenProvider
    private let sleep: Sleeper
    private let onUpdate: @Sendable (XChatUpdate) async -> Void
    private let dailyCap: Double
    private let charge: @Sendable ([(key: String, rate: Double)]) -> Double
    private let isNewKey: @Sendable (String) -> Bool
    private let avatars: Bool

    private(set) var broadcast: XBroadcast?
    private(set) var requests = 0
    private(set) var dayUSD = 0.0
    private var seen = Set<String>()
    private var loop: Task<Void, Never>?
    private var forceRefreshNext = false
    private(set) var pageSize = XChatAPI.pageSize

    /// Poll cadence. Fast while messages arrive, slower when quiet.
    static let activeSeconds = 10.0
    static let quietSeconds = 30.0
    /// Discovery cadence while not live, backing off to the max.
    static let waitingSeconds = 60.0
    static let waitingMaxSeconds = 180.0
    static let maxBackoffSeconds = 120.0
    static let maxRateLimitWait = 900.0
    /// Re-check the broadcast state this often while reading.
    static let stateCheckSeconds = 300.0

    init(
        transport: any LiveAPITransport = URLSessionLiveTransport(),
        base: String = XChatAPI.defaultBase,
        avatars: Bool = true,
        token: @escaping TokenProvider,
        sleep: @escaping Sleeper = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
        dailyCap: Double = XChatSpendLedger.dailyCap,
        charge: @escaping @Sendable ([(key: String, rate: Double)]) -> Double = { XChatSpendLedger.charge($0) },
        isNewKey: @escaping @Sendable (String) -> Bool = { XChatSpendLedger.isNew($0) },
        onUpdate: @escaping @Sendable (XChatUpdate) async -> Void
    ) {
        self.transport = transport
        self.base = base
        self.avatars = avatars
        self.token = token
        self.sleep = sleep
        self.dailyCap = dailyCap
        self.charge = charge
        self.isNewKey = isNewKey
        self.onUpdate = onUpdate
    }

    func start(_ target: Target) {
        loop?.cancel()
        broadcast = nil
        seen.removeAll()
        loop = Task.detached(priority: .utility) { [weak self] in
            await self?.run(target)
        }
    }

    func stop() async {
        loop?.cancel()
        loop = nil
        await onUpdate(XChatUpdate(state: .idle))
    }

    func waitUntilFinished() async { await loop?.value }

    var broadcastID: String? { broadcast?.id }

    static func backoff(attempt: Int) -> Double {
        min(maxBackoffSeconds, 5 * pow(2.0, Double(max(0, attempt - 1))))
    }

    /// Worst case cost of one chat page, used to stop before the cap, never after.
    var worstPageUSD: Double {
        Double(pageSize) * (XChatSpendLedger.messageRate + (avatars ? XChatSpendLedger.userRate : 0))
    }

    private func emit(_ state: ChatConnectorState) async {
        await onUpdate(XChatUpdate(state: state, broadcastID: broadcast?.id, title: broadcast?.title, requests: requests, dayUSD: dayUSD))
    }

    private func currentToken() async throws -> String {
        let force = forceRefreshNext
        forceRefreshNext = false
        do { return try await token(force) } catch { throw XChatError.unauthorized }
    }

    private func ensureBudget(_ needed: Double) throws {
        if dayUSD == 0 { dayUSD = charge([]) }
        guard dayUSD + needed <= dailyCap else { throw XChatError.budgetReached }
    }

    /// One HTTP call with a single forced token refresh on 401.
    private func call(_ build: (String) -> URLRequest) async throws -> Data {
        var refreshed = false
        while true {
            let req = build(try await currentToken())
            requests += 1
            let (data, response) = try await transport.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            let err = XChatAPI.error(status: status, body: data, response: http)
            if err == .unauthorized && !refreshed {
                refreshed = true
                forceRefreshNext = true
                continue
            }
            throw err
        }
    }

    func discover(_ target: Target) async throws -> XBroadcast? {
        try ensureBudget(5 * XChatSpendLedger.broadcastRate)
        let data: Data
        switch target {
        case .broadcast(let id):
            data = try await call { XChatAPI.broadcastRequest(base: base, id: id, token: $0) }
        case .auto:
            data = try await call { XChatAPI.listBroadcastsRequest(base: base, token: $0) }
        }
        let list = try XChatAPI.parseBroadcasts(data)
        dayUSD = charge(list.map { (key: "b:\($0.id)", rate: XChatSpendLedger.broadcastRate) })
        if case .broadcast(let id) = target, let b = list.first(where: { $0.id == id }) {
            // A scheduled broadcast from Go Live may not report running yet.
            if b.isOver { throw XChatError.ended }
            return b.isLive || b.state.isEmpty ? b : nil
        }
        return list.first(where: { $0.isLive })
    }

    private func poll(_ b: XBroadcast) async throws -> Int {
        try ensureBudget(worstPageUSD)
        let size = pageSize
        let data = try await call { XChatAPI.chatRequest(base: base, id: b.id, avatars: avatars, pageSize: size, token: $0) }
        let page = try XChatAPI.parseChat(data, hostUserID: b.hostUserID)
        var items = page.messages.compactMap { $0.externalID }.map { (key: "m:\($0)", rate: XChatSpendLedger.messageRate) }
        items += page.userIDs.map { (key: "u:\($0)", rate: XChatSpendLedger.userRate) }
        dayUSD = charge(items)
        var fresh = page
        fresh.messages = page.messages.filter { seen.insert($0.id).inserted }
        pageSize = fresh.messages.isEmpty ? XChatAPI.quietPageSize : XChatAPI.pageSize
        if !fresh.messages.isEmpty { await onUpdate(XChatUpdate(page: fresh, requests: requests, dayUSD: dayUSD)) }
        return fresh.messages.count
    }

    private func run(_ initial: Target) async {
        var target = initial
        var attempt = 0
        var waitingDelay = Self.waitingSeconds
        var lastStateCheck = Date()
        var quietPolls = 0
        await emit(.resolving)
        while !Task.isCancelled {
            do {
                if broadcast == nil {
                    if let b = try await discover(target) {
                        broadcast = b
                        lastStateCheck = Date()
                        waitingDelay = Self.waitingSeconds
                        attempt = 0
                        await emit(.polling)
                    } else {
                        // A Go Live id that never turns live falls back to discovery.
                        if case .broadcast = target { target = .auto }
                        await emit(.failed(XChatError.notLive.reason))
                        try await sleep(waitingDelay)
                        waitingDelay = min(Self.waitingMaxSeconds, waitingDelay * 1.5)
                        continue
                    }
                }
                guard let b = broadcast else { continue }
                if Date().timeIntervalSince(lastStateCheck) >= Self.stateCheckSeconds {
                    lastStateCheck = Date()
                    if try await discover(.broadcast(b.id)) == nil { throw XChatError.notLive }
                }
                let added = try await poll(b)
                attempt = 0
                quietPolls = added > 0 ? 0 : quietPolls + 1
                await emit(.polling)
                try await sleep(quietPolls >= 3 ? Self.quietSeconds : Self.activeSeconds)
            } catch is CancellationError {
                return
            } catch let e as XChatError {
                if Task.isCancelled { return }
                switch e {
                case .ended:
                    await emit(.ended); return
                case _ where e.isTerminal:
                    await emit(.failed(e.reason)); return
                case .unauthorized:
                    await emit(.failed(e.reason)); return
                case .notFound, .notLive:
                    // Broadcast gone or not running: look for a live one again.
                    broadcast = nil
                    target = .auto
                    await emit(.failed(XChatError.notLive.reason))
                    do { try await sleep(waitingDelay) } catch { return }
                    waitingDelay = min(Self.waitingMaxSeconds, waitingDelay * 1.5)
                case .rateLimited(let reset):
                    attempt += 1
                    let wait = min(Self.maxRateLimitWait, (reset ?? Self.backoff(attempt: attempt)) + 1)
                    await emit(.retrying(seconds: Int(wait.rounded(.up))))
                    do { try await sleep(wait) } catch { return }
                default:
                    attempt += 1
                    let wait = Self.backoff(attempt: attempt)
                    await emit(.retrying(seconds: Int(wait.rounded(.up))))
                    do { try await sleep(wait) } catch { return }
                }
            } catch {
                if Task.isCancelled { return }
                attempt += 1
                let wait = Self.backoff(attempt: attempt)
                await emit(.retrying(seconds: Int(wait.rounded(.up))))
                do { try await sleep(wait) } catch { return }
            }
        }
    }

    /// Posts one message to the live broadcast's chat. Call only from an explicit
    /// operator action (Send or Return). Returns a local copy for the inbox.
    func send(_ raw: String, replyTo: String?, as sender: String?) async throws -> LiveChatMessage {
        guard let text = XChatAPI.replyText(raw) else { throw XChatError.emptyMessage }
        guard let b = broadcast else { throw XChatError.notConnected }
        try ensureBudget(XChatSpendLedger.sendRate)
        let data = try await call { XChatAPI.sendRequest(base: base, id: b.id, text: text, replyTo: replyTo, token: $0) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let result = obj?["data"] as? [String: Any]
        guard result?["success"] as? Bool != false else { throw XChatError.rejected }
        let stamp = (result?["timestamp"] as? String) ?? String(Int(Date().timeIntervalSince1970 * 1e9))
        dayUSD = charge([(key: "send:\(stamp)", rate: XChatSpendLedger.sendRate)])
        return LiveChatMessage(
            id: "x:sent:\(stamp)",
            senderName: sender ?? "You",
            senderAvatarUrl: nil,
            platformSource: "X",
            messageText: text,
            timestamp: Date(),
            externalID: nil,
            authorID: nil,
            authorRole: "owner",
            kind: "text",
            amountDisplay: nil
        )
    }
}
