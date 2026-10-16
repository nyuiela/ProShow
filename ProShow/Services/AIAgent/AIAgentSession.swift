import Foundation
import Observation

/// One desk conversation with the design agent. Streams typed events, runs tools, stages drafts.
/// The show only changes when the operator taps Apply.
@MainActor
@Observable
final class AIAgentSession {
    static let shared = AIAgentSession()

    enum ProviderChoice: String, CaseIterable, Identifiable {
        case xai, practice
        var id: String { rawValue }
        var label: String { self == .xai ? "xAI" : "Practice" }
    }

    weak var controller: ShowController?
    var provider: ProviderChoice = {
        if let raw = UserDefaults.standard.string(forKey: XAIConfig.providerKey),
           let choice = ProviderChoice(rawValue: raw) {
            return choice
        }
        return XAIKeyStore.isConnected ? .xai : .practice
    }() {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: XAIConfig.providerKey) }
    }
    var deskUpdate = ""
    private(set) var events: [AgentEvent] = []
    private(set) var isRunning = false
    private(set) var draft: ComposePatch?
    private(set) var keyConnected = XAIKeyStore.isConnected
    private(set) var packVersion = ""

    private var seq = 0
    private var history: [AgentMessage] = []
    private var seenPackVersion: String?
    private var turnTask: Task<Void, Never>?
    private let maxEvents = 400

    func attach(_ controller: ShowController) { self.controller = controller }

    func saveKey(_ key: String) -> Bool {
        let ok = XAIKeyStore.save(key)
        keyConnected = XAIKeyStore.isConnected
        if ok { provider = .xai }
        return ok
    }

    func clearKey() {
        XAIKeyStore.clear()
        keyConnected = false
        provider = .practice
    }

    func reset() {
        cancel()
        history = []
        events = []
        draft = nil
        seenPackVersion = nil
    }

    func cancel() {
        guard let turnTask else { return }
        turnTask.cancel()
        self.turnTask = nil
        isRunning = false
        emit(.cancelled)
    }

    func discardDraft() { draft = nil }

    /// Operator gate. Only path from agent output into the show.
    @discardableResult
    func applyDraft() -> Int {
        guard let draft, let controller else { return 0 }
        do {
            let ids = try controller.applyComposePatch(draft)
            self.draft = nil
            return ids.count
        } catch {
            emit(.error("Apply failed: \(error)"))
            return 0
        }
    }

    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        guard ProShowFeatureFlags.aiComposeV1 else {
            emit(.error("AI compose is off. Turn on proshow.aiComposeV1."))
            return
        }
        var note = deskUpdate.trimmingCharacters(in: .whitespacesAndNewlines)
        deskUpdate = ""
        if note.isEmpty {
            note = (UserDefaults.standard.string(forKey: "proshow.ai.deskUpdateDefault") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        isRunning = true
        turnTask = Task { [weak self] in
            await self?.runTurn(prompt: trimmed, deskNote: note)
        }
    }

    // MARK: - Turn loop

    private func chatProvider() -> AgentChatProvider {
        provider == .xai && XAIKeyStore.isConnected ? XAIProvider() : PracticeAgentProvider()
    }

    private func runTurn(prompt: String, deskNote: String) async {
        defer { isRunning = false; turnTask = nil }
        emit(.turnStarted(turnID: UUID().uuidString))

        let pack = currentPack()
        packVersion = pack.version
        var ephemeral: [AgentMessage] = []
        if let previous = seenPackVersion, previous != pack.version {
            ephemeral.append(AgentMessage(role: .system, content: AgentContextPack.freshnessNote(previous: previous, current: pack.version, releaseNotes: pack.releaseNotes)))
            emit(.contextPackUpdated(version: pack.version, previous: previous))
        }
        if !deskNote.isEmpty {
            ephemeral.append(AgentMessage(role: .system, content: AgentContextPack.deskUpdateBlock(deskNote)))
        }
        history.append(AgentMessage(role: .user, content: prompt))

        var context: [AgentMessage] = [AgentMessage(role: .system, content: pack.systemPrompt())] + ephemeral + trimmedHistory()
        let provider = chatProvider()
        let tools = AgentToolRegistry.all
        var finalText = ""

        do {
            for round in 0..<AgentToolRegistry.maxToolRounds {
                try Task.checkCancellation()
                var roundText = ""
                var calls: [AgentToolCall] = []
                for try await event in provider.stream(messages: context, tools: round == AgentToolRegistry.maxToolRounds - 1 ? [] : tools) {
                    try Task.checkCancellation()
                    switch event {
                    case let .delta(text):
                        roundText += text
                        await emitOnMain(.delta(text))
                    case let .toolCalls(found):
                        calls = found
                    }
                }
                if calls.isEmpty {
                    finalText = roundText
                    break
                }
                if roundText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let beat = AgentFirstBeat.line(for: calls.map(\.name))
                    roundText = beat
                    emit(.delta(beat + "\n"))
                }
                let assistant = AgentMessage(role: .assistant, content: roundText, toolCalls: calls)
                context.append(assistant)
                history.append(assistant)
                for call in calls {
                    emit(.toolCall(name: call.name, callID: call.id))
                    let outcome = execute(call)
                    if let reason = outcome.needsConfirmation { emit(.confirmRequired(tool: call.name, reason: reason)) }
                    if let patch = outcome.draft {
                        draft = patch
                        emit(.draftReady(slideCount: patch.slides.count, summary: patch.summary))
                    }
                    emit(.toolResult(name: call.name, callID: call.id, ok: outcome.ok, summary: outcome.summary))
                    let toolMessage = AgentMessage(role: .tool, content: outcome.result, toolCallID: call.id)
                    context.append(toolMessage)
                    history.append(toolMessage)
                }
            }
            history.append(AgentMessage(role: .assistant, content: finalText))
            seenPackVersion = pack.version
            emit(.done(text: finalText))
        } catch is CancellationError {
            // cancel() already emitted.
        } catch {
            if Task.isCancelled { return }
            emit(.error((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
        }
    }

    private func trimmedHistory() -> [AgentMessage] {
        // Keep the last ~40 messages, never starting on an orphan tool result.
        var slice = Array(history.suffix(40))
        while slice.first?.role == .tool { slice.removeFirst() }
        return slice
    }

    private func emit(_ kind: AgentEvent.Kind) {
        seq += 1
        events.append(AgentEvent(seq: seq, ts: .now, kind: kind))
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
    }

    /// Stream callbacks may resume off-main; always publish events on the main actor.
    private func emitOnMain(_ kind: AgentEvent.Kind) async {
        await MainActor.run { emit(kind) }
    }

    func events(after seq: Int) -> [AgentEvent] { events.filter { $0.seq > seq } }

    // MARK: - Context

    func currentPack() -> AgentContextPack {
        let context = projectContext()
        let settingsKey = [context["stream"], context["phone"], context["theme"]].map { "\($0 ?? "")" }.joined(separator: "|")
        return AgentContextPack.build(context: context, settingsKey: settingsKey)
    }

    func projectContext() -> [String: Any] {
        guard let controller else { return ["error": "no_project"] }
        let settings = controller.projectSettings
        let show = controller.show
        let slides = show.allSlides
        let hasPhone = slides.contains { controller.phoneCanvasBoard(on: $0) != nil }
        var fonts = Set<String>()
        for slide in slides { for object in slide.canvas { fonts.insert(object.typography.fontFamily) } }
        if fonts.isEmpty { fonts.insert("Inter") }
        let w = Double(settings.resolution.width), h = Double(settings.resolution.height)
        return [
            "project": settings.name,
            "show": show.name,
            "stream": [
                "aspect": "16:9", "designWidth": CanvasConfig.width, "designHeight": CanvasConfig.height,
                "encodeWidth": w, "encodeHeight": h,
                "safeMarginFraction": 0.05, "lowerThirdBand": [0.72, 0.92], "headerBand": [0.04, 0.14], "footerTicker": [0.93, 0.99],
            ],
            "phone": [
                "enabled": hasPhone, "aspect": "9:16", "designWidth": 2160, "designHeight": 3840,
                "policy": hasPhone ? "author_phone_variant" : "fit_from_stream",
            ],
            "targetAspect": settings.targetAspect.rawValue,
            "frameRate": "\(settings.frameRate)",
            "theme": [
                "background": "#121214", "surface": "#1B1B1F", "raised": "#25252A", "accent": "#6B9FE0",
                "allowedBackgrounds": Array(ComposeDesignValidator.allowedBackgrounds).sorted(),
                "floats": "transparent",
            ],
            "fonts": Array(fonts).sorted(),
            "groups": show.groups.map { ["name": $0.name, "slides": $0.slides.count] },
            "slideCount": slides.count,
            "recipes": ComposeRecipe.all.map(\.id),
            "roles": ["operator": "applies drafts, takes, holds, arms destinations", "agent": "drafts to preview only"],
            "patchSchema": "ComposePatch v1. Slide fields: title, lines, notes, label, backgroundHex, elements[{text, alignment, x, y}] with x,y fractions 0 to 1.",
        ]
    }

    private func assets() -> [[String: Any]] {
        guard let controller else { return [] }
        var out: [[String: Any]] = []
        for group in controller.show.groups {
            for slide in group.slides {
                for object in slide.canvas where object.kind == .image || object.kind == .videoInput {
                    out.append(["group": group.name, "slide": slide.title, "name": object.name, "kind": object.kind.rawValue])
                    if out.count >= 80 { return out }
                }
            }
        }
        return out
    }

    // MARK: - Tools

    private func execute(_ call: AgentToolCall) -> AgentToolOutcome {
        guard let def = AgentToolRegistry.definition(call.name) else {
            return AgentToolOutcome(result: json(["ok": false, "error": "unknown_tool", "tools": AgentToolRegistry.all.map(\.name)]), ok: false, summary: "Unknown tool")
        }
        if def.operatorGated {
            let reason = call.name == "import_slides" ? "Use File > Import Slides." : "Operator only. Not run."
            return AgentToolOutcome(result: json(["ok": false, "error": "needs_confirmation", "message": reason]), ok: false, summary: reason, needsConfirmation: reason)
        }
        let args = Self.parseToolArguments(call.arguments)
        switch call.name {
        case "get_project_context":
            return AgentToolOutcome(result: json(projectContext()), ok: true, summary: "Context read")
        case "list_tools":
            return AgentToolOutcome(result: json(["tools": AgentToolRegistry.all.map { ["name": $0.name, "description": $0.description, "operatorGated": $0.operatorGated, "parameters": $0.wire["function"].flatMap { ($0 as? [String: Any])?["parameters"] } ?? [:]] }]), ok: true, summary: "\(AgentToolRegistry.all.count) tools")
        case "get_context_pack_status":
            let live = currentPack().version
            return AgentToolOutcome(result: json(["version": live, "sessionVersion": seenPackVersion ?? live, "outdated": (seenPackVersion ?? live) != live]), ok: true, summary: "Pack \(live)")
        case "list_assets":
            let items = assets()
            return AgentToolOutcome(result: json(["assets": items]), ok: true, summary: "\(items.count) assets")
        case "list_templates":
            return AgentToolOutcome(result: json(["note": "Inspiration only", "recipes": ComposeRecipe.all.map { ["id": $0.id, "name": $0.name] }, "packs": ["Rollup", "Bloomberg nameplate", "Guest mosaic 2/3/5", "Cam + Slide", "Milk Road"]]), ok: true, summary: "Templates listed")
        case "compose_patch_validate", "compose_patch_apply_preview":
            do {
                let raw: Any
                if let value = args["patch"] {
                    raw = value
                } else if args.isEmpty, !call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Entire arguments blob may itself be the patch or a fenced object.
                    raw = call.arguments
                } else {
                    throw ComposeError.missingPatch
                }
                let (patch, notes) = try ComposeCodec.decodePatchFlexible(raw, stripUnknownKeys: true)
                try ComposeDesignValidator.validate(patch)
                if call.name == "compose_patch_validate" {
                    var payload: [String: Any] = ["ok": true, "slides": patch.slides.count]
                    if !notes.isEmpty { payload["notes"] = notes }
                    return AgentToolOutcome(result: json(payload), ok: true, summary: "Valid, \(patch.slides.count) slides")
                }
                var payload: [String: Any] = ["ok": true, "staged": true, "slides": patch.slides.count, "next": "Operator reviews and taps Apply"]
                if !notes.isEmpty { payload["notes"] = notes }
                return AgentToolOutcome(result: json(payload), ok: true, summary: "Draft staged", draft: patch)
            } catch {
                let e = error as? ComposeError ?? .invalidJSON(String(describing: error))
                let preview = String(call.arguments.prefix(280))
                NSLog("ProShow AI compose tool \(call.name) failed: \(e.code) \(e.detail) raw=\(preview)")
                return AgentToolOutcome(
                    result: json(["ok": false, "error": e.code, "message": e.detail, "rawPreview": preview]),
                    ok: false,
                    summary: e.code
                )
            }
        default:
            return AgentToolOutcome(result: json(["ok": false, "error": "not_implemented"]), ok: false, summary: "Not implemented")
        }
    }

    private func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Best-effort parse of model tool arguments. Empty dict on failure (never throws).
    private static func parseToolArguments(_ text: String) -> [String: Any] {
        var notes: [String] = []
        if let data = try? ComposeCodec.sanitizeJSONData(Data(text.utf8), notes: &notes),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return object
        }
        return [:]
    }
}


