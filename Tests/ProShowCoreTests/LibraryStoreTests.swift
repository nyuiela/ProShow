#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct LibraryStoreTests {
    @Test
    func saveLoad_roundTrip() throws {
        let store = LibraryStore.temporary()
        let show = SampleContent.sundayMorningService().show
        try store.save(show)
        let loaded = store.loadAll()
        #expect(loaded.contains(where: { $0.id == show.id }))
        #expect(loaded.first(where: { $0.id == show.id })?.name == show.name)
    }

    @Test
    func corruptJSON_isSkipped() throws {
        let store = LibraryStore.temporary()
        try store.prepare()
        try Data("not-json".utf8).write(to: store.root.appendingPathComponent("bad.json"))
        #expect(store.loadAll().isEmpty)
    }

    @Test @MainActor
    func bootstrap_seedsWhenEmpty() {
        let store = LibraryStore.temporary()
        let controller = ShowController.bootstrap(store: store)
        #expect(!store.loadAll().isEmpty)
        #expect(controller.show.allSlides.isEmpty == false)
    }

    @Test @MainActor
    func addAndDeletePresentation() {
        let store = LibraryStore.temporary()
        let controller = TestSupport.sampleController(store: store)
        let created = controller.addPresentation(named: "New Set")
        #expect(store.loadAll().contains(where: { $0.id == created.id }))
        controller.deletePresentation(id: created.id)
        #expect(!store.loadAll().contains(where: { $0.id == created.id }))
    }

    @Test @MainActor
    func addFolder_appendsLibraryFolder() {
        let controller = TestSupport.sampleController()
        let before = controller.libraryFolders.count
        controller.addFolder(named: "Youth")
        #expect(controller.libraryFolders.count == before + 1)
        #expect(controller.libraryFolders.contains(where: { $0.name == "Youth" }))
    }

    @Test @MainActor
    func mediaPlaylist_createAndBrowse() {
        let controller = TestSupport.sampleController()
        let created = controller.addMediaPlaylist(named: "Weekend")
        #expect(controller.collections(for: .playlists).contains(where: { $0.id == created.id }))
        #expect(controller.selectedMediaSource == .playlists)
        #expect(controller.selectedCollectionID == created.id)
        controller.openMediaPane(source: .playlists)
        #expect(controller.selectedCollectionID == nil)
        #expect(!controller.visibleMediaFolders.isEmpty)
    }
}
