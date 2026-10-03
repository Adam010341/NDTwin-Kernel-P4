#!/usr/bin/env bash
# nolab_sweep.sh <worktree> <out dir> [suite ...] -- run shell suites twice under the nolab shims
# and name every lab command each one reached for. [Co-developed with claude code -- Adam]
#   pass A: no fabric (the process table as it is)
#   pass B: a FAKE fabric -- ps also lists four Mininet host shells (pids above pid_max), the only
#           thing host_pid looks at -- so a suite whose code would go on to drive a live fabric's
#           hosts does so here, into shims that refuse and record it.
# Nothing reaches the lab: sudo, mnexec, iperf, iperf3, ping and the changing forms of tc / ip /
# ovs-* are refused, curl refuses :8000/:8081/:8080. A suite's own pass/fail under the shims is
# printed but is not the question; the recorded calls are.
set -u
WT="$1"; OUT="$2"; shift 2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WT" || exit 2
if (( $# )); then SUITES=("$@"); else mapfile -t SUITES < <(ls tests/shell/test_*.sh | xargs -n1 basename); fi
rm -rf "$OUT"; mkdir -p "$OUT/A" "$OUT/B"
bash "$HERE/make_shims.sh" "$OUT/shims" >/dev/null
lab_hosts() { /usr/bin/ps -eo args= 2>/dev/null | /usr/bin/grep -cE '(^| )mininet:[A-Za-z0-9_-]+$'; }
if [[ "$(lab_hosts)" != 0 ]]; then echo "REFUSE: a real fabric is up ($(lab_hosts) mininet hosts)"; exit 2; fi
echo "HEAD $(git rev-parse HEAD); ${#SUITES[@]} suite(s); shims $OUT/shims"
printf '%-46s %-9s %-9s %s\n' suite "A rc/s" "B rc/s" "calls A | calls B (refused ones marked !)"
for s in "${SUITES[@]}"; do
    for p in A B; do
        t0=$(date +%s)
        env -u SELFTEST_PROBE_SUDO -u NDT_MEASURING PATH="$OUT/shims:$PATH" NOLAB_LOG="$OUT/$p/$s.calls" \
            NOLAB_SUITE="$s" NOLAB_PASS="$p" NOLAB_FAKE_FABRIC=$([[ $p == B ]] && echo 1 || echo 0) \
            timeout 900 bash "tests/shell/$s" < /dev/null > "$OUT/$p/$s.out" 2>&1
        echo "$? $(( $(date +%s) - t0 ))" > "$OUT/$p/$s.rc"
    done
    summ() {   # the lab commands a pass reached for, counted by command word
        [[ -s "$1" ]] || { echo "-"; return; }
        awk '{c = $3; if (c == "ps" || c == "curl" && $0 !~ /localhost:80[08][01]|127\.0\.0\.1:80[08][01]/) next;
              if (c == "tc" || c == "ip" || c == "ovs-vsctl" || c == "ovs-ofctl") { if ($0 ~ / (show|list|get|find|dump-flows|dump-ports|-V|--version)( |$)/ && $0 !~ / (netns|exec) /) next }
              n[c]++} END {for (k in n) printf "%s!%d ", k, n[k]}' "$1"
    }
    printf '%-46s %-9s %-9s %s | %s\n' "$s" "$(tr ' ' / < "$OUT/A/$s.rc")" "$(tr ' ' / < "$OUT/B/$s.rc")" \
        "$(summ "$OUT/A/$s.calls")" "$(summ "$OUT/B/$s.calls")"
done
[[ "$(lab_hosts)" == 0 ]] && echo "no real mininet host appeared during the sweep" || echo "!! a real fabric appeared during the sweep"
echo "NOLAB-SWEEP: done"
