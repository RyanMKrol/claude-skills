# F13: Auditor observations → ideas inbox

**Type**: feature · **Priority**: P3 · **Effort**: M (small code, careful principle work)
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (`audit_prompt` + the PASS path of `audit_gate`), `templates/docs/HARNESS.md` (ideas pipeline note)
**Release**: MINOR bump · MIGRATIONS entry (mechanism, both variants) · checksums · parity

## Problem

The sampled auditor reads the spec + full diff with a strong model — and any collateral value it
notices (an adjacent bug, a near-miss, a refactor opportunity) is thrown away. Meanwhile the
harness has a purpose-built inbox for exactly such observations (`tracking/IDEAS.jsonl` → the
convert-ideas triage).

## Design — and the principle constraint that shapes it

PRINCIPLES P4 forbids audit feedback **to the builder**. This routes observations to the **human
planning stage** instead — the sanctioned channel — and only the LOOP writes state (P5):

1. `audit_prompt` (both variants): after the verdict-sentinel contract (B01 — land B01 first,
   this extends its prompt), allow an optional trailer:
   ```
   OBSERVATIONS:
   - <one line each, only genuinely-worth-capturing adjacent findings; omit the section if none>
   ```
2. `audit_gate`, **PASS path only**: parse lines under `OBSERVATIONS:` (bounded — cap at, say, 5),
   and for each, append a normal ideas row to `tracking/IDEAS.jsonl` tagged with provenance:
   `{"id": …, "title": "[from-audit:TNNN] …", "description": …, "capturedAt": …}` — matching the
   capture-idea row schema exactly (open that skill and copy it). The write goes through the same
   commit the loop is already making for the outcome (worktree: fold into `record_outcome`'s
   detached-worktree commit; in-place: the status-flip commit) — no extra push.
3. **FAIL path: discard observations entirely.** FAIL reasons already go to the audit log and must
   stay out of circulation — an observation channel on the FAIL path would become a feedback side
   door (the exact §4.3 poison).
4. convert-ideas needs no change — from-audit rows are ordinary ideas; the sweep's questioning
   gives the human the accept/reject decision.

## Acceptance criteria

- PASS with observations → N new IDEAS.jsonl rows, committed by the loop, dashboard inbox shows
  them with the from-audit marker; builder-visible files unchanged.
- FAIL with observations → nothing captured anywhere except the audit log.
- No observations section → zero change to today's behavior.
- Malformed trailer → ignored with a WARN log, never fails the gate.
- Parity between variants; ideas-row schema identical to capture-idea's.

## Test plan

Extend B01's audit-parse selftest fixtures with observation trailers (PASS+obs, FAIL+obs,
malformed). Behavioral end-to-end lands with T01 (fake auditor emits the trailer → assert the
JSONL rows on origin/main).
