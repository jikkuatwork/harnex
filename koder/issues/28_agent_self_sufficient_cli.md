---
status: resolved
priority: P1
created: 2026-05-06
resolved: 2026-05-06
closed_in: harnex-0.6.1
tags: cli,docs,agents,dispatch,release
---

# Issue 28: Make harnex agent-discoverable from the CLI alone

## Summary

Agents told only to "use the ruby gem harnex to dispatch work" should be able
to discover harnex from the installed CLI alone. The implementation brief is
`koder/scratch/02_from_holm.md`: remove the bundled skill installer, migrate
the harnex dispatch/chain/buddy guidance into CLI-readable agent guides, and
ship the result as harnex 0.6.1.

## Acceptance Test

Open a fresh shell. Pretend you've never heard of harnex. Type:

```bash
gem install harnex
harnex
```

From the CLI alone, with no external docs, no skills installed, and no
installation hint:

- [x] See what harnex does: PTY harness for terminal AI agents.
- [x] Discover that there is deeper guidance for agents specifically.
- [x] Read the dispatch, chain, buddy, and monitoring patterns.
- [x] Find naming conventions, monitoring patterns, and recipe usage.

## Status

Resolved for harnex 0.6.1. The CLI exposes `harnex agents-guide [topic]`,
top-level and per-command help point agents to the guide surface, the old
skills installer and bundled skill files are removed, and the release was
verified with the full test suite plus local gem build/install smoke tests.
