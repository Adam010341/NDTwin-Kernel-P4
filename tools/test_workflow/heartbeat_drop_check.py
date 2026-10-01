#!/usr/bin/env python3
"""
Does an app package's own program DROP the veth heartbeat's frame? Answered offline, before the
heartbeat is started on an external control plane.

[Co-developed with claude code -- Adam]

WHY. Since 09-27 `ndt up p4 --app` starts the root helper's heartbeat on an external control plane
running its own pipeline (detect only). Its frames (ethertype 0x88B5) enter that program. A program
that punts an unknown ethertype to its controller, floods it, or reports it in a digest hands the
frame to the exercise's own controller or hosts -- which NDTwin cannot see (the proxy has no stream
on an external fabric; the daemon counts only frames leaving switch ports). Adam's ruling (09-28):
default-safe, not default-on -- start the heartbeat there ONLY when this check proves the loaded
program drops the frame.

HOW. For each distinct program the package's switches run (its compiled bmv2 JSON):

  * a throwaway `simple_switch` (the stock build, same bmv2 commit as the fabric's fast build, with
    per-packet logging -- the fast build is compiled without it) runs that JSON with NO controller,
    NO table entries, NO clone session and NO multicast group -- every table answers with its
    default action -- reading and writing pcap files (`--use-files`), so it needs no root and no
    interface;
  * one real heartbeat frame (the daemon's layout, ruling-pinned by a test) is injected on every
    data port the package's model gives the switches running that program;
  * each frame's fate is read from bmv2's own per-packet log, and cross-checked against the pcap
    of every attached port (every data port, and the package's CPU port).

A frame is DROPPED when bmv2 drops it (egress 511 or a drop at the end of egress), or transmits
it only to a port no switch of this fabric has (e.g. advanced_tunnel's default egress 0) and not
the CPU port -- nothing leaves. It is NOT dropped when bmv2 transmits it to a fabric port
(forwarded or flooded), to the CPU port (punted), when the program sends a digest, requests a
clone or a multicast group (a controller configures those later), or when any attached port's
pcap received a frame. Anything the check cannot read -- a frame never processed, a fate never
logged, a switch that exited, an unreadable program -- is UNKNOWN, and unknown is not a drop.

🔴 THE LIMIT, disclosed on every answer: only the program the package declares, and only its
default (table-miss) behaviour, is checked. Entries, clone sessions and multicast groups the
external controller installs later are not covered -- a controller could still send an 0x88B5
frame somewhere by installing a rule for it -- and neither is a pipeline the controller pushes
itself (SetForwardingPipelineConfig with another program) or a default action it changes at
runtime: the answer is about the declared JSON's defaults, nothing the controller does after.

NOT THE LAB. The switch runs as the caller, in its own temporary directory (its pcaps, its log and
its nanomsg socket, `ipc://notif.ipc`, relative to that directory), on a Thrift port chosen from
29400-29499 -- outside every port the lab uses -- and checked free right before the launch, with a
device id far above any fabric's. Its argv[0] is `ndt-hbdrop-bmv2`, so nothing that finds fabric
switches by name or argv (ndt's bmv2_count, the helper's sweep, p4_testbed_topo, the kernel's
capacity scan) counts or reaps it. It is stopped by its exact pid in a `finally`, on SIGTERM/SIGINT/
SIGHUP, and -- through PR_SET_PDEATHSIG -- when this process dies.

CACHE. The answer is kept per program (the JSON's sha256) under
${NDT_HB_CHECK_CACHE:-${XDG_CACHE_HOME:-~/.cache}/ndtwin/heartbeat-drop}, and reused only for the
same ports, CPU port, bmv2 version and check version. UNKNOWN is never cached.

THE SAME bmv2 AS THE FABRIC, checked on every run: the throwaway switch's `--version` must equal
the fabric's (the binary p4_proxy/mininet/bmv2_binary_override names, the one p4_testbed_topo
launches); a version that differs or cannot be read is UNKNOWN. Both version runs carry argv[0]
`ndt-hbdrop-bmv2` and are executed through a symlink of that name, so their comm is not a
fabric switch's either. (Both builds of one commit answer the same version; the check runs the
stock one because the fast one has no per-packet log.)

Usage:  heartbeat_drop_check.py <package dir> [--json <out>]
Exit:   0 every program the package's switches run drops the heartbeat's frame (it may start)
        1 at least one does not (do not start it)
        2 could not tell (do not start it either): an unreadable package or program, a switch
          that exited, a bmv2 version that is not the fabric's, a signal (128+N is kept for
          those), root, and ANY crash of this script -- never Python's own rc 1 for a traceback
        3 refused: not a package this check applies to (no switch runs a program of its own,
          or a program with no data port to inject on)
Env:    NDT_HB_CHECK_BMV2         the simple_switch to run (default /usr/local/bin/simple_switch)
        NDT_HB_CHECK_FABRIC_BMV2  the fabric's binary whose version must match (default: the one
                                  p4_proxy/mininet/bmv2_binary_override names)
        NDT_HB_CHECK_CACHE        the cache directory
"""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "p4_proxy", "mininet"))

