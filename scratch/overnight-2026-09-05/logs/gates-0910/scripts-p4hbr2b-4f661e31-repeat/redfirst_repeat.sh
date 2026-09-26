#!/usr/bin/env bash
# redfirst_repeat.sh <N> <redfirst script> <args...> -- the exact configuration that went red once
# (redfirst_r2b's 08-at-HEAD), N more times, every failing output kept (KEEP per run).
# [Co-developed with claude code -- Adam]
set -u
N="$1"; shift; R="$1"; shift; KROOT="${KEEP_ROOT:?}"; nbad=0
for i in $(seq 1 "$N"); do
    out="$(KEEP="$KROOT/run$i" bash "$R" "$@" 2>&1)"; rc=$?
    echo "run $i rc $rc: $(tail -1 <<<"$out") | $(/usr/bin/grep -c '^  BAD' <<<"$out") BAD line(s)"
    /usr/bin/grep -A12 '^  BAD' <<<"$out" | cut -c1-240 | sed 's/^/    /'
    (( rc == 0 )) || nbad=$((nbad + 1))
done
echo "REDFIRST-REPEAT: $nbad of $N runs not all-as-expected"
exit $(( nbad > 0 ))
