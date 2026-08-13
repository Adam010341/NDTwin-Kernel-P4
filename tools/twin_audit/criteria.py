#!/usr/bin/env python3
"""
criteria.py -- "are packets actually moving between these two hosts?", answered by three
independent observations that have to agree before anything is asserted.

[Co-developed with claude code -- Adam]

Why this file exists
--------------------
2026-08-13, overnight OVS round: the twin reported a flow "flowing at 9-15 Mbps" with
edges_up = 287/288, while that flow had carried zero packets for 291 seconds. Every single
signal that was being watched agreed with the twin, because they all descend from the same
ingest. The lesson this repo keeps relearning is that ONE source of truth is a source that
can be wrong in silence, so the verdict here is a quorum over three channels that fail
independently:

  ping      the data plane itself, in BOTH directions (see below -- one direction proves
            nothing here)
  paths     the control plane's own answer, from all_destination_paths
  counters  a peer-side packet counter sampled TWICE, judged on GROWTH

The three can each be fooled, but not by the same fault:

  * a stale twin fools `paths`   (control plane still advertises a route) and can fool
    `counters` (background traffic), but not `ping`
  * a busy host fools `counters` (rx grows for unrelated reasons), but not `ping`/`paths`
  * an ICMP-specific filter fools `ping`, but not `paths`/`counters`

Hence QUORUM = 2 and the rule "no dissent". A single channel never decides anything.

Both directions, always
-----------------------
doc/2026-08-10_p4_manual_test_runbook.md (2026-08-10, 3 of 6 host pairs measured asymmetric):
forward and return traffic routinely take different switches, so **one direction cannot
tell you whether two hosts can talk**. A switch failure can break exactly the direction you
did not look at. Every check here therefore asks both ways and treats "only one way works"
as NOT moving -- that asymmetric state is precisely the shape of the P0 above (a one-ended
`netem loss 100%` left the graph asymmetric permanently), and calling it UNKNOWN would
disarm the detector at the one case it was built for.

Growth, not magnitude
---------------------
`counters` compares two samples. A non-zero counter proves that packets moved at some
point in the past, which is exactly the mistake the 291-second flow got away with. Only a
counter that MOVED between two reads proves that packets are moving now.

Seams
-----
Nothing in this module touches the outside world except the three functions in the "world"
section (`run_command`, `http_get_json`, `sleep`) and the clock (`now`). Tests replace
those wholesale; live runs point them at reality with environment variables:

  TWIN_AUDIT_PING          ping binary                        (default: ping)
  TWIN_AUDIT_MNEXEC        prefix for entering a host netns    (default: sudo -n mnexec)
  TWIN_AUDIT_CAT           command used to read /proc/net/dev  (default: cat)
  NDT_URL                  kernel northbound API   (default: http://localhost:8000)
  PATHS_URL                all_destination_paths host. OVS: Ryu :8080. P4: proxy :8081.
                           (default: http://localhost:8080)
  TWIN_AUDIT_PING_COUNT    echo requests per direction         (default: 10)
  TWIN_AUDIT_GAP_S         seconds between the two counter samples (default: 2.0)
  TWIN_AUDIT_MIN_GROWTH    packets of growth that count as motion  (default: 1)
  TWIN_AUDIT_TIMEOUT_S     per-command / per-request timeout    (default: 10)

CLI (this is the interface tools/test_workflow/faults.sh calls)
---------------------------------------------------------------
  criteria.py check --src-ip 10.0.0.1 --dst-ip 10.0.0.2 [--src-pid N] [--dst-pid N] [--json]

Exit codes, chosen so a shell caller can branch without parsing text:
  0  MOVING          quorum says packets are moving
  1  STILL           quorum says they are not
  2  usage error     (same meaning as qdisc_snapshot.sh, deliberately)
  3  INCONCLUSIVE    not enough channels reported
  4  DISPUTED        channels contradict each other -- one of them is broken, which is
                     itself worth waking up for
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import OrderedDict

# --- verdict vocabulary -------------------------------------------------------------

MOVING = "moving"
STILL = "still"
UNKNOWN = "unknown"

DISPUTED = "disputed"
INCONCLUSIVE = "inconclusive"

#: How many channels must agree before a verdict is asserted. Two, not one, because every
#: channel here has a documented way of being wrong on its own.
QUORUM = 2

EXIT_CODES = {
    MOVING: 0,
    STILL: 1,
    INCONCLUSIVE: 3,
    DISPUTED: 4,
}


# --- the world ----------------------------------------------------------------------
# The only four functions in this module that touch anything outside the process. Tests
# replace them by assignment; live callers configure them through the environment.


class CommandResult(object):
    """What `run_command` returns. `rc` is None when the command could not be run at all."""

    def __init__(self, rc, stdout="", stderr=""):
        self.rc = rc
        self.stdout = stdout
        self.stderr = stderr

    def __repr__(self):  # pragma: no cover - debugging aid
        return "CommandResult(rc=%r, stdout=%r, stderr=%r)" % (
            self.rc, self.stdout, self.stderr)


def run_command(argv, timeout):
    """Run argv, never raise. A command that could not run gets rc=None, not rc!=0 --
    "the probe failed" and "the probe answered no" must not be the same value, or an
    unrunnable ping would read as a dead link."""
    try:
        proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        return CommandResult(None, "", str(exc))
    return CommandResult(proc.returncode,
                         proc.stdout.decode("utf-8", "replace"),
                         proc.stderr.decode("utf-8", "replace"))


def http_get_json(url, timeout):
    """GET and parse JSON. Returns None on any failure -- callers turn that into UNKNOWN,
    never into STILL: an unreachable endpoint is missing evidence, not evidence of death."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, OSError, ValueError):
        return None


