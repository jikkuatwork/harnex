# Open Index

Use this index as the first loaded reference for this skill. Render the final handoff with `FORMAT.md`.

# Open Session

Use this skill at the beginning of a work session in this repository. Opening is observational: establish the starting point before modifying files, starting services, repairing drift, or committing anything.

## Workflow

1. Locate the repository root from the current working directory.
2. Read `koder/STATE.md` completely before making changes. Treat it as the durable narrative handoff, not as a changelog, release record, architecture inventory, or issue tracker.
3. When `koder/docs/EXECUTION.md` exists, read it completely and surface only the active authorization window, allowed scope, stop gate, and hard orchestration/context mode. Do not activate future windows or follow their linked implementation sources during open.
4. If state or execution instructions declare `orchestration_mode: blind`, report that the primary must route isolated fresh workers and consume compact receipts rather than implement or ingest implementation detail.
5. Inspect live repository facts:
   ```bash
   git status --short --untracked-files=all
   git branch --show-current
   git log --oneline -5
   git rev-list --left-right --count @{u}...HEAD 2>/dev/null || true
   ```
   If this is not a Git repository, say so clearly and continue with the file-based handoff.
6. Keep artifact loading bounded. Do not enumerate or read every file under `koder/issues/`, `koder/plans/`, or `koder/releases/`. Read only the artifact named by the handoff or concrete user task; inspect names or counts only when needed to resolve ambiguity.
7. Summarize the handoff as **Past**, **Present**, and **Future**. Include dirty, staged, and untracked paths plus branch and upstream drift when relevant.
8. Render the response using `FORMAT.md`:
   - use `━━━` separators, not Markdown horizontal rules;
   - keep the stat block compact;
   - omit **Notes** when nothing needs attention;
   - use inline code for paths, commits, and issue numbers;
   - finish with one judgment line and one suggested next action.
9. Ask what the user wants to do next unless they already supplied a concrete task. Once opening has established a safe starting point, continue into that task. When an active window exists, make the default suggestion that bounded window and include its stop condition. For blind mode, say that “yes” routes isolated fresh workers—not direct implementation in the primary context.

## Output contract

The opening report must make it immediately obvious whether the repository is safe to start work in. Never describe a dirty repository as clean. If `koder/STATE.md` is missing, say so prominently and offer to create it; do not silently invent a handoff.

## Rules

- Do not modify files as part of opening unless the user explicitly asks.
- Do not update `koder/STATE.md` during open merely because it looks old; report stale or conflicting facts and address them only as part of an explicit task or handoff.
- Do not auto-repair dirty state, stale artifacts, services, remotes, or version drift.
- Do not dump secrets, private account details, or sensitive telemetry into the report.
- Do not start workers, preload queue plans, or repair orchestration state during opening.
- Prefer concise bullets and artifact paths over copied history or speculative reads.
