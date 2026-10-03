#!/bin/bash
# r3: the cost of the new probe (`ndt status --measuring`) on an idle lab, measured as RESULTS.md
# measured the old one: /proc/stat processes delta minus an equal idle window, 7 reps (measure.py);
# sudo and curl through logging PATH shims that exec the real binaries; no ptrace.
# Touches no lab: no claim, no fabric; plain `ndt status` is run only as the old probe's control.
# [Co-developed with claude code -- Adam]
# usage: run.sh <worktree> <outdir>
set -uo pipefail
WT="$1"; OUT="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
export NDT_OWNER=ndt-serve-gui-r3
NEW="$WT/tools/test_workflow/ndt"; OLD="$HOME/.local/bin/ndt"
state() {
    echo "## state $(date -Is): $1"
    "$OLD" status 2>&1 | grep -E '^  (claim|declared|measuring|orphaned) ' | sed 's/^/   /'
    echo "   simple_switch_grpc processes: $(ps -eo comm= | grep -cx simple_switch_g)"
    echo "   mininet-tagged processes: $(ps -eo args= | awk '{print $NF}' | grep -c '^mininet:')"
    (exec 3<>/dev/tcp/127.0.0.1/8000) 2>/dev/null && echo "   kernel :8000 open" || echo "   kernel :8000 closed"
}
{
echo "# $(date -Is) r3 probe cost, idle lab. worktree head $(git -C "$WT" rev-parse HEAD), porcelain $(git -C "$WT" status --porcelain --untracked-files=no | grep -c .)"
echo "# new probe ndt: $NEW sha256 $(sha256sum < "$NEW" | cut -c1-64)  (git blob at HEAD: $(git -C "$WT" rev-parse HEAD:tools/test_workflow/ndt))"
echo "# old probe ndt: $OLD -> $(readlink -f "$OLD") sha256 $(sha256sum < "$OLD" | cut -c1-64); main checkout HEAD $(git -C "$(dirname "$(readlink -f "$OLD")")" rev-parse HEAD 2>/dev/null)"
state before
} > "$OUT/00-header.log" 2>&1

# A. the new probe, idle
python3 "$HERE/measure.py" r3-idle-measuring 7 "$NEW status --measuring" > "$OUT/10-new-idle-forks.log" 2>&1
# B. its sudo and curl calls (3 runs)
: > "$OUT/11-new-idle-sudo.log"; : > "$OUT/11-new-idle-curl.log"
for i in 1 2 3; do
    PATH="$HERE/shim:$PATH" SUDO_SHIM_LOG="$OUT/11-new-idle-sudo.log" CURL_SHIM_LOG="$OUT/11-new-idle-curl.log" \
        "$NEW" status --measuring > "$OUT/11-new-idle-out-$i.txt" 2>&1; echo "run $i rc=$?" >> "$OUT/11-new-idle-rc.log"
done
# C. a declared measurement: the same ndt in a copy whose own claim file declares one (nobody else reads it)
SB="$(mktemp -d "${TMPDIR:-/tmp}/r3-probe-sb-XXXXXX")"
mkdir -p "$SB/tools/test_workflow" "$SB/.test_run"
cp "$NEW" "$WT/tools/test_workflow/ports.sh" "$WT/tools/test_workflow/sudo_surface.sh" "$WT/tools/test_workflow/components.env" "$SB/tools/test_workflow/"
printf 'owner=r3-cost-fixture\nexpires=%s\nnote=r3 cost fixture, not a claim on the lab\nexclusive_cpu=no\nmeasuring=r3 cost fixture\n' \
    "$(( $(date +%s) + 3600 ))" > "$SB/.test_run/lab.claim"
python3 "$HERE/measure.py" r3-declared-measuring 7 "$SB/tools/test_workflow/ndt status --measuring" > "$OUT/20-new-declared-forks.log" 2>&1
: > "$OUT/21-new-declared-sudo.log"; : > "$OUT/21-new-declared-curl.log"
PATH="$HERE/shim:$PATH" SUDO_SHIM_LOG="$OUT/21-new-declared-sudo.log" CURL_SHIM_LOG="$OUT/21-new-declared-curl.log" \
    "$SB/tools/test_workflow/ndt" status --measuring > "$OUT/21-new-declared-out.txt" 2>&1
rm -rf "$SB"
# D. the old probe (plain status of the main checkout), idle, the same way -- reconciles with RESULTS.md's 448 / 8
python3 "$HERE/measure.py" r3-idle-old-probe 7 "$OLD status" > "$OUT/30-old-idle-forks.log" 2>&1
: > "$OUT/31-old-idle-sudo.log"; : > "$OUT/31-old-idle-curl.log"
for i in 1 2 3; do
    PATH="$HERE/shim:$PATH" SUDO_SHIM_LOG="$OUT/31-old-idle-sudo.log" CURL_SHIM_LOG="$OUT/31-old-idle-curl.log" \
        "$OLD" status > /dev/null 2>&1
done
state after >> "$OUT/00-header.log" 2>&1
echo "# $(date -Is) done" >> "$OUT/00-header.log"
