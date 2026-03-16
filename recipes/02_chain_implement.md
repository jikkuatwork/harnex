# Recipe: Chain Implement

Process a batch of plans in series. Each plan goes through
implement (Codex) → review (Claude) → fix (Codex), with a
fresh instance for each step.

## Trigger

User says something like:
- "implement plans 23 to 27, review each, fix issues"
- "implement plans 23 to 27, use harnexed codex for implementation
  and harnexed claude for review, then codex again for fixes —
  separate instance for each step"

## Procedure

For each plan in the batch:

### Step 1: Implement

Spawn a Codex worker, send the plan, watch until done.

```bash
harnex run codex --id cx-impl-23 --tmux
harnex send --id cx-impl-23 --message "Implement koder/plans/plan_23.md. Run tests when done."
```

Watch with `harnex pane --id cx-impl-23 --lines 25` until the
worker is idle. Capture the result. Stop the worker.

### Step 2: Review

Spawn a Claude worker, send it the review task, watch until done.

```bash
harnex run claude --id cl-rev-23 --tmux
harnex send --id cl-rev-23 --message "Review the implementation of koder/plans/plan_23.md. Check for correctness, test coverage, and edge cases. List any issues found."
```

Watch with `harnex pane --id cl-rev-23 --lines 25` until idle.
Capture the review output. Stop the worker.

### Step 3: Fix (if needed)

Read the review. If there are issues, spawn a Codex worker to
fix them.

```bash
harnex run codex --id cx-fix-23 --tmux
```

Write the review findings to a temp file and send it:

```bash
cat > /tmp/fix-23.md <<'EOF'
Fix the issues found in the review of plan 23:

<paste review findings here>

Run tests after fixing.
EOF

harnex send --id cx-fix-23 --message "Read and execute /tmp/fix-23.md"
```

Watch until done. Capture the result. Stop the worker.

### Step 4: Next plan

Move to plan 24. Repeat from step 1.

## Naming convention

Use the plan number in every worker ID so you can tell them
apart in `harnex status`:

 | Step      | ID pattern   | Example      |
 | ---       | ---          | ---          |
 | Implement | `cx-impl-NN` | `cx-impl-23` |
 | Review    | `cl-rev-NN`  | `cl-rev-23`  |
 | Fix       | `cx-fix-NN`  | `cx-fix-23`  |

## Notes

- Each step uses a fresh instance. Don't reuse a worker across
  steps — a clean context avoids bleed between implement/review/fix.
- The batch is serial. Finish plan 23 completely before starting
  plan 24. Plans often build on each other.
- If the review finds no issues, skip the fix step and move on.


## Rationale

Plans that build on each other must be processed serially — plan
24 might depend on code landed by plan 23. A fresh instance per
step avoids context bleed: the implementer doesn't carry the
reviewer's concerns into its work, and the fixer starts clean
with just the findings. The implement→review→fix loop mirrors
how a human team works — write, review, address feedback — but
each step is delegated to a specialist agent and monitored via
screen capture rather than message passing.