try:
    import app_package  # noqa: E402
    import grpc_ports  # noqa: E402
    import topo_from_json  # noqa: E402
    IMPORT_ERROR = None
except Exception as _exc:  # noqa: BLE001 -- main() answers rc 2 with it, never a traceback's rc 1
    IMPORT_ERROR = _exc

CHECK_VERSION = 2
DEFAULT_BMV2 = "/usr/local/bin/simple_switch"
#: Where p4_testbed_topo reads the fabric's binary from (its resolve_bmv2_launcher).
FABRIC_OVERRIDE = os.path.join(REPO, "p4_proxy", "mininet", "bmv2_binary_override")
#: argv[0] of the throwaway switch: not `simple_switch*`, so no by-name or by-argv reader of the
#: fabric's switches (bmv2_count's comm, the helper's sweep, p4_testbed_topo.process_is_a_switch,
#: the kernel's OpenflowCapacityReport scan) takes it for one.
ARGV0 = "ndt-hbdrop-bmv2"
#: Thrift ports to choose from: below the ephemeral range and outside every lab port (ports.sh:
#: 6343, 6633, 6653, 8000, 8080, 8081, 9000, Thrift 9090+N, gRPC 30050+N).
THRIFT_CANDIDATES = range(29400, 29500)
if IMPORT_ERROR is None:
    LAB_PORT_RANGES = ((grpc_ports.THRIFT_PORT_BASE, grpc_ports.THRIFT_PORT_BASE + 512),
                       (grpc_ports.GRPC_PORT_BASE, grpc_ports.GRPC_PORT_BASE + 512),
                       (6343, 6344), (6633, 6634), (6653, 6654), (8000, 8001), (8080, 8082),
                       (9000, 9001))
else:                                   # main() refuses before any port is chosen
    LAB_PORT_RANGES = ((0, 65536),)
#: A fabric's device ids are its dpids (1..N); this is far above any.
DEVICE_ID_BASE = 900000
DROP_PORT = 511
TIMEOUT_S = 20.0
SETTLE_S = 0.4

LIMITS = ("only the declared program's default (table-miss) behaviour was checked: no controller, "
          "no table entries, no clone session, no multicast group. Entries, sessions and groups "
          "the external controller installs later are not covered, and neither is a pipeline it "
          "pushes itself or a default action it changes at runtime.")

# --- the heartbeat's frame: the daemon's layout (tools/test_workflow/ndtwin-lab, hb_program's
#     encode), pinned to it by tests/shell/test_heartbeat_drop_check.sh ------------------------
ETHERTYPE = 0x88B5
DST_MAC = b"\x02NDTHB"
HEAD = struct.Struct("!6s6sH")
BODY = struct.Struct("!4sBB8sHIQHQH")
FRAME_LEN = 60
SESSION = bytes.fromhex("6e64746862636b00")        # "ndthbck\0": no daemon's session


def heartbeat_frame(rx_dpid, rx_port, tx_dpid=0, tx_port=0, seq=1, dir_id=1, src_mac=None,
                    session=SESSION):
    """One frame as the daemon sends it, arriving on (rx_dpid, rx_port)."""
    if src_mac is None:
        src_mac = bytes([0x02, 0x4E, 0x44, 0x00, (rx_dpid >> 8) & 0xFF, rx_port & 0xFF])
    head = HEAD.pack(DST_MAC, src_mac, ETHERTYPE)
    body = BODY.pack(b"NDHB", 1, 0, session, dir_id, seq & 0xFFFFFFFF,
                     tx_dpid, tx_port, rx_dpid, rx_port)
    return (head + body).ljust(FRAME_LEN, b"\0")


