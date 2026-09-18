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
    """Return (source .p4 path, output basename) for the requested variant."""
    base = spec["prog"][:-3]                       # what sX-runtime.json names
    if which == "skeleton":
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

    def add(self, src, dst, dst_ip, r):
        self.pairs += 1
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

    def pingall(self, count=5):
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

    def __init__(self, hosts, exercise, which, exdir, log_dir, args, ips=None):
        self.h = hosts
        self.exercise, self.which = exercise, which
        self.exdir, self.log_dir, self.args = exdir, log_dir, args
        self.ips = ips if ips is not None else hosts.ips
        self.expects = []
        self.steps = []          # (label, command-string, raw-output)

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
                self.program_switches()
                time.sleep(1)
                self.do_net_cli()
            finally:
                rule("net.stop()")
                try:
                    self.net.stop()
                    say("net.stop() returned cleanly")
                except Exception as e:                      # noqa: BLE001
                    say("!! net.stop() raised: %r" % (e,))

        # ---- replaces run_exercise.py:324-363 (which ends in CLI(self.net)) ----
        def do_net_cli(self):
            rule("topology as brought up")
            for s in self.net.switches:
                s.describe()
            for h in self.net.hosts:
                h.describe()
            rule("scripted steps (no CLI, no xterm)")
            hosts = MininetHosts(self.net, ips, cwd=exdir)
            session = Steps(hosts, exercise, which, exdir, self.log_dir, args)
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


def ndtwin_teardown(knob_before, steps_out=None):
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


def run_on_ndtwin(ex, which, exdir, spec, args, ips, log_dir, steps_out, env=None):
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
        say("!! pre-flight FAILED (rc %d). 'ndt up p4 --app' would refuse this too;"
            " nothing was started." % rc)
        return 2, pkg, state

    # 🔴 THE KNOB IS SNAPSHOT BEFORE THE CLAIM, in bytes, because the teardown has to put it
    # back before `ndt release` will take (ndtwin_teardown's note).
    knob_before = knob_snapshot()
    say("host_count_override snapshot: %s"
        % ("absent" if knob_before is None else "%d bytes (%r)"
           % (len(knob_before), knob_before[:40])))

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
        rc, out = ndt(["up", "p4", "--app", pkg])
        steps_out.append(("N3  ndt up p4 --app", "ndt up p4 --app %s" % pkg, out))
        if rc != 0:
            say("!! 'ndt up p4 --app' exited %d" % rc)
            exit_code = 1
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
            session = Steps(hosts, ex, which, exdir, log_dir, args)
            try:
                session.run()
            finally:
                steps_out.extend(session.steps)
                run_on_ndtwin.expects = session.expects
    finally:
        rule("teardown: ndt down, the host knob, then ndt release")
        run_on_ndtwin.teardown_problem = ndtwin_teardown(knob_before, steps_out)
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

    rc, json_out, cinfo = compile_prog(exdir, src, base)
    if rc != 0:
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
        say("  NDT_OWNER=%s %s claim %s '...' && NDT_OWNER=%s %s up p4 --app %s"
            % (NDT_OWNER, NDT, CLAIM_MINUTES, NDT_OWNER, NDT, pkg))
        say("  ... the scripted steps above, then `ndt down` and `ndt release`.")

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
                ex, which, exdir, spec, args, ips, log_dir, steps, env)
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
    if exit_code == 0:
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
