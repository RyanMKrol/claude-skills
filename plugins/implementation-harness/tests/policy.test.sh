#!/usr/bin/env bash
#
# policy.test.sh — hermetic test suite for policy.jq, focused on downward exploration
# (designs/difficulty-autotune.md). Every case below invokes the REAL policy.jq via `jq -n -f` —
# no mocking, no reimplementation. The convergence simulation seeds synthetic ledger rows BETWEEN
# successive real policy.jq calls, exactly mirroring what the loop would write for a real explored
# task, to prove the epsilon-greedy probe actually self-terminates: promotion on success, permanent
# rejection on failure. No git repo / filesystem state needed — everything lives in bash variables.
# Run standalone: plugins/implementation-harness/tests/policy.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
POLICY_JQ="$SCRIPT_DIR/policy.jq"
FAIL=0

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

LADDER5='[{"model":"claude-haiku-4-5","effort":null},{"model":"claude-sonnet-5","effort":"low"},{"model":"claude-sonnet-5","effort":"medium"},{"model":"claude-sonnet-5","effort":"high"},{"model":"claude-opus-4-8","effort":"high"}]'
LADDER4='[{"model":"claude-sonnet-5","effort":"low"},{"model":"claude-sonnet-5","effort":"medium"},{"model":"claude-sonnet-5","effort":"high"},{"model":"claude-opus-4-8","effort":"high"}]'

# run_policy <rowsJson> <tiersJson> <explorePM> <riskJson> [layer] [wt] [exploreCooldownN] — echoes
# "chosen pm exploreIdx"
run_policy() {
  local layer="${5:-ui}" wt="${6:-style}" cooldown="${7:-40}"
  jq -rn --argjson rows "$1" --argjson tiers "$2" \
     --arg layer "$layer" --arg wt "$wt" --argjson floor 0.75 --argjson minN 6 --argjson coldIdx 0 \
     --argjson manualFail '{}' --argjson risk "$4" --argjson explorePM "$3" --argjson exploreCooldownN "$cooldown" \
     --argjson auditCount -1 --argjson auditStartN 3 --argjson auditFloorN 8 --argjson auditFloorPM 100 \
     -f "$POLICY_JQ"
}

# seed_rows <n_ok> <n_blocked> <model> <effortJson> <idPrefix> — echoes a JSON array of synthetic
# outcomes.jsonl-shaped rows for layer=ui/workType=style, all starting+finishing at (model, effort).
seed_rows() {
  jq -cn --argjson n_ok "$1" --argjson n_bad "$2" --arg model "$3" --argjson effort "$4" --arg prefix "$5" '
    [range(0;$n_ok) | {id:($prefix+"ok"+(.|tostring)), facets:{layer:"ui",workType:"style",risk:[]},
       startModel:$model, startEffort:$effort, finalModel:$model, finalEffort:$effort, blocked:false}]
    + [range(0;$n_bad) | {id:($prefix+"bad"+(.|tostring)), facets:{layer:"ui",workType:"style",risk:[]},
       startModel:$model, startEffort:$effort, finalModel:$model, finalEffort:$effort, blocked:true}]
  '
}
# append_row <rowsJson> <newRowJson> — echoes rowsJson + [newRowJson]
append_row() { jq -cn --argjson a "$1" --argjson b "$2" '$a + [$b]'; }

# Established-cell fixture: an already-calibrated cell pinned to sonnet-5/low, mirroring the shape
# (n=56) of the real ui/style cell found during empirical validation against actual consumer repos —
# 50 successes / 6 failures (89% >= the 75% floor), comfortably eligible at index 1, zero samples at
# index 0 (Haiku) — the exact structural gap this feature fixes.
ESTABLISHED="$(seed_rows 50 6 claude-sonnet-5 '"low"' est)"

echo "--- static matrix ---"

# 1. Regression guard: explorePM config = 0 must be bit-for-bit identical to pre-feature behavior.
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 0 '[]')"
assert "explorePM=0 → chosen unaffected (still 1)" [ "$chosen" = "1" ]
assert "explorePM=0 → output probability always 0" [ "$pm" = "0" ]

