import Foundation

struct ToolCall: Codable {
    let tool: String
    let args: [String: String]
}

struct ToolResult: Codable {
    let success: Bool
    let output: String?
    let error: String?
}

func emit(_ result: ToolResult) {
    if let data = try? JSONEncoder().encode(result) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let call = try? JSONDecoder().decode(ToolCall.self, from: input) else {
    emit(ToolResult(success: false, output: nil, error: "Failed to decode tool call"))
    exit(2)
}

// MARK: - fs.read with workspace containment

func canonicalize(_ path: String) -> String {
    // Resolve `..`, `.`, and `~`. We deliberately use both standardizingPath
    // (which handles `..`) and resolvingSymlinksInPath (which handles symlinks)
    // because either alone is insufficient: a symlink inside the workspace
    // pointing outside would otherwise pass `..` resolution.
    let expanded = (path as NSString).expandingTildeInPath
    let standardized = (expanded as NSString).standardizingPath
    return (standardized as NSString).resolvingSymlinksInPath
}

func isInsideWorkspace(_ requested: String, workspace: String) -> Bool {
    let canonRequested = canonicalize(requested)
    let canonWorkspace = canonicalize(workspace)
    if canonRequested == canonWorkspace { return true }
    return canonRequested.hasPrefix(canonWorkspace + "/")
}

switch call.tool {
case "fs.read":
    guard let requested = call.args["path"] else {
        emit(ToolResult(success: false, output: nil, error: "Missing path"))
        exit(2)
    }
    guard let workspace = ProcessInfo.processInfo.environment["SHELLFISH_WORKSPACE"] else {
        emit(ToolResult(success: false, output: nil, error: "SHELLFISH_WORKSPACE not set"))
        exit(2)
    }
    let canonRequested = canonicalize(requested)
    let canonWorkspace = canonicalize(workspace)
    if !isInsideWorkspace(requested, workspace: workspace) {
        emit(ToolResult(
            success: false,
            output: nil,
            error: "Path '\(canonRequested)' is outside session workspace '\(canonWorkspace)'"
        ))
        exit(1)
    }
    do {
        let contents = try String(contentsOfFile: canonRequested, encoding: .utf8)
        emit(ToolResult(success: true, output: contents, error: nil))
        exit(0)
    } catch {
        emit(ToolResult(success: false, output: nil, error: "Read failed: \(error)"))
        exit(1)
    }

case "fs.write":
    guard let requested = call.args["path"] else {
        emit(ToolResult(success: false, output: nil, error: "Missing path"))
        exit(2)
    }
    guard let content = call.args["content"] else {
        emit(ToolResult(success: false, output: nil, error: "Missing content"))
        exit(2)
    }
    guard let workspace = ProcessInfo.processInfo.environment["SHELLFISH_WORKSPACE"] else {
        emit(ToolResult(success: false, output: nil, error: "SHELLFISH_WORKSPACE not set"))
        exit(2)
    }
    let canonRequested = canonicalize(requested)
    let canonWorkspace = canonicalize(workspace)
    if !isInsideWorkspace(requested, workspace: workspace) {
        emit(ToolResult(
            success: false,
            output: nil,
            error: "Path '\(canonRequested)' is outside session workspace '\(canonWorkspace)'"
        ))
        exit(1)
    }
    do {
        try content.write(toFile: canonRequested, atomically: true, encoding: .utf8)
        emit(ToolResult(success: true, output: "Wrote \(content.utf8.count) bytes to \(canonRequested)", error: nil))
        exit(0)
    } catch {
        emit(ToolResult(success: false, output: nil, error: "Write failed: \(error)"))
        exit(1)
    }

case "fs.list":
    guard let workspace = ProcessInfo.processInfo.environment["SHELLFISH_WORKSPACE"] else {
        emit(ToolResult(success: false, output: nil, error: "SHELLFISH_WORKSPACE not set"))
        exit(2)
    }
    // path is optional — defaults to the workspace root.
    let requested = call.args["path"].flatMap { $0.isEmpty ? nil : $0 } ?? workspace
    let canonRequested = canonicalize(requested)
    let canonWorkspace = canonicalize(workspace)
    if !isInsideWorkspace(requested, workspace: workspace) {
        emit(ToolResult(
            success: false,
            output: nil,
            error: "Path '\(canonRequested)' is outside session workspace '\(canonWorkspace)'"
        ))
        exit(1)
    }
    do {
        let entries = try FileManager.default.contentsOfDirectory(atPath: canonRequested)
        var listing: [[String: Any]] = []
        for name in entries.sorted() {
            let full = "\(canonRequested)/\(name)"
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            let attrs = try? FileManager.default.attributesOfItem(atPath: full)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            listing.append([
                "name": name,
                "isDir": isDir.boolValue,
                "size": size,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: listing, options: [.prettyPrinted, .sortedKeys])
        let output = String(data: data, encoding: .utf8) ?? "[]"
        emit(ToolResult(success: true, output: output, error: nil))
        exit(0)
    } catch {
        emit(ToolResult(success: false, output: nil, error: "List failed: \(error)"))
        exit(1)
    }

case "http_fetch":
    guard let urlString = call.args["url"], let url = URL(string: urlString) else {
        emit(ToolResult(success: false, output: nil, error: "Missing or invalid url"))
        exit(2)
    }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        emit(ToolResult(success: false, output: nil, error: "Only http/https URLs are allowed"))
        exit(1)
    }

    // Application-layer domain allow-list (defense in depth — the broker
    // checks this too). SHELLFISH_NETFETCH_ALLOW is a comma-separated list of
    // host suffixes; "*" means any host.
    let allowList = (ProcessInfo.processInfo.environment["SHELLFISH_NETFETCH_ALLOW"] ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let host = url.host ?? ""
    let hostPermitted = allowList.contains("*")
        || allowList.contains { host == $0 || host.hasSuffix("." + $0) }
    guard hostPermitted else {
        emit(ToolResult(success: false, output: nil, error: "Host '\(host)' is not in this session's net.fetch allow-list"))
        exit(1)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    var output: String?
    var errorMsg: String?

    // Ephemeral: no on-disk cache, cookies, or credential store. A sandboxed
    // fetch tool should leave nothing behind, and it avoids touching the
    // URLSession cache DB under ~/Library/Caches (denied by the profile).
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 12
    let urlSession = URLSession(configuration: config)
    let task = urlSession.dataTask(with: url) { data, _, error in
        if let error = error {
            errorMsg = "\(error)"
        } else if let data = data {
            success = true
            output = String(data: data, encoding: .utf8) ?? "<binary>"
        } else {
            errorMsg = "no data and no error"
        }
        semaphore.signal()
    }
    task.resume()

    if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
        errorMsg = "timeout after 10s"
        task.cancel()
    }

    emit(ToolResult(success: success, output: output, error: errorMsg))
    exit(success ? 0 : 1)

default:
    emit(ToolResult(success: false, output: nil, error: "Unknown tool: \(call.tool)"))
    exit(2)
}