def write_pcap(path, frames):
    with open(path, "wb") as fh:
        fh.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        for i, frame in enumerate(frames):
            fh.write(struct.pack("<IIII", 1 + i, 0, len(frame), len(frame)))
            fh.write(frame)


def pcap_frames(path):
    """How many frames a pcap file holds; None when it is missing or not a pcap."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    if len(data) < 24:
        return None if data else 0
    n, off = 0, 24
    while off + 16 <= len(data):
        incl = struct.unpack_from("<I", data, off + 8)[0]
        off += 16 + incl
        n += 1
    return n


# --- what the package asks for -------------------------------------------------------------------
class NotApplicable(Exception):
    """This package runs no program of its own: there is nothing to check."""


def plan(package_dir):
    """[{json, sha256, dpids, ports, cpu_port}] -- one per distinct program the package's own
    switches run. Ports are the union of the data ports (host and inter-switch) the package's
    model gives those switches: the ports the fabric attaches, and so the ports a frame could
    leave by."""
    pkg = app_package.load(package_dir)
    base = os.path.join(REPO, "p4_proxy")
    foreign = [s.dpid for s in pkg.switches if not pkg.pipeline_is_ndtwin(s.dpid, base)]
    if not foreign:
        raise NotApplicable(f"{package_dir}: every switch runs NDTwin's own pipeline")
    model = topo_from_json.load(pkg.topology)
    ports = {}
    for a, ap, b, bp in topo_from_json.switch_links(model):
        ports.setdefault(a, set()).add(ap)
        ports.setdefault(b, set()).add(bp)
    for _host, dpid, port in topo_from_json.host_links(model):
        ports.setdefault(dpid, set()).add(port)
    programs = {}
    for dpid in foreign:
        path = pkg.pipeline_for(dpid, base)[1]
        with open(path, "rb") as fh:
            sha = hashlib.sha256(fh.read()).hexdigest()
        entry = programs.setdefault(sha, {"json": path, "sha256": sha, "dpids": [], "ports": set(),
                                          "cpu_port": pkg.cpu_port})
        entry["dpids"].append(dpid)
        entry["ports"] |= ports.get(dpid, set())
    out = []
    for entry in programs.values():
        entry["ports"] = sorted(entry["ports"])
        if not entry["ports"]:
            # [Co-developed with claude code -- Adam] No port to inject on is no question asked:
            # "every injected frame was dropped" over no frame would be a vacuous pass.
            raise NotApplicable(f"{package_dir}: {os.path.basename(entry['json'])} runs on "
                                f"dpid {','.join(map(str, entry['dpids']))}, which the model gives "
                                f"no data port -- no frame to inject")
        out.append(entry)
    return sorted(out, key=lambda e: e["dpids"])


# --- the throwaway switch ---------------------------------------------------------------------
def outside_lab_ports(port):
    return not any(lo <= port < hi for lo, hi in LAB_PORT_RANGES)


def port_is_free(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("0.0.0.0", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def choose_thrift_port(candidates=THRIFT_CANDIDATES, is_free=None):
    """The first candidate outside the lab's ports that nothing holds, or None."""
    is_free = is_free or port_is_free
    for port in candidates:
        if outside_lab_ports(port) and is_free(port):
            return port
    return None


def binary():
    return os.environ.get("NDT_HB_CHECK_BMV2") or DEFAULT_BMV2