# 2. The literal bug reproduction: established cell + explorePM configured nonzero → probes index 0.
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 150 '[]')"
assert "established cell: chosen=1 (sonnet/low, pinned)" [ "$chosen" = "1" ]
assert "established cell: explorePM=150 → output probability 150" [ "$pm" = "150" ]
assert "established cell: exploreIdx targets index 0 (Haiku)" [ "$exploreIdx" = "0" ]
assert "established cell: remain=0 (dashboard: armed/offered now)" [ "$remain" = "0" ]
assert "established cell: eN=0 (dashboard: candidate rung has no probes yet)" [ "$eN" = "0" ]

# 3. Cold cell (nothing matches layer/wt) → no candidate below the cold-start floor.
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 150 '[]' ui nonexistent-worktype)"
assert "cold cell: chosen=coldIdx (0)" [ "$chosen" = "0" ]
assert "cold cell: exploreIdx=-1 (nothing below the floor)" [ "$exploreIdx" = "-1" ]
assert "cold cell: remain=-2 (dashboard: no cheaper rung)" [ "$remain" = "-2" ]
assert "cold cell: output probability 0" [ "$pm" = "0" ]

# 4. Risk-flagged task on the same established cell — never a vehicle for probing index 0.
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 150 '["touches-schema"]')"
assert "risk task: exploreIdx=-1 (floor clamp, never probes index 0)" [ "$exploreIdx" = "-1" ]
assert "risk task: output probability 0" [ "$pm" = "0" ]

# 5. Settled rejection: the rung below chosen already has >= minN samples and failed the floor.
REJECTED="$(jq -cn --argjson a "$ESTABLISHED" --argjson b "$(seed_rows 1 5 claude-haiku-4-5 null bad)" '$a + $b')"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$REJECTED" "$LADDER5" 150 '[]')"
assert "settled rejection: chosen stays 1 (index 0 already failed)" [ "$chosen" = "1" ]
assert "settled rejection: exploreIdx still points at 0" [ "$exploreIdx" = "0" ]
assert "settled rejection: output probability forced 0 (never re-probed)" [ "$pm" = "0" ]
assert "settled rejection: remain>0 (dashboard: counting down to re-arm)" [ "$remain" -gt 0 ]
assert "settled rejection: eN=6 (dashboard: full batch gathered at the candidate rung)" [ "$eN" = "6" ]
assert "settled rejection: eWinOk=1 (dashboard: 1/6 passed — the batch the verdict judged)" [ "$eWinOk" = "1" ]

# 6. Reindexing: the SAME rows, evaluated against the ladder before vs. after Haiku is inserted.
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$ESTABLISHED" "$LADDER4" 150 '[]')"
assert "pre-insertion (4-rung ladder): sonnet/low was index 0" [ "$chosen" = "0" ]
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 150 '[]')"
assert "post-insertion (5-rung ladder), same rows: chosen re-resolves to 1" [ "$chosen" = "1" ]
assert "post-insertion: exploreIdx correctly targets the new index-0 rung" [ "$exploreIdx" = "0" ]

echo "--- convergence simulation (promotion branch) ---"

rows="$ESTABLISHED"
for i in 1 2 3 4 5 6; do
  read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
  assert "promotion round $i: still probing index 0 (under-sampled)" [ "$exploreIdx" = "0" ]
  assert "promotion round $i: probability still 150" [ "$pm" = "150" ]
  # simulate a real explored task that ran on Haiku and SUCCEEDED
  row="$(jq -cn --arg id "prom$i" '{id:$id, facets:{layer:"ui",workType:"style",risk:[]},
    startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:false}')"
  rows="$(append_row "$rows" "$row")"
done
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "promotion: after 6/6 Haiku successes, chosen flips to 0" [ "$chosen" = "0" ]
assert "promotion: exploreIdx recomputes to -1 (nothing left below index 0)" [ "$exploreIdx" = "-1" ]
assert "promotion: remain=-2 (index 0 became normally eligible — nothing cheaper below it)" [ "$remain" = "-2" ]
assert "promotion: self-terminated (output probability 0, no bookkeeping needed)" [ "$pm" = "0" ]

