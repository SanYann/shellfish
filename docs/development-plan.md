# Shellfish — Staged Development Plan (v0)

**Premise:** the project is currently a credibility asset (threat model + PoCs + writeup), not a product. It only becomes a product if and when you decide it is. Each stage has an explicit gate: PASS, FAIL, or KEEP-GOING.
**Status:** Draft · **Date:** 2026-05-06 · **Companion to:** `threat-model.md` v0.3, `poc-plan.md` v0

---

## Sequencing principle

Security claims are gates, not features. Every phase ends in a test that, if it fails, blocks the next phase rather than getting backlogged.

The order is:

1. **Prove containment** before building anything else (Stage 0).
2. **Build the security-critical core headless** before any UI.
3. **Add UI only after the kernel is stable.**
4. **Add features on top of the kernel.**
5. **Harden and ship.**

If a stage's gate fails, stop and decide: fix the architecture, downgrade the claim, or kill the project. Do not push forward and "fix it later."

## Stage 0 — S1 PoC (one weekend)

Specified in `poc-plan.md`. Exit:
- **PASS** (sandbox denies exfil) → Stage 1
- **FAIL because profile too strict** → spike App Sandbox + dynamic entitlements before continuing
- **FAIL because network leaked** → architecture is wrong, kill or rethink (cheap to learn now)

## Stage 1 — S2 PoC (one weekend)

Malicious MCP response cannot auto-execute via shell. Tests the PermissionBroker stub — the piece skipped in S1.

Exit:
- **PASS** → you now have the two PoCs that matter most. Stage 2.
- **FAIL** → broker design needs rework before anything else.

## Stage 2 — Credibility asset writeup (one weekend)

This is the **actual deliverable** of the exploration phase. After this, you can stop and the work has produced something real.

- Public GitHub repo, MIT or Apache-2.0 (resolve Q5).
- `README.md` that links the threat model, the PoC plan, the two PoC harnesses, and a short "why this should exist" essay.
- One blog post: "I tried to build a security-first Mac assistant. Here's what containment actually looks like." Lead with the K1-style demonstration — show the sandbox blocking the exfil.
- Done. You can ship this in three weekends total and have something genuinely interesting to point at.

## ⟨ Decision point ⟩

After Stage 2, stop and answer one question honestly: **do you want to spend 6+ months actually building this?**

- **No** → you have a credibility asset that took 3 weekends. Use it for what credibility assets are good for: writing, conversations with potential collaborators, your own confidence. This is a complete outcome.
- **Maybe** → do Stage 3 (one more weekend) and re-decide.
- **Yes** → enter Stage 4. But not before. The cost of saying "yes" prematurely is months of work on the wrong architecture.

## Stage 3 — Optional: third PoC + open questions (one weekend)

Pick one:
- S4 + S7 PoC (path-traversal + link-preview), to widen the validated surface.
- Resolve Q2 (MCP trust bootstrap) and Q3 (signing budget) — both are decisions, not code.

If after this weekend you still feel "yes I want to build this," go to Stage 4. If you feel "I've learned enough, I don't actually want to build it," that's also a valid answer — and one cheaper to find out now than in month four.

## Stage 4 — Minimum viable Shellfish (3–4 months, evenings + weekends)

This is not v1. It is one **vertical slice** that demonstrates one real session end-to-end:

- One provider only (Anthropic — fastest tool-use to validate).
- One session type only (read a local file, summarize it, no network).
- Headless CLI for two-thirds of it, SwiftUI shell only at the end.
- No MCP yet. No multi-provider. No export/import. No non-technical mode.
- Goal: one real Claude conversation that touches one real tool, fully sandboxed, end-to-end.

If you can't get this working in 4 months of part-time effort, the full architecture isn't reachable solo and you should stop or find a co-builder.

## Stage 5+ — Only if Stage 4 ships

The full v1 plan (MCP, multi-provider, export/import, non-technical mode, hardening) becomes relevant *here*, not before.

| Phase | Estimate |
|---|---|
| Headless kernel (broker + ToolRunner + sandbox + audit log) | 5 weeks |
| One provider end-to-end (Anthropic) | 3 weeks |
| SwiftUI shell, developer mode | 4 weeks |
| MCP support | 4 weeks |
| Multi-provider (OpenAI + Mistral) | 2 weeks |
| Memory export/import | 2 weeks |
| Non-technical mode | 3 weeks |
| Hardening + release prep | 5 weeks |

## Total realistic commitment

| If you stop at... | Calendar time | Outcome |
|---|---|---|
| Stage 2 | 3 weekends | Credibility asset (threat model + 2 PoCs + writeup) |
| Stage 3 | 4 weekends | Plus one more validated claim, two open questions resolved |
| Stage 4 | 4 months | Plus a working vertical slice — proof you can actually build this |
| Stage 8 (full v1) | ~12 months | Shippable 1.0 |

Each gate is a real off-ramp. The shape of the plan is: **make small, cheap commitments, evaluate honestly, then decide whether to make the next one.**

## Cuts available if timeline slips

In order of preference (cut from the top):

1. **Drop non-technical mode.** Ship developer-mode-only as 1.0. Honest scope.
2. **Drop OpenAI or Mistral, not both.** Mistral has the EU-residency story; OpenAI has the user pool. Pick one.
3. **Defer external security review** to 1.1 — keep it as a commitment, not a gate.
4. **Defer curated MCP list (Q2).** Stay user-provided-only forever; document loudly.

Do **not** cut: PoCs, broker, sandbox enforcement, audit log, signature on exports. Those are the project's reason to exist.

## Open decisions remaining (from threat model §9)

| Q | Status | Needed by |
|---|---|---|
| Q1 providers | Resolved (Anthropic + OpenAI + Mistral) | — |
| Q2 MCP curation | Open | Stage 4 (MCP integration) |
| Q3 signing/notarization | Open — confirm $99/yr budget | Stage 8 (could be earlier for dev-signed builds) |
| Q4 memory | Resolved (export/import) | — |
| Q5 license | Open | Before first public commit |
| Q6 audit budget | Open | Stage 8 |

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `sandbox-exec` deprecated mid-project | Medium | High | Spike App Sandbox alternative if PoC iteration exceeds 8h |
| Phase 4 reveals MCP protocol assumptions broke the broker | Medium | High | Build S2 PoC against a fake "MCP-shaped" subprocess to surface this in Stage 1 |
| Solo burnout around month 6 | High | High | SwiftUI shell intentionally placed before MCP — gives a demo-able artifact at the halfway point |
| Provider API drift (especially tool-use formats) | Medium | Medium | One adapter per provider; integration tests pinned to specific model IDs |
| Apple changes App Sandbox rules | Low | High | Out of our control; documented as residual risk |

## Pre-Stage-0 checklist

Things to nail down before writing a line of Swift:

- [ ] Resolve Q5 (license).
- [ ] Decide private vs. public repo. Recommendation: private until the writeup is ready; flip to public alongside Stage 2.
- [ ] Confirm Apple Developer membership budget (Q3) — needed for any signed build, even internal beta.
- [ ] Pick a project name registry (GitHub org? domain?). "Shellfish" availability.

---

*Keep this document terse, update phase estimates after each phase actually completes, and don't let it grow into a spec.*