def fabric_binary():
    """The simple_switch_grpc the fabric runs: the first directive of p4_testbed_topo's override
    file (the same rule as its resolve_bmv2_launcher and ndt's bmv2_binary), or None."""
    env = os.environ.get("NDT_HB_CHECK_FABRIC_BMV2")
    if env:
        return env
    try:
        with open(FABRIC_OVERRIDE, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    return line if os.path.isabs(line) else None
    except OSError:
        return None
    return None


def exe_link(directory, target):
    """A symlink named ARGV0 in `directory`, pointing at `target`: executed through it, a process's
    comm is `ndt-hbdrop-bmv2` (the kernel takes comm from the name executed, not from argv[0]).
    [Co-developed with claude code -- Adam]"""
    link = os.path.join(directory, ARGV0)
    if not os.path.lexists(link):
        os.symlink(os.path.abspath(target), link)
    return link


def binary_version(path):
    """`<path> --version`'s first line, or None. [Co-developed with claude code -- Adam] argv[0] is
    ARGV0 and the file executed is a symlink named ARGV0 in a fresh directory, so the process's
    comm is `ndt-hbdrop-bmv2` too: not even a version run of the FABRIC'S binary (comm
    `simple_switch_g` when run by its own name) reads as a fabric switch to ndt's bmv2_count."""
    if not path:
        return None
    tmp = tempfile.mkdtemp(prefix="ndt-hbdrop-ver-")
    try:
        link = exe_link(tmp, path)
        env = dict(os.environ, NDT_HB_CHECK_ARGV0=ARGV0)
        lib = os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(path)), "..", "lib"))
        if os.path.isdir(lib) and os.path.basename(os.path.realpath(path)).startswith("simple_switch_grpc"):
            env["LD_LIBRARY_PATH"] = lib            # p4_testbed_topo's ../lib rule
        out = subprocess.run([ARGV0, "--version"], executable=link, capture_output=True,
                             text=True, timeout=10, env=env, cwd=tmp)
        return (out.stdout or out.stderr).strip().splitlines()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        return None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _die_with_parent():
    """In the child, before exec: SIGKILL when the checker dies (PR_SET_PDEATHSIG = 1)."""
    try:
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGKILL)
    except OSError:
        pass


class Launch:
    """One throwaway switch: launched in its own directory, stopped by its exact pid."""

    def __init__(self, program_json, ports, cpu_port, workdir, thrift_port, device_id,
                 bmv2=None):
        self.workdir = workdir
        self.ports = list(ports)
        self.cpu_port = cpu_port
        self.thrift_port = thrift_port
        self.device_id = device_id
        self.attached = sorted(set(self.ports) | {cpu_port})
        for port in self.attached:
            frames = [heartbeat_frame(0, port)] if port in self.ports else []
            write_pcap(os.path.join(workdir, f"p{port}_in.pcap"), frames)
        self.argv = [ARGV0, "--use-files", "0"]
        for port in self.attached:
            self.argv += ["-i", f"{port}@p{port}"]
        self.argv += ["--thrift-port", str(thrift_port), "--device-id", str(device_id),
                      "--notifications-addr", "ipc://notif.ipc",
                      "--log-file", "bmv2", "--log-level", "debug", "--log-flush",
                      os.path.abspath(program_json)]
        self.executable = bmv2 or binary()
        self.stdout_path = os.path.join(workdir, "stdout.txt")
        self.proc = None

    def start(self):
        if os.geteuid() == 0:
            # [Co-developed with claude code -- Adam] The orchestrator's first condition (09-28).
            raise PermissionError("refusing to launch the throwaway switch as root")
        env = dict(os.environ, NDT_HB_CHECK_ARGV0=ARGV0)
        # [Co-developed with claude code -- Adam] Executed through a symlink named ARGV0 in its own
        # directory: the comm is then `ndt-hbdrop-bmv2` as well, not `simple_switch`.
        os.makedirs(os.path.join(self.workdir, ".bin"), exist_ok=True)
        link = exe_link(os.path.join(self.workdir, ".bin"), self.executable)
        with open(self.stdout_path, "wb") as out:
            self.proc = subprocess.Popen(self.argv, executable=link, cwd=self.workdir,
                                         stdin=subprocess.DEVNULL, stdout=out,
                                         stderr=subprocess.STDOUT, env=env,
                                         preexec_fn=_die_with_parent, start_new_session=True)
        return self

    @property
    def pid(self):
        return None if self.proc is None else self.proc.pid

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def stop(self):
        """TERM, then KILL, by the Popen's own pid -- never by name. Returns the exit status."""
        if self.proc is None:
            return None
        if self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=3)
        return self.proc.returncode

    def log_path(self):
        return os.path.join(self.workdir, "bmv2.txt")


# --- reading bmv2's log -------------------------------------------------------------------------
LINE = re.compile(r"\[(\d+)\.(\d+)\] \[cxt \d+\] (.*)$")


