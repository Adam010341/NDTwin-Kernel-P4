#!/usr/bin/env bash
# loaded_fp_study.sh [window_s] -- the false-positive study, this time with the fabric loaded.
#
# [Co-developed with claude code -- Adam]
#
# ## Why a second study
#
# doc/audit/2026-08-21_lldp-guard-false-positives/ measured zero false link deletions across
# three 20-minute cells -- but on an IDLE fabric. The whole worry about NDTWIN_RYU_LLDP_GUARD
# =0.01 is that it multiplies LLDP rate on the control channel ~5x, and an idle channel is
# exactly where that pressure cannot show. Adam's ruling: squeeze a loaded round in before 8/27,
# and the loaded false-positive count is the number that decides whether the guard becomes a
# default.
#
# Same three cells as the idle study, so the two are directly comparable:
#   A  Ryu defaults
#   B  NDTWIN_RYU_LLDP_GUARD=0.01
#   C  guard=0.01 + NDTWIN_RYU_LLDP_BACKOFF=10
#
# ## The load, and why it is asserted rather than assumed
#
# NTG drives it: `flow --config loaded_flow.json` typed into the topo session, which for
# `ndt up ovs` IS the NTG prompt (ovs-topo-start runs NTG's testbed_topo.py, which ends in
# command_line(net, "NTG.yaml") rather than Mininet's CLI). One actor at a time, so nothing else
# may touch the topo session while this runs.
#
# A cell whose traffic silently failed to start would report zero false positives and look like
# the best result in the study. So the load is verified from OUTSIDE NTG, by reading the switch
# interfaces' byte counters in /proc/net/dev before and after: if the fabric did not actually
# move bytes, the cell is marked INVALID and its zero is not a data point. NTG's own "flow
# started" chatter is not accepted as evidence of load -- that is the same mistake as trusting
# a config file to tell you which binary ran.
#
# Positive control per cell, identical to the idle study: a real netem failure must still be
# detected, or the zero above means nothing (smoke the accept path, not just refusals).
#
# Commands live in this file rather than on a prompt: pgrep/pkill patterns typed at a prompt
# match the shell running them, four times over on 2026-08-20..22.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-22_loaded-fp-study"
LOG="$REPO/.test_run/logs/ryu.log"
OUT="$DIR/loaded_fp_study.txt"
FLOW_CFG="$DIR/loaded_flow.json"
LAB=/usr/local/sbin/ndtwin-lab
W="${1:-1200}"
CELLS="${CELLS:-A B C}"

mkdir -p "$DIR/raw"
: > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

# ---- NTG mode: cli -> custom_command ---------------------------------------------------
# The topo session is whatever setting/Mininet.yaml says. It ships `mode: "cli"`, which gives
# Mininet's CLI -- and Mininet's CLI answers `flow --config ...` with "*** Unknown command",
# which is exactly what the first smoke run of this script hit. Only `custom_command` gives the
# NTG prompt that understands `flow`.
#
# This edits a file in a sibling repo (Network-Traffic-Generator), which is otherwise
# test-only-never-modify territory. It is a documented selector rather than code, it is restored
# on every exit path including failure, and nothing in ndt/stack.sh/ndtwin-lab keys on the
# `mininet>` prompt (checked). [Co-developed with claude code -- Adam]
NTG_YAML=/home/adam/Network-Traffic-Generator/setting/Mininet.yaml
NTG_YAML_BAK="$(mktemp -t Mininet.yaml.XXXXXX)"
cp "$NTG_YAML" "$NTG_YAML_BAK"
restore_ntg_mode() {
    cp "$NTG_YAML_BAK" "$NTG_YAML"
    printf 'NTG mode restored to: %s\n' "$(grep -oP 'mode:\s*"\K[a-z_]+' "$NTG_YAML")"
}
trap 'restore_ntg_mode; sudo -n "$LAB" topo-cmd "exit" >/dev/null 2>&1 || true; sleep 5; ndt down >/dev/null 2>&1 || ndt down --force >/dev/null 2>&1' EXIT
sed -i 's/mode: *"cli"/mode: "custom_command"/' "$NTG_YAML"
if ! grep -q 'mode: *"custom_command"' "$NTG_YAML"; then
    say "ABORT: could not switch NTG to custom_command mode; it still reads:"
    grep -n 'mode:' "$NTG_YAML" | sed 's/^/  /' | tee -a "$OUT"
    exit 2
fi

