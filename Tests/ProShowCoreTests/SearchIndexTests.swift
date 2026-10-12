#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Testing

@Suite
struct SearchIndexTests {
    @Test
    func multiToken_AND_requiresBoth() {
        var index = SearchIndex()
        index.rebuild(
            folders: [LibraryFolder(name: "Stellar Church", systemImage: "folder", children: [])],
            playlists: [],
            items: [LibraryShowItem(title: "stellar slides_peter okai", subtitle: "", isActive: true)],
            media: [],
            passages: []
        )
        let hits = index.query("stellar slides")
        #expect(hits.contains(where: { $0.title.contains("stellar slides") }))
        #expect(index.query("stellar banana").isEmpty)
    }

    @Test
    func emptyQuery_returnsNothing() {
        var index = SearchIndex()
        index.rebuild(folders: DeskSampleData.libraryFolders, playlists: [], items: [], media: [], passages: [])
        #expect(index.query("").isEmpty)
    }

    @Test
    func liveShowsAndMedia_areIndexed() {
        var index = SearchIndex()
        let show = Show(
            name: "Amazing Grace",
            groups: [SlideGroup(name: "Verse", slides: [Slide(title: "Verse 1", lines: ["through many dangers"])])]
        )
        let media = MediaBinItem(title: "Countdown Loop", kind: .video(duration: "0:05"), tintHex: "#111", source: .playlists)
        index.rebuild(
            folders: [LibraryFolder(name: "Stellar Library", systemImage: "folder", children: [])],
            playlists: [],
            items: [],
            media: [media],
            passages: [],
            shows: [show]
        )
        #expect(index.query("dangers").contains(where: { $0.kind == .presentation }))
        #expect(index.query("countdown").contains(where: { $0.kind == .media }))
        #expect(index.query("John 3:16").isEmpty)
    }
}
