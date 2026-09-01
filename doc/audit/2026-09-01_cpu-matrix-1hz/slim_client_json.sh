#!/usr/bin/env bash
# Reduce iperf3 --json output to the block the analyses in this directory actually read,
# without laundering a failure into something that looks like a result.
#
# Usage:  slim_client_json.sh <raw-file> <out-file> [label]
# Exit:   0  a result block was found and slimmed
#         3  no result block -- <out-file> is the raw input, verbatim
#         2  usage / missing input
#
# [Co-developed with claude code -- Adam]
#
# This lives in its own file because measure.sh and tests/shell/test_slim_client_json.sh both
# need it, and a test that re-implements the branch it is testing proves nothing. The 08-20
# round hit "two callers reading one piece of evidence through different code" three times in
# two days; this is the same mistake declined once more.
#
# What it is defending against, concretely. iperf3 emits {"error": "..."} instead of a result
# when it fails. The filter this replaces selected .end.sum and .start.test_start only, so on
# that input both selectors yielded null and it wrote a *well-formed* 76-byte file of nulls,
# discarding the error text -- a dead run and a missing run became indistinguishable, and
# neither looked broken. raw/mzero_nopoll_client.json is a committed instance: piping an
# iperf3 error object through the old filter reproduces it byte for byte. The run behind it
# was only salvageable because /proc/net/dev had counted the traffic independently.
set -uo pipefail

RAW="${1:-}"
OUT="${2:-}"
LABEL="${3:-slim}"

if [ -z "$RAW" ] || [ -z "$OUT" ]; then
    echo "usage: slim_client_json.sh <raw-file> <out-file> [label]" >&2
    exit 2
fi
if [ ! -f "$RAW" ]; then
    echo "[$LABEL] slim: no such file: $RAW" >&2
    exit 2
fi

# No jq means degrade to verbose rather than to no data -- the full output is still a result.
if ! command -v jq >/dev/null 2>&1; then
    cp "$RAW" "$OUT"
    exit 0
fi

# -e makes jq exit non-zero when the selected value is null or false, which is the whole test:
# a truncated file fails to parse and an error object has no .end.sum, and both take the same
# branch as each other rather than the same branch as a result.
if jq -e '.end.sum' "$RAW" >/dev/null 2>&1; then
    jq '{end: {sum: .end.sum}, start: {test_start: .start.test_start}}' "$RAW" > "$OUT"
    exit 0
fi

cp "$RAW" "$OUT"
echo "[$LABEL] WARNING: iperf3 produced no end.sum -- keeping its output verbatim" >&2
jq -r '.error // "no .error field either; the file may be truncated"' "$RAW" 2>/dev/null \
    | sed "s/^/[$LABEL] iperf3: /" >&2
exit 3
