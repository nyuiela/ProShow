import Foundation
#if os(macOS)
import AppKit
import WebKit
#endif

enum OutlineScriptError: Error, Equatable {
    case unknownTalent(String)
    case unknownSegmentType(String)
    case multipleTakes(String)
    case takeWithoutTarget(String)
    case invalidPlaylistItemID(String)
    case missingTitle(String)
}

struct OutlineCompileResult: Equatable {
    var document: ProgramDocumentModel
    var warnings: [String]
}

/// Turns an outline script into rundown fields. CueLog never sees this text.
enum OutlineScriptCompiler {
    private static let sectionWords: Set<String> = [
        "FORMAT", "SHOW", "DATE", "HARDSTART", "ITEM", "TITLE", "TYPE", "START",
        "DURATION", "LOCK", "TALENT", "AUDIO", "LOWERTHIRD", "CUE", "SAY", "LINKS", "NOTES",
    ]

    static func compile(_ source: String, talent: [TalentProfile]) throws -> OutlineCompileResult {
        var document = ProgramDocumentModel()
        document.outlineFormat = 1
        document.talentDatabase = talent
        var warnings: [String] = []
        var current: ItemDraft?
        var section: Section = .none

        func flush() throws {
            guard var item = current else { return }
            let block = try item.makeBlock(talent: talent, warnings: &warnings)
            document.rundownBlocks.append(block)
            current = nil
            section = .none
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let keyword = keyword(on: line) {
                if keyword.word == "ITEM" {
                    try flush()
                    current = ItemDraft(itemNumber: keyword.rest)
                    section = .none
                    continue
                }
                guard var item = current else {
                    try applyDocumentLine(keyword, to: &document)
                    section = .none
                    continue
                }
                switch keyword.word {
                case "SAY":
                    section = .say
                    if !keyword.rest.isEmpty { item.say.append(keyword.rest) }
                case "SHOW":
                    section = .show
                    if !keyword.rest.isEmpty { try item.absorbShow(keyword.rest) }
                case "LINKS":
                    section = .links
                    if !keyword.rest.isEmpty { try item.absorbLink(keyword.rest) }
                case "NOTES":
                    section = .notes
                    if !keyword.rest.isEmpty { item.notes.append(keyword.rest) }
                default:
                    section = .none
                    try item.apply(keyword)
                }
                current = item
                continue
            }

            guard var item = current else { continue }
            if line.isEmpty {
                if section == .say { item.say.append("") }
                if section == .notes { item.notes.append("") }
                current = item
                continue
            }
            switch section {
            case .say: item.say.append(line)
            case .show: try item.absorbShow(line)
            case .links: try item.absorbLink(line)
            case .notes: item.notes.append(line)
            case .none: break
            }
            current = item
        }
        try flush()
        document.targetDurationSeconds = document.rundownBlocks.reduce(0) { $0 + $1.plannedDurationSeconds }
        return OutlineCompileResult(document: document, warnings: warnings)
    }

    /// Splits the older labeled prose (`KALEEL:`, `ON SCREEN:`, `LINKS TO SAY:`, `REFERENCE:`)
    /// into spoken copy and operator fields. Blocks without those labels are left alone.
    static func splitLegacyLabeledScript(
        _ block: inout RundownBlock,
        documentCues: [StageCueTrigger]
    ) {
        let sections = legacySections(in: block.scriptBody)
        guard sections.keys.contains("ON SCREEN")
            || sections.keys.contains("LINKS TO SAY")
            || sections.keys.contains("REFERENCE")
            || sections.keys.contains("KALEEL")
        else { return }

        let spoken = collapseBreaks(sections["KALEEL"] ?? "")
        block.scriptBody = spoken
        let directions = screenDirections(from: sections["ON SCREEN"] ?? "")
        block.screenDirections = directions
        if !directions.isEmpty {
            block.videoCue = videoCueSummary(directions)
        }
        block.linkCues = linkCues(from: sections["LINKS TO SAY"] ?? "", spoken: spoken)
        block.referenceNotes = collapseBreaks(sections["REFERENCE"] ?? "")
        block.outlineFormat = 1
        if block.customCueTriggers.isEmpty, block.plannedDurationSeconds < 90 {
            block.customCueTriggers = explicitShortCues(inheriting: documentCues)
        }
    }

