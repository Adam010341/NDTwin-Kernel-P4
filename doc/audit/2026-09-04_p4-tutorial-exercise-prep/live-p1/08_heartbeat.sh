#!/usr/bin/env bash
#
# Phase 4, second cut -- live acceptance H1-H5 of the veth heartbeat on a foreign P4 fabric
# (TICKET-P4-heartbeat section 2, "live": detection + automatic reroute).
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WRITTEN AND SELF-TESTED OFFLINE; ITS AUTHOR NEVER RAN IT AGAINST A LAB. Segment W's worker
# had no lab (the orchestrator runs H1-H5 after the merge). `--self-test` runs every verdict below
# against synthetic captures -- one that must pass and one that must fail per check -- walks the
# teardown with a fake ndt, and reads the prelude's defaults back; it touches nothing else. That
# proves the checks can tell the answers apart; it proves nothing about a fabric.
#
# What each step asserts (the ticket's words; the numbers are the ticket's, not re-derived):
#
#   H1  exercises/basic on pod-topo with `roles.ipv4_route` owner ndtwin, and the heartbeat
#       `ndt up p4 --app` starts: switch_state says reroute true / link_discovery heartbeat.
#       An OUT-OF-BAND netem loss 100% on both ends of one inter-switch cable (faults.sh's
#       htb-safe attach point, NOT inject_link_failure -- the kernel would know about that one)
#       -> both directions `is_up: false` in the kernel's graph within 20 s -> no installed route
#       points into the cut cable any more, every destination still has one -> all 12 ordered
#       host pairs ping at 0% loss. Netem off -> both directions `is_up: true` within 20 s, no
#       netem left on either end. The cable is the first of pod-topo's four that some installed
#       route USES before the cut (a cut nobody routes over proves no reroute), preferring
#       s1-s3, the one segment S measured.
#   H2  the negative control, same fabric, same cut: the heartbeat STOPPED (`sudo ndtwin-lab
#       heartbeat stop`, once switch_state says heartbeat_not_running) -> for 30 s, longer than
#       H1's bound with margin, both directions stay `is_up: true`. Detection comes from the
#       heartbeat and from nothing else.
#   H3  the same exercise WITHOUT roles (unbound): the heartbeat runs, the cut is detected
#       (both directions down within 20 s), `reroute: false` with reason `unbound`, the
#       author's entries row-for-row what they were before the cut, and a write still 501.
#       (H3 is cut at the worst phase too and recorded like an H1 cycle.)
#   H4  exercises/p4runtime (external control plane): /stats/flowentry/add, delete,
#       delete_strict and modify answer 409 `external control plane`; `reroute.reason`
#       external_control_plane. [Co-developed with claude code -- Adam] Since 09-27 `ndt up`
#       starts the heartbeat there too, DETECT ONLY: it says so, the helper runs, switch_state's
#       heartbeat is usable with capabilities reroute false / link_discovery heartbeat, and one
#       out-of-band cut of s1-s2 is held down BY THE PROXY (switch_state `links`, both
#       directions, source heartbeat) within about 20 s while reroute stays false for the
#       external reason; restored, both directions up again, no netem left, no heartbeat frame
#       counted leaving a host port. [Co-developed with claude code -- Adam] Since the external
#       judge's F4/F9 (09-28): the kernel must have ACCEPTED both transitions on both directions
#       (`reported_to_kernel: true`), every switch's pipeline_commits / rules_timed /
#       table_generation is unchanged across the cut and the restore, and the restore is judged
#       at the strict 20 s (the poll waits 35 s so a late one is still measured). 🔴 THE KERNEL'S GRAPH IS NOT THE READING HERE: no exercise
#       controller runs in H4, so no pipeline is loaded and the twin holds these switches down
#       (03's 2026-09-18 reading). What the exercise's own evidence does with the heartbeat
#       running is H5's 06 against a same-session CONTROL without the heartbeat (README, "合併前的
#       比對"), by external_evidence.py -- not against 074635Z, which ran other code
#       (5dc7fc9a + 95 uncommitted files) and has no venv fingerprint.
#   H5  (PART=h5, separately: it runs 06 and 01, which claim the lab per step) live-p1/06 ONCE
#       with the heartbeat on wherever `ndt up` starts it -> 26 arms, every one's rc and verdict
#       what `2026-09-27T074635Z_06_thirteen` recorded (OLD_06; 185505Z until 09-27, the same rc
#       and verdict arm for arm); a sampler of the heartbeat report proves which arms had one
#       running -- 20 since 09-27, the 3 external ones included (HB_ARMS) -- and that no arm's
#       daemon counted a frame leaving a host port; then 01 (NDTwin's own fabric) PASS, with no
#       heartbeat session started under it. [Co-developed with claude code -- Adam] (the external
#       judge's S2, 09-28) For the external comparison, run H5 with OLD_06 set to the control C1
#       (`OLD_06=<C1> PART=h5 ...`): its rc/verdict check is then against a run of the same session
#       and venv. The external arms' OWN evidence (tunnel counters, packet-ins, cache entries) is
#       external_evidence.py's, against C1 and C2 with this run's 50_samples.tsv -- the sampler
#       also records each report's written_wall, stop_reason and the daemon's four counters, and
#       50_t06_end.txt holds 06's end, the last arm's window edge.
#
# 🔴 HOW H1 JUDGES "WITHIN 20 s" (the fable judge's F1 on 1a3ebd7f, 09-26; SUMMARY section 2).
# Detection is (timeout - phi) + psi + the pass's read, _notify_link's HTTP and the kernel's graph
# update: at phi -> 0 the report-level part alone is ~15 s and psi can be a whole watchdog
# interval, so a strict 20 s has NO budget left for the rest. [Co-developed with claude code --
# Adam] 🔴 ADAM'S RULING (09-27): the acceptance is AT MOST ABOUT 20 s -- the same class as NDTwin's
# own LLDP, which runs the same rule on the same constants. The strict bound is still measured and
# kept (`strict_20s` in 30_cycles.tsv and the cycle's own line), but a cycle over it is a DISCLOSED
# NOTE, not a FAIL: every such cycle's strict line is repeated verbatim, just above the run's last
# line, and the run can PASS with it -- also when the run stops early: an exit before H1's (or H3's)
# own conclusion has w_finish conclude the cycles measured so far, so their NOTE still stands above
# the FAIL. (Before the ruling: a FAIL of that cycle, with "N of M cycle(s) OVER" at the head of the
# last line -- the fable judge's F1.) [Co-developed with claude code -- Adam] Two limits the word
# "about" does NOT stretch (the opus judge's N2, 09-27): detection still has a HARD CEILING of
# DETECT_BOUND_S + 15 = 35 s -- graph_until gives up there and the cycle is a FAIL, not a note --
# and the RESTORE is still judged against the strict 20 s (RESTORE_BOUND_S, a FAIL over it): Adam's
# ruling names detection only, and whether restore becomes "about 20 s" too is his to say. "20 s +
# the time measured on
# top of the design" (the reporting pass's lateness beyond one interval, pass-to-graph, the cut
# window) is kept as a DIAGNOSTIC column and note, never as the verdict: the judge showed it is OK
# whenever the design works as designed (it restates the design's upper bound). What it checked for
# real -- a pass after the timeout that did not report the cut -- is v_cycle's own BAD. And one
# run samples ONE psi (the watchdog's phase drifts by a pass's duration per pass): a PASS says
# "within 20 s at the psi this run had", not "at the worst psi". The instants are bash's own
# $EPOCHREALTIME around each tc call (no forked `date`/`now`: the spike's forked t1 landed 12.7 ms
# after a heard frame and a whole round was discarded, a false +5 s); frames heard inside a cut
# or restore window are FLAGGED in the row, never dropped.
#
# 🔴 RULING 4 IS A STOP CONDITION HERE TOO: the daemon counting a heartbeat frame leaving a
# host-facing port (`forwarded_to_hosts > 0`) fails the run with STOP at the head of the reason.
#
# 🔴 THE TEARDOWN LESSONS OF SEGMENT S, ROUND 7 (its first live run released over a live fabric):
#   * this script NEVER declares `measuring=` (NDT_MEASURING is unset before anything else and
#     every ndt call runs without it), so `ndt down` is never refused by the T2d guard and no
#     retraction is needed before one. The claim alone keeps other owners' teardowns off;
#   * it releases ONLY after its last `ndt down` answered 0 or 3. Any other answer KEEPS the
#     claim (re-claimed for an hour, its note saying a fabric may still be up), prints what is
#     running and the commands to finish, and ends FAIL with that at the head of the last line;
#   * a phase whose `ndt down` did not answer 0 stops the run: the next `ndt up p4 --app` over
#     an intact fabric of the same size would reuse it ("already up ... reusing");
#   * CLAIM_MINUTES is defaulted BEFORE _common.sh is sourced (whose `:=45` would shadow it);
#   * INT and TERM are failures [Co-developed with claude code -- Adam] (the AEG judge's N-1,
#     09-28): each has its own trap that records "interrupted by SIG..." and exits 130 / 143, so a
#     run stopped by pid can never end PASS -- the EXIT trap then tears down as always;
#   * NDT_OWNER must be given explicitly (`live-p1` is not an owner); since Adam's ruling G
#     (09-27) _common.sh's start_step refuses without one too -- this check stays, earlier.
#
# Run:        NDT_OWNER=<you> bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/08_heartbeat.sh
#             NDT_OWNER=<you> PART=h5 bash .../08_heartbeat.sh
# Self-test:  bash .../08_heartbeat.sh --self-test
# Exit: 0 PASS, 1 FAIL (the last line says which, STOP for ruling 4), 2 refused before anything
#       was started.
set -euo pipefail

# --- the prelude: every default and every refusal that must hold before _common.sh -------------
# (--self-test runs this part on its own, from this line to the end-of-prelude marker, and reads
# the defaults back; keep anything with a side effect below the marker.)
LIVE_DIR_08="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" != "--self-test" && -z "${NDT_OWNER:-}" ]]; then
    echo "   !! refusing: set NDT_OWNER=<you>. A default owner ('live-p1', _common.sh's until 09-27) is" >&2
    echo "      nobody -- a claim nobody owns is one nobody can finish by hand (segment S, round 7)." >&2
    echo "REFUSED 08_heartbeat -- nothing was started"
    exit 2
fi
PART="${PART:-h1h4}"
case "$PART" in h1h4|h5) ;; *) echo "REFUSED 08_heartbeat -- PART=$PART (want h1h4 or h5)"; exit 2 ;; esac
# [Co-developed with claude code -- Adam] (the round-4 review's M-1) H5 reconciles a WHOLE 06 -- 26
# arms, rc and verdict each -- so its reference is a whole 06 too: refused here, before anything
# runs, rather than ending every run on "the reference table has 4 arms, not 26" (an ONLY= 06).
if [[ "$PART" == h5 ]]; then
    : "${OLD_06:=$LIVE_DIR_08/runs/2026-09-27T074635Z_06_thirteen}"
    _arms="$(awk -F'\t' 'NR > 1 && NF >= 5' "$OLD_06/00_table.tsv" 2>/dev/null | wc -l)"
    if [[ "$_arms" != 26 ]]; then
        echo "   !! OLD_06=$OLD_06 has $_arms arm(s) in its 00_table.tsv, not 26: H5 compares a whole 06" >&2
        echo "      (for the external comparison, the control C1 is a full 06 with no ONLY=; README)." >&2
        echo "REFUSED 08_heartbeat -- OLD_06 is not a whole 06 (nothing was started)"
        exit 2
    fi
fi
# 🔴 Before the source: _common.sh runs `: "${CLAIM_MINUTES:=45}"`, and H1-H4 is four fabrics.
: "${CLAIM_MINUTES:=120}"
# 🔴 This script never declares a measurement; see the header.
unset NDT_MEASURING
# The tc route: `sudo -n mnexec -a 1 tc` (uid 0 in pid 1's network namespace), set before
# faults.sh so its `${FAULTS_TC:-sudo -n tc}` keeps it -- the route segment S measured with.
: "${FAULTS_TC:=sudo -n mnexec -a 1 tc}"
# faults.sh FIRST: its `say` is then replaced by _common.sh's, the only name the two share.
# shellcheck source=/dev/null
source "$LIVE_DIR_08/../../../../tools/test_workflow/faults.sh"
# shellcheck source=_common.sh
source "$LIVE_DIR_08/_common.sh"
set -euo pipefail
# --- end of prelude ------------------------------------------------------------------------------

LAB_HELPER="${LAB_HELPER:-/usr/local/sbin/ndtwin-lab}"
HB_REPORT_FILE="${HB_REPORT_FILE:-/run/ndtwin-lab/heartbeat.json}"
REAL_NDT="$NDT"
VPY="${VERDICT_PY:-/usr/bin/python3}"
EXERCISE="${EXERCISE_DIR:-$HOME/tutorials/exercises/basic}"
PKG_ROLES="$PKG_ROOT/hb_basic_roles"
PKG_PLAIN="$PKG_ROOT/hb_basic_noroles"
PKG_EXT="$PKG_ROOT/hb_p4runtime_solution"
PREP="$LIVE_DIR/../../2026-09-25_p4-heartbeat/spike/census_prepare.py"
P4C="${P4C:-/usr/local/bin/p4c-bm2-ss}"
ROLE="owner=ndtwin,table=MyIngress.ipv4_lpm,match_field=hdr.ipv4.dstAddr"
ROLE="$ROLE,action=MyIngress.ipv4_forward,dst_mac=dstAddr,port=port"
#: pod-topo's four cables, `a:ap:b:bp` -- exercises/basic/pod-topo/topology.json.
CABLES="1:3:3:1 1:4:4:2 2:3:4:1 2:4:3:2"
#: The ticket's bounds (section 2, H1): the kernel's graph, both directions, within 20 s.
DETECT_BOUND_S=20
RESTORE_BOUND_S=20
#: H2: hold the cut this long with the heartbeat stopped.
H2_HOLD_S=30
#: H1's cuts: how many, how many of them at the worst phase, that phase, and the random seed.
H1_CYCLES="${H1_CYCLES:-6}"
H1_WORST="${H1_WORST:-3}"
#: 20 ms after the predicted send: tc's own start-up (sudo, mnexec) puts the netem 10-30 ms after
#: the call starts, i.e. 20-50 ms after the ACTUAL send (orchestrator 09-26); the attach points
#: are read before the sleep, so nothing else sits between the planned instant and the call.
PHI_WORST="${PHI_WORST:-0.02}"
H1_SEED="${H1_SEED:-$(( $(date +%s) % 32768 ))}"
#: Filled from the proxy by consts() before the claim; empty until then (never retyped here).
HB_PERIOD_S=""; TIMEOUT_S=""; WATCHDOG_S=""

# consts -- the proxy's own beacon interval, timeout and watchdog interval (never retyped here).
consts() {
    ( cd "$REPO/p4_proxy" && env -u NDTWIN_P4_BEACON_S PYTHONPATH=. PYTHONDONTWRITEBYTECODE=1 "$PY" -c \
        'from proxy_agent import topology_manager as t; print(t.LLDP_BEACON_INTERVAL_S, t.LINK_BEACON_TIMEOUT_S, t.LINK_WATCHDOG_INTERVAL_S)' 2>/dev/null )
}
#: What 06 is reconciled against (H5). [Co-developed with claude code -- Adam] 09-27: the round on
#: the protobuf 5 venv with no heartbeat on the external arms (its rc and verdict columns are
#: 185505Z's, arm for arm). For the external detect-only comparison set it to the same session's
#: control C1 instead (the external judge's S2, 09-28; README "合併前的比對"): 074635Z ran other
#: code (5dc7fc9a + 95 uncommitted files) and recorded no venv.
OLD_06="${OLD_06:-$LIVE_DIR/runs/2026-09-27T074635Z_06_thirteen}"
#: The 06 arms that bring up a foreign fabric with an inter-switch link, i.e. the ones `ndt up p4
#: --app` starts the heartbeat on. Segment S's census: calc and multicast are one switch;
#: basic_tunnel and flowcache skeletons do not build. [Co-developed with claude code -- Adam] Since
#: 09-27 the three external arms (p4runtime x2, flowcache/solution) are in it too, detect only --
#: all 20 of segment S's running arms.
HB_ARMS="basic/skeleton basic/solution source_routing/skeleton source_routing/solution
basic_tunnel/solution load_balance/skeleton load_balance/solution qos/skeleton qos/solution
link_monitor/skeleton link_monitor/solution firewall/skeleton firewall/solution ecn/skeleton
ecn/solution mri/skeleton mri/solution p4runtime/skeleton p4runtime/solution flowcache/solution"
#: [Co-developed with claude code -- Adam] H4's cut: exercises/p4runtime/topology.json's s1-p2 <->
#: s2-p2, the cable its tunnel 100 rides (transcribed, `a:ap:b:bp`; the proxy's own model of the
#: package is checked against it before the cut).
CUT_EXT="1:2:2:2"

FABRIC_UP=0
TEARDOWN_DOWN_RC=""
INJECTED_IFACES=()
SAMPLER_PID=""
SAMPLER_STOP=""
SAMPLER_ERR=""
SAMPLER_OUT=""
#: The last cut's and restore's instants: $EPOCHREALTIME just before and just after each end's tc
#: call (end A is s<a>-eth<ap>, whose egress carries a->b; end B carries b->a).
CUT_A_START=""; CUT_A_END=""; CUT_B_START=""; CUT_B_END=""
RESTORE_A_START=""; RESTORE_A_END=""; RESTORE_B_START=""; RESTORE_B_END=""
T_CUT=""
#: The restore's report watcher (restore_watch_start), and how long it waits for both directions.
RESTORE_WATCH_PID=""; RESTORE_WATCH_OUT=""
RESTORE_WATCH_S=$(( RESTORE_BOUND_S + 5 ))
#: What cut_cycle / restore_cycle leave for the caller's row.
CYCLE_ROW=""; CYCLE_STRICT=""; RESTORE_ROW=""
#: cut_cycle's tally for strict_conclude: cycles recorded, how many were over the bound, and each
#: over-cycle's own strict line, verbatim ("<label>: detection ... OVER ...", "; "-separated).
#: [Co-developed with claude code -- Adam] STRICT_PHASE is the phase those cycles belong to (H1,
#: H3), for w_finish to conclude them under when the run stops before the phase did.
STRICT_CYCLES=0; STRICT_OVER=0; STRICT_OVER_LIST=""; STRICT_PHASE=""

