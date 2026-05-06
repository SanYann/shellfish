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

switch call.tool {
case "http_fetch":
    guard let urlString = call.args["url"], let url = URL(string: urlString) else {
        emit(ToolResult(success: false, output: nil, error: "Missing or invalid url"))
        exit(2)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    var output: String?
    var errorMsg: String?

    let task = URLSession.shared.dataTask(with: url) { data, _, error in
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
