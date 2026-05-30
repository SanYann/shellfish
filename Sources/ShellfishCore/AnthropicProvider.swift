// Minimal Anthropic API client.
//
// Scope of THIS file (Stage 4 Phase 4.1):
//   - POST /v1/messages with a list of messages + optional tools.
//   - Parse the response into text blocks + tool_use blocks.
//   - No streaming. Streaming is Phase 4.5 (it pairs with the UI).
//
// Design notes:
//   - Uses URLSession + JSONSerialization deliberately. No Codable acrobatics
//     for content blocks. The Anthropic content array is heterogeneous (text,
//     tool_use, tool_result) and `[String: Any]` is the honest shape.
//   - Hardcodes `claude-opus-4-7` per the Anthropic skill's guidance.
//     Adaptive thinking only on 4.7; no temperature/top_p/top_k.
//   - API key comes from the env var ANTHROPIC_API_KEY. For Stage 4 this is
//     fine. v1 moves it to Keychain (threat model §4.1).

import Foundation

public struct ToolDef: Sendable {
    public let name: String
    public let description: String
    /// JSON-encoded object describing the tool's input schema.
    /// Example: `{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}`
    public let inputSchemaJSON: Data

    public init(name: String, description: String, inputSchemaJSON: Data) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }

    /// Convenience: build from a Swift dictionary.
    public init(name: String, description: String, inputSchema: [String: Any]) throws {
        self.name = name
        self.description = description
        self.inputSchemaJSON = try JSONSerialization.data(withJSONObject: inputSchema)
    }
}

public enum AnthropicError: Error, Sendable {
    case missingAPIKey
    case invalidResponse(status: Int, body: String)
    case decodingFailed(String)
    case transportError(Error)
}

public struct AssistantMessage: Sendable {
    public struct ToolUse: Sendable {
        public let id: String
        public let name: String
        public let inputJSON: Data  // raw JSON object; parse on demand
    }
    public let textBlocks: [String]
    public let toolUses: [ToolUse]
    public let stopReason: String

    public init(textBlocks: [String], toolUses: [ToolUse], stopReason: String) {
        self.textBlocks = textBlocks
        self.toolUses = toolUses
        self.stopReason = stopReason
    }
}

/// Represents one turn in the conversation history sent back to the API.
public struct ConversationTurn: Sendable {
    public enum Block: Sendable {
        case text(String)
        case toolUse(id: String, name: String, inputJSON: Data)
        case toolResult(toolUseId: String, content: String, isError: Bool)
    }
    public let role: String   // "user" or "assistant"
    public let blocks: [Block]

    public init(role: String, blocks: [Block]) {
        self.role = role
        self.blocks = blocks
    }

    public static func user(_ text: String) -> ConversationTurn {
        .init(role: "user", blocks: [.text(text)])
    }
}

