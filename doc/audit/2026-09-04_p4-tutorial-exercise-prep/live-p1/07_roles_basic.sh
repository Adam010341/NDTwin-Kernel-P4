#!/usr/bin/env bash
#
# Phase 4, first cut -- live acceptance L1-L6 (TICKET-P4-roles section 5-2): exercises/basic on
# pod-topo, the exercise's OWN pipeline, with `roles.ipv4_route` owned by NDTwin -- and then the
# same exercise without roles, as the negative control.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WRITTEN AND SELF-TESTED OFFLINE; ITS AUTHOR NEVER RAN IT AGAINST A LAB. The worker that
# wrote it had no sudo and no lab (TICKET-P4-roles section 0-2). `--self-test` runs every
# verdict function below against synthetic captures -- one that must pass and one that must fail
# per check -- and against the real 2026-09-19T062604Z_02_app_basic capture where it exists, and
# touches nothing else. That proves the checks can tell the answers apart; it proves nothing
# about a fabric.
#
# What each step asserts (the ticket's words, and what each is reconciled against):
#
#   L1  `GET /ndt/get_graph_data`: all 8 of pod-topo's inter-switch directions
#       `is_enabled: true, is_up: true`. Reconciled against 062604Z_02_app_basic, where all 8
#       were false -- no LLDP on a foreign pipeline, so nothing ever entered the proxy's graph.
#       🔴 `is_up` here comes from the package's DECLARED links, NOT failure detection.
#       On switch_state (both packages): the `links` block is the 8 declared directions, exactly,
#       every one `source: heartbeat, down: false` -- since TICKET-P4-heartbeat segment W the
#       heartbeat `ndt up p4 --app` starts feeds each direction to the proxy at its first
#       watchdog pass, and link_liveness serves it as heartbeat evidence (the fable judge's R2
#       note on ebdf365e). Polled for up to 30 s: before that first pass, or with no heartbeat,
#       every entry is still `source: declared, down: null`, which this check calls BAD.
#   L2  a batch rule written through the kernel API goes in: `get_flow_dispatch_status` for that
#       request has no failure, and `/stats/flow/1` reads it back (and the delete takes it out).
#   L3  every ordered host pair pings at 0% loss -- the routes NDTwin wrote into the exercise's
#       own ipv4_lpm (the package declares none: convert took them out) really forward.
#   L4  `inject_link_failure` on s1-p3<->s3-p1 -> both directions `is_up: false`, STILL false
#       after >= 35 s (at least one `updateLinks` poll), then `inject_link_recovery` -> back to
#       true, and no netem left on either end. 🔴 REROUTING IS NOT ASSERTED here (08_heartbeat.sh
#       H1 asserts it); the traffic across the cut link is recorded as it is, loss and all.
#       [Co-developed with claude code -- Adam] Since TICKET-P4-heartbeat segment W `ndt up p4
#       --app` starts the heartbeat on this package, and the cut's netem stops its frames too: on
#       the OWNED package the proxy now detects the cut itself and reroutes, so L4's recorded
#       traffic numbers may differ from the first cut's (INFERRED, not run).
#   L5  negative control, the same exercise WITHOUT roles: a kernel write answers 501
#       `unsupported_on_p4` (reason `unbound`) and lands in the dispatch failures, and the
#       author's own ipv4_lpm entries are row-for-row what they were before the write.
#       Round 2 (section 7 ruling 5, item 6): one of the writes is aimed at the author's OWN /32
#       -- s1's 10.0.1.1, declared -> port 1, written here with port 2. That is the hazard the
#       cut exists to close: before it, the INSERT failed on the existing /32 and the proxy
#       fell back to a MODIFY that silently rewrote the author's entry. It must answer 501, and
#       s1 must still send 10.0.1.1 out of port 1 afterwards.
#   L6  `GET /p4/switch_state` -- every switch's `capabilities` is section 2.5's shape, with the
#       two keys the heartbeat decides (segment W; the fable judge's 2.4 on 1a3ebd7f):
#       {ipv4_route: ndtwin, five_tuple: false, reroute: true, link_discovery: heartbeat,
#        binding_source: package}; and on the control, {unbound, false, false, heartbeat, null}
#       -- detected there, not rerouted (reroute.reason `unbound`). Both need the heartbeat
#       running: a run whose `ndt up` could not start it reads declared / false.
#
# Run:        NDT_OWNER=<you> bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/07_roles_basic.sh
# Self-test:  bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/07_roles_basic.sh --self-test
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

EXERCISE="${EXERCISE_DIR:-$HOME/tutorials/exercises/basic}"
PKG_ROLES="$PKG_ROOT/basic_roles"
PKG_PLAIN="$PKG_ROOT/basic_noroles"
P4C="${P4C:-/usr/local/bin/p4c-bm2-ss}"
TC="${TC:-/usr/sbin/tc}"
#: tutorials basic's route table, named in full -- the six words convert takes and never guesses.
ROLE="owner=ndtwin,table=MyIngress.ipv4_lpm,match_field=hdr.ipv4.dstAddr"
ROLE="$ROLE,action=MyIngress.ipv4_forward,dst_mac=dstAddr,port=port"
#: The cable L4 cuts: s1 port 3 <-> s3 port 1 (pod-topo's topology.json, "s1-p3" -- "s3-p1").
CUT='{"src_dpid":1,"src_interface":3,"dst_dpid":3,"dst_interface":1}'
CUT_A="1 3 3 1"; CUT_B="3 1 1 3"
#: A destination nothing in pod-topo owns, for L2's write and L5's refused one.
PROBE_DST="10.0.9.9"
#: The author's own /32 on s1 (exercises/basic/pod-topo/s1-runtime.json: 10.0.1.1 -> port 1),
#: and the port L5 tries to move it to.
AUTHOR_DST="10.0.1.1"; AUTHOR_PORT=1; AUTHOR_MOVED_TO=2
#: What section 2.5-2 says each switch of each fabric must report.
#: [Co-developed with claude code -- Adam] reroute / link_discovery as the heartbeat decides them
#: (TICKET-P4-heartbeat segment W): owned -> true / heartbeat, unbound -> false / heartbeat.
CAPS_OWNED='{"ipv4_route":"ndtwin","five_tuple":false,"reroute":true,"link_discovery":"heartbeat","binding_source":"package"}'
CAPS_UNBOUND='{"ipv4_route":"unbound","five_tuple":false,"reroute":false,"link_discovery":"heartbeat","binding_source":null}'
#: control_plane.skipped with every table owned: LLDP and the watchdog still off, routes back on.
SKIPPED_OWNED="['link_watchdog', 'lldp_discovery']"
SKIPPED_UNBOUND="['install_initial_routes', 'link_watchdog', 'lldp_discovery']"

# --- the verdicts. Each reads saved captures only and prints `OK ...` or `BAD ...`; the live
# path and --self-test call the same functions. --------------------------------------------------

# edges_all_up <get_graph_data.json> <package topology.json> -- every inter-switch direction the
# package's model declares is enabled and up in the kernel's graph.
edges_all_up() {
    "$PY" - "$1" "$2" <<'PY'
import json, sys
graph, model = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
switches = {n["dpid"] for n in model["nodes"] if n.get("vertex_type") == 0}
want = sorted({(e["src_dpid"], e["src_interface"], e["dst_dpid"], e["dst_interface"])
               for e in model["edges"] if e["src_dpid"] in switches and e["dst_dpid"] in switches})
have = {(e.get("src_dpid"), e.get("src_interface"), e.get("dst_dpid"), e.get("dst_interface")):
        (e.get("is_enabled"), e.get("is_up")) for e in graph.get("edges", [])}
bad = [f"{d}={have.get(d, 'absent')}" for d in want if have.get(d) != (True, True)]
if not want:
    print("BAD the model declares no inter-switch link")
elif bad:
    print(f"BAD {len(want) - len(bad)}/{len(want)} inter-switch directions enabled+up; not: "
          + "; ".join(bad))
else:
    print(f"OK {len(want)}/{len(want)} inter-switch directions is_enabled:true is_up:true")
PY
}