# --- the verdicts. One stdlib-only program, one entry per check; each prints `OK ...` or
# `BAD ...` (`STOP ...` for ruling 4). The live path and --self-test call the same entries. ------
verdict() {
    "$VPY" -I - "$@" <<'VERDICTS'
import glob, json, os, re, sys

def load(p):
    with open(p) as fh:
        return json.load(fh)

def rows_of(path):
    body = load(path)
    return [r for v in body.values() for r in v] if isinstance(body, dict) else []

def edge(graph, a, ap, b, bp):
    for e in graph.get("edges", []):
        if (e.get("src_dpid"), e.get("src_interface"), e.get("dst_dpid"), e.get("dst_interface")) == (a, ap, b, bp):
            return (e.get("is_enabled"), e.get("is_up"))
    return None

def cut_args(args):
    a, ap, b, bp = (int(x) for x in args[:4])
    return a, ap, b, bp

def v_caps(state, reroute, discovery):
    sw = load(state).get("switches") or {}
    want = reroute == "true"
    bad = {d: {k: (s.get("capabilities") or {}).get(k) for k in ("reroute", "link_discovery")}
           for d, s in sorted(sw.items())
           if (s.get("capabilities") or {}).get("reroute") is not want
           or (s.get("capabilities") or {}).get("link_discovery") != discovery}
    if not sw:
        return "BAD switch_state names no switch"
    if bad:
        return f"BAD {len(bad)} of {len(sw)} switch(es) are not reroute {reroute} / link_discovery {discovery}: {bad}"
    return f"OK all {len(sw)} switches: reroute {reroute}, link_discovery {discovery}"

def v_reroute(state, available, reason):
    r = load(state).get("reroute")
    if not isinstance(r, dict):
        return "BAD switch_state has no top-level reroute (a proxy from before segment W?)"
    want = (available == "true", None if reason == "null" else reason)
    got = (r.get("available"), r.get("reason"))
    if got == want:
        return f"OK reroute.available {got[0]}, reason {got[1]}"
    return f"BAD reroute is available {got[0]!r} reason {got[1]!r}, want {want[0]!r} {want[1]!r} ({r.get('detail')})"

def v_hb_state(state, want):
    h = load(state).get("heartbeat")
    if not isinstance(h, dict):
        return "BAD switch_state has no heartbeat block"
    if h.get("state") == want:
        return f"OK heartbeat.state {want} (watchdog {h.get('watchdog')}, session {h.get('session')})"
    return f"BAD heartbeat.state {h.get('state')!r}, want {want!r} ({h.get('detail')})"

def v_links(state, want, *cut):
    """[Co-developed with claude code -- Adam] H4: both directions of the cut as the PROXY holds them
    (switch_state `links`) -- down or up, and from the heartbeat, not merely declared. `down-told` /
    `up-told` also require the kernel to have ACCEPTED the report on both directions
    (`reported_to_kernel: true`) -- the external judge's F4 (09-28): "a cut is told to the twin" is
    otherwise asserted nowhere live."""
    a, ap, b, bp = cut_args(cut)
    word, _, told = want.partition("-")
    links = load(state).get("links") or {}
    got = {k: links.get(k) for k in (f"{a}:{ap}->{b}:{bp}", f"{b}:{bp}->{a}:{ap}")}
    bad = [f"{k}={(v.get('down'), v.get('source')) if isinstance(v, dict) else None}" for k, v in got.items()
           if not isinstance(v, dict) or v.get("down") is not (word == "down") or v.get("source") != "heartbeat"]
    if bad:
        return f"BAD the proxy does not hold s{a}:{ap}<->s{b}:{bp} {word} by the heartbeat: " + "; ".join(bad)
    untold = [k for k, v in got.items() if v.get("reported_to_kernel") is not True]
    if told == "told" and untold:
        return (f"BAD s{a}:{ap}<->s{b}:{bp} is {word} at the proxy, but the kernel has not accepted it: "
                f"reported_to_kernel is not true on {untold}")
    said = ", ".join(f"{k} reported_to_kernel {v.get('reported_to_kernel')}" for k, v in got.items())
    return f"OK both directions of s{a}:{ap}<->s{b}:{bp} {word} at the proxy, source heartbeat ({said})"

def v_restore_strict(elapsed, bound):
    """[Co-developed with claude code -- Adam] H4's restore against the STRICT bound (the external
    judge's F9, 09-28): Adam's "about 20 s" names detection only, so a restore over it is a FAIL."""
    d, b = float(elapsed), float(bound)
    if d <= b:
        return f"OK recovery {d:.1f} s, within the strict {b:g} s"
    return f"BAD recovery {d:.1f} s, over the strict {b:g} s (restore is judged strictly)"

def v_no_writes(before, after):
    """[Co-developed with claude code -- Adam] H4, the external judge's F4 (09-28): nothing this proxy
    could write moved across the cut -- every switch's pipeline_commits, rules_timed and
    table_generation (switch_state) are what they were before it."""
    keys = ("pipeline_commits", "rules_timed", "table_generation")
    b, a = load(before).get("switches") or {}, load(after).get("switches") or {}
    if not b:
        return "BAD the capture before the cut names no switch"
    bad = []
    for d, s in sorted(b.items()):
        t = a.get(d)
        if not isinstance(t, dict):
            bad.append(f"s{d} is missing after")
            continue
        moved = [f"{k} {s.get(k)!r}->{t.get(k)!r}" for k in keys if s.get(k) != t.get(k)]
        if moved:
            bad.append(f"s{d}: " + ", ".join(moved))
    if bad:
        return "BAD a switch's write record moved across the cut: " + "; ".join(bad)
    seen = sorted({str(tuple(s.get(k) for k in keys)) for s in b.values()})
    return f"OK {len(b)} switch(es): {', '.join(keys)} unchanged ({'; '.join(seen)})"

def v_model_has(model, *cut):
    """[Co-developed with claude code -- Adam] H4: the cable to cut is one the package declares."""
    a, ap, b, bp = cut_args(cut)
    m = load(model)
    pairs = {(e["src_dpid"], e["src_interface"], e["dst_dpid"], e["dst_interface"]) for e in m.get("edges", [])}
    if (a, ap, b, bp) in pairs and (b, bp, a, ap) in pairs:
        return f"OK the package declares s{a}:{ap}<->s{b}:{bp}, both directions"
    return f"BAD the package's model does not declare s{a}:{ap}<->s{b}:{bp}"

def v_hosts_clean(path):
    doc = load(path)
    side = doc.get("side_effects")
    if side is None and isinstance(doc.get("heartbeat"), dict):
        side = doc["heartbeat"].get("side_effects")
    if not isinstance(side, dict):
        return "BAD no side_effects counters to read"
    n = side.get("forwarded_to_hosts", 0) or 0
    if n:
        return f"STOP ruling 4: the heartbeat daemon counted {n} frame(s) leaving a host-facing port"
    return (f"OK forwarded_to_hosts 0 (forwarded_between_switches {side.get('forwarded_between_switches', 0)}, "
            f"misdelivered {side.get('misdelivered', 0)}, foreign {side.get('foreign_frames', 0)})")

def v_edges_up(graph, model):
    g, m = load(graph), load(model)
    sw = {n["dpid"] for n in m["nodes"] if n.get("vertex_type") == 0}
    want = sorted({(e["src_dpid"], e["src_interface"], e["dst_dpid"], e["dst_interface"])
                   for e in m["edges"] if e["src_dpid"] in sw and e["dst_dpid"] in sw})
    bad = [f"{d}={edge(g, *d)}" for d in want if edge(g, *d) != (True, True)]
    if not want:
        return "BAD the model declares no inter-switch link"
    if bad:
        return f"BAD {len(want) - len(bad)}/{len(want)} inter-switch directions enabled+up; not: " + "; ".join(bad)
    return f"OK {len(want)}/{len(want)} inter-switch directions is_enabled:true is_up:true"

def v_cut_down(graph, *cut):
    a, ap, b, bp = cut_args(cut)
    g = load(graph)
    f, r = edge(g, a, ap, b, bp), edge(g, b, bp, a, ap)
    if f is not None and r is not None and f[1] is False and r[1] is False:
        return f"OK both directions of s{a}:{ap}<->s{b}:{bp} is_up:false"
    return f"BAD the cut is not down both ways: s{a}:{ap}->s{b}:{bp} {f}, s{b}:{bp}->s{a}:{ap} {r}"

def v_cut_up(graph, *cut):
    a, ap, b, bp = cut_args(cut)
    g = load(graph)
    f, r = edge(g, a, ap, b, bp), edge(g, b, bp, a, ap)
    if f == (True, True) and r == (True, True):
        return f"OK both directions of s{a}:{ap}<->s{b}:{bp} enabled and up"
    return f"BAD the cut is not up both ways: s{a}:{ap}->s{b}:{bp} {f}, s{b}:{bp}->s{a}:{ap} {r}"

def out_ports(directory, dpid):
    p = os.path.join(directory, f"stats_flow_{dpid}.json")
    if not os.path.exists(p):
        return None
    out = {}
    for r in rows_of(p):
        dst = (r.get("match") or {}).get("nw_dst")
        for a in r.get("actions") or []:
            m = re.match(r"OUTPUT:(\d+)$", str(a))
            if dst and m:
                out[dst] = int(m.group(1))
    return out

def v_pick_cut(directory, cables):
    for c in cables.split():
        a, ap, b, bp = (int(x) for x in c.split(":"))
        pa, pb = out_ports(directory, a), out_ports(directory, b)
        if pa is None or pb is None:
            return f"BAD no /stats/flow capture for s{a} or s{b}"
        if ap in pa.values() or bp in pb.values():
            return f"OK {a} {ap} {b} {bp}"
    return "BAD no installed route uses any inter-switch cable -- a cut would prove no reroute"

def v_rerouted(before, after, *cut):
    a, ap, b, bp = cut_args(cut)
    bad = []
    for d, port in ((a, ap), (b, bp)):
        pre, post = out_ports(before, d), out_ports(after, d)
        if pre is None or post is None:
            return f"BAD no /stats/flow capture for s{d}"
        into = sorted(dst for dst, p in post.items() if p == port)
        if into:
            bad.append(f"s{d} still sends {into} out of port {port}")
        if set(pre) - set(post):
            bad.append(f"s{d} lost its route to {sorted(set(pre) - set(post))}")
    used = sum(1 for d, port in ((a, ap), (b, bp)) for p in out_ports(before, d).values() if p == port)
    if not used:
        return f"BAD before the cut no route used s{a}:{ap}<->s{b}:{bp}: nothing to reroute, nothing proven"
    if bad:
        return "BAD " + "; ".join(bad)
    return f"OK no installed route points into s{a}:{ap}<->s{b}:{bp} ({used} did before), every destination kept"

def v_rows_unchanged(before, after):
    def rows(path):
        return sorted(json.dumps([r.get("priority"), r.get("match"), r.get("actions")], sort_keys=True)
                      for r in rows_of(path))
    files = sorted(glob.glob(os.path.join(before, "stats_flow_*.json")))
    bad, total = [], 0
    for f in files:
        g = os.path.join(after, os.path.basename(f))
        x, y = rows(f), (rows(g) if os.path.exists(g) else None)
        total += len(x)
        if x != y:
            bad.append(f"{os.path.basename(f)}: before {len(x)} rows, after {'none' if y is None else len(y)}")
    if not files:
        return "BAD nothing was captured before the cut"
    if bad:
        return "BAD the author's rows changed: " + "; ".join(bad)
    return f"OK {total} rows across {len(files)} switch(es), identical before and after"

def detail_of(body):
    try:
        return load(body).get("detail") or {}
    except (OSError, ValueError, AttributeError):
        return {}

def v_refused_501(code, body):
    c, d = open(code).read().strip(), detail_of(body)
    if c == "501" and d.get("outcome") == "unsupported_on_p4" and d.get("reason") == "unbound":
        return "OK 501 unsupported_on_p4, reason unbound"
    return f"BAD HTTP {c}, outcome {d.get('outcome')!r}, reason {d.get('reason')!r}"

def v_conflict_409(code, body):
    c, d = open(code).read().strip(), detail_of(body)
    if c == "409" and d.get("error") == "external control plane":
        return "OK 409 external control plane"
    return f"BAD HTTP {c}, error {d.get('error')!r} (ruling 5(a) wants 409)"

def v_held_up(polls, n):
    lines = [l for l in open(polls).read().splitlines() if l.strip()]
    bad = [l for l in lines if "  OK " not in l]
    if len(lines) < int(n):
        return f"BAD only {len(lines)} poll(s), want at least {n}"
    if bad:
        return f"BAD the cut went down with the heartbeat stopped ({len(bad)} of {len(lines)} polls): {bad[0]}"
    return f"OK up in all {len(lines)} polls"

def v_elapsed(seconds, bound, what):
    try:
        s = float(seconds)
    except ValueError:
        return f"BAD {what}: never happened ({seconds})"
    if s <= float(bound):
        return f"OK {what} after {s:.1f} s (bound {bound} s)"
    return f"BAD {what} after {s:.1f} s, over the {bound} s bound"

def table(path):
    out = {}
    for line in open(path).read().splitlines()[1:]:
        f = line.split("\t")
        if len(f) >= 4:
            out[(f[0], f[1])] = (f[2], f[3])
    return out

def fnum(x, nd=3):
    return "?" if x is None else f"{x:.{nd}f}"

def v_cycle(state, a_s, a_e, b_s, b_e, off_pre, off_post, l_ab, l_ba, down_wall, timeout, watchdog,
            phi_target, worst):
    """One cut on the monotonic clock (the daemon's and the proxy's). The four tc instants are the
    shell's $EPOCHREALTIME around each end's call, converted with the offset read before the cut;
    the kernel's down is the poll that saw it, converted with the offset read after. The cut
    instant is the FIRST end's call start -- the earliest the cut can have taken effect -- so every
    duration below is the longest it can be. OK carries the row (18 fields, `budget` judges it).
    BAD when a piece is missing, when a pass after the timeout did not report the cut, or when a
    cycle meant for the worst phase did not land there. A frame heard inside a cut window is
    FLAGGED in the row, never dropped."""
    off, off2 = float(off_pre), float(off_post)
    if not (l_ab and l_ba):
        return "BAD no last_heard_mono for both directions of the cable in the report"
    if not down_wall:
        return "BAD the kernel's graph never showed the cut down"
    A_s, A_e, B_s, B_e = (float(x) + off for x in (a_s, a_e, b_s, b_e))
    lab, lba = float(l_ab), float(l_ba)
    l, t, w = max(lab, lba), float(timeout), float(watchdog)
    down = float(down_wall) + off2
    passes = ((load(state).get("heartbeat") or {}).get("watchdog_passes")) or []
    rep = [p for p in passes if (p.get("down") or 0) > 0 and p.get("start_mono", 0) >= l]
    # The pass that made BOTH directions down is the LAST such pass before the graph showed it:
    # when the two directions' last frames are ms apart, a pass between their timeouts reports
    # one and the next pass the other.
    rep = [p for p in rep if p.get("start_mono", 0) <= down]
    if not rep:
        return f"BAD no watchdog pass with a down transition after the last heard frame ({len(passes)} passes served)"
    ps, pe = rep[-1]["start_mono"], rep[-1].get("end_mono")
    i = passes.index(rep[-1])
    prev = passes[i - 1]["start_mono"] if i > 0 else None
    phi = A_s - l
    if worst == "1" and phi > 1.0:
        return (f"BAD meant for the worst phase ({phi_target} s after a round) and landed {phi:.3f} s after "
                f"the last heard frame -- the cut came before that round's send, so this cycle measured a better phase")
    # A pass that started after the timeout judged a silence longer than it (its clock is read
    # after its start) and had to report the cut. 1 ms for the stamps' own rounding.
    if prev is not None and prev > l + t + 0.001:
        return (f"BAD the pass at {prev:.3f} came {prev - (l + t):.3f} s after the timeout and did not report "
                f"the cut; the one at {ps:.3f} did")
    flags = []
    for name, heard, cs, ce in (("a->b", lab, A_s, A_e), ("b->a", lba, B_s, B_e)):
        if heard > ce:
            flags.append(f"{name} heard {1000 * (heard - ce):.1f} ms after its end's tc returned")
        elif heard > cs:
            flags.append(f"{name} heard inside its end's tc window, {1000 * (heard - cs):.1f} ms after the call started")
    if phi < 0:
        flags.append(f"the last frame was heard {-1000 * phi:.1f} ms after the first end's tc started (phi < 0)")
    if prev is None:
        flags.append("no pass before the reporting one was served: its lateness is not measured")
    drift = 1000.0 * (off2 - off)
    if abs(drift) > 2.0:
        flags.append(f"the wall clock moved {drift:+.1f} ms against the monotonic one during the cycle")
    extra = max(0.0, ps - prev - w) if prev is not None else None
    row = [fnum(A_s), fnum(A_e), fnum(B_s), fnum(B_e), fnum(lab), fnum(lba), fnum(phi), fnum(down),
           fnum(down - A_s), fnum(prev), fnum(ps), fnum(pe), fnum(ps - (l + t)), fnum(extra),
           fnum(down - ps), fnum(max(0.0, -phi)), f"{drift:.1f}", "; ".join(flags) or "-"]
    return "OK " + "\t".join(row)

#: [Co-developed with claude code -- Adam] N-4: the part of graph_until's limit above the strict bound.
DETECT_CEILING_EXTRA_S = 15.0

def v_strict(row, bound):
    """A cycle row (v_cycle) against the STRICT bound -- the verdict (the judge's F1). Detection runs
    from the FIRST end's tc call to the poll that saw both directions down: the longest it can be."""
    f = row.split("\t")
    if len(f) != 18:
        return f"BAD the cycle row has {len(f)} fields, not 18"
    d, b = float(f[8]), float(bound)
    if d <= b:
        return f"OK detection {d:.3f} s, within the strict {b:g} s"
    # [Co-developed with claude code -- Adam] The opus judge's N-4 (09-28): "about 20 s" stops at a
    # hard ceiling of the strict bound + DETECT_CEILING_EXTRA_S. graph_until's own limit is the same
    # number but counts whole seconds from its own start, so a slow last poll could record a
    # detection past it -- that is a FAIL here, not a NOTE.
    if d > b + DETECT_CEILING_EXTRA_S:
        return (f"BAD detection {d:.3f} s is past the hard ceiling of {b + DETECT_CEILING_EXTRA_S:g} s "
                f"(the strict {b:g} s + {DETECT_CEILING_EXTRA_S:g} s): a FAIL, not a disclosure")
    # [Co-developed with claude code -- Adam] OVER, not BAD (Adam, 09-27: at most about 20 s): a
    # measurement to disclose, not a failure. A row that cannot be read is still BAD, above.
    return (f"OVER detection {d:.3f} s is OVER the strict {b:g} s by {d - b:.3f} s (from the first end's "
            f"tc call to the graph poll that saw both directions down)")

def v_budget(row, bound):
    """A cycle row (v_cycle) against the bound: OK within `bound`; OK but "OVER the strict" when
    over it by no more than what was measured on top of the design -- the reporting pass's
    lateness beyond one interval, the pass-to-graph time (read, HTTP, kernel, this script's poll)
    and the test's own cut window; BAD beyond that. 🔴 A DIAGNOSTIC, NEVER THE VERDICT (the
    judge's F1 and 4.6): it is OK whenever the design works as designed; v_strict decides."""
    f = row.split("\t")
    if len(f) != 18:
        return f"BAD the cycle row has {len(f)} fields, not 18"
    detect, overhead, window = float(f[8]), float(f[14]), float(f[15])
    extra = 0.0 if f[13] == "?" else float(f[13])
    b = float(bound)
    budget = b + extra + overhead + window
    parts = (f"pass lateness +{extra:.3f}{' (not measured)' if f[13] == '?' else ''}, "
             f"read/HTTP/kernel/poll +{overhead:.3f}, cut window +{window:.3f}")
    if detect <= b:
        return f"OK detection {detect:.3f} s, within the strict {b:g} s ({parts})"
    if detect <= budget:
        return (f"OK detection {detect:.3f} s -- OVER the strict {b:g} s by {detect - b:.3f} s, all of it "
                f"measured on top of the design ({parts}; {b:g} s + that = {budget:.3f} s)")
    return (f"BAD detection {detect:.3f} s -- {detect - budget:.3f} s over {b:g} s + the measured "
            f"{parts} ({budget:.3f} s)")

def v_restore_cycle(state, watch, ra_s, ra_e, rb_s, rb_e, off_pre, off_post, up_wall):
    """One restore on the monotonic clock. The watcher's FIRST new frame per direction is kept
    wherever it falls: inside its own end's restore window it is FLAGGED (the segment-S judge's
    artefact: a frame heard 12.7 ms before a forked t1 was dropped and the next round's taken, a
    false +5 s); before its own end's restore started it is BAD (the cut leaked). Durations run
    from the FIRST end's call start, the longest they can be. OK carries the row (15 fields)."""
    off, off2 = float(off_pre), float(off_post)
    if not up_wall:
        return "BAD the kernel's graph never showed the cable up again"
    W = load(watch)
    first = W.get("first") or {}
    missing = sorted({"ab", "ba"} - set(first))
    if W.get("timed_out") or missing:
        return f"BAD the report watcher saw no new frame for {missing or 'a direction'} within its limit"
    RA_s, RA_e, RB_s, RB_e = (float(x) + off for x in (ra_s, ra_e, rb_s, rb_e))
    up = float(up_wall) + off2
    flags = []
    for name, key, rs, re_ in (("a->b", "ab", RA_s, RA_e), ("b->a", "ba", RB_s, RB_e)):
        h = first[key]["heard"]
        if h < rs:
            return (f"BAD {name} was heard at {h:.3f}, {rs - h:.3f} s before its end's restore started: "
                    f"the cut leaked")
        if h <= re_:
            flags.append(f"{name} heard inside its end's restore window, {1000 * (h - rs):.1f} ms after the call started")
    heard = max(first["ab"]["heard"], first["ba"]["heard"])
    shown = max((first[k].get("written") or first[k]["seen"]) for k in ("ab", "ba"))
    passes = ((load(state).get("heartbeat") or {}).get("watchdog_passes")) or []
    ups = [p for p in passes if (p.get("up") or 0) > 0 and p.get("start_mono", 0) >= shown]
    if not ups:
        return f"BAD no watchdog pass with an up transition after the report showed both directions ({len(passes)} passes served)"
    ps = ups[0]["start_mono"]
    drift = 1000.0 * (off2 - off)
    if abs(drift) > 2.0:
        flags.append(f"the wall clock moved {drift:+.1f} ms against the monotonic one during the restore")
    row = [fnum(RA_s), fnum(RA_e), fnum(RB_s), fnum(RB_e), fnum(first["ab"]["heard"]), fnum(first["ba"]["heard"]),
           fnum(heard - RA_s), fnum(shown - RA_s), fnum(ps), fnum(ps - shown), fnum(up), fnum(up - RA_s),
           fnum(up - ps), f"{drift:.1f}", "; ".join(flags) or "-"]
    return "OK " + "\t".join(row)

def v_same_06(new, old):
    a, b = table(new), table(old)
    if len(b) != 26:
        return f"BAD the reference table has {len(b)} arms, not 26"
    diff = [f"{k[0]}/{k[1]}: {a.get(k)} vs {b[k]}" for k in sorted(b) if a.get(k) != b[k]]
    extra = sorted(set(a) - set(b))
    if diff or extra:
        return f"BAD {len(diff)} arm(s) differ from the reference" + (f", {len(extra)} extra" if extra else "") + ": " + "; ".join(diff[:4])
    return f"OK all 26 arms: rc and verdict identical to the reference"

def arm_windows(tbl, end):
    starts = []
    for line in open(tbl).read().splitlines()[1:]:
        f = line.split("\t")
        m = re.search(r"(\d{4}-\d\d-\d\dT\d{6}Z)_", f[-1]) if len(f) >= 5 else None
        if m:
            import calendar, time
            t = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H%M%SZ"))
            starts.append((t, f"{f[0]}/{f[1]}"))
    starts.sort()
    return [(arm, t, starts[i + 1][0] if i + 1 < len(starts) else float(end))
            for i, (t, arm) in enumerate(starts)]

def samples(path):
    out = []
    for line in open(path).read().splitlines():
        f = line.split("\t")
        if len(f) >= 5 and f[0] != "wall":
            out.append({"t": float(f[0]), "status": f[1], "session": f[2], "hosts": f[4]})
    return out

#: The longest stretch without a sample a sampler that reads every 1 s may leave (load, a slow
#: read) before the stretch counts as NOT MEASURED. [Co-developed with claude code -- Adam]
MAX_SAMPLE_GAP_S = 10.0

def sample_gaps(ss, t0, t1):
    """[(from, to)] of every stretch of [t0, t1) longer than MAX_SAMPLE_GAP_S without a sample --
    the edges included (the opus judge's N2-1: a sampler that stopped reading part-way)."""
    ts = sorted(s["t"] for s in ss if t0 <= s["t"] < t1)
    marks = [t0] + ts + [t1]
    return [(a, b) for a, b in zip(marks, marks[1:]) if b - a > MAX_SAMPLE_GAP_S]

def v_h5_heartbeat(samples_path, tbl, end, expected):
    want = set(expected.split())
    ss = samples(samples_path)
    first = {}
    for s in ss:
        if s["status"] == "running" and s["session"] not in first:
            first[s["session"]] = s["t"]
    bad, had = [], 0
    for arm, t0, t1 in arm_windows(tbl, end):
        new = [x for x, t in first.items() if t0 <= t < t1]
        if arm in want and not new:
            bad.append(f"{arm}: no heartbeat session started")
        if arm not in want and new:
            bad.append(f"{arm}: a heartbeat session started ({new[0]})")
        had += bool(new)
    leak = [s for s in ss if s["hosts"] not in ("0", "", "None")]
    if leak:
        return f"STOP ruling 4: a sample counted forwarded_to_hosts {leak[0]['hosts']} at {leak[0]['t']:.0f}"
    if not ss:
        return "BAD the sampler recorded nothing"
    windows = arm_windows(tbl, end)
    gaps = sample_gaps(ss, windows[0][1], float(end)) if windows else []
    if gaps:
        return (f"BAD the sampler did not read for {len(gaps)} stretch(es) of 06, e.g. {gaps[0][1] - gaps[0][0]:.0f} s "
                f"from {gaps[0][0]:.0f}: a session there was not seen, so the arms there are not measured")
    if bad:
        return f"BAD {len(bad)} arm(s) not as expected: " + "; ".join(bad[:4])
    return f"OK a heartbeat ran on exactly the {had} expected arm(s); no host-port frame in {len(ss)} samples"

def v_no_session(samples_path, t0, t1):
    ss = samples(samples_path)
    new = sorted({s["session"] for s in ss if s["status"] == "running" and float(t0) <= s["t"] < float(t1)})
    if new:
        return f"BAD a heartbeat ran during 01: {new}"
    # [Co-developed with claude code -- Adam] "no session seen" is only a reading where the sampler
    # was reading (the opus judge's N2-1): no sample, or a stretch without one, is not measured.
    gaps = sample_gaps(ss, float(t0), float(t1))
    if gaps:
        return (f"BAD 01's window was not sampled throughout: {gaps[0][1] - gaps[0][0]:.0f} s without a read "
                f"from {gaps[0][0]:.0f}" + (" (no sample at all)" if len(gaps) == 1 and gaps[0] == (float(t0), float(t1)) else ""))
    return "OK no heartbeat session ran during 01 (NDTwin's own pipeline)"

name, args = sys.argv[1], sys.argv[2:]
try:
    print(globals()["v_" + name](*args))
except (OSError, ValueError, KeyError, TypeError) as exc:
    print(f"BAD {name} could not read its input: {type(exc).__name__}: {exc}")
VERDICTS
}

# judge <verdict line> <what> -- OK is a note, STOP (ruling 4) fails at the head, BAD fails.
judge() {
    case "$1" in
        OK*)   note "$2: ${1#OK }" ;;
        STOP*) VERDICT_RC=1; VERDICT_WHY="STOP (ruling 4) -- $2: ${1#STOP }${VERDICT_WHY:+ (first failure before it: $VERDICT_WHY)}"
               bad "$2: $1" ;;
        *)     fail "$2: ${1#BAD }" ;;
    esac
}

# --- the lab: ndt without measuring=, and never a release over a fabric that may be up --------

# w_ndt -- what finish() calls as "$NDT". `down` records its rc (TEARDOWN_DOWN_RC); an rc 3 from a
# run that has already taken its own fabric down is not a failure; `release` releases only after
# a down that answered 0 or 3, and otherwise KEEPS the claim.
w_ndt() {
    local rc
    if [[ "${1:-}" == release ]]; then
        if [[ "$TEARDOWN_DOWN_RC" != 0 && "$TEARDOWN_DOWN_RC" != 3 ]]; then
            keep_claim
            [[ -n "$TEARDOWN_DOWN_RC" ]] && return 0 || return 1
        fi
        env -u NDT_MEASURING "$REAL_NDT" release
        return $?
    fi
    env -u NDT_MEASURING "$REAL_NDT" "$@" && rc=0 || rc=$?
    if [[ "${1:-}" == down ]]; then
        TEARDOWN_DOWN_RC="$rc"
        if (( rc != 0 && rc != 3 )); then
            VERDICT_RC=1
            VERDICT_WHY="NOT RELEASED -- THE LAB STAYS CLAIMED: the teardown's 'ndt down' exited $rc, so a fabric may still be up; see $(basename "$RUN")/90_down.txt${VERDICT_WHY:+ (first failure before it: $VERDICT_WHY)}"
        fi
        if (( rc == 3 && FABRIC_UP == 0 )); then
            echo "08: 'ndt down' answered 3 (nothing was up) -- this run had already taken its own fabric down"
            return 0
        fi
    fi
    return "$rc"
}

# keep_claim -- the teardown's down did not answer 0 or 3: re-claim for an hour with a note that
# says so, print what runs and how to finish. Never releases.
keep_claim() {
    local rule="!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "$rule"
    echo "!! NOT RELEASED. The teardown's 'ndt down' exited ${TEARDOWN_DOWN_RC:-nothing}, so a fabric may"
    echo "!! still be up ($(basename "$RUN")/90_down.txt says why). This run KEEPS its claim:"
    env -u NDT_MEASURING "$REAL_NDT" claim 60 "FABRIC MAY STILL BE UP -- 08_heartbeat: its teardown's ndt down exited ${TEARDOWN_DOWN_RC:-nothing} and it did NOT release; finish by hand: ndt down, then ndt release (raw $(basename "$RUN"))" \
        > "$RUN/91_kept_claim.txt" 2>&1 || echo "!! -- and could NOT re-claim ($(basename "$RUN")/91_kept_claim.txt)"
    env -u NDT_MEASURING "$REAL_NDT" status > "$RUN/92_status_kept.txt" 2>&1 || true
    sed -n '/^running/,/^$/p' "$RUN/92_status_kept.txt" | sed '/^$/d; s/^/!!   /'
    echo "!! finish it by hand, in this order, once you have read 90_down.txt:"
    printf '!!     NDT_OWNER=%q %q down\n' "$NDT_OWNER" "$REAL_NDT"
    printf '!!     NDT_OWNER=%q %q release\n' "$NDT_OWNER" "$REAL_NDT"
    echo "$rule"
}

