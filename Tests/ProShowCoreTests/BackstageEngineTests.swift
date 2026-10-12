#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct BackstageEngineTests {
    @Test @MainActor
    func backstage_generatesInviteURL() {
        let engine = ProShowBackstageEngine(room: BackstageRoomConfig(roomSlug: "pso-9482"))
        #expect(engine.inviteURLString.contains("pso-9482"))
        #expect(engine.inviteURLString.contains("/j/pso-9482"))
    }

    @Test @MainActor
    func backstage_admitsGuestAndRoutesSources() {
        let engine = ProShowBackstageEngine()
        let guest = engine.admitGuest(displayName: "Dr. Jane Doe", roleOrTitle: "Keynote")
        #expect(guest != nil)
        engine.setGuestOnAir(id: guest!.id, onAir: true)
        engine.attachScreenShare(guestID: guest!.id, label: "deck.pdf")
        let sources = engine.videoSourcesForGraph()
        #expect(sources.count == 2)
        #expect(sources.contains(where: { $0.kind == .screenShare }))
    }

    @Test @MainActor
    func chatStream_featuresOverlayOnCompositor() async {
        let controller = TestSupport.sampleController()
        controller.bootstrapBackstageServices()
        let message = LiveChatMessage(
            senderName: "Sarah Connor",
            platformSource: "Zoom",
            messageText: "Will slides be shared?"
        )
        controller.chatStream?.ingest(message)
        controller.triggerChatOverlay(message)
        #expect(controller.compositor.stack.chatOverlay?.visible == true)
        #expect(controller.compositor.stack.chatOverlay?.message.author == "Sarah Connor")
    }

    @Test
    func virtualCameraFormat_matchesProjectResolution() {
        #expect(VirtualCameraFormat.hd1080p60.width == 1920)
        #expect(VirtualCameraFormat.hd720p60.fps == 60)
    }

    @Test @MainActor
    func virtualAudioLoopback_staysOffWithoutDriver() {
        let controller = TestSupport.sampleController()
        controller.deviceSettings.document.virtualCameraEnabled = true
        controller.syncVirtualAudioLoopbackPublishing()
        #expect(controller.virtualAudioLoopback.driverInstalled == false)
        #expect(controller.virtualAudioLoopback.isPublishing == false)
    }
}
