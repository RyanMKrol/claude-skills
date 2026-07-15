# outcome-row.jq — the ONE ledger-row jq filter, shared by loop.sh's outcome_row() and
# loop.in-place.sh's record_outcome() (C01 stage 3). Used to be copy-pasted verbatim in both — same
# drift class scope-lib.sh/repo-lock.sh/loop-lib.sh were extracted to fix. Expects TASKS.json (or the
# DRY_TASKS preview) as input (piped through `tj`/`jq`) and these --arg/--argjson bindings from the
# caller: $id, $blocked, $reason, $rung, $atr, $total, $sm, $se, $fm, $fe, $ts, $verif.
.tasks[]|select(.id==$id)|{
  id:$id, ts:$ts, facets:(.facets // null), scopeSize:(.scope|length),
  startModel:$sm, startEffort:(if $se=="" then null else $se end),
  finalModel:$fm, finalEffort:(if $fe=="" then null else $fe end),
  succeededRung:(if $blocked then null else $rung end), topRung:$rung,
  attemptsAtRung:$atr, totalSoftFails:$total, blocked:$blocked, reason:$reason,
  verification:$verif
}
