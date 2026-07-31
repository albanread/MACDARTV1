#!/usr/bin/env bash
# run_audit.sh — build st_audit, inventory the world corpus, and partition the
# sent-but-undefined selectors into the lists that drive porting (M0 / D1 of
# ST_PORTING_PLAN.md). Pure static analysis, no VM. Regenerable; the raw *.tsv
# are gitignored, AUDIT_SUMMARY.md is the committed snapshot.
#
#   candidates_lang.tsv   pure-Smalltalk sent-but-undefined — THE porting gap
#   candidates_cocoa.tsv  interior-capital selectors — the ObjC bridge surface
#   methods/classes/sends.tsv  the raw fact tables
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ST="$(cd "$HERE/.." && pwd)"
WORLD="${1:-$ST/world}"

( cd "$ST" && ./build.sh >/dev/null )

# The prelude (st_prelude.h, a raw string literal) defines STSystem/Exception/
# Dictionary/WriteStream/… — real providers. Extract it so its selectors count
# as defined (else STSystem>>split:by: etc. read as false-positive gaps).
sed -n '/R"PRELUDE(/,/)PRELUDE"/p' "$ST/st_prelude.h" \
  | sed '1d;$d' > "$HERE/.prelude.mst"

"$ST/st_audit" --out "$HERE" "$WORLD"/*.mst "$HERE/.prelude.mst"

# candidates = sent, not corpus-defined, minus builtins.txt. Then split by the
# interior-capital heuristic: a capital after the first char == ObjC/Cocoa.
grep -vE '^\s*#|^\s*$' "$HERE/builtins.txt" | sed 's/[[:space:]]*$//' | sort -u > "$HERE/.builtins.sorted"

awk -F'\t' 'NR>1 && $3==0 {print $2"\t"$1}' "$HERE/sends.tsv" \
  | sort -t$'\t' -k2 \
  | join -t$'\t' -1 2 -2 1 -v 1 - "$HERE/.builtins.sorted" \
  | awk -F'\t' '{print $2"\t"$1}' > "$HERE/.notbuiltin"   # count \t selector

# lang = no interior capital; cocoa = has one.
awk -F'\t' '$2 ~ /^.[a-z0-9_:]*[A-Z]/ {next} {print}' "$HERE/.notbuiltin" \
  | sort -rn > "$HERE/.lang.body"
awk -F'\t' '$2 ~ /^.[a-z0-9_:]*[A-Z]/ {print}' "$HERE/.notbuiltin" \
  | sort -rn > "$HERE/.cocoa.body"

{ echo -e "count\tselector"; cat "$HERE/.lang.body"; }  > "$HERE/candidates_lang.tsv"
{ echo -e "count\tselector"; cat "$HERE/.cocoa.body"; } > "$HERE/candidates_cocoa.tsv"
rm -f "$HERE/.builtins.sorted" "$HERE/.notbuiltin" "$HERE/.lang.body" "$HERE/.cocoa.body"

nlang=$(($(wc -l < "$HERE/candidates_lang.tsv") - 1))
ncocoa=$(($(wc -l < "$HERE/candidates_cocoa.tsv") - 1))
echo
echo "== candidates: $nlang language / $ncocoa cocoa-bridge (sent, undefined, non-builtin) =="
echo "-- top language porting candidates (the real gap) --"
tail -n +2 "$HERE/candidates_lang.tsv" | head -25 | awk -F'\t' '{printf "  %5d  %s\n",$1,$2}'