# w_finish -- the EXIT trap: netem this run added comes off FIRST, then the H5 sampler stops, then
# any strict tally still open is concluded, then _common.sh's finish() (ndt down, knobs back,
# release through w_ndt, verdict).
w_finish() {
    local rc=$?
    set +e
    trap - EXIT INT TERM
    if (( ${#INJECTED_IFACES[@]} > 0 )); then
        # Read before the revert: faults.sh's revert empties the list whatever happened, and the
        # failure line below used to name nothing (the spike's round-7 note).
        local left="${INJECTED_IFACES[*]}"
        note "removing the netem this run added: $left"
        revert_link_loss || fail "could NOT remove the netem on $left -- remove it by hand before anything else runs"
    fi
    restore_watch_stop
    sampler_stop
    # [Co-developed with claude code -- Adam] The opus judge's F1 (09-27): an exit inside H1's loop
    # or H3 (a cut_cycle or restore_cycle that stopped the run, INT, TERM) comes here before that
    # phase's strict_conclude ran, and finish() prints only what is already disclosed -- so an
    # over-cycle measured before the exit would have stayed in the body. Concluded here, just
    # before finish (the AEG judge's N-3, 09-28: after the netem is off, as the header says).
    if (( ${STRICT_CYCLES:-0} > 0 )); then
        strict_conclude "${STRICT_PHASE:-H1}, cut short"
    fi
    NDT=w_ndt
    ( exit "$rc" )
    finish
}

# [Co-developed with claude code -- Adam] The AEG judge's N-1 (09-28): INT and TERM get traps of
# their own -- _common.sh's `interrupted`, the same one start_step arms before this line runs (the
# external judge's M3: the window between start_step and here used to print PASS on a TERM). A
# signal is recorded as the run's failure and the exit code is the signal's -- 130 / 143, carried
# through finish (SIGNAL_RC); the EXIT trap then tears down as always.
arm_traps() { trap w_finish EXIT; trap 'interrupted SIGINT 130' INT; trap 'interrupted SIGTERM 143' TERM; }

# nd_up <pkg> <out> / nd_down <out> -- the run's own bring-ups and teardowns, never under measuring=.
nd_up() {
    local rc
    env -u NDT_MEASURING "$REAL_NDT" up p4 --app "$1" > "$2" 2>&1 && rc=0 || rc=$?
    (( rc == 0 )) && FABRIC_UP=1
    return "$rc"
}
nd_down() {
    local rc
    env -u NDT_MEASURING "$REAL_NDT" down > "$1" 2>&1 && rc=0 || rc=$?
    (( rc == 0 || rc == 3 )) && FABRIC_UP=0
    return "$rc"
}
# phase_down <out> <what> -- 0: the next phase may start. 1: it must not (recorded here).
phase_down() {
    local rc
    nd_down "$1" && rc=0 || rc=$?
    note "ndt down ($2): rc $rc -> $(basename "$1")"
    (( rc == 0 || rc == 3 )) && return 0
    fail "'ndt down' after $2 exited $rc -- the run STOPS here: that fabric may still be up, and the next 'ndt up p4 --app' would reuse it"
    return 1
}

# identity_gate <controls' identity.json> <B sha> <out identity.json> -- record this checkout's identity
# into <out> and check it is the controls' plus B (live-p1/code_identity.py verify): its rc, 0 or not.
identity_gate() {
    [[ -n "$2" ]] || { echo "REFUSED C_IDENTITY is set but B_SHA is not: which B was merged must be named"; return 3; }
    "$VPY" "$LIVE_DIR/code_identity.py" record "$REPO" "$3" || return 2
    "$VPY" "$LIVE_DIR/code_identity.py" verify "$1" "$3" "$2"
}

# --- the heartbeat report sampler (H5) ---------------------------------------------------------
# One line per read: wall, status, session, pid, forwarded_to_hosts, forwarded_between_switches.
# It stops itself when SAMPLER_STOP appears (or after 5 h), taking ONE LAST sample first -- so the
# daemon's final `stopped` rewrite is on record however the timing falls; sampler_stop waits for
# that, and only then signals -- by the pid it started, after checking that pid is still this
# sampler.
#
# [Co-developed with claude code -- Adam] 🔴 LIVE H5 ON cafd518a (09-26 15:32Z) NEVER SAMPLED: the
# program wrote f"...{d.get(\"status\")}..." -- a backslash inside an f-string's expression, a
# SyntaxError on this machine's Python 3.13 -- its stderr went to /dev/null, and sampler_start
# never looked whether it lived. So now: the program is a QUOTED HEREDOC (either quote may appear in
# it, and nothing in it is expanded by bash), its rows are joined from plain values (no f-string
# holds an expression with quotes in it, on any Python), its stderr is a file in $RUN, and
# sampler_start waits for the header and a live pid or FAILS the run before 06 starts. The
# self-test executes this text (st_sampler).
# [Co-developed with claude code -- Adam] (the round-4 review's M-3) Since round 5 two more fields:
# `heard` -- every direction of the report as "<tx dpid>:<port>><rx dpid>:<port>=<heard>", joined by
# commas ("-" with no report) -- and `controllers`, the pids of every process alive at that read
# whose argv runs tools/p4_exercise/run_external_controller.py (the exercises' controllers; "-"
# for none), read from /proc. external_evidence.py refuses an external arm whose session did not
# hear every direction while its controller ran: a daemon that runs and hears nothing is no
# treatment.
SAMPLER_HEADER=$'wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\twritten_wall\tstop_reason\tmisdelivered\tforeign_frames\theard\tcontrollers'
SAMPLER_PY="$(cat <<'SAMPLER'
import json, os, sys, time
report, out, stop = sys.argv[1], sys.argv[2], sys.argv[3]
interval = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
end = time.time() + 5 * 3600
HEADER = ("wall", "status", "session", "pid", "forwarded_to_hosts", "forwarded_between_switches",
          "written_wall", "stop_reason", "misdelivered", "foreign_frames", "heard", "controllers")
CONTROLLER = b"run_external_controller.py"


def controllers():
    pids = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/" + pid + "/cmdline", "rb") as fh:
                argv = fh.read().split(b"\0")
        except OSError:
            continue
        if any(a == CONTROLLER or a.endswith(b"/" + CONTROLLER) for a in argv):
            pids.append(int(pid))
    return ",".join(str(p) for p in sorted(pids)) or "-"


def heard(d):
    out = []
    for r in d.get("directions") or []:
        tx, rx = r.get("tx") or {}, r.get("rx") or {}
        out.append("%s:%s>%s:%s=%s" % (tx.get("dpid"), tx.get("port"), rx.get("dpid"), rx.get("port"),
                                       r.get("heard")))
    return ",".join(out) or "-"


def row(fh):
    wall = "%.1f" % time.time()
    try:
        with open(report) as rf:
            d = json.load(rf)
        se = d.get("side_effects") or {}
        values = (wall, d.get("status"), d.get("session"), d.get("pid"),
                  se.get("forwarded_to_hosts"), se.get("forwarded_between_switches"),
                  d.get("written_wall"), d.get("stop_reason") or "",
                  se.get("misdelivered"), se.get("foreign_frames"), heard(d))
    except (OSError, ValueError, AttributeError):
        values = (wall, "absent", "-", "-", 0, 0, "-", "", 0, 0, "-")
    fh.write("\t".join(str(v) for v in values + (controllers(),)) + "\n")


with open(out, "a", buffering=1) as fh:
    fh.write("\t".join(HEADER) + "\n")
    while time.time() < end and not os.path.exists(stop):
        row(fh)
        time.sleep(interval)
    row(fh)
SAMPLER
)"
# sampler_start <out.tsv> -- 0 once the sampler has written its header and is alive; otherwise
# `fail` with what it said (its stderr is $RUN/50_sampler.err) and 1: the caller must not go on.
sampler_start() {
    local out="$1" i
    SAMPLER_OUT="$out"
    SAMPLER_STOP="$RUN/.sampler.stop"
    SAMPLER_ERR="$RUN/50_sampler.err"
    rm -f "$SAMPLER_STOP"
    setsid "$VPY" -I -c "$SAMPLER_PY" "$HB_REPORT_FILE" "$out" "$SAMPLER_STOP" "${SAMPLER_INTERVAL_S:-1.0}" \
        > /dev/null 2> "$SAMPLER_ERR" &
    SAMPLER_PID=$!
    for (( i = 0; i < 50; i++ )); do
        if [[ "$(head -1 "$out" 2>/dev/null)" == "$SAMPLER_HEADER" ]] && kill -0 "$SAMPLER_PID" 2>/dev/null; then
            note "report sampler pid $SAMPLER_PID -> $(basename "$out") (header written, alive)"
            return 0
        fi
        kill -0 "$SAMPLER_PID" 2>/dev/null || break
        sleep 0.1
    done
    fail "H5: the report sampler did not start (pid $SAMPLER_PID $(kill -0 "$SAMPLER_PID" 2>/dev/null && echo 'alive, no header in 5 s' || echo 'exited')): $(head -c 300 "$SAMPLER_ERR" 2>/dev/null | tr '\n' ' ')"
    sampler_stop
    return 1
}
# [Co-developed with claude code -- Adam] The opus judge's N2-1 on f4f43a32: a sampler that died
# after a good start ends the run FAIL -- checked BEFORE the stop file is written (a sampler
# killed by a signal leaves no stderr), by pid AND argv (a reaped pid can be reused) -- and so
# does a sampler that wrote to its stderr (`fail`, not `bad`: `bad` only prints).
sampler_alive() {
    [[ -n "$SAMPLER_PID" ]] && kill -0 "$SAMPLER_PID" 2>/dev/null \
        && tr '\0' ' ' < "/proc/$SAMPLER_PID/cmdline" 2>/dev/null | /usr/bin/grep -qF "$SAMPLER_STOP"
}
sampler_stop() {
    [[ -n "$SAMPLER_PID" ]] || return 0
    # (it also exits by itself after 5 h -- far longer than H5 -- which is still a run it did not sample to the end)
    if ! sampler_alive; then
        local said=""
        [[ -s "${SAMPLER_ERR:-}" ]] && said="; its stderr: $(head -c 200 "$SAMPLER_ERR" | tr '\n' ' ')"
        fail "H5: the report sampler (pid $SAMPLER_PID) was not running when the run came to stop it -- its samples end early (the last row of $(basename "${SAMPLER_OUT:-50_samples.tsv}") says when)$said"
    fi
    : > "$SAMPLER_STOP"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SAMPLER_PID" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$SAMPLER_PID" 2>/dev/null \
       && tr '\0' ' ' < "/proc/$SAMPLER_PID/cmdline" 2>/dev/null | /usr/bin/grep -qF "$SAMPLER_STOP"; then
        kill "$SAMPLER_PID" 2>/dev/null || true
    fi
    [[ -s "${SAMPLER_ERR:-}" ]] && fail "H5: the report sampler wrote to its stderr: $(head -c 300 "$SAMPLER_ERR" | tr '\n' ' ')"
    SAMPLER_PID=""
}

# --- captures and the cut -----------------------------------------------------------------------

post_json() {   # post_json <url> <body> <out-prefix> -- body to .json, code to .code; never fails
    curl -s --max-time 15 -o "$3.json" -w '%{http_code}\n' -X POST \
        -H 'Content-Type: application/json' -d "$2" "$1" > "$3.code" 2> "$3.curl.err" || true
}

# graph_until <seconds> <poll-interval> <verdict> <out> [args...] -- get_graph_data every
# <poll-interval> s until the verdict reads OK or the time is up; every attempt's verdict goes to
# <out>.polls. Prints the last verdict. 🔴 The TIMING goes to files, not to variables: callers run
# this inside `$(...)`, a subshell, and a variable set in one never reaches the caller (the
# TOPO_REFUSAL lesson in ndt's up_p4). <out>.elapsed is the seconds from T_CUT (the last cut or
# restore) to the first OK poll, or "never"; <out>.at_wall is that poll's wall clock when its
# reply was in, <out>.at_wall_start when it was asked -- the graph changed before the first.
# [Co-developed with claude code -- Adam] $EPOCHREALTIME, read in this shell: no forked `date`.
graph_until() {
    local limit="$1" every="$2" fn="$3" out="$4" t0 v now asked
    shift 4
    t0="$EPOCHREALTIME"
    : > "$out.polls"
    echo never > "$out.elapsed"; : > "$out.at_wall"; : > "$out.at_wall_start"
    while :; do
        asked="$EPOCHREALTIME"
        curl -s --max-time 5 "$KERNEL_URL/ndt/get_graph_data" > "$out" 2> /dev/null || true
        now="$EPOCHREALTIME"
        v="$( [[ -s "$out" ]] && verdict "$fn" "$out" "$@" || echo "BAD no get_graph_data capture" )"
        printf '%7.2f  %s\n' "$(awk -v a="$t0" -v b="$now" 'BEGIN{print b-a}')" "$v" >> "$out.polls"
        if [[ "$v" == OK* ]]; then
            # ${T_CUT:-}: a poll before any cut (edges_up) has no instant to count from. Under
            # set -u a bare $T_CUT killed this subshell there, and the caller judged an empty
            # verdict -- H1's very first check would have failed on a healthy fabric.
            if [[ -n "${T_CUT:-}" ]]; then
                awk -v a="$T_CUT" -v b="$now" 'BEGIN{printf "%.2f\n", b-a}' > "$out.elapsed"
            else
                echo "n/a" > "$out.elapsed"
            fi
            echo "$now" > "$out.at_wall"
            echo "$asked" > "$out.at_wall_start"
            break
        fi
        (( ${now%.*} - ${t0%.*} >= limit )) && break
        sleep "$every"
    done
    printf '%s\n' "$v"
}

# --- the cut's PHASE (orchestrator, 09-26, on segment S's judge report, Blocking 1) ------------
#
# 🔴 A PHASE-LOCKED H1 PROVES NOTHING ABOUT THE WORST PHASE. The spike cut ~0.7 s after a heard
# frame every time. Detection at the kernel is (timeout - phi) + psi + the report read, the
# kernel's HTTP and this script's poll, where phi is how long after the cable's last heard frame
# the cut lands and psi is how long after "silent for LINK_BEACON_TIMEOUT_S" the next watchdog
# pass runs. phi -> 0 is the worst case (a full timeout of silence still to come); psi is up to
# one watchdog interval and is NOT under this script's control (the watchdog runs `wait(5)` then
# a pass, on the proxy's own clock). So: the first H1_WORST cycles cut right after a round
# (PHI_WORST s), the rest at a uniformly random phase (seed recorded), and every cycle records
# the phase it actually got and the watchdog phase that followed.
#
# The daemon's rounds are periodic (`next_round += PERIOD_S`), and a direction's last_heard_mono
# is its round's send time to within the veth's microseconds, so the rounds ahead are predicted
# from the report. Both are CLOCK_MONOTONIC.
mono() { "$VPY" -I -c 'import time; print(f"{time.monotonic():.3f}")'; }
mono_offset() { "$VPY" -I -c 'import time; print(f"{time.monotonic() - time.time():.6f}")'; }
sleep_until_mono() { "$VPY" -I -c 'import sys, time; time.sleep(max(0.0, float(sys.argv[1]) - time.monotonic()))' "$1"; }
# report_last <a> <ap> <b> <bp> -- the LATER last_heard_mono of the cable's two directions, or "".
report_last() {
    "$VPY" -I - "$HB_REPORT_FILE" "$@" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(0)
a, ap, b, bp = (int(x) for x in sys.argv[2:6])
want = {(a, ap, b, bp), (b, bp, a, ap)}
ts = [r.get("last_heard_mono") for r in d.get("directions", [])
      if (r["tx"]["dpid"], r["tx"]["port"], r["rx"]["dpid"], r["rx"]["port"]) in want]
if len(ts) == 2 and all(isinstance(t, (int, float)) for t in ts):
    print(f"{max(ts):.3f}")
PY
}
# report_dirs <a> <ap> <b> <bp> -- "<last_heard a->b> <last_heard b->a>" (6 decimals), or "".
report_dirs() {
    "$VPY" -I - "$HB_REPORT_FILE" "$@" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(0)
a, ap, b, bp = (int(x) for x in sys.argv[2:6])
got = {(r["tx"]["dpid"], r["tx"]["port"], r["rx"]["dpid"], r["rx"]["port"]): r.get("last_heard_mono")
       for r in d.get("directions", [])}
ab, ba = got.get((a, ap, b, bp)), got.get((b, bp, a, ap))
if all(isinstance(t, (int, float)) for t in (ab, ba)):
    print(f"{ab:.6f} {ba:.6f}")
PY
}
# next_phase_target <last> <phi> <period> [now] -- the first `last + k*period + phi` at least 0.3 s
# from now (k >= 1).
next_phase_target() {
    "$VPY" -I -c 'import math, sys, time
last, phi, p = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
now = float(sys.argv[4]) if len(sys.argv) > 4 else time.monotonic()
k = max(1, math.ceil((now + 0.3 - last - phi) / p))
print(f"{last + k * p + phi:.3f}")' "$@"
}
# cut_at_phase <phi> <a> <ap> <b> <bp> -- cut <phi> s after one of the heartbeat's rounds.
# Leaves CUT_TARGET (the planned instant) and cut_link's CUT_A_*/CUT_B_* in this shell.
cut_at_phase() {
    local phi="$1" last
    shift
    last="$(report_last "$@")"
    [[ -n "$last" ]] || { fail "the report has no last_heard for s$1:$2<->s$3:$4 -- cannot place the cut"; return 1; }
    CUT_TARGET="$(next_phase_target "$last" "$phi" "$HB_PERIOD_S")"
    cut_link "$@" "$CUT_TARGET"
}
# phase_for <cycle> -- PHI_WORST for the first H1_WORST cycles, then uniform in (PHI_WORST, period).
phase_for() {
    if (( $1 <= H1_WORST )); then echo "$PHI_WORST"; return; fi
    awk -v r="$RANDOM" -v lo="$PHI_WORST" -v p="$HB_PERIOD_S" 'BEGIN{printf "%.2f\n", lo + (r / 32767) * (p - 2 * lo)}'
}


# state_until <seconds> <out> <verdict> [args...] -- switch_state every 2 s until the verdict is OK.
state_until() {
    local limit="$1" out="$2" fn="$3" deadline v
    shift 3
    deadline=$(( $(date +%s) + limit ))
    while :; do
        get_json "$PROXY_URL/p4/switch_state" "$out" > /dev/null 2>&1 || true
        v="$( [[ -s "$out" ]] && verdict "$fn" "$out" "$@" || echo "BAD no switch_state" )"
        [[ "$v" == OK* ]] && break
        (( $(date +%s) >= deadline )) && break
        sleep 2
    done
    printf '%s\n' "$v"
}

stats_flows() {   # stats_flows <dir> -- /stats/flow/<dpid> for s1-s4
    mkdir -p "$1"
    local d
    for d in 1 2 3 4; do get_json "$PROXY_URL/stats/flow/$d" "$1/stats_flow_$d.json" || true; done
}

# cut_link <a> <ap> <b> <bp> [<target mono>] -- netem loss 100% on both ends (faults.sh's htb-safe
# attach point), end A first. Both attach points are read BEFORE the optional sleep until <target>,
# so the first tc call starts at the planned instant with nothing in between. Each end's instants
# are $EPOCHREALTIME just before and just after its call -- read in THIS shell, not by a forked
# `date` that lands after tc has returned (orchestrator 09-26): tc took effect inside that window.
# A cut refused on its second end comes off the first HERE, while the veth still exists.
# [Co-developed with claude code -- Adam]
cut_link() {
    local devs=("s$1-eth$2" "s$3-eth$4") where=() i t0 t1
    CUT_A_START=""; CUT_A_END=""; CUT_B_START=""; CUT_B_END=""
    for i in 0 1; do
        where[i]="$(netem_attach_point "${devs[i]}")" || true
        if [[ "${where[i]}" == unsafe ]]; then
            fail "no safe netem attach point on ${devs[i]} (netem already there, or the tree is unreadable)"
            return 1
        fi
    done
    [[ -z "${5:-}" ]] || sleep_until_mono "$5"
    for i in 0 1; do
        t0="$EPOCHREALTIME"
        # shellcheck disable=SC2086 -- "parent H:D" is two words on purpose
        if ! run_tc qdisc add dev "${devs[i]}" ${where[i]} netem loss 100%; then
            fail "tc refused to add netem on ${devs[i]} (${where[i]})"
            restore_link || true
            return 1
        fi
        t1="$EPOCHREALTIME"
        INJECTED_IFACES+=("${devs[i]}")
        if (( i == 0 )); then CUT_A_START="$t0"; CUT_A_END="$t1"; else CUT_B_START="$t0"; CUT_B_END="$t1"; fi
    done
    T_CUT="$EPOCHREALTIME"
}
# restore_link -- the netem off, one end at a time in the order it went on, each end's instants
# $EPOCHREALTIME around its own revert (RESTORE_A_*, RESTORE_B_*). An end that could not be cleaned
# STAYS in INJECTED_IFACES for w_finish -- faults.sh's revert empties the list whatever happened.
restore_link() {
    local all=("${INJECTED_IFACES[@]}") left=() dev rc=0 i=0 t0 t1
    RESTORE_A_START=""; RESTORE_A_END=""; RESTORE_B_START=""; RESTORE_B_END=""
    for dev in "${all[@]}"; do
        [[ -n "$dev" ]] || continue
        INJECTED_IFACES=("$dev")
        t0="$EPOCHREALTIME"
        revert_link_loss || { rc=1; left+=("$dev"); }
        t1="$EPOCHREALTIME"
        if (( i == 0 )); then RESTORE_A_START="$t0"; RESTORE_A_END="$t1"; else RESTORE_B_START="$t0"; RESTORE_B_END="$t1"; fi
        i=$(( i + 1 ))
    done
    INJECTED_IFACES=("${left[@]}")
    T_CUT="$EPOCHREALTIME"
    return "$rc"
}

# restore_watch_start <out> <a> <ap> <b> <bp> -- a watcher of the report, in the background, that
# records for each direction of the cable the FIRST new frame after it started (last_heard_mono
# moving): its last_heard_mono, when the watcher saw it (CLOCK_MONOTONIC) and the report's
# written_mono. It keeps every frame -- where it falls against the restore windows is the
# verdict's to flag -- and exits by itself after RESTORE_WATCH_S. Returns once it has read the
# report the first time (1 if it never did).
restore_watch_start() {
    local out="$1" i
    shift
    rm -f "$out" "$out.ready"
    RESTORE_WATCH_OUT="$out"
    "$VPY" -I - "$HB_REPORT_FILE" "$out" "$RESTORE_WATCH_S" "$@" <<'PY' &
import json, sys, time
path, out, limit = sys.argv[1], sys.argv[2], float(sys.argv[3])
a, ap, b, bp = (int(x) for x in sys.argv[4:8])
keys = {"ab": (a, ap, b, bp), "ba": (b, bp, a, ap)}
def read():
    try:
        d = json.load(open(path))
    except (OSError, ValueError):
        return None, None
    got = {}
    for r in d.get("directions", []):
        k = (r["tx"]["dpid"], r["tx"]["port"], r["rx"]["dpid"], r["rx"]["port"])
        for name, want in keys.items():
            if k == want:
                got[name] = r.get("last_heard_mono")
    return got, d.get("written_mono")
start = time.monotonic()
init = None
while time.monotonic() - start < 1.0:
    init, _ = read()
    if init is not None and len(init) == 2:
        break
    time.sleep(0.02)
result = {"start_mono": start, "initial": init, "first": {}, "timed_out": False}
if init is None or len(init) != 2:
    result.update(timed_out=True, error="the report did not name both directions")
    json.dump(result, open(out, "w"))
    sys.exit(0)
open(out + ".ready", "w").close()
while time.monotonic() - start < limit and len(result["first"]) < 2:
    got, written = read()
    now = time.monotonic()
    for name in ("ab", "ba"):
        h = (got or {}).get(name)
        if name not in result["first"] and isinstance(h, (int, float)) and h != init.get(name):
            result["first"][name] = {"heard": h, "seen": now, "written": written}
    time.sleep(0.02)
result["timed_out"] = len(result["first"]) < 2
result["end_mono"] = time.monotonic()
json.dump(result, open(out, "w"))
PY
    RESTORE_WATCH_PID=$!
    for (( i = 0; i < 40; i++ )); do
        [[ -e "$out.ready" ]] && return 0
        [[ -s "$out" ]] && return 1
        sleep 0.05
    done
    return 1
}
# restore_watch_wait -- until the watcher has written its answer (bounded by its own limit).
restore_watch_wait() {
    [[ -n "$RESTORE_WATCH_PID" ]] || return 0
    wait "$RESTORE_WATCH_PID" 2>/dev/null || true
    RESTORE_WATCH_PID=""
}
# restore_watch_stop -- w_finish's: a watcher still running is ours only if its argv names its file.
restore_watch_stop() {
    [[ -n "$RESTORE_WATCH_PID" ]] || return 0
    if kill -0 "$RESTORE_WATCH_PID" 2>/dev/null \
       && tr '\0' ' ' < "/proc/$RESTORE_WATCH_PID/cmdline" 2>/dev/null | /usr/bin/grep -qF "$RESTORE_WATCH_OUT"; then
        kill "$RESTORE_WATCH_PID" 2>/dev/null || true
    fi
    RESTORE_WATCH_PID=""
}

# cut_cycle <label> <graph-out> <state-out> <phi> <worst 0|1> -- cut the chosen cable <phi> s after
# a heartbeat round, wait for the kernel's graph to show both directions down, then record the cut
# on the monotonic clock (v_cycle) and judge it (v_budget). Leaves the 18-field row in CYCLE_ROW
# ("?" where it could not be recorded) and "yes" / "OVER+<s>" / "?" in CYCLE_STRICT. Returns 1
# only when the cut could not be made (the caller stops: the fabric may be half cut).
cut_cycle() {
    local label="$1" gout="$2" sout="$3" phi="$4" worst="$5" off_pre off_post v row lab="" lba="" det sv
    off_pre="$(mono_offset)"
    cut_at_phase "$phi" "$CA" "$CAP" "$CB" "$CBP" || return 1
    v="$(graph_until $(( DETECT_BOUND_S + 15 )) 0.2 cut_down "$gout" "$CA" "$CAP" "$CB" "$CBP")"
    off_post="$(mono_offset)"
    judge "$v" "$label detection"
    read -r lab lba <<<"$(report_dirs "$CA" "$CAP" "$CB" "$CBP")" || true
    get_json "$PROXY_URL/p4/switch_state" "$sout" > /dev/null 2>&1 || true
    row="$(verdict cycle "$sout" "$CUT_A_START" "$CUT_A_END" "$CUT_B_START" "$CUT_B_END" "$off_pre" "$off_post" \
           "$lab" "$lba" "$(cat "$gout.at_wall")" "$TIMEOUT_S" "$WATCHDOG_S" "$phi" "$worst")"
    judge "$row" "$label phase record"
    det="$(cat "$gout.elapsed")"
    if [[ "$row" == OK* ]]; then
        CYCLE_ROW="${row#OK }"
        # [Co-developed with claude code -- Adam] The judge's F1: the strict bound is the one
        # measured against; the budget is printed beside it and decides nothing. Adam's ruling
        # (09-27): a cycle OVER it is disclosed, verbatim, not failed -- strict_conclude repeats
        # this line above the run's last one. A row it cannot read is still a BAD.
        sv="$(verdict strict "$CYCLE_ROW" "$DETECT_BOUND_S")"
        if [[ "$sv" == OVER* ]]; then
            note "$label detection time (disclosed, not a failure): ${sv#OVER }"
            STRICT_OVER_LIST="${STRICT_OVER_LIST:+$STRICT_OVER_LIST; }$label: ${sv#OVER }"
        else
            judge "$sv" "$label detection time"
        fi
        note "$label budget, $DETECT_BOUND_S s + what was measured (a diagnostic, never the verdict): $(verdict budget "$CYCLE_ROW" "$DETECT_BOUND_S")"
        CYCLE_STRICT="$(awk -F'\t' -v b="$DETECT_BOUND_S" '{ if ($9 <= b) print "yes"; else printf "OVER+%.3f\n", $9 - b }' <<<"$CYCLE_ROW")"
        STRICT_CYCLES=$(( STRICT_CYCLES + 1 ))
        STRICT_PHASE="${label%% *}"
        [[ "$CYCLE_STRICT" == OVER* ]] && STRICT_OVER=$(( STRICT_OVER + 1 ))
        [[ "$(cut -f18 <<<"$CYCLE_ROW")" == - ]] || note "$label flags: $(cut -f18 <<<"$CYCLE_ROW")"
    else
        CYCLE_ROW="$(printf '?\t%.0s' $(seq 17))?"
        CYCLE_STRICT="?"
        judge "$(verdict elapsed "$det" "$DETECT_BOUND_S" "both directions is_up:false (no phase record: the graph poll alone, from the last tc's return)")" "$label detection time"
    fi
    return 0
}

# strict_conclude <what> -- the strict bound over the cycles cut_cycle recorded since the last
# conclusion. [Co-developed with claude code -- Adam] 🔴 ADAM'S RULING (09-27): at most ABOUT 20 s,
# the class of NDTwin's own LLDP. A cycle OVER the strict bound is DISCLOSED, not failed: the count
# and every over-cycle's own strict line, verbatim, go to _common.sh's `disclose`, which prints them
# just above the run's last line -- where a PASS, an earlier failure or a ruling-4 STOP stays the
# last line itself. (It used to FAIL <what> with the count at the head of that line: the fable
# judge's F1, 09-26, before the ruling.) The tally is reset.
strict_conclude() {
    local what="$1" n="$STRICT_CYCLES" over="$STRICT_OVER" list="$STRICT_OVER_LIST"
    local psi="one run samples one psi (watchdog_phase_s in 30_cycles.tsv): the worst psi is not guaranteed to have been sampled"
    STRICT_CYCLES=0; STRICT_OVER=0; STRICT_OVER_LIST=""; STRICT_PHASE=""
    if (( over > 0 )); then
        disclose "$what: $over of $n cycle(s) over the strict ${DETECT_BOUND_S} s -- disclosed, not a failure (Adam, 09-27: at most about ${DETECT_BOUND_S} s, the class of NDTwin's own LLDP; strict_${DETECT_BOUND_S}s in 30_cycles.tsv) -- $list"
        note "$psi"
    else
        note "$what: all $n cycle(s) within the strict ${DETECT_BOUND_S} s -- $psi"
    fi
}

# restore_cycle <label> <graph-out> <state-out> <watch-out> -- the netem off with the report watcher
# running from just before, until the kernel's graph shows both directions up; then the restore is
# recorded (v_restore_cycle) and judged against RESTORE_BOUND_S. Leaves the 15-field row in
# RESTORE_ROW. Returns 1 only when the netem could not be removed.
restore_cycle() {
    local label="$1" gout="$2" sout="$3" wout="$4" off_pre off_post v row res
    restore_watch_start "$wout" "$CA" "$CAP" "$CB" "$CBP" \
        || note "$label: the report watcher did not read the report (its restore record will say so)"
    off_pre="$(mono_offset)"
    if ! restore_link; then
        restore_watch_wait
        return 1
    fi
    v="$(graph_until $(( RESTORE_BOUND_S + 15 )) 0.2 cut_up "$gout" "$CA" "$CAP" "$CB" "$CBP")"
    off_post="$(mono_offset)"
    judge "$v" "$label recovery"
    restore_watch_wait
    get_json "$PROXY_URL/p4/switch_state" "$sout" > /dev/null 2>&1 || true
    row="$( [[ -s "$wout" ]] && verdict restore_cycle "$sout" "$wout" "$RESTORE_A_START" "$RESTORE_A_END" \
            "$RESTORE_B_START" "$RESTORE_B_END" "$off_pre" "$off_post" "$(cat "$gout.at_wall")" \
            || echo "BAD the report watcher wrote nothing" )"
    judge "$row" "$label restore record"
    if [[ "$row" == OK* ]]; then
        RESTORE_ROW="${row#OK }"
        res="$(cut -f12 <<<"$RESTORE_ROW")"
        [[ "$(cut -f15 <<<"$RESTORE_ROW")" == - ]] || note "$label restore flags: $(cut -f15 <<<"$RESTORE_ROW")"
    else
        RESTORE_ROW="$(printf '?\t%.0s' $(seq 14))?"
        res="$(cat "$gout.elapsed")"
    fi
    judge "$(verdict elapsed "$res" "$RESTORE_BOUND_S" "both directions is_up:true again")" "$label recovery time"
    return 0
}
tc_ends() {   # tc_ends <prefix> <a> <ap> <b> <bp>
    show_qdisc "s$2-eth$3" > "$1_s$2-eth$3.txt" 2>&1 || true
    show_qdisc "s$4-eth$5" > "$1_s$4-eth$5.txt" 2>&1 || true
}
no_netem() {
    local f n=0
    for f in "$@"; do
        [[ -s "$f" ]] || { echo "BAD no tc capture at $(basename "$f")"; return 0; }
        /usr/bin/grep -q netem "$f" && n=$((n+1))
    done
    (( n == 0 )) && echo "OK no netem on either end" || echo "BAD netem is still attached on $n end(s)"
}
hb_status() {   # hb_status <out> -- the helper's own answer, rc passed through
    local rc
    sudo -n "$LAB_HELPER" heartbeat status > "$1" 2>&1 && rc=0 || rc=$?
    return "$rc"
}

# --- the self-test -------------------------------------------------------------------------------

self_test() {
    local t rc=0 got d
    t="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-08-selftest-XXXXXX")"
    trap 'rm -rf "$t"' RETURN
    ok()  { printf '  ok    %s\n' "$1"; }
    red() { printf '  🔴    %s\n' "$1"; rc=1; }
    expect() {   # expect <OK|BAD|STOP> <label> <verdict line>
        if [[ "$3" == "$1"* ]]; then printf '  ok    %-60s %s\n' "$2" "${3:0:70}"
        else printf '  🔴    %-60s wanted %s, got: %s\n' "$2" "$1" "$3"; rc=1; fi
    }
    "$VPY" -I - "$t" <<'PY'
import copy, json, os, sys
t = sys.argv[1]
def dump(name, obj):
    with open(os.path.join(t, name), "w") as fh:
        json.dump(obj, fh)
cables = [(1, 3, 3, 1), (1, 4, 4, 2), (2, 3, 4, 1), (2, 4, 3, 2)]
dirs = cables + [(d, dp, s, sp) for s, sp, d, dp in cables]
dump("model.json", {"nodes": [{"dpid": d, "vertex_type": 0} for d in (1, 2, 3, 4)] + [{"dpid": 0, "vertex_type": 1}],
                    "edges": [{"src_dpid": s, "src_interface": sp, "dst_dpid": d, "dst_interface": dp} for s, sp, d, dp in dirs]
                    + [{"src_dpid": 1, "src_interface": 1, "dst_dpid": 0, "dst_interface": 1}]})
up = {"edges": [{"src_dpid": s, "src_interface": sp, "dst_dpid": d, "dst_interface": dp, "is_enabled": True, "is_up": True}
                for s, sp, d, dp in dirs]}
dump("graph_up.json", up)
cut = copy.deepcopy(up)
for e in cut["edges"]:
    if (e["src_dpid"], e["src_interface"]) in ((1, 3), (3, 1)):
        e["is_up"] = False
dump("graph_cut.json", cut)
half = copy.deepcopy(up); half["edges"][0]["is_up"] = False
dump("graph_half.json", half)
off = copy.deepcopy(up); off["edges"][1]["is_enabled"] = False
dump("graph_disabled.json", off)
def caps(reroute, disc, n=4):
    return {"switches": {str(d): {"capabilities": {"ipv4_route": "ndtwin", "five_tuple": False, "reroute": reroute,
                                                   "link_discovery": disc, "binding_source": "package"}} for d in range(1, n + 1)}}
s = caps(True, "heartbeat")
s["reroute"] = {"available": True, "reason": None, "detail": "x"}
s["heartbeat"] = {"state": "usable", "watchdog": "running", "session": "ab",
                  "side_effects": {"forwarded_to_hosts": 0, "forwarded_between_switches": 0}}
dump("state_owned.json", s)
w = copy.deepcopy(s); w["switches"]["3"]["capabilities"]["reroute"] = False
dump("state_one_off.json", w)
w = caps(True, "declared"); w["reroute"] = {"available": True, "reason": None}
dump("state_declared.json", w)
u = caps(False, "heartbeat"); u["reroute"] = {"available": False, "reason": "unbound", "detail": "x"}
u["heartbeat"] = {"state": "usable", "side_effects": {"forwarded_to_hosts": 0}}
dump("state_unbound.json", u)
n = caps(False, "declared"); n["reroute"] = {"available": False, "reason": "heartbeat_not_running"}
n["heartbeat"] = {"state": "heartbeat_not_running"}
dump("state_stopped.json", n)
dump("state_old_proxy.json", caps(False, "declared"))
dump("report_clean.json", {"side_effects": {"forwarded_to_hosts": 0, "forwarded_between_switches": 3}})
dump("report_leak.json", {"side_effects": {"forwarded_to_hosts": 2}})
leak = copy.deepcopy(s); leak["heartbeat"]["side_effects"]["forwarded_to_hosts"] = 1
dump("state_leak.json", leak)
# [Co-developed with claude code -- Adam] H4 (09-27): an external control plane, detect only.
def ext_links(down, source="heartbeat", told=False):
    return {"1:2->2:2": {"down": down, "source": source, "reported_to_kernel": told},
            "2:2->1:2": {"down": down, "source": source, "reported_to_kernel": told},
            "1:3->3:2": {"down": False, "source": source, "reported_to_kernel": False}}
x = caps(False, "heartbeat", 3)
for _d, _sw in x["switches"].items():
    _sw.update(pipeline_commits=0, rules_timed=0, table_generation=None)
x["reroute"] = {"available": False, "reason": "external_control_plane", "detail": "x"}
x["heartbeat"] = {"state": "usable", "watchdog": "running", "side_effects": {"forwarded_to_hosts": 0}}
x["links"] = ext_links(False)
dump("state_ext.json", x)
xc = copy.deepcopy(x); xc["links"] = ext_links(True)
dump("state_ext_cut.json", xc)
xh = copy.deepcopy(xc); xh["links"]["2:2->1:2"]["down"] = False
dump("state_ext_half.json", xh)
xd = copy.deepcopy(x); xd["links"] = ext_links(None, "declared")
dump("state_ext_declared.json", xd)
# [Co-developed with claude code -- Adam] F4 (09-28): told to the kernel, and the write record.
xt = copy.deepcopy(x); xt["links"] = ext_links(True, told=True)
dump("state_ext_cut_told.json", xt)
xu = copy.deepcopy(x); xu["links"] = ext_links(False, told=True)
dump("state_ext_told.json", xu)
xh2 = copy.deepcopy(xt); xh2["links"]["2:2->1:2"]["reported_to_kernel"] = False
dump("state_ext_cut_half_told.json", xh2)
xw = copy.deepcopy(xt); xw["switches"]["2"]["pipeline_commits"] = 1; xw["switches"]["2"]["table_generation"] = "g1"
dump("state_ext_wrote.json", xw)
xr = copy.deepcopy(xt); xr["switches"]["1"]["rules_timed"] = 3
dump("state_ext_rules.json", xr)
xg = copy.deepcopy(xt); xg["switches"]["3"]["table_generation"] = "g7"
dump("state_ext_gen.json", xg)
p4rt = [(1, 2, 2, 2), (1, 3, 3, 2), (3, 3, 2, 3)]
dump("model_p4rt.json", {"nodes": [{"dpid": d, "vertex_type": 0} for d in (1, 2, 3)],
                         "edges": [{"src_dpid": s, "src_interface": sp, "dst_dpid": d, "dst_interface": dp}
                                   for s, sp, d, dp in p4rt + [(d, dp, s, sp) for s, sp, d, dp in p4rt]]})
row = lambda dst, port: {"priority": 0, "match": {"dl_type": 2048, "nw_dst": dst}, "actions": [f"OUTPUT:{port}"]}
H = ["10.0.1.1", "10.0.2.2", "10.0.3.3", "10.0.4.4"]
before = {1: [row(H[0], 1), row(H[1], 2), row(H[2], 3), row(H[3], 3)], 2: [row(H[0], 4), row(H[1], 4), row(H[2], 1), row(H[3], 2)],
          3: [row(H[0], 1), row(H[1], 1), row(H[2], 2), row(H[3], 2)], 4: [row(H[0], 2), row(H[1], 2), row(H[2], 1), row(H[3], 1)]}
after = copy.deepcopy(before); after[1] = [row(H[0], 1), row(H[1], 2), row(H[2], 4), row(H[3], 4)]
after[3] = [row(H[0], 2), row(H[1], 2), row(H[2], 2), row(H[3], 2)]
stuck = copy.deepcopy(after); stuck[3] = copy.deepcopy(before[3])
lost = copy.deepcopy(after); lost[1] = lost[1][:3]
unused = copy.deepcopy(before); unused[1] = [row(H[0], 1), row(H[1], 2), row(H[2], 4), row(H[3], 4)]; unused[3] = after[3]
unused[2] = [row(H[0], 3), row(H[1], 3), row(H[2], 1), row(H[3], 2)]; unused[4] = [row(H[0], 2), row(H[1], 2), row(H[2], 1), row(H[3], 1)]
for name, tbl in (("before", before), ("after", after), ("stuck", stuck), ("lost", lost), ("unused", unused)):
    os.makedirs(os.path.join(t, name))
    for d, rows in tbl.items():
        with open(os.path.join(t, name, f"stats_flow_{d}.json"), "w") as fh:
            json.dump({str(d): rows}, fh)
os.makedirs(os.path.join(t, "moved"))
for d, rows in before.items():
    rows = copy.deepcopy(rows)
    if d == 1:
        rows[0]["actions"] = ["OUTPUT:2"]
    with open(os.path.join(t, "moved", f"stats_flow_{d}.json"), "w") as fh:
        json.dump({str(d): rows}, fh)
for name, code, detail in (("501", "501", {"outcome": "unsupported_on_p4", "reason": "unbound"}),
                           ("501_owned", "501", {"outcome": "unsupported_on_p4", "reason": "owned_by_package"}),
                           ("500", "500", {}),
                           ("409", "409", {"error": "external control plane", "dpid": 1}),
                           ("409_other", "409", {"error": "something else"})):
    open(os.path.join(t, f"code_{name}"), "w").write(code + "\n")
    dump(f"body_{name}.json", {"detail": detail})
open(os.path.join(t, "polls_up"), "w").write("".join(f"{i:6.1f}  OK both directions up\n" for i in range(12)))
open(os.path.join(t, "polls_down"), "w").write("".join(f"{i:6.1f}  OK both directions up\n" for i in range(6)) + "   7.0  BAD the cut is not up both ways\n")
arms = [("basic","skeleton","0","PASS (4/4)"),("basic","solution","0","PASS (6/6)"),("source_routing","skeleton","0","PASS (2/2)"),
        ("source_routing","solution","0","PASS (5/5)"),("calc","skeleton","0","PASS (2/2)"),("calc","solution","0","PASS (3/3)"),
        ("multicast","skeleton","0","PASS (2/2)"),("multicast","solution","0","PASS (6/6)"),
        ("basic_tunnel","skeleton","1","RED ARM (1/1): the skeleton does not get past the control plane, by design"),
        ("basic_tunnel","solution","0","PASS (4/4)"),("load_balance","skeleton","0","PASS (2/2)"),("load_balance","solution","0","PASS (2/2)"),
        ("qos","skeleton","0","PASS (3/3)"),("qos","solution","0","PASS (4/4)"),("link_monitor","skeleton","0","PASS (4/4)"),
        ("link_monitor","solution","0","PASS (4/4)"),("firewall","skeleton","0","PASS (3/3)"),("firewall","solution","0","PASS (4/4)"),
        ("ecn","skeleton","0","PASS (3/3)"),("ecn","solution","0","PASS (4/4)"),("mri","skeleton","0","PASS (4/4)"),("mri","solution","0","PASS (5/5)"),
        ("p4runtime","skeleton","0","PASS (4/4)"),("p4runtime","solution","0","PASS (5/5)"),
        ("flowcache","skeleton","1","RED ARM (1/1): skeleton does not compile, by design"),("flowcache","solution","0","PASS (5/5)")]
import calendar
T0 = calendar.timegm((2026, 9, 27, 1, 0, 0))
def tbl(rows, name):
    with open(os.path.join(t, name), "w") as fh:
        fh.write("exercise\twhich\trc\tverdict\treport\n")
        for i, (e, w, rc, v) in enumerate(rows):
            stamp = __import__("time").strftime("%Y-%m-%dT%H%M%SZ", __import__("time").gmtime(T0 + 100 * i))
            fh.write(f"{e}\t{w}\t{rc}\t{v}\t/x/runs/{stamp}_{e}_{w}_ndtwin.md\n")
tbl(arms, "table_old.tsv"); tbl(arms, "table_same.tsv")
# [Co-developed with claude code -- Adam] (M-1) the control C1 as the README now runs it: a whole 06
# on trunk -- the same 26 arms, other stamps and reports -- and the 4-arm ONLY= one it ran before.
def tbl_at(rows, name, t0, runs):
    with open(os.path.join(t, name), "w") as fh:
        fh.write("exercise\twhich\trc\tverdict\treport\n")
        for i, (e, w, rc, v) in enumerate(rows):
            stamp = __import__("time").strftime("%Y-%m-%dT%H%M%SZ", __import__("time").gmtime(t0 + 90 * i))
            fh.write(f"{e}\t{w}\t{rc}\t{v}\t{runs}/{stamp}_{e}_{w}_ndtwin.md\n")
tbl_at(arms, "table_c1.tsv", T0 - 7200, "/main/doc/audit/runs")
tbl_at([a for a in arms if a[0] in ("p4runtime", "flowcache")], "table_c1_only.tsv", T0 - 7200, "/main/doc/audit/runs")
os.makedirs(os.path.join(t, "c1_full")); os.makedirs(os.path.join(t, "c1_only"))
__import__("shutil").copyfile(os.path.join(t, "table_c1.tsv"), os.path.join(t, "c1_full", "00_table.tsv"))
__import__("shutil").copyfile(os.path.join(t, "table_c1_only.tsv"), os.path.join(t, "c1_only", "00_table.tsv"))
diff = list(arms); diff[3] = ("source_routing", "solution", "1", "FAIL (4/5)"); tbl(diff, "table_diff.tsv")
tbl(arms[:25], "table_short.tsv")
expected = {"basic/skeleton","basic/solution","source_routing/skeleton","source_routing/solution","basic_tunnel/solution",
            "load_balance/skeleton","load_balance/solution","qos/skeleton","qos/solution","link_monitor/skeleton",
            "link_monitor/solution","firewall/skeleton","firewall/solution","ecn/skeleton","ecn/solution","mri/skeleton","mri/solution",
            # [Co-developed with claude code -- Adam] 09-27: the external arms, detect only.
            "p4runtime/skeleton","p4runtime/solution","flowcache/solution"}
# [Co-developed with claude code -- Adam] A read every 5 s through 06 AND on through 01 (100 s after
# T_END), as a sampler that lived to be stopped writes; `hole` leaves a stretch out (one that died).
def sampled(name, hosts=0, drop=None, extra=None, hole=None):
    with open(os.path.join(t, name), "w") as fh:
        fh.write("wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\n")
        for i, (e, w, *_r) in enumerate(arms):
            arm = f"{e}/{w}"
            for k in range(0, 100, 5):
                ts = T0 + 100 * i + k
                if hole and hole[0] <= ts < hole[1]:
                    continue
                on = (arm in expected and arm != drop) or arm == extra
                if on and 10 <= k < 90:
                    fh.write(f"{ts}\trunning\tsess{i:02d}\t{1000+i}\t{hosts if k == 50 else 0}\t0\n")
                else:
                    fh.write(f"{ts}\tstopped\tsess{max(i-1,0):02d}\t-\t0\t0\n")
        for k in range(0, 100, 5):
            fh.write(f"{T0 + 100 * len(arms) + k}\tstopped\tsess{len(arms) - 1:02d}\t-\t0\t0\n")
sampled("samples_ok.tsv"); sampled("samples_missing.tsv", drop="qos/solution")
sampled("samples_extra.tsv", extra="calc/solution"); sampled("samples_leak.tsv", hosts=1)
sampled("samples_gap.tsv", hole=(T0 + 400, T0 + 900))
open(os.path.join(t, "T_END"), "w").write(str(T0 + 100 * len(arms)))
PY
    local cut="1 3 3 1" tend; tend="$(cat "$t/T_END")"
    echo "08_heartbeat --self-test (synthetic captures in $t; no lab, no claim, nothing started)"
    expect OK   "H1 capabilities: reroute true, heartbeat"          "$(verdict caps "$t/state_owned.json" true heartbeat)"
    expect BAD  "H1 one switch says reroute false"                   "$(verdict caps "$t/state_one_off.json" true heartbeat)"
    expect BAD  "H1 declared is not heartbeat"                       "$(verdict caps "$t/state_declared.json" true heartbeat)"
    expect OK   "H1 reroute available, no reason"                    "$(verdict reroute "$t/state_owned.json" true null)"
    expect BAD  "H1 unavailable is not available"                    "$(verdict reroute "$t/state_unbound.json" true null)"
    expect BAD  "H1 a proxy with no reroute block"                   "$(verdict reroute "$t/state_old_proxy.json" true null)"
    expect OK   "H1 heartbeat usable"                                "$(verdict hb_state "$t/state_owned.json" usable)"
    expect BAD  "H1 a stopped heartbeat is not usable"               "$(verdict hb_state "$t/state_stopped.json" usable)"
    expect OK   "ruling 4: no frame left a host port (report)"       "$(verdict hosts_clean "$t/report_clean.json")"
    expect STOP "ruling 4: the daemon counted one (report)"          "$(verdict hosts_clean "$t/report_leak.json")"
    expect STOP "ruling 4: switch_state says it too"                 "$(verdict hosts_clean "$t/state_leak.json")"
    expect OK   "H1 eight directions up"                             "$(verdict edges_up "$t/graph_up.json" "$t/model.json")"
    expect BAD  "H1 one direction down is not all up"                "$(verdict edges_up "$t/graph_half.json" "$t/model.json")"
    expect BAD  "H1 up but not enabled"                              "$(verdict edges_up "$t/graph_disabled.json" "$t/model.json")"
    expect OK   "H1 the cut is down both ways"                       "$(verdict cut_down "$t/graph_cut.json" $cut)"
    expect BAD  "H1 only one direction down"                         "$(verdict cut_down "$t/graph_half.json" $cut)"
    expect BAD  "H1 nothing down"                                    "$(verdict cut_down "$t/graph_up.json" $cut)"
    expect OK   "H1 back up both ways"                               "$(verdict cut_up "$t/graph_up.json" $cut)"
    expect BAD  "H1 still down"                                      "$(verdict cut_up "$t/graph_cut.json" $cut)"
    expect BAD  "H1 only one direction back up"                      "$(verdict cut_up "$t/graph_half.json" $cut)"
    expect OK   "H1 the cable routes use is picked"                  "$(verdict pick_cut "$t/before" "$CABLES")"
    got="$(verdict pick_cut "$t/before" "$CABLES")"
    [[ "$got" == "OK 1 3 3 1" ]] && ok "  and it is s1-s3, the first used one" || red "  pick_cut chose: $got"
    got="$(verdict pick_cut "$t/unused" "$CABLES")"
    [[ "$got" == "OK 1 4 4 2" ]] && ok "  an unused s1-s3 is skipped for the next used cable" || red "  pick_cut on unused s1-s3 chose: $got"
    expect OK   "H1 rerouted: nothing into the cut, nothing lost"    "$(verdict rerouted "$t/before" "$t/after" $cut)"
    expect BAD  "H1 s3 still routes into the cut"                    "$(verdict rerouted "$t/before" "$t/stuck" $cut)"
    expect BAD  "H1 a destination lost its route"                    "$(verdict rerouted "$t/before" "$t/lost" $cut)"
    expect BAD  "H1 a cut nothing routed over proves nothing"        "$(verdict rerouted "$t/unused" "$t/unused" $cut)"
    expect OK   "H1 within 20 s"                                     "$(verdict elapsed 14.3 20 detection)"
    expect BAD  "H1 over 20 s"                                       "$(verdict elapsed 20.4 20 detection)"
    expect BAD  "H1 never"                                           "$(verdict elapsed never 20 detection)"
    expect OK   "H2 held up in every poll"                           "$(verdict held_up "$t/polls_up" 10)"
    expect BAD  "H2 went down once"                                  "$(verdict held_up "$t/polls_down" 5)"
    expect BAD  "H2 too few polls"                                   "$(verdict held_up "$t/polls_up" 20)"
    expect OK   "H3 capabilities: no reroute, heartbeat"             "$(verdict caps "$t/state_unbound.json" false heartbeat)"
    expect OK   "H3 reason unbound"                                  "$(verdict reroute "$t/state_unbound.json" false unbound)"
    expect BAD  "H3 a stopped heartbeat's reason is not unbound"     "$(verdict reroute "$t/state_stopped.json" false unbound)"
    expect OK   "H3 author's rows unchanged"                         "$(verdict rows_unchanged "$t/before" "$t/before")"
    expect BAD  "H3 a row moved"                                     "$(verdict rows_unchanged "$t/before" "$t/moved")"
    expect OK   "H3 501 unbound"                                     "$(verdict refused_501 "$t/code_501" "$t/body_501.json")"
    expect BAD  "H3 501 for another reason"                          "$(verdict refused_501 "$t/code_501_owned" "$t/body_501_owned.json")"
    expect BAD  "H3 a 500"                                           "$(verdict refused_501 "$t/code_500" "$t/body_500.json")"
    expect OK   "H4 409 external control plane"                      "$(verdict conflict_409 "$t/code_409" "$t/body_409.json")"
    expect BAD  "H4 the 500 of before"                               "$(verdict conflict_409 "$t/code_500" "$t/body_500.json")"
    expect BAD  "H4 a 409 for something else"                        "$(verdict conflict_409 "$t/code_409_other" "$t/body_409_other.json")"
    # [Co-developed with claude code -- Adam] H4 since 09-27: detect only on the external fabric.
    expect OK   "H4 capabilities: no reroute, heartbeat"             "$(verdict caps "$t/state_ext.json" false heartbeat)"
    expect OK   "H4 reason external_control_plane"                   "$(verdict reroute "$t/state_ext.json" false external_control_plane)"
    expect BAD  "H4 an unbound reason is not the external one"       "$(verdict reroute "$t/state_unbound.json" false external_control_plane)"
    expect OK   "H4 the proxy holds the cut down"                    "$(verdict links "$t/state_ext_cut.json" down 1 2 2 2)"
    expect BAD  "H4 one direction still up"                          "$(verdict links "$t/state_ext_half.json" down 1 2 2 2)"
    expect BAD  "H4 declared is not the heartbeat"                   "$(verdict links "$t/state_ext_declared.json" down 1 2 2 2)"
    expect BAD  "H4 a cable the proxy does not name"                 "$(verdict links "$t/state_ext_cut.json" down 3 3 2 3)"
    expect OK   "H4 restored: both up again"                         "$(verdict links "$t/state_ext.json" up 1 2 2 2)"
    expect BAD  "H4 a cut that did not come back"                    "$(verdict links "$t/state_ext_cut.json" up 1 2 2 2)"
    # [Co-developed with claude code -- Adam] F4 (09-28): told to the kernel, and nothing written.
    expect OK   "H4 the cut is down and the kernel accepted it"      "$(verdict links "$t/state_ext_cut_told.json" down-told 1 2 2 2)"
    expect BAD  "H4 down at the proxy, not accepted by the kernel"   "$(verdict links "$t/state_ext_cut.json" down-told 1 2 2 2)"
    expect BAD  "H4 one direction not accepted"                      "$(verdict links "$t/state_ext_cut_half_told.json" down-told 1 2 2 2)"
    expect OK   "H4 restored and the kernel accepted it"             "$(verdict links "$t/state_ext_told.json" up-told 1 2 2 2)"
    expect OK   "H4 nothing written across the cut"                  "$(verdict no_writes "$t/state_ext.json" "$t/state_ext_cut_told.json")"
    expect BAD  "H4 a pipeline commit across the cut"                "$(verdict no_writes "$t/state_ext.json" "$t/state_ext_wrote.json")"
    expect BAD  "H4 a timed rule across the cut"                     "$(verdict no_writes "$t/state_ext.json" "$t/state_ext_rules.json")"
    # [Co-developed with claude code -- Adam] The external judge's m3 (09-28): up at the proxy with
    # the kernel not having accepted it; table_generation moving on its own; the restore's bound.
    expect BAD  "H4 up at the proxy, not accepted by the kernel"     "$(verdict links "$t/state_ext.json" up-told 1 2 2 2)"
    expect BAD  "H4 only table_generation moved"                     "$(verdict no_writes "$t/state_ext.json" "$t/state_ext_gen.json")"
    expect OK   "H4 restore 19.9 s is within the strict 20 s"        "$(verdict restore_strict 19.9 20)"
    expect BAD  "H4 restore 20.5 s is over the strict 20 s"          "$(verdict restore_strict 20.5 20)"
    expect OK   "H4 the cut is a cable the package declares"         "$(verdict model_has "$t/model_p4rt.json" 1 2 2 2)"
    expect BAD  "H4 a cable the package does not declare"            "$(verdict model_has "$t/model_p4rt.json" 1 3 3 1)"
    expect OK   "H5 26 arms identical"                               "$(verdict same_06 "$t/table_same.tsv" "$t/table_old.tsv")"
    expect BAD  "H5 one arm differs"                                 "$(verdict same_06 "$t/table_diff.tsv" "$t/table_old.tsv")"
    expect BAD  "H5 an arm missing"                                  "$(verdict same_06 "$t/table_short.tsv" "$t/table_old.tsv")"
    expect OK   "🔴 H5 against the control C1 as the README runs it (a whole 06)" "$(verdict same_06 "$t/table_same.tsv" "$t/table_c1.tsv")"
    expect BAD  "  H5 against a 4-arm ONLY= control: the reference is not a whole 06" "$(verdict same_06 "$t/table_same.tsv" "$t/table_c1_only.tsv")"
    expect OK   "H5 heartbeat on exactly the expected arms"          "$(verdict h5_heartbeat "$t/samples_ok.tsv" "$t/table_same.tsv" "$tend" "$HB_ARMS")"
    expect BAD  "H5 an expected arm had none"                        "$(verdict h5_heartbeat "$t/samples_missing.tsv" "$t/table_same.tsv" "$tend" "$HB_ARMS")"
    expect BAD  "H5 an arm that should have none had one"            "$(verdict h5_heartbeat "$t/samples_extra.tsv" "$t/table_same.tsv" "$tend" "$HB_ARMS")"
    expect STOP "H5 ruling 4 in a sample"                            "$(verdict h5_heartbeat "$t/samples_leak.tsv" "$t/table_same.tsv" "$tend" "$HB_ARMS")"
    expect OK   "H5 no session during 01"                            "$(verdict no_session "$t/samples_ok.tsv" "$tend" "$((tend + 100))")"
    expect BAD  "H5 a session during 01"                             "$(verdict no_session "$t/samples_ok.tsv" 0 "$tend")"
    # --- H5's sampler dying AFTER a good start (the opus judge's N2-1 on f4f43a32) -------------------
    # [Co-developed with claude code -- Adam] sampler_start's check only covers the start. A sampler
    # killed later (a signal: no stderr at all) or one that complained on its stderr must still end
    # the WHOLE run FAIL -- read on the run's last line, through the real sampler_start /
    # sampler_stop and the real teardown (w_finish -> finish), as H5 runs them (no claim).
    st_h5_dies() {   # st_h5_dies <kill|stderr|healthy> -> the run's output
        local d
        d="$(mktemp -d "$t/h5d-XXXXXX")"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/ndt"; chmod +x "$d/ndt"
        ( STEP=08_heartbeat; RUN="$d/run"; mkdir -p "$RUN"; CLAIMED=0; VERDICT_RC=0; VERDICT_WHY=""; FABRIC_UP=0
          INJECTED_IFACES=(); NDT="$d/ndt"; REAL_NDT="$d/ndt"; APP_KNOB="$d/none"
          KNOB_ENTRY_COPY=""; TEL_ENTRY_COPY=""; CTRL_PID=""; TEARDOWN_DOWN_RC=""
          SAMPLER_PID=""; SAMPLER_STOP=""; SAMPLER_ERR=""; SAMPLER_INTERVAL_S=0.1; HB_REPORT_FILE="$d/report.json"
          if [[ "$1" == stderr ]]; then
              SAMPLER_PY="import sys
sys.stderr.write('a warning the sampler printed\n'); sys.stderr.flush()
$SAMPLER_PY"
          fi
          sampler_start "$RUN/50_samples.tsv" || echo "sampler_start answered $?"
          if [[ "$1" == kill ]]; then kill -9 "$SAMPLER_PID" 2>/dev/null; sleep 0.4; fi
          sleep 0.3
          sampler_stop
          ( exit 0 ); w_finish ) 2>&1
    }
    out="$(st_h5_dies kill)" || true
    got="$(tail -1 <<<"$out")"
    [[ "$got" == "FAIL 08_heartbeat -- H5: the report sampler"*"was not running"* && "$out" != *"sampler_start answered"* ]] \
        && ok "H5 sampler killed after a good start: sampler_start said 0, and the run's last line is FAIL" \
        || red "H5 sampler killed after a good start: the run ended '$got'"
    out="$(st_h5_dies stderr)" || true
    got="$(tail -1 <<<"$out")"
    [[ "$got" == "FAIL 08_heartbeat -- H5: the report sampler wrote to its stderr"*"a warning the sampler printed"* ]] \
        && ok "  H5 sampler with a warning on its stderr: the run's last line is FAIL and quotes it" \
        || red "  H5 sampler with a warning on its stderr: the run ended '$got'"
    out="$(st_h5_dies healthy)" || true
    got="$(tail -1 <<<"$out")"
    [[ "$got" == "PASS 08_heartbeat" ]] && ok "  the control: a sampler that ran and stopped cleanly ends PASS" \
                                         || red "  a healthy sampler's run ended '$got'"
    # sampler_alive asks by argv too: a live pid that is not this sampler (a reaped pid, reused) is
    # not the sampler. [Co-developed with claude code -- Adam]
    got="$( sleep 20 & other=$!
            SAMPLER_PID="$other"; SAMPLER_STOP="$t/.no-such-sampler.stop"
            sampler_alive && echo "alive" || echo "not the sampler"
            kill "$other" 2>/dev/null; wait "$other" 2>/dev/null )" || true
    [[ "$got" == "not the sampler" ]] && ok "  sampler_alive: a live pid that is not the sampler (a reused pid) does not count" \
                                      || red "  sampler_alive with a reused pid said '$got'"
    # the verdicts read a sampler that stopped reading, not only one that recorded nothing
    expect BAD  "H5 01 with no sample in its window"                  "$(verdict no_session "$t/samples_ok.tsv" "$((tend + 10000))" "$((tend + 10100))")"
    expect BAD  "H5 a sampler that stopped reading for 500 s mid-06"  "$(verdict h5_heartbeat "$t/samples_gap.tsv" "$t/table_same.tsv" "$tend" "$HB_ARMS")"
    expect BAD  "H5 01 where the sampler stopped half-way"            "$(verdict no_session "$t/samples_ok.tsv" "$((tend + 50))" "$((tend + 200))")"
    # consts: the proxy's own constants, the one embedded program only the live path ran (the
    # judge's N2-2)
    got="$(consts)" || true
    [[ "$got" == "5 15 5" ]] && ok "consts: the proxy's beacon interval, timeout and watchdog interval, imported (5 15 5)" \
                             || red "consts gave '$got'"
    expect BAD  "an unreadable capture is BAD, not a traceback"      "$(verdict caps "$t/nonexistent.json" true heartbeat)"
    # --- the cut's phase: planned from the report, recorded from it ------------------------------
    printf '{"directions": [{"tx": {"dpid": 1, "port": 3}, "rx": {"dpid": 3, "port": 1}, "last_heard_mono": 100.25},
      {"tx": {"dpid": 3, "port": 1}, "rx": {"dpid": 1, "port": 3}, "last_heard_mono": 100.5},
      {"tx": {"dpid": 1, "port": 4}, "rx": {"dpid": 4, "port": 2}, "last_heard_mono": 180.0}]}' > "$t/report_phase.json"
    got="$(HB_REPORT_FILE="$t/report_phase.json" report_last 1 3 3 1)"
    [[ "$got" == "100.500" ]] && ok "report_last: the LATER of the cable's two directions (100.25, 100.5 -> 100.500)" \
                              || red "report_last gave '$got'"
    got="$(HB_REPORT_FILE="$t/report_phase.json" report_last 1 4 4 2)"
    [[ -z "$got" ]] && ok "  one direction missing: no answer, not a guess" || red "  one direction missing gave '$got'"
    got="$(next_phase_target 100.0 0.05 5 101.0)"
    [[ "$got" == "105.050" ]] && ok "next_phase_target: 0.05 s after the next round at least 0.3 s ahead (last 100, now 101 -> 105.050)" \
                              || red "next_phase_target gave '$got'"
    got="$(next_phase_target 100.0 0.05 5 104.9)"
    [[ "$got" == "110.050" ]] && ok "  a round too close to catch is skipped for the next (now 104.9 -> 110.050)" \
                              || red "  too close gave '$got'"
    got="$( H1_WORST=3; PHI_WORST=0.05; HB_PERIOD_S=5; RANDOM=7
            for c in 1 2 3 4 5 6 7 8 9 10; do phase_for "$c"; done | paste -sd' ' )"
    read -r -a PH <<<"$got"
    if [[ "${PH[0]} ${PH[1]} ${PH[2]}" == "0.05 0.05 0.05" ]] \
       && awk -v a="${PH[3]}" -v b="${PH[9]}" 'BEGIN{exit !(a > 0.05 && a < 4.95 && b > 0.05 && b < 4.95)}' \
       && [[ "$(printf '%s\n' "${PH[@]:3}" | sort -u | wc -l)" -gt 1 ]]; then
        ok "phase_for: the first H1_WORST cycles at the worst phase, the rest random inside the period ($got)"
    else
        red "phase_for gave: $got"
    fi
    # --- one cut and one restore on the monotonic clock (orchestrator 09-26 addenda) --------------
    # [Co-developed with claude code -- Adam] Wall instants are 1000 s + x with an offset of -800,
    # so the monotonic ones read 200 + x; the report's frames and the proxy's passes are monotonic.
    printf '{"heartbeat": {"watchdog_passes": [{"start_mono": 200.5, "end_mono": 200.51, "down": 0, "up": 0},
      {"start_mono": 205.5, "end_mono": 205.52, "down": 0, "up": 0},
      {"start_mono": 210.52, "end_mono": 210.54, "down": 0, "up": 0},
      {"start_mono": 215.56, "end_mono": 215.59, "down": 2, "up": 0},
      {"start_mono": 220.56, "end_mono": 220.58, "down": 0, "up": 0}]}}' > "$t/state_passes.json"
    printf '{"heartbeat": {"watchdog_passes": [{"start_mono": 200.5, "end_mono": 200.51, "down": 0, "up": 0}]}}' > "$t/state_nopass.json"
    printf '{"heartbeat": {"watchdog_passes": [{"start_mono": 205.0, "end_mono": 205.02, "down": 0, "up": 0},
      {"start_mono": 210.02, "end_mono": 210.04, "down": 0, "up": 0},
      {"start_mono": 215.0, "end_mono": 215.02, "down": 0, "up": 0},
      {"start_mono": 220.08, "end_mono": 220.1, "down": 2, "up": 0}]}}' > "$t/state_late.json"
    printf '{"heartbeat": {"watchdog_passes": [{"start_mono": 220.3, "end_mono": 220.32, "down": 2, "up": 0}]}}' > "$t/state_single.json"
    printf '{"heartbeat": {"watchdog_passes": [{"start_mono": 210.0, "end_mono": 210.02, "down": 0, "up": 0},
      {"start_mono": 215.2, "end_mono": 215.22, "down": 0, "up": 0},
      {"start_mono": 220.2, "end_mono": 220.22, "down": 2, "up": 0}]}}' > "$t/state_missed.json"
    printf '{"heartbeat": {"watchdog_passes": [{"start_mono": 210.0, "end_mono": 210.02, "down": 0, "up": 0},
      {"start_mono": 214.99, "end_mono": 215.01, "down": 1, "up": 0},
      {"start_mono": 219.99, "end_mono": 220.01, "down": 1, "up": 0},
      {"start_mono": 224.99, "end_mono": 225.01, "down": 0, "up": 0}]}}' > "$t/state_twostep.json"
    cyc() { verdict cycle "$1" "${@:2}"; }
    got="$(cyc "$t/state_passes.json" 1000.02 1000.03 1000.04 1000.06 -800.0 -800.0 199.99 200.0 1015.9 15 5 0.02 1)"
    [[ "$got" == $'OK 200.020\t200.030\t200.040\t200.060\t199.990\t200.000\t0.020\t215.900\t15.880\t210.520\t215.560\t215.590\t0.560\t0.040\t0.340\t0.000\t0.0\t-' ]] \
        && ok "cycle: four tc instants, both last frames, phi 0.020, down, detection 15.880 from the FIRST end's call, the passes, psi 0.560, lateness 0.040, pass-to-graph 0.340" \
        || red "cycle gave '$got'"
    expect OK   "budget: 15.88 s is within the strict 20 s"            "$(verdict budget "${got#OK }" 20)"
    got="$(cyc "$t/state_late.json" 1000.01 1000.02 1000.03 1000.05 -800.0 -800.0 199.995 200.0 1020.33 15 5 0.02 1)"
    got="$(verdict budget "${got#OK }" 20)"
    [[ "$got" == "OK detection 20.320 s -- OVER the strict 20 s by 0.320 s, all of it measured"* ]] \
        && ok "budget: over the strict 20 s by what was measured is OK, and says OVER ($(cut -c1-60 <<<"$got")...)" \
        || red "budget: over the strict 20 s by what was measured gave '$got'"
    got="$(cyc "$t/state_single.json" 1000.02 1000.03 1000.04 1000.06 -800.0 -800.0 199.99 200.0 1020.5 15 5 0.02 1)"
    [[ "$got" == OK*"no pass before the reporting one was served"* ]] \
        && ok "cycle: a reporting pass with none served before it says its lateness is not measured" \
        || red "cycle with no pass before the reporting one gave '$got'"
    expect BAD  "budget: a pass 5.3 s after the timeout, none before it served, is over even the measured budget" \
                "$(verdict budget "${got#OK }" 20)"
    expect BAD  "cycle: a pass after the timeout that did not report the cut" \
                "$(cyc "$t/state_missed.json" 1000.02 1000.03 1000.04 1000.06 -800.0 -800.0 199.99 200.0 1020.5 15 5 0.02 1)"
    got="$(cyc "$t/state_passes.json" 1000.02 1000.03 1000.04 1000.06 -800.0 -800.0 199.99 200.045 1015.95 15 5 0.02 1)"
    if [[ "$got" == OK* && "$got" == *"b->a heard inside its end's tc window, 5.0 ms after the call started"* \
          && "$got" == *"25.0 ms after the first end's tc started (phi < 0)"* && "$(cut -f16 <<<"${got#OK }")" == 0.025 ]]; then
        ok "cycle: a frame heard inside a cut window is flagged, and the cycle kept (window 0.025 s in the budget)"
    else
        red "cycle: a frame heard inside a cut window gave '$got'"
    fi
    got="$(cyc "$t/state_twostep.json" 1000.02 1000.03 1000.04 1000.06 -800.0 -800.0 199.98 200.0 1020.2 15 5 0.02 1)"
    [[ "$got" == OK* && "$(cut -f11 <<<"${got#OK }")" == 219.990 && "$(cut -f10 <<<"${got#OK }")" == 214.990 ]] \
        && ok "cycle: two directions timing out in two passes -- the one that made BOTH down (219.990) is the reporting pass" \
        || red "cycle with two reporting passes gave '$got'"
    got="$(cyc "$t/state_passes.json" 1000.02 1000.03 1000.04 1000.06 -800.0 -799.99 199.99 200.0 1015.9 15 5 0.02 1)"
    [[ "$got" == OK*"the wall clock moved +10.0 ms against the monotonic one"* ]] \
        && ok "cycle: the wall clock moving against the monotonic one during the cycle is flagged" \
        || red "cycle with a 10 ms clock step gave '$got'"
    expect BAD  "cycle: a worst-phase cut that landed before the round" \
                "$(cyc "$t/state_passes.json" 1004.96 1004.97 1004.98 1005.0 -800.0 -800.0 199.99 200.0 1020.9 15 5 0.02 1)"
    expect OK   "cycle: the same landing on a random-phase cycle is fine" \
                "$(cyc "$t/state_passes.json" 1004.96 1004.97 1004.98 1005.0 -800.0 -800.0 199.99 200.0 1020.9 15 5 3.1 0)"
    expect BAD  "cycle: no reporting pass served" \
                "$(cyc "$t/state_nopass.json" 1000.02 1000.03 1000.04 1000.06 -800.0 -800.0 199.99 200.0 1015.9 15 5 0.02 1)"
    expect BAD  "cycle: the graph never showed it down" \
                "$(cyc "$t/state_passes.json" 1000.02 1000.03 1000.04 1000.06 -800.0 -800.0 199.99 200.0 "" 15 5 0.02 1)"
    expect BAD  "cycle: a direction with no last frame in the report" \
                "$(cyc "$t/state_passes.json" 1000.02 1000.03 1000.04 1000.06 -800.0 -800.0 "" 200.0 1015.9 15 5 0.02 1)"
    # the restore
    printf '{"heartbeat": {"watchdog_passes": [{"start_mono": 300.2, "end_mono": 300.22, "down": 0, "up": 0},
      {"start_mono": 305.0, "end_mono": 305.02, "down": 0, "up": 2},
      {"start_mono": 310.0, "end_mono": 310.02, "down": 0, "up": 0}]}}' > "$t/state_up.json"
    printf '{"heartbeat": {"watchdog_passes": [{"start_mono": 305.0, "end_mono": 305.02, "down": 0, "up": 0}]}}' > "$t/state_noup.json"
    rwatch() {   # rwatch <file> <ab heard> <ba heard> [timed_out]
        printf '{"start_mono": 300.4, "initial": {"ab": 200.0, "ba": 200.0}, "timed_out": %s, "first": {"ab": {"heard": %s, "seen": 301.72, "written": 301.7}, "ba": {"heard": %s, "seen": 301.72, "written": 301.7}}}' \
            "${4:-false}" "$2" "$3" > "$1"
    }
    rwatch "$t/watch_ok.json" 301.2 301.201
    rwatch "$t/watch_inwin.json" 300.51 301.201
    rwatch "$t/watch_leak.json" 300.2 301.201
    rwatch "$t/watch_leak_ba.json" 301.2 300.525
    rwatch "$t/watch_timeout.json" 301.2 301.201 true
    rst() { verdict restore_cycle "$1" "$2" 1100.5 1100.52 1100.53 1100.56 -800.0 -800.0 "${3-1105.3}"; }
    got="$(rst "$t/state_up.json" "$t/watch_ok.json")"
    [[ "$got" == $'OK 300.500\t300.520\t300.530\t300.560\t301.200\t301.201\t0.701\t1.200\t305.000\t3.300\t305.300\t4.800\t0.300\t0.0\t-' ]] \
        && ok "restore: four tc instants, both first frames, daemon 0.701 / report 1.200 / the up pass 3.300 later / graph 4.800 from the FIRST end's call" \
        || red "restore gave '$got'"
    got="$(rst "$t/state_up.json" "$t/watch_inwin.json")"
    [[ "$got" == OK*"a->b heard inside its end's restore window, 10.0 ms after the call started"* ]] \
        && ok "restore: a frame heard inside its end's restore window is flagged, and kept" \
        || red "restore with a frame inside its window gave '$got'"
    expect BAD  "restore: a frame heard before the restore started means the cut leaked" "$(rst "$t/state_up.json" "$t/watch_leak.json")"
    expect BAD  "restore: b->a heard before ITS end's restore started is a leak too" "$(rst "$t/state_up.json" "$t/watch_leak_ba.json")"
    expect BAD  "restore: the watcher timed out"                         "$(rst "$t/state_up.json" "$t/watch_timeout.json")"
    expect BAD  "restore: no pass reported it up"                        "$(rst "$t/state_noup.json" "$t/watch_ok.json")"
    expect BAD  "restore: the graph never showed it up"                  "$(rst "$t/state_up.json" "$t/watch_ok.json" "")"
    # the watcher itself, on a report rewritten under it
    got="$(
        HB_REPORT_FILE="$t/rw_report.json"; RESTORE_WATCH_S=4
        wr() { "$VPY" -I -c 'import json, os, sys
p, ab, ba, wm = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
d = {"written_mono": wm, "directions": [
  {"tx": {"dpid": 1, "port": 3}, "rx": {"dpid": 3, "port": 1}, "last_heard_mono": ab},
  {"tx": {"dpid": 3, "port": 1}, "rx": {"dpid": 1, "port": 3}, "last_heard_mono": ba}]}
open(p + ".tmp", "w").write(json.dumps(d)); os.replace(p + ".tmp", p)' "$HB_REPORT_FILE" "$@"; }
        wr 100.0 100.0 100.1
        restore_watch_start "$t/rw_out.json" 1 3 3 1 || { echo "the watcher never got ready"; exit 0; }
        sleep 0.3; wr 105.0 100.0 105.1
        sleep 0.3; wr 110.0 100.0 110.1
        sleep 0.3; wr 110.0 110.0 110.2
        restore_watch_wait
        "$VPY" -I -c 'import json, sys
d = json.load(open(sys.argv[1])); f = d["first"]
print(f["ab"]["heard"], f["ba"]["heard"], f["ab"]["written"], f["ba"]["written"], d["timed_out"], f["ab"]["seen"] < f["ba"]["seen"])' "$t/rw_out.json"
    )" || got="the subshell died (rc $?)"
    [[ "$got" == "105.0 110.0 105.1 110.2 False True" ]] \
        && ok "restore_watch: the FIRST new frame per direction (105.0, not the later 110.0), with the report's written_mono" \
        || red "restore_watch gave '$got'"
    got="$( HB_REPORT_FILE="$t/rw_report.json"; RESTORE_WATCH_S=0.5
            restore_watch_start "$t/rw_out2.json" 1 3 3 1 || { echo "the watcher never got ready"; exit 0; }
            restore_watch_wait
            "$VPY" -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["timed_out"], sorted(d["first"]))' "$t/rw_out2.json" )" \
        || got="the subshell died (rc $?)"
    [[ "$got" == "True []" ]] && ok "restore_watch: nothing new within its limit is a time-out, not a hang" \
                              || red "restore_watch with nothing new gave '$got'"
    got="$( HB_REPORT_FILE="$t/nonexistent_report.json"; RESTORE_WATCH_S=2
            restore_watch_start "$t/rw_out3.json" 1 3 3 1 && echo "ready?!" || echo "not ready"
            restore_watch_wait
            "$VPY" -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["timed_out"], d.get("error"))' "$t/rw_out3.json" )" \
        || got="the subshell died (rc $?)"
    [[ "$got" == $'not ready\nTrue the report did not name both directions' ]] \
        && ok "restore_watch: a report without the cable is said at once, not waited on" \
        || red "restore_watch without a report gave '$got'"
    # the instants themselves: in this shell, around each tc call, the first call at the plan
    got="$(
        netem_attach_point() { echo root; }
        run_tc() { sleep 0.02; }
        revert_link_loss() { local d="${INJECTED_IFACES[0]}"; INJECTED_IFACES=(); sleep 0.01; [[ "$d" != s3-eth1 ]]; }
        fail() { echo "FAIL $*" >&2; }
        INJECTED_IFACES=()
        target="$(awk -v m="$(mono)" 'BEGIN{printf "%.3f", m + 0.3}')"
        off="$(mono_offset)"
        cut_link 1 3 3 1 "$target" || echo "cut failed" >&2
        cut_ifaces="${INJECTED_IFACES[*]}"
        restore_link && rrc=0 || rrc=$?
        printf '%s\n' "$CUT_A_START $CUT_A_END $CUT_B_START $CUT_B_END $RESTORE_A_START $RESTORE_A_END $RESTORE_B_START $RESTORE_B_END $T_CUT" \
               "$cut_ifaces|${INJECTED_IFACES[*]}|$rrc" "$target $off"
    )" || got="the subshell died (rc $?)"
    stamps="$(sed -n 1p <<<"$got")"; ifaces="$(sed -n 2p <<<"$got")"; plan="$(sed -n 3p <<<"$got")"
    if [[ "$(wc -w <<<"$stamps")" == 9 ]] && ! tr ' ' '\n' <<<"$stamps" | /usr/bin/grep -qvE '^[0-9]+\.[0-9]{6}$'; then
        ok "cut_link/restore_link: every instant is \$EPOCHREALTIME (µs, read in this shell -- a forked date gives ns)"
    else
        red "cut_link/restore_link instants are not \$EPOCHREALTIME: '$stamps'"
    fi
    if awk -v s="$stamps" 'BEGIN{n = split(s, a, " "); for (i = 2; i <= n; i++) if (a[i] < a[i-1]) exit 1;
                                 if (a[2] - a[1] < 0.02 || a[4] - a[3] < 0.02) exit 1}'; then
        ok "cut_link/restore_link: A before B, each window holds its whole call, the restore after the cut"
    else
        red "cut_link/restore_link instants out of order or too narrow: '$stamps'"
    fi
    if awk -v s="$stamps" -v p="$plan" 'BEGIN{split(s, a, " "); split(p, q, " "); m = a[1] + q[2];
                                          exit !(m >= q[1] - 0.002 && m <= q[1] + 0.25)}'; then
        ok "cut_link: the first tc call starts at the planned instant, not before (the attach points were read first)"
    else
        red "cut_link: the first call started off the plan: stamps '$stamps', plan and offset '$plan'"
    fi
    [[ "$ifaces" == "s1-eth3 s3-eth1|s3-eth1|1" ]] \
        && ok "restore_link: an end that could not be cleaned stays on record (rc 1, still in INJECTED_IFACES)" \
        || red "restore_link left '$ifaces' (want 's1-eth3 s3-eth1|s3-eth1|1')"
    # the glue: cut_cycle and restore_cycle on stubbed captures, the real verdicts
    got="$(
        mono_offset() { echo -800.0; }
        cut_at_phase() { CUT_A_START=1000.01; CUT_A_END=1000.02; CUT_B_START=1000.03; CUT_B_END=1000.05; }
        graph_until() { echo 1020.33 > "$4.at_wall"; echo 20.3 > "$4.elapsed"; echo "OK stub"; }
        report_dirs() { echo "199.995 200.0"; }
        get_json() { cp "$t/$CC_STATE" "$2"; }
        note() { local m="$*"; echo "N ${m:0:110}"; }
        judge() { echo "J $2: ${1:0:48}"; }
        CA=1; CAP=3; CB=3; CBP=1; TIMEOUT_S=15; WATCHDOG_S=5; DETECT_BOUND_S=20
        CC_STATE=state_late.json; cut_cycle "T" "$t/cc_graph.json" "$t/cc_state.json" 0.02 1
        echo "STRICT $CYCLE_STRICT ROW $(cut -f9,11 <<<"$CYCLE_ROW" | tr '\t' ' ')"
        echo "LIST ${STRICT_OVER_LIST:0:60}"
        CC_STATE=state_nopass.json; cut_cycle "U" "$t/cc_graph2.json" "$t/cc_state2.json" 0.02 1
        echo "STRICT $CYCLE_STRICT FIELDS $(awk -F'\t' '{print NF}' <<<"$CYCLE_ROW")"
    )" || got="the subshell died (rc $?)"
    # [Co-developed with claude code -- Adam] The judge's F1 (09-26, on 1a3ebd7f): the cycle is
    # measured against the strict bound, and "20 s + what was measured" is only a note beside it.
    # Adam's ruling (09-27): 20.320 s is OVER, DISCLOSED -- a note naming it, the line kept for
    # strict_conclude -- never judged OK and never a failure; an unreadable row is still BAD.
    if /usr/bin/grep -qF "N T detection time (disclosed, not a failure): detection 20.320 s is OVER the strict 20" <<<"$got" \
       && /usr/bin/grep -qF "N T budget, 20 s + what was measured (a diagnostic, never the verdict): OK detection 20.320 s -- OVER" <<<"$got" \
       && ! /usr/bin/grep -qF "J T detection time" <<<"$got" \
       && /usr/bin/grep -qF "LIST T: detection 20.320 s is OVER the strict 20 s by 0.320 s" <<<"$got" \
       && /usr/bin/grep -qF "STRICT OVER+0.320 ROW 20.320 220.080" <<<"$got" \
       && /usr/bin/grep -qF "J U detection time: BAD both directions is_up:false (no phase" <<<"$got" \
       && /usr/bin/grep -qF "STRICT ? FIELDS 18" <<<"$got"; then
        ok "cut_cycle: the row, the strict line (OVER at 20.320 s, disclosed and kept for the conclusion), the budget only as a note, OVER+0.320; with no record, 18 '?' and the graph poll alone"
    else
        red "cut_cycle gave: $(tr '\n' '|' <<<"$got")"
    fi
    got="$(
        mono_offset() { echo -800.0; }
        restore_watch_start() { cp "$t/watch_ok.json" "$1"; }
        restore_watch_wait() { :; }
        restore_link() { RESTORE_A_START=1100.5; RESTORE_A_END=1100.52; RESTORE_B_START=1100.53; RESTORE_B_END=1100.56; }
        graph_until() { echo 1105.3 > "$4.at_wall"; echo 9.99 > "$4.elapsed"; echo "OK stub"; }
        get_json() { cp "$t/state_up.json" "$2"; }
        note() { :; }
        judge() { echo "J $2: $1"; }
        CA=1; CAP=3; CB=3; CBP=1; RESTORE_BOUND_S=20
        restore_cycle "R" "$t/rc_graph.json" "$t/rc_state.json" "$t/rc_watch.json"
        echo "RESTORE $(cut -f12 <<<"$RESTORE_ROW")"
    )" || got="the subshell died (rc $?)"
    if /usr/bin/grep -qF "J R recovery time: OK both directions is_up:true again after 4.8 s" <<<"$got" \
       && /usr/bin/grep -qF "RESTORE 4.800" <<<"$got"; then
        ok "restore_cycle: the recovery time is the record's (4.8 s from the first end's call), not the poll's 9.99 s from the last tc"
    else
        red "restore_cycle gave: $(tr '\n' '|' <<<"$got")"
    fi
    # --- H5's report sampler, EXECUTED (live H5 on cafd518a, 09-26 15:32Z) --------------------------
    # [Co-developed with claude code -- Adam] The sampler died at compile time on the live run (a
    # backslash inside an f-string expression, a SyntaxError on the machine's Python 3.13) with its
    # stderr on /dev/null, and 50_samples.tsv was never written; no test had ever run its text.
    # Here the REAL SAMPLER_PY -- this script's own variable -- runs through the real sampler_start /
    # sampler_stop against a fake report rewritten atomically the way the daemon rewrites it: missing,
    # running, running with a counter moved, stopped with final counters, missing again, a second
    # session. The rows must say so, in order, under the header; the stopped row's final counters
    # must reach the ruling-4 check; the stop path must take one last sample.
    st_sampler() {   # st_sampler -> the samples file's path on stdout (and the helpers' notes on 3)
        local d="$t/h5s" rep i
        mkdir -p "$d/run"
        rep="$d/report.json"
        wr() {   # wr <status> <session> <hosts> <between> -- one atomic rewrite, as the daemon does
            "$VPY" -I -c 'import json, os, sys
p, st, se, h, b = sys.argv[1:6]
doc = {"format": 1, "source": "heartbeat", "status": st, "session": se, "pid": 4242,
       "written_wall": 1000.5, "stop_reason": "SIGTERM" if st == "stopped" else None,
       "side_effects": {"forwarded_to_hosts": int(h), "forwarded_between_switches": int(b),
                        "misdelivered": 0, "foreign_frames": 0},
       "directions": [{"id": 1, "heard": 3 + int(b), "tx": {"dpid": 1, "port": 2}, "rx": {"dpid": 2, "port": 2}},
                      {"id": 2, "heard": 5, "tx": {"dpid": 2, "port": 2}, "rx": {"dpid": 1, "port": 2}}]}
open(p + ".tmp", "w").write(json.dumps(doc)); os.replace(p + ".tmp", p)' "$rep" "$@"
        }
        (   RUN="$d/run"; HB_REPORT_FILE="$rep"; SAMPLER_PID=""; SAMPLER_STOP=""; SAMPLER_INTERVAL_S=0.1
            VERDICT_RC=0; VERDICT_WHY=""
            note() { echo "note: $*" >&3; }; fail() { echo "fail: $*" >&3; }; bad() { echo "bad: $*" >&3; }
            sampler_start "$d/samples.tsv" && echo "started rc 0" >&3 || echo "started rc $?" >&3
            sleep 0.5
            wr running aaaa 0 0; sleep 0.5
            # [Co-developed with claude code -- Adam] an exercise controller, as far as argv goes, for
            # the next reads (M-3: the sampler records which ones are alive)
            "$VPY" -c 'import time; time.sleep(1.2)' /x/tools/p4_exercise/run_external_controller.py pkg c.py &
            echo "controller $!" >&3
            wr running aaaa 0 1; sleep 0.5
            wr stopped aaaa 2 3; sleep 0.5
            rm -f "$rep"; sleep 0.5
            wr running bbbb 0 0; sleep 0.3
            sampler_stop
            echo "stopped; pid now '${SAMPLER_PID}'" >&3 ) 3> "$d/notes.txt"
        echo "$d"
    }
    # (every read below ends `|| true`: under this script's set -e a failing $( ) in an assignment
    # would end the self-test silently instead of printing its red line)
    d="$(st_sampler)" || true
    # [Co-developed with claude code -- Adam] The external judge's M2 (09-28): the report's
    # written_wall and stop_reason (a killed daemon's stale "running"; why a session stopped) and
    # the daemon's other two counters are on every row too -- ten fields.
    got="$(awk -F'\t' 'NR == 1 {next} {k = $2 " " $3 " " $5 " " $6 " " $7 " " $8 " " $11; if (k != last) {printf "%s|", k; last = k}}' "$d/samples.tsv" 2>/dev/null)" || true
    want="absent - 0 0 -  -|running aaaa 0 0 1000.5  1:2>2:2=3,2:2>1:2=5|running aaaa 0 1 1000.5  1:2>2:2=4,2:2>1:2=5|stopped aaaa 2 3 1000.5 SIGTERM 1:2>2:2=6,2:2>1:2=5|absent - 0 0 -  -|running bbbb 0 0 1000.5  1:2>2:2=3,2:2>1:2=5|"
    local hdr=$'wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\twritten_wall\tstop_reason\tmisdelivered\tforeign_frames\theard\tcontrollers'
    if [[ "$(head -1 "$d/samples.tsv" 2>/dev/null)" == "$hdr" && "$got" == "$want" ]] \
       && awk -F'\t' 'NR > 1 && (NF != 12 || $1 !~ /^[0-9]+\.[0-9]$/) {bad = 1} END {exit bad}' "$d/samples.tsv"; then
        ok "H5 sampler: the real SAMPLER_PY writes its header and one 12-field row per read (written_wall, stop_reason and every direction's heard included), through missing, running, stopped (final counters) and a second session"
    else
        red "H5 sampler rows: header '$(head -1 "$d/samples.tsv" 2>/dev/null)', rows '$got' (want '$want'); $(tr '\n' ' ' < "$d/notes.txt" 2>/dev/null)"
    fi
    # [Co-developed with claude code -- Adam] M-3: the controllers alive at each read, by pid.
    local cpid; cpid="$(sed -n 's/^controller //p' "$d/notes.txt" 2>/dev/null)"
    got="$(awk -F'\t' -v p="$cpid" 'NR > 1 {n++; split($12, a, ","); for (i in a) if (a[i] == p) {s++; break}} END {printf "%d of %d", s, n}' "$d/samples.tsv" 2>/dev/null)" || true
    [[ -n "$cpid" && "$got" =~ ^([1-9][0-9]*)\ of\ ([0-9]+)$ ]] && (( BASH_REMATCH[1] < BASH_REMATCH[2] )) \
        && ok "🔴 H5 sampler: the exercise controller (pid $cpid) is in the controllers column while it lives, and only then ($got reads)" \
        || red "🔴 H5 sampler controllers column: '$cpid' in $got reads"
    got="$(tail -1 "$d/samples.tsv" 2>/dev/null | cut -f2,3)" || true
    [[ "$got" == $'running\tbbbb' ]] && /usr/bin/grep -q '^started rc 0$' "$d/notes.txt" \
        && ok "  sampler_start said it had started, and the stop path took a last sample of the report as it stood" \
        || red "  sampler start/stop: last row '$got', notes: $(tr '\n' ' ' < "$d/notes.txt" 2>/dev/null)"
    printf 'exercise\twhich\trc\tverdict\treport\n' > "$d/table_none.tsv"
    expect STOP "H5 sampler: a stopped session's final forwarded_to_hosts reaches ruling 4" \
        "$(verdict h5_heartbeat "$d/samples.tsv" "$d/table_none.tsv" "$(date +%s)" "")"
    # a sampler that cannot start: sampler_start must say so and answer 1, its stderr kept
    got="$( d2="$t/h5s_broken"; mkdir -p "$d2"
            RUN="$d2"; HB_REPORT_FILE="$d2/none.json"; SAMPLER_PID=""; SAMPLER_STOP=""
            SAMPLER_PY='print(f"{d.get(\"status\")}")'
            fail() { echo "fail: $*"; }; note() { :; }; bad() { :; }
            sampler_start "$d2/samples.tsv"; echo "rc=$? pid='$SAMPLER_PID'"
            [[ -s "$d2/50_sampler.err" ]] && echo "err kept: $(grep -c SyntaxError "$d2/50_sampler.err")" )" || true
    if [[ "$got" == *"fail: H5: the report sampler did not start"* && "$got" == *"rc=1 pid=''"* && "$got" == *"err kept: 1"* ]]; then
        ok "  a sampler that dies at compile time: sampler_start fails the run (rc 1), its SyntaxError kept in 50_sampler.err"
    else
        red "  a sampler that cannot start: $(tr '\n' ' ' <<<"$got")"
    fi
    # the stop path's last read, made deterministic: at 1 s reads, a `stopped` rewrite and the
    # stop asked for in the same breath are on record only because the sampler reads once more
    # when it sees the stop file (the daemon's final counters, however the timing falls)
    got="$( d3="$t/h5s_final"; mkdir -p "$d3"
            RUN="$d3"; HB_REPORT_FILE="$d3/report.json"; SAMPLER_PID=""; SAMPLER_STOP=""; SAMPLER_INTERVAL_S=1.0
            note() { :; }; fail() { echo "fail: $*"; }; bad() { :; }
            wr3() { "$VPY" -I -c 'import json, os, sys
p = sys.argv[1]
doc = {"status": sys.argv[2], "session": "cccc", "pid": 1,
       "side_effects": {"forwarded_to_hosts": int(sys.argv[3]), "forwarded_between_switches": int(sys.argv[4])}}
open(p + ".t", "w").write(json.dumps(doc)); os.replace(p + ".t", p)' "$HB_REPORT_FILE" "$@"; }
            wr3 running 0 0
            sampler_start "$d3/samples.tsv" >/dev/null
            sleep 1.3
            wr3 stopped 5 6
            sampler_stop
            tail -1 "$d3/samples.tsv" | cut -f2,3,5,6 )" || true
    [[ "$got" == $'stopped\tcccc\t5\t6' ]] \
        && ok "  the stop path reads once more: a 'stopped' rewrite just before sampler_stop is on record (final counters 5, 6)" \
        || red "  the stop path's last read: last row '$got'"
    # report_dirs and graph_until's elapsed branch: the live path runs both on every cut, and
    # nothing else in this self-test did (the embedded-program sweep of 09-27)
    got="$(HB_REPORT_FILE="$t/report_phase.json" report_dirs 1 3 3 1)" || true
    [[ "$got" == "100.250000 100.500000" ]] && ok "report_dirs: each direction's last_heard_mono, a->b then b->a (100.25, 100.5)" \
                                            || red "report_dirs gave '$got'"
    got="$(HB_REPORT_FILE="$t/report_phase.json" report_dirs 1 4 4 2)" || true
    [[ -z "$got" ]] && ok "  report_dirs with one direction missing: no answer" || red "  report_dirs with one direction missing gave '$got'"
    mkdir -p "$t/k2/ndt"; cp "$t/graph_up.json" "$t/k2/ndt/get_graph_data"
    got="$( T_CUT="$(awk -v n="$EPOCHREALTIME" 'BEGIN{printf "%.6f", n - 1.5}')"; KERNEL_URL="file://$t/k2"
            graph_until 2 0.1 edges_up "$t/gu2.json" "$t/model.json" >/dev/null; cat "$t/gu2.json.elapsed" )" || true
    if [[ "$got" =~ ^[0-9]+\.[0-9]{2}$ ]] && awk -v e="$got" 'BEGIN{exit !(e >= 1.5 && e < 3.5)}'; then
        ok "graph_until after a cut: the elapsed time from T_CUT to the poll that said OK ($got s after a cut 1.5 s back)"
    else
        red "graph_until after a cut gave elapsed '$got'"
    fi
    # --- H1's exit, read where Adam reads it: the run's LAST lines (the judge's F1 and 8.2) --------
    # [Co-developed with claude code -- Adam] One stubbed cycle through the real cut_cycle, H1's
    # strict conclusion and the real teardown (w_finish -> finish) with a fake ndt. 🔴 Adam's
    # ruling (09-27, at most about 20 s): an OVER cycle ends the run in PASS, and the line right
    # above the PASS repeats that cycle's own strict line VERBATIM, with the count; a cycle within
    # 20 s ends in PASS with no such line (the control); an earlier failure stays the last line with
    # the disclosure above it, and a ruling-4 STOP still leads the last line.
    st_h1() {   # st_h1 <state fixture> <kernel-down wall> <earlier failure or -> <stop 0|1> -> the run's output
        local d
        d="$(mktemp -d "$t/h1-XXXXXX")"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/ndt"; chmod +x "$d/ndt"
        ( STEP=08_heartbeat; RUN="$d/run"; mkdir -p "$RUN"; CLAIMED=1; VERDICT_RC=0; VERDICT_WHY=""; FABRIC_UP=1
          INJECTED_IFACES=(); NDT="$d/ndt"; REAL_NDT="$d/ndt"; APP_KNOB="$d/none"
          KNOB_ENTRY_COPY=""; TEL_ENTRY_COPY=""; CTRL_PID=""; TEARDOWN_DOWN_RC=""; SAMPLER_PID=""
          mono_offset() { echo -800.0; }
          cut_at_phase() { CUT_A_START=1000.01; CUT_A_END=1000.02; CUT_B_START=1000.03; CUT_B_END=1000.05; }
          graph_until() { echo "$ST_DOWN" > "$4.at_wall"; echo 20.3 > "$4.elapsed"; echo "OK stub"; }
          report_dirs() { echo "199.995 200.0"; }
          get_json() { cp "$t/$ST_STATE" "$2"; }
          CA=1; CAP=3; CB=3; CBP=1; TIMEOUT_S=15; WATCHDOG_S=5; DETECT_BOUND_S=20
          ST_STATE="$1"; ST_DOWN="$2"
          [[ "$3" == - ]] || fail "$3"
          cut_cycle "H1 cycle 1" "$RUN/31_graph_cut_1.json" "$RUN/32_switch_state_cut_1.json" 0.02 1
          strict_conclude H1
          (( $4 == 1 )) && judge "STOP ruling 4: a stubbed host-port frame" "H1 ruling 4"
          ( exit 0 ); w_finish ) 2>&1
    }
    out="$(st_h1 state_late.json 1020.33 - 0)" || true
    got="$(tail -1 <<<"$out")"; above="$(tail -2 <<<"$out" | head -1)"
    cyc="$(sed -n 's/^ *H1 cycle 1 detection time (disclosed, not a failure): //p' <<<"$out" | head -1)"
    if [[ "$got" == "PASS 08_heartbeat" && "$cyc" == "detection 20.320 s is OVER the strict 20 s by 0.320 s"* \
          && "$above" == "NOTE 08_heartbeat -- H1: 1 of 1 cycle(s) over the strict 20 s -- disclosed, not a failure (Adam, 09-27: at most about 20 s"* \
          && "$above" == *" -- H1 cycle 1: $cyc" && "$out" == *"one run samples one psi"* ]]; then
        ok "H1's last lines: one cycle at 20.320 s -- the run PASSes, and the line above the PASS repeats that cycle's strict line verbatim, with the count (the one-psi caveat above)"
    else
        red "H1's last line with an OVER cycle was: '$got' (above it: '$above')"
    fi
    out="$(st_h1 state_passes.json 1015.9 - 0)" || true
    got="$(tail -1 <<<"$out")"
    if [[ "$got" == "PASS 08_heartbeat" && "$out" == *"H1: all 1 cycle(s) within the strict 20 s"*"one run samples one psi"* ]] \
          && ! /usr/bin/grep -q '^NOTE ' <<<"$out"; then
        ok "  the control: a cycle within 20 s ends PASS with nothing disclosed, and says it is one psi's answer"
    else
        red "  H1's last line with a cycle within 20 s was: '$got'"
    fi
    out="$(st_h1 state_late.json 1020.33 "an earlier failure" 0)" || true
    got="$(tail -1 <<<"$out")"; above="$(tail -2 <<<"$out" | head -1)"
    if [[ "$got" == "FAIL 08_heartbeat -- an earlier failure" \
          && "$above" == "NOTE 08_heartbeat -- H1: 1 of 1 cycle(s) over the strict 20 s"*" -- H1 cycle 1: detection 20.320 s is OVER"* ]]; then
        ok "  an earlier failure stays the last line, and the over-cycle is still disclosed right above it"
    else
        red "  H1's last line after an earlier failure was: '$got' (above it: '$above')"
    fi
    out="$(st_h1 state_late.json 1020.33 - 1)" || true
    got="$(tail -1 <<<"$out")"; above="$(tail -2 <<<"$out" | head -1)"
    if [[ "$got" == "FAIL 08_heartbeat -- STOP (ruling 4)"* \
          && "$above" == "NOTE 08_heartbeat -- H1: 1 of 1 cycle(s) over the strict 20 s"* ]]; then
        ok "  a ruling-4 STOP still leads the last line, the over-cycle disclosed above it"
    else
        red "  H1's last line with a STOP after an OVER cycle was: '$got' (above it: '$above')"
    fi
    # [Co-developed with claude code -- Adam] The opus judge's F1 (09-27): the H1 loop's own early
    # exit -- an OVER cycle, then a restore that could not remove the netem (`|| { fail ...; exit 1; }`)
    # -- through the real EXIT trap, before strict_conclude H1 ran.
    st_h1_exit() {   # -> the run's output
        local d
        d="$(mktemp -d "$t/h1x-XXXXXX")"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/ndt"; chmod +x "$d/ndt"
        ( STEP=08_heartbeat; RUN="$d/run"; mkdir -p "$RUN"; CLAIMED=1; VERDICT_RC=0; VERDICT_WHY=""; FABRIC_UP=1
          INJECTED_IFACES=(); NDT="$d/ndt"; REAL_NDT="$d/ndt"; APP_KNOB="$d/none"
          KNOB_ENTRY_COPY=""; TEL_ENTRY_COPY=""; CTRL_PID=""; TEARDOWN_DOWN_RC=""; SAMPLER_PID=""
          mono_offset() { echo -800.0; }
          cut_at_phase() { CUT_A_START=1000.01; CUT_A_END=1000.02; CUT_B_START=1000.03; CUT_B_END=1000.05; }
          graph_until() { echo 1020.33 > "$4.at_wall"; echo 20.3 > "$4.elapsed"; echo "OK stub"; }
          report_dirs() { echo "199.995 200.0"; }
          get_json() { cp "$t/state_late.json" "$2"; }
          CA=1; CAP=3; CB=3; CBP=1; TIMEOUT_S=15; WATCHDOG_S=5; DETECT_BOUND_S=20
          trap w_finish EXIT
          cut_cycle "H1 cycle 1" "$RUN/31_graph_cut_1.json" "$RUN/32_switch_state_cut_1.json" 0.02 1
          fail "H1 cycle 1: could not remove the netem"; exit 1 ) 2>&1
    }
    out="$(st_h1_exit)" || true
    got="$(tail -1 <<<"$out")"; above="$(tail -2 <<<"$out" | head -1)"
    if [[ "$got" == "FAIL 08_heartbeat -- H1 cycle 1: could not remove the netem" \
          && "$above" == "NOTE 08_heartbeat -- H1, cut short: 1 of 1 cycle(s) over the strict 20 s"*" -- H1 cycle 1: detection 20.320 s is OVER"* ]]; then
        ok "  an early exit after an OVER cycle: the FAIL is the last line, the over-cycle disclosed right above it (w_finish concludes)"
    else
        red "  H1's last lines after an early exit following an OVER cycle were: '$got' (above it: '$above')"
    fi
    # [Co-developed with claude code -- Adam] The AEG judge's 09-28 round: the same exit from H3 (a
    # w_finish that assumed H1 would name the wrong phase), an early exit whose cycles were all
    # within 20 s (concluded, nothing disclosed), a clean run (no "cut short" at all), and N-1 --
    # TERM sent to the run's own shell mid-H1 with nothing failed before it.
    st_exit() {   # st_exit <cut_cycle label> <state fixture> <kernel-down wall> <exit|clean> -> output
        local d
        d="$(mktemp -d "$t/stx-XXXXXX")"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/ndt"; chmod +x "$d/ndt"
        ( STEP=08_heartbeat; RUN="$d/run"; mkdir -p "$RUN"; CLAIMED=1; VERDICT_RC=0; VERDICT_WHY=""; FABRIC_UP=1
          INJECTED_IFACES=(); NDT="$d/ndt"; REAL_NDT="$d/ndt"; APP_KNOB="$d/none"
          KNOB_ENTRY_COPY=""; TEL_ENTRY_COPY=""; CTRL_PID=""; TEARDOWN_DOWN_RC=""; SAMPLER_PID=""
          mono_offset() { echo -800.0; }
          cut_at_phase() { CUT_A_START=1000.01; CUT_A_END=1000.02; CUT_B_START=1000.03; CUT_B_END=1000.05; }
          graph_until() { echo "$ST_DOWN" > "$4.at_wall"; echo 20.3 > "$4.elapsed"; echo "OK stub"; }
          report_dirs() { echo "199.995 200.0"; }
          get_json() { cp "$t/$ST_STATE" "$2"; }
          CA=1; CAP=3; CB=3; CBP=1; TIMEOUT_S=15; WATCHDOG_S=5; DETECT_BOUND_S=20
          ST_STATE="$2"; ST_DOWN="$3"
          arm_traps
          cut_cycle "$1" "$RUN/31_graph_cut_1.json" "$RUN/32_switch_state_cut_1.json" 0.02 1
          if [[ "$4" == clean ]]; then strict_conclude "${1%% *}"; exit 0; fi
          fail "$1: could not remove the netem"; exit 1 ) 2>&1
    }
    out="$(st_exit H3 state_late.json 1020.33 exit)" || true
    got="$(tail -1 <<<"$out")"; above="$(tail -2 <<<"$out" | head -1)"
    if [[ "$got" == "FAIL 08_heartbeat -- H3: could not remove the netem" \
          && "$above" == "NOTE 08_heartbeat -- H3, cut short: 1 of 1 cycle(s) over the strict 20 s"*" -- H3: detection 20.320 s is OVER"* ]]; then
        ok "  an early exit from H3 after an OVER cycle: concluded as H3, the NOTE right above the FAIL"
    else
        red "  H3's last lines after an early exit following an OVER cycle were: '$got' (above it: '$above')"
    fi
    out="$(st_exit "H1 cycle 1" state_passes.json 1015.9 exit)" || true
    got="$(tail -1 <<<"$out")"; above="$(tail -2 <<<"$out" | head -1)"
    if [[ "$got" == "FAIL 08_heartbeat -- H1 cycle 1: could not remove the netem" && "$above" == "raw: "* \
          && "$out" == *"H1, cut short: all 1 cycle(s) within the strict 20 s"* ]]; then
        ok "  an early exit whose cycles were all within 20 s: concluded (said in the body), nothing disclosed"
    else
        red "  an early exit with every cycle within 20 s ended: '$got' (above it: '$above')"
    fi
    out="$(st_exit "H1 cycle 1" state_passes.json 1015.9 clean)" || true
    if [[ "$(tail -1 <<<"$out")" == "PASS 08_heartbeat" && "$out" != *"cut short"* && "$out" == *"H1: all 1 cycle(s) within"* ]]; then
        ok "  a clean run concludes once, in its phase, and never says 'cut short'"
    else
        red "  a clean run's output said 'cut short' or did not PASS: '$(tail -1 <<<"$out")'"
    fi
    st_term() {   # st_term <send TERM: 1|0> [<arming: arm_traps|arm_step_traps>] -> output
        # (the H1 loop's own wait, a foreground sleep; arm_step_traps is what start_step arms, i.e.
        # a TERM between start_step and arm_traps -- the external judge's M3)
        local d
        d="$(mktemp -d "$t/term-XXXXXX")"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/ndt"; chmod +x "$d/ndt"
        ( STEP=08_heartbeat; RUN="$d/run"; mkdir -p "$RUN"; CLAIMED=1; VERDICT_RC=0; VERDICT_WHY=""; FABRIC_UP=1
          INJECTED_IFACES=(); NDT="$d/ndt"; REAL_NDT="$d/ndt"; APP_KNOB="$d/none"; SIGNAL_RC=""
          KNOB_ENTRY_COPY=""; TEL_ENTRY_COPY=""; CTRL_PID=""; TEARDOWN_DOWN_RC=""; SAMPLER_PID=""
          "${2:-arm_traps}"
          me=$BASHPID
          (( $1 )) && ( command sleep 0.4; kill -TERM "$me" ) &
          command sleep 2
          echo "the loop went on" ) 2>&1
    }
    out="$(st_term 1)" && rc_t=0 || rc_t=$?
    if [[ "$(tail -1 <<<"$out")" == "FAIL 08_heartbeat -- interrupted by SIGTERM before the run finished" \
          && "$out" != *"the loop went on"* ]]; then
        ok "🔴 TERM to the run's own shell mid-H1, nothing failed before: FAIL (interrupted by SIGTERM), never PASS"
    else
        red "TERM mid-H1 with nothing failed before it ended: '$(tail -1 <<<"$out")' (rc $rc_t)"
    fi
    # [Co-developed with claude code -- Adam] The external judge's M3 (09-28): the rc IS 143, carried
    # through finish -- and a TERM between start_step and arm_traps (start_step's own traps) is the
    # same FAIL with the same rc.
    [[ "$rc_t" == 143 ]] && ok "🔴 and the run exits 143, the signal's code" \
        || red "a TERM'd run exited $rc_t, not 143"
    out="$(st_term 1 arm_step_traps)" && rc_t=0 || rc_t=$?
    if [[ "$(tail -1 <<<"$out")" == "FAIL 08_heartbeat -- interrupted by SIGTERM before the run finished" && "$rc_t" == 143 ]]; then
        ok "🔴 TERM before arm_traps (start_step's traps): FAIL, rc 143"
    else
        red "TERM before arm_traps ended: '$(tail -1 <<<"$out")' (rc $rc_t)"
    fi
    out="$(st_term 0)" || true
    [[ "$(tail -1 <<<"$out")" == "PASS 08_heartbeat" && "$out" == *"the loop went on"* ]] \
        && ok "  the control: no signal, the same harness PASSes" \
        || red "  the no-signal control did not PASS: '$(tail -1 <<<"$out")'"
    # [Co-developed with claude code -- Adam] N-4: the strict verdict itself, against a row whose
    # detection is inside, over, and past the hard ceiling.
    srow() { printf '1\t2\t3\t4\t5\t6\t7\t8\t%s\t10\t11\t12\t13\t14\t15\t16\t17\t18' "$1"; }
    expect OK   "strict 19.5 s is within 20 s"                         "$(verdict strict "$(srow 19.5)" 20)"
    expect OVER "strict 21 s is OVER, disclosed"                       "$(verdict strict "$(srow 21)" 20)"
    expect BAD  "strict 36 s is past the 35 s ceiling: a FAIL"         "$(verdict strict "$(srow 36)" 20)"
    # graph_until before any cut: no instant to count from, and no unbound T_CUT under set -u
    mkdir -p "$t/k/ndt"; cp "$t/graph_up.json" "$t/k/ndt/get_graph_data"
    # (`|| got=`: under set -e a subshell that dies -- an unbound variable -- would take the whole
    # self-test with it, silently; this way it is a red line.)
    got="$( unset T_CUT; KERNEL_URL="file://$t/k"; graph_until 2 0.1 edges_up "$t/gu.json" "$t/model.json" )" \
        || got="the subshell died (rc $?)"
    if [[ "$got" == OK* && "$(cat "$t/gu.json.elapsed" 2>/dev/null)" == n/a \
          && "$(cat "$t/gu.json.at_wall" 2>/dev/null)" =~ ^[0-9]+\.[0-9]{6}$ ]]; then
        ok "graph_until before any cut: OK, 'n/a' to count from, and the poll's own µs stamp"
    else
        red "graph_until before any cut gave '$got' (elapsed '$(cat "$t/gu.json.elapsed" 2>/dev/null)')"
    fi
    local n_arms; n_arms="$(wc -w <<<"$HB_ARMS")"
    # [Co-developed with claude code -- Adam] 17 until 09-27; the external arms are in it since.
    [[ "$n_arms" == 20 ]] && ok "HB_ARMS names 20 arms (segment S's 20 running arms, the 3 external ones detect only)" \
                          || red "HB_ARMS names $n_arms arms, not 20"
    [[ " $(tr '\n' ' ' <<<"$HB_ARMS") " == *" p4runtime/skeleton p4runtime/solution flowcache/solution "* ]] \
        && ok "HB_ARMS names the 3 external arms" || red "HB_ARMS does not name p4runtime/skeleton, p4runtime/solution and flowcache/solution"
    # [Co-developed with claude code -- Adam] Adam's ruling A (09-27): an OVER cycle reaches the
    # last lines only through strict_conclude, so every cut_cycle on the LIVE path must be followed
    # by one before the next phase (H1 after its loop, H3 after its one cycle). Read from this file
    # -- the live path runs no self-test of its own.
    local unconcluded
    unconcluded="$(awk -v tag='if [[ "${1:-}" == "--self-test" ]]; then' '
        index($0, tag) == 1 {live = 1; next}
        live && /^ *cut_cycle "/ {if (open) out = out " " open; open = NR}
        live && /^strict_conclude / {open = 0}
        live && (/^# === phase / || /^say "done/) {if (open) out = out " " open; open = 0}
        END {if (open) out = out " " open; print out}' "$LIVE_DIR_08/08_heartbeat.sh")"
    if [[ -z "${unconcluded// /}" ]] && /usr/bin/grep -q '^strict_conclude H3$' "$LIVE_DIR_08/08_heartbeat.sh"; then
        ok "every live cut_cycle is concluded before the next phase (H1, H3), and an early exit is concluded by w_finish (the cell above): an OVER cycle anywhere reaches the last lines"
    else
        red "  a live cut_cycle with no strict_conclude after it (line(s)${unconcluded:- none; no strict_conclude H3})"
    fi

    # --- the teardown, walked with a fake ndt ----------------------------------------------------
    st_finish() {   # st_finish <FABRIC_UP> <down rc> -> "<last line>|<ndt calls>"
        local d out
        d="$(mktemp -d "$t/finish-XXXXXX")"
        printf '#!/usr/bin/env bash\necho "$1:${NDT_MEASURING-unset}" >> "%s/calls"\ncase "$1" in down) exit %s ;; *) exit 0 ;; esac\n' \
            "$d" "$2" > "$d/ndt"
        chmod +x "$d/ndt"
        out="$( STEP=08_heartbeat; RUN="$d/run"; mkdir -p "$RUN"; CLAIMED=1; VERDICT_RC=0; VERDICT_WHY=""; FABRIC_UP="$1"
                INJECTED_IFACES=(); NDT="$d/ndt"; REAL_NDT="$d/ndt"; APP_KNOB="$d/none"
                KNOB_ENTRY_COPY=""; TEL_ENTRY_COPY=""; CTRL_PID=""; TEARDOWN_DOWN_RC=""
                SAMPLER_PID=""; export NDT_MEASURING="left over from the caller"
                ( exit 0 ); w_finish 2>&1 )"
        printf '%s|%s' "$(tail -1 <<<"$out")" "$(paste -sd, "$d/calls" 2>/dev/null)"
    }
    got="$(st_finish 0 3)"
    [[ "$got" == "PASS 08_heartbeat|down:unset,release:unset" ]] \
        && ok "a run that took its own fabric down: finish's rc 3 is not a failure, then release" \
        || red "a run already down ended: $got"
    got="$(st_finish 1 0)"
    [[ "$got" == "PASS 08_heartbeat|down:unset,release:unset" ]] \
        && ok "  a clean down of a fabric that is up: PASS, released (the control)" \
        || red "  a clean down ended: $got"
    got="$(st_finish 1 5)"
    [[ "$got" == "FAIL 08_heartbeat -- NOT RELEASED"*"|down:unset,claim:unset,status:unset" ]] \
        && ok "🔴 a REFUSED down (rc 5): the claim is KEPT (re-claimed), never released, and the verdict says so first" \
        || red "🔴 a refused down ended: $got"
    got="$(st_finish 1 1)"
    [[ "$got" == "FAIL 08_heartbeat -- NOT RELEASED"*"|down:unset,claim:unset,status:unset" ]] \
        && ok "🔴 a down that did not verify clean (rc 1): kept, not released" \
        || red "🔴 an unverified down ended: $got"
    got="$(st_finish 1 3)"
    [[ "$got" == "FAIL 08_heartbeat -- 'ndt down' exited 3"*"|down:unset,release:unset" ]] \
        && ok "  a 3 while this run believes its fabric is up still fails it" \
        || red "  a 3 with the fabric believed up ended: $got"
    # 🔴 NEVER UNDER measuring= -- every ndt call above ran with NDT_MEASURING unset although the
    # caller exported one (the `:unset` on every call), and the phase wrappers do the same.
    d="$(mktemp -d "$t/nd-XXXXXX")"
    printf '#!/usr/bin/env bash\necho "$1:${NDT_MEASURING-unset}" >> "%s/calls"\nexit 0\n' "$d" > "$d/ndt"; chmod +x "$d/ndt"
    got="$( REAL_NDT="$d/ndt"; FABRIC_UP=1; export NDT_MEASURING=x; nd_down "$d/o" && echo "rc0 up=$FABRIC_UP" )"
    [[ "$got" == "rc0 up=0" && "$(cat "$d/calls")" == "down:unset" ]] \
        && ok "🔴 a phase's 'ndt down' runs without measuring= even when the caller exported one" \
        || red "🔴 nd_down: '$got', calls: $(paste -sd, "$d/calls")"

    # --- [Co-developed with claude code -- Adam] M-2: the treatment is the controls' code plus B -----
    # A real git repository: C on trunk, B on a branch, T = B merged locally onto C (as the README's
    # step 2 does), and identity_gate run from it, as H5 runs it, against C's recorded identity.
    local g="$t/idrepo" gi=(-c user.name=st -c user.email=st@example.invalid -c commit.gpgsign=false)
    mkdir -p "$g" && git -C "$g" init -q -b trunk && printf 'a\n' > "$g/a.txt" && printf 'k\n' > "$g/keep.txt" \
        && git -C "$g" add a.txt keep.txt && git "${gi[@]}" -C "$g" commit -q -m c \
        && git -C "$g" checkout -q -b b && printf 'b\n' > "$g/b.txt" && git -C "$g" add b.txt \
        && git "${gi[@]}" -C "$g" commit -q -m b && git -C "$g" checkout -q trunk \
        && printf 'theirs\n' >> "$g/keep.txt" || red "  (the identity repository could not be built)"
    local bsha; bsha="$(git -C "$g" rev-parse b)"
    ( REPO="$g"; "$VPY" "$LIVE_DIR/code_identity.py" record "$g" "$t/id_c.json" ) > /dev/null 2>&1 || true
    git "${gi[@]}" -C "$g" merge -q --no-ff --no-edit b 2>/dev/null || true
    got="$( REPO="$g"; identity_gate "$t/id_c.json" "$bsha" "$t/id_t.json" 2>&1; echo "rc=$?" )"
    [[ "$got" == *"SAME CODE APART FROM B"*"rc=0" ]] \
        && ok "  identity gate: B merged onto the controls' HEAD, the same uncommitted file: through (rc 0)" \
        || red "  identity gate, the good case: $got"
    got="$( REPO="$g"; identity_gate "$t/id_c.json" "0123456789abcdef0123456789abcdef01234567" "$t/id_t2.json" 2>&1; echo "rc=$?" )"
    [[ "$got" == *"is not the B commit under test"*"rc=3" ]] \
        && ok "🔴 identity gate: another B than the one named -- refused" || red "🔴 identity gate, another B: $got"
    got="$( REPO="$g"; identity_gate "$t/id_c.json" "" "$t/id_t3.json" 2>&1; echo "rc=$?" )"
    [[ "$got" == *"B_SHA is not"*"rc=3" ]] && ok "🔴 identity gate: no B_SHA -- refused" || red "🔴 identity gate, no B_SHA: $got"
    printf 'mine\n' > "$g/a.txt"
    got="$( REPO="$g"; identity_gate "$t/id_c.json" "$bsha" "$t/id_t4.json" 2>&1; echo "rc=$?" )"
    [[ "$got" == *"uncommitted: controls"*"rc=3" ]] \
        && ok "🔴 identity gate: a file changed in the shared checkout since the controls -- refused" \
        || red "🔴 identity gate, a new uncommitted file: $got"
    git -C "$g" checkout -q -- a.txt
    printf 'x\n' > "$g/c2.txt" && git -C "$g" add c2.txt && git "${gi[@]}" -C "$g" commit -q -m moved
    got="$( REPO="$g"; identity_gate "$t/id_c.json" "$bsha" "$t/id_t5.json" 2>&1; echo "rc=$?" )"
    [[ "$got" == *"rc=3" && "$got" == *"REFUSED"* ]] \
        && ok "🔴 identity gate: HEAD moved on past the merge -- refused" || red "🔴 identity gate, HEAD moved: $got"

    # --- the prelude, run on its own: its refusals and its defaults --------------------------------
    local pre="$t/prelude.sh"
    awk -v dir="$LIVE_DIR" '/^# --- end of prelude/ {exit} /^LIVE_DIR_08=/ {printf "LIVE_DIR_08=\"%s\"\n", dir; next} {print}' \
        "${BASH_SOURCE[0]}" > "$pre"
    got="$(env -u NDT_OWNER -u CLAIM_MINUTES "$BASH" "$pre" 2>&1; echo "rc=$?")"
    [[ "$got" == *"REFUSED 08_heartbeat -- nothing was started"*"rc=2" ]] \
        && ok "🔴 no NDT_OWNER: refused (rc 2) before _common.sh could default it" \
        || red "🔴 no NDT_OWNER: $got"
    got="$(env NDT_OWNER=st PART=nope "$BASH" "$pre" 2>&1; echo "rc=$?")"
    [[ "$got" == *"REFUSED"*"PART=nope"*"rc=2" ]] && ok "  an unknown PART is refused" || red "  PART=nope: $got"
    # [Co-developed with claude code -- Adam] M-1: H5 against a reference that is not a whole 06 is
    # refused before anything starts; a whole one passes the prelude.
    got="$(env NDT_OWNER=st PART=h5 OLD_06="$t/c1_only" "$BASH" "$pre" 2>&1; echo "rc=$?")"
    [[ "$got" == *"has 4 arm(s) in its 00_table.tsv, not 26"*"REFUSED 08_heartbeat -- OLD_06 is not a whole 06"*"rc=2" ]] \
        && ok "🔴 PART=h5 with a 4-arm OLD_06 (an ONLY= 06): refused (rc 2) before anything ran" \
        || red "🔴 PART=h5 OLD_06=<4 arms>: $got"
    got="$(env -u NDT_MEASURING NDT_OWNER=st PART=h5 OLD_06="$t/c1_full" "$BASH" -c 'source "$1" > /dev/null 2>&1 || exit 97; echo "through, OLD_06=$OLD_06"' _ "$pre" 2>&1; echo "rc=$?")"
    [[ "$got" == *"through, OLD_06=$t/c1_full"*"rc=0" ]] \
        && ok "  PART=h5 with a whole 06 as OLD_06 goes through the prelude, and keeps it" \
        || red "  PART=h5 OLD_06=<26 arms>: $got"
    st_prelude() {   # st_prelude <var> [VAR=value...] -- <var> after the prelude ran
        env -u "$1" -u NDT_MEASURING NDT_OWNER=st "${@:2}" "$BASH" -c \
            'source "$1" > /dev/null 2>&1 || exit 97; printf "%s|%s" "${!2-<unset>}" "${NDT_MEASURING-unset}"' _ "$pre" "$1"
    }
    got="$(st_prelude CLAIM_MINUTES)"
    [[ "$got" == "120|unset" ]] \
        && ok "🔴 CLAIM_MINUTES defaults to 120 and _common.sh's 45 does not shadow it" \
        || red "🔴 CLAIM_MINUTES after the prelude: $got"
    got="$(st_prelude CLAIM_MINUTES CLAIM_MINUTES=77)"
    [[ "$got" == "77|unset" ]] && ok "  a caller's CLAIM_MINUTES still wins" || red "  CLAIM_MINUTES=77 became $got"
    got="$(st_prelude CLAIM_MINUTES NDT_MEASURING=left-over)"
    [[ "$got" == "120|unset" ]] && ok "🔴 a caller's NDT_MEASURING is gone after the prelude" || red "  NDT_MEASURING after the prelude: $got"
    got="$(st_prelude NDT_OWNER)"
    [[ "$got" == "<unset>|unset" || "$got" == "st|unset" ]] && true
    got="$(env -u FAULTS_TC NDT_OWNER=st "$BASH" -c 'source "$1" >/dev/null 2>&1 || exit 97; printf "%s" "$FAULTS_TC"' _ "$pre")"
    [[ "$got" == "sudo -n mnexec -a 1 tc" ]] && ok "the tc route is mnexec by default (segment S's)" || red "  FAULTS_TC: $got"
    bash -n "${BASH_SOURCE[0]}" && ok "this script parses" || red "this script does not parse"
    [[ -r "$PREP" ]] && ok "census_prepare.py is where H4 finds it" || red "no census_prepare.py at $PREP"
    if (( rc == 0 )); then echo "SELF-TEST PASS"; else echo "SELF-TEST FAIL"; fi
    return $rc
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit $?
fi

