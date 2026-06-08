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

For unattended monitors, prefer `harnex wait --until done`: it returns on the
work-level `task_complete` signal or terminal exit, whichever comes first. For
structured sessions (Pi RPC and Codex app-server), `harnex wait --until
task_complete` remains the exact turn-level fence. Neither knows your acceptance
criteria; verify the expected artifact or tests afterward.

## Completion Test

For unattended work, first gate on harnex work completion, then verify the task
artifact and repo health:

```bash
harnex wait --id pi-i-NN --until done --timeout 5400 &&
  test -f path/to/expected-artifact &&
  test -z "$(git status --short)"
```

`harnex wait --until done` succeeds from `task_complete` or durable terminal
telemetry (`--summary-out` / `.harnex/dispatch.jsonl` / exit status), not from
tmp done markers.

Adjust the artifact path to the task. The point is to avoid declaring done while
a worker is between edits or between commits.

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
harnex pane --id pi-i-NN --lines 40
harnex events --id pi-i-NN --snapshot
harnex logs --id pi-i-NN --lines 80
```

For continuous viewing:

```bash
harnex pane --id pi-i-NN --follow --interval 2
harnex logs --id pi-i-NN --follow
harnex events --id pi-i-NN
```

For task completion:

```bash
harnex wait --id pi-i-NN --until done --timeout 900
# Or, when you specifically need the structured turn event:
harnex wait --id pi-i-NN --until task_complete --timeout 900
```

## Background Sweeper

Consumers often run a small shell loop that checks terminal state, then drops
to pane diagnostics only while work is still running. Keep a hard wall-clock cap
so an unattended pipeline cannot wait forever:

```bash
start=$(date +%s)
max_wait=5400

while :; do
  if test "$(($(date +%s) - start))" -gt "$max_wait"; then
    echo "wall-clock cap hit for pi-i-NN" >&2
    exit 2
  fi

  row=$(harnex status --id pi-i-NN --json | ruby -rjson -e 'rows=JSON.parse(STDIN.read); print JSON.generate(rows.first || {})')
  done=$(printf '%s' "$row" | ruby -rjson -e 'print(JSON.parse(STDIN.read)["done"] ? "true" : "false")')
  work_state=$(printf '%s' "$row" | ruby -rjson -e 'print(JSON.parse(STDIN.read)["work_state"].to_s)')
  state=$(printf '%s' "$row" | ruby -rjson -e 'print(JSON.parse(STDIN.read)["state"].to_s)')

  case "$done:$work_state" in
    true:*) echo "pi-i-NN work completed"; break ;;
    false:failed) echo "pi-i-NN work failed; process state: $state" >&2; exit 1 ;;
    *) harnex pane --id pi-i-NN --lines 20 ;;
  esac

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
harnex run pi --id pi-i-NN --watch --preset impl \
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

- Polling `state=completed` alone and missing live sessions with `task_complete=true`.
- Polling `state=prompt` alone and calling it done.
- Blocking orchestrators on `/tmp/*-done.txt` as the only completion signal.
- Letting an unattended loop run with no wall-clock cap.
- Reading raw tmux panes instead of `harnex pane`.
- Using `--wait-for-idle` as acceptance proof.
- Reusing a worker after a failure changes the task scope.
