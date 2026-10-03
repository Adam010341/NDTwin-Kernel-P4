"""Every cell, control and self-check of the health check, as rows. Adding one is one row.

[Co-developed with claude code -- Adam]

The cells, controls, self-checks and rule D's edges of the health-check design (sections 2.1,
2.3 and 12 of the design notes kept with the project's audit records), plus the rows marked q3b:
the six categories outside the 16 dimensions and the varbit cell, added in Cut 1 (design
section 13) and reworked in the Cut 1 review (design section 14).

Predictions are NOT here. They live in doc/audit/2026-10-03_p4-health-check/expected_today.tsv,
committed before any live run, and are read from that file (expected.py) -- a prediction this
module could compute would be a prediction made after the fact.

Each row says which keys of its observation it needs (`need`: "a:<key>" in the answer, "o:<key>"
in the oracle). A key that is missing or None is a reading that was not taken: the cell is NOT
RUN, never GREEN and never RED (verdict.decide, step 4b). The row's own functions then decide
only on readings that exist.
"""
from __future__ import annotations

import math

from .verdict import (GREEN, NOT_RUN, PROBE_BROKEN, Verdict, broken, green, not_run,
                      partial, red, unattributed)

# --- the markers' dports, mirrored from exercise/src/hc_main.p4's HC_DPORT_* -------------------
DPORTS = {"K1": 40011, "K2": 40012, "MT1": 40021, "MT3": 40023, "R2": 40031, "D1": 40041,
          "P2": 40050, "C1": 40061, "MCAST": 40062, "Q1": 40071, "TTL1": 40081, "RC1": 40091,
          "HR1": 40092, "HR2": 40093, "VB1": 40095, "CH6": 40096}
ETHERTYPES = {"CH1": 0x1212, "CH2": 0x1234, "CH7": 0x1236, "HU1": 0x86DD, "HU1x": 0x1238,
              "HB": 0x88B5}

#: TP2 / TP4 / CP4: how long a cut link may take to read `is_up=false` (design 2.3).
LINK_DOWN_DEADLINE_S = 20.0
#: (r3) How a timed reading says "it never happened": the observer watched the whole window and
#: the event did not come. Spelled as a value, never as a missing key -- a missing key is a
#: reading not taken (step 4b) and must not be confused with an observation of absence.
NEVER = "never"
#: (r4, Cut 1 follow-ups) The encoding is validated, never repaired: a timed reading is NEVER or a
#: real number of seconds, 0 <= s <= its own `watched_s` (an event cannot be seen after the
#: observer stopped looking), and `watched_s` is itself a real number >= 0. Anything else is a
#: reading the observer got wrong -- PROBE-BROKEN (timing_problem), never RED and never GREEN.
#: (r3) CP4: the route the kernel wrote is not in s1's thrift dump at all after the cut.
GONE = "gone"
#: (r3) IT1: how long after the switch shows the entry aged NDTwin may take to report it.
IT1_REPORT_DEADLINE_S = 10.0
#: (r3, review NEW-A) The no-sample floor is computed from the SENDER's own count, never from
#: NDTwin's emitter: link telemetry samples 1 in 256 (link_telemetry.py:69), and a cell whose
#: stimulus expects fewer than 19 samples is NOT RUN (P(0 samples | 19 expected) ~ 6e-9). At or
#: above the floor a twin that saw nothing is RED -- a broken emitter is NDTwin's fault, not luck.
SAMPLE_ONE_IN = 256
MIN_EXPECTED_SAMPLES = 19
IDENTITY_MIN_SENT = SAMPLE_ONE_IN * MIN_EXPECTED_SAMPLES        # 4864 frames
#: (r3, review MINOR 4; r4, Cut 1 follow-ups) HR1 / HR2's stimulus: 24000 frames of 64 bytes at
#: 800 kbit/s in all, 15.4 s -- under the 0.5 Mbit/s shaped uplink for HR2's half. The bound is
#: computed against the cell's ABSOLUTE threshold, CARRY_SHARE x the sender's flow_bytes, which is
#: CARRY_SHARE x HR_FRAMES / SAMPLE_ONE_IN = 18.75 samples' worth, so a half needs 19 samples.
#: Each uplink half of HR2 gets about Poisson(HR_FRAMES / 2 / SAMPLE_ONE_IN) = 46.9 samples (the
#: coin splits the frames, the 1-in-256 sampling thins them: two independent Poissons), and a half
#: with 18 or fewer fails: P ~ 1.3e-6 per half, 2.6e-6 for either (the test computes it, and
#: rejects anything above 1e-5; 20000 frames gave 2.0e-5). Assumed, as the test assumes: every
#: sample books SAMPLE_ONE_IN x its frame's bytes, and the quiet-window noise is zero. They run
#: after TP2, whose heartbeat they would otherwise load, and before Q1, which floods s1-eth5 and
#: stays last (design 2.4).
HR_FRAMES = 24000
HR_FRAME_BYTES = 64
HR_RATE_KBIT = 800
#: (r3) The order the active cells of bring-up A run in where it matters: (earlier, later).
#: (r4) NOTHING CONSUMES THIS YET. No scheduler for the active cells exists in Cut 1; the Cut 3
#: scheduler must read it, and the one test that touches it checks only the constant. A run order
#: that is written down here and enforced nowhere is a promise, not a fact -- do not read the
#: table as saying the order is kept (design 14.7).
ORDER = (("TP2", "HR1"), ("TP2", "HR2"), ("HR1", "Q1"), ("HR2", "Q1"), ("TP2", "Q1"))
#: Q1: the shaped link's rate, kbit/s, on both of its interfaces.
SHAPED_KBIT = 500.0
SHAPED_IFACES = ("s1-eth5", "s3-eth2")
#: HR1 / HR2: an uplink CARRIED the cell's flow when its bytes in the flow window exceed its own
#: quiet-window bytes (heartbeat and telemetry, which run on every link) by at least this share
#: of the bytes the sender sent. The same rule reads the twin's link usage.
CARRY_SHARE = 0.2
UPLINKS = ("s1-eth4", "s1-eth5")
#: (r4) HR1 sends all of HR_RATE_KBIT on ONE uplink, and HR_RATE_KBIT is above SHAPED_KBIT: its
#: 5-tuple must hash to the UNSHAPED uplink, or the shaper, not the program, decides how many
#: frames arrive. The Cut 3 stimulus picks a tuple that hashes there (S0 already finds tuples for
#: both uplinks); hr_pre(1) makes a wrong pick NOT RUN instead of a verdict.
HR1_UPLINK = [u for u in UPLINKS if u not in SHAPED_IFACES][0]
#: HU1: the side table holds at most 1024 keys (FlowLinkUsageCollector.hpp:740-747); a window
#: that starts this close to the cap could lose its row to the cap, not to NDTwin.
SIDE_TABLE_ROOM = 1000
DPIDS = ("1", "2", "3", "4")

CORE_DIMENSIONS = ("pipeline_load", "tables", "pre_multicast", "pre_clone", "counters", "meters",
                   "registers", "digest", "packet_io", "custom_headers", "queue_metadata",
                   "checksum", "ttl_or_hop", "topology", "control_plane_mode", "verification")
Q3B_DIMENSIONS = ("action_profile", "idle_timeout", "value_set", "recirculate", "hash_random",
                  "header_union")


