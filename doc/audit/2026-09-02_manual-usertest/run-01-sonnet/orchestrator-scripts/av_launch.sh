#!/bin/bash
# auditor 4(a)(b)(c) preflight + detached launch inside the run-01 VM. Run as ndt: bash /tmp/av_launch.sh
# [Co-developed with claude code -- Adam]
set -u
OUT=$HOME/auditor-verification; mkdir -p "$OUT"; K=$HOME/Desktop/NDTwin-Kernel
{ echo "preflight $(date -u +%FT%TZ)"; uptime
  for f in $HOME/.local/bin/ndt /usr/local/sbin/ndtwin-lab $HOME/miniconda3/envs/ryu-env/bin/ryu-manager $K/build/bin/ndtwin_kernel $K/intelligent_router.py $K/testbed_topo.py $K/setting/StaticNetworkTopologyMininet_10Switches.json $K/tools/test_workflow/stack.sh $K/p4_proxy/mininet/ntg_bmv2_topo.py /usr/local/bin/simple_switch_grpc; do [ -e "$f" ] && echo "OK  $f" || echo "MISSING $f"; done
  echo "--- where are intelligent_router.py / testbed_topo.py"; find "$K" -maxdepth 3 \( -name intelligent_router.py -o -name testbed_topo.py \) 2>/dev/null
  echo "--- sudo -n -l"; sudo -n -l 2>&1 | tail -2
  echo "--- manual's kernel / ryu / topology commands"; grep -rhn "ndtwin_kernel \|ryu-manager \|testbed_topo.py" "$HOME/ndtwin-docs/NDTwin User Manual" 2>/dev/null | grep -v "^\s*#" | cut -c1-200 | head -8
  echo "--- stray processes"; for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null); case "$c" in *ndtwin_kernel*|*ryu-manager*|*testbed_topo*|*simulation_platform*|*energy_saving*|*network_state_recorder*) echo "${p#/proc/} $c" | cut -c1-120;; esac; done
  echo "--- listening"; ss -tlnH | awk '{print $4}' | grep -E ':(8000|8080|6633|6653)$'
  echo "--- root tmux"; sudo -n tmux -L ndtwinlab ls 2>&1 | head -3
  echo "--- .test_run ownership"; ls -ld "$K/.test_run/pids" "$K/.test_run/logs" 2>&1
  echo "--- mininet hosts"; ps -eo args= | awk '{print $NF}' | grep -c '^mininet:h[0-9]*$'
} > "$OUT/preflight.txt" 2>&1
cat "$OUT/preflight.txt"
if grep -q "^MISSING" "$OUT/preflight.txt"; then echo "PREFLIGHT FAILED - not launching"; exit 1; fi
setsid nohup bash -c 'bash /tmp/av_a_ndt_up.sh; bash /tmp/av_b_sigint.sh; bash /tmp/av_c_apps.sh; date -u +%FT%TZ > ~/auditor-verification/ALL_DONE' > "$OUT/run.log" 2>&1 < /dev/null &
echo "launched chain pid $! at $(date -u +%T)"
