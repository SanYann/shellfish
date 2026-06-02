// Session + ConversationLoop — the headless conversation kernel.
//
// Stage 4 Phase 4.2:
//   - Session: capability set + workspace + transcript.
//   - ConversationLoop: drives turns of (LLM → tool_use? → broker → ToolRunner
//     → tool_result → LLM ...) until Claude stops calling tools.
//
// What this PoC keeps in scope:
//   - One Anthropic provider, one workspace, one session at a time.
//   - In-process PermissionBroker (same as HarnessS2). XPC promotion is v1.
//   - Approval is delegated to a callback the caller provides (Chat reads
//     stdin; a future SwiftUI shell would show NSAlert).
//   - Tool execution happens under the strict sandbox profile.
//
// Out of scope (deliberately):
//   - Streaming. Phase 4.5 adds it alongside the UI.
//   - Audit log. Phase 4.4.
//   - Multi-provider, MCP, export/import. Phase 4.5+.

import Foundation

// MARK: - Session

public struct Session: Sendable {
    public let id: String
    public let workspacePath: String       // absolute path
    public let capabilities: Capabilities
    public let tools: [ToolDef]
    public let systemPrompt: String?
    public let sandboxProfilePath: String  // strict profile, used by fs.* tools
    public let networkProfilePath: String? // network profile, used by http_fetch
    public let toolRunnerPath: String      // absolute path to ToolRunner binary
    public let buildDirPath: String        // for sandbox-exec -D BUILDDIR

    public init(
        id: String = UUID().uuidString,
        workspacePath: String,
        capabilities: Capabilities,
        tools: [ToolDef],
        systemPrompt: String?,
        sandboxProfilePath: String,
        networkProfilePath: String? = nil,
        toolRunnerPath: String,
        buildDirPath: String
    ) {
        self.id = id
        self.workspacePath = workspacePath
        self.capabilities = capabilities
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.sandboxProfilePath = sandboxProfilePath
        self.networkProfilePath = networkProfilePath
        self.toolRunnerPath = toolRunnerPath
        self.buildDirPath = buildDirPath
    }
}

// MARK: - Approval callback

public enum ApprovalDecision: Sendable {
    case once          // approve this call only
    case session       // approve this and all identical follow-ups in this session
    case deny          // deny this call (Claude sees an is_error result)
    case denyAndKill   // deny and exit the conversation
}

public typealias ApprovalCallback = @Sendable (ToolCall) async -> ApprovalDecision

// MARK: - Turn events

/// Fired by ConversationLoop during a turn so the UI can render tool
/// activity inline in the chat (not only behind an approval sheet).
public enum TurnEvent: Sendable {
    /// Incremental assistant text. Emitted as tokens stream from the model.
    case textDelta(String)
    /// A tool call has been approved and is about to run.
    case toolCall(name: String, args: [String: String], id: String)
    /// A tool call finished. `summary` is a short string for the UI
    /// (full content goes through the model, not here).
    case toolResult(toolUseId: String, success: Bool, summary: String)
    /// Transient operational note for the UI, e.g. "retrying after overload".
    /// Not part of the model conversation — purely a status hint.
    case notice(String)
}

public typealias EventCallback = @Sendable (TurnEvent) async -> Void

// MARK: - Conversation loop

public final class ConversationLoop: @unchecked Sendable {
    private let session: Session
    private let provider: AnthropicProvider
    private let broker: PermissionBroker
    private let approve: ApprovalCallback
    private let event: EventCallback?
    private let audit: AuditLogger?
    private var transcript: [ConversationTurn] = []
    private var sessionApprovedKeys: Set<String> = []

    public init(
        session: Session,
        provider: AnthropicProvider,
        approvalCallback: @escaping ApprovalCallback,
        eventCallback: EventCallback? = nil,
        auditLogger: AuditLogger? = nil
    ) {
        self.session = session
        self.provider = provider
        self.broker = PermissionBroker(capabilities: session.capabilities)
        self.approve = approvalCallback
        self.event = eventCallback
        self.audit = auditLogger
    }

