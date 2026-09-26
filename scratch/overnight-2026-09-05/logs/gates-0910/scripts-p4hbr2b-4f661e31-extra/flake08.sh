#!/usr/bin/env bash
# 08's self-test N times from a git archive of HEAD, every output kept; which cases go red, how often.
# The opus judge's N2-3 (st_sampler's 0.5 s dwell at 0.1 s reads, flake rate never measured) and this
# round's own red-first gate, whose 08-at-HEAD run under the guard was not a clean PASS once.
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; N="$2"; OUT="$3"; LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
rm -rf "$OUT"; mkdir -p "$OUT/a/tmp"
echo "HEAD $(git -C "$WT" rev-parse HEAD); $N runs"
git -C "$WT" archive HEAD "$LIVE" tools/test_workflow/faults.sh tools/test_workflow/qdisc_snapshot.sh \
    doc/audit/2026-09-25_p4-heartbeat/spike/census_prepare.py | tar -x -C "$OUT/a"
ln -s "$(readlink -f "$WT/p4_proxy")" "$OUT/a/p4_proxy"
nbad=0
for i in $(seq 1 "$N"); do
    ( cd "$OUT/a" && TMPDIR="$OUT/a/tmp" timeout 900 bash "$LIVE/08_heartbeat.sh" --self-test > "$OUT/out$i.txt" 2>&1 )
    rc=$?; reds=$(/usr/bin/grep -c '^  🔴 ' "$OUT/out$i.txt")
    echo "run $i rc $rc $(tail -1 "$OUT/out$i.txt") reds=$reds load=$(cut -d' ' -f1-3 /proc/loadavg)"
    /usr/bin/grep '^  🔴 ' "$OUT/out$i.txt" | cut -c1-240 | sed 's/^/    /'
    [[ $rc == 0 && $reds == 0 ]] || nbad=$((nbad + 1))
done
echo "FLAKE08: $nbad of $N runs not a clean PASS"
exit $(( nbad > 0 ))
