# Buddy Monitoring

A buddy is a second harnex session that watches one or more workers and nudges
them if they stall. Use a buddy when the work is long-running, unattended, or
needs interpretation that simple stall policy cannot provide.

For simple inactivity recovery, prefer built-in watch mode:

```bash
harnex run codex --id cx-i-NN --watch --preset impl --context "Read /tmp/task-impl-NN.md"
```

Use a buddy when you need reasoning over pane contents, semantic checks, or
multi-session correlation.

## When To Use

Use a buddy for:

- Overnight or multi-hour work.
- Any dispatched task expected to run more than about 30 minutes unattended.
- Work where a stalled prompt, permission request, or disconnect would waste a
  long slot.
- Monitoring multiple signals before deciding whether to nudge.

## Spawn

Spawn the worker first, then spawn the buddy:

```bash
harnex run codex --id cx-i-42 --tmux cx-i-42 \
  --context "Read and execute /tmp/task-impl-42.md"

harnex run claude --id buddy-42 --tmux buddy-42
```

The buddy is just another harnex session. Inspect it, stop it, and read its
logs with the same commands as any worker.

## Buddy Prompt

Give the buddy an explicit polling loop, stall threshold, nudge rule, return
channel, and cleanup rule:

```text
You are an accountability partner for harnex session `cx-i-42`.

Every 5 minutes:
- Run `harnex pane --id cx-i-42 --lines 30`.
- Run `harnex status --id cx-i-42 --json`.

If the worker appears stuck at a prompt or permission dialog for more than
10 minutes with no progress, nudge it:
- `harnex send --id cx-i-42 --message "You appear to have stalled. Continue with your current task."`

If the worker exits or writes `/tmp/cx-i-42-done.txt`, report back:
- `tmux send-keys -t "$HARNEX_SPAWNER_PANE" "cx-i-42 finished. Check /tmp/cx-i-42-done.txt." Enter`

Do not interfere with active work. Stop yourself after reporting completion.
```

Send it:

```bash
harnex send --id buddy-42 --message "Read and execute /tmp/buddy-42.md"
```

## Return Channel

Every harnex-spawned session receives `HARNEX_SPAWNER_PANE` when the invoker is
inside tmux. The buddy can use it to report to an invoker that is not itself a
harnex session:

```bash
tmux capture-pane -t "$HARNEX_SPAWNER_PANE" -p
tmux send-keys -t "$HARNEX_SPAWNER_PANE" "cx-i-42 finished" Enter
```

If no tmux return pane is available, require the buddy to write a file and tell
the invoker where to read it.

## Cleanup

Stop the buddy after the worker completes:

```bash
harnex stop --id buddy-42
```

For full recipe form, use:

```bash
harnex recipes show 03
```
