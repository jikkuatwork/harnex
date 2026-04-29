# `harnex events` (v1)

## 1. Purpose and non-goals

`harnex events` provides a per-session JSONL stream for orchestration and
monitoring tooling.

This layer is transport + contract only. It does not implement watcher policy
or preset logic.

## 2. CLI usage

```text
harnex events --id ID [--repo PATH] [--cli CLI] [--from ISO8601]
harnex events --id ID --snapshot
```

- `--id ID` is required.
- `--follow` is enabled by default.
- `--snapshot` is non-blocking (`--no-follow` alias behavior).
- `--from` accepts ISO-8601 only (`ts >= from` replay filter).

Follow mode exits `0` when the target session emits `type: "exited"`.

## 3. Transport and file location

Events are append-only JSONL rows at:

```text
~/.local/state/harnex/events/<repo_key>--<id_key>.jsonl
```

Writers append one event per line and flush after each append.
Readers can snapshot + tail the same file.

## 4. v1 schema reference

Every row includes this envelope:

- `schema_version` (Integer): always `1`
- `seq` (Integer): monotonic per session, starts at `1`
- `ts` (String): UTC ISO-8601 timestamp
- `id` (String): session ID
- `type` (String): event type

Emitted now (Layer 4):

- `started`: adds `pid` (Integer)
- `send`: adds
  - `msg` (String): first 200 characters of the original text; if longer,
    a trailing `…` is appended
  - `msg_truncated` (Boolean): whether truncation occurred
  - `forced` (Boolean): send force mode
- `exited`: adds
  - `code` (Integer): synthesized numeric exit code
  - `signal` (Integer, optional): present for signaled exits

## 5. Stability promise

Schema v1 is additive-only:

- existing fields will not be removed, renamed, or type-changed
- new fields and new event types may be added

Breaking changes require a major schema bump.

## 6. Consumer patterns

Snapshot:

```bash
harnex events --id worker --snapshot
```

Follow:

```bash
harnex events --id worker | jq -c '.'
```

Replay from a timestamp:

```bash
harnex events --id worker --snapshot --from 2026-04-29T10:00:00Z
```

## 7. Layer 2 integration note

Layer 4 defines the bus and schema. In a follow-up layer, watcher-owned
producers can publish `resume`, `log_active`, and `log_idle` events to this
same stream. `harnex events` remains a read-only consumer surface.