    /// Result of a single user turn — final assistant text plus any per-tool
    /// notes the caller might want to surface in the UI.
    public struct TurnResult: Sendable {
        public let assistantText: String
        public let killed: Bool   // user picked "deny and kill"
    }

    public func runTurn(userInput: String) async throws -> TurnResult {
        transcript.append(.user(userInput))

        var killed = false
        var lastText = ""

        loop: while true {
            // Stream when a UI is attached (so deltas can render live); use
            // the non-streaming path for headless CLI runs.
            let response: AssistantMessage
            if let event = self.event {
                response = try await provider.sendStreaming(
                    turns: transcript,
                    system: session.systemPrompt,
                    tools: session.tools,
                    onTextDelta: { delta in
                        await event(.textDelta(delta))
                    },
                    onRetry: { msg in
                        await event(.notice(msg))
                    }
                )
            } else {
                response = try await provider.send(
                    turns: transcript,
                    system: session.systemPrompt,
                    tools: session.tools
                )
            }

            // Capture assistant text from this round.
            lastText = response.textBlocks.joined(separator: "\n")

            // Echo the assistant's content back into the transcript verbatim
            // so the next API call sees the same conversation history.
            var assistantBlocks: [ConversationTurn.Block] = []
            for text in response.textBlocks {
                assistantBlocks.append(.text(text))
            }
            for use in response.toolUses {
                assistantBlocks.append(.toolUse(id: use.id, name: use.name, inputJSON: use.inputJSON))
            }
            transcript.append(.init(role: "assistant", blocks: assistantBlocks))

            // No tool uses → Claude is done.
            if response.toolUses.isEmpty {
                break loop
            }

            // Resolve each tool use → tool_result. They go back as a single
            // user turn per the Anthropic protocol.
            var resultBlocks: [ConversationTurn.Block] = []
            for use in response.toolUses {
                let resolved = await resolveToolUse(use)
                resultBlocks.append(.toolResult(
                    toolUseId: use.id,
                    content: resolved.content,
                    isError: resolved.isError
                ))
                if resolved.kill {
                    killed = true
                }
            }
            transcript.append(.init(role: "user", blocks: resultBlocks))

            if killed {
                lastText = "[conversation terminated by user]"
                break loop
            }
        }

        return TurnResult(assistantText: lastText, killed: killed)
    }

    // MARK: - Tool resolution

    private struct ResolvedTool {
        let content: String   // <tool_result>...</tool_result> envelope for the model
        let summary: String   // short string for the UI event stream
        let isError: Bool
        let kill: Bool
    }

