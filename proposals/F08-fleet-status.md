# F08: Fleet status — one view across every harness repo

**Type**: feature · **Priority**: P3 · **Effort**: M
**Affected files**: NEW global (plugin-registered) skill under `plugins/implementation-harness/skills/`; `implementation-harness:create` (append the new install to the registry); plugin README
**Release**: MINOR bump · MIGRATIONS not needed for the global skill itself (not under templates/) BUT the create-skill change is also outside templates/ — verify; checksums regen still mandatory with the bump

## Problem

The owner runs multiple harness repos (the per-dashboard title feature exists precisely because
several dashboards are open at once), but there is no single view of: which loops are running,
which backlogs are drained vs blocked, and which installs are behind the plugin version (the two
hand-forked consumer repos sat un-upgraded for months without anything surfacing it).

## Design

1. **Registry**: `~/.config/implementation-harness/projects.txt` — one absolute repo path per
   line. `create` appends the new project on scaffold (mkdir -p the dir; skip duplicates);
   `fleet-status` also offers to add/remove paths and silently skips lines whose path no longer
   exists (report them as stale entries).
2. **Skill**: a GLOBAL skill (`implementation-harness:fleet-status` — bare name per the N01 convention, landed in 1.94.0), since
   it must work from anywhere and reasons ACROSS projects (the project-local pattern exists so
   skill logic can't outrun a repo's `.harness/` — this skill only READS, so global is safe; state
   that rationale in the skill header). Read-only guarantees verbatim from pre-loop-checkin.
3. **Per repo, report**: lock held? (`$GIT_COMMON/<name>-loop.lock`), heartbeat freshness, backlog
   counts (eligible / needs-human / blocked / failed-pending-review — reuse the jq shapes from
   pre-loop-checkin), ideas-inbox size, `.harness-version` vs the plugin's current version (the
   upgrade nudge — flag hand-forks: no version marker), last integration timestamp (latest
   outcomes.jsonl ts).
4. Output: one table, worst-first (blocked/behind at top), plus one-line recommended action per
   flagged repo ("run /…-upgrade", "run /…-loop-prepare", "loop appears wedged — check it").

## Acceptance criteria

- With 2+ registered repos in different states, the table is accurate against manual inspection.
- A registered path that no longer exists → listed as stale, doesn't crash the sweep.
- Strictly read-only across ALL repos (no commits, no lock acquisition — only lock EXISTENCE
  checks).
- create registers new installs; documented in both READMEs.

## Test plan

Hermetic: two scratch harness fixtures (reuse select-task.test.sh's setup) + a temp registry file;
run the skill's underlying probe script (put the probing in a small `fleet-probe.sh` so it's
testable; the skill prose calls it) and assert the classification of each fixture.
