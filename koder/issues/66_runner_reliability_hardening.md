---
status: resolved
priority: P1
issue_kind: slice
created: 2026-08-03
updated: 2026-08-03
resolved: 2026-08-03
tags: reliability, concurrency, registry, pty, test-isolation
---

# Issue 66 — Runner reliability: concurrent registry writes, corrupt registry entries, PTY drain

## Problem

A single `Errno::ENOENT` in `write_registry` surfaced during #65 verification
and was initially written off as a test flake. It was not. Tracing it found
three independent production defects, each of which degrades or wedges a live
dispatch, plus the test-isolation gap that let the symptom look random.

The through-line: **bookkeeping failures were allowed to take down real work.**

## Defects found

### 1. Concurrent registry writes corrupt each other (data race)

`Harnex.write_registry` derived its temp path from the pid alone:

```ruby
tmp = "#{path}.tmp.#{Process.pid}"
```

Several threads in one session write the *same* registry path — the startup
persist (main thread, unsynchronised, and running after `@server.start` has
already begun accepting), the inbox delivery thread, and one thread per API
client (`ApiServer` spawns `Thread.new(socket)` per connection). With a shared
temp name, one thread renames the file another is still writing; the loser's
`rename` finds nothing and raises.

Reproduction (8 threads × 300 writes, before the fix):

```
concurrent write_registry errors: 2080
  2080x Errno::ENOENT: No such file or directory
```

It also had no `mkdir_p`, so a reaped state directory (tmpfs, operator
cleanup, `doctor` sweep) turned every subsequent write into a hard failure.

### 2. A failed registry write failed an *already delivered* send

`persist_registry` ran on the injection path at
`session.rb` `inject_via_structured` and `finish_injection` — in both cases
**after** the prompt had reached the agent (`adapter.dispatch` returned; PTY
bytes written). An exception there propagated out of the send, so a turn the
agent was already working on was reported as failed. An orchestrator retrying
on that signal duplicates work in the same checkout.

Combined with defect 1, two concurrent `harnex send` calls were enough.

### 3. One corrupt registry file crashed every session scan

`alive_pid?` called `Integer(pid)` and rescued only `Errno::ESRCH` /
`Errno::EPERM`. A non-numeric pid — truncated write, hand edit, foreign
writer — raised `ArgumentError` out of `active_sessions`, taking down
`harnex status`, `harnex send`, and `harnex pane`. The surrounding code
already self-heals unparseable JSON by pruning the file; this case simply
escaped the net. Confirmed present on `main` at `e887771`.

### 4. A closed stdout wedged the wrapped agent (silent hang)

`start_output_thread` rescued `EOFError, Errno::EIO, IOError`. `Errno::EPIPE`
and `Errno::EBADF` are **not** `IOError` subclasses, so a consumer going away
(`harnex run codex | head`, a detached terminal) killed the reader thread. The
PTY then stopped being drained, the kernel buffer filled, and the wrapped agent
blocked forever on write — presenting as *the agent* hanging, with no harness
error anywhere.

### 5. Test isolation let all of this look like noise

The suite runs in one process; several suites deliberately wipe shared state
directories (doctor sweep wipes `SESSIONS_DIR`, retention wipes
`events`/`output`/`receipts`). Tests leaked live threads and unreaped child
processes past their own bodies, so a leaked `Harnex::Session` could be
persisting a registry when an unrelated later test wiped the directory —
failing at a random seed, in a random file. `retention_test` also planted a
malformed registry in the shared `SESSIONS_DIR` and never removed it.

`Thread#kill` and `Process.kill` are both asynchronous, and
`Process.waitpid(pid, WNOHANG)` does not wait at all — the existing cleanup
code looked correct but did not actually guarantee death.

## Resolution

**Production**

- `Harnex.atomic_write_json` is the single atomic JSON-state writer:
  `mkdir_p` + per-write unique temp (`pid` + `SecureRandom.hex(6)`) + rename,
  with temp cleanup on failure. `write_registry` delegates to it, and
  `Retention` metadata (which had the identical pid-only temp name) now routes
  through it instead of hand-rolling its own.
