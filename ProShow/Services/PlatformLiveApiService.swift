import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(CoreVideo)
import CoreVideo
#endif

protocol LiveAPITransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionLiveTransport: LiveAPITransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

enum PlatformLiveError: Error, Equatable {
    case missingAccessToken
    case missingIngest
    case httpStatus(Int)
    case unsupportedPlatform
    case provider(String)
    case expiredSession

    var isUnauthorized: Bool {
        switch self {
        case .expiredSession, .missingAccessToken, .httpStatus(401):
            return true
        case .provider(let message):
            return PlatformLiveError.looksLikeInvalidCredentials(message)
        default:
            return false
        }
    }

    static func looksLikeInvalidCredentials(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("invalid authentication")
            || lowered.contains("invalid credentials")
            || lowered.contains("unauthenticated")
            || lowered.contains("invalid token")
            || lowered.contains("auth error")
    }

    static func looksLikeClientNotEnrolled(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("client-not-enrolled")
            || lowered.contains("client forbidden")
            || lowered.contains("required_enrollment")
            || lowered.contains("not enrolled")
            || lowered.contains("appropriate level of api access")
            || lowered.contains("not authorized to use this endpoint")
    }

    static func looksLikeMissingWriteScope(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("tweet.write")
            || lowered.contains("insufficient scope")
            || lowered.contains("missing scope")
            || lowered.contains("not permitted to perform this action")
            || lowered.contains("oauth2 permissions")
    }

    static func fromAPIResponse(_ data: Data, status: Int) -> PlatformLiveError {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let error = object["error"] as? [String: Any]
            let statusName = (error?["status"] as? String) ?? ""
            let nestedMessage = (error?["message"] as? String)
            let listMessage = (object["errors"] as? [[String: Any]])?
                .compactMap { $0["message"] as? String }
                .first
            let parts = [
                object["detail"] as? String,
                nestedMessage,
                object["error_description"] as? String,
                object["message"] as? String,
                listMessage,
                object["reason"] as? String,
                object["required_enrollment"] as? String,
                object["title"] as? String,
            ].compactMap { value -> String? in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            var unique: [String] = []
            for part in parts where !unique.contains(part) {
                unique.append(part)
            }
            let message = unique.joined(separator: " — ")
            if status == 401 || statusName == "UNAUTHENTICATED" || looksLikeInvalidCredentials(message) {
                return .expiredSession
            }
            if !message.isEmpty, !message.contains("GOCSPX"), !message.contains("ya29.") {
                return .provider(message)
            }
        }
        if status == 401 { return .expiredSession }
        return .httpStatus(status)
    }
}

enum OAuthAccessTokenScopes {
    static func listed(in token: String) -> [String] {
        let segments = token.split(separator: ".")
        guard segments.count == 3,
              let payload = base64URL(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return [] }
        if let scope = object["scope"] as? String {
            return scope.split { $0 == " " || $0 == "," }.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }
        if let scopes = object["scope"] as? [String] { return scopes }
        return []
    }

    static func xTokenAllowsPosting(_ token: String) -> Bool? {
        let scopes = listed(in: token)
        guard !scopes.isEmpty else { return nil }
        return scopes.contains("tweet.write")
    }

    private static func base64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = base64.count % 4
        if pad != 0 {
            base64 += String(repeating: "=", count: 4 - pad)
        }
        return Data(base64Encoded: base64)
    }
}

protocol StreamAccessTokenRefreshing: Sendable {
    func validAccessToken(for account: StreamAccount, forceRefresh: Bool) async throws -> String
}

struct DefaultStreamTokenRefresher: StreamAccessTokenRefreshing {
    func validAccessToken(for account: StreamAccount, forceRefresh: Bool) async throws -> String {
        try await StreamAccountManager.shared.ensureValidAccessToken(
            for: account,
            forceRefresh: forceRefresh
        ).accessToken
    }
}

