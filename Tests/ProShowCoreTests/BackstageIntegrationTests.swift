#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct BackstageIntegrationTests {
    @Test @MainActor
    func mixMinus_excludesLinkedGuestChannel() {
        let matrix = AudioMatrixEngine()
        let hostMic = AudioMatrixChannel(id: UUID(), name: "Host", role: .microphone, gainDb: 0, peak: -6)
        var guest = AudioMatrixChannel(id: UUID(), name: "Guest A", role: .guest, gainDb: 0, peak: -6)
        guest.linkedGuestID = UUID()
        let slide = AudioMatrixChannel(id: UUID(), name: "Program", role: .slide, gainDb: 6, peak: -3)
        matrix.install([hostMic, guest, slide])
        let withoutGuest = matrix.monitorMixLinear(excludingChannelIDs: [guest.id])
        let withGuest = matrix.monitorMixLinear()
        #expect(withoutGuest <= withGuest)
        let guestID = UUID()
        let channelID = matrix.ensureGuestChannel(guestID: guestID, displayName: "Remote")
        #expect(matrix.channel(id: channelID)?.linkedGuestID == guestID)
    }

    @Test
    func virtualCameraHeader_roundTrip() {
        let header = VirtualCameraFrameQueue.Header(width: 1280, height: 720, presentationTime: 12.5, byteCount: 1280 * 720 * 4)
        let encoded = VirtualCameraFrameQueue.encodeHeader(header)
        let decoded = VirtualCameraFrameQueue.decodeHeader(encoded)
        #expect(decoded?.width == 1280)
        #expect(decoded?.height == 720)
        #expect(decoded?.byteCount == header.byteCount)
    }

    @Test @MainActor
    func chatIngest_zoomWebhook() {
        let chat = LiveChatEngine()
        let body = Data(#"{"payload":{"sender_name":"Alex","message":"Hello"}}"#.utf8)
        let message = chat.ingestWebhook(platform: "zoom", body: body)
        #expect(message?.senderName == "Alex")
        #expect(chat.inbox.first?.text == "Hello")
    }

    @Test @MainActor
    func signaling_joinRegistersGuest() {
        let controller = TestSupport.sampleController()
        controller.bootstrapBackstageServices()
        let guestID = UUID().uuidString
        let payload = BackstageSignalMessage(
            kind: .join,
            roomSlug: controller.backstage.room.roomSlug,
            guestID: guestID,
            displayName: "Remote Host"
        )
        let response = controller.backstageSignaling.handle(payload)
        #expect(response.contains("\"ok\":true"))
        #expect(controller.backstage.guests.contains(where: { $0.profile.displayName == "Remote Host" }))
    }

    @Test
    func webrtc_activateWhenSignaledEndpoint() {
        let source = VideoInputSource(
            id: UUID(),
            label: "Guest",
            kind: .webrtc,
            endpoint: "webrtc://guest/\(UUID().uuidString.lowercased())"
        )
        if case .started = VideoInputRuntime.activate(source) {
            #expect(true)
        } else {
            Issue.record("Signaled WebRTC endpoint should start")
        }
    }
}
