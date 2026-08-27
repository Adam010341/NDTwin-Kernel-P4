#!/usr/bin/env bash
# Restart ONLY the kernel, against a fabric that is already up and converged.
#
# Amendment D arm U needs the same fabric with a different binary. bmv2, the proxy and the
# Mininet session must survive; only the process that reads them gets replaced.
#
# Every step asserts. The failure this guards against is the one that has cost this project
# the most time: a change that is applied to a file, reported as applied, and never reaches
# the process under measurement. `ndt up` not recompiling the .p4 while bmv2 held the old
# JSON was three layers of that in one afternoon, all three reporting success. So the
# acceptance test here is not "the command ran" -- it is the sha256 of /proc/<newpid>/exe,
# which names the bytes actually executing rather than a path that could have been replaced.
#
# Usage: restart_kernel.sh <expected-sha256-prefix>
# [Co-developed with claude code -- Adam]
set -uo pipefail
WANT="${1:?expected sha256 (prefix ok) of the binary that must end up running}"
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
PIDF="$REPO/.test_run/pids/kernel.pid"
LOG="$REPO/.test_run/logs/kernel.log"

old="$(cat "$PIDF" 2>/dev/null || true)"
echo "=== old kernel: pid ${old:-none} ==="
if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    echo "  running sha256: $(sha256sum "/proc/$old/exe" 2>/dev/null | awk '{print $1}')"
    # By exact pid. Never a pattern: `pkill -f ndtwin_kernel` has matched this session's own
    # command line before, and a pattern cannot tell this fabric's kernel from a stray one.
    kill "$old"
    for _ in $(seq 1 20); do kill -0 "$old" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$old" 2>/dev/null; then
        echo "  SIGTERM ignored, escalating"; kill -9 "$old"; sleep 1
    fi
    kill -0 "$old" 2>/dev/null && { echo "🔴 pid $old still alive -- refusing"; exit 1; }
    echo "  dead"
else
    echo "  not running"
fi

# Assert nothing else is holding :8000, or the new kernel will fail to bind and the old
# answer will keep being served -- which reads exactly like a successful restart.
if ss -ltn 2>/dev/null | grep -q ':8000 '; then
    echo "🔴 :8000 still bound after the kernel died -- something else is serving it"; exit 1
fi

echo "=== starting from $REPO/build/bin/ndtwin_kernel ==="
echo "  on-disk sha256: $(sha256sum "$REPO/build/bin/ndtwin_kernel" | awk '{print $1}')"
# `( cd X && nohup Y & echo $! )` records the wrong pid. The `&` backgrounds the whole
# `cd && nohup` list, so bash forks a subshell to run it and $! is that subshell -- which
# keeps the parent's argv and whose /proc/<pid>/exe is /usr/bin/bash. The kernel is its
# child, one pid higher. That is exactly what happened on the first live run of this script:
# it recorded 3487292, a bash wrapper, while the kernel ran as 3487293. Backgrounding a
# single simple command from the top level instead lets bash exec into it, so $! is the
# process itself. Every liveness and identity check downstream reads that pid, so getting it
# wrong here would have poisoned all of them at once.
cd "$REPO/build" || { echo "🔴 cannot cd to $REPO/build"; exit 1; }
nohup ./bin/ndtwin_kernel --mode mininet --topology "$TOPO" --no-ai >>"$LOG" 2>&1 &
new=$!
cd - >/dev/null || true
echo "$new" > "$PIDF"
echo "  new pid: $new"
sleep 2
kill -0 "$new" 2>/dev/null || { echo "🔴 new kernel died immediately -- see $LOG"; tail -20 "$LOG"; exit 1; }
# The launcher above is the reason this next assertion has to be about bytes rather than
# liveness: `kill -0` on the bash wrapper succeeded too.
case "$(readlink -f "/proc/$new/exe" 2>/dev/null)" in
    */ndtwin_kernel) : ;;
    *) echo "🔴 pid $new is $(readlink -f /proc/$new/exe), not the kernel -- launcher recorded a wrapper"; exit 1 ;;
esac

# THE assertion. A path is not the bytes; this is.
got="$(sha256sum "/proc/$new/exe" 2>/dev/null | awk '{print $1}')"
echo "  running sha256: $got"
case "$got" in
    "$WANT"*) echo "  ok  binary under measurement matches the one requested" ;;
    *) echo "🔴 WRONG BINARY: wanted $WANT*, running $got -- this is not the arm you think"; exit 1 ;;
esac

echo "=== waiting for :8000 ==="
for _ in $(seq 1 60); do ss -ltn 2>/dev/null | grep -q ':8000 ' && break; sleep 1; done
ss -ltn 2>/dev/null | grep -q ':8000 ' || { echo "🔴 :8000 never opened"; tail -20 "$LOG"; exit 1; }

# The kernel pulls topology exactly ONCE at startup and never retries, so a pull that lands in
# a dip leaves a permanently crippled model with nothing in the log. destination-paths counts
# have been observed falling back from 16256 to 13184. Poll until it agrees with the fabric
# rather than sampling once and hoping.
echo "=== waiting for the model to agree with the fabric ==="
for i in $(seq 1 40); do
    out="$(python3 - <<'PY'
import json, subprocess
try:
    g = json.loads(subprocess.run(["curl","-sS","--max-time","8",
        "http://127.0.0.1:8000/ndt/get_graph_data"], capture_output=True, text=True).stdout)
except Exception:
    print("0 0 0"); raise SystemExit
down = sum(1 for e in g["edges"] if not e.get("is_up", True))
hosts = [n for n in g.get("nodes", []) if n.get("vertex_type") == 1]
print(len(g["edges"]), down, sum(1 for h in hosts if h.get("ip") and h["ip"][0]))
PY
)"
    set -- $out
    echo "  t+$((i*5))s: edges=${1:-?} down=${2:-?} ipv4=${3:-?}"
    # [Co-developed with claude code -- Adam]
    # down==0 && ipv4==128 does NOT see a short path set. The kernel pulls destination paths
    # exactly once and never retries, and the count has been observed falling back from 16256 to
    # 13184 mid-convergence -- a pull that lands in that dip leaves a permanently crippled model
    # with nothing in the log, while every check above still reads green. 16256 = 128 * 127.
    paths="$(curl -s --max-time 5 http://localhost:8081/ryu_server/all_destination_paths \
             | python3 -c 'import sys,json; d=json.load(sys.stdin); v=d.get("all_destination_paths",d); print(len(v))' 2>/dev/null || echo 0)"
    echo "       paths=$paths (want 16256)"
    [[ "${2:-1}" == "0" && "${3:-0}" == "128" && "$paths" == "16256" ]] && { echo "  ok  converged"; exit 0; }
    sleep 5
done
echo "🔴 model never converged (down!=0, ipv4!=128, or paths!=16256) -- NOT a measurement"
exit 1
