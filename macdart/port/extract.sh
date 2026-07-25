#!/usr/bin/env bash
# MACDART Phase 0 — deterministic extraction from the read-only reference tree.
#
# Copies the subset of dart-lang/sdk @ 1.24.3 needed to build a darwin-arm64
# JIT `dart` into an owned tree. The reference (../sdk) is never modified.
#
# Policy:
#   * Keep ALL headers and arch/OS source files on disk (cheap; prevents broken
#     #includes). The COMPILE set is narrowed later, in CMake, by arch/OS/test
#     filters — see port/gen_sources.py. "Files present" is generous;
#     "files compiled" is precise. The two are deliberately decoupled.
#   * Prune only what is large and definitely unused: unit tests (*_test.*) and
#     the Observatory web UI (huge Dart+JS; we stub its asset blob).
#
# Idempotent: re-running re-syncs. Safe to run repeatedly.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$(cd "$HERE/.." && pwd)"                 # macdart/
SRC="$(cd "$DEST/../sdk" && pwd)"              # sdk/  (reference quarry)

echo "extract: SRC=$SRC"
echo "extract: DEST=$DEST"
[ -f "$SRC/tools/VERSION" ] || { echo "ERROR: reference SDK not found at $SRC" >&2; exit 1; }

# rsync excludes applied to every runtime subtree copy.
COMMON_EXCLUDES=(
  --exclude='*_test.cc'
  --exclude='*_test.h'
  --exclude='*_test_*.cc'
  --exclude='.git'
)

copy_tree() { # src_rel  dest_rel  [extra rsync args...]
  local src_rel="$1"; local dest_rel="$2"; shift 2
  mkdir -p "$DEST/$dest_rel"
  rsync -a --delete "${COMMON_EXCLUDES[@]}" "$@" "$SRC/$src_rel/" "$DEST/$dest_rel/"
}

# --- VM: the engine (arm64 + portable; other arches kept on disk, unbuilt) ---
copy_tree runtime/vm runtime/vm

# --- Platform abstraction layer ---
copy_tree runtime/platform runtime/platform

# --- Core-library native method implementations (+ patch .dart sources) ---
copy_tree runtime/lib runtime/lib

# --- Embedder: dart:io, builtin, main() (+ builtin/io .dart sources) ---
copy_tree runtime/bin runtime/bin

# --- Public embedding API headers (include/dart_api.h, ...) ---
copy_tree runtime/include runtime/include

# --- Vendored dependency: double-conversion (grisu float<->string) ---
copy_tree runtime/third_party/double-conversion runtime/third_party/double-conversion

# --- Core libraries, as Dart source (compiled to C arrays at build time) ---
# Exclude the browser-only libraries we will never target (html/js/web_*).
copy_tree sdk/lib sdk/lib \
  --exclude='html/' --exclude='js/' --exclude='js_util/' --exclude='web_audio/' \
  --exclude='web_gl/' --exclude='web_sql/' --exclude='indexed_db/' --exclude='svg/' \
  --exclude='_blink/' --exclude='_chrome/'

# --- Reference build manifests (parsed by our CMake, not executed) ---
mkdir -p "$DEST/runtime"
cp "$SRC/runtime/dart-runtime.gyp" "$DEST/runtime/dart-runtime.gyp"

# --- VERSION + license provenance ---
mkdir -p "$DEST/tools"
cp "$SRC/tools/VERSION" "$DEST/tools/VERSION"
# Preserve Dart's license and the accompanying patent grant (BSD-3-Clause +
# PATENTS). double-conversion carries its own LICENSE inside its copied dir.
cp "$SRC/LICENSE" "$DEST/LICENSE.dart" 2>/dev/null || true
cp "$SRC/PATENTS" "$DEST/PATENTS.dart" 2>/dev/null || true

# --- MACDART-owned files that live inside the extracted tree -----------------
# zlib shim: dart:io's filter.cc includes "zlib/zlib.h" (a vendored path absent
# here); redirect it to the system zlib in the macOS SDK.
mkdir -p "$DEST/runtime/third_party/zlib"
cat > "$DEST/runtime/third_party/zlib/zlib.h" <<'ZLIB'
// MACDART shim: redirect the vendored zlib include to the system one.
#include <zlib.h>
ZLIB

# --- Apply the port: the three arm64 / clang-17 fixes on top of pristine -----
# The patch is generated against pristine 1.24.3, so it applies to the fresh
# extract. Idempotent: skip if already applied.
if patch -p1 --dry-run -d "$DEST" < "$HERE/../patches/macdart-port.patch" >/dev/null 2>&1; then
  patch -p1 -d "$DEST" < "$HERE/../patches/macdart-port.patch"
  echo "extract: applied macdart-port.patch (3 VM fixes)"
else
  echo "extract: macdart-port.patch already applied (or does not apply) — skipping"
fi

echo "extract: done."
echo "extract: VM .cc on disk      : $(find "$DEST/runtime/vm"  -name '*.cc' | wc -l | tr -d ' ')"
echo "extract: bin .cc on disk     : $(find "$DEST/runtime/bin" -name '*.cc' | wc -l | tr -d ' ')"
echo "extract: core-lib .dart files: $(find "$DEST/sdk/lib"     -name '*.dart' | wc -l | tr -d ' ')"
echo "extract: total size          : $(du -sh "$DEST" | cut -f1)"
