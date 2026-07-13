---
name: implementation-harness-customize
description: >-
  Use when the user wants to discover and set up the implementation harness's customization features —
  phrases like "customize the harness", "what can I customize", "set up the hooks / guard / preambles",
  "harness feature walkthrough", "implementation-harness:implementation-harness-customize". Walks the `custom/` extension-point
  catalog one feature at a time: explains each, and for the ones the user wants, activates the opt-in file
  (.example → real) and helps DRAFT its content. Also invoked by create (all features) and upgrade (only
  features new since the install) so users always meet the features. Requires a scaffolded `.harness/`.
argument-hint: "[--since <version> — only walk features newer than it (used by upgrade)]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Customize the harness — feature walkthrough over the `custom/` overlay

You walk the user through the harness's supported customization surface — the `custom/` overlay — one
feature at a time, so nothing has to be discovered by reading source or (worse) by forking `loop.sh`. For
each feature the user wants, you **activate** it (copy its `.example` stub to the real filename) and **help
them draft the content** (interview → write the real file). Everything lives in `.harness/custom/`, which
the harness upgrade **never** overwrites — so customizing this way keeps the install on a clean upgrade
path. Read this whole file, then execute in order.

## 0. Pre-flight

- Require a harness: `.harness/scripts/loop.sh` and `.harness/custom/` must exist. If not, send the user to
  `implementation-harness:implementation-harness-create` (fresh install) and stop.
