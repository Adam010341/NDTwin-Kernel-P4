#!/usr/bin/env python3
"""
The external arms' OWN evidence out of live-p1/06 runs: controls without the heartbeat against a
treatment with it.

[Co-developed with claude code -- Adam]

09-27: `ndt up p4 --app` starts the veth heartbeat on an external control plane too, detect only.
Adam's standing condition (09-25) is that the heartbeat must not change what a user's own
forwarding does. What must NOT differ between runs without it and a run with it is what the
exercise's own controller saw and did -- its log, in each round's directory -- and what each arm's
own numbers must satisfy whatever the other runs say. The procedure that produces the runs is in
live-p1/README.md ("合併前的比對").

WHAT IS READ, per external arm (p4runtime skeleton and solution, flowcache solution):
  * 00_table.tsv: the arm's rc, verdict and round report (`<stamp>_<ex>_<arm>_ndtwin.md`; the round
    directory is beside it, and the stamp opens the arm's window, as live-p1/08's H5 reads it);
  * the round report: which code the arm ran (`code <sha> ...`), whether `ndt up` started the
    heartbeat detect-only, what `ndt status` saw (the `heartbeat running (pid N, session S)` row),
    any heartbeat block on switch_state, the pings h1 sent h2, link_usage/iperf_client.txt;
  * the controller log: every rule installed, the tunnel-counter blocks, every packet-in (and its
    frame), every cache entry, every gRPC error -- and when it was last written;
  * the treatment's H5 samples (--samples: live-p1/08 PART=h5's 50_samples.tsv, with its
    50_t06_end.txt beside it): the daemon's report, read every second through the whole of 06 --
    since round 5 with each direction's `heard` count and the pids of the exercise controllers
    (run_external_controller.py) alive at that read, since round 6 with the size of each
    controller log (`ctrl_logs`), which places the controller's pipeline push among the samples;
  * each run's 00_identity.before.txt and 00_identity.after.txt (live-p1/code_identity.py, taken
    as 06 starts and as it ends): which commit and tree, which uncommitted code files, which
    kernel, bmv2 (binaries and the fabric's lib/), helper, venv and ~/tutorials. Each run's two
    must be equal (the code did not change while it ran); every control must carry the same
    identity, and the treatment's must be that one plus B merged, its tree the one merging its two
    parents gives: refused otherwise (README, "合併前的比對", M-2);
  * [Co-developed with claude code -- Adam] (round 6) each round report's p4c sha256 and every
    compiled JSON's sha256: refused unless each external arm's are the same in every run.

WHAT IS REFUSED (exit 3) -- a comparison about nothing (the external judge's F1 and M2, 09-28):
  * no --samples: the round report's markers are all taken before the exercise's controller runs
    and before its pipeline is loaded, so they cannot say the heartbeat ran while it did;
  * a treatment arm whose N5 session is not what the samples show for the whole arm: never sampled
    running, a report that went STALE while "running" (a killed daemon leaves `running` behind --
    its written_wall stops), a stretch without a sample, a stop and a restart, a stop before the
    exercise's controller last wrote its log, or ANY OTHER session running inside the arm window;
  * [Co-developed with claude code -- Adam] a treatment arm whose session did not HEAR every one of
    its directions while the exercise's controller ran (the round-4 review's M-3): a daemon that
    runs but whose frames never arrive leaves the program nothing to drop, and the comparison
    would be about nothing. Since round 6 the window is the controller's OWN: it opens at the
    first sample whose `ctrl_logs` size of the arm's controller log reaches the end of the log's
    last pipeline push ("Installed P4 Program using SetForwardingPipelineConfig", or, with none,
    its first "Installed"/cache-entry line), and closes at the log's last write. Every direction's
    `heard` must grow by at least one round between the session's last sample at or before the
    window's opening and its last sample at or before the close; a session not yet running when
    the window opened is refused too. A window shorter than two heartbeat periods (10 s) cannot
    show it and is UNDECIDED (exit 2, reported), not refused;
  * a control arm with the detect-only line, a heartbeat block or a running row -- any trace of the
    heartbeat -- and a --control2 that is the control itself or another control (no spread).

WHAT IS UNREADABLE (exit 2), never "same": a missing or unreadable table, row, report, log or
samples file (a sampler file without the round-6 columns included; a running sample of the arm's
session whose counters or `heard` are not numbers; a controller log the sampler never saw reach
its push; a controller log with no push and no entry); a counter block cut short; a LAST counter block that had not settled (a read
taken mid-traffic: see settled() for when it has); a packet-in whose frame cannot be parsed, an
IPv4 one included.

WHAT DECIDES, AND WHAT IS ONLY DESCRIBED (pre-registered, round 5 -- the round-4 review's S-9;
README "合併前的比對" has the arithmetic). Run-to-run noise is real, and a range rule cannot hold a
noisy field to a small false-fail rate: under no effect, a continuous field lands outside the range
of n controls with probability 2/(n+1) -- 2/3 with two controls, 2/5 with four. So each arm's
evidence is split, by what 34 earlier no-heartbeat rounds of these arms show (README):
  * DECISIVE -- held EXACTLY to the controls: every key and invariant that never varied in those
    rounds (rules installed everywhere; the 0x88B5 and non-IPv4 packet-ins; on p4runtime the
    packet-ins, cache entries and gRPC errors, and the skeleton's counters; the invariants named in
    DESCRIPTIVE_INVARIANTS' complement). A treatment value that differs from controls that all
    agree is a DIFF (rc 1). Controls that DISAGREE on a decisive check make it UNDECIDED (rc 2):
    a check the pre-registration took for deterministic was not, and that is reported, not judged;
  * DESCRIPTIVE -- printed with the controls' values and whether the treatment lies inside their
    spread, and NOT counted: rc and verdict (flaky: 3 of 12 p4runtime/solution and 3 of 11
    flowcache/solution rounds FAILed), p4runtime/solution's final counters and its two traffic
    invariants (s1 ingress 100 = pings + datagrams held in 1 of 12), flowcache's packet-ins, cache
    entries and gRPC errors (3, 4 and 2 distinct values).
The daemon's counters and the 0x88B5 packet-ins are what the heartbeat would DO to the exercise --
a frame forwarded, misdelivered or punted -- and are decisive on any value but 0.

Each arm's INVARIANTS hold on its own numbers:
  * p4runtime/solution: s1 ingress 100 = pings h1->h2 + iperf datagrams to h2 (+ at most 10 FIN
    retries when the client got no ack); s2 egress 100 = s1 ingress 100; s1 egress 200 = s2
    ingress 200;
  * p4runtime/skeleton: s1 ingress 100 = pings h1->h2, and every other tunnel counter 0;
  * flowcache/solution: every packet-in is IPv4 and every cache entry is an IPv4 packet-in's flow.
A decisive invariant the treatment breaks counts only when EVERY control keeps it. The daemon's own
counters, from the samples of the arm's session (forwarded to hosts or between switches,
misdelivered, foreign), must all stay 0: that is the only evidence of what the LOADED program did
with a 0x88B5 frame. The N4 switch_state counters are printed as what they are -- a snapshot from
before the exercise's pipeline was loaded -- and decide nothing.

Usage:  external_evidence.py show <06 run dir>
        external_evidence.py compare <control 06 run> <treatment 06 run>
                                     --control2 <06 run> [--control2 <06 run> ...]
                                     --samples <08 H5 run>/50_samples.tsv
                                     --b-sha <the B commit T merged>
Exit:   0 every decisive check the same as the controls', every decisive invariant kept, the
          daemon forwarded nothing (descriptive differences are printed, not counted);
        1 a decisive difference (each printed); 2 unreadable, or UNDECIDED (the controls disagree
          on a decisive check, or an arm's controller window is under two heartbeat periods --
          printed with the rest, and a DIFF still exits 1); 3 refused.
"""

