# #38 — `harnex run` rejects unknown long flags

**Status:** Tier 2 landed
**Priority:** P3
**Filed:** 2026-05-08

## Why

`harnex run` used to silently forward unknown long flags that appeared
before the `--` separator. Holm hit this as the F24 atlas item:
`--until task_complete` belongs to `harnex wait`, but
`harnex run codex --until task_complete --context "..."` treated it as
agent argv without warning. That footgun correlated with the F23
`--auto-stop` teardown leak fixed in `koder/issues/37`; the causal link
is inconclusive, but the trigger was real and cheap to close.

Atlas leverage: 1.5. Lower priority than #37 because this is the
structural trigger fix, not the teardown symptom.

## Repro

Before the fix:

```text
harnex run codex --until task_complete -- echo hi
  -> --until task_complete forwarded to codex

harnex run codex --foo-bar
  -> --foo-bar forwarded to codex
```

Required behavior after the fix:

```text
harnex run codex --until task_complete -- echo hi
  -> exits non-zero and names --until as an unknown harnex run flag

harnex run codex --auto-stop -- echo hi
  -> --auto-stop remains a known harnex run flag

harnex run codex -- --until task_complete echo hi
  -> --until task_complete stays in agent argv

harnex run codex --foo-bar
  -> exits non-zero and names --foo-bar as an unknown harnex run flag
```

## Fix

Landed 2026-05-08:

- `lib/harnex/commands/run.rb` now rejects unknown `--long` tokens in
  `extract_wrapper_options` before harnex resolves the repo, opens a
  socket, starts tmux, or spawns an agent process.
- The error points at `harnex run --help` and names the offending flag.
- Tokens after an explicit `--` separator are still forwarded to the
  agent CLI untouched.
- Regression tests in `test/harnex/commands/run_test.rb` cover the
  four repro cases plus the `bin/harnex` stderr surface.

## Done when

- Unknown long flags before `--` fail before spawn.
- Known `harnex run` flags continue to parse.
- Agent argv after `--` is not parsed by harnex.
- The focused regression tests and full suite pass.

## Out of scope

- Adding a permissive mode or `--passthrough` toggle.
- Changing `harnex wait`, `harnex history`, `harnex doctor`, or other
  subcommand parsers.
- Changing F23 teardown behavior in `koder/issues/37`.
- Cutting a release or bumping the gem version.
