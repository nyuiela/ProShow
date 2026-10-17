import Foundation
import Testing
#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif

struct AIAgentTests {
    @Test func toolRegistryGatesLiveTools() {
        for name in ["take", "hold", "arm_destinations", "import_slides"] {
            #expect(AgentToolRegistry.definition(name)?.operatorGated == true)
        }
        #expect(AgentToolRegistry.definition("compose_patch_apply_preview")?.operatorGated == false)
    }

    @Test func contextPackVersionTracksSettings() {
        let a = AgentContextPack.build(context: ["x": 1], settingsKey: "stream|phone")
        let b = AgentContextPack.build(context: ["x": 2], settingsKey: "stream|phone")
        let c = AgentContextPack.build(context: ["x": 1], settingsKey: "stream|phone-on")
        #expect(a.version == b.version)
        #expect(a.version != c.version)
        #expect(a.systemPrompt().contains("# Context pack"))
    }

    @Test func deskUpdateIsWrapped() {
        #expect(AgentContextPack.deskUpdateBlock("Guest is late").contains("[Desk update]"))
    }

    @Test func eventJSONHasSeqAndType() {
        let e = AgentEvent(seq: 3, ts: .now, kind: .toolCall(name: "list_tools", callID: "c1"))
        #expect(e.json["seq"] as? Int == 3)
        #expect(e.json["type"] as? String == "tool_call")
    }
}
