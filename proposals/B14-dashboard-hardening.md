# B14: Dashboard hardening batch — attribute escaping, EADDRINUSE, readBody hang, spec-path containment

**Type**: bug (batch of four small, same component) · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/dashboard/server.js` (+ `lib.js` if the escaper moves there)
**Release**: PATCH bump · MIGRATIONS entry (mechanism) · checksums · `node --check` + `lib.test.js`

Context: the server binds `127.0.0.1` only and mutation endpoints re-check loopback, so none of
these are remote vulnerabilities — but the content flowing through them is LLM/tool-authored and
hits these paths routinely.

## 1. Escapers don't escape quotes → attribute breakout

The client-side `esc()` (inside the `renderPage()` template string) replaces only `& < >`, and its
output is interpolated into DOUBLE-QUOTED attributes — e.g. the failure pill's
`title="${tip}"` where tip comes from `ledgers/failures.jsonl` `detail` (arbitrary tool output).
A `detail` containing `"` (`expected "foo" but got "bar"` — extremely common) breaks the
attribute; at worst injects an event handler. Server-side `escHtml` has the same gap (latent —
currently only used in element-text positions).
**Fix**: both escapers also map `"` → `&quot;` and `'` → `&#39;`. Add lib.test.js cases (move the
shared escaper into lib.js if that keeps one implementation).

## 2. No `server.listen` error handler

Port taken (second dashboard) → unhandled `error` event → raw stack-trace crash.
**Fix**: `server.on('error', …)` printing "port N in use — is another dashboard running? (set
PORT=…)" and exiting 1.

## 3. `readBody` neither resolves nor rejects on oversized bodies

On `body.length > 1e6` it calls `req.destroy()` and leaves the promise pending — a stuck handler.
**Fix**: reject (and catch → 413) instead of bare destroy.

## 4. `task.spec` read without containment

`loadState` does `readText(path.join(ROOT, task.spec))` — a spec of `../../etc/passwd` reads
outside the repo. Loop-authored data, loopback-only, read-only — but free to harden.
**Fix**: `const p = path.resolve(ROOT, task.spec); if (!p.startsWith(ROOT + path.sep)) return null;`

## Acceptance criteria

- A failures.jsonl detail containing `"` renders as a literal quote in the pill tooltip; the row's
  markup stays intact (assert via lib.test.js on the escaper + a rendered-string spot check).
- Second dashboard on the same port → friendly message, exit 1, no stack trace.
- A >1MB POST body → 413 response, connection closed, server keeps serving.
- An out-of-tree spec path → spec renders as absent; no read outside ROOT.
