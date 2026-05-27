// Inline approval sheet — replaces the NSAlert from Phase 4.5 v1.
//
// Slides down from the window title bar (standard macOS .sheet behavior),
// stays attached to the chat, and cannot be dismissed without a decision
// (`interactiveDismissDisabled`). For a security gate that's the correct
// behavior: there's no "click away to ignore."
//
// The four buttons map 1:1 to the threat-model §5.2 grants:
//   Approve for session / Approve once / Deny / Deny & kill.

import SwiftUI
import ShellfishCore

struct ApprovalSheet: View {
    let call: ToolCall
    let onDecision: (ApprovalDecision) -> Void

    private var argsJSON: String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: call.args,
                options: [.sortedKeys, .prettyPrinted]
            ),
            let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                Text("Tool approval")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Claude wants to run a tool:")
                    .foregroundStyle(.secondary)
                Text(call.tool)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
            }

            if call.args.isEmpty {
                Text("No arguments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(argsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text("This runs in a sandboxed subprocess that can only touch the session workspace and has no network access.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(role: .destructive) { onDecision(.denyAndKill) } label: {
                    Text("Deny & Kill")
                }
                Button { onDecision(.deny) } label: {
                    Text("Deny")
                }
                Spacer()
                Button { onDecision(.once) } label: {
                    Text("Once")
                }
                Button { onDecision(.session) } label: {
                    Text("Approve for session")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(true)
    }
}