    static func screenDirections(from prose: String) -> [ScreenDirection] {
        var directions: [ScreenDirection] = []
        for sentence in sentences(in: prose) {
            if let url = firstURL(in: sentence) {
                let label = labelByRemoving(url, from: sentence)
                directions.append(ScreenDirection(kind: .url, label: label.isEmpty ? url : label, url: url))
                continue
            }
            if let camera = cameraSplit(sentence) {
                directions.append(ScreenDirection(kind: .camera, label: "Camera"))
                if !camera.isEmpty {
                    directions.append(ScreenDirection(kind: .note, label: camera))
                }
                continue
            }
            if sentence.lowercased().contains("slide") {
                directions.append(ScreenDirection(kind: .slide, label: slideLabel(sentence)))
                continue
            }
            directions.append(ScreenDirection(kind: .note, label: sentence))
        }
        return directions
    }

    static func videoCueSummary(_ directions: [ScreenDirection]) -> String {
        let primary = directions.filter { $0.kind != .note && $0.kind != .unknown }
        let source = primary.isEmpty ? Array(directions.prefix(2)) : Array(primary.prefix(3))
        let summary = source.map { direction in
            switch direction.kind {
            case .camera:
                "Camera"
            case .slide:
                direction.label.lowercased().hasPrefix("slide") ? direction.label : "Slide: \(direction.label)"
            case .url:
                direction.label.isEmpty ? (direction.url ?? "URL") : direction.label
            case .layout:
                "Layout: \(direction.label)"
            case .note, .unknown:
                direction.label
            }
        }.joined(separator: ". ")
        if summary.isEmpty { return "" }
        return summary.hasSuffix(".") ? summary : summary + "."
    }

