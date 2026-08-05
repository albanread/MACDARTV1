#!/usr/bin/env bash
# The Smalltalk type-conformance test: what Smalltalk's types ARE on this VM.
# Needs a dart built with the ST front-end (macdart/build-st-rel).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACDART="$(cd "$HERE/../.." && pwd)"
DART="$MACDART/build-st-rel/dart"
[ -x "$DART" ] || DART="$MACDART/build-release/dart"
[ -x "$DART" ] || { echo "run_conformance.sh: no dart with ST support" >&2; exit 1; }
exec "$DART" "$HERE/run_conformance.dart" "$HERE/type_conformance.mst"
