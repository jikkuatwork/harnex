---
status: resolved
priority: P1
created: 2026-11-21
updated: 2026-11-21
tags: macos, darwin, process-group, wait, ask, pi
type: bug
related: 100
---

# Issue 99 — On macOS every `ask` and `wait --timeout` fails with "Operation not permitted"

## What happened (2026-11-21)

harnex 0.30.1 was installed on a Mac (M4 Air, Ruby 3.3.0) to run Holm lanes
there for the first time; until now it had only run on Linux. The worker ran and
answered, but the caller never got the answer:

```
$ harnex ask --model foundry-zyt/gpt-6.2-astra --effort low --timeout 4m "… Reply with exactly one line: host lane ok"
harnex: Operation not permitted
harnex ask: the worker did not answer (no result)
```

The exit record said `completed_with_proof` and the turn file held `host lane ok`.
`HARNEX_TRACE=1` pointed at `Waiter#reap_observer` (`lib/harnex/commands/wait.rb:260`):
`Process.kill("KILL", -pid)` raised `Errno::EPERM`.

## Cause

Darwin and Linux disagree on `kill(-pgid, sig)` when every member of the group has
exited but is not yet reaped (zombies only):

```ruby
pid = fork { exit 0 }; Process.setpgid(pid, pid) rescue nil; sleep 0.3
Process.kill("KILL", -pid)   # Linux: succeeds;  macOS: Errno::EPERM
```

`reap_observer` runs in the `ensure` after the observer child has delivered its
result and exited, so on macOS it always met a zombie-only group. It rescued only
`ESRCH`, and the EPERM escaped through `Waiter#run`. Every `ask`, every `wait` with
`--timeout` or `--heartbeat`, and the lane verbs built on them failed.

`OwnedProcessGroup#signal` (`lib/harnex/owned_process_group.rb`), which stops a Pi
worker's process group, had the same gap: a TERM, or the `signal(0)` gone-probe,
that lands while the group holds only unreaped members raised instead of reading
the group as gone.

## Resolution

- `reap_observer` rescues `Errno::EPERM` beside `ESRCH` for the group KILL; the
  direct KILL and `waitpid` that follow still reap the observer.
- `OwnedProcessGroup#signal` treats `EPERM` as gone: no member could be signalled.
  On Darwin that is the zombie-only group; elsewhere it means members harnex has
  no right to signal, which no later signal could reach either. It still forgets
  the group ID, so a recycled ID is never signalled.
- Tests emulate Darwin with a stubbed `Process.kill`, so Linux runs them too:
  `MonitorDeadlineTest#test_reaping_a_finished_observer_tolerates_darwin_eperm`,
  `OwnedProcessGroupTest#test_zombie_only_group_eperm_is_gone_and_never_signalled_again`,
  `OwnedProcessGroupTest#test_group_that_exits_after_term_reads_gone_when_the_probe_gets_eperm`.
  All three were red before the fix (`Errno::EPERM`).
- macOS full suite: 27 failures/errors before; the 8 caused by this bug are gone.
  The other 19 are test portability, tracked in #100.
- Live: the Mac's installed 0.30.1 carried the same one-line patch, and
  `harnex ask` to `foundry-zyt/gpt-6.2-astra` then answered in 7 s.
