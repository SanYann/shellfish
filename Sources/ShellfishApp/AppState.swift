// AppState — wires the SwiftUI shell to the ShellfishCore ConversationLoop.
//
// Holds the chat transcript, drives turns asynchronously, surfaces status
// messages, and routes the approval callback to the AppKit alert presenter.

import Foundation
import SwiftUI
import AppKit
import ShellfishCore

@MainActor
final class AppState: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isThinking: Bool = false
    @Published var statusText: String = "Initializing…"
    @Published var draft: String = ""
    @Published var pendingApproval: PendingApproval?
    @Published var showAudit: Bool = false
    @Published var selectedPreset: SessionPreset = SessionPreset.all[0]

    let presets = SessionPreset.all

    private var loop: ConversationLoop?
    private var initError: String?
    // Readable by the approval sheet so it can flag paths that resolve
    // outside the workspace. Set once during bootstrap.
    private(set) var workspacePath: String = ""
    // Set when the user picks a folder via "Change Workspace…"; nil uses the
    // default ./workspaces/poc.
    private var workspaceOverride: String?
    // Surfaced to the audit viewer.
    private(set) var auditLogPath: String?
    private(set) var sessionId: String = ""
    // The "Ready · workspace: …" line, restored after a turn so transient
    // retry notices don't stick in the status bar.
    private var readyStatus: String = ""
    private var currentTurnTask: Task<Void, Never>?

    // MARK: - Approval bridge
    //
    // The ConversationLoop calls an async @Sendable approval callback from a
    // background task. We bridge that to SwiftUI by suspending on a
    // continuation and surfacing the request as `pendingApproval`, which the
    // ChatView presents as a sheet. The sheet's buttons resume the
    // continuation. The sheet is non-dismissible — there is no way to escape
    // an approval decision, which is the point.

    struct PendingApproval: Identifiable {
        let id = UUID()
        let call: ToolCall
        let continuation: CheckedContinuation<ApprovalDecision, Never>
    }

    func requestApproval(_ call: ToolCall) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            // Already on the main actor (AppState is @MainActor).
            self.pendingApproval = PendingApproval(call: call, continuation: continuation)
        }
    }

    func resolveApproval(_ decision: ApprovalDecision) {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        pending.continuation.resume(returning: decision)
    }

    // MARK: - Turn events (tool activity surfaced inline)

    func handleTurnEvent(_ event: TurnEvent) {
        switch event {
        case .textDelta(let delta):
            // If the last message is already an assistant bubble for this
            // streaming block, append in place. Otherwise start a new one.
            // Tool-row events in between automatically "break" the streak
            // and start a fresh assistant bubble afterwards.
            if !messages.isEmpty, messages[messages.count - 1].role == .assistant {
                messages[messages.count - 1].text.append(delta)
            } else {
                messages.append(.init(role: .assistant, text: delta))
            }
        case .toolCall(let name, let args, _):
            messages.append(.init(role: .tool, text: renderToolCall(name: name, args: args)))
        case .toolResult(_, let success, let summary):
            let mark = success ? "✓" : "✗"
            messages.append(.init(role: .tool, text: "\(mark) \(summary)"))
        case .notice(let msg):
            // Transient operational hint (e.g. retry after overload). Show it
            // in the status bar; it's cleared back to readyStatus when the
            // turn settles.
            statusText = msg
        }
    }

    private func renderToolCall(name: String, args: [String: String]) -> String {
        if args.isEmpty { return "→ \(name)()" }
        let parts = args.sorted { $0.key < $1.key }.map { kv -> String in
            var v = kv.value
            // Render workspace-internal paths as relative — much easier to
            // scan and reinforces that everything is inside the workspace.
            let prefix = workspacePath + "/"
            if (kv.key == "path" || kv.key.hasSuffix("_path")), v.hasPrefix(prefix) {
                v = String(v.dropFirst(prefix.count))
            }
            if v.count > 60 { v = String(v.prefix(57)) + "…" }
            return "\(kv.key): \(v)"
        }
        return "→ \(name)(\(parts.joined(separator: ", ")))"
    }

    init() {
        bootstrap()
    }

    // MARK: - Public API

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking, let loop = loop else { return }
        draft = ""
        messages.append(.init(role: .user, text: text))
        isThinking = true

        currentTurnTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await loop.runTurn(userInput: text)
                await MainActor.run {
                    self.isThinking = false
                    self.currentTurnTask = nil
                    self.statusText = self.readyStatus
                    // Text already streamed in via .textDelta events; don't
                    // double-append. The exception is .killed sessions where
                    // we want a visible "terminated" marker.
                    if result.killed {
                        self.messages.append(.init(role: .system, text: "[session terminated by deny+kill]"))
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isThinking = false
                    self.currentTurnTask = nil
                    self.statusText = self.readyStatus
                    self.messages.append(.init(role: .system, text: "[stopped]"))
                }
            } catch {
                await MainActor.run {
                    self.isThinking = false
                    self.currentTurnTask = nil
                    self.statusText = self.readyStatus
                    self.messages.append(.init(role: .system, text: self.friendlyError(error)))
                }
            }
        }
    }

    /// Turn the raw provider error into something a person can act on.
    /// The provider already retried transient failures with backoff, so by
    /// the time we land here the failure is either persistent or exhausted
    /// its retries — tell the user whether to just resend or fix something.
    private func friendlyError(_ error: Error) -> String {
        guard let e = error as? AnthropicError else {
            return "Turn failed: \(error)"
        }
        switch e {
        case .invalidResponse(let status, _):
            switch status {
            case 429: return "Anthropic rate limit hit. Give it a few seconds and resend."
            case 529: return "Anthropic is overloaded right now. Give it a few seconds and resend."
            case 401: return "API key rejected (401). Check ANTHROPIC_API_KEY."
            default:  return "Anthropic API error (\(status)). Resend to try again."
            }
        case .transportError:
            return "Network error reaching Anthropic. Check your connection and resend."
        case .missingAPIKey:
            return "ANTHROPIC_API_KEY is not set."
        case .decodingFailed(let why):
            return "Couldn't parse the API response: \(why)"
        }
    }

    /// User pressed Stop. Cancels any in-flight turn and resolves any
    /// open approval prompt with denyAndKill so the loop exits cleanly.
    func stop() {
        if let pending = pendingApproval {
            pendingApproval = nil
            pending.continuation.resume(returning: .denyAndKill)
        }
        currentTurnTask?.cancel()
        currentTurnTask = nil
        isThinking = false
    }

    // MARK: - Bootstrap

    /// Start a fresh session: new id, new conversation loop, cleared
    /// transcript. The audit log is append-only so it carries across.
    func newSession() {
        bootstrap()
    }

    /// Switch capability preset (read-only vs read/write). Starts a fresh
    /// session because capabilities are fixed for a session's lifetime.
    func selectPreset(_ preset: SessionPreset) {
        guard preset.id != selectedPreset.id else { return }
        selectedPreset = preset
        bootstrap()
    }

    /// Let the user point the session at a different folder. Tools stay
    /// confined to whatever is chosen. Starts a fresh session.
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Workspace"
        panel.message = "Pick a folder for this Shellfish session. Tools are confined to it."
        if panel.runModal() == .OK, let url = panel.url {
            workspaceOverride = url.path
            bootstrap()
        }
    }

    private func bootstrap() {
        // Idempotent — newSession() calls this again, so tear down prior state.
        if let pending = pendingApproval {
            pending.continuation.resume(returning: .denyAndKill)
            pendingApproval = nil
        }
        currentTurnTask?.cancel()
        currentTurnTask = nil
        isThinking = false
        messages.removeAll()

        let cwd = FileManager.default.currentDirectoryPath
        let workspacePath = workspaceOverride ?? "\(cwd)/workspaces/poc"
        self.workspacePath = workspacePath
        let sandboxProfilePath = "\(cwd)/profiles/toolrunner-strict.sb"
        let toolRunnerPath = "\(cwd)/.build/debug/ToolRunner"
        let buildDirPath = "\(cwd)/.build"

        // Create the workspace on first run (fresh clones don't ship one).
        try? FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        for (label, path) in [
            ("sandbox profile", sandboxProfilePath),
            ("ToolRunner binary", toolRunnerPath),
        ] {
            guard FileManager.default.fileExists(atPath: path) else {
                statusText = "Missing \(label) at \(path)"
                messages.append(.init(role: .system, text: statusText))
                return
            }
        }

        // Tools advertised to Claude depend on the preset. A read-only session
        // never sees fs_write, and the broker also denies it at the capability
        // layer — defense the model can't talk its way around.
        let tools: [ToolDef]
        do {
            var defs: [ToolDef] = [
                try ToolDef(
                    name: "fs_read",
                    description: "Read a text file from the session workspace. Only paths inside the workspace are allowed.",
                    inputSchema: ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]
                ),
            ]
            if selectedPreset.canWrite {
                defs.append(try ToolDef(
                    name: "fs_write",
                    description: "Write text content to a file in the session workspace.",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string"],
                            "content": ["type": "string"],
                        ],
                        "required": ["path", "content"],
                    ]
                ))
            }
            defs.append(try ToolDef(
                name: "fs_list",
                description: "List the entries of a directory in the session workspace. Returns JSON [{name, isDir, size}, ...].",
                inputSchema: [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": [],
                ]
            ))
            tools = defs
        } catch {
            statusText = "Failed to build tool defs: \(error)"
            messages.append(.init(role: .system, text: statusText))
            return
        }
        let toolNames = tools.map { $0.name }.joined(separator: ", ")
        let readonlyNote = selectedPreset.canWrite
            ? ""
            : " This session is read-only — you have no way to write files."

        let session = Session(
            workspacePath: workspacePath,
            capabilities: Capabilities(
                fsRead: [workspacePath],
                fsWrite: selectedPreset.canWrite ? [workspacePath] : []
            ),
            tools: tools,
            systemPrompt: """
                You are a helpful assistant operating inside a sandboxed workspace.
                The workspace is at: \(workspacePath).
                Your tools: \(toolNames). All paths must be absolute and inside
                the workspace; reads/writes outside are denied.\(readonlyNote)
                Do not invent file contents — if a tool call fails, say so plainly.
                """,
            sandboxProfilePath: sandboxProfilePath,
            toolRunnerPath: toolRunnerPath,
            buildDirPath: buildDirPath
        )

        let provider: AnthropicProvider
        do {
            provider = try AnthropicProvider()
        } catch AnthropicError.missingAPIKey {
            statusText = "ANTHROPIC_API_KEY env var is not set."
            messages.append(.init(role: .system, text: statusText))
            return
        } catch {
            statusText = "Provider init failed: \(error)"
            messages.append(.init(role: .system, text: statusText))
            return
        }

        self.sessionId = session.id

        let audit: AuditLogger?
        do {
            audit = try AuditLogger(sessionId: session.id)
        } catch {
            audit = nil
            messages.append(.init(role: .system, text: "Audit logger init failed (\(error)); continuing without audit."))
        }
        self.auditLogPath = audit?.logPath

        self.loop = ConversationLoop(
            session: session,
            provider: provider,
            approvalCallback: { [weak self] call in
                guard let self else { return .deny }
                return await self.requestApproval(call)
            },
            eventCallback: { [weak self] event in
                guard let self else { return }
                await self.handleTurnEvent(event)
            },
            auditLogger: audit
        )

        statusText = "Ready · workspace: \(workspacePath)"
        readyStatus = statusText
        if let audit = audit {
            messages.append(.init(role: .system, text: "Audit log: \(audit.logPath)"))
        }
        messages.append(.init(role: .system, text: "Session: \(session.id) · \(selectedPreset.name)"))
        messages.append(.init(role: .system, text: "Tools: \(toolNames)"))
    }
}

/// A capability preset the user can pick before/while running a session.
/// Kept tiny on purpose: the point is to demonstrate that capabilities are
/// fixed per session and that a read-only session genuinely cannot write.
struct SessionPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let canWrite: Bool

    static let all: [SessionPreset] = [
        SessionPreset(id: "rw", name: "Workspace files (read/write)", canWrite: true),
        SessionPreset(id: "ro", name: "Read & summarize (read-only)", canWrite: false),
    ]
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var text: String       // var so streaming deltas can append in-place
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }

    enum Role: Equatable {
        case user
        case assistant
        case system
        case tool          // tool call requested or tool result, rendered inline
    }
}
