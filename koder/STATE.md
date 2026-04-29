# Harnex State

Updated: 2026-04-30

## Current snapshot

- `lib/harnex.rb` is a 21-line loader.
- Code is split into separate files:
  - `lib/harnex/core.rb` — constants, env helpers, registry, port allocation
  - `lib/harnex/watcher.rb` + `watcher/{inotify,polling}.rb` — file watching (inotify on Linux, polling fallback on macOS/other)
  - `lib/harnex/adapters.rb` + `adapters/{base,generic,codex,claude}.rb`
  - `lib/harnex/runtime/{session_state,message,inbox,session,file_change_hook,api_server}.rb`
  - `lib/harnex/commands/{run,send,wait,stop,status,logs,pane,recipes,guide,skills}.rb`
  - `lib/harnex/cli.rb`
- Test suite: `test/` with 216 minitest tests, all passing.
- CLI entrypoint is `bin/harnex` (unchanged).
- Command/API redesign is implemented: generic adapter fallback, binary
  validation, random session IDs, `--description`, `stop`, `status --json`,
  and the renamed `send` flags are all live.
- Issue docs `01`, `02`, `03`, and `05` now match the implemented command and
  status surface.
- `harnex send --wait-for-idle` makes send+wait atomic: sends the message,
  polls until the agent transitions prompt→busy→prompt, and returns a single
  JSON result. Eliminates the `sleep 5` workaround in orchestration workflows.
  Uses a 30s fence timeout for instant-response agents and reuses `--timeout`
  for the full lifecycle.
- `harnex run` rejects duplicate session IDs — fails fast with a clear error
  if the ID is already active on the same repo.
- New CLI commands for documentation and onboarding:
  - `harnex guide` — prints GUIDE.md (getting started walkthrough)
  - `harnex recipes` — lists and shows workflow recipes (fire-and-watch,
    chain-implement)
  - `harnex skills install [SKILL]` — installs any bundled repo skill into
    `.claude/skills/` and symlinks `.codex/skills/` to it
- Bundled skill install is now generalized beyond `harnex`: `open` and `close`
  can be installed repo-locally with `harnex skills install <skill>` while
  `harnex` remains the default for backwards compatibility.
- Bundled session lifecycle skills now include `open` for session initialization
  (read `koder/STATE.md`, inspect the worktree, align on the next step) and
  `close` for session wrap-up (update `koder/STATE.md`, clean up artifacts,
  leave a clear handoff).
- Project-local skill symlinks added for `open` and `close`: `.claude/skills/`
  for Claude Code, `.agents/skills/` for Codex.
- README rewritten for non-users (quick "is this for me?" format). Usage
  details moved to GUIDE.md, command reference stays in TECHNICAL.md.
- README, GUIDE, and recipe docs now present **fire-and-watch** as the primary
  workflow: fresh worker per step, file handoffs between steps, Codex for
  planning/implementation/fixes, Claude for reviews.
- README documents buddy pattern with concrete examples (stall monitor, doc
  drift monitor) and the `$HARNEX_SPAWNER_PANE` non-harnex invoker pattern.
- GUIDE.md updated: `harnex skills install` replaces manual symlinks, buddy
  recipe listed, `$HARNEX_SPAWNER_PANE` return channel documented.
- `recipes/` directory with tested workflow patterns:
  - `01_fire_and_watch` — atomic unit: spawn, send, pane poll, capture
  - `02_chain_implement` — batch implement→review→fix loop
- Output streaming phases 1-2 are in place: every session writes a repo-keyed
  transcript file at `~/.local/state/harnex/output/<repo>--<id>.log`, exposed
  as `output_log_path` in status payloads and detached `run` responses, and
  `harnex logs` can snapshot the last N lines or `--follow` appended output
  without depending on the session HTTP API.
- Exit status records now preserve signal metadata as `signal` alongside the
  synthesized numeric `exit_code` for signaled sessions, with regression tests
  covering zero-exit and signaled-exit persistence.
- File watching is now cross-platform: inotify on Linux, stat-polling fallback
  on macOS and other platforms. Zero external dependencies maintained.
