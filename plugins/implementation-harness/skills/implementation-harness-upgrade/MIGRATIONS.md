# Harness migration ledger

Per-version record of what changed under `templates/` and **how an upgrade should apply it to an existing
`.harness/`**. The `implementation-harness-upgrade` skill reads this to explain each diff it finds and to
apply config changes additively. **Newest entry first.**

> **Maintainer rule:** every change under `templates/` MUST add/extend an entry here in the same commit —
> see `plugins/implementation-harness/CLAUDE.md`. A missing entry means the change silently never reaches
> existing installs on upgrade.

## How the upgrade skill uses this

- **Mechanism files** (all `scripts/*`, `dashboard/*.js`, `docs/**`, `harness-CLAUDE.md`→`.harness/CLAUDE.md`,
  `README.md`→`.harness/README.md`) — the skill content-diffs these against the reference regardless of the
  ledger; the notes here just explain *what* the diff is so the user can tell a shipped change from a local edit.
- **Project-local operational skills** (as of 1.32.0: `templates/skills/implementation-harness-*/SKILL.md` →
  `$T/.claude/skills/implementation-harness-*/SKILL.md`, at the project ROOT, not under `.harness/`) — same
  content-diff treatment as mechanism files, kept as a separate table since the target path differs.
- **Config/schema files** (`config/harness.env`, `config/facets.json`) — the `ACTION:` lines are load-bearing:
  they tell the skill exactly which knobs to add (with defaults) while preserving the user's values.
- **User-data files** (`tracking/*`, `tasks/*`, `worklog/*`, `ledgers/*`, root `CLAUDE.md`/`.gitignore`/`ci.yml`)
  are never reconciled. Where a version changed one of those, it is listed under **manual attention** so the
  skill can surface it for the user to apply by hand.

Entry format:
```
## <old> → <new>  — <summary>
- mechanism: <paths + one line each>
- config: <path> — ACTION: <exact additive instruction>
- new files: <paths the reference adds>
- renamed/removed: <old → new | removed>
- manual attention: <user-data / root files the upgrade won't touch>
- breaking: <none | description + manual steps>
```

---

## 1.34.3 → 1.35.0 — separate build vs audit live output (was: audit silently wiped the build's)
`run_claude()` was one shared function used for BOTH the builder and auditor invocations, always
writing to the same fixed filename. Since `tee` truncates that file the instant a new invocation
starts, the very first byte of the auditor's output wiped out the builder's still-fresh output before
a human had a chance to read it — reported after noticing the live-output panel appeared to "reset"
whenever the audit phase began.
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` — `run_claude()` gains a 4th required
  argument, `<phase: build|audit>`, and writes to `.claude-out.<phase>.jsonl` / `.claude-out.<phase>`
  instead of the old fixed `.claude-out.jsonl` / `.claude-out`. Both call sites (build loop, audit
  loop) now pass their phase explicitly; the `rl_reset_wait`/`rl_banner` calls in both retry-wait
  loops, and the audit's `cp … $id.audit.md` copy, were updated to the matching phase-specific path —
  logic unchanged, only the path each already used.
- mechanism: `dashboard/server.js` — `claudeOutTail()` (renamed internally to `claudeOutTailFor(phase)`
  + a thin `claudeOutTail()` wrapper calling it for both) now returns `{build, audit}` instead of a
  single result; `GET /api/activity` exposes `build`/`audit` instead of `logTail`/`toolNow`. The "Now"
  strip renders two independent collapsible panels ("live output — build" / "live output — audit"),
  each with its own persisted open/closed state; the `▶ running <Tool>…` pill follows whichever phase
  the heartbeat says is currently active.
- config: none.
- new files: `worklog/.claude-out.{build,audit}[.jsonl]` are created by the loop at runtime (not
  shipped) — `templates/gitignore`'s `.claude-out` entry widened to a glob (`.claude-out*`) covering
  every phase variant instead of the two old exact names.
- manual attention: none.
- breaking: none (an un-upgraded install simply has no `.claude-out.{build,audit}` files yet, so both
  panels degrade to showing nothing until the loop is upgraded and runs at least once).

## 1.34.2 → 1.34.3 — dashboard: line breaks between narration rounds in live output
Reported (and confirmed against a real, live transcript): the live-output tail read as one unbroken
wall of text — e.g. "I'll start by reading the files.Now let me make the fix.Now let's run the
tests." with no space between sentences. Root cause: each short round of narration ("I'll do X.",
before/after a tool call) arrives as its OWN "text" content block in the stream — confirmed by
inspecting a real `.claude-out.jsonl` directly — but `liveOutputFromJsonl()` just concatenated every
`text_delta` chunk with no regard for block boundaries.
- mechanism: `dashboard/lib.js` — `liveOutputFromJsonl()` now inserts a newline at each NEW `text`
  content block's start (never a leading one, never between two deltas of the SAME block — only a
  genuine new round of narration gets a break). `dashboard/lib.test.js` covers both the separator and
  the no-leading-newline case.
- config: none. new files: none. renamed/removed: none.
- manual attention: none.
- breaking: none.

## 1.34.1 → 1.34.2 — dashboard: show which model completed each done task
`ledgers/outcomes.jsonl` already recorded `finalModel`/`finalEffort` per task (the tier that actually
succeeded, after any escalation — distinct from `startModel`/`startEffort`, the cold-start floor it
began at), but nothing in the dashboard surfaced it per-task — only aggregated at the facet-cell level
on the Internals tab. The Backlog tab's Done bucket now shows it directly.
- mechanism: `dashboard/server.js` — new `buildOutcomesByTask()` (mirrors `buildFailures()`'s
  append-order-wins aggregation) attaches `task.completedWith = {model, effort}` in `loadState()`;
  the Done bucket's pill row gains a `model-tag`-styled pill (e.g. `claude-sonnet-5/medium`) when
  present, with a tooltip naming its source.
- config: none. new files: none. renamed/removed: none.
- manual attention: none.
- breaking: none.

## 1.34.0 → 1.34.1 — dashboard: instant Internals tooltips (was: ~1-1.5s native hover delay)
The Internals tab's per-facet calibration headers used the native `title=` attribute for their "?"
tooltips (1.33.1) — but a native tooltip has a browser-enforced hover delay before it appears, which
isn't a real "permanent, obvious" affordance if it feels sluggish to use.
- mechanism: `dashboard/server.js` — the eight `<th>` `<span class="qtip" title="...">` icons are now
  `data-tip="..."` + `tabindex="0"`; a new `initQtips()` renders one reusable popup element (appended
  to `document.body`, positioned via `getBoundingClientRect()` and clamped to the viewport) shown/hidden
  through event delegation on `document` (`mouseover`/`mouseout`/`focusin`/`focusout`), so it keeps
  working across the Internals tab's periodic re-renders and appears immediately, not after a delay.
  Positioning via a body-level popup (rather than a CSS `::after` pinned to the icon) was deliberate:
  the `.ftable` has `overflow:hidden` for its rounded corners, which would clip a same-ancestor tooltip
  for header cells near the table's edges.
- config: none. new files: none. renamed/removed: none.
- manual attention: none.
- breaking: none.

## 1.33.1 → 1.34.0 — genuinely live builder/auditor output (was: one buffered dump at exit)
Diagnosed a real bug (not just a display glitch): the dashboard's "live output" tail and the builder/
auditor's plain terminal output both only ever showed content once, at the very end of a `claude -p`
invocation — confirmed empirically (a 500-word test response sat at a flat byte count for the entire
generation, then landed in a single write the instant the process exited). Root cause: plain `-p` mode
never streams to a pipe — it computes the whole response, then writes it once. Fixed per Anthropic's
own docs: `--output-format stream-json --include-partial-messages` (`--verbose` is mandatory alongside
it — the CLI refuses to start without it).
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` — `run_claude()` now invokes claude with
  the streaming flags. The raw event stream goes to a NEW file, `worklog/.claude-out.jsonl` (what the
  dashboard tails live); `worklog/.claude-out` itself is reconstructed from that stream via
  `jq -Rrj 'fromjson? | select(...) | .event.delta.text'` into PLAIN TEXT and keeps its EXACT prior
  meaning and every existing consumer unchanged — `RL_HARD_RE`/`RL_RE` rate-limit detection,
  `rl_reset_wait()`'s reset-time parsing, the audit's PASS/FAIL verdict grep, the `.audit.md` worklog
  copy. The `-R … | fromjson?` shape (not a plain `select(...)` on parsed JSON) is load-bearing: `2>&1`
  means an occasional non-JSON stderr line can land mid-stream, and naive `jq 'select(...)'` treats one
  parse error as fatal — silently dropping every later chunk for the rest of the invocation (confirmed
  empirically with a planted bad line). Also confirmed empirically: a rate-limit phrase split across
  two streamed chunks is invisible to a per-line `grep` against the raw stream — reconstructing plain
  text first (as above) is what makes the existing detection reliable again, not incidental.
