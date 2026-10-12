import Foundation

enum ImportReflowError: Error, Equatable {
    case unsupportedProPresenter
    case emptyDocument
    case unrecognizedFormat
}

/// Local document and lyric reflow. ProPresenter binary packs are rejected, not parsed.
enum ImportReflowEngine {
    static let defaultLinesPerSlide = 4

    static func `import`(data: Data, name: String, pathExtension: String) throws -> Show {
        let ext = pathExtension.lowercased()
        if ["pro", "pro5", "pro6", "pro7"].contains(ext) {
            throw ImportReflowError.unsupportedProPresenter
        }
        if ext == "pptx" || ext == "ppt" {
            return try PresentationImport.parsePPTX(data)
        }
        if ext == "json" {
            return try PresentationImport.parseJSON(data)
        }
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let group = reflowLyrics(text, groupName: name.isEmpty ? "Imported" : name)
            return Show(name: name.isEmpty ? "Imported" : name, groups: [group], notes: "Reflow import")
        }
        throw ImportReflowError.unrecognizedFormat
    }

    static func reflowLyrics(
        _ buffer: String,
        groupName: String = "Lyrics",
        linesPerSlide: Int = defaultLinesPerSlide
    ) -> SlideGroup {
        let sections = splitSections(buffer)
        var slides: [Slide] = []
        for section in sections {
            let wrapped = wrapLines(section.lines, limit: max(1, linesPerSlide))
            for chunk in wrapped {
                slides.append(
                    Slide(
                        title: section.name,
                        lines: chunk,
                        notes: section.name,
                        label: section.label
                    )
                )
            }
        }
        return SlideGroup(name: groupName, colorHex: "#6B4C9A", slides: slides)
    }

    static func reflowScripture(_ query: String, linesPerSlide: Int = 2) -> SlideGroup {
        let hits = BibleEngine.lookup(query)
        let lines: [String]
        if let first = hits.first {
            lines = [first.reference] + wrapWords(first.text, wordLimit: 16)
        } else {
            lines = ReflowEngine.split(query, wordLimit: 16).flatMap { $0 }
        }
        let wrapped = wrapLines(lines, limit: max(1, linesPerSlide))
        return SlideGroup(
            name: hits.first?.reference ?? "Scripture",
            colorHex: "#3B82F6",
            slides: wrapped.map { Slide(title: hits.first?.reference ?? "Scripture", lines: $0, notes: "Scripture") }
        )
    }

    private struct LyricSection {
        var name: String
        var label: String
        var lines: [String]
    }

    private static func splitSections(_ buffer: String) -> [LyricSection] {
        let raw = buffer
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var sections: [LyricSection] = []
        var current = LyricSection(name: "Verse", label: "verse", lines: [])
        for line in raw {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let header = sectionHeader(trimmed) {
                if !current.lines.isEmpty { sections.append(current) }
                current = LyricSection(name: header.name, label: header.label, lines: [])
                continue
            }
            current.lines.append(trimmed)
        }
        if !current.lines.isEmpty { sections.append(current) }
        return sections
    }

    private static func sectionHeader(_ line: String) -> (name: String, label: String)? {
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]:"))
        let needle = stripped.lowercased()
        if needle.hasPrefix("verse") { return (stripped, "verse") }
        if needle.hasPrefix("chorus") || needle.hasPrefix("refrain") { return (stripped, "chorus") }
        if needle.hasPrefix("bridge") { return (stripped, "bridge") }
        if needle.hasPrefix("intro") { return (stripped, "intro") }
        if needle.hasPrefix("outro") || needle.hasPrefix("tag") { return (stripped, "outro") }
        return nil
    }

    private static func wrapLines(_ lines: [String], limit: Int) -> [[String]] {
        guard !lines.isEmpty else { return [] }
        var pages: [[String]] = []
        var index = 0
        while index < lines.count {
            pages.append(Array(lines[index..<min(index + limit, lines.count)]))
            index += limit
        }
        return pages
    }

    private static func wrapWords(_ text: String, wordLimit: Int) -> [String] {
        ReflowEngine.split(text, wordLimit: wordLimit).map { $0.joined(separator: " ") }
    }
}
