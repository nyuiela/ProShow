import Foundation
import Testing
#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif

struct ChatTemplatePropTests {
    @Test func unmarkedProp_savesWithoutTheKey() throws {
        let prop = ProShowProp(name: "Lower third")
        let json = String(decoding: try JSONEncoder().encode(prop), as: UTF8.self)
        #expect(!json.contains("isChatTemplate"))
        let back = try JSONDecoder().decode(ProShowProp.self, from: Data(json.utf8))
        #expect(back.isChatTemplate == false)
    }

    @Test func markedProp_roundTrips() throws {
        var prop = ProShowProp(name: "Chat card")
        prop.isChatTemplate = true
        let back = try JSONDecoder().decode(ProShowProp.self, from: JSONEncoder().encode(prop))
        #expect(back.isChatTemplate)
    }

    @Test @MainActor func marking_isExclusiveAndDuplicateIsUnmarked() throws {
        let engine = ActionInspectorEngine()
        let a = engine.addProp(name: "A")
        let b = engine.addProp(name: "B")
        engine.setPropChatTemplate(id: a.id, on: true)
        engine.setPropChatTemplate(id: b.id, on: true)
        #expect(engine.props.filter(\.isChatTemplate).map(\.id) == [b.id])
        let copy = try #require(engine.duplicateProp(id: b.id))
        #expect(copy.isChatTemplate == false)
        engine.setPropChatTemplate(id: b.id, on: false)
        #expect(engine.props.allSatisfy { !$0.isChatTemplate })
    }
}

struct ChatAvatarBindingTests {
    @Test func unboundLayer_savesWithoutTheKey() throws {
        let object = CanvasObject(name: "Mark", kind: .image, bounds: CanvasBounds(x: 0, y: 0, width: 10, height: 10))
        let json = String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
        #expect(!json.contains("imageBinding"))
    }

    @Test func boundLayer_roundTrips() throws {
        var object = CanvasObject(name: "Mark", kind: .image, bounds: CanvasBounds(x: 0, y: 0, width: 10, height: 10))
        object.imageBinding = "chat.avatar"
        let back = try JSONDecoder().decode(CanvasObject.self, from: JSONEncoder().encode(object))
        #expect(back.imageBinding == "chat.avatar")
    }

    @Test func preferredURL_httpsOnlyAndLargerSizes() {
        #expect(ChatAvatarFileCache.preferredURL("https://pbs.twimg.com/a/b_normal.jpg")?.absoluteString == "https://pbs.twimg.com/a/b_400x400.jpg")
        #expect(ChatAvatarFileCache.preferredURL("https://yt3.ggpht.com/x=s64-c-k")?.absoluteString == "https://yt3.ggpht.com/x=s240-c-k")
        #expect(ChatAvatarFileCache.preferredURL("http://example.com/a.png") == nil)
        #expect(ChatAvatarFileCache.preferredURL("file:///tmp/a.png") == nil)
    }

    @Test func youTubeWebhook_carriesProfileImage() throws {
        let body = #"{"snippet":{"displayMessage":"hi","authorDetails":{"displayName":"Esi","profileImageUrl":"https://yt3.ggpht.com/e=s64"}}}"#
        let message = try #require(LiveChatIngestService.parseWebhook(platform: "youtube", body: Data(body.utf8)))
        #expect(message.senderAvatarUrl == "https://yt3.ggpht.com/e=s64")
    }
}
