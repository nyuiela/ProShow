import Foundation

/// xAI key lives in the device-bound stream vault. Never in Settings JSON, logs or OpenAPI examples.
enum XAIKeyStore {
    static let vaultIdentifier = "ai.xai.apiKey"

    static var isConnected: Bool { !(KeychainStreamVault.load(identifier: vaultIdentifier) ?? "").isEmpty }
    static func load() -> String? {
        let key = KeychainStreamVault.load(identifier: vaultIdentifier) ?? ""
        return key.isEmpty ? nil : key
    }
    @discardableResult static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return KeychainStreamVault.save(identifier: vaultIdentifier, secret: trimmed)
    }
    @discardableResult static func clear() -> Bool { KeychainStreamVault.delete(identifier: vaultIdentifier) }
}

enum XAIConfig {
    static let modelKey = "proshow.xai.model"
    static let providerKey = "proshow.ai.provider"
    /// grok-4 / grok-4-fast slugs were retired 2026-05-15 and redirect to grok-4.3; use it directly with low effort.
    static let defaultModel = "grok-4.3"
    static let effortKey = "proshow.xai.reasoningEffort"
    static let defaultEffort = "low"
    static var reasoningEffort: String {
        get { UserDefaults.standard.string(forKey: effortKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultEffort }
        set { UserDefaults.standard.set(newValue, forKey: effortKey) }
    }
    static let modelsEndpoint = URL(string: "https://api.x.ai/v1/models")!
    /// Room for multi-slide ComposePatch JSON in one tool call.
    static let maxOutputTokens = 8_000
    static let endpoint = URL(string: "https://api.x.ai/v1/chat/completions")!

    static var model: String {
        get {
            let value = UserDefaults.standard.string(forKey: modelKey) ?? ""
            // Old default (and retired fast slugs) → cheaper current default.
            let retired: Set<String> = ["grok-4", "grok-4-0709", "grok-4-fast", "grok-4-fast-reasoning", "grok-4-fast-non-reasoning", "grok-4-1-fast-reasoning", "grok-4-1-fast-non-reasoning"]
            return value.isEmpty || retired.contains(value) ? defaultModel : value
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? defaultModel : trimmed, forKey: modelKey)
        }
    }
}

/// One streamed chunk from a provider round.
enum ProviderStreamEvent: Sendable {
    case delta(String)
    case toolCalls([AgentToolCall])
}

enum ProviderError: Error, LocalizedError {
    case missingKey
    case http(Int, String)
    case badStream

    var errorDescription: String? {
        switch self {
        case .missingKey: "xAI key missing. Add it in Settings > AI."
        case let .http(code, message): "xAI \(code): \(message)"
        case .badStream: "xAI stream ended early"
        }
    }
}

protocol AgentChatProvider: Sendable {
    var id: String { get }
    func stream(messages: [AgentMessage], tools: [AgentToolDefinition]) -> AsyncThrowingStream<ProviderStreamEvent, Error>
}

/// xAI OpenAI-compatible chat completions with streaming and tools.
struct XAIProvider: AgentChatProvider {
    let id = "xai"
    var model: String = XAIConfig.model
    var session: URLSession = .shared

