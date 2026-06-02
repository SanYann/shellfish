// Main chat window. Message list on top, status + input at the bottom.
// Phase 4.5 v1 — deliberately plain. Improvements (Markdown rendering,
// streaming, inline tool blocks, scroll-to-bottom polish) come in later
// iterations once the wiring is proven.

import SwiftUI
import ShellfishCore

struct ChatView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack(spacing: 10) {
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if state.isThinking {
                    ProgressView()
                        .controlSize(.small)
                }

                Menu {
                    ForEach(state.presets) { preset in
                        Button {
                            state.selectPreset(preset)
                        } label: {
                            if preset.id == state.selectedPreset.id {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                    Divider()
                    Button("Change Workspace…") { state.chooseWorkspace() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: state.selectedPreset.icon)
                        Text(state.selectedPreset.shortLabel)
                    }
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Session capabilities & workspace")

                Button {
                    state.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New session (⌘N)")

                Button {
                    state.showAudit = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Audit log (⌘L)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.messages) { msg in
                            MessageRow(message: msg)
                                .id(msg.id)
                        }
                        if state.isThinking {
                            HStack {
                                Image(systemName: "ellipsis.circle")
                                Text("thinking…")
                                    .foregroundStyle(.secondary)
                            }
                            .id("thinking")
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: state.messages.count) { _ in
                    if let last = state.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: state.isThinking) { thinking in
                    if thinking {
                        withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Input bar
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message…", text: $state.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { state.send() }
                    .disabled(state.isThinking)

                if state.isThinking {
                    Button {
                        state.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: [.command])
                    .help("Stop (⌘.)")
                } else {
                    Button {
                        state.send()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(state.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
        .onAppear { inputFocused = true }
        .sheet(item: $state.pendingApproval) { pending in
            ApprovalSheet(call: pending.call, workspacePath: state.workspacePath) { decision in
                state.resolveApproval(decision)
            }
        }
        .sheet(isPresented: $state.showAudit) {
            AuditLogView(logPath: state.auditLogPath, currentSession: state.sessionId)
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            roleBadge
                .frame(width: 60, alignment: .leading)
            messageBody
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    /// Assistant messages render inline Markdown (**bold**, `code`, *italics*,
    /// links) for prose, and fenced ``` blocks as real monospace code boxes.
    /// The text is split into prose/code segments first; an unterminated fence
    /// (mid-stream) still renders as code so streaming looks right.
    @ViewBuilder
    private var messageBody: some View {
        switch message.role {
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(parseChatSegments(message.text).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .prose(let s):
                        Text(chatMarkdown(s))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .code(let lang, let body):
                        codeBlock(lang: lang, body: body)
                    }
                }
            }
        case .tool:
            Text(message.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .user:
            Text(message.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func codeBlock(lang: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lang = lang, !lang.isEmpty {
                Text(lang)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(body)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var roleBadge: some View {
        switch message.role {
        case .user:
            Text("you")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(.blue)
        case .assistant:
            Text("claude")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(.purple)
        case .system:
            Text("system")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        case .tool:
            Text("tool")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Markdown / code-fence segmentation

enum ChatSegment {
    case prose(String)
    case code(lang: String?, body: String)
}

/// Split assistant text into prose and fenced-code segments. A ``` line
/// toggles code mode; the language tag after the opening fence is captured.
/// An unterminated fence (the model is still streaming the block) flushes as
/// code so it renders correctly before the closing fence arrives.
func parseChatSegments(_ text: String) -> [ChatSegment] {
    var result: [ChatSegment] = []
    var inCode = false
    var lang: String?
    var buffer: [String] = []

    func flushProse() {
        let joined = buffer.joined(separator: "\n")
        buffer.removeAll()
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.prose(joined))
        }
    }
    func flushCode() {
        let joined = buffer.joined(separator: "\n")
        buffer.removeAll()
        result.append(.code(lang: lang, body: joined))
        lang = nil
    }

    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if inCode {
                flushCode()
                inCode = false
            } else {
                flushProse()
                inCode = true
                let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                lang = tag.isEmpty ? nil : String(tag)
            }
            continue
        }
        buffer.append(line)
    }
    if inCode { flushCode() } else { flushProse() }
    return result
}

/// Inline-only Markdown (bold, italics, inline `code`, links) with newlines
/// preserved. Block constructs other than code fences are intentionally left
/// to render as plain text — the fences are handled by the segmenter.
func chatMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: text, options: options))
        ?? AttributedString(text)
}