links_now() {
    curl -sf --max-time 5 http://localhost:8080/v1.0/topology/links \
      | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "?"
}

# Total bytes across every switch-side veth. The load assertion reads this, not NTG's output.
#
# Split on the colon first, THEN on whitespace. /proc/net/dev right-aligns the interface name in
# a fixed-width column, so a short name like "lo" is preceded by spaces and a long one like
# "s10-eth3" starts at column 0 -- which shifts every positional field by one depending on the
# name. The first version used -F'[: ]+' with $3/$11 and was summing packet counts for exactly
# the interfaces this study cares about, reporting ~0 MiB while iperf3 logs showed 11 MB per
# flow. It was "verified" against `lo`, the one interface whose padding differs from the ones
# needed -- a known-good check that could not fail. [Co-developed with claude code -- Adam]
fabric_bytes() {
    awk '/s[0-9]+-eth/ {split($0,a,":"); split(a[2],f," "); rx+=f[1]; tx+=f[9]}
         END {printf "%d\n", rx+tx}' /proc/net/dev
}

# Verbatim from the idle study's fp_study.sh, including both recorded traps (hex vs decimal
# port_no; SRCPORT passed to python3 rather than curl).
resolve_iface() {
    local dst="$1" port
    port=$(sudo -n mnexec -a 1 ovs-ofctl dump-flows s1 2>/dev/null \
           | grep -oP "nw_dst=${dst//./\\.} actions=output:\K[0-9]+" | head -1)
    [[ -z "$port" ]] && return 1
    curl -sf --max-time 5 http://localhost:8080/v1.0/topology/links \
      | SRCPORT="$port" python3 -c "
import json,os,sys
want=int(os.environ['SRCPORT'])
ls=json.load(sys.stdin)
ok=[l for l in ls if int(l['src']['dpid'],16)==1 and int(l['src']['port_no'],16)==want]
sys.exit(0 if ok else 3)" || return 2
    echo "s1-eth${port}"
}

# NTG's flow config runs a fixed 22-minute interval, which outlives the measurement window. Its
# iperf3 processes then keep the fabric "in use", and `ndt down` REFUSES -- correctly, because
# tearing a fabric out from under a live measurement loses the run and nothing else on this
# machine would say so. So a cell must end its own load before it tears down. Discovered by the
# smoke run, whose next cell could not boot. [Co-developed with claude code -- Adam]
stop_load() {
    sudo -n "$LAB" topo-cmd "exit" >/dev/null 2>&1 || true
    sleep 8
    if ! ndt down > /dev/null 2>&1; then
        # The cell is over and this session owns the claim, so forcing here is ending our own
        # measurement, not someone else's. Anything still running is NTG's tail.
        ndt down --force > /dev/null 2>&1 || true
    fi
    sleep 3
}

