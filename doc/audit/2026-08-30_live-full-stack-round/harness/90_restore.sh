#!/bin/bash
# =================================================================================================
# 90_restore.sh -- put the fabric back after 25_apps_energy.sh powered switches down.
#
# 🔴🔴 DO NOT RUN UNTIL T-10 LANDS. NEITHER ROUTE RESTORES. (FINDING-04, measured 2026-08-30)
#
#   Route 1 (power-on) reports its own failure correctly, but P4 power-on is a stub, so the
#   switches do not come back.
#   Route 2 (--rebuild) is worse: ndt_down() in lib.sh prints its progress to the same stdout
#   it returns the count on, so REMAIN is never the bare "0" the caller tests for. It always
#   takes the `bad` branch and exit 1s -- BEFORE ndt_up. It tears the fabric down and stops,
#   leaving the machine worse than it found it.
#
#   Until then: bring a degraded fabric back by hand, with `ndt down` then `ndt up <what>`.
#
# RUN STATUS: both routes were executed 2026-08-30 15:38-15:41 and both failed. The line here
# used to read "WRITTEN, NOT RUN. `bash -n` only." -- that is no longer true and is corrected
# rather than left, because the next reader would take it as a reason to distrust the finding
# above instead of the script below.
#
# TWO ROUTES, AND THE HONEST STATEMENT OF WHAT EACH ONE RESTORES
#
#   Route 1 -- power the switches back on (default).
#       POST /ndt/set_switches_power_state action=on for each switch recorded in
#       $OUT/energy_powered_off.txt, then verify nodes and edges return to their pre-energy
#       counts. Verified working three times; 08-18 N-8 measured 10/10 processes and
#       "edges up 40/40" within 45 s.
#       ⚠️ ON OVS THIS DOES NOT FULLY RESTORE THE FABRIC. F-7a (as corrected 2026-08-18 19:30):
#       OVSPowerStrategy::powerOff saves the port list but not the qdisc, and powerOn re-adds
#       the ports WITHOUT re-applying shaping. Four interfaces -- the 1 Gbps ports on the
#       cycled switches -- come back unshaped, and nothing in the twin distinguishes them.
#       On P4 this does not apply: ntg_bmv2_topo.py shapes nothing, so 0 of 36 interfaces have
#       htb to lose (08-18 N-4).
#
#   Route 2 -- full rebuild: `ndt down` then `ndt up <same args>`  (--rebuild).
#       The only route that returns the fabric to a state comparable with the start of the
#       round. Use it on OVS always, and on P4 whenever route 1's verification does not come
#       back clean.
#
# 🔑 The reason both are offered rather than just the cheap one: "the counts came back" and
#    "the fabric came back" are different claims, and on OVS only the second route supports the
#    second claim. A restore that reports success while leaving four links unshaped is the house
#    pattern this round is auditing.
#
# H-CORRESPONDENCE
#   H-17  no signal-based liveness. `ndt down`'s effect is judged by counting processes via
#         `ps -eo comm=` and by the kernel graph, both readable regardless of owner.
#   H-18  restoration is judged on the twin's own numeric fields, not on a log word.
#   H-19  a kernel that answers with a still-degraded graph is answering; that is a restore
#         failure, not a kernel failure, and the two are reported differently.
#   H-20  the pre-energy graph is read from $OUT/graph_energy_before.json, written by
#         25_apps_energy.sh in THIS run's output directory. It cannot be a previous run's file.
#   H-21  pipefail; gates take pre-computed values.
#   H-22  nothing backgrounded. `ndt up`/`ndt down` go through lib.sh's setsid wrappers because
#         they kill their calling shell with exit 144 while the teardown itself succeeds.
#   H-23  see H-18.
#   H-24  n/a.
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harness_begin 90_restore

MODE="${1:-power-on}"        # power-on | --rebuild
UP_ARGS="${2:-}"             # e.g. "p4 4"  -- required for --rebuild

BEFORE_JSON="$OUT/graph_energy_before.json"
[[ -f "$BEFORE_JSON" ]] || die "no $BEFORE_JSON. 25_apps_energy.sh writes it, and without it there is no reference to restore TO. If the energy phase never ran, there is nothing to restore."

read -r B_SW B_UP B_E B_ED <<<"$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sw=[n for n in d["nodes"] if n.get("vertex_type")==0]
print(len(sw), sum(1 for n in sw if n.get("is_up")), len(d["edges"]),
      sum(1 for e in d["edges"] if not e.get("is_up")))' "$BEFORE_JSON")"
info "pre-energy reference: $B_UP/$B_SW switches up, $B_E edges, $B_ED down"
# Printed, not only commented in the header: the person at risk is the operator who was just
# told "run ./90_restore.sh" by 25_apps_energy.sh, and a header comment never reaches them.
# Output only -- no control flow is changed, so a deliberate run after T-10 still works.
info "🔴 T-10 NOT YET LANDED: neither route below restores (FINDING-04). Route 2 will tear the"
info "   fabric down and stop. If you did not mean to, ^C now and use: ndt down && ndt up <what>"

now_counts() {
    http_probe "$1" GET "$NDT_URL/ndt/get_graph_data" >/dev/null
    python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sw=[n for n in d["nodes"] if n.get("vertex_type")==0]
print(len(sw), sum(1 for n in sw if n.get("is_up")), len(d["edges"]),
      sum(1 for e in d["edges"] if not e.get("is_up")))' "$OUT/http/$1.body" 2>/dev/null || printf '? ? ? ?'
}

