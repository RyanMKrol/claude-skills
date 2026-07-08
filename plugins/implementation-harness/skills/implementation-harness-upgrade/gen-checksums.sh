#!/usr/bin/env bash
#
# gen-checksums.sh — maintainer-only tool for THIS repo. Regenerates
# CHECKSUMS.jsonl, the per-version file-hash ledger implementation-harness-upgrade's
# Stage 3/4 use to auto-upgrade a file that's merely stale (byte-identical to some
# past released version, never locally edited) without asking the user anything.
#
# NEVER scaffolded into a consumer's .harness/, NEVER invoked by the upgrade skill's
# own runtime logic — the upgrade skill only READS CHECKSUMS.jsonl, it never runs
# this generator. This script only ever runs inside a clone of the claude-skills repo.
#
# File discovery is UNCONDITIONAL and self-updating — every run globs everything
# under the mechanism directories (templates/scripts, templates/dashboard,
# templates/docs/**, templates/harness-CLAUDE.md, templates/README.md,
# templates/skills/implementation-harness-*/SKILL.md). There is no separate
# manifest and no exclude list: a new file added under any of these directories is
# picked up automatically on the very next run, nothing to remember to update. A
# checksummed-but-never-installed file (e.g. a CI-only test script) is simply inert,
# dead data in the ledger — Stage 3 only ever looks up paths it already lists in its
# own target/reference table, so over-covering here is harmless.
#
# Usage:
#   gen-checksums.sh --backfill [N]   one-time: walk the N most recent commits that
#                                     bumped plugin.json's version (oldest-first),
#                                     write the WHOLE ledger fresh. Omit N for full
#                                     history.
#   gen-checksums.sh --append         per-release: hash the CURRENT working tree,
#                                     append (or replace, if re-run for the same
#                                     version) exactly one line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
PLUGIN_REL="plugins/implementation-harness"
TPL_REL="$PLUGIN_REL/templates"
PLUGIN_JSON_REL="$PLUGIN_REL/.claude-plugin/plugin.json"
CHECKSUMS_FILE="$SCRIPT_DIR/CHECKSUMS.jsonl"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}
sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'
  fi
}

# build_files_json — reads "path<TAB>hash" lines from stdin, emits a {"path":"hash",...} JSON object.
build_files_json() {
  jq -R -s '
    split("\n") | map(select(length > 0)) | map(split("\t")) |
    map({(.[0]): .[1]}) | add // {}
  '
}

# discover_files_worktree <tpl_dir> — canonical (templates/-relative) paths on disk, sorted.
discover_files_worktree() {
  local tpl="$1"
  (
    find "$tpl/scripts" -maxdepth 1 -type f 2>/dev/null
    find "$tpl/dashboard" -maxdepth 1 -type f 2>/dev/null
    find "$tpl/docs" -type f 2>/dev/null
    [ -f "$tpl/harness-CLAUDE.md" ] && echo "$tpl/harness-CLAUDE.md"
    [ -f "$tpl/README.md" ] && echo "$tpl/README.md"
    find "$tpl/skills" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' 2>/dev/null
  ) | sed "s#^$tpl/##" | sort
}

# discover_files_at_commit <commit> — same, but from a historical commit's tree via git ls-tree.
discover_files_at_commit() {
  local commit="$1" p rest
  git ls-tree -r --name-only "$commit" -- \
    "$TPL_REL/scripts" "$TPL_REL/dashboard" "$TPL_REL/docs" \
    "$TPL_REL/harness-CLAUDE.md" "$TPL_REL/README.md" "$TPL_REL/skills" 2>/dev/null \
  | while IFS= read -r p; do
      case "$p" in
        "$TPL_REL"/scripts/*)
          rest="${p#"$TPL_REL"/scripts/}"; case "$rest" in */*) continue ;; esac ;;
        "$TPL_REL"/dashboard/*)
          rest="${p#"$TPL_REL"/dashboard/}"; case "$rest" in */*) continue ;; esac ;;
        "$TPL_REL"/docs/*) : ;;
        "$TPL_REL/harness-CLAUDE.md"|"$TPL_REL/README.md") : ;;
        "$TPL_REL"/skills/*/SKILL.md) : ;;
        *) continue ;;
      esac
      echo "${p#"$TPL_REL"/}"
    done | sort
}

