import Foundation

enum StreamPrivacyLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case publicAccess = "Public"
    case unlisted = "Unlisted"
    case privateAccess = "Private"

    var id: String { rawValue }

    var youtubePrivacy: String {
        switch self {
        case .publicAccess: "public"
        case .unlisted: "unlisted"
        case .privateAccess: "private"
        }
    }
}

struct BroadcastMetadata: Hashable, Codable, Sendable {
    var title: String
    var description: String
    var category: String
    var privacy: StreamPrivacyLevel
    var scheduledStartTime: Date?
    var thumbnailFileName: String
    /// Session still. Not written to JSON.
    var thumbnailJPEG: Data?

    static let categories = [
        "Nonprofits & Activism",
        "General / Ministry",
        "Music",
        "Education",
        "News & Politics",
        "Entertainment",
        "Science & Technology",
    ]

    static let `default` = BroadcastMetadata(
        title: "",
        description: "",
        category: "Nonprofits & Activism",
        privacy: .publicAccess,
        scheduledStartTime: nil
    )

    init(
        title: String = "",
        description: String = "",
        category: String = "Nonprofits & Activism",
        privacy: StreamPrivacyLevel = .publicAccess,
        scheduledStartTime: Date? = nil,
        thumbnailFileName: String = "",
        thumbnailJPEG: Data? = nil
    ) {
        self.title = title
        self.description = description
        self.category = category
        self.privacy = privacy
        self.scheduledStartTime = scheduledStartTime
        self.thumbnailFileName = thumbnailFileName
        self.thumbnailJPEG = thumbnailJPEG
    }

    private enum CodingKeys: String, CodingKey {
        case title, description, category, privacy, scheduledStartTime, thumbnailFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "Nonprofits & Activism"
        privacy = try container.decodeIfPresent(StreamPrivacyLevel.self, forKey: .privacy) ?? .publicAccess
        scheduledStartTime = try container.decodeIfPresent(Date.self, forKey: .scheduledStartTime)
        thumbnailFileName = try container.decodeIfPresent(String.self, forKey: .thumbnailFileName) ?? ""
        thumbnailJPEG = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(category, forKey: .category)
        try container.encode(privacy, forKey: .privacy)
        try container.encodeIfPresent(scheduledStartTime, forKey: .scheduledStartTime)
        try container.encode(thumbnailFileName, forKey: .thumbnailFileName)
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func validate() -> String? {
        if trimmedTitle.isEmpty { return "Enter a broadcast title." }
        return nil
    }

    /// When false, RTMP still goes out but platforms should not create public posts or listings.
    var publishesSocialListing: Bool {
        privacy != .privateAccess
    }

    /// Poster image the operator picked in Broadcast Setup — not an auto-captured program frame.
    var userChosenThumbnailJPEG: Data? {
        let name = thumbnailFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let jpeg = thumbnailJPEG, !jpeg.isEmpty else { return nil }
        return jpeg
    }
}

struct OAuthTokenBox: Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenType: String
}

struct ResolvedIngest: Hashable, Sendable {
    var accountID: UUID
    var name: String
    var platform: StreamPlatform
    var url: URL
    var streamKey: String
    var broadcastID: String = ""
    var streamID: String = ""

    var publicURLString: String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.query = nil
        parts?.fragment = nil
        return parts?.string ?? url.host ?? url.absoluteString
    }
}

enum StreamOAuthConfiguration {
    static let callbackScheme = "proshow"
    static let callbackURL = URL(string: "proshow://oauth")!
    static let loopbackPort: UInt16 = 55077
    static let n8nRedirectURI = "http://localhost:5678/rest/oauth2-credential/callback"
    static let proshowRedirectURI = "http://localhost:55077/"
    static let proshowLinkedInRedirectURI = "http://localhost:55078/"
    static let proshowXRedirectURI = "http://127.0.0.1:55079/"
    static let proshowFacebookRedirectURI = "http://localhost:55080/"
    /// Read/write + media. `broadcast.*` is approval-gated and breaks consent if requested.
    static let xUserScopes = "tweet.read tweet.write users.read offline.access media.write"
    static var secretOverrides: [StreamPlatform: String] = [:]
    static var clientsFileURL: URL = defaultClientsFileURL

    static func loopbackCallback(port: UInt16 = loopbackPort) -> URL {
        URL(string: "http://localhost:\(port)/")!
    }

    static func usesLoopbackRedirect(for platform: StreamPlatform) -> Bool {
        switch platform {
        case .youtube, .facebook, .twitter, .linkedin: true
        case .customRtmp, .srt: false
        }
    }

    /// LinkedIn's standard `/oauth/v2/authorization` rejects PKCE. Use client secret instead.
    static func usesPKCE(for platform: StreamPlatform) -> Bool {
        switch platform {
        case .youtube, .twitter: true
        case .facebook, .linkedin, .customRtmp, .srt: false
        }
    }

    static func requiresClientSecret(for platform: StreamPlatform) -> Bool {
        switch platform {
        case .youtube, .linkedin, .facebook: true
        case .twitter, .customRtmp, .srt: false
        }
    }

    static func hasClientSecret(for platform: StreamPlatform) -> Bool {
        guard let secret = clientSecret(for: platform) else { return false }
        return !secret.isEmpty
    }

    static func saveClientSecret(_ secret: String, for platform: StreamPlatform) {
        guard let key = clientSecretKey(for: platform) else { return }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        writeClientValue(trimmed.isEmpty ? nil : trimmed, forKey: key)
        _ = KeychainStreamVault.delete(identifier: clientSecretKeychainIdentifier(for: platform))
    }