def sleep(seconds):
    """The gap between the two counter samples. A seam so tests take no wall-clock time."""
    time.sleep(seconds)


def now():
    """Wall clock, seam'd so staleness reporting is testable."""
    return time.time()


# --- configuration ------------------------------------------------------------------


def _env(name, default):
    value = os.environ.get(name)
    return default if value is None or value == "" else value


class Config(object):
    """Everything the checks need to know about *where*, read once from the environment.

    Constructed explicitly in tests; `Config.from_env()` in production. Keeping this out
    of module globals is what lets one process audit two testbeds.
    """

    def __init__(self, ping="ping", mnexec="sudo -n mnexec", cat="cat",
                 ndt_url="http://localhost:8000", paths_url="http://localhost:8080",
                 ping_count=10, gap_s=2.0, min_growth=1, timeout_s=10.0):
        self.ping = ping
        self.mnexec = mnexec
        self.cat = cat
        self.ndt_url = ndt_url.rstrip("/")
        self.paths_url = paths_url.rstrip("/")
        self.ping_count = int(ping_count)
        self.gap_s = float(gap_s)
        self.min_growth = int(min_growth)
        self.timeout_s = float(timeout_s)

    @classmethod
    def from_env(cls):
        return cls(
            ping=_env("TWIN_AUDIT_PING", "ping"),
            mnexec=_env("TWIN_AUDIT_MNEXEC", "sudo -n mnexec"),
            cat=_env("TWIN_AUDIT_CAT", "cat"),
            ndt_url=_env("NDT_URL", "http://localhost:8000"),
            paths_url=_env("PATHS_URL", "http://localhost:8080"),
            ping_count=_env("TWIN_AUDIT_PING_COUNT", 10),
            gap_s=_env("TWIN_AUDIT_GAP_S", 2.0),
            min_growth=_env("TWIN_AUDIT_MIN_GROWTH", 1),
            timeout_s=_env("TWIN_AUDIT_TIMEOUT_S", 10.0),
        )


