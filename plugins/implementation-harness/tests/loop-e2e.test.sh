#!/usr/bin/env bash
#
# loop-e2e.test.sh — end-to-end test of the REAL loop dispatch state machine (T01). Runs the actual
# loop.sh / loop.in-place.sh driver against a throwaway git repo + bare origin, with a FAKE `claude`
# and FAKE `gh` prepended to PATH — so the whole select → build → structural → audit → integrate →
# record-outcome → cleanup pipeline executes for real, and we assert on origin/main STATE + the
# ledgers (not on log text). This is the harness the idle-exit (1.65.0) and rate-limit (1.69.0)
# regressions needed: static greps could not have caught either.
#
# The fakes (see write_fake_bins):
#   • fake `claude` — ignores model/flags, INFERS the phase from the prompt (the audit prompt carries
#     the "INDEPENDENT AUDITOR" marker). Per BUILD call it creates+commits an in-scope file in the cwd
#     worktree and writes `.harness/worklog/.result`; per AUDIT call it emits a stream-json text_delta
#     ending in the `VERDICT: PASS|FAIL` sentinel the loop parses. Behaviour is overridable per call by
#     ordered plan files (build.NNN / audit.NNN) under $FAKE_CLAUDE_DIR — absent = the happy-path
#     default. This lets later scenarios script soft-fails, garbage, crashes, out-of-scope commits, etc.
#   • fake `gh` — scripted CI answers keyed by call for the REQUIRE_CI scenarios (unused here; scenario
#     1 runs REQUIRE_CI=0).
#
# PLUGIN-SOURCE test: exercises BOTH loop variants (which only coexist in templates/); runs in the
# plugin's CI via the *.test.sh finder, never copied into a consumer .harness/.
# Run standalone (from a NON-Claude shell, or with env -u CLAUDECODE):
#   plugins/implementation-harness/tests/loop-e2e.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
TMPS=()
cleanup() { local d; for d in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

# The floor tier has NO effort key (mirrors a real install: the no-effort floor is null/absent, NOT
# ""). pick_base maps an empty EFFORT to null and matches it against the raw ladder value, so a `""`
# here would miss the floor and cold-start at the TOP rung — leaving no room to escalate.
FACETS_JSON='{"tiers":{"ladder":[{"model":"claude-haiku-4-5"},{"model":"claude-sonnet-5","effort":"high"}]},"policy":{"floor":0.75,"minN":6,"auditStartN":3,"auditFloorN":8,"auditFloorPM":100,"auditorModel":"claude-opus-4-8","auditorEffort":"medium"}}'

# One ready backlog task, scoped to src/, with a spec file so the audit has something to read.
BACKLOG_JSON='{"version":1,"tasks":[
  {"id":"T001","status":"pending","dependsOn":[],"gate":null,"facets":{"layer":"backend","workType":"feature"},"scope":["src/"],"spec":".harness/tasks/T001.md"}
]}'

