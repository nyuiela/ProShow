#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation

enum TestSupport {
    @MainActor
    static func sampleController(store: LibraryStore? = nil) -> ShowController {
        let sample = SampleContent.sundayMorningService()
        let resolved = store ?? .temporary()
        return ShowController(show: sample.show, playlist: sample.playlist, store: resolved, persistOnInit: true)
    }

    static func mediaAction(title: String = "Loop") -> MediaAction {
        MediaAction(id: UUID(), title: title, tintHex: "#112233", duration: "1:00.00", isImage: false)
    }

    static func writePNGFixture(in directory: URL, name: String = "still.png") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+XWusAAAAASUVORK5CYII=")
        try png?.write(to: url)
        return url
    }
}
