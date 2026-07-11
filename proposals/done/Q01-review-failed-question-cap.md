# Q01: review-failed must respect the 4-question AskUserQuestion hard cap

**Type**: skill-quality · **Priority**: P1 · **Effort**: S
**Affected files**: `templates/skills/implementation-harness-review-failed/SKILL.md` (Stage 3, the relay instructions)
**Release**: PATCH bump · MIGRATIONS entry (mechanism/skill) · checksums

## Problem

convert-ideas §4 was updated to the platform reality that **a single AskUserQuestion call
hard-caps at 4 questions**, with batching rules (≤4 per call, sequential calls) and the
self-contained-question rule (each question opens with a one-sentence restatement of its subject,
because the relay recap scrolls out of view). review-failed Stage 3 still instructs: "make ONE
AskUserQuestion batching every question from every file" — guaranteed to hit the cap on any sweep
with >4 questions. Since every authored follow-up mandates at least a definition-of-done
confirmation, a 5-task sweep already breaks: the call either fails or silently drops questions —
directly eroding the front-load-clarification principle at its most important site.

## Proposed fix

Back-port convert-ideas §4's relay-question rules into review-failed Stage 3, adapted minimally:

- batch in call-sized groups of ≤4, sequential calls until drained;
- each question self-contained (one-sentence restatement + the task id inline in the question
  text, not only in a header/label);
- keep review-failed's per-task grouping where natural (a task's DoD question + its open question
  in the same call when they fit).

Copy the WORDING from convert-ideas §4 rather than paraphrasing — the point is convergence (and
Q02, the shared relay protocol, will later hoist the common text; if Q02 lands first, this becomes
"point Stage 3 at the shared doc").

## Acceptance criteria

- Stage 3 contains the ≤4 rule, the sequential-batches instruction, and the self-contained
  restatement rule, in language matching convert-ideas §4.
- No remaining instruction says or implies "one call with every question".
- A dry read-through of a hypothetical 6-question sweep against the new text produces 2 calls.
