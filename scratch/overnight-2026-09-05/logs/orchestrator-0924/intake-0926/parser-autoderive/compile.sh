#!/usr/bin/env bash
# Compile the corpus out of tree, one program at a time, niced.
set -uo pipefail
O=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/parser-autoderive
T=/home/adam/tutorials/exercises
R=/home/adam/Desktop/NDTwin-Kernel
declare -a PROGS=(
 "basic:$T/basic/solution/basic.p4"
 "basic_tunnel:$T/basic_tunnel/solution/basic_tunnel.p4"
 "calc:$T/calc/solution/calc.p4"
 "ecn:$T/ecn/solution/ecn.p4"
 "firewall_basic:$T/firewall/basic.p4"
 "firewall_fw:$T/firewall/solution/firewall.p4"
 "flowcache:$T/flowcache/solution/flowcache.p4"
 "link_monitor:$T/link_monitor/solution/link_monitor.p4"
 "load_balance:$T/load_balance/solution/load_balance.p4"
 "mri:$T/mri/solution/mri.p4"
 "multicast:$T/multicast/solution/multicast.p4"
 "p4runtime:$T/p4runtime/advanced_tunnel.p4"
 "qos:$T/qos/solution/qos.p4"
 "source_routing:$T/source_routing/solution/source_routing.p4"
 "ndtwin_switch:$R/p4_proxy/p4_src/ndtwin_switch.p4"
)
printf '%-16s %-4s %-8s %s  %s\n' TAG RC BYTES SHA256_SRC SRC
for p in "${PROGS[@]}"; do
  tag=${p%%:*}; src=${p#*:}
  nice -n 19 p4c-bm2-ss --p4v 16 -o "$O/json/$tag.json" "$src" > "$O/compile-logs/$tag.log" 2>&1
  rc=$?
  sz=$( [ -f "$O/json/$tag.json" ] && stat -c%s "$O/json/$tag.json" || echo - )
  printf '%-16s %-4s %-8s %s  %s\n' "$tag" "$rc" "$sz" "$(sha256sum "$src" | cut -c1-12)" "$src"
done
