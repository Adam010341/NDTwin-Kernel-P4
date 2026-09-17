#!/usr/bin/env python3
"""Non-interactive driver for one p4lang/tutorials exercise.

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

Exit status: 0 every expectation met, 1 some expectation failed,
2 pre-flight refusal / exercise not scripted / harness blew up.

[Co-developed with claude code -- Adam]
"""

import argparse
import datetime
import glob
import hashlib
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

# topo/prog come from each exercise's Makefile (TOPO / DEFAULT_PROG, defaulting
# through utils/Makefile to topology.json and $(wildcard *.p4)).
EXERCISES = {
    "source_routing": {
        "topo": "topology.json",
        "prog": "source_routing.p4",
        "hosts": 3, "switches": 3,
    },
    "basic": {
        "topo": "pod-topo/topology.json",   # exercises/basic/Makefile:5
        "prog": "basic.p4",                 # utils/Makefile:21 wildcard *.p4
        "hosts": 4, "switches": 4,
    },
}

# Evidence grades, verbatim from M7-source_routing.md so the two can be compared
# line by line.  They grade the EXPECTATION's provenance, not the result.
G_SRC    = "\u3010\u6e90\u78bc\u63a8\u5c0e\uff0c\u672a\u57f7\u884c\u3011"
G_README = "\u3010README \u5ba3\u7a31\u3011"
G_BOTH   = "\u3010README \u5ba3\u7a31\u3011\uff0b\u3010\u6e90\u78bc\u63a8\u5c0e\uff0c\u672a\u57f7\u884c\u3011"

RECV_WARMUP  = 3.0    # s to let receive.py get its sniff socket up
DRAIN_WAIT   = 3.0    # s to let the last packet reach the sniffer
SEND_TIMEOUT = 60     # s

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


def run(cmd, cwd=None, timeout=300):
    """Run a command, capture everything, never raise on non-zero."""
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def trim(text, cap=6000):
    if text is None:
        return "(none)"
    if len(text) <= cap:
        return text
    return text[:cap] + "\n... [trimmed; %d chars total]" % len(text)


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


def preflight(ex, which, exdir):
    """Read-only checks.  Returns (ok, notes[]).  Kills nothing, changes nothing."""
    notes = []
    ok = True

    rule("pre-flight (read-only)")

    # 1. thrift ports.  utils/p4runtime_switch.py:20 hard-codes next_thrift_port=9090
    #    and there is no CLI flag in run_exercise.py to move it.
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

    # 2. interpreter.  run_exercise.py imports mininet.* and p4runtime_lib at
    #    module level; only the p4dev venv has mininet+grpc+scapy together.
    real = os.path.realpath(sys.executable)
    if real != os.path.realpath(VENV_PY):
        ok = False
        say("!! FAIL interpreter is %s" % sys.executable)
        say("         must be %s (the only one with mininet+grpc+scapy)" % VENV_PY)
        notes.append("wrong interpreter: %s" % sys.executable)
    else:
        say("OK   interpreter %s (%s)" % (sys.executable, sys.version.split()[0]))

    # 3. bmv2 target.  Version strings do not distinguish the two builds on this
    #    box; only the sha does (README section 3).
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


# ---------------------------------------------------------- scripted drivers --


