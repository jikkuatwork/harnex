---
status: open
priority: P2
issue_kind: slice
created: 2026-07-15
updated: 2026-07-15
tags: claude,adapter,usage,cost,context,telemetry,pty
---

> Priority note (2026-07-15): the operator's dispatch-model policy now keeps
> Claude out of automatic dispatch (GPT-family only; Claude is
> manual/interactive). This issue therefore covers explicitly-authorized
> Claude dispatches and the adapter-generic completed-with-proof
> classification fix; downgraded from P1 to P2.

# Issue 58 — Claude adapter usage/cost/context capture and completion semantics

## Problem

The Claude adapter (`lib/harnex/adapters/claude.rb`) is a pure PTY wrapper
around `claude --dangerously-skip-permissions` that screen-scrapes input state.
It emits no usage, cost, model, or context telemetry at all.

In SDK Queue `#002`, Claude Sonnet workers were the *only* adapter family that
reliably produced implementation commits (five durable product commits), yet:

- their token/cost contribution is entirely absent from the run accounting —
  the recorded `$21.18` total is a lower bound purely because of this hole;
- their terminal state commonly read `disconnected` even though typed artifact
  reports and commits existed, forcing the coordinator to reconcile Git,
  reports, and panes by hand every time;
- with pre-plan-31 rows, absent usage was indistinguishable from zero usage.

The most productive adapter in the run was the least observable one.

## Goal

Give the Claude adapter the same telemetry citizenship as Pi/Codex:

1. **Usage/cost/model capture.** Candidate producers, in preference order:
   - a structured headless mode for one-shot dispatches: `claude -p
     --output-format stream-json` exposes per-turn usage and result metadata
     over stdout, which fits `--auto-stop` workers well;
   - parsing the session transcript JSONL Claude Code writes locally, as a
     post-hoc usage source keyed by session id (bounded fields only — usage,
     model, turn counts; never message content);
   - explicit `usage.status: unsupported` provenance when neither is available,
     so absence stays distinguishable from zero.
2. **Context pressure.** Extend #54's `context` block with whatever the chosen
   producer exposes; `unsupported` is acceptable, silence is not.
3. **Completion semantics.** A Claude worker that emitted an ingested typed
   report and signaled completion must not surface as `disconnected`
   reliability tax (feeds #57's `completed_with_proof` class).

## Acceptance criteria

- [ ] A Claude dispatch row can carry `usage` (input/output/cached), `model`,
      and `cost` with provenance, or explicit `unsupported` status per field.
- [ ] At least one producer path (headless structured mode or transcript
      parse) is implemented and tested with fixture data.
- [ ] No producer path captures message content, prompts, or tool payloads.
- [ ] Completed-with-report Claude sessions stop classifying as disconnected
      failures in reliability/summary blocks.
- [ ] Docs state which Claude CLI modes support which telemetry fields.

## Out of scope

- Rewriting the interactive PTY flow for long-lived sessions (structured mode
  may be one-shot only; PTY remains for interactive use).
- Anthropic billing reconciliation.
- Claude-specific retry/recovery logic (#42/#40 territory).

## Relationship to existing work

- #46 restored cost telemetry generally; this closes its largest per-adapter
  gap.
- #54 context pressure currently has no Claude producer.
- #24/#48 cover disconnect/done-marker detection; the completion-semantics fix
  here should reuse their signals rather than adding a parallel mechanism.
- #45 did the analogous stable-marker work for the Pi PTY adapter.

## Triage

- **Tier**: B.
- **Risk**: medium — depends on Claude CLI surface stability; keep producers
  behind capability detection and degrade to `unsupported` explicitly.
- **First useful slice**: headless `-p --output-format stream-json` dispatches
  for `--auto-stop` workers with usage+model+cost capture, everything else
  `unsupported`.
