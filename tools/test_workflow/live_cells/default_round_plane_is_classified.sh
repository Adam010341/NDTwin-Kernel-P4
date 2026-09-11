#!/usr/bin/env bash
#
# CELL default_round_plane_is_classified -- F10. The plane of the DEFAULT round could not be
# named, and "I could not tell" printed byte-identically to a physical-mode run.
#
# [Co-developed with claude code -- Adam]
#
# Source: F-OFFLINE-1 §1.15, run for real 2026-09-11 (with its own positive control). `ndt up`
# with no argument is `up_ovs 128`; setting/ has no OVS 128-host model (OVS has 4/8/16/32/64);
# topo_for_hosts' OVS glob includes StaticNetworkTopologyMininet_*.json -- so the model the
# default round loads is setting/StaticNetworkTopologyMininet_10Switches.json, 128 hosts, which
# last_kernel_plane matched NEITHER of its two patterns. After `ndt up; ndt down` it returned
# rc 1 and `--check` said `names no model this script can classify`, while the same report's
# `rate source` row said OVS.  Fix: ca9af4f1, merged in 954ab467.
#
# 🔴 FOUR readings, not one, because "classify everything as ovs" is the obvious wrong fix:
#   Mininet_* -> ovs   the finding
#   OVS_*     -> ovs   the positive control F-OFFLINE-1 ran alongside it
#   P4_*      -> p4    the direction a blanket answer would swallow
#   no model  -> rc 1  a physical-mode kernel STILL cannot be classified, and must not be
#                      given a plane it does not have
#
# Offline: `ndt` is sourced through its own NDT_LIB_ONLY seam and the only input is a stubbed
# kernel_exit_field. Nothing is read from the machine, so this cell needs no lab and can run
# while somebody else holds it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

# One reading: <label> <the --topology argument kernel.exit records>
_plane() {   # <ndt> <topology-path-or-empty>
    local ndt="$1" model="$2" cmd
    if [[ -n "$model" ]]; then
        cmd="bash -c cd '/tmp/build' && exec ./bin/ndtwin_kernel --mode mininet --topology '$model' --no-ai"
    else
        cmd="bash -c cd '/tmp/build' && exec ./bin/ndtwin_kernel --mode physical --no-ai"
    fi
    NDT_LIB_ONLY=1 MODEL_CMD="$cmd" bash -c '
        source "$0" >/dev/null 2>&1
        kernel_exit_field() { [[ "$1" == command ]] && printf "%s\n" "$MODEL_CMD"; }
        out="$(last_kernel_plane)"; rc=$?
        printf "out=%s rc=%s\n" "${out:-<empty>}" "$rc"
    ' "$ndt" 2>&1
}

cell_observe() {
    local d="$1" ndt="$NDT_ROOT/tools/test_workflow/ndt"
    cell_write_ids "$d"
    { printf 'mininet128: %s\n' \
        "$(_plane "$ndt" 'setting/StaticNetworkTopologyMininet_10Switches.json')"
      printf 'ovs4:       %s\n' \
        "$(_plane "$ndt" 'setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json')"
      printf 'p44:        %s\n' \
        "$(_plane "$ndt" 'setting/StaticNetworkTopologyP4_10Switches_4Hosts.json')"
      printf 'physical:   %s\n' "$(_plane "$ndt" '')"
    } > "$d/planes.txt"
}

cell_judge() {
    local d="$1"
    a_have f10_readings_present                          "$d/planes.txt"
    # 🔴 THE KEY ASSERTION: the default round's own model is in the OVS family.
    a_has  f10_mininet_model_reads_as_ovs   'mininet128: out=ovs rc=0'   "$d/planes.txt"
    # The positive control F-OFFLINE-1 ran beside it -- without this, "always ovs" passes.
    a_has  f10_ovs_model_still_reads_as_ovs 'ovs4:       out=ovs rc=0'   "$d/planes.txt"
    # ... and the direction a blanket answer would swallow.
    a_has  f10_p4_is_not_swallowed          'p44:        out=p4 rc=0'    "$d/planes.txt"
    # 🔴 "I could not tell" must survive where it is the true answer: a physical-mode kernel has
    # no model to name, and inventing a plane for it would be F10 with the sign flipped.
    a_has  f10_physical_is_still_unknown    'physical:   out=<empty> rc=1' "$d/planes.txt"
}

cell_main default_round_plane_is_classified ndt none "$@"
