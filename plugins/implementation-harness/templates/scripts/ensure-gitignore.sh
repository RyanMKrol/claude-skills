#!/usr/bin/env bash
#
# ensure-gitignore.sh — idempotently maintain the harness-managed block in the repo-root .gitignore.
#
# The harness writes several kinds of gitignored LOCAL SCRATCH: the loop's per-iteration scratch + the
# generated status board, atomic-write temps, the ideas->tasks pipeline dirs, and scope-gap dismissals.
# Their ignore rules used to reach an EXISTING install only as a one-time "manual attention" note during
# the specific upgrade that introduced them — miss that version window (already past it, or skipped) and
# the block never lands, so a scratch file shows up untracked forever. That is a real incident: a
# .scope-gap-ignores/ file got auto-stashed because its ignore block never reached the project.
#
# This script GUARANTEES the block instead. It owns a MARKER-DELIMITED region of the root .gitignore and
# keeps it current, touching NOTHING outside its own two markers — your own entries are never read,
# reordered, or modified. It is run by `implementation-harness-create` (on scaffold) and by
# `implementation-harness-upgrade` (on EVERY run, so existing installs self-heal regardless of which
# version they came from). Idempotent and safe to run at any time.
#
# Usage:  ensure-gitignore.sh [--check] [TARGET_ROOT]
#   --check       report drift (block missing or stale) and exit 1 without writing anything; 0 = current.
#   TARGET_ROOT   repo root whose .gitignore to maintain (default: the git toplevel of this script).
#                 Pass it explicitly when the target may not be a git repo yet (e.g. fresh scaffolding).
#
# NB: deliberately NO $CLAUDECODE refusal (unlike loop.sh / supervise.sh). This is a benign, read-then-
# append helper that the create/upgrade skills — which run INSIDE Claude Code — must be able to call.
set -euo pipefail

CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)}"
[ -n "$ROOT" ] || { echo "ensure-gitignore: cannot determine the repo root (not a git repo? pass TARGET_ROOT explicitly)" >&2; exit 2; }
GITIGNORE="$ROOT/.gitignore"

START='# >>> implementation-harness managed (auto-maintained — do not edit inside) >>>'
END='# <<< implementation-harness managed <<<'

# The canonical managed region (markers + block) — the SINGLE SOURCE OF TRUTH for every harness-owned
# .gitignore entry. Add a new scratch-path ignore between the markers HERE and nowhere else; upgrade
# refreshes this script onto existing installs, and this script then refreshes the block into their
# root .gitignore. (No leading dot on the negations: `!…/.gitkeep` keeps each per-sweep dir present in
# a fresh clone.) Built with `read -d ''` rather than `$(cat <<EOF)` — bash 3.2 (our target) mis-parses
# a heredoc inside command substitution; `read -d ''` returns nonzero at EOF, hence the `|| true`.
IFS= read -r -d '' MANAGED <<MANAGED_EOF || true
$START
# Transient loop scratch (last-iteration verdict) + the generated status board.
.harness/worklog/.result
.harness/worklog/.claude-out*
.harness/worklog/.claude-prompt*
.harness/worklog/.failures.buf
.harness/worklog/.current.json
.harness/worklog/STATUS.md
.harness/worklog/*.log
.harness/worklog/*.audit.md
# atomic-write temps (TASKS.json + the owner-overlay files never keep a crashed-mid-write file)
.harness/tracking/*.tmp
.harness/tracking/*.tmp.*
# ideas->tasks pipeline — ephemeral per-sweep scratch (the .gitkeep keeps each dir in a fresh clone)
.harness/.pending-tasks/*
!.harness/.pending-tasks/.gitkeep
.harness/.pending-questions/*
!.harness/.pending-questions/.gitkeep
# scope-gap dismissals — check-task-scope.sh's per-task "already reviewed" record (fix-scope-gaps)
.harness/.scope-gap-ignores/*
!.harness/.scope-gap-ignores/.gitkeep
$END
MANAGED_EOF
MANAGED="${MANAGED%$'\n'}"   # strip the single trailing newline read captured before EOF

# Detect the current state of the two markers (if-condition form is set -e safe).
have_start=0; have_end=0
if [ -f "$GITIGNORE" ]; then
  if grep -qF -- "$START" "$GITIGNORE"; then have_start=1; fi
  if grep -qF -- "$END"   "$GITIGNORE"; then have_end=1;   fi
fi

existing=""
[ -f "$GITIGNORE" ] && existing="$(cat "$GITIGNORE")"

# Reduce the file to the user's OWN content (everything that is NOT our managed region), then
# re-attach the canonical block with one consistent formula — so an "add" (no markers yet) and a
# "refresh" (stale markers) both converge to the same bytes, i.e. re-running is a genuine no-op.
if [ "$have_start" = 1 ] && [ "$have_end" = 1 ]; then
  # Strip the existing managed region (START..END inclusive). Not passing the multi-line block to awk
  # (awk -v rejects embedded newlines) — awk only DELETES here; the shell re-attaches MANAGED below.
  user_content="$(awk -v s="$START" -v e="$END" '
    $0==s { skip=1 }
    !skip { print }
    $0==e { skip=0 }
  ' "$GITIGNORE")"
  drift="stale"; done_verb="refreshed"
elif [ "$have_start" = 0 ] && [ "$have_end" = 0 ]; then
  user_content="$existing"
  drift="missing"; done_verb="added"
else
  echo "ensure-gitignore: $GITIGNORE has only ONE of the two managed markers (corrupted) — refusing to guess. Fix by hand." >&2
  exit 2
fi

# $() has already stripped trailing blank lines from user_content, so a single blank-line separator
# is deterministic. Block-only file (no user lines) → just the block.
if [ -n "$user_content" ]; then desired="$user_content"$'\n\n'"$MANAGED"; else desired="$MANAGED"; fi

if [ "$desired" = "$existing" ]; then
  echo "ensure-gitignore: root .gitignore managed block already current."
  exit 0
fi

if [ "$CHECK" = 1 ]; then
  echo "ensure-gitignore: root .gitignore managed block is ${drift} (drift) — run ensure-gitignore.sh (no --check) to fix." >&2
  exit 1
fi

tmp="$GITIGNORE.iht-tmp.$$"
printf '%s\n' "$desired" >"$tmp"
mv "$tmp" "$GITIGNORE"
echo "ensure-gitignore: root .gitignore managed block ${done_verb}."