class Target(object):
    """The pair whose connectivity is in question.

    `src_pid`/`dst_pid` are Mininet host PIDs. When present, probes run inside that host's
    namespace via mnexec (`mnexec -a` wants a PID, not a name -- passing a name is a
    documented bug in this repo's history, see doc/2026-07-27_p4_bmv2_support_plan.md item 6).
    When absent the command runs in the caller's namespace, which is what a stubbed test
    and a single-namespace P4 testbed both want.
    """

    def __init__(self, src_ip, dst_ip, src_pid=None, dst_pid=None, label=None):
        self.src_ip = src_ip
        self.dst_ip = dst_ip
        self.src_pid = src_pid
        self.dst_pid = dst_pid
        self.label = label or "%s -> %s" % (src_ip, dst_ip)

    def reversed(self):
        return Target(self.dst_ip, self.src_ip, self.dst_pid, self.src_pid,
                      "%s -> %s" % (self.dst_ip, self.src_ip))


class Observation(object):
    """One channel's answer. `verdict` is MOVING / STILL / UNKNOWN."""

    def __init__(self, check, verdict, detail):
        self.check = check
        self.verdict = verdict
        self.detail = detail

    def as_dict(self):
        return {"check": self.check, "verdict": self.verdict, "detail": self.detail}

    def __repr__(self):  # pragma: no cover - debugging aid
        return "Observation(%r, %r, %r)" % (self.check, self.verdict, self.detail)


# --- helpers ------------------------------------------------------------------------


def ip_int_to_str(value):
    """Convert the kernel's integer IP fields to dotted quad.

    doc/2026-01-02_ndt_api.md: these hold `struct in_addr::s_addr`, i.e. the address in NETWORK byte
    order, serialised as whatever integer those four bytes make on this (little-endian)
    host. So 16777226 is 10.0.0.1, NOT 1.0.0.10 -- its bytes are 0A 00 00 01, already in
    address order. Unpacking little-endian therefore reads them out in order; using
    `!I`/ntohl here would silently reverse every address in the report.
    """
    return socket.inet_ntoa(struct.pack("<I", int(value) & 0xFFFFFFFF))


def _in_namespace(cfg, pid, argv):
    """Wrap argv so it runs inside a Mininet host's namespace, when a PID was given."""
    if pid is None:
        return list(argv)
    return shlex.split(cfg.mnexec) + ["-a", str(int(pid))] + list(argv)


# --- check 1: bidirectional ping ----------------------------------------------------


def ping_once(cfg, from_pid, to_ip):
    """True/False if the answer is trustworthy, None if the probe itself could not run.

    [Co-developed with claude code -- Adam]
    The count of 10 and `-i 0.2` travel together, and both exist because of faults.txt
    L-3 (30% loss on both ends). One echo round-trip survives that link with
    p = 0.7 * 0.7 = 0.49, so three echoes all die with p = 0.51^3 ~= 13% per direction --
    which is the flaky L-3 verdict the 2026-08-13 live rounds recorded: a loss level the
    check is supposed to call "moving" flipped its ping vote at coin-toss-ish rates, and
    any dissent is DISPUTED. Ten echoes put the same event at 0.51^10 < 0.2%.
    The interval is not a taste choice: ping's default is one echo per second, so ten
    echoes at the default run ~9 s into run_command's 10 s timeout and the gray-link fix
    would just trade flaky STILL for flaky UNKNOWN. 0.2 s is the tightest interval
    iputils grants without privileges. The budget test in test_twin_audit_criteria.py
    does this arithmetic against the argv actually built, so raising the count without
    widening the timeout is a red test, not a live surprise.
    """
    argv = _in_namespace(cfg, from_pid, [
        cfg.ping, "-c", str(cfg.ping_count), "-i", "0.2", "-W", "1", "-n", to_ip])
    result = run_command(argv, cfg.timeout_s)
    if result.rc is None:
        return None
    return result.rc == 0


def check_ping(cfg, target):
    forward = ping_once(cfg, target.src_pid, target.dst_ip)
    reverse = ping_once(cfg, target.dst_pid, target.src_ip)

    if forward is None or reverse is None:
        return Observation("ping", UNKNOWN,
                           "ping could not be run (forward=%r reverse=%r)"
                           % (forward, reverse))
    if forward and reverse:
        return Observation("ping", MOVING, "both directions answer")
    if not forward and not reverse:
        return Observation("ping", STILL, "neither direction answers")
    dead = "reverse" if forward else "forward"
    return Observation("ping", STILL,
                       "asymmetric: only one direction answers, %s is dead" % dead)