/// Provisions live events and returns RTMPS ingest without writing keys to disk JSON.
struct PlatformLiveApiService: Sendable {
    static let shared = PlatformLiveApiService()

    var transport: any LiveAPITransport = URLSessionLiveTransport()
    var tokenProvider: (@Sendable (StreamAccount) -> String?)?
    var tokenRefresher: (any StreamAccessTokenRefreshing)?

    func provisionLiveBroadcast(for account: StreamAccount, metadata: BroadcastMetadata) async throws -> ResolvedIngest {
        if account.needsManualIngest, let stored = try? Self.ingestFromKeychain(account) {
            return stored
        }
        if account.supportsOAuth {
            if let ingest = try await provisionWithOAuth(account: account, metadata: metadata) {
                return ingest
            }
        }
        return try Self.ingestFromKeychain(account)
    }

    private func provisionWithOAuth(account: StreamAccount, metadata: BroadcastMetadata) async throws -> ResolvedIngest? {
        guard let first = try await resolveAccessToken(for: account, forceRefresh: false), !first.isEmpty else {
            return nil
        }
        do {
            return try await provisionPlatform(account: account, metadata: metadata, token: first)
        } catch let error as PlatformLiveError where error.isUnauthorized && tokenProvider == nil {
            guard let retry = try await resolveAccessToken(for: account, forceRefresh: true), !retry.isEmpty else {
                throw PlatformLiveError.expiredSession
            }
            return try await provisionPlatform(account: account, metadata: metadata, token: retry)
        }
    }

    private func resolveAccessToken(for account: StreamAccount, forceRefresh: Bool) async throws -> String? {
        if let provided = tokenProvider?(account), !provided.isEmpty {
            return provided
        }
        let refresher = tokenRefresher ?? DefaultStreamTokenRefresher()
        do {
            let token = try await refresher.validAccessToken(for: account, forceRefresh: forceRefresh)
            return token.isEmpty ? nil : token
        } catch StreamOAuthError.expiredSession {
            throw PlatformLiveError.expiredSession
        } catch {
            let stored = KeychainStreamVault.load(identifier: account.oauthAccessIdentifier)
            if let stored, !stored.isEmpty { return stored }
            throw error
        }
    }

    private func provisionPlatform(
        account: StreamAccount,
        metadata: BroadcastMetadata,
        token: String
    ) async throws -> ResolvedIngest {
        switch account.platform {
        case .youtube:
            return try await YouTubeLiveService.provision(account: account, metadata: metadata, token: token, transport: transport)
        case .facebook:
            return try await FacebookLiveService.provision(account: account, metadata: metadata, token: token, transport: transport)
        case .twitter:
            return try await XLiveService.provision(account: account, metadata: metadata, token: token, transport: transport)
        case .linkedin:
            return try await LinkedInLiveService.provision(account: account, metadata: metadata, token: token, transport: transport)
        case .customRtmp, .srt:
            throw PlatformLiveError.unsupportedPlatform
        }
    }

    static func ingestFromKeychain(_ account: StreamAccount) throws -> ResolvedIngest {
        guard let url = URL(string: account.rtmpUrl) else { throw PlatformLiveError.missingIngest }
        let key = KeychainStreamVault.load(identifier: account.keychainStreamKeyIdentifier) ?? ""
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PlatformLiveError.missingIngest
        }
        return ResolvedIngest(
            accountID: account.id,
            name: account.accountName,
            platform: account.platform,
            url: url,
            streamKey: key
        )
    }

    static func splitIngest(_ raw: String, account: StreamAccount) throws -> ResolvedIngest {
        let parsed = IngestURLParser.parse(raw)
        guard let url = parsed.url else { throw PlatformLiveError.missingIngest }
        if !parsed.streamKey.isEmpty {
            _ = KeychainStreamVault.save(identifier: account.keychainStreamKeyIdentifier, secret: parsed.streamKey)
        }
        return ResolvedIngest(
            accountID: account.id,
            name: account.accountName,
            platform: account.platform,
            url: url,
            streamKey: parsed.streamKey
        )
    }
}

