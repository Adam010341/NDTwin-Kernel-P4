#!/usr/bin/env python3
"""Non-interactive driver for one p4lang/tutorials exercise, on either fabric.

Run it as ONE command from Adam's own terminal (interactive sudo lives there):

    sudo /home/adam/p4dev-python-venv/bin/python
        doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py
        source_routing --which solution

It brings the exercise up exactly the way ``utils/run_exercise.py`` does, then
-- instead of dropping into the Mininet CLI -- runs a scripted set of steps,
compares what came back against the expectations recorded in
``M7-source_routing.md``, prints a pass/fail table and writes a run report.
Nothing is typed by hand and no xterm is spawned.

Why the pieces are shaped the way they are (all read out of the callee sources,
not guessed):

  * ``ExerciseRunner.program_switch_p4runtime`` does ``open(sw_dict['runtime_json'])``
    and passes ``workdir=os.getcwd()`` (run_exercise.py:270-281), and
    ``simple_controller.program_switch`` then resolves the runtime file's own
    "p4info"/"bmv2_json" against that workdir (simple_controller.py:100,118).
    => cwd MUST be the exercise directory, and the compiled artefacts MUST land
    at build/<skeleton name>.json / build/<skeleton name>.p4.p4info.txtpb, which
    is what sX-runtime.json names.  So the solution is compiled *to the
    skeleton's output name*; no .p4 source file is ever edited or copied over.
  * ``ExerciseRunner.run_exercise`` calls ``self.net.stop()`` only after
    ``do_net_cli()`` returns normally (run_exercise.py:207-209).  This driver
    overrides run_exercise() to put net.stop() in a finally.
  * ``send.py``/``receive.py`` carry ``#!/usr/bin/env python3``, which on this
    laptop is conda's 3.13 without scapy.  They are therefore always invoked as
    ``<venv python> <script>``, never executed directly.
  * Writes into ~/tutorials stay inside build/, logs/ and pcaps/.  build/ and
    logs/ are matched by that tree's .gitignore; pcaps/ as a directory is NOT,
    but every file written into it is *.pcap, which is (line 18 of .gitignore),
    so `git status --short` stays unchanged either way.

TWO FABRICS (TICKET-P2 section 5.1).  ``--fabric tutorials`` is everything above
and is the default: the exercise's own Mininet harness, started by this process,
which is why it needs root.  ``--fabric ndtwin`` runs the SAME steps against a
fabric NDTwin brings up from an app package --

    convert.py -> preflight.py -> ndt claim -> ndt up p4 --app -> steps
                                            -> ndt down -> ndt release

-- and needs NO root: `ndt` is designed to be run as the operator with the two
passwordless sudoers grants (ndtwin-lab, mnexec) that tools/test_workflow/
sudo_surface.sh prints.  The steps reach a host through a HostRunner rather than
through ``self.net``, because on that fabric there is no Mininet object in this
process at all: the hosts belong to a Mininet started in a root tmux session and
are entered with ``sudo -n mnexec -a <pid>``, the same seam `ndt`'s own
dataplane_ok uses.

🔴 THE PLAN BLOCK AND THE SUDO LINE OF ``--fabric tutorials`` ARE FROZEN at what
they printed on 2026-09-08, byte for byte, and tests/fixtures/dryrun_*.txt is
the copy they are compared against (test_drive_exercise.py).  The 09-08 run is
the control every later number is read against; a driver whose plan block had
drifted would make "the same command, again" a sentence nobody could check.

Exit status: 0 every expectation met, 1 some expectation failed,
2 pre-flight refusal / exercise not scripted / harness blew up.

[Co-developed with claude code -- Adam]
"""

import argparse
import datetime
import glob
import hashlib
import json as _json
import os
import re
import subprocess
import sys
import time

# ---------------------------------------------------------------- constants --

TUT      = "/home/adam/tutorials"
UTILS    = os.path.join(TUT, "utils")
VENV_PY  = "/home/adam/p4dev-python-venv/bin/python"
SWITCH   = "/usr/local/bin/simple_switch_grpc"   # NOT /usr/local/bmv2-fast; see README section 3
P4C      = "/usr/local/bin/p4c-bm2-ss"
PORT_LO, PORT_HI = 9090, 9099                    # thrift ports the harness hard-codes

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(HERE, "runs")

# The repo this file sits in: doc/audit/<dir>/drive_exercise.py -> three up.
REPO      = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
NDT       = os.path.join(REPO, "tools", "test_workflow", "ndt")
PROXY_PY  = os.path.join(REPO, "p4_proxy", "venv", "bin", "python")
CONVERT   = os.path.join(REPO, "tools", "p4_exercise", "convert.py")
PREFLIGHT = os.path.join(REPO, "tools", "p4_exercise", "preflight.py")
PKG_ROOT  = os.path.join(REPO, ".test_run", "packages")
CLAIM     = os.path.join(REPO, ".test_run", "lab.claim")
#: The P4 host knob. `ndt up p4 --app` writes the package model's host count into it and
#: `ndt release` refuses while it differs from what the round started at (ndt:885-898), so a
#: round that does not put it back ends with the lab still claimed. See ndtwin_teardown().
HOST_KNOB = os.path.join(REPO, "p4_proxy", "mininet", "host_count_override")
PROXY_URL = "http://localhost:8081"

#: `ndt` refuses to run without an owner, and every call this file makes carries
#: the same one (CLAUDE.md: `ndt` 指令都帶 NDT_OWNER).
NDT_OWNER = os.environ.get("NDT_OWNER") or "drive-exercise"

CLAIM_MINUTES = "45"

# topo/prog come from each exercise's Makefile (TOPO / DEFAULT_PROG, defaulting
# through utils/Makefile to topology.json and $(wildcard *.p4)).
#
# `default_prog` is the Makefile's DEFAULT_PROG -- the program the harness passes
# as `-j` and therefore the one every switch that does NOT name its own `program`
# in topology.json runs.  For three of the four it is the exercise's own program;
# for `firewall` it is basic.p4 (exercises/firewall/Makefile:6), and only s1 runs
# firewall.json (pod-topo/topology.json's per-switch "program").  It is also the
# stem convert.py's --p4 must name, because a package whose default pipeline were
# firewall would hand s2-s4 a p4info their sX-runtime.json entries were not
# written against, which pre-flight refuses by design (TICKET-P2 section 3.5).
EXERCISES = {
    "source_routing": {
        "topo": "topology.json",
        "prog": "source_routing.p4",
        "default_prog": "source_routing.p4",
        "hosts": 3, "switches": 3,
        # 🔴 NO GENERIC CELL HERE. solution/source_routing.p4:127-138 is
        # `if (hdr.srcRoutes[0].isValid()) { ... } else { drop(); }` -- the SOLUTION drops
        # every frame that does not carry the 0x1234 source-route stack, which is why
        # audit-raw 7af2f352 measured this exercise with send.py/receive.py and a ttl rather
        # than with a ping (TICKET-P2 §7-10 says the same). An iperf between two hosts here
        # moves nothing, so "link usage follows the iperf path" has no path to follow.
        "link_usage": False,
        "link_usage_why": ("solution/source_routing.p4:127-138 drops every frame without a "
                           "0x1234 source-route stack, so an iperf crosses nothing"),
        "plan_steps": ("h2 receive.py; h1 send.py 10.0.2.2 with '2 3 2 2 1' then '2 1'; "
                       "assert packet count + ttl"),
    },
    "basic": {
        "topo": "pod-topo/topology.json",   # exercises/basic/Makefile:5
        "prog": "basic.p4",                 # utils/Makefile:21 wildcard *.p4
        "default_prog": "basic.p4",
        "hosts": 4, "switches": 4,
        "plan_steps": "net.pingAll; h1 ping -c3 h2; h1 send.py -> h2 receive.py; assert loss",
    },
    "firewall": {
        "topo": "pod-topo/topology.json",   # exercises/firewall/Makefile:5
        "prog": "firewall.p4",
        "default_prog": "basic.p4",         # exercises/firewall/Makefile:6
        "hosts": 4, "switches": 4,
        "plan_steps": "iperf h1->h3 (both arms); iperf h3->h1 (skeleton connects, solution does not)",
    },
    "link_monitor": {
        "topo": "pod-topo/topology.json",   # exercises/link_monitor/Makefile:5
        "prog": "link_monitor.p4",
        "default_prog": "link_monitor.p4",  # no DEFAULT_PROG -> utils/Makefile:21 wildcard
        "hosts": 4, "switches": 4,
        "plan_steps": "h1 receive.py + h1 send.py probes; assert swid and port fields",
    },
    # ---------------------------------------------------------------------------------
    # TICKET-P3 §2.7, the other NINE. Everything above this line shipped on 2026-09-08 and
    # 2026-09-18 and its plan block is FROZEN; everything below is new and has never been
    # run on either fabric by the session that wrote it.
    #
    # `topo` and `default_prog` were read out of each exercise's own Makefile and
    # utils/Makefile:13-23 (TOPO defaults to topology.json, DEFAULT_PROG to the wildcard
    # *.p4 in the exercise directory, which never matches solution/). NONE of the nine sets
    # DEFAULT_PROG, and only `multicast` sets TOPO -- so every `default_prog` below is the
    # exercise's own single program, and `companion_programs` returns [] for all nine.
    #
    # Three optional keys appear here and nowhere above:
    #   `red_arm`     how the SKELETON is red when it is not red in the data plane:
    #                 "compile"  -- p4c refuses it (flowcache; TICKET-P3 §2.7)
    #                 "entries"  -- it compiles, and the runtime json the harness installs
    #                               names a table it does not declare (basic_tunnel)
    #   `controller`  the exercise's own external controller, relative to the exercise dir.
    #                 The skeleton arm runs that path and the solution arm runs
    #                 solution/<basename>, which is how live-p1/03 already drives p4runtime.
    #   `needs`       a property of the FABRIC this exercise's expectations depend on, named
    #                 so a red run can be read. "shaped_links" is TICKET-P3 §2.4's G2-C.
    "basic_tunnel": {
        "topo": "topology.json",
        "prog": "basic_tunnel.p4",
        "default_prog": "basic_tunnel.p4",
        "hosts": 3, "switches": 3,
        # 🔴 THE SKELETON DOES NOT REACH THE DATA PLANE. README:41-43 says so itself: "Since
        # the control plane tries to access the myTunnel_exact table, and that table does not
        # yet exist, the `make run` command will not work with the starter code." It COMPILES;
        # what fails is installing sX-runtime.json's six entries, three of which name
        # MyIngress.myTunnel_exact. So the red arm is "the entries do not go in", and a run
        # in which they DID go in is the finding.
        "red_arm": "entries",
        "plan_steps": ("h2/h3 receive.py; h1 send.py 10.0.2.2 --dst_id 2 then --dst_id 3; "
                       "assert which host the tunnel delivered to"),
    },
    "calc": {
        "topo": "topology.json",
        "prog": "calc.p4",
        "default_prog": "calc.p4",
        "hosts": 2, "switches": 1,
        # 🔴 NO GENERIC CELL HERE either, and for the same shape: calc.p4:205-210 is
        # `if (hdr.p4calc.isValid()) { calculate.apply(); } else { operation_drop(); }`. The
        # switch handles the 0x1234 calculator protocol and drops everything else, so an
        # iperf between h1 and h2 moves nothing whichever arm is running.
        "link_usage": False,
        "link_usage_why": ("calc.p4:205-210 drops everything that is not the 0x1234 "
                           "calculator protocol, so an iperf crosses nothing"),
        "plan_steps": "h1 calc.py <<< '1+1'; assert the answer line (solution 2, skeleton no response)",
    },
    "ecn": {
        "topo": "topology.json",
        "prog": "ecn.p4",
        "default_prog": "ecn.p4",
        "hosts": 5, "switches": 3,
        # topology.json:65-69 is `[ "s1-p3", "s2-p3", "0", 0.5 ]` -- a 0.5 Mbit/s bottleneck.
        # Without it enq_qdepth never reaches ECN_THRESHOLD (ecn.p4:9, 10) and the SOLUTION
        # arm cannot show 0x3 however correct it is.
        "needs": "shaped_links",
        "plan_steps": ("h22 iperf -s; h11 iperf -u -> h22 to fill the 0.5 Mbit/s queue; "
                       "h1 send.py -> h2 receive.py; assert ipv4.tos"),
    },
    "mri": {
        "topo": "topology.json",
        "prog": "mri.p4",
        "default_prog": "mri.p4",
        "hosts": 5, "switches": 3,
        # The same throttled link as ecn, but MRI's assertion is the hop COUNT and the swids,
        # which do not need a queue -- only qdepth would, and nothing below reads it.
        "plan_steps": ("h11 iperf -u -> h22 beside it; h1 send.py -> h2 receive.py; "
                       "assert the MRI count and swids"),
    },
    "flowcache": {
        "topo": "topology.json",
        "prog": "flowcache.p4",
        "default_prog": "flowcache.p4",
        "hosts": 3, "switches": 3,
        # 🔴 THE SKELETON DOES NOT COMPILE, BY DESIGN. flowcache.p4:83-91 declares
        # packet_out_header_h and packet_in_header_h with NO fields and the body then reads
        # hdr.packet_out.opcode (:232) and hdr.packet_in.input_port (:269); README:29 states
        # it: "you need to define the fields in the packet_in and packet_out headers;
        # otherwise, you'll get compilation errors." A compile that SUCCEEDS is the finding.
        "red_arm": "compile",
        "controller": "mycontroller.py",
        "plan_steps": "run the exercise's controller; h1 ping h2/h3; assert ICMP replies",
    },
    "load_balance": {
        "topo": "topology.json",
        "prog": "load_balance.p4",
        "default_prog": "load_balance.p4",
        "hosts": 3, "switches": 3,
        # 🔴 NO GENERIC CELL HERE (judge A3). s1-runtime.json:6-25 gives ecmp_group ONE lpm
        # entry -- 10.0.0.1/32, the load-balanced service address -- and a default action of
        # drop. An iperf from h1 to any real host address is dropped at s1, so the on-path set
        # would be empty and the cell would refuse: correctly, and about the wrong thing.
        # Sending to 10.0.0.1 instead does not rescue it either -- the reply path from h2/h3
        # goes through s2/s3, whose own tables carry the same single entry.
        "link_usage": False,
        "link_usage_why": ("s1-runtime.json:6-25 forwards only 10.0.0.1/32 and drops the rest, "
                           "so an iperf between two real host addresses crosses nothing"),
        "plan_steps": ("h2 and h3 receive.py; h1 send.py 10.0.0.1 x10; "
                       "assert both servers got some (solution) / only h2 did (skeleton)"),
    },
    "multicast": {
        "topo": "sig-topo/topology.json",   # exercises/multicast/Makefile:5
        "prog": "multicast.p4",
        "default_prog": "multicast.p4",
        "hosts": 4, "switches": 1,
        # exercises/multicast/disable_ipv6.sh is `sysctl -w net.ipv6.conf.{all,default}.
        # disable_ipv6=1`. It is run INSIDE each host namespace here rather than on the box:
        # the script as shipped would turn IPv6 off for the whole machine, which is not this
        # driver's to do, and what it is for is the IPv6 multicast noise inside the fabric.
        "disable_ipv6": True,
        # 🔴 THE GENERIC CELL RUNS TO h3, NOT TO THE MODEL'S LAST HOST. h4 is the one host
        # sig-topo/s1-runtime.json:47-65 deliberately does not replicate to (README:122 is
        # the student's TODO to add it), so a flow to h4 would produce an EMPTY on-path set
        # and the cell would refuse -- correctly, and about the wrong thing.
        "link_usage": "h3",
        "plan_steps": ("disable IPv6 in each host; pingall; assert h1/h2/h3 reach each other "
                       "and nobody reaches h4 (sig-topo's group is ports 1,2,3)"),
    },
    "p4runtime": {
        "topo": "topology.json",
        "prog": "advanced_tunnel.p4",
        "default_prog": "advanced_tunnel.p4",
        "hosts": 3, "switches": 3,
        # 🔴 The .p4 has no TODO at all and there is NO solution/*.p4: the exercise is the
        # CONTROLLER, and the skeleton's gap is the transit rule (mycontroller.py:76 prints
        # "TODO Install transit tunnel rule"). Both arms therefore compile the SAME program,
        # which is what `variant: controller` says -- without it pick_source finds nothing to
        # compile for the solution arm and the round stops before it starts.
        # exercises/flowcache is the control: it ships solution/flowcache.p4 as well.
        "variant": "controller",
        "controller": "mycontroller.py",
        # 🔴 AND THE GENERIC CELL RUNS TO h2. The controller wires ONE tunnel, h1 <-> h2
        # (mycontroller.py:172-178), and never contacts s3 at all -- so h3, which is the
        # model's last host, is unreachable by design on this fabric.
        "link_usage": "h2",
        "plan_steps": "run the exercise's controller; h1 ping h2; assert the transit rule and the ping",
    },
    "qos": {
        "topo": "topology.json",
        "prog": "qos.p4",
        "default_prog": "qos.p4",
        "hosts": 5, "switches": 3,
        # 🔴 qos's topology.json has NO throttled link (unlike ecn's and mri's, whose
        # :65-69 carries `"0", 0.5`), so this exercise does not need G2-C.
        "plan_steps": ("h2 receive.py; h1 send.py --p=UDP then --p=TCP; "
                       "assert ipv4.tos (solution 0xb9 / 0xb1, skeleton 0x1)"),
    },
}

# Evidence grades, verbatim from M7-source_routing.md so the two can be compared
# line by line.  They grade the EXPECTATION's provenance, not the result.
G_SRC    = "【源碼推導，未執行】"
G_README = "【README 宣稱】"
G_BOTH   = "【README 宣稱】＋【源碼推導，未執行】"

RECV_WARMUP  = 3.0    # s to let receive.py get its sniff socket up
DRAIN_WAIT   = 3.0    # s to let the last packet reach the sniffer
SEND_TIMEOUT = 60     # s
IPERF_SECONDS = 3     # `iperf -c ... -t 3`, the README's own flow length
IPERF_TIMEOUT = 25    # s of wall clock before a client that never connected is killed
IPERF_WARMUP = 1.0    # s to let `iperf -s` bind before the client is started
PROBE_SECONDS = 8     # s of link_monitor send.py, which emits one probe per second
SEND_SECONDS = 6      # s of the ecn/mri/qos senders, whose argv carries a packet count
BG_SECONDS = 20       # s of the ecn/mri background iperf -u (must outlast SEND_SECONDS)
CTRL_SETTLE = 12      # s to let an exercise's own controller push its pipeline and rules
CTRL_PY = VENV_PY     # the only interpreter with grpc + the tutorials' p4runtime_lib

#: live-p1/_common.sh, whose link_usage_round IS the generic cell (TICKET-P3 §2.7).
#: 🔴 NOT A SECOND COPY OF THE RULE. live-p1/05 runs the same function three times and this
#: driver runs it once per exercise; a Python re-implementation here would make "the same cell
#: over thirteen exercises" a comparison between two instruments that were meant to agree.
LIVE_COMMON = os.path.join(HERE, "live-p1", "_common.sh")

#: The telemetry knob (TICKET-P3 §2.1). `ndt up p4 --telemetry <word>` writes it and `ndt down`
#: does not put it back, so a round that moved it restores it itself -- the same discipline
#: HOST_KNOB gets, and for the same reason: it decides the NEXT bring-up.
TELEMETRY_KNOB = os.path.join(REPO, "p4_proxy", "mininet", "telemetry_override")
TELEMETRY_WORDS = ("auto", "none", "cooperative", "link")

