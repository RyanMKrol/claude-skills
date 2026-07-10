---
name: implementation-harness-report-issue
description: >-
  Use when the user wants to report a bug or problem with the implementation-harness PLUGIN itself —
  phrases like "report a bug", "file an issue", "something's wrong with the harness", "the loop is
  broken / crashing", "report this upstream", "/report-issue". Captures the current session context,
  auto-detects the environment (plugin version, loop variant, bash/OS, tool presence), pushes the user
  for logs / terminal output, scrubs secrets, does a quick real-bug-vs-misconfiguration plausibility
  check, shows the FULL draft, and only on explicit confirmation files a GitHub issue on the plugin's
  home repo (RyanMKrol/claude-skills) via `gh`. Works with OR without a scaffolded `.harness/`. NOT for
  the user's own project backlog (use capture-idea / add-to-backlog) — this reports the harness itself.
allowed-tools: Read, Bash, Glob, Grep, AskUserQuestion, Write
---

# Report an issue with the implementation-harness plugin

You help the user file a **high-signal bug report about the implementation-harness plugin itself** — the
loop, the scripts, the dashboard, the skills — as a **GitHub issue on the plugin's home repo**, so the
maintainer can see it and choose to act. You do the work a good reporter can't: auto-detect the
environment, synthesise what happened this session, push for the logs, scrub secrets, sanity-check that
it's a real bug, and post only what the user has seen and approved.

Think of the output as one of the maintainer's own "proposal" write-ups, but generated from this session.

## Constants (do NOT infer these from the user's project)

- **Report repo:** `RyanMKrol/claude-skills` — the plugin's marketplace home. Always file here. Never
  file to the user's own project remote (that's their repo, not the plugin's).
- **Label:** `implementation-harness` (best-effort — see step 8; external reporters can't add labels, so
  the title also carries a `[harness]` marker for filterability).

## Scope guard — is this the right skill?

This is for a problem with the **harness/plugin**. If the user actually wants to:
- capture a feature idea for **their own project** → that's `capture-idea` / `add-to-backlog`;
- log a bug in **their own product's** backlog → that's `add-to-backlog`;

…say so and point them there instead. Only proceed here when the subject is the harness itself
(a script crash, wrong loop behaviour, a dashboard defect, a skill misbehaving, a doc error, etc.).

## Step 0 — early `gh` heads-up (non-blocking)

Run `command -v gh` and `gh auth status`. If either fails, tell the user now that filing needs
`gh` installed and authed (`brew install gh && gh auth login`) — but **keep going and build the draft
anyway** so nothing is lost; at post time (step 9) you'll save it to a file if `gh` still isn't ready.

## Step 1 — auto-capture the environment (no reporter effort)

Gather what a reporter usually doesn't know to include. Look for a scaffolded harness from the current
directory (`.harness/`); if there isn't one, say so and capture what you still can (this skill must work
when reporting a `create` failure too). Collect, tolerating any missing piece:

- **Plugin version:** contents of `.harness/.harness-version` (or "no scaffolded harness").
- **Loop variant:** the `# harness-loop-variant:` header of `.harness/scripts/loop.sh` (worktree | in-place).
- **Shell/OS:** `bash --version | head -1`, `uname -srm`.
- **Tooling:** presence + version of `gh`, `jq`, `node`, `git` (a bash < 4.4 / missing-jq environment is
  itself the cause of real bugs — always include this).
- **Git state:** `git rev-parse --short HEAD` and a dirty/clean flag (`git status --porcelain | wc -l` —
  the COUNT only, never the contents/paths).
- **Config:** `.harness/config/harness.env` if present — but mask values (step 5), it can hold hook
  commands with secrets.

Keep this as a compact "Environment" block.

## Step 2 — synthesise the session

From YOUR context of this conversation, write a short, factual narrative: what the user was doing, the
exact error/symptom that surfaced, and what has already been tried or ruled out. Quote the real error
text where you have it. This is a synthesis of the session, not a raw transcript dump.

## Step 3 — interview the user (push hard for logs)

The loop runs in a **real terminal outside Claude Code**, so you cannot see its scrollback — the reporter
must supply it. Ask for, and make it easy to paste:

1. **The symptom in their words** — what went wrong, what they expected instead.
2. **The terminal / loop output** — "paste the FULL output around the failure: the `supervise.sh` /
   `loop.sh` lines, any stack trace, `.harness/worklog/.claude-out.*` tails — more is better, don't
   trim." Take everything they give.
3. **Reproduction** — the exact command(s) run and whether it's reliably reproducible.
4. **Anything else** they think matters.