enum IngestURLParser {
    static func parse(_ raw: String) -> (url: URL?, streamKey: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let url = components.url else {
            return (nil, "")
        }
        if let user = url.user, url.password != nil {
            components.user = user
            let key = url.password ?? ""
            components.password = nil
            return (components.url, key)
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 2, let last = parts.last, last.count >= 8, !last.contains(".") {
            let basePath = "/" + parts.dropLast().joined(separator: "/")
            components.path = basePath
            return (components.url ?? url.deletingLastPathComponent(), last)
        }
        return (url, "")
    }
}

enum YouTubeLiveService {
    static func broadcastBody(metadata: BroadcastMetadata, start: Date = Date()) -> [String: Any] {
        [
            "snippet": [
                "title": metadata.trimmedTitle,
                "description": metadata.description,
                "scheduledStartTime": ISO8601DateFormatter().string(
                    from: metadata.scheduledStartTime ?? start
                ),
            ],
            "status": [
                "privacyStatus": metadata.privacy.youtubePrivacy,
                "selfDeclaredMadeForKids": false,
            ],
            "contentDetails": [
                "enableAutoStart": true,
                "enableAutoStop": true,
                "enableDvr": true,
                "recordFromStart": true,
            ],
        ]
    }

    static func streamBody(title: String) -> [String: Any] {
        [
            "snippet": ["title": title],
            "cdn": [
                "frameRate": "variable",
                "ingestionType": "rtmp",
                "resolution": "variable",
            ],
        ]
    }

    static func provision(
        account: StreamAccount,
        metadata: BroadcastMetadata,
        token: String,
        transport: any LiveAPITransport
    ) async throws -> ResolvedIngest {
        let broadcast = try await postJSON(
            URL(string: "https://youtube.googleapis.com/youtube/v3/liveBroadcasts?part=id,snippet,status,contentDetails")!,
            body: broadcastBody(metadata: metadata),
            token: token,
            transport: transport
        )
        let stream = try await postJSON(
            URL(string: "https://youtube.googleapis.com/youtube/v3/liveStreams?part=id,cdn,snippet")!,
            body: streamBody(title: metadata.trimmedTitle),
            token: token,
            transport: transport
        )
        guard let broadcastID = broadcast["id"] as? String,
              let streamID = stream["id"] as? String
        else { throw PlatformLiveError.missingIngest }
        _ = try await postJSON(
            URL(string: "https://youtube.googleapis.com/youtube/v3/liveBroadcasts/bind?id=\(broadcastID)&streamId=\(streamID)&part=id,contentDetails")!,
            body: [:],
            token: token,
            transport: transport
        )
        var ingestion = Self.ingestion(from: stream)
        if ingestion.key.isEmpty {
            let refreshed = try await liveAPIJSON(
                URL(string: "https://youtube.googleapis.com/youtube/v3/liveStreams?part=id,cdn&id=\(streamID)")!,
                method: "GET",
                body: nil,
                token: token,
                transport: transport
            )
            let item = (refreshed["items"] as? [[String: Any]])?.first ?? refreshed
            ingestion = Self.ingestion(from: item)
        }
        if ingestion.key.isEmpty { throw PlatformLiveError.missingIngest }
        _ = KeychainStreamVault.save(identifier: account.keychainStreamKeyIdentifier, secret: ingestion.key)
        guard let url = URL(string: ingestion.address.isEmpty ? account.rtmpUrl : ingestion.address) else {
            throw PlatformLiveError.missingIngest
        }
        return ResolvedIngest(
            accountID: account.id,
            name: account.accountName,
            platform: .youtube,
            url: url,
            streamKey: ingestion.key,
            broadcastID: broadcastID,
            streamID: streamID
        )
    }