class Cell(object):
    def __init__(self, id, dimension, scope, kind, bringup, cut, compare=None, cannot=None,
                 gates=(), self_checks=(), controls=(), red_attribution=("structural",),
                 negative_read=False, needs_oracle=True, needs_answer=True, need=(),
                 precondition=None, alias_of=None, alias_why=None, q3b=False, min_sent=None):
        self.id, self.dimension, self.scope, self.kind = id, dimension, scope, kind
        self.bringup, self.cut = bringup, cut
        self.compare, self.cannot = compare, cannot
        self.gates, self.self_checks, self.controls = tuple(gates), tuple(self_checks), tuple(controls)
        self.red_attribution = tuple(red_attribution)
        self.negative_read, self.needs_oracle, self.needs_answer = negative_read, needs_oracle, needs_answer
        self.need = tuple(need)
        self.precondition = precondition          # obs -> (ok, why), or None
        self.alias_of, self.alias_why, self.q3b = alias_of, alias_why, q3b
        self.min_sent = min_sent                  # (r3) step 3's floor, from the sender's count


class SelfCheck(object):
    def __init__(self, id, check, gates=(), self_checks=(), q3b=False):
        self.id, self.check = id, check
        self.gates, self.self_checks, self.q3b = tuple(gates), tuple(self_checks), q3b
        self.controls = ()


class Control(object):
    """A known-answer control (K1-neg, T3-neg): a name the switch does not have must be refused
    with the endpoint's OWN 404 -- `{"error": "not in this pipeline"}` (api_routes.py:1015 for the counter,
    :940 for the table entry). FastAPI's 404 for a route that does not exist, or "unknown switch", is not that
    answer, and anything else means the instrument is wrong: PROBE-BROKEN, never RED."""

    ERROR = "not in this pipeline"

    def __init__(self, id, of, expect_http):
        self.id, self.of, self.expect_http = id, of, expect_http

    def judge(self, obs):
        a = (obs or {}).get("answer")
        if isinstance(a, dict) and a.get("route") is False:
            # (r3, review MINOR 3) the endpoint itself is missing from openapi: there is nothing
            # to ask, so the control is not run -- and the cell goes RED for "no route" at step 1
            # instead of the whole round going PROBE-BROKEN.
            return Verdict(NOT_RUN, "no route: the endpoint is not in the proxy's openapi",
                           phase="control-no-route")
        if not isinstance(a, dict) or a.get("http") is None:
            return Verdict(NOT_RUN, "control not observed", phase="control")
        if a["http"] == self.expect_http and a.get("error") == self.ERROR:
            return Verdict(GREEN, "answered %d %r, the expected refusal" % (a["http"], self.ERROR),
                           phase="control")
        return Verdict(PROBE_BROKEN, "known-answer control answered %s %r, not %d %r"
                       % (a["http"], a.get("error"), self.expect_http, self.ERROR), phase="control")


# --- small readers shared by the rows ------------------------------------------------------------

def A(obs):
    return obs.get("answer") or {}


def O(obs):
    return obs.get("oracle") or {}


def thrift_ev(obs):
    return ("thrift",) if obs.get("oracle") is not None else ()


def route_missing(obs):
    """NDTwin's openapi lacks the endpoint this cell needs. A structural "cannot" -- never the
    same thing as "the object is absent" (mutation M2)."""
    return A(obs).get("route") is False


def no_route(what):
    def cannot(obs):
        if route_missing(obs):
            return red("no route: the proxy's openapi has no %s endpoint" % what, "structural",
                       *thrift_ev(obs))
        return None
    return cannot


def http_cannot(codes, what):
    def cannot(obs):
        if route_missing(obs):
            return red("no route: the proxy's openapi has no %s" % what, "structural", *thrift_ev(obs))
        http = A(obs).get("http")
        if http in codes:
            return red("%s answered %d" % (what, http), "structural", *thrift_ev(obs))
        return None
    return cannot


def counter_reading(a):
    """NDTwin's counter delta, or None unless the read was a 200. A 503 is EXPLICITLY NOT A ZERO
    (api_routes.py:963-1029); reading it as one is mutation M5."""
    if a.get("http") != 200:
        return None
    return a.get("delta")


def heartbeat_usable(hb):
    """`heartbeat.state == "usable"` -- not "the heartbeat block is there": the proxy runs a
    watchdog on every foreign fabric (main.py:2326-2332), so non-null proves nothing (M15)."""
    return isinstance(hb, dict) and hb.get("state") == "usable"


def g1_complete(g1):
    """All three of G1's readings were taken."""
    return isinstance(g1, dict) and g1.get("on_path") is not None \
        and g1.get("main_integral") is not None and g1.get("off_path_max") is not None


def g1_holds(g1):
    """G1 (_common.sh:911,1065-1140): the on-path set is non-empty, the main path's integral is
    above zero, and every link off the path saw less than one sample. A missing number is not
    a pass: G1 needs all three."""
    if not isinstance(g1, dict):
        return False
    if g1.get("main_integral") is None or g1.get("off_path_max") is None:
        return False
    return bool(g1.get("on_path")) and g1["main_integral"] > 0 and g1["off_path_max"] < 1


def _find_side(rows, ethertype, src, dst):
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        et = row.get("ethertype")
        try:
            et = int(et, 0) if isinstance(et, str) else int(et)
        except (TypeError, ValueError):
            continue
        if et == ethertype and str(row.get("src_mac", "")).lower() == src \
                and str(row.get("dst_mac", "")).lower() == dst:
            return row
    return None


def side_row_grew(a, ethertype):
    """The side table has a row for exactly this ethertype AND this host pair, and its
    `samples` went up inside the window (design 2.3 CH7; section 12 item 6)."""
    pair = a.get("pair") or {}
    src, dst = str(pair.get("src_mac", "")).lower(), str(pair.get("dst_mac", "")).lower()
    if not src or not dst:
        return False
    after = _find_side(a.get("side_after"), ethertype, src, dst)
    if after is None:
        return False
    before = _find_side(a.get("side_before"), ethertype, src, dst)
    return int(after.get("samples") or 0) > int((before or {}).get("samples") or 0)