public actor AnthropicProvider {
    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let session: URLSession
    /// How many times to retry a transient failure before giving up.
    private let maxRetries = 4

    public init(
        apiKey: String? = nil,
        model: String = "claude-opus-4-7",
        maxTokens: Int = 4096,
        session: URLSession = .shared
    ) throws {
        let resolvedKey = apiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        guard let key = resolvedKey, !key.isEmpty else {
            throw AnthropicError.missingAPIKey
        }
        self.apiKey = key
        self.model = model
        self.maxTokens = maxTokens
        self.session = session
    }

    // MARK: - Retry policy

    /// HTTP statuses worth retrying: rate limit (429), overloaded (529), and
    /// transient server errors (5xx). Other 4xx are caller errors — not
    /// retried, because resending won't help.
    private func isTransient(_ status: Int) -> Bool {
        status == 429 || status == 529 || (500...599).contains(status)
    }

    /// Human-readable label for a transient status, used in retry notices.
    private func statusLabel(_ status: Int) -> String {
        switch status {
        case 429: return "rate limit"
        case 529: return "overloaded"
        default:  return "server error \(status)"
        }
    }

    /// Sleep with exponential backoff before the next attempt. Honors a
    /// server-sent Retry-After (seconds) when present, otherwise backs off
    /// 0.5s, 1s, 2s, 4s … capped. `Task.sleep` throws on cancellation, so the
    /// Stop button still interrupts a turn that's mid-backoff.
    private func sleepBackoff(attempt: Int, retryAfter: String?) async throws {
        let delay: TimeInterval
        if let retryAfter, let secs = Double(retryAfter) {
            delay = min(secs, 30)
        } else {
            delay = min(pow(2.0, Double(attempt)) * 0.5, 8.0)
        }
        FileHandle.standardError.write(Data("[anthropic] transient failure, retrying in \(delay)s (attempt \(attempt + 1)/\(maxRetries))\n".utf8))
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    public func send(
        turns: [ConversationTurn],
        system: String? = nil,
        tools: [ToolDef] = [],
        onRetry: (@Sendable (String) async -> Void)? = nil
    ) async throws -> AssistantMessage {
        // Build request body as raw [String: Any].
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
        ]
        if let system = system, !system.isEmpty {
            body["system"] = system
        }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                let schema = try JSONSerialization.jsonObject(with: tool.inputSchemaJSON)
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": schema,
                ]
            }
        }
        body["messages"] = turns.map { turn -> [String: Any] in
            [
                "role": turn.role,
                "content": turn.blocks.map { block -> [String: Any] in
                    switch block {
                    case .text(let t):
                        return ["type": "text", "text": t]
                    case .toolUse(let id, let name, let input):
                        let parsed = (try? JSONSerialization.jsonObject(with: input)) ?? [:]
                        return ["type": "tool_use", "id": id, "name": name, "input": parsed]
                    case .toolResult(let id, let content, let isError):
                        var block: [String: Any] = [
                            "type": "tool_result",
                            "tool_use_id": id,
                            "content": content,
                        ]
                        if isError { block["is_error"] = true }
                        return block
                    }
                },
            ]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData
        request.timeoutInterval = 120

        var data = Data()
        var attempt = 0
        while true {
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                // Network blip — retry a few times, then surface it.
                if attempt < maxRetries {
                    await onRetry?("Network hiccup, retrying (\(attempt + 1)/\(maxRetries))…")
                    try await sleepBackoff(attempt: attempt, retryAfter: nil)
                    attempt += 1
                    continue
                }
                throw AnthropicError.transportError(error)
            }
            guard let http = response as? HTTPURLResponse else {
                throw AnthropicError.invalidResponse(status: -1, body: String(data: data, encoding: .utf8) ?? "")
            }
            if (200..<300).contains(http.statusCode) {
                break
            }
            if isTransient(http.statusCode), attempt < maxRetries {
                await onRetry?("Anthropic \(statusLabel(http.statusCode)), retrying (\(attempt + 1)/\(maxRetries))…")
                try await sleepBackoff(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "retry-after"))
                attempt += 1
                continue
            }
            throw AnthropicError.invalidResponse(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicError.decodingFailed("response not a JSON object")
        }
        guard let content = json["content"] as? [[String: Any]] else {
            throw AnthropicError.decodingFailed("missing 'content' array")
        }
        let stopReason = (json["stop_reason"] as? String) ?? "unknown"

        var texts: [String] = []
        var toolUses: [AssistantMessage.ToolUse] = []
        for block in content {
            let type = block["type"] as? String ?? ""
            switch type {
            case "text":
                if let t = block["text"] as? String { texts.append(t) }
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                let inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
                toolUses.append(.init(id: id, name: name, inputJSON: inputData))
            default:
                // Ignore thinking blocks and any unknown types for now.
                break
            }
        }

        return AssistantMessage(
            textBlocks: texts,
            toolUses: toolUses,
            stopReason: stopReason
        )
    }

    // MARK: - Streaming

    /// Same as `send`, but streams the response as Server-Sent Events.
    /// `onTextDelta` is called once per text-delta chunk as it arrives.
    /// Tool-use blocks are accumulated server-side and returned whole at
    /// the end — the SSE format streams their input JSON as deltas too,
    /// but for the chat UX the tool call is short and only meaningful
    /// when complete.
    public func sendStreaming(
        turns: [ConversationTurn],
        system: String? = nil,
        tools: [ToolDef] = [],
        onTextDelta: @Sendable @escaping (String) async -> Void,
        onRetry: (@Sendable (String) async -> Void)? = nil
    ) async throws -> AssistantMessage {
        // Build the request body identically to `send`, plus stream: true.
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
        ]
        if let system = system, !system.isEmpty {
            body["system"] = system
        }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                let schema = try JSONSerialization.jsonObject(with: tool.inputSchemaJSON)
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": schema,
                ]
            }
        }
        body["messages"] = turns.map { turn -> [String: Any] in
            [
                "role": turn.role,
                "content": turn.blocks.map { block -> [String: Any] in
                    switch block {
                    case .text(let t):
                        return ["type": "text", "text": t]
                    case .toolUse(let id, let name, let input):
                        let parsed = (try? JSONSerialization.jsonObject(with: input)) ?? [:]
                        return ["type": "tool_use", "id": id, "name": name, "input": parsed]
                    case .toolResult(let id, let content, let isError):
                        var block: [String: Any] = [
                            "type": "tool_result",
                            "tool_use_id": id,
                            "content": content,
                        ]
                        if isError { block["is_error"] = true }
                        return block
                    }
                },
            ]
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData
        // Per-request timeout for the initial response; the stream itself
        // can run long without tripping the resource timeout.
        request.timeoutInterval = 120

        // Retry transient failures here — before any text delta is emitted, so
        // a retry can't duplicate streamed output. A mid-stream error event
        // (rare) is still a hard fail since deltas may already be on screen.
        var bytes: URLSession.AsyncBytes!
        var attempt = 0
        while true {
            let attemptBytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (attemptBytes, response) = try await session.bytes(for: request)
            } catch {
                if attempt < maxRetries {
                    await onRetry?("Network hiccup, retrying (\(attempt + 1)/\(maxRetries))…")
                    try await sleepBackoff(attempt: attempt, retryAfter: nil)
                    attempt += 1
                    continue
                }
                throw AnthropicError.transportError(error)
            }
            guard let http = response as? HTTPURLResponse else {
                throw AnthropicError.invalidResponse(status: -1, body: "")
            }
            if (200..<300).contains(http.statusCode) {
                bytes = attemptBytes
                break
            }
            // Non-2xx: drain a little of the body for the error message.
            var bodyText = ""
            for try await line in attemptBytes.lines {
                bodyText += line + "\n"
                if bodyText.count > 4096 { break }
            }
            if isTransient(http.statusCode), attempt < maxRetries {
                await onRetry?("Anthropic \(statusLabel(http.statusCode)), retrying (\(attempt + 1)/\(maxRetries))…")
                try await sleepBackoff(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "retry-after"))
                attempt += 1
                continue
            }
            throw AnthropicError.invalidResponse(status: http.statusCode, body: bodyText)
        }

        // Per-content-block accumulators. Anthropic's stream interleaves
        // content_block_start / content_block_delta / content_block_stop
        // for each block by index. We keep a small map by index.
        struct BlockBuilder {
            var type: String = ""
            var text: String = ""
            var toolUseId: String = ""
            var toolUseName: String = ""
            var toolUseInputJSON: String = ""
        }
        var blocks: [Int: BlockBuilder] = [:]
        var stopReason = "unknown"

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard
                let data = payload.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let kind = event["type"] as? String
            else { continue }

            switch kind {
            case "content_block_start":
                if
                    let index = event["index"] as? Int,
                    let block = event["content_block"] as? [String: Any]
                {
                    var b = BlockBuilder()
                    b.type = (block["type"] as? String) ?? ""
                    if b.type == "tool_use" {
                        b.toolUseId = (block["id"] as? String) ?? ""
                        b.toolUseName = (block["name"] as? String) ?? ""
                    }
                    blocks[index] = b
                }
            case "content_block_delta":
                if
                    let index = event["index"] as? Int,
                    let delta = event["delta"] as? [String: Any],
                    let deltaType = delta["type"] as? String
                {
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        blocks[index]?.text.append(text)
                        await onTextDelta(text)
                    } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                        blocks[index]?.toolUseInputJSON.append(partial)
                    }
                    // thinking_delta and others ignored for now.
                }
            case "content_block_stop":
                // No-op; block already accumulated.
                continue
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            case "message_stop":
                break
            case "error":
                if let err = event["error"] as? [String: Any] {
                    let msg = (err["message"] as? String) ?? String(describing: err)
                    throw AnthropicError.invalidResponse(status: -1, body: "stream error: \(msg)")
                }
            default:
                continue
            }
        }

        // Assemble the final AssistantMessage from accumulated blocks.
        var texts: [String] = []
        var toolUses: [AssistantMessage.ToolUse] = []
        for index in blocks.keys.sorted() {
            let b = blocks[index]!
            switch b.type {
            case "text":
                if !b.text.isEmpty { texts.append(b.text) }
            case "tool_use":
                let inputData = b.toolUseInputJSON.data(using: .utf8) ?? Data()
                toolUses.append(.init(id: b.toolUseId, name: b.toolUseName, inputJSON: inputData))
            default:
                continue
            }
        }

        return AssistantMessage(
            textBlocks: texts,
            toolUses: toolUses,
            stopReason: stopReason
        )
    }
}