# ================================================================================================
# the live run
# ================================================================================================

start_step 08_heartbeat
arm_traps

say "which code this run is about"
{
    echo "repo HEAD  $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel     $(sha256sum "$REPO/build/bin/ndtwin_kernel" 2>/dev/null | cut -c1-16 || echo absent)  build/bin/ndtwin_kernel"
    echo "helper     $(sha256sum "$LAB_HELPER" 2>/dev/null | cut -c1-16 || echo unreadable)  $LAB_HELPER (installed)"
    echo "helper     $(sha256sum "$REPO/tools/test_workflow/ndtwin-lab" | cut -c1-16)  tools/test_workflow/ndtwin-lab (this checkout)"
    for f in p4_proxy/proxy_agent/link_heartbeat.py p4_proxy/proxy_agent/topology_manager.py \
             p4_proxy/proxy_agent/main.py p4_proxy/proxy_agent/api_routes.py tools/test_workflow/ndt; do
        echo "source     $(sha256sum "$REPO/$f" | cut -c1-16)  $f"
    done
} | tee "$RUN/01_binaries.txt" | sed 's/^/   /'

# The installed helper must be this checkout's and must have the verb; a heartbeat must not
# already be running (the lab is free, so one would be somebody's leftover).
set +e
hb_status "$RUN/02_hb_status_before.txt"; HBRC=$?
set -e
sed 's/^/   /' "$RUN/02_hb_status_before.txt" | head -3
case "$HBRC" in
    3) note "no heartbeat is running (rc 3)" ;;
    0) die "a heartbeat is already running on a free lab -- somebody's leftover: 'sudo ndtwin-lab heartbeat stop' after you have read 02_hb_status_before.txt" ;;
    *) die "'sudo -n ndtwin-lab heartbeat status' answered $HBRC -- the installed helper has no heartbeat verb, or sudo refused it" ;;
