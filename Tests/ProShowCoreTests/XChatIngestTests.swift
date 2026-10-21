#if canImport(ProShowCore)
@testable import ProShowCore
#endif
import Foundation
import Testing

enum XChatFixtures {
    static let running = #"{"data":[{"id":"1OwxWaaa","state":"ended","title":"Old"},{"id":"1LyxBbbb","state":"running","title":"Kaleel live","twitter_user_id":"42"}]}"#
    static let notRunning = #"{"data":[{"id":"1OwxWaaa","state":"ended","title":"Old"}]}"#
    static let one = #"{"data":{"id":"1LyxBbbb","state":"running","title":"Kaleel live","twitter_user_id":"42"}}"#
    static let chat1 = #"""
    {"data":[
      {"id":"1700000000000000002","text":"second","author_id":"7","author_username":"ada","author_name":"Ada","created_at_ms":1700000002000},
      {"id":"1700000000000000001","text":"hello from X","author_id":"42","author_username":"kaleel","author_name":"Kaleel","created_at_ms":1700000001000}
    ],"includes":{"users":[{"id":"7","username":"ada","name":"Ada","profile_image_url":"https://pbs.twimg.com/a.jpg"},{"id":"42","username":"kaleel","name":"Kaleel"}]},
    "meta":{"result_count":2}}
    """#
    static let chat2 = #"""
    {"data":[
      {"id":"1700000000000000003","text":"third","author_id":"7","author_username":"ada","created_at_ms":1700000003000},
      {"id":"1700000000000000002","text":"second","author_id":"7","author_username":"ada","created_at_ms":1700000002000}
    ],"includes":{"users":[{"id":"7","username":"ada","name":"Ada"}]},"meta":{"result_count":2}}
    """#
    static let empty = #"{"meta":{"result_count":0}}"#
    static let sent = #"{"data":{"success":true,"timestamp":"1700000009000000000"}}"#
}

/// Match is a URL substring, optionally prefixed by "POST ".
final class XFakeTransport: LiveAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(match: String, status: Int, body: String, headers: [String: String])]
    private(set) var requests: [URLRequest] = []

    init(_ queue: [(String, Int, String, [String: String])]) {
        self.queue = queue.map { (match: $0.0, status: $0.1, body: $0.2, headers: $0.3) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let url = request.url!.absoluteString
        let method = request.httpMethod ?? "GET"
        guard let index = queue.firstIndex(where: { q in
            let wantPost = q.match.hasPrefix("POST ")
            let m = wantPost ? String(q.match.dropFirst(5)) : q.match
            return (wantPost == (method == "POST")) && url.contains(m)
        }) else {
            throw URLError(.notConnectedToInternet)
        }
        let next = queue.remove(at: index)
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: next.headers)!
        return (Data(next.body.utf8), response)
    }

    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

actor XLog {
    var updates: [XChatUpdate] = []
    var sleeps: [Double] = []
    var forces: [Bool] = []
    var tokens = 0
    let maxSleeps: Int
    init(maxSleeps: Int = 3) { self.maxSleeps = maxSleeps }
    func add(_ u: XChatUpdate) { updates.append(u) }
    func slept(_ s: Double) throws {
        sleeps.append(s)
        if sleeps.count >= maxSleeps { throw CancellationError() }
    }
    func token(_ force: Bool) -> String { forces.append(force); tokens += 1; return "tok\(tokens)" }
    var messages: [LiveChatMessage] { updates.compactMap { $0.page }.flatMap { $0.messages } }
    var states: [ChatConnectorState] { updates.compactMap { $0.state } }
}

final class XSpend: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()
    private(set) var usd: Double
    init(start: Double = 0) { usd = start }
    func charge(_ items: [(key: String, rate: Double)]) -> Double {
        lock.lock(); defer { lock.unlock() }
        for i in items where keys.insert(i.key).inserted { usd += i.rate }
        return usd
    }
}

struct XChatIngestTests {
    func connector(_ t: XFakeTransport, _ log: XLog, cap: Double = 0.40, spend: XSpend = XSpend(), avatars: Bool = true) -> XChatConnector {
        XChatConnector(
            transport: t, avatars: avatars,
            token: { await log.token($0) },
            sleep: { try await log.slept($0) },
            dailyCap: cap,
            charge: { spend.charge($0) },
            isNewKey: { _ in true },
            onUpdate: { await log.add($0) }
        )
    }

    @Test
    func parseChat_mapsOldestFirstWithAvatarsAndHostRole() throws {
        let page = try XChatAPI.parseChat(Data(XChatFixtures.chat1.utf8), hostUserID: "42")
        #expect(page.messages.count == 2)
        #expect(page.messages[0].messageText == "hello from X")
        #expect(page.messages[0].senderName == "@kaleel")
        #expect(page.messages[0].authorRole == "owner")
        #expect(page.messages[1].senderName == "@ada")
        #expect(page.messages[1].senderAvatarUrl == "https://pbs.twimg.com/a.jpg")
        #expect(page.messages[1].platformSource == "X")
        #expect(page.messages[1].id == "x:1700000000000000002")
        #expect(page.messages[1].externalID == "1700000000000000002")
        #expect(abs(page.messages[1].timestamp.timeIntervalSince1970 - 1700000002) < 0.01)
        #expect(ChatPlatform.from(displayName: page.messages[0].platformSource) == .x)
        #expect(page.userIDs.sorted() == ["42", "7"])
    }

    @Test
    func requests_useDocumentedFieldsAndSmallPages() {
        let r = XChatAPI.chatRequest(base: XChatAPI.defaultBase, id: "1LyxBbbb", avatars: true, token: "t")
        let u = r.url!.absoluteString
        #expect(u.hasPrefix("https://api.x.com/2/broadcasts/1LyxBbbb/chat?"))
        #expect(u.contains("max_results=10"))
        #expect(u.contains("expansions=author_id"))
        #expect(u.contains("user.fields=profile_image_url"))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let noAvatars = XChatAPI.chatRequest(base: XChatAPI.defaultBase, id: "1LyxBbbb", avatars: false, token: "t").url!.absoluteString
        #expect(!noAvatars.contains("expansions"))
        #expect(XChatAPI.listBroadcastsRequest(base: XChatAPI.defaultBase, token: "t").url!.absoluteString.contains("broadcast.fields="))
    }

    @Test
    func sendRequest_capsAt140AndOnlyNumericReplyTo() throws {
        let long = String(repeating: "a", count: 200)
        let text = try #require(XChatAPI.replyText(long + "\n"))
        #expect(text.count == 140)
        #expect(XChatAPI.replyText("  \n ") == nil)
        let r = XChatAPI.sendRequest(base: XChatAPI.defaultBase, id: "1LyxBbbb", text: "hi", replyTo: "1700000000000000002", token: "t")
        #expect(r.httpMethod == "POST")
        let body = try #require(r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["text"] as? String == "hi")
        #expect(body["reply_to"] as? String == "1700000000000000002")
        let r2 = XChatAPI.sendRequest(base: XChatAPI.defaultBase, id: "1LyxBbbb", text: "hi", replyTo: "abc", token: "t")
        let body2 = try #require(r2.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body2["reply_to"] == nil)
    }

    @Test
    func broadcastID_acceptsIdAndLinks() {
        #expect(XChatAPI.broadcastID(from: "1LyxBbbb") == "1LyxBbbb")
        #expect(XChatAPI.broadcastID(from: "https://x.com/i/broadcasts/1LyxBbbb") == "1LyxBbbb")
        #expect(XChatAPI.broadcastID(from: "twitter.com/i/broadcasts/1LyxBbbb?s=20") == "1LyxBbbb")
        #expect(XChatAPI.broadcastID(from: "https://evil.com/i/broadcasts/1LyxBbbb") == nil)
        #expect(XChatAPI.broadcastID(from: "") == nil)
    }

    @Test
    func autoDiscovery_readsRunningBroadcastAndDedupes() async {
        let t = XFakeTransport([
            ("broadcasts?", 200, XChatFixtures.running, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.chat1, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.chat2, [:]),
        ])
        let log = XLog(maxSleeps: 2)
        let c = connector(t, log)
        await c.start(.auto)
        await c.waitUntilFinished()
        let texts = await log.messages.map(\.messageText)
        #expect(texts == ["hello from X", "second", "third"])
        #expect(await c.broadcastID == "1LyxBbbb")
        #expect(await log.sleeps == [XChatConnector.activeSeconds, XChatConnector.activeSeconds])
        #expect(await log.states.contains(.polling))
    }

    @Test
    func notLive_reportsTerselyAndBacksOffDiscovery() async {
        let t = XFakeTransport([
            ("broadcasts?", 200, XChatFixtures.notRunning, [:]),
            ("broadcasts?", 200, XChatFixtures.notRunning, [:]),
            ("broadcasts?", 200, XChatFixtures.notRunning, [:]),
        ])
        let log = XLog(maxSleeps: 3)
        let c = connector(t, log)
        await c.start(.auto)
        await c.waitUntilFinished()
        #expect(await log.states.contains(.failed("Not live on X")))
        #expect(await log.sleeps == [60, 90, 135])
        #expect(t.all.allSatisfy { !$0.url!.absoluteString.contains("/chat") })
    }

    @Test
    func unauthorized_refreshesOnceThenContinues() async {
        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, XChatFixtures.one, [:]),
            ("1LyxBbbb/chat?", 401, #"{"title":"Unauthorized"}"#, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.chat1, [:]),
        ])
        let log = XLog(maxSleeps: 1)
        let c = connector(t, log)
        await c.start(.broadcast("1LyxBbbb"))
        await c.waitUntilFinished()
        #expect(await log.forces == [false, false, true])
        #expect(await log.messages.count == 2)
        let auths = t.all.map { $0.value(forHTTPHeaderField: "Authorization") ?? "" }
        #expect(auths.last == "Bearer tok3")
    }

    @Test
    func unauthorizedTwice_failsSignInToX() async {
        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, XChatFixtures.one, [:]),
            ("1LyxBbbb/chat?", 401, "{}", [:]),
            ("1LyxBbbb/chat?", 401, "{}", [:]),
        ])
        let log = XLog(maxSleeps: 5)
        let c = connector(t, log)
        await c.start(.broadcast("1LyxBbbb"))
        await c.waitUntilFinished()
        #expect(await log.states.last == .failed("Sign in to X"))
    }

    @Test
    func rateLimited_waitsForResetHeader() async {
        let reset = String(Int(Date().timeIntervalSince1970) + 40)
        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, XChatFixtures.one, [:]),
            ("1LyxBbbb/chat?", 429, #"{"title":"Too Many Requests"}"#, ["x-rate-limit-reset": reset]),
            ("1LyxBbbb/chat?", 429, "{}", [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.chat1, [:]),
        ])
        let log = XLog(maxSleeps: 3)
        let c = connector(t, log)
        await c.start(.broadcast("1LyxBbbb"))
        await c.waitUntilFinished()
        let sleeps = await log.sleeps
        #expect(sleeps.count == 3)
        #expect(sleeps[0] >= 39 && sleeps[0] <= 42)
        // No header: exponential backoff, attempt 2 = 10 s, plus 1.
        #expect(sleeps[1] == 11)
        #expect(sleeps[2] == XChatConnector.activeSeconds)
        #expect(await log.messages.count == 2)
        #expect(await log.states.contains(.retrying(seconds: 11)))
    }

    @Test
    func serverErrors_backOffExponentially() async {
        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, XChatFixtures.one, [:]),
            ("1LyxBbbb/chat?", 503, "{}", [:]),
            ("1LyxBbbb/chat?", 503, "{}", [:]),
            ("1LyxBbbb/chat?", 503, "{}", [:]),
        ])
        let log = XLog(maxSleeps: 3)
        let c = connector(t, log)
        await c.start(.broadcast("1LyxBbbb"))
        await c.waitUntilFinished()
        #expect(await log.sleeps == [5, 10, 20])
    }

    @Test
    func quietChat_slowsTo30s() async {
        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, XChatFixtures.one, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.empty, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.empty, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.empty, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.empty, [:]),
        ])
        let log = XLog(maxSleeps: 4)
        let c = connector(t, log)
        await c.start(.broadcast("1LyxBbbb"))
        await c.waitUntilFinished()
        #expect(await log.sleeps == [10, 10, 30, 30])
        // First poll asks for 10, quiet polls after it ask for 3.
        let sizes = t.all.compactMap { r -> String? in
            guard r.url!.absoluteString.contains("/chat?") else { return nil }
            return URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "max_results" }?.value
        }
        #expect(sizes == ["10", "3", "3", "3"])
    }

    @Test
    func budget_stopsBeforeCapNeverAfter() async {
        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, XChatFixtures.one, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.chat1, [:]),
        ])
        let log = XLog(maxSleeps: 5)
        // 0.40 cap, 0.30 spent: discovery fits, a worst case page (10 x 0.015) does not.
        let c = connector(t, log, spend: XSpend(start: 0.30))
        await c.start(.broadcast("1LyxBbbb"))
        await c.waitUntilFinished()
        #expect(await log.states.last == .failed("X daily cap reached"))
        #expect(t.all.allSatisfy { !$0.url!.absoluteString.contains("/chat") })
    }

    @Test
    func spend_countsUniqueResourcesOnce() async {
        let spend = XSpend()
        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, XChatFixtures.one, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.chat1, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.chat1, [:]),
        ])
        let log = XLog(maxSleeps: 2)
        let c = connector(t, log, spend: spend)
        await c.start(.broadcast("1LyxBbbb"))
        await c.waitUntilFinished()
        // 1 broadcast + 2 messages at 0.005, 2 users at 0.010.
        #expect(abs(spend.usd - 0.035) < 1e-9)
    }

    @Test
    func send_postsAfterRefreshAndReturnsLocalCopy() async throws {
        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, XChatFixtures.one, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.empty, [:]),
            ("POST 1LyxBbbb/chat", 401, "{}", [:]),
            ("POST 1LyxBbbb/chat", 200, XChatFixtures.sent, [:]),
        ])
        let log = XLog(maxSleeps: 1)
        let c = connector(t, log)
        await c.start(.broadcast("1LyxBbbb"))
        await c.waitUntilFinished()
        let posted = try await c.send("thanks Ada", replyTo: "1700000000000000002", as: "Kaleel")
        #expect(posted.messageText == "thanks Ada")
        #expect(posted.platformSource == "X")
        #expect(posted.senderName == "Kaleel")
        let posts = t.all.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2)
        #expect(posts.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok4")
    }

    @Test
    func send_withoutBroadcastFails() async {
        let log = XLog()
        let c = connector(XFakeTransport([]), log)
        await #expect(throws: XChatError.notConnected) { _ = try await c.send("hi", replyTo: nil, as: nil) }
        await #expect(throws: XChatError.emptyMessage) { _ = try await c.send("  ", replyTo: nil, as: nil) }
    }

    @Test
    func endedBroadcast_stops() async {
        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, #"{"data":{"id":"1LyxBbbb","state":"ended"}}"#, [:]),
        ])
        let log = XLog(maxSleeps: 3)
        let c = connector(t, log)
        await c.start(.broadcast("1LyxBbbb"))
        await c.waitUntilFinished()
        #expect(await log.states.last == .ended)
    }

    @Test
    func forbidden_isTerminalAppAccess() async {
        let t = XFakeTransport([
            ("broadcasts?", 403, #"{"title":"Forbidden","reason":"client-not-enrolled"}"#, [:]),
        ])
        let log = XLog(maxSleeps: 3)
        let c = connector(t, log)
        await c.start(.auto)
        await c.waitUntilFinished()
        #expect(await log.states.last == .failed("X app lacks broadcast access"))
        #expect(await log.sleeps.isEmpty)
    }

    @Test @MainActor
    func hub_routesXRepliesOnlyWhenConnected() async throws {
        let stream = LiveChatStreamManager(chatEngine: LiveChatEngine())
        let hub = ChatIngestHub(stream: stream)
        let defaultsKey = LiveChatIngestFlags.liveChatIngestV1Key
        let was = UserDefaults.standard.object(forKey: defaultsKey)
        LiveChatIngestFlags.liveChatIngestV1 = true
        defer { UserDefaults.standard.set(was, forKey: defaultsKey) }

        let viewer = LiveChatMessage(id: "x:1700000000000000002", senderName: "@ada", platformSource: "X",
                                     messageText: "second", externalID: "1700000000000000002")
        hub.setReplyTarget(viewer)
        #expect(hub.replyPlatform == .x)
        #expect(hub.replyBlockedReason == "Sign in to X")

        let t = XFakeTransport([
            ("broadcasts/1LyxBbbb?", 200, XChatFixtures.one, [:]),
            ("1LyxBbbb/chat?", 200, XChatFixtures.chat1, [:]),
            ("POST 1LyxBbbb/chat", 200, XChatFixtures.sent, [:]),
        ])
        let log = XLog(maxSleeps: 50)
        hub.xSignedIn = true
        hub.xTokenProvider = { _ in "tok" }
        hub.makeXConnector = { token, onUpdate in
            XChatConnector(transport: t, token: token, sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) },
                           dailyCap: 1, charge: { _ in 0 }, isNewKey: { _ in true }, onUpdate: { await log.add($0); await onUpdate($0) })
        }
        #expect(hub.connectX(.broadcast("1LyxBbbb")))
        for _ in 0..<200 where hub.xBroadcastID == nil || hub.xMessageCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(hub.xBroadcastID == "1LyxBbbb")
        #expect(hub.xMessageCount == 2)
        #expect(stream.inbox.contains { $0.id == "x:1700000000000000001" })
        // Ingest does not put anything on screen.
        #expect(stream.activeOverlay == nil)
        #expect(hub.replyBlockedReason == nil)
        hub.replyDraft = "thanks"
        await hub.sendReply()
        #expect(hub.replyError == nil)
        #expect(hub.replyDraft.isEmpty)
        let post = try #require(t.all.first { $0.httpMethod == "POST" })
        let body = try #require(post.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["reply_to"] as? String == "1700000000000000002")
        #expect(body["text"] as? String == "thanks")
        #expect(hub.xStatusLine == nil)
        #expect(hub.replyTarget == nil)
        hub.stopX()
        hub.setReplyTarget(viewer)
        #expect(hub.replyBlockedReason == "Connect X chat first")
    }
}
