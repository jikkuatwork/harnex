---
name: harnex-dispatch
description: Fire & Watch — the standard pattern for launching and monitoring harnex agent sessions. Use when dispatching implementation, review, or fix agents.
allowed-tools: Bash(harnex *)
---

# Dispatch — Fire & Watch

Every harnex agent dispatch follows three phases: **spawn**, **watch**, **stop**.
Before spawn, always decide the return channel and message contract.

`harnex-dispatch` is the canonical home for lifecycle mechanics only.
For orchestrator role boundaries, phase gates, and chain-level parallel policy,
see `harnex-chain`.

## Detect your context

Check env vars first to know whether you are inside a harnex-managed session:

| Variable | Meaning |
|----------|---------|
| `HARNEX_SESSION_CLI` | Which CLI this session is (`claude` or `codex`) |
| `HARNEX_ID` | Your session ID |
| `HARNEX_SESSION_REPO_ROOT` | Repo root the session is scoped to |
| `HARNEX_SESSION_ID` | Internal harnex instance ID |
| `HARNEX_SPAWNER_PANE` | tmux pane ID (`%N`) of the invoker |

If these are present, you can coordinate peers directly with `harnex send`,
`harnex status`, and `harnex wait`. `HARNEX_SPAWNER_PANE` is the fallback
return channel to the invoker via `tmux send-keys`.

## Return Channel First

Define how results come back before delegating work.

- Inside harnex: require peers to send final results back to your own
  `HARNEX_ID` via `harnex send --id "$HARNEX_ID" ...`
- Outside harnex: require a concrete return path (for example a specific file
  in the repo or an explicit tmux pane message)

Do not delegate work without an explicit completion contract.

## Send Hygiene

### Keep prompts short; reference files for long instructions

```bash
cat > /tmp/task-impl-NN.md <<'EOF'
Detailed instructions here...
EOF

harnex send --id cx-impl-NN --message "Read /tmp/task-impl-NN.md. Reply with final status to harnex id $HARNEX_ID."
```

Long inline messages are brittle in PTYs. Use plan/issue files or temp files.

### Require explicit reply instruction in every delegated task

```bash
harnex send --id cl-rev-NN --message "Review koder/plans/NN_name.md. When done send findings to harnex id $HARNEX_ID."
```

## Relay Headers

Messages sent from one harnex session to another are auto-wrapped:

```
[harnex relay from=<cli> id=<sender_id> at=<timestamp>]
<message body>
```

When you receive a relay header, treat it as an actionable prompt from the
peer. Respond using `harnex send --id <sender_id> ...` unless instructed
otherwise.

## Practical Reply/Delegate Patterns

Reply to a peer:

```bash
harnex send --id <TARGET_ID> --message "<result>"
```

Delegate and force a return path:

```bash
harnex send --id cx-impl-NN --message "$(cat <<EOF
Implement koder/plans/NN_name.md.
Run tests before finishing.
When done, send one summary line back to harnex id $HARNEX_ID.
EOF
)"
```

## 1. Spawn

Launch the agent in a tmux window so the user can observe it live:

```bash
harnex run codex --id cx-impl-NN --tmux cx-impl-NN \
  --context "Implement koder/plans/NN_name.md. Run tests when done. Commit after each phase."
```

For reviews (Claude):

```bash
harnex run claude --id cl-rev-NN --tmux cl-rev-NN \
  --context "Review the implementation of plan NN against the spec in koder/plans/NN_name.md. Write findings to koder/reviews/NN_name.md"
```

For complex task prompts, write to a temp file and reference it:

```bash
cat > /tmp/task-impl-NN.md <<'EOF'
Detailed instructions here...
EOF

harnex run codex --id cx-impl-NN --tmux cx-impl-NN \
  --context "Read and execute /tmp/task-impl-NN.md"
```

### Built-in monitoring (`--watch`)

For unattended implementation runs where you only need stall policy (not
Claude-side reasoning), bundle dispatch and monitoring in one command:

```bash
harnex run codex --id cx-impl-42 --tmux cx-impl-42 --watch --preset impl
```

`--preset impl` applies the standard 8m stall threshold with one forced resume.
Trade-off: `--watch` is foreground-blocking and policy-only (`stall-after` +
`max-resumes`). Use pane polling (and buddy when needed) for richer reasoning.

## 2. Watch

Poll the agent's screen with `harnex pane`. Checking is cheap — a 20-line
tail is a few hundred bytes.

For structured orchestration, prefer `harnex events --id <id>` over pane-text
scraping.

**Default: poll every 30 seconds.** This is fine for most work. The check
itself costs almost nothing and catches completion quickly.

**Progressive intervals** when you expect longer work:

| Elapsed | Interval | Rationale |
|---------|----------|-----------|
| 0–2 min | 30s | Catch fast completions and early errors |
| 2–10 min | 60s | Steady state for typical implementations |
| 10+ min | 120s | Long-running work, reduce noise |

```bash
# Quick check — last 20 lines is enough to see if done or stuck
harnex pane --id cx-impl-NN --lines 20

# JSON metadata (includes capture timestamp)
harnex pane --id cx-impl-NN --lines 20 --json
```

