# Plan 22: Mapping — Built-in Dispatch Monitoring

Issue: #22
Date: 2026-04-29
Status: mapping (not yet split into thin layers)

## Purpose of this doc

Issue #22 proposes two surfaces (`harnex events` + `harnex run --watch`).
Before splitting into thin layers for Codex dispatch, map the feature
space, surface tensions with holm's current practice, and identify the
minimum viable layer path.

## What holm actually does today (ground truth)

Reviewed `~/Projects/holmhq/holm/master/scripts/harnex/` and
`knowledge-base/workflows/harnex/` to anchor the design in real usage.

| Concern | Holm's current signal | Issue #22 proposes |
|---|---|---|
| Stall detection | `harnex status` state == `unknown` for ≥2m | Log mtime idle ≥ N min |
| Completion detection | Done-marker files (`/tmp/<id>-done.txt`) + commit count + clean tree + exited | Session exited |
| Disconnect detection | `harnex pane --lines 3` regex (`stream disconnected`, `response.failed`) | Not addressed |
| Resume policy | `harnex send --force --message resume`, max 3 attempts | Same, configurable |
| Hard timeout | 90 min batch-wide | Per-session via `--stall-after` |
| Concurrency cap | Azure 5-concurrent (external) | Not addressed |

**Key holm rule:** orchestrator never polls; monitoring is delegated to
`scripts/scratch/monitor-batch.sh` (bash daemon) or per-dispatch sweep
agents. The orchestrator's context stays clean.

**Key holm files:**
- `scripts/harnex/dispatch-batch.sh` — spawn + wait-for-prompt
- `scripts/harnex/sweep.sh` — per-dispatch cleanup, force-resume on disconnect
- `scripts/scratch/monitor-batch.sh` — batch completion daemon
- `knowledge-base/workflows/harnex/{INDEX,resilience,monitoring}.md`

## Tensions to resolve before dispatch

1. **Activity signal: log mtime vs state=unknown vs done markers.**
   Issue #22 picks log mtime. Holm uses state polling. Done markers are
   the most reliable completion signal but require worker cooperation.
   *Resolution:* harnex owns activity (log mtime) + liveness (state).
   Done-markers stay caller-owned (out of scope).

2. **What counts as "stalled"?** Issue #22 says log idle ≥ N min.
   But Codex mid-test-gate emits no log lines for minutes. Holm's
   2m-on-`unknown` had the inverse problem: too aggressive.
   *Resolution:* `--stall-after` defaults must be conservative
   (≥8m for impl preset). Document the failure mode in the preset doc.

3. **Disconnect detection.** Holm's sweep regex (`stream disconnected`)
   catches a real failure mode that log-mtime misses (Codex re-emits
   nothing after disconnect). Should `--watch` also pane-grep?
   *Resolution:* defer to a layer 3. Layer 1+2 ship without it; if
   real-world shows disconnect dominates, add as `--detect-disconnect`.

4. **Events stream as public API.** Once we ship `harnex events`, we
   own its schema. Cheap to start narrow (`started`, `log_idle`,
   `log_active`, `send`, `exited`) and grow.
   *Resolution:* publish v1 schema in `docs/events.md`, mark
   "additive changes only without major bump."

5. **One-shot agent ≠ loop (trap #3 from issue).** This is a *caller*
   problem (Claude `Agent` tool returns immediately). harnex can help
   by making `--watch` blocking-by-default and self-terminating, so the
   subagent prompt is "run `harnex run --watch`" not "loop every 60s."
   *Resolution:* `--watch` runs in foreground and exits when watch ends;
   no separate polling for the caller.

## Layer map (thinnest → thickest)

### Layer 1: log-mtime activity tracking (foundation)
- Track `output_log_path` mtime per session (already exists at
  `~/.local/state/harnex/output/<repo>--<id>.log`)
- Add `log_mtime` and `log_idle_s` fields to status payload
- ~30 LoC in `Session` + `commands/status.rb`
- **No new commands.** Pure data exposure.
- Tests: status JSON contains both fields; mtime advances when agent
  emits.

### Layer 2: `harnex run --watch` blocking babysitter
- New flags on `run`: `--watch`, `--stall-after <dur>`, `--max-resumes <n>`
- After spawning session, foreground process polls every 60s:
  - read live status (state + log_idle_s)
  - if `log_idle_s ≥ stall_after` and state != exited: force-resume,
    increment counter
  - if state == exited: print summary, exit watcher
  - if resumes ≥ max: print escalation, exit watcher (do not kill session)
- ~80 LoC in a new `commands/watch.rb` or extension to `run.rb`
- Tests: fake-clock test that triggers stall + resume + exit summary.

### Layer 3: presets
- `--preset impl|plan|gate` selects `--stall-after`/`--max-resumes`
  defaults; explicit flags override.
- ~20 LoC + a small constant table.
- Tests: preset resolves to expected values; flags override.

### Layer 4: `harnex events --id X` JSON-line stream
- Subscribe to a new in-process event bus, render JSONL to stdout, exit
  when session exits (or on `--follow=false` snapshot).
- Required event types: `started`, `log_active`, `log_idle`, `send`,
  `resume`, `exited`. Schema doc.
- ~80 LoC: event bus in `Session`, command in `commands/events.rb`,
  emission points (start, watcher, send, exit).
- Tests: emit + capture round-trip; schema stability.

### Layer 5 (deferred): disconnect detection via pane regex
- Optional `--detect-disconnect` on `--watch` that runs `harnex pane`
  every cycle and force-resumes on regex match. Defer until needed.

## Recommended dispatch order

1. **Plan 23** (Layer 1 / log-mtime). Foundation; risk-free, ~30 LoC.
2. **Plan 24** (Layer 2 / `--watch`). Solves the immediate pain, ~80 LoC.
3. **Plan 25** (Layer 3 / presets). Sugar on top of 24, ~20 LoC.
4. **Plan 26** (Layer 4 / events). Public API; ~80 LoC + docs.
5. **Layer 5** (deferred): disconnect-regex detection — file as separate
   issue if stalls recur after 23–26 ship.

After L1+L2+L3 ship, holm's `monitor-batch.sh` can be replaced by
`harnex run codex --watch --preset impl` per session, with done-markers
remaining the completion ground truth on the holm side.

## Out of scope (kept from issue #22)

- Brief validation gate
- Structured result extraction (`harnex result`)
- Tier-aware shorthand
- Done-marker convention (caller-owned)
- Concurrency cap / Azure throttle (caller-owned)

## Open questions for Jikku

- **Q1:** OK to leave done-markers caller-owned? (Recommend: yes.)
- **Q2:** Is L4 (events stream) worth shipping speculatively, or wait
  for a second consumer? (Recommend: wait.)
- **Q3:** Default polling cadence — 60s like holm, or finer? (Recommend:
  60s; expose `--watch-interval` only if we need it.)
- **Q4:** `--watch` blocking foreground vs detaching to background?
  Issue #22 implies foreground; that matches "subagent runs one
  command and returns." (Recommend: foreground only for now.)