- `Session#refresh_registry` wraps post-injection persistence and warns instead
  of raising. Startup persistence stays strict on purpose: a session nothing
  can discover should fail loudly rather than run unreachable and unstoppable.
- `alive_pid?` treats a non-numeric pid as dead, so `active_sessions` prunes
  the entry — the same self-healing already applied to unparseable JSON.
- `start_output_thread` always drains the PTY; stdout echo is best-effort and
  degrades with one warning. Both reader loops now report an unexpected exit
  instead of vanishing.

**Tests**

- `HarnexTestIsolation` (in `test_helper.rb`) snapshots `Thread.list` per test
  and reaps anything left alive at `after_teardown`, so no test can leak live
  concurrency into the next one. Adds `reap_thread` (join → kill → confirm) and
  `reap_process` (signal → bounded blocking waitpid) helpers, applied at the
  session-runner threads and every `kill`-without-real-reap site.
- `test_isolation_test.rb` covers the net itself — that a leaked thread is
  reaped, that pre-existing threads are *not*, and that both helpers actually
  confirm death. Without it the net could silently stop working and the suite
  would drift back to seed-dependent failures.
- `retention_test` removes the malformed registry it plants in the shared dir.

The suite executes serially (no `parallelize_me!`), so reaping non-main threads
at the boundary cannot disturb sibling tests.

## Verification

Every fix is mutation-tested — reverted one at a time, with the new test
confirmed to fail:

| Fix | Mutation | Result |
| --- | --- | --- |
| Unique temp name | restore `tmp.#{pid}` | 1 failure |
| `mkdir_p` | remove it | 1 failure + 1 error |
| `alive_pid?` guard | restore raising | 2 errors |
| Non-fatal refresh | restore `persist_registry` | 1 error |
| PTY drain | restore old loop | 1 error |
| Isolation net | disable the reaper | 1 failure |

Unit reproduction of the registry race: 2400 concurrent writes, 2080 errors
before, **0 after**.

Live runner stress (temp `HARNEX_STATE_DIR`): 20 cycles of detached start →
3 concurrent forced sends → stop. 0 run failures, **0/60 send failures**,
0 delivery failures, 0 stop failures, 0 orphan temp files, all messages
confirmed echoed by the wrapped agent.

Suite: **0 failing runs out of 40** consecutive randomized-order runs, each on
a different seed (2 environment-gated skips throughout). Production code was
frozen before run 1; the isolation-net tests landed at run 9, so runs 1–8 cover
653 tests / 2829 assertions and runs 9–40 cover 658 / 2836. Every run clean.

**What the evidence does and does not show.** The unit reproduction proves the
temp-name race is real and severe in `write_registry` itself. Reachability in a
live session comes from reading the call graph: the startup persist is
unsynchronised and runs after `@server.start` is already accepting, and
`inject_via_structured`/`finish_injection` hold *different* mutexes
(`@inject_mutex` vs `@mutex`). The live stress run is a regression check on the
fixed runner — it is not evidence that the old code failed there, since most
PTY injections serialise on `@mutex` and the window is narrow.

## Not covered

- The lost-update race between a live session persisting its own registry and
  the parent `harnex run` process running `annotate_tmux_registry` on the same
  file. Cross-process, read-modify-write; each write is atomic and the merge is
  intentional, so this is a stale-field risk, not corruption. Not addressed.
- `Harnex.strip_ansi` does not `scrub` invalid bytes the way
  `Adapters::Base#normalized_screen_text` does. Its callers are inside
  already-rescued teardown telemetry, so it degrades rather than crashing.
  Left alone; worth tightening if it ever moves onto a hot path.
- Stub-server threads in the app-server test files are still fire-and-forget;
  they only read pipes, and the isolation net now reaps them. Not individually
  rewritten.
