import Foundation

/// AI compose (Phase 0-1). AI proposes slides as a patch. The operator applies it.
/// Never touches Take, destinations, streams, or LiveKit.
enum AIComposeFlags {
    static let aiComposeV1Key = "proshow.aiComposeV1"

    /// Off by default. Turn on with `defaults write <bundle id> proshow.aiComposeV1 -bool YES`.
    static var aiComposeV1: Bool {
        get { UserDefaults.standard.bool(forKey: aiComposeV1Key) }
        set { UserDefaults.standard.set(newValue, forKey: aiComposeV1Key) }
    }
}

extension ProShowFeatureFlags {
    static var aiComposeV1Key: String { AIComposeFlags.aiComposeV1Key }
    static var aiComposeV1: Bool {
        get { AIComposeFlags.aiComposeV1 }
        set { AIComposeFlags.aiComposeV1 = newValue }
    }
}

struct ComposeRecipe: Codable, Hashable, Sendable {
    var id: String
    var name: String

    static let all: [ComposeRecipe] = [
        ComposeRecipe(id: "title", name: "Title"),
        ComposeRecipe(id: "lower_third", name: "Lower third"),
        ComposeRecipe(id: "qa", name: "Q&A"),
        ComposeRecipe(id: "chapter_cta", name: "Chapter CTA"),
        ComposeRecipe(id: "talk_section", name: "Talk section"),
        ComposeRecipe(id: "freeform", name: "Freeform"),
    ]
}

struct ComposeDesignMeta: Codable, Hashable, Sendable {
    var canvases: [String]
    var tokenSet: String?
    var grid: String?
    var backgroundToken: String?
    var accentToken: String?
    var notes: String?
    /// When true, Phone 9:16 may be omitted. Default is dual Stream + Phone.
    var streamOnly: Bool? = nil
}

struct ComposeRundownBlock: Codable, Hashable, Sendable {
    var title: String
    var start: String?
    var minutes: Int?
    var notes: String?
}

struct ComposePatch: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var recipeId: String
    var summary: String
    var slides: [Slide]
    var rundownBlocks: [ComposeRundownBlock]?
    var designMeta: ComposeDesignMeta

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, recipeId, summary, slides, rundownBlocks, designMeta
    }
}

struct ComposeRequest: Codable, Sendable {
    var provider: String
    var recipeId: String?
    var prompt: String?
    var patch: ComposePatch?
}

struct ApplyRequest: Codable, Sendable {
    var patch: ComposePatch
    var confirm: Bool
    var groupName: String?
}

enum ComposeError: Error, Equatable {
    case invalidJSON(String)
    case unknownKeys([String])
    case schemaVersion(Int)
    case unknownRecipe(String)
    case noSlides
    case missingStreamCanvas
    case missingPhoneCanvas
    case offTokenColor(String)
    case unknownProvider(String)
    case missingPatch

    var code: String {
        switch self {
        case .invalidJSON: "invalid_json"
        case .unknownKeys: "unknown_keys"
        case .schemaVersion: "bad_schema_version"
        case .unknownRecipe: "unknown_recipe"
        case .noSlides: "no_slides"
        case .missingStreamCanvas: "missing_stream_canvas"
        case .missingPhoneCanvas: "missing_phone_canvas"
        case .offTokenColor: "off_token_color"
        case .unknownProvider: "unknown_provider"
        case .missingPatch: "missing_patch"
        }
    }

    var detail: String {
        switch self {
        case let .invalidJSON(text): text
        case let .unknownKeys(keys): keys.joined(separator: ",")
        case let .schemaVersion(v): "Need v\(ComposePatch.currentSchemaVersion), got v\(v)"
        case let .unknownRecipe(id): id
        case .noSlides: "Patch has no slides"
        case .missingStreamCanvas: "designMeta.canvases needs stream"
        case .missingPhoneCanvas: "designMeta.canvases needs phone (or set streamOnly true when the operator asked for Stream-only)"
        case let .offTokenColor(hex): hex
        case let .unknownProvider(p): p
        case .missingPatch: "Practice needs an inline patch"
        }
    }
}

