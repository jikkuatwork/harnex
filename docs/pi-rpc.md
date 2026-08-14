# Pi RPC adapter

Harnex runs Pi workers over Pi's structured subprocess protocol rather than
scraping the TUI:

```text
harnex run pi  ->  pi --mode rpc  ->  LF-delimited JSON objects on stdio
```

Pi RPC is JSONL, not JSON-RPC 2.0. Codex uses `codex app-server` JSON-RPC;
Harnex presents the same run/send/wait/events control surface over both.

## Compatibility

Harnex requires Pi **0.80.4 or newer** for structured dispatch. Pi 0.80.4 added
`agent_settled`, the first lifecycle event that guarantees no automatic retry,
compaction recovery, or queued continuation remains. `agent_end` is only a
low-level run boundary and is never accepted as Harnex work completion.

Check the installed transport before unattended work:

```bash
harnex doctor --adapter pi
```

`harnex run pi` also checks the version before spawn and fails closed when the
version cannot be parsed or predates 0.80.4. The current contract was live
verified against Pi 0.84.1.

Pi 0.84.0 removed cumulative message snapshots from `message_update`. Harnex
therefore assembles output from `assistantMessageEvent` deltas between
`message_start` and authoritative `message_end` events. This remains compatible
with Pi 0.80.4-0.83.x and avoids printing the final message twice on 0.84+.

## Dispatch

```bash
harnex run pi --id cx-i-42 --tmux cx-i-42 \
  --context "Implement issue 42 and run tests" --auto-stop

harnex wait --id cx-i-42 --until task_complete --timeout 3600
harnex events --id cx-i-42
```

`--context` is sent as an RPC `prompt` command; it is not passed as a Pi
positional argument.

Harnex model and effort flags are active controls, not telemetry-only labels:

```bash
harnex run pi \
  --model anthropic/claude-sonnet-4-5 --effort high \
  --context "Review the change" --auto-stop
```

Harnex maps those controls to Pi `--model` / `--thinking` startup flags, then
verifies the effective values with RPC `get_state` before prompting. This avoids
`set_model` / `set_thinking_level` persisting a dispatch override into the
user's Pi defaults. Use `provider/model` for deterministic dispatch. Harnex
fails before the prompt if Pi cannot apply the requested model or thinking level
exactly, so requested and effective policy cannot silently diverge. Direct
adapter callers can still use Pi's RPC setters for an intentional mid-session
switch.

Pass Pi startup flags after `--`:

```bash
harnex run pi --context "Implement X" --auto-stop -- \
  --no-session --no-extensions --model anthropic/claude-sonnet-4-5
```

When both Harnex `--model` and a Pi child `--model` are supplied, the Harnex
startup override is appended last and is authoritative for that dispatch.

## Project trust

Pi 0.79 added project trust. RPC mode cannot show the interactive trust prompt;
an unresolved project follows Pi's global `defaultProjectTrust` policy. Harnex
does not auto-trust repository code.

For deterministic unattended runs, choose explicitly after reviewing the
repository:

```bash
# Load trusted project-local .pi settings, packages, and extensions
harnex run pi --context "..." -- --approve

# Ignore project-local executable resources
harnex run pi --context "..." -- --no-approve
```

Context files continue to follow Pi's documented trust behavior. Third-party or
project extensions execute with the worker's OS privileges; `--approve` is a
security decision, not merely a prompt-suppression flag.

## Lifecycle and failures

Harnex maps Pi events as follows:

| Pi event | Harnex behavior |
|---|---|
| `agent_start`, `turn_start` | busy |
| `agent_end` | remain busy; capture outcome/stats, but do not complete |
| retry/compaction events | remain busy and emit structured telemetry |
| `agent_settled` + final `stopReason=stop` | emit `task_complete` |
| `agent_settled` + `error`, `aborted`, or `length` | emit `task_failed` |
| `agent_settled` without an authoritative final stop reason | fail closed |
| EOF, malformed JSON, or request timeout | disconnect/failure |

A forced send while Pi is busy is translated to a `prompt` with
`streamingBehavior="steer"`; ordinary sends wait for the settled prompt state.
This avoids sending a plain prompt that current Pi correctly rejects while
streaming.

RPC requests are bounded, stderr is continuously drained into a bounded
diagnostic tail, and Harnex consumes Open3's wait thread so the real subprocess
exit status is not lost to a competing `waitpid`.

## Telemetry

At settlement and teardown, Harnex reads `get_session_stats` and records:

- input/output/cache/total tokens and provider-reported cost;
- tool-call count;
- Pi session ID;
- effective provider and model;
- terminal and peak active-context usage.

Message/tool/retry/compaction events are available through `harnex events`.
Blocking extension dialogs (`select`, `confirm`, `input`, `editor`) are
currently auto-cancelled so autonomous workers cannot hang. Full extension UI
mediation is not implemented.

## Boundaries

- The structured adapter does not embed Pi's TypeScript SDK.
- `--tmux` displays Harnex's synthesized RPC transcript, not Pi's native TUI.
- First-class native Pi TUI/PTTY markers remain tracked in Issue `#45`.
- Durable Pi session recovery is separate from lifecycle correctness and remains
  part of the broader structured-recovery work.

## Verification

Hermetic tests cover lifecycle settlement, retry boundaries, failure stop
reasons, delta-only message streaming, model/effort RPC controls, request
timeouts, and telemetry. The opt-in live contract test is:

```bash
PI_INTEGRATION=1 ruby -Ilib -Itest \
  test/harnex/adapters/pi_integration_test.rb
```
