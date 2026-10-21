#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

struct ScriptedLiveTransport: LiveAPITransport, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.absoluteString ?? ""
        var payload: [String: Any] = [:]
        if path.contains("liveBroadcasts/transition") {
            payload = ["id": "bcast-1", "status": ["lifeCycleStatus": "live"]]
        } else if path.contains("liveBroadcasts/bind") {
            payload = ["id": "bound"]
        } else if path.contains("liveBroadcasts") {
            payload = ["id": "bcast-1"]
        } else if path.contains("liveStreams") {
            payload = [
                "id": "stream-1",
                "status": ["streamStatus": "active"],
                "items": [[
                    "id": "stream-1",
                    "status": ["streamStatus": "active"],
                    "cdn": [
                        "ingestionInfo": [
                            "ingestionAddress": "rtmps://a.rtmp.youtube.com/live2",
                            "streamName": "yt-generated-key",
                        ]
                    ]
                ]],
                "cdn": [
                    "ingestionInfo": [
                        "ingestionAddress": "rtmps://a.rtmp.youtube.com/live2",
                        "streamName": "yt-generated-key",
                    ]
                ]
            ]
        } else if path.contains("live_videos") {
            payload = ["secure_stream_url": "rtmps://live-api-s.facebook.com:443/rtmp/fb-generated-key"]
        } else {
            payload = ["rtmp_url": "rtmps://va.pscp.tv/x/x-generated-key"]
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Suite
struct BroadcastGoLiveTests {
    @Test
    func metadata_requiresTitle() {
        #expect(BroadcastMetadata(title: "  ").validate() != nil)
        #expect(BroadcastMetadata(title: "Sunday Service").validate() == nil)
    }

    @Test
    func pkce_isUrlSafe() {
        let verifier = StreamPKCE.makeVerifier()
        let challenge = StreamPKCE.codeChallenge(for: verifier)
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
        #expect(!challenge.contains("="))
        #expect(challenge != verifier)
    }

    @Test
    func ingestParser_splitsKeyFromPath() {
        let parsed = IngestURLParser.parse("rtmps://live-api-s.facebook.com:443/rtmp/supersecretkey")
        #expect(parsed.url?.host == "live-api-s.facebook.com")
        #expect(parsed.streamKey == "supersecretkey")
        #expect(!(parsed.url?.absoluteString.contains("supersecretkey") ?? true))
    }

    @Test
    func youtubeBody_usesPrivacyAndTitle() {
        let body = YouTubeLiveService.broadcastBody(
            metadata: BroadcastMetadata(title: "Sunrise", privacy: .unlisted)
        )
        let snippet = body["snippet"] as? [String: Any]
        let status = body["status"] as? [String: Any]
        #expect(snippet?["title"] as? String == "Sunrise")
        #expect(status?["privacyStatus"] as? String == "unlisted")
    }

    @Test
    func loopbackServer_requiresTheFamilyTheRedirectHostNames() {
        #expect(OAuthLoopbackServer.requiredFamilies(host: "127.0.0.1") == (true, false))
        #expect(OAuthLoopbackServer.requiredFamilies(host: "[::1]") == (false, true))
        #expect(OAuthLoopbackServer.requiredFamilies(host: "localhost") == (true, true))
    }

    @Test @MainActor
    func xChatAuthorizationURL_requestsBroadcastScopesOnlyWhenAsked() throws {
        guard StreamAccountManager.shared.hasClientID(for: .twitter) else { return }
        let redirect = URL(string: StreamOAuthConfiguration.proshowXRedirectURI)!
        let chat = try StreamAccountManager.shared.authorizationURL(
            for: .twitter, verifier: "v", redirectURI: redirect, state: "s", scopes: XChatAuth.scopes)
        let plain = try StreamAccountManager.shared.authorizationURL(for: .twitter, verifier: "v", redirectURI: redirect, state: "s")
        func scope(_ u: URL) -> String { URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value ?? "" }
        #expect(scope(chat) == "tweet.read users.read broadcast.read broadcast.write offline.access")
        #expect(scope(plain) == StreamOAuthConfiguration.xUserScopes)
        #expect(!scope(plain).contains("broadcast"))
    }

    @Test @MainActor
    func youtubeAuthorizationURL_usesLoopbackNotCustomScheme() throws {
        let redirect = StreamOAuthConfiguration.loopbackCallback()
        let url = try StreamAccountManager.shared.authorizationURL(
            for: .youtube,
            verifier: "verifier-value",
            redirectURI: redirect,
            state: "state-1"
        )
        #expect(url.host == "accounts.google.com")
        #expect(url.absoluteString.contains("localhost") || url.absoluteString.contains("127.0.0.1"))
        #expect(!url.absoluteString.contains("proshow://"))
        #expect(StreamOAuthConfiguration.usesLoopbackRedirect(for: .youtube))
        #expect(StreamOAuthConfiguration.usesLoopbackRedirect(for: .linkedin))
        #expect(StreamOAuthConfiguration.usesLoopbackRedirect(for: .twitter))
        #expect(StreamOAuthConfiguration.usesLoopbackRedirect(for: .facebook))
        let linkedin = try StreamAccountManager.shared.authorizationURL(
            for: .linkedin,
            verifier: "verifier-value",
            redirectURI: StreamOAuthConfiguration.resolvedLoopbackRedirect(
                preferred: StreamOAuthConfiguration.n8nRedirectURI,
                platform: .linkedin
            ),
            state: "state-1"
        )
        #expect(linkedin.host == "www.linkedin.com")
        #expect(linkedin.absoluteString.contains("localhost"))
        #expect(!linkedin.absoluteString.contains("proshow://"))
        #expect(!linkedin.absoluteString.contains("code_challenge"))
        #expect(linkedin.absoluteString.contains("openid"))
        #expect(!linkedin.absoluteString.contains("r_organization_social"))
        #expect(!StreamOAuthConfiguration.usesPKCE(for: .linkedin))
        #expect(StreamOAuthConfiguration.requiresClientSecret(for: .linkedin))
        #expect(StreamOAuthConfiguration.requiresClientSecret(for: .youtube))
    }

    @Test
    func loopbackRedirect_defaultsToN8nCallback() {
        let url = StreamOAuthConfiguration.resolvedLoopbackRedirect(preferred: nil)
        #expect(url.absoluteString == StreamOAuthConfiguration.n8nRedirectURI)
        #expect(StreamOAuthConfiguration.parseLoopbackRedirect("https://evil.example/oauth") == nil)
        let x = StreamOAuthConfiguration.resolvedLoopbackRedirect(
            preferred: StreamOAuthConfiguration.n8nRedirectURI,
            platform: .twitter
        )
        #expect(x.absoluteString == StreamOAuthConfiguration.proshowXRedirectURI)
        #expect(x.host == "127.0.0.1")
        #expect(x.port == 55079)
    }

    @Test
    func loopbackCallback_parsesCodeFromRequestLine() throws {
        let registered = URL(string: StreamOAuthConfiguration.n8nRedirectURI)!
        let request = "GET /rest/oauth2-credential/callback?code=abc123&state=s1 HTTP/1.1\r\nHost: localhost:5678\r\n\r\n"
        let url = try #require(OAuthLoopbackServer.callbackURL(from: request, registered: registered))
        #expect(url.path == "/rest/oauth2-credential/callback")
        #expect(try StreamPKCE.authorizationCode(from: url) == "abc123")
        #expect(url.host == "localhost")
        #expect(url.port == 5678)
    }

    @Test
    func loopbackCallback_keepsCodeWhenPathDiffersAndIgnoresFavicon() throws {
        let registered = URL(string: StreamOAuthConfiguration.n8nRedirectURI)!
        let root = "GET /?code=from-root&state=s1 HTTP/1.1\r\nHost: localhost:5678\r\n\r\n"
        let url = try #require(OAuthLoopbackServer.callbackURL(from: root, registered: registered))
        #expect(try StreamPKCE.authorizationCode(from: url) == "from-root")
        #expect(OAuthLoopbackServer.result(
            from: "GET /favicon.ico HTTP/1.1\r\nHost: localhost:5678\r\n\r\n",
            registered: registered
        ) == .ignore)
        let rejected = URL(string: "http://localhost:5678/rest/oauth2-credential/callback?error=unauthorized_scope_error&error_description=bad+scope")!
        #expect(StreamPKCE.providerError(from: rejected) == "bad scope")
    }

    @Test @MainActor
    func linkedinTokenRequest_usesSecretNotPKCE() {
        StreamOAuthConfiguration.secretOverrides[.linkedin] = "test-linkedin-secret"
        defer { StreamOAuthConfiguration.secretOverrides.removeValue(forKey: .linkedin) }
        let request = StreamAccountManager.shared.tokenRequest(
            code: "abc",
            verifier: "should-not-appear",
            clientID: "client",
            platform: .linkedin
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("client_secret=test-linkedin-secret"))
        #expect(!body.contains("code_verifier"))
        #expect(!body.contains("should-not-appear"))
    }

    @Test @MainActor
    func oauthClientIDs_areConfiguredForYouTubeXLinkedIn() {
        #expect(StreamAccountManager.shared.hasClientID(for: .youtube))
        #expect(StreamAccountManager.shared.hasClientID(for: .twitter))
        #expect(StreamAccountManager.shared.hasClientID(for: .linkedin))
        #expect(!StreamAccountManager.shared.hasClientID(for: .facebook))
    }

    @Test @MainActor
    func youtubeTokenRequest_includesSecretWhenPresent() {
        StreamOAuthConfiguration.secretOverrides[.youtube] = "test-youtube-secret"
        defer { StreamOAuthConfiguration.secretOverrides.removeValue(forKey: .youtube) }
        let request = StreamAccountManager.shared.tokenRequest(
            code: "abc",
            verifier: "verifier",
            clientID: "client",
            platform: .youtube
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("client_secret=test-youtube-secret"))
        #expect(body.contains("code_verifier=verifier"))
        #expect(!body.contains("GOCSPX"))
    }

    @Test
    func identity_parsesYouTubeChannel() {
        let identity = StreamIdentityService.parseYouTube([
            "items": [[
                "id": "UCchurch",
                "snippet": [
                    "title": "Sunrise Church",
                    "thumbnails": ["default": ["url": "https://img.example/yt.jpg"]],
                ],
            ]],
        ])
        #expect(identity?.displayName == "Sunrise Church")
        #expect(identity?.channelOrPageId == "UCchurch")
        #expect(identity?.profileImageUrl == "https://img.example/yt.jpg")
    }

    @Test
    func identity_parsesXHandle() {
        let identity = StreamIdentityService.parseX([
            "data": [
                "id": "42",
                "name": "Jane",
                "username": "jane",
                "profile_image_url": "https://img.example/x.jpg",
            ]
        ])
        #expect(identity?.displayName == "Jane")
        #expect(identity?.channelOrPageId == "42")
    }

    @Test
    func identity_parsesLinkedInAndFacebook() {
        let linked = StreamIdentityService.parseLinkedInUserInfo([
            "sub": "person-1",
            "name": "Alex Rivera",
            "picture": "https://img.example/li.jpg",
        ])
        #expect(linked.displayName == "Alex Rivera")
        #expect(linked.channelOrPageId == "person-1")
        let facebook = StreamIdentityService.parseFacebook(
            me: ["id": "user-1", "name": "Alex"],
            pages: ["data": [["id": "page-9", "name": "Ministry Page"]]]
        )
        #expect(facebook?.displayName == "Ministry Page")
        #expect(facebook?.channelOrPageId == "page-9")
    }

    @Test @MainActor
    func completeAuthentication_fillsProfileFromBackend() async throws {
        let manager = StreamAccountManager()
        manager.codeExchange = { _ in
            try JSONSerialization.data(withJSONObject: ["access_token": "tok", "refresh_token": "ref"])
        }
        manager.identityLoader = { _, _ in
            StreamIdentity(displayName: "Sunrise Church", channelOrPageId: "UCabc", profileImageUrl: "https://img")
        }
        let account = try await manager.completeAuthentication(
            platform: .youtube,
            code: "auth-code",
            verifier: "verifier"
        )
        #expect(account.accountName == "Sunrise Church")
        #expect(account.channelOrPageId == "UCabc")
        #expect(account.profileImageUrl == "https://img")
        #expect(account.isAuthenticated)
        defer {
            _ = KeychainStreamVault.delete(identifier: account.oauthAccessIdentifier)
            _ = KeychainStreamVault.delete(identifier: account.oauthRefreshIdentifier)
        }
        #expect(KeychainStreamVault.load(identifier: account.oauthAccessIdentifier) == "tok")
    }

    @Test
    func accountJSON_omitsTokens() throws {
        let account = StreamAccount(accountName: "Main", platform: .youtube, channelOrPageId: "UC123")
        let json = String(decoding: try JSONEncoder().encode(account), as: UTF8.self)
        #expect(!json.contains("access_token"))
        #expect(!json.contains("refresh_token"))
        #expect(json.contains("channelOrPageId"))
    }

    @Test @MainActor
    func oneEncode_twoDestinationsUseRelay() {
        let engine = StreamingEngine()
        let youtube = ResolvedIngest(
            accountID: UUID(),
            name: "YT",
            platform: .youtube,
            url: URL(string: "rtmps://a.rtmp.youtube.com/live2")!,
            streamKey: "one"
        )
        let facebook = ResolvedIngest(
            accountID: UUID(),
            name: "FB",
            platform: .facebook,
            url: URL(string: "rtmps://live-api-s.facebook.com/rtmp")!,
            streamKey: "two"
        )
        engine.configureOutputs([youtube, facebook])
        #expect(engine.config.useCloudRelay)
        #expect(engine.config.relayDestinations.count == 2)
        engine.configureOutputs([youtube])
        #expect(!engine.config.useCloudRelay)
    }

    @Test
    func youtubeIngestion_readsRtmpsAddressAndStreamName() {
        let parsed = YouTubeLiveService.ingestion(from: [
            "cdn": [
                "ingestionInfo": [
                    "rtmpsIngestionAddress": "rtmps://a.rtmps.youtube.com/live2",
                    "ingestionAddress": "rtmp://a.rtmp.youtube.com/live2",
                    "streamName": "minted-key",
                ]
            ]
        ])
        #expect(parsed.address.contains("rtmps://"))
        #expect(parsed.key == "minted-key")
    }

    @Test
    func provisionYouTube_storesKeyInKeychain() async throws {
        var service = PlatformLiveApiService()
        service.transport = ScriptedLiveTransport()
        service.tokenProvider = { _ in "access-token" }
        let account = StreamAccount(accountName: "Church", platform: .youtube)
        defer { _ = KeychainStreamVault.delete(identifier: account.keychainStreamKeyIdentifier) }
        let ingest = try await service.provisionLiveBroadcast(
            for: account,
            metadata: BroadcastMetadata(title: "Sunday")
        )
        #expect(ingest.platform == .youtube)
        #expect(ingest.streamKey == "yt-generated-key")
        #expect(ingest.streamID == "stream-1")
        #expect(KeychainStreamVault.load(identifier: account.keychainStreamKeyIdentifier) == "yt-generated-key")
        #expect(!ingest.publicURLString.contains("yt-generated-key"))
        let active = await YouTubeLiveService.waitUntilStreamActive(
            streamID: ingest.streamID,
            token: "access-token",
            transport: service.transport
        )
        #expect(active)
    }

    @Test @MainActor
    func startBroadcast_provisionsThenGoesLive() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-device-settings.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(url: url)
        let youtube = StreamAccount(accountName: "Main", platform: .youtube)
        store.upsert(youtube, secret: "fallback")
        defer {
            _ = KeychainStreamVault.delete(identifier: youtube.keychainStreamKeyIdentifier)
            _ = KeychainStreamVault.delete(identifier: youtube.oauthAccessIdentifier)
        }
        let sample = SampleContent.sundayMorningService()
        let controller = ShowController(
            show: sample.show,
            playlist: sample.playlist,
            store: .temporary(),
            persistOnInit: false,
            deviceSettings: store
        )
        var api = PlatformLiveApiService()
        api.transport = ScriptedLiveTransport()
        api.tokenProvider = { _ in "access-token" }
        controller.streaming.transport = MockStreamTransport()
        let started = await controller.startMultiPlatformBroadcast(
            metadata: BroadcastMetadata(title: "Sunday Morning"),
            accounts: [youtube],
            api: api,
            skipPreflight: true
        )
        #expect(started)
        #expect(controller.streaming.isLive)
        #expect(!controller.streaming.config.useCloudRelay)
        controller.stopBroadcast()
        #expect(!controller.streaming.isLive)
    }

    @Test @MainActor
    func youtubeRefreshRequest_usesRefreshGrant() {
        StreamOAuthConfiguration.secretOverrides[.youtube] = "yt-secret"
        defer { StreamOAuthConfiguration.secretOverrides.removeValue(forKey: .youtube) }
        let request = StreamAccountManager.shared.refreshRequest(
            refreshToken: "refresh-1",
            clientID: "client",
            platform: .youtube
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(request.url?.host == "oauth2.googleapis.com")
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=refresh-1"))
        #expect(body.contains("client_secret=yt-secret"))
        #expect(!body.contains("code_verifier"))
    }

    @Test @MainActor
    func expiredAccessToken_refreshesSilently() async throws {
        let manager = StreamAccountManager()
        manager.codeExchange = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("grant_type=refresh_token"))
            return try JSONSerialization.data(withJSONObject: [
                "access_token": "fresh-access",
                "expires_in": 3600,
            ])
        }
        var account = StreamAccount(accountName: "Main", platform: .youtube)
        account.tokenExpiresAt = Date().addingTimeInterval(-120)
        _ = KeychainStreamVault.save(identifier: account.oauthAccessIdentifier, secret: "stale-access")
        _ = KeychainStreamVault.save(identifier: account.oauthRefreshIdentifier, secret: "refresh-1")
        defer {
            _ = KeychainStreamVault.delete(identifier: account.oauthAccessIdentifier)
            _ = KeychainStreamVault.delete(identifier: account.oauthRefreshIdentifier)
            _ = KeychainStreamVault.delete(identifier: account.oauthExpiresIdentifier)
        }
        #expect(manager.shouldRefreshAccessToken(for: account))
        let box = try await manager.ensureValidAccessToken(for: account)
        #expect(box.accessToken == "fresh-access")
        #expect(KeychainStreamVault.load(identifier: account.oauthAccessIdentifier) == "fresh-access")
    }

    @Test
    func provisionYouTube_retriesAfterExpiredCredentials() async throws {
        var service = PlatformLiveApiService()
        service.transport = FlipAuthTransport()
        service.tokenRefresher = ScriptedTokenRefresher()
        let account = StreamAccount(accountName: "Church", platform: .youtube)
        defer { _ = KeychainStreamVault.delete(identifier: account.keychainStreamKeyIdentifier) }
        let ingest = try await service.provisionLiveBroadcast(
            for: account,
            metadata: BroadcastMetadata(title: "Sunday")
        )
        #expect(ingest.streamKey == "yt-generated-key")
    }

    @Test @MainActor
    func linkedinTokenStaysValidWithoutHourlyRefresh() {
        let manager = StreamAccountManager()
        var account = StreamAccount(accountName: "Work", platform: .linkedin)
        account.lastAuthenticated = Date().addingTimeInterval(-4 * 60 * 60)
        _ = KeychainStreamVault.save(identifier: account.oauthAccessIdentifier, secret: "linkedin-access")
        defer { _ = KeychainStreamVault.delete(identifier: account.oauthAccessIdentifier) }
        #expect(!manager.shouldRefreshAccessToken(for: account))
        var youtube = StreamAccount(accountName: "Church", platform: .youtube)
        youtube.lastAuthenticated = Date().addingTimeInterval(-4 * 60 * 60)
        _ = KeychainStreamVault.save(identifier: youtube.oauthAccessIdentifier, secret: "yt-access")
        defer { _ = KeychainStreamVault.delete(identifier: youtube.oauthAccessIdentifier) }
        #expect(manager.shouldRefreshAccessToken(for: youtube))
    }

    @Test @MainActor
    func broadcastFailure_namesTheSelectedPlatform() {
        let linkedin = ShowController.broadcastFailureMessage(
            PlatformLiveError.expiredSession,
            platform: .linkedin
        )
        #expect(linkedin.contains("LinkedIn"))
        #expect(!linkedin.localizedCaseInsensitiveContains("youtube"))
        let x = ShowController.broadcastFailureMessage(
            PlatformLiveError.missingIngest,
            platform: .twitter
        )
        #expect(x.contains("X"))
        #expect(x.localizedCaseInsensitiveContains("studio.x.com"))
        #expect(!x.localizedCaseInsensitiveContains("youtube live"))
    }

    @Test @MainActor
    func xTokenRequest_usesBasicAuthWhenSecretPresent() {
        StreamOAuthConfiguration.secretOverrides[.twitter] = "x-secret"
        defer { StreamOAuthConfiguration.secretOverrides.removeValue(forKey: .twitter) }
        let request = StreamAccountManager.shared.tokenRequest(
            code: "abc",
            verifier: "verifier",
            clientID: "x-client",
            platform: .twitter
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        #expect(body.contains("code_verifier=verifier"))
        #expect(!body.contains("client_secret"))
        let url = try? StreamAccountManager.shared.authorizationURL(
            for: .twitter,
            verifier: "verifier-value",
            redirectURI: StreamOAuthConfiguration.loopbackCallback(),
            state: "state-1"
        )
        #expect(url?.host == "twitter.com")
        #expect(url?.absoluteString.contains("tweet.write") == true)
        #expect(url?.absoluteString.contains("media.write") == true)
        #expect(url?.absoluteString.contains("broadcast.write") == false)
        #expect(url?.absoluteString.contains("users.read") == true)
    }

    @Test @MainActor
    func startBroadcast_linkedinWithoutToken_doesNotBlameYouTube() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-device-settings.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(url: url)
        let linkedin = StreamAccount(accountName: "Work", platform: .linkedin)
        store.upsert(linkedin, secret: nil)
        let sample = SampleContent.sundayMorningService()
        let controller = ShowController(
            show: sample.show,
            playlist: sample.playlist,
            store: .temporary(),
            persistOnInit: false,
            deviceSettings: store
        )
        controller.streaming.transport = MockStreamTransport()
        let started = await controller.startMultiPlatformBroadcast(
            metadata: BroadcastMetadata(title: "Sunday Morning"),
            accounts: [linkedin],
            skipPreflight: true
        )
        #expect(!started)
        let message = controller.lastBroadcastError ?? ""
        #expect(message.localizedCaseInsensitiveContains("linkedin"))
        #expect(!message.localizedCaseInsensitiveContains("youtube"))
    }

    @Test
    func provisionX_usesPastedStudioKeyWithoutCallingXAPI() async throws {
        var service = PlatformLiveApiService()
        service.transport = ScriptedLiveTransport()
        service.tokenProvider = { _ in "access-token" }
        let account = StreamAccount(accountName: "Newsdesk", platform: .twitter)
        _ = KeychainStreamVault.save(identifier: account.keychainStreamKeyIdentifier, secret: "x-studio-key")
        defer { _ = KeychainStreamVault.delete(identifier: account.keychainStreamKeyIdentifier) }
        let ingest = try await service.provisionLiveBroadcast(
            for: account,
            metadata: BroadcastMetadata(title: "Sunday")
        )
        #expect(ingest.platform == .twitter)
        #expect(ingest.streamKey == "x-studio-key")
        #expect(account.needsManualIngest)
        #expect(!StreamAccount(accountName: "YT", platform: .youtube).needsManualIngest)
    }

    @Test
    func liveAPIError_mapsInvalidCredentials() {
        #expect(PlatformLiveError.looksLikeInvalidCredentials(
            "Request had invalid authentication credentials. Expected OAuth 2 access token."
        ))
    }

    @Test
    func liveAPIError_readsXProblemBody() throws {
        let payload: [String: Any] = [
            "title": "Client Forbidden",
            "detail": "Your client is not authorized to use this endpoint.",
            "reason": "client-not-enrolled",
            "required_enrollment": "Appropriate Level of API Access",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let error = PlatformLiveError.fromAPIResponse(data, status: 403)
        guard case .provider(let message) = error else {
            Issue.record("expected provider error")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("client-not-enrolled"))
        #expect(PlatformLiveError.looksLikeClientNotEnrolled(message))
        let text = XLiveService.userFacingGoLiveFailure(error)
        #expect(text.localizedCaseInsensitiveContains("not enrolled"))
        #expect(!text.localizedCaseInsensitiveContains("set the x app to read and write"))
    }

    @Test
    func xTokenScopes_detectMissingTweetWrite() {
        let token = fakeJWT(scope: "tweet.read users.read offline.access")
        #expect(OAuthAccessTokenScopes.xTokenAllowsPosting(token) == false)
        #expect(OAuthAccessTokenScopes.listed(in: token).contains("tweet.read"))
        #expect(OAuthAccessTokenScopes.xTokenAllowsPosting("opaque-token") == nil)
        #expect(OAuthAccessTokenScopes.xTokenAllowsPosting(fakeJWT(scope: "tweet.read tweet.write users.read")) == true)
    }

    @Test
    func xScheduledBody_bindsSourceTitleAndThumbnail() {
        let body = XLiveService.scheduledBroadcastBody(
            metadata: BroadcastMetadata(title: "Sunday Service", description: "Join us", privacy: .privateAccess),
            sourceID: "rtmp-source-key",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            thumbnailMediaID: "998877"
        )
        #expect(body["source_id"] as? String == "rtmp-source-key")
        #expect(body["title"] as? String == "Sunday Service")
        #expect(body["description"] as? String == "Join us")
        #expect(body["manual_publish"] as? Bool == true)
        #expect(body["is_locked"] as? Bool == true)
        #expect(body["thumbnail_media_id"] as? String == "998877")
        #expect(body["scheduled_start_ms"] as? String == "1700000000000")
    }

    @Test
    func xAnnouncement_fitsTweetLimit() {
        let text = XLiveService.announcementText(
            metadata: BroadcastMetadata(title: "Sunday", description: String(repeating: "b", count: 400))
        )
        #expect(text.count == 280)
        #expect(text.hasPrefix("Sunday"))
        #expect(text.hasSuffix("…"))
        let tweet = XLiveService.tweetBody(
            metadata: BroadcastMetadata(title: "Sunday"),
            shareURL: "https://x.com/i/broadcasts/abc123xyz"
        )
        #expect(tweet["text"] as? String == "Sunday\n\nhttps://x.com/i/broadcasts/abc123xyz")
        #expect(tweet["media"] == nil)
    }

    @Test
    func xAnnouncement_includesBroadcastWatchURL() {
        let url = XLiveService.broadcastWatchURL(broadcastID: "abc123xyz")
        #expect(url == "https://x.com/i/broadcasts/abc123xyz")
        let text = XLiveService.announcementText(
            metadata: BroadcastMetadata(title: "Sunday Service", description: "Join us"),
            shareURL: url
        )
        #expect(text.contains(url))
        #expect(text.hasPrefix("Sunday Service"))
    }

    @Test
    func broadcastMetadata_privateSkipsSocialListing() {
        let pub = BroadcastMetadata(title: "Live", privacy: .publicAccess)
        let priv = BroadcastMetadata(title: "Live", privacy: .privateAccess)
        #expect(pub.publishesSocialListing)
        #expect(!priv.publishesSocialListing)
    }

    @Test
    func metadataJSON_omitsThumbnailBytes() throws {
        var metadata = BroadcastMetadata(title: "Sunday", thumbnailFileName: "poster.jpg")
        metadata.thumbnailJPEG = Data([0xFF, 0xD8, 0xFF])
        let json = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        #expect(json.contains("poster.jpg"))
        #expect(!json.contains("thumbnailJPEG"))
        #expect(!json.contains("/9j/"))
    }

    @Test
    func xGoLive_createsScheduledBroadcastThenGoesLive() async {
        let transport = ScriptedXListingTransport(mode: .broadcast)
        let listing = await XLiveService.publishGoLive(
            ingest: ResolvedIngest(
                accountID: UUID(),
                name: "Newsdesk",
                platform: .twitter,
                url: URL(string: "rtmps://va.pscp.tv/x")!,
                streamKey: "studio-source"
            ),
            metadata: BroadcastMetadata(title: "Sunday Service", description: "Join us live."),
            thumbnailJPEG: nil,
            token: "x-token",
            transport: transport
        )
        #expect(listing == .success(.broadcast(id: "abc123xyz")))
        #expect(transport.paths.contains { $0.hasSuffix("/2/broadcasts/scheduled") })
        #expect(transport.paths.contains { $0.hasSuffix("/2/broadcasts/scheduled/abc123xyz/live") })
        #expect(transport.paths.contains { $0.contains("/2/tweets") })
    }

    @Test
    func xGoLive_privateSkipsListingAndPosts() async {
        let transport = ScriptedXListingTransport(mode: .broadcast)
        let listing = await XLiveService.publishGoLive(
            ingest: ResolvedIngest(
                accountID: UUID(),
                name: "Newsdesk",
                platform: .twitter,
                url: URL(string: "rtmps://va.pscp.tv/x")!,
                streamKey: "studio-source",
                broadcastID: "prepared-id"
            ),
            metadata: BroadcastMetadata(title: "Sunday Service", privacy: .privateAccess),
            thumbnailJPEG: Data([0xFF, 0xD8]),
            token: "x-token",
            transport: transport
        )
        #expect(listing == .success(.broadcast(id: "prepared-id")))
        #expect(transport.paths.isEmpty)
    }

    @Test
    func xGoLive_fallsBackToTweetWhenBroadcastsForbidden() async {
        let transport = ScriptedXListingTransport(mode: .tweetOnly)
        let listing = await XLiveService.publishGoLive(
            ingest: ResolvedIngest(
                accountID: UUID(),
                name: "Newsdesk",
                platform: .twitter,
                url: URL(string: "rtmps://va.pscp.tv/x")!,
                streamKey: "studio-source"
            ),
            metadata: BroadcastMetadata(title: "Sunday Service"),
            thumbnailJPEG: nil,
            token: "x-token",
            transport: transport
        )
        #expect(listing == .success(.post(id: "tweet-9")))
        #expect(transport.paths.contains { $0.hasSuffix("/2/tweets") })
    }

    @Test
    func xGoLive_reportsClientForbiddenInsteadOfReadAndWriteHint() async {
        let transport = ScriptedXListingTransport(mode: .clientForbidden)
        let listing = await XLiveService.publishGoLive(
            ingest: ResolvedIngest(
                accountID: UUID(),
                name: "Newsdesk",
                platform: .twitter,
                url: URL(string: "rtmps://va.pscp.tv/x")!,
                streamKey: "studio-source"
            ),
            metadata: BroadcastMetadata(title: "Sunday Service"),
            thumbnailJPEG: nil,
            token: "x-token",
            transport: transport
        )
        guard case .failure(let error) = listing else {
            Issue.record("expected failure")
            return
        }
        let text = XLiveService.userFacingGoLiveFailure(error)
        #expect(text.localizedCaseInsensitiveContains("not enrolled"))
        #expect(text.localizedCaseInsensitiveContains("write api"))
    }

    @Test
    func xGoLive_rejectsTokenMissingTweetWrite() async {
        let transport = ScriptedXListingTransport(mode: .tweetOnly)
        let listing = await XLiveService.publishGoLive(
            ingest: ResolvedIngest(
                accountID: UUID(),
                name: "Newsdesk",
                platform: .twitter,
                url: URL(string: "rtmps://va.pscp.tv/x")!,
                streamKey: "studio-source"
            ),
            metadata: BroadcastMetadata(title: "Sunday Service"),
            thumbnailJPEG: nil,
            token: fakeJWT(scope: "tweet.read users.read offline.access"),
            transport: transport
        )
        guard case .failure(let error) = listing else {
            Issue.record("expected failure")
            return
        }
        #expect(PlatformLiveError.looksLikeMissingWriteScope(XLiveService.userFacingGoLiveFailure(error)))
        #expect(transport.paths.isEmpty)
    }
}