    func stream(messages: [AgentMessage], tools: [AgentToolDefinition]) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = XAIKeyStore.load() else { throw ProviderError.missingKey }
                    var request = URLRequest(url: XAIConfig.endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "max_tokens": XAIConfig.maxOutputTokens,
                        "reasoning_effort": XAIConfig.reasoningEffort,
                        "messages": messages.map(\.wire),
                    ]
                    if !tools.isEmpty {
                        body["tools"] = tools.map(\.wire)
                        body["tool_choice"] = "auto"
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 600 { break } }
                        throw ProviderError.http(status, Self.errorMessage(text))
                    }

                    var pending: [Int: AgentToolCall] = [:]
                    var finishReason = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choice = (object["choices"] as? [[String: Any]])?.first
                        else { continue }
                        if let reason = choice["finish_reason"] as? String { finishReason = reason }
                        guard let delta = choice["delta"] as? [String: Any] else { continue }
                        if let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(.delta(text))
                        }
                        for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                            let index = call["index"] as? Int ?? 0
                            var current = pending[index] ?? AgentToolCall(id: "", name: "", arguments: "")
                            if let id = call["id"] as? String, !id.isEmpty { current.id = id }
                            if let fn = call["function"] as? [String: Any] {
                                if let name = fn["name"] as? String { current.name += name }
                                if let args = fn["arguments"] as? String { current.arguments += args }
                            }
                            pending[index] = current
                        }
                    }
                    if !pending.isEmpty {
                        let calls = pending.keys.sorted().compactMap { pending[$0] }.enumerated().map { offset, call in
                            var c = call
                            if c.id.isEmpty { c.id = "call_\(offset)" }
                            if finishReason == "length" { c.truncated = true }
                            return c
                        }
                        continuation.yield(.toolCalls(calls))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Model ids available to this key (GET /v1/models). Never returns or logs the key.
    static func listModels(session: URLSession = .shared) async throws -> [String] {
        guard let key = XAIKeyStore.load() else { throw ProviderError.missingKey }
        var request = URLRequest(url: XAIConfig.modelsEndpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ProviderError.http(status, errorMessage(String(decoding: data, as: UTF8.self))) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    private static func errorMessage(_ text: String) -> String {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object["error"] as? String { return message }
        }
        return String(text.prefix(200))
    }
}

/// Offline practice: reads context, validates the operator's last patch if any, never calls the network.
struct PracticeAgentProvider: AgentChatProvider {
    let id = "practice"

    func stream(messages: [AgentMessage], tools: [AgentToolDefinition]) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let usedContext = messages.contains { $0.role == .tool }
            if !usedContext {
                continuation.yield(.toolCalls([AgentToolCall(id: "practice_ctx", name: "get_project_context", arguments: "{}")]))
            } else {
                continuation.yield(.delta("Practice mode. I read the project context. Add an xAI key to design live, or paste a patch into the Control API compose route."))
            }
            continuation.finish()
        }
    }
}

/// Offline scripted model for verifying the agent loop (`defaults write com.kaleel.proshow proshow.ai.mockScript batched|broken`).
/// batched: context → validate 3 → stage by patchId → stage 3 (append) → stage 4 (append) → reply.
/// broken: keeps calling apply_preview with no patch, like the failing xAI run.
struct ScriptedAgentProvider: AgentChatProvider {
    let id = "scripted"
    var script: String

    static var configured: String? {
        let v = UserDefaults.standard.string(forKey: "proshow.ai.mockScript") ?? ""
        return v.isEmpty ? nil : v
    }

    private static func patch(_ range: ClosedRange<Int>) -> String {
        let slides = range.map { "{\"title\":\"Morapay Live \($0)\",\"lines\":[\"Stablecoin rails slide \($0)\"],\"backgroundHex\":\"#121214\"}" }
        return #"{"schemaVersion":1,"recipeId":"freeform","summary":"Batch \#(range.lowerBound)-\#(range.upperBound)","slides":[\#(slides.joined(separator: ","))],"designMeta":{"canvases":["stream","phone"]}}"#
    }

