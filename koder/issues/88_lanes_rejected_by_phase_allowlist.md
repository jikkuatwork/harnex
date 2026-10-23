---
status: done
priority: P1
created: 2026-10-23
updated: 2026-10-23
tags: lanes, config, phase, agents
type: bug
related: 87
---

# Issue 88 — Lanes are refused in repos with a `reject` phase allowlist

Seen 2026-10-23 in Holm (harnex 0.29.0), first `harnex delegate --cwd <sibling worktree> --name
b2-red --no-wait --file <brief>`:

`harnex could not start lane b2-red: harnex: invalid option: harnex run: meta.phase (none) is not
allowlisted by <repo>/.harnex/config.json (allowed: plan-write, …; policy: reject)`

- `delegate`, `ask` and `reply` build a `harnex run` with no `meta.phase`, so
  `validate_repo_phase_policy!` (`commands/run.rb`) refuses every lane in a repo whose config says
  `"policy": "reject"`. `delegate` has no `--phase` flag to pass one.
- The failed launch still writes a lane record in state `failed`, so a retry with the same name
  is refused ("lane b2-red already exists (failed)") until `discard`.

Holm's workaround: config policy `warn` (commit `7ed759c14`). Suggested fix: lanes carry a phase
(for example `ask`/`delegate`, or an explicit `--phase`), the allowlist check exempts lane kinds or
accepts them, and a launch refused before spawn leaves no lane record.

## Resolution (0.29.1, 2026-10-23)

- The runs behind lanes are tagged `meta.phase` = the lane kind (`delegate`,
  `ask`). `validate_repo_phase_policy!` exempts these like `preflight`
  (`Lanes::PHASES`).
- `delegate --phase NAME` / `ask --phase NAME` tag a work phase instead. The
  allowlist checks it, and `reply` reuses it.
- A launch refused before spawn (no JSON, exit other than 124) leaves no
  record or brief (`Lanes.unlaunch`). A refused `reply` restores the lane's
  prior state. `delegate` clears 0.29.0's `failed`, zero-turn leftovers
  (`Lanes.never_started?`).
- Verification: `koder/releases/0.29.1.md`. Holm can return to `"policy":
  "reject"` on 0.29.1 and reuse `b2-red`.
