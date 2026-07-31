#!/usr/bin/env bash
# Does every <primitive: N> in the world actually do something on this VM?
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACDART="$(cd "$HERE/../.." && pwd)"
DART="$MACDART/build-st-rel/dart"
[ -x "$DART" ] || DART="$MACDART/build-release/dart"
[ -x "$DART" ] || { echo "no dart with ST support" >&2; exit 1; }
exec "$DART" "$HERE/primitive_coverage.dart" "$HERE/../world"
