# Harnex State

Updated: 2026-08-14 | 11:54 AM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in linked
issue/plan files.

## Past

- 2026-08-14 | 11:54 AM | IST: **Pi 0.84 RPC drift hardened** (`a29127f`,
  unreleased). Pi >= 0.80.4 now completes only at `agent_settled`; 0.84
  delta-only message updates no longer duplicate output; terminal stop reasons
  fail closed; startup model/thinking policy is verified without mutating Pi
  defaults; RPC waits, stderr, and child status are bounded. Issue #44 is
  corrected closed and `docs/pi-rpc.md` is canonical.
- 2026-08-08 | 06:52 PM | IST: **`harnex 0.10.2` shipped** (`ef25148`,
  `v0.10.2`), a docs-only correction for harness-owned dispatch telemetry and
  monitoring fences. Verification: `koder/releases/0.10.2.md`.
- `0.10.1` closed Issue #67 / Plan 34 with canonical telemetry assertion and
  dry-run-first reconciliation; `0.10.0` shipped #64/#65/#66.

## Present

- Pi hardening is committed but not released. Installed Pi `0.84.1` passed
  `harnex doctor --adapter pi`, the opt-in live RPC contract test, successful
  end-to-end auto-stop/model-policy smokes, and an invalid-model fail-closed
  smoke; the successful override left Pi settings unchanged.
- Relevant tests pass. The full suite passes with the unrelated Codex schema
  gate skipped: 689 runs, 2967 assertions, 0 failures, 4 skips.
- Release blocker: unskipped `SchemaFreshnessTest` detects Codex `0.147.0`
  drift in five shipped fixtures. That drift predates/is separate from this Pi
  change and needs its own adapter review before any release claim.
- #58 remains explicitly unsupported. The known cross-process registry
  lost-update race remains: writes are atomic, but stale fields are possible.

## Future

1. Review the Codex `0.147.0` schema drift, refresh only validated fixtures and
   adapter behavior, then release the Pi compatibility work (likely a minor
   version because Pi < 0.80.4 is now rejected) with a release record.
2. Implement #56 adapter preflight, then converge #57/#59 into the deterministic
   conveyor runner required by Holm Plan 708.S04.
3. #45 Pi PTY stable markers, then #42 / Plan 30 recovery/fallback phases; #41
   API docs and #58 Claude usage remain later work.