def make_driver(base_cls, exercise, which, exdir, spec, args):
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
            if exercise == "source_routing":
                self.steps_source_routing()
            elif exercise == "basic":
                self.steps_basic()
            else:                                            # unreachable; guarded in main
                raise RuntimeError("no scripted steps for %s" % exercise)

        # -------------------------------------------------------- utilities --

        def _script(self, name):
            return os.path.join(self.exdir, name)

        def _start_receiver(self, host, tag):
            """receive.py in the host namespace, stdout+stderr into logs/."""
            path = os.path.join(self.log_dir, "driver-%s-receive.log" % tag)
            fh = open(path, "wb")
            cmd = [VENV_PY, self._script("receive.py")]
            say("$ %s: %s   (> %s)" % (host.name, " ".join(cmd), path))
            proc = host.popen(cmd, stdout=fh, stderr=subprocess.STDOUT)
            time.sleep(args.recv_warmup)
            return proc, fh, path, " ".join(cmd)

        def _stop_receiver(self, proc, fh, path):
            time.sleep(args.drain_wait)
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

        # ------------------------------------------------ source_routing ------

        def steps_source_routing(self):
            h1 = self.net.get("h1")
            h2 = self.net.get("h2")

            recv, fh, rpath, rcmd = self._start_receiver(h2, "h2")
            self.steps.append(("S1  h2 starts the sniffer", rcmd, "(background; output below)"))

            # send.py:52-73 loops on input() until the line is exactly "q", so both
            # port lists and the quit go in as one stdin blob and one process run.
            scmd = [VENV_PY, self._script("send.py"), "10.0.2.2"]
            feed = b"2 3 2 2 1\n2 1\nq\n"
            say("$ %s: %s   <<< %r" % (h1.name, " ".join(scmd), feed))
            send = h1.popen(scmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
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

            if which == "solution":
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
            h1 = self.net.get("h1")
            h2 = self.net.get("h2")

            say("$ mininet: net.pingAll(timeout=1)")
            loss = self.net.pingAll(timeout=1)
            say("-> pingAll loss = %s%%" % loss)
            self.steps.append(("B1  net.pingAll(timeout=1)", "net.pingAll(timeout=1)",
                               "loss = %s%%" % loss))

            pcmd = "ping -c 3 -W 1 10.0.2.2"
            say("$ %s: %s" % (h1.name, pcmd))
            pout = h1.cmd("LANG=C " + pcmd)
            say(pout.rstrip())
            self.steps.append(("B2  h1 ping -c3 h2", pcmd, pout))
            m = re.search(r"(\d+) packets transmitted, (\d+) received", pout)
            rx = int(m.group(2)) if m else -1

            recv, fh, rpath, rcmd = self._start_receiver(h2, "h2")
            self.steps.append(("B3  h2 starts the sniffer", rcmd, "(background; output below)"))
            # basic/send.py:27-38 takes <dst> "<message>" as argv and sends once.
            scmd = [VENV_PY, self._script("send.py"), "10.0.2.2", "P4 driver probe"]
            say("$ %s: %s" % (h1.name, " ".join(scmd)))
            send = h1.popen(scmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
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

            emitted = 1 if re.search(r"sending on interface .* to 10\.0\.2\.2", sout) else 0
            self._add("injection: send.py emitted 1 TCP frame", "1", str(emitted),
                      emitted == 1, G_SRC,
                      "basic/send.py:34 prints before sendp(); dport 1234 is what receive.py filters on")

            pkts = self._packets(rtext)

            if which == "solution":
                self._add("pingAll packet loss", "0.0%", "%s%%" % loss,
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
                self._add("pingAll packet loss", "100.0%", "%s%%" % loss,
                          loss == 100, G_BOTH,
                          "see the derivation in DRIVER.md: basic.p4:66-74 / :119-129 / :147 / :202-211")
                self._add("h1 ping -c3 h2 received", "0", str(rx),
                          rx == 0, G_SRC)
                self._add("h2 got the send.py packet", "0", str(len(pkts)),
                          len(pkts) == 0, G_SRC)

            self._log_sizes()

        # ---------------------------------------------------------------------

        def _log_sizes(self):
            say("")
            say("-- switch logs --")
            for name in sorted(os.listdir(self.log_dir)):
                p = os.path.join(self.log_dir, name)
                if os.path.isfile(p):
                    say("   %-52s %d B" % (p, os.path.getsize(p)))

    return Driver


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
    a("| cwd | `%s` |" % ctx["exdir"])
    a("| 直譯器 | `%s` (%s) |" % (sys.executable, sys.version.split()[0]))
    a("| euid | %d |" % os.geteuid())
    a("| 判定 | **%s** (exit %d) |" % (ctx["verdict"], ctx["exit"]))
    a("")
    a("## 1. 工具鏈身分")
    a("")
    a("| 執行檔 | sha256[:16] | --version |")
    a("|---|---|---|")
    a("| `%s` | `%s` | %s |" % (SWITCH, ctx["env"]["switch_sha"], ctx["env"]["switch_ver"]))
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
    a("")
    a("## 3. 拓樸")
    a("")
    a("```")
    a(ctx["topo_summary"])
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
        if os.geteuid() == 0 and os.environ.get("SUDO_UID"):
            os.chown(path, int(os.environ["SUDO_UID"]), int(os.environ["SUDO_GID"]))
            os.chown(os.path.dirname(path), int(os.environ["SUDO_UID"]),
                     int(os.environ["SUDO_GID"]))
    except OSError:
        pass


# ---------------------------------------------------------------------- main --


def sudo_line(exercise, which):
    return "sudo %s %s %s --which %s" % (
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

    if spec is None:
        say("")
        say("!! '%s' is not scripted yet. Scripted: %s" % (ex, ", ".join(sorted(EXERCISES))))
        say("   (the others need their own expectation table first -- see README section 5)")
        return 2

    pf_ok, notes, env = preflight(ex, which, exdir)

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

    topo_path = os.path.join(exdir, spec["topo"])
    import json as _json
    with open(topo_path) as f:
        topo = _json.load(f)
    topo_summary = "topology : %s\nhosts    : %s\nswitches : %s\nlinks    : %d" % (
        spec["topo"], ", ".join(sorted(topo["hosts"])),
        ", ".join(sorted(topo["switches"])), len(topo["links"]))

    rule("plan")
    say(topo_summary)
    say("program  : %s -> build/%s.json" % (src, base))
    say("switch   : %s" % SWITCH)
    say("steps    : %s" % ("h2 receive.py; h1 send.py 10.0.2.2 with '2 3 2 2 1' then '2 1'; "
                           "assert packet count + ttl"
                           if ex == "source_routing" else
                           "net.pingAll; h1 ping -c3 h2; h1 send.py -> h2 receive.py; assert loss"))
    say("equivalent to (cwd must be the exercise dir):")
    say("  cd %s && \\" % exdir)
    say("  sudo %s %s/utils/run_exercise.py -t %s -j build/%s.json -b %s"
        % (VENV_PY, TUT, spec["topo"], base, SWITCH))
    say("  ... except do_net_cli() is replaced by the scripted steps above.")

    if args.dry_run:
        rule("dry run stops here")
        say("compile done, nothing was started.  Run it for real with:")
        say("")
        say("  " + sudo_line(ex, which))
        say("")
        if not pf_ok:
            say("!! PRE-FLIGHT REFUSED (above) -- fix that first; exit 2")
            return 2
        return 0

    if os.geteuid() != 0:
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
    Driver = make_driver(ExerciseRunner, ex, which, exdir, spec, args)
    try:
        drv = Driver(spec["topo"], log_dir, pcap_dir, "build/%s.json" % base, SWITCH, False)
    except Exception as e:                                   # noqa: BLE001
        import traceback
        say("!! could not build the runner: %r" % (e,))
        say(traceback.format_exc())
        return 2

    exit_code = 0
    try:
        drv.run_exercise()
    except SystemExit as e:
        # p4_mininet.py / p4runtime_switch.py call exit(1) when a switch cannot
        # bind its port or did not start; make that visible instead of silent.
        say("!! harness called exit(%s) -- a switch failed to start (ports? orphan bmv2?)" % e.code)
        exit_code = 2
    except Exception as e:                                   # noqa: BLE001
        import traceback
        say("!! driver raised: %r" % (e,))
        say(traceback.format_exc())
        exit_code = 2

    rule("verdict")
    for e in drv.expects:
        say("   " + e.line() + "   " + e.grade)
    failed = [e for e in drv.expects if not e.ok]
    if exit_code == 0:
        if not drv.expects:
            verdict, exit_code = "NO RESULT", 2
        elif failed:
            verdict, exit_code = "FAIL (%d/%d)" % (len(failed), len(drv.expects)), 1
        else:
            verdict = "PASS (%d/%d)" % (len(drv.expects), len(drv.expects))
    else:
        verdict = "ERROR"
    say("")
    say(">>> %s" % verdict)

    artifacts = []
    for d in (log_dir, pcap_dir):
        if os.path.isdir(d):
            for n in sorted(os.listdir(d)):
                artifacts.append(os.path.join(d, n))

    if not os.path.isdir(RUNS):
        os.makedirs(RUNS)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    rpath = os.path.join(RUNS, "%s_%s_%s.md" % (stamp, ex, which))
    out, err = transcript()
    write_report(rpath, {
        "utc": stamp, "exercise": ex, "which": which, "exdir": exdir,
        "env": env, "compile": cinfo, "topo_summary": topo_summary,
        "steps": drv.steps, "expects": drv.expects, "artifacts": artifacts,
        "notes": notes, "verdict": verdict, "exit": exit_code,
        "stdout": out, "stderr": err,
    })
    say("")
    say("report: %s" % rpath)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