    static func waitUntilStreamActive(
        streamID: String,
        token: String,
        transport: any LiveAPITransport,
        timeoutMs: Int = 12_000
    ) async -> Bool {
        guard !streamID.isEmpty else { return false }
        let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 400)) / 1000)
        while Date() < deadline {
            if await streamStatus(streamID: streamID, token: token, transport: transport) == "active" {
                return true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    static func streamStatus(
        streamID: String,
        token: String,
        transport: any LiveAPITransport
    ) async -> String? {
        guard let url = URL(string: "https://youtube.googleapis.com/youtube/v3/liveStreams?part=status&id=\(streamID)") else {
            return nil
        }
        guard let json = try? await liveAPIJSON(url, method: "GET", body: nil, token: token, transport: transport) else {
            return nil
        }
        let item = (json["items"] as? [[String: Any]])?.first ?? json
        return (item["status"] as? [String: Any])?["streamStatus"] as? String
    }

    static func transitionToLive(
        broadcastID: String,
        token: String,
        transport: any LiveAPITransport
    ) async {
        guard !broadcastID.isEmpty else { return }
        for status in ["testing", "live"] {
            let url = URL(
                string: "https://youtube.googleapis.com/youtube/v3/liveBroadcasts/transition?broadcastStatus=\(status)&id=\(broadcastID)&part=id,status"
            )!
            _ = try? await liveAPIJSON(url, method: "POST", body: [:], token: token, transport: transport)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    static func ingestion(from object: [String: Any]) -> (address: String, key: String) {
        let cdn = object["cdn"] as? [String: Any]
        let info = cdn?["ingestionInfo"] as? [String: Any] ?? [:]
        let address = (info["rtmpsIngestionAddress"] as? String)
            ?? (info["ingestionAddress"] as? String)
            ?? ""
        let key = (info["streamName"] as? String) ?? ""
        return (address, key)
    }
}

enum FacebookLiveService {
    static func provision(
        account: StreamAccount,
        metadata: BroadcastMetadata,
        token: String,
        transport: any LiveAPITransport
    ) async throws -> ResolvedIngest {
        let page = account.channelOrPageId.isEmpty ? "me" : account.channelOrPageId
        guard let url = URL(string: "https://graph.facebook.com/v19.0/\(page)/live_videos") else {
            throw PlatformLiveError.missingIngest
        }
        let body: [String: Any] = [
            "title": metadata.trimmedTitle,
            "description": metadata.description,
            "status": metadata.privacy == .publicAccess ? "LIVE_NOW" : "SCHEDULED_UNPUBLISHED",
        ]
        let object = try await postJSON(url, body: body, token: token, transport: transport)
        let raw = (object["secure_stream_url"] as? String) ?? (object["stream_url"] as? String)
        guard let raw else { throw PlatformLiveError.missingIngest }
        return try PlatformLiveApiService.splitIngest(raw, account: account)
    }
}

enum XGoLiveListing: Equatable, Sendable {
    case broadcast(id: String)
    case post(id: String)
}

enum XLiveService {
    static let defaultDurationMs = 12 * 60 * 60 * 1000

    static func broadcastWatchURL(broadcastID: String) -> String {
        let id = broadcastID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "https://x.com/i/broadcasts/\(id)"
    }

    static func provision(
        account: StreamAccount,
        metadata: BroadcastMetadata,
        token: String,
        transport: any LiveAPITransport
    ) async throws -> ResolvedIngest {
        _ = metadata
        _ = token
        _ = transport
        if let stored = try? PlatformLiveApiService.ingestFromKeychain(account) {
            return stored
        }
        throw PlatformLiveError.missingIngest
    }

    static func scheduledBroadcastBody(
        metadata: BroadcastMetadata,
        sourceID: String,
        start: Date = Date(),
        durationMs: Int = defaultDurationMs,
        thumbnailMediaID: String? = nil
    ) -> [String: Any] {
        let startAt = max(start, metadata.scheduledStartTime ?? start)
        let startMs = Int(startAt.timeIntervalSince1970 * 1000)
        var body: [String: Any] = [
            "source_id": sourceID,
            "scheduled_start_ms": String(startMs),
            "scheduled_end_ms": String(startMs + durationMs),
            "title": metadata.trimmedTitle,
            "description": metadata.description,
            "manual_publish": true,
            "available_for_replay": true,
            "is_locked": metadata.privacy == .privateAccess,
        ]
        if let thumbnailMediaID, !thumbnailMediaID.isEmpty {
            body["thumbnail_media_id"] = thumbnailMediaID
        }
        return body
    }

    static func tweetBody(metadata: BroadcastMetadata, shareURL: String? = nil) -> [String: Any] {
        ["text": announcementText(metadata: metadata, shareURL: shareURL)]
    }

    static func announcementText(
        metadata: BroadcastMetadata,
        shareURL: String? = nil,
        limit: Int = 280
    ) -> String {
        let trimmedURL = shareURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let urlSuffix = trimmedURL.isEmpty ? "" : "\n\n\(trimmedURL)"
        let title = metadata.trimmedTitle
        let detail = metadata.description.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = detail.isEmpty ? title : "\(title)\n\n\(detail)"
        let bodyLimit = max(1, limit - urlSuffix.count)
        if body.count > bodyLimit, bodyLimit > 1 {
            let end = body.index(body.startIndex, offsetBy: bodyLimit - 1)
            body = String(body[..<end]) + "…"
        } else if body.count > bodyLimit {
            body = String(body.prefix(bodyLimit))
        }
        return body + urlSuffix
    }

    static func nestedID(_ object: [String: Any], keys: [String]) -> String {
        let data = object["data"] as? [String: Any] ?? object
        for key in keys {
            if let text = data[key] as? String, !text.isEmpty { return text }
            if let number = data[key] as? Int { return String(number) }
            if let number = data[key] as? Int64 { return String(number) }
        }
        return ""
    }

    static func userFacingGoLiveFailure(_ error: PlatformLiveError) -> String {
        switch error {
        case .missingAccessToken, .expiredSession:
            return String(localized: "X post failed. Reconnect.")
        case .provider(let message):
            if PlatformLiveError.looksLikeClientNotEnrolled(message) {
                return String(localized: "X post failed. Check API access.")
            }
            if PlatformLiveError.looksLikeMissingWriteScope(message) {
                return String(localized: "X post failed. Reconnect.")
            }
            return String(localized: "X post failed. Retry.")
        case .httpStatus:
            return String(localized: "X post failed. Retry.")
        default:
            return String(localized: "X post failed. Retry.")
        }
    }

    /// Create the X livestream listing if Broadcasts is enabled; otherwise post the announcement.
    static func publishGoLive(
        ingest: ResolvedIngest,
        metadata: BroadcastMetadata,
        thumbnailJPEG: Data?,
        token: String,
        transport: any LiveAPITransport
    ) async -> Result<XGoLiveListing, PlatformLiveError> {
        guard metadata.publishesSocialListing else {
            return .success(.broadcast(id: ingest.broadcastID))
        }
        if OAuthAccessTokenScopes.xTokenAllowsPosting(token) == false {
            return .failure(.provider("This X sign-in does not include tweet.write. Reconnect X after the app is set to Read and write."))
        }
        let mediaID = await uploadJPEG(thumbnailJPEG, token: token, transport: transport)
        if let listing = await createAndPublishBroadcast(
            ingest: ingest,
            metadata: metadata,
            mediaID: mediaID,
            token: token,
            transport: transport
        ) {
            return .success(listing)
        }
        do {
            return .success(try await postAnnouncement(
                metadata: metadata,
                shareURL: nil,
                token: token,
                transport: transport
            ))
        } catch let error as PlatformLiveError {
            return .failure(error)
        } catch {
            return .failure(.provider(error.localizedDescription))
        }
    }

    static func createScheduledBroadcast(
        ingest: ResolvedIngest,
        metadata: BroadcastMetadata,
        thumbnailJPEG: Data?,
        token: String,
        transport: any LiveAPITransport
    ) async -> String? {
        let mediaID = await uploadJPEG(thumbnailJPEG, token: token, transport: transport)
        return await createScheduledBroadcastID(
            ingest: ingest,
            metadata: metadata,
            mediaID: mediaID,
            token: token,
            transport: transport
        )
    }

    static func goLive(broadcastID: String, token: String, transport: any LiveAPITransport) async -> Bool {
        let trimmed = broadcastID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://api.x.com/2/broadcasts/scheduled/\(trimmed)/live")
        else { return false }
        do {
            _ = try await postJSON(url, body: [:], token: token, transport: transport)
            return true
        } catch {
            return false
        }
    }

    private static func createAndPublishBroadcast(
        ingest: ResolvedIngest,
        metadata: BroadcastMetadata,
        mediaID: String?,
        token: String,
        transport: any LiveAPITransport
    ) async -> XGoLiveListing? {
        let existing = ingest.broadcastID.trimmingCharacters(in: .whitespacesAndNewlines)
        let broadcastID = existing.isEmpty
            ? await createScheduledBroadcastID(
                ingest: ingest,
                metadata: metadata,
                mediaID: mediaID,
                token: token,
                transport: transport
            )
            : existing
        guard let broadcastID else { return nil }
        _ = await goLive(broadcastID: broadcastID, token: token, transport: transport)
        let shareURL = broadcastWatchURL(broadcastID: broadcastID)
        _ = try? await postAnnouncement(
            metadata: metadata,
            shareURL: shareURL,
            token: token,
            transport: transport
        )
        return .broadcast(id: broadcastID)
    }

    private static func createScheduledBroadcastID(
        ingest: ResolvedIngest,
        metadata: BroadcastMetadata,
        mediaID: String?,
        token: String,
        transport: any LiveAPITransport
    ) async -> String? {
        guard !ingest.streamKey.isEmpty,
              let url = URL(string: "https://api.x.com/2/broadcasts/scheduled")
        else { return nil }
        do {
            let object = try await postJSON(
                url,
                body: scheduledBroadcastBody(
                    metadata: metadata,
                    sourceID: ingest.streamKey,
                    thumbnailMediaID: mediaID
                ),
                token: token,
                transport: transport
            )
            let id = nestedID(object, keys: ["broadcast_id", "id"])
            return id.isEmpty ? nil : id
        } catch {
            return nil
        }
    }

    private static func postAnnouncement(
        metadata: BroadcastMetadata,
        shareURL: String?,
        token: String,
        transport: any LiveAPITransport
    ) async throws -> XGoLiveListing {
        let endpoints = [
            "https://api.x.com/2/tweets",
            "https://api.twitter.com/2/tweets",
        ]
        var lastError: PlatformLiveError = .provider("X did not return a post id.")
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let object = try await postJSON(
                    url,
                    body: tweetBody(metadata: metadata, shareURL: shareURL),
                    token: token,
                    transport: transport
                )
                let id = nestedID(object, keys: ["id"])
                if !id.isEmpty {
                    return .post(id: id)
                }
                lastError = .provider("X accepted the request but did not return a post id.")
            } catch let error as PlatformLiveError {
                lastError = error
            }
        }
        throw lastError
    }

    private static func uploadJPEG(
        _ jpeg: Data?,
        token: String,
        transport: any LiveAPITransport
    ) async -> String? {
        guard let jpeg, !jpeg.isEmpty,
              let initURL = URL(string: "https://api.x.com/2/media/upload/initialize")
        else { return nil }
        do {
            let started = try await postJSON(
                initURL,
                body: [
                    "media_type": "image/jpeg",
                    "total_bytes": jpeg.count,
                    "media_category": "tweet_image",
                ],
                token: token,
                transport: transport
            )
            let mediaID = nestedID(started, keys: ["id"])
            guard !mediaID.isEmpty else { return nil }
            try await appendMedia(id: mediaID, jpeg: jpeg, token: token, transport: transport)
            if let finalize = URL(string: "https://api.x.com/2/media/upload/\(mediaID)/finalize") {
                _ = try await postJSON(finalize, body: [:], token: token, transport: transport)
            }
            return mediaID
        } catch {
            return nil
        }
    }

    private static func appendMedia(
        id: String,
        jpeg: Data,
        token: String,
        transport: any LiveAPITransport
    ) async throws {
        guard let url = URL(string: "https://api.x.com/2/media/upload/\(id)/append") else {
            throw PlatformLiveError.httpStatus(400)
        }
        let (body, contentType) = multipartForm(
            fields: ["segment_index": "0"],
            fileField: "media",
            filename: "thumbnail.jpg",
            mime: "image/jpeg",
            file: jpeg
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw liveAPIError(from: data, status: http.statusCode)
        }
    }
}

enum BroadcastThumbnailEncoder {
    static func jpeg(fromImageData data: Data, maxEdge: Int = 1280) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return jpeg(from: image, maxEdge: maxEdge)
    }

    #if canImport(CoreVideo)
    static func jpeg(from pixel: CVPixelBuffer, maxEdge: Int = 1280) -> Data? {
        guard let image = InputPreviewImaging.cgImage(from: pixel) else { return nil }
        return jpeg(from: image, maxEdge: maxEdge)
    }
    #endif

    static func jpeg(from image: CGImage, maxEdge: Int = 1280) -> Data? {
        let scaled = scale(image, maxEdge: maxEdge)
        let destData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            scaled,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destData as Data
    }

    private static func scale(_ image: CGImage, maxEdge: Int) -> CGImage {
        let width = image.width
        let height = image.height
        let longest = max(width, height)
        guard longest > maxEdge else { return image }
        let scale = CGFloat(maxEdge) / CGFloat(longest)
        let nextWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let nextHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: nextWidth,
            height: nextHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: nextWidth, height: nextHeight))
        return context.makeImage() ?? image
    }
}