extension ShowController {
    /// Read-only agent routes: /v1/ai/agent/{status,context,tools,events}. No key material is ever returned.
    func handleAIAgent(method: String, parts: [String]) -> (Int, String)? {
        guard parts.count == 4, parts[0] == "v1", parts[1] == "ai", parts[2] == "agent" else { return nil }
        guard ProShowFeatureFlags.aiComposeV1 else { return AIComposeAPI.flagOff() }
        guard method == "GET" else { return (405, #"{"ok":false,"error":"method_not_allowed"}"#) }
        let session = AIAgentSession.shared
        if session.controller == nil { session.attach(self) }
        switch parts[3] {
        case "status":
            return (200, ControlJSON.encode([
                "ok": true,
                "provider": session.provider.rawValue,
                "xai": XAIKeyStore.isConnected ? "connected" : "missing",
                "model": XAIConfig.model,
                "running": session.isRunning,
                "contextPackVersion": session.currentPack().version,
                "hasDraft": session.draft != nil,
            ]))
        case "context":
            return (200, ControlJSON.encode(["ok": true, "version": session.currentPack().version, "context": session.projectContext()]))
        case "tools":
            return (200, ControlJSON.encode(["ok": true, "tools": AgentToolRegistry.catalogJSON, "maxToolRounds": AgentToolRegistry.maxToolRounds]))
        case "events":
            return (200, ControlJSON.encode(["ok": true, "events": session.events.suffix(100).map(\.json)]))
        default:
            return nil
        }
    }
}
