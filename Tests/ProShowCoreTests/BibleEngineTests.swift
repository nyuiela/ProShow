#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Testing

@Suite
struct BibleEngineTests {
    @Test
    func john316_exact() {
        let hits = BibleEngine.lookup("John 3:16")
        #expect(hits.contains(where: { $0.reference == "John 3:16" }))
        #expect(hits.first(where: { $0.reference == "John 3:16" })?.text.contains("God so loved") == true)
    }

    @Test
    func john_prefix() {
        let hits = BibleEngine.lookup("john")
        #expect(hits.contains(where: { $0.reference.hasPrefix("John") }))
    }

    @Test
    func unknownReference_isEmpty() {
        #expect(BibleEngine.lookup("Revelation 99:1").isEmpty)
    }

    @Test
    func deskStaysHiddenWithoutPackage() {
        #expect(BibleEngine.hasTranslationPackage == false)
        #expect(BibleEngine.installedPassages.isEmpty)
    }
}