- mechanism: `dashboard/lib.js` — new `liveOutputFromJsonl(text)` (parses the raw stream, concatenates
  `text_delta` text, and reports the name of a tool call that's started but has no response text after
  it yet — surfaced as a `▶ running <Tool>…` pill). `dashboard/server.js` — `claudeOutTail()` now picks
  the freshest of FOUR candidates (`.claude-out.jsonl` / `.claude-out` × primary checkout / loop
  worktree) instead of two, parsing whichever wins based on its extension; an install that hasn't
  upgraded `loop.sh` yet never produces a `.jsonl` file, so this degrades automatically to the old
  two-candidate plain-text behavior. `GET /api/activity` gains a `toolNow` field alongside `logTail`.
  `dashboard/lib.test.js` covers concatenation, the mid-tool-call state, garbled-line tolerance, and
  empty input.
- new files: `worklog/.claude-out.jsonl` is created by the loop at runtime (not shipped) — added to
  `templates/gitignore` alongside the existing `.claude-out` entry.
- config: none.
- manual attention: `docs/LIMITATIONS.md` — new field note: rate-limit detection still regex-matches
  prose rather than the structured `rate_limit_info.resetsAt` timestamp the same stream also emits on
  every invocation (a good follow-up, deliberately NOT done here — it needs its own verification
  against a real rate-limit-hit payload, which this round of testing never triggered).
- breaking: none (an un-upgraded install keeps working exactly as before; this only adds a capability).

## 1.33.0 → 1.33.1 — dashboard: visible "?" tooltip icons on Internals table headers
The per-facet calibration table's column headers had `title=` tooltips (added in 1.33.0), but a
plain native tooltip on the header text gives no visual hint that hovering does anything — nothing
signals there's more to read. Adds a small circled "?" icon after each header label, carrying the
tooltip itself, so the affordance is a permanent, obvious UI element instead of a hidden one.
- mechanism: `dashboard/server.js` — each of the eight `<th>`s in the per-facet calibration table's
  header row now ends with `<span class="qtip" title="...">?</span>` instead of the `<th title="...">`
  attribute; new `.qtip`/`.qtip:hover` CSS (small circle, muted by default, accent-colored on hover).
  Same tooltip text as 1.33.0, just relocated onto a visible icon.
- config: none. new files: none. renamed/removed: none.
- manual attention: none.
- breaking: none.

## 1.32.3 → 1.33.0 — dashboard polish: preset color swatches, expand-all ideas, header tooltips
Three small UI improvements, all in `dashboard/server.js`, none touching any endpoint or data shape:
- The background-color picker is now 10 curated light/bright preset swatches (cream, sky blue, mint,
  lavender, peach, blush pink, aqua, butter yellow, coral, periwinkle) instead of a native
  open-ended `<input type="color">` — picking a good background from unlimited options was fiddly;
  a small curated set isn't. Same `localStorage` persistence/namespacing as before.
- The Ideas tab gained an "Expand all" / "Collapse all" button (flips label based on current state)
  so unfurling every idea no longer means clicking each caret one at a time.
