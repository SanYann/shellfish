// Shellfish PoC — S4 harness.
//
// Scenario from shellfish-threat-model.md §3.5:
//   "MCP server asks for args containing `../../../.ssh/id_rsa`.
//    Filesystem tool resolves paths and rejects anything outside the
//    session's declared workspace roots."
//
// What this tests: application-level path canonicalization in the fs.read
// tool. The tool receives a path arg containing `..` traversal, resolves
// it via NSString standardizingPath + resolvingSymlinksInPath, and refuses
// to read the file because the resolved path falls outside the session
// workspace.
//
// What this does NOT test: OS-level filesystem isolation via sandbox-exec.
// That is the second line of defense (threat model §4 I3) and is gated
// on the strict default-deny profile working — currently INCONCLUSIVE.

import Foundation

let isNegative = CommandLine.arguments.contains("--negative")

// Test fixture: a "secret" file outside the session workspace, simulating
// something like ~/.ssh/id_rsa. We use /tmp so the test never reads a real
// secret on the user's machine.
let secretPath = "/tmp/shellfish-poc-fake-secret.txt"
let secretContent = "FAKE-SSH-KEY-CONTENTS-DO-NOT-LEAK"

do {
    try secretContent.write(toFile: secretPath, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("Failed to write fixture: \(error)\n".utf8))
    exit(2)
}

let cwd = FileManager.default.currentDirectoryPath
let workspace = "\(cwd)/workspaces/poc"
let toolRunnerPath = "\(cwd)/.build/debug/ToolRunner"

guard FileManager.default.fileExists(atPath: toolRunnerPath) else {
    FileHandle.standardError.write(Data("ToolRunner not found at \(toolRunnerPath)\n".utf8))
    exit(2)
}

// The traversal attack — what an injected MCP arg would look like.
// We use 10 `..` to safely reach `/` from any reasonable workspace depth
// (POSIX: `..` from `/` is `/`, so over-shooting is safe), then descend
// into /tmp.
let traversalPath = "\(workspace)/../../../../../../../../../../tmp/shellfish-poc-fake-secret.txt"

// In the negative control we widen the workspace to /tmp so the same
// traversal arg now resolves inside the (widened) workspace and the read
// succeeds. Same code path, same arg — the only thing that changes is
// the session capability set. This proves the validation is what was
// containing the attack.
let effectiveWorkspace = isNegative ? "/tmp" : workspace

print("=== HarnessS4 ===")
print("Mode:                  \(isNegative ? "NEGATIVE CONTROL (workspace widened to /tmp)" : "primary (workspace bound to poc/)")")
print("Workspace passed:      \(effectiveWorkspace)")
print("Traversal arg:         \(traversalPath)")
print("Secret fixture:        \(secretPath)")
print("")

// Build the tool call.
struct ToolCall: Codable {
    let tool: String
    let args: [String: String]
}

let call = ToolCall(tool: "fs.read", args: ["path": traversalPath])
guard let callData = try? JSONEncoder().encode(call) else {
    FileHandle.standardError.write(Data("encode failed\n".utf8))
    exit(2)
}

// Spawn ToolRunner. We don't use sandbox-exec for S4 — the claim under
// test is application-level canonicalization, not OS isolation. The
// sandbox is a second line of defense and is exercised by S1.
let process = Process()
process.executableURL = URL(fileURLWithPath: toolRunnerPath)
var env = ProcessInfo.processInfo.environment
env["SHELLFISH_WORKSPACE"] = effectiveWorkspace
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
    FileHandle.standardError.write(Data("Failed to launch ToolRunner: \(error)\n".utf8))
    exit(2)
}

stdinPipe.fileHandleForWriting.write(callData)
try? stdinPipe.fileHandleForWriting.close()
process.waitUntilExit()

let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""

print("--- ToolRunner stdout ---")
print(stdoutString)
if !stderrData.isEmpty {
    print("--- ToolRunner stderr ---")
    print(String(data: stderrData, encoding: .utf8) ?? "")
}
print("--- ToolRunner exit code: \(process.terminationStatus) ---")
print("")

// Detect whether the secret leaked into the tool result.
let leaked = stdoutString.contains(secretContent)

// Inverted exit convention, matching S1/S2:
//   exit 0 = containment FAILED (secret leaked in primary mode)
//   exit 1 = containment HELD   (read rejected with the path-validation error)
//   exit 3 = inconclusive
if leaked {
    FileHandle.standardError.write(Data("HarnessS4: secret LEAKED — fs.read FAILED to contain.\n".utf8))
    exit(0)
} else if process.terminationStatus == 1 && stdoutString.contains("outside session workspace") {
    FileHandle.standardError.write(Data("HarnessS4: traversal REJECTED — fs.read contained it.\n".utf8))
    exit(1)
} else {
    FileHandle.standardError.write(Data("HarnessS4: ToolRunner exited unexpectedly. INCONCLUSIVE.\n".utf8))
    exit(3)
}
