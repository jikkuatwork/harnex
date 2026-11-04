---
status: open
priority: P2
created: 2026-11-05
updated: 2026-11-05
tags: tmux, ssh, remote, lanes, delegate, ask, unattended
type: bug
related: 97, 95, 85
---

# Issue 98 — Second lane over ssh fails with `duplicate session: harnex`

## What happened (helium plan 38/39, 2026-11-05)

First real run of a remote worker VM (`~/Projects/helium/koder/plans/38_remote_worker_vm.md`).
The orchestrator drives harnex 0.30.1 on the host with non-interactive ssh:

```
ssh hvm-helium 'cd ~/work/helium && harnex delegate --no-wait --worktree bake-tts --file …'   # ok
ssh hvm-helium 'cd ~/work/helium && harnex delegate --no-wait --worktree bake-stt --file …'   # fails
```

The second and every later lane die before Pi starts:

```
harnex could not start lane bake-stt: duplicate session: harnex
harnex: tmux failed to start "pi"
```

`tmux ls` on the host shows one session `harnex` with the first lane's window.
A `harnex ask` run a minute earlier had succeeded only because its window had
already closed, so the session was gone when the first `delegate` ran.

## Cause

`lib/harnex/commands/run.rb:335-343` decides how to start the worker by the
caller's environment alone:

```ruby
started =
  if ENV["TMUX"]
    system("tmux", "new-window", "-c", tmux_start_cwd, "-n", window_name, "-d", shell_cmd)
  else
    system("tmux", "new-session", "-c", tmux_start_cwd, "-d", "-s", "harnex", "-n", window_name, shell_cmd)
  end
```

Locally the owner always runs inside tmux, so `$TMUX` is set and lanes become
windows of the current session. Over `ssh HOST CMD` (and from any cron, hook or
headless agent) `$TMUX` is unset, so harnex tries `new-session -s harnex` each
time and tmux refuses once that session exists. Elsewhere harnex already knows
how to probe for the session (`commands/pane.rb:183`,
`dispatch_history.rb:359` use `tmux has-session`), but `run` does not.

## Workaround in use

helium's `scripts/hvm run|delegate` export `TMUX` on the host before calling
harnex when a `harnex` session exists:

```
TMUX="$(tmux display -p -t =harnex '#{socket_path},#{pid},#{session_id}' | tr -d '$')"
```

With only one session on the host, `new-window` then lands in it. Fragile:
it leans on tmux resolving the "current" session from a synthetic `$TMUX`.

## Wanted

- `run` reuses an existing `harnex` session whether or not the caller is inside
  tmux: if `$TMUX` is set, `new-window` in the caller's session as today;
  else if `tmux has-session -t =harnex` succeeds, `new-window -t =harnex:`;
  else `new-session -s harnex`. The exact-match `=harnex` target matters so a
  session named `harnex-foo` does not count.
- Two lanes started at the same moment without `$TMUX` must not race each
  other into the same `duplicate session` failure (serialize session creation,
  or retry the `new-window` path once on that error).
- `harnex doctor` run outside tmux reports which session lanes will join.
- A spec that starts two lanes with `ENV["TMUX"]` unset against a stub tmux.

This is a prerequisite for #97 (remote host lanes): every `--on HOST` verb runs
harnex on the host through non-interactive ssh.

## Acceptance

- [ ] On a host with no tmux server, `harnex delegate --no-wait` twice in a
      row (no `$TMUX`) yields two windows in one `harnex` session.
- [ ] The same with `harnex ask` followed by `harnex delegate`.
- [ ] Inside tmux, behaviour is unchanged (window in the caller's session).
- [ ] helium can drop the `TMUX` export from `scripts/hvm`.