private final class ScriptedXListingTransport: LiveAPITransport, @unchecked Sendable {
    enum Mode {
        case broadcast
        case tweetOnly
        case clientForbidden
    }

    let mode: Mode
    private(set) var paths: [String] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        paths.append(path)
        let payload: [String: Any]
        let status: Int
        if path.hasSuffix("/2/broadcasts/scheduled") {
            switch mode {
            case .broadcast:
                payload = ["data": ["broadcast_id": "abc123xyz"]]
                status = 201
            case .tweetOnly:
                payload = ["title": "Forbidden", "detail": "broadcast.write required"]
                status = 403
            case .clientForbidden:
                payload = [
                    "title": "Client Forbidden",
                    "detail": "Your client is not authorized to use this endpoint.",
                    "reason": "client-not-enrolled",
                    "required_enrollment": "Appropriate Level of API Access",
                ]
                status = 403
            }
        } else if path.contains("/2/broadcasts/scheduled/"), path.hasSuffix("/live") {
            payload = ["data": ["state": "Running"]]
            status = 200
        } else if path.hasSuffix("/2/tweets") {
            switch mode {
            case .clientForbidden:
                payload = [
                    "title": "Client Forbidden",
                    "detail": "Your client is not authorized to use this endpoint.",
                    "reason": "client-not-enrolled",
                ]
                status = 403
            default:
                payload = ["data": ["id": "tweet-9", "text": "Sunday Service"]]
                status = 201
            }
        } else {
            payload = [:]
            status = 404
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

private func fakeJWT(scope: String) -> String {
    func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        var encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while encoded.last == "=" { encoded.removeLast() }
        return encoded
    }
    return "\(encode(["alg": "none"])).\(encode(["scope": scope])).sig"
}

private struct ScriptedTokenRefresher: StreamAccessTokenRefreshing {
    func validAccessToken(for account: StreamAccount, forceRefresh: Bool) async throws -> String {
        forceRefresh ? "fresh-token" : "stale-token"
    }
}

private final class FlipAuthTransport: LiveAPITransport, @unchecked Sendable {
    private var unauthorizedLeft = 1
    private let ok = ScriptedLiveTransport()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if unauthorizedLeft > 0 {
            unauthorizedLeft -= 1
            let payload: [String: Any] = [
                "error": [
                    "code": 401,
                    "status": "UNAUTHENTICATED",
                    "message": "Request had invalid authentication credentials. Expected OAuth 2 access token.",
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        return try await ok.data(for: request)
    }
}
