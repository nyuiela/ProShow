import Foundation
import CryptoKit

// MARK: - Events (desk stream)

/// One update from the agent to the desk. `seq` is monotonic per session.
struct AgentEvent: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case turnStarted(turnID: String)
        case delta(String)
        case toolCall(name: String, callID: String)
        case toolResult(name: String, callID: String, ok: Bool, summary: String)
        case confirmRequired(tool: String, reason: String)
        case draftReady(slideCount: Int, summary: String)
        case slidesCreated(groupName: String, slideCount: Int, label: String, deepLink: String, slideIDs: [UUID])
        case contextPackUpdated(version: String, previous: String)
        case done(text: String)
        case cancelled
        case error(String)

        var name: String {
            switch self {
            case .turnStarted: "turn_started"
            case .delta: "delta"
            case .toolCall: "tool_call"
            case .toolResult: "tool_result"
            case .confirmRequired: "confirm_required"
            case .draftReady: "draft_ready"
            case .slidesCreated: "slides_created"
            case .contextPackUpdated: "context_pack_updated"
            case .done: "done"
            case .cancelled: "cancelled"
            case .error: "error"
            }
        }
    }

    var id: Int { seq }
    let seq: Int
    let ts: Date
    let kind: Kind

    var json: [String: Any] {
        var data: [String: Any] = ["v": 1, "seq": seq, "type": kind.name, "ts": ISO8601DateFormatter().string(from: ts)]
        switch kind {
        case let .turnStarted(id): data["turnId"] = id
        case let .delta(t): data["text"] = t
        case let .toolCall(n, c): data["tool"] = n; data["callId"] = c
        case let .toolResult(n, c, ok, s): data["tool"] = n; data["callId"] = c; data["ok"] = ok; data["summary"] = s
        case let .confirmRequired(t, r): data["tool"] = t; data["reason"] = r
        case let .draftReady(n, s): data["slideCount"] = n; data["summary"] = s
        case let .slidesCreated(g, n, label, link, ids):
            data["group"] = g; data["slideCount"] = n; data["label"] = label; data["deepLink"] = link
            data["slideIds"] = ids.map(\.uuidString)
        case let .contextPackUpdated(v, p): data["version"] = v; data["previousVersion"] = p
        case let .done(t): data["text"] = t
        case .cancelled: break
        case let .error(m): data["message"] = m
        }
        return data
    }
}

// MARK: - Chat wire types (OpenAI compatible)

struct AgentToolCall: Hashable, Sendable {
    var id: String
    var name: String
    var arguments: String
    /// Provider stopped mid-call (finish_reason == "length"); arguments are incomplete.
    var truncated: Bool = false
}

struct AgentMessage: Hashable, Sendable {
    enum Role: String, Sendable { case system, user, assistant, tool }
    var role: Role
    var content: String?
    var toolCalls: [AgentToolCall] = []
    var toolCallID: String? = nil

    var wire: [String: Any] {
        var out: [String: Any] = ["role": role.rawValue]
        out["content"] = content ?? NSNull()
        if !toolCalls.isEmpty {
            out["tool_calls"] = toolCalls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
            }
        }
        if let toolCallID { out["tool_call_id"] = toolCallID }
        return out
    }
}

// MARK: - Tools

struct AgentToolDefinition: Sendable {
    var name: String
    var description: String
    /// JSON schema as a JSON string so the struct stays Sendable and hashable.
    var parametersJSON: String
    /// Live, Take, Hold, destinations. Never executes. Always needs the operator.
    var operatorGated: Bool = false

    var wire: [String: Any] {
        let params = (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) ?? ["type": "object", "properties": [:]]
        return ["type": "function", "function": ["name": name, "description": description, "parameters": params]]
    }
}

struct AgentToolOutcome: Sendable {
    var result: String
    var ok: Bool
    var summary: String
    var needsConfirmation: String? = nil
    var draft: ComposePatch? = nil
}

