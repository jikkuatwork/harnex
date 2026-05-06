---
status: open
priority: P2
created: 2026-05-07
tags: appserver,jsonrpc,cli,ux,flags,boot_failure
---

# Issue 34: harnex silently forwards `-m MODEL` to `codex app-server`, which rejects it and boot-disconnects with no message

## Summary

When dispatching a JSON-RPC codex worker with an explicit model
override via the regular-codex flag form (`-m MODEL`), harnex passes
the flag through unchanged to `codex app-server`, which does not
implement `-m`/`--model`. The subprocess exits immediately, harnex
records `disconnected source=transport message=null`, and the user
sees only `harnex: detached session <id> did not register within
N.0s`. Nothing in the error path indicates the model flag is the
cause.

## Reproduction (2026-05-07)

```bash
harnex run codex --id w1 --tmux w1 --detach \
  --context "echo OK" \
  -- -m gpt-5.5 -c model_reasoning_effort=xhigh
# → harnex: detached session w1 did not register within 5.0s
cat ~/.local/state/harnex/events/<repo>--w1.jsonl
# → {"type":"disconnected","source":"transport","message":null}
```

The same dispatch with the **app-server-correct** flag form boots
cleanly:

```bash
harnex run codex --id w1 --tmux w1 --detach \
  --context "echo OK" \
  -- -c model=gpt-5.5 -c model_reasoning_effort=xhigh
# → boots normally
```

The asymmetry surfaced while debugging issue #15 dispatch. Initial
diagnosis blamed the model name; the actual cause was that
`codex app-server --help` only exposes `-c, --config`, `--enable`,
`--disable`, `--listen`, `--analytics-default-enabled` — no `-m`. The
regular `codex` CLI does have `-m, --model`, which is why the flag
looks correct in the user's muscle memory and in the holm preset
catalog (e.g. `-m gpt-5.5 -c model_reasoning_effort=high`). Those
presets target the legacy PTY adapter; on JSON-RPC they break.

## Why this matters

- **Indistinguishable from real boot bugs.** The same symptom
  signature (`disconnected source=transport message=null` at seq:1)
  is produced by genuine schema mismatches like the original #29.
  Operators waste time chasing harnex bugs that aren't there.
- **The holm preset catalog uses `-m`.** Any orchestrator that
  copy-pastes `coding_optimized` /  `frontier_heavy` flag strings
  from holm into a JSON-RPC dispatch will hit this. The presets are
  not labeled with which adapter they target.
- **Migration tax from legacy-pty → JSON-RPC.** Users converting
  existing scripts will hit this as a silent regression.

## What "fixed" looks like

Pick one of these (in increasing order of effort/value):

1. **Reject early with a clear error.** Before spawning, when the
   adapter is JSON-RPC, scan `extra_args` for `-m`, `--model`, or
   `--model=…`. If present, fail the run with:
   ```
   harnex: -m/--model is not supported by `codex app-server`.
   Use `-c model="<name>"` instead.
   ```
   Same treatment for any other regular-codex-only flags discovered
   over time.
2. **Translate transparently.** Auto-rewrite `-m X` → `-c model="X"`
   in `CodexAppServer#build_command`. Same for any other regular-codex
   flags that have a 1:1 `-c` equivalent (none today, but design for
   it). Pro: holm presets keep working unchanged. Con: silent
   adapter-specific behavior.
3. **Document in `harnex help run` + `agents-guide dispatch`.** A
   "JSON-RPC vs legacy-pty flag forms" note. Necessary regardless;
   not sufficient on its own.

Recommended: do (1) + (3). Translation in (2) hides the seam in a way
that bites later when codex CLI evolves.

## Related

- #29 (closed) — produced the same `disconnected source=transport
  message=null` symptom; classification work in #32 doesn't
  distinguish "harnex sent a bad flag" from "harnex sent a bad
  payload".
- #32 — `boot_failure` classification (Commit 1 shipped in 0.6.4) and
  the planned `last_error` capture (Commit 3, TODO) would partially
  mitigate the diagnostic-opacity half of this issue. If `last_error`
  surfaced the codex stderr line ("error: unexpected argument '-m'
  found"), this would be ~immediately self-diagnosing without
  requiring (1).
- #30 — test stubs mirror harnex's wrong assumptions; this issue is
  a related class of "the failure mode that isn't covered by tests."

## Acceptance test

```bash
# Negative path — should fail fast with a clear error before spawn.
harnex run codex --id bad --context "x" -- -m gpt-5.5 2>&1 \
  | grep -q "model.*not supported\|Use \`-c model"
# (returns 0)

# Positive path — `-c model=…` still works on JSON-RPC.
harnex run codex --id good --tmux good --detach \
  --context "echo OK" -- -c model=gpt-5.5 -c model_reasoning_effort=xhigh
harnex wait --id good --until task_complete --timeout 60
```

## Out of scope

- Bringing native `-m`/`--model` to `codex app-server` upstream
  (Codex's call, not harnex's).
- Auto-detecting and translating `--enable`/`--disable` differences
  between the two CLIs (none known today).
