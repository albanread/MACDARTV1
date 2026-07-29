#!/usr/bin/env bash
# Build the standalone MACVM Smalltalk (.mst) reader — Sprint 0 of ST_PLAN.md.
# Pure C++17, no Dart-VM dependencies. Produces ./st_dump.
set -euo pipefail
cd "$(dirname "$0")"

clang++ -std=c++17 -Wall -Wextra -O0 \
  st_lexer.cc st_parser.cc st_dump.cc \
  -o st_dump

echo "built ./st_dump"
