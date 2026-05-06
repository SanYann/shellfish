# Stage 4 — Step-by-step build plan

**Goal:** a single demo where you type a message in a SwiftUI window, Claude reads a file from a sandboxed workspace, and writes a summary back. Sandbox-enforced, broker-approved, audit-logged.
**Time budget:** 3–4 months evenings + weekends. If you blow past 5 months, stop and reassess.
**Status:** plan · **Date:** 2026-05-06 · **Companion to:** `development-plan.md`

---

## What you already have

These come into Stage 4 already validated by the PoCs — don't rebuild them, extend them:

- `ToolRunner` with `http_fetch` and `fs.read`
- `PermissionBroker` (in-process struct from HarnessS2)
- The strict `sandbox-exec` profile (`profiles/toolrunner-strict.sb`)
- Capability-set struct shape and the lethal-trifecta refusal logic
- `AttackerObserver` (keep — useful for ongoing security regression testing)

## What you're adding

- A real Anthropic API client (`AnthropicProvider`)
- A real conversation loop driving turns of (user → Claude → tool calls → results → Claude → …)
- `fs.write` and `fs.list` tools alongside `fs.read`
- An append-only audit log
- A SwiftUI menu-bar + chat-window app
- Native macOS approval dialogs

## Prerequisites

- Anthropic API key from [console.anthropic.com](https://console.anthropic.com). $5 of credit is plenty for development.
- Xcode 15+ (you only need the command-line tools you already have for the headless phases; full Xcode for the SwiftUI phase).
- An understanding that ~half of Stage 4 is the SwiftUI shell, which is the part most likely to drag.

---

## Phase 4.1 — Anthropic adapter (CLI only)

**Time:** 1–2 weeks · **Output:** a `Chat` CLI binary that can have one tool-using conversation with Claude, no UI.

### Step 1 — Get the API key into your environment

- Get the key.
- For Stage 4, use an environment variable: `export ANTHROPIC_API_KEY=sk-ant-...` in `~/.zshrc`.
- Production goes in Keychain (Stage 5+); for now, env var keeps the iteration loop fast.
- **Done when:** `echo $ANTHROPIC_API_KEY` prints your key.

### Step 2 — New executable target `Chat`

- In `Package.swift`, add `Chat` and a shared library target `ShellfishCore` for everything you'll reuse (capabilities, broker, session types).
- Move the in-process `PermissionBroker`, `Capabilities`, and `ToolCall` types from `HarnessS2/main.swift` into `Sources/ShellfishCore/`.
- HarnessS2 imports them; existing PoCs still pass.
- **Done when:** `swift build` succeeds, `./run-s2.sh` still passes.

### Step 3 — Minimal Anthropic API client

- Inside `ShellfishCore/`, add `AnthropicProvider.swift`.
- One method: `func send(messages: [Message], tools: [ToolDef]?) async throws -> Response`.
- POST to `https://api.anthropic.com/v1/messages` with `anthropic-version: 2023-06-01` header. Use `claude-sonnet-4-5` as the model for development (cheap, fast, supports tool use).
- Decode the response: text blocks, `tool_use` blocks, `stop_reason`.
- No streaming yet. One-shot only.
- **Done when:** a `Chat` invocation that sends `"hello"` prints Claude's text response.

### Step 4 — Add tool definitions and tool_use parsing

- Define `ToolDef` matching Anthropic's tool schema (name, description, input_schema as JSON Schema).
- Hand-write the schema for `fs.read`: `{ "type": "object", "properties": { "path": { "type": "string" } }, "required": ["path"] }`.
- Pass the tool def in the API request.
- Parse `tool_use` blocks from the response.
- **Done when:** asking Claude "read the file at /tmp/test.txt" returns a `tool_use` block with the right path.

### Step 5 — Streaming (optional in 4.1, deferrable to 4.5)

- Add `stream: true` to the API request.
- Parse the SSE event stream — `message_start`, `content_block_delta`, `message_stop`.
- This is the kind of thing that's easier to skip until the UI exists. Mark TODO and move on.

---

## Phase 4.2 — Conversation loop with broker + sandbox

**Time:** 1 week · **Output:** a CLI chat where Claude actually executes `fs.read` under the strict sandbox, end-to-end.

### Step 6 — `Session` and `ConversationLoop`

- `Session` holds: id, capabilities, transcript (array of messages), workspace path.
- `ConversationLoop.run(userInput:)` does:
  1. Append user message to transcript.
  2. Call `AnthropicProvider.send(messages: transcript, tools: capabilities.toolDefs)`.
  3. If response has `tool_use` blocks → for each, broker.authorize → spawn ToolRunner → wrap result as `<tool_result source="untrusted">…` → append.
  4. Loop step 2 until response has no more `tool_use`.
  5. Print final assistant text.
- **Done when:** at the CLI, you type "summarize /tmp/foo.txt" and get a real summary of a real file's contents from Claude.

### Step 7 — Wire the strict sandbox profile in

- `ToolRunner` invocation in the loop should use `profiles/toolrunner-strict.sb` with `WORKSPACE` and `BUILDDIR` set from session config.
- Test: ask Claude to read `~/.ssh/id_rsa`. Expect: broker (path validation) AND sandbox (OS-level deny) both reject.
- **Done when:** Claude cannot read anything outside the session workspace, regardless of how cleverly it phrases the request.

### Step 8 — CLI approval prompt

- For the headless version, broker shows a stdin prompt: `"Tool: fs.read, args: {path: /workspace/foo.txt}. Approve? [y/n]"`.
- Add session-scoped "always" caching: a `Set<ToolApprovalKey>` per session.
- The native dialog comes in 4.5; this is the placeholder.
- **Done when:** approving once auto-approves identical follow-up calls; denying kills the loop.

---

## Phase 4.3 — More filesystem tools

**Time:** 3–5 days · **Output:** Claude can read, write, and list files in the workspace.

### Step 9 — `fs.write` in ToolRunner

- New case in ToolRunner's switch: `fs.write` with `{path, content}`.
- Same canonicalization + workspace check as `fs.read`.
- Reject if path is outside workspace.
- Update strict profile: `(allow file-write* (subpath (param "WORKSPACE")))`.
- **Done when:** Claude can write a file to the workspace and the file appears.

### Step 10 — `fs.list` in ToolRunner

- New case: `fs.list` with `{path}`.
- Returns directory entries as JSON (name, isDir, size).
- Workspace-bounded.
- **Done when:** Claude can list the workspace directory and see correct contents.

### Step 11 — Tool definitions registered with the session

- `Capabilities` now includes `tools: [ToolDef]` derived from the capability flags (`fs.read: [paths]` → ToolDef for fs.read with that workspace).
- The session-creation step picks which tools to expose.
- **Done when:** a session created with `fs.read` only does NOT advertise `fs.write` to Claude.

---

## Phase 4.4 — Audit log

**Time:** 3 days · **Output:** an append-only file recording every tool call, every decision, every result hash.

### Step 12 — JSONL audit log

- `~/.shellfish/audit.jsonl`.
- One line per event: `{ts, session, kind: "tool_call|decision|result", tool, args, result_hash, decision}`.
- Skip SQLite for Stage 4 — JSONL is honest, append-only, human-readable. Upgrade to SQLite in Stage 8 if needed.
- Audit log writes happen in the broker, not in ToolRunner. ToolRunner has no write access to it.
- **Done when:** after a session, `cat ~/.shellfish/audit.jsonl` shows the expected events in order.

### Step 13 — Audit log integrity check

- The result_hash is SHA-256 of the tool result. Lets you later verify nothing was tampered with.
- Don't bother encrypting/signing it for Stage 4 — that's Stage 8 hardening.

---

## Phase 4.5 — SwiftUI shell

**Time:** 3–4 weeks · **Output:** the actual app you can show someone.

### Step 14 — Add macOS app target

- New target `ShellfishApp` in Package.swift, type `.executableTarget` with `LSUIElement: true` in its Info.plist for menu-bar-only behavior.
- Or: use Xcode to create a separate `Shellfish.xcodeproj` that depends on the SwiftPM library. Many find Xcode easier for SwiftUI work.
- **Done when:** `swift run ShellfishApp` (or running from Xcode) launches a process that doesn't crash.

### Step 15 — Menu bar item

- `NSStatusBar.system.statusItem` — a menu bar icon that, when clicked, opens a chat window.
- **Done when:** the icon is visible in your menu bar.

### Step 16 — Chat window

- `NSWindow` containing a SwiftUI `ChatView`.
- `ChatView` has: scrolling message list, text input field, send button.
- Message bubble component renders user / assistant / tool_use / tool_result differently.
- **Done when:** typing into the field and clicking send appends a "user" bubble. No backend yet.

### Step 17 — Wire chat to ConversationLoop

- `@StateObject` view model holds the active `Session` and `ConversationLoop`.
- Send button calls `loop.run(userInput:)`.
- Streaming: loop publishes message updates to the view model, which re-renders.
- **Done when:** typing a message produces a real Claude response in the chat window.

### Step 18 — Native approval dialog

- Replace the stdin prompt from Step 8 with `NSAlert`.
- Four buttons: Once / This session / Always / Deny.
- Modal to the chat window.
- The "Always" grant is keyed on `(tool, args-shape, capability-set)` per threat model §5.2.
- **Done when:** a tool call surfaces a real macOS modal that the user clicks; result threads back into the loop.

### Step 19 — Audit log viewer

- A second window (or a tab) showing the audit log as a table.
- Read-only. Reads from `~/.shellfish/audit.jsonl` on demand.
- **Done when:** the viewer shows the entries from your last session.

### Step 20 — Session switcher

- A simple session list in the menu bar dropdown: "Read & summarize", "Workspace files", and a "New custom session" option.
- Each preset is a hardcoded `Capabilities` struct.
- "New custom session" can show a YAML editor in dev-mode or just be hidden in non-dev — for Stage 4, hide it.
- **Done when:** you can pick a session preset and the chat starts with that session's capabilities.

---

## Phase 4.6 — Polish, debugging, demo

**Time:** 1–2 weeks · **Output:** something you can record a video of.

### Step 21 — Error handling pass

- Network errors from Anthropic: retry with backoff (3 tries), then surface to user.
- Tool errors: surface in the chat as a tool_result with `is_error: true`.
- ToolRunner timeouts: hard cap at 30s, cancel and surface.
- **Done when:** flipping airplane mode mid-conversation produces a clean error message, not a crash.

### Step 22 — Cancel button

- A stop button in the chat that cancels the in-flight LLM request and any pending ToolRunner subprocess.
- **Done when:** mid-stream cancel produces a partial assistant message and stops cleanly.

### Step 23 — Workspace switching

- A small dropdown above the chat input lets the user pick from `~/.shellfish/workspaces/*`.
- Default workspace is created at first run with a README explaining what goes in it.
- **Done when:** pointing the session at a different workspace folder makes Claude see different files.

### Step 24 — Record the demo

The demo:

> 1. Open Shellfish from the menu bar.
> 2. Pick "Read & summarize" session.
> 3. Type: "Summarize the meeting notes from yesterday."
> 4. Claude requests `fs.read("~/Shellfish/workspace/notes/2026-04-22.md")`. Approval dialog appears. Click "This session."
> 5. Summary streams in.
> 6. Type: "Now read my SSH key."
> 7. Claude requests `fs.read("~/.ssh/id_rsa")`. Either Claude refuses (model alignment), OR the broker rejects with "path outside workspace" — show whichever happens.
> 8. Open the audit log viewer. Show both events recorded.
> 9. Stop recording.

That's Stage 4. Send the recording (and the repo link) to one technically-credible person whose reaction you trust. Their reaction is the data point that tells you whether to keep going.

---

## Acceptance criteria for "Stage 4 done"

All of the following must be true:

- [ ] You can have a full back-and-forth conversation with Claude inside a Shellfish window.
- [ ] At least one tool call (fs.read) goes through approval and executes inside the strict sandbox.
- [ ] At least one attempted tool call outside the workspace is rejected (broker OR sandbox OR both).
- [ ] The audit log records every tool call with timestamps and result hashes.
- [ ] The S1 / S2 / S4 PoCs still pass after all the changes.
- [ ] You can record the demo above start-to-finish without it crashing.

If any of these are false at month 4, treat that as a signal that Stage 4 has scope-crept and either trim to make it true or stop.

## What is explicitly NOT in Stage 4

If you find yourself doing any of these, you're in Stage 5+:

- Multi-provider (OpenAI, Mistral)
- MCP support
- Memory export/import
- Non-technical mode
- Notarization, signing, installer
- Public release prep
- Any feature added "while I'm here anyway"

Each of those is its own Stage 5–8 phase. Stage 4 is "the cheapest possible thing that proves end-to-end works."

## Risks to watch

- **SwiftUI fatigue.** This is the longest phase and the one most likely to drag. If you're 3 weeks into Phase 4.5 and the chat window still doesn't render messages, consider whether a non-SwiftUI front-end (e.g. a TUI with `swift-tui` or even a web UI in a `WKWebView`) gets you to demo faster. A worse-looking demo that exists beats a beautiful one that doesn't.
- **API drift.** Anthropic's tool-use format may evolve. Pin a specific model ID in `AnthropicProvider` and the integration tests.
- **macOS sandbox changes.** If a future macOS update breaks the strict profile, you find out via the existing PoC tests. Run them periodically.
- **Solo burnout.** Three months is a long time for a project nobody else is using. Set a calendar reminder for month 2 to ask yourself "is this still fun?" — and answer honestly.

## After Stage 4

Don't decide at the start of Stage 4 whether you'll continue. Decide *after* the demo, with one outside reaction in hand. The whole point of the staged plan is that each gate is a real off-ramp.

---

*This plan is meant to be edited. As soon as you start Step 1, you'll find things wrong with this document. Update it.*
