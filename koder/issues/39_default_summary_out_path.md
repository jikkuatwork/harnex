# #39 — `default_summary_out_path` returns legacy `koder/DISPATCH.jsonl`

**Status:** landed
**Priority:** P2
**Filed:** 2026-05-09

## Why

`Harnex.default_summary_out_path` falls back to
`<repo>/koder/DISPATCH.jsonl` whenever a `koder/` directory exists at
the repo root. The canonical path has been
`<repo>/.harnex/dispatch.jsonl` since Holm commit `271c2fd1`
(2026-05-08), which archived the old `koder/DISPATCH.jsonl` and
declared `.harnex/dispatch.jsonl` the sole live ledger. README.md
already documents the canonical path; only the runtime default is
stale.

Holm hit this on dispatch `cx-278-impl` (2026-05-09): the entry
written to `.harnex/dispatch.jsonl` carried
`summary_out_path: ".../koder/DISPATCH.jsonl"`, and a stray
`koder/DISPATCH.jsonl` file reappeared in the working tree despite
the May-8 archival. The actual durable ledger is fine; the metadata
pointer and the stray file are the regression.

Same-day dispatch `cx-medialab-esm` recorded the correct
`.harnex/dispatch.jsonl` path, so the bug is "default fallback when
`--summary-out` is unset" rather than a hard-coded path everywhere.

## Repro

From any repo whose root contains a `koder/` directory and no explicit
`--summary-out`:

```text
harnex run codex --id cx-foo -- echo hi
  -> writes summary row with
     summary_out_path: "<repo>/koder/DISPATCH.jsonl"
  -> creates "<repo>/koder/DISPATCH.jsonl" if it does not already exist
```

Expected:

```text
harnex run codex --id cx-foo -- echo hi
  -> writes summary row with
     summary_out_path: "<repo>/.harnex/dispatch.jsonl"
  -> creates "<repo>/.harnex/" if missing, appends to dispatch.jsonl
  -> never touches koder/DISPATCH.jsonl
```

## Root Cause

`lib/harnex/core.rb:87-91`:

```ruby
def default_summary_out_path(repo_root)
  koder_dir = File.join(repo_root.to_s, "koder")
  return nil unless File.directory?(koder_dir)

  File.join(koder_dir, "DISPATCH.jsonl")
end
```

Predates the May-8 `.harnex/dispatch.jsonl` migration. Single
caller: `lib/harnex/commands/run.rb:574`
(`resolve_summary_out` → returns this default when `--summary-out`
is not configured).

## Fix

1. Change `default_summary_out_path` to return
   `File.join(repo_root.to_s, ".harnex", "dispatch.jsonl")` when
   `repo_root` is non-nil/non-empty. No `koder/` directory check;
   harnex owns the `.harnex/` namespace.
2. Return `nil` only when `repo_root` itself is nil/empty (preserve
   the "no repo, no default" behaviour).
3. Ensure the writer that appends to `summary_out` creates the
   `.harnex/` directory if it does not yet exist (mkdir_p on first
   write). Audit the existing append site; add mkdir_p there if
   missing.
4. Update unit tests that pin the legacy default behaviour.
5. No backward-compat shim, no env var to opt back into the old path.

## Done when

- `default_summary_out_path` returns `.harnex/dispatch.jsonl`.
- Smoke dispatch from a repo with only `koder/` (no `.harnex/`)
  creates `<repo>/.harnex/dispatch.jsonl` and never recreates
  `koder/DISPATCH.jsonl`.
- New + updated tests pass; full `bundle exec rake test` green.

## Out of scope

- Cutting a harnex release / bumping the gem version (defer to next
  ≥3-dispatch session per Holm STATE).
- Touching the historical references in `koder/issues/{32,33,35,36}.md`
  and `koder/plans/27_dispatch_telemetry.md`. Those are point-in-time
  artifacts.
- Renaming the file (`DISPATCH.jsonl` vs `dispatch.jsonl`) outside
  the new default value. README.md already standardises on
  lowercase; preserve that.

## Resolution

Landed 2026-05-09:

- `Harnex.default_summary_out_path` now returns
  `<repo>/.harnex/dispatch.jsonl` for any non-empty repo root,
  independent of `koder/` directory presence.
- `nil` and empty repo roots still return `nil`.
- The existing summary writer already creates the parent directory
  before append; no duplicate mkdir path was added.
- Regression tests cover no-`koder`, legacy-`koder`, nil, empty, and
  `harnex run` default resolution cases.

Verification:

- Red phase: the two new `.harnex` default-path tests failed against
  the legacy implementation.
- Green phase: path-focused tests pass, full suite passes with
  `HARNEX_SKIP_SCHEMA_DRIFT=1`, and a smoke dispatch from a temp repo
  with only `koder/` created `.harnex/dispatch.jsonl` without creating
  `koder/DISPATCH.jsonl`.