# write_fake_bins <bindir> — drop a fake `claude` and `gh` into <bindir> (prepended to PATH).
write_fake_bins() {
  local bin="$1"
  cat >"$bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
# Fake `claude` for loop-e2e.test.sh. Ignores --model/--effort/flags. Infers build vs audit from the
# prompt; drives behaviour from ordered plan files under $FAKE_CLAUDE_DIR (build.NNN / audit.NNN),
# each a sourced snippet setting the vars below. No plan file = the happy-path default.
set -u
FCD="${FAKE_CLAUDE_DIR:?FAKE_CLAUDE_DIR must be set}"
st="$FCD/state"; mkdir -p "$st"

# The prompt is the argv element immediately after -p.
prompt=""; want=0
for a in "$@"; do
  if [ "$want" = 1 ]; then prompt="$a"; break; fi
  [ "$a" = "-p" ] && want=1
done
taskid="$(printf '%s' "$prompt" | grep -oE 'T[0-9]+' | head -n1)"; taskid="${taskid:-T000}"

next() {  # next <kind> → echoes the zero-padded call index, incrementing its counter
  local kind="$1" c
  c="$(cat "$st/$kind.count" 2>/dev/null || echo 0)"; c=$((c + 1)); printf '%s' "$c" >"$st/$kind.count"
  printf '%03d' "$c"
}

if printf '%s' "$prompt" | grep -q 'INDEPENDENT AUDITOR'; then
  # ---- AUDIT call ----
  idx="$(next audit)"; plan="$FCD/audit.$idx"; [ -f "$plan" ] || plan="$FCD/audit.default"
  VERDICT=PASS; EXIT=0; EMIT=""
  [ -f "$plan" ] && . "$plan"
  if [ -n "$EMIT" ]; then
    printf '%s\n' "$EMIT"
  else
    # Reassembled by the loop's jq (text_delta → $out); the FINAL non-empty line is the sentinel.
    printf '{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"audited %s\\nVERDICT: %s"}}}\n' "$taskid" "$VERDICT"
  fi
  exit "$EXIT"
fi

# ---- BUILD call ----
idx="$(next build)"; plan="$FCD/build.$idx"; [ -f "$plan" ] || plan="$FCD/build.default"
RESULT="done"; FILES="src/app.txt"; CONTENT=""; MSG=""; EXTRA=""; EXIT=0; NORESULT=0; EMIT=""; NOCOMMIT=0
[ -f "$plan" ] && . "$plan"
[ -n "$EMIT" ] && printf '%s\n' "$EMIT"
if [ -n "$FILES" ] && [ "$NOCOMMIT" != 1 ]; then
  for f in $FILES; do
    d="$(dirname "$f")"; [ "$d" = "." ] || mkdir -p "$d"
    printf '%s\n' "${CONTENT:-fake build for $taskid — $f}" >"$f"
    git add -- "$f" 2>/dev/null || true
  done
  git commit -q -m "${MSG:-$taskid: fake build}" 2>/dev/null || true
fi
[ "$NORESULT" = 1 ] || printf '%s %s %s\n' "$RESULT" "$taskid" "$EXTRA" > .harness/worklog/.result
exit "$EXIT"
FAKE_CLAUDE

  cat >"$bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake `gh` for the loop-e2e CI scenarios. Ignores --json/--jq entirely and prints the exact value the
# loop consumes from stdout, driven by files under $FAKE_GH_DIR:
#   • `gh run list …`  → prints $FAKE_GH_DIR/runid (default "100"; "NONE" = no run found yet).
#   • `gh run view ID` → prints the Nth line of $FAKE_GH_DIR/views (a "<status>/<conclusion>" string,
#     e.g. completed/success, completed/failure, completed/cancelled, in_progress/), advancing a global
#     call counter; once past the last line it repeats the last (default: completed/success).
#   • `gh run watch ID` → records the call in $FAKE_GH_DIR/watch.calls and exits 0. (B10: after the fix
#     the loop no longer calls this — a scenario asserts watch.calls stays empty.)
set -u
GHD="${FAKE_GH_DIR:?FAKE_GH_DIR must be set}"; mkdir -p "$GHD"
case "${1:-} ${2:-}" in
  "run list")
    rid="$(cat "$GHD/runid" 2>/dev/null || echo 100)"
    [ "$rid" = NONE ] || printf '%s\n' "$rid" ;;
  "run view")
    c="$(cat "$GHD/view.count" 2>/dev/null || echo 0)"; c=$((c + 1)); printf '%s' "$c" >"$GHD/view.count"
    if [ -f "$GHD/views" ]; then
      line="$(sed -n "${c}p" "$GHD/views")"; [ -n "$line" ] || line="$(tail -1 "$GHD/views")"
    else line="completed/success"; fi
    printf '%s\n' "$line" ;;
  "run watch")
    printf 'watch %s\n' "${3:-}" >>"$GHD/watch.calls"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE_GH
  chmod +x "$bin/claude" "$bin/gh"
}