# edge_state <get_graph_data.json> <src> <sport> <dst> <dport> -- "is_enabled is_up" or "absent".
edge_state() {
    "$PY" - "$@" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
want = tuple(int(x) for x in sys.argv[2:6])
for e in g.get("edges", []):
    if (e.get("src_dpid"), e.get("src_interface"), e.get("dst_dpid"), e.get("dst_interface")) == want:
        print(e.get("is_enabled"), e.get("is_up"))
        break
else:
    print("absent")
PY
}

# cut_is_down <get_graph_data.json> -- both directions of CUT are is_up false.
cut_is_down() {
    local a b
    a="$(edge_state "$1" $CUT_A)"; b="$(edge_state "$1" $CUT_B)"
    if [[ "$a" == *" False" && "$b" == *" False" ]]; then
        echo "OK both directions of the cut link is_up:false ($a / $b)"
    else
        echo "BAD the cut link is not down in both directions: s1:3->s3:1 [$a], s3:1->s1:3 [$b]"
    fi
}

# cut_is_up <get_graph_data.json> -- both directions of CUT are enabled and up again.
cut_is_up() {
    local a b
    a="$(edge_state "$1" $CUT_A)"; b="$(edge_state "$1" $CUT_B)"
    if [[ "$a" == "True True" && "$b" == "True True" ]]; then
        echo "OK both directions of the cut link are back up"
    else
        echo "BAD the cut link is not back up: s1:3->s3:1 [$a], s3:1->s1:3 [$b]"
    fi
}

# caps_are <switch_state.json> <expected capabilities JSON> -- every switch reports exactly it.
caps_are() {
    "$PY" - "$1" "$2" <<'PY'
import json, sys
state, want = json.load(open(sys.argv[1])), json.loads(sys.argv[2])
switches = state.get("switches") or {}
bad = {dpid: s.get("capabilities") for dpid, s in sorted(switches.items())
       if s.get("capabilities") != want}
if not switches:
    print("BAD switch_state names no switch")
elif bad:
    print(f"BAD {len(bad)} of {len(switches)} switch(es) differ from {want}: {bad}")
else:
    print(f"OK all {len(switches)} switches report {json.dumps(want, sort_keys=True)}")
PY
}

# skipped_is <switch_state.json> <python list literal, sorted> -- control_plane.skipped exactly.
skipped_is() {
    local got
    got="$(jqp "$1" "sorted((d.get('control_plane') or {}).get('skipped') or [])")"
    if [[ "$got" == "$2" ]]; then echo "OK control_plane.skipped is $got"
    else echo "BAD control_plane.skipped is $got, want $2"; fi
}

# l1_links_verdict <switch_state.json> <model> -- THE check the live path's L1-on-switch_state
# runs, one name for the live path and the self-test. [Co-developed with claude code -- Adam]
l1_links_verdict() { links_heard "$1" "$2"; }

# links_heard <switch_state.json> <model topology.json> -- switch_state's `links` is the model's
# inter-switch directions EXACTLY (none missing, none extra), every one fed by the heartbeat
# (`source: heartbeat`) and every heartbeat entry up (`down: false`).
# [Co-developed with claude code -- Adam] TICKET-P4-heartbeat segment W, the fable judge's R2 note:
# "every link heartbeat-sourced, all 8 present" rather than "declared or heartbeat", because the
# looser rule passes the two failures this line exists for -- a heartbeat that never reached the
# proxy (all 8 still `declared`: no detection at all, which only the caps line would otherwise
# notice) and a direction the heartbeat does not carry (the report is then unusable and every
# entry stays `declared`). Both rules count; this one also compares the KEYS with the model, so
# a wrong link cannot stand in for a missing one.
links_heard() {
    "$PY" - "$1" "$2" <<'PY'
import json, sys
links = json.load(open(sys.argv[1])).get("links") or {}
model = json.load(open(sys.argv[2]))
switches = {n["dpid"] for n in model["nodes"] if n.get("vertex_type") == 0}
want = sorted({f"{e['src_dpid']}:{e['src_interface']}->{e['dst_dpid']}:{e['dst_interface']}"
               for e in model["edges"] if e["src_dpid"] in switches and e["dst_dpid"] in switches})
got = lambda k, f: (links.get(k) or {}).get(f)
missing = [k for k in want if k not in links]
extra = sorted(k for k in links if k not in want)
unfed = [k for k in want if k in links and got(k, "source") != "heartbeat"]
down = [k for k in want if k in links and got(k, "source") == "heartbeat" and got(k, "down") is not False]
# [Co-developed with claude code -- Adam] The opus judge's N3-1: a direction the heartbeat has not
# heard yet reads heartbeat / down false for the proxy's 30 s startup grace, with no age -- HEARD
# means an age.
number = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
unheard = [k for k in want if k in links and got(k, "source") == "heartbeat" and got(k, "down") is False
           and not number(got(k, "last_beacon_age_s"))]
bad = []
if missing:
    bad.append(f"missing {missing}")
if extra:
    bad.append(f"not declared {extra}")
if unfed:
    bad.append(f"not fed by the heartbeat {[(k, got(k, 'source')) for k in unfed]}")
if down:
    bad.append(f"reported down {[(k, got(k, 'down')) for k in down]}")
if unheard:
    bad.append(f"not heard yet (no last_beacon_age_s: the proxy's startup grace) {unheard}")
if not want:
    print("BAD the model declares no inter-switch link")
elif bad:
    print(f"BAD switch_state links against the {len(want)} declared directions: " + "; ".join(bad))
else:
    print(f"OK {len(want)}/{len(want)} declared directions, exactly, every one source: heartbeat, down: false, heard")
PY
}

# flow_has <stats_flow.json> <dpid> <nw_dst> <port> -- a row matching nw_dst with OUTPUT:<port>.
flow_has() {
    "$PY" - "$@" <<'PY'
import json, sys
body, dpid, dst, port = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
rows = [r for r in body.get(dpid, []) if (r.get("match") or {}).get("nw_dst") == dst]
if any(r.get("actions") == [f"OUTPUT:{port}"] for r in rows):
    print(f"OK /stats/flow/{dpid} reads back nw_dst {dst} -> OUTPUT:{port}")
else:
    print(f"BAD /stats/flow/{dpid} has no nw_dst {dst} -> OUTPUT:{port} (rows for it: {rows})")
PY
}

# flow_lacks <stats_flow.json> <dpid> <nw_dst> -- no row for nw_dst.
flow_lacks() {
    "$PY" - "$@" <<'PY'
import json, sys
body, dpid, dst = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
rows = [r for r in body.get(dpid, []) if (r.get("match") or {}).get("nw_dst") == dst]
print(f"BAD /stats/flow/{dpid} still has {dst}: {rows}" if rows
      else f"OK /stats/flow/{dpid} has no row for {dst}")
PY
}

# rows_unchanged <before-dir> <after-dir> -- per switch, the (priority, match, actions) rows of
# /stats/flow are the same set before and after. Counters and durations are not compared: they
# move with traffic and time, and are not what "the author's entries were not touched" means.
rows_unchanged() {
    "$PY" - "$1" "$2" <<'PY'
import glob, json, os, sys
def rows(path):
    body = json.load(open(path))
    return sorted(json.dumps([r.get("priority"), r.get("match"), r.get("actions")], sort_keys=True)
                  for v in body.values() for r in v)
bad, total = [], 0
files = sorted(glob.glob(os.path.join(sys.argv[1], "stats_flow_*.json")))
for before in files:
    after = os.path.join(sys.argv[2], os.path.basename(before))
    a, b = rows(before), rows(after)
    total += len(a)
    if not os.path.exists(after) or a != b:
        bad.append(f"{os.path.basename(before)}: before {len(a)} rows, after {len(b)}")
if not files:
    print("BAD nothing was captured before the write")
elif bad:
    print("BAD the author's rows changed: " + "; ".join(bad))
else:
    print(f"OK {total} rows across {len(files)} switch(es), identical before and after")
PY
}

