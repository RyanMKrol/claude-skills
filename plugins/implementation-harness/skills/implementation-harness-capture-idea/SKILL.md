---
name: implementation-harness-capture-idea
description: >-
  Use for a quick, zero-ceremony capture of a feature idea, bug report, or improvement into the
  project's ideas inbox — phrases like "note this idea", "add this to the ideas list",
  "capture this for later", "/idea ...". Does NOT interview, decompose, or touch TASKS.json — it
  just appends one bullet to .harness/tracking/IDEAS.md (a committed inbox) for a later
  implementation-harness-convert-ideas sweep. Requires the implementation harness to already be
  scaffolded (.harness/docs/HARNESS.md present).
argument-hint: "<idea description>"
allowed-tools: Read, Write, Edit, Bash, Glob
---

# Capture an idea (zero-ceremony, rich)

Append ONE numbered bullet to `.harness/tracking/IDEAS.md` — no interview, no decomposition, no
`TASKS.json` edit, no clarifying questions. This must never derail the task at hand: it's a quick
side-append, no back-and-forth. But "zero-ceremony" means **no scoping/decisions**, NOT "terse" —
capture the idea RICHLY (step 4): the context you have in front of you right now is cheap to record,
and the later `implementation-harness-convert-ideas` sweep runs COLD and would otherwise have to
re-excavate all of it (or bug the user for it).

## Steps

1. **Require the harness.** `.harness/docs/HARNESS.md` must exist. If missing, stop and tell the
   user to run `/implementation-harness-create` first.
2. **Ensure the inbox exists.** If `.harness/tracking/IDEAS.md` doesn't exist yet, create it with a
   `## Inbox` header. This file is committed (it travels with the repo), so a converted idea's bullet
   is removed by `implementation-harness-convert-ideas` once it becomes a `TASKS.json` task.
3. **Determine the next number.** The highest existing `N.` bullet under `## Inbox`, plus one
   (start at 1 if the inbox is empty). Numbers are LOCAL to the current inbox contents, not a
   permanent ledger — once an idea is converted its bullet is removed by
   `implementation-harness-convert-ideas`, and that number is never reused within the current
   inbox's remaining lifetime, but a fresh empty inbox restarts at 1.
4. **Capture as much as you can — richly.** Append `N. <idea text>`: the full substance of what the
   user described, in their meaning, PLUS any context you ALREADY have that helps understand it later
   — relevant code anchors (`path:line`), the root cause, related tasks/ideas, and *why it matters*.
   **There is no length limit — a long, detailed bullet is good.** The ONE thing you must NOT do is
   *resolve* the idea: no scoping, no acceptance criteria, no design decisions, no choosing between
   options, no inventing requirements the user didn't imply — and **never ask clarifying questions**.
   Enrich ONLY from what you already know (you're usually mid-task in the relevant code, so it's cheap
   now). In short: capture everything that helps *understand* the idea; defer everything that
   *decides* it — that's conversion's job, done in a batch across the whole inbox.
5. **Confirm briefly.** "Captured as idea #N." Nothing else.

## What this is NOT

- **Not an interview.** Don't ask the user follow-up questions here — that's
  `implementation-harness-convert-ideas`'s job, run later, across the whole inbox at once.
- **Not a `TASKS.json` write.** This skill never touches the backlog, never assigns facets, never
  creates a `tasks/TNNN.md` spec.
- **Not deduplication.** If a similar idea already exists in the inbox, capture this one anyway —
  the convert sweep dedupes before doing any real work (see that skill's §1).