# setup_repo <loop-src> — build a throwaway repo + bare origin wired for a real run. Echoes "<repo> <bare>".
setup_repo() {
  local src="$1" d bare
  d="$(mktemp -d)"; bare="$(mktemp -d)"; TMPS+=("$d" "$bare")
  # The worktree variant creates a sibling "<name>-loop" dir next to the repo — register it for cleanup.
  TMPS+=("$(dirname "$d")/$(basename "$d")-loop")
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking" "$d/.harness/worklog" \
           "$d/.harness/ledgers" "$d/.harness/config" "$d/.harness/tasks"
  cp "$src" "$d/.harness/scripts/loop.sh"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/loop-lib.sh" \
     "$SCRIPT_DIR/policy.jq" "$SCRIPT_DIR/outcome-row.jq" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  printf '%s\n' "$BACKLOG_JSON"  >"$d/.harness/tracking/TASKS.json"
  printf '%s\n' "$FACETS_JSON"   >"$d/.harness/config/facets.json"
  printf '{}\n' >"$d/.harness/tracking/human-done.json"
  printf '{}\n' >"$d/.harness/tracking/manual-fail.json"
  : >"$d/.harness/ledgers/outcomes.jsonl"
  : >"$d/.harness/worklog/.gitkeep"
  # Ignore worklog scratch but keep the dir (tracked .gitkeep). This mirrors a real install's managed
  # .gitignore block and is load-bearing: the in-place variant's cold_reset runs `git clean -fd`, which
  # removes untracked-but-NOT-ignored files — so an un-ignored .failures.buf would be wiped between
  # attempts, dropping every soft-failure diagnostic but the last. Ignoring it lets the buffer survive.
  printf '%s\n' '.harness/worklog/*' '!.harness/worklog/.gitkeep' >"$d/.gitignore"
  printf '## Do\nBuild the thing.\n\n## Done when\n- src/app.txt exists.\n' >"$d/.harness/tasks/T001.md"
  ( cd "$d" && git add -A && git commit -q -m init )
  git init -q --bare -b main "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin main )
  echo "$d $bare"
}

# aux_dir — a scratch dir OUTSIDE the repo for the fake bins / fake-plan / run log, so the repo's
# working tree stays clean (the in-place loop hard-refuses to start on a dirty tree). Echoes the dir.
aux_dir() { local a; a="$(mktemp -d)"; TMPS+=("$a"); mkdir -p "$a/bin" "$a/fc" "$a/gh"; write_fake_bins "$a/bin"; echo "$a"; }

