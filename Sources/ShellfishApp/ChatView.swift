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
            HStack {
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if state.isThinking {
                    ProgressView()
                        .controlSize(.small)
                }
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

                Button {
                    state.send()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(state.isThinking || state.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .onAppear { inputFocused = true }
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            roleBadge
                .frame(width: 60, alignment: .leading)
            Text(message.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
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
        }
    }
}
