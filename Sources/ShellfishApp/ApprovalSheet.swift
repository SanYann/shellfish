// Inline approval sheet — replaces the NSAlert from Phase 4.5 v1.
//
// Slides down from the window title bar (standard macOS .sheet behavior),
// stays attached to the chat, and cannot be dismissed without a decision
// (`interactiveDismissDisabled`). For a security gate that's the correct
// behavior: there's no "click away to ignore."
//
// The four buttons map 1:1 to the threat-model §5.2 grants:
//   Approve for session / Approve once / Deny / Deny & kill.
//
// v2 (FSB-feedback hardening): the weak link in this whole design is the
// human clicking "Approve" on a tool call whose arguments *look* innocent
// but aren't. A hostile page can talk the model into pointing a granted
// tool somewhere sneaky. So before the click, we now:
//   1. Resolve each path argument the same way ToolRunner does
//      (expand ~, standardize, follow symlinks) and show the *resolved*
//      target — this unmasks symlink redirection and `..` traversal.
//   2. Flag resolved paths that land on sensitive locations (ssh/aws keys,
//      keychains, /etc) or anywhere outside the session workspace.
//   3. For fs_write, preview the content and warn if it overwrites a file.

import SwiftUI
import ShellfishCore

struct ApprovalSheet: View {
    let call: ToolCall
    let workspacePath: String
    let onDecision: (ApprovalDecision) -> Void

    // MARK: - Path analysis

    private enum Severity {
        case ok        // inside the workspace
        case outside   // outside the workspace (sandbox denies)
        case sensitive // a known-sensitive location
    }

    private struct PathArg: Identifiable {
        let id = UUID()
        let key: String
        let raw: String
        let resolved: String
        let severity: Severity
        let note: String
        var redirected: Bool { raw != resolved }
    }

    /// Resolve a path to the real target a tool would touch. Goes one step
    /// further than ToolRunner: we follow symlinks *manually* so a dangling
    /// link still reveals its intended target.
    ///
    /// `NSString.resolvingSymlinksInPath` silently leaves a broken symlink
    /// untouched — which would let a planted link like
    ///   workspace/innocent.txt -> ~/.ssh/id_rsa
    /// look like a harmless in-workspace file whenever that key doesn't
    /// happen to exist yet. The intent to escape is the signal, so we chase
    /// the link target ourselves and flag it regardless.
    private func canonicalize(_ path: String) -> String {
        let fm = FileManager.default
        var current = (path as NSString).expandingTildeInPath
        current = (current as NSString).standardizingPath

        var hops = 0
        while hops < 16, let dest = try? fm.destinationOfSymbolicLink(atPath: current) {
            if (dest as NSString).isAbsolutePath {
                current = dest
            } else {
                let parent = (current as NSString).deletingLastPathComponent
                current = (parent as NSString).appendingPathComponent(dest)
            }
            current = (current as NSString).standardizingPath
            hops += 1
        }

        return (current as NSString).resolvingSymlinksInPath
    }

    private var sensitivePrefixes: [(label: String, path: String)] {
        let home = NSHomeDirectory()
        let raw: [(label: String, path: String)] = [
            (label: "SSH keys", path: home + "/.ssh"),
            (label: "AWS credentials", path: home + "/.aws"),
            (label: "App config", path: home + "/.config"),
            (label: "Keychains", path: home + "/Library/Keychains"),
            (label: "System config", path: "/etc"),
        ]
        return raw.map { entry in
            let resolved = (entry.path as NSString).resolvingSymlinksInPath
            return (label: entry.label, path: resolved)
        }
    }