# run_loop <repo> <aux> [max_iters] [sync_primary] — run the real loop hermetically (fakes on PATH,
# REQUIRE_CI off). Echoes the loop's exit code; combined output → <aux>/run.log. SYNC_PRIMARY_ON_DONE
# defaults OFF here (most scenarios assert on origin/main and don't care about the primary checkout);
# the primary-checkout-freshness scenario passes 1 to exercise the real production default.
run_loop() {  # <repo> <aux> [max_iters] [sync_primary] [EXTRA_ENV=val ...]
  local d="$1" a="$2" mi="${3:-3}" spod="${4:-0}"
  if [ $# -ge 4 ]; then shift 4; else shift $#; fi   # remaining args = KEY=VAL env overrides (win over the defaults)
  ( cd "$d" && env -u CLAUDECODE PATH="$a/bin:$PATH" CLAUDE_BIN=claude FAKE_CLAUDE_DIR="$a/fc" FAKE_GH_DIR="$a/gh" \
      MAX_ITERS="$mi" WAIT_SECONDS=0 REQUIRE_CI=0 PRINT_PROMPT=0 SYNC_PRIMARY_ON_DONE="$spod" \
      MODEL=claude-haiku-4-5 EFFORT="" "$@" \
      bash .harness/scripts/loop.sh >"$a/run.log" 2>&1 )
  echo $?
}

# ── Scenario 1: happy path ─────────────────────────────────────────────────────────────────────────
scenario_happy_path() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  rc="$(run_loop "$d" "$a")"
  LAST_RUN_LOG="$a/run.log"

  assert "[$label] happy: loop exits 0 (backlog drained after integrating T001)" [ "$rc" -eq 0 ]
  assert "[$label] happy: T001 is status=done on origin/main" \
    bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json 2>/dev/null | jq -e '.tasks[]|select(.id==\"T001\")|.status==\"done\"' >/dev/null"
  assert "[$label] happy: the in-scope build file landed on origin/main" \
    bash -c "git -C '$bare' show main:src/app.txt 2>/dev/null | grep -q ."
  assert "[$label] happy: exactly ONE outcome row for T001 on origin/main" \
    bash -c "[ \"\$(git -C '$bare' show main:.harness/ledgers/outcomes.jsonl 2>/dev/null | jq -c 'select(.id==\"T001\")' | wc -l | tr -d ' ')\" = 1 ]"
  assert "[$label] happy: the T001 outcome row is a non-blocked, AUDITED success" \
    bash -c "git -C '$bare' show main:.harness/ledgers/outcomes.jsonl 2>/dev/null | jq -e 'select(.id==\"T001\") | .blocked==false and .verification==\"audited\"' >/dev/null"
  assert "[$label] happy: heartbeat (.current.json) cleared after integrate" \
    [ ! -f "$d/.harness/worklog/.current.json" ]

  # Worktree-only teardown (the sibling worktree + tNNN branch, local & remote, are gone).
  if [ "$label" = worktree ]; then
    local wt; wt="$(dirname "$d")/$(basename "$d")-loop"
    assert "[$label] happy: isolation worktree removed after the run" [ ! -d "$wt" ]
    assert "[$label] happy: local tNNN branch deleted after integrate" \
      bash -c "! git -C '$d' show-ref --verify --quiet refs/heads/t001"
    assert "[$label] happy: remote tNNN branch deleted after integrate" \
      bash -c "! git -C '$bare' show-ref --verify --quiet refs/heads/t001"
  fi
}

# ── Scenario 2a: idle verdict → reconcile status=done and CONTINUE (the 1.65.0 regression class) ─────
# The agent cold-reads main, finds the task's Done-when already met, and returns `idle`. The loop must
# NOT stall/exit: it reconciles the ONE task to done (ci-only — the audit never runs on this path) and
# continues, draining on the next iteration. The discriminators vs the happy path: verification is
# ci-only (not audited) AND no build file was produced (idle committed nothing).
scenario_idle_reconcile() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  printf 'RESULT=idle\nFILES=""\n' >"$a/fc/build.default"
  rc="$(run_loop "$d" "$a")"; LAST_RUN_LOG="$a/run.log"

  assert "[$label] idle: loop exits 0 (reconciled + continued, did NOT stall)" [ "$rc" -eq 0 ]
  assert "[$label] idle: T001 reconciled to status=done on origin/main" \
    bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json 2>/dev/null | jq -e '.tasks[]|select(.id==\"T001\")|.status==\"done\"' >/dev/null"
  assert "[$label] idle: outcome row is ci-only (audit never ran on the idle path)" \
    bash -c "git -C '$bare' show main:.harness/ledgers/outcomes.jsonl 2>/dev/null | jq -e 'select(.id==\"T001\") | .blocked==false and .verification==\"ci-only\"' >/dev/null"
  assert "[$label] idle: no build file was produced (idle committed nothing)" \
    bash -c "! git -C '$bare' show main:src/app.txt >/dev/null 2>&1"

  # B11: the idle reconcile-and-continue path must tear the scratch branch/worktree down like every
  # other terminal path — otherwise the local tNNN branch lingers and postflight reports it "in flight"
  # forever (its inprogress() greps local `t[0-9]{3,}` branches).
  if [ "$label" = worktree ]; then
    local wt; wt="$(dirname "$d")/$(basename "$d")-loop"
    assert "[$label] idle: no leftover local tNNN branch (postflight won't report it in-flight)" \
      bash -c "! git -C '$d' show-ref --verify --quiet refs/heads/t001"
    assert "[$label] idle: isolation worktree removed after reconcile" [ ! -d "$wt" ]
  fi
}