# --- check 2: control-plane path count ----------------------------------------------


def fetch_paths(cfg):
    """The raw all_destination_paths list, or None if it could not be read."""
    payload = http_get_json(cfg.paths_url + "/ryu_server/all_destination_paths",
                            cfg.timeout_s)
    if not isinstance(payload, dict):
        return None
    paths = payload.get("all_destination_paths")
    if not isinstance(paths, list):
        return None
    return paths


def _path_endpoints(path):
    """(first node, last node) of one path, or None if the shape is not what we expect.

    A path is a list of hops; each hop's [0] is the node (host IP string at the ends).
    Source: doc/2026-08-10_ovs_manual_test_runbook.md 4h, which reads p[0][0] and p[-1][0].
    """
    if not isinstance(path, list) or len(path) < 2:
        return None
    first, last = path[0], path[-1]
    if isinstance(first, (list, tuple)) and first:
        first = first[0]
    if isinstance(last, (list, tuple)) and last:
        last = last[0]
    return (str(first), str(last))


def count_paths(paths, src_ip, dst_ip):
    total = 0
    for path in paths:
        ends = _path_endpoints(path)
        if ends is not None and ends[0] == src_ip and ends[1] == dst_ip:
            total += 1
    return total


def check_paths(cfg, target):
    paths = fetch_paths(cfg)
    if paths is None:
        return Observation("paths", UNKNOWN,
                           "all_destination_paths unreadable at " + cfg.paths_url)
    forward = count_paths(paths, target.src_ip, target.dst_ip)
    reverse = count_paths(paths, target.dst_ip, target.src_ip)
    detail = "forward=%d reverse=%d (of %d advertised)" % (forward, reverse, len(paths))
    if forward > 0 and reverse > 0:
        return Observation("paths", MOVING, detail)
    if forward == 0 and reverse == 0:
        return Observation("paths", STILL, "no path either way; " + detail)
    return Observation("paths", STILL, "asymmetric routing state; " + detail)


# --- check 3: peer counter growth ---------------------------------------------------


def read_rx_packets(cfg, pid):
    """Total rx packets across the host's non-loopback interfaces, or None if unreadable.

    /proc/net/dev inside the host's own namespace: independent of the twin, of sFlow and
    of Ryu, which is the whole point of having it as a third channel.
    """
    argv = _in_namespace(cfg, pid, [cfg.cat, "/proc/net/dev"])
    result = run_command(argv, cfg.timeout_s)
    if result.rc is None or result.rc != 0:
        return None
    total = 0
    seen = False
    for line in result.stdout.splitlines():
        if ":" not in line:
            continue
        name, _, rest = line.partition(":")
        name = name.strip()
        if not name or name == "lo":
            continue
        fields = rest.split()
        if len(fields) < 2:
            continue
        try:
            total += int(fields[1])
        except ValueError:
            continue
        seen = True
    return total if seen else None