from __future__ import annotations

import ast
import calendar
import glob
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import code_identity  # noqa: E402

#: (exercise, arm) -- the three 06 arms whose fabric has an external control plane.
EXTERNAL_ARMS = (("p4runtime", "skeleton"), ("p4runtime", "solution"), ("flowcache", "solution"))
HEARTBEAT_ETHERTYPE = 0x88B5
IPV4_ETHERTYPE = 0x0800
#: The evidence that decides; everything else printed is context.
COMPARED = ("rc", "verdict", "rules_installed", "counters_final", "packet_ins", "cache_entries",
            "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors")
#: [Co-developed with claude code -- Adam] Pre-registered (round 5, S-9; README): what is only
#: DESCRIBED per arm -- the keys that varied across 34 earlier no-heartbeat rounds of these arms.
DESCRIPTIVE = {
    ("p4runtime", "skeleton"): {"rc", "verdict"},
    ("p4runtime", "solution"): {"rc", "verdict", "counters_final"},
    ("flowcache", "solution"): {"rc", "verdict", "packet_ins", "cache_entries", "grpc_errors"},
}
#: ...and the invariants that broke in some of those rounds (p4runtime/solution's traffic sums).
DESCRIPTIVE_INVARIANTS = {
    ("p4runtime", "solution"): {"s1 ingress 100 = pings + iperf datagrams",
                                "s2 egress 100 = s1 ingress 100"},
}
#: The most FIN retries iperf makes when it gets no ack of its last datagram -- and the most
#: settled() allows when it did (09-27T081205Z's FIN went out twice, acked).
IPERF_FIN_RETRIES = 10
#: The longest a running report may go unrewritten, and the longest stretch without a sample,
#: before either stops being evidence (two heartbeat periods; the sampler reads every second).
STALE_S = 10.0
MAX_GAP_S = 10.0
#: The daemon's four counters as the sampler records them (live-p1/08 SAMPLER_HEADER).
DAEMON = ("forwarded_to_hosts", "forwarded_between_switches", "misdelivered", "foreign_frames")
#: live-p1/08's SAMPLER_HEADER since round 6 (heard per direction, the controllers alive -- context
#: only since round 6 -- and the controller logs' sizes).
SAMPLER_COLUMNS = ["wall", "status", "session", "pid", "forwarded_to_hosts",
                   "forwarded_between_switches", "written_wall", "stop_reason", "misdelivered",
                   "foreign_frames", "heard", "controllers", "ctrl_logs"]
#: [Co-developed with claude code -- Adam] (round 6) the daemon's round period, and the shortest
#: controller window that can show a direction heard: two periods.
PERIOD_S = 5.0
MIN_WINDOW_S = 2 * PERIOD_S
#: The controller's pipeline push, as tutorials' p4runtime_lib/switch.py's callers print it.
PUSH = re.compile(r"^Installed P4 Program using SetForwardingPipelineConfig on s\d+\s*$")
#: drive_exercise's report tables: the toolchain row of p4c, and each compiled JSON with its sha256[:16].
P4C_ROW = re.compile(r"^\|\s*`[^`]*p4c-bm2-ss`\s*\|\s*`([0-9a-f]{16})`\s*\|")
JSON_ROW = re.compile(r"^\|\s*`([^`]+\.json)`\s*\|\s*\d+\s*\|\s*`([0-9a-f]{16})`\s*\|")

INSTALLED = re.compile(r"^Installed .* on s\d+\s*$")
COUNTER = re.compile(r"^(s\d+ \S+ \d+): (\d+) packets \((\d+) bytes\)\s*$")
CACHE_ENTRY = re.compile(r"^For switch s\d+ flow \(SA=([\d.]+), DA=([\d.]+), proto=(\d+)\) added table entry .*$")
CODE = re.compile(r"^\s*code\s+([0-9a-f]{7,40})\s*(.*?)\s*$")
HB_UP = "heartbeat running on the inter-switch veths, detect only"
#: `ndt status`'s heartbeat row (printf '  %-14s %s'): two or more spaces after the word.
HB_ROW = re.compile(r"^\s*heartbeat\s{2,}(running \(pid (\d+), session ([0-9a-f]+)\).*|\S.*)$")
#: A heartbeat block on switch_state (B's proxy serves one on these arms; before B it was null).
HB_BLOCK = re.compile(r'"heartbeat":\s*\{')
SIDE_EFFECT = re.compile(r'"(forwarded_to_hosts|forwarded_between_switches|misdelivered|foreign_frames)":\s*(\d+)')
PING_HEAD = re.compile(r"^### \d+\. \S+\s+h1 (?:ping|probes) h2\b")
TRANSMITTED = re.compile(r"^(\d+) packets transmitted")
SENT = re.compile(r"Sent (\d+) datagrams")
#: The iperf server's report as the client prints it ("Server Report:", then "... 0/3499 (0%)"):
#: lost / total datagrams the server received.
SERVER_REPORT = "Server Report:"
LOST_TOTAL = re.compile(r"(\d+)/\s*(\d+) \(")
CONNECTED = re.compile(r"connected with ([\d.]+) port")
STAMP = re.compile(r"(\d{4}-\d\d-\d\dT\d{6}Z)_")