# ── Scenario 2b: failed:blocked → status=blocked + a blocked outcome row (terminal) ─────────────────
scenario_failed_blocked() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  printf 'RESULT="failed:blocked"\nFILES=""\nEXTRA="needs a real API key"\n' >"$a/fc/build.default"
  rc="$(run_loop "$d" "$a")"; LAST_RUN_LOG="$a/run.log"

  assert "[$label] blocked: T001 is status=blocked on origin/main" \
    bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json 2>/dev/null | jq -e '.tasks[]|select(.id==\"T001\")|.status==\"blocked\"' >/dev/null"
  assert "[$label] blocked: a blocked outcome row (blocked=true) was recorded" \
    bash -c "git -C '$bare' show main:.harness/ledgers/outcomes.jsonl 2>/dev/null | jq -e 'select(.id==\"T001\") | .blocked==true' >/dev/null"
  assert "[$label] blocked: nothing was merged to main" \
    bash -c "! git -C '$bare' show main:src/app.txt >/dev/null 2>&1"
}

# ── Scenario 2c: failed:soft ×(ladder) → escalation up the rungs, then BLOCK at the top ─────────────
# Every attempt soft-fails; bump() escalates rung 0 → 1 after MAX_ATTEMPTS, then blocks at the top.
# The escalation is observable in failures.jsonl (a row at rung 1), flushed to main on the block.
scenario_soft_escalation() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  printf 'RESULT="failed:soft"\nFILES=""\nEXTRA="transient"\n' >"$a/fc/build.default"
  # ladder=2 rungs × MAX_ATTEMPTS=2 = 4 attempts, then block on the 4th; MAX_ITERS=6 leaves room.
  rc="$(run_loop "$d" "$a" 6)"; LAST_RUN_LOG="$a/run.log"

  assert "[$label] soft: T001 ends status=blocked after exhausting the ladder" \
    bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json 2>/dev/null | jq -e '.tasks[]|select(.id==\"T001\")|.status==\"blocked\"' >/dev/null"
  assert "[$label] soft: escalated to rung 1 (a failures.jsonl row at rung 1 exists)" \
    bash -c "git -C '$bare' show main:.harness/ledgers/failures.jsonl 2>/dev/null | jq -se 'any(.[]; .id==\"T001\" and .rung==1)' >/dev/null"
  assert "[$label] soft: an agent-soft-fail row was recorded at rung 0 too" \
    bash -c "git -C '$bare' show main:.harness/ledgers/failures.jsonl 2>/dev/null | jq -se 'any(.[]; .id==\"T001\" and .rung==0 and .kind==\"agent-soft-fail\")' >/dev/null"
}

# ── Scenario 6: out-of-scope commit → scope-creep block after ONE attempt, nothing merged ───────────
scenario_scope_creep() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  # Agent claims done, but commits a file OUTSIDE the declared scope (["src/"]).
  printf 'RESULT=done\nFILES="other/evil.txt"\n' >"$a/fc/build.default"
  rc="$(run_loop "$d" "$a")"; LAST_RUN_LOG="$a/run.log"

  assert "[$label] scope-creep: T001 is status=blocked (wrong scope isn't fixed by a retry)" \
    bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json 2>/dev/null | jq -e '.tasks[]|select(.id==\"T001\")|.status==\"blocked\"' >/dev/null"
  assert "[$label] scope-creep: the blocked outcome row names scope-creep" \
    bash -c "git -C '$bare' show main:.harness/ledgers/outcomes.jsonl 2>/dev/null | jq -e 'select(.id==\"T001\") | .blocked==true and (.reason|test(\"scope-creep\"))' >/dev/null"
  assert "[$label] scope-creep: the out-of-scope file never reached main" \
    bash -c "! git -C '$bare' show main:other/evil.txt >/dev/null 2>&1"
}

