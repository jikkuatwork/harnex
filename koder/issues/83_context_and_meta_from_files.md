---
status: resolved
priority: P2
created: 2026-10-20
updated: 2026-10-20
tags: run, cli, briefs, orchestration
issue_kind: slice
type: feature
---

# Issue 83 — `run --context-file` and `--meta-file`

Holm launches every lane from a brief file whose dispatchable part follows a "Sent verbatim"
heading. The launch line today is
`--context "$(sed -n '/^Sent verbatim/,$p' brief.md | sed '1,2d')"` plus an inline `--meta
'<long JSON>'`. That breaks easily: under zsh a variable holding several flags is not
word-split, which broke two Queue 160 launches. An empty extraction also launches a session with
no task unless the supervisor checks the length by hand.

Want: `harnex run ... --context-file PATH [--context-section "HEADING"]`. It sends the file, or
the text after the named heading up to the next heading of the same level, and refuses an empty
result. Add `--meta-file PATH` to read the metadata JSON from a file, refusing invalid JSON
before launch. Record the brief path and a content hash in the started event and the dispatch
row.

## Decisions (owner, 2026-10-20) — ready for autonomous implementation

Build as written. No open choices.

## Resolution

Shipped in 0.18.0 (local install): `--context-file`, `--context-section`,
`--meta-file`; `meta.context_file` / `meta.context_sha256` on the started
event and both dispatch rows. `--tmux` passes the file by path. Verified live
on a Holm-format brief ("Sent verbatim" marker line).
