#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct TransitionEngineTests {
    @Test
    func testShaderProgressInterpolation() {
        let engine = TransitionShaderEngine()
        let from = TransitionImage.solid(RGBA8(r: 1, g: 0, b: 0, a: 1), width: 8, height: 8)
        let to = TransitionImage.solid(RGBA8(r: 0, g: 0, b: 1, a: 1), width: 8, height: 8)
        for effect in TransitionShaderEffect.allCases {
            let start = engine.composite(effect: effect, from: from, to: to, uniforms: .make(progress: 0, width: 8, height: 8))
            let end = engine.composite(effect: effect, from: from, to: to, uniforms: .make(progress: 1, width: 8, height: 8))
            #expect(start.pixels == from.pixels)
            #expect(end.pixels == to.pixels)
        }
    }

    @Test @MainActor
    func testStingerCutPointExecution() {
        let player = StingerPlayer()
        let outgoing = UUID()
        let incoming = UUID()
        var cue = AlphaStingerCue.flameWipe
        cue.cutPointMs = 500
        cue.totalDurationMs = 1000
        player.start(cue: cue, from: outgoing, to: incoming)
        #expect(player.activeLowerSceneID == outgoing)
        #expect(player.overlayLayerIndex == 6)
        #expect(player.overlayVisible)
        #expect(!player.hasReachedCutPoint)
        player.advance(toMs: 499)
        #expect(player.activeLowerSceneID == outgoing)
        player.advance(toMs: 500)
        #expect(player.hasReachedCutPoint)
        #expect(player.didCut)
        #expect(player.activeLowerSceneID == incoming)
        #expect(player.overlayVisible)
        player.advance(toMs: 1000)
        #expect(player.activeLowerSceneID == incoming)
        #expect(!player.isPlaying)
    }

    @Test
    func lottieWipe_isResolutionIndependentAndThemed() throws {
        let json = """
        {"w":1920,"h":1080,"ip":0,"op":30,"fr":30,"layers":[{"ty":4,"shapes":[{"ty":"fl","c":{"k":[1,0,0,1]}}]}]}
        """.data(using: .utf8)!
        let document = try LottieWipeDocument.parse(json)
        #expect(document.fillColors.first?.r == 1)
        let theme = TransitionThemeColors.desk
        let fills = LottieTransitionEngine.themedFills(in: document, theme: theme)
        #expect(fills.first == theme.primary)
        let wide = LottieTransitionEngine.alphaMatte(document: document, progress: 0.5, width: 32, height: 8)
        let tall = LottieTransitionEngine.alphaMatte(document: document, progress: 0.5, width: 8, height: 32)
        #expect(wide.filter { $0 == 1 }.count == 16 * 8)
        #expect(tall.filter { $0 == 1 }.count == 4 * 32)
        let from = TransitionImage.solid(RGBA8(r: 0, g: 0, b: 0, a: 1), width: 8, height: 8)
        let to = TransitionImage.solid(RGBA8(r: 1, g: 1, b: 1, a: 1), width: 8, height: 8)
        #expect(LottieTransitionEngine.composite(document: document, from: from, to: to, progress: 0).pixels == from.pixels)
        #expect(LottieTransitionEngine.composite(document: document, from: from, to: to, progress: 1).pixels == to.pixels)
    }

    @Test
    func coreImageAndCatalog_coverFourEngines() {
        let from = TransitionImage.solid(RGBA8(r: 0.2, g: 0.2, b: 0.2, a: 1), width: 6, height: 6)
        let to = TransitionImage.solid(RGBA8(r: 0.9, g: 0.9, b: 0.1, a: 1), width: 6, height: 6)
        for kind in CoreImageTransitionKind.allCases {
            #expect(CoreImageTransitionEngine.composite(kind: kind, from: from, to: to, uniforms: .make(progress: 0, width: 6, height: 6)).pixels == from.pixels)
            #expect(CoreImageTransitionEngine.composite(kind: kind, from: from, to: to, uniforms: .make(progress: 1, width: 6, height: 6)).pixels == to.pixels)
        }
        #expect(Set(TransitionCatalog.all.map(\.category)) == Set(TransitionEngineKind.allCases))
        #expect(TransitionCatalog.preset(id: "Whip Pan").shader == .whipPan)
    }

    @Test @MainActor
    func goLive_runsDissolveAcrossOutgoingIncoming() {
        let controller = TestSupport.sampleController()
        let first = controller.addSlide(named: "Verse")
        let second = controller.addSlide(named: "Chorus")
        controller.configureSlide(id: first.id) {
            $0.lines = ["Amazing grace"]
            $0.transition = "dissolve"
            $0.backgroundEnabled = false
        }
        controller.configureSlide(id: second.id) {
            $0.lines = ["How sweet the sound"]
            $0.transition = "dissolve"
            $0.backgroundEnabled = false
        }
        controller.slideTransitionSeconds = 0.6
        controller.goLive(slideID: first.id)
        controller.compositor.cancelProgramTransition()
        let started = Date()
        controller.goLive(slideID: second.id)
        #expect(controller.compositor.programTransition?.isActive == true)
        #expect(controller.compositor.programTransition?.preset.id == "dissolve")
        #expect(controller.compositor.stack.slideElements.contains(where: { $0.text.contains("How sweet") }))
        #expect(controller.compositor.programTransition?.outgoing.slideElements.contains(where: { $0.text.contains("Amazing") }) == true)

        controller.tickProgram(now: started.addingTimeInterval(0.2))
        #expect((controller.compositor.programTransition?.progress ?? 0) > 0.2)
        #expect((controller.compositor.programTransition?.progress ?? 1) < 1)

        controller.tickProgram(now: started.addingTimeInterval(0.7))
        #expect(controller.compositor.programTransition == nil)
        #expect(controller.compositor.stack.slideElements.contains(where: { $0.text.contains("How sweet") }))
    }

    @Test @MainActor
    func cut_doesNotHoldOutgoingProgram() {
        let controller = TestSupport.sampleController()
        let first = controller.addSlide(named: "A")
        let second = controller.addSlide(named: "B")
        controller.configureSlide(id: first.id) { $0.lines = ["One"]; $0.transition = "Cut" }
        controller.configureSlide(id: second.id) { $0.lines = ["Two"]; $0.transition = "Cut" }
        controller.goLive(slideID: first.id)
        controller.goLive(slideID: second.id)
        #expect(controller.compositor.programTransition == nil)
        #expect(controller.compositor.stack.slideElements.contains(where: { $0.text.contains("Two") }))
    }
}
