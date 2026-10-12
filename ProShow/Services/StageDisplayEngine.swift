import Foundation

struct StageDisplayLayout: Hashable, Codable, Sendable {
    var showCurrent: Bool
    var showNext: Bool
    var showClock: Bool
    var showCountdown: Bool
    var showAlertBanner: Bool
    var showChords: Bool
    var ndiOutputEnabled: Bool
    var chordSemitones: Int

    static let standard = StageDisplayLayout(
        showCurrent: true,
        showNext: true,
        showClock: true,
        showCountdown: true,
        showAlertBanner: true,
        showChords: false,
        ndiOutputEnabled: false,
        chordSemitones: 0
    )
}

/// Stage confidence layouts, musician chords, and opt-in NDI stage publish.
enum StageDisplayEngine {
    private static let chromatic = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func document(from look: StageLookConfig, layout: StageDisplayLayout, name: String = "Stage") -> EditorDocument {
        var merged = look
        merged.showCurrent = look.showCurrent || layout.showCurrent
        merged.showNext = look.showNext || layout.showNext
        merged.showClock = look.showClock || layout.showClock
        var document = StageLiveBinder.document(from: merged, name: name)
        if layout.showCountdown {
            var countdown = CanvasObject(
                name: CanvasObjectKind.timerCountdown.defaultName,
                kind: .timerCountdown,
                bounds: CanvasBounds(x: 160, y: 80, width: 720, height: 140),
                zIndex: 6,
                text: "00:00",
                token: CountdownFormatCatalog.default,
                timerID: ActionSeedID.serviceTimer
            )
            countdown.fill.type = .none
            countdown.stroke.style = .none
            countdown.fontSize = 56
            document.objects.append(countdown)
        }
        return document
    }

    static func audienceLines(from lines: [String]) -> [String] {
        lines.map(stripChordTokens)
    }

    static func stageLines(from lines: [String], semitones: Int, showChords: Bool) -> [String] {
        guard showChords else { return audienceLines(from: lines) }
        return lines.map { overlayChords(in: $0, semitones: semitones) }
    }

    static func stripChordTokens(_ line: String) -> String {
        let stripped = line.replacingOccurrences(
            of: #"\[[^\]]+\]"#,
            with: "",
            options: .regularExpression
        )
        return stripped
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func overlayChords(in line: String, semitones: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]"#) else { return line }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        var output = line
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let tokenRange = Range(match.range(at: 1), in: line)
            else { continue }
            let token = String(line[tokenRange])
            let transposed = transposeChord(token, semitones: semitones)
            if let full = Range(match.range, in: output) {
                output.replaceSubrange(full, with: "[\(transposed)]")
            }
        }
        return output
    }

    static func transposeChord(_ token: String, semitones: Int) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = rootIndex(in: trimmed) else { return trimmed }
        let accidental = trimmed.dropFirst().first.map(String.init).flatMap { mark in
            mark == "#" || mark == "b" ? mark : nil
        } ?? ""
        let suffixStart = trimmed.index(trimmed.startIndex, offsetBy: 1 + accidental.count)
        let suffix = String(trimmed[suffixStart...])
        var index = root
        if accidental == "b" { index = (index + 11) % 12 }
        let shifted = (index + semitones % 12 + 12) % 12
        return chromatic[shifted] + suffix
    }

    static func shouldPublishNDI(layout: StageDisplayLayout, outputName: String, runtimeAvailable: Bool) -> Bool {
        layout.ndiOutputEnabled && !outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && runtimeAvailable
    }

    private static func rootIndex(in token: String) -> Int? {
        guard let first = token.first else { return nil }
        let letter = String(first).uppercased()
        switch letter {
        case "C": return 0
        case "D": return 2
        case "E": return 4
        case "F": return 5
        case "G": return 7
        case "A": return 9
        case "B": return 11
        default: return nil
        }
    }
}
