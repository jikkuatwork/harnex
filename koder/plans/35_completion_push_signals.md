---
status: draft
issue: 71
plan: 35
tier: B
layer: unattended-completion-reliability
created: 2026-09-03
updated: 2026-09-03
phases: 5
---

# Plan 35 — Session-owned completion push signals (#71)

## User decisions captured

- Issue #71 is the next implementation priority, ahead of #69, because it
  affects the currently recommended unattended fresh-worker lifecycle; #69 has
  the bounded `--auto-stop` workaround and remains next.
- This plan covers only the core push-signal slice: a durable default marker,
  one optional completion hook, and loud rejected-work visibility.
- Use one `--on-done` hook with a typed outcome. Do not add a parallel
  `--on-fail` surface in this slice.
- Reuse the existing `outcome.class` / `outcome.status` vocabulary. Do not add a
  competing top-level `outcome_class: rejected` schema.
- `wait`/`watch` heartbeat and hard-deadline work require their own bounded
  follow-up plan. `--exit-on-prompt` is not part of the solution: prompt state
  is not proof, and the source incident already had `task_complete`.

## Capability statement

A registered Harnex session publishes one durable, typed completion marker and
optionally launches one operator hook at its first work-terminal result, even
when no `wait` or `watch` client is attached and the wrapped agent remains alive
at a prompt.

## Current state (verified at `74b69a9`)

- `Harnex::Session` owns structured `task_complete`, `task_failed`, and
  `dispatch_error` transitions. Accepted completion already writes the
  harness-authored receipt before emitting `task_complete`.
- `harnex watch` can write caller-selected done/fail markers, but only after the
  watching process observes the result. It cannot page anyone when that caller
  is absent or its tool result is swallowed.
- `TerminalWatcher#capture_wait` redirects `$stdout`/`$stderr` into `StringIO`
  until `Waiter#run` returns. A heartbeat added only to `Waiter` would therefore
  remain invisible through `watch`; that work is deliberately deferred.
- `harnex status` table rendering prefers adapter input state, so a live worker
  with rejected work can appear merely as `prompt` even though JSON already
  carries `task_failed`, `work_state`, `outcome_class`, and
  `artifact_report_status`.
- The v2 `dispatch_end` row already has the canonical nested `outcome` block and
  `wait --until done` already returns `2` for rejected proof. This plan should
  assert and expose those semantics, not redesign them.
- Issue #69 remains separate: explicit idle stop can rewrite accepted Pi proof.
  This plan must prove notification before cleanup and must not absorb stop
  lifecycle changes.

## Layer boundary

This is the first plan in the `unattended-completion-reliability` layer for
Issue #71.

In scope:

1. a session-owned default marker for the first work-terminal result;
2. `harnex run --on-done CMD`, propagated through foreground, detached, and
   tmux launch paths;
3. exactly-once and non-blocking hook launch with a fixed environment contract;
4. loud rejected/failed state in `harnex status` and regression coverage for
   canonical rejected telemetry;
5. operator documentation and a process-level no-watcher smoke.

Deferred to later monotonic plan IDs:

- streamed `wait`/`watch --heartbeat`;
- a monotonic, hard `--max-wait` boundary under slow probes;
- any reconsideration of prompt-based exits.

## Locked public contract

### CLI

```text
harnex run <cli> [options] --on-done CMD [--] [cli-args...]
```

- Support both `--on-done CMD` and `--on-done=CMD` in the existing wrapper
  parser.
- `CMD` is an explicit operator-authored shell command executed as
  `/bin/sh -c CMD` from the resolved repository root.
- The option is valid with or without `--auto-stop`; it applies to the first
  work-terminal result of the session.
- The tmux outer runner must forward the exact argument to the inner runner.
  Detached mode inherits it into the forked session process.
- Do not add `--on-fail`, hook configuration files, aliases, or implicit
  notification commands.

### Trigger and ordering

The registered session process is the sole notification owner. `wait`, `watch`,
the invoking orchestrator, and the wrapped agent never own hook execution.

The first of these terminal conditions wins:

| Signal | `HARNEX_OUTCOME` | `HARNEX_WORK_STATE` |
| --- | --- | --- | --- |
| accepted `task_complete` | `completed` | `completed` |
| proof-gate rejection (`completed_no_activity`, `report_missing`, `report_invalid`, `report_rejected`) | `rejected` | `failed` |
| observed unsuccessful completion — `task_complete` emitted but the receipt/outcome is `rejected` (the `pi-b-862s2` incident: `report_status: accepted`, `outcome.class: completed_with_proof`, `outcome.status: rejected`, `source: harnex_observed_state`) | `rejected` | `failed` |
| other typed `task_failed` | `failed` | `failed` |
| registered-session `dispatch_error`, or finalization without any earlier typed work result | `error` | `failed` |