# refused_501 <http code file> <body file> -- 501, outcome unsupported_on_p4, reason unbound.
refused_501() {
    "$PY" - "$1" "$2" <<'PY'
import json, sys
code = open(sys.argv[1]).read().strip()
try:
    detail = json.load(open(sys.argv[2])).get("detail") or {}
except ValueError:
    detail = {}
if code == "501" and detail.get("outcome") == "unsupported_on_p4" and detail.get("reason") == "unbound":
    print("OK the proxy answered 501 unsupported_on_p4, reason unbound")
else:
    print(f"BAD HTTP {code}, outcome {detail.get('outcome')!r}, reason {detail.get('reason')!r}")
PY
}

# dispatch_clean <dispatch_status.json> -- this request: complete, dispatched_ok == enqueued,
# no dispatch failure and no switch rejection.
dispatch_clean() {
    "$PY" - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c, so = d.get("counters") or {}, d.get("switch_outcome") or {}
ok = (d.get("complete") is True and c.get("dispatch_failed") == 0
      and c.get("dispatched_ok") == d.get("enqueued") and so.get("rejected_by_switch", 0) == 0)
print(("OK" if ok else "BAD") + f" request {d.get('request_id')}: enqueued {d.get('enqueued')}, "
      f"dispatched_ok {c.get('dispatched_ok')}, dispatch_failed {c.get('dispatch_failed')}, "
      f"rejected_by_switch {so.get('rejected_by_switch')}, complete {d.get('complete')}")
PY
}

# dispatch_refused_unbound <dispatch_status.json> <global dispatch_status.json> -- the request
# failed, and the kernel's recent_failures carries the proxy's 501 reason for it.
dispatch_refused_unbound() {
    "$PY" - "$1" "$2" <<'PY'
import json, sys
d, g = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
failed = (d.get("counters") or {}).get("dispatch_failed", 0)
hits = [f for f in g.get("recent_failures", [])
        if "unsupported_on_p4" in str(f.get("message")) and "unbound" in str(f.get("message"))]
if failed >= 1 and hits:
    print(f"OK the write failed ({failed}) and recent_failures says why: "
          f"{str(hits[-1].get('message'))[:120]}")
else:
    print(f"BAD dispatch_failed {failed}, {len(hits)} recent failure(s) naming unsupported_on_p4/unbound")
PY
}

# no_netem <tc output file>... -- no netem qdisc on any of the given interfaces' captures.
no_netem() {
    local f n=0
    for f in "$@"; do
        [[ -s "$f" ]] || { echo "BAD no tc capture at $(basename "$f")"; return; }
        /usr/bin/grep -q netem "$f" && n=$((n+1))
    done
    if (( n == 0 )); then echo "OK no netem on either end of the cut link"
    else echo "BAD netem is still attached on $n end(s)"; fi
}

# judge <verdict line> <what> -- OK is a note, BAD is a fail.
judge() {
    case "$1" in
        OK*)  note "$2: ${1#OK }" ;;
        *)    fail "$2: ${1#BAD }" ;;
    esac
}

# [Co-developed with claude code -- Adam] state_until and the L6/L1 calls live ABOVE the self-test
# dispatch (they used to sit below it, with the rest of the live helpers -- which is why no self-test
# could run them: the opus judge's N3-2).
# state_until <seconds> <verdict function> <out-file> [args...] -- poll /p4/switch_state every 2 s
# until the verdict reads OK or the time is up; the LAST capture is kept at <out-file> and every
# attempt's verdict is appended to <out-file>.polls. [Co-developed with claude code -- Adam] The
# heartbeat reaches switch_state's `links` at the proxy's first watchdog pass, up to one
# interval after the proxy starts -- a single read right after `ndt up` could land before it.
state_until() {
    local limit="$1" fn="$2" out="$3" deadline v
    shift 3
    deadline=$(( $(date +%s) + limit ))
    : > "$out.polls"
    while :; do
        get_json "$PROXY_URL/p4/switch_state" "$out" >/dev/null 2>&1 || true
        v="$( [[ -s "$out" ]] && "$fn" "$out" "$@" || echo "BAD no switch_state capture" )"
        printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$v" >> "$out.polls"
        [[ "$v" == OK* ]] && break
        (( $(date +%s) >= deadline )) && break
        sleep 2
    done
    printf '%s\n' "$v"
}

# l6_switch_state <out> <model> <caps> <skipped> <label suffix> <no-state message> -- L6's two
# capability checks and L1 on switch_state, on the capture state_until's poll ends on.
# l6_roles / l6_plain are the live path's two calls, arguments and all -- functions so that the
# self-test executes them (the opus judge's N3-2). [Co-developed with claude code -- Adam]
l6_switch_state() {
    local out="$1" model="$2" caps="$3" skipped="$4" sfx="$5" none="$6" v
    v="$(state_until "${L1_POLL_S:-30}" l1_links_verdict "$out" "$model")"
    if [[ -s "$out" ]]; then
        judge "$(caps_are "$out" "$caps")" "L6 capabilities$sfx"
        judge "$(skipped_is "$out" "$skipped")" "L6 control_plane.skipped$sfx"
        judge "$v" "L1 declared links on switch_state, fed by the heartbeat$sfx"
    else
        fail "$none"
    fi
}
l6_roles() {
    l6_switch_state "$RUN/30_switch_state_roles.json" "$PKG_ROLES/ndtwin/topology.json" \
        "$CAPS_OWNED" "$SKIPPED_OWNED" "" "L6: no switch_state"
}
l6_plain() {
    l6_switch_state "$RUN/71_switch_state_plain.json" "$PKG_PLAIN/ndtwin/topology.json" \
        "$CAPS_UNBOUND" "$SKIPPED_UNBOUND" " (unbound)" "L6: no switch_state on the control fabric"
}

# --- --self-test: every verdict against a capture it must pass and one it must fail ------------

self_test() {
    local t rc=0 got
    t="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-07-selftest-XXXXXX")"
    trap 'rm -rf "$t"' RETURN
    "$PY" - "$t" <<'PY'
import copy, json, os, sys
t = sys.argv[1]
def dump(name, obj):
    with open(os.path.join(t, name), "w") as fh:
        json.dump(obj, fh)
cables = [(1, 3, 3, 1), (1, 4, 4, 2), (2, 3, 4, 1), (2, 4, 3, 2)]
directions = cables + [(d, dp, s, sp) for s, sp, d, dp in cables]
model = {"nodes": [{"dpid": d, "vertex_type": 0} for d in (1, 2, 3, 4)]
         + [{"dpid": 0, "vertex_type": 1}],
         "edges": [{"src_dpid": s, "src_interface": sp, "dst_dpid": d, "dst_interface": dp}
                   for s, sp, d, dp in directions]
         + [{"src_dpid": 1, "src_interface": 1, "dst_dpid": 0, "dst_interface": 1}]}
dump("model.json", model)
up = {"edges": [{"src_dpid": s, "src_interface": sp, "dst_dpid": d, "dst_interface": dp,
                 "is_enabled": True, "is_up": True} for s, sp, d, dp in directions]}
dump("graph_up.json", up)
dump("graph_all_down.json", {"edges": [dict(e, is_enabled=False, is_up=False)
                                       for e in up["edges"]]})
cut = copy.deepcopy(up)
for e in cut["edges"]:
    if (e["src_dpid"], e["src_interface"]) in ((1, 3), (3, 1)):
        e["is_up"] = False
dump("graph_cut.json", cut)
half = copy.deepcopy(up)
half["edges"][0]["is_up"] = False     # (1,3,3,1) only
dump("graph_half_cut.json", half)
# [Co-developed with claude code -- Adam] TICKET-P4-heartbeat segment W (the fable judge's 2.4 on
# 1a3ebd7f): `ndt up p4 --app` now starts the root helper's heartbeat on these packages, so an
# owned fabric reroutes and both fabrics discover their links by the heartbeat.
owned = {"ipv4_route": "ndtwin", "five_tuple": False, "reroute": True,
         "link_discovery": "heartbeat", "binding_source": "package"}
