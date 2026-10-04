import Foundation

enum ProgramDocumentStore {
    /// Resolves a package, a `program.json` inside one, a directory, or a loose JSON file.
    static func jsonURL(for url: URL) -> URL {
        let ext = url.pathExtension.lowercased()
        if ext == ProgramDocumentFormat.fileExtension {
            return url.appendingPathComponent(ProgramDocumentFormat.jsonFilename)
        }
        if url.lastPathComponent == ProgramDocumentFormat.jsonFilename {
            return url
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url.appendingPathComponent(ProgramDocumentFormat.jsonFilename)
        }
        if ext.isEmpty || ext == "json" {
            if ext == "json" { return url }
            return url.appendingPathComponent(ProgramDocumentFormat.jsonFilename)
        }
        return url
            .deletingPathExtension()
            .appendingPathExtension(ProgramDocumentFormat.fileExtension)
            .appendingPathComponent(ProgramDocumentFormat.jsonFilename)
    }

    static func load(from url: URL) throws -> ProgramDocumentModel {
        let data = try Data(contentsOf: jsonURL(for: url))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProgramDocumentModel.self, from: data)
    }

    static func save(_ model: ProgramDocumentModel, to url: URL) throws {
        let jsonURL = jsonURL(for: url)
        try FileManager.default.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(model).write(to: jsonURL, options: .atomic)
    }
}
