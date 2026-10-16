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
    static let defaultModel = "grok-4"
    /// Room for multi-slide ComposePatch JSON in one tool call.
    static let maxOutputTokens = 32_000
    static let endpoint = URL(string: "https://api.x.ai/v1/chat/completions")!

    static var model: String {
        get {
            let value = UserDefaults.standard.string(forKey: modelKey) ?? ""
            return value.isEmpty ? defaultModel : value
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