class Unreadable(Exception):
    """Evidence that cannot be read: exit 2, never a comparison."""


class Refused(Exception):
    """A comparison about nothing: exit 3."""


def read_text(path):
    """A file's text, or Unreadable -- never a traceback (the external judge's F7, 09-28)."""
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise Unreadable(f"{path}: {type(exc).__name__}: {exc}") from exc


def table_rows(run):
    lines = read_text(os.path.join(run, "00_table.tsv")).splitlines()
    rows = {}
    for line in lines[1:]:
        f = line.split("\t")
        if len(f) >= 5:
            rows[(f[0], f[1])] = {"rc": f[2], "verdict": f[3], "report": f[4]}
    return rows


def round_dir(report):
    return report[:-3] if report.endswith(".md") else report


def controller_log(report):
    logs = sorted(glob.glob(os.path.join(round_dir(report), "driver-controller-*.log")))
    if len(logs) != 1:
        raise Unreadable(f"{round_dir(report)}: {len(logs)} controller logs, want exactly 1")
    return logs[0]


def ethertype_of(line):
    """(ethertype, payload) of a decodePacketInMetadata line -- or Unreadable."""
    try:
        payload = ast.literal_eval(line.split("ret=", 1)[1].strip())["payload"]
        if not isinstance(payload, bytes) or len(payload) < 14:
            raise ValueError("payload shorter than an Ethernet header")
        et = int.from_bytes(payload[12:14], "big")
        if et == IPV4_ETHERTYPE and len(payload) < 34:
            # the external judge's m1 (09-28): an IPv4 frame too short for its header was an
            # IndexError later -- a traceback, rc 1
            raise ValueError(f"an IPv4 payload of {len(payload)} bytes, shorter than its header")
    except (IndexError, KeyError, TypeError, ValueError, SyntaxError) as exc:
        raise Unreadable(f"a packet-in whose frame cannot be parsed ({type(exc).__name__}: {exc}): "
                         f"{line[:120]}") from exc
    return et, payload


def ipv4_flow(payload):
    """(src, dst, proto) of an IPv4 frame (ethertype_of has checked its length)."""
    ip = payload[14:34]
    return (".".join(str(b) for b in ip[12:16]), ".".join(str(b) for b in ip[16:20]), ip[9])


def controller_evidence(log_path):
    lines = read_text(log_path).splitlines()
    blocks, current = [], None
    for line in lines:
        if line.startswith("----- Reading tunnel counters"):
            current = {}
            blocks.append(current)
            continue
        m = COUNTER.match(line)
        if m and current is not None:
            current[m.group(1)] = (int(m.group(2)), int(m.group(3)))
        elif not line.strip():
            current = None
    if blocks:
        width = max(len(b) for b in blocks)
        short = [i for i, b in enumerate(blocks) if len(b) < width]
        if short:
            raise Unreadable(f"{log_path}: counter block {short[-1] + 1} of {len(blocks)} has "
                             f"{len(blocks[short[-1]])} of {width} counters -- cut short (a "
                             f"controller stopped mid-print), so the last reading is not known")
    kinds, flows = [], set()
    for line in lines:
        if line.startswith("decodePacketInMetadata:"):
            et, payload = ethertype_of(line)
            kinds.append(et)
            if et == IPV4_ETHERTYPE:
                flows.add(ipv4_flow(payload))
    entries = [line.strip() for line in lines if CACHE_ENTRY.match(line)]
    try:
        last_write = os.stat(log_path).st_mtime
    except OSError as exc:
        raise Unreadable(f"{log_path}: {type(exc).__name__}: {exc}") from exc
    return {
        "rules_installed": sorted(line.strip() for line in lines if INSTALLED.match(line)),
        "counters_final": blocks[-1] if blocks else {},
        "_counters_before": blocks[-2] if len(blocks) > 1 else None,
        "counter_reads": len(blocks),
        "packet_ins": sum(1 for line in lines if line.startswith("Received PacketIn")),
        "cache_entries": sorted(entries),
        "heartbeat_packet_ins": sum(1 for e in kinds if e == HEARTBEAT_ETHERTYPE),
        "non_ipv4_packet_ins": sum(1 for e in kinds if e != IPV4_ETHERTYPE),
        "grpc_errors": sum(1 for line in lines if line.startswith("gRPC error occurred")),
        "_flows": flows,
        "_entry_flows": [(m.group(1), m.group(2), int(m.group(3)))
                         for m in (CACHE_ENTRY.match(e) for e in entries)],
        "_last_write": last_write,
        "log": log_path,
    }


