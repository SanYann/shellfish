# Shellfish

A security-first, local, open-source macOS AI assistant. Chat with a frontier
LLM and let it use tools — filesystem, and (later) shell, web, MCP — where the
defense against prompt injection is a **structural property of the OS**, not a
prompt or an application-level allowlist.

This repo is the architecture, proven and running. It is honest about what it
does not yet do (see [Status](#status)).

## Why this exists

OpenClaw is a popular personal-AI-assistant project that, in Q1 2026, was
publicly criticized for security holes by Microsoft, Kaspersky, Cisco,
CrowdStrike, and Sophos. Sophos named the core problem the **lethal trifecta**:
an agent that simultaneously has (1) private-data read, (2) open outbound
network, and (3) untrusted-content ingestion is catastrophic by construction —
a prompt injection in an email can exfiltrate your SSH key.

Most proposed fixes are model-level (better system prompts, injection
detection). Those help; they are not a defense. Shellfish takes the position
that the defense has to be structural: the agent must be *unable* to combine
the three legs of the trifecta in one session, regardless of what the model
decides to do. That's enforced with capability-bound sessions, an OS sandbox
(`sandbox-exec`), and a permission broker — not with TypeScript allowlists.

Full reasoning: [`docs/threat-model.md`](docs/threat-model.md) (v0.3).

## The security claims, mechanically proven

Three CLI harnesses, each exiting `0`/`1` based on whether a simulated attack
succeeds. Each has a **negative control** showing the attack lands when the
defense is removed — so a PASS isn't coincidence.

| | Scenario | Defense | Result |
|---|---|---|---|
| **S1** | A worst-case LLM is told to exfiltrate to `127.0.0.1:9999/exfil` | OS-level `sandbox-exec` denies network egress | **PASS** |
| **S2** | A malicious MCP response asks the agent to run a shell command; the LLM complies | In-process `PermissionBroker` denies — session has no `shell` capability | **PASS** |
| **S4** | A tool arg contains `../../../.ssh/id_rsa`-style path traversal | `fs_read` canonicalizes the path and rejects anything outside the workspace | **PASS** |

```sh
swift build
./run.sh        # S1
./run-s2.sh     # S2
./run-s4.sh     # S4
```

Full details, including what each does *not* prove: [`FINDINGS.md`](FINDINGS.md).

## What's running now

On top of those primitives sits a working headless kernel and a SwiftUI shell —
a real `claude-opus-4-7` conversation, brokered, sandboxed, and audit-logged.

```sh
export ANTHROPIC_API_KEY="sk-ant-..."
swift build

# CLI:
.build/debug/Chat

# GUI:
swift run ShellfishApp
```

In either front-end, a session is created with a minimal capability set
(filesystem read/write bound to one workspace, no shell, no network). When the
model requests a tool:

1. The `PermissionBroker` checks the session's capabilities (instant deny if not granted).
2. You're shown an approval prompt (CLI: `o/s/d/k`; GUI: native dialog) — with session-scoped "always" caching.
3. The tool runs in a `ToolRunner` subprocess under a `sandbox-exec` profile that denies network and any read of `/Users/<anyone>` outside the workspace.
4. The result is wrapped as `<tool_result source="untrusted">` before the model sees it.
5. Every step is appended to an audit log at `~/.shellfish/audit.jsonl` (SHA-256 hash of each output, for tamper detection).

Try asking it to read a file in the workspace (it'll ask permission), then ask
it to read `~/.ssh/id_rsa` (it can't — the path is outside the workspace, and
the sandbox would block it even if the app code had a bug).

## Layout

```
.
├── Package.swift
├── LICENSE                                 ← MIT
├── README.md
├── FINDINGS.md                             ← PoC results + headless-kernel writeup
├── ESSAY.md                                ← draft "what containment looks like" essay
├── run.sh / run-s2.sh / run-s4.sh          ← the three security harnesses
├── docs/
│   ├── threat-model.md                     ← the heart of the project (v0.3)
│   ├── poc-plan.md
│   ├── development-plan.md                  ← staged decision plan
│   └── stage4-plan.md                       ← step-by-step build plan for the app
├── profiles/
│   ├── toolrunner.sb                        ← S1 primary: allow-default + deny-network
│   ├── toolrunner-allow-all.sb              ← S1 negative control
│   └── toolrunner-strict.sb                 ← production-shape: deny user data + deny network
└── Sources/
    ├── ShellfishCore/                       ← shared library: provider, session loop, broker, audit
    │   ├── AnthropicProvider.swift          ← raw HTTP client for claude-opus-4-7
    │   ├── Session.swift                     ← ConversationLoop: LLM → broker → ToolRunner → result
    │   ├── Types.swift                       ← Capabilities, ToolCall, PermissionBroker
    │   └── AuditLogger.swift                 ← append-only JSONL audit log
    ├── ToolRunner/                          ← sandboxed tool executor (fs_read/write/list, http_fetch)
    ├── Chat/                                 ← interactive CLI front-end
    ├── ShellfishApp/                         ← SwiftUI front-end (window + native approval dialog)
    ├── AttackerObserver/                     ← test-only HTTP listener for exfil detection
    └── Harness / HarnessS2 / HarnessS4/      ← the three PoC harnesses
```

## Status

**Working:** the three security PoCs, the headless kernel (real Anthropic
conversation, broker, sandbox, audit log), three filesystem tools, and a
minimal SwiftUI window.

**Not here yet** (roadmap, not hidden holes):

- No menu-bar mode, no streaming, no inline tool rendering — the GUI is a v0.1.
- One provider (Anthropic). OpenAI + Mistral are designed (`docs/threat-model.md` §4.1) but unimplemented.
- No MCP support, no memory export/import.
- The broker runs in-process; the threat model wants it as a separate XPC service (v1 hardening).
- `sandbox-exec` is officially deprecated by Apple. It works through macOS 26; App Sandbox + dynamic entitlements is the long-term path.
- No code signing / notarization — you build it yourself with `swift build`.

None of those gaps is a lethal-trifecta hole. They're the difference between
"the architecture runs" and "your non-technical friend can install it."

## Requirements

- macOS 13+ (developed and tested on macOS 26 / Apple Silicon).
- Swift 5.9+.
- An Anthropic API key in `ANTHROPIC_API_KEY` for the `Chat` / `ShellfishApp` front-ends. (The PoCs need no key.)

## License

MIT. See [`LICENSE`](LICENSE).

## Contributing / security

This is an early personal project. Issues and discussion are welcome; response
times are best-effort. If you find a way to make the agent combine the lethal
trifecta in one session, that's the bug that matters most — please open an issue.
