#!/usr/bin/env bash
# Sequential, one kernel at a time: they all want :8000, and a concurrent run makes every
# refusal look identical to a topology refusal. [Co-developed with claude code -- Adam]
set -u
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
BIN="$1"; DEST="$2"
for m in m0_baseline m1_host_edge_ghost_dpid m4a_port_zero m4b_port_six_digits; do
    # refuse to start the next one until :8000 is free, so no run can inherit another's failure
    for i in $(seq 1 40); do
        [[ "$(ss -ltnH 'sport = :8000' | wc -l)" == 0 ]] && break
        sleep 0.5
    done
    if [[ "$(ss -ltnH 'sport = :8000' | wc -l)" != 0 ]]; then
        echo "REFUSING $m: :8000 still held; this run would not measure the topology" \
            > "$DEST/$m.log"
        continue
    fi
    "$SP/repro/run_kernel_on_topology.sh" "$BIN" "$SP/repro/topo/$m.json" "$DEST/$m.log"
    echo "done $m"
done
