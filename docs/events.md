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

## 8. Layer 5: dispatch telemetry

Layer 5 adds dispatch telemetry events without changing schema version `1`.
The additions are optional for legacy consumers: existing event types keep
their fields, and new event types can be ignored by readers that do not need
telemetry.

New optional fields on existing event types:

- `started.meta` (Object, optional): parsed verbatim from `harnex run --meta`.
  It is absent when `--meta` is not provided.
- `exited.reason` (String, optional): one of `success`, `failure`, `timeout`,
  or `disconnected`.

New event types:

- `usage`: emitted once after the wrapped process exits and before `exited`.
  It includes nullable `input_tokens`, `output_tokens`, `reasoning_tokens`,
  `cached_tokens`, `total_tokens`, and `agent_session_id`.
- `git`: emitted when git metadata is available. `phase: "start"` includes
  `sha` and `branch`; `phase: "end"` includes `sha`, `loc_added`,
  `loc_removed`, `files_changed`, and `commits`.
- `summary`: emitted last before `exited`. It includes `path` (String or
  `null`) and `exit` (`success`, `failure`, `timeout`, or `disconnected`).

Example telemetry sequence:

```json
{"schema_version":1,"seq":1,"ts":"2026-05-01T11:30:00Z","id":"cx-i-372","type":"started","pid":12345,"meta":{"issue":"23","plan":"27","predicted":{"input_tokens":[200000,800000]}}}
{"schema_version":1,"seq":2,"ts":"2026-05-01T11:30:00Z","id":"cx-i-372","type":"git","phase":"start","sha":"a8114695c1f0","branch":"main"}
{"schema_version":1,"seq":3,"ts":"2026-05-01T11:42:13Z","id":"cx-i-372","type":"usage","input_tokens":104158,"output_tokens":2709,"reasoning_tokens":870,"cached_tokens":250880,"total_tokens":106867,"agent_session_id":"019ddf05-0f03-7d70-904f-23db7f00640f"}
{"schema_version":1,"seq":4,"ts":"2026-05-01T11:42:13Z","id":"cx-i-372","type":"git","phase":"end","sha":"abc1234567","loc_added":312,"loc_removed":65,"files_changed":7,"commits":1}
{"schema_version":1,"seq":5,"ts":"2026-05-01T11:42:13Z","id":"cx-i-372","type":"summary","path":"/home/u/proj/koder/DISPATCH.jsonl","exit":"success"}
{"schema_version":1,"seq":6,"ts":"2026-05-01T11:42:13Z","id":"cx-i-372","type":"exited","code":0,"reason":"success"}
```