def report_evidence(report):
    text = read_text(report)
    codes = sorted({(m.group(1), m.group(2)) for m in map(CODE.match, text.splitlines()) if m})
    rows = [m for m in map(HB_ROW.match, text.splitlines()) if m]
    running = [(m.group(2), m.group(3)) for m in rows if m.group(2)]
    pings, in_ping = 0, False
    for line in text.splitlines():
        if line.startswith("### "):
            in_ping = bool(PING_HEAD.match(line))
            continue
        m = TRANSMITTED.match(line)
        if in_ping and m:
            pings += int(m.group(1))
    iperf = os.path.join(round_dir(report), "link_usage", "iperf_client.txt")
    sent, target, no_ack, total = 0, None, False, None
    if os.path.exists(iperf):
        itext = read_text(iperf)
        m, c = SENT.search(itext), CONNECTED.search(itext)
        sent, target = (int(m.group(1)) if m else 0), (c.group(1) if c else None)
        no_ack = "did not receive ack of last datagram" in itext
        if SERVER_REPORT in itext:
            t = LOST_TOTAL.search(itext.split(SERVER_REPORT, 1)[1])
            total = int(t.group(2)) if t else None
    n4 = {}
    for name, n in SIDE_EFFECT.findall(text):
        n4[name] = max(n4.get(name, 0), int(n))
    stamp = STAMP.search(os.path.basename(report))
    p4c = sorted({m.group(1) for m in map(P4C_ROW.match, text.splitlines()) if m})
    jsons = sorted({(os.path.basename(m.group(1)), m.group(2)) for m in map(JSON_ROW.match, text.splitlines()) if m})
    return {
        "p4c_sha": p4c[0] if len(p4c) == 1 else None,
        "json_shas": [f"{n} {h}" for n, h in jsons],
        "code": "; ".join(f"{sha} {rest}".strip() for sha, rest in codes) or "not recorded",
        "hb_started": HB_UP in text,
        "hb_block": bool(HB_BLOCK.search(text)),
        "hb_rows": [m.group(1) for m in rows],
        "hb_running": running,
        "n4_counters": n4,
        "pings_h1_h2": pings,
        "iperf": {"sent": sent, "target": target, "no_ack": no_ack, "server_total": total},
        "_start": calendar.timegm(time.strptime(stamp.group(1), "%Y-%m-%dT%H%M%SZ")) if stamp else None,
    }


def settled(arm, ev):
    """Unreadable unless the LAST counter block is final -- read after the round's traffic ended,
    so that no read taken mid-traffic is compared.

    [Co-developed with claude code -- Adam] Either (i) it repeats the block before it, or:
      * p4runtime/skeleton: s1 ingress 100 is exactly the pings h1 sent h2 (11 of 11 earlier
        rounds);
      * p4runtime/solution, all of:
          - the iperf client got the server's ack: a Server Report with its datagram total, and no
            "did not receive ack";
          - s2 egress 100 = s1 ingress 100 in that same block (nothing still between the switches);
          - pings + D <= s1 ingress 100 <= pings + D + IPERF_FIN_RETRIES, D the server report's
            total (the "/3499"; 0 if iperf went elsewhere than 10.0.2.2), the slack for FIN
            retransmissions, which happen when acked too.
    Why D and not the client's "Sent N": iperf 2.1.9 says Sent 3500 where the server counts 3499
    in all 8 acked earlier rounds, and s1's bytes are 5 pings x 98 + 3499 x 1242 exactly -- the
    3500th is on no wire. Exact pings + Sent, the rule before 10-02, settled 1 of the 12 frozen
    rounds (external_survey_34.tsv), and that one by a FIN retransmission. This rule settles the 7
    that ended after traffic (six at 3504, and 09-27T081205Z at 3505) and leaves UNREADABLE the
    one read mid-traffic (09-26T175425Z: s2 egress 3821, s1 3820) and the four 09-19 rounds,
    which have no server report. A repeated last block occurs in none of them.
    With no server report only (i) settles the block. No earlier round supports that case with
    data: the only no-ack rounds are those four, whose forwarding had broken."""
    last, before = ev["counters_final"], ev["_counters_before"]
    if arm not in (("p4runtime", "skeleton"), ("p4runtime", "solution")) or not last:
        return
    if before == last:
        return
    s1 = last.get("s1 MyIngress.ingressTunnelCounter 100", (None,))[0]
    pings = ev["pings_h1_h2"]
    if arm == ("p4runtime", "skeleton"):
        if s1 == pings:
            return
        why = f"s1 ingress 100 = {s1} is not the {pings} ping(s) h1 sent h2: a read taken mid-traffic"
    else:
        ip = ev["iperf"]
        s2e = last.get("s2 MyIngress.egressTunnelCounter 100", (None,))[0]
        total = ip["server_total"]
        if total is None or ip["no_ack"]:
            why = ("the iperf client got no ack from the server ("
                   + ("it says it did not receive ack of the last datagram" if ip["no_ack"]
                      else "no Server Report with a datagram total")
                   + "), so only a repeated block can show the traffic over")
        elif s1 is None or s2e != s1:
            why = (f"s2 egress 100 = {s2e} is not s1 ingress 100 = {s1} in that block: a read "
                   f"taken mid-traffic")
        else:
            low = pings + (total if ip["target"] == "10.0.2.2" else 0)
            high = low + IPERF_FIN_RETRIES
            if low <= s1 <= high:
                return
            if s1 < low:
                why = (f"s1 ingress 100 = {s1} is under pings {pings} + the server's {total} "
                       f"datagram(s) = {low}: a read taken mid-traffic")
            else:
                why = (f"s1 ingress 100 = {s1} is over pings {pings} + the server's {total} "
                       f"datagram(s) + {IPERF_FIN_RETRIES} FIN retries = {high}: more than the "
                       f"round sent")
    raise Unreadable(f"{ev['log']}: the last counter block had not settled -- it does not repeat "
                     f"the block before it, and {why}")


def arms(run):
    rows = table_rows(run)
    out = {}
    for arm in EXTERNAL_ARMS:
        row = rows.get(arm)
        if row is None:
            raise Unreadable(f"{run}: no {arm[0]}/{arm[1]} row in 00_table.tsv")
        ev = dict(row, **controller_evidence(controller_log(row["report"])),
                  **report_evidence(row["report"]))
        settled(arm, ev)
        out[arm] = ev
    # every arm's window, as live-p1/08's H5 reads them: from its report's stamp to the next arm's
    starts = sorted((report_evidence_start(r["report"]), key) for key, r in rows.items()
                    if report_evidence_start(r["report"]) is not None)
    for arm, ev in out.items():
        later = [t for t, _k in starts if ev["_start"] is not None and t > ev["_start"]]
        ev["_end"] = min(later) if later else None
    return out


def report_evidence_start(report):
    m = STAMP.search(os.path.basename(report))
    return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H%M%SZ")) if m else None


