#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct PresentationImportTests {
    @Test
    func parseInterchangeJSON() throws {
        let json = """
        {"name":"Imported","groups":[{"name":"Verse","slides":[{"lines":["Hello world"],"notes":"soft"}]}]}
        """
        let show = try PresentationImport.parseJSON(Data(json.utf8))
        #expect(show.name == "Imported")
        #expect(show.groups[0].slides[0].displayText == "Hello world")
    }

    @Test @MainActor
    func controllerImport_persists() throws {
        let store = LibraryStore.temporary()
        let controller = TestSupport.sampleController(store: store)
        let json = """
        {"name":"From File","groups":[{"name":"A","slides":[{"lines":["One"]}]}]}
        """
        let imported = try controller.importPresentation(data: Data(json.utf8))
        #expect(store.loadAll().contains(where: { $0.id == imported.id }))
    }
}
