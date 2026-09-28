#!/usr/bin/env python3
"""
The external arms' OWN evidence out of live-p1/06 runs: a control without the heartbeat against a
treatment with it.

[Co-developed with claude code -- Adam]

09-27: `ndt up p4 --app` starts the veth heartbeat on an external control plane too, detect only.
Adam's standing condition (09-25) is that the heartbeat must not change what a user's own
forwarding does. What must NOT differ between a run without it and a run with it is what the
exercise's own controller saw and did -- its log, in each round's directory -- and what each arm's
own numbers must satisfy whatever the other run says.

WHAT IS READ, per external arm (p4runtime skeleton and solution, flowcache solution):
  * 00_table.tsv: the arm's rc, verdict and round report (`<round>.md`, the round directory beside);
  * the round report: which code the arm ran (`code <sha> ...`), whether `ndt up` started the
    heartbeat detect-only (its `ok` line) and whether `ndt status` saw it running (the `heartbeat
    running (pid N, session S)` row), the pings h1 sent h2, and link_usage/iperf_client.txt;
  * the controller log: every rule installed, the LAST complete tunnel-counter block, every
    packet-in (and its frame's ethertype), every cache entry, every gRPC error.

WHAT IS REFUSED (exit 3), because the comparison would be about nothing (the external judge's F1,
09-28): a treatment arm with no detect-only start or no running status row, and a control arm
whose heartbeat was running -- an A/A comparison can only print NO DIFFERENCE. With --samples
(live-p1/08 PART=h5's 50_samples.tsv), each treatment arm's session must also have been read
running, and no sample of it may count a frame forwarded to a host or to another switch.

WHAT IS UNREADABLE (exit 2), never "same": a missing table, row, report or log; a file that cannot
be read or decoded; a counter block cut short (a controller stopped mid-print); a packet-in whose
frame cannot be parsed (a format drift would otherwise make the 0x88B5 count a guaranteed 0).

WHAT IS COMPARED, and against what. Run-to-run noise is real (a flowcache race, counter timing),
so a difference counts only OUTSIDE the spread of two control runs (--control2, the same arms in
the same session and venv without the heartbeat -- the judge's F2). Without a second control every
difference is printed as a DIFF and none can be told from noise; the tool says so. Beside that,
each arm's INVARIANTS hold on its own numbers (the judge's section 5.5 and 5.4):
  * p4runtime/solution: s1 ingress 100 = pings h1->h2 + iperf datagrams to h2 (+ at most 10 FIN
    retries when the client got no ack); s2 egress 100 = s1 ingress 100; s1 egress 200 = s2 ingress 200;
  * p4runtime/skeleton: s1 ingress 100 = pings h1->h2, and every other tunnel counter 0;
  * flowcache/solution: every packet-in is IPv4 (none 0x88B5, none of any other type), and every
    cache entry is the flow of an IPv4 packet-in the controller received.
An invariant the treatment breaks and the control keeps is a difference; one both break is shown.

Usage:  external_evidence.py show <06 run dir>
        external_evidence.py compare <control 06 run> <treatment 06 run> [--control2 <06 run>]
                                     [--samples <50_samples.tsv>]
Exit:   0 nothing outside the control's spread and every invariant as the control has it;
        1 a difference (each printed); 2 unreadable; 3 refused (a treatment without the heartbeat,
        or a control with it).
"""

from __future__ import annotations

import ast
import glob
import os
import re
import sys

#: (exercise, arm) -- the three 06 arms whose fabric has an external control plane.
EXTERNAL_ARMS = (("p4runtime", "skeleton"), ("p4runtime", "solution"), ("flowcache", "solution"))
HEARTBEAT_ETHERTYPE = 0x88B5
IPV4_ETHERTYPE = 0x0800
#: The evidence that decides; everything else printed is context.
COMPARED = ("rc", "verdict", "rules_installed", "counters_final", "packet_ins", "cache_entries",
            "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors")
#: The most FIN retries iperf makes when it gets no ack of its last datagram.
IPERF_FIN_RETRIES = 10

INSTALLED = re.compile(r"^Installed .* on s\d+\s*$")
COUNTER = re.compile(r"^(s\d+ \S+ \d+): (\d+) packets \((\d+) bytes\)\s*$")
CACHE_ENTRY = re.compile(r"^For switch s\d+ flow \(SA=([\d.]+), DA=([\d.]+), proto=(\d+)\) added table entry .*$")
CODE = re.compile(r"^\s*code\s+([0-9a-f]{7,40})\s*(.*?)\s*$")
HB_UP = "heartbeat running on the inter-switch veths, detect only"
#: `ndt status`'s heartbeat row (printf '  %-14s %s'): two or more spaces after the word, which
#: `heartbeat plan:` / `heartbeat started (pid` in ndt up's output do not have.
HB_ROW = re.compile(r"^\s*heartbeat\s{2,}(running \(pid (\d+), session ([0-9a-f]+)\).*|\S.*)$")
#: The daemon's own counters, as switch_state's heartbeat block serves them in the round report.
SIDE_EFFECT = re.compile(r'"(forwarded_to_hosts|forwarded_between_switches|misdelivered|foreign_frames)":\s*(\d+)')
PING_HEAD = re.compile(r"^### \d+\. \S+\s+h1 (?:ping|probes) h2\b")
TRANSMITTED = re.compile(r"^(\d+) packets transmitted")
SENT = re.compile(r"Sent (\d+) datagrams")
CONNECTED = re.compile(r"connected with ([\d.]+) port")