def invariants(arm, ev):
    """{name: (holds, detail)} -- the arm's own numbers, whatever the other runs say."""
    c = {k: v[0] for k, v in ev["counters_final"].items()}
    get = lambda key: c.get(key)  # noqa: E731
    s1_in, s2_eg = get("s1 MyIngress.ingressTunnelCounter 100"), get("s2 MyIngress.egressTunnelCounter 100")
    s2_in, s1_eg = get("s2 MyIngress.ingressTunnelCounter 200"), get("s1 MyIngress.egressTunnelCounter 200")
    out = {}
    if arm == ("p4runtime", "solution"):
        ip = ev["iperf"]
        sent = ip["sent"] if ip["target"] == "10.0.2.2" else 0
        base = ev["pings_h1_h2"] + sent
        extra = IPERF_FIN_RETRIES if ip["no_ack"] else 0
        out["s1 ingress 100 = pings + iperf datagrams"] = (
            s1_in is not None and base <= s1_in <= base + extra,
            f"s1 ingress 100 = {s1_in}; pings h1->h2 {ev['pings_h1_h2']} + datagrams to 10.0.2.2 "
            f"{sent}{f' + up to {extra} FIN retries' if extra else ''} = {base}")
        out["s2 egress 100 = s1 ingress 100"] = (s1_in is not None and s2_eg == s1_in,
                                                 f"{s2_eg} vs {s1_in}")
        out["s1 egress 200 = s2 ingress 200"] = (s2_in is not None and s1_eg == s2_in,
                                                 f"{s1_eg} vs {s2_in}")
    elif arm == ("p4runtime", "skeleton"):
        out["s1 ingress 100 = pings"] = (s1_in == ev["pings_h1_h2"],
                                         f"s1 ingress 100 = {s1_in}; pings h1->h2 {ev['pings_h1_h2']}")
        others = {k: v for k, v in c.items() if k != "s1 MyIngress.ingressTunnelCounter 100"}
        out["every other tunnel counter 0"] = (bool(others) and all(v == 0 for v in others.values()),
                                               f"{others}")
    else:
        out["every packet-in is IPv4"] = (ev["non_ipv4_packet_ins"] == 0,
                                          f"{ev['non_ipv4_packet_ins']} non-IPv4 "
                                          f"({ev['heartbeat_packet_ins']} of them 0x88B5)")
        stray = [f for f in ev["_entry_flows"] if f not in ev["_flows"]]
        out["every cache entry is an IPv4 packet-in's flow"] = (not stray, f"not a packet-in's flow: {stray}")
    return out


def parse_heard(field):
    """{direction: heard} out of the sampler's `heard` column, or None when it is not one."""
    if field in ("", "-"):
        return None
    out = {}
    for item in field.split(","):
        name, _, n = item.rpartition("=")
        if not name or not n.isdigit():
            return None
        out[name] = int(n)
    return out


def read_samples(path):
    out = []
    lines = read_text(path).splitlines()
    head = lines[0].split("\t") if lines else []
    want = SAMPLER_COLUMNS
    if head[:len(want)] != want:
        raise Unreadable(f"{path}: header {head} -- a sampler from before round 6 (no per-direction "
                         f"`heard`, no controllers or ctrl_logs column), or not a sampler's file")
    for line in lines[1:]:
        f = line.split("\t")
        if len(f) < len(want):
            raise Unreadable(f"{path}: a row with {len(f)} fields: {line[:100]}")
        try:
            wall = float(f[0])
        except ValueError as exc:
            raise Unreadable(f"{path}: a row whose wall is not a number: {line[:100]}") from exc
        try:
            written = float(f[6])
        except ValueError:
            written = None
        counts = {}
        for name, v in zip(DAEMON, (f[4], f[5], f[8], f[9])):
            # [Co-developed with claude code -- Adam] None, not 0: a counter the report did not carry
            # is not a counter that stayed at zero (the round-4 review's residual on M2).
            counts[name] = int(v) if v.isdigit() else None
        logs = {}
        for item in f[12].split(","):
            key, _, size = item.rpartition(":")
            if key and size.isdigit():
                logs[key] = int(size)
        out.append({"wall": wall, "status": f[1], "session": f[2], "written": written,
                    "stop_reason": f[7], "counts": counts, "heard": parse_heard(f[10]),
                    "heard_raw": f[10], "ctrl_logs": logs, "row": line[:120]})
    if not out:
        raise Unreadable(f"{path}: no samples")
    return sorted(out, key=lambda s: s["wall"])


def t06_end(samples_path):
    path = os.path.join(os.path.dirname(os.path.abspath(samples_path)), "50_t06_end.txt")
    try:
        return float(read_text(path).split()[0])
    except (IndexError, ValueError) as exc:
        raise Unreadable(f"{path}: not 06's end time") from exc


