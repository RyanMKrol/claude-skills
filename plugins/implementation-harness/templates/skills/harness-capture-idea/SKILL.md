---
name: harness-capture-idea
description: >-
  Use for a quick, zero-ceremony capture of a feature idea, bug report, or improvement into the
  project's ideas inbox — phrases like "note this idea", "add this to the ideas list",
  "capture this for later", "/idea ...". Does NOT interview, decompose, or touch TASKS.json — it
  just appends one JSON row to .harness/tracking/IDEAS.jsonl (a committed inbox) for a later
  harness-convert-ideas sweep. Requires the implementation harness to already be
  scaffolded (.harness/docs/HARNESS.md present).
argument-hint: "<idea description>"
allowed-tools: Read, Write, Edit, Bash, Glob
---

# Capture an idea (zero-ceremony, rich)

Append ONE JSON object, on its own line, to `.harness/tracking/IDEAS.jsonl` (a JSONL file — one idea
per line) — no interview, no decomposition, no `TASKS.json` edit, no clarifying questions. This must
never derail the task at hand: it's a quick side-append, no back-and-forth. But "zero-ceremony" means
**no scoping/decisions**, NOT "terse" — capture the idea RICHLY (step 4): the context you have in
front of you right now is cheap to record, and the later `harness-convert-ideas` sweep
runs COLD and would otherwise have to re-excavate all of it (or bug the user for it).

## Schema

Each line is one JSON object:

```json
{"id": 3, "title": "One-line summary shown in the dashboard's collapsed row", "description": "The full rich capture — as much detail and context as you have.", "capturedAt": "2026-07-07T14:32:00Z"}
```

- `id` — integer. See step 3.
- `title` — a short, one-line summary (a few words to ~10). This is what the dashboard shows
  collapsed, so make it identify the idea at a glance; it is NOT the full capture.
- `description` — the rich body (step 4). No length limit.
- `capturedAt` — ISO-8601 UTC timestamp of when you're capturing it (`date -u +%Y-%m-%dT%H:%M:%SZ`).

## Steps

1. **Require the harness.** `.harness/docs/HARNESS.md` must exist. If missing, stop and tell the
   user to run `implementation-harness:create` first.
2. **Ensure the inbox exists.** If `.harness/tracking/IDEAS.jsonl` doesn't exist yet, create it empty
   (JSONL has no header/comment convention — just start appending lines). This file is committed (it
   travels with the repo), so a converted idea's row is removed by
   `harness-convert-ideas` once it becomes a `TASKS.json` task.
3. **Determine the next id.** Read every line, parse its `id`, take the max (0 if the inbox is
   empty), and use max + 1. Ids are LOCAL to the current inbox contents, not a permanent ledger —
   once an idea is converted its row is removed by `harness-convert-ideas`, and that
   id is never reused within the current inbox's remaining lifetime, but a fresh empty inbox
   restarts at 1.
4. **Capture as much as you can — richly, in `description`.** The full substance of what the user
   described, in their meaning, PLUS any context you ALREADY have that helps understand it later —
   relevant code anchors (`path:line`), the root cause, related tasks/ideas, and *why it matters*.
   **There is no length limit — a long, detailed description is good.** The ONE thing you must NOT do
   is *resolve* the idea: no scoping, no acceptance criteria, no design decisions, no choosing between
   options, no inventing requirements the user didn't imply — and **never ask clarifying questions**.
   Enrich ONLY from what you already know (you're usually mid-task in the relevant code, so it's cheap
   now). Draft `title` as a short label for the same idea — don't let title-writing tempt you into
   resolving or narrowing it. In short: capture everything that helps *understand* the idea; defer
   everything that *decides* it — that's conversion's job, done in a batch across the whole inbox.
5. **Append the line** (e.g. via a small Bash `printf '%s\n' "$(jq -nc --argjson id "$ID" --arg title "$TITLE" --arg description "$DESC" --arg capturedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{id:$id,title:$title,description:$description,capturedAt:$capturedAt}')" >> .harness/tracking/IDEAS.jsonl` — using `jq -nc` to build the JSON guarantees valid escaping regardless of what the description contains).
6. **Confirm briefly.** "Captured as idea #N: <title>." Nothing else.

## What this is NOT

- **Not an interview.** Don't ask the user follow-up questions here — that's
  `harness-convert-ideas`'s job, run later, across the whole inbox at once.
- **Not a `TASKS.json` write.** This skill never touches the backlog, never assigns facets, never
  creates a `tasks/TNNN.md` spec.
- **Not deduplication.** If a similar idea already exists in the inbox, capture this one anyway —
  the convert sweep dedupes before doing any real work (see that skill's §1).
