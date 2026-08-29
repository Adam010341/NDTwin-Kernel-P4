#!/usr/bin/env bash
# ① driver: alternate the bmv2 build, one arm per fabric generation.
#
# Every arm needs its own fabric because the build is the treatment, so this script owns the
# swap-and-restart cycle. Three things are re-established after EVERY restart, because `ndt up`
# rebuilds the fabric and nothing about the previous generation carries over:
#
#   1. the build identity, by symbol, in both directions (run_build_arm.sh does this and exits
#      non-zero if the label and the binary disagree);
#   2. the one-hop property, by interface counters -- exactly two interfaces on ONE switch may
#      move. "It was one hop last time" is not evidence about this fabric.
#   3. the host namespaces, which get new pids.
#
# 🔴 `ndt down` and `ndt up` kill the shell that calls them (observed twice, exit 144, fabric and
# data intact both times). That is why every ndt invocation here is wrapped in setsid: without it
# this driver would die on its first swap, exactly as pass B of ticket 3 died on a /compact.
#
# Usage: NDT_OWNER="..." ./drive_p1.sh <build:arm> [<build:arm> ...]
#        e.g. ./drive_p1.sh fast:fast_a stock:stock_b fast:fast_b
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
OVR="$REPO/p4_proxy/mininet/bmv2_binary_override"
FAST=/usr/local/bmv2-fast/bin/simple_switch_grpc
STOCK=/usr/local/bin/simple_switch_grpc
SETTLE_S="${SETTLE_S:-20}"

select_build() {   # $1 = fast|stock ; rewrites the override, keeping its comments
    local want; case "$1" in fast) want="$FAST";; stock) want="$STOCK";; *) return 1;; esac
    python3 - "$OVR" "$want" <<'PY'
import sys
p, want = sys.argv[1], sys.argv[2]
keep = [l for l in open(p).read().split("\n") if l.strip().startswith("#") or not l.strip()]
open(p, "w").write("\n".join(keep + [want]) + "\n")
PY
}

verify_one_hop() {  # returns 0 only if exactly two interfaces moved and both are on one switch
    local h1 h2 before after
    h1=$(ps -eo pid,args | awk '$NF=="mininet:h1"{print $1; exit}')
    h2=$(ps -eo pid,args | awk '$NF=="mininet:h2"{print $1; exit}')
    [[ -n "$h1" && -n "$h2" ]] || { echo "  🔴 host namespaces missing"; return 1; }
    before=$(grep -E 's[0-9]+-eth' /proc/net/dev)
    sudo -n mnexec -a "$h2" iperf3 -s -1 --daemon -p 5599 >/dev/null 2>&1; sleep 1
    sudo -n mnexec -a "$h1" iperf3 -c 10.0.0.2 -p 5599 -u -b 5M -t 4 -l 1400 >/dev/null 2>&1
    after=$(grep -E 's[0-9]+-eth' /proc/net/dev)
    python3 - "$before" "$after" <<'PY'
import re, sys
def parse(t):
    d = {}
    for l in t.strip().split("\n"):
        m = re.match(r"\s*(\S+):\s*(.*)", l)
        if m:
            f = m.group(2).split(); d[m.group(1)] = (int(f[1]), int(f[9]))
    return d
b, a = parse(sys.argv[1]), parse(sys.argv[2])
moved = [k for k in b if (a[k][0]-b[k][0]) > 500 or (a[k][1]-b[k][1]) > 500]
sw = {k.split("-")[0] for k in moved}
for k in moved:
    print(f"  {k:10s} RX +{a[k][0]-b[k][0]:<7d} TX +{a[k][1]-b[k][1]}")
ok = len(moved) == 2 and len(sw) == 1
print(f"  => {len(moved)} interfaces on {len(sw)} switch(es): {'✅ ONE HOP' if ok else '🔴 NOT ONE HOP'}")
raise SystemExit(0 if ok else 1)
PY
}

for spec in "$@"; do
    build="${spec%%:*}"; arm="${spec##*:}"
    echo; echo "############ $arm  (build=$build)  $(date '+%F %H:%M:%S') ############"

    echo "--- selecting $build and restarting the fabric ---"
    select_build "$build" || { echo "🔴 unknown build '$build'"; continue; }
    setsid env NDT_OWNER="$NDT_OWNER" ndt down > "$HERE/raw/ndt_${arm}_down.log" 2>&1
    setsid env NDT_OWNER="$NDT_OWNER" ndt up   > "$HERE/raw/ndt_${arm}_up.log"   2>&1
    if ! grep -q '^up\. ready' "$HERE/raw/ndt_${arm}_up.log"; then
        echo "🔴 ndt up did not report ready for $arm -- stopping. See raw/ndt_${arm}_up.log"
        tail -5 "$HERE/raw/ndt_${arm}_up.log"; exit 1
    fi
    echo "  fabric up"

    echo "--- re-verifying ONE HOP on the rebuilt fabric ---"
    if ! verify_one_hop; then
        echo "🔴 one-hop property does not hold on this fabric generation -- refusing to run $arm"; exit 1
    fi

    sleep "$SETTLE_S"
    NDT_OWNER="$NDT_OWNER" "$HERE/run_build_arm.sh" "$build" "$arm" || echo "🔴 arm $arm returned non-zero"
done

echo; echo "############ ① arms complete $(date '+%F %H:%M:%S') ############"
printf '%-10s %-7s %-14s %-11s %-11s %s\n' arm build clean_mbit external EventLogger sha
for d in "$HERE"/raw/*/; do
    m="$d/arm.meta"; [[ -f "$m" ]] || continue
    grep -q '^finished=' "$m" || continue
    printf '%-10s %-7s %-14s %-11s %-11s %s\n' "$(basename "$d")" \
      "$(sed -n 's/^build=//p' "$m")" "$(sed -n 's/^highest_clean_mbit=//p' "$m")" \
      "$(sed -n 's/^external=//p' "$m")" \
      "$(sed -n 's/^build_signature_EventLogger=//p' "$m" | awk '{print $1}')" \
      "$(sed -n 's/^switch_binary_sha256=//p' "$m")"
done
