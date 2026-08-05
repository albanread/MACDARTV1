#!/usr/bin/env bash
# Build the standalone MACVM Smalltalk (.mst) reader — Sprint 0 of ST_PLAN.md.
# Pure C++17, no Dart-VM dependencies. Produces ./st_dump.
set -euo pipefail
cd "$(dirname "$0")"

clang++ -std=c++17 -Wall -Wextra -O0 \
  st_lexer.cc st_parser.cc st_dump.cc \
  -o st_dump

echo "built ./st_dump"

# The corpus static-inventory / cross-reference tool (M0 of ST_PORTING_PLAN.md).
clang++ -std=c++17 -Wall -Wextra -O0 \
  st_lexer.cc st_parser.cc st_audit.cc \
  -o st_audit

echo "built ./st_audit"