echo "--- convergence simulation (rejection branch) ---"

rows="$ESTABLISHED"
for i in 1 2 3 4 5 6; do
  read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
  assert "rejection round $i: still probing index 0 (under-sampled)" [ "$exploreIdx" = "0" ]
  assert "rejection round $i: probability still 150" [ "$pm" = "150" ]
  # simulate a real explored task that ran on Haiku and FAILED
  row="$(jq -cn --arg id "rej$i" '{id:$id, facets:{layer:"ui",workType:"style",risk:[]},
    startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:true}')"
  rows="$(append_row "$rows" "$row")"
done
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "rejection: after 6/6 Haiku failures, chosen stays 1" [ "$chosen" = "1" ]
assert "rejection: settled rejection (output probability forced 0)" [ "$pm" = "0" ]
# NOTE: pre-recheck, this suite asserted a directly-appended 7th failure kept the rung permanently
# silent (0 probability forever). Under the recheck mechanism that's no longer a reachable real-world
# state — a 7th touch can only ever be recorded if `offer` was true at n=6, which it wasn't (cooldown
# not elapsed) — so directly appending one here would test an artificial state, not real behavior. The
# "--- recheck ---" section below supersedes this with the actually-reachable equivalent: cooldown
# gating via ORDINARY cell activity (rows that don't touch the candidate rung), which is what really
# grows `sinceTouch` in production.

echo "--- recheck: cooldown gating (rejected rung stays silent until enough OTHER cell activity lands) ---"

# Continue from a freshly settled rejection (6/6 failures, n=6, just settled — 'rows' from above).
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "cooldown: freshly rejected, still 0 probability" [ "$pm" = "0" ]
assert "cooldown: exploreIdx still points at 0" [ "$exploreIdx" = "0" ]

# Append 39 filler rows of ORDINARY traffic at the chosen tier (index 1) — doesn't touch the candidate.
FILLER39="$(seed_rows 39 0 claude-sonnet-5 '"low"' fill)"
rows="$(jq -cn --argjson a "$rows" --argjson b "$FILLER39" '$a + $b')"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "cooldown: still 0 after 39 filler rows (not yet elapsed)" [ "$pm" = "0" ]
assert "cooldown: exploreIdx unchanged" [ "$exploreIdx" = "0" ]

# The 40th filler row tips it over.
row="$(jq -cn '{id:"fill40", facets:{layer:"ui",workType:"style",risk:[]},
  startModel:"claude-sonnet-5", startEffort:"low", finalModel:"claude-sonnet-5", finalEffort:"low", blocked:false}')"
rows="$(append_row "$rows" "$row")"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "cooldown: probability resumes after the 40th filler row" [ "$pm" = "150" ]
assert "cooldown: exploreIdx still 0 (not promoted yet)" [ "$exploreIdx" = "0" ]
assert "cooldown: chosen still 1 (not promoted yet)" [ "$chosen" = "1" ]

echo "--- recheck: full batch at once after cooldown elapses, then promotion ---"

# Continuing 'rows' (cooldown just elapsed, n=6 stale failures at index 0). Append fresh SUCCESSFUL
# touches one at a time — none of these should individually re-arm the cooldown ("full batch at once").
# The trailing window is CONTINUOUS (last minN touches, mixing stale+fresh while both are present), so
# promotion can fire as soon as the MIX clears floor — it doesn't need to wait for a fully-flushed,
# all-fresh window. With 6 stale failures and floor=0.75, that happens once 5 of the 6 window slots are
# fresh successes (5/6 = 83.3% >= 75%), i.e. after the 5th new touch (n=11), one round earlier than a
# naive "wait for a clean batch of 6" model would predict.
for i in 1 2 3 4 5; do
  read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
  assert "resume round $i: still offered, no re-cooldown mid-batch" [ "$pm" = "150" ]
  assert "resume round $i: not yet promoted" [ "$chosen" = "1" ]
  row="$(jq -cn --arg id "resume$i" '{id:$id, facets:{layer:"ui",workType:"style",risk:[]},
    startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:false}')"
  rows="$(append_row "$rows" "$row")"
