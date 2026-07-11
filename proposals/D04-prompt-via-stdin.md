# D04: Pass prompts (and their embedded diffs) via stdin, not argv

**Type**: design-drift / latent bug · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (`run_claude` and its call sites; the audit call embeds the full diff in the prompt)
**Release**: PATCH/MINOR bump · MIGRATIONS entry (mechanism, both variants) · checksums · parity (run_claude differs only in path vars — keep the delta minimal)

## Problem

The loops invoke `claude -p "$pr"` with the entire composed prompt as ONE argv element — and the
audit prompt embeds the full implementation diff. A lockfile-heavy diff (a few MB) can exceed
`ARG_MAX` → `execve` fails with E2BIG → the invocation dies instantly and is misclassified as a
crash ("crash / out of tokens" → 30s backoff → cold re-attempt), burning attempts on a task whose
only sin is a big lockfile.

## Proposed fix

Feed the prompt on stdin instead: `printf '%s' "$pr" | "$CLAUDE_BIN" -p ... ` (verify the CLI's
current contract for reading the prompt from stdin with `-p` — check `claude --help`; if `-p ""`
plus stdin is not supported, write the prompt to a temp file under the scratch worklog and use the
CLI's file-input mechanism). Keep `PRINT_PROMPT` echoing working. Apply to both build and audit
invocations, both variants.

## Acceptance criteria

- A synthetic 5MB prompt round-trips (fake claude in T01 asserts it receives the full text).
- Real invocation shape verified manually once against the actual CLI (this is the risky part —
  the flag semantics, not the shell).
- `PRINT_PROMPT=1` still prints the prompt; `print-prompt-banner.test.sh` green.

## Notes

Do this AFTER or WITH T01 (its fake `claude` is how you assert the prompt content survives). The
stdin switch also simplifies T01's golden-prompt tests (test #3 in its spec).