def read_log(path):
    """{packet id: [events]} out of bmv2's per-packet log, and the log's other lines."""
    try:
        with open(path, errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return {}, []
    packets, other = {}, []
    for line in lines:
        m = LINE.search(line)
        if m:
            packets.setdefault((int(m.group(1)), int(m.group(2))), []).append(m.group(3).strip())
        else:
            other.append(line)
    return packets, other


RECEIVED = re.compile(r"^Processing packet received on port (\d+)$")
TRANSMIT = re.compile(r"^Transmitting packet of size \d+ out of port (\d+)$")
ACTION = re.compile(r"^Action entry is (\S+)")
TERMINAL = ("Dropping packet at the end of ingress", "Dropping packet at the end of egress",
            "Multicast requested for packet")
#: Primitives that hand a copy or a report of the packet to something a controller configures.
REPORTING_PRIMITIVES = {"generate_digest": "a digest to the controller",
                        "clone_ingress_pkt_to_egress": "a clone to a mirror session",
                        "clone_egress_pkt_to_egress": "a clone to a mirror session"}


def action_primitives(program_json):
    """{action name: {primitive op}} out of the compiled program."""
    try:
        with open(program_json) as fh:
            program = json.load(fh)
    except (OSError, ValueError):
        return {}
    return {a.get("name"): {p.get("op") for p in a.get("primitives", [])}
            for a in program.get("actions", [])}


def fate(events):
    """Whether one packet copy has finished, from its events."""
    return any(e in TERMINAL or TRANSMIT.match(e) for e in events)


def judge(packets, injected, fabric_ports, cpu_port, primitives, out_frames):
    """(verdict, reason, per_port) from what bmv2 logged and what the pcaps hold.

    verdict: "dropped" | "not_dropped" | "unknown"."""
    per_port, problems, unknown = {}, [], []
    received = {}
    for pid, events in packets.items():
        for e in events:
            m = RECEIVED.match(e)
            if m and pid[1] == 0:
                received.setdefault(int(m.group(1)), []).append(pid[0])
    for port in injected:
        ids = received.get(port)
        if not ids:
            per_port[port] = "never processed"
            unknown.append(f"the frame injected on port {port} was never processed")
            continue
        copies = {pid: ev for pid, ev in packets.items() if pid[0] in ids}
        outcomes, bad = [], []
        for pid, events in sorted(copies.items()):
            for e in events:
                m = TRANSMIT.match(e)
                if m:
                    out = int(m.group(1))
                    if out == cpu_port:
                        bad.append(f"PUNTED to the CPU port {out}")
                    elif out in fabric_ports:
                        bad.append(f"FORWARDED out of fabric port {out}")
                    else:
                        outcomes.append(f"sent to port {out}, which no switch of this fabric has "
                                        f"(nothing leaves)")
                elif e == "Multicast requested for packet":
                    bad.append("MULTICAST requested (a group a controller fills)")
                elif e.startswith("Cloning packet"):
                    bad.append("CLONED (a mirror session a controller configures)")
                elif e.startswith("Dropping packet at the end of"):
                    outcomes.append("dropped")
                am = ACTION.match(e)
                if am:
                    for op in sorted(primitives.get(am.group(1), ())):
                        if op in REPORTING_PRIMITIVES:
                            bad.append(f"{REPORTING_PRIMITIVES[op].upper()} ({op} in "
                                       f"{am.group(1)})")
            if not fate(events):
                unknown.append(f"the frame injected on port {port} has no logged fate "
                               f"(packet {pid[0]}.{pid[1]})")
        if bad:
            per_port[port] = "; ".join(sorted(set(bad)))
            problems.append(f"port {port}: {per_port[port]}")
        else:
            # A copy with no fate is already UNKNOWN above; every fate logged is an outcome or bad.
            per_port[port] = "; ".join(sorted(set(outcomes))) or "no fate logged"
    leaked = {p: n for p, n in out_frames.items() if n}
    unreadable = [p for p, n in out_frames.items() if n is None]
    if leaked:
        problems.append("frames left the switch on attached port(s) "
                        + ", ".join(f"{p} ({n})" for p, n in sorted(leaked.items())))
    if problems:
        return "not_dropped", "; ".join(problems), per_port
    if unreadable:
        unknown.append("no output pcap for port(s) " + ", ".join(map(str, sorted(unreadable))))
    if unknown:
        return "unknown", "; ".join(unknown), per_port
    return ("dropped", "every injected frame was dropped: "
            + "; ".join(f"port {p}: {per_port[p]}" for p in sorted(per_port)), per_port)


def settled(packets, injected, other):
    """The run can stop: every injected frame was read, and every copy has a fate."""
    if not any("end of all input files" in line for line in other):
        return False
    got = {int(RECEIVED.match(e).group(1)) for pid, ev in packets.items() if pid[1] == 0
           for e in ev if RECEIVED.match(e)}
    if not set(injected) <= got:
        return False
    return all(fate(ev) for ev in packets.values())


def check_program(program_json, ports, cpu_port, bmv2=None, tmp_parent=None, timeout=TIMEOUT_S,
                  on_launch=None):
    """Run one program through a throwaway switch. Returns the answer as a dict."""
    exe = bmv2 or binary()
    answer = {"program": os.path.abspath(program_json), "ports": list(ports), "cpu_port": cpu_port,
              "binary": exe, "binary_version": binary_version(exe), "check_version": CHECK_VERSION,
              "limits": LIMITS, "checked_at": int(time.time())}
    with open(program_json, "rb") as fh:
        answer["program_sha256"] = hashlib.sha256(fh.read()).hexdigest()
    if not ports:
        answer.update(verdict="unknown", reason="no data port to inject a frame on: nothing was asked")
        return answer
    workdir = tempfile.mkdtemp(prefix="ndt-hbdrop-", dir=tmp_parent)
    launch = None
    try:
        port = choose_thrift_port()
        if port is None:
            answer.update(verdict="unknown", reason="no free Thrift port in "
                          f"{THRIFT_CANDIDATES.start}-{THRIFT_CANDIDATES.stop - 1}")
            return answer
        device_id = DEVICE_ID_BASE + os.getpid() % 90000
        launch = Launch(program_json, ports, cpu_port, workdir, port, device_id, bmv2=exe)
        # Checked free RIGHT before the launch, not only when it was chosen.
        if not port_is_free(port):
            answer.update(verdict="unknown", reason=f"Thrift port {port} was taken before the launch")
            return answer
        launch.start()
        answer.update(pid=launch.pid, thrift_port=port, device_id=device_id, argv=launch.argv)
        if on_launch is not None:
            on_launch(launch)
        deadline = time.monotonic() + timeout
        packets, other = {}, []
        while time.monotonic() < deadline:
            packets, other = read_log(launch.log_path())
            if settled(packets, ports, other) or not launch.alive():
                break
            time.sleep(0.05)
        if launch.alive():
            time.sleep(SETTLE_S)            # a clone or a recirculation logs after its parent
            packets, other = read_log(launch.log_path())
        exited_early = not launch.alive()
        status = launch.stop()
        answer["exit_status"] = status
        out_frames = {p: pcap_frames(os.path.join(workdir, f"p{p}_out.pcap"))
                      for p in launch.attached}
        verdict, reason, per_port = judge(packets, ports, set(ports), cpu_port,
                                          action_primitives(program_json), out_frames)
        if exited_early and verdict != "not_dropped":
            try:
                with open(launch.stdout_path, errors="replace") as fh:
                    last = [ln for ln in fh.read().splitlines() if ln.strip()][-1:]
            except OSError:
                last = []
            verdict, reason = "unknown", ("the switch exited before the check finished"
                                          + (f": {last[0][:200]}" if last else ""))
        if verdict == "dropped" and not settled(packets, ports, other):
            verdict, reason = "unknown", "the run did not settle within the time allowed"
        answer.update(verdict=verdict, reason=reason, per_port={str(k): v for k, v in
                                                                 per_port.items()})
        return answer
    finally:
        if launch is not None:
            launch.stop()
        shutil.rmtree(workdir, ignore_errors=True)


# --- the cache --------------------------------------------------------------------------------
def cache_dir():
    d = os.environ.get("NDT_HB_CHECK_CACHE")
    if d:
        return d
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "ndtwin", "heartbeat-drop")


