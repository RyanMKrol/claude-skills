# Difficulty auto-tuning policy. Given the escalation ledger + a task's (layer × work-type) cell,
# return the index of the cheapest tier on the global ladder whose historical first-attempt success
# rate for that cell is >= floor with >= minN samples; else coldIdx (the authored difficulty).
#
# Invoke: jq -n -f policy.jq \
#   --slurpfile rows <outcomes.jsonl> \      # the ledger (array of outcome rows)
#   --argjson tiers '<ladder array>' \       # [{model,effort}, ...] cheapest -> priciest
#   --arg layer <L> --arg wt <W> \           # the task's cell
#   --argjson floor 0.75 --argjson minN 6 \
#   --argjson coldIdx <N>                    # authored tier index = cold-start fallback
#
# Each ledger row records the tier a task STARTED at and the tier it finally SUCCEEDED at (or, if
# blocked, the top tier it reached). We expand each row into per-tier pass/fail events: every tier
# from start up to (but not including) the success tier FAILED; the success tier PASSED; a blocked
# row FAILED at every tier from start through the top it reached. Then per tier we compute the
# success rate over its samples and pick the cheapest qualifying one.

def tidx($m; $e): ($tiers | map(.model == $m and .effort == $e) | index(true)) // -1;

( $rows
  | map(select(.facets != null and .facets.layer == $layer and .facets.workType == $wt))
  | map(
      tidx(.startModel; .startEffort) as $s
      | tidx(.finalModel; .finalEffort) as $f
      | select($s >= 0 and $f >= 0)
      | if .blocked
        then [ range($s; $f + 1) | { idx: ., ok: false } ]
        else [ range($s; $f)     | { idx: ., ok: false } ] + [ { idx: $f, ok: true } ]
        end
    )
  | add // []
) as $ev
| [ range(0; ($tiers | length)) as $i
    | ($ev | map(select(.idx == $i))) as $at
    | ($at | length) as $n
    | select($n >= $minN and (($at | map(select(.ok)) | length) / $n) >= $floor)
    | $i
  ]
| (min // $coldIdx)
