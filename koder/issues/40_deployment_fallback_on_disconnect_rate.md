---
status: open
priority: P2
---

# Issue 40 — Deployment-fallback on disconnect-rate threshold

**Status**: open
**Priority**: P2
**Filed**: 2026-05-09
**Tier**: B (plan → impl → diff-sanity)
**Sister**: builds on issue 24 (codex disconnect detection, superseded by 27)
and issue 27 (codex app-server adapter). Disconnect signal is already a
typed JSON-RPC event after issue 27.
**Source**: Holm codex telemetry brief (2026-05-08 → 2026-05-09 IST) +
Azure-side capacity response (Holm issue 276).

> Filed as a **suggestion**. The harness already auto-recovers from
> single-stream disconnects on `gpt-5.5` via the app-server adapter; this
> issue proposes a richer behavior for the case where the underlying
> Azure shared pool is in a sustained stress window and reconnects
> repeatedly land on the same hot pool.

## Problem

Azure OpenAI `GlobalStandard` SKU is multi-tenant on a shared pool.
Sustained pool stress (e.g. European business-hours peak in eastus2) shows
up as repeated mid-stream JSON-RPC disconnects on a single deployment for
the duration of the stress window. Current harnex behavior: on disconnect,
force-resume on the same deployment. If the deployment's pool is hot, this
repeats — the dispatch eats cumulative reconnect overhead and (possibly)
cache-locality drops without escaping the contended pool.

Recent capacity bump on the Azure side (Holm issue 275) is expected to
substantially reduce this — the pre-bump pattern was likely soft-throttle
near per-deployment TPM cap, not pool-wide contention. **This issue is
prophylactic**: ship the fallback mechanism so we have it if pool-level
stress shows up post-bump or in a future workload.

## Evidence

From Holm `dispatch.jsonl` (2026-05-09 IST):

| Dispatch                  | Duration | Disc | Disc/min | Result   |
|---|---|---|---|---|
| cx-250-member-oauth       | 21:02    | 145  | 6.9      | success  |
| cx-cr-i250                | 5:19     | 39   | 7.3      | success  |
| cx-252-runtime-coverage   | 10:12    | 61   | 6.0      | success  |
| cx-251-esm-docs-retry     | 3:10     | 3    | 0.9      | success  |
| cx-251-p25-fix            | 1:24     | 1    | 0.7      | success  |

Bimodal — dispatches in the same window cluster either at 6–7/min or
<1/min. Three time windows visible (high / quiet / high) consistent with
shared-pool stress, not client-side cause. All recovered cleanly on
`gpt-5.5` (the harness force-resume path works); the cost was reconnect
overhead.

## Existing infrastructure

- **Issue 27 (codex app-server adapter)** — disconnects are already typed
  events from the JSON-RPC server, not pane regex. The detection signal
  needed here exists.
- **Issue 23 (dispatch telemetry)** — `dispatch.jsonl` already records
  per-dispatch `disconnections` count. Disc/min derivation is trivial.
- **Issue 22 (built-in dispatch monitoring)** — has the watch loop where
  a "fallback should fire" signal can be emitted.
- **`lib/harnex/adapters/codex.rb`** — adapter is the right place to track
  disconnect timing.

## Proposed feature

When mid-dispatch disconnect rate exceeds a configurable threshold,
**retry the in-progress dispatch on an alternate deployment** rather than
reconnecting to the same one.

Configuration shape (sketch — plan-write should refine):

```bash
harnex run codex --tmux cx-NNN \
  --fallback-model gpt-5.5-dz \
  --fallback-disc-threshold 5/60s \
  -- -c model=gpt-5.5
```

Or via `--meta`:

```json
{
  "model": "gpt-5.5",
  "fallback": {
    "model": "gpt-5.5-dz",
    "trigger": "disc_rate_5_per_60s"
  }
}
```

Default: off (explicit opt-in via flag). When the threshold trips:

1. Stop the current Codex session.
2. Start a fresh Codex session against the alternate deployment with the
   same brief.
3. Record `fallback_triggered: true` + trigger details in
   `dispatch.jsonl`.

## Open design questions (plan-write must answer)

1. **Resume semantics across deployments.** Codex 0.128.0 supports session
   resume by session ID. Does session-resume work across deployments
   (same model name, different deployment) or only same-deployment? If
   same-deployment-only, fallback requires fresh dispatch + brief replay
   from scratch — meaningfully different cost shape.
2. **Cache-locality trade-off.** The alternate deployment likely has cold
   cache. Plan should weigh "stay on hot-pool deployment, eat reconnect
   cost, keep ~94% cache" vs "switch to cold-cache deployment, pay full
   prompt-prefix re-bill, escape pool stress". Telemetry from issue 23 +
   Holm's per-dispatch cache rates have the data to model both.