def cached(entry, version):
    path = os.path.join(cache_dir(), entry["sha256"] + ".json")
    try:
        with open(path) as fh:
            old = json.load(fh)
    except (OSError, ValueError):
        return None
    same = (old.get("check_version") == CHECK_VERSION and old.get("ports") == entry["ports"]
            and old.get("cpu_port") == entry["cpu_port"] and old.get("binary_version") == version
            and old.get("verdict") in ("dropped", "not_dropped"))
    return old if same else None


def remember(answer):
    if answer.get("verdict") not in ("dropped", "not_dropped"):
        return
    d = cache_dir()
    try:
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, f".{answer['program_sha256']}.{os.getpid()}")
        with open(tmp, "w") as fh:
            json.dump(answer, fh, indent=2, sort_keys=True)
        os.replace(tmp, os.path.join(d, answer["program_sha256"] + ".json"))
    except OSError:
        pass


# --- the command ------------------------------------------------------------------------------
def run(package_dir, out=print):
    """(rc, [answers]) for a package, printing one line per program."""
    try:
        programs = plan(package_dir)
    except NotApplicable as exc:
        out(f"heartbeat drop check: not applicable -- {exc}")
        return 3, []
    except Exception as exc:  # noqa: BLE001 -- an unreadable package is "could not tell"
        out(f"heartbeat drop check: could not read the package ({type(exc).__name__}: {exc})")
        return 2, []
    version = binary_version(binary())
    # [Co-developed with claude code -- Adam] The same bmv2 as the fabric, or no answer: a verdict
    # from another bmv2 version is about another switch (the round-4 review's S-4).
    fabric = fabric_binary()
    fabric_version = binary_version(fabric)
    mismatch = None
    if version is None or fabric_version is None or version != fabric_version:
        mismatch = (f"the check's bmv2 {binary()} answers --version {version!r} and the fabric's "
                    f"{fabric} answers {fabric_version!r}: not the same switch, no answer")
    answers = []
    for entry in programs:
        answer = None if mismatch else cached(entry, version)
        how = "cached"
        if mismatch:
            how = "checked"
            answer = {"program": entry["json"], "program_sha256": entry["sha256"],
                      "verdict": "unknown", "reason": mismatch, "binary_version": version,
                      "fabric_binary": fabric, "fabric_version": fabric_version}
        elif answer is None:
            how = "checked"
            try:
                answer = check_program(entry["json"], entry["ports"], entry["cpu_port"])
            except Exception as exc:  # noqa: BLE001 -- never a pass
                answer = {"program": entry["json"], "program_sha256": entry["sha256"],
                          "verdict": "unknown",
                          "reason": f"the check itself failed ({type(exc).__name__}: {exc})"}
            remember(answer)
        answer["dpids"] = entry["dpids"]
        answers.append(answer)
        out(f"heartbeat drop check ({how}): {os.path.basename(entry['json'])} "
            f"(sha256 {entry['sha256'][:12]}, dpid {','.join(map(str, entry['dpids']))}, ports "
            f"{','.join(map(str, entry['ports']))}, CPU port {entry['cpu_port']}): "
            f"{answer['verdict'].upper()} -- {answer.get('reason')}")
    out(f"  limit: {LIMITS}")
    verdicts = {a["verdict"] for a in answers}
    rc = 1 if "not_dropped" in verdicts else 2 if "unknown" in verdicts else 0
    return rc, answers