unbound = {"ipv4_route": "unbound", "five_tuple": False, "reroute": False,
           "link_discovery": "heartbeat", "binding_source": None}
# [Co-developed with claude code -- Adam] `links` as switch_state serves it once the heartbeat
# has fed the proxy (the fable judge's R2 note on ebdf365e): the first watchdog pass enters every
# declared direction as heartbeat evidence, and link_liveness reports it with `source: heartbeat`
# (a declared entry is only the setdefault behind it). Before that pass, or with no heartbeat,
# every entry is `source: declared, down: null` -- the first cut's shape, kept below as a BAD.
heard = lambda: {"source": "heartbeat", "down": False, "last_beacon_age_s": 1.2,
                 "reported_to_kernel": True}
declared_only = lambda: {"source": "declared", "down": None, "last_beacon_age_s": None,
                         "reported_to_kernel": False}
key = lambda s, sp, d, dp: f"{s}:{sp}->{d}:{dp}"
state = {"control_plane": {"skipped": ["lldp_discovery", "link_watchdog"]},
         "switches": {str(d): {"capabilities": owned} for d in (1, 2, 3, 4)},
         "links": {key(*x): heard() for x in directions}}
dump("state_owned.json", state)
def links_variant(name, change):
    v = copy.deepcopy(state)
    change(v["links"])
    dump(name, v)
links_variant("links_one_declared.json", lambda l: l.__setitem__(key(1, 3, 3, 1), declared_only()))
links_variant("links_all_declared.json", lambda l: [l.__setitem__(k, declared_only()) for k in list(l)])
links_variant("links_one_down.json", lambda l: l[key(3, 1, 1, 3)].__setitem__("down", True))
links_variant("links_one_missing.json", lambda l: l.pop(key(2, 4, 3, 2)))
links_variant("links_one_extra.json", lambda l: l.__setitem__(key(1, 3, 4, 1), heard()))
# [Co-developed with claude code -- Adam] The opus judge's N3-1: a direction the heartbeat has not
# heard yet is entered at the daemon's start and, for LINK_STARTUP_GRACE_S (30 s), served as
# heartbeat / down false / age null -- not heard, and not yet down.
grace = lambda: {"source": "heartbeat", "down": False, "last_beacon_age_s": None, "reported_to_kernel": True}
links_variant("links_one_grace.json", lambda l: l.__setitem__(key(2, 4, 3, 2), grace()))
links_variant("state_grace.json", lambda l: [l.__setitem__(k, grace()) for k in list(l)])
state_plain = copy.deepcopy(state)
state_plain["switches"] = {str(d): {"capabilities": unbound} for d in (1, 2, 3, 4)}
state_plain["control_plane"]["skipped"] = ["install_initial_routes", "link_watchdog", "lldp_discovery"]
dump("state_plain.json", state_plain)
os.makedirs(os.path.join(t, "pkg", "ndtwin"))
dump(os.path.join("pkg", "ndtwin", "topology.json"), model)
wrong = copy.deepcopy(state)
wrong["switches"]["3"]["capabilities"] = dict(owned, reroute=False)
wrong["control_plane"]["skipped"].append("install_initial_routes")
wrong["links"] = {}
dump("state_wrong.json", wrong)
state_unbound = copy.deepcopy(state)
state_unbound["switches"] = {str(d): {"capabilities": unbound} for d in (1, 2, 3, 4)}
dump("state_unbound.json", state_unbound)
state_unbound["switches"]["3"]["capabilities"] = dict(unbound, reroute=True)
dump("state_unbound_wrong.json", state_unbound)
row = lambda dst, port: {"priority": 0, "match": {"dl_type": 2048, "nw_dst": dst},
                         "actions": [f"OUTPUT:{port}"], "byte_count": 0}
dump("flow_with.json", {"1": [row("10.0.1.1", 1), row("10.0.9.9", 3)]})
dump("flow_without.json", {"1": [row("10.0.1.1", 1)]})
os.makedirs(os.path.join(t, "before")); os.makedirs(os.path.join(t, "same"))
os.makedirs(os.path.join(t, "moved"))
for d in (1, 2):
    for sub, rows in (("before", [row("10.0.1.1", 1)]), ("same", [dict(row("10.0.1.1", 1), byte_count=99)]),
                      ("moved", [row("10.0.1.1", 2)])):
        with open(os.path.join(t, sub, f"stats_flow_{d}.json"), "w") as fh:
            json.dump({str(d): rows}, fh)
disabled = copy.deepcopy(up)
disabled["edges"][2]["is_enabled"] = False     # up, but the kernel has not enabled it
dump("graph_disabled.json", disabled)
open(os.path.join(t, "code_501"), "w").write("501\n")
open(os.path.join(t, "code_500"), "w").write("500\n")
dump("body_501.json", {"detail": {"error": "no NDTwin route binding for this write",
                                  "outcome": "unsupported_on_p4", "reason": "unbound"}})
dump("body_501_owned.json", {"detail": {"error": "no NDTwin route binding for this write",
                                        "outcome": "unsupported_on_p4",
                                        "reason": "owned_by_package"}})
dump("body_501_other.json", {"detail": {"error": "group tables are not supported",
                                        "outcome": "not_implemented", "reason": "unbound"}})
dump("dispatch_clean.json", {"request_id": 7, "enqueued": 1, "complete": True,
                             "counters": {"dispatched": 1, "dispatched_ok": 1,
                                          "dispatch_failed": 0},
                             "switch_outcome": {"rejected_by_switch": 0}})
dump("dispatch_failed.json", {"request_id": 8, "enqueued": 1, "complete": True,
                              "counters": {"dispatched": 1, "dispatched_ok": 0,
                                           "dispatch_failed": 1},
                              "switch_outcome": {"rejected_by_switch": 1}})
dump("dispatch_global.json", {"recent_failures": [{"dpid": 1, "message":
    'HTTP 501: {"detail":{"error":"no NDTwin route binding for this write","outcome":"unsupported_on_p4","reason":"unbound"'}]})
dump("dispatch_global_owned.json", {"recent_failures": [{"dpid": 1, "message":
    'HTTP 501: {"detail":{"error":"no NDTwin route binding for this write","outcome":"unsupported_on_p4","reason":"owned_by_package"'}]})
