#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct StagePayloadTests {
    @Test
    func programOff_stillHasSummaries() {
        let payload = StagePayload.make(
            liveSummary: "Hello",
            nextSummary: "World",
            notes: "Soft",
            programOutputEnabled: false
        )
        #expect(payload.current == "Hello")
        #expect(payload.next == "World")
        #expect(payload.notes == "Soft")
        #expect(payload.outputEnabled == false)
    }

    @Test @MainActor
    func makeFromController_afterLive() {
        let controller = TestSupport.sampleController()
        controller.goLive(slideID: controller.show.allSlides[0].id)
        let payload = StagePayload.make(controller: controller)
        #expect(!payload.current.isEmpty)
        #expect(payload.current != "—")
        if let next = controller.nextSlide?.previewSummary, !next.isEmpty {
            #expect(payload.next == next || payload.next != "—")
        }
        #expect(payload.outputEnabled)
    }

    @Test
    func lookPlusDisabledOutput_isBlackContract() {
        let payload = StagePayload.make(
            liveSummary: "Hidden",
            nextSummary: nil,
            notes: nil,
            programOutputEnabled: false
        )
        #expect(payload.outputEnabled == false)
        #expect(payload.next == "—")
    }

    @Test
    func stageDocument_resolvesLiveTokens() {
        let payload = StagePayload.make(
            liveSummary: "Amazing Grace",
            nextSummary: "Verse 2",
            notes: "Soft",
            programOutputEnabled: true
        )
        let document = StageLiveBinder.document(
            from: StageLookConfig(showCurrent: true, showNext: true, showNotes: true, showClock: true),
            name: "Grid View"
        )
        #expect(document.kind == .stage)
        #expect(document.objects.contains(where: { $0.kind == .currentSlide }))
        let current = document.objects.first(where: { $0.kind == .currentSlide })!
        #expect(StageLiveBinder.resolvedText(for: current, payload: payload, clock: "7:00:00 PM", timerText: nil) == "Amazing Grace")
        #expect(ScreenCatalog.defaultScreens().contains(where: { $0.role == .stage }))
        #expect(ScreenCatalog.defaultScreens().contains(where: { $0.role == .audience }))
    }

    @Test
    func stagePackIncludesGridLayoutVariant() {
        ThemeVariantRegistry.configure(packs: [ProShowThemePack.builtIn], profileDefaults: [:])
        #expect(ThemeVariantRegistry.stageVariants.count >= 4)
        #expect(ThemeVariantRegistry.stageVariant(id: ActionSeedID.layoutGrid)?.name == "Grid View")
    }
}
