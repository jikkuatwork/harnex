# Plan 27 review

## Verdict
PASS

## P1 findings
None. All P1 acceptance criteria are met:

1. **Schema additive-only.** `docs/events.md` §8 and the implementation
   add only new event types (`usage`, `git`, `summary`) and new optional
   fields (`started.meta`, `exited.reason`). No existing field is removed,
   renamed, or retyped. `test/fixtures/events_v1.jsonl` was extended with
   examples for each new type and `test_fixture_matches_v1_schema_contract`
   (test/harnex/commands/events_test.rb:126) re-asserts every legacy field
   still present.
2. **`actual.cost_usd` always `null`.** Hardcoded at
   lib/harnex/runtime/session.rb:548 (`cost_usd: nil`). No pricing table
   exists in the tree (`grep -ri "cost_usd"` returns only schema fields,
   docs, and the `nil` write site).
3. **`--meta` parse failure exits non-zero with a clear error.**
   `parse_meta` (lib/harnex/commands/run.rb:513) raises
   `OptionParser::InvalidOption` with "must be valid JSON: …" or "must
   be a JSON object". Empty/missing `--meta` leaves `@options[:meta]` as
   `nil`; `meta_hash` (session.rb:569) returns `{}` so harnex-owned fields
   are still populated. Tests
   `test_extract_wrapper_options_rejects_invalid_meta_json` and
   `test_extract_wrapper_options_rejects_meta_json_array` cover both.
4. **Best-effort summary writer.** `append_summary_record`
   (session.rb:573) wraps the write in `rescue StandardError` and emits a
   `warn(...)` matching the existing failure-log pattern. The summary
   `event` and `exited` event are still emitted afterward
   (session.rb:131–137 ordering).
   `test_summary_write_failure_warns_without_crashing_exit` exercises this
   by passing a directory path as `summary_out` and asserts exit 0.
5. **Adapter contract clean.** `Adapters::Base#parse_session_summary`
   (lib/harnex/adapters/base.rb:42) returns `{}`. Codex overrides
   (codex.rb:59). Claude/Generic untouched (`grep -l parse_session_summary
   lib/harnex/adapters/`). `normalized_usage_summary` (session.rb:585)
   coerces `{}` to a hash with all `USAGE_FIELDS` set to `nil`, so the
   `usage` event still emits with all-null fields when an adapter does not
   override.
6. **Plan §300 file-by-file table.** Diff matches the table exactly:
   `core.rb`, `adapters/base.rb`, `adapters/codex.rb`, `runtime/session.rb`,
   `commands/run.rb`, `docs/events.md`, `docs/dispatch-telemetry.md`, plus
   tests + fixture. `cli.rb` was *not* modified — the plan's "help text
   additions (mirror existing flag block)" line lists `cli.rb`, but the
   help text actually lives in `Runner.usage` and was updated there
   (run.rb:35–36). Net effect is the same; not a blocker.
   `koder/STATE.md` is the only out-of-table file in the diff and is
   incidental session bookkeeping.
7. **Tests cover every plan §"Test plan" bullet.** See coverage section
   below — every bullet maps to at least one test.

## P2 findings
- `lib/harnex/adapters/codex.rb:63` — Token regex only matches when
  `total=` is the **first** field after `Token usage:`. Codex's documented
  marker fits this, but if the producer ever swaps order (`input=` first)
  the line silently fails and `usage` carries all nulls. Suggested fix:
  consider a permissive multi-pass parser keyed on each `key=value`
  segment in a follow-up. Not blocking — sample marker matches and
  `test_parse_session_summary_extracts_token_usage_and_resume_id` pins it.
- `lib/harnex/core.rb:83` — `strip_ansi` only strips CSI (`\e[...letter`)
  sequences. Codex emits OSC (`\e]...`) and other forms. The session-end
  marker is plain text, so this is unlikely to bite, but if a future
  codex version wraps the marker in OSC the token regex would fail. The
  adapter input-state path uses a richer `normalized_screen_text`
  (base.rb:130) — the telemetry path could share that to be safe.
- `lib/harnex/runtime/session.rb:482` — `classify_exit` uses exit code
  `124` as the timeout signal. The plan §"Failure modes" mentions
  "timeout (force-stop via watcher escalation flag)". There is no flag
  passed in from the watcher today; classification is based purely on the
  numeric exit code. RunWatcher does kill via TERM/KILL, which would land
  as `failure`, not `timeout`. Practically, anything that synthesizes
  124 (e.g., `timeout(1)` wrapping) gets the right label. Worth a
  follow-up if/when the watcher wants to assert a timeout.
- `lib/harnex/runtime/session.rb:71` — `EventCounters` records `resume`,
  `log_idle`, `compaction`, `disconnect`/`disconnection`. Today no
  producer emits any of these (Layer 2 not yet shipped), so the counters
  cleanly degrade to 0 — verified by `test_event_counters_tally_reserved_operational_events`
  (in isolation). Note that `disconnections` is force-bumped to ≥1 when
  `exit_reason == "disconnected"` (session.rb:538) — a small but
  intentional asymmetry; documented behavior matches plan §"Failure
  modes" case 3.
