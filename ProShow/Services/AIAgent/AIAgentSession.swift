import SwiftUI
import AppKit
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
    /// Group the staged draft lands in on Apply (model may name it, e.g. the show title).
    private(set) var draftGroupName: String = AIComposeAPI.draftGroupName
    /// Last patch that passed compose_patch_validate, so apply_preview can stage it by id / default.
    private var lastValidated: (id: String, patch: ComposePatch)?
    // Per-turn compose bookkeeping (reset in runTurn).
    private var turnStagedSlides = 0
    private var turnComposeAttempted = false
    private var turnLastComposeError: String?
    private var turnComposeFailures = 0
    private var turnPrompt = ""
    private(set) var keyConnected = XAIKeyStore.isConnected
    private(set) var packVersion = ""
    /// Persisted display history for Ask overlay / Settings (survives relaunch).
    private(set) var persistedEntries: [AgentHistoryStore.Entry] = []
    private(set) var lastPlacement: AgentSlidePlacement?

    private var seq = 0
    private var history: [AgentMessage] = []
    private var seenPackVersion: String?
    private var turnTask: Task<Void, Never>?
    private let maxEvents = 400
    private var projectKey = "global"

    func attach(_ controller: ShowController) {
        self.controller = controller
        let key = controller.show.id.uuidString
        if key != projectKey || persistedEntries.isEmpty {
            projectKey = key
            loadPersistedHistory()
        }
    }

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
        lastPlacement = nil
        seenPackVersion = nil
        persistedEntries = []
        AgentHistoryStore.clear(projectKey: projectKey)
        persistHistory()
    }

    func clearPersistedHistory() {
        persistedEntries = []
        history = []
        AgentHistoryStore.clear(projectKey: projectKey)
        persistHistory()
    }

    func cancel() {
        guard let turnTask else { return }
        turnTask.cancel()
        self.turnTask = nil
        isRunning = false
        emit(.cancelled)
    }

    func discardDraft() { draft = nil; draftGroupName = AIComposeAPI.draftGroupName }

    /// Operator gate. Only path from agent output into the show.
    @discardableResult
    func applyDraft() -> AgentSlidePlacement? {
        guard let draft, let controller else { return nil }
        do {
            let placement = try controller.applyComposePatch(draft, groupName: draftGroupName)
            self.draft = nil
            draftGroupName = AIComposeAPI.draftGroupName
            lastPlacement = placement
            emit(.slidesCreated(
                groupName: placement.groupName,
                slideCount: placement.slideIDs.count,
                label: placement.label,
                deepLink: placement.deepLink,
                slideIDs: placement.slideIDs
            ))
            appendPersisted(
                role: "assistant",
                text: ([placement.label + " · " + placement.deepLink] + zip(placement.slideIDs, placement.slideTitles).enumerated().map { index, pair in
                    let link = placement.showID.map { "proshow://show/\($0.uuidString)/slide/\(pair.0.uuidString)" } ?? "proshow://slide/\(pair.0.uuidString)"
                    return "\(index + 1). \(pair.1.isEmpty ? "Slide" : pair.1) · \(link)"
                }).joined(separator: "\n"),
                placement: placement
            )
            if let first = placement.slideIDs.first {
                controller.select(first)
            }
            return placement
        } catch {
            emit(.error("Apply failed: \(error)"))
            return nil
        }
    }

    /// Jump to a created slide in the rundown / canvas.
    func openPlacement(_ placement: AgentSlidePlacement) {
        guard let controller, let first = placement.slideIDs.first else { return }
        controller.select(first)
        if !controller.isCanvasEditorPresented {
            controller.openEditor(.presentation)
        }
    }

    func openDeepLink(_ link: String) {
        guard let id = Self.slideID(fromDeepLink: link) else { return }
        controller?.select(id)
        if let controller, !controller.isCanvasEditorPresented {
            controller.openEditor(.presentation)
        }
    }

    private static func slideID(fromDeepLink link: String) -> UUID? {
        // proshow://slide/<uuid> or proshow://show/<show>/slide/<uuid>
        let parts = link.split(separator: "/").map(String.init)
        guard let idx = parts.lastIndex(of: "slide"), idx + 1 < parts.count else {
            return UUID(uuidString: parts.last ?? "")
        }
        return UUID(uuidString: parts[idx + 1])
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
        if let script = ScriptedAgentProvider.configured { return ScriptedAgentProvider(script: script) }
        return provider == .xai && XAIKeyStore.isConnected ? XAIProvider() : PracticeAgentProvider()
    }

    private func runTurn(prompt: String, deskNote: String) async {
        defer { isRunning = false; turnTask = nil }
        emit(.turnStarted(turnID: UUID().uuidString))
        turnStagedSlides = 0
        turnComposeAttempted = false
        turnLastComposeError = nil
        turnComposeFailures = 0
        turnPrompt = prompt

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
        if Self.userRequestsStreamOnly(prompt) {
            ephemeral.append(AgentMessage(role: .system, content: #"[Canvas policy] Operator asked for Stream-only. You may set designMeta.streamOnly true and canvases ["stream"]."#))
        } else {
            ephemeral.append(AgentMessage(role: .system, content: #"[Canvas policy] Default is dual canvas. Author Stream 16:9 and Phone 9:16. designMeta.canvases must be ["stream","phone"] unless the operator explicitly waived Phone."#))
        }
        history.append(AgentMessage(role: .user, content: prompt))
        appendPersisted(role: "user", text: prompt)

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
                if turnComposeFailures >= AgentToolRegistry.maxComposeFailures { break }
            }
            // Never report success when nothing was staged or the last compose call failed.
            let wantedSlides = Self.promptRequestsSlides(prompt)
            if (turnComposeAttempted || wantedSlides), turnStagedSlides == 0 || turnComposeFailures >= AgentToolRegistry.maxComposeFailures {
                let reason = turnLastComposeError ?? "the agent never staged a draft"
                let message = "No slides were created. The design agent could not stage the draft (\(reason)) after \(turnComposeFailures) failed attempt(s). Try again, or ask for fewer slides at a time."
                history.append(AgentMessage(role: .assistant, content: message))
                appendPersisted(role: "assistant", text: message)
                seenPackVersion = pack.version
                persistHistory()
                emit(.error(message))
                return
            }
            if let draft, turnStagedSlides > 0 {
                let list = draft.slides.enumerated().map { "\($0.offset + 1). \($0.element.title.isEmpty ? "Slide" : $0.element.title)" }.joined(separator: "\n")
                finalText += "\n\nStaged \(draft.slides.count) slide(s) for group \"\(draftGroupName)\":\n\(list)\nTap Apply to create them. Each slide's link is listed after Apply."
            }
            history.append(AgentMessage(role: .assistant, content: finalText))
            if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendPersisted(role: "assistant", text: finalText)
            }
            seenPackVersion = pack.version
            persistHistory()
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
        // Dual-canvas is the product default; Phone board is ensured on Apply.
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
                "enabled": true,
                "presentInShow": hasPhone,
                "aspect": "9:16",
                "designWidth": 2160,
                "designHeight": 3840,
                "policy": "author_both_by_default",
                "note": "Always author Phone unless the operator says Stream-only. Apply creates a Phone board when missing.",
            ],
            "canvasDefault": ["stream", "phone"],
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
            "templates": AgentTemplateCatalog.compactSummary,
            "templateTools": "templates_list, template_instantiate (dual Stream+Phone, slots, style, edits, addElements)",
            "designBar": "Rich multi-element slides: header strip, headline hierarchy, plates, stat cards, accent rules, footer ticker. No single-text slides unless asked for minimal.",
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
        case "templates_list":
            if let id = args["id"] as? String, let t = AgentTemplateCatalog.template(id) {
                return AgentToolOutcome(result: json(["id": t.id, "name": t.name, "description": t.description, "regions": t.regions, "bestFor": t.bestFor, "slots": AgentTemplateCatalog.slots(t.id), "canvases": ["stream", "phone"]]), ok: true, summary: "Template \(t.id)")
            }
            let list = AgentTemplateCatalog.all.map { t -> [String: Any] in
                ["id": t.id, "name": t.name, "description": t.description, "regions": t.regions, "bestFor": t.bestFor,
                 "slots": AgentTemplateCatalog.slots(t.id).map { $0["slot"] ?? "" }, "canvases": ["stream", "phone"]]
            }
            return AgentToolOutcome(result: json(["templates": list, "note": "Starting points. Restyle, edit, remove and add elements freely."]), ok: true, summary: "\(list.count) templates")
        case "template_instantiate":
            turnComposeAttempted = true
            let outcome = instantiateTool(args)
            if outcome.ok { turnComposeFailures = 0 } else { turnComposeFailures += 1; turnLastComposeError = outcome.summary }
            return outcome
        case "compose_patch_validate", "compose_patch_apply_preview":
            turnComposeAttempted = true
            let outcome = composeTool(call, args: args)
            if outcome.ok {
                turnComposeFailures = 0
            } else {
                turnComposeFailures += 1
                turnLastComposeError = outcome.summary
            }
            return outcome
        default:
            return AgentToolOutcome(result: json(["ok": false, "error": "not_implemented"]), ok: false, summary: "Not implemented")
        }
    }

    private func instantiateTool(_ args: [String: Any]) -> AgentToolOutcome {
        let id = (args["templateId"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        do {
            let (slide, notes) = try AgentTemplateCatalog.instantiate(id, args: args)
            let streamOnly = (args["streamOnly"] as? Bool) == true
            let patch = ComposePatch(
                schemaVersion: ComposePatch.currentSchemaVersion,
                recipeId: "freeform",
                summary: "\(id): \(slide.title)",
                slides: [slide],
                rundownBlocks: nil,
                designMeta: ComposeDesignMeta(canvases: streamOnly ? ["stream"] : ["stream", "phone"], streamOnly: streamOnly ? true : nil)
            )
            try ComposeDesignValidator.validate(patch)
            let patchId = "t" + String(UUID().uuidString.prefix(8)).lowercased()
            lastValidated = (patchId, patch)
            let phoneCount = slide.editorCanvases.first(where: \.isPhoneArtboard)?.objects.count ?? 0
            var payload: [String: Any] = ["ok": true, "patchId": patchId, "title": slide.title,
                                          "streamElements": slide.canvas.count, "phoneElements": phoneCount,
                                          "elementNames": slide.canvas.map(\.name)]
            if !notes.isEmpty { payload["notes"] = notes }
            if (args["stage"] as? Bool) ?? true {
                if let name = (args["groupName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    draftGroupName = String(name.prefix(80))
                }
                var staged = patch
                if turnStagedSlides > 0, let existing = draft {
                    staged = existing
                    staged.slides += patch.slides
                    staged.summary = String((existing.summary + "; " + patch.summary).prefix(600))
                    if streamOnly == false, existing.designMeta.streamOnly == true { staged.designMeta = patch.designMeta }
                }
                turnStagedSlides += 1
                payload["staged"] = true
                payload["draftSlides"] = staged.slides.count
                payload["group"] = draftGroupName
                return AgentToolOutcome(result: json(payload), ok: true, summary: "\(id) → \(slide.title) (S\(slide.canvas.count)/P\(phoneCount))", draft: staged)
            }
            payload["next"] = "compose_patch_apply_preview {\"patchId\":\"\(patchId)\"}"
            return AgentToolOutcome(result: json(payload), ok: true, summary: "Built \(id)")
        } catch AgentTemplateCatalog.InstantiateError.unknownTemplate(let bad) {
            return AgentToolOutcome(result: json(["ok": false, "error": "unknown_template", "message": bad, "templates": AgentTemplateCatalog.all.map(\.id)]), ok: false, summary: "unknown_template")
        } catch {
            let e = error as? ComposeError ?? .invalidJSON(String(describing: error))
            return AgentToolOutcome(result: json(["ok": false, "error": e.code, "message": e.detail, "retry": "Fix and call template_instantiate again."]), ok: false, summary: e.code)
        }
    }

    /// Build requests get rich slides; a lone text element is pushed back unless the operator asked for minimal.
    private func plainSlideTitles(_ patch: ComposePatch) -> [String] {
        let lower = turnPrompt.lowercased()
        if ["minimal", "simple slide", "plain", "text only", "single line", "just text"].contains(where: { lower.contains($0) }) { return [] }
        return patch.slides.filter { $0.canvas.count + $0.elements.count + ($0.lines.isEmpty ? 0 : 1) <= 2 && $0.canvas.count < 3 }.map(\.title)
    }

    private func composeTool(_ call: AgentToolCall, args: [String: Any]) -> AgentToolOutcome {
        let isStage = call.name == "compose_patch_apply_preview"
        func fail(_ code: String, _ message: String) -> AgentToolOutcome {
            let preview = String(call.arguments.prefix(280))
            NSLog("ProShow AI compose tool \(call.name) failed: \(code) \(message) raw=\(preview)")
            return AgentToolOutcome(
                result: json(["ok": false, "error": code, "message": message, "rawPreview": preview, "retry": "Fix and call \(call.name) again. Send at most 3 slides per call."]),
                ok: false,
                summary: code
            )
        }
        if call.truncated {
            return fail("output_truncated", "Your tool call was cut off by the output limit. Send 1-3 slides per call and stage batches with append true.")
        }
        do {
            var patch: ComposePatch
            var notes: [String] = []
            if let value = args["patch"] {
                (patch, notes) = try ComposeCodec.decodePatchFlexible(value, stripUnknownKeys: true)
            } else if args["slides"] != nil {
                // Model sent the patch itself as the arguments object.
                var bare = args
                for key in ["patchId", "append", "groupName"] { bare.removeValue(forKey: key) }
                (patch, notes) = try ComposeCodec.decodePatchFlexible(bare, stripUnknownKeys: true)
            } else if args.isEmpty, !call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      call.arguments.contains("\"slides\"") {
                // Entire arguments blob may itself be the patch or a fenced object.
                (patch, notes) = try ComposeCodec.decodePatchFlexible(call.arguments, stripUnknownKeys: true)
            } else if isStage, let last = lastValidated,
                      (args["patchId"] as? String).map({ $0 == last.id }) ?? true {
                patch = last.patch
                notes.append("Staged last validated patch \(last.id)")
            } else {
                let hint = lastValidated == nil
                    ? "Send {\"patch\": {...}}. Call compose_patch_validate first if unsure."
                    : "Unknown patchId. Last validated id is \(lastValidated!.id). Or send {\"patch\": {...}}."
                return fail(ComposeError.missingPatch.code, hint)
            }
            try ComposeDesignValidator.validate(patch)
            let plain = plainSlideTitles(patch)
            if !plain.isEmpty {
                return fail("too_plain", "Slides \(plain.joined(separator: ", ")) are a single text element. Use template_instantiate (templates_list) or add header, plates, cards, rules and a footer.")
            }
            if !isStage {
                let id = "p" + String(UUID().uuidString.prefix(8)).lowercased()
                lastValidated = (id, patch)
                var payload: [String: Any] = ["ok": true, "slides": patch.slides.count, "patchId": id, "next": "compose_patch_apply_preview with {\"patchId\": \"\(id)\", \"append\": true}"]
                if !notes.isEmpty { payload["notes"] = notes }
                return AgentToolOutcome(result: json(payload), ok: true, summary: "Valid, \(patch.slides.count) slides")
            }
            if let name = (args["groupName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                draftGroupName = String(name.prefix(80))
            }
            let append = (args["append"] as? Bool) ?? (turnStagedSlides > 0)
            var staged = patch
            if append, let existing = draft {
                staged = existing
                staged.slides += patch.slides
                if let blocks = patch.rundownBlocks { staged.rundownBlocks = (staged.rundownBlocks ?? []) + blocks }
                if !patch.summary.isEmpty, !staged.summary.contains(patch.summary) {
                    staged.summary = String((staged.summary + " " + patch.summary).prefix(600))
                }
                try ComposeDesignValidator.validate(staged)
            }
            turnStagedSlides += patch.slides.count
            let canvases = staged.designMeta.canvases.map { $0.lowercased() }
            var payload: [String: Any] = [
                "ok": true,
                "staged": true,
                "addedSlides": patch.slides.count,
                "slides": staged.slides.count,
                "group": draftGroupName,
                "canvases": canvases,
                "locationHint": "After Apply: group \(draftGroupName)",
                "next": "Stage remaining slides (append true), then reply with the slide list. The operator taps Apply.",
            ]
            if !notes.isEmpty { payload["notes"] = notes }
            return AgentToolOutcome(
                result: json(payload),
                ok: true,
                summary: "Draft staged → \(draftGroupName) (\(staged.slides.count))",
                draft: staged
            )
        } catch {
            let e = error as? ComposeError ?? .invalidJSON(String(describing: error))
            return fail(e.code, e.detail)
        }
    }

    private func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }


    // MARK: - History persistence

    private func loadPersistedHistory() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = AgentHistoryStore.load(projectKey: projectKey)
        persistedEntries = doc.entries
        history = doc.wire.compactMap { wire in
            guard let role = AgentMessage.Role(rawValue: wire.role) else { return nil }
            return AgentMessage(role: role, content: wire.content, toolCallID: wire.toolCallID)
        }
    }

    private func persistHistory() {
        var doc = AgentHistoryStore.Document(projectKey: projectKey)
        doc.entries = persistedEntries
        doc.wire = history.compactMap { message in
            // Skip bulky tool payloads; keep user/assistant for continuity.
            guard message.role == .user || message.role == .assistant else { return nil }
            let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AgentHistoryStore.WireMessage(role: message.role.rawValue, content: String(text.prefix(4000)), toolCallID: message.toolCallID)
        }
        AgentHistoryStore.save(doc)
    }

    private func appendPersisted(role: String, text: String, placement: AgentSlidePlacement? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = AgentHistoryStore.Entry(
            id: UUID(),
            ts: .now,
            role: role,
            text: String(trimmed.prefix(4000)),
            groupName: placement?.groupName,
            slideIDs: placement?.slideIDs ?? [],
            slideTitles: placement?.slideTitles ?? [],
            deepLink: placement?.deepLink
        )
        persistedEntries.append(entry)
        if persistedEntries.count > AgentHistoryStore.maxEntries {
            persistedEntries = Array(persistedEntries.suffix(AgentHistoryStore.maxEntries))
        }
        persistHistory()
    }

    /// Build/design requests must end with staged slides, or the turn reports failure.
    private static func promptRequestsSlides(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let verbs = ["build", "create", "make", "design", "generate", "add", "draft", "compose"]
        let nouns = ["slide", "show", "deck", "lower third", "template", "screen"]
        return verbs.contains { lower.contains($0) } && nouns.contains { lower.contains($0) }
    }

    private static func userRequestsStreamOnly(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let needles = [
            "stream only", "stream-only", "no phone", "without phone",
            "16:9 only", "skip phone", "don't make phone", "do not make phone",
            "dont make phone", "desktop only",
        ]
        return needles.contains { lower.contains($0) }
    }


    /// Best-effort parse of model tool arguments. Empty dict on failure (never throws).
    private static func parseToolArguments(_ text: String) -> [String: Any] {
        // Plain JSON first. `sanitizeJSONData` unwraps {"patch":{...}} to the bare patch, which used to
        // drop the `patch` key (and patchId/append/groupName) so every well-formed call hit missing_patch.
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return object
        }
        var notes: [String] = []
        if let data = try? ComposeCodec.sanitizeJSONData(Data(text.utf8), notes: &notes),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Sanitizer may have unwrapped a nested patch; keep it addressable as `patch`.
            if object["patch"] == nil, object["slides"] != nil { return ["patch": object] }
            return object
        }
        return [:]
    }
}