done
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "resume: after 5/5 new successes (window 5/6, mixed with 1 stale fail), chosen promotes to 0" [ "$chosen" = "0" ]
assert "resume: exploreIdxOut=-1 (promoted this call)" [ "$exploreIdx" = "-1" ]
assert "resume: remain=-1 (dashboard: promoted via the trailing window)" [ "$remain" = "-1" ]
assert "resume: self-terminated (0 probability, no bookkeeping)" [ "$pm" = "0" ]

echo "--- recheck: promotion is durable and self-corrects (not just a boundary flash) ---"

# Continuing 'rows' (n=11 at index 0: 6 stale fails + 5 fresh successes, currently promoted, chosen=0).
# Confirm it STAYS promoted on a call with no new touches at all (sanity: sticky, not a one-shot flag).
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "durability: still promoted with zero new touches (re-derived fresh, not a flag)" [ "$chosen" = "0" ]

# Now feed 2 REAL failures at the candidate — NOT at a batch boundary (n=12, n=13) — and confirm the
# trailing window (continuously re-evaluated every call, not just at multiples of minN) correctly
# drops the promotion the moment it dips below floor, falling back to the old, proven tier. This is
# the exact bug an earlier draft of this mechanism had (promotion only checked AT boundaries, so it
# would flicker back to the stale tier on every non-boundary call) — this test guards against it.
row="$(jq -cn '{id:"drift1", facets:{layer:"ui",workType:"style",risk:[]},
  startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:true}')"
rows="$(append_row "$rows" "$row")"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "durability: one new failure (5/6 in window) doesn't yet flip a promoted rung" [ "$chosen" = "0" ]

row="$(jq -cn '{id:"drift2", facets:{layer:"ui",workType:"style",risk:[]},
  startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:true}')"
rows="$(append_row "$rows" "$row")"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "durability: a second new failure (window now 4/6) falls back to the old tier, mid-batch (n=13, not a boundary)" [ "$chosen" = "1" ]

echo "--- recheck: rejected again after resume — cooldown restarts, not a tight loop ---"

# Fresh fixture: settle a rejection, let cooldown elapse, then resume with FAILING (not succeeding)
# touches this time — confirms mid-batch stays offered throughout (same "full batch at once" pacing),
# but once that fresh batch is ALSO fully failing, cooldown restarts from the NEW position.
rows2="$REJECTED"   # 56 established (index 1) + 6 stale fails (index 0) — same shape as the earlier fixture
FILLER40="$(seed_rows 40 0 claude-sonnet-5 '"low"' fill2)"
rows2="$(jq -cn --argjson a "$rows2" --argjson b "$FILLER40" '$a + $b')"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows2" "$LADDER5" 150 '[]')"
assert "resumed-rejection: cooldown elapsed (40 fillers), offered again" [ "$pm" = "150" ]

for i in 1 2 3 4 5; do
  read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows2" "$LADDER5" 150 '[]')"
  assert "resumed-rejection round $i: still offered, no re-cooldown mid-batch" [ "$pm" = "150" ]
  row="$(jq -cn --arg id "rerej$i" '{id:$id, facets:{layer:"ui",workType:"style",risk:[]},
    startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:true}')"
  rows2="$(append_row "$rows2" "$row")"
done
# 6th fresh failure -> n=12, a batch boundary; window = 6 fresh failures (all-new, no stale mix) = 0%.
row="$(jq -cn '{id:"rerej6", facets:{layer:"ui",workType:"style",risk:[]},
  startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:true}')"
rows2="$(append_row "$rows2" "$row")"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows2" "$LADDER5" 150 '[]')"
assert "resumed-rejection: fresh batch also fails -> chosen stays 1" [ "$chosen" = "1" ]
assert "resumed-rejection: cooldown restarts immediately (0 probability)" [ "$pm" = "0" ]

