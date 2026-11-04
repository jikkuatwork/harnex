---
status: open
priority: P2
created: 2026-11-04
updated: 2026-11-04
tags: lanes, remote, ssh, mcp, worktree, unattended, orchestration
type: feature
related: 86, 87, 89, 90, 94, 95
---

# Issue 97 — Remote host lanes: run lanes on a cloud VM, land them locally

## Context

Helium (2026-11-04) wants Pi/GPT workers on an on-demand cloud VM (more
cores/RAM/bandwidth, unattended hours) while a local orchestrator — the owner
or Claude through harnex MCP — steers them and pulls results back as a local
worktree. Full process: `~/Projects/helium/koder/plans/38_remote_worker_vm.md`.

Phase 1 needs no harnex change: harnex runs on the VM and the orchestrator
drives it with `ssh HOST harnex …`, and git over ssh moves the base and the
lane branch. That loses what makes lanes good locally: MCP progress, one
`lanes` view, `land`/`discard` doing the git work, owner-scoped `result`.

## Ask

Lane verbs can target a configured remote host, and remote lanes look and
land like local ones.

## Design sketch

1. **Hosts registry** (user-level, not repo): `~/.config/harnex/hosts.json`
   `{"hvm-helium": {"ssh": "hvm-helium", "root": "~/work/{repo}"}}`; `harnex
   host add|list|rm`. `{repo}` = local repo dir name unless overridden.
2. **`--on HOST`** for `ask`, `delegate`, `result`, `reply`, `lanes`, `land`,
   `discard`, `pane`, `doctor` (not `--host`: `run --host` is the API bind
   address). MCP tools gain a `host` arg; the `gpt` agent a `host:` header.
3. **Exact base:** `delegate --on` first pushes local `HEAD` to
   `refs/harnex/base/NAME` on the host, then runs the remote delegate with a
   new `--base REF` so the worktree starts from the orchestrator's commit
   (unpushed local commits included). Remote repos use
   `receive.denyCurrentBranch updateInstead`.
4. **Proxying:** each verb runs `ssh HOST env HARNEX_OWNER=<owner> harnex
   <verb> --json …` and renders locally. Owner passes through so `result`
   with no NAME still means "my lanes". No long-held ssh: `result --on`
   polls `lanes --json` / `result NAME --json` and reconnects, so a dropped
   connection never loses a lane (worker keeps running in the host's tmux).
5. **Shadow records:** local lane record with `host`, remote name, base sha;
   `lanes` merges local + reachable hosts (host column; unreachable hosts
   shown, not dropped). Cost and usage copied from the remote result.
6. **Return:**
   - `harnex fetch NAME` (new): fetch `harnex/NAME` from the host into a local
     worktree (honours `lanes.worktree_path`/`lanes.branch`, #90) for review.
   - `harnex land NAME` on a remote lane: fetch (if needed) → local merge →
     remote `discard` → drop the shadow. Conflicts behave as local land.
   - `harnex discard NAME --on`: remote discard + local cleanup.
7. **Parity and preflight:** `harnex doctor --on HOST` checks harnex/pi
   versions match local (every release ships immediately, so drift is
   likely), the Pi provider key is present, and the repo root exists.
8. **Host init (later, Phase 3):** `harnex host init HOST` — install
   ruby/node via mise, pi and harnex at the local versions, sync pi config
   from a given path, write a provider key file (mode 600). Cloud
   provisioning stays out of harnex (cloma owns Azure).

## Why #95 matters more here

Remote lanes are unattended by design; the orchestrator may be offline for
hours. A mechanical per-lane wall cap (#95) should land before or with this.

## Out of scope

- Provisioning or destroying cloud machines.
- Syncing uncommitted local changes (base is a commit).
- Remote Claude/OpenCode workers (Pi only, per owner direction).
- Multi-host scheduling or host pools.

## Acceptance

- [ ] `harnex delegate --on hvm-x --worktree a "…"` starts a remote lane from
      the local HEAD (verified sha), visible in local `harnex lanes`.
- [ ] MCP `delegate`/`result`/`reply`/`land` with `host` work from Claude Code,
      with progress notifications during `result`.
- [ ] Killing the ssh connection mid-`result` loses nothing; re-running
      `result` collects the reply.
- [ ] `harnex fetch a` gives a local worktree on `harnex/a`; `harnex land a`
      merges locally and removes the remote worktree and branch.
- [ ] `harnex doctor --on hvm-x` reports version drift.
- [ ] Docs: TECHNICAL.md *Remote hosts* section; skill + `gpt` agent notes.
