# Naming Conventions

Use predictable session IDs so humans, agents, tmux windows, logs, events, and
done markers all point at the same work.

## Session IDs

Format:

```text
<cli>-<phase>-<number>
```

Common prefixes:

| Prefix | Meaning |
| --- | --- |
| `pi` | Pi worker (default) |
| `cx` | Codex worker |
| `cl` | Claude worker |
| `buddy` | Buddy monitor |

Common phases:

| Code | Phase |
| --- | --- |
| `m` | Mapping or analysis |
| `p` | Plan writing |
| `r` | Plan review |
| `f` | Plan fix |
| `i` | Implementation |
| `cr` | Code review |
| `cf` | Code fix |

Examples:

```text
pi-m-42      Pi maps task 42
pi-p-42      Pi writes plan 42
pi-r-42      Pi reviews plan 42
pi-f-42      Pi fixes plan 42
pi-i-42      Pi implements plan 42
pi-cr-42     Pi reviews implementation 42
pi-cf-42     Pi fixes implementation 42
buddy-42     Buddy monitors task 42
```

Use names that fit your project. The important part is that the ID is stable,
short, and present in every artifact.

## Match `--id` And `--tmux`

Always pass both and keep them identical:

```bash
harnex run pi --id pi-i-42 --tmux pi-i-42
```

Avoid this:

```bash
harnex run pi --tmux pi-i-42
```

If `--id` is missing, harnex generates a random session ID. The tmux window may
look right, but `harnex status`, `harnex pane --id`, and logs need the random
ID.

## Retry Suffixes

If a session fails and you dispatch a fresh attempt, append a suffix:

```text
pi-i-42      first attempt
pi-i-42b     second attempt
pi-i-42c     third attempt
```

Keep the old session's logs. They are useful for diagnosis.

## Task Files

Use human-readable file names for long instructions:

```text
/tmp/task-plan-42.md
/tmp/task-impl-42.md
/tmp/task-review-42.md
/tmp/task-fix-42.md
```

The task file name does not need to duplicate the exact short phase code. It
should be easy to scan in `/tmp` and should include the same task number as the
session ID.

## Done Markers

Derive done markers from the session ID:

```text
/tmp/pi-p-42-done.txt
/tmp/pi-i-42-done.txt
/tmp/pi-cr-42-done.txt
```

When a brief asks for a completion marker, make it one line and include the
highest-signal result: tests passed, review clean, or the blocking issue.
