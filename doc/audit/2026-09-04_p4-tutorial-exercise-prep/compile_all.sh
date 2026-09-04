#!/usr/bin/env bash
# Compile every p4lang/tutorials exercise .p4 (skeleton + solution) OUT OF TREE.
# The tutorials tree is a control; nothing is written inside it.
# [Co-developed with claude code -- Adam]
set -uo pipefail
T=${T:-/home/adam/tutorials}
KIT=${KIT:?}
OUT="$KIT/build"; LOGS="$KIT/logs"
mkdir -p "$OUT" "$LOGS"
printf '%-16s %-26s %-4s %-9s %-8s %s\n' EXERCISE SOURCE RC JSON_BYTES WARNINGS FIRST_ERROR
for d in "$T"/exercises/*/; do
  ex=$(basename "$d")
  for src in "$d"*.p4 "$d"solution/*.p4; do
    [ -e "$src" ] || continue
    rel=${src#$d}
    tag=$(echo "$rel" | tr '/' '_'); tag=${tag%.p4}
    mkdir -p "$OUT/$ex"
    p4c-bm2-ss --p4v 16 --p4runtime-files "$OUT/$ex/$tag.p4info.txtpb" \
        -o "$OUT/$ex/$tag.json" "$src" > "$LOGS/$ex.$tag.log" 2>&1
    rc=$?
    sz=$( [ -f "$OUT/$ex/$tag.json" ] && stat -c%s "$OUT/$ex/$tag.json" || echo - )
    warn=$(grep -c 'warning' "$LOGS/$ex.$tag.log")
    err=$(grep -m1 'error' "$LOGS/$ex.$tag.log" | cut -c1-70)
    printf '%-16s %-26s %-4s %-9s %-8s %s\n' "$ex" "$rel" "$rc" "$sz" "$warn" "${err:--}"
  done
done
