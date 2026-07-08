---
name: freshen-up
description: >-
  Use when the user wants to update all their Claude Code marketplaces and plugins in one go —
  phrases like "update my plugins", "update all my marketplaces", "refresh my plugins", "sync my
  plugins", "freshen up my plugins", "/freshen-up". Runs `claude plugin marketplace update`
  (refreshes every configured marketplace from its source) then `claude plugin update` for every
  currently-installed plugin, via the `claude` CLI's own scriptable subcommands — NOT the
  interactive `/plugin` session commands, which have no bulk "update all" option. Reports exactly
  what changed version. Does nothing else — no project files touched, no other side effects.
allowed-tools: Bash
---

# Update every marketplace and every installed plugin

A single-purpose skill: update everything, report what changed, remind the user how to pick it up.
Read this whole file, then run the steps in order.

## 1. Snapshot the current state

```bash
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
BEFORE="$(claude plugin list --json)"
```

## 2. Update every marketplace, then every installed plugin

```bash
claude plugin marketplace update
echo "$BEFORE" | jq -r '.[].id' | xargs -n1 claude plugin update
```

Run these as shown — `claude plugin marketplace update` with no argument updates ALL configured
marketplaces (confirmed via `claude plugin marketplace update --help`: "updates all if no name
specified"); `claude plugin update <plugin>` only takes one target at a time, so the `jq`/`xargs`
loop is what makes "every installed plugin" a single command. If any individual `claude plugin
update` call fails (e.g. a plugin removed from its marketplace), let it print its own error and keep
going — don't abort the whole run over one plugin.

## 3. Diff and report

```bash
AFTER="$(claude plugin list --json)"
diff <(echo "$BEFORE" | jq -r '.[] | "\(.id) \(.version)"' | sort) \
     <(echo "$AFTER"  | jq -r '.[] | "\(.id) \(.version)"' | sort)
```

Summarize plainly for the user: which plugins changed version (old → new), which were already
current, and the marketplace update's own output (new commits/versions pulled, if any). Use the
diff output above rather than re-deriving it by hand.

## 4. Remind the user to pick it up

Every `claude plugin update` prints "restart required to apply" — this session won't see the new
versions until the user runs `/reload-plugins`, or starts a fresh `claude` session. Say so plainly as
the last line of the report; don't imply the update is fully "live" yet.