run_cell() {
    local name="$1"; shift
    say "## cell $name"
    say "   env: ${*:-<defaults>}"

    stop_load
    if ! env "$@" timeout 900 ndt up ovs > "$DIR/raw/up_$name.out" 2>&1; then
        say "   UP FAILED (raw/up_$name.out)"
        tail -5 "$DIR/raw/up_$name.out" | sed 's/^/     /' | tee -a "$OUT"
        return 1
    fi

    say "   knob lines in ryu log:"
    if grep -q "^NDTWIN:" "$LOG" 2>/dev/null; then
        grep "^NDTWIN:" "$LOG" | sed 's/^/     /' | tee -a "$OUT"
    else
        say "     (none -- Ryu defaults)"
    fi
    say "   ryu links at start: $(links_now)"

    # ---- start the load -----------------------------------------------------------------
    say "   starting NTG: flow --config $(basename "$FLOW_CFG")"
    sudo -n "$LAB" topo-cmd "flow --config $FLOW_CFG" >/dev/null 2>&1
    sleep 45          # let flows ramp before the window opens

    local b0 b1 moved
    b0=$(fabric_bytes)
    sleep 15
    b1=$(fabric_bytes)
    moved=$(( b1 - b0 ))
    say "   load check: fabric moved $(( moved / 1048576 )) MiB in 15s (from /proc/net/dev)"
    if (( moved < 10485760 )); then      # < 10 MiB in 15 s is not a loaded fabric
        say "   !! CELL INVALID: NTG did not put the fabric under load."
        say "      A zero false-positive count here would measure an idle fabric while claiming"
        say "      otherwise, which is the whole failure mode this study exists to avoid."
        say "      NTG's last words:"
        sudo -n "$LAB" topo-out 25 2>/dev/null | tail -12 | sed 's/^/        /' | tee -a "$OUT"
        return 1
    fi

    # ---- the window ---------------------------------------------------------------------
    local base_del base_chg
    base_del=$(grep -c "Link deleted:" "$LOG")
    base_chg=$(grep -c "topology changed" "$LOG")
    say "   loaded window: ${W}s, zero injections ($(date -Is))"
    sleep "$W"

    local n_del n_chg b2
    n_del=$(grep -c "Link deleted:" "$LOG")
    n_chg=$(grep -c "topology changed" "$LOG")
    b2=$(fabric_bytes)
    say "   LOADED FALSE link deletions during window: $((n_del - base_del))"
    say "   'topology changed' during window:          $((n_chg - base_chg))"
    say "   bytes moved across the whole window:       $(( (b2 - b1) / 1048576 )) MiB"
    say "   ryu links at window end: $(links_now)"
    if (( n_del - base_del > 0 )); then
        grep "Link deleted:" "$LOG" | tail -n $((n_del - base_del)) \
          | sed 's/^/     FP: /' | tee -a "$OUT"
    fi

    # ---- positive control ---------------------------------------------------------------
    local dst=10.0.0.33 iface rc
    iface=$(resolve_iface "$dst"); rc=$?
    if (( rc != 0 )); then
        say "   POSITIVE CONTROL SKIPPED: no inter-switch on-path iface resolved (rc=$rc)"
        say ""
        return 0
    fi
    local cls add del
    if sudo -n tc qdisc show dev "$iface" 2>/dev/null | head -1 | grep -q htb; then
        cls=$(sudo -n mnexec -a 1 tc class show dev "$iface" 2>/dev/null \
              | grep -oP 'class htb \K[0-9]+:[0-9]+' | head -1)
        add=(sudo -n tc qdisc add dev "$iface" parent "$cls" netem loss 100%)
        del=(sudo -n tc qdisc del dev "$iface" parent "$cls")
    else
        add=(sudo -n tc qdisc add dev "$iface" root netem loss 100%)
        del=(sudo -n tc qdisc del dev "$iface" root)
    fi

    local pre_chg t0 t1="" deadline
    pre_chg=$(grep -c "topology changed" "$LOG")
    t0=$(date +%s.%N)
    "${add[@]}" 2>/dev/null
    # Bare `tc qdisc show` is NOT in sudoers -- only `show dev sX-ethY` is -- and a refused read
    # with stderr discarded reads exactly like "no netem". Assert on the specific device.
    if ! sudo -n tc qdisc show dev "$iface" 2>/dev/null | grep -q netem; then
        say "   POSITIVE CONTROL INVALID: netem not present on $iface after add"
        say ""
        return 0
    fi
    deadline=$(( $(date +%s) + 180 ))
    while (( $(date +%s) < deadline )); do
        (( $(grep -c "topology changed" "$LOG") > pre_chg )) && { t1=$(date +%s.%N); break; }
        sleep 0.2
    done
    "${del[@]}" 2>/dev/null
    if [[ -z "$t1" ]]; then
        say "   POSITIVE CONTROL FAILED: no detection in 180s -- this cell's zero is VOID"
    else
        say "   positive control: iface=$iface detection=$(python3 -c "print(f'{$t1-$t0:.1f}')")s (+-0.3)"
    fi
    say ""
}

say "# LLDP guard / backoff false-positive study -- LOADED fabric, 128-host OVS"
say "# date:   $(date -Is)"
say "# commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# window: ${W}s per cell under NTG load, then a positive control"
say "# idle counterpart: doc/audit/2026-08-21_lldp-guard-false-positives/fp_study.txt (0/0/0)"
say ""

for c in $CELLS; do
    case "$c" in
        A) run_cell A ;;
        B) run_cell B NDTWIN_RYU_LLDP_GUARD=0.01 ;;
        C) run_cell C NDTWIN_RYU_LLDP_GUARD=0.01 NDTWIN_RYU_LLDP_BACKOFF=10 ;;
        *) say "unknown cell '$c'" ;;
    esac || say "   (cell $c did not complete -- not a data point)"
done

stop_load
say "=================================================================="
say "## the decision number"
grep -E "^## cell|LOADED FALSE link deletions|CELL INVALID|POSITIVE CONTROL (FAILED|INVALID)" "$OUT" \
  | sed 's/^/  /' >> "$OUT"
say ""
say "done -> $OUT"
