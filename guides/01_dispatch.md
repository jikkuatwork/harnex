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
| `HARNEX_SESSION_CLI` | Wrapped CLI name, such as `pi` or `claude` |
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

For a one-shot task, add `--auto-stop --wait-done --wait-timeout 9m`: the
same command blocks until the first turn's result and prints it with the
launch fields (`turn_result.final_message` is the worker's reply; on 124 run
the `resume` command it prints). `harnex ask "QUESTION"` does that for a
read-only question and prints only the answer. See `harnex agents-guide
claude` for the Claude Code patterns.

To send a brief file's text itself, use `--context-file PATH`. Add
`--context-section TEXT` to send only one part: after a Markdown heading that
starts with TEXT, up to the next heading of the same or a higher level; after a
plain marker line (e.g. `Sent verbatim as the harnex --context.`), to the end
of the file. An empty result is refused before launch. `--meta-file PATH`
reads `--meta` JSON from a file and refuses invalid JSON (inline `--meta`
keys win). The brief's path and the SHA-256 of the sent text are recorded as
`meta.context_file` / `meta.context_sha256` on the started event and dispatch
rows.

For one-shot context dispatches that should clean themselves up, add
`--auto-stop`. It requires `--context` (or `--context-file`) and does not keep
the session alive for later reuse. A Pi turn is accepted when it settles. With
`--require-artifact-report` it must also show command/tool activity or a Git
delta; optional claims and final prose cannot satisfy that gate, and a
prose-only acknowledgment emits `completed_no_activity`, is visible as
`task_failed` before teardown, and exits non-zero. This keeps parallel
orchestration compact:

```bash
for i in 1 2 3; do
  harnex run pi --id w-$i --tmux w-$i --detach \
    --context "Read and execute /tmp/task-$i.md" --auto-stop &
done
for i in 1 2 3; do harnex watch --id w-$i --until done --max-wait 90m & done
wait
```

Before an unattended queue run, prove the plumbing with one tiny real
dispatch for the chosen worker and one declared fallback (with Pi, a fallback
`--model`). Both must be inside your dispatch-model policy; an out-of-policy
fallback is a launch blocker, not a fallback. `preflight` exits non-zero on any failed check
(boot, registration, trust prompt, task read, workspace write, command exit,
receipt, claims, completion, stop) and names the failure class:

```bash
harnex preflight pi --cwd "$REPO" \
  && harnex preflight pi --cwd "$REPO" --model "$FALLBACK_MODEL" \
  && harnex run pi --id pi-i-NN --tmux pi-i-NN --context "Read and execute /tmp/task-NN.md" --auto-stop
```

Add `--commit-check` when workers must commit (it commits only in a throwaway
scratch repo). Preflight rows land in history with `phase=preflight` and stay
out of `orchestration report` rollups unless `--include-preflight` is passed.

To separate final acceptance from exploratory command noise in the receipt,
declare the final commands: `--final-gate 'bundle exec rake test'` (repeatable).
`validation.status` then reflects each gate's last observed exit, and
`validation.commands_had_failures` keeps the history. Still replay the gates
yourself before accepting work.

For unattended work, pair each dispatch with an owner-addressed consumer and
bounded native monitoring rather than depending on one long blocking watcher:

```bash
harnex run pi --id pi-i-NN --tmux pi-i-NN \
  --context "Read and execute /tmp/task-NN.md" --auto-stop
```

When `harnex run` is invoked by a Pi shell tool, it captures `PI_SESSION_ID`
(from a Claude Code Bash shell, `CLAUDE_CODE_SESSION_ID`; Pi's wins if both
are present) before crossing detached/tmux process boundaries. The session registers a
per-owner, per-attempt record under `$HARNEX_STATE_DIR/notifications/` before
sending the structured initial prompt, then atomically settles that record at
the first typed outcome. A nested Harnex worker never implicitly nominates
itself; non-Pi or nested orchestrators can pass `--orchestration-session-id`
explicitly. Dispatch-name reuse does not erase these records.

Every registered session also writes the existing
`$HARNEX_STATE_DIR/done/<repo-key>--<normalized-id>.<outcome>` marker. Optional
`--on-done CMD` remains available for single-consumer integrations and receives
`HARNEX_ID`, `HARNEX_OUTCOME`, `HARNEX_WORK_STATE`, `HARNEX_RECEIPT_PATH`,
`HARNEX_END_SHA`, and `HARNEX_ELAPSED_S`; never use one destructive shared file
as a multi-session delivery queue. `CMD` is trusted `/bin/sh -c` input, so do
not embed secrets in the command line.

A delivery only wakes the consumer. Even `completed` requires exact-receipt,
artifact, test, and Git verification plus a durable consumer acknowledgment.

Rule: when you use `--tmux`, pass the same name as `--id`. If you pass only
`--tmux NAME`, harnex creates a random session ID and the pane name no longer
matches `harnex status` or `harnex pane --id`.

For public-bundle or benchmark runs, use `--cwd DIR` to make harnex launch the
wrapped agent from that directory and associate session metadata/default
telemetry with it:

```bash
harnex run pi --cwd /tmp/leximaze_eval_run_001 \
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
apply verified Pi startup controls before the prompt (e.g. `--model
foundry-zyt/gpt-6.1-sol --effort high`). Pass other Pi startup flags after
`--` (e.g. `harnex run pi --context "..." -- --approve`).
Since RPC cannot display Pi's trust prompt, harnex starts Pi with
`--no-approve` (project-local resources ignored) unless you pass `--approve`.

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

Sending to a busy worker:

- **Pi:** the message is handed to Pi at once as a follow-up (`delivery:
  "follow_up"`) and delivered when the current turn ends. It cannot expire.
  `--force` steers it into the turn now instead.
- **Other adapters:** it queues until the agent is at a prompt. If it is not
  delivered within `--timeout`, send withdraws it and exits 124; if it
  expires in the inbox (`run --inbox-ttl`), send exits 1 with `status:
  "expired"`. Either way the caller knows the note was not delivered.

Every delivery reports `after_seq`. To wait for the turn a message started
(for example after nudging a turn that failed on provider capacity), wait
after that point so the earlier failure cannot answer:

```bash
harnex send --id pi-i-NN --message "Continue the same task from where you stopped" \
  --wait-done --timeout 540
# on exit 124, resume with the after_seq it printed:
harnex wait --id pi-i-NN --until done --after-seq 812 --timeout 540
```

`--wait-done` uses the `wait --until done` exit codes (0 done, 1 failed, 2
proof rejected, 4 stalled, 124 timeout). Without `--timeout` it waits for
the turn without a cap.

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