enum ComposeCodec {
    /// Strict decode: top-level patch keys must be known. Used by Control API fixtures.
    static func decodePatch(_ data: Data) throws -> ComposePatch {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try checkKeys(object)
        }
        return try decodePatchObject(data)
    }

    /// Agent / model path: accept messy payloads, strip fences, extract `{...}`, tolerate stringified JSON.
    /// Never crashes the desk. Returns a clear ComposeError with a truncated preview.
    static func decodePatchFlexible(_ raw: Any, stripUnknownKeys: Bool = true) throws -> (patch: ComposePatch, notes: [String]) {
        var notes: [String] = []
        let data: Data
        do {
            data = try coerceToPatchData(raw, notes: &notes)
        } catch let error as ComposeError {
            throw error
        } catch {
            throw ComposeError.invalidJSON(String(describing: error))
        }
        var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if stripUnknownKeys {
            let known = Set(ComposePatch.CodingKeys.allCases.map(\.rawValue))
            let extra = object.keys.filter { !known.contains($0) }.sorted()
            if !extra.isEmpty {
                notes.append("stripped_unknown_keys:\(extra.joined(separator: ","))")
                for key in extra { object.removeValue(forKey: key) }
            }
        } else {
            try checkKeys(object)
        }
        // Models don't send ids; Apply assigns fresh ones anyway. Fill them so decoding never fails.
        if var slides = object["slides"] as? [[String: Any]] {
            var filled = 0
            for index in slides.indices {
                if slides[index]["id"] == nil { slides[index]["id"] = UUID().uuidString; filled += 1 }
                if var elements = slides[index]["elements"] as? [[String: Any]] {
                    for e in elements.indices where elements[e]["id"] == nil { elements[e]["id"] = UUID().uuidString }
                    slides[index]["elements"] = elements
                }
            }
            if filled > 0 { notes.append("filled_slide_ids:\(filled)") }
            object["slides"] = slides
        }
        let cleaned = try JSONSerialization.data(withJSONObject: object)
        let patch = try decodePatchObject(cleaned)
        return (patch, notes)
    }

    private static func decodePatchObject(_ data: Data) throws -> ComposePatch {
        do {
            return try JSONDecoder().decode(ComposePatch.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(280), as: UTF8.self)
            throw ComposeError.invalidJSON("\(error) | preview=\(preview)")
        }
    }

    /// Coerce tool-arg `patch` (dict, string, Data) into JSON object bytes.
    static func coerceToPatchData(_ raw: Any, notes: inout [String]) throws -> Data {
        if let data = raw as? Data {
            return try sanitizeJSONData(data, notes: &notes)
        }
        if let dict = raw as? [String: Any] {
            guard JSONSerialization.isValidJSONObject(dict) else {
                throw ComposeError.invalidJSON("patch object is not JSON-serializable | preview=\(previewAny(dict))")
            }
            return try JSONSerialization.data(withJSONObject: dict)
        }
        if let string = raw as? String {
            notes.append("patch_was_string")
            return try sanitizeJSONData(Data(string.utf8), notes: &notes)
        }
        if let number = raw as? NSNumber {
            throw ComposeError.invalidJSON("patch must be an object, got number \(number)")
        }
        throw ComposeError.invalidJSON("patch must be an object or JSON string | preview=\(previewAny(raw))")
    }

    /// Strip markdown fences, extract the first JSON object, repair light damage.
    static func sanitizeJSONData(_ data: Data, notes: inout [String]) throws -> Data {
        var text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            notes.append("stripped_markdown_fence")
            text = stripMarkdownFence(text)
        }
        // Some models wrap the patch again: {"patch":{...}}
        if let unwrapped = unwrapNestedPatch(text) {
            notes.append("unwrapped_nested_patch")
            text = unwrapped
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            let sliced = String(text[start...end])
            if sliced != text {
                notes.append("extracted_object_span")
                text = sliced
            }
        }
        // Common damage: trailing commas before } or ]
        let repaired = text
            .replacingOccurrences(of: ",\\s*}", with: "}", options: .regularExpression)
            .replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)
        if repaired != text {
            notes.append("repaired_trailing_commas")
            text = repaired
        }
        guard let out = text.data(using: .utf8) else {
            throw ComposeError.invalidJSON("UTF-8 encode failed | preview=\(String(text.prefix(240)))")
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: out)
            guard obj is [String: Any] else {
                throw ComposeError.invalidJSON("Top-level JSON must be an object | preview=\(String(text.prefix(240)))")
            }
            return out
        } catch {
            throw ComposeError.invalidJSON("\(error) | preview=\(String(text.prefix(240)))")
        }
    }

    private static func stripMarkdownFence(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unwrapNestedPatch(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.count == 1,
              let inner = object["patch"]
        else { return nil }
        if let dict = inner as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        if let s = inner as? String { return s }
        return nil
    }

    private static func previewAny(_ value: Any) -> String {
        if let s = value as? String { return String(s.prefix(240)) }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let s = String(data: data, encoding: .utf8) {
            return String(s.prefix(240))
        }
        return String(describing: value).prefix(240).description
    }

    static func checkKeys(_ object: [String: Any]) throws {
        let known = Set(ComposePatch.CodingKeys.allCases.map(\.rawValue))
        let extra = object.keys.filter { !known.contains($0) }.sorted()
        if !extra.isEmpty { throw ComposeError.unknownKeys(extra) }
    }

    static func patchData(in body: Data?, key: String = "patch") throws -> (object: [String: Any], patch: Data?) {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { throw ComposeError.invalidJSON("Body is not a JSON object") }
        guard let inner = object[key] else { return (object, nil) }
        var notes: [String] = []
        let data = try coerceToPatchData(inner, notes: &notes)
        return (object, data)
    }

    static func encode(_ patch: ComposePatch) -> Any {
        guard let data = try? JSONEncoder().encode(patch),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return NSNull() }
        return object
    }
}

