# Shellfish — proof of concept

A two-weekend proof that the core security claim of a sandboxed, capability-bound Mac AI assistant is mechanically real on macOS 26.

This is not a product. It is the floor under one. If the PoCs in here failed, building the product would be a waste of time. They pass.

## What this proves

Two scenarios, each a small CLI harness that exits 0/1 based on whether a simulated attack succeeds.

| | Scenario | Defense | Result |
|---|---|---|---|
| **S1** | Sandboxed `ToolRunner` is told by a fake LLM to exfiltrate to `127.0.0.1:9999/exfil` | OS-level `sandbox-exec` denies network egress | **PASS** |
| **S2** | Malicious MCP response asks agent to run a shell command; fake LLM complies | In-process `PermissionBroker` denies — session has no `shell` capability | **PASS** |

Both have negative controls: with the defense removed, the attack reaches the observer. So we know the PASS isn't coincidence.

See [`FINDINGS.md`](FINDINGS.md) for full details — exit codes, observer logs, what isn't proven, what comes next.

## What this does not prove

Honesty matters more than a clean PASS table:

- That a real LLM would actually emit the malicious tool call. The fake LLM is hardcoded to comply with the injection. A real Claude/GPT/Mistral might refuse. The PoC tests *containment if compliance happens*, which is the worst case.
- That the strict default-deny `sandbox-exec` profile works. It doesn't yet — Swift runtime won't initialize under the tight whitelist. Production would need this resolved or a move to App Sandbox + dynamic entitlements.
- That `sandbox-exec` itself will exist in macOS 27+. Apple has marked it deprecated for years. Replacement path is a separate spike.
- The interactive approval-dialog UX, the export/import signature scheme, the audit log, MCP transport, multi-provider — none of these are in the PoC. They're in the [threat model](../shellfish-threat-model.md) but not validated here.

## How to run

```sh
# requires Swift 5.9+ and macOS 13+ (tested on macOS 26 / Apple Silicon)
swift build

./run.sh                # S1
./run-s2.sh             # S2
```

Both should print `PASS` and exit 0.

To see the attack actually succeed without the defense:

```sh
SHELLFISH_PROFILE=$(pwd)/profiles/toolrunner-allow-all.sb ./run.sh   # S1 negative control
```

## Layout

```
.
├── Package.swift
├── FINDINGS.md                          ← S1 + S2 results, what they validate
├── run.sh / run-s2.sh
├── Sources/
│   ├── Harness/                         ← S1 orchestrator
│   ├── HarnessS2/                       ← S2 with in-process broker
│   ├── ToolRunner/                      ← sandboxed http_fetch executor
│   └── AttackerObserver/                ← logs incoming /exfil hits
└── profiles/
    ├── toolrunner.sb                    ← primary, allow-default + deny-network
    ├── toolrunner-allow-all.sb          ← S1 negative control
    └── toolrunner-strict.sb             ← stretch goal, currently INCONCLUSIVE
```

## Context

The motivation, threat model, and architecture live in [`docs/threat-model.md`](docs/threat-model.md) (v0.3). The PoC plan that this implements is in [`docs/poc-plan.md`](docs/poc-plan.md). The staged decision plan is in [`docs/development-plan.md`](docs/development-plan.md).

Short version: OpenClaw is a personal-AI-assistant project that, in Q1 2026, was publicly criticized for security holes by Microsoft, Kaspersky, Cisco, CrowdStrike, and Sophos. Sophos called it the "lethal trifecta" — an agent with private-data read + open network + untrusted-content ingestion is catastrophic by construction. Shellfish is an attempt to design those three out structurally rather than warn the user about them.

## Status

**Stage 0 + 1 of the staged plan are complete.** The decision gate is: does the work to date justify continuing to Stage 4 (a real vertical slice, ~3–4 months of evenings and weekends)?

That decision is for me, not the repo. The repo is what makes the decision possible.
