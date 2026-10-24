import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(AppKit)
import AppKit
#endif

enum StreamOAuthError: Error, Equatable {
    case missingClientID
    case missingClientSecret
    case cancelled
    case invalidCallback
    case tokenExchangeFailed
    case unsupportedPlatform
    case providerRejected(String)
    case expiredSession
}

/// PKCE OAuth for YouTube, Facebook, X, and LinkedIn. Tokens stay in the local vault.
@MainActor
final class StreamAccountManager {
    static let shared = StreamAccountManager()

    var presentationAnchor: AnyObject?
    var codeExchange: ((URLRequest) async throws -> Data)?
    var identityLoader: ((StreamPlatform, String) async throws -> StreamIdentity?)?
    var profileTransport: (any LiveAPITransport)?

    func hasClientID(for platform: StreamPlatform) -> Bool {
        StreamOAuthConfiguration.clientID(for: platform) != nil
    }

    func authorizationURL(
        for platform: StreamPlatform,
        verifier: String,
        redirectURI: URL = StreamOAuthConfiguration.callbackURL,
        state: String? = nil,
        scopes: String? = nil
    ) throws -> URL {
        guard let clientID = StreamOAuthConfiguration.clientID(for: platform) else {
            throw StreamOAuthError.missingClientID
        }
        let redirect = redirectURI.absoluteString
        var components: URLComponents
        switch platform {
        case .youtube:
            components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/youtube https://www.googleapis.com/auth/youtube.readonly"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
        case .facebook:
            components = URLComponents(string: "https://www.facebook.com/v19.0/dialog/oauth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "pages_manage_posts,publish_video,pages_read_engagement,pages_show_list"),
            ]
        case .twitter:
            components = URLComponents(string: "https://twitter.com/i/oauth2/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: scopes ?? StreamOAuthConfiguration.xUserScopes),
            ]
        case .linkedin:
            components = URLComponents(string: "https://www.linkedin.com/oauth/v2/authorization")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "openid profile email"),
            ]
        case .customRtmp, .srt:
            throw StreamOAuthError.unsupportedPlatform
        }
        if StreamOAuthConfiguration.usesPKCE(for: platform) {
            let challenge = StreamPKCE.codeChallenge(for: verifier)
            components.queryItems?.append(URLQueryItem(name: "code_challenge", value: challenge))
            components.queryItems?.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        if let state {
            components.queryItems?.append(URLQueryItem(name: "state", value: state))
        }
        guard let url = components.url else { throw StreamOAuthError.invalidCallback }
        return url
    }

    func authenticate(
        platform: StreamPlatform,
        existing: StreamAccount? = nil,
        redirectURI: URL? = nil,
        scopes: String? = nil
    ) async throws -> StreamAccount {
        if StreamOAuthConfiguration.requiresClientSecret(for: platform),
           !StreamOAuthConfiguration.hasClientSecret(for: platform) {
            throw StreamOAuthError.missingClientSecret
        }
        let verifier = StreamPKCE.makeVerifier()
        let state = StreamPKCE.makeVerifier()
        if StreamOAuthConfiguration.usesLoopbackRedirect(for: platform) {
            return try await authenticateWithLoopback(
                platform: platform,
                verifier: verifier,
                state: state,
                existing: existing,
                redirectURI: redirectURI ?? StreamOAuthConfiguration.resolvedLoopbackRedirect(
                    preferred: nil,
                    platform: platform
                ),
                scopes: scopes
            )
        }
        let url = try authorizationURL(for: platform, verifier: verifier, state: state, scopes: scopes)
        let callback = try await openSession(url: url)
        try StreamPKCE.validate(state: state, in: callback)
        let code = try StreamPKCE.authorizationCode(from: callback)
        return try await completeAuthentication(
            platform: platform,
            code: code,
            verifier: verifier,
            existing: existing
        )
    }

    private func authenticateWithLoopback(
        platform: StreamPlatform,
        verifier: String,
        state: String,
        existing: StreamAccount?,
        redirectURI: URL,
        scopes: String? = nil
    ) async throws -> StreamAccount {
        let server = OAuthLoopbackServer(redirect: redirectURI)
        try server.start()
        await server.waitUntilReady()
        defer { server.stop() }
        let redirect = server.callbackURL
        let url = try authorizationURL(
            for: platform,
            verifier: verifier,
            redirectURI: redirect,
            state: state,
            scopes: scopes
        )
        try openBrowser(url)
        let callback = try await server.waitForCallback()
        if let rejected = StreamPKCE.providerError(from: callback) {
            throw StreamOAuthError.providerRejected(rejected)
        }
        try StreamPKCE.validate(state: state, in: callback)
        let code = try StreamPKCE.authorizationCode(from: callback)
        return try await completeAuthentication(
            platform: platform,
            code: code,
            verifier: verifier,
            existing: existing,
            redirectURI: redirect
        )
    }

    private func openBrowser(_ url: URL) throws {
        #if os(macOS)
        if !NSWorkspace.shared.open(url) {
            throw StreamOAuthError.invalidCallback
        }
        #else
        throw StreamOAuthError.unsupportedPlatform
        #endif
    }

    func completeAuthentication(
        platform: StreamPlatform,
        code: String,
        verifier: String,
        existing: StreamAccount? = nil,
        redirectURI: URL = StreamOAuthConfiguration.callbackURL
    ) async throws -> StreamAccount {
        let tokens = try await exchangeCode(
            code,
            verifier: verifier,
            platform: platform,
            redirectURI: redirectURI
        )
        var account = existing ?? StreamAccount(accountName: platform.title, platform: platform)
        if let identity = try? await loadIdentity(platform: platform, token: tokens.accessToken) {
            account.apply(identity)
        }
        account.isAuthenticated = true
        account.lastAuthenticated = Date()
        account.tokenExpiresAt = tokens.expiresAt
        persist(tokens: tokens, for: account)
        return account
    }

    private func loadIdentity(platform: StreamPlatform, token: String) async throws -> StreamIdentity? {
        if let identityLoader {
            return try await identityLoader(platform, token)
        }
        return try await StreamIdentityService.fetch(
            platform: platform,
            token: token,
            transport: profileTransport ?? URLSessionLiveTransport()
        )
    }

    func persist(tokens: OAuthTokenBox, for account: StreamAccount) {
        _ = KeychainStreamVault.save(identifier: account.oauthAccessIdentifier, secret: tokens.accessToken)
        if let refresh = tokens.refreshToken, !refresh.isEmpty {
            _ = KeychainStreamVault.save(identifier: account.oauthRefreshIdentifier, secret: refresh)
        }
        if let expires = tokens.expiresAt {
            _ = KeychainStreamVault.save(
                identifier: account.oauthExpiresIdentifier,
                secret: ISO8601DateFormatter().string(from: expires)
            )
        }
    }

    func accessToken(for account: StreamAccount) -> String? {
        KeychainStreamVault.load(identifier: account.oauthAccessIdentifier)
    }

    func storedExpiresAt(for account: StreamAccount) -> Date? {
        if let stored = account.tokenExpiresAt { return stored }
        guard let raw = KeychainStreamVault.load(identifier: account.oauthExpiresIdentifier) else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    func shouldRefreshAccessToken(for account: StreamAccount, now: Date = Date()) -> Bool {
        guard accessToken(for: account) != nil else { return true }
        if let expires = storedExpiresAt(for: account) {
            return expires <= now.addingTimeInterval(90)
        }
        // YouTube access tokens last about an hour. LinkedIn and X keep access
        // for days and often omit a refresh token — do not treat "signed in
        // earlier today" as expired.
        if account.platform == .youtube {
            if let last = account.lastAuthenticated {
                return last.addingTimeInterval(50 * 60) <= now
            }
            return KeychainStreamVault.load(identifier: account.oauthRefreshIdentifier) != nil
        }
        return false
    }

    @discardableResult
    func ensureValidAccessToken(
        for account: StreamAccount,
        forceRefresh: Bool = false,
        now: Date = Date()
    ) async throws -> OAuthTokenBox {
        if !forceRefresh,
           let access = accessToken(for: account),
           !access.isEmpty,
           !shouldRefreshAccessToken(for: account, now: now) {
            return OAuthTokenBox(
                accessToken: access,
                refreshToken: KeychainStreamVault.load(identifier: account.oauthRefreshIdentifier),
                expiresAt: storedExpiresAt(for: account),
                tokenType: "Bearer"
            )
        }
        return try await refreshAccessToken(for: account)
    }

    func refreshAccessToken(for account: StreamAccount) async throws -> OAuthTokenBox {
        guard let refresh = KeychainStreamVault.load(identifier: account.oauthRefreshIdentifier),
              !refresh.isEmpty
        else {
            throw StreamOAuthError.expiredSession
        }
        guard let clientID = StreamOAuthConfiguration.clientID(for: account.platform) else {
            throw StreamOAuthError.missingClientID
        }
        let request = refreshRequest(
            refreshToken: refresh,
            clientID: clientID,
            platform: account.platform
        )
        let tokens = try await sendTokenRequest(request)
        var merged = tokens
        if merged.refreshToken == nil {
            merged.refreshToken = refresh
        }
        persist(tokens: merged, for: account)
        return merged
    }

    func deleteTokens(for account: StreamAccount) {
        _ = KeychainStreamVault.delete(identifier: account.oauthAccessIdentifier)
        _ = KeychainStreamVault.delete(identifier: account.oauthRefreshIdentifier)
        _ = KeychainStreamVault.delete(identifier: account.oauthExpiresIdentifier)
        _ = KeychainStreamVault.delete(identifier: account.keychainStreamKeyIdentifier)
    }

    private func exchangeCode(
        _ code: String,
        verifier: String,
        platform: StreamPlatform,
        redirectURI: URL = StreamOAuthConfiguration.callbackURL
    ) async throws -> OAuthTokenBox {
        guard let clientID = StreamOAuthConfiguration.clientID(for: platform) else {
            throw StreamOAuthError.missingClientID
        }
        if StreamOAuthConfiguration.requiresClientSecret(for: platform),
           !StreamOAuthConfiguration.hasClientSecret(for: platform) {
            throw StreamOAuthError.missingClientSecret
        }
        let request = tokenRequest(
            code: code,
            verifier: verifier,
            clientID: clientID,
            platform: platform,
            redirectURI: redirectURI
        )
        return try await sendTokenRequest(request)
    }

    private func sendTokenRequest(_ request: URLRequest) async throws -> OAuthTokenBox {
        let data: Data
        if let codeExchange {
            data = try await codeExchange(request)
        } else {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw tokenExchangeError(from: body)
            }
            data = body
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty
        else {
            throw tokenExchangeError(from: data)
        }
        let expires = (object["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        return OAuthTokenBox(
            accessToken: access,
            refreshToken: object["refresh_token"] as? String,
            expiresAt: expires,
            tokenType: (object["token_type"] as? String) ?? "Bearer"
        )
    }

    func tokenRequest(
        code: String,
        verifier: String,
        clientID: String,
        platform: StreamPlatform,
        redirectURI: URL = StreamOAuthConfiguration.callbackURL
    ) -> URLRequest {
        let endpoint = tokenEndpoint(for: platform)
        var body: [String: String] = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI.absoluteString,
            "grant_type": "authorization_code",
        ]
        if StreamOAuthConfiguration.usesPKCE(for: platform) {
            body["code_verifier"] = verifier
        }
        if platform != .twitter, let secret = StreamOAuthConfiguration.clientSecret(for: platform), !secret.isEmpty {
            body["client_secret"] = secret
        }
        return tokenFormRequest(endpoint: endpoint, body: body, clientID: clientID, platform: platform)
    }

    func refreshRequest(
        refreshToken: String,
        clientID: String,
        platform: StreamPlatform
    ) -> URLRequest {
        let endpoint = tokenEndpoint(for: platform)
        var body: [String: String] = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "grant_type": "refresh_token",
        ]
        if platform != .twitter, let secret = StreamOAuthConfiguration.clientSecret(for: platform), !secret.isEmpty {
            body["client_secret"] = secret
        }
        return tokenFormRequest(endpoint: endpoint, body: body, clientID: clientID, platform: platform)
    }

    private func tokenFormRequest(
        endpoint: URL,
        body: [String: String],
        clientID: String,
        platform: StreamPlatform
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if platform == .twitter,
           let secret = StreamOAuthConfiguration.clientSecret(for: platform),
           !secret.isEmpty {
            let raw = "\(clientID):\(secret)"
            request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = FormURLEncoder.encode(body)
        return request
    }

    private func tokenEndpoint(for platform: StreamPlatform) -> URL {
        switch platform {
        case .youtube:
            URL(string: "https://oauth2.googleapis.com/token")!
        case .facebook:
            URL(string: "https://graph.facebook.com/v19.0/oauth/access_token")!
        case .twitter:
            URL(string: "https://api.twitter.com/2/oauth2/token")!
        case .linkedin:
            URL(string: "https://www.linkedin.com/oauth/v2/accessToken")!
        case .customRtmp, .srt:
            URL(string: "https://127.0.0.1/token")!
        }
    }

    private func tokenExchangeError(from data: Data) -> StreamOAuthError {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .tokenExchangeFailed
        }
        let code = (object["error"] as? String) ?? ""
        if code == "invalid_grant" || code == "invalid_token" {
            return .expiredSession
        }
        let description = (object["error_description"] as? String)
            ?? (code.isEmpty ? nil : code)
            ?? (object["message"] as? String)
        if let description, !description.isEmpty {
            return .providerRejected(description)
        }
        return .tokenExchangeFailed
    }

    private func openSession(url: URL) async throws -> URL {
        #if canImport(AuthenticationServices)
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: StreamOAuthConfiguration.callbackScheme
            ) { callback, error in
                if let error {
                    continuation.resume(throwing: (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                        ? StreamOAuthError.cancelled
                        : error)
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: StreamOAuthError.invalidCallback)
                    return
                }
                continuation.resume(returning: callback)
            }
            #if os(macOS)
            session.presentationContextProvider = StreamOAuthPresenter.shared
            #endif
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: StreamOAuthError.cancelled)
            }
        }
        #else
        throw StreamOAuthError.unsupportedPlatform
        #endif
    }
}

enum StreamPKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func codeChallenge(for verifier: String) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #else
        return verifier
        #endif
    }

    static func authorizationCode(from callback: URL) throws -> String {
        if let rejected = providerError(from: callback) {
            throw StreamOAuthError.providerRejected(rejected)
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw StreamOAuthError.invalidCallback
        }
        return code
    }

    static func providerError(from callback: URL) -> String? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty else {
            return nil
        }
        if let description = items.first(where: { $0.name == "error_description" })?.value,
           !description.isEmpty {
            return description.replacingOccurrences(of: "+", with: " ")
        }
        return error
    }

    static func validate(state: String, in callback: URL) throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let received = items.first(where: { $0.name == "state" })?.value else { return }
        if received != state {
            throw StreamOAuthError.invalidCallback
        }
    }
}

enum FormURLEncoder {
    static func encode(_ fields: [String: String]) -> Data {
        fields
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

#if canImport(AuthenticationServices) && os(macOS)
final class StreamOAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = StreamOAuthPresenter()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
#endif