For the winning transition:

1. settle the in-memory work outcome;
2. persist/update the harness-owned receipt where possible;
3. atomically write the default marker;
4. launch the optional hook once;
5. continue the existing session lifecycle unchanged.

The marker and hook must happen at work completion, not wait for process exit or
`dispatch_end`. Finalization is only a fallback for sessions that exit without
an earlier work-terminal signal.

A mutex/one-shot guard must cover competing callbacks and finalization. Repeated
turn notifications, disconnect callbacks, stop cleanup, and repeated
finalization cannot write a second outcome or launch a second hook. The first
terminal result remains authoritative for this per-session option.

Pre-validation and pre-registration failures do not yet have a registered
session owner and are out of scope. A runtime `dispatch_error` raised while
sending the initial structured turn is in scope.

### Default marker

Every registered session writes a marker, whether or not `--on-done` is set:

```text
<HARNEX_STATE_DIR>/done/<repo-key>--<normalized-id>.<outcome>
```

Use the existing `Harnex.repo_key` / session slug rules and the four outcome
suffixes `completed`, `rejected`, `failed`, and `error`.

The marker is atomically replaced JSON with this bounded v1 payload:

```json
{
  "schema_version": 1,
  "id": "pi-i-71",
  "session_id": "...",
  "repo_root": "/repo",
  "outcome": "rejected",
  "work_state": "failed",
  "outcome_class": "report_rejected",
  "artifact_report_status": "rejected",
  "receipt_path": "...json",
  "end_sha": "...",
  "elapsed_s": 12,
  "terminal_signal": "task_failed",
  "notified_at": "2026-09-03T00:00:00Z"
}
```

Rules:

- Null is allowed for unavailable `outcome_class`, report status, or SHA; all
  other keys are present.
- The receipt is written first in normal paths, so `receipt_path` is immediately
  inspectable when the marker appears.
- At successful registration, remove only prior known outcome markers for the
  same repo/id. A reused ID cannot expose stale completion while new work is
  running.
- Never store prompt text, command output, hook command text, credentials, or
  provider payloads in the marker.
- Marker-write failure is loud in stderr/events but does not rewrite accepted
  work as failed and does not suppress the optional hook.
- No marker retention policy or marker-listing command in this plan. One path
  per repo/id/outcome bounds repeated reuse; broader state retention is a
  separate concern.

### Hook environment and execution

The hook inherits the runner environment plus these explicit string values:

- `HARNEX_ID`
- `HARNEX_OUTCOME` (`completed|rejected|failed|error`)
- `HARNEX_WORK_STATE` (`completed|failed`)
- `HARNEX_RECEIPT_PATH`
- `HARNEX_END_SHA` (empty when unavailable)
- `HARNEX_ELAPSED_S` (non-negative integer seconds)

Execution rules:

- Spawn once with stdin from `/dev/null`; route hook stdout/stderr to the
  session's stderr destination so it cannot corrupt structured runner stdout.
- Detach/reap without waiting. A slow or hung hook cannot stall JSON-RPC event
  handling, auto-stop, finalization, or process exit.
- Spawn failure emits one bounded warning and diagnostic event, but does not
  alter the worker's acceptance status and is not retried.
- Emit a bounded notification event containing outcome, marker path, and
  whether hook launch succeeded. Never record `CMD` itself.
- Documentation must label `CMD` as trusted local shell input and warn against
  embedding secrets in the command line.

### Rejected-work visibility

No dispatch schema fork is allowed.

- A rejected v2 end row keeps top-level `status: completed` and
  `terminal_event: task_complete` — the session did complete; the rejection
  lives in the nested `outcome.status: rejected` block that already exists.
  The incident row (`pi-b-862s2`) confirms this shape: `status: completed`,
  `terminal_event: task_complete`, `outcome.status: rejected`,
  `outcome.class: completed_with_proof`, `outcome.report_status: accepted`,
  `outcome.source: harnex_observed_state`. Do **not** rewrite the top-level
  `status` to `failed` — that would conflate session completion with work
  outcome and fork the schema. Loudness comes from the status table, the
  default marker, and the hook, not from the end-row `status`.
- `harnex wait/watch --until done` keeps exit code `2` and its current JSON
  fields for rejected proof.
- For a live session whose adapter input state is `prompt`, the status table
  must render `rejected` when its work outcome is a proof rejection and
  `failed` for another typed task failure. Failure state outranks input state.
- `status --json` remains additive-compatible and continues exposing the
  existing fields; do not invent a second status schema.

## Phase 1 — Independent plan review

A fresh reviewer reads Issue #71, this plan, and the named implementation seams
only. It must check:

- the first-terminal-wins rule across accepted, rejected, failed, error, and
  finalization paths;