3. **Threshold value.** 5/60s is a starting guess. Plan should mine
   `dispatch.jsonl` (Holm + harnex DISPATCH.jsonl) for the distribution
   of disconnect rates and pick a threshold at the clear inflection point
   between "normal" and "stressed" (the bimodal signal in the evidence
   table suggests an obvious gap).
4. **Trigger granularity.** Per-dispatch (decide once on first burst, no
   re-evaluation) vs sliding-window (re-evaluate every minute, can
   fall back partway). Single-shot is simpler; sliding is more responsive.
5. **Telemetry shape.** Trigger-event fields (always needed):
   `fallback_triggered: bool`, `fallback_to: string`,
   `fallback_at_disc_count: int`, `fallback_at_wallclock_s: number`.

   Beyond the trigger event, the row must capture enough to answer
   *"was switching the right call?"* — i.e. compare the cost shape on
   each side of the switch. Two viable shapes; choice depends on Q1:

   - **Single-row + per-arm split** (if codex resume carries across
     deployments — one logical session): add `pre_fallback_*` /
     `post_fallback_*` splits for the counters that drive the
     trade-off — `disconnections`, `duration_s`, `cached_tokens`,
     `input_tokens`, `output_tokens`. Existing aggregate fields stay
     as the row-level total.
   - **Two linked rows** (if resume is same-deployment-only —
     fallback is a fresh dispatch): original row exits with new enum
     `exit: "fallback_triggered"`; child row carries
     `parent_dispatch_id` pointing at the original and gets normal
     counters against the new deployment. Reuses existing
     `parent_dispatch_id` infra (#35 Tier 2). No per-arm split fields
     needed — analysis joins by `parent_dispatch_id`.

   Both shapes are additive: rows without fallback are unchanged.
   Rate-over-time reconstruction (for tuning the threshold) comes from
   `events_log_path`, not new schema.
6. **Multi-fallback chains.** `gpt-5.5 → gpt-5.5-dz → gpt-5.4-mini`?
   Probably out of scope for v1; plan should explicitly note v1 = single
   alternate.

## Acceptance criteria (initial — plan can refine)

- New CLI flags: `--fallback-model <name>` and
  `--fallback-disc-threshold <N>/<window>s` (or equivalent in `--meta`).
- `dispatch.jsonl` populated per chosen shape in Q5: trigger-event
  fields always, plus either per-arm splits (single-row shape) or a
  child row with `parent_dispatch_id` (two-row shape). Cost shape on
  each side of the switch must be reconstructable from the row(s).
- Existing dispatches without the new flags behave unchanged.
- New tests cover: threshold trip → fallback fired, threshold not tripped
  → no fallback, fallback session telemetry recorded correctly.
- Documented in `docs/dispatch.md` (or wherever fallback semantics belong).

## Out of scope

- Auto-detection of fallback target (v1 requires explicit opt-in).
- Multi-fallback chains (single alternate only for v1).
- Cross-adapter fallback (codex-only for v1).
- Auto-tuning of threshold (manual flag only for v1).

## Triage

- **Tier**: B
- **Reasoning**: new state-machine branch in adapter; integrates with
  issue 27 JSON-RPC events; failure modes recoverable (default-off);
  events schema additive (fields appear only when fallback fires).
- **Phases**: plan → impl → diff-sanity
- **Plan count**: 1
- **Estimated sessions**: 2–3
- **Estimated wall-clock**: ~3–4h

## Notes

- This issue is the harness-side complement to Holm issue 276 (Azure-side
  response to codex telemetry brief). Filing here per Holm's
  `knowledge-base/ORCHESTRATOR.md` rule that harness-behavior changes
  belong in harnex, not in project workflow docs.
- Capacity bump (Azure side, 2026-05-09) may make this less urgent — if
  the bumped TPM cap eliminates the stress pattern entirely, this
  feature may sit unused in production. Worth shipping anyway: the
  failure mode it addresses is a structural property of GlobalStandard
  SKU, not specific to one workload.
- **Ship-to-measure.** Q2 (cache-locality vs reconnect cost) and Q3
  (single-shot vs sliding-window trigger) cannot be answered from
  desk-bound reasoning — both depend on the actual cost shape under
  real pool stress. Default-off + opt-in design means production
  becomes the testbed: opt-in dispatches generate the per-arm
  comparison data needed to tune the threshold and (later) the
  trigger granularity. Q1 (resume across deployments) is the one
  fact-finding question the plan should answer *before* picking the
  telemetry shape.