enum ComposeDesignValidator {
    static let allowedBackgrounds: Set<String> = [
        "#121214", "#1B1B1F", "#161618", "#25252A", "#000000", "#6B9FE0",
        // Broadcast pack + news accents (Rollup lime, Bloomberg yellow/red, Milk Road yellow, paper white).
        "#C6FF3D", "#F5C518", "#FFD60A", "#E5322D", "#FFFFFF", "#1A1C22", "#0B0B0D", "#F4F1EA", "#0E2A47", "#9AA3B2",
    ]

    static func validate(_ patch: ComposePatch) throws {
        guard patch.schemaVersion == ComposePatch.currentSchemaVersion else {
            throw ComposeError.schemaVersion(patch.schemaVersion)
        }
        guard ComposeRecipe.all.contains(where: { $0.id == patch.recipeId }) else {
            throw ComposeError.unknownRecipe(patch.recipeId)
        }
        guard !patch.slides.isEmpty else { throw ComposeError.noSlides }
        let canvases = patch.designMeta.canvases.map { $0.lowercased() }
        guard canvases.contains("stream") else {
            throw ComposeError.missingStreamCanvas
        }
        let streamOnly = patch.designMeta.streamOnly == true
        if !streamOnly && !canvases.contains("phone") {
            throw ComposeError.missingPhoneCanvas
        }
        for slide in patch.slides {
            let hex = slide.backgroundHex.trimmingCharacters(in: .whitespaces)
            if hex.isEmpty { continue }
            let allowed = Set(allowedBackgrounds.map { $0.uppercased() })
            if !allowed.contains(hex.uppercased()) {
                throw ComposeError.offTokenColor(hex)
            }
        }
    }
}

protocol ComposeProvider {
    var id: String { get }
    func compose(_ request: ComposeRequest) throws -> ComposePatch
}

/// Practice provider: echoes an inline patch after validation. No network.
struct LocalPracticeProvider: ComposeProvider {
    let id = "practice"

    func compose(_ request: ComposeRequest) throws -> ComposePatch {
        guard let patch = request.patch else { throw ComposeError.missingPatch }
        try ComposeDesignValidator.validate(patch)
        return patch
    }
}

enum AIComposeAPI {
    static let draftGroupName = "AI Draft"

    static func flagOff() -> (Int, String) {
        (409, ControlJSON.encode(["ok": false, "error": "ai_compose_off", "message": "AI compose is off"]))
    }

    static func failure(_ error: Error) -> (Int, String) {
        let compose = error as? ComposeError ?? .invalidJSON(String(describing: error))
        return (400, ControlJSON.encode(["ok": false, "error": compose.code, "message": compose.detail]))
    }

    static func recipes() -> (Int, String) {
        (200, ControlJSON.encode([
            "ok": true,
            "recipes": ComposeRecipe.all.map { ["id": $0.id, "name": $0.name] },
        ]))
    }

    static func compose(body: Data?) -> (Int, String) {
        do {
            let (object, patchData) = try ComposeCodec.patchData(in: body)
            let provider = (object["provider"] as? String) ?? "practice"
            guard provider == "practice" else { throw ComposeError.unknownProvider(provider) }
            guard let patchData else { throw ComposeError.missingPatch }
            let patch = try ComposeCodec.decodePatch(patchData)
            let request = ComposeRequest(
                provider: provider,
                recipeId: object["recipeId"] as? String,
                prompt: object["prompt"] as? String,
                patch: patch
            )
            let result = try LocalPracticeProvider().compose(request)
            return (200, ControlJSON.encode([
                "ok": true,
                "provider": provider,
                "slide_count": result.slides.count,
                "patch": ComposeCodec.encode(result),
            ]))
        } catch {
            return failure(error)
        }
    }
}