# Confirm the restart is a genuine fresh 40-row wait FROM THE NEW position, not the original.
FILLER39b="$(seed_rows 39 0 claude-sonnet-5 '"low"' fill3)"
rows2="$(jq -cn --argjson a "$rows2" --argjson b "$FILLER39b" '$a + $b')"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows2" "$LADDER5" 150 '[]')"
assert "resumed-rejection: still 0 after 39 more fillers (new cooldown not yet elapsed)" [ "$pm" = "0" ]
row="$(jq -cn '{id:"fill80", facets:{layer:"ui",workType:"style",risk:[]},
  startModel:"claude-sonnet-5", startEffort:"low", finalModel:"claude-sonnet-5", finalEffort:"low", blocked:false}')"
rows2="$(append_row "$rows2" "$row")"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$rows2" "$LADDER5" 150 '[]')"
assert "resumed-rejection: offered again after the NEW cooldown's 40th filler" [ "$pm" = "150" ]

echo "--- degenerate configs ---"

# exploreCooldownN=0: cooldown disabled — a rejected rung is offered again on the VERY NEXT call.
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$REJECTED" "$LADDER5" 150 '[]' ui style 0)"
assert "exploreCooldownN=0: cooldown disabled, offered immediately after settling" [ "$pm" = "150" ]

# minN=1: every touch is its own batch/boundary — degenerates to per-touch cooldown automatically,
# no special-casing needed. Sanity check only.
MINN1_ROWS="$(jq -cn --argjson a "$ESTABLISHED" --argjson b "$(seed_rows 0 1 claude-haiku-4-5 null bad1)" '$a + $b')"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(jq -rn --argjson rows "$MINN1_ROWS" --argjson tiers "$LADDER5" \
   --arg layer ui --arg wt style --argjson floor 0.75 --argjson minN 1 --argjson coldIdx 0 \
   --argjson manualFail '{}' --argjson risk '[]' --argjson explorePM 150 --argjson exploreCooldownN 40 \
   --argjson auditCount -1 --argjson auditStartN 3 --argjson auditFloorN 8 --argjson auditFloorPM 100 \
   -f "$POLICY_JQ")"
assert "minN=1: single failing touch is a complete (and rejected) batch, cooldown-gated" [ "$pm" = "0" ]
assert "minN=1: exploreIdx still points at the candidate" [ "$exploreIdx" = "0" ]

echo "--- escalate-through touch attribution ---"

# A row that escalated THROUGH the candidate index (index 0) on its way to a higher final tier
# (index 2) should count as a touch at index 0 with its own row ordinal, exactly like a row that
# started AND ended there — reuses the existing $ev span logic verbatim (range($s;$f) covers it).
ESCALATE_ROW="$(jq -cn '{id:"esc1", facets:{layer:"ui",workType:"style",risk:[]},
  startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-sonnet-5", finalEffort:"medium", blocked:false}')"
ESC_ROWS="$(jq -cn --argjson a "$ESTABLISHED" --argjson b "$ESCALATE_ROW" '$a + [$b]')"
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$ESC_ROWS" "$LADDER5" 150 '[]')"
assert "escalate-through: still counts as 1 sample at the candidate rung (offered, under-sampled)" [ "$pm" = "150" ]
assert "escalate-through: exploreIdx unaffected" [ "$exploreIdx" = "0" ]

echo "--- regression: byte-identical against the original (pre-recheck) shipped ladder scenarios ---"

# The exact real-data reproduction from the original feature's empirical validation — chosen=1,
# explorePM passthrough=150, exploreIdx=0 — must still hold with exploreCooldownN now present.
read -r chosen pm exploreIdx remain eN eWinOk <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 150 '[]' ui style 40)"
assert "final regression: established cell still resolves identically with exploreCooldownN present" [ "$chosen" = "1" ]
assert "final regression: explorePM passthrough unaffected" [ "$pm" = "150" ]
assert "final regression: exploreIdx unaffected" [ "$exploreIdx" = "0" ]

if [ "$FAIL" = 0 ]; then echo "policy.test.sh: ALL PASS"; else echo "policy.test.sh: FAILURES"; exit 1; fi