- receipt-before-marker-before-hook ordering without recursive receipt failure;
- exact option propagation through tmux and detached paths;
- no hook command leakage into durable telemetry;
- no dependency on `wait`, `watch`, prompt scraping, or Issue #69;
- whether the diff budget below remains credible.

Only P1/P2 corrections amend the plan before RED tests. No production code in
this phase.

## Phase 2 — RED tests first

Add focused failing tests before implementation.

### Notifier unit contract

Create `test/harnex/runtime/completion_notifier_test.rb` (or an equivalently
narrow name) covering:

1. accepted, rejected, failed, and error suffix/payload mapping;
2. atomic marker creation and removal of all stale same-id outcome variants;
3. two sequential and two concurrent notification attempts produce one marker
   outcome and one hook launch;
4. hook receives every required environment variable, runs from `repo_root`,
   and can write a sentinel file;
5. hook spawn failure and marker-write failure are reported but never mutate the
   supplied work outcome;
6. marker/event payloads do not contain a distinctive secret placed in the hook
   command.

Use injected spawn, clock, and filesystem seams for deterministic unit tests;
do not sleep except in the process-level smoke.

### Session and CLI contract

Extend focused existing tests to prove:

- `--on-done` parsing/help, equals form, child-argument boundary, and tmux
  passthrough;
- accepted `task_complete`, rejected proof, ordinary `task_failed`, runtime
  `dispatch_error`, and no-signal finalization each invoke the notifier with the
  right typed snapshot;
- receipt persistence precedes notification on normal terminal paths;
- repeated notifications/finalization remain exactly once;
- a live prompt with rejected work renders `rejected` in the status table;
- rejected final telemetry retains the existing v2 shape and `watch` exit-code
  contract.

### No-watcher process smoke

Using a fixture structured adapter, launch a detached worker without
`--auto-stop` and without any `wait`/`watch` client. The fixture emits an
accepted completion and stays alive. Poll only for the default marker and hook
sentinel, assert both appear while the worker PID is still alive, then clean up
the fixture session. Repeat the outcome assertion for a rejected fixture if it
can share the same helper without materially expanding the test.

This smoke proves the incident-specific capability; a test that waits for
process exit is insufficient.

## Phase 3 — Marker/notifier and session integration

Expected implementation shape:

- add canonical completion-marker path helpers near existing state-path helpers
  in `lib/harnex/core.rb`;
- add one small runtime object (recommended:
  `lib/harnex/runtime/completion_notifier.rb`) owning stale-marker cleanup,
  one-shot synchronization, atomic marker write, environment construction, and
  detached shell launch;
- require it in `lib/harnex.rb` and construct it from `Harnex::Session`;
- clear stale markers only once the new session has successfully reached its
  registration boundary;
- call one session method after accepted or failed work state has settled and
  its observed receipt has been attempted;
- call the same method from finalization only when no earlier terminal signal
  won.

Do not put hook execution in `TerminalWatcher`, `Waiter`, adapters, or the API
server. Adapters report facts; the session owns lifecycle side effects.

If normal failure paths do not currently persist an interim observed receipt,
add the narrow receipt-before-notification call there. Guard the existing
receipt-write-error path against recursion; notification must still occur with
an error/rejected outcome when receipt generation itself fails.

## Phase 4 — CLI propagation, status, and docs

- Extend `Runner::KNOWN_FLAGS`, `VALUE_FLAGS`, defaults, help, parser/equal
  forms, wrapper-token detection, tmux forwarding, and `build_session`.
- Preserve the command as one argument through `Shellwords.shellescape`; never
  interpolate outcome values into the command string.
- Make `Status#table_state` prefer rejected/failed work over prompt/busy input
  state while leaving JSON keys stable.
- Add a regression assertion around `DispatchHistory.build_record` rather than
  adding a new end-row field.
- Update `guides/01_dispatch.md` and `guides/04_monitoring.md` with the safe
  unattended pattern: runner-owned marker/hook plus bounded watcher calls.
- Update `CHANGELOG.md` when implementation lands, not during plan creation.

Recommended operator pattern after implementation:

```bash
harnex run pi --id pi-i-NN --tmux pi-i-NN \
  --context "Read and execute the task brief" --auto-stop \
  --on-done 'agent-speak "worker $HARNEX_ID $HARNEX_OUTCOME"'

harnex watch --id pi-i-NN --until done --max-wait 30m
```

`agent-speak` pages a *human*, who may be asleep (the incident). To wake the
*orchestrator* with no human in the loop, point the hook at a file the
orchestrator's runtime watches — e.g. a Pi `file-trigger` extension that calls
`sendUserMessage()` on change:

```bash
--on-done 'printf "%s %s\n" "$HARNEX_ID" "$HARNEX_OUTCOME" >> .harnex/trigger.txt'
```