# ── Scenario: garbage verdict → back off + reattempt (never a hard exit / crash) ─────────────────────
scenario_garbage_verdict() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  printf 'RESULT="wat-is-this"\nFILES=""\n' >"$a/fc/build.default"
  # Garbage never terminates the task, so the loop reattempts until MAX_ITERS → exit 4 (not a crash).
  rc="$(run_loop "$d" "$a" 2)"; LAST_RUN_LOG="$a/run.log"

  assert "[$label] garbage: loop reaches MAX_ITERS and exits 4 (kept reattempting, didn't die)" [ "$rc" -eq 4 ]
  assert "[$label] garbage: T001 is still pending (never done, never blocked)" \
    bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json 2>/dev/null | jq -e '.tasks[]|select(.id==\"T001\")|.status==\"pending\"' >/dev/null"
  assert "[$label] garbage: nothing was merged to main" \
    bash -c "! git -C '$bare' show main:src/app.txt >/dev/null 2>&1"
}

# ── Primary-checkout freshness: the dashboard reads the PRIMARY checkout's working-tree files, but the
# worktree loop commits status to origin/main via a detached worktree — so the primary checkout must be
# ff-synced to origin/main EVERY iteration (not only on the drain exit), else the dashboard lags until
# the backlog drains. Run bounded to ONE iteration so the loop exits via MAX_ITERS (exit 4), NOT the
# drain path (which already syncs) — then the primary checkout must ALREADY reflect the completed task.
# (In-place has no gap — it builds directly in the primary checkout — so this holds there trivially.)
scenario_primary_checkout_fresh() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  rc="$(run_loop "$d" "$a" 1 1)"; LAST_RUN_LOG="$a/run.log"   # MAX_ITERS=1, SYNC_PRIMARY_ON_DONE=1 (prod default)

  assert "[$label] fresh: T001 integrated to origin/main (precondition)" \
    bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json 2>/dev/null | jq -e '.tasks[]|select(.id==\"T001\")|.status==\"done\"' >/dev/null"
  assert "[$label] fresh: the loop exited via MAX_ITERS (exit 4), not the drain path" [ "$rc" -eq 4 ]
  assert "[$label] fresh: PRIMARY checkout working tree shows T001=done WITHOUT waiting for drain (dashboard current)" \
    bash -c "jq -e '.tasks[]|select(.id==\"T001\")|.status==\"done\"' '$d/.harness/tracking/TASKS.json' >/dev/null"
}

# ── CI green (REQUIRE_CI=1): a green run → integrate, no CI failure rows ─────────────────────────────
scenario_ci_green() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  printf 'completed/success\n' >"$a/gh/views"
  rc="$(run_loop "$d" "$a" 3 0 REQUIRE_CI=1 CI_TIMEOUT=5)"; LAST_RUN_LOG="$a/run.log"
  assert "[$label] ci-green: T001 integrated (status=done) on green CI" \
    bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json 2>/dev/null | jq -e '.tasks[]|select(.id==\"T001\")|.status==\"done\"' >/dev/null"
  assert "[$label] ci-green: no CI failure rows recorded" \
    bash -c "[ \"\$(git -C '$bare' show main:.harness/ledgers/failures.jsonl 2>/dev/null | jq -s '[.[]|select(.id==\"T001\" and (.kind|startswith(\"ci-\")))]|length')\" = 0 ]"
}

