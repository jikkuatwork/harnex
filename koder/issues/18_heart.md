---
status: open
priority: P0
created: 2026-04-18
tags: core,design,llm
---

# Issue 018: `harnex heart` — Persistent Presence for Stateless Agents

## The Problem

AI agents like Claude Code are stateless and reactive — invoked, respond, exit. They have no
persistent presence. When a multi-step pipeline runs overnight, the only thing keeping it alive
is a shell script or a human checking in. Both fail.

On 2026-04-18, an overnight automation script died silently because one bad exit code killed
everything — after training had already succeeded. The machine stayed up, the state was all
there, but nothing was driving the process forward. The pipeline hadn't lost information; it had
lost **continuous presence**.

## The Insight

Heart is not a pipeline orchestrator. It's a **heartbeat monitor for running harnex sessions**.

It watches a running agent (via tmux pane + structured logs), uses an LLM to understand what's
happening, and nudges the agent when it stalls or breaks. Like a human checking in — but
reliable and tireless.

The user's workflow: "do this overnight, involve heart so you won't die."

## Design

### Core Loop

```
harnex heart <session-id> [--llm azure/gpt-5.4]
```

1. Read the tmux pane (via existing `harnex pane` internals)
2. Read the tail of the session's JSONL log (structured breadcrumbs)
3. Send both to an LLM: "is this session stalled? does it need a nudge?"
4. If yes, compose and send a message via `harnex send`
5. Sleep, repeat

Heart is itself short-lived per iteration — it can be cron'd or run as a loop.

### Existing Harnex Primitives Used

- Tmux pane capture + follow mode (`harnex pane`)
- Session state machine (prompt/busy/blocked detection)
- Message injection (`harnex send`)
- File watching with inotify + auto-delivery
- Per-session HTTP API
- Adapter-based screen parsing

Heart adds the **intelligent monitoring layer** on top of these.

### JSONL Log Convention

The watched agent writes breadcrumbs to `<repo>/logs/NN_label.jsonl` — one JSON object per
line, append-only. This gives heart structured context alongside the raw pane text.

```jsonl
{"ts":"2026-04-18T05:06:41+05:30","event":"step.started","step":"train","detail":"launching azure job"}
{"ts":"2026-04-18T05:09:00+05:30","event":"step.progress","step":"train","detail":"job running, 3m elapsed"}
{"ts":"2026-04-18T07:42:00+05:30","event":"step.succeeded","step":"train","detail":"training complete"}
```

No rigid schema — heart's LLM reads these as context, not as structured state.

### LLM Integration

#### Provider flag

```
--llm azure/gpt-5.4
```

Format: `provider/model`. Parsed and routed to the matching provider class. Today only
`azure/*` is implemented; the flag does nothing beyond routing, but ensures future providers
(openai, anthropic, ollama) slot in by adding one file.

#### Configuration

```yaml
# ~/.config/harnex/config.yml
heart:
  llm: azure/gpt-5.4
  azure:
    api_key: sk-...
    endpoint: https://your-resource.openai.azure.com/...
```

**Resolution order:**
1. **Environment variables** override everything — `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`
2. **`~/.config/harnex/config.yml`** — persistent defaults
3. **CLI flags** — `--llm azure/gpt-5.4` overrides config file's `llm` value

Standard env var names only — no custom `HEART_*` vars.

#### Architecture

One abstract interface, one concrete implementation:

```
lib/harnex/heart/
  llm/
    base.rb           # chat(messages) -> String — the only method
    azure_openai.rb   # Net::HTTP to Azure OpenAI
```

- `Base#chat(messages)` — takes an array of `{role:, content:}`, returns the response string
- `AzureOpenai` — reads from config.yml, env vars override
- No SDK — just `Net::HTTP` (harnex is stdlib-only)

Adding a second provider later = add a sibling file, no refactoring.

### What Heart Is NOT

- Not a pipeline engine or step runner
- Not managing state.json / step types / retry policies
- Not project-specific — works with any harnex session

### What Heart IS

- A thin, intelligent monitor that gives Claude the one thing it lacks: persistent presence
- Project-agnostic: any session can say "involve heart" and get watched
- Transparent: reads pane + logs, reasons about state, nudges when needed
- LLM-powered: understands context, doesn't just pattern-match

## Acceptance Criteria

- [ ] `harnex heart <session-id>` monitors a running session
- [ ] Reads tmux pane via existing harnex internals
- [ ] Reads JSONL log tail for structured context
- [ ] Sends pane + log context to LLM for assessment
- [ ] Sends nudge via `harnex send` when LLM detects a stall
- [ ] `--llm provider/model` flag parsed and routed (azure/* implemented)
- [ ] Config from `~/.config/harnex/config.yml`, env vars override
- [ ] No external gem dependencies (Net::HTTP only)
- [ ] Idempotent — safe to run repeatedly or via cron

## Open Questions

- **Nudge content**: Should the LLM compose the nudge message, or should heart have
  templates ("continue where you left off", "the last step failed, retry")?
- **Log discovery**: How does heart find the right JSONL file? Convention (glob `logs/*.jsonl`),
  explicit flag, or registered in harnex session metadata?
- **Polling interval**: Fixed (e.g., 60s), configurable, or adaptive based on LLM assessment?
- **CLAUDE.md integration**: Should we document heart in global CLAUDE.md so any agent knows
  how to write breadcrumbs and request heart monitoring?

## Origin

Born from MoMa (modern-mallu) Issue 006 — an overnight training pipeline that died silently.
Originally scoped as a standalone tool (`~/Projects/heart`), refined to a harnex feature since
harnex already owns session orchestration, pane monitoring, and message delivery.