def check_counters(cfg, target):
    """Two samples of the far end's rx counter with our own probe traffic in between.

    [Co-developed with claude code -- Adam]
    This channel used to sample, sleep, and sample again -- pure passive observation. On an
    idle link that reads STILL no matter how healthy the path is, so a quiet network came out
    as ping=MOVING against counters=STILL: permanent DISPUTED, and the fault harness refused
    to inject on the grounds that the baseline was broken. Found on the harness's first live
    run, 2026-08-13; the earlier runs that looked fine had a background flood running.

    Sending between the samples makes it an experiment rather than an observation: the
    question becomes "did the packets I just sent arrive", which needs no external traffic
    and is what independence was supposed to mean. It does not collapse into the ping check:
    this counts arrivals at the far end, so a path that carries packets one way but drops the
    replies shows up here as MOVING while ping says STILL -- the asymmetry stays visible.

    Known weakness, unchanged: unrelated background traffic to the same host also grows the
    counter, so this can say MOVING for the wrong reason. One vote, never a verdict.
    """
    first = read_rx_packets(cfg, target.dst_pid)
    if first is None:
        return Observation("counters", UNKNOWN, "peer rx counter unreadable")
    probe_rc = ping_once(cfg, target.src_pid, target.dst_ip)
    if probe_rc is None:
        # The probe could not be launched at all; the sleep alone would measure background
        # noise, and reporting that as the flow's health is exactly the passive trap above.
        return Observation("counters", UNKNOWN, "probe traffic could not be generated")
    sleep(cfg.gap_s)
    second = read_rx_packets(cfg, target.dst_pid)
    if second is None:
        return Observation("counters", UNKNOWN, "peer rx counter unreadable on resample")

    growth = second - first
    detail = "peer rx %d -> %d over %.1fs (growth %d, floor %d)" % (
        first, second, cfg.gap_s, growth, cfg.min_growth)
    if growth < 0:
        # A counter that went backwards means the interface was reset or the far end was
        # replaced between samples. That is not evidence of stillness, it is evidence that
        # this channel lost track of what it was measuring.
        return Observation("counters", UNKNOWN, "counter went backwards; " + detail)
    if growth >= cfg.min_growth:
        return Observation("counters", MOVING, detail)
    return Observation("counters", STILL, detail)


# --- reserved: path reconciliation --------------------------------------------------


def check_path_match(cfg, target):  # pragma: no cover - refuses before doing anything
    """RESERVED, not implemented this round.

    The next question after "are packets moving" is "are they moving along the path the
    twin claims". That needs a per-hop observation (flow-table dumps, or an ingress counter
    per hop) which is a different order of expense, so this round stops at connectivity.

    It is registered rather than merely mentioned so that adding it later is a one-line
    change to RESERVED_CHECKS -> CHECKS with no change to `evaluate`, and so that the
    quorum arithmetic already accounts for a fourth channel. A reserved check that silently
    returned UNKNOWN would be worse than this: it would look implemented in the output.
    """
    raise NotImplementedError(
        "path_match is reserved for a later round; this tool reconciles connectivity only")


#: The channels that vote. Order is the order they run in and the order they print.
CHECKS = OrderedDict([
    ("ping", check_ping),
    ("paths", check_paths),
    ("counters", check_counters),
])

#: Which channels are *evidence* and which merely repeat a *claim*.
#:
#: [Co-developed with claude code -- Adam]
#: This split is the whole point of the tool and it was missing on the first pass, which is
#: worth recording. ping and counters go and look at the network. `paths` reads
#: all_destination_paths -- the controller stating what it believes -- and the twin's belief
#: is the thing under audit, not a witness to it. Letting it vote seats the defendant on the
#: jury: measured live 2026-08-13, with h1's access link cut, ping said still, counters said
#: still, paths said moving, and the verdict came out DISPUTED with exit 0. That is precisely
#: the shape of the incident this tool exists to catch (twin advertising a healthy path over
#: a flow carrying no packets), so the first version would have missed its own founding case.
#:
#: Claim channels are still run and still printed -- a claim contradicting the evidence is
#: the most interesting line in the report -- they just do not get a vote.
EVIDENCE_CHECKS = ("ping", "counters")
CLAIM_CHECKS = ("paths",)

#: Declared but not implemented. Enabling one raises NotImplementedError rather than
#: quietly contributing UNKNOWN.
RESERVED_CHECKS = OrderedDict([
    ("path_match", check_path_match),
])


def resolve_checks(names):
    """Map requested check names to callables. Unknown names and reserved names are
    distinguishable errors, because "I typo'd" and "that is not built yet" want different
    reactions from the operator."""
    if names is None:
        return OrderedDict(CHECKS)
    chosen = OrderedDict()
    for name in names:
        if name in CHECKS:
            chosen[name] = CHECKS[name]
        elif name in RESERVED_CHECKS:
            raise NotImplementedError(
                "check %r is reserved and not implemented yet" % name)
        else:
            raise KeyError("no such check: %r (have: %s)"
                           % (name, ", ".join(CHECKS)))
    return chosen


