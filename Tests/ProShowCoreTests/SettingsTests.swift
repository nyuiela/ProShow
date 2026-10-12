#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct SettingsTests {
    @Test
    func oauthClientSecret_staysOutOfKeychain() {
        let previous = StreamOAuthConfiguration.clientsFileURL
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-oauth-clients.plist")
        StreamOAuthConfiguration.secretOverrides.removeValue(forKey: .youtube)
        StreamOAuthConfiguration.clientsFileURL = url
        defer {
            StreamOAuthConfiguration.clientsFileURL = previous
            try? FileManager.default.removeItem(at: url)
            _ = KeychainStreamVault.delete(identifier: StreamOAuthConfiguration.clientSecretKeychainIdentifier(for: .youtube))
        }
        StreamOAuthConfiguration.saveClientSecret("yt-local-secret", for: .youtube)
        #expect(StreamOAuthConfiguration.hasClientSecret(for: .youtube))
        #expect(StreamOAuthConfiguration.clientSecret(for: .youtube) == "yt-local-secret")
        #expect(KeychainStreamVault.load(identifier: StreamOAuthConfiguration.clientSecretKeychainIdentifier(for: .youtube)) == nil)
        StreamOAuthConfiguration.saveClientSecret("", for: .youtube)
    }

    @Test
    func streamSecret_roundTripsThroughFileBox() {
        let identifier = "settings-test.\(UUID().uuidString)"
        defer { _ = KeychainStreamVault.delete(identifier: identifier) }
        #expect(KeychainStreamVault.save(identifier: identifier, secret: "rtmp-secret-xyz"))
        #expect(KeychainStreamVault.load(identifier: identifier) == "rtmp-secret-xyz")
        #expect(KeychainStreamVault.save(identifier: identifier, secret: "rtmp-secret-updated"))
        #expect(KeychainStreamVault.load(identifier: identifier) == "rtmp-secret-updated")
        #expect(KeychainStreamVault.delete(identifier: identifier))
        #expect(KeychainStreamVault.load(identifier: identifier) == nil)
    }

    @Test
    func projectMatrixEncodesAccountIdsWithoutSecrets() throws {
        let account = StreamAccount(accountName: "Church Main Channel", platform: .youtube)
        let matrix = ProjectStreamMatrix(projectId: UUID(), activeAccountIds: [account.id])
        let json = String(decoding: try ProjectJSON.encoder.encode(matrix), as: UTF8.self)
        #expect(json.contains(account.id.uuidString))
        #expect(!json.contains("rtmp-secret"))
        #expect(!json.contains("streamKey"))
        #expect(!json.contains(account.rtmpUrl) || account.rtmpUrl.isEmpty)
    }

    @Test
    func deviceDocumentKeepsKeychainReferenceOnly() throws {
        var document = DeviceSettingsDocument.default
        document.accounts = [
            StreamAccount(accountName: "Youth Ministry", platform: .facebook, isAuthenticated: true)
        ]
        let json = String(decoding: try ProjectJSON.encoder.encode(document), as: UTF8.self)
        #expect(json.contains("keychainStreamKeyIdentifier"))
        #expect(!json.contains("\"streamKey\""))
        #expect(!json.contains("oauth_token"))
    }

    @Test
    func projectDecodesMissingStreamMatrix() throws {
        let project = ProShowProject(name: "Live Program")
        var encoded = try ProjectJSON.encoder.encode(project)
        var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        object.removeValue(forKey: "streamMatrix")
        encoded = try JSONSerialization.data(withJSONObject: object)
        let decoded = try ProjectJSON.decoder.decode(ProShowProject.self, from: encoded)
        #expect(decoded.streamMatrix.activeAccountIds.isEmpty)
        #expect(decoded.streamMatrix.projectId == decoded.id)
    }

    @Test
    func deviceDocument_decodesLegacyWithoutOSC() throws {
        var object = try JSONSerialization.jsonObject(with: try ProjectJSON.encoder.encode(DeviceSettingsDocument.default)) as? [String: Any] ?? [:]
        object.removeValue(forKey: "oscEnabled")
        object.removeValue(forKey: "oscPort")
        object.removeValue(forKey: "midiEnabled")
        let decoded = try ProjectJSON.decoder.decode(
            DeviceSettingsDocument.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.oscEnabled)
        #expect(decoded.oscPort == 8000)
        #expect(decoded.midiEnabled)
        #expect(decoded.webSocketEnabled)
    }

    @Test
    func categorySearchFiltersStreaming() {
        #expect(SettingsCategory.streaming.matches("youtube"))
        #expect(SettingsCategory.streaming.matches("RTMP"))
        #expect(SettingsCategory.network.matches("midi"))
        #expect(SettingsCategory.network.matches("osc"))
        #expect(SettingsCategory.screens.matches("virtual camera"))
        #expect(!SettingsCategory.audio.matches("youtube"))
        #expect(SettingsCategory.general.matches(""))
    }

    @Test
    func navSectionsCoverEveryCategoryOnce() {
        let grouped = SettingsNavSection.allCases.flatMap(\.categories)
        #expect(grouped.count == SettingsCategory.allCases.count)
        #expect(Set(grouped) == Set(SettingsCategory.allCases))
    }

    @Test @MainActor
    func destinationMatrixUsesRelayForMultipleAccounts() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-device-settings.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(url: url)
        let youtube = StreamAccount(accountName: "Main Channel", platform: .youtube)
        let facebook = StreamAccount(accountName: "Page", platform: .facebook)
        store.upsert(youtube, secret: "yt-key")
        store.upsert(facebook, secret: "fb-key")
        defer {
            _ = KeychainStreamVault.delete(identifier: youtube.keychainStreamKeyIdentifier)
            _ = KeychainStreamVault.delete(identifier: facebook.keychainStreamKeyIdentifier)
        }

        let sample = SampleContent.sundayMorningService()
        let controller = ShowController(
            show: sample.show,
            playlist: sample.playlist,
            store: .temporary(),
            persistOnInit: false,
            deviceSettings: store
        )
        controller.setStreamDestination(youtube.id, enabled: true)
        #expect(controller.streaming.config.useCloudRelay == false)
        #expect(controller.streaming.config.destinationURL == youtube.rtmpUrl)
        #expect(controller.streaming.config.streamKey == "yt-key")

        controller.setStreamDestination(facebook.id, enabled: true)
        #expect(controller.streaming.config.useCloudRelay)
        #expect(controller.streaming.config.relayDestinations.count == 2)
        #expect(controller.streamMatrix.activeAccountIds.count == 2)
    }
}