esac
if ! cmp -s "$LAB_HELPER" "$REPO/tools/test_workflow/ndtwin-lab"; then
    die "the installed $LAB_HELPER is not this checkout's tools/test_workflow/ndtwin-lab"
fi
# tc through the route this run cuts with, BEFORE the claim (segment S's precheck_tc): a show
# that answers proves the grant without touching anything.
if ! run_tc qdisc show dev lo > "$RUN/03_tc_route.txt" 2>&1; then
    die "the tc route '$FAULTS_TC' does not run: $(head -1 "$RUN/03_tc_route.txt")"
fi

if [[ "$PART" == h5 ]]; then
    # ============================== H5 (no claim: 06 and 01 claim per step) ======================
    say "H5 -- 06 once with the heartbeat wherever ndt up starts it, and a sampler of its report"
    [[ -s "$OLD_06/00_table.tsv" ]] || die "no reference table at $OLD_06/00_table.tsv (set OLD_06=)"
    # [Co-developed with claude code -- Adam] (the round-4 review's M-2) The external comparison's
    # treatment must be the controls' code plus B: with C_IDENTITY (the controls' recorded identity)
    # and B_SHA, refused HERE, before 06 runs, unless this checkout's HEAD is a merge of B onto the
    # controls' HEAD with the same uncommitted files, kernel, bmv2, helper and venv.
    if [[ -n "${C_IDENTITY:-}" ]]; then
        identity_gate "$C_IDENTITY" "${B_SHA:-}" "$RUN/00_identity.txt" > "$RUN/00_identity_check.txt" 2>&1 \
            || die "H5: this checkout is not the controls' code plus B -- $(head -3 "$RUN/00_identity_check.txt" | tr '\n' ' ')"
        note "$(tail -1 "$RUN/00_identity_check.txt")"
    fi
    # [Co-developed with claude code -- Adam] A sampler that did not start stops the run HERE,
    # before 06 brings anything up: H5 without its samples is not H5 (live, cafd518a).
    sampler_start "$RUN/50_samples.tsv" || exit 1
    set +e
    NDT_OWNER="$NDT_OWNER" bash "$LIVE_DIR/06_thirteen.sh" > "$RUN/51_06.txt" 2>&1
    R06=$?
    T06_END="$(date +%s)"
    # [Co-developed with claude code -- Adam] 06's end, the last arm's window edge for
    # external_evidence.py --samples (the external judge's M2, 09-28).
    printf '%s\n' "$T06_END" > "$RUN/50_t06_end.txt"
    set -e
    NEW_06="$(sed -n 's/^   raw : //p' "$RUN/51_06.txt" | head -1)"
    note "06 rc $R06, raw $NEW_06"
    tail -3 "$RUN/51_06.txt" | sed 's/^/     /'
    if [[ -s "$NEW_06/00_table.tsv" ]]; then
        cp "$NEW_06/00_table.tsv" "$RUN/52_table_06.tsv"
        judge "$(verdict same_06 "$NEW_06/00_table.tsv" "$OLD_06/00_table.tsv")" "H5 06 against $(basename "$OLD_06")"
        judge "$(verdict h5_heartbeat "$RUN/50_samples.tsv" "$NEW_06/00_table.tsv" "$T06_END" "$HB_ARMS")" "H5 where the heartbeat ran"
    else
        fail "H5: 06 left no table (rc $R06) -- see 51_06.txt"
    fi
    say "H5 -- 01 (NDTwin's own fabric) PASS, with no heartbeat under it"
    T01_START="$(date +%s)"
    set +e
    NDT_OWNER="$NDT_OWNER" bash "$LIVE_DIR/01_baseline.sh" > "$RUN/53_01.txt" 2>&1
    R01=$?
    set -e
    T01_END="$(date +%s)"
    sampler_stop
    case "$(tail -1 "$RUN/53_01.txt")" in
        "PASS 01_baseline") note "H5 01: PASS" ;;
        *) fail "H5 01: rc $R01, $(tail -1 "$RUN/53_01.txt")" ;;
    esac
    judge "$(verdict no_session "$RUN/50_samples.tsv" "$T01_START" "$T01_END")" "H5 01 ran no heartbeat"
    say "done -- nothing of this run's own to tear down"
    exit 0
