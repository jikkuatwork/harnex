# Recipe: Chain Implement

This is repeated fire-and-watch for a batch of jobs.

Process plans in series. For each plan, use fresh instances for
every step:

- Pi plans or implements
- Claude (or a fresh Pi lane) reviews
- Pi fixes
- Repeat review and fix until clean, then move to the next plan

## Trigger

User says something like:
- "implement plans 23 to 27, review each, fix issues"
- "implement plans 23 to 27, use fresh Pi for implementation
  and fresh Claude for review on every plan"

## Procedure

For each plan in the batch:

### Step 1: Plan or confirm the plan

If the plan file does not already exist or needs refinement, spawn a
fresh Pi planner and tell it to write a plan artifact.

```bash
harnex run pi --id pi-p-23 --tmux pi-p-23
harnex send --id pi-p-23 --message "Write a concrete implementation plan for plan 23 to /tmp/plan-23.md. Do not change code." --wait-for-idle --timeout 600
```

Inspect with `harnex pane --id pi-p-23 --lines 60`, then stop it.

If the plan is already written and trusted, skip this step and use the
existing plan file directly.

### Step 2: Implement

Spawn a fresh Pi worker, send it the plan, watch it, stop it.

```bash
harnex run pi --id pi-i-23-r1 --tmux pi-i-23-r1
harnex send --id pi-i-23-r1 --message "Read /tmp/plan-23.md, implement it, run tests, and write a summary to /tmp/impl-23-r1.md." --wait-for-idle --timeout 1200
```

Inspect with `harnex pane --id pi-i-23-r1 --lines 80`, then stop it.

### Step 3: Review

Spawn a fresh reviewer: a Claude session, or a fresh Pi lane that has
not seen the implementation. Reviewers only review in this recipe.

```bash
harnex run claude --id cl-r-23-r1 --tmux cl-r-23-r1
harnex send --id cl-r-23-r1 --message "Review the current changes against /tmp/plan-23.md. Write findings to /tmp/review-23-r1.md. If there are no issues, say clean." --wait-for-idle --timeout 900
```

For a Pi reviewer, use `harnex run pi --id pi-r-23-r1 --tmux pi-r-23-r1`
with the same message.

Inspect with `harnex pane --id cl-r-23-r1 --lines 80`, then stop it.

### Step 4: Fix and repeat if needed

If the review is clean, move to the next plan.

If the review finds issues, spawn a fresh Pi fixer:

```bash
harnex run pi --id pi-f-23-r1 --tmux pi-f-23-r1
harnex send --id pi-f-23-r1 --message "Read /tmp/review-23-r1.md, fix every issue, run tests, and write a summary to /tmp/fix-23-r1.md." --wait-for-idle --timeout 1200
```

Inspect with `harnex pane --id pi-f-23-r1 --lines 80`, then stop it.

Then spawn another fresh reviewer and repeat the review and fix
loop until clean or until you decide the plan needs manual attention.

### Step 5: Next plan

Move to plan 24. Repeat from step 1.

## Naming convention

Use the plan number in every worker ID so you can tell them apart in
`harnex status`:

 | Step      | ID pattern                  | Example        |
 | ---       | ---                         | ---            |
 | Plan      | `pi-p-NN`                   | `pi-p-23`      |
 | Implement | `pi-i-NN-rM`                | `pi-i-23-r1`   |
 | Review    | `cl-r-NN-rM` / `pi-r-NN-rM` | `cl-r-23-r1`   |
 | Fix       | `pi-f-NN-rM`                | `pi-f-23-r1`   |

## Notes

- Each step uses a fresh instance. Don't reuse a worker across
  steps or rounds. A clean context avoids bleed between plan,
  implement, review, and fix.
- The batch is serial. Finish plan 23 completely before starting
  plan 24. Plans often build on each other.
- The reviewer only reviews. Do not use Claude as the planner or
  fixer in this recipe, and never let the implementing Pi lane review
  its own work.
- Pass artifacts between steps as files (`/tmp/plan-23.md`,
  `/tmp/review-23-r1.md`), not as harnex reply messages.
- If the review finds no issues, skip the fix step and move on.

## Rationale

This recipe is not a different control model. It is just
fire-and-watch repeated with stronger discipline:

- one worker per step
- one artifact per handoff
- one reviewer role, always a fresh Claude or Pi lane
- one serial job stream, so later plans see earlier fixes