def _real(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def timing_problem(a, key):
    """Why the timed reading a[key] and a["watched_s"] are not a valid encoding (see NEVER), or
    None. Called by the cell BEFORE it uses either value (r4, Cut 1 follow-ups)."""
    watched, value = a.get("watched_s"), a.get(key)
    if not _real(watched) or watched < 0:
        return "watched_s is %r, not a number of seconds >= 0" % (watched,)
    if value == NEVER:
        return None
    if not _real(value) or value < 0:
        return "%s is %r: neither %r nor a number of seconds >= 0" % (key, value, NEVER)
    if value > watched:
        return "%s is %s s but the observer only watched %s s" % (key, value, watched)
    return None


def deadline_met(seconds, deadline=LINK_DOWN_DEADLINE_S):
    """A number of seconds, 0 <= s <= the deadline. NEVER (watched the window, it did not happen)
    is not met; neither is anything else."""
    if seconds == NEVER:
        return False
    return _real(seconds) and 0 <= seconds <= deadline


def watched_enough(a, deadline=LINK_DOWN_DEADLINE_S):
    """A NEVER is an observation only if the observer watched at least the whole deadline."""
    w = a.get("watched_s")
    return isinstance(w, (int, float)) and w >= deadline


def nonempty(*values):
    return all(isinstance(v, (list, tuple, set, frozenset, dict)) and len(v) > 0 for v in values)


# --- the rows' functions, one block per dimension --------------------------------------------------

def pl1(obs):
    a, o, expect = A(obs), O(obs), (obs.get("expect") or {}).get("pipelines") or {}
    if set(expect) != set(DPIDS):
        return broken("the probe's own expectation does not name s1-s4's programs")
    for dpid in DPIDS:
        got = (a.get("pipelines") or {}).get(dpid)
        if got != expect[dpid]:
            return red("s%s reports pipeline %s, expected %s" % (dpid, got, expect[dpid]), "structural")
    if (o.get("alt_table") or {}).get("1") is not True:
        return red("thrift: s1 does not list the table only hc_alt has", "structural", "thrift")
    return green("every switch runs its program; only s1 lists the hc_alt table")


def pl2(obs):
    a, o = A(obs), O(obs)
    if "pipeline_push" not in (a.get("skipped") or []):
        return red("the proxy did not skip pipeline_push on an external fabric", "structural")
    if o.get("primary") is not True:
        return red("the external controller is not primary", "structural")
    if o.get("set_pipeline_ok") is not True:
        return red("the controller's SetForwardingPipelineConfig did not return OK", "structural")
    return green("pipeline_push skipped; the controller is primary and pushed its own")


def t1(obs):
    a, o, expect = A(obs), O(obs), (obs.get("expect") or {}).get("entries") or {}
    if set(expect) != set(DPIDS):
        return broken("the probe's own expectation does not cover s1-s4")
    counts, dumps = a.get("counts") or {}, o.get("dumps") or {}
    for dpid in DPIDS:
        c = counts.get(dpid)
        if not isinstance(c, dict) or c.get("recorded") is None or c.get("applied") is None:
            return red("s%s: switch_state carries no table_entries counts" % dpid, "structural")
        if c.get("failed", 0) > 0:
            return red("s%s: %d entr(ies) failed" % (dpid, c["failed"]), "structural")
        if c["recorded"] != c["applied"] or c["recorded"] == 0:
            return red("s%s: recorded %s, applied %s" % (dpid, c["recorded"], c["applied"]), "structural")
    for dpid in DPIDS:
        got = dumps.get(dpid)
        if got is None:
            return not_run("s%s: no thrift dump" % dpid)
        if set(got) != set(expect[dpid]):
            return red("s%s: the thrift dump is not the package's entries" % dpid, "structural", "thrift")
    return green("recorded == applied, failed == 0, every dump matches entry for entry")


def t2(obs):
    a, o = A(obs), O(obs)
    if a["applied"] is not True:
        return red("NDTwin does not report s2's runtime default as applied", "structural")
    got = o["s2_default"]
    if (got[0], tuple(got[1])) != ("HcIngress.stamp", (0x2A,)):
        return red("thrift: s2's default is %r, not stamp(0x2A)" % (got,), "structural", "thrift")
    return green("s2's default is the runtime stamp(0x2A)")


def write_then_read(what, checks):
    """The write answered 200 and every one of `checks` (oracle booleans) is True afterwards.
    The checks are named by the row, so a missing one is a reading not taken (need), never a
    pass (review MAJ-1)."""
    def compare(obs):
        a, o = A(obs), O(obs)
        if a["http"] != 200:
            return red("%s answered %s" % (what, a["http"]), "structural")
        for key in checks:
            if o.get(key) is not True:
                return red("thrift after the write: %s is not true" % key, "structural", "thrift")
        return green("written, and thrift shows it (%s)" % ", ".join(checks))
    return compare


def wtr(cid, what, checks, **kw):
    """A write-then-read row: needs the http answer and every named check."""
    need = ("a:http",) + tuple("o:" + k for k in checks)
    return dict(compare=write_then_read(what, checks), need=need, **kw)


def t7(obs):
    a, o = A(obs), O(obs)
    if a["http"] != 200:
        return red("POST answered %s for the overlapping pair" % a["http"], "structural")
    if o["order_ok"] is not True:
        return red("thrift: the two overlapping entries' priorities are in the wrong order",
                   "structural", "thrift")
    return green("both overlapping entries present, priority order right")


def t8_cannot(obs):
    if A(obs).get("journaled") is False:
        return red("switch_state's `journaled` is the constant false (api_routes.py:765-767)",
                   "structural")
    return None


def t8(obs):
    if A(obs)["journaled"] is True:
        return green("journaled; the restart half is deferred (design 2.3)")
    return not_run("switch_state's journaled field is %r" % (A(obs)["journaled"],))


def pft_cannot(obs):
    a = A(obs)
    if a.get("rc") not in (None, 0) and (a.get("g5_rows") or 0) >= 1 and a.get("other_fail_rows") == 0:
        return red("pre-flight refuses a boot entry that names a TERNARY field (G5 not done)",
                   "structural")
    return None


def pft(obs):
    a = A(obs)
    if a["rc"] == 0:
        return green("pre-flight accepts a boot ternary entry")
    return broken("pre-flight failed on something other than the ternary row (%s other FAIL "
                  "row(s)): a path or format error, not the G5 answer" % a.get("other_fail_rows"))


def m1(obs):
    a, o = A(obs), O(obs)
    if a["recorded"] < 1 or a["applied"] != a["recorded"]:
        return red("multicast applied %s of %s" % (a["applied"], a["recorded"]), "structural")
    if o["s1_group1"] != frozenset({1, 2}):
        return red("thrift: s1's group 1 is %r, not {1, 2}" % (o["s1_group1"],), "structural", "thrift")
    return green("group 1 on s1 replicates to {p1, p2}")


def m2(obs):
    a, o = A(obs), O(obs)
    if not o["declared"]:
        return broken("the probe declared no ports for group 2")
    if a["http"] != 200:
        return red("POST /p4/multicast_group answered %s" % a["http"], "structural")
    if o["group2_after"] != frozenset(o["declared"]):
        return red("thrift: group 2 is %r after the write" % (o["group2_after"],), "structural", "thrift")
    return green("group 2 written and replicating to the declared ports")


def c1(obs):
    a, o = A(obs), O(obs)
    if a["applied"] != 1:
        return red("clone applied %s, not 1" % a["applied"], "structural")
    if o["ports"] != frozenset({1}):
        return red("thrift: session 7's group replicates to %r, not {p1}" % (o["ports"],),
                   "structural", "thrift")
    return green("session 7 on s2 mirrors to p1")


def k1_cannot(obs):
    if route_missing(obs):
        return red("no route: the proxy's openapi has no GET /p4/counter", "structural", *thrift_ev(obs))
    if A(obs).get("http") == 404:
        return red("GET /p4/counter answered 404 (not in this pipeline)", "structural",
                   *thrift_ev(obs))
    return None


def counter_equal(obs):
    a, o = A(obs), O(obs)
    mine = counter_reading(a)
    if mine is None:
        return red("GET /p4/counter answered %s, which is not a reading" % a.get("http"),
                   "structural", "thrift")
    if mine != o["delta"]:
        return red("NDTwin read %s, thrift %s" % (mine, o["delta"]), "structural", "thrift")
    return green("NDTwin's counter delta equals thrift's (%s)" % mine)


def k2_pre(obs):
    """Design 2.3 K2: thrift's direct counter moved, and by exactly what was sent."""
    delta, sent = O(obs).get("delta"), obs.get("sent")
    if not delta or delta != sent:
        return False, "thrift's direct counter moved by %s for %s sent" % (delta, sent)
    return True, ""


def rates_written(obs):
    a, o = A(obs), O(obs)
    if not o["target"]:
        return broken("the probe's own target rates are empty")
    if a["http"] != 200:
        return red("the meter write answered %s" % a["http"], "structural")
    if o["rates_after"] != o["target"]:
        return red("thrift: the meter's rates are %r, not %r" % (o["rates_after"], o["target"]),
                   "structural", "thrift")
    return green("the rates written are the rates thrift reads")


def r2(obs):
    a, o = A(obs), O(obs)
    if a["value"] != o["value"]:
        return red("NDTwin read %s, thrift %s" % (a["value"], o["value"]), "structural", "thrift")
    return green("NDTwin's register read equals register_read")


def r3(obs):
    a, o = A(obs), O(obs)
    if a["http"] != 200:
        return red("the register write answered %s" % a["http"], "structural")
    if o["value_after"] != o["target"]:
        return red("thrift: the register holds %s, not %s" % (o["value_after"], o["target"]),
                   "structural", "thrift")
    return green("the value written is the value register_read returns")


def exit_cannot(what, cite):
    def cannot(obs):
        if A(obs).get("exit") is False:
            return red("NDTwin has no %s exit (%s)" % (what, cite), "structural")
        return None
    return cannot


def d1(obs):
    a, o = A(obs), O(obs)
    if not o["fields"]:
        return broken("the marker's own fields are empty")
    if a["fields"] != o["fields"]:
        return red("NDTwin's digest content %r is not the marker's %r" % (a["fields"], o["fields"]),
                   "structural")
    return green("NDTwin's digest equals the marker's fields")


def argv_flag(flag, value, what):
    def compare(obs):
        if O(obs)["argv_has"] is True:
            return green("the bmv2 argv has %s%s" % (flag, " %s" % value if value else ""))
        return red("the bmv2 argv lacks %s%s (%s)" % (flag, " %s" % value if value else "", what),
                   "structural")
    return compare


def delivered(obs):
    a, o = A(obs), O(obs)
    if "http" in a and a["http"] != 200:
        return red("the endpoint answered %s" % a["http"], "structural")
    if o["received"] >= 1:
        return green("delivered")
    return red("nothing arrived where NDTwin's endpoint said it would", "structural")


# GAP-2b = doc/audit/2026-09-04_p4-tutorial-exercise-prep/GAP-2b-ndtwin-p4-capabilities-2026-09-27.md, on the trunk branch (not on main).
def p4(obs):
    """Section 12 item 8, decided in Cut 1: the controller receiving its packet-in is PARTIAL(b)
    -- the exercise's own controller did NDTwin's half of packet_io (GAP-2b 0.3 (b)). Nothing
    arriving is RED, attributed ("bmv2" here means: B's controller is primary and its own writes
    take, so the silence is not the controller's) only then."""
    if O(obs)["received"] is True:
        return partial("b", "the controller got its packet-in; no NDTwin code is on that path")
    return red("no packet-in on dport 40050 reached the external controller")


def expected_samples(sent):
    return (sent or 0) / float(SAMPLE_ONE_IN)


def sampled_or_not_run(obs, sent_key="sent"):
    """Design 2.3 (r3, review NEW-A): too small a stimulus to expect a sample is NOT RUN. The
    expectation comes from the SENDER's own count at 1/256; NDTwin's emitter count plays no part,
    so an emitter that sampled nothing over a big enough stimulus leaves the cell to go RED."""
    if expected_samples(obs.get(sent_key)) < MIN_EXPECTED_SAMPLES:
        return not_run("stimulus: %s frames expect %.1f samples at 1/%d, under the floor of %d"
                       % (obs.get(sent_key), expected_samples(obs.get(sent_key)), SAMPLE_ONE_IN,
                          MIN_EXPECTED_SAMPLES))
    return None


def identity_cell(ethertype=None, partial_ok=False, g1=True):
    """CH1/CH2/CH7/CH8/V1/RC1-shaped cells: G1, then flow identity, then the side table. (The
    stimulus floor is step 3's, from the sender's count: Cell.min_sent.)"""
    def compare(obs):
        a = A(obs)
        if g1 and not g1_complete(a.get("g1")):
            return not_run("G1's on-path set, main-path integral or off-path maximum was not read")
        if g1 and not g1_holds(a.get("g1")):
            return red("G1 does not hold: link usage is not on the path", "structural")
        if a.get("flow_identity") is True:
            return green("the flow table has the sender's 5-tuple" + (" and G1 holds" if g1 else ""))
        if ethertype is not None and side_row_grew(a, ethertype):
            if partial_ok:
                return partial("a", "only the side table: ethertype 0x%04X, this host pair, "
                                    "samples grew" % ethertype)
            return green("G1 holds and the side table has 0x%04X for this pair, samples grew"
                         % ethertype)
        if ethertype is None and not partial_ok:
            return green("G1 holds")
        return red("no flow identity and no side-table row for this pair", "structural")
    return compare


def ident_need(g1=True, side=False):
    need = ("a:flow_identity",)
    if g1:
        need += ("a:g1",)
    if side:
        need += ("a:pair", "a:side_after")
    return need


def flow_correct(obs):
    if A(obs)["flow_identity"] is True:
        return green("the flow table has the right identity")
    return red("the flow table's identity is wrong or missing", "structural")


def ch4(obs):
    if A(obs)["identity"] in ("correct", "disclosed"):
        return green("flow port is the real port, or NDTwin says it cannot decode the shim")
    return red("the flow table shows a port that is not the real one", "structural")


def q1(obs):
    a, o = A(obs), O(obs)
    if o["shaped"] is not True:
        return red("no 0.5 Mbit/s qdisc on %s" % " and ".join(SHAPED_IFACES), "structural")
    if set(a["sent_idents"]) != {0}:
        return not_run("the sender did not send identification 0, so a flag proves nothing")
    stamped = [r for r in (o.get("received") or []) if int(r.get("ident", 0)) & 0x8000]
    if not stamped:
        return not_run("no packet carried the 0x8000 stamp flag")
    if any(int(r["ident"]) & 0x7FFF > 0 for r in stamped):
        return green("shaped, stamped, and at least one qdepth > 0")
    return unattributed("shaped and stamped, but qdepth was 0 on every packet")


def cs1(obs):
    hosts = O(obs)["tx_checksum_off"]
    if not hosts:
        return not_run("no host's ethtool answer")
    if all(v is True for v in hosts.values()):
        return green("tx-checksumming off on every host")
    return red("tx-checksumming is on (or unknown) on %s"
               % sorted(h for h, v in hosts.items() if v is not True), "structural")


def ttl1(obs):
    if O(obs)["received"] >= 1:
        return green("the marker reached the receiver")
    return not_run("no marker arrived")


TP1_ITEMS = ("switches", "hosts", "edges", "ports")


def tp1(obs):
    a, o = A(obs), O(obs)
    if not nonempty(*[o[i] for i in TP1_ITEMS]):
        return not_run("the fabric oracle is empty for at least one of %s" % ", ".join(TP1_ITEMS))
    for item in TP1_ITEMS:
        if a[item] != o[item]:
            return red("get_graph_data's %s differ from the fabric's" % item, "structural")
    return green("switches, hosts (IP, MAC), edges and ports all equal the fabric")


def link_cut(obs):
    a = A(obs)
    bad = timing_problem(a, "down_after_s")
    if bad:
        return broken("the observer's timing is not a valid reading: %s" % bad)
    if a["down_after_s"] == NEVER and not watched_enough(a):
        return not_run("the edge was watched for %s s, less than the %d s deadline" % (a.get("watched_s"), LINK_DOWN_DEADLINE_S))
    if not deadline_met(a["down_after_s"]):
        return red("the cut edge read is_up=false after %s s (deadline %d s)"
                   % (a["down_after_s"], LINK_DOWN_DEADLINE_S), "structural")
    if a["recovered"] is not True:
        return red("the edge did not come back after the netem was removed", "structural")
    return green("is_up=false within the deadline, and back after")


def tp2_pre(obs):
    hb = A(obs).get("heartbeat")
    if not heartbeat_usable(hb):
        return False, "heartbeat state is %r, not usable" % ((hb or {}).get("state"),)
    if (hb or {}).get("missing_directions"):
        return False, "heartbeat missing directions %s" % hb["missing_directions"]
    return True, ""


def tp4_pre(obs):
    a = A(obs)
    if a.get("drop_check_rc") != 0:
        return False, "drop check rc %s" % a.get("drop_check_rc")
    if a.get("withheld") is not False:
        return False, "heartbeat.withheld present (or unknown)"
    if not heartbeat_usable(a.get("heartbeat")):
        return False, "heartbeat not usable"
    return True, ""


def cp2(obs):
    a, o = A(obs), O(obs)
    if a["http"] == 200 or o["entry_present"] is True:
        return red("the proxy wrote on an external fabric (POST %s)" % a["http"], "structural")
    if a["http"] != 409:
        return red("POST answered %s, not the refusal 409" % a["http"], "structural")
    if o["controller_entry_present"] is not True:
        return broken("the same dump does not show the controller's own entry, so this read "
                      "cannot tell absent from unreadable")
    return green("409, nothing written, and the controller's own entry is there")


def cp4_pre(obs):
    if not heartbeat_usable(A(obs).get("heartbeat")):
        return False, "heartbeat not usable"
    return True, ""


def cp4(obs):
    a, o = A(obs), O(obs)
    caps = a["capabilities"] or {}
    if (caps.get("ipv4_route"), caps.get("binding_source"), caps.get("reroute")) != ("ndtwin", "package", True):
        return red("capabilities are %r" % (caps,), "structural")
    if o["kernel_route_present"] is not True:
        return red("thrift: no kernel-written route on s1", "structural", "thrift")
    bad = timing_problem(a, "rerouted_after_s")
    if bad:
        return broken("the observer's timing is not a valid reading: %s" % bad)
    # (r4) the watch length comes BEFORE `gone`: a route read as gone while the observer had not
    # yet watched the whole deadline is not an observation of the end state
    if a["rerouted_after_s"] == NEVER and not watched_enough(a):
        return not_run("the route was watched for %s s, less than the %d s deadline" % (a.get("watched_s"), LINK_DOWN_DEADLINE_S))
    if o["port_after_cut"] == GONE:
        return red("thrift: s1's route to h6 is gone after the cut", "structural", "thrift")
    if o["port_after_cut"] != 5 or not deadline_met(a["rerouted_after_s"]):
        return red("s1's route to h6 did not move to p5 within the deadline", "structural", "thrift")
    return green("roles bound, the kernel's route moved to p5 after the cut")


def v2(obs):
    a = A(obs)
    if a["bytes_match"] is not True:
        return red("link bytes do not match netdev", "structural")
    if a["flow_identity"] is True:
        return green("bytes match and the flow table has the identity")
    return partial("a", "bytes match; the identity is only in the side table")


def it1_cannot(obs):
    a = A(obs)
    if a.get("idle_field") is False or a.get("notification_exit") is False:
        return red("NDTwin cannot write an idle timeout, or has no exit for IdleTimeoutNotification "
                   "(p4_client.py:526-551 handles packet and arbitration only)", "structural")
    return None


def it1_pre(obs):
    """The entry really aged on the switch: thrift's `Life: <since hit>ms ..., timeout is <t>ms`
    shows more time since the last hit than the timeout. Otherwise nothing was owed a report."""
    o = O(obs)
    if o.get("since_hit_ms") is None or o.get("timeout_ms") is None:
        return False, "no Life: line in thrift's dump"
    if o["since_hit_ms"] <= o["timeout_ms"]:
        return False, "the entry has not aged (%s ms since hit, timeout %s ms)" % (o["since_hit_ms"], o["timeout_ms"])
    return True, ""


def it1(obs):
    a, o = A(obs), O(obs)
    if o["timeout_ms"] != a["requested_timeout_ms"]:
        return red("thrift shows timeout %s ms, NDTwin was asked for %s ms"
                   % (o["timeout_ms"], a["requested_timeout_ms"]), "structural", "thrift")
    bad = timing_problem(a, "reported_after_s")
    if bad:
        return broken("the observer's timing is not a valid reading: %s" % bad)
    if a["reported_after_s"] == NEVER and not watched_enough(a, IT1_REPORT_DEADLINE_S):
        return not_run("watched for %s s after the entry aged, less than the %d s deadline"
                       % (a.get("watched_s"), IT1_REPORT_DEADLINE_S))
    if deadline_met(a["reported_after_s"], IT1_REPORT_DEADLINE_S):
        return green("the entry aged on the switch and NDTwin reported its idle timeout in time")
    return red("the entry aged on the switch and NDTwin did not report it within %d s (%s)"
               % (IT1_REPORT_DEADLINE_S, a["reported_after_s"]), "structural", "thrift")


def _carried(win, flow_bytes):
    """{uplink: carried?} from {uplink: {"base": bytes, "during": bytes}}; None when unreadable."""
    out = {}
    for up in UPLINKS:
        w = (win or {}).get(up)
        if not isinstance(w, dict) or w.get("base") is None or w.get("during") is None:
            return None
        out[up] = (w["during"] - w["base"]) >= CARRY_SHARE * flow_bytes
    return out


def multipath(obs):
    """HR1 / HR2: the twin shows the cell's flow on exactly the uplinks netdev says carried it,
    both read against their own quiet window (the heartbeat runs on every link)."""
    a, o = A(obs), O(obs)
    carried = _carried(o["uplinks"], o["flow_bytes"])
    seen = _carried(a["uplinks"], o["flow_bytes"])
    if carried is None or seen is None:
        return not_run("an uplink window is missing")
    wrong = sorted(u for u in UPLINKS if carried[u] != seen[u])
    if wrong:
        return red("the twin's link usage disagrees with netdev on %s" % ", ".join(wrong), "structural")
    return green("the twin shows the flow on exactly the uplinks netdev says carried it")


def hr_pre(want):
    def pre(obs):
        o = O(obs)
        if not o.get("flow_bytes"):
            return False, "the sender reported no bytes"
        carried = _carried(o.get("uplinks"), o["flow_bytes"])
        if carried is None:
            return False, "netdev windows missing"
        n = sum(1 for v in carried.values() if v)
        if n != want:
            return False, "netdev shows the flow on %d uplink(s), the cell needs %d" % (n, want)
        if want == 1 and not carried[HR1_UPLINK]:
            return False, ("the flow went to the shaped uplink, not %s: its %d kbit/s exceeds the "
                           "%d kbit/s shaping" % (HR1_UPLINK, HR_RATE_KBIT, SHAPED_KBIT))
        return True, ""
    return pre


def hu1_pre(obs):
    size = A(obs).get("side_size")
    if size is None or size > SIDE_TABLE_ROOM:
        return False, "the side table holds %s keys; its 1024 cap could drop this row" % size
    return True, ""


def hu1(obs):
    """HU1: BOTH members of the header union. The 0x1238 member is non-IP, so its only NDTwin
    half is the side table (CH7's rule); the IPv6 member needs flow identity for GREEN and is
    PARTIAL(a) with only a side-table row."""
    a = A(obs)
    for key in ("sent", "sent_x"):
        skip = sampled_or_not_run(obs, key)
        if skip:
            return skip
    v6, x = a["v6"], a["x"]
    # (r3, review MINOR 2) the nested readings, the same rule as step 4b
    # (r4) v6.flow_identity too: False is a reading ("looked, nothing there"), a missing key is not
    for member, doc, keys in (("v6", v6, ("g1", "pair", "side_after", "flow_identity")),
                              ("x", x, ("pair", "side_after"))):
        lacking = [k for k in keys if not isinstance(doc, dict) or doc.get(k) is None]
        if lacking:
            return not_run("reading not taken: answer.%s.%s" % (member, lacking[0]))
    if not g1_complete(v6.get("g1")):
        return not_run("G1 was not read for the IPv6 member")
    if not g1_holds(v6.get("g1")):
        return red("G1 does not hold for the IPv6 member", "structural")
    if not side_row_grew(x, ETHERTYPES["HU1x"]):
        return red("the 0x1238 member has no side-table row for this pair", "structural")
    if v6.get("flow_identity") is True:
        return green("both members seen; the IPv6 member has flow identity")
    if side_row_grew(v6, ETHERTYPES["HU1"]):
        return partial("a", "both members seen; the IPv6 member only in the side table")
    return red("the IPv6 member has neither identity nor a side-table row", "structural")


# --- self-checks ---------------------------------------------------------------------------------

def hops_from_lpm(dumps, links, start_dpid, dst, max_hops=8):
    """How many switches a packet to `dst` crosses from `start_dpid`, walked over the entries
    THRIFT read off each switch (section 12 item 4: h4->h6 has a 2-hop and a 4-hop path, so the
    topology alone cannot say which). `dumps` {dpid: {dst: port}} -- an lpm dump's /32s for
    SC-ttl, v6_host's keys for SC-union; `links` {(dpid, port): dpid of the next switch}; a port
    not in `links` is a host port. None when the walk leaves the dumps or loops."""
    dpid, hops, seen = start_dpid, 0, set()
    while hops < max_hops:
        if dpid in seen:
            return None
        seen.add(dpid)
        port = (dumps.get(dpid) or {}).get(dst)
        if port is None:
            return None
        hops += 1
        nxt = links.get((dpid, port))
        if nxt is None:
            return hops
        dpid = nxt
    return None


def sc_fwd(obs):
    ok, total = obs.get("pingall") or (0, 0)
    want = obs.get("expected_total", 30)
    if total != want or ok != want:
        return False, "pingall %s/%s, expected %s/%s" % (ok, total, want, want)
    if obs.get("dump_ok") is not True:
        return False, "thrift table_dump does not show every T1 entry"
    return True, "pingall %d/%d and the T1 entries are in the dumps" % (ok, total)


def sc_count(obs):
    """Section 12 item 1, the zero-loss form: thrift's delta must equal what was sent, and only
    when the receiver got every marker. With loss on the path the switch may have seen fewer, so
    neither equal nor unequal says anything about the program: not decided (NOT RUN).
    (The netdev form was dropped in the Cut 1 review: an interface counter includes the
    heartbeat's frames and cannot equal a marker count.)"""
    delta = obs.get("thrift_delta")
    sent, got = obs.get("sent"), obs.get("received")
    if not sent or got != sent:
        return None, "the receiver got %s of %s sent: with loss on the path the count cannot be decided" % (got, sent)
    if delta == sent:
        return True, "c_in delta %s == sent == received" % delta
    return False, "c_in delta %s, sent and received %s" % (delta, sent)


def sc_reg(obs):
    """Section 12 item 2: the register must hold the NON-ZERO value the marker chose."""
    chosen, got = obs.get("chosen"), obs.get("register")
    if not chosen:
        return False, "the marker chose no non-zero value"
    if got != chosen:
        return False, "register_read %s, the marker wrote %s" % (got, chosen)
    return True, "register holds the marker's %s" % chosen


def sc_qstamp(obs):
    """Section 12 item 3: the sender must have sent identification 0, so the flag cannot be the
    sender's own."""
    if set(obs.get("sent_idents") or ()) != {0}:
        return False, "the sender's identifications were %s, not {0}" % sorted(obs.get("sent_idents") or ())
    if (obs.get("stamped") or 0) < 1:
        return False, "no received packet carries the 0x8000 flag"
    return True, "%d stamped packet(s)" % obs["stamped"]


def sc_ttl(obs):
    hops = obs.get("hops_lpm")
    if hops is None:
        return False, "no hop count from the thrift-read lpm path"
    ttls = obs.get("ttls") or []
    want = obs.get("sent_ttl", 64) - hops
    if not ttls:
        return False, "no marker received"
    bad = [t for t in ttls if t != want]
    if bad:
        return False, "ttl %s, expected %d (64 - %d hops)" % (sorted(set(bad)), want, hops)
    return True, "ttl %d after %d hops" % (want, hops)


def sc_recirc(obs):
    flags = obs.get("flags") or []
    if not flags:
        return False, "no recirculation marker received"
    bad = [f for f in flags if f & 0x0C != 0x0C]
    if bad:
        return False, "diffserv flags %s lack resubmit|recirculate (0x0C)" % sorted(set(bad))
    return True, "resubmitted and recirculated"


def sc_union(obs):
    """The IPv6 member forwarded and rewritten: hop limit = sent - hops, the hops walked over
    the v6_host entries thrift read (review MINOR 4; section 12 item 4's rule)."""
    hops = obs.get("hops_v6")
    lims = obs.get("hop_limits") or []
    if hops is None or not lims:
        return False, "no IPv6 marker received, or no hop count from the v6_host entries"
    want = obs.get("sent_hop_limit", 64) - hops
    if any(h != want for h in lims):
        return False, "hop limits %s, expected %d" % (sorted(set(lims)), want)
    return True, "the union's IPv6 member was forwarded and rewritten"


SELF_CHECKS = [
    SelfCheck("SC-fwd", sc_fwd, gates=("PL1", "T1", "TP1")),
    SelfCheck("SC-count", sc_count, self_checks=("SC-fwd",)),
    SelfCheck("SC-reg", sc_reg, self_checks=("SC-fwd",)),
    SelfCheck("SC-qstamp", sc_qstamp, self_checks=("SC-fwd",)),
    SelfCheck("SC-ttl", sc_ttl, gates=("TP1",), self_checks=("SC-fwd",)),
    SelfCheck("SC-recirc", sc_recirc, self_checks=("SC-fwd",), q3b=True),
    SelfCheck("SC-union", sc_union, gates=("TP1",), self_checks=("SC-fwd",), q3b=True),
]

NEG = dict(negative_read=True)
#: identity cells: the oracle is the sender's own report and the configured path, so no thrift
#: oracle; the stimulus floor is the sender-side sample expectation (r3, NEW-A)
#:
#: (r4, Cut 1 follow-ups) THE OBSERVER CONTRACT these cells rest on. A reading the observer TOOK
#: and found nothing in is False or 0 (flow_identity False, no side-table row [], usage 0,
#: samples 0) -- NEVER None and never a missing key. None or a missing key is "not read": step 4b
#: turns it into NOT RUN, and (verdict.has) the identity cells' G1 and flow_identity fields count
#: as missing too. An observer that encodes "looked, nothing there" as None therefore turns the
#: RED a broken emitter owes into NOT RUN. Cut 2-4 observers must be written to this rule.
IDENT = dict(needs_oracle=False, min_sent=IDENTITY_MIN_SENT)
BM = ("structural", "bmv2")

CELLS = [
    # pipeline_load
    Cell("PL1", "pipeline_load", "core", "static", "A", 2, pl1, need=("a:pipelines", "o:alt_table"), **NEG),
    Cell("PL2", "pipeline_load", "core", "active", "B", 4, pl2,
         need=("a:skipped", "o:primary", "o:set_pipeline_ok")),
    # tables
    Cell("T1", "tables", "core", "active", "A", 2, t1, need=("a:counts", "o:dumps"), **NEG),
    Cell("T2", "tables", "core", "static", "A", 2, t2, need=("a:applied", "o:s2_default"), **NEG),
    Cell("T3", "tables", "core", "active", "A", 2, controls=("T3-neg",),
         cannot=http_cannot((404, 501), "POST /p4/table_entry"),
         **wtr("T3", "POST /p4/table_entry", ("present_after",), **NEG)),
    Cell("T4", "tables", "ext", "active", "A", 2, cannot=http_cannot((501,), "POST /p4/table_entry (ternary)"),
         red_attribution=BM, **wtr("T4", "POST /p4/table_entry (ternary)",
                                   ("present_after", "mask_ok", "priority_ok"), **NEG)),
    Cell("T5", "tables", "ext", "active", "A", 2, cannot=http_cannot((501,), "POST /p4/table_entry (range)"),
         red_attribution=BM, **wtr("T5", "POST /p4/table_entry (range)", ("present_after", "priority_ok"), **NEG)),
    Cell("T6", "tables", "ext", "active", "A", 2, cannot=http_cannot((501,), "POST /p4/table_entry (optional)"),
         red_attribution=BM, **wtr("T6", "POST /p4/table_entry (optional)", ("present_after", "priority_ok"), **NEG)),
    Cell("T7", "tables", "ext", "active", "A", 2, t7, gates=("T4",), red_attribution=BM,
         need=("a:http", "o:order_ok"), **NEG),
    Cell("T8", "tables", "ext", "static", "A", 2, t8, cannot=t8_cannot, needs_oracle=False,
         need=("a:journaled",)),
    Cell("PF-T", "tables", "ext", "static", "S0", 1, pft, cannot=pft_cannot, needs_oracle=False,
         red_attribution=("structural", "bmv2|static"), need=("a:rc",)),
    # pre_multicast
    Cell("M1", "pre_multicast", "core", "static", "A", 2, m1,
         need=("a:applied", "a:recorded", "o:s1_group1"), **NEG),
    Cell("M2", "pre_multicast", "core", "active", "A", 2, m2,
         need=("a:http", "o:group2_after", "o:declared"), **NEG),
    # pre_clone
    Cell("C1", "pre_clone", "core", "static", "A", 2, c1, need=("a:applied", "o:ports"), **NEG),
    Cell("C2", "pre_clone", "ext", "static", "A", 2, cannot=no_route("clone-session"), red_attribution=BM,
         **wtr("C2", "the clone-session write", ("present_after", "ports_ok"), **NEG)),
    # counters
    Cell("K1", "counters", "core", "active", "A", 2, counter_equal, cannot=k1_cannot,
         self_checks=("SC-count",), controls=("K1-neg",), red_attribution=("structural", "thrift"),
         need=("a:http", "o:delta")),
    Cell("K2", "counters", "ext", "active", "A", 2, counter_equal, cannot=k1_cannot,
         red_attribution=BM, precondition=k2_pre, need=("a:http", "o:delta")),
    Cell("K3", "counters", "core", "active", "B", 4, counter_equal, self_checks=("SC-count",),
         red_attribution=("structural", "thrift"), need=("a:http", "o:delta")),
    # meters
    Cell("MT1", "meters", "core", "active", "A", 2, rates_written,
         cannot=http_cannot((501,), "/ndt/install_meter_entry"), red_attribution=BM,
         need=("a:http", "o:rates_after", "o:target"), **NEG),
    Cell("MT2", "meters", "core", "static", "A", 2, rates_written, cannot=no_route("meter"),
         red_attribution=BM, need=("a:http", "o:rates_after", "o:target"), **NEG),
    Cell("MT3", "meters", "ext", "static", "A", 2, rates_written, cannot=no_route("direct-meter"),
         red_attribution=BM, need=("a:http", "o:rates_after", "o:target"), **NEG),
    # registers
    Cell("R2", "registers", "core", "active", "A", 2, r2, cannot=no_route("register read"),
         self_checks=("SC-reg",), red_attribution=("structural", "thrift"), need=("a:value", "o:value")),
    Cell("R3", "registers", "core", "static", "A", 2, r3, cannot=no_route("register write"),
         red_attribution=BM, need=("a:http", "o:value_after", "o:target"), **NEG),
    # digest
    Cell("D1", "digest", "core", "active", "A", 2, d1,
         cannot=exit_cannot("digest", "the stream drops them, p4_client.py:544-545"),
         red_attribution=BM, need=("a:fields", "o:fields")),
    # packet_io
    Cell("P1", "packet_io", "core", "static", "A", 2, argv_flag("--cpu-port", 510, "P1"),
         needs_answer=False, need=("o:argv_has",)),
    Cell("P2", "packet_io", "core", "active", "A", 2, delivered,
         cannot=exit_cannot("packet-in", "telemetry/LLDP only, p4_client.py:553-586"),
         red_attribution=BM, need=("a:exit", "o:received")),
    Cell("P3", "packet_io", "core", "active", "A", 2, delivered, cannot=no_route("packet-out"),
         red_attribution=BM, need=("a:http", "o:received")),
    Cell("P4", "packet_io", "core", "active", "B", 4, p4, red_attribution=("bmv2",),
         needs_answer=False, need=("o:received",)),
    # custom_headers
    Cell("CH1", "custom_headers", "core", "active", "A", 3,
         identity_cell(ETHERTYPES["CH1"], partial_ok=True), need=ident_need(side=True), **IDENT),
    Cell("CH2", "custom_headers", "core", "active", "A", 3,
         identity_cell(ETHERTYPES["CH2"], partial_ok=True), need=ident_need(side=True), **IDENT),
    Cell("CH3", "custom_headers", "core", "active", "A", 3, flow_correct, need=("a:flow_identity",), **IDENT),
    Cell("CH4", "custom_headers", "ext", "active", "A", 3, ch4,
         red_attribution=("structural", "wire"), need=("a:identity",), **IDENT),
    Cell("CH5", "custom_headers", "core", "active", "A", 3, flow_correct, need=("a:flow_identity",), **IDENT),
    Cell("CH6", "custom_headers", "ext", "active", "A", 3, flow_correct, need=("a:flow_identity",), **IDENT),
    Cell("CH7", "custom_headers", "core", "active", "A", 3, identity_cell(ETHERTYPES["CH7"]),
         need=("a:g1", "a:pair", "a:side_after"), **IDENT),
    Cell("CH8", "custom_headers", "ext", "active", "A", 3,
         identity_cell(ETHERTYPES["CH1"], partial_ok=True, g1=False), need=ident_need(g1=False, side=True),
         **IDENT),
    Cell("VB1", "custom_headers", "ext", "active", "A", 3, q3b=True, alias_of="CH3",
         alias_why="the varbit NDTwin must parse through is the IPv4 options header "
                   "(hc_main.p4 ipv4_opt_t, varbit<320>): CH3's marker carries those options and "
                   "CH3's oracle is the 5-tuple behind them. A second cell would send the same "
                   "frames to the same oracle"),
    # queue_metadata
    Cell("Q1", "queue_metadata", "core", "active", "A", 3, q1, self_checks=("SC-qstamp",),
         need=("a:sent_idents", "o:shaped", "o:received")),
    Cell("Q2", "queue_metadata", "ext", "static", "A", 3, argv_flag("--priority-queues", None, "Q2"),
         red_attribution=("structural", "static"), needs_answer=False, need=("o:argv_has",)),
    # checksum
    Cell("CS1", "checksum", "core", "static", "A", 2, cs1, needs_answer=False, need=("o:tx_checksum_off",)),
    # ttl_or_hop
    Cell("TTL1", "ttl_or_hop", "core", "active", "A", 2, ttl1, self_checks=("SC-ttl",),
         needs_answer=False, need=("o:received",)),
    # topology
    Cell("TP1", "topology", "core", "static", "A", 2, tp1,
         need=tuple("a:" + i for i in TP1_ITEMS) + tuple("o:" + i for i in TP1_ITEMS)),
    Cell("TP2", "topology", "core", "active", "A", 3, link_cut, precondition=tp2_pre,
         needs_oracle=False, need=("a:down_after_s", "a:recovered", "a:watched_s")),
    Cell("TP4", "topology", "core", "active", "B", 4, link_cut, precondition=tp4_pre,
         needs_oracle=False, need=("a:down_after_s", "a:recovered", "a:watched_s")),
    # control_plane_mode
    Cell("CP1", "control_plane_mode", "core", "active", "A", 2, alias_of="T1",
         alias_why="design 2.3: CP1 = T1"),
    Cell("CP2", "control_plane_mode", "core", "active", "B", 4, cp2,
         need=("a:http", "o:entry_present", "o:controller_entry_present")),
    Cell("CP4", "control_plane_mode", "core", "active", "C", 4, cp4, precondition=cp4_pre,
         need=("a:capabilities", "a:rerouted_after_s", "a:watched_s", "o:kernel_route_present",
               "o:port_after_cut"), **NEG),
    # verification
    Cell("V1", "verification", "core", "active", "A", 3, identity_cell(None), need=("a:g1",), **IDENT),
    Cell("V2", "verification", "core", "active", "A", 3, v2, needs_oracle=False,
         need=("a:bytes_match", "a:flow_identity")),
    # Q3(b): the six categories outside the 16 dimensions (design 13, reworked in 14)
    Cell("AP1", "action_profile", "ext", "active", "A", 2, cannot=no_route("action-profile member"),
         red_attribution=BM, q3b=True,
         **wtr("AP1", "the action-profile write", ("present_after", "points_to_member"), **NEG)),
    Cell("AS1", "action_profile", "ext", "active", "A", 2, cannot=no_route("action-selector group"),
         red_attribution=BM, q3b=True,
         **wtr("AS1", "the action-selector write", ("present_after", "points_to_group"), **NEG)),
    Cell("IT1", "idle_timeout", "ext", "active", "A", 2, it1, cannot=it1_cannot, precondition=it1_pre,
         red_attribution=BM, q3b=True,
         need=("a:requested_timeout_ms", "a:reported_after_s", "a:watched_s", "o:timeout_ms",
               "o:since_hit_ms"), **NEG),
    Cell("VS1", "value_set", "ext", "active", "A", 2, cannot=no_route("value-set"),
         red_attribution=BM, q3b=True, **wtr("VS1", "the value-set write", ("present_after",), **NEG)),
    Cell("RC1", "recirculate", "ext", "active", "A", 3, identity_cell(None), self_checks=("SC-recirc",),
         q3b=True, need=("a:g1",), **IDENT),
    Cell("HR1", "hash_random", "ext", "active", "A", 3, multipath, precondition=hr_pre(1), q3b=True,
         need=("a:uplinks", "o:uplinks", "o:flow_bytes"), min_sent=HR_FRAMES),
    Cell("HR2", "hash_random", "ext", "active", "A", 3, multipath, precondition=hr_pre(2), q3b=True,
         need=("a:uplinks", "o:uplinks", "o:flow_bytes"), min_sent=HR_FRAMES),
    Cell("HU1", "header_union", "ext", "active", "A", 3, hu1, precondition=hu1_pre,
         self_checks=("SC-union",), q3b=True, need=("a:v6", "a:x"), **IDENT),
]

CONTROLS = [Control("K1-neg", "K1", 404), Control("T3-neg", "T3", 404)]


class Table(object):
    def __init__(self, cells, self_checks, controls):
        self.cells = list(cells)
        self.self_checks = list(self_checks)
        self.controls = list(controls)
        self.core_dimensions = CORE_DIMENSIONS
        self.q3b_dimensions = Q3B_DIMENSIONS
        ids = [c.id for c in self.cells] + [s.id for s in self.self_checks] + [c.id for c in self.controls]
        if len(ids) != len(set(ids)):
            raise ValueError("duplicate ids in the cell table")
        known = set(ids)
        for c in self.cells:
            for dep in c.gates + c.self_checks + c.controls + ((c.alias_of,) if c.alias_of else ()):
                if dep not in known:
                    raise ValueError("%s depends on unknown %s" % (c.id, dep))

    def cell(self, cid):
        for c in self.cells:
            if c.id == cid:
                return c
        raise KeyError(cid)

    def counted(self, scope=None, q3b=None):
        """The cells that are judged on their own (an alias carries another cell's verdict)."""
        return [c for c in self.cells if c.alias_of is None
                and (scope is None or c.scope == scope) and (q3b is None or c.q3b == q3b)]


TABLE = Table(CELLS, SELF_CHECKS, CONTROLS)
