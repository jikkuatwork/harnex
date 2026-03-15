---
id: 10
title: "Inbox management — list, drop, clear, and TTL for queued messages"
status: open
priority: P2
created: 2026-03-15
---

# Issue 10: Inbox Management

## Problem

When a queued message gets stuck (e.g., adapter never transitions to `prompt`
state), there's no way to inspect, remove, or expire it. The message sits in
the inbox forever, and if the adapter eventually delivers it, the context is
stale — the sender has already retried with `--force` or moved on.

Observed during chain-implement v2: a message queued to `cx-159` never
delivered because the Codex adapter stayed in `unknown` state despite the
prompt being visible. The supervisor force-sent a duplicate, leaving the
original stale message still pending.

## Desired Behavior

### 1. Inbox inspection

```bash
harnex inbox --id cx-159
```

List pending messages with ID, queued_at timestamp, and truncated text preview.

### 2. Selective drop

```bash
harnex inbox drop --id cx-159 --message-id <id>
```

Remove a specific pending message without delivering it.

### 3. Flush all

```bash
harnex inbox clear --id cx-159
```

Drop all pending messages. Useful after a force-send recovery.

### 4. TTL auto-expiry

Messages older than a configurable TTL (default: 60s) are automatically
discarded from the inbox. A stale prompt from minutes ago is almost certainly
wrong context — the sender has moved on.

Configurable via `--inbox-ttl` on `harnex run` or `HARNEX_INBOX_TTL` env var.

## Priority

P2 — workaround exists (`--force` to bypass queue), but stale messages
accumulating silently is a footgun for automated workflows.
