# B15: Dashboard performance — tail reads, async subprocess calls, and a parse-error banner

**Type**: bug/perf (batch, same component) · **Priority**: P2 · **Effort**: M
**Affected files**: `templates/dashboard/server.js`, `lib.js`
**Release**: MINOR bump · MIGRATIONS entry (mechanism) · checksums · `node --check` + `lib.test.js`

## Problems (verified)

1. **O(whole-transcript) work every 5s poll.** `claudeOutTailFor` reads the ENTIRE
   `.claude-out.<phase>.jsonl` (multi-MB on a long build) and `liveOutputFromJsonl` JSON-parses
   every line — only to `slice(-8000)` chars at the end. Similarly `blockedIds()` reads every
   `worklog/*.md` in full per `/api/backlog` poll, and `loadState` re-reads every task's
   spec/worklog/audit each poll.
2. **Synchronous subprocess spawns block the single-threaded server.** `runPolicy`/`runPolicyRaw`
   use `execFileSync('jq', …)` — called twice per facet cell inside `buildHarnessState`'s loop
   (mtime-cached, but a cache-miss rebuild with a wide matrix stalls ALL requests for seconds);
   `lockState`/`freshness`/`gitCommonDir` run `execFileSync('git', …)` on EVERY `/api/activity`
   poll with no cache.
3. **A malformed TASKS.json silently blanks the board.** `readJson(TASKS_PATH, {tasks: []})`
   swallows parse errors → corrupt backlog renders as "0 tasks, done" — indistinguishable from a
   real empty backlog. (The loop writes via temp+rename so torn reads are rare; hand-edits and the
   `block_task` direct-`>` write path are the realistic sources.)

## Proposed fixes

1. **Tail-read the live transcript**: `fs.open` + read only the last N bytes (e.g. 64KB), split on
   newline, drop the first partial line, parse only that window. Cache `blockedIds`/spec/worklog
   reads keyed on file mtime (a tiny `mtimeCache(path, fn)` helper) so unchanged files cost a
   `stat`, not a read.
2. **Go async**: replace `execFileSync` with promisified `execFile` in request handlers (`/api/*`
   handlers can be async; they already return promises in places). Batch the per-cell jq calls
   into ONE jq invocation over all cells if feasible (`--argjson cells [...]` and a jq loop), else
   at least run them concurrently with `Promise.all`. Cache the git-derived values in
   `/api/activity` for a few seconds.
3. **Parse-error banner**: `readJson` distinguishes missing (→ default) from unparseable (→ throw
   or return a marker); `/api/backlog` returns `{parseError: "..."}` and the client renders a red
   banner "TASKS.json is not valid JSON — the board may be stale" instead of an empty board.

## Acceptance criteria

- With a 50MB fixture transcript, `/api/activity` responds in <100ms and memory stays flat.
- A slow jq (simulate with a wrapper sleeping 2s) no longer blocks a concurrent `/api/backlog`.
- Corrupt TASKS.json → visible banner, not an empty "done" board; valid file → unchanged UI.
- lib.test.js: cases for the tail-window parser (partial first line dropped, exact-boundary) and
  the readJson marker.

## Notes

Pure lib-shaped logic (tail-window line parser, mtime cache) belongs in `lib.js` where it is
testable — server.js keeps only the fs/exec glue (the established split). F12 (client extraction)
is a separate proposal; don't couple them.