fi

# ================================= H1-H4 =========================================================
say "compiling $EXERCISE/solution/basic.p4, converting with and without roles, and p4runtime"
[[ -d "$EXERCISE" ]] || die "no exercise at $EXERCISE (set EXERCISE_DIR=)"
[[ -x "$P4C" ]]      || die "no p4c-bm2-ss at $P4C (set P4C=)"
mkdir -p "$EXERCISE/build"
( cd "$EXERCISE" && "$P4C" --p4v 16 --p4runtime-files build/basic.p4.p4info.txtpb \
      -o build/basic.json solution/basic.p4 ) > "$RUN/09_compile.txt" 2>&1 \
    || die "p4c failed -- see 09_compile.txt"
rm -rf "$PKG_ROLES" "$PKG_PLAIN"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" --topology pod-topo/topology.json \
      --p4 solution/basic.p4 --out "$PKG_ROLES" --role-ipv4-route "$ROLE" \
      > "$RUN/10_convert_roles.txt" 2>&1 || die "convert.py --role-ipv4-route failed -- see 10_convert_roles.txt"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" --topology pod-topo/topology.json \
      --p4 solution/basic.p4 --out "$PKG_PLAIN" > "$RUN/11_convert_plain.txt" 2>&1 \
    || die "convert.py failed for the unbound package -- see 11_convert_plain.txt"
