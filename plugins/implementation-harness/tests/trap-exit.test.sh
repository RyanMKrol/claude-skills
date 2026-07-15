#!/usr/bin/env bash
#
# trap-exit.test.sh — regression guard for B02: a trap handler that doesn't `exit` merely returns
# control to wherever the script was interrupted, so the process keeps running after releasing the
# lock. Two parts:
#   1. A PROBE that reproduces the bug's exact signature with the real repo-lock.sh, against both
#      the OLD (broken) and NEW (fixed) trap idiom — SELF-signaled (`kill -INT/-TERM $$`) rather than
#      delivered externally to a backgrounded job: bash ignores SIGINT/SIGQUIT-by-default for async
#      commands started from a non-interactive script (a well-known, environment-dependent quirk —
#      see the bash manual's SIGNALS section), which makes externally-delivered-signal tests flaky
#      across shells/sandboxes. A self-signal is a plain, portable kill(2) call and exercises the
#      exact same trap body the real scripts install; it proves what B02 actually changed (the trap
#      body's own release/exit behavior), not bash's foreground-wait scheduling.
#   2. A STATIC check that all 6 real scripts (2 loop variants + 4 owner CLIs, 7 trap sites —
#      mark-failed.sh has two) carry the fixed 3-line idiom verbatim, and none still carry the old
#      single-line form.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

# --- 1a. PROBE: OLD (broken) idiom — self-signal proves the exact bug signature -----------------
old="$TMP/old.sh"
cat >"$old" <<EOF
#!/usr/bin/env bash
LOCK="$TMP/old.lock"; mkdir -p "\$LOCK"; echo \$\$ >"\$LOCK/pid"
. "$SCRIPT_DIR/repo-lock.sh"
trap 'release_lock' EXIT INT TERM
kill -INT \$\$
echo AFTER-SIGNAL-BUG-PROOF >>"$TMP/old.out"
EOF
chmod +x "$old"
"$old"; rc=$?
assert "[probe] OLD idiom: process does NOT stop at the signal (execution resumes — the bug)" \
  [ -f "$TMP/old.out" ]
assert "[probe] OLD idiom: exits normally (rc 0) instead of being killed" [ "$rc" = 0 ]
assert "[probe] OLD idiom: lock IS released (the dangerous half — guard is gone, process still running)" \
  [ ! -d "$TMP/old.lock" ]

# --- 1b. PROBE: NEW (fixed) idiom — INT and TERM each stop promptly with the right code ---------
fixed_int="$TMP/fixed-int.sh"
cat >"$fixed_int" <<EOF
#!/usr/bin/env bash
LOCK="$TMP/fixed-int.lock"; mkdir -p "\$LOCK"; echo \$\$ >"\$LOCK/pid"
. "$SCRIPT_DIR/repo-lock.sh"
trap 'release_lock' EXIT
trap 'release_lock; trap - EXIT; exit 130' INT
trap 'release_lock; trap - EXIT; exit 143' TERM
kill -INT \$\$
echo AFTER-SIGNAL-SHOULD-NOT-PRINT >>"$TMP/fixed-int.out"
EOF
chmod +x "$fixed_int"
"$fixed_int"; rc=$?
assert "[probe] NEW idiom: INT stops immediately (rc 130)" [ "$rc" = 130 ]
assert "[probe] NEW idiom: INT — never reaches the line after the signal" [ ! -f "$TMP/fixed-int.out" ]
assert "[probe] NEW idiom: INT — lock released exactly once" [ ! -d "$TMP/fixed-int.lock" ]

fixed_term="$TMP/fixed-term.sh"
cat >"$fixed_term" <<EOF
#!/usr/bin/env bash
LOCK="$TMP/fixed-term.lock"; mkdir -p "\$LOCK"; echo \$\$ >"\$LOCK/pid"
. "$SCRIPT_DIR/repo-lock.sh"
trap 'release_lock' EXIT
trap 'release_lock; trap - EXIT; exit 130' INT
trap 'release_lock; trap - EXIT; exit 143' TERM
kill -TERM \$\$
echo AFTER-SIGNAL-SHOULD-NOT-PRINT >>"$TMP/fixed-term.out"
EOF
chmod +x "$fixed_term"
"$fixed_term"; rc=$?
assert "[probe] NEW idiom: TERM stops immediately (rc 143)" [ "$rc" = 143 ]
assert "[probe] NEW idiom: TERM — never reaches the line after the signal" [ ! -f "$TMP/fixed-term.out" ]
assert "[probe] NEW idiom: TERM — lock released exactly once" [ ! -d "$TMP/fixed-term.lock" ]

# --- 2. STATIC check: scripts that install the trap directly carry the fixed idiom verbatim, none
# carry the old one. As of C03, mark-done.sh/mark-failed.sh/mark-reviewed.sh no longer install the
# trap themselves — they go through the shared overlay-edit.sh, which installs it ONCE for all three
# (checked separately below).
for f in loop.sh loop.in-place.sh consolidate-ideas.sh; do
  p="$SCRIPT_DIR/$f"
  assert "[$f] no leftover single-line 'trap ... EXIT INT TERM' idiom" \
    bash -c '! grep -q "trap .release_lock. EXIT INT TERM" "$1"' _ "$p"
  assert "[$f] carries the fixed EXIT-only trap" \
    bash -c "grep -q \"trap 'release_lock' EXIT\\\$\" \"\$1\"" _ "$p"
  assert "[$f] carries the fixed INT trap (release + clear EXIT + exit 130)" \
    bash -c "grep -qF \"trap 'release_lock; trap - EXIT; exit 130' INT\" \"\$1\"" _ "$p"
  assert "[$f] carries the fixed TERM trap (release + clear EXIT + exit 143)" \
    bash -c "grep -qF \"trap 'release_lock; trap - EXIT; exit 143' TERM\" \"\$1\"" _ "$p"
done

# overlay-edit.sh (C03's structural home for B02, shared by the 3 mark-*.sh callers) installs the
# fixed idiom exactly once, and none of the 3 callers re-install it themselves.
oe="$SCRIPT_DIR/overlay-edit.sh"
assert "[overlay-edit.sh] carries the fixed EXIT-only trap" \
  bash -c "grep -q \"trap 'release_lock' EXIT\\\$\" \"\$1\"" _ "$oe"
assert "[overlay-edit.sh] carries the fixed INT trap (release + clear EXIT + exit 130)" \
  bash -c "grep -qF \"trap 'release_lock; trap - EXIT; exit 130' INT\" \"\$1\"" _ "$oe"
assert "[overlay-edit.sh] carries the fixed TERM trap (release + clear EXIT + exit 143)" \
  bash -c "grep -qF \"trap 'release_lock; trap - EXIT; exit 143' TERM\" \"\$1\"" _ "$oe"
for f in mark-done.sh mark-failed.sh mark-reviewed.sh; do
  p="$SCRIPT_DIR/$f"
  assert "[$f] no longer installs its own trap (goes through overlay-edit.sh instead)" \
    bash -c '! grep -q "^trap " "$1"' _ "$p"
  assert "[$f] sources overlay-edit.sh" bash -c 'grep -qF "overlay-edit.sh" "$1"' _ "$p"
done
# mark-failed.sh calls overlay_edit TWICE (--undo branch + main path) — the structural replacement
# for the old "trap present twice" check now that the trap itself lives in overlay-edit.sh.
assert "[mark-failed.sh] calls overlay_edit at BOTH call sites" \
  bash -c '[ "$(grep -c "overlay_edit \"\$OVERLAY_REL\"" "$1")" = 2 ]' _ "$SCRIPT_DIR/mark-failed.sh"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
