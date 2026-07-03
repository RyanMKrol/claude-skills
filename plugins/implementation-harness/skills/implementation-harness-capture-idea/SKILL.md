---
name: implementation-harness-capture-idea
description: >-
  Use for a quick, zero-ceremony capture of a feature idea, bug report, or improvement into the
  project's private ideas inbox — phrases like "note this idea", "add this to the ideas list",
  "capture this for later", "/idea ...". Does NOT interview, decompose, or touch TASKS.json — it
  just appends one bullet to .harness/tracking/IDEAS.md (gitignored) for a later
  implementation-harness-convert-ideas sweep. Requires the implementation harness to already be
  scaffolded (.harness/docs/HARNESS.md present).
argument-hint: "<idea description>"
allowed-tools: Read, Write, Edit, Bash, Glob
---

# Capture an idea (zero-ceremony)

Append ONE numbered bullet to `.harness/tracking/IDEAS.md` — no interview, no decomposition, no
`TASKS.json` edit. This is deliberately the cheapest possible action so capturing an idea never
interrupts the current conversation or the task at hand.

## Steps

1. **Require the harness.** `.harness/docs/HARNESS.md` must exist. If missing, stop and tell the
   user to run `/implementation-harness-create` first.
2. **Ensure the inbox exists.** If `.harness/tracking/IDEAS.md` doesn't exist yet, create it with a
   `## Inbox` header. This file is gitignored — private captures never leave the machine (they may
   reference confidential context) until a later conversion promotes them into `TASKS.json`.
3. **Determine the next number.** The highest existing `N.` bullet under `## Inbox`, plus one
   (start at 1 if the inbox is empty). Numbers are LOCAL to the current inbox contents, not a
   permanent ledger — once an idea is converted its bullet is removed by
   `implementation-harness-convert-ideas`, and that number is never reused within the current
   inbox's remaining lifetime, but a fresh empty inbox restarts at 1.
4. **Write the idea in the user's own words.** Append `N. <idea text>` — capture what they said
   (plus any concrete, grounded detail you already have on hand: a file/line citation, a root
   cause you just found), but do NOT rephrase it into task language, decompose it, or ask
   clarifying questions. Vague is fine here; clarification happens at CONVERSION time, in a batch,
   not one idea at a time.
5. **Confirm briefly.** "Captured as idea #N." Nothing else.

## What this is NOT

- **Not an interview.** Don't ask the user follow-up questions here — that's
  `implementation-harness-convert-ideas`'s job, run later, across the whole inbox at once.
- **Not a `TASKS.json` write.** This skill never touches the backlog, never assigns facets, never
  creates a `tasks/TNNN.md` spec.
- **Not deduplication.** If a similar idea already exists in the inbox, capture this one anyway —
  the convert sweep dedupes before doing any real work (see that skill's §1).