def _raise_on_signal(signum, _frame):
    raise SystemExit(128 + signum)


def _main(argv):
    if IMPORT_ERROR is not None:
        print(f"heartbeat drop check: could not tell -- the check could not load its modules "
              f"({type(IMPORT_ERROR).__name__}: {IMPORT_ERROR})")
        return 2
    if os.geteuid() == 0:
        # [Co-developed with claude code -- Adam] The orchestrator's first condition (09-28): the
        # throwaway switch runs as the caller, never as root -- refused, not obeyed under sudo.
        print("heartbeat drop check: could not tell -- refusing to run as root (euid 0); run it "
              "as the user who runs ndt")
        return 2


    if len(argv) not in (2, 4) or (len(argv) == 4 and argv[2] != "--json"):
        print(__doc__.split("Usage:")[1].split("Env:")[0].rstrip(), file=sys.stderr)
        return 3
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, _raise_on_signal)
    rc, answers = run(argv[1])
    if len(argv) == 4:
        with open(argv[3], "w") as fh:
            json.dump({"rc": rc, "limits": LIMITS, "programs": answers}, fh, indent=2,
                      sort_keys=True)
    return rc


def main(argv):
    """_main, with every crash an rc 2 (could not tell) -- never Python's rc 1 for a traceback,
    which ndt would read as "a program does NOT drop it" (the round-4 review's S-4). A signal's
    SystemExit(128+N) passes through; the switch was stopped by check_program's `finally`."""
    try:
        return _main(argv)
    except SystemExit:
        raise
    except BaseException as exc:  # noqa: BLE001 -- KeyboardInterrupt included
        print(f"heartbeat drop check: could not tell -- the check itself crashed "
              f"({type(exc).__name__}: {exc})")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
