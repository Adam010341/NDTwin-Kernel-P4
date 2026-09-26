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
#   H4  exercises/p4runtime (external control plane): /stats/flowentry/add, delete,
#       delete_strict and modify answer 409 `external control plane`; `reroute.reason`
#       external_control_plane, and `ndt up` started no heartbeat there.
#   H5  (PART=h5, separately: it runs 06 and 01, which claim the lab per step) live-p1/06 ONCE
#       with the heartbeat on wherever `ndt up` starts it -> 26 arms, every one's rc and verdict
#       what `2026-09-24T185505Z_06_thirteen` recorded; a sampler of the heartbeat report proves
#       which arms had one running (and that no arm's daemon counted a frame leaving a host
#       port); then 01 (NDTwin's own fabric) PASS, with no heartbeat session started under it.
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
#   * NDT_OWNER must be given explicitly: _common.sh's default (`live-p1`) is not an owner.
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
    echo "   !! refusing: set NDT_OWNER=<you>. _common.sh would default it to 'live-p1', which is" >&2
    echo "      nobody -- a claim nobody owns is one nobody can finish by hand (segment S, round 7)." >&2
    echo "REFUSED 08_heartbeat -- nothing was started"
    exit 2
fi
PART="${PART:-h1h4}"
case "$PART" in h1h4|h5) ;; *) echo "REFUSED 08_heartbeat -- PART=$PART (want h1h4 or h5)"; exit 2 ;; esac
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
PHI_WORST="${PHI_WORST:-0.05}"
H1_SEED="${H1_SEED:-$(( $(date +%s) % 32768 ))}"
#: Filled from the proxy by consts() before the claim; empty until then (never retyped here).
HB_PERIOD_S=""; TIMEOUT_S=""; WATCHDOG_S=""

# consts -- the proxy's own beacon interval, timeout and watchdog interval (never retyped here).
consts() {
    ( cd "$REPO/p4_proxy" && env -u NDTWIN_P4_BEACON_S PYTHONPATH=. PYTHONDONTWRITEBYTECODE=1 "$PY" -c \
        'from proxy_agent import topology_manager as t; print(t.LLDP_BEACON_INTERVAL_S, t.LINK_BEACON_TIMEOUT_S, t.LINK_WATCHDOG_INTERVAL_S)' 2>/dev/null )
}
#: What 06 is reconciled against (H5).
OLD_06="${OLD_06:-$LIVE_DIR/runs/2026-09-24T185505Z_06_thirteen}"
#: The 06 arms that bring up a foreign, non-external fabric with an inter-switch link, i.e. the
#: ones `ndt up p4 --app` starts the heartbeat on. Segment S's census: calc and multicast are one
#: switch; p4runtime and flowcache are external; basic_tunnel and flowcache skeletons do not build.
HB_ARMS="basic/skeleton basic/solution source_routing/skeleton source_routing/solution
basic_tunnel/solution load_balance/skeleton load_balance/solution qos/skeleton qos/solution
link_monitor/skeleton link_monitor/solution firewall/skeleton firewall/solution ecn/skeleton
ecn/solution mri/skeleton mri/solution"

FABRIC_UP=0
TEARDOWN_DOWN_RC=""
INJECTED_IFACES=()
SAMPLER_PID=""
SAMPLER_STOP=""

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