    static func linkCues(from prose: String, spoken: String) -> [LinkCue] {
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.compare("none", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || trimmed.compare("none.", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return []
        }
        return urls(in: trimmed).map { url in
            let bare = bareAddress(url)
            return LinkCue(
                label: bare,
                url: url,
                speakOnAir: spoken.lowercased().contains(bare.lowercased()),
                autoTake: false
            )
        }
    }

    static func explicitShortCues(inheriting documentCues: [StageCueTrigger]) -> [StageCueTrigger] {
        let dangerous = documentCues.contains { $0.triggerOffsetSeconds <= -60 }
        let source = (documentCues.isEmpty || dangerous)
            ? [StageCueTrigger(triggerOffsetSeconds: 0, stageMessage: "NEXT MINUTE")]
            : documentCues
        return source.map {
            StageCueTrigger(
                triggerOffsetSeconds: $0.triggerOffsetSeconds,
                stageMessage: $0.stageMessage,
                flashScreen: $0.flashScreen,
                triggerMacroId: $0.triggerMacroId
            )
        }
    }

    private enum Section {
        case none, say, show, links, notes
    }

    private struct Keyword {
        var word: String
        var rest: String
    }

    private struct ItemDraft {
        var itemNumber: String
        var title = ""
        var segmentType: SegmentType = .keynote
        var duration: TimeInterval = 60
        var lockHard = false
        var start: Date?
        var talentName = ""
        var audio = ""
        var lowerThird = false
        var inheritCues = false
        var cues: [StageCueTrigger] = []
        var sawCueLine = false
        var say: [String] = []
        var notes: [String] = []
        var directions: [ScreenDirection] = []
        var links: [LinkCue] = []
        var takeCount = 0
        var linkedPlaylistId: UUID?
        var linkedMediaBinItemID: UUID?
        var linkedMediaFilePath: String?

        mutating func apply(_ keyword: Keyword) throws {
            switch keyword.word {
            case "TITLE":
                title = keyword.rest
            case "TYPE":
                guard let type = SegmentType(rawValue: keyword.rest) else {
                    throw OutlineScriptError.unknownSegmentType(keyword.rest)
                }
                segmentType = type
            case "START":
                start = OutlineScriptCompiler.parseDate(keyword.rest)
            case "DURATION":
                duration = TimeInterval(Int(keyword.rest) ?? 0)
            case "LOCK":
                lockHard = keyword.rest.lowercased() == "hard"
            case "TALENT":
                talentName = keyword.rest
            case "AUDIO":
                audio = keyword.rest
            case "LOWERTHIRD":
                lowerThird = keyword.rest.lowercased() == "on"
            case "CUE":
                sawCueLine = true
                if keyword.rest.lowercased() == "inherit" {
                    inheritCues = true
                    cues = []
                    return
                }
                let parts = keyword.rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let seconds = Int(parts.first.map(String.init) ?? "") ?? 0
                let message = parts.count > 1 ? String(parts[1]) : ""
                cues.append(StageCueTrigger(triggerOffsetSeconds: seconds, stageMessage: message))
            default:
                break
            }
        }

        mutating func absorbShow(_ line: String) throws {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower == "camera" {
                directions.append(ScreenDirection(kind: .camera, label: "Camera"))
                return
            }
            if lower.hasPrefix("slide ") {
                directions.append(ScreenDirection(kind: .slide, label: String(trimmed.dropFirst(6))))
                return
            }
            if lower.hasPrefix("layout ") {
                directions.append(ScreenDirection(kind: .layout, label: String(trimmed.dropFirst(7))))
                return
            }
            if lower.hasPrefix("note ") {
                directions.append(ScreenDirection(kind: .note, label: String(trimmed.dropFirst(5))))
                return
            }
            if lower.hasPrefix("url ") {
                let body = String(trimmed.dropFirst(4))
                let pieces = body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                directions.append(ScreenDirection(kind: .url, label: pieces.first ?? body, url: pieces.count > 1 ? pieces[1] : nil))
                return
            }
            if lower.hasPrefix("take ") {
                try absorbTake(String(trimmed.dropFirst(5)))
                return
            }
            directions.append(ScreenDirection(kind: .unknown, label: trimmed, rawKind: firstWord(trimmed)))
        }

        mutating func absorbTake(_ spec: String) throws {
            takeCount += 1
            if takeCount > 1 {
                throw OutlineScriptError.multipleTakes(title.isEmpty ? itemNumber : title)
            }
            let parts = spec.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2 else {
                throw OutlineScriptError.takeWithoutTarget(title.isEmpty ? itemNumber : title)
            }
            switch parts[0].lowercased() {
            case "playlist-item":
                guard let id = UUID(uuidString: parts[1]) else {
                    throw OutlineScriptError.invalidPlaylistItemID(parts[1])
                }
                linkedPlaylistId = id
                linkedMediaBinItemID = nil
                linkedMediaFilePath = nil
            case "media":
                guard let id = UUID(uuidString: parts[1]) else {
                    throw OutlineScriptError.takeWithoutTarget(parts[1])
                }
                linkedMediaBinItemID = id
                linkedPlaylistId = nil
                linkedMediaFilePath = nil
            case "file":
                linkedMediaFilePath = parts[1]
                linkedPlaylistId = nil
                linkedMediaBinItemID = nil
            default:
                throw OutlineScriptError.takeWithoutTarget(spec)
            }
        }

        mutating func absorbLink(_ line: String) throws {
            let pieces = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2 else { return }
            let speak = pieces.count > 2 && pieces[2].lowercased() == "say yes"
            let take = pieces.count > 3 && pieces[3].lowercased() == "take yes"
            if take {
                takeCount += 1
                if takeCount > 1 {
                    throw OutlineScriptError.multipleTakes(title.isEmpty ? itemNumber : title)
                }
                if linkedPlaylistId == nil && linkedMediaBinItemID == nil && (linkedMediaFilePath ?? "").isEmpty {
                    throw OutlineScriptError.takeWithoutTarget(title.isEmpty ? itemNumber : title)
                }
            }
            links.append(LinkCue(label: pieces[0], url: pieces[1], speakOnAir: speak, autoTake: take))
        }

        func makeBlock(talent: [TalentProfile], warnings: inout [String]) throws -> RundownBlock {
            if title.isEmpty { throw OutlineScriptError.missingTitle(itemNumber) }
            var block = RundownBlock(
                itemNumber: padded(itemNumber),
                title: title,
                segmentType: segmentType,
                plannedDurationSeconds: duration
            )
            block.outlineFormat = 1
            block.isHardTimeLocked = lockHard
            block.hardStartTime = start
            block.audioCue = audio
            block.autoFireLowerThirdOnStart = lowerThird
            block.scriptBody = OutlineScriptCompiler.collapseBreaks(say.joined(separator: "\n"))
            block.screenDirections = directions
            block.linkCues = links
            block.referenceNotes = OutlineScriptCompiler.collapseBreaks(notes.joined(separator: "\n"))
            block.videoCue = OutlineScriptCompiler.videoCueSummary(directions)
            block.linkedPlaylistId = linkedPlaylistId
            block.linkedMediaBinItemID = linkedMediaBinItemID
            block.linkedMediaFilePath = linkedMediaFilePath
            if let layout = directions.first(where: { $0.kind == .layout }) {
                block.stageDisplayLayoutId = layout.label
            }
            if !talentName.isEmpty {
                guard let match = talent.first(where: { $0.fullName.caseInsensitiveCompare(talentName) == .orderedSame }) else {
                    throw OutlineScriptError.unknownTalent(talentName)
                }
                block.assignedTalentIds = [match.id]
            }
            if inheritCues {
                block.customCueTriggers = []
            } else if !cues.isEmpty {
                block.customCueTriggers = cues
            } else if duration < 90 {
                warnings.append("\(block.itemNumber) \(block.title) is under 90 seconds with no CUE line. Using NEXT MINUTE at 0 instead of the one-minute warning.")
                block.customCueTriggers = OutlineScriptCompiler.explicitShortCues(inheriting: [])
            }
            return block
        }
    }

    private static func applyDocumentLine(_ keyword: Keyword, to document: inout ProgramDocumentModel) throws {
        switch keyword.word {
        case "SHOW":
            document.showTitle = keyword.rest
        case "DATE":
            if let date = parseDate(keyword.rest) { document.scheduledDate = date }
        case "HARDSTART":
            if let date = parseDate(keyword.rest) { document.hardStartTime = date }
        case "FORMAT":
            document.outlineFormat = Int(keyword.rest) ?? 1
        default:
            break
        }
    }

    private static func keyword(on line: String) -> Keyword? {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        let word = first.uppercased()
        guard sectionWords.contains(word) else { return nil }
        return Keyword(word: word, rest: parts.count > 1 ? parts[1] : "")
    }

    private static func legacySections(in body: String) -> [String: String] {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let header = legacyHeader(trimmed) {
                current = header
                sections[header] = []
                continue
            }
            guard let current else { continue }
            sections[current, default: []].append(line)
        }
        return sections.mapValues { collapseBreaks($0.joined(separator: "\n")) }
    }