# reverse_lines — portable (no GNU tac / BSD `tail -r` dependency).
reverse_lines() { awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'; }

# add_or_replace_line <version> <line> — mutate the GLOBAL `LINES` array in place: replace the
# existing entry for $version if one exists (keeps chronological position), else append. (Bash 3.2
# has no namerefs (`local -n`, bash 4.3+), so this operates directly on the caller's global array
# rather than taking an array name as a parameter.)
add_or_replace_line() {
  local version="$1" line="$2" i v found=0
  for ((i = 0; i < ${#LINES[@]}; i++)); do
    v="$(printf '%s' "${LINES[$i]}" | jq -r .version)"
    if [ "$v" = "$version" ]; then LINES[$i]="$line"; found=1; break; fi
  done
  [ "$found" = 1 ] || LINES+=("$line")
}

cmd="${1:-}"
case "$cmd" in
  --backfill)
    n="${2:-}"
    commits="$(git -C "$REPO_ROOT" log --format='%H' -- "$PLUGIN_JSON_REL")"   # newest-first
    [ -n "$n" ] && commits="$(printf '%s\n' "$commits" | head -n "$n")"
    commits="$(printf '%s\n' "$commits" | reverse_lines)"                      # oldest-first

    LINES=()
    while IFS= read -r commit; do
      [ -n "$commit" ] || continue
      version="$(git -C "$REPO_ROOT" show "$commit:$PLUGIN_JSON_REL" 2>/dev/null | jq -r .version)"
      [ -n "$version" ] && [ "$version" != "null" ] || { echo "WARN: no version at $commit, skipping" >&2; continue; }
      files_json="$(
        discover_files_at_commit "$commit" | while IFS= read -r path; do
          h="$(git -C "$REPO_ROOT" show "$commit:$TPL_REL/$path" 2>/dev/null | sha256_of_stdin)"
          printf '%s\t%s\n' "$path" "$h"
        done | build_files_json
      )"
      line="$(jq -nc --arg v "$version" --argjson f "$files_json" '{version:$v, files:$f}')"
      add_or_replace_line "$version" "$line"
      echo "backfilled $version ($commit)" >&2
    done <<<"$commits"

    printf '%s\n' "${LINES[@]}" >"$CHECKSUMS_FILE"
    echo "wrote ${#LINES[@]} version(s) to $CHECKSUMS_FILE" >&2
    ;;

  --append)
    version="$(jq -r .version "$REPO_ROOT/$PLUGIN_JSON_REL")"
    [ -n "$version" ] && [ "$version" != "null" ] || { echo "ABORT: couldn't read version from $PLUGIN_JSON_REL" >&2; exit 1; }
    files_json="$(
      discover_files_worktree "$REPO_ROOT/$TPL_REL" | while IFS= read -r path; do
        h="$(sha256_of_file "$REPO_ROOT/$TPL_REL/$path")"
        printf '%s\t%s\n' "$path" "$h"
      done | build_files_json
    )"
    line="$(jq -nc --arg v "$version" --argjson f "$files_json" '{version:$v, files:$f}')"

    LINES=()
    if [ -f "$CHECKSUMS_FILE" ]; then
      while IFS= read -r existing; do
        [ -n "$existing" ] && LINES+=("$existing")
      done <"$CHECKSUMS_FILE"
    fi
    add_or_replace_line "$version" "$line"
    printf '%s\n' "${LINES[@]}" >"$CHECKSUMS_FILE"
    echo "appended/updated $version in $CHECKSUMS_FILE ($(printf '%s' "$files_json" | jq 'length') files)" >&2
    ;;

  *)
    echo "usage: gen-checksums.sh --backfill [N] | --append" >&2
    exit 2
    ;;
esac
