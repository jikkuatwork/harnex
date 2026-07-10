---
status: open
priority: P2
issue_kind: slice
created: 2026-07-10
updated: 2026-07-10
tags: cli,run,cwd,dispatch,isolation,eval
---

# Issue 53 — Add explicit `harnex run --cwd/--root` dispatch directory support

## Problem

Some evaluation and benchmark workflows need to launch an agent in a temporary
public bundle directory rather than in the orchestrator's current repository.
The current workaround is to shell-wrap the command:

```bash
cd /tmp/leximaze_eval_run_001 && harnex run codex ...
```

This works, but it is awkward for automation and produces noisy git-root probes
when the temp directory is not a git repository:

```text
fatal: not a git repository (or any of the parent directories): .git
```

Agent-specific child flags can also help for some CLIs, for example Codex can be
passed `--cd` after `--`, but that is not a harnex-level abstraction and does not
cleanly update harnex's own session root, history association, default summary
path, or no-git behavior across adapters.

## Concrete motivating workflow

Lexi Maze wants to run public-bundle evals where the solver sees only:

```text
/tmp/leximaze_eval_run_001/
  README.md
  OBSERVATIONS.jsonl
```

and writes:

```text
RESPONSES.jsonl
OUTPUT.md
```

The private instance and scorer stay outside the worker cwd. This provides a
lightweight anti-cheat boundary for internal pilots without requiring a full
container.

A smoke dispatch launched from the temp bundle succeeded, but required an outer
`cd` and emitted non-git noise. A first-class flag would make this easy to script
from the orchestrating repo.

## Goal

Add a wrapper-level working-directory/root option for `harnex run`, independent
of the child CLI's own cwd flags.

Possible surface:

```bash
harnex run codex \
  --cwd /tmp/leximaze_eval_run_001 \
  --id lm-run-001 \
  --tmux lm-run-001 \
  --context "Read README.md and write RESPONSES.jsonl"
```

Open naming question: `--cwd`, `--workdir`, `--repo-root`, and `--root` carry
slightly different semantics. A practical split may be:

- `--cwd DIR`: chdir before launching/wrapping the child process and resolving
  relative paths meant for the worker.
- `--root DIR`: override harnex session/root attribution for registry/history
  and default summary path.

A single `--cwd` that also becomes session root may be enough for v1.

## Acceptance criteria

- [ ] `harnex run` accepts an explicit directory flag before the child CLI name
      or among wrapper options.
- [ ] The wrapped agent process starts with that directory as its cwd.
- [ ] Harnex session metadata/root/history/summary-out defaults are associated
      with the chosen directory, not the invoker's original cwd.
- [ ] Non-git directories are supported without printing raw `git` fatal errors.
- [ ] Relative `--context` file references in worker prompts can be written from
      the assumption that cwd is the selected bundle directory.
- [ ] Existing child-argument passthrough still works; for Codex, `-- --cd ...`
      remains valid and independent.
- [ ] Tests cover git cwd, non-git cwd, missing cwd, relative cwd, and interaction
      with explicit `--summary-out`.
- [ ] Docs and `harnex run --help` show a public-bundle/temporary-workdir example.

## Out of scope

- Security sandboxing. `--cwd` is not a filesystem isolation boundary; it only
  makes the intended worker root explicit and automation-friendly.
- Containers/chroot/network policy.
- Changing adapter-specific repo inference beyond ensuring the wrapper-level cwd
  is authoritative when supplied.

## Triage

- **Tier**: S/M
- **Estimated sessions**: 1
- **Risk**: medium because root/summary/history path behavior is subtle.
- **Motivation**: benchmark/eval dispatches, public bundle workflows, and cleaner
  no-git temp-directory support.
