# Plan 25: Phase Presets for `harnex run --watch` (Layer 3 of #22)

Issue: #22 (Layer 3)  
Date: 2026-04-29  
Status: plan-write

## Goal

Add `--preset impl|plan|gate` to `harnex run --watch` so dispatch callers can
pick safe defaults for stall handling without hand-tuning every run.

This layer is strictly preset resolution + validation. Layer 2 watch loop
behavior is assumed to already exist.

## Scope Guardrails

- In scope:
  - `--preset` flag on `harnex run` (only meaningful with `--watch`)
  - mapping preset name -> default `--stall-after` + `--max-resumes`
  - precedence: explicit flags win over preset values
  - CLI/help text + tests for the behavior above
- Out of scope:
  - watcher loop internals
  - new event types or disconnect detection
  - new preset names beyond `impl|plan|gate`

## Preset Table (Canonical)

| Preset | `--stall-after` | `--max-resumes` |
|---|---:|---:|
| `impl` | `8m` | `1` |
| `plan` | `3m` | `2` |
| `gate` | `15m` | `0` |

## Exact File Inventory (Layer 3 only)

### New file

- `lib/harnex/commands/watch_presets.rb` (~20 LoC)
  - Recommendation: place the preset table here (not inline in `run.rb`).
  - Reason: keeps mapping data isolated/testable and avoids further growth of
    `run.rb`, which already owns substantial option parsing logic.

### Existing files

- `lib/harnex/commands/run.rb` (~20-30 LoC)
  - parse `--preset NAME` / `--preset=NAME`
  - validate `--preset` requires `--watch`
  - validate preset name and render valid-name list on failure
  - merge preset defaults with explicit flags (explicit flags win)
  - update `usage` text to document precedence and available presets
- `lib/harnex.rb` (~1 LoC)
  - require `harnex/commands/watch_presets`
- `test/harnex/commands/run_test.rb` (~40-55 LoC)
  - preset resolution and validation tests

## CLI Behavior Contract

1. `--preset` is accepted only when `--watch` is present.
2. `--preset` without `--watch` is an error:
   - message: `harnex run: --preset requires --watch`
   - justification: avoids silently accepting an inert flag and preserves clear
     operator intent.
3. Unknown preset name is an error:
   - message includes invalid value and valid names
   - example: `harnex run: unknown --preset "foo" (valid: impl, plan, gate)`
4. Explicit `--stall-after` and/or `--max-resumes` values always override the
   selected preset defaults.

## Precedence / Resolution Rules

Resolution order at runtime:

1. Start from Layer 2 watch options as parsed from explicit CLI flags.
2. If `--preset` is provided, load preset defaults from
   `Harnex::WatchPresets::TABLE`.
3. Fill only missing watch fields from preset defaults.
4. Preserve explicit values already provided by the caller.

Equivalent precedence statement:

`explicit watch flags` > `preset defaults` > `Layer 2 internal defaults`

## Implementation Steps

1. Add `Harnex::WatchPresets` constant table in
   `lib/harnex/commands/watch_presets.rb`.
2. Wire `--preset` parsing in `Runner#extract_wrapper_options`.
3. Add post-parse validation in `Runner#run` (or a dedicated validator):
   - reject `--preset` without `--watch`
   - reject unknown preset names with canonical valid list
4. Apply preset defaults during watch config assembly with explicit-flag
   precedence.
5. Update `Runner.usage` to include:
   - `--preset impl|plan|gate`
   - one-line precedence note (`explicit flags override preset`)
6. Add/adjust unit tests in `test/harnex/commands/run_test.rb`.

## Tests (minimum required)

1. Preset resolution:
   - `impl`, `plan`, `gate` each resolve to expected
     `stall_after`/`max_resumes`.
2. Override semantics:
   - with `--preset impl --stall-after 20m`, resolved `stall_after` is `20m`
     while `max_resumes` remains preset-derived (`1`) unless explicitly set.
3. Unknown preset:
   - invalid name fails with clear error listing valid presets.

Recommended additional guard:

4. `--preset` without `--watch` fails with `--preset requires --watch`.

## Verification

- `ruby -Ilib -Itest test/harnex/commands/run_test.rb`
- Optional confidence pass:
  - `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Acceptance Checklist (Layer 3)

- [ ] `harnex run` supports `--preset impl|plan|gate` when `--watch` is used
- [ ] preset table exactly matches Layer 3 mapping values
- [ ] explicit `--stall-after` / `--max-resumes` override preset values
- [ ] `--preset` without `--watch` errors clearly
- [ ] unknown preset names error clearly with valid-name list
- [ ] help text documents preset names and precedence
- [ ] run command tests cover preset resolution, overrides, and invalid input

## Open Questions

None.
