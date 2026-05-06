# Shellfish PoC — Findings

**Date:** 2026-05-06 · **Platform:** macOS Tahoe (Darwin 25), Apple Silicon, Swift 6.3
**Scope:** S1 and S2 from `shellfish-threat-model.md` v0.3.

| Scenario | Claim | Result |
|---|---|---|
| **S1** | Sandboxed `ToolRunner` cannot exfiltrate via network even when fake LLM emits a malicious tool call | **PASS** |
| **S2** | Capability-bound broker denies `shell.exec` requested in response to an injected MCP response | **PASS** |

---

## S1 — sandbox-exec containment

**Scope:** a sandboxed `ToolRunner` cannot exfiltrate to `http://127.0.0.1:9999/exfil` even when a fake LLM emits a malicious tool call.

### Result: **PASS** on primary profile

Three runs, three different profiles, all with the same harness:

| Profile | Approach | ToolRunner exit | Observer `/exfil` hits | Verdict |
|---|---|---|---|---|
| `toolrunner.sb` (primary) | `(allow default) (deny network*)` | 1 (POSIX `Operation not permitted`) | 0 | **PASS** |
| `toolrunner-allow-all.sb` (negative control) | `(allow default)` | 0 (HTTP 200 from observer) | 1 | FAIL — as expected |
| `toolrunner-strict.sb` (stretch, default-deny) | `(deny default)` + whitelist | 6 (Swift runtime did not initialize) | 0 | INCONCLUSIVE |

The negative control matters: it proves the attack is real and the primary profile is what blocks it, not some unrelated coincidence (e.g. `URLSession` failing for another reason, observer not actually reachable, etc.).

## What this validates

- `sandbox-exec` on macOS 26 can reliably deny outbound network from a Swift child process. The error surfaces cleanly through `URLSession` as `NSPOSIXErrorDomain Code=1 "Operation not permitted"` — identifiable in code, not a silent hang.
- The architectural shape from threat model §5.1 (UI → broker → sandboxed `ToolRunner` subprocess) is buildable. ~150 lines of Swift, sub-30s build, sub-1s test.
- The `URLSession` API path goes through a single chokepoint that the sandbox catches. No need for application-level allowlisting on top of OS-level enforcement.

## What this does NOT validate

- **The strict default-deny profile.** Under `(deny default)` with my whitelist, ToolRunner exits 6 before emitting any output — the Swift runtime needs more access than I granted it on first try. This is the "wild card" called out in PoC plan §3 note 2. It does not block S1 (the primary profile already proves containment), but it matters for production: the primary profile is "deny network", which is fine for *this* attack, while a real Shellfish session would also need filesystem isolation, mach-lookup limits, etc. Resolving the strict profile is a Stage 1 item, not a Stage 0 one.
- That a real LLM would behave like the fake one. The fake LLM is hardcoded to emit the malicious tool call. A real Claude/GPT/Mistral might refuse, or might comply differently. The PoC tests containment; it does not test model behavior.
- That the broker design works (no broker in the PoC). Next.
- That `sandbox-exec` will still exist in macOS 27+. Apple has marked it deprecated. The architectural answer is App Sandbox + dynamic entitlements; that's a separate spike.

## Cost

- ~1 hour from empty directory to PASS, including the run.sh bug, the observer logging bug, and the strict-profile detour. The PoC plan budgeted 4–7 hours; the primary-profile path turned out to be shorter than expected because Swift 6.3 + `Network.framework` required no dependencies and the `(allow default) (deny network*)` profile is genuinely simple.
- Most of the time was spent on the inconclusive strict-profile detour and on harness diagnostic plumbing (distinguishing "sandbox blocked the call" from "profile failed to load"). Neither was strictly necessary for S1.

## What I'd do next

In priority order:

1. **Stage 1 — S2 PoC.** Malicious MCP response cannot auto-execute via shell. This tests the PermissionBroker stub that S1 deliberately skipped.
2. **Strict-profile spike.** Get a default-deny profile that runs Swift cleanly. Probably needs `(allow mach-lookup)` to specific services, more `iokit-open` entries, and `(allow file-read*)` on a few `/usr/share` paths. ½–1 day of work.
3. **App Sandbox alternative.** Determine whether `sandbox-exec` deprecation is a real problem or a docs-only one for our use case. Spike: same S1 scenario but using `NSXPCConnection` + a properly-entitled App Sandbox helper instead of `sandbox-exec`.