- OSC escape sequence stripping fixed: greedy regex was consuming entire
  screen buffers when multiple OSC sequences were present, breaking state
  detection for both Codex and Claude adapters.
- Layer A (multi-agent reliability) is implemented:
  - `harnex stop` now uses a 75ms delay between exit text and submit in
    Claude/Codex adapters, matching the `build_send_payload` pattern.
  - `harnex send` default timeout raised from 30s to 120s for fresh sessions.
  - Claude adapter detects vim normal mode (`NORMAL`/`--NORMAL--`) as a
    sendable state (`vim-normal`, `input_ready: true`).
  - Inbox has TTL auto-expiry (default 120s), `pending_messages`, `drop`,
    `clear` methods, and API endpoints (`GET /inbox`, `DELETE /inbox`,
    `DELETE /inbox/:id`). Configurable via `--inbox-ttl` or `HARNEX_INBOX_TTL`.
- Issue #11 is now implemented: `harnex pane --id <session>` captures a clean
  tmux screen snapshot for live sessions, supports `--lines`/`--json`/`--follow`,
  and fails clearly when `tmux` is unavailable or the session is not tmux-backed.
  `--follow` refreshes the screen at a configurable interval until the session
  exits, effectively solving the supervisor monitoring use case and making the
  output streaming HTTP API (issue #04 phase 3) low priority.
- Issue #14 is now fixed: `harnex pane` no longer assumes the harnex session ID
  is a valid tmux target. Tmux-backed launches annotate the registry with
  `tmux_target` / `tmux_session` / `tmux_window`, pane lookup falls back to
  discovering the live tmux pane by session PID for older sessions, and `pane`
  can resolve a unique matching session across repo roots when invoked from the
  wrong worktree.
- `tmux_pane_for_pid` now walks the process tree via `/proc/<pid>/stat` when
  no direct PID match is found, fixing the common case where the registry
  stores the agent PID (PTY child) but tmux reports the inner harnex process
  PID (the agent's ancestor).
- `harnex status` now always shows a truncated REPO column (20 chars, tail-
  truncated with `..` prefix), giving context without requiring `--all`.
- Installable skills namespaced as `harnex-dispatch`, `harnex-chain`,
  `harnex-buddy`. Install via `harnex skills install`.
- `harnex skills install` auto-removes deprecated skill names (`dispatch`,
  `chain-implement`) during install. `harnex skills uninstall` removes all
  installed skills.
- New buddy recipe (`recipes/03_buddy.md`): spawn an accountability partner
  for long-running sessions. The buddy polls `harnex pane`/`harnex status` and
  nudges stalled workers via `harnex send`.
- `$HARNEX_SPAWNER_PANE` env var: every spawned session receives the invoker's
  stable tmux pane ID (`$TMUX_PANE`), enabling the return channel to non-harnex
  invokers via `tmux send-keys`.
- `harnex skills install` defaults to global install (`~/.claude/skills/`,
  `~/.codex/skills/`). Use `--local` for repo-local installs. Global install
  copies files (not symlinks) so skills survive gem updates.
- Codex adapter now latches `@banner_seen` on first detection, so state
  detection survives stream disconnects that push the banner out of the
  40-line window. Previously this caused `unknown` state and 120s send
  timeouts requiring `--force` to work around.
- `normalized_screen_text` now preserves multi-byte UTF-8 characters from
  BINARY PTY buffers (force_encoding + scrub instead of encode) and converts
  column-1 cursor positioning (`\e[N;1H`) to newlines. Fixes Codex prompt
  detection for TUIs that draw via cursor addressing rather than newlines.
- Issue #21 (skill catalogue cohesion) fully implemented in v0.3.4:
  - Unit A (`0ed37c5`): `harnex` skill collapsed into `harnex-dispatch`;
    installer aliases `harnex`/`dispatch`/`chain-implement` -> canonical names;
    cross-refs cleaned in CLAUDE.md/TECHNICAL.md (AGENTS.md/CODEX.md are
    symlinks).
  - Unit B (`a95771c`): `harnex-chain` rewritten with Orchestrator Role and
    Parallel Variant (global 5-concurrent Codex cap, worktrees only on
    explicit request); stop-on-commit rule added to `harnex-dispatch` #3-stop.
  - Unit D (`34a09a8`): cross-reference audit across the 3 remaining skills;
    every mechanic has one canonical owner, non-owners reference by name; no
    duplicated prose block larger than 3 lines / 1 paragraph.
- Issue #22 (built-in dispatch monitoring) is now tracked by layered plans:
  `koder/plans/22_mapping.md` (mapping), `koder/plans/23_log_mtime.md`
  (Layer 1), `koder/plans/24_watch.md` (Layer 2), and
  `koder/plans/25_presets.md` (Layer 3).
- Layer 2 is now implemented: `harnex run --watch` starts a blocking
  babysitter loop (foreground-only), uses live `agent_state` + `log_idle_s`,
  sends bounded forced `resume` nudges, and exits with watcher-specific
  status codes (`0` exited, `2` escalated, `1` operational error).
- `run` now preserves file-hook compatibility while adding babysitter mode:
  - bare `--watch` enables babysitter
  - `--watch PATH` / `--watch=PATH` still configure legacy file-hook
  - `--watch-file PATH` is the canonical file-hook flag

## What harnex does

Harnex is a local PTY harness for interactive terminal agents.

- `harnex run` launches a wrapped agent session under a PTY, starts a
  localhost control API, and writes repo-scoped session metadata to the
  local registry.
- `harnex send` resolves a target session, applies relay headers when one
  harnex-managed session talks to another, and sends input through the
  local API.
- `harnex stop` sends the adapter-appropriate stop sequence to a session.
- `harnex status` reads the registry and live status endpoints, with table
  or JSON output.
- `harnex logs` reads the persisted transcript for a live or exited session,
  with last-N snapshot output and polling `--follow` mode.
- `harnex pane` reads the current tmux pane for a live session and prints a
  clean screen snapshot, optionally limited to the last N lines or wrapped in
  JSON metadata. `--follow` refreshes the snapshot at a configurable interval
  until the session exits.
- `harnex wait` blocks until a session exits or reaches a target state
  (`--until prompt`).
- `harnex guide` prints the getting started guide.
- `harnex recipes` lists and shows workflow recipes.
- `harnex skills install [SKILL...]` installs bundled skills into a repo for
  Claude/Codex (accepts multiple names; defaults to `harnex`).
- Adapter logic owns CLI-specific launch args, prompt detection, submit
  behavior, stop sequence, and send-readiness waiting.
- Session output is mirrored to the terminal, stored in a 64KB ring buffer for
  prompt detection, and appended to a repo-keyed transcript file for later
  access.

## Issues

| # | Title | Status | Priority |
|---|-------|--------|----------|
| 01 | Clean stop primitive | **fixed** | P1 |
| 02 | Wait-until-prompt mode | **fixed** | P1 |
| 03 | API & command design audit | **fixed** | P1 |
| 04 | Output streaming | open | P3 |
| 05 | Inbox fast-path deadlock | **fixed** | P1 |
| 06 | Full adapter abstraction | open | P2 |
| 07 | `stop` types exit but doesn't submit | **fixed** | P1 |
| 08 | Send to fresh Codex times out | **fixed** | P2 |
| 09 | Claude vim mode not detected | **fixed** | P2 |
| 10 | Inbox management (list/drop/TTL) | **fixed** | P2 |
| 11 | Tmux pane capture | **fixed** | P3 |
| 12 | State detection failures cause send/receive problems | **fixed** | P1 |
| 19 | Codex banner scroll-out breaks state detection | **fixed** | P1 |
| 13 | Atomic `send --wait-for-idle` | **fixed** | P1 |
| 14 | Pane lookup fails for worktree/custom tmux sessions | **fixed** | P2 |
| 15 | Auto-stop session on task completion | open | P2 |
| 16 | Platform-agnostic data directory (~/.harnex/) | open | P2 |
| 17 | Multi-session coordination | open | P2 |
| 18 | Buddy pattern — accountability partner for long-running sessions | open | P2 |
| 20 | `--tmux` greedily consumes next flag as window name | **fixed** | P1 |
| 21 | Skill catalogue cohesion | **fixed** | P2 |
| 22 | Built-in dispatch monitoring | **fixed** | P2 |

See `koder/issues/` for details.

## Plans

| # | Title | Status |
|---|-------|--------|
| 01 | Monolith refactor | **done** (phases 1-2) |
| 02 | Command & API redesign | **done** |
| 03 | Output streaming | **in progress** (phases 1-2 done) |
| 04 | Stop submit fix (#07) | **done** |
| 05 | Send startup timeout (#08) | **done** |
| 06 | Claude vim mode (#09) | **done** |
| 07 | Inbox management (#10) | **done** |
| 08 | Pane capture (#11) | **done** |
| 09 | Atomic send --wait-for-idle (#13) | **done** |
| 21a | Collapse `harnex` into `harnex-dispatch` (#21 Unit A) | **done** |
| 21b | Rewrite `harnex-chain` (#21 Unit B) | **done** |
| 21d | Cross-reference audit (#21 Unit D) | **done** |
| 23 | Log-mtime activity tracking (#22 Layer 1) | **done** |
| 24 | Blocking `run --watch` babysitter (#22 Layer 2) | **done** |
| 25 | Phase presets for `run --watch` (#22 Layer 3) | **done** |
| 26 | `harnex events` JSONL stream (#22 Layer 4) | **done** |

Plans 04-08 are **layer A** (multi-agent reliability).
Plan 09 is **layer B** (atomic orchestration primitives).

See `koder/plans/` for details.

## Next step

### 2026-04-30: v0.4.0 released — issue #22 fully shipped (layers 1–4)

Pushed `harnex-0.4.0` to RubyGems. Version bump commit `71ad244`.



All four layers of built-in dispatch monitoring landed serially on `main`:

- **Layer 1** (`23_log_mtime.md`, commit `31bf7b5`) — `log_mtime` and
  `log_idle_s` exposed in status payload + `IDLE` column in text mode.
- **Layer 2** (`24_watch.md`, commit `7e511a8`) — `harnex run --watch
  --stall-after --max-resumes` blocking babysitter; legacy `--watch PATH`
  file-hook preserved via `--watch-file` rename.
- **Layer 3** (`25_presets.md`, commit `21c1517`) — `--preset
  impl|plan|gate` resolves stall/resume defaults; explicit flags override.
- **Layer 4** (`26_events.md`, commit `63c37ad`) — `harnex events --id`
  JSONL stream with v1 schema (envelope: `schema_version`, `seq`, `ts`,
  `id`, `type`); emits `started`, `send`, `exited`. `send.msg` truncated
  to 200 chars with `msg_truncated` flag. File transport at
  `~/.local/state/harnex/events/<repo>--<id>.jsonl`. Docs: `docs/events.md`.

Plans, mapping doc, and STATE updates committed on `main`. Full suite
green at HEAD: 235 runs, 666 assertions, 0 failures.

**Layer 5 (deferred):** disconnect-regex detection. File as separate
issue if real-world stalls show disconnect dominates.

**Outstanding (from L4 contract):** Layer 2 watcher does not yet emit
`resume` / `log_active` / `log_idle` events into the JSONL stream. The
contract is documented in `docs/events.md`; retrofit is a small
follow-up (touch `commands/watch.rb` only).

**Next:**
- (optional) bump version + release gem
- Retrofit Layer 2 watcher to emit `resume` / `log_*` events per the
  documented contract
- Test buddy pattern end-to-end with a real long-running dispatch
- Build a third adapter (aider, cursor, etc.) to naturally drive #06

## Confirmed bugs from earlier review (all fixed)

1. ~~`harnex send --port` broken for auth~~ -> added `--token` flag
2. ~~Exit status files keyed only by `id`~~ -> `repo_key--id_key.json`
3. ~~`harnex wait` depends on live registry~~ -> falls back to exit file
4. ~~Registry ID normalization collision~~ -> `id_key` for matching
