// Stage 4 Phase 4.2 — Chat REPL.
//
// What it does:
//   - Opens a session whose only tool is fs_read, bound to ./workspaces/poc/.
//   - Reads user prompts from stdin in a loop.
//   - For each prompt, runs a ConversationLoop turn:
//     LLM → tool_use? → broker → user approval → ToolRunner under strict sandbox → tool_result → LLM
//   - Prints Claude's final answer, then prompts again.
//   - Type "exit" / "quit" or Ctrl-D to end.
//
// Run:
//   export ANTHROPIC_API_KEY="sk-ant-..."
//   echo "decoy contents" > workspaces/poc/decoy.txt
//   .build/debug/Chat

import Foundation
import ShellfishCore

@main
struct Main {
    static func main() async {
        let cwd = FileManager.default.currentDirectoryPath
        let workspacePath = "\(cwd)/workspaces/poc"
        let sandboxProfilePath = "\(cwd)/profiles/toolrunner-strict.sb"
        let toolRunnerPath = "\(cwd)/.build/debug/ToolRunner"
        let buildDirPath = "\(cwd)/.build"

        // Sanity checks.
        for (label, path) in [
            ("workspace", workspacePath),
            ("sandbox profile", sandboxProfilePath),
            ("ToolRunner binary", toolRunnerPath),
        ] {
            guard FileManager.default.fileExists(atPath: path) else {
                FileHandle.standardError.write(Data("Missing \(label) at \(path)\n".utf8))
                exit(2)
            }
        }

        let tools: [ToolDef]
        do {
            tools = [
                try ToolDef(
                    name: "fs_read",
                    description: """
                        Read the contents of a text file from the session workspace.
                        Only paths inside the workspace are allowed.
                        """,
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "Absolute path inside the workspace.",
                            ],
                        ],
                        "required": ["path"],
                    ]
                ),
                try ToolDef(
                    name: "fs_write",
                    description: """
                        Write text content to a file in the session workspace, replacing
                        any existing contents. Only paths inside the workspace are allowed.
                        """,
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "Absolute path inside the workspace.",
                            ],
                            "content": [
                                "type": "string",
                                "description": "Full text content to write.",
                            ],
                        ],
                        "required": ["path", "content"],
                    ]
                ),
                try ToolDef(
                    name: "fs_list",
                    description: """
                        List the entries of a directory in the session workspace.
                        Returns JSON: [{name, isDir, size}, ...]. If path is omitted,
                        lists the workspace root.
                        """,
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "Absolute path inside the workspace (optional).",
                            ],
                        ],
                        "required": [],
                    ]
                ),
            ]
        } catch {
            FileHandle.standardError.write(Data("Failed to build tool defs: \(error)\n".utf8))
            exit(2)
        }

        let session = Session(
            workspacePath: workspacePath,
            capabilities: Capabilities(
                fsRead: [workspacePath],
                fsWrite: [workspacePath]
            ),
            tools: tools,
            systemPrompt: """
                You are a helpful assistant operating inside a sandboxed workspace.
                The workspace is at: \(workspacePath).
                Your tools: fs_read, fs_write, fs_list. All paths must be absolute
                and inside the workspace; reads/writes outside are denied.
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
            FileHandle.standardError.write(Data("ANTHROPIC_API_KEY env var is not set.\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("Provider init failed: \(error)\n".utf8))
            exit(2)
        }

        let audit: AuditLogger?
        do {
            audit = try AuditLogger(sessionId: session.id)
        } catch {
            FileHandle.standardError.write(Data("Audit logger init failed (\(error)) — continuing without audit.\n".utf8))
            audit = nil
        }

        let loop = ConversationLoop(
            session: session,
            provider: provider,
            approvalCallback: approve,
            auditLogger: audit
        )

        print("=== Shellfish Chat (Stage 4 Phase 4.4) ===")
        print("Model:     claude-opus-4-7")
        print("Workspace: \(workspacePath)")
        print("Profile:   \(sandboxProfilePath)")
        print("Tools:     fs_read, fs_write, fs_list")
        if let path = audit?.logPath {
            print("Audit:     \(path)")
        }
        print("Session:   \(session.id)")
        print("Type your message, then Enter. Type 'exit' or Ctrl-D to quit.")
        print("")

        while true {
            FileHandle.standardOutput.write(Data("> ".utf8))
            guard let line = readLine(strippingNewline: true) else {
                print("")  // ctrl-d
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "exit" || trimmed == "quit" { break }

            do {
                let result = try await loop.runTurn(userInput: trimmed)
                print("")
                print(result.assistantText)
                print("")
                if result.killed {
                    print("[session terminated]")
                    break
                }
            } catch AnthropicError.invalidResponse(let status, let body) {
                FileHandle.standardError.write(Data("API error \(status):\n\(body)\n\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("Turn failed: \(error)\n\n".utf8))
            }
        }

        print("Goodbye.")
    }

    /// Approval callback used by ConversationLoop. Reads stdin synchronously.
    @Sendable
    static func approve(_ call: ToolCall) async -> ApprovalDecision {
        // Render the args back to JSON for legibility.
        let argsJSON = (try? JSONSerialization.data(withJSONObject: call.args, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        print("")
        print("[approval] Claude wants to call: \(call.tool)\(argsJSON)")
        FileHandle.standardOutput.write(Data("  [o]nce / [s]ession / [d]eny / [k]ill: ".utf8))
        guard let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) else {
            return .deny
        }
        switch answer.lowercased().first ?? " " {
        case "o", "y", "\r", "\n":  return .once
        case "s", "a":              return .session
        case "k":                   return .denyAndKill
        default:                    return .deny
        }
    }
}
