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
    /// More popover open. Lives here so the QA hook can open it for screenshots.
    var moreMenuOpen = false

    /// True when Go Live started the connector (stopping the broadcast stops it).
    private(set) var youtubeAutoStarted = false

    @ObservationIgnored weak var stream: LiveChatStreamManager?
    @ObservationIgnored var tokenProvider: YouTubeChatConnector.TokenProvider?
    @ObservationIgnored var makeConnector: ((@escaping YouTubeChatConnector.TokenProvider, @escaping @Sendable (YouTubeChatUpdate) async -> Void) -> YouTubeChatConnector)?
    /// Clears the on-screen card when its message is removed upstream.
    @ObservationIgnored var clearOverlay: (() -> Void)?
    @ObservationIgnored private var youtube: YouTubeChatConnector?
    @ObservationIgnored private var generation = 0

    init(stream: LiveChatStreamManager?) {
        self.stream = stream
    }

    var isEnabled: Bool { LiveChatIngestFlags.liveChatIngestV1 }

    @discardableResult
    func connectYouTube(_ target: YouTubeChatTarget, auto: Bool = false) -> Bool {
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
        Task { await connector.start(target) }
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

    /// Platform the next reply goes to: the target's platform, else YouTube.
    var replyPlatform: ChatPlatform {
        replyTarget.map { ChatPlatform.from(displayName: $0.platformSource) } ?? .youtube
    }

    /// Nil when Send can run. Otherwise a terse reason shown under the box.
    var replyBlockedReason: String? {
        switch replyPlatform {
        case .youtube:
            return youtube != nil && youtubeState.isActive ? nil : "Connect YouTube chat first"
        case .x:
            return "Sign in to X"
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

    func stopAutoStarted() {
        if youtubeAutoStarted { stopYouTube() }
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
        ]
    }
}
