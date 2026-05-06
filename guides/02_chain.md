# Chain Implementation

Chain implementation is Fire and Watch repeated with phase gates. It takes an
issue or request through planning, review, implementation, review, fixes, and
release without reusing long-lived worker context.

## Roles

Keep roles explicit:

| Role | Responsibility |
| --- | --- |
| Orchestrator | Dispatches sessions, watches progress, enforces gates |
| Worker | Performs scoped production work in a fresh session |
| Reviewer | Reviews one artifact or change set and writes findings |
| Fixer | Addresses review findings in a fresh session |

The orchestrator may be a human or an agent. It should not quietly skip review
gates, guess around user-blocking questions, or keep piling work into one
worker after the scope changes.

## Default Serial Flow

Use this serial flow for most work:

```text
Issue or request
  -> optional mapping
  -> plan
  -> plan review
  -> plan fix if needed
  -> implement
  -> code review
  -> code fix if needed
  -> verify
  -> release or handoff
```

Each arrow is a fresh harnex worker when delegated. Pass state through files:
the issue, plan, review file, fix summary, test log, or done marker.

## Per-Plan Loop

For each independently testable plan:

1. Start a planner only if the plan does not already exist or needs revision.
2. Start a reviewer for the plan.
3. Start a fixer if the review finds blocking issues.
4. Start an implementation worker.
5. Start a code reviewer.
6. Start a code fixer if needed.
7. Verify tests and state.
8. Commit or tag only after the gate passes.

Do not start implementation with unresolved blocking plan-review findings. Do
not advance to the next plan with unresolved blocking code-review findings.

## Parallel Variant

Parallelism is safest in planning and review phases, because those steps can
write separate artifacts. Keep implementation serial on the main working tree
unless the user explicitly asks for parallel implementation and you create
isolated worktrees.

Recommended limits:

| Lane | Default |
| --- | --- |
| Planning | Parallel allowed |
| Plan review | Parallel allowed |
| Implementation | Serial unless worktrees are explicit |
| Code review/fix | Serial per implementation |

When parallelizing, cap the number of active workers to what the machine and
CLI provider can handle. A practical upper bound is five Codex sessions across
all active lanes unless the user requested more.

## Worktrees

Use worktrees only when they solve a real isolation problem. Commit or otherwise
make every needed artifact available before creating the worktree, because
untracked files do not carry over.

```bash
git worktree add ../project-plan-NN -b plan/NN main
cd ../project-plan-NN
harnex run codex --id cx-i-NN --tmux cx-i-NN \
  --context "Read the project plan and implement this isolated lane."
```

Launch and manage the harnex session from the same repo root or pass `--repo`
when needed. Use `harnex status --all` to inspect sessions across worktrees.

## Failure And Escalation

Escalate instead of guessing when:

- A review asks a user-blocking question.
- A worker diverges materially from the plan.
- The working tree is dirty in unexpected files.
- The same gate fails repeatedly.
- Monitoring hits the wall-clock cap.

Fix loops are useful only while the review finding is concrete and the worker
has enough context to address it.

## Recipe

For a compact command walkthrough, use:

```bash
harnex recipes show 02
```
