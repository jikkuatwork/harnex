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
| `HARNEX_ARTIFACT_REPORT_PATH` | Absolute harness-owned final receipt path |
| `HARNEX_ARTIFACT_CLAIMS_PATH` | Optional bounded worker-claims input path |
| `HARNEX_ARTIFACT_REPORT_SCHEMA` | Receipt schema identifier |
| `HARNEX_ARTIFACT_REPORT_MODE` | `observed_state` for harness-authored receipts |
| `HARNEX_ARTIFACT_REPORT_REQUIRED` | `1` when the compatibility strict flag was passed |

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
`--auto-stop`. It requires `--context` and does not keep the session alive for
later reuse. On Codex app-server, a turn launched from `--context` is accepted
only after structured command/tool activity or a Git delta. Optional claims and
final prose cannot satisfy that observed-activity gate. A prose-only acknowledgment emits
`completed_no_activity`, is
visible as `task_failed` before teardown, and exits non-zero. This keeps
parallel orchestration compact without converting agent turn completion into
accepted work completion:

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

For public-bundle or benchmark runs, use `--cwd DIR` to make harnex launch the
wrapped agent from that directory and associate session metadata/default
telemetry with it:

```bash
harnex run codex --cwd /tmp/leximaze_eval_run_001 \
  --id lm-run-001 \
  --context "Read README.md and write RESPONSES.jsonl and OUTPUT.md" \
  --auto-stop
```

`--root DIR` only overrides harnex's root attribution; it does not change the
child process cwd. Neither flag is a sandbox.

For queue closeout, do not ask workers to author proof JSON. Harnex writes a
canonical receipt for every dispatch from the Git delta, structured command
exits, turn outcome, and usage it observed. The default receipt lives outside
the checkout under the Harnex state directory; pass `--artifact-report PATH`
only when a queue needs a fixed destination. Consumers can run:

```bash
harnex artifact-report validate /path/from/the-dispatch-row.json --final
```

A worker may add review context by writing only a small block to
`$HARNEX_ARTIFACT_CLAIMS_PATH` before it completes:

```json
{"claims":{"summary":"Review complete","verdict":"changes_requested","findings":{"P1":0,"P2":1,"P3":0}}}
```

Claims are bounded and advisory. They never determine receipt validity, and
malformed/stale claims are ignored. `HARNEX_ARTIFACT_REPORT_PATH` is owned and
overwritten by Harnex; JSON printed in final prose is not scraped. The legacy
`artifact-report init` command and `--require-artifact-report` flag remain for
compatibility, but normal dispatches need neither worker JSON nor an explicit
receipt path.

Queue runners should pass first-class attribution so dispatch rows can be grouped
without path/id heuristics:

```bash
harnex run pi --id pi-i-NN --tmux pi-i-NN \
  --project-id harnex --queue-id queue-005 --entry-id SP-4 \
  --phase implement --intent queue-work --require-attribution \
  --context "Read and execute /tmp/task-impl-NN.md"
```

`--require-attribution` fails before launch unless `project_id`, `phase`,
`intent`, and at least one work id (`queue_id`, `entry_id`, `issue`, or `plan`)
are present.

Every dispatch writes one `dispatch_start` and one rich v2 `dispatch_end` row
to the canonical repo/global dispatch stream, which is the only telemetry
destination. Repo `.harnex/config.json` can warn on or reject non-canonical
phase names before spawn.

Pi runs use structured RPC (`pi --mode rpc`) and require Pi >= 0.80.4; gate
unattended work with `harnex doctor --adapter pi`. Harnex `--model` / `--effort`
apply verified Pi startup controls before the prompt. Pass other Pi startup
flags after `--` (e.g. `harnex run pi --context "..." -- --model
anthropic/claude-sonnet-4-5 --thinking high`).
Since RPC cannot display Pi's trust prompt, explicitly pass child `--approve`
for reviewed project-local resources or `--no-approve` to ignore them.

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
