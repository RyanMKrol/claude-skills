# B07: Usage-limit detection can false-positive on repo content; the audit-path RL loop never gives up

**Type**: bug · **Priority**: P1 · **Effort**: M
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh`: `rl_detect` (parity-manifest function — keep byte-identical), the audit-path RL retry loop inside the done path, `rl_selftest`
**Release**: MINOR bump · MIGRATIONS entry (mechanism, both variants) · checksums · parity (rl_detect IS in tests/loop-parity.test.sh's manifest)

## ⚠️ Status — PARTIALLY LANDED (2026-07-13, v1.74.1)

- ✅ **Fix 1 (tool_result false positives) — DONE.** `rl_detect` now runs the raw stream through a new
  `rl_cli_said` helper that drops `type:"user"` (tool_result) events before the `RL_HARD_RE` grep, keeping
  non-JSON stderr + result/assistant events. Both variants, kept parity-identical.
- ✅ **Fix 3 (rl_selftest fixtures) — DONE.** `loop-ratelimit.test.sh` gained case 4a (hard wording only in a
  tool_result + success → NOLIMIT) and 4b (genuine notice on a non-JSON stderr line → LIMIT).
- ❌ **Fix 2 (cap the audit-path RL loop) — STILL OPEN.** The done-path auditor retry (`loop.sh` ~L1221–1230
  / in-place equivalent: `if [ "$arc" = 10 ]; then … sleep "$rlpoll"; continue`) still has NO
  `rl_waited`/`RL_MAX_WAIT` accounting — unlike the build path (~L1397+). A genuine, prolonged audit-path
  limit loops forever. (The most common trigger — the false positive from Fix 1 — is now gone, so this is
  much less likely to fire, but the unbounded-loop hazard remains.) **This is the remaining work on B07.**

## Problem

Two related defects in the 1.69.0 rate-limit fix:

1. **False positives from tool_results.** `rl_detect` greps `RL_HARD_RE` ("hit your session limit"
   wording) against the RAW stream (`$raw`), which contains every tool_result — i.e. the contents
   of files the agent reads/writes. A project whose task is literally about limit UX (common in
   LLM-wrapper apps: UI copy like "You've reached your usage limit"), or **the harness's own
   installed `loop-ratelimit.test.sh`** (its fixtures contain "You have hit your session limit"),
   puts matching text into tool_results → `run_claude` returns rc 10 **even on a successful run**,
   on every attempt of any task that touches such a file.
2. **The audit path's RL loop is unbounded.** The build path's RL backoff is capped by
   `RL_MAX_WAIT` (then exit 5 for supervise). The audit path's retry loop (`while :; do … sleep
   "$rlpoll"; continue; done` in the done path) has NO waited-counter — combined with (1), a task
   whose DIFF contains the limit wording wedges the loop asleep forever, silently.

## Proposed fix

1. **Scope the raw-stream scan to where the real notice lives.** The genuine limit notice arrives
   as a `result` event (`is_error`) or on stderr — never inside a `tool_result`. Instead of
   grepping the whole `$raw`, pre-filter to non-tool events:
   ```bash
   jq -R 'fromjson? | select(.type != "user" and .type != "tool_result")' ... # shape to verify
   ```
   Verify the actual stream-json event taxonomy empirically against a real transcript (the
   `.claude-out.*.jsonl` files in any consumer repo) before choosing the filter; the key
   requirement is: tool_result payload text must NOT be scanned, `result`/error/stderr lines MUST
   be. Keep `rl_detect`'s two-regex structure (tight `RL_HARD_RE` both streams filtered; broad
   `RL_RE` `$out`-only on crashed builds) and keep it byte-identical across variants.
2. **Cap the audit-path RL loop** with the same `rl_waited`/`RL_MAX_WAIT` accounting as the build
   path; on exhaustion exit 5 (supervise relaunches after RETRY_INTERVAL).
3. Extend `rl_selftest` with: (a) a fixture where the limit wording appears ONLY inside a
   tool_result event → must NOT detect; (b) the real notice as a `result` event → must detect.
   (`loop-ratelimit.test.sh` drives `rl_selftest`, so tests come mostly free.)

## Acceptance criteria

- A successful (rc 0) run whose tool_results contain limit wording → rc stays 0, no RL branch.
- A genuine limit notice (result event / stderr) → still detected on both build and audit paths.
- Audit-path limited longer than RL_MAX_WAIT → loop exits 5, supervise takes over.
- `tests/loop-parity.test.sh` stays green (rl_detect identical in both variants).

## Notes

The residual "forks tight-loop until upgraded" memory item is about consumer repos on old
versions — unaffected by this; they need the upgrade skill run regardless.
