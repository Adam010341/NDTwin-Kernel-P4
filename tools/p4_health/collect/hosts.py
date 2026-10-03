"""The stimulus side: markers sent from one host's namespace, sniffed in another's. (Cut 2)

[Co-developed with claude code -- Adam]

Every command goes through the injected Runner (design 4.1): a host is entered with
`sudo -n mnexec -a <pid>` (design 4.2), the pid found by the tail-field rule (fabric.host_pid,
drive_exercise.py:1024-1038), and what runs inside is tools/p4_health/hostside.py under the p4dev
interpreter. A sniffer is a long-lived child: it is started with Runner.spawn, recorded in
LAB_STATE.json through `register` (pid + start time + the run's marker token) the moment its pid
is known, and stops by itself after its window; the round's teardown stops it if a crash comes
first. `sent` is always what the SENDER printed (collect/sniff.py), never what was asked for.
"""
from __future__ import annotations

import hashlib
import os
import time

from . import fabric as FB
from . import ps as PS

HOSTSIDE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hostside.py")


#: What root executes, relative to tools/p4_health: hostside.py and what it imports.
ROOT_CODE = ("hostside.py", "frames.py", "__init__.py")


def freeze_root_code(run_dir, src=None):
    """(Cut 2 second review N8) Copy the files root executes into <run>/rootcode/p4_health/ and
    return ({name: sha256}, the frozen hostside.py). Root then runs these copies for the whole
    run, whatever the shared working tree does meanwhile, and health.json records exactly what
    they were."""
    import hashlib
    import shutil
    src = src or os.path.dirname(HOSTSIDE)
    dst = os.path.join(run_dir, "rootcode", "p4_health")
    os.makedirs(dst, exist_ok=True)
    sums = {}
    for name in ROOT_CODE:
        shutil.copyfile(os.path.join(src, name), os.path.join(dst, name))
        with open(os.path.join(dst, name), "rb") as fh:
            sums[name] = hashlib.sha256(fh.read()).hexdigest()
    return sums, os.path.join(dst, "hostside.py")


def marker_token(run_id):
    """The 8 characters a marker carries for this run (frames.payload keeps 8 bytes)."""
    return hashlib.sha1(run_id.encode("utf-8")).hexdigest()[:8]


