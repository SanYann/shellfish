// Shared types used across the Shellfish PoCs and (in Stage 4) the real app.
//
// What's in here right now: the things HarnessS2's in-process broker needed.
// As Stage 4 progresses, more will move in (Session, ConversationLoop, etc.)
// but the rule is the same: anything used by more than one binary lives here.

import Foundation

public struct ToolCall: Sendable {
    public let tool: String
    public let args: [String: String]

    public init(tool: String, args: [String: String]) {
        self.tool = tool
        self.args = args
    }
}

public struct Capabilities: Sendable {
    public let mcp: [String]
    public let shell: Bool
    public let netFetch: [String]
    public let fsRead: [String]     // workspace paths
    public let fsWrite: [String]

    public init(
        mcp: [String] = [],
        shell: Bool = false,
        netFetch: [String] = [],
        fsRead: [String] = [],
        fsWrite: [String] = []
    ) {
        self.mcp = mcp
        self.shell = shell
        self.netFetch = netFetch
        self.fsRead = fsRead
        self.fsWrite = fsWrite
    }
}

public enum BrokerDecision: Sendable {
    case approve
    case deny(reason: String)
}

public struct PermissionBroker: Sendable {
    public let capabilities: Capabilities

    public init(capabilities: Capabilities) {
        self.capabilities = capabilities
    }

    public func authorize(_ call: ToolCall) -> BrokerDecision {
        switch call.tool {
        case "mcp.call":
            let server = call.args["server"] ?? ""
            return capabilities.mcp.contains(server)
                ? .approve
                : .deny(reason: "mcp server '\(server)' not in session capabilities")
        case "shell.exec":
            return capabilities.shell
                ? .approve
                : .deny(reason: "shell capability not granted to this session")
        // Accept both "fs.read" (internal name, used by ToolRunner + PoCs)
        // and "fs_read" (Anthropic name — tool names there must match
        // ^[a-zA-Z0-9_-]+ so dots aren't allowed).
        case "fs.read", "fs_read":
            return capabilities.fsRead.isEmpty
                ? .deny(reason: "fs.read not granted to this session")
                : .approve
        case "fs.write", "fs_write":
            return capabilities.fsWrite.isEmpty
                ? .deny(reason: "fs.write not granted to this session")
                : .approve
        case "http_fetch":
            return capabilities.netFetch.isEmpty
                ? .deny(reason: "net.fetch not granted to this session")
                : .approve
        default:
            return .deny(reason: "unknown tool '\(call.tool)'")
        }
    }
}