# ── B08: CI indeterminate → the loop RE-CHECKS once before charging a failure (both variants) ─────────
# The in-place variant used to go straight to record_failure "ci-indeterminate"; the worktree variant
# already re-checked. Script an indeterminate (cancelled) run whose RE-CHECK comes back green: the task
# must integrate on this attempt, and (in-place) the "re-checking once" log must appear.
scenario_ci_indeterminate_recheck() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  # wait_ci_green makes 2 `gh run view` calls per invocation (poll + classify): first invocation sees
  # cancelled (indeterminate), the re-check invocation sees success (green).
  printf 'completed/cancelled\ncompleted/cancelled\ncompleted/success\ncompleted/success\n' >"$a/gh/views"
  rc="$(run_loop "$d" "$a" 1 0 REQUIRE_CI=1 CI_TIMEOUT=5)"; LAST_RUN_LOG="$a/run.log"
  assert "[$label] ci-recheck: T001 integrated after an indeterminate→green re-check (not soft-failed)" \
    bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json 2>/dev/null | jq -e '.tasks[]|select(.id==\"T001\")|.status==\"done\"' >/dev/null"
  assert "[$label] ci-recheck: the single re-check fired (log names it)" \
    bash -c "grep -qi 're-check' '$a/run.log'"
}

# ── B10: a run that never completes must NOT hang on `gh run watch` — CI_TIMEOUT bounds the WHOLE wait ─
scenario_ci_watch_bounded() {  # <label> <loop-src>
  local label="$1" src="$2" d bare a rc
  read -r d bare <<<"$(setup_repo "$src")"
  a="$(aux_dir)"
  printf 'in_progress/\n' >"$a/gh/views"   # the run is found but never settles
  rc="$(run_loop "$d" "$a" 2 0 REQUIRE_CI=1 CI_TIMEOUT=1 WAIT_SECONDS=1)"; LAST_RUN_LOG="$a/run.log"
  assert "[$label] ci-watch-bound: the loop returned (didn't hang) — reached MAX_ITERS" [ "$rc" -eq 4 ]
  assert "[$label] ci-watch-bound: 'gh run watch' was never called (bounded poll replaces the unbounded watch)" \
    [ ! -s "$a/gh/watch.calls" ]
  assert "[$label] ci-watch-bound: the CI wait timed out via the bounded poll (log names it)" \
    bash -c "grep -q 'still not finished after' '$a/run.log'"
}

# run_variant_suite <label> <loop-src> — every scenario against one variant.
run_variant_suite() {
  local label="$1" src="$2"
  scenario_happy_path               "$label" "$src"
  scenario_idle_reconcile           "$label" "$src"
  scenario_failed_blocked           "$label" "$src"
  scenario_soft_escalation          "$label" "$src"
  scenario_scope_creep              "$label" "$src"
  scenario_garbage_verdict          "$label" "$src"
  scenario_primary_checkout_fresh   "$label" "$src"
  scenario_ci_green                 "$label" "$src"
  scenario_ci_indeterminate_recheck "$label" "$src"
  scenario_ci_watch_bounded         "$label" "$src"
}

# Plugin source tree carries both variants; an install carries exactly one (as loop.sh, by its
# `# harness-loop-variant:` header). Exercise every distinct variant present.
LAST_RUN_LOG=""
ran=0
if grep -q '^# harness-loop-variant: worktree' "$SCRIPT_DIR/loop.sh" 2>/dev/null; then
  run_variant_suite worktree "$SCRIPT_DIR/loop.sh"; ran=$((ran+1))
elif grep -q '^# harness-loop-variant: in-place' "$SCRIPT_DIR/loop.sh" 2>/dev/null; then
  run_variant_suite in-place "$SCRIPT_DIR/loop.sh"; ran=$((ran+1))
fi
if [ -f "$SCRIPT_DIR/loop.in-place.sh" ]; then
  run_variant_suite in-place "$SCRIPT_DIR/loop.in-place.sh"; ran=$((ran+1))
fi
assert "at least one loop variant was found and tested" [ "$ran" -ge 1 ]

if [ "$FAIL" = 0 ]; then
  echo "PASS: loop-e2e"
else
  echo "FAIL: loop-e2e"
  [ -n "$LAST_RUN_LOG" ] && { echo "--- last run log ($LAST_RUN_LOG) ---"; tail -40 "$LAST_RUN_LOG" 2>/dev/null; }
  exit 1
fi