dump("dispatch_global_empty.json", {"recent_failures": []})
open(os.path.join(t, "tc_clean"), "w").write("qdisc noqueue 0: root refcnt 2\n")
open(os.path.join(t, "tc_netem"), "w").write("qdisc netem 8001: root refcnt 2 limit 1000 loss 100%\n")
PY
    expect() {   # expect <OK|BAD> <label> <verdict line>
        if [[ "$3" == "$1"* ]]; then printf '  ok    %-58s %s\n' "$2" "${3:0:70}"
        else printf '  🔴    %-58s wanted %s, got: %s\n' "$2" "$1" "$3"; rc=1; fi
    }
    echo "07_roles_basic --self-test (synthetic captures in $t; no lab, no claim, nothing started)"
    expect OK  "L1 all eight up"                 "$(edges_all_up "$t/graph_up.json" "$t/model.json")"
    expect BAD "L1 all eight down (062604Z's shape)" "$(edges_all_up "$t/graph_all_down.json" "$t/model.json")"
    expect BAD "L1 one direction down"           "$(edges_all_up "$t/graph_half_cut.json" "$t/model.json")"
    expect BAD "L1 up but not enabled"           "$(edges_all_up "$t/graph_disabled.json" "$t/model.json")"
    expect OK  "L4 the cut is down both ways"    "$(cut_is_down "$t/graph_cut.json")"
    expect BAD "L4 only one direction down"      "$(cut_is_down "$t/graph_half_cut.json")"
    expect BAD "L4 nothing down"                 "$(cut_is_down "$t/graph_up.json")"
    expect OK  "L4 back up"                      "$(cut_is_up "$t/graph_up.json")"
    expect BAD "L4 still down"                   "$(cut_is_up "$t/graph_cut.json")"
    expect BAD "L4 only one direction back up"   "$(cut_is_up "$t/graph_half_cut.json")"
    expect OK  "L4 no netem left"                "$(no_netem "$t/tc_clean" "$t/tc_clean")"
    expect BAD "L4 netem left on one end"        "$(no_netem "$t/tc_clean" "$t/tc_netem")"
    expect OK  "L6 capabilities owned"           "$(caps_are "$t/state_owned.json" "$CAPS_OWNED")"
    expect BAD "L6 one owned switch says reroute:false" "$(caps_are "$t/state_wrong.json" "$CAPS_OWNED")"
    expect BAD "L6 owned is not unbound"         "$(caps_are "$t/state_owned.json" "$CAPS_UNBOUND")"
    expect OK  "L6 capabilities unbound"         "$(caps_are "$t/state_unbound.json" "$CAPS_UNBOUND")"
    expect BAD "L6 one switch says reroute:true" "$(caps_are "$t/state_unbound_wrong.json" "$CAPS_UNBOUND")"
    expect OK  "L6 skipped with every table owned" "$(skipped_is "$t/state_owned.json" "$SKIPPED_OWNED")"
    expect BAD "L6 routes still skipped"         "$(skipped_is "$t/state_wrong.json" "$SKIPPED_OWNED")"
    # [Co-developed with claude code -- Adam] L1 on switch_state with the heartbeat running: the
    # package's 8 declared directions, exactly, every one fed by the heartbeat and none down.
    # The live path's L1-on-switch_state check (l1_links_verdict), on a heartbeat-fed switch_state
    # and on the first cut's all-declared shape. Until 7de09bac's fix it was `declared_links_marked
    # "$SS" 8`, which said "BAD 0 of 8 link entries are declared" on the first -- the judge's R2
    # finding.
    expect OK  "L1 the live path's switch_state check on a heartbeat-fed fabric" "$(l1_links_verdict "$t/state_owned.json" "$t/model.json")"
    expect BAD "L1 the live path's check on the first cut's all-declared shape" "$(l1_links_verdict "$t/links_all_declared.json" "$t/model.json")"
    expect OK  "L1 the eight declared directions, heard" "$(links_heard "$t/state_owned.json" "$t/model.json")"
    expect BAD "L1 no link entries"              "$(links_heard "$t/state_wrong.json" "$t/model.json")"
    expect BAD "L1 a declared link the heartbeat never fed" "$(links_heard "$t/links_one_declared.json" "$t/model.json")"
    expect BAD "L1 the heartbeat never fed the proxy (all declared)" "$(links_heard "$t/links_all_declared.json" "$t/model.json")"
    expect BAD "L1 a link the heartbeat reports down" "$(links_heard "$t/links_one_down.json" "$t/model.json")"
    expect BAD "L1 a link missing"               "$(links_heard "$t/links_one_missing.json" "$t/model.json")"
    expect BAD "L1 an extra link"                "$(links_heard "$t/links_one_extra.json" "$t/model.json")"
    expect BAD "L1 a direction never heard yet (the startup grace)" "$(links_heard "$t/links_one_grace.json" "$t/model.json")"
    expect BAD "L1 every direction in the startup grace" "$(links_heard "$t/state_grace.json" "$t/model.json")"
    # (a red line is "<case> -- <what it saw>": the first cut's gate finds a case by its name and a space)
    ok()  { printf '  ok    %s\n' "$1"; }
    red() { printf '  🔴    %s\n' "$1"; rc=1; }
    # [Co-developed with claude code -- Adam] L6 and L1 on switch_state as the live path runs them --
    # l6_roles / l6_plain, their own arguments, state_until's poll -- against a proxy served by
    # file:// (08's precedent), with a switch_state that turns heard 2.5 s into the poll.
    st_l6() {   # st_l6 <roles|plain> <first switch_state|-> <later one|-> <poll s> -> judge lines + polls
        local px d
        px="$(mktemp -d "$t/px-XXXXXX")"; mkdir -p "$px/p4"
        [[ "$2" == - ]] || cp "$t/$2" "$px/p4/switch_state"
        ( RUN="$px"; PROXY_URL="file://$px"; PKG_ROLES="$t/pkg"; PKG_PLAIN="$t/pkg"; L1_POLL_S="$4"
          note() { :; }; judge() { echo "J $2: ${1:0:70}"; }; fail() { echo "F $*"; }
          if [[ "$3" != - ]]; then
              ( sleep 2.5; cp "$t/$3" "$px/p4/switch_state.tmp"; mv "$px/p4/switch_state.tmp" "$px/p4/switch_state" ) &
          fi
          "l6_$1"
          wait
          d="$(ls "$px"/*.polls 2>/dev/null | head -1)"
          echo "polls $( [[ -n "$d" ]] && wc -l < "$d" || echo 0)" ) 2>&1
    }
    got="$(st_l6 roles state_owned.json - 4)" || true
    if [[ "$got" == *"J L6 capabilities: OK"* && "$got" == *"J L6 control_plane.skipped: OK"* \
          && "$got" == *"J L1 declared links on switch_state, fed by the heartbeat: OK"* && "$got" == *"polls 1"* ]]; then
        ok "L6/L1 on switch_state (roles): all heard at once -- three OK judgements from one read"
    else
        red "L6/L1 on switch_state (roles), heard at once -- $(tr '\n' '|' <<<"$got")"
    fi
    got="$(st_l6 roles state_grace.json state_owned.json 10)" || true
    if [[ "$got" == *"J L1 declared links on switch_state, fed by the heartbeat: OK"* && "$got" == *"J L6 capabilities: OK"* \
          && "$(sed -n 's/^polls //p' <<<"$got")" -ge 2 ]]; then
        ok "  state_until waits: in the startup grace first, heard 2.5 s later -- OK on a later read"
    else
        red "  state_until through the startup grace -- $(tr '\n' '|' <<<"$got")"
    fi
    got="$(st_l6 roles state_grace.json - 3)" || true
    if [[ "$got" == *"J L1 declared links on switch_state, fed by the heartbeat: BAD"* && "$(sed -n 's/^polls //p' <<<"$got")" -ge 2 ]]; then
        ok "  never heard within the poll: L1 on switch_state is judged BAD after more than one read"
    else
        red "  never heard within the poll -- $(tr '\n' '|' <<<"$got")"
    fi
    got="$(st_l6 roles - - 2)" || true
    [[ "$got" == *"F L6: no switch_state"* ]] && ok "  no switch_state at all: a fail, not a pass" \
                                            || red "  no switch_state at all -- $(tr '\n' '|' <<<"$got")"
    got="$(st_l6 plain state_plain.json - 4)" || true
    if [[ "$got" == *"J L6 capabilities (unbound): OK"* && "$got" == *"J L6 control_plane.skipped (unbound): OK"* \
          && "$got" == *"J L1 declared links on switch_state, fed by the heartbeat (unbound): OK"* ]]; then
        ok "L6/L1 on switch_state (unbound): its own capabilities, skipped list and labels"
    else
        red "L6/L1 on switch_state (unbound) -- $(tr '\n' '|' <<<"$got")"
    fi
    # 🔴 Against the REAL switch_states of 08's live run (2026-09-26T152605Z_08_heartbeat), where they
    # exist on this machine (not committed; SELFTEST_HB_RUN / SELFTEST_HB_PKGS point elsewhere,
    # read-only): right after `ndt up` (22 roles, 61 unbound) every link is still `declared` -- BAD;
    # after a cut and restore (35, 67) all eight heard -- OK. (The opus judge's suggested check.)
    local hbrun="${SELFTEST_HB_RUN:-$LIVE_DIR/runs/2026-09-26T152605Z_08_heartbeat}"
    local hbpkgs="${SELFTEST_HB_PKGS:-$PKG_ROOT}"
    if [[ -s "$hbrun/22_switch_state.json" && -s "$hbpkgs/hb_basic_roles/ndtwin/topology.json" ]]; then
        expect BAD "L1 on the real 08 capture 22 (roles, right after up)" "$(links_heard "$hbrun/22_switch_state.json" "$hbpkgs/hb_basic_roles/ndtwin/topology.json")"
        expect OK  "L1 on the real 08 capture 35 (roles, restored)" "$(links_heard "$hbrun/35_switch_state_restored_1.json" "$hbpkgs/hb_basic_roles/ndtwin/topology.json")"
        expect BAD "L1 on the real 08 capture 61 (unbound, right after up)" "$(links_heard "$hbrun/61_switch_state.json" "$hbpkgs/hb_basic_noroles/ndtwin/topology.json")"
        expect OK  "L1 on the real 08 capture 67 (unbound, restored)" "$(links_heard "$hbrun/67_switch_state_restored.json" "$hbpkgs/hb_basic_noroles/ndtwin/topology.json")"
    else
        echo "  --    08's live switch_states are not on this machine; not compared (NOT a pass)"
    fi
    expect OK  "L2 read back"                    "$(flow_has "$t/flow_with.json" 1 10.0.9.9 3)"
    expect BAD "L2 not read back"                "$(flow_has "$t/flow_without.json" 1 10.0.9.9 3)"
    expect BAD "L2 read back on the wrong port"  "$(flow_has "$t/flow_with.json" 1 10.0.9.9 4)"
    expect OK  "L2 delete took it out"           "$(flow_lacks "$t/flow_without.json" 1 10.0.9.9)"
    expect BAD "L2 delete left it"               "$(flow_lacks "$t/flow_with.json" 1 10.0.9.9)"
    expect OK  "L2 dispatch clean"               "$(dispatch_clean "$t/dispatch_clean.json")"
    expect BAD "L2 dispatch failed"              "$(dispatch_clean "$t/dispatch_failed.json")"
    expect OK  "L5 the proxy said 501 unbound"   "$(refused_501 "$t/code_501" "$t/body_501.json")"
    expect BAD "L5 a 500 is not the 501"         "$(refused_501 "$t/code_500" "$t/body_501.json")"
    expect BAD "L5 a 501 for another reason"     "$(refused_501 "$t/code_501" "$t/body_501_owned.json")"
    expect BAD "L5 a 501 that is not unsupported_on_p4" "$(refused_501 "$t/code_501" "$t/body_501_other.json")"
    expect OK  "L5 dispatch failed, reason kept" "$(dispatch_refused_unbound "$t/dispatch_failed.json" "$t/dispatch_global.json")"
    expect BAD "L5 a clean dispatch is not the refusal" "$(dispatch_refused_unbound "$t/dispatch_clean.json" "$t/dispatch_global.json")"
    expect BAD "L5 no failure record names it"   "$(dispatch_refused_unbound "$t/dispatch_failed.json" "$t/dispatch_global_empty.json")"
    expect BAD "L5 a refusal for another reason" "$(dispatch_refused_unbound "$t/dispatch_failed.json" "$t/dispatch_global_owned.json")"
    expect OK  "L5 counters moved, rows did not" "$(rows_unchanged "$t/before" "$t/same")"
    expect BAD "L5 a row changed"                "$(rows_unchanged "$t/before" "$t/moved")"
    # 🔴 Against the REAL capture the ticket reconciles L1 with, where it exists on this machine:
    # the run that motivated this ticket must read BAD, all eight false.
    # Overridable because the capture is not committed: it lives in whichever checkout ran it
    # (SELFTEST_OLD_RUN / SELFTEST_OLD_TOPO point elsewhere, read-only).
    local old="${SELFTEST_OLD_RUN:-$LIVE_DIR/runs/2026-09-19T062604Z_02_app_basic}"
    local topo="${SELFTEST_OLD_TOPO:-$PKG_ROOT/basic/ndtwin/topology.json}"
    if [[ -s "$old/32_get_graph_data.json" && -s "$topo" ]]; then
        got="$(edges_all_up "$old/32_get_graph_data.json" "$topo")"
        expect BAD "L1 on the real 062604Z_02 capture" "$got"
        [[ "$got" == "BAD 0/8 "* ]] || { echo "  🔴    062604Z_02 should be 0/8, got: $got"; rc=1; }
    else
        echo "  --    the real 062604Z_02 capture is not on this machine; not compared (NOT a pass)"
    fi
    if (( rc == 0 )); then echo "SELF-TEST PASS"; else echo "SELF-TEST FAIL"; fi
    return $rc
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit $?
fi

