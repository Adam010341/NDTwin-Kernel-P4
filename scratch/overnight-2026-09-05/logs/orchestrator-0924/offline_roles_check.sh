#!/usr/bin/env bash
# Offline check for TICKET-P4-roles section 5-3 (worker R, 2026-09-24).
# [Co-developed with claude code -- Adam]
#
# For each tutorials exercise: copy ONLY the files a conversion reads (topology, runtime files,
# .p4 sources) out of ~/tutorials into a scratch tree -- ~/tutorials is read, never written --
# compile the SOLUTION into that copy's build/ under the skeleton's output name (the exercises'
# own Makefile recipe, as live-p1/02 does), convert with --role-ipv4-route naming basic's
# ipv4_lpm, and run pre-flight (--no-compile). The six same-shape exercises must PASS; the four
# that cannot bind ipv4_lpm must FAIL and say what is missing.
set -u
WT="${WT:?}"
OUT="${OUT:?}"
PY="$WT/p4_proxy/venv/bin/python"
P4C=/usr/local/bin/p4c-bm2-ss
ROLE="owner=ndtwin,table=MyIngress.ipv4_lpm,match_field=hdr.ipv4.dstAddr"
ROLE="$ROLE,action=MyIngress.ipv4_forward,dst_mac=dstAddr,port=port"
rm -rf "$OUT"; mkdir -p "$OUT/src" "$OUT/pkg"

# exercise | topology | --p4 | "stem:source ..." to compile | expect
CASES="basic_tunnel|topology.json|solution/basic_tunnel.p4|basic_tunnel:solution/basic_tunnel.p4|PASS
ecn|topology.json|solution/ecn.p4|ecn:solution/ecn.p4|PASS
qos|topology.json|solution/qos.p4|qos:solution/qos.p4|PASS
mri|topology.json|solution/mri.p4|mri:solution/mri.p4|PASS
link_monitor|pod-topo/topology.json|solution/link_monitor.p4|link_monitor:solution/link_monitor.p4|PASS
firewall|pod-topo/topology.json|basic.p4|basic:basic.p4 firewall:solution/firewall.p4|PASS
calc|topology.json|solution/calc.p4|calc:solution/calc.p4|FAIL
load_balance|topology.json|solution/load_balance.p4|load_balance:solution/load_balance.p4|FAIL
multicast|sig-topo/topology.json|solution/multicast.p4|multicast:solution/multicast.p4|FAIL
source_routing|topology.json|solution/source_routing.p4|source_routing:solution/source_routing.p4|FAIL"

bad=0
while IFS='|' read -r ex topo p4 builds expect; do
    src="$HOME/tutorials/exercises/$ex"; dst="$OUT/src/$ex"
    mkdir -p "$dst/build" "$dst/solution" "$dst/$(dirname "$topo")"
    cp "$src/$topo" "$dst/$topo"
    cp "$src"/*.p4 "$dst/" 2>/dev/null
    cp "$src"/solution/*.p4 "$dst/solution/"
    # every runtime file the topology names
    "$PY" - "$src" "$dst" "$topo" <<'PY'
import json, os, shutil, sys
src, dst, topo = sys.argv[1:4]
doc = json.load(open(os.path.join(src, topo)))
for spec in (doc.get("switches") or {}).values():
    rel = (spec or {}).get("runtime_json")
    if rel:
        os.makedirs(os.path.dirname(os.path.join(dst, rel)) or dst, exist_ok=True)
        shutil.copyfile(os.path.join(src, rel), os.path.join(dst, rel))
PY
    for b in $builds; do
        stem="${b%%:*}"; prog="${b#*:}"
        "$P4C" --p4v 16 --p4runtime-files "$dst/build/$stem.p4.p4info.txtpb" \
            -o "$dst/build/$stem.json" "$dst/$prog" > "$OUT/$ex.compile.$stem.txt" 2>&1 \
            || { echo "$ex: compile $prog FAILED (see $ex.compile.$stem.txt)"; bad=1; continue 2; }
    done
    "$PY" "$WT/tools/p4_exercise/convert.py" "$dst" --topology "$topo" --p4 "$p4" \
        --out "$OUT/pkg/$ex" --role-ipv4-route "$ROLE" > "$OUT/$ex.convert.txt" 2>&1
    crc=$?
    "$PY" "$WT/tools/p4_exercise/preflight.py" --no-compile "$OUT/pkg/$ex" > "$OUT/$ex.preflight.txt" 2>&1
    prc=$?
    got=$([[ $prc -eq 0 ]] && echo PASS || echo FAIL)
    verdict=$([[ "$got" == "$expect" ]] && echo "as expected" || { bad=1; echo "UNEXPECTED"; })
    printf '%-15s convert rc=%s  preflight %s (want %s) -- %s\n' "$ex" "$crc" "$got" "$expect" "$verdict"
    /usr/bin/grep -E '^  owned table' "$OUT/$ex.convert.txt" | sed 's/^/                   /'
    /usr/bin/grep -E 'roles\.ipv4_route resolves|owned table has no' "$OUT/$ex.preflight.txt" \
        | cut -c1-230 | sed 's/^/                 /'
    if [[ "$got" == FAIL ]]; then
        /usr/bin/grep -E '^  FAIL' "$OUT/$ex.preflight.txt" | /usr/bin/grep -v 'roles\.ipv4_route' \
            | cut -c1-200 | sed 's/^/                 other FAIL: /'
    fi
done <<<"$CASES"
echo "OFFLINE-5-3: $([[ $bad -eq 0 ]] && echo 'every exercise as expected' || echo 'SOMETHING UNEXPECTED')"
exit $bad