- Every column header in the Internals tab's per-facet calibration table now carries a hover
  tooltip explaining what it means (two columns already had one; the rest — Facet, Start model,
  Builds, ✓, ✗, ⚠ fails — didn't).
- mechanism: `dashboard/server.js` — swapped `.bgpicker`'s `<input type="color">` + "Reset" button
  for 10 `<button class="swatch">` elements (`setBg()`/`markActiveSwatch()` replace
  `initBgPicker()`'s input-listener + `resetBg()`); `renderIdeas()` gained a bar with a
  `toggleAllIdeas()` button; the per-facet `<table>`'s `<thead>` gained `title=` attributes on the
  six previously-untitled `<th>`s.
- config: none. new files: none. renamed/removed: none.
- manual attention: none.
- breaking: none (a saved custom hex from the old open-ended picker, if it doesn't match one of the
  10 presets, still applies visually via the stored `--bg` value — it just won't show any swatch as
  active until the user picks one of the 10).

## 1.32.2 → 1.32.3 — dashboard: fix a broken-page bug in the Ideas tab's onclick escaping
`renderIdea()` (added in 1.31.0's ideas-inbox migration) built its onclick attribute with a
single-backslash-escaped quote (`'...onclick="toggleIdea(\'' + key + '\')">'`). Since the whole
dashboard page is itself one giant server-side template literal, Node's own parsing silently
consumes that `\'` at render time and drops the backslash — so the SERVED script contains a bare,
unescaped quote instead, which breaks the entire `<script>` block's syntax. A syntax error anywhere
in a `<script>` tag prevents ALL of it from running, so every function on the page (`switchView`,
`resetBg`, everything) ended up undefined — not just the Ideas tab. Confirmed by extracting the
actual served `<script>` content and running it through `node --check`: it failed before this fix,
passes after.
- mechanism: `dashboard/server.js` — `renderIdea()` rewritten to use the same nested
  escaped-backtick template-literal convention the rest of the file already uses correctly (e.g.
  `renderTask`), instead of string concatenation with escaped quotes — avoids the exact
  double-escaping trap that caused this.
- config: none. new files: none. renamed/removed: none.
- manual attention: none.
- breaking: none (this is a straight regression fix — any install on 1.31.0, 1.32.0, 1.32.1, or
  1.32.2 has a dashboard whose Ideas tab silently breaks the WHOLE page's client-side JS the moment
  any idea exists in `tracking/IDEAS.jsonl`; upgrading picks up the fix).

## 1.32.1 → 1.32.2 — dashboard: spinning cog while the loop is actively running
Pure visual polish: the ⚙ next to "Harness" now spins (CSS animation, `prefers-reduced-motion`
respected) whenever the "Now" strip's own lock check reports the loop as running
(`lock.held && lock.alive` — the same condition that already drives the "▶ loop running" pill), so
it's idle-still whenever the loop isn't.
- mechanism: `dashboard/server.js` — the `<h1>`'s ⚙ is now `<span id="cog" class="cog">`; new
  `.cog`/`.cog.spin`/`@keyframes cogspin` CSS; `renderNow()` toggles the `spin` class from the same
  lock-state data it already renders the strip from. No new endpoint, no new data.
- config: none. new files: none. renamed/removed: none.
- manual attention: none.
- breaking: none.

## 1.32.0 → 1.32.1 — convert-ideas: self-contained questions + fix the "one call" batching bug
Owners reported that mid-sweep `AskUserQuestion` prompts were hard to place — a question like "For Unit
A... Match what you want?" carries no restatement of which idea it's about, only a ≤12-char header chip
and a one-time recap shown before potentially many questions. Checked the `AskUserQuestion` schema
directly: there is no length limit on the `question` text (only structural caps — max 4 questions per
call, 2–4 options per question) — so nothing stopped the skill from writing richer questions; the
instructions just didn't ask for it. Also found a real bug alongside it: §4 said to batch "every question
from every file" into **one** `AskUserQuestion` call, which is impossible once a sweep has more than 4
questions total.
- mechanism: `templates/skills/implementation-harness-convert-ideas/SKILL.md` — §3 step 5's
  pending-questions schema now requires every `question` string to open with a one-sentence,
  self-contained restatement of which idea it's about ("For idea #&lt;N&gt; (&lt;one-sentence gist&gt;): ...") —
  a full sentence, not a short phrase, since several ideas may be in flight with similar-sounding gists.
  §4 now instructs batching in groups of ≤4 (the tool's actual cap) across possibly several sequential
  calls, keeping one idea's questions together within a batch, instead of the previous (infeasible) "one
  call" instruction. The upfront markdown recap stays but is now explicitly a courtesy, not the
  question's only source of context.
- config: none. new files: none. renamed/removed: none.
- manual attention: none (prompt-only change; no schema/data migration).
- breaking: none.

## 1.31.0 → 1.32.0 — six operational skills become project-local (fix global/version-skew + namespacing)
Six skills (`add-to-backlog`, `capture-idea`, `convert-ideas`, `loop-recover`, `pre-loop-checkin`,
`review-failed`) read/write a SPECIFIC project's versioned `.harness/` mechanism files, but were
registered globally (plugin-scoped) — so a global plugin update could silently outrun a project's
still-un-upgraded `.harness/` (e.g. `convert-ideas`' pending-tasks schema vs `consolidate-ideas.mjs`,
the exact `ideaBullets`→`ideaIds` drift from 1.31.0). Moves them to project-local skills, scaffolded
by `create` into `.claude/skills/implementation-harness-<name>/SKILL.md` at the repo root and kept in
sync by `upgrade`'s existing mechanism-file reconciliation, so they can never drift ahead of the
project's own `.harness/`. `create`/`customize`/`upgrade` stay global (they're what you run to FIX a
version mismatch, so global is correct for them).

Also fixes a confirmed, pre-existing doc bug: every doc taught a bare `/implementation-harness-<name>`
invocation for ALL nine skills, but plugin-registered skills always need the `implementation-harness:`
colon prefix — this never worked for create/customize/upgrade. Docs now correctly show the colon form
for those three; the six operational skills' existing bare-form docs were already correct (Claude Code
project-local skills invoke bare) and are unchanged.

- mechanism: `skills/implementation-harness-{add-to-backlog,capture-idea,convert-ideas,loop-recover,
  pre-loop-checkin,review-failed}/` moved to `templates/skills/implementation-harness-<name>/SKILL.md`
  (no longer plugin-registered — Claude Code stops discovering them globally). `convert-ideas/SKILL.md`
  §0 also drops its dead "harness up to date?" plugin-version nudge (relied on `CLAUDE_PLUGIN_ROOT`,
  which isn't set for a project-local skill; the drift it guarded against is now structurally prevented
  by this same change).
- mechanism: `skills/implementation-harness-create/SKILL.md` — new §4b scaffolds the six as
  `.claude/skills/implementation-harness-<name>/SKILL.md` at the target repo root; new validation-gate
  checks (frontmatter `name:` + existence for the six; regression guard that create/customize/upgrade are
  NOT scaffolded project-locally; warns if the target's own `.gitignore` blanket-ignores `.claude/`).
- mechanism: `skills/implementation-harness-upgrade/SKILL.md` — new stage-3 mechanism-file table for the
  six `.claude/skills/implementation-harness-<name>/SKILL.md` files (target at `$T/.claude/skills/`, NOT
  under `$H`); an install missing all six is always a straightforward add-candidate, never a "deliberate
  removal" question (even in §1a adoption mode) — it's a wholesale new category, not an ambiguous removal.
- new files: for any install upgrading from before this version, all six
  `.claude/skills/implementation-harness-<name>/SKILL.md` files (offered as add-candidates per above).
- renamed/removed: `skills/implementation-harness-{add-to-backlog,capture-idea,convert-ideas,
  loop-recover,pre-loop-checkin,review-failed}/SKILL.md` (plugin-registered) → `.claude/skills/
  implementation-harness-<name>/SKILL.md` (project-local, scaffolded/synced copy). The plugin-registered
  copies are gone; only `create`, `customize`, `upgrade` remain plugin-registered.
- manual attention: doc fixes for the colon-form invocation of create/customize/upgrade across
  `README.md`, `templates/harness-CLAUDE.md`, `templates/custom/CLAUDE.md`, and cross-references inside
  the skill files themselves — informational, not auto-appliable by the upgrade skill.
- breaking: **yes** — until an existing install runs this upgrade, its `.claude/skills/` directory does
  not exist, so the six operational skills are NOT invocable in that project at all (they were previously
  reachable globally via the plugin; that global registration is now gone). Running
  `implementation-harness:implementation-harness-upgrade` once restores them as project-local skills.

## 1.30.0 → 1.31.0 — ideas inbox: Markdown → JSONL (title/description fields, dashboard cards)
The ideas inbox was a hand-edited markdown numbered-bullet list, matched by ~60 lines of fuzzy
bullet-text normalization in `consolidate-ideas.mjs`, and rendered on the dashboard's Ideas tab as one
long markdown blob (hard to tell where one idea ends and the next begins). Moves it to
`tracking/IDEAS.jsonl` — one `{id, title, description, capturedAt}` JSON object per line, matching the
harness's existing ledger convention (`outcomes.jsonl`/`failures.jsonl`) — so ideas are addressed by a
real `id` instead of fuzzy text matching, and the dashboard renders a collapsed one-line-per-idea list
that expands to the full (still markdown-rendered) description.
- mechanism: `dashboard/lib.js` — new `ideasFromJsonl(text)` (parses via the existing `parseJsonl()`,
  renders each row's `description` through the existing `mdToHtml()`, sorts ascending by `id`);
  `dashboard/server.js` — `GET /api/ideas` now returns `{ideas: [...], empty}` instead of one
  pre-rendered HTML blob; the Ideas tab renders a collapsed id+title+captured-date row per idea
  (reusing the backlog's taskrow/expand pattern) that expands to the rendered description.
  `dashboard/lib.test.js` covers the new parser (garbled/id-less rows dropped, sort order, markdown
  rendering).
- mechanism: `scripts/consolidate-ideas.mjs` — the fuzzy bullet-text matcher (`normalizeForMatch`,
  `inboxBounds`, `inboxBullets`, `removeIdeaBullet`) is GONE, replaced by a plain `id`-based filter over
  `IDEAS.jsonl` rows. The pending-tasks file shape changes: `"ideaBullets": [<raw bullet text>, ...]` →
  `"ideaIds": [<id>, ...]`. `review-failed`'s synthetic-bullet workaround (a `<TNNN>: <title>` string
  that never matched anything, logging an expected-harmless warning) is gone too — it now simply omits
  `ideaIds`, and consolidation does nothing idea-side for a review-derived unit, no warning.
- renamed/removed: `tracking/IDEAS.md` → `tracking/IDEAS.jsonl` (format changed, not just the
  extension). Fresh installs (`create`) get the new empty `IDEAS.jsonl` starter automatically.
- config: none.
- manual attention: an EXISTING install's `tracking/IDEAS.md` is user data — the upgrade never
  silently rewrites it. The upgrade skill's new **§1c** offers a one-time, confirmed conversion: read
  every numbered bullet, write one JSON object per idea (`id` in bullet order, a drafted one-line
  `title`, the full bullet as `description`, `capturedAt: null`), show the result, and remove
  `IDEAS.md` only once the user confirms.
- breaking: **yes** — as of this version nothing reads `tracking/IDEAS.md` any more (dashboard,
  `capture-idea`, `convert-ideas` all expect `IDEAS.jsonl`). An existing install's ideas pipeline is
  effectively paused until it runs the upgrade's §1c conversion (or hand-converts).

## 1.29.0 → 1.30.0 — dashboard project title (custom/) + client-side background color picker
Multiple projects (or multiple harness-driven repos) running the dashboard look identical, making tabs hard
to tell apart. Adds an opt-in `custom/` overlay for a short project label shown in the header + browser tab,
plus a purely client-side background-color picker for further visual differentiation.
- new files: `custom/dashboard-title.txt.example` — overlay stub (blank/`#`-comment lines ignored; first
  remaining line is the title). **Add-if-missing on upgrade; NEVER overwrite a user's real
  `dashboard-title.txt`.** The whole-tree `custom/` copy lands it on fresh installs.
- mechanism: `dashboard/server.js` — reads `custom/dashboard-title.txt` (if present) and uses it for the
  `<title>` and header `<h1>`; absent → unchanged ("Harness"/"Backlog — implementation harness"). Also adds
  a 🎨 color-picker control in the header that sets the `--bg` CSS variable and persists it to the browser's
  `localStorage`, namespaced by the project directory name — purely a rendering preference, no new file and
  nothing written to the repo.
- docs: `docs/HARNESS.md` §8.3, `harness-CLAUDE.md`'s custom/ table, and `README.md`'s dashboard section
  document both. `implementation-harness-customize` catalog gains a matching entry (skill-side).
- config: none.
- breaking: none.

## 1.28.0 → 1.29.0 — customization walkthrough skill + surfaced on create/upgrade + stronger in-place red flag
Users rarely discover the `custom/` extension points. Adds a feature-walkthrough skill (the canonical
versioned catalog) that create runs in full and upgrade runs scoped to what's new since the install, and
sharpens the "don't edit in place" warning. Mostly skill-side; the one `templates/` change is the warning.
- mechanism: `harness-CLAUDE.md` — the "Customizing / forking" section is now a prominent **⚠️ danger
  callout**: editing ANY plugin-owned `.harness/` file in place is a red flag that forfeits clean upgrades →
  STOP + flag it + route to `custom/` (with a catalog table + a pointer to `/implementation-harness-customize`).
  It loads whenever Claude works in `.harness/`, so it fires at edit time.
- config: none.
- manual attention: existing installs pick up the strengthened `.harness/CLAUDE.md` on their next upgrade
  (normal mechanism refresh). The new skill + the create/upgrade wiring are plugin-side — they reach installs
  as soon as the plugin is updated; nothing to apply per-install.
- breaking: none.
- (skill-side, no template change: new `implementation-harness-customize` skill owning the versioned catalog;
  `create` §8 invokes it for all features; `upgrade` §5 invokes it `--since <CUR_VERSION>` for features new
  since the install.)

## 1.27.0 → 1.28.0 — project build/audit prompt preambles (custom/ injection) + helper bugfix
Adds a `custom/` extension point for **standing** project rules injected into *every* builder/auditor prompt
(e.g. "never make live paid-API calls during verification; use cached fixtures + the scratch DB"). Follows
the 1.24.0/1.27.0 `custom/` pattern. Also fixes a latent bug in the 1.27.0 visual-verify helper.
- new files: `custom/build-preamble.md.example`, `custom/audit-preamble.md.example` — overlay stubs.
  **Add-if-missing on upgrade; NEVER overwrite a user's real `build-preamble.md` / `audit-preamble.md`.**
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` — both gain `_custom_preamble <build|audit>`,
  which **unconditionally** appends `custom/<mode>-preamble.md` (if present) to the builder/auditor prompt (a
  standing rule, not gated on the task). Absent → byte-identical prior prompt. **Bugfix:** both
  `_custom_preamble` and the 1.27.0 `_visual_verify_custom` declared `local mode="$1" f="…${mode}…"` in ONE
  `local` statement, so `${mode}` expanded *before* it was assigned → empty path. Split onto separate `local`
  lines. (`_visual_verify_custom` worked in 1.27.0 only by coincidence — its caller's `mode` leaked in via
  dynamic scope — but `_custom_preamble`, called from `prompt()`, would not have.)
- docs: `docs/HARNESS.md` §8.3 documents the preamble pair. Covered by `scripts/loop-extend.test.sh`.
- config: none.
- breaking: none.

## 1.26.0 → 1.27.0 — project visual-verify prompt snippets (custom/ injection)
Adds a `custom/` extension point for project-specific visual-verification prompt text, so a project with a
richer discipline (exact capture commands, a living-fixtures file, named flows) injects it into the
builder/auditor prompts without forking `loop.sh`. Follows the 1.24.0 `custom/` pattern: convention-located
optional file, absent → byte-identical prior behavior.
- new files: `custom/visual-verify-build.md.example`, `custom/visual-verify-audit.md.example` — overlay
  stubs. **Add-if-missing on upgrade; NEVER overwrite a user's real `visual-verify-*.md`.** The whole-tree
  `custom/` copy lands them on fresh installs.
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` — both gain a `_visual_verify_custom <build|audit>`
  helper that **appends** `custom/visual-verify-<mode>.md` (if present) to the generic visual-verification
  block, gated identically (only when the block already fires — task opted in / heuristic matched; never an
  independent trigger). `docs/HARNESS.md` §8.3 + `docs/designs/visual-verification.md` document it. Absent
  files → byte-identical prior prompt. Covered by `scripts/loop-extend.test.sh`.
- config: none.
- breaking: none.

## 1.25.0 → 1.26.0 — in-place postflight variant (fix the worktree-only status board)
The single shipped `postflight.sh` was worktree-bound: it read the board from `origin/main` blobs and
detected in-flight by grepping for `tNNN` task branches — neither fits the in-place variant (it builds on
the local checkout, never creates `tNNN` branches, and may have no remote, so the board showed nothing
in-flight and was empty without a remote). Adds a second postflight variant, selected by loop variant
exactly like `loop.sh`.
- new files: `scripts/postflight.in-place.sh` — the in-place status board (reads LOCAL
  `tracking/TASKS.json` + `worklog/`; in-flight = a dirty working tree). Installs as `scripts/postflight.sh`
  on an in-place install.
- mechanism: `scripts/postflight.sh` is now VARIANT-SELECTED (like `loop.sh`) — the upgrade diffs an
  installed `postflight.sh` against `postflight.in-place.sh` on an in-place install (VARIANT read from the
  loop marker), else against `postflight.sh`. A fork that hand-rewrote its in-place postflight can now take
  the pristine in-place reference and go byte-clean. `scripts/supervise.sh` — one header comment
  de-worktree'd (its logic was already variant-agnostic; no behavior change).
- config: none.
- manual attention: an in-place install created before this shipped still carries the WORKTREE
  `postflight.sh` (its board never shows in-flight, and is empty with no remote). Re-run
  `/implementation-harness-upgrade` — it now offers the in-place postflight for that install.
- breaking: none.

## 1.24.0 → 1.25.0 — trim the default tier ladder to 4 rungs (match the documented recommendation)
The template shipped a 7-rung ladder reaching `opus/max`, while the docs recommended a short 4-tier ladder;
this aligns the shipped DEFAULT with the recommendation. A stuck task now blocks to a human after at most
`4 × MAX_ATTEMPTS = 8` cold attempts instead of 14.
- config: `config/facets.json` — `.tiers.ladder` trimmed from 7 rungs (sonnet low/medium/high + opus
  medium/high/xhigh/max) to **4** (sonnet low → medium → high, then opus/high); `.tiers._about` reworded to
  describe the short default. ACTION: this is a shipped DEFAULT change, NOT an additive knob — the upgrade
  must **NOT** touch an existing install's `.tiers.ladder` (it is tailored per project; §1a "facet
  vocabularies belong to the project" already protects `facets.json` from clobbering).
- mechanism: `docs/HARNESS.md` — the "keep the ladder short" callout now states the template ships the
  4-tier ladder (was "ships a longer ladder that reaches `max`"); `README.md` — corrects the
  `VISUAL_VERIFY_WORKTYPES` default to `component style` (was a stale `component`; `HARNESS.md` +
  `visual-verification.md` were already correct).
- new files: none.
- manual attention: existing installs keep their own `.tiers.ladder`. To adopt the shorter default, edit
  `.harness/config/facets.json` by hand (drop opus medium/xhigh/max; keep opus/high as the top rung).
- breaking: none.

## 1.23.0 → 1.24.0 — custom/ extension points: lifecycle hooks + append-only guard denylist
Turns `.harness/custom/` into a behavior/config extension surface (not just prose). Both extension points
are opt-in `.example` stubs and back-compatible: absent → byte-identical prior loop behavior. See
`docs/HARNESS.md` §8.3.
- new files: `custom/hooks/on-drained.sh.example`, `custom/hooks/on-blocked.sh.example`,
  `custom/hooks/on-exhausted.sh.example`, `custom/hooks/on-integrated.sh.example`,
  `custom/sensitive-paths.txt.example`. **Add-if-missing on upgrade; NEVER overwrite a user's REAL
  `custom/hooks/on-*.sh` or `custom/sensitive-paths.txt`** (their content). The whole-tree `custom/` copy
  lands them on fresh installs automatically.
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` — both gain (a) a `run_hook <event>` dispatcher
  running `custom/hooks/on-<event>.sh` if present (child process, non-fatal, exports
  `HARNESS_ROOT`/`HARNESS_DIR`/`HARNESS_MAIN_BRANCH`), wired at drain/idle (`on-drained`), MAX_ITERS +
  rate-limit give-up (`on-exhausted`), block (`on-blocked`), and integrate (`on-integrated`); (b) an
  append-only guard extension that OR-appends valid patterns from `custom/sensitive-paths.txt` to
  `SENSITIVE_RE` (an invalid regex → WARN + base-only, never wedges the loop or disables the guard); (c)
  `--guard-selftest [path]` — the path-probe mode is new, and the whole `guard_selftest` is now PORTED to
  the worktree `loop.sh` (previously in-place only). Absent custom files → byte-identical prior behavior.
- plugin-CI only (NOT shipped to installs): `scripts/loop-extend.test.sh` (NEW) — hermetic tests for the
  guard extension (both variants) + the hook dispatcher; run in the plugin's CI by the repo's new `*.test.sh`
  step. It exercises both loop variants (which only coexist in `templates/`), so `create` does not copy it
  and the upgrade never reconciles it into an install.
- mechanism: `docs/HARNESS.md` — new §8.3 "Extending via custom/"; `harness-CLAUDE.md` — the forking section
  now points at the hooks/denylist; `config/harness.env` — comment-only pointer to the two extension points.
- config: none (convention over config — no new `harness.env` knob).
- manual attention: a fork that inlined deploy-on-drain logic or extra guard patterns into `loop.sh` should
  move them into `custom/hooks/on-drained.sh` / `custom/sensitive-paths.txt` and take the pristine loop (the
  upgrade §1a note + §1b standardize path call this out).
- breaking: none.

## 1.22.0 → 1.23.0 — prose customization overlay (`custom/`) + standardize upgrade path + version nudge
The big change is the **prose overlay**: plugin-owned prose files (`.harness/CLAUDE.md`, `README.md`,
`docs/**`) stay pristine and reference a parallel `.harness/custom/` tree where consumers put their edits —
so those files upgrade cleanly instead of drifting into per-file reconciles. Baked into fresh installs
(templates + `create`, here) and migratable for existing forks via the upgrade skill's new §1b *standardize*
path (skill-side — reaches existing installs automatically). The `convert-ideas` version-check nudge is
also skill-side (no template change).
- new files: `custom/CLAUDE.md`, `custom/README.md`, `custom/docs/HARNESS.md`, `custom/docs/LIMITATIONS.md`,
  `custom/docs/designs/{audit-verification,difficulty-autotune,manual-fail-signal,visual-verification}.md`
  — the overlay stub tree (mirrors the prose layout). **Add-if-missing on upgrade; NEVER overwrite an
  existing overlay file — it's user content.** Without them the pristine files' `@custom/…`/pointer
  references have no target.
- mechanism: `harness-CLAUDE.md` — appends an `@custom/CLAUDE.md` import at the very bottom (auto-loads the
  overlay when `.harness/CLAUDE.md` loads) and adds a "Customizing / forking the harness" section (put
  changes in `custom/`, never inline; scripts/config are the exception).
- mechanism: `README.md`, `docs/HARNESS.md`, `docs/LIMITATIONS.md`, `docs/designs/*.md` — each gains a
  one-line pointer to its `custom/…` overlay near the top; `docs/LIMITATIONS.md` also redirects
  golden-rule-5's "add a row" to `custom/docs/LIMITATIONS.md`.
- config: none.
- manual attention: existing installs adopt the overlay via the upgrade skill — add the missing `custom/`
  stubs, take the pristine files' new pointer lines, and (for a fork) run the §1b **standardize** path to
  move any inline prose edits into `custom/`. Repo-root `CLAUDE.md` is user-data: its golden-rule-5 now
  points at `custom/docs/LIMITATIONS.md` for FRESH installs (via `create`); existing repos should update
  that wording by hand if they want the overlay convention.
- breaking: none.

## 1.21.0 → 1.22.0 — front-load clarification into the planning stage (DoD emphasis)
(The behavioural change lives in the `convert-ideas` / `review-failed` skills — bias toward asking, a
mandatory definition-of-done confirmation, and an `ideaSummary` shown before questions — which are skill
files, not `templates/`, so they reach existing installs automatically without an upgrade. The only
`templates/` touch is the docs paragraph below.)
- mechanism: `docs/HARNESS.md` — §5.1 ("Planning vs building") gains a paragraph stating that clarification
  is front-loaded into the authoring stage (idea→task conversion, failed-task review), where a human
  confirms the definition of done, so the unattended build pass inherits an unambiguous contract; the
  planning skills bias toward asking, the loop does not.
- config: none.
- new files: none.
- renamed/removed: none.
- manual attention: none.
- breaking: none.

## 1.19.0 → 1.21.0 — dashboard ops console: live "Now" strip, freshness, observed audit + failure health
(1.20.0 was skill-only — the upgrade skill's adoption mode for legacy/hand-forked installs — no template
changes, so no entry.)
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` — new `heartbeat`/`heartbeat_clear` helpers:
  the loop drops a gitignored `worklog/.current.json` breadcrumb (task, phase building/awaiting-ci/
  auditing/integrating/rate-limited, rung, attempt, tier, timestamps) at phase transitions and removes it
  at terminal outcomes and on any exit (trap). Purely observational — nothing reads it back; every write
  is `|| true`.
- mechanism: `dashboard/server.js` — new `GET /api/activity` (loop lock state via the same
  `<git-common>/<name>-loop.lock/pid` derivation as repo-lock.sh with a PID liveness probe; the heartbeat;
  the last ~40 lines of `.claude-out` from whichever checkout was touched last; freshness = FETCH_HEAD age
  + local HEAD vs `origin/<MAIN_BRANCH>`), an always-visible "Now" strip on every tab (running / idle /
  ⚠ stale-lock-run-loop-recover pill, `local ≠ origin` and "origin seen Xm ago" badges, collapsible live
  output tail), an opt-in interval `git fetch` (`HARNESS_DASHBOARD_FETCH_SECONDS`, fetch-only), and the
  Internals table now shows **Audit (policy)** next to **Audited (observed)** plus a global failure-kind
  health panel (per-cell kinds on the ⚠ hover).
- mechanism: `dashboard/lib.js` + `dashboard/lib.test.js` — `harnessCells` cells gain a `kinds` breakdown;
  new `failureKinds()` global aggregation; tests for both.
- mechanism: `README.md` — dashboard section documents the Now strip, observed-audit column, failure
  health, and the fetch knob.
- config: `config/harness.env` — ACTION: add these knobs if absent (do NOT touch existing values):
  `HARNESS_DASHBOARD_PORT` (default `4790`), `HARNESS_DASHBOARD_FETCH_SECONDS` (default `0`).
- manual attention: repo-root `.gitignore` (user data) — add `.harness/worklog/.current.json` next to the
  other worklog scratch entries. Without it the heartbeat is still safe (the worktree variant writes it
  only to the primary checkout; the in-place variant never stages it), but it will show as an untracked
  file.
- breaking: none.

## 1.18.1 → 1.19.0 — smarter rate-limit backoff + production field notes
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` —
  - `rl_reset_wait` now returns non-zero (echoes nothing) when no reset time parses, instead of
    silently returning `RL_POLL`; a PARSED wait is capped at `RL_BACKOFF_MAX`.
  - The build path falls back to **exponential backoff** (`RL_BACKOFF_MIN` doubling to `RL_EXP_MAX`)
    when the notice carries no parseable reset time; the audit path still polls `RL_POLL`. The
    `RL_MAX_WAIT` → exit-5-for-supervise budget is unchanged.
  - New `_hms` + `rl_banner` helpers: every rate-limit sleep prints a boxed banner with what Claude
    reported, the sleep duration, and the WALL-CLOCK resume time (unattended runs become diagnosable
    from the log alone). Inline `RL_BUFFER` default raised 60 → 300 (waking a hair early re-hits the
    same limit and burns the attempt).
- mechanism: `docs/HARNESS.md` (§ usage-limit handling rewritten to match),
  `docs/LIMITATIONS.md` (new "Field notes — traps learned operating this harness in production"
  subsection under Harness: interrupt-orphan → run loop-recover; the load-bearing split `git add`s;
  deploy-webhook rate limits → `PUSH_COOLDOWN_SECONDS`; UI false-successes need a human to actually
  look; tests can encode the same bug as the code).
- config: `config/harness.env` — ACTION: add these knobs if absent (do NOT touch existing values):
  `RL_BACKOFF_MIN` (default `300`), `RL_EXP_MAX` (default `3600`), `RL_BACKOFF_MAX` (default `18000`).
  ACTION: `RL_BUFFER` default changed `60` → `300` — update only if the target still holds the old
  default verbatim (`: "${RL_BUFFER:=60}"`); if the user customized it, leave it and just report.
- breaking: none (RL_POLL keeps its role as the audit-path fallback; behavior only changes on the
  previously-fixed-poll unknown-reset build path).

## 1.18.0 → 1.18.1 — loop correctness fixes (ledger accuracy + policy hygiene)
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` —
  - `cur_verification` now resets to `ci-only` whenever a NEW task is selected (was reset only inside
    `audit_gate`, so a task failing before its audit could write the previous task's `"audited"` into
    its outcome/blocked ledger row).
  - `pick_base` no longer reads per-task `.model`/`.effort` from `TASKS.json` — the cold-start prior is
    always the `harness.env` `MODEL`/`EFFORT` floor. Facets were already the documented only difficulty
    signal; a stray hand-added field could silently override the tier floor.
  - audit sampling uses a new `rand_pm` helper (rejection-sampled `$RANDOM`) instead of `RANDOM % 1000`,
    removing the modulo bias that skewed the effective audit rate slightly below the configured per-mille.
- mechanism: `scripts/loop.sh` (worktree variant only) — `sync_primary_checkout` no longer checks out
  `main` from another branch: a primary checkout deliberately left on a feature branch (or detached) is
  left alone; only a checkout already on `main` is fast-forwarded.
- mechanism: `docs/HARNESS.md`, `docs/designs/difficulty-autotune.md` — cold-start-prior wording updated
  to match (prior = `harness.env` floor; per-task `model`/`effort` ignored).
- config: `config/harness.env` — comment-only clarification on `PUSH_COOLDOWN_SECONDS` (the throttle
  covers the integration push; the follow-up `[skip ci]` status/ledger push is not throttled). No ACTION —
  knob reconciliation doesn't carry comments; nothing to apply.
- manual attention: root `CLAUDE.md` template (golden rule 7) rewords the cold-start-prior sentence and
  now says per-task `model`/`effort` fields are ignored — existing installs may want to update their copy.
  If any existing `TASKS.json` task carries a hand-added `model`/`effort` field, it stops having an effect
  as of this version (facets/ladder govern entirely).
- breaking: none.

## 1.17.0 → 1.18.0 — dashboard Ideas + Internals (per-facet calibration) tabs
- mechanism: `dashboard/server.js` + `dashboard/lib.js` — the dashboard is now a 3-tab app
  (Backlog / Ideas / Internals). New `GET /api/ideas` (renders `tracking/IDEAS.md` via a dependency-free,
  XSS-safe `mdToHtml`) and `GET /api/harness` (per `layer × work-type` cell: chosen model + audit rate by
  invoking `scripts/policy.jq` exactly as the loop does, plus build/failure counts, the tier ladder, the
  policy knobs, and a recent-activity feed; memoised on ledger mtimes). `README.md` dashboard section updated.
- config: none. new files: none. breaking: none. (Pure dashboard refresh — no change to the loop, ledgers,
  or task schema.)

## 1.16.1 → 1.17.0 — worktree loop leaves the primary checkout on main when done
- mechanism: `scripts/loop.sh` (worktree variant only) — new `sync_primary_checkout()`, called at the
  clean "backlog drained / idle" exits: fast-forwards the owner's primary checkout onto the latest main so
  the local copy reflects the completed work. Safe/best-effort — skips a dirty tree, ff-only, non-fatal.
  Header ISOLATION note + `docs/HARNESS.md` §Isolation updated. `loop.in-place.sh` unchanged (it already
  works directly on main).
- config: `config/harness.env` — ACTION: add knob `SYNC_PRIMARY_ON_DONE` (default `1`) if absent; do not
  touch existing values. `0` keeps the strict never-touch-the-primary-checkout behavior. (No effect on the
  in-place variant.)
- breaking: none (default-on but safe + opt-out).

## 1.16.0 → 1.16.1 — dashboard fixes: spec-scroll reset + failed-implies-reviewed
- mechanism: `dashboard/server.js` — the 5s auto-refresh now skips the re-render when the backlog is
  unchanged since the last poll (it was rebuilding `#sections` every tick, recreating each open `<pre>`
  and snapping its scroll back to the top mid-read); the per-task "Mark reviewed" button is no longer
  offered on a failed task.
- mechanism: `dashboard/lib.js` — a failed task is now implicitly reviewed (`reviewed = isReviewed || failed`),
  so it drops out of the unreviewed / bulk-review set and shows the reviewed pill; failure is itself the
  review verdict.
- config: none. breaking: none.

## 1.15.0 → 1.16.0 — upgrade skill + version stamping + migration ledger
- new files: `.harness/.harness-version` (written by create/upgrade — the plugin version marker; commit it).
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` gain a `# harness-loop-variant:` header line
  (worktree / in-place) so the upgrade skill knows which reference to diff a target's `loop.sh` against.
- config: none.
- manual attention: none. (This is the first version that stamps `.harness-version`; any harness installed
  before it reads as "legacy/unknown" and is reconciled purely by content diff.)
- breaking: none.

## 1.14.0 → 1.15.0 — facets-driven visual-verification trigger
- config: `config/harness.env` — ACTION: add these knobs if absent (do NOT touch existing values):
  `VISUAL_VERIFY_LAYERS` (default `frontend`) and `VISUAL_VERIFY_SKIP_WORKTYPES` (default `docs config logging`).
  Also the default for `VISUAL_VERIFY_WORKTYPES` widened from `component` to `component style` — only update a
  target that still holds the *old default verbatim*; if the user customized it, leave it and just report.
- mechanism: `scripts/loop.{sh,in-place.sh}` (`visual_verify_block` now also reads `facets.layer`);
  `scripts/consolidate-ideas.mjs` (carries a unit's `visualVerify` through to the task);
  `docs/designs/visual-verification.md`, `docs/HARNESS.md` (two-tier model).
- breaking: none (a task with no flag simply gains layer-based auto-fire; suppress with `visualVerify:false`).

## 1.13.1 → 1.14.0 — dashboard restyle (cream/amber)
- mechanism: `dashboard/server.js` (full restyle + `failures.jsonl` aggregation → failed-attempts pill).
- config: none. breaking: none.

## 1.13.0 → 1.13.1 — ignore ideas-pipeline scratch dirs entirely
- manual attention: root `.gitignore` — the template now ignores `.harness/.pending-tasks/*` and
  `.harness/.pending-questions/*` wholesale (keeping each `.gitkeep`). The upgrade does NOT edit the user's
  `.gitignore`; if theirs still uses the old `*.json`-only rules, tell them to widen it by hand.
- config: none. breaking: none.

## 1.12.0 → 1.13.0 — content alignment (## Overview spec convention)
- mechanism: `scripts/consolidate-ideas.mjs` (+ `.sh`) now writes a leading `## Overview` into each spec;
  `docs/HARNESS.md` documents it.
- manual attention: `tracking/IDEAS.md` became a committed starter inbox — user-data, not reconciled.
- config: none. breaking: none.

## 1.11.1 → 1.12.0 — operational skills, drop `gate:"gate"`
- mechanism/docs: `docs/HARNESS.md` + authoring guidance dropped the dead-end `gate:"gate"` value (gate is
  now `null | "needs-human"`). No installed *data* migration — but if a target's `TASKS.json` still contains
  a literal `"gate":"gate"`, flag it under manual attention (the loop treats only `"needs-human"` as gated).
- (The three operational skills added this version — review-failed, loop-recover, pre-loop-checkin — are
  plugin skills, not files installed into `.harness/`, so nothing to reconcile.)
- config: none. breaking: none.

## 1.11.0 → 1.11.1 — cold-start ladder model refresh
- config/state: `config/facets.json` `tiers.ladder` example refreshed to `claude-sonnet-5`. This file is
  tailored per project, so the upgrade leaves it alone — informational only.

## 1.10.0 → 1.11.0 — generalize visual verification beyond browser UI
- config: `config/harness.env` — ACTION: add the `VISUAL_VERIFY_HOOK` block + `VISUAL_VERIFY_WORKTYPES`
  (default `component`) if absent. `UI_VERIFY_HOOK` is kept as a back-compat alias, so a target still using
  the old name keeps working — no removal needed.
- renamed/removed: `docs/designs/ui-verification.md` → `docs/designs/visual-verification.md` (remove the old,
  add the new).
- mechanism: `scripts/loop.{sh,in-place.sh}` (`ui_verify_block` → `visual_verify_block`).
- breaking: none (alias preserved).

---

### Older context (pre-1.11 — reconstruct from `git log` if upgrading a very old install)
A harness from before ~1.11 predates version stamping and much of the current file set. The upgrade skill's
"missing in target" detection will surface any absent files; notable additions by version:
`dashboard/*` + `check-task-scope.sh` (1.3.0), `consolidate-ideas.{mjs,sh}` + the ideas pipeline (1.4.0),
the `mark-*.sh` triad + owner-overlay `tracking/*.json` (1.2.0), and the `config/`, `scripts/`, `docs/`
regrouping (1.1.0). For such installs, prefer re-running `implementation-harness-create` in update mode if
the drift is large.
