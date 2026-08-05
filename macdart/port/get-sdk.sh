#!/usr/bin/env bash
# get-sdk.sh — obtain the reference Dart 1.24.3 tree the build extracts from.
#
# Source of truth is our OWNED private mirror, not dart-lang/sdk: Dart V1 is
# end-of-life and Google could archive or remove the 1.24.3 tag/branch at any
# time. The mirror is a byte-verbatim snapshot of dart-lang/sdk @ 1.24.3
# (commit 0b0b41ef25358dd77d63b4d02718287c26f8e408); see its PROVENANCE.md for
# the exact upstream reference and a byte-match check. Owning it removes the
# one external point of failure — the build itself is fully offline once the
# tree is present (no gclient/gyp/GN; double-conversion is vendored inside the
# tree, zlib is the system's).
#
# Idempotent: does nothing if the reference tree is already present. Override
# the source with MACDART_SDK_MIRROR (e.g. a local path or a fork).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"              # repo root (holds sdk/ and macdart/)
SDK="$ROOT/sdk"
MIRROR="${MACDART_SDK_MIRROR:-https://github.com/albanread/dart-v1-sdk.git}"

if [ -f "$SDK/tools/VERSION" ]; then
  echo "get-sdk: reference tree already present at $SDK — nothing to do."
  exit 0
fi

echo "get-sdk: cloning the owned Dart 1.24.3 mirror"
echo "get-sdk:   $MIRROR  ->  $SDK"
git clone --depth 1 "$MIRROR" "$SDK"
# Sanity: the extractor's precondition.
[ -f "$SDK/tools/VERSION" ] || { echo "get-sdk: ERROR — clone did not yield tools/VERSION" >&2; exit 1; }
echo "get-sdk: done — $(grep -E '^(MAJOR|MINOR|PATCH) ' "$SDK/tools/VERSION" | tr '\n' ' ')"