    private static func legacyHeader(_ line: String) -> String? {
        let known = ["KALEEL:", "ON SCREEN:", "LINKS TO SAY:", "REFERENCE:"]
        guard known.contains(line) else { return nil }
        return String(line.dropLast())
    }

    private static func sentences(in prose: String) -> [String] {
        prose
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    private static func cameraSplit(_ sentence: String) -> String? {
        let lower = sentence.lowercased()
        guard lower == "camera" || lower.hasPrefix("camera,") || lower.hasPrefix("camera ") else { return nil }
        if lower == "camera" { return "" }
        var rest = sentence.dropFirst("Camera".count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(",") {
            rest = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return String(rest)
    }

    private static func slideLabel(_ sentence: String) -> String {
        if let colon = sentence.firstIndex(of: ":") {
            let after = sentence[sentence.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { return after }
        }
        return sentence
    }

    private static func urls(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>]+"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            var url = ns.substring(with: $0.range)
            while let last = url.last, ",.;".contains(last) {
                url.removeLast()
            }
            return url
        }
    }

    private static func firstURL(in text: String) -> String? {
        urls(in: text).first
    }

    private static func bareAddress(_ url: String) -> String {
        var bare = url
        for prefix in ["https://", "http://"] where bare.lowercased().hasPrefix(prefix) {
            bare.removeFirst(prefix.count)
        }
        while bare.hasSuffix("/") { bare.removeLast() }
        return bare
    }

    private static func labelByRemoving(_ url: String, from sentence: String) -> String {
        var label = sentence.replacingOccurrences(of: url, with: " ")
        label = label.replacingOccurrences(of: "  ", with: " ")
        return label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstWord(_ line: String) -> String {
        line.split(separator: " ").first.map(String.init) ?? line
    }

    private static func padded(_ item: String) -> String {
        if let number = Int(item) { return String(format: "%03d", number) }
        return item
    }

    static func collapseBreaks(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var collapsed: [String] = []
        var blank = false
        for line in lines {
            if line.isEmpty {
                if !blank { collapsed.append("") }
                blank = true
            } else {
                collapsed.append(line)
                blank = false
            }
        }
        return collapsed.joined(separator: "\n")
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)
    }
}

/// What Next puts on the program. The clock does not advance on its own.
enum RundownPictureKind: String, Equatable, Sendable {
    case camera
    case display
}

struct RundownProgramCut: Equatable, Sendable {
    var picture: RundownPictureKind?
    /// Copyable page for this minute. Shown when the picture is the screen.
    var pageURL: String?

    var effectivePicture: RundownPictureKind? {
        if let picture { return picture }
        return pageURL == nil ? nil : .display
    }

    static func resolve(_ block: RundownBlock) -> RundownProgramCut {
        RundownProgramCut(picture: picture(in: block), pageURL: pageURL(in: block))
    }

    private static func picture(in block: RundownBlock) -> RundownPictureKind? {
        for direction in block.screenDirections {
            switch direction.kind {
            case .camera:
                return .camera
            case .url, .slide:
                return .display
            case .note, .layout:
                continue
            case .unknown:
                let word = (direction.rawKind ?? direction.label)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if word == "display" || word == "screen" || word.hasPrefix("display ") || word.hasPrefix("screen ") {
                    return .display
                }
            }
        }
        return nil
    }

    private static func pageURL(in block: RundownBlock) -> String? {
        let cues = block.linkCues.filter { $0.autoTake } + block.linkCues.filter { !$0.autoTake }
        for cue in cues {
            if let url = PromptWebsiteURL.canonical(cue.url) { return url }
        }
        for direction in block.screenDirections where direction.kind == .url {
            if let raw = direction.url, let url = PromptWebsiteURL.canonical(raw) { return url }
            if let url = PromptWebsiteURL.canonical(direction.label) { return url }
        }
        return nil
    }
}

enum RundownPageMedia {
    static let id = UUID(uuidString: "C0FFEE00-0000-4000-8000-0000000000A1")!
}

/// One desktop viewport for the minute page on program and stream.
enum ProgramPageViewport {
    static let width: CGFloat = 1920
    static let height: CGFloat = 1080

    static func fitScale(in size: CGSize) -> CGFloat {
        guard size.width > 1, size.height > 1 else { return 1 }
        return min(size.width / width, size.height / height)
    }

    static func displayHost(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return urlString
        }
        return host
    }

    #if os(macOS)
    private static var loadingPlateCache: [String: CVPixelBuffer] = [:]

    /// Neutral program plate while a page raster is still loading (stream + Audience).
    static func loadingPlatePixelBuffer(label: String) -> CVPixelBuffer? {
        let cacheKey = "\(label)#v2"
        if let cached = loadingPlateCache[cacheKey] { return cached }
        let width = Int(Self.width)
        let height = Int(Self.height)
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let title = label as NSString
        let subtitle = "Loading page…" as NSString
        let titleFont = NSFont.systemFont(ofSize: 36, weight: .semibold)
        let subtitleFont = NSFont.systemFont(ofSize: 22, weight: .regular)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: subtitleFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let titleSize = title.size(withAttributes: titleAttrs)
        let subtitleSize = subtitle.size(withAttributes: subtitleAttrs)
        let blockH = titleSize.height + 10 + subtitleSize.height
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let midY = CGFloat(height) * 0.5
        let subtitleOrigin = NSPoint(
            x: (CGFloat(width) - subtitleSize.width) / 2,
            y: midY - blockH / 2
        )
        let titleOrigin = NSPoint(
            x: (CGFloat(width) - titleSize.width) / 2,
            y: subtitleOrigin.y + subtitleSize.height + 10
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        subtitle.draw(at: subtitleOrigin, withAttributes: subtitleAttrs)
        title.draw(at: titleOrigin, withAttributes: titleAttrs)
        NSGraphicsContext.restoreGraphicsState()

        loadingPlateCache[cacheKey] = pixelBuffer
        return pixelBuffer
    }
    #endif

    #if os(macOS)
    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        if #available(macOS 13.0, *) {
            config.defaultWebpagePreferences.preferredContentMode = .desktop
        }
        let web = WKWebView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            configuration: config
        )
        web.setValue(false, forKey: "drawsBackground")
        web.pageZoom = 1
        return web
    }

    /// Readable broadcast framing: fit page **width** to the viewport (up to 100% zoom). Tall pages
    /// keep legible type and show the top of the document; only short pages are centered vertically.
    static func readablePageZoom(viewWidth: Double, pageWidth: Double) -> Double {
        guard viewWidth > 1, pageWidth > 0 else { return 1 }
        let fitWidth = viewWidth / pageWidth
        return max(0.08, min(1, fitWidth))
    }

    static func fitDocument(in webView: WKWebView, completion: (() -> Void)? = nil) {
        let viewW = Double(webView.bounds.width)
        let viewH = Double(webView.bounds.height)
        guard viewW > 1, viewH > 1 else {
            completion?()
            return
        }
        let script = """
        (function(){
          var d = document.documentElement, b = document.body;
          var w = Math.max(d.scrollWidth, d.clientWidth, b ? b.scrollWidth : 0, 1);
          var h = Math.max(d.scrollHeight, d.clientHeight, b ? b.scrollHeight : 0, 1);
          return {w:w,h:h};
        })();
        """
        webView.evaluateJavaScript(script) { value, _ in
            Task { @MainActor in
                guard let dict = value as? [String: Any],
                      let pageW = dict["w"] as? Double,
                      pageW > 0 else {
                    completion?()
                    return
                }
                webView.pageZoom = readablePageZoom(viewWidth: viewW, pageWidth: pageW)
                frameDocument(in: webView, completion: completion)
            }
        }
    }

    /// After `pageZoom`, center horizontally; align to top when content is taller than the viewport.
    private static func frameDocument(in webView: WKWebView, completion: (() -> Void)?) {
        let script = """
        (function(){
          var el = document.body || document.documentElement;
          if (!el) return;
          el.style.transform = '';
          el.style.transformOrigin = 'top left';
          window.scrollTo(0, 0);
          var r = el.getBoundingClientRect();
          var dx = (window.innerWidth - r.width) / 2 - r.left;
          var dy = 0;
          if (r.height <= window.innerHeight + 1) {
            dy = (window.innerHeight - r.height) / 2 - r.top;
          } else {
            dy = -r.top;
          }
          if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) {
            el.style.transform = 'translate(' + dx + 'px,' + dy + 'px)';
          }
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in
            Task { @MainActor in
                completion?()
            }
        }
    }
    #endif
}
