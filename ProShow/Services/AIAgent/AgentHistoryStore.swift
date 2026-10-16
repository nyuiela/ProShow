import Foundation

/// Persisted Ask / agent conversation. Survives relaunch. Caps growth.
enum AgentHistoryStore {
    static let maxEntries = 60
    static let maxWireMessages = 40

    struct Entry: Codable, Identifiable, Hashable, Sendable {
        var id: UUID
        var ts: Date
        var role: String
        var text: String
        var groupName: String? = nil
        var slideIDs: [UUID] = []
        var slideTitles: [String] = []
        var deepLink: String? = nil

        var locationLabel: String? {
            guard let groupName, !slideIDs.isEmpty else { return nil }
            let first = slideTitles.first.flatMap { $0.isEmpty ? nil : $0 } ?? "Slide"
            if slideIDs.count == 1 {
                return "Created in \(groupName) · \(first)"
            }
            return "Created in \(groupName) · \(slideIDs.count) slides (first: \(first))"
        }
    }

    struct WireMessage: Codable, Hashable, Sendable {
        var role: String
        var content: String?
        var toolCallID: String? = nil
    }

    struct Document: Codable, Sendable {
        var v: Int = 1
        var updatedAt: Date = .now
        var projectKey: String
        var entries: [Entry] = []
        var wire: [WireMessage] = []
    }

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ProShow/Agent/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(projectKey: String) -> URL {
        let safe = projectKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = safe.isEmpty ? "global.json" : "\(safe).json"
        return rootDirectory.appendingPathComponent(name)
    }

    static func load(projectKey: String) -> Document {
        let url = fileURL(projectKey: projectKey)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let doc = try? decoder.decode(Document.self, from: data)
        else {
            return Document(projectKey: projectKey)
        }
        return doc
    }

    static func save(_ document: Document) {
        var doc = document
        doc.updatedAt = .now
        if doc.entries.count > maxEntries {
            doc.entries = Array(doc.entries.suffix(maxEntries))
        }
        if doc.wire.count > maxWireMessages {
            doc.wire = Array(doc.wire.suffix(maxWireMessages))
            while doc.wire.first?.role == "tool" { doc.wire.removeFirst() }
        }
        let url = fileURL(projectKey: doc.projectKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(doc) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func clear(projectKey: String) {
        try? FileManager.default.removeItem(at: fileURL(projectKey: projectKey))
    }
}

struct AgentSlidePlacement: Hashable, Sendable {
    var groupName: String
    var slideIDs: [UUID]
    var slideTitles: [String]
    var showID: UUID?

    var deepLink: String {
        guard let first = slideIDs.first else {
            return "proshow://group/\(groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupName)"
        }
        if let showID {
            return "proshow://show/\(showID.uuidString)/slide/\(first.uuidString)"
        }
        return "proshow://slide/\(first.uuidString)"
    }

    var label: String {
        let first = slideTitles.first.flatMap { $0.isEmpty ? nil : $0 } ?? "Slide"
        if slideIDs.count <= 1 {
            return "Created in \(groupName) · \(first)"
        }
        return "Created in \(groupName) · \(slideIDs.count) slides · \(first)"
    }
}
