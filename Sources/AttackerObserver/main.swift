import Foundation
import Network

let logPath = "/tmp/shellfish-poc-observer.log"

// Truncate log on start.
try? "".write(toFile: logPath, atomically: true, encoding: .utf8)

let port: NWEndpoint.Port = 9999
let listener: NWListener
do {
    listener = try NWListener(using: .tcp, on: port)
} catch {
    FileHandle.standardError.write(Data("AttackerObserver failed to bind: \(error)\n".utf8))
    exit(1)
}

func appendLog(_ line: String) {
    let entry = "\(Date().timeIntervalSince1970)\t\(line)\n"
    if let data = entry.data(using: .utf8) {
        if let f = FileHandle(forWritingAtPath: logPath) {
            f.seekToEndOfFile()
            f.write(data)
            try? f.close()
        } else {
            try? entry.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}

listener.newConnectionHandler = { connection in
    connection.start(queue: .main)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
        if let data = data, !data.isEmpty,
           let request = String(data: data, encoding: .utf8) {
            // Extract just the request line (METHOD PATH HTTP/x.y), nothing else.
            let lines = request.components(separatedBy: "\r\n")
            let requestLine = lines.first ?? request
            appendLog(requestLine.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            appendLog("<connection without data>")
        }
        let body = "OK"
        let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        FileHandle.standardError.write(Data("AttackerObserver listening on 127.0.0.1:9999\n".utf8))
    case .failed(let error):
        FileHandle.standardError.write(Data("AttackerObserver listener failed: \(error)\n".utf8))
        exit(1)
    default:
        break
    }
}

listener.start(queue: .main)
RunLoop.main.run()
