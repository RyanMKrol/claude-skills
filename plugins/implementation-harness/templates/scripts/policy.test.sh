#!/usr/bin/env bash
#
# policy.test.sh — hermetic test suite for policy.jq, focused on downward exploration
# (designs/difficulty-autotune.md). Every case below invokes the REAL policy.jq via `jq -n -f` —
# no mocking, no reimplementation. The convergence simulation seeds synthetic ledger rows BETWEEN
# successive real policy.jq calls, exactly mirroring what the loop would write for a real explored
# task, to prove the epsilon-greedy probe actually self-terminates: promotion on success, permanent
# rejection on failure. No git repo / filesystem state needed — everything lives in bash variables.
# Run standalone: .harness/scripts/policy.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_JQ="$SCRIPT_DIR/policy.jq"
FAIL=0

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

LADDER5='[{"model":"claude-haiku-4-5","effort":null},{"model":"claude-sonnet-5","effort":"low"},{"model":"claude-sonnet-5","effort":"medium"},{"model":"claude-sonnet-5","effort":"high"},{"model":"claude-opus-4-8","effort":"high"}]'
LADDER4='[{"model":"claude-sonnet-5","effort":"low"},{"model":"claude-sonnet-5","effort":"medium"},{"model":"claude-sonnet-5","effort":"high"},{"model":"claude-opus-4-8","effort":"high"}]'

# run_policy <rowsJson> <tiersJson> <explorePM> <riskJson> [layer] [wt] — echoes "chosen pm exploreIdx"
run_policy() {
  local layer="${5:-ui}" wt="${6:-style}"
  jq -rn --argjson rows "$1" --argjson tiers "$2" \
     --arg layer "$layer" --arg wt "$wt" --argjson floor 0.75 --argjson minN 6 --argjson coldIdx 0 \
     --argjson manualFail '{}' --argjson risk "$4" --argjson explorePM "$3" \
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
read -r chosen pm exploreIdx <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 0 '[]')"
assert "explorePM=0 → chosen unaffected (still 1)" [ "$chosen" = "1" ]
assert "explorePM=0 → output probability always 0" [ "$pm" = "0" ]

# 2. The literal bug reproduction: established cell + explorePM configured nonzero → probes index 0.
read -r chosen pm exploreIdx <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 150 '[]')"
assert "established cell: chosen=1 (sonnet/low, pinned)" [ "$chosen" = "1" ]
assert "established cell: explorePM=150 → output probability 150" [ "$pm" = "150" ]
assert "established cell: exploreIdx targets index 0 (Haiku)" [ "$exploreIdx" = "0" ]

# 3. Cold cell (nothing matches layer/wt) → no candidate below the cold-start floor.
read -r chosen pm exploreIdx <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 150 '[]' ui nonexistent-worktype)"
assert "cold cell: chosen=coldIdx (0)" [ "$chosen" = "0" ]
assert "cold cell: exploreIdx=-1 (nothing below the floor)" [ "$exploreIdx" = "-1" ]
assert "cold cell: output probability 0" [ "$pm" = "0" ]

# 4. Risk-flagged task on the same established cell — never a vehicle for probing index 0.
read -r chosen pm exploreIdx <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 150 '["touches-schema"]')"
assert "risk task: exploreIdx=-1 (floor clamp, never probes index 0)" [ "$exploreIdx" = "-1" ]
assert "risk task: output probability 0" [ "$pm" = "0" ]

# 5. Settled rejection: the rung below chosen already has >= minN samples and failed the floor.
REJECTED="$(jq -cn --argjson a "$ESTABLISHED" --argjson b "$(seed_rows 1 5 claude-haiku-4-5 null bad)" '$a + $b')"
read -r chosen pm exploreIdx <<<"$(run_policy "$REJECTED" "$LADDER5" 150 '[]')"
assert "settled rejection: chosen stays 1 (index 0 already failed)" [ "$chosen" = "1" ]
assert "settled rejection: exploreIdx still points at 0" [ "$exploreIdx" = "0" ]
assert "settled rejection: output probability forced 0 (never re-probed)" [ "$pm" = "0" ]

# 6. Reindexing: the SAME rows, evaluated against the ladder before vs. after Haiku is inserted.
read -r chosen pm exploreIdx <<<"$(run_policy "$ESTABLISHED" "$LADDER4" 150 '[]')"
assert "pre-insertion (4-rung ladder): sonnet/low was index 0" [ "$chosen" = "0" ]
read -r chosen pm exploreIdx <<<"$(run_policy "$ESTABLISHED" "$LADDER5" 150 '[]')"
assert "post-insertion (5-rung ladder), same rows: chosen re-resolves to 1" [ "$chosen" = "1" ]
assert "post-insertion: exploreIdx correctly targets the new index-0 rung" [ "$exploreIdx" = "0" ]

echo "--- convergence simulation (promotion branch) ---"

rows="$ESTABLISHED"
for i in 1 2 3 4 5 6; do
  read -r chosen pm exploreIdx <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
  assert "promotion round $i: still probing index 0 (under-sampled)" [ "$exploreIdx" = "0" ]
  assert "promotion round $i: probability still 150" [ "$pm" = "150" ]
  # simulate a real explored task that ran on Haiku and SUCCEEDED
  row="$(jq -cn --arg id "prom$i" '{id:$id, facets:{layer:"ui",workType:"style",risk:[]},
    startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:false}')"
  rows="$(append_row "$rows" "$row")"
done
read -r chosen pm exploreIdx <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "promotion: after 6/6 Haiku successes, chosen flips to 0" [ "$chosen" = "0" ]
assert "promotion: exploreIdx recomputes to -1 (nothing left below index 0)" [ "$exploreIdx" = "-1" ]
assert "promotion: self-terminated (output probability 0, no bookkeeping needed)" [ "$pm" = "0" ]

echo "--- convergence simulation (rejection branch) ---"

rows="$ESTABLISHED"
for i in 1 2 3 4 5 6; do
  read -r chosen pm exploreIdx <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
  assert "rejection round $i: still probing index 0 (under-sampled)" [ "$exploreIdx" = "0" ]
  assert "rejection round $i: probability still 150" [ "$pm" = "150" ]
  # simulate a real explored task that ran on Haiku and FAILED
  row="$(jq -cn --arg id "rej$i" '{id:$id, facets:{layer:"ui",workType:"style",risk:[]},
    startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:true}')"
  rows="$(append_row "$rows" "$row")"
done
read -r chosen pm exploreIdx <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "rejection: after 6/6 Haiku failures, chosen stays 1" [ "$chosen" = "1" ]
assert "rejection: settled rejection (output probability forced 0)" [ "$pm" = "0" ]
# one more round confirms it stays stable — not re-probed, doesn't flip back
row="$(jq -cn '{id:"rej7", facets:{layer:"ui",workType:"style",risk:[]},
  startModel:"claude-haiku-4-5", startEffort:null, finalModel:"claude-haiku-4-5", finalEffort:null, blocked:true}')"
rows="$(append_row "$rows" "$row")"
read -r chosen pm exploreIdx <<<"$(run_policy "$rows" "$LADDER5" 150 '[]')"
assert "rejection: stable after a 7th failure too (no flip-flopping)" [ "$chosen" = "1" ]
assert "rejection: still 0 probability (permanently settled)" [ "$pm" = "0" ]

if [ "$FAIL" = 0 ]; then echo "policy.test.sh: ALL PASS"; else echo "policy.test.sh: FAILURES"; exit 1; fi