    private func resolveToolUse(_ use: AssistantMessage.ToolUse) async -> ResolvedTool {
        // Parse the input JSON into a flat [String: String] for the broker.
        let argsAny = (try? JSONSerialization.jsonObject(with: use.inputJSON)) as? [String: Any] ?? [:]
        var args: [String: String] = [:]
        for (k, v) in argsAny {
            if let s = v as? String { args[k] = s }
        }

        let call = ToolCall(tool: use.name, args: args)

        // Layer 1: capability check (instant deny if not granted).
        switch broker.authorize(call) {
        case .deny(let reason):
            audit?.logCapabilityCheck(tool: call.tool, args: call.args, approved: false, reason: reason)
            return ResolvedTool(
                content: "<tool_result source=\"untrusted\">Permission denied: \(reason)</tool_result>",
                summary: "denied: \(reason)",
                isError: true,
                kill: false
            )
        case .approve:
            audit?.logCapabilityCheck(tool: call.tool, args: call.args, approved: true, reason: nil)
        }

        // Layer 2: per-call approval (cached if user picked "session" before).
        let approvalKey = callKey(call)
        if sessionApprovedKeys.contains(approvalKey) {
            FileHandle.standardError.write(Data("[approval] cached for this session: \(call.tool)\n".utf8))
            audit?.logUserApproval(tool: call.tool, args: call.args, decision: "session_cached", cached: true)
        } else {
            let decision = await approve(call)
            switch decision {
            case .once:
                audit?.logUserApproval(tool: call.tool, args: call.args, decision: "once", cached: false)
            case .session:
                audit?.logUserApproval(tool: call.tool, args: call.args, decision: "session", cached: false)
                sessionApprovedKeys.insert(approvalKey)
            case .deny:
                audit?.logUserApproval(tool: call.tool, args: call.args, decision: "deny", cached: false)
                return ResolvedTool(
                    content: "<tool_result source=\"untrusted\">User denied this tool call.</tool_result>",
                    summary: "denied by user",
                    isError: true,
                    kill: false
                )
            case .denyAndKill:
                audit?.logUserApproval(tool: call.tool, args: call.args, decision: "deny_and_kill", cached: false)
                return ResolvedTool(
                    content: "<tool_result source=\"untrusted\">User denied this tool call and terminated the session.</tool_result>",
                    summary: "denied + session killed",
                    isError: true,
                    kill: true
                )
            }
        }

        // Layer 3: execute the tool under sandbox-exec.
        // Emit the toolCall event now — only for calls that actually run.
        await event?(.toolCall(name: call.tool, args: call.args, id: use.id))

        FileHandle.standardError.write(Data("[tool] \(call.tool) invoked under sandbox-exec\n".utf8))
        let result = await invokeToolRunner(toolName: call.tool, argsJSON: use.inputJSON)
        audit?.logToolResult(
            tool: call.tool,
            args: call.args,
            success: !result.isError,
            output: result.isError ? nil : result.content,
            // Log the clean summary, not the model-facing <tool_result> envelope.
            error: result.isError ? result.summary : nil
        )
        await event?(.toolResult(toolUseId: use.id, success: !result.isError, summary: result.summary))
        return result
    }

    private func callKey(_ call: ToolCall) -> String {
        let sorted = call.args.sorted { $0.key < $1.key }
        let argsString = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(call.tool)::\(argsString)"
    }

    private func invokeToolRunner(toolName: String, argsJSON: Data) async -> ResolvedTool {
        // ToolRunner's switch expects dot-style names ("fs.read"). Map back.
        let internalName: String
        switch toolName {
        case "fs_read":  internalName = "fs.read"
        case "fs_write": internalName = "fs.write"
        case "fs_list":  internalName = "fs.list"
        default:         internalName = toolName
        }

        // Build the tool call JSON ToolRunner expects: {"tool":..., "args":{...}}.
        let argsObj = (try? JSONSerialization.jsonObject(with: argsJSON)) ?? [:]
        let toolCallObj: [String: Any] = [
            "tool": internalName,
            "args": argsObj,
        ]
        guard let toolCallData = try? JSONSerialization.data(withJSONObject: toolCallObj) else {
            return ResolvedTool(
                content: "<tool_result source=\"untrusted\">Failed to build tool call JSON.</tool_result>",
                summary: "internal error: bad JSON",
                isError: true,
                kill: false
            )
        }

        // Pick the sandbox profile per tool: http_fetch runs under the
        // network profile (outbound allowed, /Users still unreadable); every
        // filesystem tool runs under the strict profile (no network at all).
        // The two capabilities therefore never share a process — the OS never
        // lets one ToolRunner both read user data and reach the network.
        let isFetch = (toolName == "http_fetch")
        let profilePath = isFetch
            ? (session.networkProfilePath ?? session.sandboxProfilePath)
            : session.sandboxProfilePath

        // Spawn /usr/bin/sandbox-exec ... /path/to/ToolRunner.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-D", "WORKSPACE=\(session.workspacePath)",
            "-D", "BUILDDIR=\(session.buildDirPath)",
            "-f", profilePath,
            session.toolRunnerPath,
        ]

