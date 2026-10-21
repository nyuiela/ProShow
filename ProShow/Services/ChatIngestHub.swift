import Foundation
import Observation

/// Main actor facade for chat connectors. Holds UI state only; the connectors
/// do their work on their own actors. See docs/PROSHOW_LIVE_CHAT_PLAN.md.
@MainActor
@Observable
final class ChatIngestHub {
    var youtubeState: ChatConnectorState = .idle
    var youtubeTitle: String?
    var youtubeQuotaUnits = 0
    var youtubeMessageCount = 0
    var youtubeConnects = 0
    var youtubeLastHoldSeconds: Double?
    var youtubeDayUnits = 0
    /// Reply composer state. Sending happens only from `sendReply()`, which the
    /// UI calls on the operator's Send click or Return. No API route sends.
    var replyTarget: LiveChatMessage?
    var replyDraft = ""
    var replySending = false
    var replyError: String?
    var xState: ChatConnectorState = .idle
    var xTitle: String?
    var xBroadcastID: String?
    var xMessageCount = 0
    var xRequests = 0
    var xDayUSD = 0.0
    /// Signed in to the separate X chat login (broadcast scopes).
    var xSignedIn = false
    var xUsername: String?
    var xSigningIn = false
    var xSignInError: String?
    private(set) var xAutoStarted = false
    /// Connect chat from the live broadcast when a stream starts. On unless turned off.
    var autoConnectChat: Bool = UserDefaults.standard.object(forKey: ChatIngestHub.autoConnectKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoConnectChat, forKey: Self.autoConnectKey) }
    }
    static let autoConnectKey = "proshow.chat.autoConnect"
    /// Finds the live broadcast chat now (More menu refresh). Set by the controller.
    @ObservationIgnored var findLiveChats: (() -> Void)?
    /// Stream id and key of the last Go Live YouTube ingest, so a refresh can match the bound broadcast.
    @ObservationIgnored var lastYouTubeStreamHint = YouTubeStreamHint()
    /// More popover open. Lives here so the QA hook can open it for screenshots.
    var moreMenuOpen = false

    /// True when Go Live started the connector (stopping the broadcast stops it).
    private(set) var youtubeAutoStarted = false

    @ObservationIgnored weak var stream: LiveChatStreamManager?
    @ObservationIgnored var tokenProvider: YouTubeChatConnector.TokenProvider?
    @ObservationIgnored var makeConnector: ((@escaping YouTubeChatConnector.TokenProvider, @escaping @Sendable (YouTubeChatUpdate) async -> Void) -> YouTubeChatConnector)?
    /// Clears the on-screen card when its message is removed upstream.
    @ObservationIgnored var clearOverlay: (() -> Void)?
    @ObservationIgnored var xTokenProvider: XChatConnector.TokenProvider?
    @ObservationIgnored var makeXConnector: ((@escaping XChatConnector.TokenProvider, @escaping @Sendable (XChatUpdate) async -> Void) -> XChatConnector)?
    /// Starts the X chat browser sign-in. The operator approves in the browser.
    @ObservationIgnored var signInX: (() async -> Void)?
    @ObservationIgnored private var youtube: YouTubeChatConnector?
    @ObservationIgnored private var xConnector: XChatConnector?
    @ObservationIgnored private var xGeneration = 0
    @ObservationIgnored private var generation = 0

    init(stream: LiveChatStreamManager?) {
        self.stream = stream
    }

    var isEnabled: Bool { LiveChatIngestFlags.liveChatIngestV1 }

    @discardableResult
    func connectYouTube(_ target: YouTubeChatTarget, auto: Bool = false, streamHint: YouTubeStreamHint = .init()) -> Bool {
        guard isEnabled else { return false }
        guard let tokenProvider else {
            youtubeState = .failed("Connect a YouTube account")
            return false
        }
        stopYouTube()
        generation += 1
        let gen = generation
        youtubeAutoStarted = auto
        youtubeTitle = nil
        youtubeMessageCount = 0
        youtubeConnects = 0
        youtubeLastHoldSeconds = nil
        stream?.setSourceEnabled(.youtube, enabled: true)
        let onUpdate: @Sendable (YouTubeChatUpdate) async -> Void = { [weak self] update in
            await MainActor.run { self?.apply(update, generation: gen) }
        }
        let connector = makeConnector?(tokenProvider, onUpdate)
            ?? YouTubeChatConnector(token: tokenProvider, onUpdate: onUpdate)
        youtube = connector
        youtubeState = .resolving
        Task {
            await connector.setStreamHint(streamHint)
            await connector.start(target)
        }
        return true
    }

    func stopYouTube() {
        generation += 1
        if let youtube {
            Task { await youtube.stop() }
        }
        youtube = nil
        youtubeAutoStarted = false
        youtubeState = .idle
    }

    @discardableResult
    func connectX(_ target: XChatConnector.Target, auto: Bool = false) -> Bool {
        guard isEnabled else { return false }
        guard let xTokenProvider, xSignedIn || makeXConnector != nil else {
            xState = .failed(XChatError.unauthorized.reason)
            return false
        }
        stopX()
        xGeneration += 1
        let gen = xGeneration
        xAutoStarted = auto
        xTitle = nil
        xBroadcastID = nil
        xMessageCount = 0
        stream?.setSourceEnabled(.x, enabled: true)
        let onUpdate: @Sendable (XChatUpdate) async -> Void = { [weak self] update in
            await MainActor.run { self?.applyX(update, generation: gen) }
        }
        let connector = makeXConnector?(xTokenProvider, onUpdate)
            ?? XChatConnector(avatars: XChatAuth.avatars, token: xTokenProvider, onUpdate: onUpdate)
        xConnector = connector
        xState = .resolving
        Task { await connector.start(target) }
        return true
    }

    /// Tests only: reads from a loopback mock X server with a dummy token, so a
    /// real token never leaves for it. The caller checks the base is loopback.
    var xMock = false

    func connectXMock(base: String, target: String?) {
        let saved = makeXConnector
        makeXConnector = { _, onUpdate in
            XChatConnector(base: base, token: { _ in "mock-token" }, dailyCap: 1_000,
                           charge: { _ in 0 }, isNewKey: { _ in false }, onUpdate: onUpdate)
        }
        let savedToken = xTokenProvider
        if xTokenProvider == nil { xTokenProvider = { _ in "mock-token" } }
        connectX(target.map { .broadcast($0) } ?? .auto)
        xMock = true
        makeXConnector = saved
        xTokenProvider = savedToken
    }

    func stopX() {
        xGeneration += 1
        if let xConnector {
            Task { await xConnector.stop() }
        }
        xConnector = nil
        xMock = false
        xAutoStarted = false
        xBroadcastID = nil
        xState = .idle
    }

    /// Status line text: X shows only a terse error on failure.
    var xStatusLine: String? {
        if let xSignInError { return xSignInError }
        if case .failed(let reason) = xState { return reason }
        return nil
    }

    private func applyX(_ update: XChatUpdate, generation gen: Int) {
        guard gen == xGeneration else { return }
        if let state = update.state { xState = state }
        if let id = update.broadcastID { xBroadcastID = id }
        if let title = update.title { xTitle = title }
        if let n = update.requests { xRequests = n }
        if let usd = update.dayUSD { xDayUSD = usd }
        if let page = update.page {
            xMessageCount += stream?.ingestBatch(page.messages) ?? 0
        }
    }

    /// Platform the next reply goes to: the target's platform, else the one connected chat.
    /// Nil when there is no target and zero or two chats are connected.
    var replyPlatform: ChatPlatform? {
        if let replyTarget { return ChatPlatform.from(displayName: replyTarget.platformSource) }
        switch (youtubeState.isActive, xState.isActive) {
        case (true, false): return .youtube
        case (false, true): return .x
        default: return nil
        }
    }

    /// Nil when Send can run. Otherwise a terse reason shown under the box.
    /// Only a reply to a YouTube message needs YouTube; X and local actions never do.
    var replyBlockedReason: String? {
        guard let platform = replyPlatform else {
            return youtubeState.isActive || xState.isActive ? "Pick a message" : "No chat connected"
        }
        switch platform {
        case .youtube:
            return youtube != nil && youtubeState.isActive ? nil : "Connect YouTube chat first"
        case .x:
            if !xSignedIn && !xMock && makeXConnector == nil { return XChatError.unauthorized.reason }
            return xConnector != nil && xBroadcastID != nil && xState.isActive ? nil : XChatError.notConnected.reason
        default:
            return "Replies go to YouTube or X"
        }
    }

    func setReplyTarget(_ message: LiveChatMessage?) {
        replyTarget = message
        replyError = nil
    }

    /// Operator action only. Posts the draft to the target platform.
    func sendReply() async {
        guard !replySending else { return }
        if replyPlatform == .x {
            await sendXReply()
            return
        }
        guard replyBlockedReason == nil, let youtube else {
            replyError = replyBlockedReason
            return
        }
        var text = replyDraft
        if let target = replyTarget, ChatPlatform.from(displayName: target.platformSource) == .youtube,
           !text.hasPrefix("@") {
            let handle = target.senderName.hasPrefix("@") ? target.senderName : "@\(target.senderName)"
            text = "\(handle) \(text)"
        }
        guard YouTubeChatAPI.replyText(replyDraft) != nil else {
            replyError = YouTubeChatError.emptyMessage.reason
            return
        }
        replySending = true
        replyError = nil
        defer { replySending = false }
        do {
            let posted = try await youtube.send(text)
            replyDraft = ""
            replyTarget = nil
            if let posted { _ = stream?.ingestBatch([posted]) }
        } catch let error as YouTubeChatError {
            replyError = error.reason
        } catch {
            replyError = "Send failed"
        }
    }

    private func sendXReply() async {
        guard replyBlockedReason == nil, let xConnector else {
            replyError = replyBlockedReason
            return
        }
        guard XChatAPI.replyText(replyDraft) != nil else {
            replyError = XChatError.emptyMessage.reason
            return
        }
        replySending = true
        replyError = nil
        defer { replySending = false }
        do {
            var text = replyDraft
            let replyTo = replyTarget?.externalID.flatMap { XChatAPI.isMessageID($0) ? $0 : nil }
            // No threadable id: mention the viewer instead.
            if let target = replyTarget, replyTo == nil, target.senderName.hasPrefix("@"), !text.hasPrefix("@") {
                text = "\(target.senderName) \(text)"
            }
            let posted = try await xConnector.send(text, replyTo: replyTo, as: xUsername)
            replyDraft = ""
            replyTarget = nil
            _ = stream?.ingestBatch([posted])
        } catch let error as XChatError {
            replyError = error.reason
        } catch {
            replyError = "Send failed"
        }
    }

    func stopAutoStarted() {
        if youtubeAutoStarted { stopYouTube() }
        if xAutoStarted { stopX() }
    }

    private func apply(_ update: YouTubeChatUpdate, generation gen: Int) {
        guard gen == generation else { return }
        if let state = update.state { youtubeState = state }
        if let title = update.title { youtubeTitle = title }
        if let units = update.quotaUnits { youtubeQuotaUnits = units }
        if let connects = update.connects { youtubeConnects = connects }
        if let hold = update.holdSeconds { youtubeLastHoldSeconds = hold }
        if let day = update.dayUnits { youtubeDayUnits = day }
        if let page = update.page {
            let added = stream?.ingestBatch(page.messages) ?? 0
            youtubeMessageCount += added
            var overlayRemoved = false
            if !page.removedMessageIDs.isEmpty {
                overlayRemoved = stream?.removeExternal(platform: .youtube, ids: page.removedMessageIDs) ?? false
            }
            if !page.bannedAuthorIDs.isEmpty {
                overlayRemoved = (stream?.removeAuthors(platform: .youtube, authorIDs: page.bannedAuthorIDs) ?? false) || overlayRemoved
            }
            if overlayRemoved { clearOverlay?() }
        }
    }

    func statusJSON() -> [String: Any] {
        [
            "ok": true,
            "enabled": isEnabled,
            "state": youtubeState.label,
            "active": youtubeState.isActive,
            "title": youtubeTitle ?? "",
            "messages": youtubeMessageCount,
            "quota_units": youtubeQuotaUnits,
            "quota_units_today": youtubeDayUnits,
            "quota_budget": YouTubeQuotaLedger.dailyBudget,
            "stream_connects": youtubeConnects,
            "last_hold_s": youtubeLastHoldSeconds.map { (($0 * 10).rounded()) / 10 } ?? 0,
            "auto": youtubeAutoStarted,
            "auto_connect": autoConnectChat,
            "reply_blocked": replyBlockedReason ?? "",
            "x": xStatusJSON(),
        ]
    }

    func xStatusJSON() -> [String: Any] {
        [
            "signed_in": xSignedIn,
            "username": xUsername ?? "",
            "state": xState.label,
            "active": xState.isActive,
            "broadcast_id": xBroadcastID ?? "",
            "title": xTitle ?? "",
            "messages": xMessageCount,
            "requests": xRequests,
            "usd_today": (xDayUSD * 1000).rounded() / 1000,
            "usd_cap": XChatSpendLedger.dailyCap,
            "auto": xAutoStarted,
            "error": xStatusLine ?? "",
        ]
    }
}