    static func resolvedLoopbackRedirect(preferred: String?, platform: StreamPlatform = .youtube) -> URL {
        if let parsed = parseLoopbackRedirect(preferred), !shouldReplaceSharedN8nRedirect(parsed, platform: platform) {
            return parsed
        }
        switch platform {
        case .twitter:
            return parseLoopbackRedirect(proshowXRedirectURI) ?? loopbackCallback(port: 55079)
        case .linkedin:
            return parseLoopbackRedirect(proshowLinkedInRedirectURI) ?? loopbackCallback(port: 55078)
        case .facebook:
            return parseLoopbackRedirect(proshowFacebookRedirectURI) ?? loopbackCallback(port: 55080)
        case .youtube, .customRtmp, .srt:
            return parseLoopbackRedirect(preferred) ?? parseLoopbackRedirect(n8nRedirectURI) ?? loopbackCallback()
        }
    }

    static func shouldReplaceSharedN8nRedirect(_ url: URL, platform: StreamPlatform) -> Bool {
        switch platform {
        case .twitter, .linkedin, .facebook:
            return url.port == 5678
        case .youtube, .customRtmp, .srt:
            return false
        }
    }

    static func parseLoopbackRedirect(_ raw: String?) -> URL? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              url.scheme?.lowercased() == "http",
              host == "localhost" || host == "127.0.0.1",
              loopbackPort(in: url) != nil
        else { return nil }
        return url
    }

    static func loopbackPort(in url: URL) -> UInt16? {
        if let port = url.port, port > 0, port <= Int(UInt16.max) {
            return UInt16(port)
        }
        return 80
    }

    static func clientID(for platform: StreamPlatform) -> String? {
        credential(named: clientIDKey(for: platform), platform: platform, kind: "id")
    }

    static func clientSecret(for platform: StreamPlatform) -> String? {
        credential(named: clientSecretKey(for: platform), platform: platform, kind: "secret")
    }

    static func clientSecretKeychainIdentifier(for platform: StreamPlatform) -> String {
        "oauth.client.\(platform.rawValue).secret"
    }

    private static func clientIDKey(for platform: StreamPlatform) -> String? {
        switch platform {
        case .youtube: "PROSHOW_YOUTUBE_CLIENT_ID"
        case .facebook: "PROSHOW_FACEBOOK_APP_ID"
        case .twitter: "PROSHOW_X_CLIENT_ID"
        case .linkedin: "PROSHOW_LINKEDIN_CLIENT_ID"
        case .customRtmp, .srt: nil
        }
    }

    private static func clientSecretKey(for platform: StreamPlatform) -> String? {
        switch platform {
        case .youtube: "PROSHOW_YOUTUBE_CLIENT_SECRET"
        case .facebook: "PROSHOW_FACEBOOK_APP_SECRET"
        case .twitter: "PROSHOW_X_CLIENT_SECRET"
        case .linkedin: "PROSHOW_LINKEDIN_CLIENT_SECRET"
        case .customRtmp, .srt: nil
        }
    }

    private static func credential(named key: String?, platform: StreamPlatform, kind: String) -> String? {
        if kind == "secret", let override = secretOverrides[platform] {
            return override.isEmpty ? nil : override
        }
        guard let key else { return nil }
        let env = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        if let local = plistValue(key, in: bundledLocalOAuthURL) { return local }
        if let stored = plistValue(key, in: clientsFileURL) { return stored }
        let bundle = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = bundle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        if kind == "secret" {
            return migrateVaultSecret(for: platform, key: key)
        }
        return nil
    }

    private static func migrateVaultSecret(for platform: StreamPlatform, key: String) -> String? {
        let identifier = clientSecretKeychainIdentifier(for: platform)
        guard let secret = KeychainStreamVault.load(identifier: identifier), !secret.isEmpty else {
            return nil
        }
        writeClientValue(secret, forKey: key)
        _ = KeychainStreamVault.delete(identifier: identifier)
        return secret
    }

    private static func writeClientValue(_ value: String?, forKey key: String) {
        var items = plistDictionary(at: clientsFileURL)
        if let value, !value.isEmpty {
            items[key] = value
        } else {
            items.removeValue(forKey: key)
        }
        persistClientPlist(items)
    }

    private static func plistValue(_ key: String, in url: URL?) -> String? {
        guard let url, let raw = plistDictionary(at: url)[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func plistDictionary(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [:] }
        if let typed = object as? [String: String] { return typed }
        guard let any = object as? [String: Any] else { return [:] }
        var items: [String: String] = [:]
        for (key, value) in any {
            if let text = value as? String {
                items[key] = text
            }
        }
        return items
    }

    private static func persistClientPlist(_ items: [String: String]) {
        do {
            try FileManager.default.createDirectory(at: clientsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if items.isEmpty {
                try? FileManager.default.removeItem(at: clientsFileURL)
                return
            }
            let data = try PropertyListSerialization.data(fromPropertyList: items, format: .xml, options: 0)
            try data.write(to: clientsFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clientsFileURL.path)
        } catch {
            return
        }
    }

    private static var bundledLocalOAuthURL: URL? {
        Bundle.main.url(forResource: "LocalOAuth", withExtension: "plist")
    }

    static var defaultClientsFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return root.appendingPathComponent("ProShow", isDirectory: true)
            .appendingPathComponent("oauth-clients.plist")
    }
}