Items 2 and 3 are independent and could be done in either order.

## S1 repro

```
swift build
./run.sh                                                    # primary profile, PASS
SHELLFISH_PROFILE=$(pwd)/profiles/toolrunner-allow-all.sb ./run.sh   # negative control, FAIL (expected)
SHELLFISH_PROFILE=$(pwd)/profiles/toolrunner-strict.sb ./run.sh      # strict, INCONCLUSIVE
```

---

## S2 — capability-bound broker

**Scope:** a malicious MCP server returns a response containing a prompt injection that asks the agent to run a shell command. A worst-case LLM complies and emits `shell.exec("curl …/exfil")`. The PermissionBroker must deny that call because the session was created without `shell` capability.

### Result: **PASS**

| Mode | Capabilities | Broker decision on `shell.exec` | Shell ran? | Observer `/exfil` hits |
|---|---|---|---|---|
| Primary | `mcp=[malicious-mcp], shell=false` | **DENY** ("shell capability not granted") | no | 0 |
| Negative control | `mcp=[malicious-mcp], shell=true` | APPROVE | yes | 1 |

The negative control proves the curl command would have actually exfiltrated if the broker had approved. In the primary run it's the capability check, not luck, that contained the attack.

### What this validates

- **The lethal-trifecta defense is mechanical, not model-dependent.** The fake LLM is told to comply with the injection. It does. The broker doesn't care — it checks capabilities and denies. The model could be anything; the architectural floor holds.
- **MCP responses are data, not instructions.** The Harness prints the MCP response with a `<tool_result source="untrusted">` header (matching the §5.4 envelope). The fact that the response *contains* the string "run this shell command" doesn't translate into auto-execution because there is no execution path that takes MCP output as input. Execution only happens via tool calls, and tool calls go through the broker.
- **In-process broker stub is enough to test the architectural claim.** The threat model has the broker as a separate XPC service (§5.1, §5.2). For S2, the placement doesn't matter — what matters is that *some* component, distinct from the LLM, owns the approve/deny decision. Moving it to XPC is an isolation hardening for v1, not a change to S2's correctness.

### What this does NOT validate

- **Interactive approval dialogs.** The PoC tests capability denial only (no shell capability → automatic deny). The threat model §5.2 specifies a four-button native dialog (once/session/always/deny). That UX is untested. It also introduces the dialog-fatigue failure mode — users clicking "Always" out of habit. A separate UX-level study, not a PoC.
- **The "always" grant isolation.** Threat model §5.2 says approval grants are scoped to `(tool, argument-pattern, session-capability-set)` tuples. Untested here. Probably worth a tiny S2-bis PoC: approving `shell.exec("ls ~/Documents")` should not auto-approve `shell.exec("rm -rf ~")`.
- **MCP transport.** The PoC inlines the malicious MCP response as a string. Real MCP runs as a stdio subprocess. The transport doesn't affect S2's logic (broker is upstream of MCP), but a real MCP integration is its own work.

## S2 repro

```
swift build
./run-s2.sh
```

---

## Cumulative status (after Stages 0 + 1 of staged plan)

The two security claims that gate the rest of the architecture are now mechanically verified on macOS 26:

1. **OS-level network containment** of a Swift child process (S1).
2. **Capability-level containment** of injection-induced tool escalation (S2).

This is the "credibility floor" called out in the staged plan §Stage 2. With a short writeup ("here is what containment actually looks like, with two reproducible PoCs"), the work to date is a coherent public artifact.

### Recommended next decisions

- **Stop or continue?** The staged plan has an explicit decision point after Stage 2. The case for continuing is strongest now, before the work cools.
- **If continuing**, the highest-value next PoC is S4 (path traversal — does the workspace-restricted profile actually reject `../../../.ssh/id_rsa`?) because it's the third independent containment primitive.
- **The strict default-deny `sandbox-exec` profile is still unsolved.** That is the production-shape question, not an S1 question. Worth a half-day spike before any v1 work begins.
