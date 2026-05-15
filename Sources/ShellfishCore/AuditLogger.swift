// Append-only audit log for tool calls.
//
// Stage 4 Phase 4.4 — the §5.5 piece of the threat model becoming real.
//
// Format: one JSON object per line (JSONL), written to ~/.shellfish/audit.jsonl.
// Stage 4 deliberately uses JSONL, not SQLite — append-only, human-readable,
// no dependency. Promotion to SQLite is a Stage 8 hardening concern.
//
// Three event kinds get logged per tool invocation:
//   - "capability_check" — broker decided based on session capabilities
//   - "user_approval"    — broker's UI layer asked the user (or hit the cache)
//   - "tool_result"      — ToolRunner finished; records success + SHA-256 of output
//
// What we do NOT log (deliberate):
//   - The full output content. Could be huge or sensitive. We log byte count
//     and a SHA-256 of the output so post-hoc tampering is detectable, but
//     the actual bytes stay out of the log.
//
// What we DO log:
//   - Full args. For the PoC this is honest — the user explicitly typed the
//     prompt that triggered this call. A production hardening layer would
//     add per-arg redaction (e.g., for credentials).

import Foundation
import CryptoKit

public final class AuditLogger: @unchecked Sendable {
    public let sessionId: String
    public let logPath: String
    private let queue = DispatchQueue(label: "com.shellfish.audit")
    private let handle: FileHandle

    public init(sessionId: String, logPath: String? = nil) throws {
        self.sessionId = sessionId

        let resolvedPath: String
        if let logPath = logPath {
            resolvedPath = logPath
        } else {
            let home = NSString(string: "~/.shellfish").expandingTildeInPath
            try FileManager.default.createDirectory(
                atPath: home,
                withIntermediateDirectories: true
            )
            resolvedPath = "\(home)/audit.jsonl"
        }
        self.logPath = resolvedPath

        if !FileManager.default.fileExists(atPath: resolvedPath) {
            FileManager.default.createFile(atPath: resolvedPath, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: URL(fileURLWithPath: resolvedPath))
        try self.handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    private func appendJSON(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(0x0a)  // newline
        queue.sync {
            try? handle.write(contentsOf: line)
        }
    }

    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    public func logCapabilityCheck(tool: String, args: [String: String], approved: Bool, reason: String?) {
        var entry: [String: Any] = [
            "ts": isoTimestamp(),
            "session": sessionId,
            "kind": "capability_check",
            "tool": tool,
            "args": args,
            "decision": approved ? "approve" : "deny",
        ]
        if let reason = reason {
            entry["reason"] = reason
        }
        appendJSON(entry)
    }

    public func logUserApproval(tool: String, args: [String: String], decision: String, cached: Bool) {
        appendJSON([
            "ts": isoTimestamp(),
            "session": sessionId,
            "kind": "user_approval",
            "tool": tool,
            "args": args,
            "decision": decision,
            "cached": cached,
        ])
    }

    public func logToolResult(tool: String, args: [String: String], success: Bool, output: String?, error: String?) {
        var entry: [String: Any] = [
            "ts": isoTimestamp(),
            "session": sessionId,
            "kind": "tool_result",
            "tool": tool,
            "args": args,
            "success": success,
        ]
        if let output = output {
            let bytes = Data(output.utf8)
            let digest = SHA256.hash(data: bytes)
            entry["output_bytes"] = bytes.count
            entry["result_hash"] = digest.map { String(format: "%02x", $0) }.joined()
        }
        if let error = error {
            entry["error"] = error
        }
        appendJSON(entry)
    }
}