If a harness is present, also OFFER to attach the current task's worklog tail and the last few
`ledgers/outcomes.jsonl` / `failures.jsonl` rows (read them, show what you'd include, let them trim).

## Step 4 — plausibility check (informs, NEVER blocks)

Do a quick assessment from everything gathered: **is this a genuine harness bug, or a
misconfiguration / environment gap / expected behaviour?** Where cheap, sanity-check it (e.g. re-read
the cited script line, confirm a version, reproduce a one-liner). Then:

- If it reads as a **real bug** → say so briefly and include that verdict in the report.
- If it looks like a **misconfig / user error** → surface the likely fix FIRST and ask, via
  `AskUserQuestion`, whether they still want to file it. It stays their call — never refuse to file.

Put your verdict (bug | likely-misconfig | unsure) and one line of reasoning INTO the report so the
maintainer isn't re-deriving it.

## Step 5 — scrub secrets (mandatory)

Before assembling, scan EVERYTHING (auto-captured + pasted logs + env) and mask anything secret. Be
conservative — when unsure, mask. Cover at least:

- token/key shapes: `sk-…`, `ghp_…`/`github_pat_…`, `AKIA…`, `xox[baprs]-…`, `Bearer <token>`,
  `-----BEGIN … PRIVATE KEY-----` blocks, long hex/base64 blobs that look like credentials;
- `KEY=value` / `PASSWORD=` / `TOKEN=` / `SECRET=` assignments (mask the value);
- in `harness.env`, mask the VALUE of any hook knob (`INTEGRATE_HOOK`, `VISUAL_VERIFY_HOOK`, …) and any
  value matching the above;
- the harness's own sensitive-path sense: `.env`, `data/`, `*.pem`/`*.key`/`*.p12`, `credentials.json`,
  `service-account*` (mirror `SENSITIVE_RE` / `.harness/custom/sensitive-paths.txt` if present).

Replace each with `‹redacted›`. The human confirmation in step 9 is the final backstop — but do the
automated pass first so they aren't relying on catching everything by eye.

## Step 6 — assemble the issue

Title: concise, prefixed for filterability — e.g. `[harness] loop crash-loops on effort-less rung (bash 3.2)`.

Body (Markdown), mirroring the maintainer's proposal style:

```
**Reported via** `/implementation-harness-report-issue`

## TL;DR
<one-paragraph summary of the problem>

## Environment
<the step-1 block: plugin version, loop variant, bash/OS, tool versions, git state>

## Symptom
<what went wrong; expected vs actual>

## Reproduction
<commands + reliability>

## Logs / terminal output
```
<the pasted, SCRUBBED output>
```

## What happened this session
<the step-2 synthesis>

## Plausibility
<bug | likely-misconfig | unsure> — <one line of reasoning>

## Severity (reporter's sense)
<low | medium | high> — <why>
```

## Step 7 — dedup

Run `gh issue list --repo RyanMKrol/claude-skills --search "<key terms>" --state all --limit 10` and
scan for an existing match. If one looks like the same problem, show it and ask (via `AskUserQuestion`)
whether to **add a comment** to that issue instead of opening a new one, or file fresh anyway.

## Step 8 — show the FULL draft and get explicit confirmation (mandatory gate)

Print the **entire** title + body exactly as it will be posted. Remind the user that
`RyanMKrol/claude-skills` is **public** and filing publishes this irreversibly (indexed even if later
deleted). Then use `AskUserQuestion` — "File this issue / Let me edit it first / Don't file" — and only
proceed on an explicit yes. If they want edits, revise and re-show the full draft before asking again.

## Step 9 — file it (gh required)

Re-check `gh` (`command -v gh` && `gh auth status`). 

- **If `gh` is ready:** write the body to a temp file and run
  `gh issue create --repo RyanMKrol/claude-skills --title "<title>" --body-file <tmp> --label implementation-harness`.
  If it fails **only** because the label can't be applied (external reporters lack triage rights), retry
  the exact command **without** `--label` (the `[harness]` title prefix keeps it filterable). Report the
  resulting issue URL back to the user.
- **If `gh` is NOT ready:** do not silently drop the work — write the finished title+body to
  `./harness-issue-draft.md` (tell them the path), and give the remediation
  (`brew install gh && gh auth login`, then re-run this skill or `gh issue create --repo RyanMKrol/claude-skills --title … --body-file harness-issue-draft.md`).

## Notes

- This skill also serves the maintainer as a one-command replacement for hand-writing proposal artifacts.
- It never writes to the user's project or the harness backlog — its only external effect is the GitHub
  issue it creates (with consent) on the plugin's own repo, plus (fallback) a local draft file.