The hook is an independent push path; it does not replace bounded verification
of the receipt, expected artifact, tests, or Git state.

## Phase 5 — Verification, review, and release gate

Run focused tests first, then the full suite:

```bash
ruby -Ilib -Itest test/harnex/runtime/completion_notifier_test.rb
ruby -Ilib -Itest test/harnex/runtime/session_jsonrpc_test.rb
ruby -Ilib -Itest test/harnex/commands/run_test.rb
ruby -Ilib -Itest test/harnex/commands/status_test.rb
ruby -Ilib -Itest test/harnex/commands/watch_test.rb
ruby -Ilib -Itest test/dispatch_row_schema_test.rb
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'
git diff --check
```

Then run the no-watcher fixture smoke from Phase 2 against the CLI entry point.
A fresh code reviewer checks exactly-once behavior, descriptor/process handling,
receipt ordering, secret non-persistence, marker staleness, status precedence,
and scope containment. P1/P2 findings require a fix and rereview.

Publishing is a separate owner gate. If authorized, follow the repository
release checklist in `AGENTS.md`, install the released gem locally, and perform
one real Pi `--auto-stop --on-done` smoke. Record full verification and explicit
non-coverage in `koder/releases/<version>.md`.

## Diff budget

Expected touched surface:

- production: `lib/harnex.rb`, `lib/harnex/core.rb`,
  `lib/harnex/runtime/completion_notifier.rb`,
  `lib/harnex/runtime/session.rb`, `lib/harnex/commands/run.rb`, and
  `lib/harnex/commands/status.rb`;
- tests: one notifier unit file plus focused additions to session, run, status,
  watch, and row-schema tests;
- docs: two bundled guides, then changelog/issue/plan state at completion.

Budget:

- no more than 8 production files;
- roughly 250 production lines and 400 test/doc lines;
- total implementation diff target <=700 lines, excluding generated runtime
  telemetry.

Split before implementation continues if the hook requires a daemon, persistent
queue, callback framework, or changes to `wait`/`watch` polling.

## Acceptance criteria

- [ ] Every registered session clears stale same-id markers at registration and
      atomically writes one typed marker at its first work-terminal result.
- [ ] The marker appears before process exit and without an attached
      `wait`/`watch` client.
- [ ] `--on-done` works in foreground, detached, and tmux modes and launches at
      most once.
- [ ] The hook receives all six documented environment values and runs from the
      resolved repository root.
- [ ] Hook latency/failure cannot block or reclassify the worker result.
- [ ] Accepted, rejected, failed, and error outcomes are distinguished without
      parsing prose or adding a competing dispatch schema.
- [ ] Receipt persistence is attempted before marker/hook publication; normal
      successful paths expose an immediately readable receipt.
- [ ] A live rejected worker is visibly `rejected` in the status table even if
      its adapter reports `prompt`.
- [ ] Rejected `dispatch_end` and `wait/watch` behavior retain their canonical
      nested outcome and exit-code contracts.
- [ ] No durable marker/event/dispatch row contains the hook command or test
      secret.
- [ ] Focused tests, full suite, process smoke, and `git diff --check` pass.

## Deferred / non-goals

- `wait`/`watch --heartbeat` and streaming refactor.
- Hard monotonic `--max-wait` enforcement under slow probes.
- `--exit-on-prompt` or any prompt-as-proof behavior.
- `--on-fail`, retries, backoff, hook timeout/kill, exit-status collection, or
  guaranteed external delivery.
- Webhooks, notification providers, a scheduler, or a daemon.
- One hook per turn in reusable sessions; this contract is once per Harnex
  session.
- Marker listing, acknowledgement, pruning, or cross-host synchronization.
- Pre-registration launch/validation errors.
- Issue #69 idle-stop receipt preservation, Issue #70 Pi command observation,
  and conveyor/preflight work.

## Stop rules

- Stop if notification cannot be placed after receipt generation and before
  hook launch without recursion or changing existing completion acceptance.
- Stop if exactly-once behavior would require cross-process locking or durable
  job execution; narrow the guarantee to the registered session process and
  return for design review.
- Stop if tmux propagation would persist or log raw hook contents beyond the
  unavoidable process command line; do not add telemetry fields containing
  `CMD`.
- Stop rather than absorb #69 if cleanup rewrites accepted proof after this
  plan has already emitted its correct pre-stop marker.
- Stop and split if the diff exceeds the budget or touches heartbeat/deadline
  polling.

## Definition of done

Plan 35 is implemented when the no-watcher process smoke proves a live worker
can publish a typed marker and launch one hook, all focused/full tests and
independent review pass, and bundled monitoring guidance uses the new push path.
Issue #71 remains open for the deferred heartbeat and hard-deadline plans; this
slice alone must not close it.