When checking, look for:
- **At prompt** → agent finished, read last output for results
- **Still working** → agent is reading files, running tests, editing code
- **Error/stuck** → agent hit a blocker, may need intervention
- **Permission prompt** → agent waiting for user approval, intervene

### Background poll from Claude Code

```bash
# Run as a background task, check result when notified
harnex pane --id cx-impl-NN --lines 20
```

Or use `--follow` for continuous monitoring:

```bash
harnex pane --id cx-impl-NN --lines 20 --follow
```

## 3. Stop

When the agent is done (at prompt, work committed):

Stop each completed session as soon as its commit lands.

```bash
harnex stop --id cx-impl-NN
```

Always verify the agent's work landed before stopping:

```bash
# Quick sanity check
harnex pane --id cx-impl-NN --lines 20
# Confirm commits exist
git log --oneline -5
# Then stop
harnex stop --id cx-impl-NN
```

## Naming Conventions

| Step | ID pattern | tmux window | Example |
|------|-----------|-------------|---------|
| Mapping | `cx-map-NN` | `cx-map-NN` | `cx-map-42` |
| Map review | `cx-rev-map-NN` | `cx-rev-map-NN` | `cx-rev-map-42` |
| Map fix | `cx-fix-map-NN` | `cx-fix-map-NN` | `cx-fix-map-42` |
| Implement | `cx-impl-NN` | `cx-impl-NN` | `cx-impl-42` |
| Review | `cl-rev-NN` | `cl-rev-NN` | `cl-rev-42` |
| Fix | `cx-fix-NN` | `cx-fix-NN` | `cx-fix-42` |
| Plan write | `cx-plan-NN` | `cx-plan-NN` | `cx-plan-42` |
| Plan review | `cx-rev-plan-NN` | `cx-rev-plan-NN` | `cx-rev-plan-42` |
| Plan fix | `cx-fix-plan-NN` | `cx-fix-plan-NN` | `cx-fix-plan-42` |
| Buddy | `buddy-NN` | `buddy-NN` | `buddy-42` |

**Rule**: Always use `--tmux <same-as-id>` so the tmux window name matches
the session ID. Never use a different tmux name.

## Full Dispatch Lifecycle

```
1. Mark plan IN_PROGRESS, commit
2. harnex run codex --id cx-impl-NN --tmux cx-impl-NN
3. Poll with harnex pane --lines 20 every 30s
4. When done: verify commits, harnex stop
5. harnex run claude --id cl-rev-NN --tmux cl-rev-NN (review)
6. Poll with harnex pane --lines 20 every 30s
7. When done: harnex stop, read review
8. If NEEDS FIXES: harnex run codex --id cx-fix-NN (fix pass)
9. If PASS: done
```

## Worktree Option

Use worktrees only when you need **parallel isolation** — e.g., implementing
one plan while another is being reviewed, or when the user explicitly asks.
Do not default to worktrees for serial work.

### Worktree Setup

```bash
# Commit all files the agent will need BEFORE creating the worktree
# (untracked files don't carry over)
git add koder/plans/NN_name.md
git commit -m "docs(plan-NN): add plan"

# Create worktree
WORKTREE="$(pwd)/../$(basename $(pwd))-plan-NN"
git worktree add ${WORKTREE} -b plan/NN_name main

# Launch from worktree
cd ${WORKTREE}
harnex run codex --id cx-impl-NN --tmux cx-impl-NN \
  --context "Implement koder/plans/NN_name.md. Run tests when done."
```

### Worktree Caveats

- **cd first**: launch and manage sessions from the worktree directory
- **Merge conflicts**: `koder/` state files may diverge — on merge, keep
  master's versions of session-state files
- **Cleanup**: `git worktree remove <path>` then `git branch -d plan/<branch>`

## Checking Status

```bash
harnex status           # current repo sessions
harnex status --all     # all repos
```

## Buddy for Long-Running Dispatches

If the dispatched work is expected to take a long time (overnight, multi-hour)
or the user asks for unattended execution, spawn a buddy alongside the worker.
Dispatch mechanics stay here; buddy monitoring mechanics live in
`harnex-buddy`.

```bash
harnex run claude --id buddy-NN --tmux buddy-NN
harnex send --id buddy-NN --message "Watch session cx-impl-NN. Follow skills/harnex-buddy/SKILL.md and report completion to \$HARNEX_SPAWNER_PANE."
```

For activation conditions, poll/stall/nudge loop, return channel details, and
buddy cleanup, use `harnex-buddy`.

## What NOT to Do

- **Never** launch agents with raw `tmux send-keys` or `tmux new-window`
- **Never** use `--tmux NAME` where NAME differs from `--id`
- **Never** pass `-- --cd <path>` to Claude sessions (unsupported flag)
- **Never** poll with raw `tmux capture-pane` — use `harnex pane`
- **Never** rely on `--wait-for-idle` alone — always use Fire & Watch
- **Never** use `c-zai-dangerous` or direct CLI spawning outside harnex