# --- the quorum ---------------------------------------------------------------------


def combine(observations):
    """Fold the *evidence* channels into one verdict.

    MOVING / STILL need QUORUM agreeing channels AND no dissent. Any dissent at all is
    DISPUTED, never a majority vote: two channels outvoting a third does not make the
    third wrong, it means one of several independent observers of the same network
    disagrees and somebody should find out which. Everything else is INCONCLUSIVE.

    Claim channels (CLAIM_CHECKS) are excluded here -- see the note beside that constant.
    They are reported, never counted.
    """
    voting = [o for o in observations if o.check not in CLAIM_CHECKS]
    moving = [o for o in voting if o.verdict == MOVING]
    still = [o for o in voting if o.verdict == STILL]
    if moving and still:
        return DISPUTED
    if len(still) >= QUORUM:
        return STILL
    if len(moving) >= QUORUM:
        return MOVING
    return INCONCLUSIVE


def evaluate(cfg, target, checks=None):
    """Run the channels and combine them. Returns (verdict, [Observation])."""
    selected = resolve_checks(checks)
    observations = [fn(cfg, target) for fn in selected.values()]
    return combine(observations), observations


# --- reconciliation against a twin claim --------------------------------------------

AGREES = "agrees"
LYING = "lying"
BLIND = "blind"


def reconcile(twin_claims_active, verdict):
    """Compare the twin's claim with what the network says.

    LYING  the twin advertises a live flow that is not moving -- the 2026-08-13 P0.
    BLIND  packets are moving and the twin does not know -- the same defect wearing the
           other face, and free to detect once the machinery exists.
    """
    if verdict in (DISPUTED, INCONCLUSIVE):
        return verdict
    if twin_claims_active and verdict == STILL:
        return LYING
    if not twin_claims_active and verdict == MOVING:
        return BLIND
    return AGREES


# --- CLI ----------------------------------------------------------------------------


def format_report(target, verdict, observations):
    lines = ["%s: %s" % (target.label, verdict.upper())]
    for obs in observations:
        lines.append("  %-9s %-8s %s" % (obs.check, obs.verdict, obs.detail))
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="criteria.py",
        description="Decide whether packets are moving between two hosts, by quorum.")
    sub = parser.add_subparsers(dest="command")

    check = sub.add_parser("check", help="evaluate one host pair")
    check.add_argument("--src-ip", required=True)
    check.add_argument("--dst-ip", required=True)
    check.add_argument("--src-pid", type=int, default=None,
                       help="Mininet host PID for the source namespace (mnexec -a)")
    check.add_argument("--dst-pid", type=int, default=None,
                       help="Mininet host PID for the destination namespace")
    check.add_argument("--checks", default=None,
                       help="comma-separated subset of: " + ",".join(CHECKS))
    check.add_argument("--json", action="store_true")

    sub.add_parser("list-checks", help="print the registered and reserved channels")

    args = parser.parse_args(argv)
    if args.command == "list-checks":
        for name in CHECKS:
            sys.stdout.write("%-12s implemented\n" % name)
        for name in RESERVED_CHECKS:
            sys.stdout.write("%-12s reserved (not implemented)\n" % name)
        return 0
    if args.command != "check":
        parser.print_usage(sys.stderr)
        return 2

    names = None
    if args.checks:
        names = [n.strip() for n in args.checks.split(",") if n.strip()]

    cfg = Config.from_env()
    target = Target(args.src_ip, args.dst_ip, args.src_pid, args.dst_pid)
    try:
        verdict, observations = evaluate(cfg, target, names)
    except (KeyError, NotImplementedError) as exc:
        sys.stderr.write("%s\n" % exc)
        return 2

    if args.json:
        sys.stdout.write(json.dumps({
            "target": target.label,
            "verdict": verdict,
            "observations": [o.as_dict() for o in observations],
        }, indent=2) + "\n")
    else:
        sys.stdout.write(format_report(target, verdict, observations) + "\n")
    return EXIT_CODES[verdict]


if __name__ == "__main__":
    sys.exit(main())
