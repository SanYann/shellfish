// Audit log viewer — surfaces ~/.shellfish/audit.jsonl in-app.
//
// The AuditLogger writes one JSON object per line (see AuditLogger.swift):
//   kind ∈ { capability_check, user_approval, tool_result }
// plus ts, session, tool, args, and kind-specific fields (decision, reason,
// success, cached, output_bytes, result_hash, error).
//
// This view reads the file on appear, parses each line, and shows the entries
// newest-first. It's read-only: the log is append-only and tamper-evident
// (result_hash), so the UI never writes to it.

import SwiftUI
import AppKit

struct AuditEntry: Identifiable {
    let id = UUID()
    let ts: String
    let kind: String
    let tool: String
    let session: String
    let decision: String?
    let success: Bool?
    let cached: Bool?
    let reason: String?
    let error: String?
    let outputBytes: Int?
    let argsSummary: String
}

struct AuditLogView: View {
    let logPath: String?
    let currentSession: String

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AuditEntry] = []
    @State private var loadError: String?
    @State private var thisSessionOnly = false

    private var shown: [AuditEntry] {
        thisSessionOnly ? entries.filter { $0.session == currentSession } : entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let loadError = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if shown.isEmpty {
                Text("No audit entries yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { entry in
                            AuditRow(entry: entry, isCurrent: entry.session == currentSession)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 660, height: 460)
        .onAppear(perform: load)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.secondary)
                Text("Audit log")
                    .font(.headline)
                Spacer()
                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload")
                Button("Reveal in Finder") {
                    if let logPath = logPath {
                        NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
                    }
                }
                .disabled(logPath == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            HStack {
                Text(logPath ?? "no audit log")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Toggle("This session only", isOn: $thisSessionOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .padding(12)
    }

    private func load() {
        loadError = nil
        guard let logPath = logPath else {
            loadError = "Audit logging is disabled for this session."
            return
        }
        guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            loadError = "Couldn't read \(logPath)."
            return
        }
        var parsed: [AuditEntry] = []
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            parsed.append(Self.entry(from: obj))
        }
        // Newest first.
        entries = parsed.reversed()
    }

    private static func entry(from obj: [String: Any]) -> AuditEntry {
        let args = (obj["args"] as? [String: String]) ?? [:]
        let argsSummary = args.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return AuditEntry(
            ts: obj["ts"] as? String ?? "",
            kind: obj["kind"] as? String ?? "?",
            tool: obj["tool"] as? String ?? "",
            session: obj["session"] as? String ?? "",
            decision: obj["decision"] as? String,
            success: obj["success"] as? Bool,
            cached: obj["cached"] as? Bool,
            reason: obj["reason"] as? String,
            error: obj["error"] as? String,
            outputBytes: obj["output_bytes"] as? Int,
            argsSummary: argsSummary
        )
    }
}

private struct AuditRow: View {
    let entry: AuditEntry
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(shortTime(entry.ts))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            kindBadge
                .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.tool)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                    if isCurrent {
                        Text("this session")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.argsSummary.isEmpty {
                    Text(entry.argsSummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = detailLine {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(detailColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var kindBadge: some View {
        let (label, color) = kindStyle
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var kindStyle: (String, Color) {
        switch entry.kind {
        case "capability_check":
            return ("capability", entry.decision == "deny" ? .red : .blue)
        case "user_approval":
            return ("approval", entry.decision == "deny" || entry.decision == "deny_and_kill" ? .red : .purple)
        case "tool_result":
            return ("result", entry.success == false ? .red : .green)
        default:
            return (entry.kind, .secondary)
        }
    }

    private var detailLine: String? {
        switch entry.kind {
        case "capability_check":
            if let reason = entry.reason { return "\(entry.decision ?? "?") — \(reason)" }
            return entry.decision
        case "user_approval":
            var s = entry.decision ?? "?"
            if entry.cached == true { s += " (cached)" }
            return s
        case "tool_result":
            if let error = entry.error { return "failed: \(error)" }
            if let bytes = entry.outputBytes { return "ok · \(bytes) B" }
            return entry.success == true ? "ok" : nil
        default:
            return nil
        }
    }

    private var detailColor: Color {
        if entry.kind == "tool_result", entry.success == false { return .red }
        if entry.decision == "deny" || entry.decision == "deny_and_kill" { return .red }
        return .secondary
    }

    private func shortTime(_ ts: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: ts) else {
            // Fall back to the last path-ish component of the timestamp.
            return String(ts.suffix(12))
        }
        let out = DateFormatter()
        out.dateFormat = "HH:mm:ss"
        return out.string(from: date)
    }
}
