# Claude Code: GPT Workers as Tools

Harnex lets a Claude Code session or subagent hand work to Pi workers (GPT or
other provider models) and get the result back in one blocking command, the
way it calls any tool. Each worker runs in a visible tmux window; nothing needs
a background notification, so a subagent can use every pattern here.

## Pick The Shape

| Need | Command | Returns |
| --- | --- | --- |
| A second opinion, an explanation, a read-only review | `harnex ask` | the answer text |
| One delegated task | `harnex run … --auto-stop --wait-done` | one JSON result |
| Several lanes in parallel | `harnex run …` per lane, then `harnex watch --owner --once` | results as they land |
| A follow-up or nudge to a live lane | `harnex send … --wait-done` | that turn's result |

### Ask

```bash
harnex ask "Which module writes dispatch rows, and is the lane case tested?"
harnex ask --model foundry-zyt/gpt-6.1-sol --file /tmp/review.md --timeout 9m
```

The worker reads the repository with read-only tools (`read,grep,find,ls`),
answers, and stops. stdout is the answer; stderr gets one line with the lane,
its time and the model. The default model is Pi's own (`defaultProvider` /
`defaultModel` in `~/.pi/agent/settings.json`). A read-only ask records its
dispatch in the global harnex stream, so the repository stays untouched. Add
`--write` to let it edit and run commands (recorded in the repository),
`--json` for the full result, and `--fallback-model M` to ask once more with
another model when the first fails on provider capacity or rate limits (that
failure arrives only after Pi's own retries, often a couple of minutes).

### Delegate One Task

```bash
harnex run pi --id pi-i-42 --tmux pi-i-42 \
  --cwd ../wt-42 --root . \
  --context-file koder/briefs/42.md --context-section "Sent verbatim" \
  --auto-stop --wait-done --wait-timeout 9m -- --no-approve
```

The result's `turn_result` carries `wait_result`, `outcome_class`, `model`,
the lane's head `end_sha`, `commits` (since launch) and `turn_commits` (this
turn), and `final_message`: the worker's last reply, up to 4,000 characters,
with the full text at `final_message_path`. On exit 124 the worker keeps going;
run the `resume` command the output names (it prints the same result object,
unnested). `--auto-stop` ends the lane after this result, so a later turn needs
a fresh lane; leave it off when you plan follow-ups.

`--context-section TEXT` sends the part of the brief under the first heading
(or plain marker line) starting with TEXT; `"Task"` and `"## Task"` both match
`## Task`, and the heading line itself is not sent. Durations accept `540`,
`9m`, `8m30s` or `1h30m`.

### Parallel Lanes

Launch each lane without `--wait-done`, then block on all of them at once:

```bash
harnex watch --owner --once --owner-tag sub-a --timeout 9m
```

It prints every result or stall that is ready (one JSON line each, with
`final_message` on results), advances its cursor, and exits 0; exit 124 means
nothing new yet, so call it again. Every turn of every lane is delivered once,
in settle order (`settled_at`; `ts` is when the line was printed), even turns
that ended while you were busy elsewhere. To wait for a whole batch in one
call, use `--until-idle` instead of `--once`: it prints results as they land
and exits 0 once none of your lanes is still running.

The stream reports results, stalls and how a running turn ended (`stopped`,
`timeout`, `failed`). Stopping a lane that already reported its result adds
no line. A turn you already collected with `send --wait-done` also arrives on
the stream; skip it by `(id, turn)`.

### Follow-Ups And Nudges

```bash
harnex send --id pi-i-42 --message "Also cover the empty-input case." --wait-done --timeout 540
```

A busy Pi lane takes the message at once as a follow-up (`delivery:
"follow_up"`); the turn's result then reports `follow_ups: {sent, pending}`,
and `pending: 0` means the worker saw it. An idle lane starts a new turn. After
a `provider_capacity` failure, nudge with "Continue the same task from where
you stopped" the same way. On 124, resume with
`harnex wait --id pi-i-42 --until done --after-seq <after_seq>`.

## Rules For Subagents

- **Block, never poll in the background.** A subagent cannot be woken after it
  ends its turn. Keep each blocking call under the 10-minute Bash cap
  (`--timeout 9m` / `--wait-timeout 9m`) and loop on 124.
- **Own your lanes.** A subagent inherits its parent's `CLAUDE_CODE_SESSION_ID`.
  Pass the same `--owner-tag TAG` to `harnex run` and
  `harnex watch --owner`, so your stream holds only your lanes. (Alternatively
  keep the shared owner and filter with `--match 'pi-TAG-*'` plus your own
  `--cursor TAG`.)
- **Name lanes** `pi-<role>-<tag>` (`i` implement, `r` review, `f` fix…); use
  the same value for `--id` and `--tmux`.
- **Give each lane its own worktree** (`--cwd <worktree> --root <checkout>`).
  Harnex then credits the lane's own commits, never yours on the root.
- **Verify before you report success.** `done` means the worker's turn
  settled without error; it is not acceptance (add `--require-artifact-report`
  to reject turns with no command, tool or Git activity). Check
  `final_message`, `turn_commits` and the tests yourself.
- **Clean up.** `--auto-stop` ends a one-shot lane. Otherwise stop it with
  `harnex stop --id X` once you have its result.
- **Avoid follow-forever readers.** `harnex events --id X` follows the stream;
  use `--snapshot`. Prefer `final_message` over scraping `harnex logs`.

## Exit Codes

`run --wait-done`, `send --wait-done`, `wait --until done` and `ask` share
them: 0 done, 1 failed, 2 completed but proof rejected, 3 no such session,
4 stalled (`--stall-after`), 124 timeout (the worker keeps running). A usage
error also exits 2 but prints no JSON (just an error on stderr).
`watch --owner --once` / `--until-idle`: 0 events printed, 124 nothing new.
`send` to a lane that has exited fails fast with exit 1 and
`status: "exited"`.
