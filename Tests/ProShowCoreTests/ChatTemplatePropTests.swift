import Foundation
import Testing
#if canImport(ProShowCore)
@testable import ProShowCore
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
