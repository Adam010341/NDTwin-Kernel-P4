#!/usr/bin/env bash
# fp_study.sh [window_s] -- does probing faster (or skipping host ports) invent link failures?
#
# [Co-developed with claude code -- Adam]
#
# ## Why this exists
#
# The 3.9x detection speedup (NDTWIN_RYU_LLDP_GUARD=0.01, DETECTION.md) and the
# never-answered-port backoff (NDTWIN_RYU_LLDP_BACKOFF) both leave link_loop's six-missed-
# probes threshold alone -- that is their entire justification against just lowering
# LINK_LLDP_DROP. But "the threshold is untouched" is an argument, not a measurement: a
# guard of 0.01 also multiplies LLDP packet rate on the control channel 5x, and nobody has
# measured whether that pressure makes a healthy link miss six probes in a row. n=3
# detection runs over five minutes is not a false-positive study. This is the gate for
# changing any default, and it was open.
#
# ## What is measured
#
# Three cells on the full 128-host OVS stack (kernel polling, sFlow, the works):
#
#   A  Ryu defaults                          -- control: the exposure the fabric always had
#   B  NDTWIN_RYU_LLDP_GUARD=0.01            -- the shipped speedup, idle
#   C  guard=0.01 + NDTWIN_RYU_LLDP_BACKOFF=10 -- plus the host-port backoff
#
# Per cell:
#   1. knob proof     -- the overrides announce themselves in the Ryu log; a cell whose log
#                        does not carry the line was not configured, whatever env said.
#   2. idle window    -- ${W}s with zero injections. Every `Link deleted:` line in that
#                        window is a false positive by construction.
#   3. positive control -- then a REAL failure (netem loss 100% on an inter-switch link,
#                        same resolution and assertions as lldp_detection.sh). A cell that
#                        cannot detect a real failure would make its zero above meaningless
#                        (smoke the accept path, not just refusals). This also logs the
#                        failover-path walk line -- the _route_reinstall_worker call site
#                        WALK_SWEEP.md still owes a number for.
#
# Detection here is polled at 0.2 s, so control-cell times carry +-0.3 s -- fine against a
# 10 s LINK_TIMEOUT floor; DETECTION.md's tail-stamped numbers stay the precise ones.
#
# Commands live in a script file, not on a prompt: pgrep/pkill patterns typed at a prompt
# match the shell running them (three times on 2026-08-20).
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0821}"
REPO=/home/adam/Desktop/NDTwin-Kernel
LOG="$REPO/.test_run/logs/ryu.log"
OUT="$REPO/doc/audit/2026-08-21_lldp-guard-false-positives/fp_study.txt"
W="${1:-1200}"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

links_now() {
    curl -sf --max-time 5 http://localhost:8080/v1.0/topology/links \
      | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "?"
}

# Verbatim from lldp_detection.sh, including both of its recorded traps (hex vs decimal
# port_no; SRCPORT on python3 not curl).
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

run_cell() {
    local name="$1"; shift
    say "## $name"
    say "   env: ${*:-<defaults>}"

    ndt down > /tmp/fp_down.out 2>&1 || { say "   DOWN FAILED; aborting"; exit 1; }
    sleep 2
    if ! env "$@" timeout 600 ndt up ovs 128 > "/tmp/fp_up_$name.out" 2>&1; then
        say "   UP FAILED (/tmp/fp_up_$name.out)"
        tail -4 "/tmp/fp_up_$name.out" | sed 's/^/     /' | tee -a "$OUT"
        return 1
    fi

    say "   knob lines in ryu log:"
    if grep "^NDTWIN:" "$LOG" >/dev/null 2>&1; then
        grep "^NDTWIN:" "$LOG" | sed 's/^/     /' | tee -a "$OUT"
    else
        say "     (none -- Ryu defaults)"
    fi

    local ifaces
    ifaces=$(ls /sys/class/net | grep -c '^s[0-9]*-eth')
    say "   fabric: $((ifaces - 32)) hosts, ${ifaces} switch ports (veth count)"
    say "   ryu links at window start: $(links_now)"

    local base_del base_chg
    base_del=$(grep -c "Link deleted:" "$LOG")
    base_chg=$(grep -c "topology changed" "$LOG")
    say "   idle window: ${W}s, zero injections ($(date -Is))"
    sleep "$W"

    local n_del n_chg
    n_del=$(grep -c "Link deleted:" "$LOG")
    n_chg=$(grep -c "topology changed" "$LOG")
    say "   false link deletions during window: $((n_del - base_del))"
    say "   'topology changed' during window:   $((n_chg - base_chg))"
    say "   ryu links at window end: $(links_now)"
    if (( n_del - base_del > 0 )); then
        grep "Link deleted:" "$LOG" | tail -n $((n_del - base_del)) \
          | sed 's/^/     FP: /' | tee -a "$OUT"
    fi

    # ---- positive control: a real failure must still be detected ------------------------
    local dst=10.0.0.33 iface rc
    iface=$(resolve_iface "$dst"); rc=$?
    if (( rc != 0 )); then
        say "   POSITIVE CONTROL SKIPPED: could not resolve an inter-switch on-path iface (rc=$rc)"
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

    local pre_chg pre_done t0
    pre_chg=$(grep -c "topology changed" "$LOG")
    pre_done=$(grep -c "route reinstall done" "$LOG")
    t0=$(date +%s.%N)
    "${add[@]}" 2>/dev/null
    if ! sudo -n tc qdisc show dev "$iface" 2>/dev/null | grep -q netem; then
        say "   POSITIVE CONTROL INVALID: netem not present after add"
        return 0
    fi

    local deadline t1="" t2=""
    deadline=$(( $(date +%s) + 180 ))
    while (( $(date +%s) < deadline )); do
        [[ -z "$t1" ]] && (( $(grep -c "topology changed" "$LOG") > pre_chg )) && t1=$(date +%s.%N)
        [[ -z "$t2" ]] && (( $(grep -c "route reinstall done" "$LOG") > pre_done )) && t2=$(date +%s.%N)
        [[ -n "$t1" && -n "$t2" ]] && break
        sleep 0.2
    done
    "${del[@]}" 2>/dev/null

    if [[ -z "$t1" ]]; then
        say "   POSITIVE CONTROL FAILED: no detection within 180 s -- the idle zero above is void"
    else
        local det tot
        det=$(python3 -c "print(f'{$t1-$t0:.1f}')")
        tot=$([[ -n "$t2" ]] && python3 -c "print(f'{$t2-$t0:.1f}')" || echo "n/a")
        say "   positive control: iface=$iface detection=${det}s (+-0.3) detect+debounce+walk=${tot}s"
        say "   failover-path walk line (last 'install_all_pair_paths done' in log):"
        grep "install_all_pair_paths done" "$LOG" | tail -1 | sed 's/^/     /' | tee -a "$OUT"
        say "   walks this boot: $(grep -c "install_all_pair_paths done" "$LOG")  (first is startup, rest are reinstalls)"
    fi
    say ""
}

: > "$OUT"
say "# LLDP guard / backoff false-positive study, 128-host OVS, idle fabric"
say "# date:   $(date -Is)"
say "# commit: $(cd "$REPO" && git rev-parse --short HEAD)"
say "# window: ${W}s per cell, then a positive control (real netem failure)"
say ""

run_cell A_default
run_cell B_guard001 NDTWIN_RYU_LLDP_GUARD=0.01
run_cell C_guard001_backoff10 NDTWIN_RYU_LLDP_GUARD=0.01 NDTWIN_RYU_LLDP_BACKOFF=10

ndt down >/dev/null 2>&1
say "study complete -> $OUT"
