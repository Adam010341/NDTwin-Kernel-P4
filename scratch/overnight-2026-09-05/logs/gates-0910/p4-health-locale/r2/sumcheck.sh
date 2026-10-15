#!/usr/bin/env bash
# sumcheck.sh : the shard-sum script of this checkout over the four real fd208fbd shard logs, and over copies of them
# with shard 2's line 5 (the interpreter line) changed to another path and to another version. Not the gate.
# [Co-developed with claude code -- Adam]
R=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c
SUM=tests/shell/sum_p4_health_gate_shards.sh
T="$(mktemp -d "${TMPDIR:-/tmp}/sumcheck-XXXXXX")"; trap 'rm -rf "$T"' EXIT
one() {  # one <title> <args...>
    local t="$1"; shift
    echo; echo "### $t"; echo "\$ $SUM $*" | sed "s|$T|<copies>|g; s|$R|<real>|g"
    bash "$SUM" "$@"; echo "(sum rc=$?)"
}
echo "line 5 of each real log:"; for k in 0 1 2 3; do printf '  shard%s: ' $k; sed -n 5p "$R/mutate_p4_health.shard${k}of4.log"; done
one "the four real logs, no --commit (the checkout's HEAD is not fd208fbd)" "$R"/mutate_p4_health.shard{0,1,2,3}of4.log
one "the four real logs, --commit fd208fbd" --commit fd208fbd "$R"/mutate_p4_health.shard{0,1,2,3}of4.log
for what in path version; do
    mkdir -p "$T/$what"; cp "$R"/mutate_p4_health.shard{0,1,2,3}of4.log "$T/$what/"
    case "$what" in
        path) sed -i '5s|^interpreter: /home/adam/miniconda3/envs/ryu-env/bin/python3.8 |interpreter: /usr/bin/python3.8 |' "$T/$what/mutate_p4_health.shard2of4.log";;
        version) sed -i '5s|(3\.8\.20)$|(3.8.19)|' "$T/$what/mutate_p4_health.shard2of4.log";;
    esac
    echo; echo "copy, $what: shard2 line 5 is now: $(sed -n 5p "$T/$what/mutate_p4_health.shard2of4.log")"
    cmp -s "$R/mutate_p4_health.shard2of4.log" "$T/$what/mutate_p4_health.shard2of4.log" && { echo "THE COPY DID NOT CHANGE"; exit 1; }
    one "copies, shard 2's interpreter $what changed, --commit fd208fbd" --commit fd208fbd "$T/$what"/mutate_p4_health.shard{0,1,2,3}of4.log
done
