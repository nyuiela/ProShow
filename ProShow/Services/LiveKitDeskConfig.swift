import Foundation

struct LiveKitDeskCredentials: Equatable, Sendable {
    var url: String
    var apiKey: String
    var apiSecret: String
    var tokenEndpoint: String

    var httpOrigin: String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("wss://") {
            value = "https://" + value.dropFirst("wss://".count)
        } else if value.hasPrefix("ws://") {
            value = "http://" + value.dropFirst("ws://".count)
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

struct LiveKitDeskSettings: Equatable, Sendable, Decodable {
    var url: String
    var tokenEndpoint: String

    enum CodingKeys: String, CodingKey {
        case url
        case tokenEndpoint
    }

    init(url: String, tokenEndpoint: String) {
        self.url = url
        self.tokenEndpoint = tokenEndpoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        tokenEndpoint = try container.decodeIfPresent(String.self, forKey: .tokenEndpoint) ?? ""
    }
}

enum LiveKitDeskConfig {
    static let apiKeyIdentifier = "livekit.apiKey"
    static let apiSecretIdentifier = "livekit.apiSecret"
    static let guestsOffStatus = "Guests off"

    /// Non-secret LiveKit URL and token endpoint. Secrets stay in the keychain.
    static func supportFileURL() -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return folder
            .appendingPathComponent("ProShow", isDirectory: true)
            .appendingPathComponent("livekit.json")
    }

    /// Called when a guest action starts. Not at launch.
    static func load() -> LiveKitDeskCredentials? {
        #if DEBUG
        if let env = fromProcessEnvironment() { return env }
        #endif
        return fromApplicationSupport()
    }

    static func settings(from data: Data) -> LiveKitDeskSettings? {
        guard let decoded = try? JSONDecoder().decode(LiveKitDeskSettings.self, from: data) else { return nil }
        let url = decoded.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let endpoint = decoded.tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveKitDeskSettings(url: url, tokenEndpoint: endpoint)
    }

    #if DEBUG
    static func fromProcessEnvironment() -> LiveKitDeskCredentials? {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["LIVEKIT_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
              let key = env["LIVEKIT_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let secret = env["LIVEKIT_API_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty
        else { return nil }
        let endpoint = env["LIVEKIT_TOKEN_ENDPOINT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LiveKitDeskCredentials(url: url, apiKey: key, apiSecret: secret, tokenEndpoint: endpoint)
    }
    #endif

    private static func fromApplicationSupport() -> LiveKitDeskCredentials? {
        let url = supportFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let settings = settings(from: data),
              let key = KeychainStreamVault.load(identifier: apiKeyIdentifier)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              let secret = KeychainStreamVault.load(identifier: apiSecretIdentifier)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty
        else { return nil }
        return LiveKitDeskCredentials(
            url: settings.url,
            apiKey: key,
            apiSecret: secret,
            tokenEndpoint: settings.tokenEndpoint
        )
    }
}
