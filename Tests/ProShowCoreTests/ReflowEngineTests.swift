#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Testing

@Suite
struct ReflowEngineTests {
    @Test
    func blankLineBlocks() {
        let pages = ReflowEngine.split("Line one\n\nLine two")
        #expect(pages == [["Line one"], ["Line two"]])
    }

    @Test
    func wordLimit() {
        let pages = ReflowEngine.split("one two three four", wordLimit: 2)
        #expect(pages.count == 2)
        #expect(pages[0] == ["one two"])
        #expect(pages[1] == ["three four"])
    }

    @Test
    func emptyBuffer_noGroupSlides() {
        let group = ReflowEngine.slides(from: "   ")
        #expect(group.slides.isEmpty)
    }
}
