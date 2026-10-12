#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct LiveKitDeskTests {
    @Test
    func token_includesDeskRoleWithoutRoomAdmin() {
        let token = LiveKitAccessToken.jwt(
            apiKey: "devkey",
            apiSecret: "secret",
            identity: "proshow-desk",
            name: "ProShow Desk",
            room: "sunday",
            attributes: ["ps.role": "desk"]
        )
        let payload = LiveKitAccessToken.payloadJSON(token)
        let video = payload?["video"] as? [String: Any]
        #expect(video?["room"] as? String == "sunday")
        #expect(video?["roomJoin"] as? Bool == true)
        #expect(video?["canSubscribe"] as? Bool == true)
        #expect(video?["roomAdmin"] == nil)
        let attributes = payload?["attributes"] as? [String: String]
        #expect(attributes?["ps.role"] == "desk")
    }

    @Test
    func endpoint_roundTripsIdentity() {
        let endpoint = LiveKitGuestEndpoint.camera(room: "sunday", identity: "guest-ama")
        #expect(LiveKitGuestEndpoint.identity(from: endpoint) == "guest-ama")
        let items = LiveKitGuestCatalog.items(
            room: "sunday",
            guests: [LiveKitGuestFeed(identity: "guest-ama", name: "Ama", hasCamera: true, hasScreen: true, hasMic: true)]
        )
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.category == .network && $0.groupName == "Live Guests" })
    }

    @Test
    func config_readsAppSupportSettings() throws {
        let data = Data(#"{"url":"wss://example.livekit.cloud","tokenEndpoint":"https://example.livekit.cloud/token"}"#.utf8)
        let settings = LiveKitDeskConfig.settings(from: data)
        #expect(settings?.url == "wss://example.livekit.cloud")
        #expect(settings?.tokenEndpoint == "https://example.livekit.cloud/token")
        let credentials = LiveKitDeskCredentials(
            url: settings?.url ?? "",
            apiKey: "key",
            apiSecret: "secret",
            tokenEndpoint: settings?.tokenEndpoint ?? ""
        )
        #expect(credentials.httpOrigin == "https://example.livekit.cloud")
    }
}