extension ShowController {
    /// Appends patch slides to a named group. Fresh ids so repeat applies never collide.
    /// Ensures a Phone 9:16 board exists unless the patch is stream-only.
    @discardableResult
    func applyComposePatch(_ patch: ComposePatch, groupName: String = AIComposeAPI.draftGroupName) throws -> AgentSlidePlacement {
        try ComposeDesignValidator.validate(patch)
        let wantPhone = patch.designMeta.streamOnly != true
        let slides = patch.slides.map { source -> Slide in
            var slide = source
            slide.id = UUID()
            slide.elements = slide.elements.map { element in
                var copy = element
                copy.id = UUID()
                return copy
            }
            if wantPhone {
                Self.ensurePhoneEditorCanvas(on: &slide, backgroundHex: slide.backgroundHex)
            } else {
                Self.ensurePrimaryEditorCanvas(on: &slide, backgroundHex: slide.backgroundHex)
            }
            return slide
        }
        appendSlides(slides, toGroupNamed: groupName, colorHex: "#6B9FE0")
        return AgentSlidePlacement(
            groupName: groupName,
            slideIDs: slides.map(\.id),
            slideTitles: slides.map(\.title),
            showID: show.id
        )
    }

    /// Stream primary (16:9 design space) when the slide has no boards yet.
    static func ensurePrimaryEditorCanvas(on slide: inout Slide, backgroundHex: String) {
        if slide.editorCanvases.contains(where: \.isPrimary) { return }
        let primary = EditorCanvasFrame(
            id: UUID(),
            name: "Stream",
            width: CanvasConfig.width,
            height: CanvasConfig.height,
            originX: 0,
            originY: 0,
            isPrimary: true,
            backgroundEnabled: slide.backgroundEnabled,
            backgroundHex: backgroundHex.isEmpty ? "#121214" : backgroundHex
        )
        slide.editorCanvases.insert(primary, at: 0)
    }

    /// Dual-canvas default: Stream primary + Phone secondary at 2160x3840 design space.
    static func ensurePhoneEditorCanvas(on slide: inout Slide, backgroundHex: String) {
        ensurePrimaryEditorCanvas(on: &slide, backgroundHex: backgroundHex)
        let hasPhone = slide.editorCanvases.contains { $0.isPhoneArtboard }
        guard !hasPhone else { return }
        let primary = slide.editorCanvases.first(where: \.isPrimary) ?? slide.editorCanvases[0]
        let phone = EditorCanvasFrame(
            id: UUID(),
            name: "Phone",
            width: 2160,
            height: 3840,
            originX: primary.originX + primary.width + 480,
            originY: primary.originY,
            isPrimary: false,
            backgroundEnabled: true,
            backgroundHex: backgroundHex.isEmpty ? "#121214" : backgroundHex
        )
        slide.editorCanvases.append(phone)
    }

    func handleAICompose(method: String, parts: [String], body: Data?) -> (Int, String)? {
        guard parts.count == 3, parts[0] == "v1", parts[1] == "ai" else { return nil }
        let route = parts[2]
        guard ["recipes", "compose", "apply"].contains(route) else { return nil }
        guard ProShowFeatureFlags.aiComposeV1 else { return AIComposeAPI.flagOff() }
        switch (method, route) {
        case ("GET", "recipes"):
            return AIComposeAPI.recipes()
        case ("POST", "compose"):
            return AIComposeAPI.compose(body: body)
        case ("POST", "apply"):
            do {
                let (object, patchData) = try ComposeCodec.patchData(in: body)
                guard (object["confirm"] as? Bool) == true else {
                    return (400, ControlJSON.encode(["ok": false, "error": "confirm_required", "message": "Send confirm true to apply"]))
                }
                guard let patchData else { throw ComposeError.missingPatch }
                let patch = try ComposeCodec.decodePatch(patchData)
                let group = (object["groupName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? AIComposeAPI.draftGroupName
                if show.id == ProgramOutlinePresentation.showID {
                    return (409, ControlJSON.encode(["ok": false, "error": "program_outline", "message": "Open a show first"]))
                }
                let placement = try applyComposePatch(patch, groupName: group)
                return (200, ControlJSON.encode([
                    "ok": true,
                    "group": placement.groupName,
                    "slide_count": placement.slideIDs.count,
                    "slide_ids": placement.slideIDs.map(\.uuidString),
                    "slide_titles": placement.slideTitles,
                    "deep_link": placement.deepLink,
                    "label": placement.label,
                    "show_id": show.id.uuidString,
                ]))
            } catch {
                return AIComposeAPI.failure(error)
            }
        default:
            return (405, #"{"ok":false,"error":"method_not_allowed"}"#)
        }
    }
}
