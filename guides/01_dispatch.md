# Dispatch: Fire and Watch

Fire and Watch is the base harnex workflow for agent dispatch:

1. Spawn one fresh worker.
2. Send one scoped task.
3. Watch for progress with harnex primitives.
4. Verify the result.
5. Stop the worker.

Use this pattern for implementation, review, fix, mapping, and planning
sessions. Compose larger workflows by repeating it with file handoffs.

## Detect Your Context

Inside a harnex-managed session, these environment variables are available:

| Variable | Meaning |
| --- | --- |
| `HARNEX_SESSION_CLI` | Wrapped CLI name, such as `pi`, `codex`, or `claude` |
| `HARNEX_ID` | Current harnex session ID |
| `HARNEX_SESSION_REPO_ROOT` | Repo root for the session |
| `HARNEX_SESSION_ID` | Internal harnex instance ID |
| `HARNEX_SPAWNER_PANE` | Tmux pane ID of the invoker |

Use `harnex send`, `harnex status`, `harnex wait`, `harnex pane`, and
`harnex logs` to coordinate with peers. If you are not inside harnex,
use a concrete return artifact such as a file path or a tmux pane message.

## Return Channel First

Decide how results come back before you delegate work.

Inside harnex, instruct the peer to reply to your own session:

```bash
harnex send --id pi-i-NN --message "Read /tmp/task-impl-NN.md. When done, send one summary line back to harnex id $HARNEX_ID."
```

Outside harnex, require a file or another explicit return path:

```bash
harnex send --id pi-i-NN --message "Read /tmp/task-impl-NN.md. Write final status to /tmp/pi-i-NN-done.txt."
```

Do not delegate work without an explicit completion contract.

## Spawn

Launch worker sessions in tmux when a user or orchestrator may need to inspect
them live. Default to Pi unless a task explicitly requires another adapter:

```bash
harnex run pi --id pi-i-NN --tmux pi-i-NN \
  --context "Implement the project plan in /tmp/task-impl-NN.md. Run tests when done."
```

For long prompts, write the details into a file and reference it. Structured
sends are more reliable with short injected messages.

```bash
harnex run pi --id pi-i-NN --tmux pi-i-NN \
  --context "Read and execute /tmp/task-impl-NN.md"
```

For one-shot context dispatches that should clean themselves up, add
`--auto-stop`. It requires `--context`, fires once on the first task
completion, and does not keep the session alive for later reuse. This keeps
parallel orchestration compact:

```bash
for i in 1 2 3; do
  harnex run pi --id w-$i --tmux w-$i --detach \
    --context "Read and execute /tmp/task-$i.md" --auto-stop &
done
for i in 1 2 3; do harnex watch --id w-$i --until done --max-wait 90m & done
wait
```

Rule: when you use `--tmux`, pass the same name as `--id`. If you pass only
`--tmux NAME`, harnex creates a random session ID and the pane name no longer
matches `harnex status` or `harnex pane --id`.

Pi runs use structured RPC (`pi --mode rpc`). Pass Pi child flags after `--`
(e.g. `harnex run pi --context "..." -- --model anthropic/claude-sonnet-4-5 --thinking high`).

Codex flag forms differ between transports. The default JSON-RPC adapter
(`codex app-server`) does not accept `-m`/`--model`; pass the model as
`-c model="<name>"` instead. The legacy PTY adapter (`harnex run codex
--legacy-pty`) still accepts `-m`. Codex app-server runs also default to
`service_tier="flex"`; add `--fast` to use `service_tier="fast"`.

## Send

Use `--message` for short instructions and file references:

```bash
harnex send --id pi-i-NN --message "Continue with /tmp/task-impl-NN.md. Report final status to $HARNEX_ID."
```

Use `--wait-for-idle` only as a turn fence. It proves that one send returned to
an idle state; it is not a full work-completion signal.

```bash
harnex send --id pi-i-NN --message "Run the acceptance test." --wait-for-idle --timeout 900
```

Messages sent from one harnex session to another include a relay header:

```text
[harnex relay from=<cli> id=<sender_id> at=<timestamp>]
<message body>
```

Treat relay messages as actionable prompts. Reply with `harnex send --id
<sender_id> ...` unless the sender provided a different return path.

## Watch

Use the lightest primitive that gives the signal you need:

| Need | Command |
| --- | --- |
| Current live screen | `harnex pane --id pi-i-NN --lines 40` |
| Continuous pane view | `harnex pane --id pi-i-NN --follow` |
| Transcript tail | `harnex logs --id pi-i-NN --lines 80` |
| Structured events | `harnex events --id pi-i-NN --snapshot` |
| Existing-session work monitor | `harnex watch --id pi-i-NN --until done --max-wait 90m` |
| Primitive work completion/failure fence | `harnex wait --id pi-i-NN --until done` |
| Native successful-turn completion | `harnex wait --id pi-i-NN --until task_complete` |

For visible `--tmux` or detached dispatches, prefer `harnex watch --id`: it
returns `0` on done, non-zero on `task_failed`/failed terminal summaries, and
`124` on `--max-wait` timeout. Use `--done-marker` / `--fail-marker` only as
compatibility outputs for older queue scripts.

For foreground launch-and-stall-recovery, use `harnex run --watch`:

```bash
harnex run pi --id pi-i-NN --watch --preset impl --context "Read /tmp/task-impl-NN.md"
```

`run --watch` is foreground-blocking. Use it when a single process should
launch and monitor the worker. Use pane/log/event polling or a buddy when you
need interpretation across multiple sessions.

## Verify And Stop

Before stopping a worker, verify the expected artifact, test result, commit,
or review output exists:

```bash
harnex pane --id pi-i-NN --lines 60
git status --short
git log --oneline -5
harnex stop --id pi-i-NN
```

Stop completed sessions promptly. Fresh workers are easier to reason about
than reused workers with stale context.

## Recipes

For compact command recipes, use:

```bash
harnex recipes show 01
harnex recipes show fire
```
