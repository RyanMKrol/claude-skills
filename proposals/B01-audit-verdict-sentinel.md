# B01: Audit verdict must be a sentinel, not a grep over the whole transcript

**Type**: bug · **Priority**: P0 · **Effort**: M
**Affected files**: `templates/scripts/loop.sh` (`audit_gate`, `audit_prompt`), `templates/scripts/loop.in-place.sh` (same functions)
**Release**: MINOR bump · MIGRATIONS entry (mechanism, both variants) · checksums · `bash -n` · parity (audit_gate/audit_prompt are NOT in the parity manifest — they differ in data access — so mirror the change by hand in both)

## Problem

The blocking audit's verdict is parsed as:

```bash
verdict="$(grep -oiE '\b(PASS|FAIL)\b' "$out" 2>/dev/null | head -1 | tr '[:lower:]' '[:upper:]')"
```

`$out` is the reassembled text of **every assistant message across the auditor's whole agentic
session** (the auditor has tools; the visual-verify block even tells it to run a hook and look at
output). The grep is case-insensitive and takes the FIRST occurrence of either word anywhere.

**Failure scenario**: the auditor narrates *"I'll run the tests to see if they pass"* before doing
any work, then concludes `FAIL` → the first match is the prose word "pass" → verdict=PASS → the
task integrates and the ledger records `verification:"audited"`. This silently defeats the exact
false-success defense the audit exists for (DESIGN.md §3–4; PRINCIPLES.md P2). The inverse flip
(prose "fail" before a PASS conclusion) burns paid attempts and pollutes calibration.

## Proposed fix

1. **Change the contract in `audit_prompt` (both variants)**: instruct the auditor that its FINAL
   line must be exactly `VERDICT: PASS` or `VERDICT: FAIL` (uppercase, nothing after it), and that
   the verdict line is the only thing the harness reads.
2. **Change the parse in `audit_gate` (both variants)**: read the LAST non-empty line of `$out`
   and match it against `^VERDICT: (PASS|FAIL)$` (case-sensitive). Suggested shape:
   ```bash
   verdict="$(awk 'NF{last=$0} END{print last}' "$out" | grep -oE '^VERDICT: (PASS|FAIL)$' | grep -oE 'PASS|FAIL' || true)"
   ```
3. **No-verdict handling**: if the sentinel is absent/malformed, treat it as an audit FAIL (a
   normal failed attempt — never a pass; a mumbling auditor has not confirmed the work) and log
   loudly that the verdict was unparseable, so a systematic prompt problem is visible in the log
   and `failures.jsonl` (`record_failure` kind, e.g. `audit-unparseable`).
4. Keep writing the full audit output to the audit log (see B04) so a human can adjudicate.

## Acceptance criteria

- An auditor transcript containing "pass" in prose but ending `VERDICT: FAIL` → task fails the
  attempt (and vice versa).
- A transcript with no sentinel → failed attempt with a distinct failure kind, loud log line.
- The audit prompt states the sentinel contract explicitly.
- Both variants byte-equivalent in the parsing logic (even though the functions as a whole differ).

## Test plan

Add a small `--audit-parse-selftest` dispatch flag (mirroring the existing `--rl-selftest`
pattern) that feeds fixture transcripts through the extraction: prose-pass-then-FAIL,
prose-fail-then-PASS, sentinel-only, no-sentinel, trailing-whitespace variants. Add a
`audit-parse.test.sh` under `templates/scripts/` invoking it for whichever variant(s) are present
(copy the pattern in `select-task.test.sh`).

## Notes

- Do NOT feed the failure reason back to the builder (PRINCIPLES.md P4 — no audit feedback).
- This composes with C01 (loop-lib extraction): if C01 lands first, fix once in the lib.