enum AgentToolRegistry {
    static let maxToolRounds = 24
    /// Consecutive failed compose calls before the turn is failed for the operator.
    static let maxComposeFailures = 4

    private static let empty = #"{"type":"object","properties":{},"additionalProperties":false}"#
    private static let patchArg = #"{"type":"object","properties":{"patch":{"type":"object","description":"ComposePatch v1: schemaVersion, recipeId, summary, slides, rundownBlocks, designMeta"}},"required":["patch"]}"#
    private static let stageArg = #"{"type":"object","properties":{"patch":{"type":"object","description":"ComposePatch v1 with 1-3 slides. Omit to stage the last validated patch."},"patchId":{"type":"string","description":"id returned by compose_patch_validate; stages that patch without resending it"},"append":{"type":"boolean","description":"Add these slides to the draft already staged this turn (default true after the first batch)"},"groupName":{"type":"string","description":"Group the slides land in after Apply, e.g. the show name"}}}"#

    static let all: [AgentToolDefinition] = [
        .init(name: "get_project_context", description: "Live project context: canvas sizes, Stream and Phone lanes, theme tokens, fonts in use, groups, assets, roles. Call first.", parametersJSON: empty),
        .init(name: "list_tools", description: "List every tool with its schema and whether it needs the operator.", parametersJSON: empty),
        .init(name: "get_context_pack_status", description: "Context pack version for this session vs live. Use when history may describe stale tools or settings.", parametersJSON: empty),
        .init(name: "list_assets", description: "Images and media already in the project, with slide and group names.", parametersJSON: empty),
        .init(name: "list_templates", description: "Template and recipe ids for inspiration only. You may invent layouts that follow the guide.", parametersJSON: empty),
        .init(name: "design_guide", description: "Full ProShow creative design guide (long). Only call when the built-in rules are not enough.", parametersJSON: empty),
        .init(name: "templates_list", description: "Broadcast/news template catalog: id, name, description, layout regions, editable text slots with defaults, canvases (Stream 16:9 + Phone 9:16). Starting points, not limits.", parametersJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Optional: one template id to get its full slot list"}}}"#),
        .init(name: "template_instantiate", description: "Build one rich dual-canvas slide (Stream + Phone reflow) from a template, fill slots, restyle, edit/remove/add elements. By default stages it straight into the draft (append). Use templateId blank + addElements for fully custom layouts.", parametersJSON: #"{"type":"object","properties":{"templateId":{"type":"string"},"title":{"type":"string"},"slots":{"type":"object","description":"slot name -> text, e.g. {\"Headline\":\"...\",\"Host Name\":\"Kaleel\"}"},"style":{"type":"object","properties":{"accent":{"type":"string"},"background":{"type":"string"},"text":{"type":"string"}}},"edits":{"type":"object","description":"element name -> {text,color,fill,fontSize,opacity,frame:{x,y,w,h fractions}}"},"remove":{"type":"array","items":{"type":"string"},"description":"element names to delete"},"addElements":{"type":"array","items":{"type":"object","description":"{kind: text|rect|video, name, text, x,y,w,h (fractions of Stream 16:9), fill, color, size (px at 3840 wide), weight, align, radius, border, phone:{x,y,w,h,size} optional}"}},"notes":{"type":"string"},"streamOnly":{"type":"boolean"},"stage":{"type":"boolean","description":"default true: append to the draft now"},"groupName":{"type":"string"}},"required":["templateId"]}"#),
        .init(name: "compose_patch_validate", description: "Validate a ComposePatch against schema, tokens and canvas rules. Returns errors to fix.", parametersJSON: patchArg),
        .init(name: "compose_patch_apply_preview", description: "Stage a validated ComposePatch as the desk draft. The operator reviews and taps Apply. Does not change the show. Large shows: stage in batches of 1-3 slides with append true, or pass patchId from validate.", parametersJSON: stageArg),
        .init(name: "import_slides", description: "Ask the operator to import a deck (PPTX, Key, PDF) as full-frame slides.", parametersJSON: empty, operatorGated: true),
        .init(name: "take", description: "Send Preview to Program. Operator only.", parametersJSON: empty, operatorGated: true),
        .init(name: "hold", description: "Hold Program. Operator only.", parametersJSON: empty, operatorGated: true),
        .init(name: "arm_destinations", description: "Arm YouTube, LinkedIn, X or RTMP. Operator only.", parametersJSON: empty, operatorGated: true),
    ]

    static func definition(_ name: String) -> AgentToolDefinition? { all.first { $0.name == name } }

    static var catalogDigest: String {
        AgentContextPack.shortHash(all.map { "\($0.name)|\($0.parametersJSON)|\($0.operatorGated)" }.sorted().joined(separator: "\n"))
    }

    static var catalogJSON: [[String: Any]] {
        all.map { ["name": $0.name, "description": $0.description, "operatorGated": $0.operatorGated] }
    }
}

// MARK: - Prompt packs

enum AgentPromptPacks {
    static let designBriefResource = "PROSHOW_CREATIVE_DESIGN_AGENT"

    /// Hot override folder: ~/Library/Application Support/ProShow/Agent/*.md. Non-empty files replace bundled packs.
    static var overrideDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ProShow/Agent", isDirectory: true)
    }

    static func designBrief() -> String {
        if let text = readOverride("design.md") { return text }
        if let url = Bundle.main.url(forResource: designBriefResource, withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return fallbackBrief
    }

    static func readOverrideDesign() -> String? { readOverride("design.md") }

    static func toolsGuide() -> String { readOverride("tools.md") ?? defaultToolsGuide }
    static func releaseNotes() -> String? { readOverride("release-notes.md") }

    private static func readOverride(_ name: String) -> String? {
        let url = overrideDirectory.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let fallbackBrief = """
    # ProShow creative design agent
    You design broadcast slides for ProShow. Follow the contract: ComposePatch v1.
    Default: author BOTH Stream 16:9 and Phone 9:16 (designMeta.canvases = ["stream","phone"]).
    Only skip Phone when the operator explicitly says Stream-only or no Phone (then set designMeta.streamOnly = true and canvases = ["stream"]).
    Use graphite #121214 backgrounds and the accent #6B9FE0 unless the theme says otherwise. Keep text inside safe margins (5 percent).
    Genres (news desk, lower third, mosaic, keynote, workshop) are vocabulary, not a menu. Explain bends in `summary`.
    """

    /// Built-in design rules (kept short: sent every call). Full guide via design_guide tool.
    static let designRules = """
    # ProShow design agent
    You design ORIGINAL broadcast slides. Default path: template_instantiate with templateId "blank" + addElements (one call per slide), or a raw ComposePatch.
    Templates (templates_list) are optional inspiration. Use one ONLY when the operator names a template or asks for one. Never copy a template or an existing slide in the show.
    References: Bloomberg TV graphics, Apple HIG, Swiss/International grid, FT, Stripe. Restraint over decoration.

    ## Rules (defaults unless the operator overrides)
    - 12-column grid. Margins: Stream 160 px left/right, 120 px top/bottom (3840x2160). Phone 120 px (2160x3840).
    - Spacing scale only: 8, 16, 24, 48, 96 px (multiples allowed for big gaps).
    - Per slide: max 2 font weights, max 3 font sizes. Clear hierarchy: label < body < headline.
    - Accent color on at most 2 elements per slide. Everything else graphite/white/gray.
    - Flush left. No centered body text. No gradients, shadows, emoji, buzzwords.
    - Headlines under 7 words.
    - Variety: within one request no two slides share the same layout structure (vary column split, card count, alignment axis, image/text ratio). Don't reproduce slides already in the show.
    - Dual canvas by default: give every addElements item a `phone` frame designed for 9:16 (stack, don't shrink).
    - Graphite #121214 background, accent #6B9FE0 unless the theme or operator says otherwise.

    ## Self-check before replying
    For each slide confirm: grid + margins, spacing scale, ≤2 weights, ≤3 sizes, ≤2 accents, headline <7 words, flush left, unique layout, phone frames present. Fix and re-stage anything that fails; tools also return `lint` issues.
    """

    static let defaultToolsGuide = """
    # Tools
    1. Call get_project_context before you design.
    2. Draft a ComposePatch. Element x and y are fractions of the canvas (0 to 1). Fonts and sizes come from context.
    2a. Default: template_instantiate {templateId:"blank", title, addElements:[...]} per slide. Each call stages one dual-canvas slide; no giant JSON.
    2b. Every build slide needs hierarchy (label, headline, supporting rules/plates/cards). A single text element is rejected unless the operator asked for minimal.
    2c. templates_list / named templates only when the operator asks. design_guide returns the full creative guide if you need it.
    3. (Raw patches) compose_patch_validate, fix every error, then compose_patch_apply_preview (pass the same patch, or just {"patchId": id} from validate).
    3a. More than 3 slides: build in batches. Validate and stage 1-3 slides per call with "append": true until every slide is staged. Never put a whole 10-slide show in one call; it gets cut off.
    3b. If a tool returns ok false, fix the error and call it again. Never say done until apply_preview returned staged true for every slide.
    3c. For a named show, pass "groupName" so slides land in their own group.
    4. Never call take, hold, arm_destinations. They need the operator and do nothing for you.
    5. Keep replies short. Say what you staged and what the operator should check.
    6. recipeId: use "freeform" for invented layouts.
    7. Tool argument `patch` must be a raw JSON object only. No markdown fences, no prose around it, no stringified JSON.
    8. Default canvases are ["stream","phone"]. Set designMeta.streamOnly true only when the operator asks for Stream-only.
    9. After staging, tell the operator the draft will land in group "AI Draft" so they can find it after Apply.
    """
}

// MARK: - Context pack

struct AgentContextPack: Sendable {
    var version: String
    var contextJSON: String
    var releaseNotes: String?

    static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// Version covers teaching packs, tool catalog and project settings. Show content is excluded so edits do not thrash it.
    static func build(context: [String: Any], settingsKey: String) -> AgentContextPack {
        let brief = AgentPromptPacks.readOverrideDesign() ?? AgentPromptPacks.designRules
        let tools = AgentPromptPacks.toolsGuide()
        let notes = AgentPromptPacks.releaseNotes()
        let version = shortHash([shortHash(brief), shortHash(tools), notes ?? "", AgentToolRegistry.catalogDigest, settingsKey].joined(separator: "|"))
        let data = (try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])) ?? Data("{}".utf8)
        return AgentContextPack(version: version, contextJSON: String(decoding: data, as: UTF8.self), releaseNotes: notes)
    }

    func systemPrompt() -> String {
        """
        \(AgentPromptPacks.readOverrideDesign() ?? AgentPromptPacks.designRules)

        \(AgentPromptPacks.toolsGuide())

        # Context pack
        version: \(version)
        Live project context (JSON):
        \(contextJSON)
        """
    }

    static func freshnessNote(previous: String, current: String, releaseNotes: String?) -> String {
        var text = "[Context pack updated] \(previous) -> \(current). Tools, guide or project settings changed. Trust the live context and tools over earlier messages."
        if let releaseNotes { text += "\nRelease notes:\n\(releaseNotes)" }
        return text
    }

    /// Operator desk notes for this turn only. Never persisted into history.
    static func deskUpdateBlock(_ note: String) -> String {
        "[Desk update]\n\(note)\n[/Desk update]\nThe operator added this for this turn. Follow it over older instructions."
    }
}

/// Short ack so the desk never looks idle when the model goes straight to tools.
enum AgentFirstBeat {
    static func line(for tools: [String]) -> String {
        if tools.contains("get_project_context") { return "Reading the project." }
        if tools.contains(where: { $0.hasPrefix("compose_patch") }) { return "Checking the layout." }
        return "Working on it."
    }
}
