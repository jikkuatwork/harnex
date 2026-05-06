---
status: open
priority: P1
created: 2026-05-06
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

- [ ] See what harnex does: PTY harness for terminal AI agents.
- [ ] Discover that there is deeper guidance for agents specifically.
- [ ] Read the dispatch, chain, buddy, and monitoring patterns.
- [ ] Find naming conventions, monitoring patterns, and recipe usage.

## Status

Open. Resolve when the CLI surface, packaged guide files, tests, local gem
build/install verification, and `v0.6.1` tag are complete.
