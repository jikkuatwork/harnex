---
status: open
priority: P2
created: 2026-10-25
updated: 2026-10-25
tags: lanes, send, relay, gpt-agent, orchestration
type: bug
related: 86, 87
---

# Issue 92 — Messages sent straight to a lane are invisible to the session orchestrating it

Seen in Holm (harnex 0.29.1), 2026-10-24 ~23:26 +04.

1. A Claude session (the orchestrator) delegated a review lane through the `gpt` agent.
2. While it ran, the owner sent the worker two messages directly from another terminal (`send`
   events in `harnex events --id …`). They redirected where the report should be written.
3. The worker obeyed, finished, then answered the owner's last message. The relay returned only
   that last answer ("Understood …") to the orchestrator, not the task's report and not the fact
   that someone else had interjected.
4. The orchestrator saw a missing output file and a reply about instructions it never sent, and
   briefly suspected a prompt injection from the subject repository. Only
   `harnex events --id <lane>` showed the truth.

Ask:
- `result` and the relay include a short "interjections" block in the footer: who sent messages
  outside the orchestrating owner, when, and their text.
- The lane's final report covers the original task's outcome, not only the last turn's answer.
- Optionally a flag that rejects direct `send` to a lane owned by another session, unless forced.
