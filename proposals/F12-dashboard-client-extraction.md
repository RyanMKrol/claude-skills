# F12: Dashboard — extract the ~870-line inline client app out of renderPage()

**Type**: feature/refactor · **Priority**: P2 · **Effort**: M
**Affected files**: `templates/dashboard/server.js` (renderPage shrinks to a shell), NEW `templates/dashboard/app.js` + `styles.css` (served statically), `lib.test.js` or a new client test file, create/upgrade file plumbing, MIGRATIONS
**Release**: MINOR bump · MIGRATIONS entry (new mechanism files) · checksums · `node --check`

## Problem

~870 of server.js's ~1400 lines are ONE template literal containing all CSS plus the entire
client-side app (theme derivation, scroll preservation, range-select, every render function). As
an opaque string it is un-lintable and untestable — the 1.68.1 force-scroll regression lived
exactly here, structurally out of reach of lib.test.js. The client `esc()` quote gap (B14) is
another symptom: the client can't share the tested server-side helpers.

## Design

1. Serve `app.js` and `styles.css` as static sibling files (the server already reads/serves files;
   add two routes with correct content-types; CSP-safe since same-origin).
2. Move the client JS out verbatim FIRST (a pure cut-and-paste commit — behavior identical,
   `node --check` now covers it), CSS second. renderPage() keeps only the HTML skeleton +
   `<script src>`/`<link>`.
3. Then (follow-up commit) make the pure client functions importable for tests: either a shared
   `client-lib.js` consumed by both app.js and the test runner, or structure app.js with a
   `module.exports` guard (`if (typeof module !== 'undefined')`) like lib.js already does. Priority
   test targets: `deriveLight`/`hexToHsl`/`hslToHex` (pure color math, zero tests today), the
   scroll-preservation decision logic (the 1.68.1 class), the client `esc()` (unify with the
   server escaper per B14).

## Acceptance criteria

- Pixel-identical dashboard before/after the extraction commits (manual side-by-side on a fixture
  repo; the extraction commits change NO logic).
- `node --check` passes on app.js (it now catches syntax errors CI couldn't see inside the string).
- New files plumbed: create copy list, upgrade mechanism table, MIGRATIONS new-files, checksums.
- At least the color-math + scroll-decision functions under test.

## Notes

Land B14/B15 relative to this in whatever order is convenient, but don't interleave — each is a
clean diff on its own. If F09/F10/F11 are planned soon, do THIS first so their client code is born
testable.
