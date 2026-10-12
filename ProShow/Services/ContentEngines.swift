import Foundation

/// In-memory inverted index across library, playlists, Bibles, and media.
struct SearchIndex: Sendable {
    private var postings: [String: [SearchHit]] = [:]

    mutating func rebuild(
        folders: [LibraryFolder],
        playlists: [LibraryFolder],
        items: [LibraryShowItem],
        media: [MediaBinItem],
        passages: [BiblePassage],
        shows: [Show] = []
    ) {
        postings = [:]
        for folder in folders {
            insert(tokens: folder.name, SearchHit(id: "lib-\(folder.id)", kind: .library, title: folder.name, detail: "Library"))
        }
        for folder in playlists {
            insert(tokens: folder.name, SearchHit(id: "pl-\(folder.id)", kind: .playlist, title: folder.name, detail: "Playlist"))
        }
        for item in items {
            insert(tokens: "\(item.title) \(item.subtitle)", SearchHit(id: "item-\(item.id)", kind: .playlist, title: item.title, detail: item.subtitle))
        }
        for item in media {
            insert(tokens: item.title, SearchHit(id: "media-\(item.id)", kind: .media, title: item.title, detail: item.source.title))
        }
        for show in shows {
            insert(tokens: show.name, SearchHit(id: "show-\(show.id.uuidString)", kind: .presentation, title: show.name, detail: "Presentation"))
            for slide in show.allSlides {
                let body = ([slide.title] + slide.lines).joined(separator: " ")
                insert(
                    tokens: "\(show.name) \(body)",
                    SearchHit(id: "slide-\(slide.id.uuidString)", kind: .presentation, title: slide.previewSummary, detail: show.name)
                )
            }
        }
        for passage in passages {
            insert(tokens: "\(passage.reference) \(passage.text)", SearchHit(id: "bible-\(passage.reference)", kind: .bible, title: passage.reference, detail: passage.text))
        }
    }

    func query(_ raw: String) -> [SearchHit] {
        let tokens = Self.tokenize(raw)
        guard !tokens.isEmpty else { return [] }
        var allowed = Set(postings[tokens[0], default: []].map(\.id))
        for token in tokens.dropFirst() {
            allowed.formIntersection(postings[token, default: []].map(\.id))
        }
        var unique: [String: SearchHit] = [:]
        for token in tokens {
            for hit in postings[token, default: []] where allowed.contains(hit.id) {
                unique[hit.id] = hit
            }
        }
        return Array(unique.values).sorted { $0.title < $1.title }
    }

    private mutating func insert(tokens: String, _ hit: SearchHit) {
        for token in Self.tokenize(tokens) {
            postings[token, default: []].append(hit)
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }
    }
}

/// Splits a text buffer into slide line arrays by delimiter or word count.
enum ReflowEngine {
    static func split(_ buffer: String, wordLimit: Int = 12) -> [[String]] {
        let blocks = buffer
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if blocks.count > 1 {
            return blocks.map { $0.components(separatedBy: "\n").filter { !$0.isEmpty } }
        }

        let words = buffer.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var slides: [[String]] = []
        var index = 0
        while index < words.count {
            let chunk = Array(words[index..<min(index + wordLimit, words.count)])
            slides.append([chunk.joined(separator: " ")])
            index += wordLimit
        }
        return slides
    }

    static func slides(from buffer: String, groupName: String = "Reflow") -> SlideGroup {
        let pages = split(buffer)
        return SlideGroup(
            name: groupName,
            colorHex: "#6B4C9A",
            slides: pages.map { Slide(lines: $0) }
        )
    }
}

/// Local scripture lookup. The desk stays hidden until a translation package is installed.
enum BibleEngine {
    static let packageExtension = "proshowbible"

    static var translationsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ProShow/Translations", isDirectory: true)
    }

    static var hasTranslationPackage: Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: translationsRoot, includingPropertiesForKeys: nil) else {
            return false
        }
        return files.contains { $0.pathExtension.lowercased() == packageExtension }
    }

    static var installedPassages: [BiblePassage] {
        guard hasTranslationPackage else { return [] }
        guard let files = try? FileManager.default.contentsOfDirectory(at: translationsRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.flatMap { url -> [BiblePassage] in
            guard url.pathExtension.lowercased() == packageExtension, let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([BiblePassage].self, from: data)) ?? []
        }
    }

    static let canon: [BiblePassage] = DeskSampleData.biblePassages + [
        BiblePassage(reference: "John 3:16", text: "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life."),
        BiblePassage(reference: "Genesis 1:1", text: "In the beginning God created the heaven and the earth."),
        BiblePassage(reference: "Romans 8:28", text: "And we know that all things work together for good to them that love God, to them who are the called according to his purpose."),
    ]

    static func lookup(_ query: String, passages: [BiblePassage] = canon) -> [BiblePassage] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return passages }
        return passages.filter {
            $0.reference.localizedCaseInsensitiveContains(needle)
                || $0.text.localizedCaseInsensitiveContains(needle)
        }
    }

    static func slide(from passage: BiblePassage) -> Slide {
        Slide(title: passage.reference, lines: [passage.reference, passage.text], notes: "Bible")
    }
}

/// JSON document store for library presentations (local, not GPL).
struct LibraryStore: Sendable {
    var root: URL
    var fileExtension: String

    init(root: URL, fileExtension: String = "json") {
        self.root = root
        self.fileExtension = fileExtension
    }

    static func applicationSupport() -> LibraryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return LibraryStore(root: base.appendingPathComponent("ProShow/Library", isDirectory: true))
    }

    static func temporary() -> LibraryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProShowTests-\(UUID().uuidString)", isDirectory: true)
        return LibraryStore(root: url)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func save(_ show: Show) throws {
        try prepare()
        let url = root.appendingPathComponent("\(show.id.uuidString).\(fileExtension)")
        let data = try JSONEncoder().encode(show)
        try AtomicPersistenceEngine.writeData(data, to: url)
        // An older .json next to a newer .prolib (or the reverse) used to win
        // directory order on the next open and bring deleted shapes back.
        for ext in ["json", "prolib"] where ext != fileExtension.lowercased() {
            let stale = root.appendingPathComponent("\(show.id.uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: stale.path) {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }

    func loadAll() -> [Show] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        var newest: [ShowID: (show: Show, modified: Date)] = [:]
        for url in files {
            let ext = url.pathExtension.lowercased()
            guard ext == "json" || ext == "prolib" || ext == fileExtension.lowercased() else { continue }
            guard let data = try? Data(contentsOf: url),
                  let show = try? JSONDecoder().decode(Show.self, from: data)
            else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let existing = newest[show.id], existing.modified > modified { continue }
            newest[show.id] = (show, modified)
        }
        return newest.values.map(\.show).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func delete(id: ShowID) throws {
        for ext in Set([fileExtension, "json", "prolib"]) {
            let url = root.appendingPathComponent("\(id.uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func replaceAll(with shows: [Show]) throws {
        for show in loadAll() {
            try delete(id: show.id)
        }
        for show in shows {
            try save(show)
        }
    }
}
