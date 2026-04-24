# Review: Plan 21D — Cross-Reference Audit

**Verdict:** Approve with minor tightening.

The plan is well-scoped, the dependency gate on A/B is stated explicitly, and
the findings matrix plus concrete edit list give the executor actionable work.
Below are the requested dimensions and a few issues worth fixing before
execution.

## Findings matrix structure — concrete?

**Yes, sufficient.** The matrix names:
- mechanic (12 rows, covering dispatch lifecycle, chain orchestration, buddy
  loop),
- single canonical owner per row,
- the referencing skills expected to link (not duplicate),
- editable `Audit status` / `Evidence` columns.

Strengths:
- Each mechanic has exactly one owner — no split ownership, which is the
  failure mode this plan exists to prevent.
- Coverage spans all three final skills; I cannot think of a catalogued
  mechanic the matrix misses.

Gaps / suggestions:
- Row 8 ("Parallel-within-chain rules + 5 concurrent cap") lists
  `harnex-dispatch` as an optional referencer "only if referencing chain
  mode". That hedge weakens the contract — either dispatch references it or
  it doesn't. Recommend removing the conditional and stating "no reference
  from dispatch" as the default, since the 5-cap is pure chain policy.
- Several rows use "(if X)" / "(optional)" qualifiers (rows 4, 6, 8, 10).
  An audit contract should be binary. Recommend: for each row, decide now
  whether the referencing skill must link or must not, and drop the
  conditionals.
- `Evidence` column is undefined — specify format (e.g., "file:line of the
  canonical section + file:line of each reference"). Otherwise reviewers
  won't know what "filled in" looks like.

## De-dup edit list — actionable?

**Mostly yes.** The per-file bullet lists tell the executor what to keep,
remove, and replace-with-pointer. Replacement pointer wording is given
verbatim ("Use Fire & Watch from `harnex-dispatch`."), which is good.

Issues:
- "Remove deep lifecycle restatements" in `harnex-chain` lists categories
  (spawn/watch/stop walkthroughs, poll table, stop discipline) but does not
  name the current sections/headings. Executor will have to hunt. Either
  add a grep-anchored locator or accept that the rg command in Phase 1 is
  how they'll find them — in which case, state that explicitly.
- No edit bullet covers the case where a mechanic is **missing** from its
  canonical owner (e.g., if post-A/B `harnex-dispatch` doesn't actually
  spell out the poll cadence table any more). Add: "If canonical owner
  lacks the mechanic, move the normative prose there before trimming
  referencers."
- "Keep buddy mention concise" in dispatch is subjective. Define concise
  as "≤2 lines, skill-name pointer only, no prompt examples."

## Post-A/B execution gate — explicit?

**Yes, clearly.** The Preconditions section is hard-gated with a checkbox
list and an explicit "If any gate fails, stop and resume Unit D after A/B
merge." That is as explicit as it gets. The header also repeats
"Execution order: Run last".

Minor: "the audit branch contains the final post-A/B versions" is slightly
ambiguous — does it mean A/B merged to main, or the D branch rebased onto
A/B? Clarify (likely "A/B merged to main, D branched from main after").

## Acceptance criteria — testable?

Phase 4 checklist:
- "Exactly three harnex skills remain" — testable (`ls skills/harnex*`).
- "Every matrix mechanic has one canonical owner" — testable via the
  matrix itself once filled in.
- "Non-owner skills reference canonical mechanics by skill name" —
  testable via grep for literal skill names around each mechanic.
- "No large duplicated prose blocks" — **not testable as written.** Define
  "large" (e.g., ">3 consecutive lines of normative prose repeated across
  files" or "no duplicated code fences / command examples"). Without a
  threshold this is a judgment call that will re-open in review.
- "Unit D acceptance in issue #21 is satisfied" — delegates testability to
  that issue; assumed fine if issue #21 Unit D is itself testable.

## Other notes

- Phase headers use `## Phase N` at the same level as top-level sections;
  since they sit under "Audit procedure", they should be `### Phase N` for
  correct nesting. Cosmetic.
- The rg pattern in Phase 1 is useful but includes `buddy` as a bare word,
  which will match every paragraph mentioning buddy. Consider anchoring
  (`\bbuddy\b` with word boundaries or more specific tokens like
  `harnex-buddy`).
- Consider adding an explicit "no runtime code changes" check to Phase 4
  since the Scope says so but acceptance doesn't verify it. A `git diff
  --stat` restricted to `skills/` would do it.

## Required changes before execution

1. Remove conditional qualifiers in matrix referencer column — make each
   cell binary.
2. Define `Evidence` column format.
3. Define "large duplicated prose" threshold in acceptance.
4. Clarify the "audit branch" language in Preconditions.

## Optional

- Fix phase heading levels.
- Tighten the rg pattern.
- Add the "if canonical owner lacks the mechanic, move it first" edit rule.
