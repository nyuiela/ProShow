import Foundation
import Testing
#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif

@Suite(.serialized)
struct AIComposeTests {
    static func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/compose-patch-demo-day-2026-10-17.json")
        return try Data(contentsOf: url)
    }

    static func body(_ extra: [String: Any]) throws -> Data {
        let patch = try JSONSerialization.jsonObject(with: fixture())
        var object = extra
        object["patch"] = patch
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func fixtureDecodesAndValidates() throws {
        let patch = try ComposeCodec.decodePatch(Self.fixture())
        #expect(patch.slides.count == 8)
        try ComposeDesignValidator.validate(patch)
    }

    @Test func strictDecodeRejectsUnknownKeys() throws {
        var object = try JSONSerialization.jsonObject(with: Self.fixture()) as! [String: Any]
        object["surprise"] = 1
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ComposeError.unknownKeys(["surprise"])) { try ComposeCodec.decodePatch(data) }
    }

    @Test func validatorRejectsOffTokenAndMissingStream() throws {
        var patch = try ComposeCodec.decodePatch(Self.fixture())
        patch.slides[0].backgroundHex = "#FF00FF"
        #expect(throws: ComposeError.offTokenColor("#FF00FF")) { try ComposeDesignValidator.validate(patch) }
        patch = try ComposeCodec.decodePatch(Self.fixture())
        patch.designMeta.canvases = ["phone"]
        #expect(throws: ComposeError.missingStreamCanvas) { try ComposeDesignValidator.validate(patch) }
        patch = try ComposeCodec.decodePatch(Self.fixture())
        patch.designMeta.canvases = ["stream"]
        patch.designMeta.streamOnly = nil
        #expect(throws: ComposeError.missingPhoneCanvas) { try ComposeDesignValidator.validate(patch) }
        patch.designMeta.streamOnly = true
        try ComposeDesignValidator.validate(patch)
    }

    @Test @MainActor func routesReturn409WhenFlagOff() throws {
        let saved = ProShowFeatureFlags.aiComposeV1
        defer { ProShowFeatureFlags.aiComposeV1 = saved }
        ProShowFeatureFlags.aiComposeV1 = false
        let controller = TestSupport.sampleController()
        #expect(controller.handleControl(method: "GET", path: "/v1/ai/recipes").0 == 409)
        #expect(controller.handleControl(method: "POST", path: "/v1/ai/compose", body: try Self.body(["provider": "practice"])).0 == 409)
        #expect(controller.handleControl(method: "POST", path: "/v1/ai/apply", body: try Self.body(["confirm": true])).0 == 409)
    }

    @Test @MainActor func practiceComposeAndApplyCreatesSlides() throws {
        let saved = ProShowFeatureFlags.aiComposeV1
        defer { ProShowFeatureFlags.aiComposeV1 = saved }
        ProShowFeatureFlags.aiComposeV1 = true
        let controller = TestSupport.sampleController()
        #expect(controller.handleControl(method: "GET", path: "/v1/ai/recipes").0 == 200)
        let before = controller.show.allSlides.count
        let compose = controller.handleControl(method: "POST", path: "/v1/ai/compose", body: try Self.body(["provider": "practice"]))
        #expect(compose.0 == 200)
        #expect(controller.show.allSlides.count == before)
        let refused = controller.handleControl(method: "POST", path: "/v1/ai/apply", body: try Self.body(["confirm": false]))
        #expect(refused.0 == 400)
        let applied = controller.handleControl(method: "POST", path: "/v1/ai/apply", body: try Self.body(["confirm": true]))
        #expect(applied.0 == 200)
        #expect(controller.show.allSlides.count == before + 8)
        #expect(controller.show.groups.contains { $0.name == "AI Draft" && $0.slides.count == 8 })
        #expect(!controller.streaming.isLive)
    }


    @Test func flexibleDecodeAcceptsFencedAndStringifiedPatch() throws {
        let fixture = String(decoding: try Self.fixture(), as: UTF8.self)
        let fenced = "```json\n\(fixture)\n```"
        let (a, notesA) = try ComposeCodec.decodePatchFlexible(fenced)
        #expect(a.slides.count == 8)
        #expect(notesA.contains { $0.contains("fence") || $0.contains("extracted") || $0.contains("string") })

        let stringified = fixture
        let (b, _) = try ComposeCodec.decodePatchFlexible(stringified)
        #expect(b.slides.count == 8)

        let wrapped = "{\"patch\": \(fixture)}"
        let (c, notesC) = try ComposeCodec.decodePatchFlexible(wrapped)
        #expect(c.slides.count == 8)
        #expect(notesC.contains { $0.contains("unwrapped") || $0.contains("extracted") })
    }

    @Test func flexibleDecodeStripsUnknownKeysAndNeverThrowsCrash() throws {
        var object = try JSONSerialization.jsonObject(with: Self.fixture()) as! [String: Any]
        object["surprise"] = 1
        let (patch, notes) = try ComposeCodec.decodePatchFlexible(object, stripUnknownKeys: true)
        #expect(patch.slides.count == 8)
        #expect(notes.contains { $0.contains("surprise") })
    }

    @Test func flexibleDecodeReportsPreviewOnGarbage() {
        #expect(throws: ComposeError.self) {
            _ = try ComposeCodec.decodePatchFlexible("not json at all {{{")
        }
    }

}
