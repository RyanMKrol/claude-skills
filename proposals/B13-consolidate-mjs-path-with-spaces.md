# B13: consolidate-ideas.mjs breaks on repo paths containing spaces

**Type**: bug · **Priority**: P3 · **Effort**: S
**Affected files**: `templates/scripts/consolidate-ideas.mjs` (top-of-file path derivation)
**Release**: PATCH bump · MIGRATIONS entry (mechanism) · checksums

## Problem

The script derives its own location with `new URL(import.meta.url).pathname`, which yields a
percent-encoded path (`/Users/x/My%20Repo/...`) for any path containing spaces (or other encoded
characters). Every subsequent `fs` call against derived paths then fails with ENOENT — the whole
ideas-consolidation pipeline is broken for such repos.

## Proposed fix

```js
import { fileURLToPath } from 'node:url';
const __filename = fileURLToPath(import.meta.url);
```

and derive directories from that. Audit the file for any other `new URL(...).pathname` usage.

## Acceptance criteria

- Running the consolidator inside a scratch repo whose absolute path contains a space works end
  to end (id allocation, spec writing, inbox row removal).

## Test plan

Extend `templates/scripts/consolidate-rewire.test.sh` (or T05's new suite): create the fixture
under `"$(mktemp -d)/with space"` and run the existing rewire scenario there.
