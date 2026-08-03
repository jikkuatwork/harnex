# Close Index

Use this index as the first loaded reference for this skill. Render the final handoff with `FORMAT.md`.

# Close Session

Use this skill at the end of a real interactive work session or explicit durable handoff. Do not invoke it for every phase worker or internal coordinator rollover; those use compact receipts and batched checkpoints. A close is complete only when every intentional change is committed and the working tree plus index are clean. Do not claim success while `git status --porcelain=v1 --untracked-files=all` prints anything.

## Workflow

1. Establish the repository root and inspect the complete delta, including staged, unstaged, and untracked work:
   ```bash
   git status --short --untracked-files=all
   git diff HEAD --stat
   git diff HEAD
   git diff --cached --name-only
   git ls-files --others --exclude-standard
   ```
   If this is not a Git repository, initialize it only when the user has approved repository initialization.
2. Review every changed path before committing. Check implementation, docs, tests, deleted files, permissions, and untracked files. Inspect for secrets, credentials, private payloads, generated output, caches, and unrelated work. Never use `git add -A` blindly.
3. Preserve `koder/DISPATCH.jsonl` as append-only runtime telemetry. Never restore, reset, truncate, or discard legitimate rows; include them with the logical work or in a separate selected-path commit. Edit a row by hand only when it is genuinely malformed.
4. Run the repository’s relevant tests, linters, formatters, validators, and `git diff --check`. Record failures honestly. Do not commit code known to be incomplete or unreviewed merely to make the status green.
5. Commit all reviewed, intentional work in logical commits using selected-path staging. If unrelated or unknown dirty work exists, stop and ask rather than absorbing or deleting it. A successful close must not strand reviewed work.
6. Refresh `koder/STATE.md` using Harnex’s timestamp format:
   ```bash
   TZ='Asia/Kolkata' date '+%Y-%m-%d | %I:%M %p | %Z'
   ```
   Keep it short (under 100 lines), with only the latest **Past**, current **Present**, and actionable **Future** handoff. Put durable history in `CHANGELOG.md`, release evidence in `koder/releases/`, and issue- or plan-specific detail in its canonical artifact.
7. Commit the handoff with subject `state: close - <semantic result>`. Its body must name `State file: koder/STATE.md`, the session result, semantic delta, and validation. Stage only the state file and any inseparable handoff artifacts; routine artifact movement belongs in the logical work commit instead.
8. Re-run the final review after the state commit:
   ```bash
   wc -l koder/STATE.md
   git diff --check
   git status --short --untracked-files=all
   git diff --cached --name-only
   git log --grep='^state:' --oneline -5
   git rev-list --left-right --count @{u}...HEAD 2>/dev/null || true
   ```
9. Render `FORMAT.md` only after the final status check. Use `Git clean` only when both the index and working tree are empty. Report upstream ahead/behind separately; do not push, publish, install, deploy, or rewrite history unless repository instructions or the user explicitly require it.

## Completion invariant

- **Clean close:** no output from `git status --porcelain=v1 --untracked-files=all`; all intended work is in commits; `koder/STATE.md` is current and under 100 lines; validation results are reported.
- **Blocked close:** if any path is unknown, unsafe, incomplete, unreviewed, or cannot be committed safely, do not pretend the session closed. Render `Session Close Blocked`, list exact paths and the reason, and name the next action.
- A pre-existing dirty tree is not an excuse to skip the final check. Either review and commit the intentional paths, or leave the close explicitly blocked.

## Rules

- Preserve unrelated dirty or staged work; never reset, discard, force-push, or overwrite it to manufacture cleanliness.
- Never commit secrets, credentials, caches, build outputs, private data, or accidental large binaries.
- Do not commit failed or incomplete implementation work merely to satisfy the clean-state invariant; ask for a decision when needed.
- Do not create, close, or rewrite issue/plan records unless the session actually changed their status or the user explicitly requested it.
- Routine artifacts and status changes belong in logical work commits or batched checkpoints; do not create standalone `state:` commits merely to mirror metadata movement.
- If the user explicitly says not to commit, report the resulting dirty paths and mark the close blocked rather than claiming a clean close.
