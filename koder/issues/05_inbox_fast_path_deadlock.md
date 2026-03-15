# 05 — Inbox fast-path deadlock

**Priority:** P1
**Status:** fixed
**Found:** 2026-03-14

## Description

The original fast path in `Inbox#enqueue` tried to call `deliver_now` while the
inbox mutex was still held. `deliver_now` also takes that mutex, so immediate
delivery could recurse into the same lock and raise `ThreadError`.

## Fix

`lib/harnex/runtime/inbox.rb` now:

- checks the fast-path precondition under lock
- releases the lock before calling `deliver_now`
- falls back to the normal queue path if immediate delivery fails

Regression coverage lives in `test/harnex/runtime/inbox_test.rb`, including the
prompt-ready fast path and the queued-delivery path.

## Result

Immediate delivery works again when the queue is empty and the agent is already
at prompt, without changing the normal queued delivery behavior.