- **Determine scope** from `$ARGUMENTS`:
  - `--since <version>` (e.g. `--since 1.24.0`) → walk ONLY catalog features whose `since:` is **newer**
    than `<version>` (this is how `upgrade` shows a user just what's new since their install). Compare
    versions numerically (major.minor.patch). If none are newer, say "no new customization features since
    `<version>`" and stop.
  - no argument → walk the **whole** catalog.
- Read the installed version for context: `cat .harness/.harness-version 2>/dev/null`.
- Locate the shipped `.example` stubs — prefer the installed ones under `.harness/custom/`; if one is
  missing (an install predating that feature), fall back to the plugin templates:
  `TPL="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_SKILL_DIR}/../..}/templates"`.

## 1. The customization catalog (canonical — keep this the single source of truth)

Each feature: what it does, the file(s) it lives in, the `since:` version it shipped, and the drafting
interview. **When a new `custom/` extension point is added to the plugin, add a row here** (this catalog is
what `create`/`upgrade`/this skill all walk — see the maintainer `CLAUDE.md`).

1. **Project conventions** — `custom/CLAUDE.md` · since **1.23.0**
   - *What:* extra harness-authoring rules/house-conventions, auto-loaded whenever Claude works inside
     `.harness/` (it's imported by the pristine `.harness/CLAUDE.md`). Always present; you just add content.
   - *Draft:* ask for any project-specific authoring conventions, naming rules, or reminders the builder/
     author should always follow. Append them under a clear heading in `custom/CLAUDE.md`.

2. **Lifecycle hooks** — `custom/hooks/on-<event>.sh` · since **1.24.0**
   - *What:* a script run (child process, non-fatal) at a loop event. Events: `on-drained` (backlog empty /
     idle — e.g. **deploy the product**), `on-blocked` (a task needs a human — e.g. **notify** Slack/email),
     `on-exhausted` (the loop stopped without finishing — MAX_ITERS / rate-limit), `on-integrated` (each task
     landed — task-id + verification as args).
   - *Draft:* ask which events they want. For each, ask for the command/behavior (the deploy command for
     `on-drained`; the notification for `on-blocked`/`on-exhausted`; the per-task action for `on-integrated`).
     Copy `hooks/on-<event>.sh.example` → `hooks/on-<event>.sh` and replace its body with the real command
     (keep it cheap + idempotent — it can fire once per loop cycle). `chmod +x` it.

3. **Secret-guard denylist** — `custom/sensitive-paths.txt` · since **1.24.0**
   - *What:* extra append-only patterns for the pre-push secret guard (can only *tighten* it).
   - *Draft:* ask what additional paths must never be pushed for this project (e.g. `.vercel/`, `.aws/`, a
     data dir). Copy `sensitive-paths.txt.example` → `sensitive-paths.txt`, write one ERE fragment per line.
     Validate with `.harness/scripts/loop.sh --guard-selftest <a-path>` (prints BLOCK/ALLOW).

4. **Visual-verify snippets** — `custom/visual-verify-build.md` / `custom/visual-verify-audit.md` · since **1.27.0**
   - *What:* richer visual-verification guidance, appended to the builder/auditor prompt **for tasks that
     opt into visual verification**. (No effect unless `VISUAL_VERIFY_HOOK` is set + the task opts in.)
   - *Draft:* ask for the exact capture command, a living-fixtures file to keep current, named flows to
     screenshot, and what "renders correctly" means. Copy the matching `.example` → real and write it
     (builder = do-and-record; auditor = adversarial/pass-fail). Populate one or both.

5. **Build/audit preambles** — `custom/build-preamble.md` / `custom/audit-preamble.md` · since **1.28.0**
   - *What:* **standing** project rules injected into **every** builder/auditor prompt (unconditional) — e.g.
     "never make live paid-API calls during verification; use cached fixtures + the scratch DB."
   - *Draft:* ask for always-applies rules every build/audit must respect. Copy the matching `.example` →
     real and write them. Populate one or both.

6. **Dashboard title** — `custom/dashboard-title.txt` · since **1.30.0**
   - *What:* a short project label shown in the dashboard's header and browser tab, so several open
     dashboards (multiple projects, or multiple harness-driven repos) are easy to tell apart at a glance.
   - *Draft:* ask for a short project name/label. Copy `dashboard-title.txt.example` → `dashboard-title.txt`
     and write one line (blank lines and `#`-comments are ignored; the first remaining line wins — keep it
     short, it's the browser tab title too).

7. **Test-file patterns** — `custom/test-file-patterns.txt` · since **1.81.0**
   - *What:* extra patterns for "what counts as a test file", used by the `expectsTest: true` gate and the
     test-file scope-creep exemption. The built-in conventions already cover the common shapes AND CamelCase
     test dirs/files (`UITests/`, `FooTests.swift`, `BarTest.kt`); add lines here only for a convention they
     miss (e.g. Android `androidTest/`, a top-level `e2e/`, `.feature` files). One ERE fragment per line,
     OR-appended to the built-ins (they always stay active; a bad regex is ignored with a WARN).
   - *Draft:* ask whether the project has a test layout the built-ins wouldn't recognize (mainly non-standard
     folder names). If so, copy `test-file-patterns.txt.example` → `test-file-patterns.txt` and write one ERE
     fragment per line. Verify with `.harness/scripts/loop.sh --test-selftest <path>` (prints `TEST`/`NOT-TEST`,
     run from a real terminal — the loop refuses to run inside a Claude session).

> Also note (not a `custom/` file): the `INTEGRATE_HOOK` and `VISUAL_VERIFY_HOOK` commands live in
> `config/harness.env` and are normally set during `create`'s interview. Mention them if relevant, but this
> walkthrough is about the `custom/` overlay.

## 2. Walk the in-scope features, one at a time

For each in-scope catalog feature, in catalog order:

1. **Explain** it in a sentence or two — what it does and when it's worth setting up (use the *What* above).
2. **Ask** with `AskUserQuestion` whether to set it up now (options like: *Set it up* / *Skip* / *Tell me
   more*). Batch nothing — one feature at a time keeps it legible; the user can skip fast.
3. **On "set it up":** run that feature's *Draft* interview, then **activate + write**:
   - Copy the `.example` to the real filename if the real file doesn't exist yet (never clobber an existing
     real file — if it exists, offer to append/edit instead).
   - Replace the stub body with the drafted content; confirm what you wrote back to the user.
   - `chmod +x` any `hooks/*.sh`.
4. **On "skip":** leave the `.example` in place (they can run
   `implementation-harness:implementation-harness-customize` again any time) and move on.

Never edit a plugin-owned file outside `custom/` to achieve any of this — the whole point is that these
live in the overlay and survive upgrades.

## 3. Wrap up

- Summarize what got set up (and what was skipped, so they know it's still available).
- Remind them: everything you wrote is under `.harness/custom/` and is **never touched by
  `implementation-harness:implementation-harness-upgrade`**; re-run
  `implementation-harness:implementation-harness-customize` anytime to set up more.
- If any hook/guard file was created, suggest a quick sanity check (`--guard-selftest` for the denylist; a
  dry `bash .harness/custom/hooks/on-<event>.sh <args>` for a hook).
- Commit is the user's call (these are their files) — remind them to `git add -A && git commit` the new
  `custom/` files so they're durable.