for pkg in "$PKG_ROLES" "$PKG_PLAIN"; do
    "$PY" "$REPO/tools/p4_exercise/preflight.py" "$pkg" > "$RUN/12_preflight_$(basename "$pkg").txt" 2>&1 \
        || die "pre-flight FAILED for $(basename "$pkg") -- nothing was started"
done
set +e
"$PY" "$PREP" p4runtime solution "$PKG_EXT" > "$RUN/13_prepare_p4runtime.txt" 2>&1
PRC=$?
set -e
(( PRC == 0 )) || die "census_prepare.py p4runtime solution answered $PRC -- see 13_prepare_p4runtime.txt"

read -r HB_PERIOD_S TIMEOUT_S WATCHDOG_S < <(consts) || true
[[ "$HB_PERIOD_S" =~ ^[0-9.]+$ && "$TIMEOUT_S" =~ ^[0-9.]+$ && "$WATCHDOG_S" =~ ^[0-9.]+$ ]] \
    || die "could not read the proxy's beacon constants from p4_proxy/proxy_agent/topology_manager.py"

take_claim "P4 heartbeat live H1-H4 (segment W): basic roles (H1, H2), basic unbound (H3), p4runtime external detect-only (H4)"

# === phase A: H1 and H2, the roles package ====================================================
say "ndt up p4 --app $(basename "$PKG_ROLES")"
set +e; nd_up "$PKG_ROLES" "$RUN/20_up_roles.txt"; UPRC=$?; set -e
note "rc $UPRC -> 20_up_roles.txt"
tail -4 "$RUN/20_up_roles.txt" | sed 's/^/     /'
(( UPRC == 0 )) || { fail "'ndt up p4 --app' (roles) exited $UPRC -- H1/H2 are not measured"; exit 1; }
/usr/bin/grep -qF "heartbeat running" "$RUN/20_up_roles.txt" \
    && note "ndt up started the heartbeat" || fail "H1: 'ndt up p4 --app' did not say it started the heartbeat"
