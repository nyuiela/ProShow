#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

// Fixtures follow the liveChatMessageListResponse shape from
// https://developers.google.com/youtube/v3/live/docs/liveChatMessages
// Ids and names are synthetic. No tokens.
enum YouTubeChatFixtures {
    static let videoLive = #"""
    {"kind":"youtube#videoListResponse","items":[{"id":"jfKfPfyJRdk","snippet":{"title":"lofi radio"},
     "liveStreamingDetails":{"actualStartTime":"2026-10-20T10:00:00Z","activeLiveChatId":"Cg0KC2pmS2ZQZnlKUmRr"}}]}
    """#
    static let videoNoChat = #"""
    {"kind":"youtube#videoListResponse","items":[{"id":"dQw4w9WgXcQ","snippet":{"title":"vod"}}]}
    """#
    static let broadcastActive = #"""
    {"items":[{"id":"bc1","snippet":{"title":"Kaleel Streams","liveChatId":"CHAT_BC1"}}]}
    """#
    static let broadcastEmpty = #"{"items":[]}"#

    static let page1 = #"""
    {"kind":"youtube#liveChatMessageListResponse","nextPageToken":"TOK1","pollingIntervalMillis":3000,
     "items":[
      {"id":"m1","snippet":{"type":"textMessageEvent","publishedAt":"2026-10-20T22:30:01.123+00:00","displayMessage":"hello from ghana",
        "textMessageDetails":{"messageText":"hello from ghana"}},
       "authorDetails":{"channelId":"UC_a","displayName":"Ama","profileImageUrl":"https://yt3.example/a.jpg","isChatOwner":false,"isChatModerator":true}},
      {"id":"m2","snippet":{"type":"superChatEvent","publishedAt":"2026-10-20T22:30:02Z","displayMessage":"$5.00 from Kofi: love it",
        "superChatDetails":{"amountDisplayString":"$5.00","userComment":"love it","tier":2}},
       "authorDetails":{"channelId":"UC_b","displayName":"Kofi","isChatSponsor":true}},
      {"id":"m3","snippet":{"type":"pollEvent","displayMessage":"poll"},"authorDetails":{"displayName":"x"}},
      {"id":"m4","snippet":{"type":"textMessageEvent","displayMessage":"   "},"authorDetails":{"displayName":"blank"}}
     ]}
    """#
    static let page2 = #"""
    {"nextPageToken":"TOK2","pollingIntervalMillis":3000,"items":[
      {"id":"m2","snippet":{"type":"superChatEvent","displayMessage":"dup","superChatDetails":{"amountDisplayString":"$5.00","userComment":"love it"}},"authorDetails":{"channelId":"UC_b","displayName":"Kofi"}},
      {"id":"m5","snippet":{"type":"textMessageEvent","displayMessage":"second page"},"authorDetails":{"channelId":"UC_c","displayName":"Esi"}},
      {"id":"d1","snippet":{"type":"messageDeletedEvent","messageDeletedDetails":{"deletedMessageId":"m1"}}},
      {"id":"b1","snippet":{"type":"userBannedEvent","userBannedDetails":{"bannedUserDetails":{"channelId":"UC_c"},"banType":"permanent"}}}
    ]}
    """#
    static let ended = #"""
    {"nextPageToken":"TOK3","offlineAt":"2026-10-20T23:00:00Z","items":[{"id":"e1","snippet":{"type":"chatEndedEvent"}}]}
    """#
    static let posted = #"""
    {"kind":"youtube#liveChatMessage","id":"posted1","snippet":{"type":"textMessageEvent","publishedAt":"2026-10-20T23:59:00Z",
     "displayMessage":"@Ama hi","textMessageDetails":{"messageText":"@Ama hi"}},
     "authorDetails":{"channelId":"UC_me","displayName":"Kaleel","isChatOwner":true}}
    """#

    static func error(_ code: Int, _ reason: String) -> String {
        #"{"error":{"code":\#(code),"message":"x","errors":[{"domain":"youtube.liveChat","reason":"\#(reason)"}]}}"#
    }
}

final class FakeLiveTransport: LiveAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(match: String, status: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(_ queue: [(String, Int, String)]) {
        self.queue = queue.map { (match: $0.0, status: $0.1, body: $0.2) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let url = request.url!.absoluteString
        guard let index = queue.firstIndex(where: { url.contains($0.match) }) else {
            throw URLError(.notConnectedToInternet)
        }
        let next = queue.remove(at: index)
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        return (Data(next.body.utf8), response)
    }

    var urls: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.map { $0.url!.absoluteString }
    }
}

final class FakeStreamTransport: ChatStreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [(Int, [String])]
    private(set) var opened: [URLRequest] = []

    init(_ sessions: [(Int, [String])]) { self.sessions = sessions }

    func open(_ request: URLRequest) async throws -> (Int, AsyncThrowingStream<Data, Error>) {
        lock.lock()
        opened.append(request)
        guard !sessions.isEmpty else { lock.unlock(); throw URLError(.networkConnectionLost) }
        let (status, chunks) = sessions.removeFirst()
        lock.unlock()
        let stream = AsyncThrowingStream<Data, Error> { c in
            for chunk in chunks { c.yield(Data(chunk.utf8)) }
            c.finish()
        }
        return (status, stream)
    }

    var openedURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return opened.map { $0.url!.absoluteString }
    }
}

actor UpdateLog {
    var states: [ChatConnectorState] = []
    var pages: [YouTubeChatPage] = []
    var titles: [String] = []
    func add(_ u: YouTubeChatUpdate) {
        if let s = u.state { states.append(s) }
        if let p = u.page { pages.append(p) }
        if let t = u.title { titles.append(t) }
    }
}

final class TestLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int
    init(start: Int = 0) { total = start }
    func spend(_ units: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        total += units
        return total
    }
}

actor TokenLog {
    var forces: [Bool] = []
    func add(_ f: Bool) { forces.append(f) }
}

@Suite
struct YouTubeChatIngestTests {
    @Test
    func videoID_parsesCommonForms() {
        #expect(YouTubeChatTarget.videoID(from: "jfKfPfyJRdk") == "jfKfPfyJRdk")
        #expect(YouTubeChatTarget.videoID(from: "https://www.youtube.com/watch?v=jfKfPfyJRdk&t=3") == "jfKfPfyJRdk")
        #expect(YouTubeChatTarget.videoID(from: "youtube.com/live/jfKfPfyJRdk?si=abc") == "jfKfPfyJRdk")
        #expect(YouTubeChatTarget.videoID(from: "https://youtu.be/jfKfPfyJRdk") == "jfKfPfyJRdk")
        #expect(YouTubeChatTarget.videoID(from: "https://m.youtube.com/shorts/jfKfPfyJRdk") == "jfKfPfyJRdk")
        #expect(YouTubeChatTarget.videoID(from: " https://example.com/watch?v=jfKfPfyJRdk ") == nil)
        #expect(YouTubeChatTarget.videoID(from: "short") == nil)
        #expect(YouTubeChatTarget.videoID(from: "") == nil)
    }

    @Test
    func parsePage_normalizesTextSuperChatAndSkipsNoise() throws {
        let page = try YouTubeChatAPI.parsePage(Data(YouTubeChatFixtures.page1.utf8))
        #expect(page.nextPageToken == "TOK1")
        #expect(page.pollingIntervalMillis == 3000)
        #expect(page.messages.map(\.externalID) == ["m1", "m2"])
        let first = page.messages[0]
        #expect(first.senderName == "Ama")
        #expect(first.messageText == "hello from ghana")
        #expect(first.platformSource == "YouTube")
        #expect(first.authorID == "UC_a")
        #expect(first.authorRole == "moderator")
        #expect(first.kind == "text")
        #expect(first.dedupeKey == "youtube:m1")
        let superChat = page.messages[1]
        #expect(superChat.kind == "superChat")
        #expect(superChat.amountDisplay == "$5.00")
        #expect(superChat.messageText == "love it")
        #expect(superChat.authorRole == "member")
    }

    @Test
    func parsePage_deletesBansAndEnd() throws {
        let page = try YouTubeChatAPI.parsePage(Data(YouTubeChatFixtures.page2.utf8))
        #expect(page.removedMessageIDs == ["m1"])
        #expect(page.bannedAuthorIDs == ["UC_c"])
        let ended = try YouTubeChatAPI.parsePage(Data(YouTubeChatFixtures.ended.utf8))
        #expect(ended.chatEnded)
        #expect(ended.offline)
        #expect(ended.messages.isEmpty)
    }

    @Test
    func errorMapping_usesGoogleReasons() {
        func map(_ code: Int, _ reason: String) -> YouTubeChatError {
            YouTubeChatAPI.error(status: code, body: Data(YouTubeChatFixtures.error(code, reason).utf8))
        }
        #expect(map(403, "liveChatEnded") == .ended)
        #expect(map(403, "liveChatDisabled") == .disabled)
        #expect(map(404, "liveChatNotFound") == .notFound)
        #expect(map(403, "quotaExceeded") == .quotaExceeded)
        #expect(map(403, "rateLimitExceeded") == .rateLimited)
        #expect(map(401, "authError") == .unauthorized)
        #expect(map(403, "forbidden") == .forbidden)
        #expect(YouTubeChatAPI.error(status: 404, body: Data("<html>".utf8)) == .streamUnsupported)
        #expect(YouTubeChatAPI.error(status: 503, body: Data()) == .http(503))
        #expect(YouTubeChatError.quotaExceeded.isTerminal)
        #expect(!YouTubeChatError.rateLimited.isTerminal)
    }

    @Test
    func framer_splitsArrayAndNewlineFraming() {
        var framer = JSONObjectFramer()
        let tricky = #"{"a":"brace } and quote \" inside","b":{"c":1}}"#
        let input = "[\n" + tricky + ",\n" + #"{"n":2}"# + "\n]"
        var out: [Data] = []
        // Feed in awkward splits.
        let bytes = Array(input.utf8)
        var i = 0
        while i < bytes.count {
            let end = min(bytes.count, i + 7)
            out += framer.feed(Data(bytes[i..<end]))
            i = end
        }
        #expect(out.count == 2)
        #expect(String(data: out[0], encoding: .utf8) == tricky)
        var nl = JSONObjectFramer()
        #expect(nl.feed(Data((#"{"x":1}"# + "\n" + #"{"y":2}"# + "\n").utf8)).count == 2)
    }

    @Test
    func backoff_isExponentialAndCapped() {
        #expect(YouTubeChatConnector.backoff(attempt: 1, jitter: 0) == 1)
        #expect(YouTubeChatConnector.backoff(attempt: 2, jitter: 0) == 2)
        #expect(YouTubeChatConnector.backoff(attempt: 4, jitter: 0) == 8)
        #expect(YouTubeChatConnector.backoff(attempt: 20, jitter: 0.25) == 60)
    }

    @Test
    func polling_resolvesVideo_resumesPageToken_andEnds() async {
        let transport = FakeLiveTransport([
            ("/videos", 200, YouTubeChatFixtures.videoLive),
            ("/liveChat/messages?", 200, YouTubeChatFixtures.page1),
            ("/liveChat/messages?", 200, YouTubeChatFixtures.page2),
            ("/liveChat/messages?", 200, YouTubeChatFixtures.ended),
        ])
        let log = UpdateLog()
        let connector = YouTubeChatConnector(
            transport: transport,
            streamTransport: FakeStreamTransport([]),
            preferStream: false,
            token: { _ in "test-token" },
            sleep: { _ in },
            jitter: { 0 },
            spendUnits: TestLedger().spend, onUpdate: { await log.add($0) }
        )
        await connector.start(.video("https://www.youtube.com/watch?v=jfKfPfyJRdk"))
        await connector.waitUntilFinished()
        let urls = transport.urls
        #expect(urls.count == 4)
        #expect(urls[0].contains("id=jfKfPfyJRdk"))
        #expect(urls[1].contains("liveChatId=Cg0KC2pmS2ZQZnlKUmRr"))
        #expect(!urls[1].contains("pageToken"))
        #expect(urls[2].contains("pageToken=TOK1"))
        #expect(urls[3].contains("pageToken=TOK2"))
        #expect(await log.states.last == .ended)
        #expect(await log.titles == ["lofi radio"])
        #expect(await connector.quotaUnits == 1 + 5 * 3)
    }

    @Test
    func video_withoutChat_failsTerse() async {
        let transport = FakeLiveTransport([("/videos", 200, YouTubeChatFixtures.videoNoChat)])
        let log = UpdateLog()
        let connector = YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]),
            token: { _ in "t" }, sleep: { _ in }, spendUnits: TestLedger().spend, onUpdate: { await log.add($0) })
        await connector.start(.video("dQw4w9WgXcQ"))
        await connector.waitUntilFinished()
        #expect(await log.states.last == .failed("No live chat on this video"))
    }

    @Test
    func unauthorized_refreshesOnceThenContinues() async {
        let transport = FakeLiveTransport([
            ("/liveChat/messages?", 401, YouTubeChatFixtures.error(401, "authError")),
            ("/liveChat/messages?", 200, YouTubeChatFixtures.ended),
        ])
        let tokens = TokenLog()
        let log = UpdateLog()
        let connector = YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]),
            preferStream: false, token: { f in await tokens.add(f); return "t" }, sleep: { _ in },
            spendUnits: TestLedger().spend, onUpdate: { await log.add($0) })
        await connector.start(.chatID("CHAT"))
        await connector.waitUntilFinished()
        #expect(await tokens.forces == [false, true])
        #expect(await log.states.last == .ended)
    }

    @Test
    func quotaExceeded_stopsWithoutRetry() async {
        let transport = FakeLiveTransport([
            ("/liveChat/messages?", 403, YouTubeChatFixtures.error(403, "quotaExceeded")),
            ("/liveChat/messages?", 200, YouTubeChatFixtures.page1),
        ])
        let log = UpdateLog()
        let connector = YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]),
            preferStream: false, token: { _ in "t" }, sleep: { _ in }, spendUnits: TestLedger().spend, onUpdate: { await log.add($0) })
        await connector.start(.chatID("CHAT"))
        await connector.waitUntilFinished()
        #expect(transport.urls.count == 1)
        #expect(await log.states.last == .failed("YouTube quota exceeded"))
    }

    @Test
    func stream_deliversChunks_resumesWithToken_thenEnds() async {
        let page1 = YouTubeChatFixtures.page1.replacingOccurrences(of: "\n", with: "")
        let split = page1.index(page1.startIndex, offsetBy: 40)
        let stream = FakeStreamTransport([
            (200, ["[", String(page1[..<split]), String(page1[split...])]),
            (200, [",", YouTubeChatFixtures.ended, "]"]),
        ])
        let log = UpdateLog()
        let connector = YouTubeChatConnector(transport: FakeLiveTransport([]), streamTransport: stream,
            token: { _ in "t" }, sleep: { _ in }, jitter: { 0 }, spendUnits: TestLedger().spend, onUpdate: { await log.add($0) })
        await connector.start(.chatID("CHAT"))
        await connector.waitUntilFinished()
        let opened = stream.openedURLs
        #expect(opened.count == 2)
        #expect(opened[0].contains("/liveChat/messages/stream"))
        #expect(opened[1].contains("pageToken=TOK1"))
        #expect(await log.pages.first?.messages.map(\.externalID) == ["m1", "m2"])
        #expect(await log.states.contains(.streaming))
        #expect(await log.states.last == .ended)
    }

    @Test
    func stream_unsupported_fallsBackToPolling() async {
        let stream = FakeStreamTransport([(404, ["<html>Not Found</html>"])])
        let transport = FakeLiveTransport([("/liveChat/messages?", 200, YouTubeChatFixtures.ended)])
        let log = UpdateLog()
        let connector = YouTubeChatConnector(transport: transport, streamTransport: stream,
            token: { _ in "t" }, sleep: { _ in }, spendUnits: TestLedger().spend, onUpdate: { await log.add($0) })
        await connector.start(.chatID("CHAT"))
        await connector.waitUntilFinished()
        #expect(stream.openedURLs.count == 1)
        #expect(transport.urls.count == 1)
        #expect(await log.states.last == .ended)
    }

    @Test
    func networkErrors_backOffThenRecover() async {
        // Stream fails 3 times (connection lost), then polling takes over.
        let transport = FakeLiveTransport([("/liveChat/messages?", 200, YouTubeChatFixtures.ended)])
        let log = UpdateLog()
        let connector = YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]),
            token: { _ in "t" }, sleep: { _ in }, jitter: { 0 }, spendUnits: TestLedger().spend, onUpdate: { await log.add($0) })
        await connector.start(.chatID("CHAT"))
        await connector.waitUntilFinished()
        let retries = await log.states.filter { if case .retrying = $0 { return true }; return false }
        #expect(retries == [.retrying(seconds: 1), .retrying(seconds: 2), .retrying(seconds: 4)])
        #expect(await log.states.last == .ended)
    }

    @Test
    func autoActive_findsMyBroadcastChat() async {
        let transport = FakeLiveTransport([
            ("broadcastStatus=active", 200, YouTubeChatFixtures.broadcastEmpty),
            ("broadcastStatus=upcoming", 200, YouTubeChatFixtures.broadcastEmpty),
            ("broadcastStatus=active", 200, YouTubeChatFixtures.broadcastActive),
            ("/liveChat/messages?", 200, YouTubeChatFixtures.ended),
        ])
        let connector = YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]),
            preferStream: false, token: { _ in "t" }, sleep: { _ in }, spendUnits: TestLedger().spend, onUpdate: { _ in })
        await connector.start(.autoActive)
        await connector.waitUntilFinished()
        #expect(transport.urls.last?.contains("liveChatId=CHAT_BC1") == true)
        #expect(await connector.liveChatID == "CHAT_BC1")
    }

    @Test
    func dailyBudget_stopsBeforeOverspend() async {
        // 6,990 already spent today: the 1 unit video lookup fits, the 5 unit stream connect does not.
        let transport = FakeLiveTransport([("/videos", 200, YouTubeChatFixtures.videoLive)])
        let stream = FakeStreamTransport([(200, [YouTubeChatFixtures.page1])])
        let log = UpdateLog()
        let connector = YouTubeChatConnector(transport: transport, streamTransport: stream,
            token: { _ in "t" }, sleep: { _ in }, dailyBudget: 6995,
            spendUnits: TestLedger(start: 6990).spend, onUpdate: { await log.add($0) })
        await connector.start(.video("jfKfPfyJRdk"))
        await connector.waitUntilFinished()
        #expect(stream.openedURLs.isEmpty)
        #expect(await log.states.last == .failed("Daily quota budget reached"))
        #expect(await connector.dayUnits == 6991)
    }

    @Test
    func ledger_keysByPacificDay() {
        let defaults = UserDefaults(suiteName: "proshow.tests.ledger")!
        defaults.removePersistentDomain(forName: "proshow.tests.ledger")
        // 06:59 UTC Oct 21 is still Oct 20 in Los Angeles (PDT, UTC-7).
        let lateLA = ISO8601DateFormatter().date(from: "2026-10-21T06:59:00Z")!
        let nextLA = ISO8601DateFormatter().date(from: "2026-10-21T07:01:00Z")!
        #expect(YouTubeQuotaLedger.dayKey(lateLA) == "2026-10-20")
        #expect(YouTubeQuotaLedger.dayKey(nextLA) == "2026-10-21")
        #expect(YouTubeQuotaLedger.spend(5, now: lateLA, defaults: defaults) == 5)
        #expect(YouTubeQuotaLedger.spend(5, now: lateLA, defaults: defaults) == 10)
        #expect(YouTubeQuotaLedger.spend(1, now: nextLA, defaults: defaults) == 1)
        #expect(YouTubeQuotaLedger.today(now: lateLA, defaults: defaults) == 0)
    }

    @Test
    func insertRequest_postsTextMessageToChat() throws {
        let r = YouTubeChatAPI.insertRequest(liveChatID: "CHAT", text: "hello", token: "t")
        #expect(r.httpMethod == "POST")
        #expect(r.url!.absoluteString.contains("/liveChat/messages?part=snippet"))
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        let snippet = body["snippet"] as! [String: Any]
        #expect(snippet["liveChatId"] as? String == "CHAT")
        #expect(snippet["type"] as? String == "textMessageEvent")
        #expect((snippet["textMessageDetails"] as? [String: Any])?["messageText"] as? String == "hello")
        #expect(YouTubeChatAPI.replyText("  a\nb  ") == "a b")
        #expect(YouTubeChatAPI.replyText("   ") == nil)
        #expect(YouTubeChatAPI.replyText(String(repeating: "x", count: 300))?.count == 200)
    }

    @Test
    func send_requiresConnection_andRespectsBudget() async {
        let idle = YouTubeChatConnector(transport: FakeLiveTransport([]), streamTransport: FakeStreamTransport([]),
            token: { _ in "t" }, sleep: { _ in }, spendUnits: TestLedger().spend, onUpdate: { _ in })
        await #expect(throws: YouTubeChatError.notConnected) { _ = try await idle.send("hi") }

        // Connected (chat id known after polling), 6,985 spent: list (5) fits, the 20 unit send does not.
        let transport = FakeLiveTransport([("liveChatId=", 200, YouTubeChatFixtures.ended)])
        let tight = YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]),
            preferStream: false, token: { _ in "t" }, sleep: { _ in }, dailyBudget: 7000,
            spendUnits: TestLedger(start: 6985).spend, onUpdate: { _ in })
        await tight.start(.chatID("CHAT"))
        await tight.waitUntilFinished()
        await #expect(throws: YouTubeChatError.budgetReached) { _ = try await tight.send("hi") }
        #expect(transport.urls.count == 1)
        await #expect(throws: YouTubeChatError.emptyMessage) { _ = try await tight.send("  ") }
    }

    @Test
    func send_postsOnce_andReturnsPostedMessage() async throws {
        let transport = FakeLiveTransport([
            ("liveChatId=", 200, YouTubeChatFixtures.ended),
            ("messages?part=snippet", 200, YouTubeChatFixtures.posted),
        ])
        let connector = YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]),
            preferStream: false, token: { _ in "t" }, sleep: { _ in }, spendUnits: TestLedger().spend, onUpdate: { _ in })
        await connector.start(.chatID("CHAT"))
        await connector.waitUntilFinished()
        let posted = try await connector.send("@Ama hi")
        #expect(posted?.externalID == "posted1")
        #expect(posted?.authorRole == "owner")
        let inserts = transport.requests.filter { $0.httpMethod == "POST" }
        #expect(inserts.count == 1)
        #expect(await connector.quotaUnits == 5 + 20)
    }

    @Test @MainActor
    func hub_replyRouting_andOperatorSend() async throws {
        let saved = LiveChatIngestFlags.liveChatIngestV1
        defer { LiveChatIngestFlags.liveChatIngestV1 = saved }
        LiveChatIngestFlags.liveChatIngestV1 = true
        let manager = LiveChatStreamManager(chatEngine: LiveChatEngine())
        let hub = ChatIngestHub(stream: manager)
        hub.tokenProvider = { _ in "t" }
        #expect(hub.replyBlockedReason == "No chat connected")
        hub.setReplyTarget(LiveChatMessage(senderName: "ytuser", platformSource: "YouTube", messageText: "hey"))
        #expect(hub.replyBlockedReason == "Connect YouTube chat first")
        hub.setReplyTarget(LiveChatMessage(senderName: "xuser", platformSource: "X", messageText: "yo"))
        #expect(hub.replyBlockedReason == "Sign in to X")
        hub.setReplyTarget(nil)

        let transport = FakeLiveTransport([
            ("liveChatId=", 200, YouTubeChatFixtures.page1),
            ("messages?part=snippet", 200, YouTubeChatFixtures.posted),
        ])
        hub.makeConnector = { token, onUpdate in
            YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]), preferStream: false,
                token: token, sleep: { _ in try await Task.sleep(nanoseconds: 20_000_000) },
                spendUnits: TestLedger().spend, onUpdate: onUpdate)
        }
        #expect(hub.connectYouTube(.chatID("CHAT")))
        for _ in 0..<100 where manager.inbox.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let ama = try #require(manager.inbox.first(where: { $0.externalID == "m1" }))
        hub.setReplyTarget(ama)
        #expect(hub.replyBlockedReason == nil)
        // Nothing is posted until sendReply runs (the composer calls it on Send or Return only).
        hub.replyDraft = "hi"
        #expect(transport.requests.filter { $0.httpMethod == "POST" }.isEmpty)
        await hub.sendReply()
        let posts = transport.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 1)
        let body = try JSONSerialization.jsonObject(with: posts[0].httpBody!) as! [String: Any]
        #expect(((body["snippet"] as? [String: Any])?["textMessageDetails"] as? [String: Any])?["messageText"] as? String == "@Ama hi")
        #expect(hub.replyDraft.isEmpty)
        #expect(hub.replyTarget == nil)
        #expect(hub.replyError == nil)
        #expect(manager.inbox.first?.externalID == "posted1")
        hub.stopYouTube()
    }

    @Test @MainActor
    func talkButton_tapTogglesAndHoldIsMomentary() {
        let model = TalkButtonModel()
        var active = false
        var calls: [String] = []
        let start = { active = true; calls.append("start") }
        let stop = { active = false; calls.append("stop") }
        let t = Date()
        // Tap: starts and stays on.
        model.press(isActive: active, at: t, start: start)
        #expect(model.isPressed)
        model.release(at: t.addingTimeInterval(0.1), stop: stop)
        #expect(active && !model.isPressed)
        // Tap while on: off.
        model.press(isActive: active, at: t, start: start)
        model.release(at: t.addingTimeInterval(0.1), stop: stop)
        #expect(!active)
        // Hold: on while held, off on release.
        model.press(isActive: active, at: t, start: start)
        #expect(active)
        model.release(at: t.addingTimeInterval(1.2), stop: stop)
        #expect(!active)
        // Repeated press events while held start only once; stray release does nothing.
        model.press(isActive: active, at: t, start: start)
        model.press(isActive: active, at: t, start: start)
        model.release(at: t.addingTimeInterval(2), stop: stop)
        model.release(at: t.addingTimeInterval(3), stop: stop)
        #expect(calls == ["start", "stop", "start", "stop", "start", "stop"])
        model.toggle(isActive: false, start: start, stop: stop)
        #expect(active)
        model.toggle(isActive: true, start: start, stop: stop)
        #expect(!active)
    }

    @Test @MainActor
    func inbox_hideAndBlockAuthor() throws {
        let manager = LiveChatStreamManager(chatEngine: LiveChatEngine())
        manager.setSourceEnabled(.youtube, enabled: true)
        let p1 = try YouTubeChatAPI.parsePage(Data(YouTubeChatFixtures.page1.utf8))
        manager.ingestBatch(p1.messages)
        manager.hide(id: "youtube:m1")
        #expect(manager.inbox.map(\.externalID) == ["m2"])
        #expect(manager.ingestBatch(p1.messages) == 0)
        manager.blockAuthor(of: "youtube:m2")
        #expect(manager.inbox.isEmpty)
        let again = LiveChatMessage(id: "youtube:m9", senderName: "Kofi", platformSource: "YouTube", messageText: "back",
            externalID: "m9", authorID: "UC_b")
        #expect(!manager.ingest(again))
    }

    @Test @MainActor
    func inbox_dedupesAndHonorsUpstreamRemovals() throws {
        let manager = LiveChatStreamManager(chatEngine: LiveChatEngine())
        manager.setSourceEnabled(.youtube, enabled: true)
        let p1 = try YouTubeChatAPI.parsePage(Data(YouTubeChatFixtures.page1.utf8))
        let p2 = try YouTubeChatAPI.parsePage(Data(YouTubeChatFixtures.page2.utf8))
        #expect(manager.ingestBatch(p1.messages) == 2)
        #expect(manager.ingestBatch(p1.messages) == 0)
        #expect(manager.ingestBatch(p2.messages) == 1)
        #expect(manager.inbox.map(\.externalID) == ["m5", "m2", "m1"])
        manager.removeExternal(platform: .youtube, ids: p2.removedMessageIDs)
        manager.removeAuthors(platform: .youtube, authorIDs: p2.bannedAuthorIDs)
        #expect(manager.inbox.map(\.externalID) == ["m2"])
        // A deleted id never comes back on replay.
        #expect(manager.ingestBatch(p1.messages) == 0)
        // Webhook messages without ids are not deduped.
        let hook = LiveChatMessage(senderName: "Zed", platformSource: "YouTube", messageText: "hi")
        #expect(manager.ingest(hook))
        #expect(manager.ingest(hook))
    }

    @Test @MainActor
    func hub_isInertWhenFlagOff() {
        let saved = LiveChatIngestFlags.liveChatIngestV1
        defer { LiveChatIngestFlags.liveChatIngestV1 = saved }
        LiveChatIngestFlags.liveChatIngestV1 = false
        let hub = ChatIngestHub(stream: nil)
        hub.tokenProvider = { _ in "t" }
        #expect(!hub.connectYouTube(.chatID("CHAT")))
        #expect(hub.youtubeState == .idle)
    }

    @Test @MainActor
    func hub_replyNeverBlamesYouTubeForXOrNoChat() {
        let saved = LiveChatIngestFlags.liveChatIngestV1
        defer { LiveChatIngestFlags.liveChatIngestV1 = saved }
        LiveChatIngestFlags.liveChatIngestV1 = true
        let hub = ChatIngestHub(stream: LiveChatStreamManager(chatEngine: LiveChatEngine()))
        #expect(hub.replyPlatform == nil)
        #expect(hub.replyBlockedReason == "No chat connected")
        hub.xState = .polling
        #expect(hub.replyPlatform == .x)
        #expect(hub.replyBlockedReason != "Connect YouTube chat first")
        hub.youtubeState = .polling
        #expect(hub.replyPlatform == nil)
        #expect(hub.replyBlockedReason == "Pick a message")
        hub.xState = .idle
        #expect(hub.replyPlatform == .youtube)
        hub.setReplyTarget(LiveChatMessage(senderName: "guest", platformSource: "Backstage", messageText: "hi"))
        #expect(hub.replyBlockedReason == "Replies go to YouTube or X")
    }

    @Test
    func pickBroadcast_boundStreamWins_upcomingNeedsOneWarm() {
        typealias C = YouTubeChatAPI.BroadcastCandidate
        let old = C(chatID: "OLD", title: nil, boundStreamID: "s1", lifeCycle: "ready")
        let test = C(chatID: "TEST", title: nil, boundStreamID: "s2", lifeCycle: "testing")
        let other = C(chatID: "OTHER", title: nil, boundStreamID: "s3", lifeCycle: "ready")
        #expect(YouTubeChatAPI.pickBroadcast([old, test], streamIDs: ["s1"], upcoming: true)?.chatID == "OLD")
        #expect(YouTubeChatAPI.pickBroadcast([old, test], streamIDs: [], upcoming: true)?.chatID == "TEST")
        #expect(YouTubeChatAPI.pickBroadcast([old, other], streamIDs: [], upcoming: true) == nil)
        #expect(YouTubeChatAPI.pickBroadcast([old, other], streamIDs: ["zz"], upcoming: true) == nil)
        #expect(YouTubeChatAPI.pickBroadcast([other], streamIDs: [], upcoming: true)?.chatID == "OTHER")
        #expect(YouTubeChatAPI.pickBroadcast([old, test], streamIDs: [], upcoming: false)?.chatID == "OLD")
        #expect(YouTubeChatAPI.pickBroadcast([], streamIDs: [], upcoming: false) == nil)
    }

    @Test
    func autoActive_plainKeyMapsToBoundUpcomingBroadcast() async {
        let streams = #"{"items":[{"id":"sA","cdn":{"ingestionInfo":{"streamName":"key-a"}}},{"id":"sB","cdn":{"ingestionInfo":{"streamName":"key-b"}}}]}"#
        let upcoming = #"{"items":[{"id":"b1","snippet":{"title":"Old","liveChatId":"CHAT_OLD"},"contentDetails":{"boundStreamId":"sA"},"status":{"lifeCycleStatus":"ready"}},{"id":"b2","snippet":{"title":"Tonight","liveChatId":"CHAT_B"},"contentDetails":{"boundStreamId":"sB"},"status":{"lifeCycleStatus":"ready"}}]}"#
        let transport = FakeLiveTransport([
            ("/liveStreams", 200, streams),
            ("broadcastStatus=active", 200, YouTubeChatFixtures.broadcastEmpty),
            ("broadcastStatus=upcoming", 200, upcoming),
            ("/liveChat/messages?", 200, YouTubeChatFixtures.ended),
        ])
        let connector = YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]),
            preferStream: false, token: { _ in "t" }, sleep: { _ in }, spendUnits: TestLedger().spend, onUpdate: { _ in })
        await connector.setStreamHint(YouTubeStreamHint(streamID: "", streamKey: "key-b"))
        await connector.start(.autoActive)
        await connector.waitUntilFinished()
        #expect(await connector.liveChatID == "CHAT_B")
        #expect(transport.urls.allSatisfy { !$0.contains("key-b") })
    }

    @Test
    func autoActive_noBroadcast_endsQuietlyAfterSpacedTries() async {
        let transport = FakeLiveTransport((0..<12).map { i in (i % 2 == 0 ? "broadcastStatus=active" : "broadcastStatus=upcoming", 200, YouTubeChatFixtures.broadcastEmpty) })
        let log = UpdateLog()
        let connector = YouTubeChatConnector(transport: transport, streamTransport: FakeStreamTransport([]),
            preferStream: false, token: { _ in "t" }, sleep: { _ in }, spendUnits: TestLedger().spend, onUpdate: { await log.add($0) })
        await connector.start(.autoActive)
        await connector.waitUntilFinished()
        #expect(transport.requests.count == 12)
        #expect(await log.states.last == .failed("No live broadcast"))
    }

    @Test @MainActor
    func controlRoute_returnsFlagOffWhenDisabled() {
        let saved = LiveChatIngestFlags.liveChatIngestV1
        defer { LiveChatIngestFlags.liveChatIngestV1 = saved }
        LiveChatIngestFlags.liveChatIngestV1 = false
        let controller = TestSupport.sampleController()
        let result = controller.handleControl(method: "GET", path: "/v1/chat/youtube", body: nil)
        #expect(result.0 == 404)
    }
}