# -------------------------------------------------------------------- output --


class Tee(object):
    """Mirror a stream into a buffer so the run report carries the transcript.

    Installed on sys.stdout AND sys.stderr *before* mininet is imported: mininet's
    logger is a logging.StreamHandler built with no stream, so it binds whatever
    sys.stderr is at import time (mininet/log.py) and everything mininet prints --
    including pingAll's per-host output, which is at level OUTPUT=25 -- goes there.
    """

    def __init__(self, real):
        self.real = real
        self.buf = []

    def write(self, s):
        self.real.write(s)
        self.buf.append(s)
        return len(s)

    def flush(self):
        self.real.flush()

    def isatty(self):
        return False

    def fileno(self):
        return self.real.fileno()

    def text(self):
        return "".join(self.buf)


TEE_OUT = None
TEE_ERR = None


def transcript():
    out = TEE_OUT.text() if TEE_OUT else ""
    err = TEE_ERR.text() if TEE_ERR else ""
    return out, err


def say(*parts):
    print(" ".join(str(p) for p in parts))
    sys.stdout.flush()


def rule(title):
    say("")
    say("== %s %s" % (title, "=" * max(0, 68 - len(title))))


# ------------------------------------------------------------------ helpers --


def sha16(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def run(cmd, cwd=None, timeout=300, env=None):
    """Run a command, capture everything, never raise on non-zero."""
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout, env=env)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def ndt_env():
    """The environment every `ndt` call is made in: this run's NDT_OWNER."""
    env = dict(os.environ)
    env["NDT_OWNER"] = NDT_OWNER
    return env


def local_popen(argv, **kw):
    """A process started on THIS machine rather than inside a host namespace.

    The only user is the exercise's own external controller (`p4runtime`, `flowcache`): it is
    a gRPC client of the switches' control ports, which are reachable from here, and it must
    NOT be entered into a host's netns. A named seam rather than a bare subprocess.Popen so
    the offline suite can drive that arm at all -- and so this file has exactly one place
    where a process is started outside a HostRunner.
    """
    return subprocess.Popen(argv, **kw)


def trim(text, cap=6000):
    if text is None:
        return "(none)"
    if len(text) <= cap:
        return text
    return text[:cap] + "\n... [trimmed; %d chars total]" % len(text)


def euid():
    """Who this process is.  A seam, so the refusals that turn on it have tests."""
    return os.geteuid()


def host_key(name):
    m = re.match(r"^h(\d+)$", name or "")
    return (0, int(m.group(1))) if m else (1, 0)


def host_addresses(exdir, spec):
    """{h1: '10.0.1.1', ...} out of the exercise's own topology.json.

    The same file both fabrics are built from: `ndt up p4 --app` builds the
    package's ndtwin/topology.json, which convert.py derives from this one, so a
    step that names an address by reading it here names the same host on either.
    """
    with open(os.path.join(exdir, spec["topo"])) as f:
        topo = _json.load(f)
    out = {}
    for name, h in (topo.get("hosts") or {}).items():
        out[name] = str(h.get("ip", "")).split("/")[0]
    return out


class Expect(object):
    """One expectation, carrying the evidence grade it inherits from M7."""

    def __init__(self, name, want, got, ok, grade, note=""):
        self.name, self.want, self.got = name, want, got
        self.ok, self.grade, self.note = bool(ok), grade, note

    def line(self):
        return "%-4s %-46s want=%-22s got=%s" % (
            "PASS" if self.ok else "FAIL", self.name, self.want, self.got)


# ----------------------------------------------------------------- preflight --


def listeners_in_range(lo, hi):
    """Return [(port, raw ss line)] for LISTEN sockets in [lo,hi]."""
    try:
        rc, out = run(["ss", "-ltnpH"])
        if rc != 0:
            rc, out = run(["ss", "-ltnH"])
    except (OSError, subprocess.TimeoutExpired) as e:       # noqa: BLE001
        say("?? could not run ss (%r) -- port check inconclusive" % (e,))
        return []
    hits = []
    for line in out.splitlines():
        cols = line.split()
        if len(cols) < 4:
            continue
        addr = cols[3]
        m = re.search(r"[:.](\d+)$", addr)
        if not m:
            continue
        port = int(m.group(1))
        if lo <= port <= hi:
            hits.append((port, line.strip()))
    return hits


def pid_identity(pid):
    try:
        with open("/proc/%s/cmdline" % pid, "rb") as f:
            cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
    except OSError:
        cmd = "?"
    try:
        cwd = os.readlink("/proc/%s/cwd" % pid)
    except OSError:
        cwd = "?"
    return cmd, cwd