# --- the live run -------------------------------------------------------------------------------

start_step 07_roles_basic

# post_json <url> <body> <out-prefix> -- the body to <prefix>.json, the status code to
# <prefix>.code. Never fails the script; the verdicts read the files.
post_json() {
    curl -s --max-time 15 -o "$3.json" -w '%{http_code}\n' -X POST \
        -H 'Content-Type: application/json' -d "$2" "$1" > "$3.code" 2> "$3.curl.err" || true
}

# graph_until <seconds> <verdict function> <out-file> [args...] -- poll get_graph_data every 3 s
# until the verdict reads OK or the time is up; the LAST capture is kept at <out-file> and every
# attempt's verdict is appended to <out-file>.polls.
graph_until() {
    local limit="$1" fn="$2" out="$3" deadline v
    shift 3
    deadline=$(( $(date +%s) + limit ))
    : > "$out.polls"
    while :; do
        get_json "$KERNEL_URL/ndt/get_graph_data" "$out" >/dev/null 2>&1 || true
        v="$( [[ -s "$out" ]] && "$fn" "$out" "$@" || echo "BAD no get_graph_data capture" )"
        printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$v" >> "$out.polls"
        [[ "$v" == OK* ]] && break
        (( $(date +%s) >= deadline )) && break
        sleep 3
    done
    printf '%s\n' "$v"
}

# dispatch_until <request id> <out-file> -- poll get_flow_dispatch_status?request_id= until
# `complete` (or 30 s).
dispatch_until() {
    local id="$1" out="$2" i
    for i in $(seq 1 15); do
        get_json "$KERNEL_URL/ndt/get_flow_dispatch_status?request_id=$id" "$out" >/dev/null 2>&1 || true
        [[ -s "$out" ]] && [[ "$(jqp "$out" "d.get('complete')")" == "True" ]] && return 0
        sleep 2
    done
    return 1
}

# batch <json body> <out-prefix> -- POST the kernel batch endpoint, echo the request_id (or "").
batch() {
    post_json "$KERNEL_URL/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries" \
        "$1" "$2"
    [[ -s "$2.json" ]] && jqp "$2.json" "d.get('request_id') or ''" || true
}

# stats_flows <dir> -- /stats/flow/<dpid> for s1-s4 into <dir>/stats_flow_<dpid>.json.
stats_flows() {
    mkdir -p "$1"
    local d
    for d in 1 2 3 4; do get_json "$PROXY_URL/stats/flow/$d" "$1/stats_flow_$d.json" || true; done
}

tc_ends() {   # tc_ends <prefix> -- the qdiscs on both ends of the cut link, unprivileged read
    "$TC" qdisc show dev s1-eth3 > "$1_s1-eth3.txt" 2>&1 || true
    "$TC" qdisc show dev s3-eth1 > "$1_s3-eth1.txt" 2>&1 || true
}

# --- 0. which binaries -----------------------------------------------------------------------
say "which code this run is about"
{
    echo "repo HEAD  $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel     $(sha256sum "$REPO/build/bin/ndtwin_kernel" 2>/dev/null | cut -c1-16 || echo absent)  build/bin/ndtwin_kernel"
    for f in p4_proxy/proxy_agent/route_binding.py p4_proxy/proxy_agent/p4_client.py \
             p4_proxy/proxy_agent/main.py p4_proxy/proxy_agent/topology_manager.py \
             tools/p4_exercise/convert.py tools/p4_exercise/preflight.py; do
        echo "source     $(sha256sum "$REPO/$f" | cut -c1-16)  $f"
    done
} | tee "$RUN/01_binaries.txt" | sed 's/^/   /'

