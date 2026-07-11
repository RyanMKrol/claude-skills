# Q03: add-to-backlog uses paths missing the `.harness/` prefix throughout

**Type**: skill-quality · **Priority**: P1 · **Effort**: S
**Affected files**: `templates/skills/implementation-harness-add-to-backlog/SKILL.md` (throughout), `implementation-harness-update-ladder/SKILL.md` (milder: §5 vs its pre-flight)
**Release**: PATCH bump · MIGRATIONS entry (mechanism/skills) · checksums

## Problem

Nearly every jq command and much of the prose in add-to-backlog targets `tracking/TASKS.json`,
`config/facets.json`, `config/harness.env`, `config/facet-misfits.jsonl` — WITHOUT the `.harness/`
prefix (e.g. `jq -r '.tasks[].id' tracking/TASKS.json`). Run from the repo root — the normal cwd —
those paths don't exist. Every other skill consistently anchors on `.harness/…`. A strong model
recovers by noticing the ENOENT; the cheap models this plugin is philosophically committed to may
not, or may waste turns. update-ladder has a milder inconsistency: its pre-flight uses
`.harness/config/facets.json` but §5 says "Edit `config/facets.json`".

## Proposed fix

Mechanical sweep of both files: prefix every repo-relative harness path with `.harness/`
(commands AND prose). Grep-verify afterwards:

```bash
grep -nE '(^|[^./a-zA-Z])((tracking|config|tasks|worklog|ledgers|docs)/)' \
  templates/skills/implementation-harness-add-to-backlog/SKILL.md \
  templates/skills/implementation-harness-update-ladder/SKILL.md
# every remaining hit must be inside an explicit `.harness/` context or a spec-FIELD value
```

Careful: task `spec` FIELD VALUES are repo-relative by schema (`.harness/tasks/TNNN.md` is the
stored string) — don't double-prefix example JSON values that are already correct; the fix targets
COMMANDS and file references, not schema examples that already carry `.harness/`.

## Acceptance criteria

- Every jq/shell command in both skills runs from the repo root against a real scaffold (spot-run
  the read-only ones in a scratch install).
- The grep above returns only legitimate hits (schema value examples).
- T06's non-ASCII/skill-lint suite (if landed) can adopt this grep as a permanent lint — note it
  there.
