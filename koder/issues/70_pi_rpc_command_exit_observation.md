---
status: open
priority: P2
created: 2026-08-14
updated: 2026-08-14
tags: pi, rpc, receipts, commands, validation, telemetry
type: feature
issue_kind: slice
context: Pi is now a preferred structured adapter, but its receipts cannot attest bash command text or exit status.
---

# Issue 70 — Observe Pi RPC bash commands and exits in receipts

## Problem

Pi RPC is a structured transport and emits `tool_execution_start` /
`tool_execution_end` events, but Harnex currently treats command observation as
Codex-only. Pi dispatch receipts report:

- `observed.command_observation: "unsupported"`;
- `observed.commands: []`;
- `actual.commands_executed: 0`;
- `validation.status: not_run`.

At the same time, the same dispatch records nonzero Pi `tool_calls`, accepted
work, Git changes, and provider usage. This means a blind queue can prove that a
Pi worker changed and committed files, but cannot use Harnex proof to establish
which test/build commands ran or whether they exited successfully.

Current documentation explicitly says non-Codex transports are unsupported, so
this is a missing capability rather than receipt corruption. It matters more now
that Harnex's own guide defaults autonomous chain work to Pi.

## Evidence

External source: Holm Queue `121` on 2026-08-14, Harnex `0.11.0`, Pi `0.84.1`.

Every Pi product phase (`pi-i-828`, `pi-t-829`, `pi-tf-829`, `pi-i-829`) used
bash tools for tests, formatting, Git checks, and commits. Harnex observed many
Pi tool calls and accepted Git deltas, but each canonical receipt had unsupported
command observation and no command exits. The Holm supervisor therefore had to
replay every acceptance command independently; that replay caught no product
failure, but Harnex could not attest the worker's own proof.

Related contracts:

- #44 already consumes Pi `tool_execution_start/end` for activity and output.
- #64 observed-state receipts preserve command text/exits for Codex.
- #68 proposes final-gate semantics, which cannot become adapter-neutral while
  Pi command exits remain unavailable.

## Proposed Direction

For Pi RPC bash-tool calls, correlate `toolCallId` across
`tool_execution_start` and `tool_execution_end` and record a command only when
Harnex has structured evidence for:

- tool name is the built-in bash tool (or another explicitly supported command
  tool);
- bounded command text from structured args;
- integer exit code and completion/error status from the structured result;
- optional duration when deterministically available.

If a Pi/provider/extension tool does not expose an integer exit, keep that call
unsupported or partial rather than inferring from prose. Apply existing receipt
caps/redaction and never persist command output as proof payload.

## Acceptance Criteria

- [ ] A Pi RPC bash success appears in `observed.commands` with bounded command
      text, `exit_code: 0`, and completed status.
- [ ] A Pi RPC bash failure appears with its nonzero integer exit and makes the
      legacy command-history validation status fail as expected.
- [ ] `actual.commands_executed` counts observed Pi bash executions while generic
      read/edit/write tools remain `tool_calls`, not commands.
- [ ] Multiple/concurrent tool calls correlate by `toolCallId` without mixing
      command/result pairs.
- [ ] Missing or malformed exit metadata fails closed to unsupported/partial
      observation; no prose or rendered log scraping.
- [ ] Harness-authored receipts remain within size/redaction bounds, and tests
      cover successful, failed, missing-exit, truncated-command, and non-bash
      Pi tool events.
- [ ] Pi adapter and dispatch-telemetry docs state the new proof semantics and
      their limits.

## Non-Goals

- Replacing supervisor replay for high-risk product acceptance.
- Capturing command stdout/stderr in the receipt.
- Fixing explicit Pi stop lifecycle corruption; tracked in #69.