case "$MODE" in
--rebuild)
    say "ROUTE 2 -- full rebuild"
    [[ -n "$UP_ARGS" ]] || die "--rebuild needs the same arguments the round was brought up with, e.g.  ./90_restore.sh --rebuild 'p4 4'"
    REMAIN="$(ndt_down)"
    if [[ "$REMAIN" == "0" ]]; then
        ok "teardown: 0 bmv2 processes remain (judged on the machine's state, not on ndt down's rc -- it exits 144 by killing its own caller)"
    else
        bad "teardown left $REMAIN bmv2 process(es) running. bmv2 survives 'mn -c'; do not bring a new fabric up on top of them."
        summary; exit 1
    fi
    # H-20 again: the manifest is root-owned and outlives the fabric.
    if [[ -e "$P4_MANIFEST" ]]; then
        bad "$P4_MANIFEST still exists after teardown (owner $(stat -c %U "$P4_MANIFEST" 2>/dev/null || echo '?')). Remove it before 'ndt up', or the next run's manifest check can read this one: sudo rm -f $P4_MANIFEST"
    else
        ok "$P4_MANIFEST is gone"
    fi
    # shellcheck disable=SC2086
    ndt_up $UP_ARGS || true
    ;;
power-on)
    say "ROUTE 1 -- power the recorded switches back on"
    OFFLIST="$OUT/energy_powered_off.txt"
    [[ -f "$OFFLIST" ]] || die "no $OFFLIST -- 25_apps_energy.sh records there which switches it saw go down. Without it we would be guessing which to power on."
    NAMES="$(head -1 "$OFFLIST")"
    info "recorded as powered off: $NAMES"
    if [[ "$NAMES" == "none" || -z "$NAMES" ]]; then
        skip "nothing was powered off, so there is nothing to restore"
        summary; exit 0
    fi
    # The endpoint takes the switch's management IP, not its name (Energy-App's own call shape:
    # src/app/http.cpp:126-127  set_switches_power_state?ip=...&action=on|off). Map name -> ip
    # from the graph the kernel is holding, so the mapping comes from the system rather than
    # from a table in this script that could drift.
    python3 - "$BEFORE_JSON" "$NAMES" > "$OUT/restore_targets.txt" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
want=set(x for x in sys.argv[2].split(",") if x)
for n in d["nodes"]:
    if n.get("vertex_type")==0 and n.get("device_name") in want:
        print(n.get("device_name"), n.get("ip") or n.get("ip_address") or n.get("mgmt_ip") or "NO-IP-FIELD")
PY
    sed 's/^/      /' "$OUT/restore_targets.txt"
    if grep -q 'NO-IP-FIELD' "$OUT/restore_targets.txt"; then
        bad "the graph has no IP field under the names this script tried (ip / ip_address / mgmt_ip). Read one node object out of $BEFORE_JSON, find the real key, and fix the python block above before continuing. Do NOT hand-write an IP table."
        summary; exit 1
    fi
    while read -r nm ip; do
        [[ -n "$ip" ]] || continue
        read -r RC CODE <<<"$(http_probe "poweron_$nm" POST "$NDT_URL/ndt/set_switches_power_state?ip=$ip&action=on")"
        info "power on $nm ($ip) -> curl_rc=$RC http=$CODE"
    done < "$OUT/restore_targets.txt"

    # A power-on endpoint in this project has already been observed returning success without
    # acting (memory: power-on-reports-success-without-acting). The verdict is the graph, and
    # only the graph. 08-18 N-8 measured full restoration within 45 s, so 120 s is generous.
    say "verify -- the graph, not the response code"
    RESTORED=0
    for i in $(seq 1 24); do
        read -r N_SW N_UP N_E N_ED <<<"$(now_counts restore_check)"
        info "  +$(( i * 5 ))s: $N_UP/$N_SW up, $N_E edges, $N_ED down"
        if [[ "$N_UP" == "$B_UP" && "$N_ED" == "$B_ED" ]]; then RESTORED=1; break; fi
        sleep 5
    done
    if (( RESTORED == 1 )); then
        ok "counts are back to the pre-energy reference ($B_UP/$B_SW up, $B_ED edges down)"
    else
        bad "counts did not return within 120s. Fall back to the full rebuild:  ./90_restore.sh --rebuild '<the same args you used for ndt up>'"
    fi
    ;;
*)
    die "unknown mode '$MODE' (use: power-on | --rebuild '<ndt up args>')"
    ;;
esac

# -------------------------------------------------------------------------------------------------
say "the statement that must go in the write-up either way"
if [[ -n "$(port_holder 8080)" ]]; then
    bad "THIS IS AN OVS RUN (:8080 held). Route 1 cannot restore link shaping: F-7a leaves the cycled switches' 1 Gbps ports unshaped and the twin reports them identically to shaped ones. If you used power-on, the fabric is NOT comparable to the start of the round. Rebuild, or record the limitation explicitly."
else
    ok "P4 run (no Ryu on :8080): there is no htb on this fabric to lose (08-18 N-4), so power-on restores what there was"
fi
info "leftover fault-injection check:"
"$NDT_BIN" status --check > "$OUT/ndt_status_restore.txt" 2>&1 && ok "ndt status --check: ok" || bad "ndt status --check reports problems -- see $OUT/ndt_status_restore.txt"
sed 's/^/      /' "$OUT/ndt_status_restore.txt" || true

summary
exit 0