- `lib/harnex/runtime/session.rb:495–500` — Event ordering is correct
  (`started → git start → … → usage → git end → summary → exited`),
  pinned by `test_run_emits_usage_and_git_events_before_exited`.
  Counter-intuitive nit: when git capture fails (no repo), the order
  collapses to `started → usage → summary → exited`, which matches
  `test_summary_event_has_nil_path_when_no_summary_path_resolves`.
- `lib/harnex/commands/run.rb:147` — `--summary-out` is forwarded to the
  tmux child as the already-resolved absolute path. That is what
  `resolve_summary_out` produces, so the child sees the same path the
  parent computed. Headless (`run_headless`) re-builds the session in the
  forked child and re-runs `resolve_summary_out` against the same
  `repo_root`, so the result is consistent. No bug; documenting because
  the two paths got there differently.

## P3 notes
- `lib/harnex/runtime/session.rb:9` — `USAGE_FIELDS` constant is private-
  ish to this class but defined at the top level of `Session`. Fine.
- `lib/harnex/core.rb:67` — `harness_version` is just `VERSION`. A
  one-liner method is mild ceremony but mirrors the plan's "harness_version
  constant load" wording.
- `lib/harnex/runtime/session.rb:454` — `transcript_tail` reads up to
  `TRANSCRIPT_TAIL_BYTES = 16 * 1024` and silently returns "" on any
  error. Acceptable; documented in the plan.
- `docs/dispatch-telemetry.md` is concise and accurate. Could mention
  that `--meta` keys not in the documented passthrough list are dropped
  from the consolidated record but preserved on `started.meta`.

## Test plan coverage
Each plan §"Test plan" bullet:

- ✅ **CLI flags accepted** — `test_extract_wrapper_options_parses_meta_json`,
  `test_extract_wrapper_options_rejects_invalid_meta_json`,
  `test_extract_wrapper_options_rejects_meta_json_array`,
  `test_extract_wrapper_options_parses_summary_out`,
  `test_resolve_summary_out_defaults_when_koder_dir_exists`,
  `test_resolve_summary_out_returns_nil_without_koder_dir`,
  `test_resolve_summary_out_expands_explicit_path`.
- ✅ **Session-end events emitted** —
  `test_run_emits_usage_and_git_events_before_exited` covers token
  counts, `agent_session_id`, git start+end, `summary.path`,
  `exited.reason == "success"` in a real temp git repo.
- ✅ **Consolidated record written** — same test asserts top-level
  `meta`/`predicted`/`actual` shape, `cost_usd: nil`, `tests_run: nil`.
- ✅ **Predicted passthrough with and without metadata** — same test
  (with) and `test_summary_record_uses_null_actuals_and_disconnected_exit_without_summary_marker`
  (without — predicted is `{}`).
- ✅ **Non-extractable nullability** — same null-actuals test asserts
  `usage` event nulls, consolidated nulls, `actual.exit == "disconnected"`.
- ✅ **Schema additive-only check** — `test_fixture_matches_v1_schema_contract`
  in `events_test.rb` plus the extended `events_v1.jsonl` fixture.
- ✅ **No-regression** — full suite green at 259 tests (was 235 before
  the plan; budget said 250+).
- ✅ **Existing dispatches unchanged (no koder dir)** —
  `test_summary_event_has_nil_path_when_no_summary_path_resolves`. Note
  it asserts `started → usage → summary → exited` (no `git` events when
  not in a repo) — matches plan §"Failure modes".
- ✅ **Codex adapter parser unit test** — `test_parse_session_summary_extracts_token_usage_and_resume_id`,
  `test_parse_session_summary_returns_nil_fields_for_garbage`.

Gaps: none against the explicit plan. One latent gap worth noting (not
required by plan §"Test plan"): no test exercises the
`actual.exit == "failure"` branch (non-zero exit). The classification
logic is trivial enough that this is acceptable.

## Schema additive verification
**Yes, additive.**

Evidence:
- `docs/events.md` §5 "Stability promise" preserved verbatim. §8
  explicitly states the additions keep schema_version `1`.
- Diff against `lib/harnex/runtime/session.rb` shows no removal of
  prior event payloads. `started` still emits `pid`; `meta` is added
  only when `meta` is truthy (session.rb:441–443). `exited` still emits
  `code` and optional `signal`; `reason` is added only when
  `@exit_reason` is set (session.rb:475–479) — pre-existing fixtures
  without `reason` remain valid.
- `test_events_log_records_started_and_exited_round_trip` continues to
  validate the legacy `started`/`exited` shape with no `meta`/`reason`.
- `test_fixture_matches_v1_schema_contract` re-validates the legacy
  fields (`pid`, `msg`, `msg_truncated`, `forced`, `code`) on top of
  the new types.

## Test run
```
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'
259 runs, 811 assertions, 0 failures, 0 errors, 0 skips
```
