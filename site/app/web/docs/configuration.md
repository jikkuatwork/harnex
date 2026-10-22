# Repository Configuration

Harnex has one optional repository configuration file:

```text
<git-root>/.harnex/config.json
```

It is resolved with the same git-root rule as the canonical dispatch stream.
Non-git launches use the global dispatch stream and do not invent a global
configuration file. An absent file is valid. An explicitly present malformed
file fails before agent spawn so policy is never silently ignored.

## Phase allowlist

Repositories can normalize queue/work phase names:

```json
{
  "phase": {
    "allowlist": [
      "plan-write",
      "plan-review",
      "plan-fix",
      "test-suite",
      "implement",
      "code-review",
      "code-fix",
      "mapping",
      "triage",
      "docs"
    ],
    "policy": "reject"
  }
}
```

The effective value is the first-class `harnex run --phase TEXT` value, or
`--meta.phase` when no first-class override is supplied.

- No `phase` configuration: any phase passes.
- Allowlisted phase: dispatches silently.
- `policy: "warn"`: prints a warning and dispatches.
- `policy: "reject"`: exits non-zero before spawn and writes no dispatch row.

The allowlist must be an array of non-empty strings. Policy must be `warn` or
`reject`.

## Events, output, and receipt retention

Per-session event JSONL, output transcripts, and generated proof receipts live
under Harnex's local state directory and are not the durable dispatch stream:

```text
~/.local/state/harnex/events/
~/.local/state/harnex/output/
~/.local/state/harnex/receipts/
```

Defaults apply independently to each directory:

- maximum age: 45 days;
- maximum total size: 1 GiB.

Override them in repo configuration:

```json
{
  "retention": {
    "events": {
      "max_age_days": 45,
      "max_bytes": 1073741824
    },
    "output": {
      "max_age_days": 45,
      "max_bytes": 1073741824
    },
    "receipts": {
      "max_age_days": 45,
      "max_bytes": 1073741824
    }
  }
}
```

Environment variables take precedence:

```text
HARNEX_EVENTS_MAX_AGE_DAYS
HARNEX_EVENTS_MAX_BYTES
HARNEX_OUTPUT_MAX_AGE_DAYS
HARNEX_OUTPUT_MAX_BYTES
HARNEX_RECEIPTS_MAX_AGE_DAYS
HARNEX_RECEIPTS_MAX_BYTES
```

Limits must be positive integers. Harnex deletes only regular files directly
owned by the `events`, `output`, and `receipts` directories: expired files first, then the
oldest unprotected files until the size cap is met. It never follows paths
outside those directories. Files for the current session, live registry PIDs,
and alive uncompleted dispatch-start rows are protected. If protected files
alone exceed a cap, Harnex reports the directory over cap rather than deleting
them.

A bounded prune runs opportunistically when a dispatch starts. Inspect or force
the same policy with `doctor`:

```bash
harnex doctor                    # sizes, limits, and last-prune status
harnex doctor --prune --dry-run  # preview bounded candidate paths, do not delete
harnex doctor --prune            # apply now
```

`--dry-run` is valid only with `--prune`. Manual prune bypasses the automatic
cadence but preserves the same live/current safety rules.

Set `HARNEX_STATE_DIR` before launching Harnex when tests or isolated automation
need a disposable local-state root.
