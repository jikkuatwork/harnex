# Plan 09: Atomic `send --wait` (#13)

## Goal

Add `--wait` flag to `harnex send` that blocks until the agent completes
the work triggered by the sent message. Eliminates the `sleep 5` race
between `send` and `wait --until prompt`.

## Semantics

```bash
harnex send --id cx-1 --message "implement the plan" --wait --timeout 600
```

1. Send the message (existing send logic)
2. **State fence**: poll `/status` until `agent_state != "prompt"` (confirms
   the agent picked up the message)
3. **Wait for idle**: poll `/status` until `agent_state == "prompt"` again
4. Return JSON: `{"ok":true,"id":"cx-1","state":"prompt","waited_seconds":45.2}`

On timeout (exit code 124):
`{"ok":false,"id":"cx-1","state":"busy","error":"timeout","waited_seconds":600}`

On process exit during wait (exit code 1):
`{"ok":false,"id":"cx-1","state":"exited","waited_seconds":3.1}`

## Design decisions

- **`--wait` reuses `--timeout`**: the existing `--timeout` flag covers the
  entire lifecycle (lookup + send + wait). No separate `--wait-timeout`.
- **State fence approach** (option 1 from issue): poll until not-prompt, then
  poll until prompt. Simple, no registry changes needed.
- **Fence timeout**: if the agent never leaves `prompt` within 30s of send,
  treat it as success (the agent may have processed instantly). This avoids
  hanging forever on very fast responses.
- **Poll interval**: 0.5s, matching `Waiter::POLL_INTERVAL`.
- **The wait logic lives in `Sender`**, not extracted to a shared module. The
  `Waiter` class handles different concerns (exit watching, registry lookup).
  Sharing would over-abstract for now.

## File changes

### `lib/harnex/commands/send.rb`

1. Add `--wait` flag to parser (name: `--wait-for-idle`, option key:
   `:wait_for_idle`, default: `false`). Avoid collision with existing
   `--no-wait` (which controls async delivery polling and uses `:wait` key).
2. After the existing send+delivery logic returns successfully (exit 0),
   if `wait_for_idle` is true, call `wait_for_idle_state(registry, deadline)`.
3. New private method `wait_for_idle_state(registry, deadline)`:
   - Extract host/port/token from registry
   - Phase 1 (fence): poll `/status` every 0.5s until `agent_state != "prompt"`
     or 30s fence timeout or deadline reached
   - Phase 2 (idle): poll `/status` every 0.5s until `agent_state == "prompt"`
     or deadline reached
   - On process death (connection refused after successful send): return exited
   - Return hash with ok/id/state/waited_seconds
4. New private method `fetch_agent_state(host, port, token)` — identical to
   the one in `Waiter`, returns the `agent_state` string or nil.

### `test/harnex/commands/send_test.rb`

Add tests:
- `test_wait_for_idle_flag_parsed` — verify the option is set
- `test_wait_for_idle_full_cycle` — mock send success, then fake server
  returns "busy" twice then "prompt"; verify JSON output and exit 0
- `test_wait_for_idle_timeout` — fake server stays "busy"; verify exit 124
- `test_wait_for_idle_fence_timeout_succeeds` — fake server always returns
  "prompt" (agent was instant); verify exit 0 after fence timeout
- `test_wait_for_idle_process_exit` — connection refused during wait;
  verify exit 1 with state "exited"
- `test_wait_for_idle_not_set_by_default` — verify `:wait_for_idle` is false

### `koder/STATE.md`

- Add issue #13 to the issues table (open, P1)
- Add plan 09 to the plans table (in progress)

## Out of scope

- Monotonic generation counter (option 2 from issue) — unnecessary complexity
- Refactoring `Waiter` to share code — premature abstraction
- Changes to the HTTP API server — the existing `/status` endpoint is sufficient

## Acceptance criteria

- [ ] `harnex send --id X --message "..." --wait --timeout 60` blocks until
      agent returns to prompt after processing
- [ ] Exits 0 with JSON `{ok:true, state:"prompt", waited_seconds:N}`
- [ ] Exits 124 on timeout with JSON `{ok:false, state:"busy", error:"timeout"}`
- [ ] Exits 1 on process death with JSON `{ok:false, state:"exited"}`
- [ ] Fence timeout (30s) prevents hang when agent processes instantly
- [ ] `--wait` without `--wait-for-idle` (the existing flag) is unaffected
- [ ] All new tests pass; existing 163 tests still pass