    func stream(messages: [AgentMessage], tools: [AgentToolDefinition]) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let lastUser = messages.lastIndex { $0.role == .user } ?? 0
            let toolResults = messages[lastUser...].filter { $0.role == .tool }
            let step = toolResults.count
            func call(_ name: String, _ args: String) {
                continuation.yield(.toolCalls([AgentToolCall(id: "s\(step)", name: name, arguments: args)]))
            }
            if tools.isEmpty { continuation.yield(.delta("Done.")); continuation.finish(); return }
            if script == "broken" {
                if step == 0 { call("get_project_context", "{}") } else { call("compose_patch_apply_preview", "{}") }
                continuation.finish(); return
            }
            if script == "palettes" {
                let steps: [(String, String)] = [
                    ("get_project_context", ##"{}"##),
                    ("fonts_list", ##"{}"##),
                    ("template_instantiate", ##"{"templateId": "blank", "title": "Cream Editorial", "style": {"background": "#F4EFE6"}, "addElements": [{"kind": "text", "name": "Kicker", "x": 0.0417, "y": 0.0556, "w": 0.5, "h": 0.05, "phone": {"x": 0.056, "y": 0.04, "w": 0.8, "h": 0.03, "size": 36}, "text": "MORAPAY JOURNAL", "size": 48, "weight": "semibold", "color": "#C2410C", "font": "Helvetica Neue"}, {"kind": "text", "name": "Headline", "x": 0.0417, "y": 0.3, "w": 0.6, "h": 0.3, "phone": {"x": 0.056, "y": 0.25, "w": 0.89, "h": 0.2, "size": 150}, "text": "Money should move like messages", "size": 200, "weight": "bold", "color": "#1A1A1A", "font": "Baskerville"}, {"kind": "rect", "name": "Rule", "x": 0.0417, "y": 0.66, "w": 0.12, "h": 0.006, "phone": {"x": 0.056, "y": 0.5, "w": 0.2, "h": 0.003}, "fill": "#C2410C"}, {"kind": "text", "name": "Body", "x": 0.0417, "y": 0.7, "w": 0.5, "h": 0.15, "phone": {"x": 0.056, "y": 0.53, "w": 0.89, "h": 0.1, "size": 54}, "text": "Stablecoin rails cut settlement from days to seconds.", "size": 72, "weight": "semibold", "color": "#3A3A3A", "font": "Helvetica Neue"}], "groupName": "Agent Palette Test"}"##),
                    ("template_instantiate", ##"{"templateId": "blank", "title": "Navy Data", "style": {"background": "#0B1F3A"}, "addElements": [{"kind": "text", "name": "Label", "x": 0.0417, "y": 0.0556, "w": 0.4, "h": 0.05, "phone": {"x": 0.056, "y": 0.04, "w": 0.8, "h": 0.03, "size": 36}, "text": "SETTLEMENT TIME", "size": 48, "weight": "semibold", "color": "#9FB3C8", "font": "Menlo"}, {"kind": "text", "name": "Value", "x": 0.5, "y": 0.2, "w": 0.46, "h": 0.5, "phone": {"x": 0.056, "y": 0.15, "w": 0.89, "h": 0.25, "size": 300}, "text": "4.2s", "size": 400, "weight": "bold", "color": "#F5C518", "font": "Avenir Next Condensed"}, {"kind": "text", "name": "Compare", "x": 0.0417, "y": 0.3, "w": 0.4, "h": 0.3, "phone": {"x": 0.056, "y": 0.45, "w": 0.89, "h": 0.15, "size": 90}, "text": "Down from 3 days", "size": 120, "weight": "bold", "color": "#F4EFE6", "font": "Avenir Next Condensed"}, {"kind": "rect", "name": "Base Line", "x": 0.0417, "y": 0.85, "w": 0.9167, "h": 0.004, "phone": {"x": 0.056, "y": 0.7, "w": 0.89, "h": 0.002}, "fill": "#2A4466"}, {"kind": "text", "name": "Source", "x": 0.0417, "y": 0.88, "w": 0.6, "h": 0.05, "phone": {"x": 0.056, "y": 0.72, "w": 0.89, "h": 0.03, "size": 36}, "text": "Morapay pilot, Q3", "size": 48, "weight": "semibold", "color": "#9FB3C8", "font": "Menlo"}]}"##),
                    ("template_instantiate", ##"{"templateId": "blank", "title": "Lime Poster", "style": {"background": "#C6FF3D"}, "addElements": [{"kind": "text", "name": "Headline", "x": 0.0417, "y": 0.1, "w": 0.9, "h": 0.5, "phone": {"x": 0.056, "y": 0.1, "w": 0.89, "h": 0.4, "size": 240}, "text": "Built for Africa", "size": 320, "weight": "bold", "color": "#0B0B0D", "font": "Futura"}, {"kind": "rect", "name": "Block", "x": 0.0417, "y": 0.68, "w": 0.3, "h": 0.24, "phone": {"x": 0.056, "y": 0.6, "w": 0.89, "h": 0.15}, "fill": "#0B0B0D"}, {"kind": "text", "name": "Block Text", "x": 0.0625, "y": 0.72, "w": 0.26, "h": 0.16, "phone": {"x": 0.09, "y": 0.63, "w": 0.8, "h": 0.09, "size": 90}, "text": "Live now", "size": 120, "weight": "medium", "color": "#C6FF3D", "font": "Georgia"}, {"kind": "text", "name": "Note", "x": 0.4167, "y": 0.72, "w": 0.5, "h": 0.16, "phone": {"x": 0.056, "y": 0.8, "w": 0.89, "h": 0.08, "size": 54}, "text": "Join the stream and ask questions", "size": 72, "weight": "medium", "color": "#0B0B0D", "font": "Futura"}]}"##)
                ]
                let step = messages[(messages.lastIndex { $0.role == .user } ?? 0)...].filter { $0.role == .tool }.count
                if step < steps.count, !tools.isEmpty { call(steps[step].0, steps[step].1) } else { continuation.yield(.delta("Staged 3 palette slides.")) }
                continuation.finish(); return
            }
            if script == "original" {
                let steps: [(String, String)] = [
                    ("get_project_context", ##"{}"##),
                    ("template_instantiate", ##"{"templateId": "blank", "title": "Cold Open", "addElements": [{"kind": "text", "name": "Label", "x": 0.0417, "y": 0.0556, "w": 0.5, "h": 0.05, "phone": {"x": 0.056, "y": 0.04, "w": 0.8, "h": 0.03, "size": 36}, "text": "MORAPAY LIVE \u00b7 EP 1", "size": 48, "weight": "semibold", "color": "#9AA3B2"}, {"kind": "rect", "name": "Rule", "x": 0.0417, "y": 0.42, "w": 0.083, "h": 0.006, "phone": {"x": 0.056, "y": 0.4, "w": 0.15, "h": 0.003}, "fill": "#6B9FE0"}, {"kind": "text", "name": "Headline", "x": 0.0417, "y": 0.44, "w": 0.8, "h": 0.2, "phone": {"x": 0.056, "y": 0.42, "w": 0.89, "h": 0.16, "size": 150}, "text": "Stablecoin Rails for Africa", "size": 200, "weight": "bold"}, {"kind": "text", "name": "Host", "x": 0.0417, "y": 0.86, "w": 0.5, "h": 0.06, "phone": {"x": 0.056, "y": 0.9, "w": 0.8, "h": 0.03, "size": 36}, "text": "Kaleel, Founder, Morapay", "size": 48, "weight": "semibold", "color": "#9AA3B2"}], "groupName": "Agent Original Test"}"##),
                    ("template_instantiate", ##"{"templateId": "blank", "title": "Agenda", "addElements": [{"kind": "text", "name": "Label", "x": 0.0417, "y": 0.0556, "w": 0.3, "h": 0.05, "phone": {"x": 0.056, "y": 0.04, "w": 0.8, "h": 0.03, "size": 36}, "text": "TODAY", "size": 48, "weight": "semibold", "color": "#6B9FE0"}, {"kind": "text", "name": "Headline", "x": 0.0417, "y": 0.12, "w": 0.28, "h": 0.4, "phone": {"x": 0.056, "y": 0.08, "w": 0.89, "h": 0.1, "size": 90}, "text": "Three things to know", "size": 120, "weight": "bold"}, {"kind": "rect", "name": "Divider", "x": 0.375, "y": 0.0556, "w": 0.0021, "h": 0.89, "phone": {"x": 0.056, "y": 0.2, "w": 0.89, "h": 0.002}, "fill": "#25252A"}, {"kind": "text", "name": "Item 1", "x": 0.4167, "y": 0.12, "w": 0.54, "h": 0.2, "phone": {"x": 0.056, "y": 0.26, "w": 0.89, "h": 0.15, "size": 90}, "text": "01  Why payments stall", "size": 120, "weight": "bold"}, {"kind": "text", "name": "Item 2", "x": 0.4167, "y": 0.4, "w": 0.54, "h": 0.2, "phone": {"x": 0.056, "y": 0.46, "w": 0.89, "h": 0.15, "size": 90}, "text": "02  How settlement works", "size": 120, "weight": "bold"}, {"kind": "text", "name": "Item 3", "x": 0.4167, "y": 0.68, "w": 0.54, "h": 0.2, "phone": {"x": 0.056, "y": 0.66, "w": 0.89, "h": 0.15, "size": 90}, "text": "03  Live questions", "size": 120, "weight": "bold"}]}"##),
                    ("template_instantiate", ##"{"templateId": "blank", "title": "The Gap", "addElements": [{"kind": "text", "name": "Label", "x": 0.0417, "y": 0.0556, "w": 0.4, "h": 0.05, "phone": {"x": 0.056, "y": 0.04, "w": 0.8, "h": 0.03, "size": 36}, "text": "THE PROBLEM", "size": 48, "weight": "semibold", "color": "#9AA3B2"}, {"kind": "text", "name": "Big Number", "x": 0.0417, "y": 0.2, "w": 0.5, "h": 0.45, "phone": {"x": 0.056, "y": 0.12, "w": 0.89, "h": 0.25, "size": 300}, "text": "3 days", "size": 400, "weight": "bold", "color": "#6B9FE0"}, {"kind": "text", "name": "Caption", "x": 0.0417, "y": 0.7, "w": 0.45, "h": 0.1, "phone": {"x": 0.056, "y": 0.4, "w": 0.89, "h": 0.06, "size": 90}, "text": "Average cross-border settlement", "size": 120, "weight": "semibold"}, {"kind": "rect", "name": "Panel", "x": 0.5833, "y": 0.0556, "w": 0.375, "h": 0.89, "phone": {"x": 0.056, "y": 0.52, "w": 0.89, "h": 0.42}, "fill": "#1B1B1F"}, {"kind": "text", "name": "Panel Note", "x": 0.6042, "y": 0.12, "w": 0.33, "h": 0.3, "phone": {"x": 0.08, "y": 0.55, "w": 0.84, "h": 0.2, "size": 90}, "text": "Fees average 6 percent", "size": 120, "weight": "semibold"}]}"##),
                    ("template_instantiate", ##"{"templateId": "blank", "title": "Flow", "addElements": [{"kind": "text", "name": "Label", "x": 0.0417, "y": 0.0556, "w": 0.4, "h": 0.05, "phone": {"x": 0.056, "y": 0.04, "w": 0.8, "h": 0.03, "size": 36}, "text": "HOW IT WORKS", "size": 48, "weight": "semibold", "color": "#9AA3B2"}, {"kind": "text", "name": "Headline", "x": 0.0417, "y": 0.12, "w": 0.7, "h": 0.14, "phone": {"x": 0.056, "y": 0.08, "w": 0.89, "h": 0.08, "size": 90}, "text": "Send to settle in seconds", "size": 120, "weight": "bold"}, {"kind": "rect", "name": "Track", "x": 0.0417, "y": 0.55, "w": 0.9167, "h": 0.004, "phone": {"x": 0.11, "y": 0.22, "w": 0.003, "h": 0.7}, "fill": "#6B9FE0"}, {"kind": "text", "name": "Step 1", "x": 0.0417, "y": 0.6, "w": 0.2, "h": 0.1, "phone": {"x": 0.15, "y": 0.24, "w": 0.7, "h": 0.06, "size": 36}, "text": "Send", "size": 48, "weight": "semibold"}, {"kind": "text", "name": "Step 2", "x": 0.2917, "y": 0.6, "w": 0.2, "h": 0.1, "phone": {"x": 0.15, "y": 0.42, "w": 0.7, "h": 0.06, "size": 36}, "text": "Convert", "size": 48, "weight": "semibold"}, {"kind": "text", "name": "Step 3", "x": 0.5417, "y": 0.6, "w": 0.2, "h": 0.1, "phone": {"x": 0.15, "y": 0.6, "w": 0.7, "h": 0.06, "size": 36}, "text": "Settle", "size": 48, "weight": "semibold"}, {"kind": "text", "name": "Step 4", "x": 0.7917, "y": 0.6, "w": 0.2, "h": 0.1, "phone": {"x": 0.15, "y": 0.78, "w": 0.7, "h": 0.06, "size": 36}, "text": "Receive", "size": 48, "weight": "semibold"}]}"##),
                    ("template_instantiate", ##"{"templateId": "blank", "title": "Guest", "addElements": [{"kind": "video", "name": "Camera", "x": 0, "y": 0, "w": 0.625, "h": 1, "phone": {"x": 0, "y": 0, "w": 1, "h": 0.55}}, {"kind": "rect", "name": "Info Panel", "x": 0.625, "y": 0, "w": 0.375, "h": 1, "phone": {"x": 0, "y": 0.55, "w": 1, "h": 0.45}, "fill": "#1B1B1F"}, {"kind": "text", "name": "Name", "x": 0.6667, "y": 0.6, "w": 0.3, "h": 0.08, "phone": {"x": 0.056, "y": 0.62, "w": 0.89, "h": 0.05, "size": 90}, "text": "Kaleel", "size": 120, "weight": "bold"}, {"kind": "text", "name": "Role", "x": 0.6667, "y": 0.7, "w": 0.3, "h": 0.06, "phone": {"x": 0.056, "y": 0.68, "w": 0.89, "h": 0.03, "size": 36}, "text": "Founder, Morapay", "size": 48, "weight": "semibold", "color": "#6B9FE0"}]}"##)
                ]
                let step = messages[(messages.lastIndex { $0.role == .user } ?? 0)...].filter { $0.role == .tool }.count
                if step < steps.count, !tools.isEmpty { call(steps[step].0, steps[step].1) } else { continuation.yield(.delta("Staged 5 original slides.")) }
                continuation.finish(); return
            }
            if script == "templates" {
                let g = #""groupName":"Agent Template Test""#
                let steps: [(String, String)] = [
                    ("get_project_context", "{}"),
                    ("templates_list", "{}"),
                    ("template_instantiate", ##"{"templateId":"title_card","title":"Cold Open",\##(g),"slots":{"Headline":"Stablecoin Rails for Africa","Subline":"Morapay Live, Episode 1","Host Name":"Kaleel","Host Role":"Founder, Morapay","Show Name":"MORAPAY LIVE"}}"##),
                    ("template_instantiate", ##"{"templateId":"next_up","title":"Next Up","slots":{"Item 1":"Why payments are slow","Item 2":"How Morapay settles","Item 3":"Live Q&A"}}"##),
                    ("template_instantiate", ##"{"templateId":"stat_cards","title":"The Problem","slots":{"Stat Label 1":"Avg fees","Stat Label 2":"Settlement","Stat Label 3":"Unbanked"},"addElements":[{"kind":"text","name":"Source","text":"Sources: TBD","x":0.0625,"y":0.88,"w":0.5,"h":0.04,"size":40,"color":"#9AA3B2"}]}"##),
                    ("template_instantiate", ##"{"templateId":"process_steps","title":"How It Works","style":{"accent":"#C6FF3D"}}"##),
                    ("template_instantiate", ##"{"templateId":"bloomberg","title":"Guest Intro","slots":{"Name":"Kaleel","Role":"Founder, Morapay","Location":"ACCRA","Headline":"STABLECOIN RAILS GO MAINSTREAM IN AFRICA"}}"##),
                ]
                let step = messages[(messages.lastIndex { $0.role == .user } ?? 0)...].filter { $0.role == .tool }.count
                if step < steps.count, !tools.isEmpty { call(steps[step].0, steps[step].1) } else { continuation.yield(.delta("Staged 5 template slides.")) }
                continuation.finish(); return
            }
            let lastPatchId: String? = toolResults.last.flatMap { msg in
                (try? JSONSerialization.jsonObject(with: Data((msg.content ?? "").utf8)) as? [String: Any])?["patchId"] as? String
            }
            switch step {
            case 0: call("get_project_context", "{}")
            case 1: call("compose_patch_validate", #"{"patch":\#(Self.patch(1...3))}"#)
            case 2: call("compose_patch_apply_preview", #"{"patchId":"\#(lastPatchId ?? "")","groupName":"Morapay Live: Stablecoin Rails for Africa"}"#)
            case 3: call("compose_patch_apply_preview", #"{"patch":\#(Self.patch(4...6)),"append":true}"#)
            case 4: call("compose_patch_apply_preview", #"{"patch":\#(Self.patch(7...10)),"append":true}"#)
            default: continuation.yield(.delta("Done."))
            }
            continuation.finish()
        }
    }
}
