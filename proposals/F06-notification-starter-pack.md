# F06: Notification starter pack for lifecycle hooks

**Type**: feature · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/custom/hooks/on-blocked.sh.example`, `on-drained.sh.example`, `on-exhausted.sh.example` (and siblings), `skills/customize/SKILL.md` (catalog §1 + the hooks drafting interview)
**Release**: MINOR bump · MIGRATIONS entry (custom/*.example are add-if-missing scaffolding — note that class) · checksums · **catalog rule**: any custom/ extension change must update the customize catalog in the same commit (plugin CLAUDE.md)

## Problem

The lifecycle hooks are the right extension point, but every `.example` is an empty stub and the
customize interview asks the user to compose a shell command cold. The dominant real use case —
"tell me when the loop needs me" (blocked / drained / exhausted) — has no ready-made option. The
only built-in signal is supervise's terminal bell, which requires the terminal to be visible.

## Proposed fix

1. Rewrite the relevant `.example` stubs to contain working, commented-out one-liners the user
   uncomments, each labeled:
   ```bash
   # macOS notification:
   # osascript -e "display notification \"Task $1 blocked — needs you\" with title \"harness: $HARNESS_ROOT\""
   # terminal-notifier (brew install terminal-notifier):
   # terminal-notifier -title "harness" -message "Task $1 blocked"
   # Phone push via ntfy.sh (pick a private topic):
   # curl -s -d "harness: task $1 blocked" ntfy.sh/YOUR-PRIVATE-TOPIC >/dev/null
   ```
   Keep hooks' contract: cheap, idempotent, non-fatal (they run as children; a hanging curl should
   have `--max-time 5`). Match each hook's actual argument signature — read `run_hook`'s call
   sites for what `$1…` carry per event and document per stub.
2. customize's hooks interview gains a preset: "Just notify me (recommended)" → activates
   blocked/drained/exhausted stubs with the platform-right line uncommented (ask macOS vs ntfy),
   instead of the freeform drafting question. Update the catalog row (`since:` bumps to this
   version? NO — `since` is the feature's introduction version; the hooks feature already exists.
   Add a note line in the catalog row's interview text instead).

## Acceptance criteria

- Fresh install: activating the preset yields a working notification on a synthetic
  `run_hook blocked T001` (manually verifiable; automated: assert the uncommented line shape).
- `loop-extend.test.sh` (hooks dispatcher coverage) stays green; stubs remain non-fatal with
  `--max-time` on any network call.
- Upgrade path: existing installs get missing `.example` files as add-candidates (already the
  upgrade rule for custom scaffolding); installs with ACTIVATED hooks are never touched.