enum LinkedInLiveService {
    static func provision(
        account: StreamAccount,
        metadata: BroadcastMetadata,
        token: String,
        transport: any LiveAPITransport
    ) async throws -> ResolvedIngest {
        _ = metadata
        _ = token
        _ = transport
        if let stored = try? PlatformLiveApiService.ingestFromKeychain(account) {
            return stored
        }
        throw PlatformLiveError.missingIngest
    }
}

private func postJSON(
    _ url: URL,
    body: [String: Any],
    token: String,
    transport: any LiveAPITransport
) async throws -> [String: Any] {
    try await liveAPIJSON(url, method: "POST", body: body, token: token, transport: transport)
}

private func liveAPIJSON(
    _ url: URL,
    method: String,
    body: [String: Any]?,
    token: String,
    transport: any LiveAPITransport
) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if url.host?.contains("linkedin.com") == true {
        request.setValue("202401", forHTTPHeaderField: "LinkedIn-Version")
        request.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
    }
    if let body, !body.isEmpty {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await transport.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw PlatformLiveError.fromAPIResponse(data, status: http.statusCode)
    }
    return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func liveAPIError(from data: Data, status: Int) -> PlatformLiveError {
    PlatformLiveError.fromAPIResponse(data, status: status)
}

private func multipartForm(
    fields: [String: String],
    fileField: String,
    filename: String,
    mime: String,
    file: Data
) -> (Data, String) {
    let boundary = "ProShow\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    var body = Data()
    for (name, value) in fields {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n".utf8))
    body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
    body.append(file)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return (body, "multipart/form-data; boundary=\(boundary)")
}