    private var pathArgs: [PathArg] {
        let ws = canonicalize(workspacePath)
        return call.args
            .filter { $0.key == "path" || $0.key.hasSuffix("_path") }
            .sorted { $0.key < $1.key }
            .map { (key, raw) -> PathArg in
                let resolved = canonicalize(raw)
                for entry in sensitivePrefixes where resolved == entry.path || resolved.hasPrefix(entry.path + "/") {
                    return PathArg(key: key, raw: raw, resolved: resolved,
                                   severity: .sensitive, note: "Sensitive: \(entry.label)")
                }
                if resolved == ws || resolved.hasPrefix(ws + "/") {
                    return PathArg(key: key, raw: raw, resolved: resolved,
                                   severity: .ok, note: "Inside workspace")
                }
                return PathArg(key: key, raw: raw, resolved: resolved,
                               severity: .outside, note: "Outside workspace")
            }
    }

    private var overallSeverity: Severity {
        let sevs = pathArgs.map(\.severity)
        if sevs.contains(.sensitive) { return .sensitive }
        if sevs.contains(.outside) { return .outside }
        return .ok
    }

    private func color(for severity: Severity) -> Color {
        switch severity {
        case .ok: return .green
        case .outside: return .orange
        case .sensitive: return .red
        }
    }

    // MARK: - http_fetch destination

    private var fetchURL: String? {
        guard call.tool == "http_fetch" else { return nil }
        return call.args["url"]
    }

    // MARK: - fs_write preview

    private var isWrite: Bool { call.tool == "fs_write" || call.tool == "fs.write" }

    private var writeContentAllLines: [String]? {
        guard isWrite, let content = call.args["content"] else { return nil }
        return content.components(separatedBy: "\n")
    }

    private var existingFileSize: Int? {
        guard isWrite, let path = call.args["path"] else { return nil }
        let resolved = canonicalize(path)
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
            let size = attrs[.size] as? Int
        else { return nil }
        return size
    }

    // MARK: - Raw args

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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                Text("Tool approval")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Claude wants to run a tool:")
                    .foregroundStyle(.secondary)
                Text(call.tool)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
            }

            severityBanner

            if !pathArgs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pathArgs) { pathRow($0) }
                }
            }

            if let urlString = fetchURL {
                networkSection(urlString)
            }

            writePreviewSection

            rawArgsSection

            Text("Runs in a sandboxed subprocess limited to the session workspace, with no network access.")
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
        .frame(width: 460)
        .interactiveDismissDisabled(true)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var severityBanner: some View {
        switch overallSeverity {
        case .sensitive:
            banner(
                icon: "exclamationmark.octagon.fill",
                color: .red,
                title: "Resolves to a sensitive location",
                detail: "A path below points at keys, credentials, or system files. Read the resolved target carefully before approving."
            )
        case .outside:
            banner(
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                title: "Resolves outside the workspace",
                detail: "A path below lands outside the session workspace. The sandbox denies access there — check why the tool is asking."
            )
        case .ok:
            EmptyView()
        }
    }

    private func banner(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func pathRow(_ arg: PathArg) -> some View {
        let tint = color(for: arg.severity)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(arg.key)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                Text(arg.note)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.15))
                    .foregroundStyle(tint)
                    .clipShape(Capsule())
            }
            Text(arg.resolved)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(arg.severity == .ok ? .primary : tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if arg.redirected {
                Text("requested: \(arg.raw)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func networkSection(_ urlString: String) -> some View {
        let host = URL(string: urlString)?.host ?? "unknown host"
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Outbound request to \(host)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("This sends a request over the network. Anything in the URL leaves your machine — check the destination.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(urlString)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var writePreviewSection: some View {
        if let lines = writeContentAllLines {
            let preview = Array(lines.prefix(5))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Content to write")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let size = existingFileSize {
                        Text("overwrites \(size) bytes")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Text("new file")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(preview.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if lines.count > 5 {
                    Text("… \(lines.count - 5) more line\(lines.count - 5 == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var rawArgsSection: some View {
        if call.args.isEmpty {
            Text("No arguments.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            DisclosureGroup("Raw arguments") {
                ScrollView {
                    Text(argsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 140)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .font(.caption)
        }
    }
}