        // ToolRunner reads SHELLFISH_WORKSPACE for its application-level path
        // check, and SHELLFISH_NETFETCH_ALLOW to re-validate the fetch host.
        var env = ProcessInfo.processInfo.environment
        env["SHELLFISH_WORKSPACE"] = session.workspacePath
        if isFetch {
            env["SHELLFISH_NETFETCH_ALLOW"] = session.capabilities.netFetch.joined(separator: ",")
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ResolvedTool(
                content: "<tool_result source=\"untrusted\">Failed to launch ToolRunner: \(error)</tool_result>",
                summary: "launch failed: \(error)",
                isError: true,
                kill: false
            )
        }

        try? stdinPipe.fileHandleForWriting.write(contentsOf: toolCallData)
        try? stdinPipe.fileHandleForWriting.close()

        // Wait for exit with a 30s hard cap. Poll cooperatively (no blocked
        // thread) so the turn stays cancellable: Stop terminates the
        // subprocess, and a hung tool can't wedge the session forever.
        var waited = 0.0
        var endReason = "exited"
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                endReason = "cancelled"
                break
            }
            if waited >= 30.0 {
                process.terminate()
                endReason = "timeout"
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            waited += 0.05
        }
        process.waitUntilExit()

        if endReason == "timeout" {
            return ResolvedTool(
                content: "<tool_result source=\"untrusted\">ToolRunner exceeded the 30s limit and was terminated.</tool_result>",
                summary: "timed out after 30s",
                isError: true,
                kill: false
            )
        }
        if endReason == "cancelled" {
            return ResolvedTool(
                content: "<tool_result source=\"untrusted\">Tool call cancelled.</tool_result>",
                summary: "cancelled",
                isError: true,
                kill: false
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let exit = process.terminationStatus
        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""

        // Parse ToolRunner's JSON {success, output, error}.
        if let parsed = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] {
            let success = parsed["success"] as? Bool ?? false
            let output = parsed["output"] as? String
            let errorMsg = parsed["error"] as? String
            if success, let output = output {
                // Tag the result's origin: a fetched page is labelled with its
                // URL (so the model sees external, untrusted provenance), a
                // file with the workspace it came from.
                let origin: String
                if isFetch,
                   let obj = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                   let url = obj["url"] as? String {
                    origin = url
                } else {
                    origin = session.workspacePath
                }
                let wrapped = "<tool_result source=\"untrusted\" origin=\"\(origin)\">\n\(output)\n</tool_result>"
                let oneLine = output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                let summary: String
                if toolName == "fs_write" || toolName == "fs.write" {
                    // ToolRunner's write confirmation already states the byte
                    // count ("Wrote N bytes to …"). Prefixing the length of
                    // *that message* is just noise, so show it as-is — with the
                    // workspace prefix stripped so the path reads cleanly.
                    summary = oneLine.replacingOccurrences(of: session.workspacePath + "/", with: "")
                } else {
                    // Reads/lists: the output IS the data, so its size is the
                    // meaningful number. Short results get inlined too.
                    let bytes = output.utf8.count
                    summary = bytes <= 80 ? "\(bytes) B · \(oneLine)" : "\(bytes) B"
                }
                return ResolvedTool(content: wrapped, summary: summary, isError: false, kill: false)
            } else {
                return ResolvedTool(
                    content: "<tool_result source=\"untrusted\">Tool failed: \(errorMsg ?? "unknown error")</tool_result>",
                    summary: errorMsg ?? "unknown error",
                    isError: true,
                    kill: false
                )
            }
        }

        // ToolRunner crashed before emitting a result.
        return ResolvedTool(
            content: "<tool_result source=\"untrusted\">ToolRunner exited \(exit) with no result. stdout: \(stdoutString)</tool_result>",
            summary: "ToolRunner exited \(exit) with no result",
            isError: true,
            kill: false
        )
    }
}
