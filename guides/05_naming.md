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
cx-m-42      Codex maps task 42
cx-p-42      Codex writes plan 42
cx-r-42      Codex reviews plan 42
cx-f-42      Codex fixes plan 42
cx-i-42      Codex implements plan 42
cx-cr-42     Codex reviews implementation 42
cx-cf-42     Codex fixes implementation 42
buddy-42     Buddy monitors task 42
```

Use names that fit your project. The important part is that the ID is stable,
short, and present in every artifact.

## Match `--id` And `--tmux`

Always pass both and keep them identical:

```bash
harnex run codex --id cx-i-42 --tmux cx-i-42
```

Avoid this:

```bash
harnex run codex --tmux cx-i-42
```

If `--id` is missing, harnex generates a random session ID. The tmux window may
look right, but `harnex status`, `harnex pane --id`, and logs need the random
ID.

## Retry Suffixes

If a session fails and you dispatch a fresh attempt, append a suffix:

```text
cx-i-42      first attempt
cx-i-42b     second attempt
cx-i-42c     third attempt
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
/tmp/cx-p-42-done.txt
/tmp/cx-i-42-done.txt
/tmp/cx-cr-42-done.txt
```

When a brief asks for a completion marker, make it one line and include the
highest-signal result: tests passed, review clean, or the blocking issue.