def v_cycle(state, cut_a_wall, cut_b_wall, off, last, down_wall, timeout, phi_target, worst):
    """One H1 cycle on the monotonic clock (the daemon's and the proxy's): the two cut instants,
    the last heard frame before the cut, the kernel's graph showing it down, and the watchdog
    pass that reported it. OK carries the row; BAD when a piece is missing or a cycle meant for
    the worst phase did not land there (it would be measuring a better one)."""
    off = float(off)
    if not last:
        return "BAD no last_heard_mono for the cable in the report"
    if not down_wall:
        return "BAD the kernel's graph never showed the cut down"
    a, b, l, t = float(cut_a_wall) + off, float(cut_b_wall) + off, float(last), float(timeout)
    down = float(down_wall) + off
    passes = ((load(state).get("heartbeat") or {}).get("watchdog_passes")) or []
    rep = [p for p in passes if (p.get("down") or 0) > 0 and p.get("start_mono", 0) >= l]
    if not rep:
        return f"BAD no watchdog pass with a down transition after the last heard frame ({len(passes)} passes served)"
    ps = rep[0]["start_mono"]
    phi = b - l
    if worst == "1" and phi > 1.0:
        return (f"BAD meant for the worst phase ({phi_target} s after a round) and landed {phi:.3f} s after "
                f"the last heard frame -- the cut came before that round's send, so this cycle measured a better phase")
    return "OK " + "\t".join(f"{x:.3f}" for x in (a, b, l, phi, down, down - b, ps, ps - (l + t)))

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
    if bad:
        return f"BAD {len(bad)} arm(s) not as expected: " + "; ".join(bad[:4])
    return f"OK a heartbeat ran on exactly the {had} expected arm(s); no host-port frame in {len(ss)} samples"