class Unreadable(Exception):
    """Evidence that cannot be read: exit 2, never a comparison."""


class Refused(Exception):
    """A comparison about nothing -- a treatment without the heartbeat, a control with it: exit 3."""


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
    """The ethertype of a decodePacketInMetadata line's payload -- or Unreadable."""
    try:
        payload = ast.literal_eval(line.split("ret=", 1)[1].strip())["payload"]
        if not isinstance(payload, bytes) or len(payload) < 14:
            raise ValueError("payload shorter than an Ethernet header")
    except (IndexError, KeyError, TypeError, ValueError, SyntaxError) as exc:
        raise Unreadable(f"a packet-in whose frame cannot be parsed ({type(exc).__name__}): "
                         f"{line[:120]}") from exc
    return int.from_bytes(payload[12:14], "big"), payload


def ipv4_flow(payload):
    """(src, dst, proto) of an IPv4 frame."""
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
    return {
        "rules_installed": sorted(line.strip() for line in lines if INSTALLED.match(line)),
        "counters_final": blocks[-1] if blocks else {},
        "counter_reads": len(blocks),
        "packet_ins": sum(1 for line in lines if line.startswith("Received PacketIn")),
        "cache_entries": sorted(entries),
        "heartbeat_packet_ins": sum(1 for e in kinds if e == HEARTBEAT_ETHERTYPE),
        "non_ipv4_packet_ins": sum(1 for e in kinds if e != IPV4_ETHERTYPE),
        "grpc_errors": sum(1 for line in lines if line.startswith("gRPC error occurred")),
        "_flows": flows,
        "_entry_flows": [(m.group(1), m.group(2), int(m.group(3)))
                         for m in (CACHE_ENTRY.match(e) for e in entries)],
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
    sent, target, no_ack = 0, None, False
    if os.path.exists(iperf):
        itext = read_text(iperf)
        m, c = SENT.search(itext), CONNECTED.search(itext)
        sent, target = (int(m.group(1)) if m else 0), (c.group(1) if c else None)
        no_ack = "did not receive ack of last datagram" in itext
    side = {}
    for name, n in SIDE_EFFECT.findall(text):
        side[name] = max(side.get(name, 0), int(n))
    return {
        "code": "; ".join(f"{sha} {rest}".strip() for sha, rest in codes) or "not recorded",
        "side_effects": side,
        "hb_started": HB_UP in text,
        "hb_rows": [m.group(1) for m in rows],
        "hb_running": running,
        "pings_h1_h2": pings,
        "iperf": {"sent": sent, "target": target, "no_ack": no_ack},
    }


def arms(run):
    rows = table_rows(run)
    out = {}
    for arm in EXTERNAL_ARMS:
        row = rows.get(arm)
        if row is None:
            raise Unreadable(f"{run}: no {arm[0]}/{arm[1]} row in 00_table.tsv")
        out[arm] = dict(row, **controller_evidence(controller_log(row["report"])),
                        **report_evidence(row["report"]))
    return out


def invariants(arm, ev):
    """{name: (holds, detail)} -- the arm's own numbers, whatever the other run says."""
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


def check_roles(control, treatment, samples):
    """Refused unless the treatment ran the heartbeat on every arm and the control on none."""
    why = []
    for arm in EXTERNAL_ARMS:
        name = f"{arm[0]}/{arm[1]}"
        t = treatment[arm]
        if not t["hb_started"]:
            why.append(f"treatment {name}: `ndt up` did not say it started the heartbeat detect-only")
        if not t["hb_running"]:
            why.append(f"treatment {name}: no `heartbeat running (pid, session)` row "
                       f"(saw: {t['hb_rows'] or 'none'})")
        if control[arm]["hb_running"]:
            why.append(f"control {name}: the heartbeat was running ({control[arm]['hb_running']}) "
                       f"-- that is not a control")
        if not t["side_effects"]:
            why.append(f"treatment {name}: the round report shows no daemon counters "
                       f"(switch_state's heartbeat.side_effects) -- nothing says what it forwarded")
        if samples is not None and t["hb_running"]:
            sess = t["hb_running"][-1][1]
            mine = [s for s in samples if s["session"] == sess]
            if not any(s["status"] == "running" for s in mine):
                why.append(f"treatment {name}: session {sess} was never sampled running")
            leaked = [s for s in mine if s["hosts"] not in ("0", "") or s["between"] not in ("0", "")]
            if leaked:
                raise_hosts = leaked[0]
                why.append(f"treatment {name}: session {sess} counted a frame forwarded "
                           f"(to hosts {raise_hosts['hosts']}, between switches "
                           f"{raise_hosts['between']}) at {raise_hosts['wall']}")
    if why:
        raise Refused("; ".join(why))


def read_samples(path):
    out = []
    for line in read_text(path).splitlines()[1:]:
        f = line.split("\t")
        if len(f) >= 6:
            out.append({"wall": f[0], "status": f[1], "session": f[2], "hosts": f[4], "between": f[5]})
    if not out:
        raise Unreadable(f"{path}: no samples")
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


def within(key, t, c1, c2):
    """Whether a treatment value lies inside the spread of the two controls."""
    if key == "counters_final":
        keys = set(t) | set(c1) | set(c2)
        for k in keys:
            if k not in t or k not in c1 or k not in c2:
                return False
            for i in (0, 1):
                lo, hi = sorted((c1[k][i], c2[k][i]))
                if not lo <= t[k][i] <= hi:
                    return False
        return True
    if isinstance(t, int) and isinstance(c1, int) and isinstance(c2, int):
        return min(c1, c2) <= t <= max(c1, c2)
    return t in (c1, c2)


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
        print(f"   heartbeat             started detect-only: {ev['hb_started']}; status: "
              f"{ev['hb_rows'] or 'no row'}; daemon counters: {ev['side_effects'] or 'none shown'}")
        for key in COMPARED + ("counter_reads",):
            print(f"   {key:<21} {fmt(ev[key])}")
        for name, (ok, detail) in invariants(arm, ev).items():
            print(f"   {'inv ok' if ok else 'INV BAD':<7} {name}: {detail}")
    return 0


def compare(control, treatment, control2=None, samples_path=None):
    a, b = arms(control), arms(treatment)
    c2 = arms(control2) if control2 else None
    samples = read_samples(samples_path) if samples_path else None
    check_roles(a, b, samples)
    if c2 is not None:
        for arm in EXTERNAL_ARMS:
            if c2[arm]["hb_running"]:
                raise Refused(f"control2 {arm[0]}/{arm[1]}: the heartbeat was running -- not a control")
    header("control  ", control, a)
    if c2 is not None:
        header("control2 ", control2, c2)
    header("treatment", treatment, b)
    if c2 is None:
        print("  !! one control only: a DIFF below may be run-to-run noise -- nothing here can tell "
              "(run the same arms twice without the heartbeat and pass --control2)")
    if samples is not None:
        print(f"  samples {samples_path}: every treatment arm's session read running, no frame "
              f"forwarded to a host or between switches")
    diffs = 0
    for arm in EXTERNAL_ARMS:
        print(f"\n== {arm[0]}/{arm[1]}  (treatment session "
              f"{b[arm]['hb_running'][-1][1] if b[arm]['hb_running'] else '-'})")
        for key in COMPARED:
            if a[arm][key] == b[arm][key]:
                print(f"   same    {key:<21} {fmt(b[arm][key])}")
                continue
            if c2 is not None and within(key, b[arm][key], a[arm][key], c2[arm][key]):
                print(f"   spread  {key:<21} {fmt(b[arm][key])}\n"
                      f"           {'':<21} inside the two controls' spread (not counted)")
                continue
            diffs += 1
            print(f"   DIFF    {key:<21} {fmt(b[arm][key])}\n"
                  f"           {'':<21} control: {fmt(a[arm][key])}")
        print(f"   ----    {'counter_reads':<21} {b[arm]['counter_reads']} (control "
              f"{a[arm]['counter_reads']}; not compared: it is how long the arm ran)")
        ia, ib = invariants(arm, a[arm]), invariants(arm, b[arm])
        for name, (ok, detail) in ib.items():
            if ok:
                print(f"   inv ok  {name}: {detail}")
            elif not ia[name][0]:
                print(f"   inv --  {name}: broken in the control too, so not the treatment's: {detail}")
            else:
                diffs += 1
                print(f"   INV BAD {name}: {detail} (the control keeps it)")
        moved = {k: v for k, v in b[arm]["side_effects"].items() if v}
        if moved:
            diffs += 1
            print(f"   !! DAEMON the heartbeat daemon counted frames it must not: {moved} "
                  f"(ruling 4 when a host got one)")
        else:
            print(f"   daemon  {fmt(b[arm]['side_effects'])} (the treatment's own counters, all 0)")
        if b[arm]["heartbeat_packet_ins"]:
            print(f"   !! {b[arm]['heartbeat_packet_ins']} packet-in(s) carried the heartbeat's "
                  f"ethertype 0x88B5: the frame reached the exercise's own controller")
    print(f"\n{'NO DIFFERENCE' if not diffs else f'{diffs} DIFFERENCE(S)'} in the external arms' "
          f"own evidence{'' if c2 is not None else ' (one control: noise not excluded)'}")
    return 0 if not diffs else 1


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "show":
            return show(argv[1])
        if len(argv) >= 3 and argv[0] == "compare":
            rest, opts = argv[3:], {}
            while len(rest) >= 2 and rest[0] in ("--control2", "--samples"):
                opts[rest[0]], rest = rest[1], rest[2:]
            if not rest:
                return compare(argv[1], argv[2], opts.get("--control2"), opts.get("--samples"))
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
