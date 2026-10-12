import Foundation

struct ThemePackStore: Sendable {
    var root: URL

    init(root: URL) {
        self.root = root
    }

    static func themesDirectory(in projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent("Libraries/Themes", isDirectory: true)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func fileURL(for packID: UUID) -> URL {
        root.appendingPathComponent("\(packID.uuidString).protheme.json")
    }

    func save(_ pack: ProShowThemePack) throws {
        try prepare()
        let data = try ProjectJSON.encoder.encode(pack)
        try AtomicPersistenceEngine.writeData(data, to: fileURL(for: pack.id))
    }

    func load(id: UUID) -> ProShowThemePack? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ProjectJSON.decoder.decode(ProShowThemePack.self, from: data)
    }

    func loadAll() -> [ProShowThemePack] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { url -> ProShowThemePack? in
            guard url.pathExtension.lowercased() == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? ProjectJSON.decoder.decode(ProShowThemePack.self, from: data)
        }
        .sorted { $0.collectionName.localizedCaseInsensitiveCompare($1.collectionName) == .orderedAscending }
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    func ensureBuiltInSeed() throws -> ProShowThemePack {
        if var existing = load(id: ProShowThemePack.builtInID) {
            if !existing.variants.contains(where: { $0.layoutKind == .stage }) {
                existing.variants.append(contentsOf: ProShowThemePack.builtIn.variants.filter { $0.layoutKind == .stage })
                existing.schemaVersion = ProShowThemePack.schemaVersion
                try save(existing)
            }
            return existing
        }
        let seeded = ProShowThemePack.builtIn
        try save(seeded)
        return seeded
    }
}