# --- 1. compile, convert twice, pre-flight twice ----------------------------------------------
say "compiling $EXERCISE/solution/basic.p4 -> build/basic.json"
[[ -d "$EXERCISE" ]] || die "no exercise at $EXERCISE (set EXERCISE_DIR=)"
[[ -x "$P4C" ]]      || die "no p4c-bm2-ss at $P4C (set P4C=)"
mkdir -p "$EXERCISE/build"
( cd "$EXERCISE" && "$P4C" --p4v 16 \
        --p4runtime-files build/basic.p4.p4info.txtpb -o build/basic.json solution/basic.p4 ) \
    > "$RUN/09_compile.txt" 2>&1 || die "p4c failed -- see $(basename "$RUN")/09_compile.txt"
note "$(sha256sum "$EXERCISE/build/basic.p4.p4info.txtpb" | cut -c1-16)  build/basic.p4.p4info.txtpb"

say "converting WITH --role-ipv4-route -> $PKG_ROLES"
rm -rf "$PKG_ROLES"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" --topology pod-topo/topology.json \
      --p4 solution/basic.p4 --out "$PKG_ROLES" --role-ipv4-route "$ROLE" \
      > "$RUN/10_convert_roles.txt" 2>&1 || die "convert.py --role-ipv4-route failed -- see 10_convert_roles.txt"
/usr/bin/grep -E '^  (roles|owned table)' "$RUN/10_convert_roles.txt" | sed 's/^/ /'
ENTRY_TABLES="$("$PY" -c "
import json,sys,os
p=sys.argv[1]
m=json.load(open(os.path.join(p,'package.json')))
print(sorted({(e.get('table'), bool(e.get('default_action'))) for s in m['switches'].values()
              for e in json.load(open(os.path.join(p, s['entries'])))['table_entries']}))" "$PKG_ROLES")"
note "the roles package's runtime entries (table, default?): $ENTRY_TABLES"
[[ "$ENTRY_TABLES" == "[('MyIngress.ipv4_lpm', True)]" ]] \
    || die "the roles package still carries match entries for the owned table: $ENTRY_TABLES"

say "converting WITHOUT roles (the L5 control) -> $PKG_PLAIN"
rm -rf "$PKG_PLAIN"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" --topology pod-topo/topology.json \
      --p4 solution/basic.p4 --out "$PKG_PLAIN" > "$RUN/11_convert_plain.txt" 2>&1 \
    || die "convert.py failed for the control package -- see 11_convert_plain.txt"

for pkg in "$PKG_ROLES" "$PKG_PLAIN"; do
    name="$(basename "$pkg")"
    set +e
    "$PY" "$REPO/tools/p4_exercise/preflight.py" "$pkg" > "$RUN/12_preflight_$name.txt" 2>&1
    rc=$?
    set -e
    tail -1 "$RUN/12_preflight_$name.txt" | sed "s/^/   $name: /"
    (( rc != 0 )) && die "pre-flight FAILED for $name (rc $rc) -- nothing was started"
done
/usr/bin/grep -E 'roles' "$RUN/12_preflight_basic_roles.txt" | sed 's/^/   /' || true
/usr/bin/grep -E 'roles suggestion' "$RUN/12_preflight_basic_noroles.txt" | cut -c1-160 | sed 's/^/   /' || true

take_claim "P4 roles live L1-L6: --app basic (pod-topo) with roles.ipv4_route owner ndtwin, then without roles"

# === phase A: the roles package ===============================================================
say "ndt up p4 --app $PKG_ROLES"
set +e
"$NDT" up p4 --app "$PKG_ROLES" > "$RUN/20_up_roles.txt" 2>&1
UP_RC=$?
set -e
note "rc=$UP_RC -> 20_up_roles.txt"
tail -6 "$RUN/20_up_roles.txt" | sed 's/^/     /'
if (( UP_RC != 0 )); then
    fail "'ndt up p4 --app' (roles package) exited $UP_RC -- phase A is not measured"
else
    [[ -s "$REPO/.test_run/logs/p4_proxy.log" ]] && \
        /usr/bin/grep -E 'declared inter-switch|binds roles.ipv4_route|REFUSING' \
            "$REPO/.test_run/logs/p4_proxy.log" > "$RUN/21_proxy_roles_lines.txt" 2>&1 || true

    # --- L6 --------------------------------------------------------------------------------------
    say "L6 -- switch_state capabilities (roles package)"
    # [Co-developed with claude code -- Adam] Polled: the links are the heartbeat's from the proxy's
    # first watchdog pass on, and heard (an age) after its startup grace. Every check reads the
    # capture the poll ended on (30_switch_state_roles.json). The self-test runs this call.
    l6_roles

    # --- L1 --------------------------------------------------------------------------------------
    say "L1 -- the kernel's graph: 8 inter-switch directions enabled and up (poll up to 90 s)"
    V="$(graph_until 90 edges_all_up "$RUN/31_graph_roles.json" "$PKG_ROLES/ndtwin/topology.json")"
    judge "$V" "L1 (reconciled against 062604Z_02_app_basic: 0/8 there)"
    # [Co-developed with claude code -- Adam] TICKET-P4-heartbeat segment W: detection comes from the
    # heartbeat now (switch_state `heartbeat`, `reroute`); the edges came up by the declaration.
    note "the edges came up by DECLARATION; a cut is detected by the heartbeat (switch_state heartbeat/reroute), not by LLDP"

    # --- L3 --------------------------------------------------------------------------------------
    say "L3 -- pingall, every ordered pair, ping -c 5 (NDTwin's routes in the exercise's table)"
    set +e
    pingall_loss "$PKG_ROLES" 5 "$RUN/33_ping_raw.txt" > "$RUN/32_pingall.txt" 2>&1
    set -e
    sed 's/^/   /' "$RUN/32_pingall.txt"
    case "$(tail -1 "$RUN/32_pingall.txt")" in
        "PINGALL_LOSS pairs=12 zero_loss=12 lossy=0 untested=0") note "L3: 0% loss on all 12 pairs" ;;
        *) fail "L3: $(tail -1 "$RUN/32_pingall.txt")" ;;
    esac

    # --- L2 --------------------------------------------------------------------------------------
    say "L2 -- a batch rule through the kernel API, read back, then deleted"
    INSTALL="{\"install_flow_entries\":[{\"dpid\":1,\"priority\":10,\"match\":{\"eth_type\":2048,\"ipv4_dst\":\"$PROBE_DST\"},\"actions\":[{\"type\":\"OUTPUT\",\"port\":3}]}],\"modify_flow_entries\":[],\"delete_flow_entries\":[]}"
    RID="$(batch "$INSTALL" "$RUN/40_batch_install")"
    note "install: HTTP $(cat "$RUN/40_batch_install.code" 2>/dev/null) request_id=${RID:-none}"
    if [[ -n "$RID" ]] && dispatch_until "$RID" "$RUN/41_dispatch_install.json"; then
        judge "$(dispatch_clean "$RUN/41_dispatch_install.json")" "L2 dispatch"
    else
        fail "L2: the install batch has no completed dispatch record (request_id '${RID:-none}')"
    fi
    get_json "$PROXY_URL/stats/flow/1" "$RUN/42_stats_flow_1_after_install.json" || true
    judge "$(flow_has "$RUN/42_stats_flow_1_after_install.json" 1 "$PROBE_DST" 3)" "L2 read-back"
    DELETE="{\"install_flow_entries\":[],\"modify_flow_entries\":[],\"delete_flow_entries\":[{\"dpid\":1,\"match\":{\"eth_type\":2048,\"ipv4_dst\":\"$PROBE_DST\"}}]}"
    RID2="$(batch "$DELETE" "$RUN/43_batch_delete")"
    [[ -n "$RID2" ]] && dispatch_until "$RID2" "$RUN/44_dispatch_delete.json" || true
    get_json "$PROXY_URL/stats/flow/1" "$RUN/45_stats_flow_1_after_delete.json" || true
    judge "$(flow_lacks "$RUN/45_stats_flow_1_after_delete.json" 1 "$PROBE_DST")" "L2 delete"

    # --- L4 --------------------------------------------------------------------------------------
    say "L4 -- inject_link_failure s1-p3<->s3-p1, hold >= 35 s, recover"
    tc_ends "$RUN/50_tc_before"
    post_json "$KERNEL_URL/ndt/inject_link_failure" "$CUT" "$RUN/51_inject_failure"
    note "inject_link_failure: HTTP $(cat "$RUN/51_inject_failure.code")"
    tc_ends "$RUN/52_tc_during"
    V="$(graph_until 20 cut_is_down "$RUN/53_graph_cut.json")"
    judge "$V" "L4 down"
    # Recorded, not asserted: rerouting is not claimed in this cut.
    set +e
    pingall_loss "$PKG_ROLES" 3 "$RUN/55_ping_during_raw.txt" > "$RUN/54_pingall_during_cut.txt" 2>&1
    set -e
    note "traffic during the cut (recorded, NOT asserted -- (c) does not hold): $(tail -1 "$RUN/54_pingall_during_cut.txt")"
    get_json "$PROXY_URL/v1.0/topology/links" "$RUN/56_proxy_links_during_cut.json" || true
    note "holding 40 s -- at least one updateLinks poll (5 s while converging, 30 s after)"
    sleep 40
    get_json "$KERNEL_URL/ndt/get_graph_data" "$RUN/57_graph_cut_after_poll.json" || true
    judge "$(cut_is_down "$RUN/57_graph_cut_after_poll.json")" "L4 still down after a poll"
    post_json "$KERNEL_URL/ndt/inject_link_recovery" "$CUT" "$RUN/58_inject_recovery"
    note "inject_link_recovery: HTTP $(cat "$RUN/58_inject_recovery.code")"
    V="$(graph_until 60 cut_is_up "$RUN/59_graph_recovered.json")"
    judge "$V" "L4 recovered"
    tc_ends "$RUN/60_tc_after"
    judge "$(no_netem "$RUN/60_tc_after_s1-eth3.txt" "$RUN/60_tc_after_s3-eth1.txt")" "L4 netem"
    set +e
    pingall_loss "$PKG_ROLES" 3 "$RUN/62_ping_after_raw.txt" > "$RUN/61_pingall_after_recovery.txt" 2>&1
    set -e
    note "traffic after recovery (recorded): $(tail -1 "$RUN/61_pingall_after_recovery.txt")"