class Hosts(object):
    """The hosts of one bring-up. `model` is the exercise's generator module (gen_runtime): its
    host_ip / host_mac and the gateway MAC rule of topology.json."""

    def __init__(self, cfg, runner, run_id, out_dir, model, register=None, hostside=HOSTSIDE,
                 sleep=time.sleep, clock=time.monotonic, ready_timeout=10.0):
        self.cfg, self.runner, self.model = cfg, runner, model
        self.token = marker_token(run_id)
        self.out_dir = out_dir
        self.register = register
        self.hostside = hostside
        self.sleep, self.clock = sleep, clock
        self.ready_timeout = ready_timeout
        self._pids = None
        self.problems = []
        self.n = 0

    # --- addresses --------------------------------------------------------------------------
    @staticmethod
    def num(host):
        return int(str(host).lstrip("h"))

    def ip(self, host):
        return self.model.host_ip(self.num(host))

    def mac(self, host):
        return self.model.host_mac(self.num(host))

    def gw_mac(self, host):
        """topology.json's static ARP entry for the host's gateway: 08:00:00:00:<h>:00."""
        return "08:00:00:00:%02x:00" % self.num(host)

    # --- namespaces ----------------------------------------------------------------------------
    def pids(self):
        if self._pids is None:
            lines = PS.ps_lines(self.runner)
            self._pids = {"h%d" % h: FB.host_pid(lines, "h%d" % h) for h in sorted(self.model.HOSTS)}
        return self._pids

    def root_python(self):
        """The p4dev interpreter as root runs it: -B writes no .pyc beside the probe's sources,
        -X pycache_prefix keeps any read cache under the run, -I takes nothing from the
        environment or the user's site (Cut 2 review w1)."""
        return [self.cfg.p4dev_python, "-B", "-X", "pycache_prefix=%s" % os.path.join(self.out_dir, "pycache"),
                "-I"]

    def in_ns(self, host, argv):
        pid = self.pids().get(host)
        if pid is None:
            return None
        return ["sudo", "-n", "mnexec", "-a", str(pid)] + list(argv)

    def run_in(self, host, argv, timeout=60):
        """stdout of a command inside `host`'s namespace, or None (no pid, or it failed)."""
        full = self.in_ns(host, argv)
        if full is None:
            return None
        res = self.runner.run(full, timeout=timeout)
        return res.stdout if res.rc == 0 else None

    # --- markers -----------------------------------------------------------------------------
    def send(self, src, dst, cell, dport, count, sport=40000, ttl=64, ident=1, pps=500.0):
        """The sender's stdout (its SENT line is the count), or "" when it could not run."""
        argv = self.in_ns(src, self.root_python() + [self.hostside, "send", "--run", self.token,
                                "--cell", cell, "--count", str(int(count)), "--pps", str(pps),
                                "--src-mac", self.mac(src), "--dst-mac", self.gw_mac(src),
                                "--src-ip", self.ip(src), "--dst-ip", self.ip(dst),
                                "--dport", str(int(dport)), "--sport", str(int(sport)),
                                "--ttl", str(int(ttl)), "--ident", str(int(ident))])
        if argv is None:
            self.problems.append("no namespace pid for %s" % src)
            return ""
        res = self.runner.run(argv, timeout=60 + count / max(pps, 1.0))
        return res.stdout

    def sniff_start(self, host, cells, dport, seconds, until=0):
        """A sniffer on `host` for this run's markers of `cells` -- UDP to `dport` addressed to
        the host itself (MAJOR-2: not the ICMP errors that quote them)."""
        argv = self.in_ns(host, self.root_python() + [self.hostside, "sniff", "--run", self.token,
                                                      "--cells", ",".join(cells), "--seconds", str(seconds),
                                                      "--until", str(int(until)), "--dport", str(int(dport)),
                                                      "--ip", self.ip(host)])
        if argv is None:
            self.problems.append("no namespace pid for %s" % host)
            return None
        self.n += 1
        path = os.path.join(self.out_dir, "sniff.%03d.%s.txt" % (self.n, host))
        proc = self.runner.spawn(argv, path)
        if proc is None:
            self.problems.append("the sniffer on %s could not be started" % host)
            return None
        if self.register is not None:
            try:
                self.register("sniffer", proc.pid, self.token)
            except ValueError as exc:
                self.problems.append("sniffer on %s not recorded: %s" % (host, exc))
        return {"host": host, "proc": proc, "path": path, "seconds": seconds}

    def _read(self, path):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                return fh.read()
        except OSError:
            return None

    def wait_ready(self, handle):
        deadline = self.clock() + self.ready_timeout
        while True:
            text = self._read(handle["path"]) or ""
            if "READY" in text:
                return True
            if handle["proc"].poll() is not None or self.clock() >= deadline:
                return False
            self.sleep(0.1)

    def sniff_wait(self, handle):
        """The sniffer's output once it has finished its window; None when it never got ready or
        its output is unreadable (unreadable is not "nothing arrived")."""
        if handle is None:
            return None
        try:
            handle["proc"].wait(timeout=handle["seconds"] + 30)
        except Exception:  # noqa: BLE001 -- a sniffer that will not end is the teardown's to stop
            self.problems.append("the sniffer on %s did not end" % handle["host"])
            return None
        text = self._read(handle["path"])
        if text is None or "READY" not in text:
            return None
        return text

    def window(self, sniffs, stimulate, seconds=4.0, until=0):
        """Start a sniffer per (host, cells, dport), wait until each listens, run `stimulate()`
        (the sender stdout it returns is kept), and collect every sniffer. A sniffer ends after
        `seconds`, or as soon as it has `until` records (0: no early end). -> (sent stdout,
        {host: sniffer stdout or None})."""
        handles = [self.sniff_start(h, cells, dport, seconds, until) for h, cells, dport in sniffs]
        ready = [h is not None and self.wait_ready(h) for h in handles]
        out = stimulate() if all(ready) else ""
        got = {}
        for (host, _cells, _dport), handle, ok in zip(sniffs, handles, ready):
            got[host] = self.sniff_wait(handle) if ok else None
        return out, got
