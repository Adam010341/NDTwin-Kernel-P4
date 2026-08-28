#!/usr/bin/env bash
# Keyword sweep over the 14 bmv2-performance PDFs (as pdftotext -layout output).
# Purpose: locate (a) build/compile-configuration mentions, (b) bmv2 variant naming,
# (c) packet-size axes, (d) flow-count axes. A zero hit in (a) for a paper is itself
# a data point for GAP.md ①.
# Usage: sweep_keywords.sh <dir-with-txt-files> <out-dir>
# [Co-developed with claude code -- Adam]
set -u
TXT_DIR="${1:?txt dir}"
OUT="${2:?out dir}"
mkdir -p "$OUT"

# (a) build / compile configuration
grep -in -E -- '-O[0123]|CXXFLAGS|CFLAGS|configure|compil|build (flag|option|config)|disable.logging|disable.elogger|logging.macro|NDEBUG|debug build|release build|optimi[sz]ation (flag|level)' \
  "$TXT_DIR"/*.txt > "$OUT/hits_build.txt" 2>/dev/null
# (b) bmv2 variant / version identity
grep -in -E 'simple_switch_grpc|simple_switch|psa_switch|behavioral.model|bmv2 version|v1model|p4c' \
  "$TXT_DIR"/*.txt > "$OUT/hits_variant.txt" 2>/dev/null
# (c) packet-size axis
grep -in -E 'packet (size|length)|frame (size|length)|64.?byte|64 B|128.?byte|512.?byte|1400|1500|MTU|pps|packets per second|packet rate' \
  "$TXT_DIR"/*.txt > "$OUT/hits_pktsize.txt" 2>/dev/null
# (d) flow-count axis
grep -in -E 'number of flows|flow count|concurrent flows|parallel (flows|streams)|multiple flows|16 flows|multi.flow' \
  "$TXT_DIR"/*.txt > "$OUT/hits_flows.txt" 2>/dev/null

for f in hits_build hits_variant hits_pktsize hits_flows; do
  echo "== $f: $(wc -l < "$OUT/$f.txt") hits =="
done
# Per-paper hit count for (a) — papers with 0 are the interesting ones
echo "== per-paper build-keyword hits =="
for t in "$TXT_DIR"/*.txt; do
  n=$(grep -c -i -E -- '-O[0123]|CXXFLAGS|CFLAGS|configure|compil|build (flag|option|config)|disable.logging|disable.elogger|logging.macro|NDEBUG|debug build|release build|optimi[sz]ation (flag|level)' "$t")
  printf '%6d  %s\n' "$n" "$(basename "$t")"
done
