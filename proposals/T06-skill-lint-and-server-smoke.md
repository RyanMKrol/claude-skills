# T06: Skill non-ASCII lint + dashboard server smoke test

**Type**: testing · **Priority**: P3 · **Effort**: S
**Affected files**: NEW dev-level `plugins/implementation-harness/tests/skill-lint.test.sh`; NEW `templates/dashboard/server-smoke.test.sh` (or .mjs)
**Release**: PATCH bump · MIGRATIONS entry only for the templates-side smoke test · checksums

## 1. Skill lint (dev-level — plugin authoring guard, not shipped)

**Problem**: the 1.66.0 "command not found" incident: a non-ASCII character (em-dash) inside a
MULTI-LINE fenced bash block in a SKILL.md corrupted the Bash tool's parsing of following lines.
The fix moved that command into a script, but nothing prevents the next one. Also Q03's path-
prefix rule is grep-lintable.

**Design**: `tests/skill-lint.test.sh` walks every `SKILL.md` under `skills/` and
`templates/skills/`, extracts fenced ```bash blocks (awk state machine), and fails on:
- non-ASCII bytes inside a multi-line block (`LC_ALL=C grep -n '[^ -~\t]'` within the block —
  allow single-line blocks or relax to: only flag blocks with >1 command line);
- (adopt from Q03 once landed) harness paths missing the `.harness/` prefix in command lines.
Print file:line for each hit. Expect to whitelist a few legitimate hits (e.g. box-drawing in
echoed banners) via an inline allowlist of exact lines — keep it tiny and commented.

## 2. Dashboard server smoke (templates-side)

**Problem**: `server.js` (~1400 lines) has ZERO execution in CI — `node --check` only parses it.
A boot-time crash (or a route regression like B14's EADDRINUSE handling) ships silently.

**Design**: a test that builds a minimal `.harness` fixture tree (TASKS.json + empty ledgers),
starts the server on an ephemeral port (`PORT=0` support may need a 1-line change — read the
chosen port from stdout), then curls: `GET /` → 200 + contains the title; `GET /api/backlog` →
200 + valid JSON with the fixture task; `POST /api/mark-done` with an invalid id → 4xx; kill the
server; assert clean exit. Bash-driven with `curl`, or a node .mjs using fetch — prefer node (no
curl dependency guarantees; CI has node already).

## Acceptance criteria

- Both suites in CI via the existing finders (<10s each); the lint catches a planted em-dash in a
  fixture block (negative control inside the test itself, like loop-parity's).
- Server smoke leaves no orphan process on failure (trap kill).
