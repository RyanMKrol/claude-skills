# UI visual verification — design (optional, opt-in)

Automated checks (typecheck, unit tests, build) can all pass while a UI change is still visibly
broken — an element present in the DOM but never painted, a style that doesn't apply, a modal that
never opens. This was born from a real caught bug: a UI element that passed every automated check
while never actually rendering. The fix isn't a better automated check (there may not be one cheap
enough) — it's requiring an agent to actually LOOK at the result before declaring the task done.

## The mechanism (generic, ships in the harness)

- **`UI_VERIFY_HOOK`** (`config/harness.env`) — a command that produces something a human or
  another Claude agent can visually inspect (a screenshot, a rendered page dump, whatever fits your
  stack). Empty by default — zero cost for projects without a browser UI.
- **Gated on `facets.workType == "component"`** (an existing, universal facet value — "new/changed
  UI component or page," see `config/facets.json`) — not a new taxonomy axis. When
  `UI_VERIFY_HOOK` is set and a task's `workType` is `component`, `loop.sh`/`loop.in-place.sh`
  inject a fixed instruction block into BOTH the builder's prompt and — if that task is sampled —
  the independent auditor's prompt, telling them to run the hook and record what they OBSERVED
  before declaring done. Every other task (and every project that leaves `UI_VERIFY_HOOK` empty)
  pays nothing.
- **`SCOPE_EXEMPT_GLOBS`** (`config/harness.env`) — if your `UI_VERIFY_HOOK` target is itself a
  project-owned script that needs updating alongside the UI change it verifies (see the worked
  pattern below), list its path here so `structural_checks` doesn't flag it as scope creep on every
  UI task that touches it. Empty by default (fully strict).

This is deliberately thin — the harness does not ship Playwright, a screenshot library, or any
browser-automation code. What that hook actually DOES is entirely up to your project's own stack.

## A worked pattern: the "living artifact" harness script

One concrete way to implement `UI_VERIFY_HOOK`, proven in a real project, is a small script the
project itself owns (e.g. `scripts/visual-check.mjs`) that defines two things:

- **`PAGES`** — a list of `{ name, path }` routes to screenshot as a baseline (every top-level
  page/view in the app).
- **`FLOWS`** — a list of `{ name, path, actions(page) }` — named INTERACTION sequences (open a
  modal, expand a menu, submit a form) that reach UI states a static page screenshot can't, using
  whatever browser-automation library your stack already uses (Playwright, Puppeteer, Cypress, …).

The script drives a headless browser through every `PAGES` entry and every `FLOWS` entry, saving
screenshots to a scratch directory, and prints their paths so the agent (builder or auditor) can
open and actually look at them.

**The key discipline:** this script is a LIVING artifact — a UI task that adds a new page or a new
interactive state (a new modal, a new expandable section) must add a matching `PAGES`/`FLOWS` entry
in the SAME commit, so the next UI task's visual check actually exercises what it added. This is
exactly the kind of "always allowed to touch" file `SCOPE_EXEMPT_GLOBS` exists for — set it to the
script's path (e.g. `SCOPE_EXEMPT_GLOBS="scripts/visual-check.mjs"`) so adding a `FLOWS` entry never
trips scope creep on an unrelated UI task.

This pattern is NOT shipped as harness code — it's a convention worth adopting deliberately, once a
project has enough UI surface to make a shared visual-check script worth maintaining. A one-page
project doesn't need it; `UI_VERIFY_HOOK` pointing straight at a one-off screenshot command is
plenty.

## What this does NOT do

- It does not replace the audit gate's text-diff review — it supplements it for UI work
  specifically, since a diff review alone cannot see what the UI actually looks like.
- It does not run automatically for non-`component` work-types, even if `UI_VERIFY_HOOK` is set —
  a backend task with no visual surface gets no instruction, no added tokens.
- It is not mandatory to adopt. A project can set `UI_VERIFY_HOOK` to a single ad-hoc command and
  skip the `PAGES`/`FLOWS` convention entirely if its UI surface is small.
