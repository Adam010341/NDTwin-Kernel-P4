#!/usr/bin/env bash
# probe_report.sh <worktree> <out dir> -- round (a), 09-27: the six read-only-probe suites, each run
# twice, every call recorded, nothing reaching root. [Co-developed with claude code -- Adam]
#   R  the refusing nolab shims (make_shims.sh), no fabric -- what the suite does today under the gate
#   L  the live-answering shims (make_shims_live.sh): `ndtwin-lab status` lists energy/sim/topo and
#      "bmv2: 10  mininet: 4", `topo-out` a prompt, `ovs-vsctl list-br` s1..s4, `mnexec -a 1 true`
#      rc 0, `sudo -l` grants; ps lists Mininet hosts h1..h4 and ten simple_switch_grpc (pids above
#      pid_max). Every OTHER sudo is recorded and refused -- those are what a live answer leads to.
# Output: <out>/{R,L}/<suite>.{out,calls,rc}, and a table of the calls L makes that R does not.
set -u
WT="$1"; OUT="$2"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SUITES=(test_apps_stop_kills_the_group.sh test_cell_gate_suspect_wiring.sh test_lab_handoff.sh
        test_ndt_app_orphans.sh test_ndt_honesty.sh test_ndt_sample_rate_reads_both_bounds.sh)
cd "$WT" || exit 2
lab_hosts() { /usr/bin/ps -eo args= 2>/dev/null | /usr/bin/grep -cE '(^| )mininet:[A-Za-z0-9_-]+$'; }
[[ "$(lab_hosts)" == 0 ]] || { echo "REFUSE: a real fabric is up"; exit 2; }
rm -rf "$OUT"; mkdir -p "$OUT/R" "$OUT/L"
bash "$HERE/make_shims.sh" "$OUT/shims_R" >/dev/null
bash "$HERE/make_shims_live.sh" "$OUT/shims_L" >/dev/null
echo "HEAD $(git rev-parse HEAD)"
for s in "${SUITES[@]}"; do
    for p in R L; do
        env -u SELFTEST_PROBE_SUDO -u NDT_MEASURING PATH="$OUT/shims_$p:$PATH" NOLAB_LOG="$OUT/$p/$s.calls" \
            NOLAB_SUITE="$s" NOLAB_PASS="$p" NOLAB_FAKE_FABRIC=$([[ $p == L ]] && echo 1 || echo 0) \
            NOLAB_FAKE_BMV2=$([[ $p == L ]] && echo 1 || echo 0) \
            timeout 900 bash "tests/shell/$s" < /dev/null > "$OUT/$p/$s.out" 2>&1
        echo $? > "$OUT/$p/$s.rc"; touch "$OUT/$p/$s.calls"
    done
    norm() { cut -d' ' -f3- "$1" | /usr/bin/grep -v '^curl .*file://' | sed -E 's#/tmp/[^ ]*#<tmp>#g; s/[0-9]{5,}/N/g' | sort | uniq -c; }
    echo
    echo "== $s   R rc $(cat "$OUT/R/$s.rc") ($(tail -1 "$OUT/R/$s.out" | cut -c1-60))   L rc $(cat "$OUT/L/$s.rc") ($(tail -1 "$OUT/L/$s.out" | cut -c1-60))"
    echo "   calls under R:"; norm "$OUT/R/$s.calls" | sed 's/^/      /'
    echo "   calls under L:"; norm "$OUT/L/$s.calls" | sed 's/^/      /'
    echo "   in L and not in R (what a LIVE answer leads to):"
    comm -13 <(norm "$OUT/R/$s.calls" | sed 's/^ *[0-9]* //' | sort -u) <(norm "$OUT/L/$s.calls" | sed 's/^ *[0-9]* //' | sort -u) \
        | sed 's/^/      + /'
    echo "   checks that changed verdict R -> L:"
    diff <(/usr/bin/grep -E '^  (ok|FAILED) ' "$OUT/R/$s.out" | sed -E 's/[0-9]{5,}/N/g') \
         <(/usr/bin/grep -E '^  (ok|FAILED) ' "$OUT/L/$s.out" | sed -E 's/[0-9]{5,}/N/g') | /usr/bin/grep '^[<>]' | head -20 | sed 's/^/      /'
done
[[ "$(lab_hosts)" == 0 ]] && echo "no real mininet host appeared" || echo "!! a real fabric appeared during the run"
echo "PROBE-REPORT: done"
