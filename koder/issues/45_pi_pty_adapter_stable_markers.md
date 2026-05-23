---
status: open
priority: P2
---

# Issue 45 — Deferred Pi PTY adapter with stable extension markers

**Status**: open
**Priority**: P2
**Filed**: 2026-05-23
**Tier**: C (research -> plan later)
**Sister**: follows #44 (Pi RPC adapter). Related to harnex's existing PTY adapters for Codex/Claude/OpenCode.

## Problem

Pi has a rich interactive TUI that is useful for visible work in tmux. harnex can wrap unknown CLIs through the generic PTY adapter, but Pi's TUI does not expose a simple stable prompt token in terminal snapshots. Pure screen scraping would be brittle.

The recommended first-class integration is Pi RPC (#44). PTY support should be deferred and designed around Pi's extension system, where we can add stable harnex-visible markers instead of reverse-engineering the TUI.

## Goal

Add a visible Pi PTY mode later, suitable for tmux-inspectable sessions, using a small Pi extension to make state detection reliable.

Potential future surface:

```bash
harnex run pi --pty --tmux cx-i-pi-visible --context "..."
```

Exact flag naming should wait for the post-freeze `--legacy-pty` / structured-vs-PTY naming cleanup.

## Proposed direction

Use a Pi extension loaded by harnex (or documented for users to install) that emits stable markers via supported extension APIs:

- session start marker
- idle/prompt marker
- busy/streaming marker
- completion marker
- error marker
- optional session ID / session file marker

Candidate APIs from Pi extension docs:

- `pi.on("agent_start")`
- `pi.on("agent_end")`
- `pi.on("turn_start")`
- `pi.on("turn_end")`
- `ctx.ui.setStatus(...)`
- `ctx.ui.setWidget(...)`
- `ctx.ui.setTitle(...)`
- `pi.sendMessage(...)` for visible custom messages if needed

The adapter should then parse those explicit markers rather than infer readiness from TUI layout, colors, borders, or footer text.

## Acceptance criteria

- A visible `harnex run pi ... --tmux` session can be inspected live by the operator.
- harnex can reliably determine prompt/busy/completed state from explicit markers.
- `harnex send` only injects at safe prompt points unless forced.
- The marker extension does not disrupt normal Pi UX.
- Marker protocol is documented and versioned enough that future Pi UI changes do not break harnex.
- Tests cover marker parsing independently of real terminal rendering.

## Out of scope

- Pi RPC support. Tracked in #44 and should land first.
- Generic Pi TUI scraping without extension markers.
- Full RPC extension UI mediation.

## Triage

- **Tier**: C
- **Plan count**: 1 later, after #44 ships
- **Estimated sessions**: 1
- **Estimated wall-clock**: ~2–4h after marker design is settled

## Notes

Do not start this by adding regexes for Pi's current TUI footer. The project already has enough evidence that structured/marker-based integration is more durable.
