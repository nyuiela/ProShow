import Foundation

// Live chat ingest wiring (proshow.liveChatIngestV1). Read only.
// The connector runs on its own actor; nothing here touches audio or the encoder.
extension ShowController {
    func bootstrapChatIngest() {
        let hub = ChatIngestHub(stream: chatStream)
        hub.tokenProvider = { @MainActor [weak self] force in
            guard let self else { throw YouTubeChatError.unauthorized }
            return try await self.youTubeChatToken(forceRefresh: force)
        }
        hub.clearOverlay = { [weak self] in
            guard let self else { return }
            self.chatStream?.dismissOverlay(compositor: self.compositor)
        }
        bootstrapXChat(hub)
        chatIngest = hub
    }

    /// Armed YouTube destination first, then any signed in YouTube account.
    func youTubeChatAccount() -> StreamAccount? {
        let youtube = deviceSettings.document.accounts.filter { $0.platform == .youtube }
        return youtube.first(where: { streamMatrix.isActive($0.id) })
            ?? youtube.first(where: { StreamAccountManager.shared.accessToken(for: $0) != nil })
            ?? youtube.first
    }

    func youTubeChatToken(forceRefresh: Bool) async throws -> String {
        guard let account = youTubeChatAccount() else { throw YouTubeChatError.unauthorized }
        let tokens = try await StreamAccountManager.shared.ensureValidAccessToken(for: account, forceRefresh: forceRefresh)
        return tokens.accessToken
    }

    /// Called after the encoder is live. Leaves a manual session alone.
    func startYouTubeChatAfterGoLive(_ ingests: [ResolvedIngest]) {
        guard LiveChatIngestFlags.liveChatIngestV1, let hub = chatIngest else { return }
        if hub.youtubeState.isActive && !hub.youtubeAutoStarted { return }
        guard let youtube = ingests.first(where: { $0.platform == .youtube }) else { return }
        let id = youtube.broadcastID.trimmingCharacters(in: .whitespacesAndNewlines)
        hub.connectYouTube(id.isEmpty ? .autoActive : .broadcast(id), auto: true)
    }

    func handleYouTubeChatControl(method: String, body: Data?) -> (Int, String) {
        guard let hub = chatIngest, hub.isEnabled else {
            return (404, #"{"ok":false,"error":"flag_off"}"#)
        }
        if method == "POST" {
            let parsed = ControlHTTP.jsonObject(body)
            if parsed["stop"] != nil {
                hub.stopYouTube()
            } else if let chatID = parsed["chat_id"], !chatID.isEmpty {
                hub.connectYouTube(.chatID(chatID))
            } else if let input = parsed["input"], !input.isEmpty {
                if input == "auto" {
                    hub.connectYouTube(.autoActive)
                } else if YouTubeChatTarget.videoID(from: input) != nil {
                    hub.connectYouTube(.video(input))
                } else {
                    return (400, #"{"ok":false,"error":"bad_input"}"#)
                }
            } else {
                return (400, #"{"ok":false,"error":"missing_input"}"#)
            }
        }
        return (200, ControlJSON.encode(hub.statusJSON()))
    }
}

// X chat (Phase 2). A separate sign-in with broadcast scopes, stored in the
// keychain under XChatAuth.accountID. The X destination account is untouched.
extension ShowController {
    static let xChatAccount = StreamAccount(id: XChatAuth.accountID, accountName: "X chat", platform: .twitter)

    func bootstrapXChat(_ hub: ChatIngestHub) {
        hub.xTokenProvider = { force in
            let tokens = try await StreamAccountManager.shared.ensureValidAccessToken(for: ShowController.xChatAccount, forceRefresh: force)
            return tokens.accessToken
        }
        hub.signInX = { @MainActor [weak self] in await self?.signInXChat() }
        hub.xSignedIn = StreamAccountManager.shared.accessToken(for: Self.xChatAccount) != nil
        hub.xUsername = UserDefaults.standard.string(forKey: XChatAuth.usernameKey)
    }

    /// Opens the X consent page in the browser. Kaleel approves there himself.
    func signInXChat() async {
        guard let hub = chatIngest, !hub.xSigningIn else { return }
        hub.xSigningIn = true
        hub.xSignInError = nil
        defer { hub.xSigningIn = false }
        do {
            let account = try await StreamAccountManager.shared.authenticate(
                platform: .twitter,
                existing: Self.xChatAccount,
                scopes: XChatAuth.scopes
            )
            hub.xSignedIn = true
            hub.xUsername = account.accountName == Self.xChatAccount.accountName ? nil : account.accountName
            UserDefaults.standard.set(hub.xUsername, forKey: XChatAuth.usernameKey)
        } catch {
            hub.xSignInError = Self.xSignInReason(error)
        }
    }

    static func xSignInReason(_ error: Error) -> String? {
        guard let e = error as? StreamOAuthError else { return "X sign-in failed" }
        switch e {
        case .cancelled: return nil
        case .missingClientID, .missingClientSecret: return "X app not set up"
        case .providerRejected(let reason):
            let r = reason.lowercased()
            if r.contains("scope") { return XChatError.notAllowed.reason }
            if r.contains("access_denied") { return nil }
            if r.contains("in use") { return reason }
            return "X sign-in failed"
        default: return "X sign-in failed"
        }
    }

    /// Called after the encoder is live, with the X broadcast id from Go Live when there is one.
    func startXChatAfterGoLive(_ ingests: [ResolvedIngest]) {
        guard LiveChatIngestFlags.liveChatIngestV1, let hub = chatIngest, hub.xSignedIn else { return }
        if hub.xState.isActive && !hub.xAutoStarted { return }
        let x = ingests.filter {
            $0.platform == .twitter || ($0.url.host ?? "").contains("pscp.tv") || ($0.url.host ?? "").contains("periscope")
        }
        guard !x.isEmpty else { return }
        let id = x.map { $0.broadcastID.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: XChatAPI.isBroadcastID)
        hub.connectX(id.map { .broadcast($0) } ?? .auto, auto: true)
    }

    /// GET state. POST {input: "auto" | id | x.com/i/broadcasts link} or {stop}.
    /// {mock_base} points at a loopback mock X server with a dummy token (tests only).
    /// There is no send route: replies post only from the reply box.
    func handleXChatControl(method: String, body: Data?) -> (Int, String) {
        guard let hub = chatIngest, hub.isEnabled else {
            return (404, #"{"ok":false,"error":"flag_off"}"#)
        }
        if method == "POST" {
            let parsed = ControlHTTP.jsonObject(body)
            if parsed["stop"] != nil {
                hub.stopX()
            } else if let mock = parsed["mock_base"], !mock.isEmpty {
                guard let url = URL(string: mock), ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
                      url.scheme == "http" else {
                    return (400, #"{"ok":false,"error":"mock_must_be_loopback"}"#)
                }
                hub.connectXMock(base: mock, target: parsed["input"].flatMap(XChatAPI.broadcastID(from:)))
            } else if let input = parsed["input"], !input.isEmpty {
                if input == "auto" {
                    hub.connectX(.auto)
                } else if let id = XChatAPI.broadcastID(from: input) {
                    hub.connectX(.broadcast(id))
                } else {
                    return (400, #"{"ok":false,"error":"bad_input"}"#)
                }
            } else {
                return (400, #"{"ok":false,"error":"missing_input"}"#)
            }
        }
        return (200, ControlJSON.encode(hub.xStatusJSON().merging(["ok": true]) { a, _ in a }))
    }
}