def session_evidence(arm, ev, samples, end_06):
    """What the samples say about the arm's N5 session across the arm's window -- or Refused."""
    name = f"{arm[0]}/{arm[1]}"
    sess = ev["hb_running"][-1][1]
    t0, t1 = ev["_start"], ev["_end"] if ev["_end"] is not None else end_06
    if t0 is None:
        raise Unreadable(f"treatment {name}: its report's name carries no stamp -- no arm window")
    win = [s for s in samples if t0 <= s["wall"] < t1]
    others = sorted({s["session"] for s in win if s["status"] == "running" and s["session"] != sess})
    if others:
        raise Refused(f"treatment {name}: another heartbeat session ran inside the arm window: {others}")
    mine = [i for i, s in enumerate(win) if s["session"] == sess and s["status"] == "running"]
    if not mine:
        raise Refused(f"treatment {name}: session {sess} was never sampled running in the arm window")
    first = mine[0]
    stop = next((i for i in range(first, len(win)) if win[i]["status"] != "running"), None)
    stretch = win[first:stop if stop is not None else len(win)]
    for a, b in zip(stretch, stretch[1:]):
        if b["wall"] - a["wall"] > MAX_GAP_S:
            raise Refused(f"treatment {name}: no sample for {b['wall'] - a['wall']:.0f} s from "
                          f"{a['wall']:.0f} -- session {sess} was not watched throughout")
    for s in stretch:
        if s["written"] is None or s["wall"] - s["written"] > STALE_S or s["stop_reason"]:
            raise Refused(f"treatment {name}: session {sess} read 'running' at {s['wall']:.0f} from a "
                          f"report written at {s['written']} (stop_reason {s['stop_reason']!r}) -- "
                          f"STALE: a daemon that died leaves 'running' behind")
    if stop is not None and any(s["session"] == sess and s["status"] == "running" for s in win[stop:]):
        raise Refused(f"treatment {name}: session {sess} stopped at {win[stop]['wall']:.0f} and ran again")
    stopped_at = win[stop]["wall"] if stop is not None else t1
    if ev["_last_write"] > stopped_at:
        raise Refused(f"treatment {name}: session {sess} stopped at {stopped_at:.0f}, before the "
                      f"exercise's controller last wrote its log ({ev['_last_write']:.0f})")
    for s in stretch:
        bad = [k for k in DAEMON if s["counts"][k] is None]
        if bad or s["heard"] is None:
            raise Unreadable(f"treatment {name}: a running sample of session {sess} whose "
                             f"{'counters ' + ', '.join(bad) if bad else 'heard column'} "
                             f"{'are' if bad else 'is'} not numbers: {s['row']}")
    counts = {k: max(s["counts"][k] for s in win if s["session"] == sess) for k in DAEMON}
    heard = heard_evidence(name, ev, sess, stretch, samples)
    return {"session": sess, "from": stretch[0]["wall"], "to": stopped_at, "samples": len(stretch),
            "stop_reason": win[stop]["stop_reason"] if stop is not None else "(still running at the window's end)",
            "counts": counts, "heard": heard}


