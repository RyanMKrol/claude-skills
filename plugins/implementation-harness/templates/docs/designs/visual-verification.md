# Visual verification — design (optional, opt-in)

Automated checks (typecheck, unit tests, build) can all pass while a change is still visibly broken —
an element present in the DOM but never painted, a style that doesn't apply, a modal that never opens,
a native screen that lays out wrong, a generated chart with the axes swapped. This was born from a
real caught bug: a UI element that passed every automated check while never actually rendering. The
fix isn't a better automated check (there may not be one cheap enough) — it's requiring an agent to
actually LOOK at the result before declaring the task done.

**Not just browsers.** "Visual output" is anything you can capture and eyeball: a web page, a
native/desktop app window, a mobile screen in a simulator, a generated image/chart/PDF. The mechanism
is platform-agnostic — you supply the capture command, the harness supplies the discipline.

## The mechanism (generic, ships in the harness)

- **`VISUAL_VERIFY_HOOK`** (`config/harness.env`) — a command that produces something a human or
  another Claude agent can visually inspect (a screenshot, a rendered dump, whatever fits your stack).
  Empty by default — zero cost for projects with no visual surface. (The old name `UI_VERIFY_HOOK` is
  still honoured as a back-compat alias.)
- **A task fires the check via a two-tier, facets-driven model:**
  - **Explicit flag (wins, any platform)** — a task-level `"visualVerify": true` fires it regardless of
    facets/platform (an iOS-screen task, a desktop window, an image-generation task); `"visualVerify":
    false` hard-suppresses it. Omit the flag to use the facets heuristic ↓.
  - **Facets heuristic (auto-fire, no flag needed)** — for a task with no flag it auto-fires when:
    (a) its `facets.workType` is **inherently visual** — in `VISUAL_VERIFY_WORKTYPES` (default
    `"component style"`) — on ANY layer; OR (b) its `facets.layer` is in `VISUAL_VERIFY_LAYERS` (default
    `"frontend"`) **unless** its work-type is clearly non-visual (`VISUAL_VERIFY_SKIP_WORKTYPES`, default
    `"docs config logging"`). So a frontend task is verified by default; a pure-CSS `style` or a new
    `component` on any layer is verified; a frontend `docs` change is not.
  - **The "maybe visual" tier is authored, not auto** — `bugfix`/`feature`/`migration` on a *non*-frontend
    layer can still touch the UI (a backend migration changing an API the UI reads, a bugfix fixing a
    render). These are NOT auto-fired; instead the **`add-to-backlog` / `convert-ideas` / `review-failed`
    skills** ask/judge at authoring time and set `"visualVerify": true` when warranted. That's how the
    judgment gets encoded — the authors are usually AI agents, so the convention lives in the skills.
  When it fires, `loop.sh`/`loop.in-place.sh` inject a fixed instruction block into BOTH the builder's
  prompt and — if that task is sampled — the independent auditor's prompt (a stricter PASS/FAIL-framed
  variant), telling them to run the hook and record/judge what they OBSERVED. Every other task (and
  every project that leaves `VISUAL_VERIFY_HOOK` empty) pays nothing.
- **`SCOPE_EXEMPT_GLOBS`** (`config/harness.env`) — if your `VISUAL_VERIFY_HOOK` target is itself a
  project-owned script that needs updating alongside the change it verifies (see the "living artifact"
  pattern below), list its path here so `structural_checks` doesn't flag it as scope creep. Empty by
  default (fully strict).

This is deliberately thin — the harness ships NO Playwright, no screenshot library, no simulator
tooling, no browser-automation code. What the hook actually DOES is entirely your project's stack.

## Worked examples (all bring-your-own — none are shipped)

A single `VISUAL_VERIFY_HOOK` command is enough even for a project with several visual surfaces: point
it at a small dispatcher script that inspects the task/scope and captures the right thing.

- **Browser** — the "living artifact" pattern (below): `VISUAL_VERIFY_HOOK="node scripts/visual-check.mjs"`.
- **macOS desktop app** — capture the running window: `VISUAL_VERIFY_HOOK="screencapture -x /tmp/app.png"`
  (or a script that focuses the app first, then captures).
- **iOS simulator** — boot the app, then grab the screen:
  `VISUAL_VERIFY_HOOK="xcrun simctl io booted screenshot /tmp/app.png"` (wrap it in a script that
  builds + installs + launches onto the booted simulator first).
- **Android emulator** — `VISUAL_VERIFY_HOOK="adb exec-out screencap -p > /tmp/app.png"`.
- **Generated image / chart / PDF** — render the artifact the task produces to a file:
  `VISUAL_VERIFY_HOOK="npm run render -- --out /tmp/out.png"`.

In every case the agent runs the hook, opens the resulting file, and records what it actually saw.

## A worked pattern: the "living artifact" harness script (browser example)

One concrete way to implement `VISUAL_VERIFY_HOOK` for a web app, proven in a real project, is a small
script the project owns (e.g. `scripts/visual-check.mjs`) that defines two things:

- **`PAGES`** — a list of `{ name, path }` routes to screenshot as a baseline (every top-level
  page/view in the app).
- **`FLOWS`** — a list of `{ name, path, actions(page) }` — named INTERACTION sequences (open a
  modal, expand a menu, submit a form) that reach states a static page screenshot can't, using
  whatever browser-automation library your stack already uses (Playwright, Puppeteer, Cypress, …).

The script drives a headless browser through every `PAGES` and `FLOWS` entry, saving screenshots to a
scratch directory, and prints their paths so the agent (builder or auditor) can open and look at them.

**The key discipline:** this script is a LIVING artifact — a task that adds a new page or a new
interactive state must add a matching `PAGES`/`FLOWS` entry in the SAME commit, so the next visual
check exercises what it added. This is exactly the "always allowed to touch" case `SCOPE_EXEMPT_GLOBS`
exists for — set it to the script's path (e.g. `SCOPE_EXEMPT_GLOBS="scripts/visual-check.mjs"`) so
adding an entry never trips scope creep on an unrelated task. (The same idea generalizes: a simulator
project might keep a `SCREENS`/`FLOWS` manifest driving `xcrun simctl`.)

This pattern is NOT shipped as harness code — adopt it once a project has enough visual surface to make
a shared capture script worth maintaining. A one-surface project doesn't need it; `VISUAL_VERIFY_HOOK`
pointing straight at a one-off capture command is plenty.

## What this does NOT do

- It does not replace the audit gate's text-diff review — it supplements it for visual work, since a
  diff review alone cannot see what the output actually looks like.
- It does not run for a task that hasn't opted in (no `visualVerify` flag, and neither the layer nor
  the work-type matches the facets heuristic), even if `VISUAL_VERIFY_HOOK` is set — a backend
  feature/logging/config task with no visual surface gets no instruction, no added tokens.
- It is not mandatory to adopt. A project can set `VISUAL_VERIFY_HOOK` to a single ad-hoc command and
  set `visualVerify` per task, skipping the `PAGES`/`FLOWS` convention entirely if its surface is small.
