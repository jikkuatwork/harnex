# Plan 23: Log-mtime Activity Tracking (Layer 1 of #22)

Issue: #22 (Layer 1 from `koder/plans/22_mapping.md`)
Date: 2026-04-29
Status: ready-for-implementation

## Goal

Expose per-session output-log activity on existing `status` surfaces so later
layers can detect idle/stall reliably without adding any new commands.

## Scope Guardrails (Layer 1 only)

- Add `log_mtime` and `log_idle_s` to the session status payload.
- Surface those keys in `harnex status --json` (additive schema only).
- Add one compact text-mode signal in `harnex status` (`IDLE` column).
- No new commands, no new flags, no presets.
- No `--watch`, no events stream, no auto-resume behavior.

## Existing Surface Anchors

### Runtime payload source (`lib/harnex/runtime/session.rb`)

- `status_payload` currently emits `output_log_path` at
  `status_payload` lines 97-125 (`output_log_path` at line 112).
- `registry_payload` calls `status_payload(include_input_state: false)`, so
  additive payload fields automatically persist in registry snapshots.
- `prepare_output_log` (line ~297) opens/creates the transcript file.
- `record_output` + `append_output_log` (lines ~318-340) append emitted
  chunks and therefore advance the transcript file mtime.

### CLI surface (`lib/harnex/commands/status.rb`)

- `load_live_status` merges live `/status` JSON onto registry rows
  (lines 84-97).
- `--json` prints merged rows directly via `JSON.generate(sessions)`
  (lines 35-39).
- Table rendering currently uses columns `ID CLI PID PORT AGE STATE REPO DESC`
  (`render_table`/`table_row`, lines 100-125).

## New Field Contract

1. `log_mtime`
- Type: `String | nil`
- Format: ISO8601 timestamp from transcript mtime (`Time#iso8601`), e.g.
  `"2026-04-29T13:31:44+05:30"`.
- Null behavior: `nil` when the log file is absent or unreadable.

2. `log_idle_s`
- Type: `Integer | nil`
- Meaning: whole seconds since last transcript update (`Time.now - mtime`),
  floored and clamped to `>= 0`.
- Null behavior: `nil` when the log file is absent or unreadable.

3. Fresh-session behavior (pre-first-write)
- `output_log_path` remains populated.
- `log_mtime: nil` and `log_idle_s: nil`.
- No warning, no raised error, status response remains `ok: true`.

### Example payload (log exists)

```json
{
  "id": "cx-impl-17",
  "output_log_path": "/home/user/.local/state/harnex/output/repo--cx-impl-17.log",
  "log_mtime": "2026-04-29T13:31:44+05:30",
  "log_idle_s": 12
}
```

### Example payload (log missing)

```json
{
  "id": "cx-impl-17",
  "output_log_path": "/home/user/.local/state/harnex/output/repo--cx-impl-17.log",
  "log_mtime": null,
  "log_idle_s": null
}
```

## Text-mode Column Decision (`harnex status`)

Recommendation: add one `IDLE` column; keep `log_mtime` JSON-only.

Rationale:
- `log_idle_s` is the actionable operator signal and fits current table style.
- Raw timestamp would crowd the table and is already available in JSON.
- This preserves machine-readability and human glanceability without flags.

Formatting rules:
- `IDLE` uses compact age units like `12s`, `4m`, `2h`, `1d`.
- `IDLE` renders `-` when `log_idle_s` is `nil`.

Proposed table order:
- `ID`, `CLI`, `PID`, `PORT`, `AGE`, `IDLE`, `STATE`, `REPO`, `DESC`.

## Implementation Steps

1. Extend `lib/harnex/runtime/session.rb` status payload.
- Add a private helper (e.g. `log_activity_snapshot`) that:
  - checks log-file existence,
  - reads `File.mtime(output_log_path)`,
  - returns `log_mtime` + `log_idle_s` in a null-safe hash.
- Merge helper output into `status_payload` next to `output_log_path`.
- On stat/read failures, return nil fields (no exceptions surfaced).

2. Extend `lib/harnex/commands/status.rb` table output.
- Insert `IDLE` into `columns`.
- Populate `IDLE` in `table_row` from `session["log_idle_s"]`.
- Add a small formatter helper for idle seconds -> compact unit text.
- Leave JSON path unchanged (keys flow through existing merge + generate).

3. Add minimum tests for Layer 1.
- `test/harnex/runtime/session_test.rb`:
  - test A: `status_payload` returns nil for both fields when log file is
    absent.
  - test B: after `prepare_output_log` + `record_output`, payload returns
    ISO8601 `log_mtime` and Integer `log_idle_s`; a later `record_output`
    advances `log_mtime`.
- `test/harnex/commands/status_test.rb`:
  - test C: `--json` output includes `log_mtime` and `log_idle_s` keys with
    expected null/non-null types.
  - test D: text mode includes `IDLE` header and renders `-` when idle is nil.

4. Keep Layer 1 boundaries strict.
- Do not add `events` command or watcher logic.
- Do not add new CLI options.
- Do not introduce preset constants.

## Verification

- `ruby -Ilib -Itest test/harnex/runtime/session_test.rb`
- `ruby -Ilib -Itest test/harnex/commands/status_test.rb`
- `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

Manual sanity check:
1. Launch a session that emits output.
2. Run `harnex status --id <id> --json`.
3. Emit new output from the agent.
4. Re-run status and confirm `log_mtime` advances and `log_idle_s` resets.

## Exact Files To Touch (estimated)

- `lib/harnex/runtime/session.rb` (~18-24 LoC)
  - helper + additive payload keys.
- `lib/harnex/commands/status.rb` (~8-14 LoC)
  - `IDLE` table column + formatter.
- `test/harnex/runtime/session_test.rb` (~20-35 LoC)
  - nil/log-exists assertions plus mtime-advance assertion.
- `test/harnex/commands/status_test.rb` (~12-20 LoC)
  - JSON key/type assertions and `IDLE` table assertion.

Estimated total: ~58-93 LoC, additive only.

## Acceptance Checklist (Layer 1)

- [ ] `status_payload` includes `log_mtime` (ISO8601 or nil).
- [ ] `status_payload` includes `log_idle_s` (Integer or nil).
- [ ] Missing log file yields `log_mtime: nil` and `log_idle_s: nil` without
      errors.
- [ ] `harnex status --json` includes both keys per session.
- [ ] Transcript mtime advances on agent output and is reflected in payload.
- [ ] Text-mode `harnex status` shows `IDLE` with `-` fallback.
- [ ] No new commands/flags and no Layer 2+ behavior added.
