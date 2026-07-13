#!/usr/bin/env bash
#
# ensure-actionlint.sh — best-effort, idempotent installer for rhysd/actionlint (the GitHub Actions
# workflow linter) into the harness's own scratch bin: `.harness/.bin/actionlint`. Pure bash + curl +
# tar — NO package manager, NO language runtime, NO Docker — so it works on any GitHub-Actions-capable
# machine (Linux/macOS, amd64/arm64/386) regardless of the target project's stack (Node, Python, Swift,
# …). The version is PINNED (ACTIONLINT_VERSION) for determinism, and the download is verified against
# the release's published sha256 checksums before it is trusted.
#
# CONTRACT: on success prints the binary's absolute path on stdout and exits 0. On ANY failure (offline,
# rate-limited, unsupported platform, checksum mismatch) it prints the reason to stderr and exits
# non-zero — the caller (loop.sh `structural_checks`) treats a non-zero exit as "linter unavailable" and
# WARNs + SKIPS the local workflow-YAML check rather than blocking the build (the scaffolded
# lint-workflows.yml CI job is the authoritative catch). It NEVER blocks on its own.
#
# Usage: ensure-actionlint.sh [<repo-root>]   (defaults to the git toplevel, else $PWD)
set -euo pipefail

VER="${ACTIONLINT_VERSION:-1.7.12}"
ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BIN_DIR="$ROOT/.harness/.bin"
BIN="$BIN_DIR/actionlint"

# Idempotent: already installed at the pinned version → just echo the path.
if [ -x "$BIN" ] && "$BIN" --version 2>/dev/null | head -1 | grep -qx "$VER"; then
  printf '%s\n' "$BIN"; exit 0
fi

os=""; case "$(uname -s)" in
  Linux) os=linux ;; Darwin) os=darwin ;;
  *) echo "ensure-actionlint: unsupported OS '$(uname -s)'" >&2; exit 1 ;;
esac
arch=""; case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; i?86) arch=386 ;;
  *) echo "ensure-actionlint: unsupported arch '$(uname -m)'" >&2; exit 1 ;;
esac
command -v curl >/dev/null 2>&1 || { echo "ensure-actionlint: curl not found on PATH" >&2; exit 1; }
sha_cmd=""
if command -v sha256sum >/dev/null 2>&1; then sha_cmd="sha256sum"
elif command -v shasum   >/dev/null 2>&1; then sha_cmd="shasum -a 256"
else echo "ensure-actionlint: no sha256 tool (sha256sum/shasum)" >&2; exit 1; fi

asset="actionlint_${VER}_${os}_${arch}.tar.gz"
base="https://github.com/rhysd/actionlint/releases/download/v${VER}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$base/$asset"                          -o "$tmp/$asset"        2>/dev/null || { echo "ensure-actionlint: download failed ($base/$asset) — offline or rate-limited?" >&2; exit 1; }
curl -fsSL "$base/actionlint_${VER}_checksums.txt" -o "$tmp/checksums.txt" 2>/dev/null || { echo "ensure-actionlint: checksums download failed" >&2; exit 1; }

want="$(grep -E "[[:space:]]${asset}\$" "$tmp/checksums.txt" | awk '{print $1}' | head -1)"
got="$(cd "$tmp" && $sha_cmd "$asset" | awk '{print $1}')"
if [ -z "$want" ] || [ "$want" != "$got" ]; then
  echo "ensure-actionlint: sha256 mismatch for $asset (want='${want:-<none>}' got='$got') — refusing to install" >&2; exit 1
fi

tar -xzf "$tmp/$asset" -C "$tmp" actionlint 2>/dev/null || { echo "ensure-actionlint: extract failed" >&2; exit 1; }
mkdir -p "$BIN_DIR"
mv "$tmp/actionlint" "$BIN"
chmod +x "$BIN"
printf '%s\n' "$BIN"
