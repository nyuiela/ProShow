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
