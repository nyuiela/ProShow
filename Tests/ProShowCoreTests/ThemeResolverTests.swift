import Foundation
import Testing
@testable import ProShowCore

struct ThemeResolverTests {
    @Test
    func mapsLinesOntoLyricStandardVariant() {
        var slide = Slide(
            title: "",
            lines: ["Line one", "Line two"],
            theme: "Lyric Standard",
            themeVariantID: ThemeVariantRegistry.variant(named: "Lyric Standard")?.id
        )
        slide.canvas = []
        let canvas = slide.audienceCanvas()
        let text = canvas.first(where: \.isTextLike)?.text ?? ""
        #expect(text.contains("Line one"))
        #expect(text.contains("Line two"))
        #expect(!text.contains("Lyric Standard"))
    }

    @Test
    func primaryFallbackSingleStream() {
        var slide = Slide(lines: ["Only line"], theme: "Lyric Standard")
        slide.themeVariantID = ThemeVariantRegistry.variant(named: "Lyric Standard")?.id
        slide.canvas = []
        let text = slide.audienceCanvas().first(where: \.isTextLike)?.text
        #expect(text == "Only line")
    }

    @Test
    func titleAndSubtitleRoles() {
        var slide = Slide(title: "Main Title", lines: ["Sub line"], theme: "Title & Subtitle")
        slide.themeVariantID = ThemeVariantRegistry.variant(named: "Title & Subtitle")?.id
        slide.canvas = []
        let objects = slide.audienceCanvas().filter(\.isTextLike)
        #expect(objects.contains(where: { $0.text == "Main Title" }))
        #expect(objects.contains(where: { $0.text == "Sub line" }))
    }

    @Test
    func scriptureReferenceAndBody() {
        var slide = Slide(
            lines: ["John 3:16", "For God so loved the world"],
            theme: "Scripture",
            themeVariantID: ThemeVariantRegistry.variant(named: "Scripture")?.id
        )
        slide.canvas = []
        let objects = slide.audienceCanvas().filter(\.isTextLike)
        #expect(objects.contains(where: { $0.text == "John 3:16" }))
        #expect(objects.contains(where: { $0.text.contains("For God") }))
    }

    @Test
    func nativeCanvasSkipsThemeWhenAuthorDesigned() {
        let seeded = DefaultSeedData.lyricSlide(lines: ["Stored lyric"])
        var slide = seeded
        slide.theme = "Lyric Standard"
        slide.themeVariantID = ThemeVariantRegistry.variant(named: "Lyric Standard")?.id
        slide.themeApplication = .native
        let canvas = slide.audienceCanvas()
        #expect(canvas.count == 1)
        #expect(canvas[0].text.contains("Stored lyric"))
    }

    @Test
    func emptySlotRendersEmptyTextBox() {
        var slide = Slide(lines: [], theme: "Lyric Standard")
        slide.themeVariantID = ThemeVariantRegistry.variant(named: "Lyric Standard")?.id
        slide.canvas = []
        let text = slide.audienceCanvas().first(where: \.isTextLike)?.text ?? "missing"
        #expect(text.isEmpty)
    }

    @Test
    func outputVariantOverrideReplacesNativeCanvas() {
        let seeded = DefaultSeedData.lyricSlide(lines: ["Stored lyric"])
        var slide = seeded
        slide.theme = "Lyric Standard"
        slide.themeVariantID = ThemeVariantRegistry.variant(named: "Lyric Standard")?.id
        slide.themeApplication = .native
        let override = ThemeVariantRegistry.variant(named: "Lyric Standard")!.id
        let canvas = slide.audienceCanvas(variantOverrideID: override)
        let text = canvas.first(where: \.isTextLike)?.text ?? ""
        #expect(text.contains("Stored lyric"))
        #expect(!text.isEmpty)
    }

    @Test
    func rundownBridgeDecorOnlyForCameraBlock() {
        var block = RundownBlock(
            itemNumber: "1",
            title: "Cam",
            segmentType: .keynote,
            plannedDurationSeconds: 60
        )
        RundownBlockSlideSource.apply(.camera, to: &block)
        var slide = Slide(lines: ["Line"], canvas: [])
        slide = ThemeRundownBridge.prepareSlide(slide, block: block, profileDefaults: [:])
        #expect(slide.themeApplication == .decorOnly)
    }

    @Test
    func resolverGeneratesFreshObjectIDs() {
        var slide = Slide(lines: ["A"], theme: "Lyric Standard")
        slide.themeVariantID = ThemeVariantRegistry.variant(named: "Lyric Standard")?.id
        slide.canvas = []
        let first = slide.audienceCanvas().map(\.id)
        let second = slide.audienceCanvas().map(\.id)
        #expect(first != second)
    }
}