extension ShowController {
    @MainActor
    static func renderPNG<V: View>(_ view: V, size: NSSize, to path: String) -> Bool {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.black))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Read-only agent routes: /v1/ai/agent/{status,context,tools,events}. No key material is ever returned.
    func handleAIAgent(method: String, parts: [String]) -> (Int, String)? {
        guard parts.count == 4, parts[0] == "v1", parts[1] == "ai", parts[2] == "agent" else { return nil }
        guard ProShowFeatureFlags.aiComposeV1 else { return AIComposeAPI.flagOff() }
        let session = AIAgentSession.shared
        if session.controller == nil { session.attach(self) }
        // Test hooks only while a scripted mock model is configured (never with a real key path).
        if method == "POST", ScriptedAgentProvider.configured != nil {
            switch parts[3] {
            case "send":
                session.send("Build a complete 10-slide show (mock run).")
                return (202, #"{"ok":true}"#)
            case "render_last":
                // Writes Stream + Phone PNGs of the last applied slides to /tmp for visual checks.
                guard let placement = session.lastPlacement else { return (409, #"{"ok":false,"error":"no_placement"}"#) }
                var paths: [String] = []
                var counts: [[String: Any]] = []
                for (index, id) in placement.slideIDs.enumerated() {
                    guard let slide = show.allSlides.first(where: { $0.id == id }) else { continue }
                    let phone = phoneCanvasBoard(on: slide)
                    counts.append(["title": slide.title, "stream": slide.canvas.count, "phone": phone?.objects.count ?? 0])
                    let base = "/tmp/proshow-agent-\(index + 1)"
                    if Self.renderPNG(ProgramSlideThumbnailPreview(controller: self, slide: slide, objects: resolvedCanvasObjects(slide.canvas)), size: NSSize(width: 1280, height: 720), to: base + "-stream.png") { paths.append(base + "-stream.png") }
                    if let phone, Self.renderPNG(ProgramSlideThumbnailPreview(controller: self, slide: slide, objects: resolvedCanvasObjects(phone.objects), canvasWidth: phone.width, canvasHeight: phone.height), size: NSSize(width: 540, height: 960), to: base + "-phone.png") { paths.append(base + "-phone.png") }
                }
                return (200, ControlJSON.encode(["ok": true, "paths": paths, "slides": counts]))
            case "delete_group":
                let name = session.lastPlacement?.groupName ?? ""
                guard !name.isEmpty, name != BroadcastTemplatePack.groupName else { return (409, #"{"ok":false}"#) }
                let removed = removeGroups(named: name)
                return (200, ControlJSON.encode(["ok": true, "removedGroups": removed, "name": name]))
            case "apply_draft":
                guard let placement = session.applyDraft() else { return (409, #"{"ok":false,"error":"no_draft"}"#) }
                return (200, ControlJSON.encode(["ok": true, "group": placement.groupName, "slides": placement.slideIDs.count, "deepLink": placement.deepLink]))
            default: break
            }
        }
        guard method == "GET" else { return (405, #"{"ok":false,"error":"method_not_allowed"}"#) }
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
