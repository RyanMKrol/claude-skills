# .harness/custom/CLAUDE.md — your project-specific harness instructions

This is the **customization overlay** for `.harness/CLAUDE.md`. Anything you add here loads automatically
(the pristine `.harness/CLAUDE.md` imports it with `@custom/CLAUDE.md`), and **harness upgrades never touch
this file** — so this is where your edits belong.

## Why this file exists — the overlay rule

The harness's own prose files (`.harness/CLAUDE.md`, `README.md`, and everything under `docs/`) are
**plugin-owned**: `implementation-harness:implementation-harness-upgrade` refreshes them from the latest plugin version. If you
edit them in place, your changes collide with every future upgrade and force a manual reconcile. Instead,
put project-specific additions in the matching file under `.harness/custom/` — this tree **mirrors** the
harness layout (`custom/CLAUDE.md`, `custom/README.md`, `custom/docs/HARNESS.md`, …). The pristine files
then stay byte-identical to the plugin and upgrade cleanly, while your customizations ride along untouched.

(Scripts and config are NOT covered by this prose overlay — customize the loop via `config/harness.env`,
and if you need a script change, flag it to upstream into the plugin rather than hand-editing in place.)

Add your project's harness-authoring conventions, house rules, and reminders below.

<!-- Add your project-specific instructions here. -->
