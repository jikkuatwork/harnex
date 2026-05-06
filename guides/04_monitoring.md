# Monitoring Patterns

Monitoring should be based on work-level signals first and UI state second.
Pane state is useful for interpretation, but it should not be the only proof
that delegated work is finished.

## Signal Ladder

Prefer signals in this order:

| Signal | Use |
| --- | --- |
| Expected artifact | Primary proof that a task produced its deliverable |
| Tests and git state | Confirms work landed and the tree is not mid-edit |
| `harnex events` | Structured runtime events, including task completion |
| `harnex logs` | Transcript history and last output |
| `harnex pane` | Live UI interpretation and prompt/error diagnosis |
| `harnex status` | Session liveness and coarse state |

For Codex app-server sessions, `harnex wait --until task_complete` is a strong
turn-level fence. It still does not know your acceptance criteria; verify the
expected artifact or tests afterward.

## Completion Test

For unattended work, declare done with a conjunction of work-level facts:

```bash
test -f /tmp/cx-i-NN-done.txt &&
  test -z "$(git status --short)" &&
  test "$(git log -1 --format=%ct)" -lt "$(($(date +%s) - 600))"
```

Adjust the artifact path and commit-age window to the task. The point is to
avoid declaring done while a worker is between edits or between commits.

## Why Pane State Alone Is Not Enough

Avoid using `state=prompt` or a quiet pane as the only completion signal:

- A finished agent can sit at a prompt forever.
- Some CLIs stay in a session state while auto-fix or tool loops continue.
- Focus changes and UI redraws can reset idle timers.
- A prompt can also mean the agent is blocked, not done.

Use `harnex pane` to understand what happened after a stronger signal tells you
where to look.

## Polling Patterns

For active supervision:

```bash
harnex pane --id cx-i-NN --lines 40
harnex events --id cx-i-NN --snapshot
harnex logs --id cx-i-NN --lines 80
```

For continuous viewing:

```bash
harnex pane --id cx-i-NN --follow --interval 2
harnex logs --id cx-i-NN --follow
harnex events --id cx-i-NN
```

For task completion:

```bash
harnex wait --id cx-i-NN --until task_complete --timeout 900
```

## Background Sweeper

Consumers often run a small shell loop that checks the expected done marker,
tree state, and harnex liveness. Keep a hard wall-clock cap so an unattended
pipeline cannot wait forever:

```bash
start=$(date +%s)
max_wait=5400

until test -f /tmp/cx-i-NN-done.txt; do
  if test "$(($(date +%s) - start))" -gt "$max_wait"; then
    echo "wall-clock cap hit for cx-i-NN" >&2
    exit 2
  fi

  harnex status --id cx-i-NN --json
  harnex pane --id cx-i-NN --lines 20
  sleep 60
done
```

Recommended caps:

| Work type | Cap |
| --- | --- |
| Small single dispatch | 30 minutes |
| Medium implementation | 90 minutes |
| Large unattended phase | 3 hours |

## Built-In Watch Mode

Use `harnex run --watch` when one foreground process should launch the worker
and apply bounded stall recovery:

```bash
harnex run codex --id cx-i-NN --watch --preset impl \
  --context "Read /tmp/task-impl-NN.md"
```

`--watch` exits with:

| Code | Meaning |
| --- | --- |
| `0` | Session exited |
| `1` | Operational error |
| `2` | Watcher escalated after bounded resumes |

Use a buddy instead when the monitoring decision needs language-level
interpretation.

## Anti-Patterns

- Polling `state=prompt` alone and calling it done.
- Letting an unattended loop run with no wall-clock cap.
- Reading raw tmux panes instead of `harnex pane`.
- Using `--wait-for-idle` as acceptance proof.
- Reusing a worker after a failure changes the task scope.
