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

    public func send(
        turns: [ConversationTurn],
        system: String? = nil,
        tools: [ToolDef] = []
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicError.transportError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse(status: -1, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard (200..<300).contains(http.statusCode) else {
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
}
