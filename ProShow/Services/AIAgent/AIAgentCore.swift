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
    static let elementSchema = ##"{"type":"object","required":["kind","x","y","w","h"],"properties":{"kind":{"type":"string","enum":["text","rect","video","image"],"description":"text = type; rect = plate/card/bar/rule; video = transparent camera/screen pane; image = placeholder plate"},"name":{"type":"string","description":"unique element name, e.g. Headline, Quote Card, Host Camera"},"role":{"type":"string","enum":["headline","body","label","caption"],"description":"sets the default fontSize when fontSize is omitted"},"x":{"type":"number","description":"left edge, fraction 0-1 of the 3840 px wide board"},"y":{"type":"number","description":"top edge, fraction 0-1 of the 2160 px tall board"},"w":{"type":"number","description":"width fraction 0-1"},"h":{"type":"number","description":"height fraction 0-1"},"text":{"type":"string"},"font":{"type":"string","description":"installed family from fonts_list, max 2 per slide"},"fontSize":{"type":"number","description":"px on the 3840x2160 board (NOT points, NOT 1080p). headline 140-200, big stat 300-400, body 56-72, label 36-48, caption 48-56. Omit to auto-size by role and box height"},"weight":{"type":"string","enum":["regular","medium","semibold","bold","black"]},"align":{"type":"string","enum":["left","center","right"]},"color":{"type":"string","description":"text color hex #RRGGBB"},"fill":{"type":"string","description":"rect/image fill hex, or text background plate"},"opacity":{"type":"number","description":"0-1"},"cornerRadius":{"type":"number","description":"px, e.g. 48 for a soft card"},"borderColor":{"type":"string"},"borderWidth":{"type":"number","description":"px, 2-6"},"phone":{"type":"object","description":"optional Phone 9:16 frame {x,y,w,h fractions of 2160x3840, fontSize}; omitted = auto restack"}}}"##
    static let instantiateSchema = ##"{"type":"object","required":["templateId","title","addElements"],"properties":{"templateId":{"type":"string","description":"blank for custom layouts, or an id from templates_list"},"title":{"type":"string"},"groupName":{"type":"string"},"style":{"type":"object","properties":{"background":{"type":"string","description":"slide background hex"},"accent":{"type":"string"},"text":{"type":"string"}}},"addElements":{"type":"array","minItems":3,"description":"ALL elements of the slide, drawn in order (first = back)","items":"## + elementSchema + ##"},"slots":{"type":"object"},"edits":{"type":"object","description":"element name -> {text,color,fill,fontSize,opacity,frame:{x,y,w,h}}"},"remove":{"type":"array","items":{"type":"string"}},"notes":{"type":"string"},"streamOnly":{"type":"boolean"},"stage":{"type":"boolean"}}}"##
    static let addElementsSchema = ##"{"type":"object","required":["title","addElements"],"properties":{"title":{"type":"string"},"addElements":{"type":"array","items":"## + elementSchema + ##"}}}"##
    static let instantiateDescription = ##"""
    Build and stage ONE complete dual-canvas slide (Stream 3840x2160 + auto Phone 9:16). One call per slide, with every element in addElements. x,y,w,h are fractions 0-1; fontSize is board px (headline 140-200, body 56-72, label 36-48). Blur, gradients and shadows are not supported: fake frosted glass with a dark fill at opacity 0.8 plus a 2px light border.
    Example A, frosted quote card + camera:
    {"templateId":"blank","title":"Quote","style":{"background":"#3A2622"},"addElements":[{"kind":"rect","name":"Rose Block","x":0.35,"y":0,"w":0.65,"h":1,"fill":"#5A2A3A","opacity":0.6},{"kind":"rect","name":"Quote Card","x":0.042,"y":0.18,"w":0.5,"h":0.56,"fill":"#1A1A1C","opacity":0.8,"cornerRadius":48,"borderColor":"#5C5C60","borderWidth":3},{"kind":"text","name":"Card Label","role":"label","text":"Post:","x":0.072,"y":0.22,"w":0.44,"h":0.06,"fontSize":56,"weight":"bold","color":"#FFFFFF","font":"Helvetica Neue"},{"kind":"text","name":"Card Body","role":"body","text":"Stablecoins are a payroll story, a remittance story, a small shop story.","x":0.072,"y":0.3,"w":0.44,"h":0.4,"fontSize":88,"weight":"semibold","color":"#E6E6E6","font":"Helvetica Neue"},{"kind":"video","name":"Host Camera","x":0.62,"y":0.12,"w":0.33,"h":0.66,"borderColor":"#FF7A9A","borderWidth":6,"cornerRadius":36},{"kind":"rect","name":"Caption Plate","x":0.25,"y":0.85,"w":0.5,"h":0.07,"fill":"#000000","opacity":0.5,"cornerRadius":16},{"kind":"text","name":"Caption","role":"caption","text":"Kaleel on why Africa leads","x":0.26,"y":0.855,"w":0.48,"h":0.06,"fontSize":56,"align":"center","color":"#FFFFFF","font":"Helvetica Neue"}]}
    Example B, CNBC-style X post + lower third:
    {"templateId":"blank","title":"X Post","style":{"background":"#0B1F3A"},"addElements":[{"kind":"rect","name":"Headline Bar","x":0,"y":0,"w":1,"h":0.2,"fill":"#1534A8"},{"kind":"text","name":"Headline","role":"headline","text":"TOKENIZED PAYMENTS IN AFRICA","x":0.042,"y":0.03,"w":0.92,"h":0.14,"fontSize":180,"weight":"bold","color":"#FFFFFF","font":"Avenir Next Condensed"},{"kind":"rect","name":"Post Header","x":0.25,"y":0.25,"w":0.5,"h":0.07,"fill":"#E6E8EC","cornerRadius":16},{"kind":"text","name":"Post Handle","role":"label","text":"X   @kaleel","x":0.27,"y":0.255,"w":0.4,"h":0.06,"fontSize":64,"weight":"bold","color":"#1A2A5A","font":"Helvetica Neue"},{"kind":"rect","name":"Post Body","x":0.25,"y":0.32,"w":0.5,"h":0.28,"fill":"#FFFFFF"},{"kind":"text","name":"Post Text","role":"body","text":"Settlement in seconds, not days.","x":0.27,"y":0.34,"w":0.46,"h":0.18,"fontSize":88,"weight":"semibold","color":"#1A2A5A","font":"Helvetica Neue"},{"kind":"rect","name":"Show Tag","x":0.042,"y":0.7,"w":0.16,"h":0.08,"fill":"#FFFFFF"},{"kind":"text","name":"Show Tag Text","role":"label","text":"MORAPAY LIVE","x":0.05,"y":0.71,"w":0.15,"h":0.06,"fontSize":64,"weight":"bold","color":"#1534A8","align":"center","font":"Helvetica Neue"},{"kind":"rect","name":"Title Bar","x":0.202,"y":0.7,"w":0.756,"h":0.08,"fill":"#1534A8"},{"kind":"text","name":"Title","role":"headline","text":"FOUNDER ON STABLECOIN RAILS","x":0.215,"y":0.71,"w":0.73,"h":0.06,"fontSize":88,"weight":"bold","color":"#FFFFFF","font":"Avenir Next Condensed"},{"kind":"rect","name":"Channel Strip","x":0.042,"y":0.78,"w":0.917,"h":0.06,"fill":"#08122A"},{"kind":"text","name":"Stream Tag","role":"label","text":"STREAM MORAPAY+","x":0.6,"y":0.785,"w":0.35,"h":0.05,"fontSize":64,"weight":"bold","color":"#FF7A1A","align":"right","font":"Helvetica Neue"}]}
    """##

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
        .init(name: "fonts_list", description: "Installed font families on this Mac grouped by category (serif, sans, condensed, mono, display, script). Any of them works in addElements.font.", parametersJSON: #"{"type":"object","properties":{"category":{"type":"string"}}}"#),
        .init(name: "design_guide", description: "Full ProShow creative design guide (long). Only call when the built-in rules are not enough.", parametersJSON: empty),
        .init(name: "templates_list", description: "Broadcast/news template catalog: id, name, description, layout regions, editable text slots with defaults, canvases (Stream 16:9 + Phone 9:16). Starting points, not limits.", parametersJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Optional: one template id to get its full slot list"}}}"#),
        .init(name: "template_instantiate", description: AgentToolRegistry.instantiateDescription, parametersJSON: AgentToolRegistry.instantiateSchema),
        .init(name: "slide_add_elements", description: "Append elements to a staged slide (by title; creates the slide if the title is new). Same element format as template_instantiate addElements.", parametersJSON: AgentToolRegistry.addElementsSchema),
        .init(name: "slide_snapshot", description: "Layout summary of a staged slide (by title, default last): every element's frame as fractions, fontSize in board px, colors, plus problems (tiny text, no headline, overlaps, empty). Call after staging to check your work, then fix with slide_add_elements or a new template_instantiate.", parametersJSON: #"{"type":"object","properties":{"title":{"type":"string"}}}"#),
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
    - Accent color on at most 2 elements per slide (rule is per slide, not per show). Everything else neutral within that slide's palette.
    - Max 2 font families per slide (set addElements.font). Call fonts_list for installed families.
    - Range: when asked for variety (or for a multi-slide show), give each slide its own palette (background, text, one accent; any hex) and its own font pairing (e.g. serif headline + sans body, condensed + mono). Keep text contrast >= 4.5:1.
    - Flush left. No centered body text. No gradients, shadows, emoji, buzzwords.
    - Headlines under 7 words.
    - Variety: within one request no two slides share the same layout structure (vary column split, card count, alignment axis, image/text ratio). Don't reproduce slides already in the show.
    - Dual canvas by default: give every addElements item a `phone` frame designed for 9:16 (stack, don't shrink).
    - Default palette: graphite #121214 background, accent #6B9FE0, unless the operator asks for range or other colors. Set the slide background with style.background on blank.

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
