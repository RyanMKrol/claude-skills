# Difficulty auto-tuning policy. TWO modes, switched by $auditCount:
#
#   TIER selection ($auditCount < 0, the default): given the escalation ledger + a task's
#   (layer × work-type) cell, return the index of the cheapest tier on the global ladder whose
#   historical first-attempt success rate for that cell is >= floor with >= minN samples; else
#   coldIdx (the authored difficulty / cold-start prior). Output is a 3-field space-separated line
#   "$chosen $explorePMOut $exploreIdx" — see "downward exploration" below.
#
#   AUDIT probability ($auditCount >= 0): given a cell's CONFIRMED-AUDITED success count, return the
#   blocking-audit sampling probability as an integer PER-MILLE (0..1000) — so the loop can sample
#   with $RANDOM and no bash floats. 100% until auditStartN, linear taper to auditFloor*1000 by
#   auditFloorN, floored there (never zero). See designs/audit-verification.md §4.6.
#
# Invoke (tier):  jq -n -f policy.jq --slurpfile rows <outcomes.jsonl> --argjson tiers '<ladder>' \
#                   --arg layer <L> --arg wt <W> --argjson floor 0.75 --argjson minN 6 \
#                   --argjson coldIdx <N> --argjson auditCount -1 --argjson manualFail '<tracking/manual-fail.json>' \
#                   --argjson risk '<this task's facets.risk array>' \
#                   --argjson auditStartN 3 --argjson auditFloorN 8 --argjson auditFloorPM 100 \
#                   --argjson explorePM <per-mille, 0 = off>
# Invoke (audit): same flags, but --argjson auditCount <confirmed-count> (>= 0); the tier-only flags
#                 may be placeholders (rows '[]', tiers '[]', layer/wt '', etc.) — that branch is not
#                 evaluated. Both invocations must DEFINE every $var (jq compiles both branches).
#
# $explorePM (downward exploration, designs/difficulty-autotune.md): inserting a cheaper rung below
# an already-calibrated cell never gets it chosen — it has 0 samples, so it's excluded from the
# eligible set outright, and can therefore never accumulate the evidence that would make it eligible.
# This is a bounded, self-terminating epsilon-greedy probe: whenever the rung directly below $chosen
# has < minN samples (genuinely untested, not tested-and-rejected), TIER mode also returns a nonzero
# sampling probability for it (capped by the same risk-floor clamp $chosen itself uses) and its own
# index, so the shell can occasionally start a task there instead. Once that rung reaches minN
# samples, the probability is forced to 0 — self-termination, no separate bookkeeping — and the
# UNMODIFIED tier-selection logic above takes it from there: promotes it on the very next call if its
# rate cleared $floor, or excludes it permanently, exactly like any other rejected tier, if not.
# $explorePM = 0 (the default) makes $explorePMOut always 0 — bit-for-bit identical to pre-exploration
# behavior.
#
# $manualFail is the owner-overlay `tracking/manual-fail.json` ({id: {failed, reason, at}}) — a task
# the owner has retroactively overturned from a false "done" is treated as a FAILURE at every rung it
# touched, same as a blocked row, even though the ledger row itself still says blocked:false. This
# keeps a corrected false-positive from propagating into either the tier success rate or (upstream,
# in the shell's confirmed-audited-count query) the audit-sampling decay — WITHOUT mutating the
# append-only ledger itself (designs/manual-fail-signal.md).
#
# $risk is the CURRENT task's `facets.risk` array (danger flags — touches-schema, full-stack, …).
# A non-empty risk clamps the calibration's usual cost-saving in two ways (designs/difficulty-autotune.md):
#   - AUDIT mode: mandatory audit (1000 per-mille) regardless of the cell's confirmed-success decay —
#     a risky task is always independently verified, however reliable the cell has looked so far.
#   - TIER mode: the eligible starting index is clamped to >= 1 (never the cheapest rung), even if
#     historical calibration would otherwise let index 0 clear the floor for this cell. Escalation
#     above that floor on real failure is unaffected — this only raises the FLOOR, not the ceiling.

# A rung's `effort` (and a ledger row's startEffort/finalEffort) may be JSON null for a model with no
# effort parameter (e.g. Haiku) — jq's `==` treats null == null as true, so tidx() matches an
# effort-less rung correctly with no special-casing, as long as both sides are real null (not the
# string "null" or ""). The loop scripts normalize to real null at the ledger-write boundary.
def tidx($m; $e): ($tiers | map(.model == $m and .effort == $e) | index(true)) // -1;

# audit per-mille from a cell's confirmed-audited success count.
def audit_permille($count; $startN; $floorN; $floorPM):
  if   $count <  $startN then 1000
  elif $count >= $floorN then $floorPM
  else ((1000 - (($count - $startN) * (1000 - $floorPM) / ($floorN - $startN))) | round)
  end;

if $auditCount >= 0 then
  if ($risk | length) > 0 then 1000 else audit_permille($auditCount; $auditStartN; $auditFloorN; $auditFloorPM) end
else
  ( $rows
    | map(select(.facets != null and .facets.layer == $layer and .facets.workType == $wt))
    | map(
        tidx(.startModel; .startEffort) as $s
        | tidx(.finalModel; .finalEffort) as $f
        | select($s >= 0 and $f >= 0)
        | (.blocked or ($manualFail[.id].failed == true)) as $overturned
        | if $overturned
          then [ range($s; $f + 1) | { idx: ., ok: false } ]
          else [ range($s; $f)     | { idx: ., ok: false } ] + [ { idx: $f, ok: true } ]
          end
      )
    | add // []
  ) as $ev
  | ( [ range(0; ($tiers | length)) as $i
        | ($ev | map(select(.idx == $i))) as $at
        | ($at | length) as $n
        | select($n >= $minN and (($at | map(select(.ok)) | length) / $n) >= $floor)
        | $i
      ]
    | (min // $coldIdx)
  ) as $rawChosen
  | (if ($risk | length) > 0 then ([$rawChosen, 1] | max) else $rawChosen end) as $chosen
  # --- downward exploration (see header comment) ---
  | (if ($risk | length) > 0 then 1 else 0 end) as $floorIdx
  | (if ($chosen - 1) >= $floorIdx then ($chosen - 1) else -1 end) as $exploreIdx
  | ( if $exploreIdx >= 0
      then ($ev | map(select(.idx == $exploreIdx)) | length)
      else $minN
      end
    ) as $exploreN
  | (if $exploreIdx >= 0 and $exploreN < $minN then $explorePM else 0 end) as $explorePMOut
  | "\($chosen) \($explorePMOut) \($exploreIdx)"
end
