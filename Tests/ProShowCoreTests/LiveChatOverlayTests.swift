#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct LiveChatOverlayTests {
    @Test @MainActor
    func ingest_pushesLowerThirdCard() {
        let chat = LiveChatEngine()
        chat.connect(.twitch)
        let message = ChatMessage(platform: .twitch, author: "Ada", text: "Great stream", avatarName: "ada")
        let card = chat.pushOverlay(message)
        #expect(chat.connectedPlatforms.isEmpty)
        #expect(!LiveChatEngine.platformClientAvailable)
        #expect(card.visible)
        #expect(card.message.author == "Ada")
        #expect(chat.widgets.enabled(.liveChat))
        #expect(chat.widgets.enabled(.streamAlert))
    }

    @Test @MainActor
    func controlAPI_chatOverlayRendersOnStack() {
        let controller = TestSupport.sampleController()
        let body = #"{"author":"Sam","text":"Hello from chat","platform":"youtube"}"#.data(using: .utf8)
        let result = controller.handleControl(method: "POST", path: "/v1/chat/overlay", body: body)
        #expect(result.0 == 200)
        #expect(controller.chat.overlay?.message.author == "Sam")
        #expect(controller.compositor.stack.chatOverlay?.message.text == "Hello from chat")
        #expect(controller.compositor.stack.chatOverlay?.message.platform == .youtube)
    }
}
