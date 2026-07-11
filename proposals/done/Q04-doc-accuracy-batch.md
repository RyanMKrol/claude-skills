# Q04: Doc-accuracy batch — four small falsehoods that reach builders and owners

**Type**: skill-quality (batch — lands as ONE commit, all prose/comment fixes) · **Priority**: P1 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (build prompt text), `templates/docs/HARNESS.md` §8.1, `templates/skills/implementation-harness-add-to-backlog/SKILL.md`, `templates/config/harness.env`, `implementation-harness-pre-loop-checkin/SKILL.md`, `implementation-harness-review-failed/SKILL.md`
**Release**: PATCH bump · MIGRATIONS entry (mechanism, incl. both loop variants — the prompt string) · checksums · parity for the prompt string

## 1. The DoD section reference is wrong — in the builder's own prompt

The Definition of Done is HARNESS.md **§5**; §6 is "Sequential, single-flight". But the build
prompt in BOTH loop variants says "DEFINITION OF DONE (.harness/docs/HARNESS.md **§6** …", and the
same §6 citation appears in HARNESS.md §8.1 (the `status` row and the `spec` row: "the universal
bar in §6 is not repeated") and in add-to-backlog §2.3 ("that lives once in HARNESS §6"). Every
cold builder is pointed at the wrong section by its own prompt.
**Fix**: correct all to §5. Grep both variants + all skills + HARNESS.md for `§6`/`section 6` and
adjudicate each hit (some §6 references may legitimately mean single-flight). Mirror the prompt
edit across variants.

## 2. `MAX_ATTEMPTS`'s comment describes pre-ladder behavior

`templates/config/harness.env`: "Soft failures per task before the loop stops and asks a human."
Since the global ladder shipped it's soft failures **per RUNG before escalating**; only top-rung
exhaustion blocks to a human. An owner tuning from the comment mis-models by ~5× (2 attempts × 5
rungs = 10 attempts before a human sees anything).
**Fix**: rewrite the comment: "Soft failures per RUNG before escalating to the next ladder tier;
a task blocks for a human only after exhausting the TOP rung. Loop.sh's own default comment is
already correct — mirror its wording." This is a comment in a CONFIG file — the upgrade reconciles
config additively and won't rewrite the user's copy; the MIGRATIONS entry should note it under
manual attention ("existing installs: update the MAX_ATTEMPTS comment by hand if you care").

## 3. pre-loop-checkin's final report says "checks a–e" but defines a–f

Check (f) (expectsTest-without-test-authoring) was added to §4 but the final-report bullet still
enumerates a–e. Also the two (e)-class WARN severities (file-mention advisory = GO-with-a-note vs
unsupported-glob = firm NO-GO) are flattened in the verdict list after being carefully
distinguished in the body.
**Fix**: report bullet says a–f; the verdict section names the two (e) classes separately,
matching the body's severities.

## 4. review-failed teaches a phantom `ideaBullets` field

Stage 2 step 3's "already resolved"/"not worth pursuing" JSON shapes include `"ideaBullets": []` —
a relic of the pre-JSONL IDEAS era; `consolidate-ideas.mjs` reads only `ideaIds`. Harmless but it
teaches agents a schema field that doesn't exist.
**Fix**: delete the field from both shapes (the step-4 authored shape is already correct).

## Acceptance criteria

- `grep -rn '§6' templates/ | grep -i 'done\|DoD'` → no hits; the build prompt cites §5 in both
  variants (print-prompt test still green; parity test green).
- harness.env comment matches the ladder reality; MIGRATIONS manual-attention note present.
- checkin report internally consistent (a–f; two (e) severities distinct).
- No `ideaBullets` anywhere under templates/.