def push_offset(log_path):
    """[Co-developed with claude code -- Adam] The byte offset just past the controller log's last
    pipeline push -- or, with none, past its first rule or cache entry -- or Unreadable."""
    try:
        with open(log_path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        raise Unreadable(f"{log_path}: {type(exc).__name__}: {exc}") from exc
    pos, push, entry = 0, None, None
    for raw in data.splitlines(keepends=True):
        pos += len(raw)
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if PUSH.match(line):
            push = pos
        elif entry is None and (INSTALLED.match(line) or CACHE_ENTRY.match(line)):
            entry = pos
    if push is None and entry is None:
        raise Unreadable(f"{log_path}: no pipeline push and no rule or cache entry -- the controller's "
                         f"window has no start")
    return push if push is not None else entry


def heard_evidence(name, ev, sess, stretch, samples):
    """[Co-developed with claude code -- Adam] Every direction of the session HEARD at least one round
    inside the controller's own window (the round-4 review's M-3, round 6's rule): from the first
    sample whose ctrl_logs size of the arm's log reaches the push's end, to the log's last write."""
    log = ev["log"]
    key = f"{os.path.basename(os.path.dirname(log))}/{os.path.basename(log)}"
    offset = push_offset(log)
    seen = [s for s in samples if key in s["ctrl_logs"]]
    if not seen:
        raise Unreadable(f"treatment {name}: the sampler never saw {key} -- the controller's window "
                         f"cannot be placed among the samples")
    opened = next((s for s in seen if s["ctrl_logs"][key] >= offset), None)
    if opened is None:
        raise Unreadable(f"treatment {name}: the sampler last saw {key} at {seen[-1]['ctrl_logs'][key]} "
                         f"bytes, never at the push's end ({offset}) -- no window start")
    t0, t1 = opened["wall"], ev["_last_write"]
    if t1 - t0 < MIN_WINDOW_S:
        # [Co-developed with claude code -- Adam] UNDECIDED, counted like a decisive check the
        # controls disagree on (exit 2 unless a DIFF), and the rest of the arm still printed
        return {"log": key, "push_offset": offset, "from": t0, "to": t1, "grew": {},
                "undecided": f"the controller's window, push seen at {t0:.0f} to its last write at "
                             f"{t1:.0f}, is {t1 - t0:.1f} s -- under two heartbeat periods "
                             f"({MIN_WINDOW_S:.0f} s), too short to show a direction heard"}
    before = [s for s in stretch if s["wall"] <= t0]
    upto = [s for s in stretch if s["wall"] <= t1]
    if not before:
        raise Refused(f"treatment {name}: session {sess} was first sampled running at "
                      f"{stretch[0]['wall']:.0f}, after the controller pushed its pipeline ({t0:.0f}) "
                      f"-- the window was not watched from its start")
    first, last = before[-1]["heard"], upto[-1]["heard"]
    if not first or set(first) != set(last):
        raise Refused(f"treatment {name}: session {sess}'s directions changed or are none in the "
                      f"controller's window ({sorted(first or {})} vs {sorted(last or {})})")
    deaf = sorted(d for d in first if last[d] - first[d] < 1)
    if deaf:
        raise Refused(f"treatment {name}: session {sess} did not hear {len(deaf)} of {len(first)} "
                      f"direction(s) in the controller's window, {t0:.0f}-{t1:.0f}: "
                      + ", ".join(f"{d} stayed {first[d]}" for d in deaf[:4])
                      + " -- no frame entered the program then, so the arm says nothing about it")
    return {"log": key, "push_offset": offset, "from": t0, "to": t1, "undecided": None,
            "grew": {d: last[d] - first[d] for d in sorted(first)}}


def check_roles(controls, treatment, samples, end_06):
    for label, run in controls:
        for arm in EXTERNAL_ARMS:
            ev = run[arm]
            trace = [w for w, hit in (("the detect-only start line", ev["hb_started"]),
                                      ("a heartbeat block on switch_state", ev["hb_block"]),
                                      (f"a running row {ev['hb_running']}", bool(ev["hb_running"]))) if hit]
            if trace:
                raise Refused(f"{label} {arm[0]}/{arm[1]}: {', '.join(trace)} -- that is not a control")
    out = {}
    for arm in EXTERNAL_ARMS:
        t = treatment[arm]
        name = f"{arm[0]}/{arm[1]}"
        if not t["hb_started"]:
            raise Refused(f"treatment {name}: `ndt up` did not say it started the heartbeat detect-only")
        if not t["hb_running"]:
            raise Refused(f"treatment {name}: no `heartbeat running (pid, session)` row "
                          f"(saw: {t['hb_rows'] or 'none'})")
        out[arm] = session_evidence(arm, t, samples, end_06)
    return out


def fingerprint(run):
    path = os.path.join(run, "00_venv.txt")
    if not os.path.exists(path):
        return ["not recorded (no 00_venv.txt)"]
    out, who = [], None
    for line in read_text(path).splitlines():
        if line.startswith("== interpreter "):
            who = line[len("== interpreter "):]
        elif line.startswith(("protobuf ", "distributions ", "NOT RECORDED")):
            out.append(f"{who}: {line}")
    return out


def fmt(value):
    if isinstance(value, dict):
        return "; ".join(f"{k} = {v[0]} packets ({v[1]} bytes)" if isinstance(v, tuple) else f"{k} = {v}"
                         for k, v in sorted(value.items())) or "(none)"
    if isinstance(value, list):
        return f"{len(value)}: " + " | ".join(value) if value else "0"
    return str(value)


def within(key, t, cs):
    """Whether a treatment value lies inside the spread of the controls' values `cs`."""
    if key == "counters_final":
        keys = set(t).union(*(set(c) for c in cs))
        for k in keys:
            if k not in t or any(k not in c for c in cs):
                return False
            for i in (0, 1):
                vals = [c[k][i] for c in cs]
                if not min(vals) <= t[k][i] <= max(vals):
                    return False
        return True
    if isinstance(t, int) and all(isinstance(c, int) for c in cs):
        return min(cs) <= t <= max(cs)
    return t in cs


def header(label, run, evs):
    print(f"{label} {run}")
    codes = sorted({ev["code"] for ev in evs.values()})
    print(f"  code  {' / '.join(codes)}")
    for line in fingerprint(run):
        print(f"  venv  {line}")


def show(run):
    evs = arms(run)
    header("run", run, evs)
    for arm, ev in evs.items():
        print(f"\n== {arm[0]}/{arm[1]}  (log {ev['log']})")
        print(f"   heartbeat             started detect-only: {ev['hb_started']}; heartbeat block: "
              f"{ev['hb_block']}; status: {ev['hb_rows'] or 'no row'}")
        print(f"   N4 counters           {fmt(ev['n4_counters']) if ev['n4_counters'] else 'none shown'} "
              f"(before the exercise's pipeline was loaded: not evidence about the program)")
        for key in COMPARED + ("counter_reads",):
            print(f"   {key:<21} {fmt(ev[key])}")
        for name, (ok, detail) in invariants(arm, ev).items():
            print(f"   {'inv ok' if ok else 'INV BAD':<7} {name}: {detail}")
    return 0


def identities(control, controls2, treatment, b_sha):
    """[Co-developed with claude code -- Adam] The round-4 review's M-2: every control ran the same
    code, and the treatment ran that code with B merged on top -- or Refused."""
    if not b_sha:
        raise Refused("no --b-sha: which B the treatment merged must be named, or 'the same code "
                      "apart from B' cannot be checked (README, 合併前的比對)")
    ids = []
    for run in [control] + list(controls2) + [treatment]:
        # [Co-developed with claude code -- Adam] round 6: recorded BEFORE and AFTER the run, and equal
        pair = []
        for name in ("00_identity.before.txt", "00_identity.after.txt"):
            path = os.path.join(run, name)
            if not os.path.exists(path):
                raise Refused(f"{run}: no {name} -- which code it ran is not known "
                              f"(record it with live-p1/code_identity.py before and after the run, "
                              f"README step 1)")
            try:
                pair.append(code_identity.load(path))
            except (OSError, ValueError) as exc:
                raise Unreadable(f"{path}: {type(exc).__name__}: {exc}") from exc
        why = code_identity.unchanged_reasons(pair[0], pair[1], os.path.basename(run))
        if why:
            raise Refused(f"the code changed while a run ran: {'; '.join(why)}")
        ids.append(pair[1])
    c, cs, t = ids[0], ids[1:-1], ids[-1]
    for i, other in enumerate(cs):
        why = ([f"HEAD {c.get('head')} vs {other.get('head')}"] if other.get("head") != c.get("head") else []) \
            + code_identity.same_reasons(c, other, "control", f"control2 #{i + 1}")
        if why:
            raise Refused(f"the controls did not run the same code: {'; '.join(why)}")
    why = code_identity.verify(c, t, b_sha)
    if why:
        raise Refused(f"the treatment is not the controls' code plus B: {'; '.join(why)}")
    return c, t


def programs_same(runs):
    """[Co-developed with claude code -- Adam] Round 6: each external arm compiled the same program with
    the same compiler in every run (the round reports' p4c and compiled-JSON sha256s) -- or Refused."""
    for arm in EXTERNAL_ARMS:
        seen = []
        for label, evs in runs:
            ev = evs[arm]
            if not ev["p4c_sha"] or not ev["json_shas"]:
                raise Unreadable(f"{label} {arm[0]}/{arm[1]}: its round report names no p4c sha256 or "
                                 f"no compiled JSON sha256")
            seen.append((label, ev["p4c_sha"], tuple(ev["json_shas"])))
        if len({(p, j) for _l, p, j in seen}) != 1:
            raise Refused(f"{arm[0]}/{arm[1]}: not the same compiler and program in every run: "
                          + "; ".join(f"{l} p4c {p} json {list(j)}" for l, p, j in seen))


def compare(control, treatment, controls2, samples_path, b_sha=None):
    if not samples_path:
        raise Refused("no --samples: every marker in a round report is taken before the exercise's "
                      "controller runs, so only live-p1/08 PART=h5's samples can say the heartbeat "
                      "ran while it did (README, 合併前的比對)")
    if not controls2:
        raise Refused("no --control2: with one control nothing can tell a difference from run-to-run "
                      "noise (README, 合併前的比對)")
    dirs = [os.path.realpath(d) for d in [control] + list(controls2)]
    if len(set(dirs)) != len(dirs):
        raise Refused(f"a control is given twice ({dirs}): a control compared with itself has no spread")
    if os.path.realpath(treatment) in dirs:
        raise Refused("the treatment is one of the controls")
    cid, tid = identities(control, controls2, treatment, b_sha)
    a = arms(control)
    cs2 = [arms(d) for d in controls2]
    b = arms(treatment)
    programs_same([("control", a)] + [(f"control2 #{i + 1}", c) for i, c in enumerate(cs2)]
                  + [("treatment", b)])
    samples, end_06 = read_samples(samples_path), t06_end(samples_path)
    sessions = check_roles([("control", a)] + [(f"control2 #{i + 1}", c) for i, c in enumerate(cs2)],
                           b, samples, end_06)
    header("control  ", control, a)
    for i, (d, c) in enumerate(zip(controls2, cs2)):
        header(f"control2 #{i + 1}", d, c)
    header("treatment", treatment, b)
    print(f"  identity: the controls ran {cid['head'][:12]} with {len(cid.get('uncommitted') or [])} "
          f"uncommitted tracked file(s); the treatment ran {tid['head'][:12]} = that + B {b_sha[:12]}, "
          f"the same uncommitted files, kernel, bmv2, helper and venv")
    print(f"  samples {samples_path}: 06 ended at {end_06:.0f}")
    diffs = undecided = 0
    for arm in EXTERNAL_ARMS:
        se = sessions[arm]
        print(f"\n== {arm[0]}/{arm[1]}")
        print(f"   hb      session {se['session']} running from {se['from']:.0f} to {se['to']:.0f} "
              f"({se['samples']} samples, none stale, no gap over {MAX_GAP_S:g} s; stop: "
              f"{se['stop_reason'] or '-'}); the controller last wrote at {b[arm]['_last_write']:.0f}")
        hd = se["heard"]
        if hd["undecided"]:
            undecided += 1
            print(f"   UNDECIDED heard     {hd['undecided']}")
        else:
            print(f"   heard   all {len(hd['grew'])} direction(s) in the controller's window ({hd['log']} "
                  f"from its push to its last write), {hd['from']:.0f}-{hd['to']:.0f}: "
                  + ", ".join(f"{d} +{n}" for d, n in hd["grew"].items()))
        moved = {k: v for k, v in se["counts"].items() if v}
        if moved:
            diffs += 1
            print(f"   !! DAEMON the heartbeat daemon counted, for this arm's session: {moved}"
                  f"{' -- ruling 4: a frame reached a host' if moved.get('forwarded_to_hosts') else ''}")
        else:
            print(f"   daemon  {fmt(se['counts'])} (the session's own counters, sampled, all 0)")
        for key in COMPARED:
            cvals = [a[arm][key]] + [c[arm][key] for c in cs2]
            if all(v == b[arm][key] for v in cvals):
                print(f"   same    {key:<21} {fmt(b[arm][key])}")
                continue
            if key in DESCRIPTIVE.get(arm, ()):
                where = "inside" if within(key, b[arm][key], cvals) else "OUTSIDE"
                print(f"   note    {key:<21} {fmt(b[arm][key])}\n"
                      f"           {'':<21} {where} the controls' spread -- descriptive, not counted "
                      f"(pre-registered); control: {fmt(a[arm][key])}")
                continue
            if any(v != cvals[0] for v in cvals):
                undecided += 1
                print(f"   UNDECIDED {key:<19} {fmt(b[arm][key])}\n"
                      f"           {'':<21} the controls disagree on a decisive check: "
                      + " / ".join(fmt(v) for v in cvals))
                continue
            diffs += 1
            print(f"   DIFF    {key:<21} {fmt(b[arm][key])}\n"
                  f"           {'':<21} control: {fmt(a[arm][key])}")
        print(f"   ----    {'counter_reads':<21} {b[arm]['counter_reads']} (control "
              f"{a[arm]['counter_reads']}; not compared: it is how long the arm ran)")
        ic = [invariants(arm, a[arm])] + [invariants(arm, c[arm]) for c in cs2]
        for name, (ok, detail) in invariants(arm, b[arm]).items():
            if ok:
                print(f"   inv ok  {name}: {detail}")
            elif name in DESCRIPTIVE_INVARIANTS.get(arm, ()):
                print(f"   inv ..  {name}: {detail} (descriptive, not counted: pre-registered)")
            elif not all(i[name][0] for i in ic):
                undecided += 1
                print(f"   UNDECIDED inv {name}: broken in a control too -- a decisive invariant that "
                      f"is not one: {detail}")
            else:
                diffs += 1
                print(f"   INV BAD {name}: {detail} (every control keeps it)")
        if b[arm]["heartbeat_packet_ins"]:
            print(f"   !! {b[arm]['heartbeat_packet_ins']} packet-in(s) carried the heartbeat's "
                  f"ethertype 0x88B5: the frame reached the exercise's own controller")
    print(f"\n{'NO DIFFERENCE' if not diffs else f'{diffs} DIFFERENCE(S)'} in the external arms' "
          f"own evidence ({1 + len(cs2)} controls)"
          + (f"; {undecided} UNDECIDED: the controls disagree on a decisive check, or a controller's "
             f"window was too short to show the heartbeat heard" if undecided else ""))
    return 1 if diffs else 2 if undecided else 0


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "show":
            return show(argv[1])
        if len(argv) >= 3 and argv[0] == "compare":
            rest, controls2, samples, b_sha = argv[3:], [], None, None
            while len(rest) >= 2 and rest[0] in ("--control2", "--samples", "--b-sha"):
                if rest[0] == "--control2":
                    controls2.append(rest[1])
                elif rest[0] == "--samples":
                    samples = rest[1]
                else:
                    b_sha = rest[1]
                rest = rest[2:]
            if not rest:
                return compare(argv[1], argv[2], controls2, samples, b_sha)
    except Unreadable as exc:
        print(f"UNREADABLE {exc}")
        return 2
    except Refused as exc:
        print(f"REFUSED {exc}")
        return 3
    print(__doc__.split("Usage:")[1].split("Exit:")[0].rstrip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