def v_no_session(samples_path, t0, t1):
    new = sorted({s["session"] for s in samples(samples_path)
                  if s["status"] == "running" and float(t0) <= s["t"] < float(t1)})
    return "OK no heartbeat session ran during 01 (NDTwin's own pipeline)" if not new \
        else f"BAD a heartbeat ran during 01: {new}"

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
# _common.sh's finish() (ndt down, knobs back, release through w_ndt, verdict).
w_finish() {
    local rc=$?
    set +e
    trap - EXIT INT TERM
    if (( ${#INJECTED_IFACES[@]} > 0 )); then
        note "removing the netem this run added: ${INJECTED_IFACES[*]}"
        revert_link_loss || fail "could NOT remove the netem on ${INJECTED_IFACES[*]} -- remove it by hand before anything else runs"
    fi
    sampler_stop
    NDT=w_ndt
    ( exit "$rc" )
    finish
}

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

# --- the heartbeat report sampler (H5) ---------------------------------------------------------
# One line per second: wall, status, session, pid, forwarded_to_hosts, forwarded_between_switches.
# It stops itself when SAMPLER_STOP appears (or after 5 h); sampler_stop waits for that, and only
# then signals -- by the pid it started, after checking that pid is still this sampler.
SAMPLER_PY='
import json, os, sys, time
report, out, stop = sys.argv[1], sys.argv[2], sys.argv[3]
end = time.time() + 5 * 3600
with open(out, "a", buffering=1) as fh:
    fh.write("wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\n")
    while time.time() < end and not os.path.exists(stop):
        try:
            d = json.load(open(report))
            se = d.get("side_effects") or {}
            fh.write(f"{time.time():.1f}\t{d.get(\"status\")}\t{d.get(\"session\")}\t{d.get(\"pid\")}\t"
                     f"{se.get(\"forwarded_to_hosts\")}\t{se.get(\"forwarded_between_switches\")}\n")
        except (OSError, ValueError):
            fh.write(f"{time.time():.1f}\tabsent\t-\t-\t0\t0\n")
        time.sleep(1.0)
'
sampler_start() {   # sampler_start <out.tsv>
    SAMPLER_STOP="$RUN/.sampler.stop"
    rm -f "$SAMPLER_STOP"
    setsid "$VPY" -I -c "$SAMPLER_PY" "$HB_REPORT_FILE" "$1" "$SAMPLER_STOP" > /dev/null 2>&1 &
    SAMPLER_PID=$!
    note "report sampler pid $SAMPLER_PID -> $(basename "$1")"
}
sampler_stop() {
    [[ -n "$SAMPLER_PID" ]] || return 0
    : > "$SAMPLER_STOP"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SAMPLER_PID" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$SAMPLER_PID" 2>/dev/null \
       && tr '\0' ' ' < "/proc/$SAMPLER_PID/cmdline" 2>/dev/null | /usr/bin/grep -qF "$SAMPLER_STOP"; then
        kill "$SAMPLER_PID" 2>/dev/null || true
    fi
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
# restore) to the first OK poll, or "never"; <out>.at_wall is that poll's wall clock.
graph_until() {
    local limit="$1" every="$2" fn="$3" out="$4" t0 v now
    shift 4
    t0="$(date +%s.%N)"
    : > "$out.polls"
    echo never > "$out.elapsed"; : > "$out.at_wall"
    while :; do
        curl -s --max-time 5 "$KERNEL_URL/ndt/get_graph_data" > "$out" 2> /dev/null || true
        now="$(date +%s.%N)"
        v="$( [[ -s "$out" ]] && verdict "$fn" "$out" "$@" || echo "BAD no get_graph_data capture" )"
        printf '%7.2f  %s\n' "$(awk -v a="$t0" -v b="$now" 'BEGIN{print b-a}')" "$v" >> "$out.polls"
        if [[ "$v" == OK* ]]; then
            awk -v a="$T_CUT" -v b="$now" 'BEGIN{printf "%.2f\n", b-a}' > "$out.elapsed"
            echo "$now" > "$out.at_wall"
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
# Leaves CUT_TARGET (the planned instant) and CUT_MONO (both ends cut) in this shell.
cut_at_phase() {
    local phi="$1" last
    shift
    last="$(report_last "$@")"
    [[ -n "$last" ]] || { fail "the report has no last_heard for s$1:$2<->s$3:$4 -- cannot place the cut"; return 1; }
    CUT_TARGET="$(next_phase_target "$last" "$phi" "$HB_PERIOD_S")"
    sleep_until_mono "$CUT_TARGET"
    cut_link "$@" || return 1
    CUT_MONO="$(mono)"
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

# cut_link <a> <ap> <b> <bp> -- netem loss 100% on both ends (faults.sh's htb-safe attach point).
# A cut refused on its second end comes off the first HERE, while the veth still exists.
cut_link() {
    local dev where
    for dev in "s$1-eth$2" "s$3-eth$4"; do
        where="$(netem_attach_point "$dev")" || true
        if [[ "$where" == unsafe ]]; then
            fail "no safe netem attach point on $dev (netem already there, or the tree is unreadable)"
            revert_link_loss || true
            return 1
        fi
        # shellcheck disable=SC2086 -- "parent H:D" is two words on purpose
        if ! run_tc qdisc add dev "$dev" $where netem loss 100%; then
            fail "tc refused to add netem on $dev ($where)"
            revert_link_loss || true
            return 1
        fi
        INJECTED_IFACES+=("$dev")
        # The instant each end was cut (wall; the cycle converts with the monotonic offset).
        [[ "$dev" == "s$1-eth$2" ]] && CUT_A_WALL="$(date +%s.%N)" || CUT_B_WALL="$(date +%s.%N)"
    done
    T_CUT="$(date +%s.%N)"
}
restore_link() { revert_link_loss; T_CUT="$(date +%s.%N)"; }
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
diff = list(arms); diff[3] = ("source_routing", "solution", "1", "FAIL (4/5)"); tbl(diff, "table_diff.tsv")
tbl(arms[:25], "table_short.tsv")
expected = {"basic/skeleton","basic/solution","source_routing/skeleton","source_routing/solution","basic_tunnel/solution",
            "load_balance/skeleton","load_balance/solution","qos/skeleton","qos/solution","link_monitor/skeleton",
            "link_monitor/solution","firewall/skeleton","firewall/solution","ecn/skeleton","ecn/solution","mri/skeleton","mri/solution"}
def sampled(name, hosts=0, drop=None, extra=None):
    with open(os.path.join(t, name), "w") as fh:
        fh.write("wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\n")
        for i, (e, w, *_r) in enumerate(arms):
            arm = f"{e}/{w}"
            for k in range(0, 100, 5):
                ts = T0 + 100 * i + k
                on = (arm in expected and arm != drop) or arm == extra
                if on and 10 <= k < 90:
                    fh.write(f"{ts}\trunning\tsess{i:02d}\t{1000+i}\t{hosts if k == 50 else 0}\t0\n")
                else:
                    fh.write(f"{ts}\tstopped\tsess{max(i-1,0):02d}\t-\t0\t0\n")
sampled("samples_ok.tsv"); sampled("samples_missing.tsv", drop="qos/solution")
sampled("samples_extra.tsv", extra="calc/solution"); sampled("samples_leak.tsv", hosts=1)
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
    expect OK   "H5 26 arms identical"                               "$(verdict same_06 "$t/table_same.tsv" "$t/table_old.tsv")"
    expect BAD  "H5 one arm differs"                                 "$(verdict same_06 "$t/table_diff.tsv" "$t/table_old.tsv")"
    expect BAD  "H5 an arm missing"                                  "$(verdict same_06 "$t/table_short.tsv" "$t/table_old.tsv")"
    expect OK   "H5 heartbeat on exactly the expected arms"          "$(verdict h5_heartbeat "$t/samples_ok.tsv" "$t/table_same.tsv" "$tend" "$HB_ARMS")"
    expect BAD  "H5 an expected arm had none"                        "$(verdict h5_heartbeat "$t/samples_missing.tsv" "$t/table_same.tsv" "$tend" "$HB_ARMS")"
    expect BAD  "H5 an arm that should have none had one"            "$(verdict h5_heartbeat "$t/samples_extra.tsv" "$t/table_same.tsv" "$tend" "$HB_ARMS")"
    expect STOP "H5 ruling 4 in a sample"                            "$(verdict h5_heartbeat "$t/samples_leak.tsv" "$t/table_same.tsv" "$tend" "$HB_ARMS")"
    expect OK   "H5 no session during 01"                            "$(verdict no_session "$t/samples_ok.tsv" "$tend" "$((tend + 100))")"
    expect BAD  "H5 a session during 01"                             "$(verdict no_session "$t/samples_ok.tsv" 0 "$tend")"
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
        note() { :; }
        judge() { echo "J $2: ${1:0:48}"; }
        CA=1; CAP=3; CB=3; CBP=1; TIMEOUT_S=15; WATCHDOG_S=5; DETECT_BOUND_S=20
        CC_STATE=state_late.json; cut_cycle "T" "$t/cc_graph.json" "$t/cc_state.json" 0.02 1
        echo "STRICT $CYCLE_STRICT ROW $(cut -f9,11 <<<"$CYCLE_ROW" | tr '\t' ' ')"
        CC_STATE=state_nopass.json; cut_cycle "U" "$t/cc_graph2.json" "$t/cc_state2.json" 0.02 1
        echo "STRICT $CYCLE_STRICT FIELDS $(awk -F'\t' '{print NF}' <<<"$CYCLE_ROW")"
    )" || got="the subshell died (rc $?)"
    if /usr/bin/grep -qF "J T detection time: OK detection 20.320 s -- OVER the strict 20" <<<"$got" \
       && /usr/bin/grep -qF "STRICT OVER+0.320 ROW 20.320 220.080" <<<"$got" \
       && /usr/bin/grep -qF "J U detection time: BAD both directions is_up:false (no phase" <<<"$got" \
       && /usr/bin/grep -qF "STRICT ? FIELDS 18" <<<"$got"; then
        ok "cut_cycle: the row, its budget verdict and the strict answer (OVER+0.320); with no record, 18 '?' and the graph poll alone"
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
    [[ "$n_arms" == 17 ]] && ok "HB_ARMS names 17 arms (segment S's 20 running arms less the 3 external ones)" \
                          || red "HB_ARMS names $n_arms arms, not 17"

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
trap w_finish EXIT INT TERM

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
    sampler_start "$RUN/50_samples.tsv"
    set +e
    NDT_OWNER="$NDT_OWNER" bash "$LIVE_DIR/06_thirteen.sh" > "$RUN/51_06.txt" 2>&1
    R06=$?
    T06_END="$(date +%s)"
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

take_claim "P4 heartbeat live H1-H4 (segment W): basic roles (H1, H2), basic unbound (H3), p4runtime external (H4)"

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
note "the design's worst case at the kernel (INFERRED): timeout $TIMEOUT_S s + one watchdog interval $WATCHDOG_S s + report read, HTTP, kernel -- the ticket's bound is $DETECT_BOUND_S s"
RANDOM="$H1_SEED"
note "random phases: seed $H1_SEED (H1_SEED= to repeat)"
printf 'cycle\tphi_target\tcut_a_mono\tcut_b_mono\tlast_heard_mono\tphi_s\tgraph_down_mono\tdetect_s\tpass_start_mono\twatchdog_phase_s\trestore_s\n' > "$RUN/30_cycles.tsv"
for (( CYC = 1; CYC <= H1_CYCLES; CYC++ )); do
    PHI="$(phase_for "$CYC")"
    say "H1 cycle $CYC/$H1_CYCLES -- cut $PHI s after a heartbeat round; down in the kernel's graph within ${DETECT_BOUND_S} s"
    OFF="$(mono_offset)"
    cut_at_phase "$PHI" "$CA" "$CAP" "$CB" "$CBP" || exit 1
    V="$(graph_until $(( DETECT_BOUND_S + 15 )) 0.2 cut_down "$RUN/31_graph_cut_$CYC.json" "$CA" "$CAP" "$CB" "$CBP")"
    judge "$V" "H1 cycle $CYC detection"
    DET="$(cat "$RUN/31_graph_cut_$CYC.json.elapsed")"
    LAST="$(report_last "$CA" "$CAP" "$CB" "$CBP")"
    get_json "$PROXY_URL/p4/switch_state" "$RUN/32_switch_state_cut_$CYC.json" || true
    ROW="$(verdict cycle "$RUN/32_switch_state_cut_$CYC.json" "$CUT_A_WALL" "$CUT_B_WALL" "$OFF" "$LAST" \
           "$(cat "$RUN/31_graph_cut_$CYC.json.at_wall")" "$TIMEOUT_S" "$PHI" "$(( CYC <= H1_WORST ? 1 : 0 ))")"
    judge "$ROW" "H1 cycle $CYC phase record"
    # A cycle that could not be recorded still gets its row, with ? where the record is missing.
    [[ "$ROW" == OK* ]] || ROW="OK $(printf '?\t?\t%s\t?\t?\t%s\t?\t?' "${LAST:-?}" "$DET")"
    IFS=$'\t' read -r _A _B _L PHIA _D _DT _P PSI <<<"${ROW#OK }"
    judge "$(verdict elapsed "$DET" "$DETECT_BOUND_S" "cycle $CYC (cut $PHIA s after the last heard frame, the reporting pass $PSI s after the timeout): both directions is_up:false")" "H1 detection time"
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
    restore_link || { fail "H1 cycle $CYC: could not remove the netem"; exit 1; }
    V="$(graph_until $(( RESTORE_BOUND_S + 15 )) 0.2 cut_up "$RUN/35_graph_restored_$CYC.json" "$CA" "$CAP" "$CB" "$CBP")"
    judge "$V" "H1 cycle $CYC recovery"
    RES="$(cat "$RUN/35_graph_restored_$CYC.json.elapsed")"
    judge "$(verdict elapsed "$RES" "$RESTORE_BOUND_S" "cycle $CYC: both directions is_up:true again")" "H1 recovery time"
    tc_ends "$RUN/36_tc_after_$CYC" "$CA" "$CAP" "$CB" "$CBP"
    judge "$(no_netem "$RUN/36_tc_after_${CYC}_s$CA-eth$CAP.txt" "$RUN/36_tc_after_${CYC}_s$CB-eth$CBP.txt")" "H1 cycle $CYC netem"
    printf '%s\t%s\t%s\t%s\n' "$CYC" "$PHI" "${ROW#OK }" "$RES" >> "$RUN/30_cycles.tsv"
done
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
cut_at_phase "$PHI_WORST" "$CA" "$CAP" "$CB" "$CBP" || exit 1
V="$(graph_until $(( DETECT_BOUND_S + 15 )) 0.2 cut_down "$RUN/64_graph_cut.json" "$CA" "$CAP" "$CB" "$CBP")"
judge "$V" "H3 detection"
judge "$(verdict elapsed "$(cat "$RUN/64_graph_cut.json.elapsed")" "$DETECT_BOUND_S" "both directions is_up:false (cut $PHI_WORST s after a round)")" "H3 detection time"
sleep "$WATCHDOG_S"
stats_flows "$RUN/65_after"
judge "$(verdict rows_unchanged "$RUN/63_before" "$RUN/65_after")" "H3 the author's entries"
post_json "$PROXY_URL/stats/flowentry/add" \
    '{"dpid":1,"match":{"dl_type":2048,"nw_dst":"10.0.9.9"},"actions":[{"type":"OUTPUT","port":3}]}' "$RUN/66_proxy_add"
judge "$(verdict refused_501 "$RUN/66_proxy_add.code" "$RUN/66_proxy_add.json")" "H3 a write is still 501"
restore_link || fail "H3: could not remove the netem"
judge "$(graph_until $(( RESTORE_BOUND_S + 15 )) 0.2 cut_up "$RUN/67_graph_restored.json" "$CA" "$CAP" "$CB" "$CBP")" "H3 recovery"
tc_ends "$RUN/68_tc_after" "$CA" "$CAP" "$CB" "$CBP"
judge "$(no_netem "$RUN/68_tc_after_s$CA-eth$CAP.txt" "$RUN/68_tc_after_s$CB-eth$CBP.txt")" "H3 netem"
cp "$HB_REPORT_FILE" "$RUN/69a_report.json" 2>/dev/null || true
judge "$(verdict hosts_clean "$RUN/69a_report.json")" "H3 ruling 4"
[[ "$VERDICT_WHY" == STOP* ]] && exit 1
phase_down "$RUN/69_down_plain.txt" "phase B (H3)" || exit 1

# === phase C: H4, an external control plane ======================================================
say "ndt up p4 --app $(basename "$PKG_EXT") (external)"
set +e; nd_up "$PKG_EXT" "$RUN/80_up_external.txt"; UPRC=$?; set -e
note "rc $UPRC -> 80_up_external.txt"
(( UPRC == 0 )) || { fail "'ndt up p4 --app' (p4runtime) exited $UPRC -- H4 is not measured"; exit 1; }
set +e; hb_status "$RUN/81_hb_status.txt"; HBRC=$?; set -e
(( HBRC == 3 )) && note "no heartbeat on the external fabric (rc 3), as designed" \
               || fail "H4: 'heartbeat status' answered $HBRC on an external fabric (want 3: ndt starts none there)"
ROUTE='{"dpid":1,"match":{"dl_type":2048,"nw_dst":"10.0.1.1"},"actions":[{"type":"OUTPUT","port":1}]}'
for verb in add delete delete_strict modify; do
    post_json "$PROXY_URL/stats/flowentry/$verb" "$ROUTE" "$RUN/82_flowentry_$verb"
    judge "$(verdict conflict_409 "$RUN/82_flowentry_$verb.code" "$RUN/82_flowentry_$verb.json")" "H4 /stats/flowentry/$verb"
done
get_json "$PROXY_URL/p4/switch_state" "$RUN/83_switch_state.json" || true
judge "$(verdict reroute "$RUN/83_switch_state.json" false external_control_plane)" "H4 reroute"
phase_down "$RUN/89_down_external.txt" "phase C (H4)" || exit 1

say "done -- teardown follows"
