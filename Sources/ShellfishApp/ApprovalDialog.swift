// Native macOS approval dialog that satisfies the ConversationLoop's
// ApprovalCallback contract.
//
// Phase 4.5 v1 uses NSAlert — the simplest "definitely a native dialog"
// path. A later iteration can replace this with an inline SwiftUI sheet
// for nicer composition with the chat window.
//
// The four buttons match the threat-model §5.2 spec: once / session / deny /
// kill. The labels are friendlier than the spec's wording; the semantics are
// identical.

import Foundation
import AppKit
import ShellfishCore

enum ApprovalDialog {
    /// Sendable, top-level function so the closure capture is trivial — the
    /// ConversationLoop's ApprovalCallback is @Sendable and this avoids the
    /// usual self-capture dance.
    @Sendable
    static func present(_ call: ToolCall) async -> ApprovalDecision {
        await MainActor.run {
            runAlert(for: call)
        }
    }

    @MainActor
    private static func runAlert(for call: ToolCall) -> ApprovalDecision {
        let argsJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: call.args, options: [.sortedKeys, .prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            argsJSON = s
        } else {
            argsJSON = "{}"
        }

        let alert = NSAlert()
        alert.messageText = "Claude wants to call \(call.tool)"
        alert.informativeText = "Args:\n\(argsJSON)"
        alert.alertStyle = .informational

        // NSAlert button order is left → right: addButton appends right-to-left
        // on macOS, but the response codes map: firstButtonReturn = first added.
        alert.addButton(withTitle: "Once")        // .alertFirstButtonReturn
        alert.addButton(withTitle: "Session")     // .alertSecondButtonReturn
        alert.addButton(withTitle: "Deny")        // .alertThirdButtonReturn
        alert.addButton(withTitle: "Deny & Kill") // 1003 / fourth

        // Make the app come to front so the modal isn't lost behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:  return .once
        case .alertSecondButtonReturn: return .session
        case .alertThirdButtonReturn:  return .deny
        default:                       return .denyAndKill
        }
    }
}