def claim_fields(path=CLAIM):
    """owner/expires/measuring out of .test_run/lab.claim, or {}."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                if "=" in line:
                    k, v = line.split("=", 1)
                    out.setdefault(k.strip(), v.strip())
    except OSError:
        return {}
    return out


def lab_is_free(fields, now=None):
    """(ok, why) for the two fields _common.sh's require_free_lab reads.

    🔴 BOTH FIELDS, NOT ONE.  `measuring=` is the only channel a session has for
    "you cannot see what I am running from the process table" (ROLE-4 T2d), and a
    claim can be held with nothing declared -- so a live claim somebody else holds
    refuses, and a live claim of ours that DECLARES a measurement refuses too.
    An expired claim is not a claim.
    """
    now = int(time.time()) if now is None else now
    exp = fields.get("expires", "")
    if not re.match(r"^\d+$", exp or "") or int(exp) <= now:
        return True, ""
    owner = fields.get("owner", "")
    if owner != NDT_OWNER:
        return False, ("the lab is claimed by '%s' until %s (measuring=%s)"
                       % (owner, exp, fields.get("measuring", "") or "nothing"))
    if fields.get("measuring"):
        return False, ("the live claim DECLARES a measurement in progress: measuring=%s"
                       % fields["measuring"])
    return True, ""


def preflight(ex, which, exdir, fabric="tutorials"):
    """Read-only checks.  Returns (ok, notes[], env).  Kills nothing, changes nothing."""
    notes = []
    ok = True

    rule("pre-flight (read-only)")

    # 1. thrift ports.  utils/p4runtime_switch.py:20 hard-codes next_thrift_port=9090
    #    and there is no CLI flag in run_exercise.py to move it.
    #
    #    🔴 NOT ASKED ON THE NDTWIN FABRIC, and not because it is inconvenient: that
    #    fabric's switches are started by `ndt up p4` on 9091-9100 (tools/test_workflow/
    #    ports.sh), so 9090-9099 says nothing about whether it can come up, while the
    #    question that DOES decide it -- is the lab free -- is not asked by this list.
    if fabric == "tutorials":
        hits = listeners_in_range(PORT_LO, PORT_HI)
        if hits:
            ok = False
            say("!! FAIL  ports %d-%d: %d listener(s) -- s1 will not bind its thrift port"
                % (PORT_LO, PORT_HI, len(hits)))
            for port, line in hits:
                say("         %s" % line)
                for pid in re.findall(r"pid=(\d+)", line):
                    cmd, cwd = pid_identity(pid)
                    say("         pid=%s  cmdline: %s  cwd: %s" % (pid, cmd, cwd))
                    notes.append("port %d held by pid %s (%s, cwd %s)" % (port, pid, cmd, cwd))
            say("         -> close it yourself; this driver never kills a process.")
        else:
            say("OK   ports %d-%d free" % (PORT_LO, PORT_HI))
    else:
        fields = claim_fields()
        free, why = lab_is_free(fields)
        if not free:
            ok = False
            say("!! FAIL  %s" % why)
            say("         -> wait for it, or take the lab over deliberately -- not from here.")
            notes.append(why)
        else:
            say("OK   lab is free (claim: owner=%s expires=%s measuring=%s)"
                % (fields.get("owner", "-"), fields.get("expires", "-"),
                   fields.get("measuring", "") or "nothing"))

    # 2. interpreter.  run_exercise.py imports mininet.* and p4runtime_lib at
    #    module level; only the p4dev venv has mininet+grpc+scapy together.
    #
    #    On the ndtwin fabric nothing is imported from there -- the fabric is brought
    #    up by `ndt`, in another process -- but send.py/receive.py still run under
    #    that interpreter inside the host namespace, so it has to EXIST.
    real = os.path.realpath(sys.executable)
    if fabric == "tutorials":
        if real != os.path.realpath(VENV_PY):
            ok = False
            say("!! FAIL interpreter is %s" % sys.executable)
            say("         must be %s (the only one with mininet+grpc+scapy)" % VENV_PY)
            notes.append("wrong interpreter: %s" % sys.executable)
        else:
            say("OK   interpreter %s (%s)" % (sys.executable, sys.version.split()[0]))
    else:
        if not os.path.exists(VENV_PY):
            ok = False
            say("!! FAIL no %s -- send.py/receive.py have no interpreter with scapy" % VENV_PY)
            notes.append("missing %s" % VENV_PY)
        else:
            say("OK   host scripts will run under %s" % VENV_PY)
        for tool in (NDT, CONVERT, PREFLIGHT, PROXY_PY):
            if not os.path.exists(tool):
                ok = False
                say("!! FAIL missing %s" % tool)
                notes.append("missing %s" % tool)
        say("OK   ndt %s, converter %s, pre-flight %s" % (NDT, CONVERT, PREFLIGHT))

    # 3. bmv2 target.  Version strings do not distinguish the two builds on this
    #    box; only the sha does (README section 3).
    #
    #    🔴 On the ndtwin fabric this driver does NOT choose the switch binary:
    #    `ndt up p4` does, through p4_proxy/mininet/bmv2_binary_override, and the
    #    `ndt status` capture in the report is where that identity is.  Printing
    #    /usr/local/bin's sha there would name a binary this run never started.
    if fabric == "tutorials":
        if not os.path.exists(SWITCH):
            ok = False
            say("!! FAIL switch binary missing: %s" % SWITCH)
            notes.append("missing %s" % SWITCH)
            sw_sha = sw_ver = "-"
        else:
            sw_sha = sha16(SWITCH)
            _, sw_ver = run([SWITCH, "--version"])
            sw_ver = sw_ver.strip().splitlines()[0] if sw_ver.strip() else "?"
            say("OK   switch  %s  sha256[:16]=%s  --version=%s" % (SWITCH, sw_sha, sw_ver))
    else:
        sw_sha = "-"
        sw_ver = "n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture"
        say("--   switch  %s" % sw_ver)

    if not os.path.exists(P4C):
        ok = False
        say("!! FAIL compiler missing: %s" % P4C)
        notes.append("missing %s" % P4C)
        p4c_sha = p4c_ver = "-"
    else:
        p4c_sha = sha16(P4C)
        _, p4c_ver = run([P4C, "--version"])
        lines = [l for l in p4c_ver.strip().splitlines() if l.strip()]
        # --version prints the program name first and the version on line 2
        p4c_ver = lines[1] if len(lines) > 1 else (lines[0] if lines else "?")
        say("OK   p4c     %s  sha256[:16]=%s  --version=%s" % (P4C, p4c_sha, p4c_ver))

    # 4. exercise directory
    if not os.path.isdir(exdir):
        ok = False
        say("!! FAIL no such exercise directory: %s" % exdir)
        notes.append("missing exercise dir %s" % exdir)
    else:
        say("OK   exercise dir %s" % exdir)

    env = {"switch_sha": sw_sha, "switch_ver": sw_ver,
           "p4c_sha": p4c_sha, "p4c_ver": p4c_ver}
    return ok, notes, env


# ------------------------------------------------------------------- compile --


def pick_source(exdir, spec, which):
    """Return (source .p4 path, output basename) for the requested variant.

    🔴 ONE EXERCISE'S VARIANT IS NOT ITS PROGRAM. exercises/p4runtime ships
    solution/mycontroller.py and NO solution/*.p4: advanced_tunnel.p4 has no TODO in it,
    the exercise IS the controller, and both arms run the same pipeline. Without
    spec["variant"] == "controller" this function returns None there and `main()` stops
    with "no .p4 source for p4runtime/solution" -- measured 2026-09-19 by reading the real
    tree, before the orchestrator's live round rather than during it.

    The flag is explicit rather than "fall back to the skeleton when solution/ has no .p4",
    because for every other exercise a missing solution/*.p4 IS the error this returns None
    for. exercises/flowcache is the control: it has BOTH solution/flowcache.p4 and
    solution/mycontroller.py, so its two arms differ in the program as well.
    """
    base = spec["prog"][:-3]                       # what sX-runtime.json names
    if which == "skeleton" or spec.get("variant") == "controller":
        return os.path.join(exdir, spec["prog"]), base
    cands = sorted(glob.glob(os.path.join(exdir, "solution", "*.p4")))
    for c in cands:
        if os.path.basename(c) == spec["prog"]:
            return c, base
    if cands:
        return cands[0], base
    return None, base


def compile_prog(exdir, src, base):
    """p4c-bm2-ss the chosen program to the SKELETON's output names."""
    build = os.path.join(exdir, "build")
    for d in (build, os.path.join(exdir, "logs"), os.path.join(exdir, "pcaps")):
        if not os.path.isdir(d):
            os.makedirs(d)
    json_out = os.path.join(build, base + ".json")
    p4info   = os.path.join(build, base + ".p4.p4info.txtpb")
    cmd = [P4C, "--p4v", "16", "--p4runtime-files", p4info, "-o", json_out, src]
    rule("compile")
    say("$ " + " ".join(cmd))
    rc, out = run(cmd, cwd=exdir)
    if out.strip():
        say(out.rstrip())
    warns = len(re.findall(r"\[--Wwarn=", out))
    if rc != 0 or not os.path.exists(json_out):
        say("!! compile FAILED rc=%d" % rc)
        return rc, None, {"cmd": " ".join(cmd), "rc": rc, "out": out, "warnings": warns}
    size = os.path.getsize(json_out)
    jsha = sha16(json_out)
    say("-> %s  %d B  sha256[:16]=%s  warnings=%d" % (json_out, size, jsha, warns))
    return 0, json_out, {"cmd": " ".join(cmd), "rc": rc, "out": out, "warnings": warns,
                         "json": json_out, "bytes": size, "sha": jsha,
                         "p4info": p4info, "src": src}


def companion_programs(exdir, spec, which):
    """The OTHER programs this exercise's topology needs compiled, as (src, base).

    `make build` compiles every *.p4 in the exercise directory (utils/Makefile:17-18
    and :43),
    not just the one `-j` names, and exercises/firewall is the shipped case where
    that matters: pod-topo/topology.json gives s1 `build/firewall.json` and leaves
    s2-s4 on DEFAULT_PROG=basic.p4.  A run that compiled only the variant would
    start three switches on a json that is not there.

    The companion is always the SKELETON copy: solution/ carries one file, the
    exercise's own program, and the variant is what `which` already selected.
    """
    want = {spec["prog"], spec["default_prog"]}
    out = []
    for name in sorted(want - {spec["prog"]}):
        src = os.path.join(exdir, name)
        out.append((src, name[:-3]))
    return out


# ------------------------------------------------------------- host runners --


class HostNotFound(Exception):
    """A host the steps asked for has no namespace on this fabric."""


class PingResult(object):
    """One ping, as ping's OWN summary line says it went, or UNTESTED."""

    def __init__(self, loss, received, transmitted, why="", raw=""):
        self.loss, self.received, self.transmitted = loss, received, transmitted
        self.why, self.raw = why, raw

    @property
    def tested(self):
        return self.loss is not None

    def label(self):
        if not self.tested:
            return "UNTESTED (%s)" % (self.why or "no reason recorded")
        return "%g%% loss, %s/%s received" % (self.loss, self.received, self.transmitted)


class PingAll(object):
    """Every ordered host pair, and the ONE number acceptance is written in.

    🔴 `loss` IS None WHEN ANY PAIR WAS UNTESTED, never 0.  A pair whose ping
    printed no summary line did not run, and an unparsed reading rendered as a
    good one is the failure mode _common.sh's ping_loss was written against.
    """

    def __init__(self):
        self.pairs = self.zero = self.lossy = self.untested = 0
        self.sent = self.received = 0
        self.lines = []
        #: (src, dst) -> PingResult, kept because `multicast` is the one exercise whose
        #: expectation is NOT the aggregate: its solution reaches h1/h2/h3 and must NOT reach
        #: h4 (sig-topo/s1-runtime.json:47-65 replicates ports 1,2,3 and the fourth is the
        #: student's TODO), so an aggregate loss number is a reading no arm can be written on.
        self.results = {}

    def add(self, src, dst, dst_ip, r):
        self.pairs += 1
        self.results[(src, dst)] = r
        if not r.tested:
            self.untested += 1
            self.lines.append("%s -> %s (%s): %s" % (src, dst, dst_ip, r.label()))
            return
        self.sent += r.transmitted
        self.received += r.received
        if r.loss == 0:
            self.zero += 1
        else:
            self.lossy += 1
            self.lines.append("%s -> %s (%s): %s" % (src, dst, dst_ip, r.label()))

    @property
    def loss(self):
        if self.untested or not self.sent:
            return None
        return round(100.0 * (self.sent - self.received) / self.sent, 1)

    def label(self):
        if self.loss is None:
            return ("UNTESTED (%d of %d pairs produced no summary line)"
                    % (self.untested, self.pairs))
        return "%g%% (%d/%d pairs at 0%%, %d lossy)" % (
            self.loss, self.zero, self.pairs, self.lossy)


class HostRunner(object):
    """How a step reaches a host.  The steps never touch a fabric directly.

    Three verbs, and they are the three the steps use: `popen` for a process the
    step keeps a handle on (a sniffer, a sender, an iperf server), `cmd` for one
    line whose output it wants, and `pingall` for the acceptance measurement.
    Subclasses supply the first two; `ping`/`pingall` are HERE, once, so the loss
    number is parsed out of ping's own summary line by the same code on both
    fabrics -- otherwise the tutorials arm and the NDTwin arm would be two
    instruments and every comparison between them a claim about neither.
    """

    def __init__(self, ips, cwd=None):
        self.ips = dict(ips)
        self.cwd = cwd

    def names(self):
        return sorted(self.ips, key=host_key)

    def describe(self):
        return "hosts: " + ", ".join("%s=%s" % (n, self.ips[n]) for n in self.names())

    def popen(self, host, argv, **kw):
        raise NotImplementedError

    def cmd(self, host, line):
        raise NotImplementedError

    # -- the loss measurement, shared ------------------------------------------
    #
    # -c 5 and -W 2, the same as live-p1/_common.sh's ping_loss and deliberately
    # NOT `ndt`'s dataplane_ok (-c 2, rc 0 = "at least one of two replies"): both
    # acceptance conditions here are about a RATE, and a two-packet sample cannot
    # tell 0% from 50%.
    def ping(self, host, dst, count=5):
        try:
            out = self.cmd(host, "LANG=C ping -c %d -W 2 %s" % (count, dst))
        except HostNotFound as e:
            return PingResult(None, 0, 0, why=str(e))
        m = re.search(r"([0-9]+(?:\.[0-9]+)?)% packet loss", out)
        if not m:
            return PingResult(None, 0, 0,
                              why="ping printed no '%% packet loss' summary for %s -> %s"
                                  % (host, dst),
                              raw=out)
        t = re.search(r"(\d+) packets transmitted, (\d+) received", out)
        trans = int(t.group(1)) if t else 0
        recv = int(t.group(2)) if t else 0
        return PingResult(float(m.group(1)), recv, trans, raw=out)

    def flush_arp(self):
        """Empty every host's ARP cache. Returns the hosts it actually flushed.

        🔴 A CACHED MAC MAKES AN UNREACHABLE HOST REACHABLE (round-3 ruling 5). multicast's
        expectation is that hX -> h4 is 100% because the ARP request for h4 floods to ports
        1,2,3 and h4 never sees it -- but that is a statement about a host that has NOT already
        learned h4's MAC. Once h4 has sent its own ARP (which IS answered, because the group
        reaches h1/h2/h3 and their unicast replies hit h4's mac_forward entry), h1-h3 hold h4's
        MAC and a later hX -> h4 ping is a plain unicast that h4's own entry forwards: 0% loss,
        on a fabric that has not changed at all.

        So the measurement only means what it says from a known cache state, and this is how it
        is put into one. `ip neigh flush all` is a read-modify of the host's own namespace and
        needs no lab claim.
        """
        done = []
        for name in self.names():
            try:
                self.cmd(name, "ip neigh flush all")
                done.append(name)
            except Exception:                                # noqa: BLE001
                pass
        return done

    def pingall(self, count=5):
        """Every ordered pair, SRC-MAJOR: h1->h2, h1->h3, ..., h4->h1, h4->h2, h4->h3.

        🔴 THE ORDER IS LOAD-BEARING FOR multicast AND IS PINNED BY A TEST
        (`TheMulticastArms.test_the_pingall_order_is_src_major`). With h4 last as a SOURCE,
        every hX -> h4 pair is measured before h4 has ever ARPed, which is the only state in
        which "h4 is unreachable" is observable. A dst-major walk would measure h1 -> h4 after
        h4 -> h1 had already taught h1 h4's MAC, and the expectation would invert.
        """
        pa = PingAll()
        for src in self.names():
            for dst in self.names():
                if src == dst:
                    continue
                pa.add(src, dst, self.ips[dst], self.ping(src, self.ips[dst], count))
        return pa


class MininetHosts(HostRunner):
    """The tutorials fabric: the Mininet this process started."""

    def __init__(self, net, ips, cwd=None):
        HostRunner.__init__(self, ips, cwd)
        self.net = net

    def popen(self, host, argv, **kw):
        return self.net.get(host).popen(argv, **kw)

    def cmd(self, host, line):
        return self.net.get(host).cmd(line)

    def native_pingall(self, timeout=1):
        """mininet's own pingAll, RECORDED beside the -c 5 measurement.

        Kept because the 2026-09-08 rows (audit-raw 7af2f352) are this number and
        the two have to be reconcilable; it is not what anything asserts, because
        it sends one packet per pair and cannot express a rate.
        """
        return self.net.pingAll(timeout=timeout)


class NdtwinHosts(HostRunner):
    """The NDTwin fabric: hosts in a Mininet started by `ndt up p4`, elsewhere.

    🔴 `sudo -n mnexec -a <pid>`, and the pid comes from the process table's TAIL
    FIELD -- `ndt`'s own host_pid rule (ndt:4492-4499): Mininet tags each host's
    namespace process `mininet:hN` as the LAST word of its argv, and a process
    that merely mentions that string somewhere else is a different process.  A
    host whose pid cannot be found is a NAMED FAILURE and never a zero: "no
    namespace" rendered as 100% loss would be a claim about forwarding made by a
    step that never sent a packet.  Nothing here uses pgrep or pkill.
    """

    def __init__(self, ips, cwd=None, runner=None, popen_factory=None):
        HostRunner.__init__(self, ips, cwd)
        self._run = runner or run
        self._popen = popen_factory or subprocess.Popen
        self._pids = {}

    def host_pid(self, host):
        if host in self._pids:
            return self._pids[host]
        rc, out = self._run(["ps", "-eo", "pid=,args="], timeout=30)
        tag = "mininet:%s" % host
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[-1] == tag and parts[0].isdigit():
                self._pids[host] = parts[0]
                return parts[0]
        raise HostNotFound(
            "no namespace for %s: no process in `ps -eo pid=,args=` ends in %r" % (host, tag))

    def mnexec(self, host, argv):
        return ["sudo", "-n", "mnexec", "-a", str(self.host_pid(host))] + list(argv)

    def popen(self, host, argv, **kw):
        kw.setdefault("cwd", self.cwd)
        return self._popen(self.mnexec(host, argv), **kw)

    def cmd(self, host, line):
        rc, out = self._run(self.mnexec(host, ["sh", "-c", line]),
                            cwd=self.cwd, timeout=120)
        return out


# ---------------------------------------------------------- scripted drivers --


class Steps(object):
    """The scripted steps, written against a HostRunner and nothing else.

    Same object on both fabrics: `--fabric tutorials` hands it MininetHosts and
    `--fabric ndtwin` hands it NdtwinHosts, so "the exercise behaves the same on
    NDTwin" is a comparison of one script's output against itself rather than of
    two scripts that were meant to agree.
    """

    def __init__(self, hosts, exercise, which, exdir, log_dir, args, ips=None,
                 fabric="tutorials", package=None):
        self.h = hosts
        self.exercise, self.which = exercise, which
        self.exdir, self.log_dir, self.args = exdir, log_dir, args
        self.ips = ips if ips is not None else hosts.ips
        self.expects = []
        self.steps = []          # (label, command-string, raw-output)
        #: Which fabric these steps are running on, and the package directory when that is
        #: `ndtwin`. Only the two external-controller exercises read them: the exercise's own
        #: controller has 127.0.0.1:5005N and device_id N-1 written into it, which is the
        #: truth on the tutorials harness and is not on NDTwin's, where
        #: tools/p4_exercise/run_external_controller.py rewrites both (TICKET-P1D).
        self.fabric, self.package = fabric, package
        self.exercise_spec = EXERCISES.get(exercise) or {}

    # -------------------------------------------------------- utilities --

    def run(self):
        fn = getattr(self, "steps_" + self.exercise, None)
        if fn is None:                                       # guarded in main()
            raise RuntimeError("no scripted steps for %s" % self.exercise)
        fn()

    def _script(self, name):
        return os.path.join(self.exdir, name)

    def _start_receiver(self, host, tag, script="receive.py"):
        """receive.py in the host namespace, stdout+stderr into the log dir.

        🔴 `-u`, because the exercise's own file decides whether it flushes and
        this driver does not get to assume it does.  stdout here is a FILE, so
        CPython block-buffers it, and `_stop_receiver` ends the child with
        SIGTERM -- no atexit, no flush, the buffer is discarded.  basic's
        receive.py:51,58 and source_routing's :41,56 call sys.stdout.flush()
        themselves; link_monitor/receive.py:16-28 only prints, and on 2026-09-18
        19:11 its driver-h1-receive.log came back 0 B -- without even :26's
        "sniffing on eth0" -- while the same run's s1.log recorded all 8 probes
        as `Egress port is 1`.  An argv flag rather than PYTHONUNBUFFERED in the
        environment: NdtwinHosts.popen goes through `sudo -n mnexec` (:731),
        which resets the environment it passes on, and neither popen path takes
        an `env=` at all -- the flag is the only form that survives both
        fabrics, and it is visible in the command this step records.
        """
        path = os.path.join(self.log_dir, "driver-%s-receive.log" % tag)
        fh = open(path, "wb")
        cmd = [VENV_PY, "-u", self._script(script)]
        say("$ %s: %s   (> %s)" % (host, " ".join(cmd), path))
        proc = self.h.popen(host, cmd, stdout=fh, stderr=subprocess.STDOUT)
        time.sleep(self.args.recv_warmup)
        return proc, fh, path, " ".join(cmd)

    def _stop_receiver(self, proc, fh, path, drain=None):
        time.sleep(self.args.drain_wait if drain is None else drain)
        proc.terminate()                 # our own child handle; never pkill -f
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
        fh.flush()
        fh.close()
        with open(path, "r", errors="replace") as f:
            return f.read()

    @staticmethod
    def _packets(text):
        """Split receive.py output into per-packet blocks.

        receive.py:37-41 prints 'got a packet' then pkt.show2() then flushes,
        so one block per delivered packet.  scapy's show2() renders the IP TTL
        as e.g. '     ttl       = 59' and the Ethernet type as
        '  type      = IPv4' (0x800) or '  type      = 0x1234'.
        """
        blocks = text.split("got a packet")[1:]
        out = []
        for b in blocks:
            m = re.search(r"^\s*ttl\s*=\s*(\d+)\s*$", b, re.M)
            t = re.search(r"^\s*type\s*=\s*(\S+)\s*$", b, re.M)
            out.append({"ttl": int(m.group(1)) if m else None,
                        "ethertype": t.group(1) if t else None,
                        "srcroute": "SourceRoute" in b,
                        "text": b})
        return out

    def _add(self, *a, **kw):
        e = Expect(*a, **kw)
        self.expects.append(e)
        say("   " + e.line())
        return e

    def _pingall(self):
        """The acceptance measurement, printed with its per-pair detail."""
        say("$ every ordered host pair: ping -c 5 -W 2, loss parsed from ping's summary")
        pa = self.h.pingall(count=5)
        for line in pa.lines:
            say("   " + line)
        say("-> pingall %s" % pa.label())
        self.steps.append(("pingall -- every ordered pair, ping -c 5 -W 2",
                           "ping -c 5 -W 2 <each ordered pair>",
                           pa.label() + ("\n" + "\n".join(pa.lines) if pa.lines else "")))
        return pa

    # ------------------------------------------------ source_routing ------

    def steps_source_routing(self):
        h2_ip = self.ips["h2"]

        recv, fh, rpath, rcmd = self._start_receiver("h2", "h2")
        self.steps.append(("S1  h2 starts the sniffer", rcmd, "(background; output below)"))

        # send.py:52-73 loops on input() until the line is exactly "q", so both
        # port lists and the quit go in as one stdin blob and one process run.
        scmd = [VENV_PY, self._script("send.py"), h2_ip]
        feed = b"2 3 2 2 1\n2 1\nq\n"
        say("$ h1: %s   <<< %r" % (" ".join(scmd), feed))
        send = self.h.popen("h1", scmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
        try:
            sout, _ = send.communicate(input=feed, timeout=SEND_TIMEOUT)
        except subprocess.TimeoutExpired:
            send.kill()
            sout, _ = send.communicate()
        sout = sout.decode("utf-8", "replace")
        say(trim(sout, 2500))
        self.steps.append(("S2  h1 sends 2 packets", " ".join(scmd) + "   <<< " + repr(feed), sout))

        rtext = self._stop_receiver(recv, fh, rpath)
        say("-- h2 receive.py output (%s) --" % rpath)
        say(trim(rtext, 4000))
        self.steps.append(("S3  h2 sniffer output", rcmd, rtext))

        # ---- injection assertion first: '0 received' must not be vacuous ----
        emitted = len(re.findall(r"^\s*type\s*=\s*0x1234\s*$", sout, re.M))
        self._add("injection: send.py built 2 srcroute frames", "2", str(emitted),
                  emitted == 2, G_SRC,
                  "send.py:72 pkt.show2() before sendp(); type 0x1234 = SourceRoute stack present")

        pkts = self._packets(rtext)
        ttls = sorted([p["ttl"] for p in pkts if p["ttl"] is not None])

        if self.which == "solution":
            self._add("h2 received packet count", "2", str(len(pkts)),
                      len(pkts) == 2, G_BOTH,
                      "README step 3: the message should be delivered")
            self._add("ttl multiset {2 3 2 2 1 ; 2 1}", "[59, 62]", str(ttls),
                      ttls == [59, 62], G_BOTH,
                      "M7 section 2: 5 hops -> 64-5=59; shortest path 2 hops -> 62")
            bad = [p for p in pkts if p["srcroute"]]
            self._add("no SourceRoute layer left at h2", "0 blocks", "%d blocks" % len(bad),
                      not bad, G_SRC,
                      "solution:116 pop_front(1) per hop, :120 srcRoute_finish restores 0x800")
            types = [p["ethertype"] for p in pkts]
            self._add("ethertype seen by h2", "IPv4 (0x800)", str(types),
                      bool(types) and all(t == "IPv4" for t in types),
                      G_SRC,
                      "scapy show2() renders 0x800 as the name 'IPv4', not the number")
        else:
            self._add("h2 received packet count", "0", str(len(pkts)),
                      len(pkts) == 0, G_BOTH,
                      "skeleton parser stops at accept, hdr.srcRoutes[0] never valid -> drop()")

        self._log_sizes()

    # -------------------------------------------------------- basic ------

    def steps_basic(self):
        h2_ip = self.ips["h2"]

        native = getattr(self.h, "native_pingall", None)
        if native is not None:
            say("$ mininet: net.pingAll(timeout=1)")
            nloss = native(timeout=1)
            say("-> net.pingAll loss = %s%%   (RECORDED, for the 2026-09-08 rows; not the assertion)" % nloss)
            self.steps.append(("B0  net.pingAll(timeout=1)  [recorded, one packet per pair]",
                               "net.pingAll(timeout=1)", "loss = %s%%" % nloss))

        pa = self._pingall()
        loss = pa.loss

        pcmd = "ping -c 3 -W 1 %s" % h2_ip
        say("$ h1: %s" % pcmd)
        pout = self.h.cmd("h1", "LANG=C " + pcmd)
        say(pout.rstrip())
        self.steps.append(("B2  h1 ping -c3 h2", pcmd, pout))
        m = re.search(r"(\d+) packets transmitted, (\d+) received", pout)
        rx = int(m.group(2)) if m else -1

        recv, fh, rpath, rcmd = self._start_receiver("h2", "h2")
        self.steps.append(("B3  h2 starts the sniffer", rcmd, "(background; output below)"))
        # basic/send.py:27-38 takes <dst> "<message>" as argv and sends once.
        scmd = [VENV_PY, self._script("send.py"), h2_ip, "P4 driver probe"]
        say("$ h1: %s" % " ".join(scmd))
        send = self.h.popen("h1", scmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            sout, _ = send.communicate(timeout=SEND_TIMEOUT)
        except subprocess.TimeoutExpired:
            send.kill()
            sout, _ = send.communicate()
        sout = sout.decode("utf-8", "replace")
        say(trim(sout, 2500))
        self.steps.append(("B4  h1 send.py -> h2", " ".join(scmd), sout))
        rtext = self._stop_receiver(recv, fh, rpath)
        say("-- h2 receive.py output (%s) --" % rpath)
        say(trim(rtext, 3000))
        self.steps.append(("B5  h2 sniffer output", rcmd, rtext))

        emitted = 1 if re.search(r"sending on interface .* to %s" % re.escape(h2_ip), sout) else 0
        self._add("injection: send.py emitted 1 TCP frame", "1", str(emitted),
                  emitted == 1, G_SRC,
                  "basic/send.py:34 prints before sendp(); dport 1234 is what receive.py filters on")

        pkts = self._packets(rtext)

        if self.which == "solution":
            self._add("pingall loss (ping -c 5, every ordered pair)", "0.0%", pa.label(),
                      loss == 0, G_BOTH,
                      "solution/basic.p4 parses+forwards; pod-topo sX-runtime.json has /32 entries for all 4 hosts")
            self._add("h1 ping -c3 h2 received", "3", str(rx),
                      rx == 3, G_SRC)
            self._add("h2 got the send.py packet", ">=1", str(len(pkts)),
                      len(pkts) >= 1, G_SRC)
            ttls = [p["ttl"] for p in pkts if p["ttl"] is not None]
            self._add("ttl at h2 (h1-s1-h2 is one hop)", "[63]", str(ttls),
                      ttls == [63] * len(ttls) and bool(ttls), G_SRC,
                      "solution ipv4_forward does ttl = ttl - 1 once; h1 and h2 share s1 (pod-topo links)")
        else:
            self._add("pingall loss (ping -c 5, every ordered pair)", "100.0%", pa.label(),
                      loss == 100, G_BOTH,
                      "see the derivation in DRIVER.md: basic.p4:66-74 / :119-129 / :147 / :202-211")
            self._add("h1 ping -c3 h2 received", "0", str(rx),
                      rx == 0, G_SRC)
            self._add("h2 got the send.py packet", "0", str(len(pkts)),
                      len(pkts) == 0, G_SRC)

        self._log_sizes()

    # ------------------------------------------------------ firewall ------

    def steps_firewall(self):
        """exercises/firewall, README steps 1 and 3.

        WHAT THE TWO ARMS ARE, and where each expectation comes from:

          * h1 -> h3 connects in BOTH arms.  【README 宣稱】 "TCP flows from hosts
            in the internal network to the outside hosts should also work", and
            【源碼推導】 firewall.p4:190-215 (skeleton) applies ipv4_lpm exactly as
            the solution does -- the two TODOs at :205 and :211 are the bloom
            filter's write and read and NOTHING else, so the skeleton forwards
            everything the solution forwards plus the flows the solution drops.
          * h3 -> h1 connects with the SKELETON.  README step 1.2 verbatim:
            "since the firewall is not implemented yet, the following should work:
            iperf h3 h1".  🔴 THIS IS THE RED ARM AND IT MUST BE RED: if the
            skeleton does NOT forward h3 -> h1 then the solution's block below is
            not evidence of a firewall -- a fabric that forwards nothing would
            produce the same two rows -- so this run FAILS and says so.
          * h3 -> h1 does NOT connect with the SOLUTION.  README: "TCP flows from
            the outside hosts to hosts inside the internal network should NOT
            work", and solution/firewall.p4:212-219: direction 1 (s1-runtime.json
            maps ingress 3|4 -> egress 1|2 to set_direction(1)) reads both bloom
            cells and drop()s unless h1/h2 opened the connection first.
        """
        h1, h3 = self.ips["h1"], self.ips["h3"]
        pa = self._pingall()

        out_ok, out_raw = self._iperf("h1", "h3", h3)
        self.steps.append(("F1  iperf h1 -> h3 (internal to external)",
                           "iperf -s on h3; iperf -c %s -t %d on h1" % (h3, IPERF_SECONDS),
                           out_raw))
        self._add("iperf h1 -> h3 (internal -> external)", "connects", "connects" if out_ok else "no transfer",
                  out_ok, G_BOTH,
                  "README step 1.2; firewall.p4 ipv4_lpm forwards in both arms")

        in_ok, in_raw = self._iperf("h3", "h1", h1)
        self.steps.append(("F2  iperf h3 -> h1 (external to internal)",
                           "iperf -s on h1; iperf -c %s -t %d on h3" % (h1, IPERF_SECONDS),
                           in_raw))

        if self.which == "solution":
            self._add("iperf h3 -> h1 is blocked", "no transfer",
                      "connects" if in_ok else "no transfer",
                      not in_ok, G_BOTH,
                      "solution/firewall.p4:212-219 drop()s direction-1 packets whose bloom cells are unset")
            self._add("the fabric still forwards (pingall)", "0.0%", pa.label(),
                      pa.loss == 0, G_SRC,
                      "ICMP has no TCP header, so check_ports never fires: the firewall drops TCP, not the fabric")
        else:
            self._add("RED ARM: iperf h3 -> h1 must connect", "connects",
                      "connects" if in_ok else "no transfer",
                      in_ok, G_BOTH,
                      "README step 1.2: with the firewall unimplemented h3 -> h1 works. "
                      "If this is red the solution's block proves nothing -- the red arm is not red.")
            self._add("the fabric forwards (pingall)", "0.0%", pa.label(),
                      pa.loss == 0, G_SRC,
                      "the skeleton is basic.p4 plus unfilled TODOs; nothing in it drops ICMP")

        self._log_sizes()

    def _iperf(self, client, server, server_ip):
        """One TCP flow, client -> server.  (connected?, transcript).

        iperf v2, the one `mininet> iperf h1 h3` runs.  The server is started in
        the SERVER's namespace and stopped by the handle this function holds --
        never by name, and never with pkill.  A client that never connects is a
        client that sits in SYN retries, so the wall clock is the reading: the
        timeout means "no transfer", which is exactly what the solution's drop
        looks like from h3.
        """
        log = os.path.join(self.log_dir, "driver-iperf-%s-to-%s.log" % (client, server))
        fh = open(log, "wb")
        say("$ %s: iperf -s   (> %s)" % (server, log))
        try:
            srv = self.h.popen(server, ["iperf", "-s"], stdout=fh, stderr=subprocess.STDOUT)
        except HostNotFound as e:
            fh.close()
            return False, "UNTESTED: %s" % e
        time.sleep(IPERF_WARMUP)
        ccmd = ["iperf", "-c", server_ip, "-t", str(IPERF_SECONDS)]
        say("$ %s: %s" % (client, " ".join(ccmd)))
        killed = False
        try:
            cli = self.h.popen(client, ccmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except HostNotFound as e:
            self._stop_proc(srv)
            fh.close()
            return False, "UNTESTED: %s" % e
        try:
            cout, _ = cli.communicate(timeout=IPERF_TIMEOUT)
        except subprocess.TimeoutExpired:
            cli.kill()
            cout, _ = cli.communicate()
            killed = True
        cout = cout.decode("utf-8", "replace")
        self._stop_proc(srv)
        fh.flush()
        fh.close()
        with open(log, "r", errors="replace") as f:
            stext = f.read()
        # 🔴 THE TRANSFER LINE, not the exit code: iperf exits 0 in cases where
        # nothing crossed the network, and the report line is what `iperf h1 h3`
        # in the README's Mininet CLI shows.
        connected = bool(re.search(r"\d+(\.\d+)?\s*\w?bits/sec", cout)) and not killed
        text = ("client:\n%s\nserver:\n%s\n%s"
                % (cout, stext, "(client killed after %ds)" % IPERF_TIMEOUT if killed else ""))
        say(trim(text, 2000))
        return connected, text

    def _stop_proc(self, proc):
        try:
            proc.terminate()
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        except Exception:                                    # noqa: BLE001
            pass

    # -------------------------------------------------- link_monitor ------

    PROBE_RE = re.compile(r"^Switch (\d+) - Port (\d+): (\S+) Mbps\s*$", re.M)

    def steps_link_monitor(self):
        """exercises/link_monitor, README step 1.

        WHAT DISTINGUISHES THE ARMS.  Both arms run `swid.apply()`
        (link_monitor.p4:239 and solution/link_monitor.p4:239), and pod-topo's
        sX-runtime.json sets that table's DEFAULT action to set_swid(X) -- so the
        switch ids come out non-zero in BOTH, and a check written on them would
        pass over an unimplemented exercise.  What the skeleton's two TODOs
        (link_monitor.p4:240-243) leave unwritten is `probe_data[0].port`,
        `.byte_cnt`, `.last_time` and `.cur_time` (the two TODOs at :240-243), all of
        which stay 0 --
        receive.py then prints `Port 0` and, because `cur_time == last_time`,
        `0 Mbps` for every hop.  【README 宣稱】 step 1.4 says exactly that: "The
        reported link utilization and the switch port numbers will always be 0
        because the probe fields have not been filled out yet."

          * skeleton: probes arrive, and EVERY reported port is 0.
          * solution: probes arrive, every reported port is non-zero, and the
            switch ids seen cover all four switches -- 【源碼推導】 send.py's nine
            ProbeFwd headers (4,1,4,1,3,2,3,2,1) walk s1-s4-s2-s3-s1-s3-s2-s4-s1
            over pod-topo's links, so each of s1..s4 appears at least once.

        Probes arriving at all is asserted FIRST in both arms: "every port is 0"
        is vacuously true of no probes.

        WHY THE RECEIVER IS STARTED WITH `-u`.  link_monitor/receive.py:16-28
        never calls sys.stdout.flush() -- unlike basic's and source_routing's --
        so with stdout redirected to a file its lines sat in the interpreter's
        buffer and the SIGTERM in _stop_receiver threw them away: on 2026-09-18
        19:11 both arms failed here with driver-h1-receive.log at 0 B while the
        same run's s1.log held all 8 probes.  _start_receiver supplies the flush
        the exercise does not; nothing below changed.
        """
        recv, fh, rpath, rcmd = self._start_receiver("h1", "h1")
        self.steps.append(("L1  h1 starts receive.py", rcmd, "(background; output below)"))

        scmd = [VENV_PY, self._script("send.py")]
        say("$ h1: %s   (one probe per second, for %ds)" % (" ".join(scmd), PROBE_SECONDS))
        send = self.h.popen("h1", scmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        time.sleep(PROBE_SECONDS)
        self._stop_proc(send)
        try:
            sout, _ = send.communicate(timeout=10)
            sout = sout.decode("utf-8", "replace")
        except (subprocess.TimeoutExpired, ValueError):      # noqa: BLE001
            sout = "(send.py produced no output before it was stopped)"
        self.steps.append(("L2  h1 send.py (probes)", " ".join(scmd), sout))

        rtext = self._stop_receiver(recv, fh, rpath)
        say("-- h1 receive.py output (%s) --" % rpath)
        say(trim(rtext, 4000))
        self.steps.append(("L3  h1 receive.py output", rcmd, rtext))

        rows = [(int(a), int(b), c) for a, b, c in self.PROBE_RE.findall(rtext)]
        swids = sorted({r[0] for r in rows})
        ports = sorted({r[1] for r in rows})

        # The injection assertion: no rows makes every claim below vacuous.
        self._add("injection: probes reached h1", ">=1 report row", "%d rows" % len(rows),
                  len(rows) >= 1, G_README,
                  "receive.py:22 prints one 'Switch X - Port Y: Z Mbps' line per probe_data layer")

        if self.which == "solution":
            self._add("switch ids seen", "[1, 2, 3, 4]", str(swids),
                      swids == [1, 2, 3, 4], G_SRC,
                      "send.py's 9 ProbeFwd hops walk s1-s4-s2-s3-s1-s3-s2-s4-s1 over pod-topo")
            self._add("every reported port is non-zero", "no 0 port", str(ports),
                      bool(ports) and 0 not in ports, G_SRC,
                      "solution:240 hdr.probe_data[0].port = standard_metadata.egress_port")
        else:
            self._add("switch ids seen", "[1, 2, 3, 4]", str(swids),
                      swids == [1, 2, 3, 4], G_SRC,
                      "swid.apply() is in the skeleton too (link_monitor.p4:235); sX-runtime.json "
                      "sets the DEFAULT action, so the ids are filled in on both arms")
            self._add("every reported port is 0", "[0]", str(ports),
                      ports == [0], G_BOTH,
                      "README step 1.4; link_monitor.p4:240-243 leave .port unwritten")
            utils = sorted({r[2] for r in rows})
            self._add("every reported utilization is 0", "['0']", str(utils),
                      utils == ["0"], G_BOTH,
                      "cur_time == last_time == 0 -> receive.py:21 yields the integer 0")

        self._log_sizes()

    # ================================================ TICKET-P3 §2.7: the other nine ==
    #
    # 🔴 EVERY EXPECTATION BELOW IS 【源碼推導，未執行】 OR 【README 宣稱】 UNTIL THE
    # ORCHESTRATOR'S LIVE ROUND. None of the nine has been run on either fabric by the session
    # that wrote them; what the offline suite asserts is that the driver ASKS the question this
    # way and that the two arms are distinguishable. DRIVER.md §6 carries the grade per cell.

    # -- shared readers -------------------------------------------------------------------

    @staticmethod
    def _field_values(text, field):
        """Every `field = <value>` scapy show2() printed, in arrival order.

        show2() renders one `     tos       = 0x1` per layer that has the field, so this is
        the reading both `ecn` and `qos` are written on. The value is taken verbatim -- `0x1`
        and `1` are different strings and only the exercise's README says which one its scapy
        prints.
        """
        # 🔴 SCAPY INDENTS NESTED LAYERS WITH `|`, AND THE FIELD IS STILL THE FIELD
        # (TICKET-P3 §9 ruling 23①, from the second live 06). An IP OPTION is a nested layer,
        # so receive.py prints it as
        #       |###[ MRI ]###
        #       |  count     = 2
        #       |  \swtraces  \
        #       |   |###[ SwitchTrace ]###
        #       |   |  swid      = 2
        # -- every line carrying one or more `|` before the name. `^\s*` does not match those,
        # so `count` read 0 and `swid` read [], and BOTH mri arms reported
        # "injection: the MRI option survived to h2 got=0" while the transcript printed the
        # option in full. The prefix is presentation, not data: strip `|` and spaces first.
        return re.findall(r"^[|\s]*%s\s*=\s*(\S+)\s*$" % re.escape(field), text, re.M)

    def _send_once(self, host, argv, feed=None, label=""):
        """One sender, run to completion in the host namespace. -> its combined output."""
        say("$ %s: %s%s" % (host, " ".join(argv), ("   <<< %r" % feed) if feed else ""))
        kw = {"stdout": subprocess.PIPE, "stderr": subprocess.STDOUT}
        if feed is not None:
            kw["stdin"] = subprocess.PIPE
        proc = self.h.popen(host, argv, **kw)
        try:
            out, _ = proc.communicate(input=feed, timeout=SEND_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, _ = proc.communicate()
        out = (out or b"").decode("utf-8", "replace")
        say(trim(out, 2500))
        if label:
            self.steps.append((label, " ".join(argv) + (("   <<< " + repr(feed)) if feed else ""), out))
        return out

    def _background_udp(self, client, server, server_ip, rate="1M", seconds=None):
        """`iperf -s -u` on the server and `iperf -c -u` on the client, both left running.

        🔴 THE QUEUE IS THE SUBJECT, NOT THE THROUGHPUT. ecn's bottleneck is
        topology.json:65-69's 0.5 Mbit/s link and what fills it is offered load; the numbers
        iperf reports are never read. Both handles are returned so the caller stops them by
        the handle it holds -- never by name, never with pkill.
        """
        seconds = BG_SECONDS if seconds is None else seconds
        log = os.path.join(self.log_dir, "driver-bg-iperf-%s-to-%s.log" % (client, server))
        fh = open(log, "wb")
        say("$ %s: iperf -s -u   (> %s)" % (server, log))
        srv = self.h.popen(server, ["iperf", "-s", "-u"], stdout=fh, stderr=subprocess.STDOUT)
        time.sleep(IPERF_WARMUP)
        ccmd = ["iperf", "-c", server_ip, "-u", "-b", rate, "-t", str(seconds)]
        say("$ %s: %s" % (client, " ".join(ccmd)))
        cli = self.h.popen(client, ccmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.steps.append(("BG  %s -> %s background UDP (fills the bottleneck queue)" % (client, server),
                           "iperf -s -u on %s; %s on %s" % (server, " ".join(ccmd), client),
                           "(background; the numbers it reports are not read)"))
        return srv, cli, fh

    def _start_controller(self, which, tag):
        """The exercise's OWN controller, by the same seam live-p1/03 uses.

        🔴 TWO PATHS, ONE DECISION. On the tutorials fabric the controller's hard-coded
        127.0.0.1:5005N / device_id N-1 are exactly what the harness built, so it is run as
        itself. On the NDTwin fabric they are not, and tools/p4_exercise/
        run_external_controller.py is the adapter that rewrites them (TICKET-P1D) -- the same
        launcher live-p1/03 uses, so "the exercise's controller ran" means one thing on both.

        The process is stopped by the handle returned here. Nothing uses pkill.
        """
        rel = self.exercise_spec.get("controller")
        ctrl = rel if self.which == "skeleton" else os.path.join("solution", os.path.basename(rel))
        path = os.path.join(self.log_dir, "driver-controller-%s.log" % tag)
        fh = open(path, "wb")
        if self.fabric == "ndtwin":
            if not self.package:
                raise RuntimeError("the ndtwin arm has no package directory to hand the adapter")
            argv = [CTRL_PY, os.path.join(REPO, "tools", "p4_exercise",
                                          "run_external_controller.py"), self.package, ctrl]
        else:
            argv = [CTRL_PY, os.path.join(self.exdir, ctrl)]
        env = dict(os.environ)
        env["PYTHONUNBUFFERED"] = "1"
        say("$ %s   (> %s)" % (" ".join(argv), path))
        proc = local_popen(argv, cwd=self.exdir, stdout=fh, stderr=subprocess.STDOUT,
                           stdin=subprocess.DEVNULL, env=env)
        time.sleep(CTRL_SETTLE)
        alive = proc.poll() is None
        fh.flush()
        with open(path, "r", errors="replace") as f:
            text = f.read()
        say("-- controller log (%s) --" % path)
        say(trim(text, 4000))
        self.steps.append(("C1  %s under its own interpreter" % ctrl, " ".join(argv), text))
        return proc, fh, path, text, alive, ctrl

    def _stop_controller(self, proc, fh, path):
        self._stop_proc(proc)
        try:
            fh.flush()
            fh.close()
        except (OSError, ValueError):                         # noqa: BLE001
            pass
        with open(path, "r", errors="replace") as f:
            return f.read()

    # -------------------------------------------------- basic_tunnel ------

    def _tunnel_round(self, dst_id, tag):
        """One `send.py <ip> <msg> --dst_id N` with h2 AND h3 sniffing. -> (n2, n3, sent)."""
        r2, f2, p2, c2 = self._start_receiver("h2", "h2-%s" % tag)
        r3, f3, p3, c3 = self._start_receiver("h3", "h3-%s" % tag)
        scmd = [VENV_PY, self._script("send.py"), self.ips["h2"], "P4 driver probe",
                "--dst_id", str(dst_id)]
        sout = self._send_once("h1", scmd, label="T%s  h1 send.py --dst_id %d" % (tag, dst_id))
        t2 = self._stop_receiver(r2, f2, p2)
        t3 = self._stop_receiver(r3, f3, p3)
        say("-- h2 (%s) --" % p2); say(trim(t2, 2000))
        say("-- h3 (%s) --" % p3); say(trim(t3, 2000))
        self.steps.append(("T%s  h2 sniffer" % tag, c2, t2))
        self.steps.append(("T%s  h3 sniffer" % tag, c3, t3))
        return len(self._packets(t2)), len(self._packets(t3)), sout

    def steps_basic_tunnel(self):
        """exercises/basic_tunnel, README steps 2.4 and 2.6.

        WHAT DISTINGUISHES THE ARMS. The tunnel header carries the destination, not the IP:
        README:138-140 -- "The packet should be received at h2, even though that IP address is
        the address of h3." Both rounds below therefore send to the SAME IP (h2's) and change
        only `--dst_id`, which is the only way to tell "the tunnel routed it" from "IP routing
        routed it". A driver that changed the IP as well would pass over a fabric with no
        tunnel at all.

        The skeleton's red arm is NOT here: it is the entries (spec["red_arm"] == "entries",
        README:41-43). If this ever runs with the skeleton, nothing should arrive anywhere.
        """
        emitted = 0
        n2_a, n3_a, s_a = self._tunnel_round(2, "1")
        emitted += len(re.findall(r"^sending on interface .* to dst_id 2$", s_a, re.M))
        n2_b, n3_b, s_b = self._tunnel_round(3, "2")
        emitted += len(re.findall(r"^sending on interface .* to dst_id 3$", s_b, re.M))

        self._add("injection: send.py built 2 tunnel frames", "2", str(emitted),
                  emitted == 2, G_SRC,
                  "send.py:38 prints 'sending on interface <i> to dst_id <n>' before sendp()")

        if self.which == "solution":
            self._add("--dst_id 2 lands on h2", "h2=1 h3=0", "h2=%d h3=%d" % (n2_a, n3_a),
                      n2_a >= 1 and n3_a == 0, G_BOTH,
                      "README step 2.4: the packet should be received at h2")
            self._add("--dst_id 3 lands on h3, same IP", "h2=0 h3>=1",
                      "h2=%d h3=%d" % (n2_b, n3_b),
                      n3_b >= 1 and n2_b == 0, G_BOTH,
                      "README step 2.4: 'try to send to 10.0.3.3 ... will instead be received "
                      "by h3'; here the IP is h2's and only dst_id moved, which is the whole tunnel")
        else:
            self._add("nothing is delivered by the skeleton", "0 everywhere",
                      "h2=%d/%d h3=%d/%d" % (n2_a, n2_b, n3_a, n3_b),
                      (n2_a + n2_b + n3_a + n3_b) == 0, G_SRC,
                      "basic_tunnel.p4:71-75 parses no myTunnel header and :183 emits none; "
                      "the arm's real red is that its runtime entries do not install at all")
        self._log_sizes()

    # ---------------------------------------------------------- calc ------

    def steps_calc(self):
        """exercises/calc, README step 1.3 (skeleton) and step 3 (solution).

        calc.py is the exercise's whole client: no send.py/receive.py pair, no argv, a REPL on
        `input('> ')` that quits on the line `quit` (calc.py:80-83). So the step feeds it one
        expression and the quit, and reads its own printed lines back.

        🔴 THE TWO ARMS ARE TWO DIFFERENT LINES, both quoted by the README verbatim:
          solution   `> 1+1` then `2`               (README:109-113)
          skeleton   `> 1+1` then `Didn't receive response`  (README:54-58)
        `2` is asserted as a LINE OF ITS OWN and not as a substring: `1+1` contains no `2`, but
        an error message might, and a substring test would then read a failure as the answer.
        """
        scmd = [VENV_PY, "-u", self._script("calc.py")]
        out = self._send_once("h1", scmd, feed=b"1+1\nquit\n", label="K1  h1 calc.py <<< 1+1")

        echoed = bool(re.search(r"^> 1\+1$", out, re.M))
        self._add("injection: calc.py read the expression", "> 1+1", "yes" if echoed else "no",
                  echoed, G_BOTH,
                  "calc.py:80-84 prints the prompt and echoes the line it read; without this "
                  "'no answer' would also describe a client that never sent anything")

        answered = bool(re.search(r"^2$", out, re.M))
        silent = "Didn't receive response" in out
        if self.which == "solution":
            self._add("the switch answered 1+1", "2", "2" if answered else "(no line '2')",
                      answered, G_BOTH, "README step 3's own transcript")
            self._add("and it did not time out", "no timeout",
                      "timed out" if silent else "answered", not silent, G_SRC,
                      "calc.py:101 prints \"Didn't receive response\" when srp1 returns None")
        else:
            self._add("RED ARM: the skeleton must not answer", "Didn't receive response",
                      "answered 2" if answered else ("Didn't receive response" if silent
                                                     else "(neither)"),
                      silent and not answered, G_BOTH,
                      "README step 1.3's own transcript; calc.p4:116-126 leaves check_p4calc "
                      "with no transition, so hdr.p4calc is never valid and :205-210 drops. "
                      "If this is green the solution's answer proves nothing.")
        self._log_sizes()

    # ----------------------------------------------------------- ecn ------

    def steps_ecn(self):
        """exercises/ecn, README step 1.8 (skeleton) and step 3 (solution).

        🔴 THIS ARM NEEDS A QUEUE, AND THE QUEUE NEEDS G2-C. ecn.p4:9 sets ECN_THRESHOLD = 10
        and the solution only marks when `standard_metadata.enq_qdepth >= ECN_THRESHOLD`
        (solution/ecn.p4:131-139). The only thing that builds a queue here is
        topology.json:65-69's `[ "s1-p3", "s2-p3", "0", 0.5 ]` -- a 0.5 Mbit/s link. On a
        fabric that does not shape that link the queue is empty, `tos` never leaves 0x1, and
        the SOLUTION arm is red for a reason that is not about ecn.p4. spec["needs"] says so
        and DRIVER.md §6 repeats it; TICKET-P3 §2.4 keeps this exercise out of the gate until
        G2-C lands.
        """
        srv, cli, fh = self._background_udp("h11", "h22", self.ips["h22"], rate="1M")
        try:
            recv, rfh, rpath, rcmd = self._start_receiver("h2", "h2")
            self.steps.append(("E1  h2 starts the sniffer", rcmd, "(background; output below)"))
            scmd = [VENV_PY, self._script("send.py"), self.ips["h2"], "P4 driver probe",
                    str(SEND_SECONDS)]
            sout = self._send_once("h1", scmd, label="E2  h1 send.py (one packet per second)")
            rtext = self._stop_receiver(recv, rfh, rpath)
        finally:
            self._stop_proc(cli)
            self._stop_proc(srv)
            fh.flush(); fh.close()
        say("-- h2 receive.py output (%s) --" % rpath)
        say(trim(rtext, 4000))
        self.steps.append(("E3  h2 sniffer output", rcmd, rtext))

        pkts = self._packets(rtext)
        tos = self._field_values(rtext, "tos")
        self._add("injection: packets reached h2", ">=1", "%d" % len(pkts),
                  len(pkts) >= 1, G_SRC,
                  "send.py:35-41 sends one UDP/4321 datagram per second; receive.py:34 filters "
                  "'udp and port 4321'. Every claim below is vacuous without this.")
        self._add("injection: send.py showed the frame it built", "1 show2",
                  str(len(self._field_values(sout, "tos"))),
                  len(self._field_values(sout, "tos")) >= 1, G_SRC,
                  "send.py:36 pkt.show2() before the loop; the sender sets tos=1 (:35)")

        if self.which == "solution":
            self._add("h2 saw a congestion-marked packet", "0x3 among the tos values",
                      str(sorted(set(tos))), "0x3" in tos, G_BOTH,
                      "README step 3: 'tos values change from 1 to 3 as the queue builds up'; "
                      "solution/ecn.p4:131-139 sets ecn=3 when enq_qdepth >= 10. Needs the "
                      "0.5 Mbit/s link of topology.json:65-69 (G2-C).")
        else:
            self._add("RED ARM: every tos stays 0x1", "['0x1']", str(sorted(set(tos))),
                      bool(tos) and set(tos) == {"0x1"}, G_BOTH,
                      "README step 1.8: 'the ipv4.tos field is always 1'; ecn.p4:132-138 "
                      "leaves MyEgress.apply empty. If this is red the solution's 0x3 proves "
                      "nothing -- a fabric that marked everything would look the same.")
        self._log_sizes()

    # ----------------------------------------------------------- mri ------

    def steps_mri(self):
        """exercises/mri, README step 1.7 (skeleton) and step 3 (solution).

        WHAT DISTINGUISHES THE ARMS is the MRI option's `count` and the swids under it.
        README:85 for the skeleton: "At h2, the MRI header has no hop info (count=0)".
        README:171-212 for the solution: a `count = 2` with `swid = 2` and `swid = 1` -- the
        two switches h1 -> s1 -> s2 -> h2 crosses.

        🔴 `qdepth` IS DELIBERATELY NOT ASSERTED. It is 0 unless the 0.5 Mbit/s link of
        topology.json:65-69 is shaped (G2-C), and README's own troubleshooting item 4 is
        about exactly that; `count` and the swids are the exercise's claim and need no queue.
        """
        srv, cli, fh = self._background_udp("h11", "h22", self.ips["h22"], rate="1M")
        try:
            recv, rfh, rpath, rcmd = self._start_receiver("h2", "h2")
            self.steps.append(("M1  h2 starts the sniffer", rcmd, "(background; output below)"))
            scmd = [VENV_PY, self._script("send.py"), self.ips["h2"], "P4 driver probe",
                    str(SEND_SECONDS)]
            sout = self._send_once("h1", scmd, label="M2  h1 send.py (MRI option, one per second)")
            rtext = self._stop_receiver(recv, rfh, rpath)
        finally:
            self._stop_proc(cli)
            self._stop_proc(srv)
            fh.flush(); fh.close()
        say("-- h2 receive.py output (%s) --" % rpath)
        say(trim(rtext, 4000))
        self.steps.append(("M3  h2 sniffer output", rcmd, rtext))

        pkts = self._packets(rtext)
        counts = [int(v) for v in self._field_values(rtext, "count") if v.isdigit()]
        swids = sorted({int(v) for v in self._field_values(rtext, "swid") if v.isdigit()})

        self._add("injection: packets reached h2", ">=1", "%d" % len(pkts),
                  len(pkts) >= 1, G_SRC,
                  "send.py:69-83 sends one UDP/4321 datagram per second carrying "
                  "IPOption_MRI(count=0); receive.py:63 filters 'udp and port 4321'")
        self._add("injection: the MRI option survived to h2", ">=1 count field",
                  "%d" % len(counts), bool(counts), G_SRC,
                  "receive.py:33-50 decodes IP option 31 as IPOption_MRI; no count line means "
                  "the option was not there at all, which is a different failure")

        if self.which == "solution":
            self._add("hop count at h2", "2", str(sorted(set(counts))),
                      bool(counts) and set(counts) == {2}, G_BOTH,
                      "README step 3: h1 -> s1 -> s2 -> h2 is two switches")
            self._add("switch ids in the trace", "[1, 2]", str(swids),
                      swids == [1, 2], G_BOTH,
                      "sX-runtime.json:6-13 sets MyEgress.swtrace's DEFAULT action to "
                      "add_swtrace(swid=N), so s1 and s2 stamp 1 and 2")
        else:
            self._add("RED ARM: the hop count stays 0", "[0]", str(sorted(set(counts))),
                      bool(counts) and set(counts) == {0}, G_BOTH,
                      "README step 1.7: 'the MRI header has no hop info (count=0)'; "
                      "mri.p4:205 leaves add_swtrace empty and :268 emits no swtraces. "
                      "If this is red the solution's count=2 proves nothing.")
            self._add("and no swid is ever stamped", "[]", str(swids),
                      swids == [], G_SRC,
                      "the skeleton's parse_swtrace is a bare `transition accept` (mri.p4:137)")
        self._log_sizes()

    # ----------------------------------------------------- load_balance ---

    def steps_load_balance(self):
        """exercises/load_balance, README step 1 (skeleton) and step 3 (solution).

        WHAT DISTINGUISHES THE ARMS. README:24-25 says the skeleton "initially sends all
        packets of the load balance IP to h2"; README:102-104 says the solution delivers to
        "h2 or h3. If you send several messages, some should be received by each server."
        So the reading is a SPLIT over ten sends, and the skeleton's is the degenerate one --
        which is why ten and not one: a single packet is consistent with both arms.

        🔴 THE DESTINATION IS 10.0.0.1 AND IT IS NOBODY'S ADDRESS. It is the load-balanced
        service address s1's ecmp_group matches on (s1-runtime.json:5-70), so the hosts that
        answer are decided by the fabric and not by the IP.
        """
        r2, f2, p2, c2 = self._start_receiver("h2", "h2")
        r3, f3, p3, c3 = self._start_receiver("h3", "h3")
        self.steps.append(("D1  h2 and h3 start sniffers", c2 + " | " + c3,
                           "(background; output below)"))
        sent = 0
        for i in range(10):
            scmd = [VENV_PY, self._script("send.py"), "10.0.0.1", "P4 driver probe %d" % i]
            sout = self._send_once("h1", scmd)
            sent += len(re.findall(r"^sending on interface .* to 10\.0\.0\.1$", sout, re.M))
        self.steps.append(("D2  h1 send.py 10.0.0.1 x10",
                           "%s %s 10.0.0.1 'P4 driver probe <i>'  (x10)"
                           % (VENV_PY, self._script("send.py")),
                           "%d of 10 sends printed their 'sending on interface' line" % sent))
        t2 = self._stop_receiver(r2, f2, p2)
        t3 = self._stop_receiver(r3, f3, p3)
        say("-- h2 (%s) --" % p2); say(trim(t2, 2500))
        say("-- h3 (%s) --" % p3); say(trim(t3, 2500))
        self.steps.append(("D3  h2 sniffer output", c2, t2))
        self.steps.append(("D4  h3 sniffer output", c3, t3))
        n2, n3 = len(self._packets(t2)), len(self._packets(t3))

        self._add("injection: send.py emitted 10 frames", "10", str(sent),
                  sent == 10, G_SRC,
                  "send.py:34 prints 'sending on interface <i> to 10.0.0.1' before sendp()")

        if self.which == "solution":
            self._add("both servers were used", "h2>=1 and h3>=1", "h2=%d h3=%d" % (n2, n3),
                      n2 >= 1 and n3 >= 1, G_BOTH,
                      "README step 3: 'some should be received by each server'; "
                      "solution/load_balance.p4:106-115 hashes the 5-tuple into ecmp_select")
        else:
            self._add("RED ARM: only h2 is used", "h2>=1 and h3==0", "h2=%d h3=%d" % (n2, n3),
                      n2 >= 1 and n3 == 0, G_BOTH,
                      "README:24-25 'initially sends all packets of the load balance IP to h2'; "
                      "load_balance.p4:107 leaves set_ecmp_select empty so ecmp_select stays 0 "
                      "and s1-runtime.json maps 0 to port 2. If this is red the solution's "
                      "split proves nothing.")
        self._log_sizes()

    # -------------------------------------------------------- multicast ---

    def steps_multicast(self):
        """exercises/multicast, README step 1 (skeleton) and step 3 (solution).

        🔴 THE EXPECTATION IS PER PAIR, NOT THE AGGREGATE. README:119-120: "you should be able
        to successfully ping between h1, h2 and h3 but not h4". sig-topo/s1-runtime.json:47-65
        replicates ports 1, 2 and 3 only -- adding the fourth is the student's own TODO
        (README:122) -- so the SOLUTION arm's correct result is a fabric that is partly
        unreachable, and a `pingall` loss number cannot express it.

        IPv6 is turned off INSIDE each host first. exercises/multicast/disable_ipv6.sh is the
        exercise's own `sysctl -w net.ipv6.conf.{all,default}.disable_ipv6=1`; run as shipped
        it would turn IPv6 off for the whole machine, which is not this driver's to do, so it
        is run in the namespaces whose multicast noise it is about.
        """
        for name in self.h.names():
            out = self.h.cmd(name, "sysctl -w net.ipv6.conf.all.disable_ipv6=1 "
                                   "&& sysctl -w net.ipv6.conf.default.disable_ipv6=1")
            say("$ %s: disable_ipv6 -> %s" % (name, out.strip().replace("\n", " | ")))
        self.steps.append(("U1  IPv6 off in every host namespace",
                           "sysctl -w net.ipv6.conf.{all,default}.disable_ipv6=1 in each host",
                           "exercises/multicast/disable_ipv6.sh's two lines, per namespace"))

        # 🔴 FROM A KNOWN CACHE STATE (round-3 ruling 5). See HostRunner.flush_arp.
        flushed = self.h.flush_arp()
        say("$ ip neigh flush all, in each host namespace -> %s" % (", ".join(flushed) or "none"))
        self.steps.append(("ARP caches emptied before the measurement",
                           "ip neigh flush all (each host)", ", ".join(flushed) or "none"))
        pa = self._pingall()
        group = ("h1", "h2", "h3")
        inside = [pa.results.get((s, d)) for s in group for d in group if s != d]
        # 🔴 h4 IS UNREACHABLE IN ONE DIRECTION ONLY (judge A4). sig-topo/s1-runtime.json:36-45
        # installs a mac_forward entry for h4's MAC to port 4 like every other host -- it is
        # only the MULTICAST GROUP (:47-65) that leaves port 4 out. So an ARP request from hX
        # floods to ports 1,2,3 and never reaches h4 (hX -> h4 is 100% loss), while h4's own
        # ARP request floods to 1,2,3 and IS answered, and the unicast reply hits h4's
        # mac_forward entry: h4 -> hX forwards at 0%. Round 1 asserted 100% on all six pairs
        # and would have been red on three of them for a fabric behaving exactly as the
        # exercise describes.
        to_h4 = [r for (s, d), r in sorted(pa.results.items()) if d == "h4"]
        from_h4 = [r for (s, d), r in sorted(pa.results.items()) if s == "h4"]
        inside_ok = bool(inside) and all(r is not None and r.tested and r.loss == 0 for r in inside)
        inside_label = ", ".join("%s" % (r.label() if r else "MISSING") for r in inside)
        h4_blocked = bool(to_h4) and all(r.tested and r.loss == 100 for r in to_h4)
        h4_label = ", ".join(r.label() for r in to_h4)
        h4_out_ok = bool(from_h4) and all(r.tested and r.loss == 0 for r in from_h4)
        h4_out_label = ", ".join(r.label() for r in from_h4)

        self._add("injection: every ordered pair was tested", "0 untested",
                  "%d untested of %d" % (pa.untested, pa.pairs),
                  pa.untested == 0, G_SRC,
                  "an untested pair is not a blocked one; without this 'h4 is unreachable' "
                  "would also describe a host whose namespace could not be entered")

        if self.which == "solution":
            self._add("h1/h2/h3 reach each other", "0% on all 6 pairs", inside_label,
                      inside_ok, G_BOTH,
                      "README step 3; solution/multicast.p4:74-76 floods to mcast_grp 1 and "
                      ":113-114 prunes the ingress copy")
            self._add("nobody reaches h4", "100% on the three hX -> h4 pairs", h4_label,
                      h4_blocked, G_BOTH,
                      "sig-topo/s1-runtime.json:47-65 replicates ports 1,2,3 only -- port 4 is "
                      "README:122's TODO and this driver does not edit the exercise; an ARP "
                      "request for h4 floods to 1,2,3 and h4 never sees it")
            self._add("but h4 reaches them", "0% on the three h4 -> hX pairs", h4_out_label,
                      h4_out_ok, G_SRC,
                      "sig-topo/s1-runtime.json:36-45 DOES give h4's MAC a mac_forward entry "
                      "to port 4; only the group leaves 4 out. h4's own ARP floods to 1,2,3, "
                      "is answered, and the unicast reply hits that entry.")
            # 🔴 AND IT IS NOT AN ARTEFACT OF THE PING ORDER (round-3 ruling 5). The pass above
            # got hX -> h4 right because h4 is last as a source, so nobody had learned its MAC
            # yet. That is true of THIS walk; it would not be true of a dst-major one, nor of a
            # second pingall on the same fabric -- by now h1-h3 DO hold h4's MAC, from the
            # replies they sent it. So: flush again and re-measure just that direction. If the
            # 100% only held because of ordering, this cell is where it shows.
            reflushed = self.h.flush_arp()
            say("$ ip neigh flush all again -> %s; re-measuring the three hX -> h4 pairs"
                % (", ".join(reflushed) or "none"))
            again = [(src, self.h.ping(src, self.h.ips["h4"], 5)) for src in group]
            again_ok = all(r.tested and r.loss == 100 for _s, r in again)
            again_label = ", ".join("%s->h4 %s" % (s, r.label()) for s, r in again)
            self.steps.append(("hX -> h4 re-measured from cold ARP caches",
                               "ip neigh flush all; ping -c 5 -W 2 h4", again_label))
            self._add("and h4 is unreachable from cold caches, not just from this ping order",
                      "100% on all three, after a second flush", again_label, again_ok, G_SRC,
                      "the first pass measured hX -> h4 before h4 had ever ARPed, which this "
                      "walk guarantees only because h4 sorts last as a source; this repeats it "
                      "from a state that does not depend on the order at all")
        else:
            self._add("RED ARM: nothing pings at all", "100.0%", pa.label(),
                      pa.loss == 100, G_BOTH,
                      "README:78-80 'multicast.p4 ... drops all packets on arrival'; "
                      "multicast.p4:91 default_action = drop, so even ARP dies and no host "
                      "ever learns a MAC. If this is red the solution's reachability proves "
                      "nothing.")
        self._log_sizes()

    # ------------------------------------------------------------- qos ----

    def _tos_from(self, text, src):
        """The tos of every sniffed packet whose IP src is `src` -- and of nothing else.

        🔴 qos/receive.py:22 HAS NO BPF FILTER (judge A5). It prints every frame on h2's eth0,
        h2's OWN replies included -- and h2 replies: nothing is listening on UDP/4321, so the
        kernel answers ICMP port-unreachable (tos 0xc0), and the TCP round's SYN to port 80
        gets a RST (tos 0x0). Reading every `tos` line in the capture therefore makes the
        skeleton arm's `set(tos) == {"0x1"}` red over a fabric doing exactly what the exercise
        says, and makes the solution arm's reading a mixture of two hosts' traffic.

        Per PACKET, not per file: `_packets` already splits the capture into one block per
        `got a packet`, so the src and the tos are read out of the same block and cannot come
        from two different frames.
        """
        out = []
        for pkt in self._packets(text):
            head = self._outer_ip(pkt["text"])
            if head is None:
                continue
            m_src = re.search(r"^[|\s]*src\s*=\s*(\S+)\s*$", head, re.M)
            m_tos = re.search(r"^[|\s]*tos\s*=\s*(\S+)\s*$", head, re.M)
            if m_src and m_tos and m_src.group(1) == src:
                out.append(m_tos.group(1))
        return out

    @staticmethod
    def _outer_ip(block):
        """The text of a block's FIRST `###[ IP ]###` layer, up to the next layer header.

        🔴 AN ICMP ERROR CARRIES A SECOND IP HEADER, AND IT IS THE ONE THAT MATCHED
        (TICKET-P3 §9 ruling 20②, from the first live 06). h2 answers the UDP probe with a port
        unreachable whose OUTER header is `src = 10.0.2.2, tos = 0xc0` and whose payload embeds
        the original datagram as `###[ IP in ICMP ]###` with `src = 10.0.1.1, tos = 0x1`. One
        `got a packet` block therefore has two `src =` lines and two `tos =` lines: the old
        filter matched the INNER src (h1, so the block was kept) and then took the FIRST tos it
        found, which is the OUTER 0xc0. `got ['0x1', '0xc0']` -- h2's own error reported as one
        of h1's frames.

        Taking src and tos from the same, outer, header makes the pair consistent: this block
        is h2 -> h1 and is dropped, exactly as a block whose src is h2 always should have been.
        """
        start = re.search(r"^[|\s]*###\[ IP \]###", block, re.M)
        if start is None:
            return None
        rest = block[start.end():]
        nxt = re.search(r"^[|\s]*###\[", rest, re.M)
        return rest[:nxt.start()] if nxt else rest

    def _qos_round(self, proto, tag):
        """One `send.py --p=<proto>` run with h2 sniffing. -> (tos of h1's frames, out, n)."""
        recv, fh, rpath, rcmd = self._start_receiver("h2", "h2-%s" % tag)
        scmd = [VENV_PY, self._script("send.py"), "--p=%s" % proto,
                "--des=%s" % self.ips["h2"], "--m=P4 driver probe", "--dur=%d" % SEND_SECONDS]
        sout = self._send_once("h1", scmd, label="Q%s  h1 send.py --p=%s" % (tag, proto))
        rtext = self._stop_receiver(recv, fh, rpath)
        say("-- h2 (%s) --" % rpath); say(trim(rtext, 3000))
        self.steps.append(("Q%s  h2 sniffer output (%s)" % (tag, proto), rcmd, rtext))
        mine = self._tos_from(rtext, self.ips["h1"])
        say("   tos values on frames from %s: %s   (of %d packet(s) sniffed in total)"
            % (self.ips["h1"], sorted(set(mine)), len(self._packets(rtext))))
        return mine, sout, len(mine)

    def steps_qos(self):
        """exercises/qos, README step 1.6 (skeleton) and step 3 (solution).

        BOTH PROTOCOLS, because the solution's two classes are the exercise: README:110-111
        "you should see tos values change from 0x1 to 0xb9 for UDP and 0xb1 for TCP", and
        solution/qos.p4:208-214 dispatches on hdr.ipv4.protocol. One protocol alone cannot
        tell a fabric that classifies from one that stamps a constant.

        🔴 qos/receive.py:22 HAS NO BPF FILTER -- it prints every frame on eth0, ARP and IPv6
        included -- so the reading is the SET of tos values seen, not "the last packet".
        """
        udp_tos, udp_out, udp_n = self._qos_round("UDP", "1")
        tcp_tos, tcp_out, tcp_n = self._qos_round("TCP", "2")

        self._add("injection: h1's packets reached h2 in both rounds", ">=1 each",
                  "udp=%d tcp=%d" % (udp_n, tcp_n), udp_n >= 1 and tcp_n >= 1, G_SRC,
                  "send.py:40-54 loops for --dur seconds. Counted on frames whose IP src is "
                  "h1: receive.py:22 has no BPF filter, so h2's own ICMP unreachable and RST "
                  "replies are in the same capture and would make a bare count non-zero even "
                  "if nothing arrived from h1")

        if self.which == "solution":
            self._add("UDP is expedited forwarding", "0xb9 among the tos values",
                      str(sorted(set(udp_tos))), "0xb9" in udp_tos, G_BOTH,
                      "README step 3; solution/qos.p4:208-210 calls expedited_forwarding(), "
                      "diffserv 46 -> tos 46<<2 | ecn 1 = 0xb9")
            self._add("TCP is voice admit", "0xb1 among the tos values",
                      str(sorted(set(tcp_tos))), "0xb1" in tcp_tos, G_BOTH,
                      "README step 3; solution/qos.p4:211-213 calls voice_admit(), "
                      "diffserv 44 -> tos 44<<2 | ecn 1 = 0xb1")
        else:
            self._add("RED ARM: UDP tos stays 0x1", "['0x1']", str(sorted(set(udp_tos))),
                      bool(udp_tos) and set(udp_tos) == {"0x1"}, G_BOTH,
                      "README step 1.6: 'the ipv4.tos field is always 1'; qos.p4:138 leaves "
                      "the ingress apply with nothing but ipv4_lpm. Read on h1's frames only: "
                      "h2's own ICMP port-unreachable carries tos 0xc0")
            self._add("RED ARM: TCP tos stays 0x1", "['0x1']", str(sorted(set(tcp_tos))),
                      bool(tcp_tos) and set(tcp_tos) == {"0x1"}, G_BOTH,
                      "the same TODO; h2's RST to the SYN carries tos 0x0, which is why this "
                      "reads h1's frames and not the capture. If either of these is red the "
                      "solution's 0xb9/0xb1 proves nothing")
        self._log_sizes()

    # ------------------------------------------------------ p4runtime -----

    def steps_p4runtime(self):
        """exercises/p4runtime, README step 1.3 (skeleton) and step 3 (solution).

        The .p4 has no TODO: the exercise is the CONTROLLER, and the skeleton's gap is the
        transit rule -- mycontroller.py:76 prints "TODO Install transit tunnel rule" where the
        solution prints "Installed transit tunnel rule on s2" (solution/mycontroller.py:85).

        🔴 THE CONTROLLER'S OWN LOG IS THE INJECTION ASSERTION, and it comes first. README
        step 1.2: "Because there are no rules on the switches, you should not receive any
        replies yet" -- so "h1 cannot ping h2" is true of a controller that never started, of
        a fabric that never came up and of the skeleton alike, and only the pipeline lines in
        the log tell them apart. It is the same rule live-p1/_common.sh's
        controller_program_set enforces for the twin's liveness.
        """
        proc, fh, path, text, alive, ctrl = self._start_controller(self.which, "p4runtime")
        try:
            self._add("injection: the controller stayed up", "alive after %ds" % CTRL_SETTLE,
                      "alive" if alive else "exited", alive, G_SRC,
                      "mycontroller.py:205-212 exits 1 when build/ is missing; a dead "
                      "controller makes every claim below vacuous")
            loaded = sorted(set(int(d) for d in re.findall(
                r"^Installed P4 Program using SetForwardingPipelineConfig on s(\d+)\s*$",
                text, re.M)))
            self._add("switches the controller programmed", "[1, 2]", str(loaded),
                      loaded == [1, 2], G_SRC,
                      "mycontroller.py:142-152 connects to s1 and s2 only; s3 is never "
                      "contacted, which live-p1/03 asserts on the twin's side too")
            ping = self.h.ping("h1", self.ips["h2"], count=5)
            say("$ h1: ping -c5 %s -> %s" % (self.ips["h2"], ping.label()))
            self.steps.append(("P1  h1 ping h2 with the controller running",
                               "ping -c 5 -W 2 %s" % self.ips["h2"], ping.raw or ping.label()))
            transit = "Installed transit tunnel rule" in text
            todo = "TODO Install transit tunnel rule" in text
            if self.which == "solution":
                self._add("the transit rule went in", "Installed transit tunnel rule",
                          "installed" if transit else ("still a TODO" if todo else "neither"),
                          transit, G_SRC, "solution/mycontroller.py:85")
                self._add("h1 -> h2 forwards through the tunnel", "0.0%", ping.label(),
                          ping.tested and ping.loss == 0, G_BOTH,
                          "README step 3: 'You should start to see ICMP replies'")
            else:
                self._add("RED ARM: the transit rule is still the student's TODO",
                          "TODO Install transit tunnel rule",
                          "installed" if transit else ("still a TODO" if todo else "neither"),
                          todo and not transit, G_SRC,
                          "mycontroller.py:76. If the skeleton installed it, the solution's "
                          "green says nothing about the transit rule.")
                self._add("RED ARM: h1 -> h2 does not forward", "100% loss", ping.label(),
                          ping.tested and ping.loss == 100, G_BOTH,
                          "README step 1.3: only s1's ingress counter moves; the packets die "
                          "inside s1 for want of the transit rule")
        finally:
            text = self._stop_controller(proc, fh, path)
            self.steps.append(("P9  controller log after the round", path, text))
        self._log_sizes()

    # ------------------------------------------------------- flowcache ----

    def steps_flowcache(self):
        """exercises/flowcache, README step 1.2 (skeleton) and step 3 (solution).

        🔴 THE SKELETON NEVER REACHES THIS FUNCTION. flowcache.p4:83-91 declares both
        controller headers with no fields while the body reads them (:232, :269-271), so p4c
        refuses it -- README:29 says so -- and spec["red_arm"] == "compile" makes that refusal
        the arm's whole verdict. A run that got here with `--which skeleton` means the
        skeleton COMPILED, which is the finding, and the first expectation below says so.
        """
        if self.which == "skeleton":
            self._add("RED ARM: the skeleton must not compile", "p4c refuses it",
                      "it compiled and the steps ran", False, G_BOTH,
                      "README:29 and flowcache.p4:83-91 vs :232/:269-271. Reaching the data "
                      "plane with the skeleton means the red arm is not red.")
        proc, fh, path, text, alive, ctrl = self._start_controller(self.which, "flowcache")
        try:
            self._add("injection: the controller stayed up", "alive after %ds" % CTRL_SETTLE,
                      "alive" if alive else "exited", alive, G_SRC,
                      "mycontroller.py:546-553 exits 1 when build/ is missing")
            loaded = sorted(set(int(d) for d in re.findall(
                r"^Installed P4 Program using SetForwardingPipelineConfig on s(\d+)\s*$",
                text, re.M)))
            self._add("switches the controller programmed", "[1, 2, 3]", str(loaded),
                      loaded == [1, 2, 3], G_SRC,
                      "mycontroller.py:457-472 connects to s1, s2 and s3")
            ping = self.h.ping("h1", self.ips["h2"], count=5)
            say("$ h1: ping -c5 %s -> %s" % (self.ips["h2"], ping.label()))
            self.steps.append(("W1  h1 ping h2 with the controller running",
                               "ping -c 5 -W 2 %s" % self.ips["h2"], ping.raw or ping.label()))
            text = self._stop_controller(proc, fh, path)
            cached = bool(re.search(r"^For switch s\d+ flow \(SA=.*added table entry", text, re.M))
            self._add("the controller cached the flow it was punted", "a flow_cache entry",
                      "cached" if cached else "no 'added table entry' line", cached, G_SRC,
                      "mycontroller.py:372-376 prints one line per flow it installs; without "
                      "it the ping below would be evidence about something else")
            self._add("h1 -> h2 forwards once the cache is warm", "0.0%", ping.label(),
                      ping.tested and ping.loss == 0, G_BOTH,
                      "README step 3: 'You should start to see ICMP replies'")
        finally:
            if proc.poll() is None:
                text = self._stop_controller(proc, fh, path)
            self.steps.append(("W9  controller log after the round", path, text))
        self._log_sizes()

    # ---------------------------------------------------------------------

    def _log_sizes(self):
        say("")
        say("-- switch logs --")
        for name in sorted(os.listdir(self.log_dir)):
            p = os.path.join(self.log_dir, name)
            if os.path.isfile(p):
                say("   %-52s %d B" % (p, os.path.getsize(p)))


def make_driver(base_cls, exercise, which, exdir, spec, args, ips):
    """Subclass ExerciseRunner, replacing the interactive CLI with scripted steps."""

    class Driver(base_cls):

        def __init__(self, *a, **kw):
            base_cls.__init__(self, *a, **kw)
            self.exdir = exdir
            self.expects = []
            self.steps = []          # (label, command-string, raw-output)

        # run_exercise.py:190-209, but with net.stop() in a finally.
        def run_exercise(self):
            self.create_network()
            try:
                self.net.start()
                time.sleep(1)
                self.program_hosts()
                # 🔴 THE ARM WHOSE RED IS HERE AND NOT IN THE DATA PLANE (TICKET-P3 §2.7).
                # exercises/basic_tunnel's README:41-43 says the starter code's `make run`
                # does not work, because sX-runtime.json names MyIngress.myTunnel_exact and
                # the skeleton declares no such table. That refusal IS the arm, so it is
                # caught and recorded rather than escaping as "the harness blew up" -- which
                # is exit 2, "nothing to look at", and would make the one exercise whose red
                # arm is a control-plane refusal indistinguishable from a broken driver.
                if not self._program_switches_arm():
                    return
                time.sleep(1)
                self.do_net_cli()
            finally:
                rule("net.stop()")
                try:
                    self.net.stop()
                    say("net.stop() returned cleanly")
                except Exception as e:                      # noqa: BLE001
                    say("!! net.stop() raised: %r" % (e,))

        def _program_switches_arm(self):
            """program_switches(), and the designed refusal of the `entries` red arm.

            -> True to go on to the steps, False when the arm is finished here.
            """
            want = spec.get("red_arm") == "entries" and which == "skeleton"
            try:
                self.program_switches()
            except Exception as e:                           # noqa: BLE001
                if not want:
                    raise
                import traceback
                rule("the skeleton's runtime entries")
                say(traceback.format_exc())
                self.expects = [Expect(
                    "RED ARM: the skeleton's runtime entries must NOT install",
                    "the control plane refuses", "%r" % (e,), True, G_BOTH,
                    "README:41-43: 'the control plane tries to access the myTunnel_exact "
                    "table, and that table does not yet exist, [so] the `make run` command "
                    "will not work with the starter code'")]
                self.steps = [("T0  program_switches (the exercise's own sX-runtime.json)",
                               "ExerciseRunner.program_switches()", traceback.format_exc())]
                # 🔴 THE SAME VERDICT THE NDTwin ARM GETS (round-3 ruling 1). The refusal lands
                # here as a harness exception instead of a pre-flight rc, but it is the refusal
                # README:41-43 describes and the arm met every expectation it has. Reporting it
                # as `PASS (1/1)` / exit 0 here while the other fabric says `RED ARM (1/1)` /
                # exit 1 is one exercise reading two ways -- which is what the two-fabric driver
                # exists to make impossible.
                designed_refusal_seen()
                return False
            if want:
                self.expects = [Expect(
                    "RED ARM: the skeleton's runtime entries must NOT install",
                    "the control plane refuses", "every entry went in", False, G_BOTH,
                    "README:41-43. If the skeleton's entries install, the solution's tunnel "
                    "delivery is not evidence that the tunnel table did anything.")]
                self.steps = [("T0  program_switches (the exercise's own sX-runtime.json)",
                               "ExerciseRunner.program_switches()",
                               "it returned cleanly, which this arm says it must not")]
                return False
            return True

        # ---- replaces run_exercise.py:324-363 (which ends in CLI(self.net)) ----
        def do_net_cli(self):
            rule("topology as brought up")
            for s in self.net.switches:
                s.describe()
            for h in self.net.hosts:
                h.describe()
            rule("scripted steps (no CLI, no xterm)")
            hosts = MininetHosts(self.net, ips, cwd=exdir)
            session = Steps(hosts, exercise, which, exdir, self.log_dir, args,
                            fabric="tutorials")
            try:
                session.run()
            finally:
                self.expects = session.expects
                self.steps = session.steps

    return Driver


# ------------------------------------------------------- the ndtwin fabric --


def switch_state(url=PROXY_URL):
    """GET /p4/switch_state, as a dict, or {"error": ...}.

    Disclosure, not a result: what goes in the report is every switch's
    `pipeline.p4info_sha256` and `table_entries` counters, which is how a reader
    of the raw can tell which program each switch was running and how many of the
    package's entries actually went in (TICKET-P2 section 5.6).
    """
    import urllib.request
    try:
        with urllib.request.urlopen(url + "/p4/switch_state", timeout=10) as r:
            return _json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:                                   # noqa: BLE001
        return {"error": "%r" % (e,)}


def switch_state_summary(state):
    """The lines the report carries: per switch, the pipeline sha and the counts."""
    if not isinstance(state, dict) or "error" in state:
        return ["switch_state UNREADABLE: %s" % (state or {}).get("error", "?")]
    cp = state.get("control_plane") or {}
    lines = ["control_plane.mode    %s" % cp.get("mode"),
             "control_plane.package %s" % cp.get("package"),
             "control_plane.skipped %s" % (cp.get("skipped"),)]
    sw = state.get("switches")
    items = sorted(sw.items()) if isinstance(sw, dict) else list(enumerate(sw or []))
    for key, s in items:
        if not isinstance(s, dict):
            continue
        pipe = s.get("pipeline") or {}
        te = s.get("table_entries") or {}
        lines.append("s%s  ndtwin=%s p4info_sha256=%s  entries recorded=%s applied=%s "
                     "failed=%s api_writes=%s  (entries_recorded=%s)"
                     % (key, pipe.get("ndtwin"), pipe.get("p4info_sha256"),
                        te.get("recorded"), te.get("applied"), te.get("failed"),
                        te.get("api_writes"), s.get("entries_recorded")))
    return lines


def ndt(argv, cwd=None, timeout=900):
    """One `ndt` verb, with this run's NDT_OWNER, echoed and captured."""
    cmd = [NDT] + list(argv)
    say("$ NDT_OWNER=%s %s" % (NDT_OWNER, " ".join(cmd)))
    rc, out = run(cmd, cwd=cwd or REPO, timeout=timeout, env=ndt_env())
    say(trim(out, 3000).rstrip())
    return rc, out


def bmv2_identity(status_text):
    """(sha256[:16], label) for the bmv2 binary `ndt status` says this fabric runs.

    🔴 A BENCHMARK NAMES ITS BINARY BY A sha, NOT BY A VERSION STRING (CLAUDE.md; README
    section 3). There are two builds of `simple_switch_grpc` on this laptop and `--version`
    does not tell them apart -- only the hash does, and on the NDTwin fabric this driver does
    not choose which one runs: `ndt up p4` does, through p4_proxy/mininet/bmv2_binary_override.
    So the choice is read back out of `ndt status`'s `bmv2` row (ndt's bmv2_binary(): either an
    absolute path from that override, or the words "simple_switch_grpc (stock, PATH)"), the
    file is hashed, and anything this cannot resolve comes back UNREADABLE **and never as a
    bare "-"**: an empty identity in a run report reads as a binary nobody chose.
    """
    m = re.search(r"^\s*bmv2\s{2,}(.+?)\s*$", status_text or "", re.M)
    if not m:
        return "-", "UNREADABLE: `ndt status` printed no bmv2 row"
    value = m.group(1)
    path = value if value.startswith("/") else None
    if path is None and "stock" in value:
        import shutil
        path = shutil.which("simple_switch_grpc")
    if not path or not os.path.isfile(path):
        return "-", "UNREADABLE: `ndt status` says %r" % value
    try:
        _, ver = run([path, "--version"], timeout=30)
        ver = (ver.strip().splitlines() or [""])[0]
    except (OSError, subprocess.TimeoutExpired):        # noqa: BLE001
        ver = "(--version did not answer)"
    return sha16(path), "%s   (ndt status: %s)" % (ver, value)


def knob_snapshot(path=None):
    """The P4 host knob's BYTES, or None when there is no file.

    🔴 BYTES, NOT THE NUMBER (live-p1/_common.sh:119-131). `host_count_in` skips comments and
    leading whitespace, so the file can read 4 without being the two bytes `4\\n`; writing the
    number back would rewrite a hand-annotated file into a bare number and call it a restore.
    """
    try:
        with open(path or HOST_KNOB, "rb") as f:
            return f.read()
    except OSError:
        return None


def knob_restore(before, path=None):
    """Put the snapshot back.  -> (ok, what happened, in words)."""
    path = path or HOST_KNOB
    now = knob_snapshot(path)
    if now == before:
        return True, "unchanged (%s)" % ("absent" if before is None else "%d bytes" % len(before))
    if before is None:
        try:
            os.remove(path)
        except OSError as e:                             # noqa: BLE001
            return False, "could NOT remove the knob this round created: %r" % (e,)
        return True, "removed (this round created it)"
    try:
        with open(path, "wb") as f:
            f.write(before)
    except OSError as e:                                 # noqa: BLE001
        return False, "could NOT put the knob back: %r" % (e,)
    if knob_snapshot(path) != before:
        return False, "put the knob back and it did NOT take"
    return True, "put back to the %d bytes this round found" % len(before)


def link_usage_applies(spec, which):
    """(run it?, destination host or None, why not) for the generic cell on ONE ndtwin arm.

    🔴 THE CELL NEEDS A FLOW, AND TWO KINDS OF ARM DO NOT HAVE ONE. "Link usage follows the
    iperf path" is a claim about NDTwin and is program-independent -- but it still needs the
    exercise's fabric to carry a packet, and:

      * a SKELETON is, for most of these exercises, a fabric that deliberately forwards
        nothing. Running the cell there produces an EMPTY on-path set, which
        assert_link_usage_follows_path refuses -- correctly, and about the wrong thing;
      * two SOLUTIONS forward nothing either. source_routing's drops every frame without a
        0x1234 stack and calc's drops everything that is not the calculator protocol, both
        in the solution (see their spec entries). Those are properties of the exercise, not
        of the twin.

    🔴 AND "NOT RUN" IS NOT "PASSED". Neither case produces an expectation: the round records
    a named reading saying the cell did not run and why, the way `ndt`'s own NOT CHECKED
    branches do. Inventing a green cell for a fabric that moved no packet is the exact shape
    this whole ticket keeps refusing.
    """
    if which != "solution":
        return False, None, ("the skeleton arm is a fabric the exercise says should not "
                             "forward; there is no path for a program-independent cell to follow")
    want = spec.get("link_usage", True)
    if want is False:
        return False, None, spec.get("link_usage_why") or "this exercise declares no path"
    return True, (want if isinstance(want, str) else None), ""


def link_usage_cell(package, label, out_dir, expect="follows", runner=None, dst=None):
    """The generic cell of TICKET-P3 §2.7, run through live-p1/_common.sh's own helper.

    -> (ok, transcript).  `expect` is "follows" (the cell) or "absent" (the control).

    🔴 ONE INSTRUMENT, TWO CALLERS, AND THIS IS THE SECOND ONE. `link_usage_round` is defined
    in live-p1/_common.sh and live-p1/05 runs it three times; a Python re-implementation here
    would make "the same program-independent cell over thirteen exercises" a comparison
    between two pieces of code that were meant to agree and had no way of saying when they
    stopped. _common.sh defines names and sets variables when sourced and runs nothing until
    start_step, which is what makes it safe to source for one function (the same thing
    tests/shell/test_live_p1_common.sh does).

    🔴 A CELL THAT COULD NOT RUN IS NOT A CELL THAT PASSED. rc 2 from link_usage_round is
    "no namespace / no sudo" -- a permission answer -- and it comes back as a FAILED
    expectation naming that, never as a quiet skip and never as link usage.
    """
    runner = runner or run
    script = ("set -u\n"
              "source %s\n"
              "link_usage_round %s %s %s %s %s\n" % (_sh(LIVE_COMMON), _sh(package),
                                                     _sh(label), _sh(out_dir), _sh(expect),
                                                     _sh(dst or "")))
    rc, out = runner(["bash", "-c", script], cwd=REPO, timeout=240, env=ndt_env())
    say(trim(out, 4000).rstrip())
    return rc == 0, out


def _sh(word):
    """One shell word, quoted. The driver builds exactly one shell command and this is it."""
    return "'" + str(word).replace("'", "'\\''") + "'"


def ndtwin_teardown(knob_before, steps_out=None, telemetry_before=None):
    """`ndt down`, then the host knob, then `ndt release`.  -> "" or what went wrong.

    🔴 THE ORDER IS _common.sh finish()'s, AND THE MIDDLE STEP IS NOT OPTIONAL.
    `ndt up p4 --app` writes the package model's host count into
    p4_proxy/mininet/host_count_override -- exercises/source_routing declares THREE hosts, so
    that file moves off 4 the first time this driver runs that exercise -- `ndt down` does not
    put it back, and `ndt release` REFUSES while it differs from what the round started at
    (ndt:885-898, E-11b). A teardown without the restore therefore ends with the lab still
    claimed by a driver that printed PASS and exited 0, which is the one failure this whole
    step exists to make impossible.
    """
    problems = []
    drc, dout = ndt(["down"])
    say("   ndt down rc=%d" % drc)
    if steps_out is not None:
        steps_out.append(("N9  ndt down", "ndt down", dout))
    if drc != 0:
        problems.append("`ndt down` exited %d" % drc)
    ok, why = knob_restore(knob_before)
    say("   host_count_override: %s" % why)
    if not ok:
        problems.append(why)
    # 🔴 THE TELEMETRY KNOB TOO, and for the reason the host knob is put back rather than the
    # reason `ndt release` gives. `ndt down` does not touch p4_proxy/mininet/telemetry_override
    # (TICKET-P3 §2.1) and `ndt release` does not check it, so nothing refuses over it -- which
    # is exactly why a round that moved it and walked away would decide the NEXT bring-up's
    # telemetry source with nothing on screen saying so. Bytes, not the word, for the same
    # reason as the host knob: the file may be annotated.
    tok, twhy = knob_restore(telemetry_before, TELEMETRY_KNOB)
    say("   telemetry_override: %s" % twhy)
    if not tok:
        problems.append(twhy)
    rrc, rout = ndt(["release"])
    say("   ndt release rc=%d" % rrc)
    if steps_out is not None:
        steps_out.append(("N10 ndt release", "ndt release", rout))
    if rrc != 0:
        problems.append("`ndt release` exited %d -- THE LAB IS STILL CLAIMED" % rrc)
    return "; ".join(problems)


def final_verdict(verdict, exit_code, problem):
    """The verdict line and the exit code, after the teardown has had its say.

    🔴 A ROUND THAT LEFT THE LAB CLAIMED DID NOT PASS. The expectations can all be green and
    the next session still find a lab it cannot take; reporting that as PASS/0 would put the
    reader's attention exactly where the problem is not.
    """
    if not problem:
        return verdict, exit_code
    return "%s -- LAB NOT RETURNED: %s" % (verdict, problem), exit_code or 1


def convert_p4_arg(exdir, spec, which):
    """The `--p4` path: the file that was actually compiled to the DEFAULT stem.

    Only the stem of this argument decides the package's pipelines (convert.py's `_p4_stem`),
    but the path itself is recorded in the package as `source.p4` -- so naming `basic.p4` for a
    package whose build/basic.json is the SOLUTION's compile would be a package that says it
    carries a program nobody ran. `firewall` keeps the skeleton path on purpose: its
    DEFAULT_PROG is basic.p4 and solution/ holds one file, firewall.p4.
    """
    default = spec["default_prog"]
    if which == "solution" and default == spec["prog"]:
        cand = os.path.join("solution", default)
        if os.path.isfile(os.path.join(exdir, cand)):
            return cand
    return default


#: Whether this round ended on the refusal its arm is SUPPOSED to end on (judge A6, and the
#: round-3 ruling that it must read the same on both fabrics). It is neither an error nor a
#: pass: the verdict is `RED ARM (n/n): ... by design` and the exit code is 1 -- the pair
#: `flowcache`'s compile arm has always reported.
#:
#: 🔴 A DICT, AND MODULE-LEVEL, BECAUSE BOTH FABRICS HAVE TO SET IT. Round 2 hung it on
#: `run_on_ndtwin`, which is only reachable from the NDTwin path, and then read it under
#: `args.fabric == "ndtwin"` -- so `basic_tunnel`'s skeleton still printed `PASS (1/1)` / exit 0
#: on tutorials while printing `RED ARM (1/1)` / exit 1 on NDTwin. That is the same defect A6
#: named, half-fixed: ONE EXERCISE MUST NOT READ TWO WAYS ON TWO FABRICS. The tutorials refusal
#: happens inside the harness (`program_switches` raises) rather than in a pre-flight, but it is
#: the same refusal, for the reason README:41-43 gives.
DESIGNED_REFUSAL = {"hit": False}


def designed_refusal_seen():
    """Call when the arm ended on its own designed refusal. Both fabrics call this."""
    DESIGNED_REFUSAL["hit"] = True


def run_on_ndtwin(ex, which, exdir, spec, args, ips, log_dir, steps_out, env=None,
                  red_stage=None):
    """convert -> pre-flight -> claim -> up -> steps -> down -> release.

    🔴 THE TEARDOWN IS IN A `finally` AND IT IS BOTH HALVES, in _common.sh
    finish()'s order: `ndt down` first (it is what removes
    p4_proxy/mininet/app_package_override) and `ndt release` last, because
    release refuses while the checkout is still moved.  A step that raised, a
    pre-flight that refused after the claim was taken, a KeyboardInterrupt --
    all of them come back through here.

    Returns (rc, package_dir, switch_state).  rc 2 = nothing was started.
    """
    pkg = os.path.join(PKG_ROOT, "%s-%s" % (ex, which))
    state = {}

    rule("convert the exercise into an app package")
    if os.path.isdir(pkg):
        import shutil
        shutil.rmtree(pkg)
    os.makedirs(os.path.dirname(pkg), exist_ok=True)
    # --p4 names the Makefile's DEFAULT_PROG, whose STEM is what convert.py uses
    # for every switch that does not name a `program` of its own.  The variant
    # (skeleton or solution) is already compiled to that stem's output names, and
    # convert_p4_arg() is what keeps the recorded source honest about which of
    # the two that was.
    cmd = [PROXY_PY, CONVERT, exdir, "--topology", spec["topo"],
           "--p4", convert_p4_arg(exdir, spec, which), "--out", pkg]
    say("$ " + " ".join(cmd))
    rc, out = run(cmd, cwd=REPO, timeout=600)
    say(trim(out, 3000).rstrip())
    steps_out.append(("N1  convert.py", " ".join(cmd), out))
    if rc != 0:
        say("!! convert.py exited %d -- nothing was started" % rc)
        return 2, pkg, state

    rule("pre-flight the package")
    cmd = [PROXY_PY, PREFLIGHT, pkg]
    say("$ " + " ".join(cmd))
    rc, out = run(cmd, cwd=REPO, timeout=600)
    say(trim(out, 4000).rstrip())
    steps_out.append(("N2  preflight.py", " ".join(cmd), out))
    if rc != 0:
        # 🔴 THE ONE ARM WHOSE RED IS A REFUSAL (TICKET-P3 §2.7). basic_tunnel's skeleton
        # declares no myTunnel_exact and its own sX-runtime.json writes three entries into it
        # (README:41-43), so pre-flight's entries-match-p4info check is where that arm is
        # supposed to stop. Reported as the expectation it is, not as rc 2 "nothing was
        # started" -- which is the answer for a package that is merely broken.
        if red_stage == "entries":
            run_on_ndtwin.expects = [Expect(
                "RED ARM: the skeleton's runtime entries must NOT install",
                "pre-flight refuses them", "pre-flight rc=%d" % rc, True, G_BOTH,
                "README:41-43; tools/p4_exercise/preflight.py checks every entry against the "
                "p4info the package carries, and the skeleton's does not declare that table")]
            # 🔴 THE VERDICT IS THE DESIGNED-REFUSAL ONE, NOT `ERROR` (judge A6). Returning a
            # bare non-zero rc made main() print `ERROR`, because that is what a non-zero round
            # means everywhere else -- while the SAME arm on the tutorials fabric printed
            # `PASS (1/1)`. One exercise reading two different ways on two fabrics is the thing
            # the two-fabric driver exists to make impossible.
            designed_refusal_seen()
            say("!! pre-flight FAILED (rc %d) -- and for this arm that IS the expectation." % rc)
            return 1, pkg, state
        say("!! pre-flight FAILED (rc %d). 'ndt up p4 --app' would refuse this too;"
            " nothing was started." % rc)
        return 2, pkg, state

    # 🔴 THE KNOB IS SNAPSHOT BEFORE THE CLAIM, in bytes, because the teardown has to put it
    # back before `ndt release` will take (ndtwin_teardown's note).
    knob_before = knob_snapshot()
    say("host_count_override snapshot: %s"
        % ("absent" if knob_before is None else "%d bytes (%r)"
           % (len(knob_before), knob_before[:40])))
    # The telemetry knob, snapshot at the same point and for the same reason: `ndt up p4
    # --telemetry` writes it, `ndt down` leaves it, and it decides the next bring-up.
    telemetry_before = knob_snapshot(TELEMETRY_KNOB)
    say("telemetry_override snapshot: %s"
        % ("absent" if telemetry_before is None else "%d bytes (%r)"
           % (len(telemetry_before), telemetry_before[:40])))

    # 🔴 THE CLAIM IS TAKEN HERE, after convert and pre-flight -- neither touches
    # the lab, and a package that will not pre-flight must not have held the lab
    # while it was being rejected. (live-p1/02_app_basic.sh:52-54, same order.)
    rule("claim the lab")
    rc, out = ndt(["claim", CLAIM_MINUTES,
                   "drive_exercise %s/%s on the ndtwin fabric" % (ex, which)])
    if rc != 0:
        say("!! 'ndt claim' would not take -- nothing was started")
        return 2, pkg, state

    exit_code = 0
    run_on_ndtwin.teardown_problem = ""
    try:
        rule("ndt up p4 --app")
        # 🔴 `--telemetry` IS PASSED ONLY WHEN IT WAS ASKED FOR (TICKET-P3 §2.1). Not giving
        # the flag is not the same as giving `auto`: without it `ndt` writes what the PACKAGE
        # declares, and a driver that always spelled a word out would silently overrule every
        # package's own telemetry.source and then report the result as the package's.
        up_argv = ["up", "p4", "--app", pkg]
        if getattr(args, "telemetry", None):
            up_argv += ["--telemetry", args.telemetry]
        rc, out = ndt(up_argv)
        steps_out.append(("N3  ndt up p4 --app", " ".join(["ndt"] + up_argv), out))
        if rc != 0:
            say("!! 'ndt up p4 --app' exited %d" % rc)
            exit_code = 1
            if red_stage == "entries":
                run_on_ndtwin.expects = [Expect(
                    "RED ARM: the skeleton's runtime entries must NOT install",
                    "the bring-up refuses them", "'ndt up p4 --app' exited %d" % rc, True,
                    G_BOTH,
                    "README:41-43; verify_p4_package_entries is the gate that says the "
                    "package's own entries did not go on the switches")]
                designed_refusal_seen()
        else:
            state = switch_state()
            rule("GET /p4/switch_state")
            for line in switch_state_summary(state):
                say("   " + line)
            steps_out.append(("N4  GET /p4/switch_state", PROXY_URL + "/p4/switch_state",
                              _json.dumps(state, indent=2, sort_keys=True)))

            # 🔴 WHICH BMV2 IS RUNNING. The whole `ndt status` is kept as raw, and the binary
            # it names is hashed into the report's tool-chain table -- on this fabric the
            # driver did not choose that binary and `--version` cannot tell the two builds on
            # this laptop apart.
            rule("ndt status (raw; and the bmv2 binary it names)")
            srrc, sout = ndt(["status"])
            steps_out.append(("N5  ndt status", "ndt status (rc=%d)" % srrc, sout))
            sha, label = bmv2_identity(sout)
            say("   bmv2 sha256[:16]=%s  %s" % (sha, label))
            if env is not None:
                env["switch_sha"], env["switch_ver"] = sha, label
                env["switch_path"] = "the bmv2 `ndt status` names"

            rule("scripted steps (no CLI, no xterm)")
            hosts = NdtwinHosts(ips, cwd=exdir)
            say("   " + hosts.describe())
            session = Steps(hosts, ex, which, exdir, log_dir, args, fabric="ndtwin",
                            package=pkg)
            try:
                session.run()
            finally:
                steps_out.extend(session.steps)
                run_on_ndtwin.expects = session.expects
                if red_stage == "entries":
                    run_on_ndtwin.expects = [Expect(
                        "RED ARM: the skeleton's runtime entries must NOT install",
                        "pre-flight or the bring-up refuses them",
                        "the fabric came up and the steps ran", False, G_BOTH,
                        "README:41-43. Nothing refused the skeleton's entries, so the "
                        "solution's tunnel delivery is not evidence about the tunnel table."
                    )] + list(session.expects)

            # 🔴 THE GENERIC CELL, LAST AND ON EVERY EXERCISE (TICKET-P3 §2.7). Everything
            # above is a claim about ONE exercise's program; this one is a claim about
            # NDTwin -- while a flow crosses the fabric the twin's link usage must be
            # non-zero exactly on the interfaces that carried it. It is run after the
            # exercise's own steps so that a failure here cannot be confused with one of
            # theirs, and before the teardown because it needs the fabric.
            rule("G1  link usage follows the iperf path (program-independent)")
            run_it, usage_dst, why = link_usage_applies(spec, which)
            if not run_it:
                say("   NOT RUN: %s" % why)
                say("   (a cell with no flow to follow is recorded as not run, never as a pass)")
                steps_out.append(("N8  G1 link usage follows the iperf path -- NOT RUN",
                                  "live-p1/_common.sh link_usage_round (not called)",
                                  "NOT RUN: %s" % why))
            else:
                usage_dir = os.path.join(log_dir, "link_usage")
                ok, usage_out = link_usage_cell(pkg, "%s/%s" % (ex, which), usage_dir,
                                                dst=usage_dst)
                steps_out.append(("N8  G1 link usage follows the iperf path",
                                  "live-p1/_common.sh link_usage_round %s (to %s)"
                                  % (pkg, usage_dst or "the model's last host"), usage_out))
                run_on_ndtwin.expects = list(run_on_ndtwin.expects) + [Expect(
                    # 🔴 THE STRING SAYS WHAT THE CELL ACTUALLY ASSERTS (round-3 ruling 7).
                    # It said `off-path == 0` -- which is the rule R4 REMOVED, because a single
                    # sampled LLDP beacon (1/256, banked as 256x its frame length) would red a
                    # correct fabric at random. An expectation line that names a bound nobody
                    # applies is worse than none: a reader reconciling a green cell against it
                    # concludes the off-path edges integrated to zero, which they did not.
                    "G1  link usage follows the iperf path",
                    # 🔴 THE WORDS NAME THE THREE CLASSES (§9 ruling 20① + round-3 ruling 7's
                    # principle): a reader reconciling a green cell has to know which rows were
                    # asserted, which were only printed, and which the floor covered.
                    "primary on-path > 0; minor rows printed, not asserted; "
                    "off-path under max(5 kbit, 2% of the smallest PRIMARY on-path)",
                    "PASS" if ok else "see the transcript", ok, G_SRC,
                    "TICKET-P3 §2.7's program-independent cell, through live-p1/_common.sh's "
                    "link_usage_round -- the same function live-p1/05 runs. The floor and every "
                    "off-path edge's raw integral are in that transcript.")]
    finally:
        rule("teardown: ndt down, the two knobs, then ndt release")
        run_on_ndtwin.teardown_problem = ndtwin_teardown(knob_before, steps_out,
                                                         telemetry_before)
        if run_on_ndtwin.teardown_problem:
            say("!! TEARDOWN WAS NOT CLEAN: %s" % run_on_ndtwin.teardown_problem)
    if run_on_ndtwin.teardown_problem and exit_code == 0:
        exit_code = 1
    return exit_code, pkg, state


run_on_ndtwin.expects = []
run_on_ndtwin.teardown_problem = ""


# -------------------------------------------------------------------- report --


def write_report(path, ctx):
    L = []
    a = L.append
    a("# 執行報告 — `%s` / %s" % (ctx["exercise"], ctx["which"]))
    a("")
    a("由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。")
    a("每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。")
    a("")
    a("[Co-developed with claude code -- Adam]")
    a("")
    a("| 欄位 | 值 |")
    a("|---|---|")
    a("| UTC | %s |" % ctx["utc"])
    a("| exercise | `%s` |" % ctx["exercise"])
    a("| which | `%s` |" % ctx["which"])
    a("| fabric | `%s` |" % ctx.get("fabric", "tutorials"))
    a("| package | %s |" % ("`%s`" % ctx["package"] if ctx.get("package") else "— (tutorials harness)"))
    a("| cwd | `%s` |" % ctx["exdir"])
    a("| 直譯器 | `%s` (%s) |" % (sys.executable, sys.version.split()[0]))
    a("| euid | %d |" % euid())
    a("| 判定 | **%s** (exit %d) |" % (ctx["verdict"], ctx["exit"]))
    a("")
    a("## 1. 工具鏈身分")
    a("")
    a("| 執行檔 | sha256[:16] | --version |")
    a("|---|---|---|")
    a("| `%s` | `%s` | %s |" % (ctx["env"].get("switch_path") or SWITCH,
                               ctx["env"]["switch_sha"], ctx["env"]["switch_ver"]))
    a("| `%s` | `%s` | %s |" % (P4C, ctx["env"]["p4c_sha"], ctx["env"]["p4c_ver"]))
    a("")
    a("> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。"
      "此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。")
    a("")
    a("## 2. 編譯")
    a("")
    c = ctx["compile"]
    a("```")
    a("$ " + c.get("cmd", "-"))
    a("rc=%s  warnings=%s" % (c.get("rc"), c.get("warnings")))
    a((c.get("out") or "").rstrip())
    a("```")
    a("")
    if c.get("json"):
        a("| 產物 | bytes | sha256[:16] |")
        a("|---|---|---|")
        a("| `%s` | %d | `%s` |" % (c["json"], c["bytes"], c["sha"]))
        a("| `%s` | %d | `%s` |" % (c["p4info"], os.path.getsize(c["p4info"]),
                                    sha16(c["p4info"])))
        a("")
        a("來源 `.p4`：`%s`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）" % c["src"])
    for extra in ctx.get("compile_extra", []):
        a("")
        a("同時編譯（Makefile 的 `DEFAULT_PROG` / 其他 `*.p4`）：`%s` -> `%s`  sha256[:16]=`%s`"
          % (extra.get("src"), extra.get("json"), extra.get("sha")))
    a("")
    a("## 3. 拓樸")
    a("")
    a("```")
    a(ctx["topo_summary"])
    a("```")
    a("")
    if ctx.get("switch_state"):
        a("### 3b. `GET /p4/switch_state`（揭露，不是結果）")
        a("")
        a("```")
        for line in switch_state_summary(ctx["switch_state"]):
            a(line)
        a("```")
        a("")
    a("## 4. 每一步的指令與原始輸出")
    a("")
    for i, (label, cmd, out) in enumerate(ctx["steps"], 1):
        a("### %d. %s" % (i, label))
        a("")
        a("```")
        a("$ " + str(cmd))
        a("```")
        a("")
        a("```")
        a(trim(out, 6000).rstrip())
        a("```")
        a("")
    a("## 5. 判定表")
    a("")
    a("| 結果 | 期望 | 來源等級 | want | got | 依據 |")
    a("|---|---|---|---|---|---|")
    for e in ctx["expects"]:
        a("| %s | %s | %s | `%s` | `%s` | %s |" % (
            "PASS" if e.ok else "**FAIL**", e.name, e.grade, e.want, e.got, e.note or "-"))
    if not ctx["expects"]:
        a("| — | （沒有跑到任何一步） | — | — | — | — |")
    a("")
    a("## 6. 交換機 log / pcap")
    a("")
    for p in ctx["artifacts"]:
        a("- `%s`" % p)
    a("")
    if ctx["notes"]:
        a("## 7. pre-flight 註記")
        a("")
        for n in ctx["notes"]:
            a("- %s" % n)
        a("")
    a("## 8. 完整 transcript")
    a("")
    a("### stdout")
    a("")
    a("```")
    a(trim(ctx["stdout"], 40000).rstrip())
    a("```")
    a("")
    a("### stderr（mininet 的 logger 走這裡）")
    a("")
    a("```")
    a(trim(ctx["stderr"], 20000).rstrip())
    a("```")
    with open(path, "w") as f:
        f.write("\n".join(L) + "\n")
    # do not leave a root-owned file in Adam's repo
    try:
        if euid() == 0 and os.environ.get("SUDO_UID"):
            os.chown(path, int(os.environ["SUDO_UID"]), int(os.environ["SUDO_GID"]))
            os.chown(os.path.dirname(path), int(os.environ["SUDO_UID"]),
                     int(os.environ["SUDO_GID"]))
    except OSError:
        pass


# ---------------------------------------------------------------------- main --


def sudo_line(exercise, which):
    return "sudo %s %s %s --which %s" % (
        VENV_PY, os.path.abspath(__file__), exercise, which)


def ndtwin_line(exercise, which):
    """The same run on the NDTwin fabric.  No sudo: `ndt` holds the grants."""
    return "%s %s %s --which %s --fabric ndtwin" % (
        VENV_PY, os.path.abspath(__file__), exercise, which)


def main():
    global TEE_OUT, TEE_ERR
    TEE_OUT = Tee(sys.stdout)
    TEE_ERR = Tee(sys.stderr)
    sys.stdout = TEE_OUT
    sys.stderr = TEE_ERR      # must precede `import run_exercise` -> mininet.log

    ap = argparse.ArgumentParser(
        description="Non-interactive driver for one p4lang/tutorials exercise.")
    ap.add_argument("exercise")
    ap.add_argument("--which", choices=["solution", "skeleton"], default="solution")
    ap.add_argument("--fabric", choices=["tutorials", "ndtwin"], default="tutorials",
                    help="tutorials: the exercise's own Mininet harness (needs root). "
                         "ndtwin: convert to an app package and run it on `ndt up p4 --app`.")
    ap.add_argument("--dry-run", action="store_true",
                    help="pre-flight + compile + plan only; no root needed")
    # 🔴 NO DEFAULT, AND THE DEFAULT IS NOT `auto` (TICKET-P3 §2.1). Omitting the flag makes
    # `ndt up p4 --app` write the telemetry source the PACKAGE declares; spelling `auto` out
    # would overrule a package that declared `link` and then report its numbers as the
    # package's. Only meaningful on --fabric ndtwin: the tutorials harness has no NDTwin
    # telemetry at all, and passing it there is refused rather than ignored.
    ap.add_argument("--telemetry", choices=list(TELEMETRY_WORDS), default=None,
                    help="ndtwin fabric only: the telemetry source `ndt up p4` writes into "
                         "p4_proxy/mininet/telemetry_override. Omitted = what the package says.")
    ap.add_argument("--recv-warmup", type=float, default=RECV_WARMUP)
    ap.add_argument("--drain-wait", type=float, default=DRAIN_WAIT)
    args = ap.parse_args()

    ex, which = args.exercise, args.which
    exdir = os.path.join(TUT, "exercises", ex)
    spec = EXERCISES.get(ex)

    say("drive_exercise.py -- %s / %s%s" % (ex, which, "  [DRY RUN]" if args.dry_run else ""))
    say("(non-interactive: no mininet CLI, no xterm; kills nothing)")
    if args.fabric != "tutorials":
        say("fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed")

    if spec is None:
        say("")
        say("!! '%s' is not scripted yet. Scripted: %s" % (ex, ", ".join(sorted(EXERCISES))))
        say("   (the others need their own expectation table first -- see README section 5)")
        return 2

    # 🔴 THE NDTWIN FABRIC IS NOT RUN AS ROOT, and this is a refusal rather than a warning.
    # `ndt` is designed to be run as the operator with passwordless grants for ndtwin-lab and
    # mnexec (tools/test_workflow/sudo_surface.sh); under sudo every file this round writes --
    # .test_run/, the package directory, runs/ -- comes out root-owned, and the operator's next
    # unprivileged `ndt` then cannot read its own state (live-p1/_common.sh:64-71 says the same
    # thing about the same files). Refused before the compile, so nothing has been written yet.
    # 🔴 REFUSED, NOT IGNORED. `--fabric tutorials` builds the exercise's own Mininet: there is
    # no proxy, no kernel and no telemetry_override in it, so a `--telemetry` there would be a
    # word the operator typed, this driver accepted, and nothing read.
    if args.telemetry and args.fabric != "ndtwin":
        say("")
        say("!! --telemetry is an ndtwin-fabric flag: the tutorials harness has no NDTwin")
        say("   telemetry to choose. Drop it, or add --fabric ndtwin.")
        return 2

    if args.fabric == "ndtwin" and euid() == 0:
        say("")
        say("!! refusing: --fabric ndtwin must NOT be run as root (euid 0).")
        say("   `ndt` needs only the two sudoers grants tools/test_workflow/sudo_surface.sh")
        say("   prints; under sudo this round would leave root-owned files in .test_run/ and")
        say("   in runs/, and the operator's next unprivileged `ndt` would fail on them.")
        say("   Run it as yourself:")
        say("   " + ndtwin_line(ex, which))
        return 2

    pf_ok, notes, env = preflight(ex, which, exdir, args.fabric)

    if not pf_ok and not args.dry_run:
        say("")
        say("!! PRE-FLIGHT REFUSED -- nothing was started.")
        return 2

    src, base = pick_source(exdir, spec, which)
    if src is None or not os.path.exists(src):
        say("!! no .p4 source for %s/%s" % (ex, which))
        return 2

    # 🔴 WHICH DESIGNED REFUSAL THIS ARM IS SUPPOSED TO HIT (TICKET-P3 §2.7). Only the skeleton
    # has one; `None` is every other arm, whose red is a data-plane difference.
    red_stage = spec.get("red_arm") if which == "skeleton" else None

    rc, json_out, cinfo = compile_prog(exdir, src, base)
    compile_arm = None
    if red_stage == "compile":
        # exercises/flowcache. The refusal IS the arm, so it is an expectation and not an
        # error: a compile that SUCCEEDED here is the finding, and a report that said
        # "compile failed -- stopping / exit 2" would file the designed case and the broken
        # case under the same code.
        compile_arm = Expect(
            "RED ARM: the skeleton must NOT compile", "p4c refuses it",
            "p4c rc=%d" % rc, rc != 0, G_BOTH,
            "README:29 'you need to define the fields in the packet_in and packet_out "
            "headers; otherwise, you'll get compilation errors'; flowcache.p4:83-91 declares "
            "both with no fields and :232/:269-271 read them")
        rule("red arm")
        say("   " + compile_arm.line())
    elif rc != 0:
        say("!! compile failed -- stopping")
        return 2

    # The other programs this topology names (firewall's s2-s4 run basic.json).
    extra = []
    for esrc, ebase in companion_programs(exdir, spec, which):
        erc, ejson, einfo = compile_prog(exdir, esrc, ebase)
        if erc != 0:
            say("!! companion compile failed (%s) -- stopping" % esrc)
            return 2
        extra.append(einfo)

    default_base = spec["default_prog"][:-3]
    topo_path = os.path.join(exdir, spec["topo"])
    with open(topo_path) as f:
        topo = _json.load(f)
    topo_summary = "topology : %s\nhosts    : %s\nswitches : %s\nlinks    : %d" % (
        spec["topo"], ", ".join(sorted(topo["hosts"])),
        ", ".join(sorted(topo["switches"])), len(topo["links"]))
    ips = host_addresses(exdir, spec)

    rule("plan")
    say(topo_summary)
    say("program  : %s -> build/%s.json" % (src, base))
    say("switch   : %s" % SWITCH)
    say("steps    : %s" % spec["plan_steps"])
    if args.fabric == "tutorials":
        say("equivalent to (cwd must be the exercise dir):")
        say("  cd %s && \\" % exdir)
        say("  sudo %s %s/utils/run_exercise.py -t %s -j build/%s.json -b %s"
            % (VENV_PY, TUT, spec["topo"], default_base, SWITCH))
        say("  ... except do_net_cli() is replaced by the scripted steps above.")
    else:
        pkg = os.path.join(PKG_ROOT, "%s-%s" % (ex, which))
        say("package  : %s" % pkg)
        say("equivalent to (from the repo root, as the operator -- no sudo):")
        say("  %s %s %s --topology %s --p4 %s --out %s" %
            (PROXY_PY, CONVERT, exdir, spec["topo"], spec["default_prog"], pkg))
        say("  %s %s %s" % (PROXY_PY, PREFLIGHT, pkg))
        say("  NDT_OWNER=%s %s claim %s '...' && NDT_OWNER=%s %s up p4 --app %s%s"
            % (NDT_OWNER, NDT, CLAIM_MINUTES, NDT_OWNER, NDT, pkg,
               " --telemetry %s" % args.telemetry if args.telemetry else ""))
        say("  ... the scripted steps above, then `ndt down` and `ndt release`.")
        say("telemetry: %s" % (args.telemetry if args.telemetry
                               else "whatever the package declares (no --telemetry given)"))

    # 🔴 THE ARM THAT ENDS AT THE COMPILER (TICKET-P3 §2.7). exercises/flowcache's skeleton is
    # supposed not to compile, so there is no fabric to bring up either way: with the refusal
    # the arm is red BY DESIGN, and without it the arm is red because the red arm is not red.
    # Both are exit 1 and both write a report; neither is exit 2, which means "nothing to look
    # at on the machine".
    if compile_arm is not None:
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
        verdict = ("RED ARM (1/1): skeleton does not compile, by design" if compile_arm.ok
                   else "FAIL (1/1): the skeleton COMPILED -- the red arm is not red")
        rule("verdict")
        say("   " + compile_arm.line() + "   " + compile_arm.grade)
        say("")
        say(">>> %s" % verdict)
        if not os.path.isdir(RUNS):
            os.makedirs(RUNS)
        rpath = os.path.join(RUNS, "%s_%s_%s%s.md" % (
            stamp, ex, which, "" if args.fabric == "tutorials" else "_ndtwin"))
        out, err = transcript()
        write_report(rpath, {
            "utc": stamp, "exercise": ex, "which": which, "exdir": exdir,
            "fabric": args.fabric, "package": None, "switch_state": {},
            "env": env, "compile": cinfo, "compile_extra": [],
            "topo_summary": topo_summary, "steps": [], "expects": [compile_arm],
            "artifacts": [], "notes": notes, "verdict": verdict, "exit": 1,
            "stdout": out, "stderr": err,
        })
        say("")
        say("report: %s" % rpath)
        return 1

    if args.dry_run:
        rule("dry run stops here")
        say("compile done, nothing was started.  Run it for real with:")
        say("")
        say("  " + (sudo_line(ex, which) if args.fabric == "tutorials"
                    else ndtwin_line(ex, which)))
        say("")
        if not pf_ok:
            say("!! PRE-FLIGHT REFUSED (above) -- fix that first; exit 2")
            return 2
        return 0

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    exit_code = 0
    package = None
    state = {}
    steps = []
    expects = []
    # 🔴 RESET BEFORE THE ROUND, ON EITHER FABRIC. The flag is module state so that both the
    # tutorials harness-exception path and the NDTwin pre-flight path can set it; module state
    # that is never cleared is module state that reports the PREVIOUS round's refusal.
    DESIGNED_REFUSAL["hit"] = False

    if args.fabric == "ndtwin":
        # 🔴 NO ROOT, AND NOT BY OVERSIGHT.  `ndt` is designed to be run as the
        # operator with passwordless grants for ndtwin-lab and mnexec
        # (tools/test_workflow/sudo_surface.sh); running this as root would leave
        # root-owned files in .test_run/ and in runs/, which break the operator's
        # next unprivileged `ndt` (live-p1/_common.sh's require_root note).
        log_dir = os.path.join(RUNS, "%s_%s_%s_ndtwin" % (stamp, ex, which))
        os.makedirs(log_dir, exist_ok=True)
        run_on_ndtwin.expects = []
        try:
            exit_code, package, state = run_on_ndtwin(
                ex, which, exdir, spec, args, ips, log_dir, steps, env, red_stage)
        except Exception as e:                               # noqa: BLE001
            import traceback
            say("!! driver raised: %r" % (e,))
            say(traceback.format_exc())
            exit_code = 2
        expects = run_on_ndtwin.expects
        artifacts = sorted(os.path.join(log_dir, n) for n in os.listdir(log_dir))
    else:
        if euid() != 0:
            say("")
            say("!! needs root (mininet creates namespaces and veth pairs). Run:")
            say("   " + sudo_line(ex, which))
            return 2

        # ---- from here on we are root and about to touch the network namespace ----
        os.chdir(exdir)
        sys.path.insert(0, UTILS)
        from run_exercise import ExerciseRunner          # noqa: E402  (needs cwd+path)

        log_dir = os.path.join(exdir, "logs")
        pcap_dir = os.path.join(exdir, "pcaps")
        Driver = make_driver(ExerciseRunner, ex, which, exdir, spec, args, ips)
        try:
            drv = Driver(spec["topo"], log_dir, pcap_dir,
                         "build/%s.json" % default_base, SWITCH, False)
        except Exception as e:                               # noqa: BLE001
            import traceback
            say("!! could not build the runner: %r" % (e,))
            say(traceback.format_exc())
            return 2

        try:
            drv.run_exercise()
        except SystemExit as e:
            # p4_mininet.py / p4runtime_switch.py call exit(1) when a switch cannot
            # bind its port or did not start; make that visible instead of silent.
            say("!! harness called exit(%s) -- a switch failed to start (ports? orphan bmv2?)" % e.code)
            exit_code = 2
        except Exception as e:                               # noqa: BLE001
            import traceback
            say("!! driver raised: %r" % (e,))
            say(traceback.format_exc())
            exit_code = 2
        steps = drv.steps
        expects = drv.expects
        artifacts = []
        for d in (log_dir, pcap_dir):
            if os.path.isdir(d):
                for n in sorted(os.listdir(d)):
                    artifacts.append(os.path.join(d, n))

    rule("verdict")
    for e in expects:
        say("   " + e.line() + "   " + e.grade)
    failed = [e for e in expects if not e.ok]
    # 🔴 THE DESIGNED REFUSAL HAS ITS OWN VERDICT, and it is the same sentence on both fabrics
    # (judge A6). `basic_tunnel`'s skeleton cannot install its own runtime entries -- README:41-43
    # says so -- and the round therefore ends non-zero having met every expectation it has. On
    # the tutorials fabric the refusal lands as a harness exception and on NDTwin as a pre-flight
    # rc; BOTH set DESIGNED_REFUSAL, and this branch does not ask which fabric it was. Round 2
    # asked, and `basic_tunnel`'s skeleton went on reading two ways (round-3 ruling 1).
    designed = DESIGNED_REFUSAL["hit"]
    if designed and expects and not failed:
        verdict, exit_code = ("RED ARM (%d/%d): the skeleton does not get past the control "
                              "plane, by design" % (len(expects), len(expects))), 1
    elif exit_code == 0:
        if not expects:
            verdict, exit_code = "NO RESULT", 2
        elif failed:
            verdict, exit_code = "FAIL (%d/%d)" % (len(failed), len(expects)), 1
        else:
            verdict = "PASS (%d/%d)" % (len(expects), len(expects))
    else:
        verdict = "ERROR"
    # 🔴 THE TEARDOWN HAS THE LAST WORD. Every expectation can be green and the lab still be
    # claimed -- `ndt release` refuses while the host knob is moved -- and a PASS/0 over that
    # would point the reader at the one place the problem is not.
    if args.fabric == "ndtwin":
        verdict, exit_code = final_verdict(verdict, exit_code, run_on_ndtwin.teardown_problem)
    say("")
    say(">>> %s" % verdict)

    if not os.path.isdir(RUNS):
        os.makedirs(RUNS)
    rpath = os.path.join(RUNS, "%s_%s_%s%s.md" % (
        stamp, ex, which, "" if args.fabric == "tutorials" else "_ndtwin"))
    out, err = transcript()
    write_report(rpath, {
        "utc": stamp, "exercise": ex, "which": which, "exdir": exdir,
        "fabric": args.fabric, "package": package, "switch_state": state,
        "env": env, "compile": cinfo, "compile_extra": extra,
        "topo_summary": topo_summary,
        "steps": steps, "expects": expects, "artifacts": artifacts,
        "notes": notes, "verdict": verdict, "exit": exit_code,
        "stdout": out, "stderr": err,
    })
    say("")
    say("report: %s" % rpath)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