set +e; hb_status "$RUN/21_hb_status.txt"; HBRC=$?; set -e
(( HBRC == 0 )) && note "the helper says it runs: $(head -1 "$RUN/21_hb_status.txt")" \
               || fail "H1: 'heartbeat status' answered $HBRC after ndt up"

say "H1 -- switch_state: the heartbeat is usable and this fabric reroutes (poll up to 30 s)"
judge "$(state_until 30 "$RUN/22_switch_state.json" hb_state usable)" "H1 heartbeat"
judge "$(verdict caps "$RUN/22_switch_state.json" true heartbeat)" "H1 capabilities"
judge "$(verdict reroute "$RUN/22_switch_state.json" true null)" "H1 reroute"
judge "$(graph_until 90 1 edges_up "$RUN/23_graph.json" "$PKG_ROLES/ndtwin/topology.json")" "H1 all eight directions up before the cut"
set +e; pingall_loss "$PKG_ROLES" 3 "$RUN/24_ping_raw.txt" > "$RUN/24_pingall_before.txt" 2>&1; set -e
note "before the cut: $(tail -1 "$RUN/24_pingall_before.txt")"

stats_flows "$RUN/25_before"
V="$(verdict pick_cut "$RUN/25_before" "$CABLES")"
[[ "$V" == OK* ]] || { fail "H1: $V"; exit 1; }
read -r CA CAP CB CBP <<<"${V#OK }"
note "the cut: s$CA-eth$CAP <-> s$CB-eth$CBP (an installed route uses it)"
tc_ends "$RUN/26_tc_before" "$CA" "$CAP" "$CB" "$CBP"

note "the proxy's constants: beacon interval $HB_PERIOD_S s, timeout $TIMEOUT_S s, watchdog every $WATCHDOG_S s"
note "the design's worst case at the kernel (INFERRED): (timeout $TIMEOUT_S s - phi) + up to one watchdog interval $WATCHDOG_S s + pass time + report read, HTTP, kernel -- at phi -> 0 that is the ticket's $DETECT_BOUND_S s with nothing to spare. Each cycle is measured against the strict $DETECT_BOUND_S s and one over it is DISCLOSED, not failed (Adam, 09-27: at most about $DETECT_BOUND_S s); a detection not seen within $(( DETECT_BOUND_S + 15 )) s is a FAIL; '$DETECT_BOUND_S s + what was measured' is recorded beside it as a diagnostic"
RANDOM="$H1_SEED"
note "random phases: seed $H1_SEED (H1_SEED= to repeat); worst-phase cycles at PHI_WORST=$PHI_WORST s"
CYCLE_COLS="cut_a_start_mono\tcut_a_end_mono\tcut_b_start_mono\tcut_b_end_mono\tlast_heard_ab_mono\tlast_heard_ba_mono\tphi_s\tgraph_down_mono\tdetect_s\tpass_prev_start_mono\tpass_start_mono\tpass_end_mono\twatchdog_phase_s\tpass_lateness_s\tpass_to_graph_s\tcut_window_s\tclock_drift_ms\tcut_flags"
RESTORE_COLS="restore_a_start_mono\trestore_a_end_mono\trestore_b_start_mono\trestore_b_end_mono\tfirst_heard_ab_mono\tfirst_heard_ba_mono\trestore_daemon_s\trestore_report_s\tpass_up_start_mono\tpass_up_after_report_s\tgraph_up_mono\trestore_s\tpass_to_graph_up_s\trestore_drift_ms\trestore_flags"
printf "cycle\tphi_target\t$CYCLE_COLS\tstrict_${DETECT_BOUND_S}s\t$RESTORE_COLS\n" > "$RUN/30_cycles.tsv"
STRICT_CYCLES=0; STRICT_OVER=0; STRICT_OVER_LIST=""
for (( CYC = 1; CYC <= H1_CYCLES; CYC++ )); do
    PHI="$(phase_for "$CYC")"
    say "H1 cycle $CYC/$H1_CYCLES -- cut $PHI s after a heartbeat round; down in the kernel's graph within about ${DETECT_BOUND_S} s (the strict ${DETECT_BOUND_S} s measured and disclosed; past $(( DETECT_BOUND_S + 15 )) s a FAIL)"
    cut_cycle "H1 cycle $CYC" "$RUN/31_graph_cut_$CYC.json" "$RUN/32_switch_state_cut_$CYC.json" \
        "$PHI" "$(( CYC <= H1_WORST ? 1 : 0 ))" || exit 1
    if (( CYC == 1 )); then
        # The reroute runs in the same watchdog pass that told the kernel; give it a pass to
        # land, then read what the switches hold.
        sleep "$WATCHDOG_S"
        stats_flows "$RUN/33_after"
        judge "$(verdict rerouted "$RUN/25_before" "$RUN/33_after" "$CA" "$CAP" "$CB" "$CBP")" "H1 routes rewritten"
        set +e; pingall_loss "$PKG_ROLES" 5 "$RUN/34_ping_raw.txt" > "$RUN/34_pingall_cut.txt" 2>&1; set -e
        sed 's/^/   /' "$RUN/34_pingall_cut.txt"
        case "$(tail -1 "$RUN/34_pingall_cut.txt")" in
            "PINGALL_LOSS pairs=12 zero_loss=12 lossy=0 untested=0") note "H1: all 12 pairs at 0% loss around the cut" ;;
            *) fail "H1 ping around the cut: $(tail -1 "$RUN/34_pingall_cut.txt")" ;;
        esac
    fi
    restore_cycle "H1 cycle $CYC" "$RUN/35_graph_restored_$CYC.json" "$RUN/35_switch_state_restored_$CYC.json" \
        "$RUN/35_restore_watch_$CYC.json" || { fail "H1 cycle $CYC: could not remove the netem"; exit 1; }
    tc_ends "$RUN/36_tc_after_$CYC" "$CA" "$CAP" "$CB" "$CBP"
    judge "$(no_netem "$RUN/36_tc_after_${CYC}_s$CA-eth$CAP.txt" "$RUN/36_tc_after_${CYC}_s$CB-eth$CBP.txt")" "H1 cycle $CYC netem"
    printf '%s\t%s\t%s\t%s\t%s\n' "$CYC" "$PHI" "$CYCLE_ROW" "$CYCLE_STRICT" "$RESTORE_ROW" >> "$RUN/30_cycles.tsv"
done
# 🔴 Adam's ruling A (09-27): the strict bound is measured, and every cycle over it is disclosed
# right above the run's last line -- here, or by w_finish when the loop above exited early.
strict_conclude H1
column -t -s $'\t' "$RUN/30_cycles.tsv" 2>/dev/null | sed 's/^/   /' || sed 's/^/   /' "$RUN/30_cycles.tsv"
set +e; pingall_loss "$PKG_ROLES" 3 "$RUN/37_ping_raw.txt" > "$RUN/37_pingall_after.txt" 2>&1; set -e
note "after the last restore (recorded): $(tail -1 "$RUN/37_pingall_after.txt")"
cp "$HB_REPORT_FILE" "$RUN/38_report.json" 2>/dev/null || true
judge "$(verdict hosts_clean "$RUN/38_report.json")" "H1 ruling 4"
[[ "$VERDICT_WHY" == STOP* ]] && exit 1

say "H2 -- the heartbeat STOPPED, the same cut held ${H2_HOLD_S} s: nothing may go down"
sudo -n "$LAB_HELPER" heartbeat stop > "$RUN/40_hb_stop.txt" 2>&1 || fail "H2: 'heartbeat stop' failed -- see 40_hb_stop.txt"
judge "$(state_until 20 "$RUN/41_switch_state.json" hb_state heartbeat_not_running)" "H2 the proxy sees it stopped"
judge "$(verdict reroute "$RUN/41_switch_state.json" false heartbeat_not_running)" "H2 reroute"
cut_link "$CA" "$CAP" "$CB" "$CBP" || exit 1
: > "$RUN/42_graph_hold.polls"
T_END=$(( $(date +%s) + H2_HOLD_S ))
while (( $(date +%s) < T_END )); do
    get_json "$KERNEL_URL/ndt/get_graph_data" "$RUN/42_graph_hold.json" > /dev/null 2>&1 || true
    printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$(verdict cut_up "$RUN/42_graph_hold.json" "$CA" "$CAP" "$CB" "$CBP")" >> "$RUN/42_graph_hold.polls"
    sleep 3
done
judge "$(verdict held_up "$RUN/42_graph_hold.polls" 8)" "H2 no detection without the heartbeat"
restore_link || fail "H2: could not remove the netem"
tc_ends "$RUN/43_tc_after" "$CA" "$CAP" "$CB" "$CBP"
judge "$(no_netem "$RUN/43_tc_after_s$CA-eth$CAP.txt" "$RUN/43_tc_after_s$CB-eth$CBP.txt")" "H2 netem"
phase_down "$RUN/49_down_roles.txt" "phase A (H1, H2)" || exit 1

# === phase B: H3, the unbound package ===========================================================
say "ndt up p4 --app $(basename "$PKG_PLAIN")"
set +e; nd_up "$PKG_PLAIN" "$RUN/60_up_plain.txt"; UPRC=$?; set -e
note "rc $UPRC -> 60_up_plain.txt"
(( UPRC == 0 )) || { fail "'ndt up p4 --app' (unbound) exited $UPRC -- H3 is not measured"; exit 1; }
judge "$(state_until 30 "$RUN/61_switch_state.json" hb_state usable)" "H3 heartbeat"
judge "$(verdict caps "$RUN/61_switch_state.json" false heartbeat)" "H3 capabilities"
judge "$(verdict reroute "$RUN/61_switch_state.json" false unbound)" "H3 reroute and why not"
judge "$(graph_until 90 1 edges_up "$RUN/62_graph.json" "$PKG_PLAIN/ndtwin/topology.json")" "H3 all eight directions up before the cut"
stats_flows "$RUN/63_before"
cut_cycle "H3" "$RUN/64_graph_cut.json" "$RUN/64_switch_state_cut.json" "$PHI_WORST" 1 || exit 1
printf "phi_target\t$CYCLE_COLS\tstrict_${DETECT_BOUND_S}s\n%s\t%s\t%s\n" "$PHI_WORST" "$CYCLE_ROW" "$CYCLE_STRICT" > "$RUN/64_cycle.tsv"
# [Co-developed with claude code -- Adam] H3's one cycle is disclosed the same way (Adam, 09-27):
# before the ruling its OVER was a per-cycle FAIL; now it is repeated above the last line.
strict_conclude H3
sleep "$WATCHDOG_S"
stats_flows "$RUN/65_after"
judge "$(verdict rows_unchanged "$RUN/63_before" "$RUN/65_after")" "H3 the author's entries"
post_json "$PROXY_URL/stats/flowentry/add" \
    '{"dpid":1,"match":{"dl_type":2048,"nw_dst":"10.0.9.9"},"actions":[{"type":"OUTPUT","port":3}]}' "$RUN/66_proxy_add"
judge "$(verdict refused_501 "$RUN/66_proxy_add.code" "$RUN/66_proxy_add.json")" "H3 a write is still 501"
restore_cycle "H3" "$RUN/67_graph_restored.json" "$RUN/67_switch_state_restored.json" "$RUN/67_restore_watch.json" \
    || fail "H3: could not remove the netem"
printf "$RESTORE_COLS\n%s\n" "$RESTORE_ROW" >> "$RUN/64_cycle.tsv"
tc_ends "$RUN/68_tc_after" "$CA" "$CAP" "$CB" "$CBP"
judge "$(no_netem "$RUN/68_tc_after_s$CA-eth$CAP.txt" "$RUN/68_tc_after_s$CB-eth$CBP.txt")" "H3 netem"
cp "$HB_REPORT_FILE" "$RUN/69a_report.json" 2>/dev/null || true
judge "$(verdict hosts_clean "$RUN/69a_report.json")" "H3 ruling 4"
[[ "$VERDICT_WHY" == STOP* ]] && exit 1
phase_down "$RUN/69_down_plain.txt" "phase B (H3)" || exit 1

# === phase C: H4, an external control plane -- detect only (09-27) ================================
# [Co-developed with claude code -- Adam] Until 09-27 H4 asked for `heartbeat status` rc 3 here (ndt
# started none on an external fabric). Now ndt starts it, detect only, and H4 is the check that the
# proxy DETECTS a cut on this fabric and still reroutes nothing -- read at the proxy, see the header.
say "ndt up p4 --app $(basename "$PKG_EXT") (external, detect only)"
set +e; nd_up "$PKG_EXT" "$RUN/80_up_external.txt"; UPRC=$?; set -e
note "rc $UPRC -> 80_up_external.txt"
(( UPRC == 0 )) || { fail "'ndt up p4 --app' (p4runtime) exited $UPRC -- H4 is not measured"; exit 1; }
/usr/bin/grep -qF "heartbeat running on the inter-switch veths, detect only" "$RUN/80_up_external.txt" \
    && note "ndt up started the heartbeat, detect only" || fail "H4: 'ndt up p4 --app' did not say it started the heartbeat detect-only"
set +e; hb_status "$RUN/81_hb_status.txt"; HBRC=$?; set -e
(( HBRC == 0 )) && note "the helper says it runs: $(head -1 "$RUN/81_hb_status.txt")" \
               || fail "H4: 'heartbeat status' answered $HBRC on the external fabric (want 0: ndt starts it there, detect only)"
judge "$(state_until 30 "$RUN/83_switch_state.json" hb_state usable)" "H4 heartbeat"
judge "$(verdict caps "$RUN/83_switch_state.json" false heartbeat)" "H4 capabilities"
judge "$(verdict reroute "$RUN/83_switch_state.json" false external_control_plane)" "H4 reroute"
ROUTE='{"dpid":1,"match":{"dl_type":2048,"nw_dst":"10.0.1.1"},"actions":[{"type":"OUTPUT","port":1}]}'
for verb in add delete delete_strict modify; do
    post_json "$PROXY_URL/stats/flowentry/$verb" "$ROUTE" "$RUN/82_flowentry_$verb"
    judge "$(verdict conflict_409 "$RUN/82_flowentry_$verb.code" "$RUN/82_flowentry_$verb.json")" "H4 /stats/flowentry/$verb"
done
IFS=: read -r CA CAP CB CBP <<<"$CUT_EXT"
V="$(verdict model_has "$PKG_EXT/ndtwin/topology.json" "$CA" "$CAP" "$CB" "$CBP")"
[[ "$V" == OK* ]] || { fail "H4: $V"; exit 1; }
say "H4 -- cut s$CA-eth$CAP <-> s$CB-eth$CBP out of band: the proxy holds it down by the heartbeat, and reroutes nothing"
tc_ends "$RUN/84_tc_before" "$CA" "$CAP" "$CB" "$CBP"
cut_link "$CA" "$CAP" "$CB" "$CBP" || exit 1
# [Co-developed with claude code -- Adam] The external judge's F4 (09-28): down at the proxy AND
# accepted by the kernel (reported_to_kernel on both directions), and no write record moved.
judge "$(state_until $(( DETECT_BOUND_S + 15 )) "$RUN/85_switch_state_cut.json" links down-told "$CA" "$CAP" "$CB" "$CBP")" "H4 detection at the proxy, told to the kernel"
H4_DET="$(awk -v a="$EPOCHREALTIME" -v b="$T_CUT" 'BEGIN { printf "%.1f", a - b }')"
if awk -v d="$H4_DET" -v b="$DETECT_BOUND_S" 'BEGIN { exit !(d <= b) }'; then
    note "H4 detection at the proxy within ${H4_DET} s of the cut (switch_state polled every 2 s)"
else
    disclose "H4: detection at the proxy read ${H4_DET} s after the cut, over the strict ${DETECT_BOUND_S} s -- disclosed, not a failure (Adam, 09-27: at most about ${DETECT_BOUND_S} s; switch_state polled every 2 s)"
fi
judge "$(verdict reroute "$RUN/85_switch_state_cut.json" false external_control_plane)" "H4 reroute after the cut"
judge "$(verdict caps "$RUN/85_switch_state_cut.json" false heartbeat)" "H4 capabilities after the cut"
judge "$(verdict no_writes "$RUN/83_switch_state.json" "$RUN/85_switch_state_cut.json")" "H4 nothing written across the cut"
restore_link || { fail "H4: could not remove the netem"; exit 1; }
# [Co-developed with claude code -- Adam] The external judge's F9 (09-28): RESTORE_BOUND_S + 15 is how
# long the poll WAITS (so a late restore is measured); the restore is JUDGED at the strict
# RESTORE_BOUND_S, like every restore in this file (Adam has not extended "about 20 s" to restores).
judge "$(state_until $(( RESTORE_BOUND_S + 15 )) "$RUN/86_switch_state_restored.json" links up-told "$CA" "$CAP" "$CB" "$CBP")" "H4 recovery at the proxy, told to the kernel"
H4_REST="$(awk -v a="$EPOCHREALTIME" -v b="$T_CUT" 'BEGIN { printf "%.1f", a - b }')"
judge "$(verdict restore_strict "$H4_REST" "$RESTORE_BOUND_S")" "H4 recovery time at the proxy (switch_state polled every 2 s)"
judge "$(verdict no_writes "$RUN/83_switch_state.json" "$RUN/86_switch_state_restored.json")" "H4 nothing written across the restore"
tc_ends "$RUN/87_tc_after" "$CA" "$CAP" "$CB" "$CBP"
judge "$(no_netem "$RUN/87_tc_after_s$CA-eth$CAP.txt" "$RUN/87_tc_after_s$CB-eth$CBP.txt")" "H4 netem"
cp "$HB_REPORT_FILE" "$RUN/88_report.json" 2>/dev/null || true
judge "$(verdict hosts_clean "$RUN/88_report.json")" "H4 ruling 4"
[[ "$VERDICT_WHY" == STOP* ]] && exit 1
phase_down "$RUN/89_down_external.txt" "phase C (H4)" || exit 1

say "done -- teardown follows"