fi

say "ndt down (phase A)"
set +e
"$NDT" down > "$RUN/69_down_roles.txt" 2>&1
DOWN_RC=$?
set -e
note "rc=$DOWN_RC -> 69_down_roles.txt"
(( DOWN_RC == 0 )) || fail "'ndt down' after phase A exited $DOWN_RC -- phase B would start on an unknown fabric"

# === phase B: the same exercise WITHOUT roles (L5, and L6 for an unbound fabric) =================
if (( DOWN_RC == 0 )); then
    say "ndt up p4 --app $PKG_PLAIN"
    set +e
    "$NDT" up p4 --app "$PKG_PLAIN" > "$RUN/70_up_plain.txt" 2>&1
    UP2_RC=$?
    set -e
    note "rc=$UP2_RC -> 70_up_plain.txt"
    if (( UP2_RC != 0 )); then
        fail "'ndt up p4 --app' (control package) exited $UP2_RC -- L5 is not measured"
    else
        say "L6 -- switch_state capabilities (no roles)"
        # [Co-developed with claude code -- Adam] The unbound package runs the heartbeat too
        # (detect-only): the same checks on its own model (71_switch_state_plain.json).
        l6_plain

        say "L5 -- a write with no binding: 501, and the author's entries untouched"
        stats_flows "$RUN/72_before"
        post_json "$PROXY_URL/stats/flowentry/add" \
            "{\"dpid\":1,\"match\":{\"dl_type\":2048,\"nw_dst\":\"$PROBE_DST\"},\"actions\":[{\"type\":\"OUTPUT\",\"port\":3}]}" \
            "$RUN/73_proxy_add"
        judge "$(refused_501 "$RUN/73_proxy_add.code" "$RUN/73_proxy_add.json")" "L5 proxy"
        # The author's OWN /32 with another port -- round 1's silent-MODIFY hazard, aimed at
        # directly (section 7 ruling 5, item 6).
        post_json "$PROXY_URL/stats/flowentry/add" \
            "{\"dpid\":1,\"match\":{\"dl_type\":2048,\"nw_dst\":\"$AUTHOR_DST\"},\"actions\":[{\"type\":\"OUTPUT\",\"port\":$AUTHOR_MOVED_TO}]}" \
            "$RUN/73b_proxy_add_author_32"
        judge "$(refused_501 "$RUN/73b_proxy_add_author_32.code" "$RUN/73b_proxy_add_author_32.json")" \
              "L5 proxy, the author's own /32"
        RID3="$(batch "$INSTALL" "$RUN/74_batch_install_plain")"
        note "kernel batch: HTTP $(cat "$RUN/74_batch_install_plain.code" 2>/dev/null) request_id=${RID3:-none}"
        if [[ -n "$RID3" ]] && dispatch_until "$RID3" "$RUN/75_dispatch_plain.json"; then
            get_json "$KERNEL_URL/ndt/get_flow_dispatch_status" "$RUN/76_dispatch_global.json" || true
            judge "$(dispatch_refused_unbound "$RUN/75_dispatch_plain.json" "$RUN/76_dispatch_global.json")" \
                  "L5 recent_failures"
        else
            fail "L5: the kernel batch has no completed dispatch record (request_id '${RID3:-none}')"
        fi
        # Through the kernel too: the same /32 in a batch install, which the kernel dispatches
        # to the proxy exactly as it dispatched the one above.
        INSTALL_AUTHOR="{\"install_flow_entries\":[{\"dpid\":1,\"priority\":10,\"match\":{\"eth_type\":2048,\"ipv4_dst\":\"$AUTHOR_DST\"},\"actions\":[{\"type\":\"OUTPUT\",\"port\":$AUTHOR_MOVED_TO}]}],\"modify_flow_entries\":[],\"delete_flow_entries\":[]}"
        RID4="$(batch "$INSTALL_AUTHOR" "$RUN/76b_batch_install_author_32")"
        note "kernel batch at the author's /32: HTTP $(cat "$RUN/76b_batch_install_author_32.code" 2>/dev/null) request_id=${RID4:-none}"
        if [[ -n "$RID4" ]] && dispatch_until "$RID4" "$RUN/76c_dispatch_author_32.json"; then
            get_json "$KERNEL_URL/ndt/get_flow_dispatch_status" "$RUN/76d_dispatch_global.json" || true
            judge "$(dispatch_refused_unbound "$RUN/76c_dispatch_author_32.json" "$RUN/76d_dispatch_global.json")" \
                  "L5 recent_failures, the author's own /32"
        else
            fail "L5: the author-/32 batch has no completed dispatch record (request_id '${RID4:-none}')"
        fi
        stats_flows "$RUN/77_after"
        judge "$(rows_unchanged "$RUN/72_before" "$RUN/77_after")" "L5 author's entries"
        judge "$(flow_has "$RUN/77_after/stats_flow_1.json" 1 "$AUTHOR_DST" "$AUTHOR_PORT")" \
              "L5 the author's /32 still goes out of port $AUTHOR_PORT"
        # Recorded: the same declared links on the control fabric, and the author's own
        # forwarding (NDTwin wrote nothing here).
        V="$(graph_until 30 edges_all_up "$RUN/78_graph_plain.json" "$PKG_PLAIN/ndtwin/topology.json")"
        note "control fabric's graph (recorded): ${V}"
    fi
fi

say "done -- teardown follows"
