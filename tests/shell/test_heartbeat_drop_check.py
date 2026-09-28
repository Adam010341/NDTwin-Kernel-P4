#!/usr/bin/env python3
"""
tools/test_workflow/heartbeat_drop_check.py, driven for real: a throwaway stock `simple_switch`
runs each program, one heartbeat frame per data port, no controller.

[Co-developed with claude code -- Adam]

Adam's ruling (09-28): on an external control plane the heartbeat is default-SAFE -- it starts only
when this check proves the program drops the heartbeat's frame. What is asserted, and against what:

  1. the frame the check injects IS the daemon's frame (the root helper's encode, byte for byte);
  2. the three programs live-p1/06's external arms load -- advanced_tunnel (p4runtime skeleton and
     solution) and flowcache's solution -- are DROPPED, end to end through a converted package;
  3. a program that floods, punts, digests, clones or multicasts an unknown ethertype is NOT
     dropped, each named for what it did, and a package running one is rc 1;
  4. the judgement itself, on made-up logs: a pcap that holds a frame outranks a log that says
     dropped, and anything unread is UNKNOWN -- never a drop;
  5. rc 2 when the check cannot tell (an unreadable package, a switch that exits), rc 3 when there
     is nothing to check;
  6. the cache: reused for the same program and ports only, UNKNOWN never kept;
  7. NOT THE LAB (the orchestrator's conditions, 09-28): no root; its socket and pcaps in its own
     directory; a Thrift port outside the lab's, checked free right before the launch; a device id
     no fabric has; stopped by its exact pid, and killed with the checker; and, while it runs,
     nothing that finds the fabric's switches by name or argv takes it for one.

Every cell here launches the real /usr/local/bin/simple_switch (NDT_HB_CHECK_BMV2 overrides it; the
gates point it at a wrapper that records each launch in their tripwire).

Run:  python3 tests/shell/test_heartbeat_drop_check.py
Env:  CHECK_UNDER_TEST=<path to a copy of the tool>   (the mutation gate), HELPER_UNDER_TEST
Exit: 0 every check passed, 1 some check failed
"""

import ast
import importlib.util
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TOOL = os.environ.get("CHECK_UNDER_TEST") or os.path.join(REPO, "tools/test_workflow/heartbeat_drop_check.py")
HELPER = os.environ.get("HELPER_UNDER_TEST") or os.path.join(REPO, "tools/test_workflow/ndtwin-lab")
NDT = os.path.join(REPO, "tools/test_workflow/ndt")
FIX = os.path.join(REPO, "tests/fixtures/heartbeat_drop")
AT_JSON = os.path.join(REPO, "tools/p4_exercise/tests/fixtures/p4runtime/build/advanced_tunnel.json")
P4RT_EXERCISE = os.path.join(REPO, "tools/p4_exercise/tests/fixtures/p4runtime")

PASS = FAIL = 0


def ok(name):
    global PASS
    PASS += 1
    print(f"  ok       {name}")


def bad(name, detail):
    global FAIL
    FAIL += 1
    print(f"  FAILED   {name}\n             {detail}")


def check(name, expected, actual):
    ok(name) if expected == actual else bad(name, f"expected: [{expected}] / actual: [{actual}]")


def has(name, needle, hay):
    ok(name) if needle in (hay or "") else bad(name, f"no match for: [{needle}] in: [{(hay or '')[:300]}]")


def hasnt(name, needle, hay):
    bad(name, f"unexpected: [{needle}]") if needle in (hay or "") else ok(name)


def section(title):
    print(f"\n{title}")


spec = importlib.util.spec_from_file_location("hbcheck", TOOL)
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

WORK = tempfile.mkdtemp(prefix="hbdrop-test-")
os.environ["NDT_HB_CHECK_CACHE"] = os.path.join(WORK, "cache")


def run_quiet(pkg):
    lines = []
    rc, answers = c.run(pkg, out=lines.append)
    return rc, answers, "\n".join(lines)


def convert(out, program_json=None):
    """exercises/p4runtime, converted the way live-p1/06 converts it -- and optionally its
    program swapped for another compiled one (same package, different program)."""
    r = subprocess.run([sys.executable, os.path.join(REPO, "tools/p4_exercise/convert.py"),
                        P4RT_EXERCISE, "--topology", "topology.json", "--p4", "advanced_tunnel.p4",
                        "--out", out], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stdout + r.stderr)
    if program_json:
        shutil.copyfile(program_json, os.path.join(out, "build", "advanced_tunnel.json"))
    return out


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        with open(f"/proc/{pid}/stat") as fh:
            return fh.read().split(")")[-1].split()[0] != "Z"
    except OSError:
        return False


try:
    # =============================================================================================
    section("1. the injected frame is the daemon's frame")
    # =============================================================================================
    src = open(HELPER).read()
    start = src.index("hb_program() {\n    cat <<'NDTWIN_LAB_HEARTBEAT_PY'\n")
    body = src[start:].split("\n", 2)[2]
    body = body[:body.index("\nNDTWIN_LAB_HEARTBEAT_PY\n")]
    hb = {"__name__": "ndtwin_lab_heartbeat"}
    exec(compile(body, "ndtwin-lab:hb_program", "exec"), hb)
    d = hb["Direction"](7, hb["Port"]("s1", 1, 2, "s1-eth2"), hb["Port"]("s2", 2, 3, "s2-eth3"))
    mac = bytes.fromhex("020000aa0102")
    session = bytes.fromhex("0102030405060708")
    check("🔴 byte for byte the daemon's encode()",
          hb["encode"](d, session, 41, mac).hex(),
          c.heartbeat_frame(2, 3, tx_dpid=1, tx_port=2, seq=41, dir_id=7, src_mac=mac,
                            session=session).hex())
    check("  its ethertype, destination and length", (hb["ETHERTYPE"], hb["DST_MAC"], hb["FRAME_LEN"]),
          (c.ETHERTYPE, c.DST_MAC, c.FRAME_LEN))
    check("  and the daemon decodes it as one of its own", 3,
          getattr(hb["decode"](c.heartbeat_frame(2, 3)), "rx_port", None))

    # =============================================================================================
    section("2. 🔴 the three programs live-p1/06's external arms load drop it")
    # =============================================================================================
    a = c.check_program(AT_JSON, [1, 2, 3], 255, tmp_parent=WORK)
    check("🔴 advanced_tunnel (p4runtime skeleton and solution): DROPPED", "dropped", a["verdict"])
    has("  sent to port 0, which no switch of the fabric has", "sent to port 0, which no switch",
        a.get("per_port", {}).get("1"))
    a = c.check_program(os.path.join(FIX, "flowcache_solution.json"), [1, 2, 3], 510, tmp_parent=WORK)
    check("🔴 flowcache's solution: DROPPED", "dropped", a["verdict"])
    has("  dropped by the program itself", "dropped", a.get("per_port", {}).get("2"))
    pkg = convert(os.path.join(WORK, "p4runtime"))
    rc, answers, text = run_quiet(pkg)
    check("🔴 the converted p4runtime package: rc 0", 0, rc)
    check("  one program, on all three switches", ([1, 2, 3], [1, 2, 3], 255),
          (answers[0].get("dpids"), answers[0].get("ports"), answers[0].get("cpu_port")) if answers else None)
    has("  and the limit is said with the answer", "table-miss", text)

    # =============================================================================================
    section("3. 🔴 a program that does not drop it is named for what it did")
    # =============================================================================================
    cases = (("hb_drop", "dropped", "port 1: dropped"),
             ("hb_flood", "not_dropped", "FORWARDED out of fabric port"),
             ("hb_punt", "not_dropped", "PUNTED to the CPU port 255"),
             ("hb_digest", "not_dropped", "A DIGEST TO THE CONTROLLER"),
             ("hb_clone", "not_dropped", "A CLONE TO A MIRROR SESSION"),
             ("hb_mcast", "not_dropped", "MULTICAST requested"))
    for name, verdict, said in cases:
        a = c.check_program(os.path.join(FIX, name + ".json"), [1, 2, 3], 255, tmp_parent=WORK)
        tag = "  the control: a program that drops it" if name == "hb_drop" else f"🔴 {name}"
        check(f"{tag}: {verdict}", verdict, a["verdict"])
        has(f"  said as {said!r}", said, a.get("reason"))
    a = c.check_program(os.path.join(FIX, "hb_clone.json"), [1, 2, 3], 255, tmp_parent=WORK)
    has("  a clone is seen in bmv2's own log too", "CLONED (a mirror session a controller configures)",
        a.get("reason"))
    a = c.check_program(os.path.join(FIX, "hb_flood.json"), [1, 2, 3], 255, tmp_parent=WORK)
    has("  a flood is seen in the pcaps too", "frames left the switch on attached port", a.get("reason"))
    pkg = convert(os.path.join(WORK, "p4runtime-flood"), os.path.join(FIX, "hb_flood.json"))
    rc, answers, text = run_quiet(pkg)
    check("🔴 a package whose program floods it: rc 1", 1, rc)
    has("  naming the program", "NOT_DROPPED", text)

    # =============================================================================================
    section("4. the judgement: a pcap outranks the log, and unread is UNKNOWN")
    # =============================================================================================
    dropped = {(0, 0): ["Processing packet received on port 1", "Egress port is 511",
                        "Dropping packet at the end of ingress"]}
    v, why, _ = c.judge(dropped, [1], {1}, 255, {}, {1: 0, 255: 0})
    check("  a dropped frame and empty pcaps: dropped", "dropped", v)
    v, why, _ = c.judge(dropped, [1], {1}, 255, {}, {1: 0, 255: 1})
    check("🔴 the log says dropped, the CPU port's pcap holds a frame: NOT dropped", "not_dropped", v)
    has("  saying where it left", "frames left the switch on attached port(s) 255 (1)", why)
    v, why, _ = c.judge({}, [1], {1}, 255, {}, {1: 0, 255: 0})
    check("🔴 a frame never processed: unknown, not dropped", "unknown", v)
    v, why, _ = c.judge({(0, 0): ["Processing packet received on port 1",
                                  "Dropping packet at the end of ingress"],
                         (0, 1): ["Egress port is 3"]},
                        [1], {1}, 255, {}, {1: 0, 255: 0})
    check("🔴 a copy of the frame with no logged fate: unknown, though the original dropped", "unknown", v)
    v, why, _ = c.judge(dropped, [1], {1}, 255, {}, {1: 0, 255: None})
    check("🔴 an output pcap that is not there: unknown", "unknown", v)
    v, why, _ = c.judge({(0, 0): ["Processing packet received on port 1",
                                  "Transmitting packet of size 60 out of port 0"]},
                        [1], {1}, 255, {}, {1: 0, 255: 0})
    check("  sent to a port no switch of the fabric has: dropped", "dropped", v)
    v, why, _ = c.judge({(0, 0): ["Processing packet received on port 1",
                                  "Transmitting packet of size 62 out of port 255"]},
                        [1], {1}, 255, {}, {1: 0, 255: 0})
    check("🔴 sent to the CPU port (not a data port): punted, NOT dropped", "not_dropped", v)
    v, why, _ = c.judge({(0, 0): ["Processing packet received on port 1",
                                  "Transmitting packet of size 60 out of port 1"]},
                        [1], {1}, 255, {}, {1: 0, 255: 0})
    check("🔴 sent back out of a fabric port: NOT dropped", "not_dropped", v)
    v, why, _ = c.judge({(0, 0): ["Processing packet received on port 1", "Action entry is learn - ",
                                  "Dropping packet at the end of ingress"]},
                        [1], {1}, 255, {"learn": {"generate_digest", "mark_to_drop"}},
                        {1: 0, 255: 0})
    check("🔴 dropped after a digest: NOT dropped", "not_dropped", v)

    # =============================================================================================
    section("5. rc 2 when it cannot tell, rc 3 when there is nothing to check")
    # =============================================================================================
    bogus = os.path.join(WORK, "bogus")
    os.makedirs(bogus)
    with open(os.path.join(bogus, "package.json"), "w") as fh:
        fh.write("not json\n")
    rc, _, text = run_quiet(bogus)
    check("🔴 an unreadable package: rc 2", 2, rc)
    broken = os.path.join(WORK, "broken.json")
    with open(broken, "w") as fh:
        fh.write("{}\n")
    a = c.check_program(broken, [1, 2], 255, tmp_parent=WORK)
    check("🔴 a program bmv2 will not load: unknown", "unknown", a["verdict"])
    has("  saying the switch exited", "the switch exited before the check finished", a.get("reason"))
    pkg_ndt = convert(os.path.join(WORK, "p4runtime-ndtwin"))
    with open(os.path.join(pkg_ndt, "package.json")) as fh:
        manifest = json.load(fh)
    for sw in manifest["switches"].values():
        sw["pipeline"] = None
    with open(os.path.join(pkg_ndt, "package.json"), "w") as fh:
        json.dump(manifest, fh)
    rc, _, text = run_quiet(pkg_ndt)
    check("  a package on NDTwin's own pipeline: rc 3", 3, rc)
    pkg_broken = convert(os.path.join(WORK, "p4runtime-broken"), broken)
    rc, _, text = run_quiet(pkg_broken)
    check("🔴 a package whose program bmv2 will not load: rc 2", 2, rc)

    # =============================================================================================
    section("6. the cache: one program, the same ports; UNKNOWN never kept")
    # =============================================================================================
    os.environ["NDT_HB_CHECK_CACHE"] = os.path.join(WORK, "cache6")
    pkg = convert(os.path.join(WORK, "p4runtime-cache"))
    run_quiet(pkg)
    rc, _, text = run_quiet(pkg)
    has("🔴 the second run reads the first one's answer", "heartbeat drop check (cached)", text)
    check("  and it is still rc 0", 0, rc)
    entry = c.plan(pkg)[0]
    entry = dict(entry, ports=[1, 2])
    check("🔴 other ports are not the same question", None, c.cached(entry, c.binary_version(c.binary())))
    c.remember({"program_sha256": "ab" * 32, "verdict": "unknown"})
    check("🔴 an UNKNOWN answer is not kept", False,
          os.path.exists(os.path.join(c.cache_dir(), "ab" * 32 + ".json")))

    # =============================================================================================
    section("7. 🔴 not the lab: its own directory, its own port, stopped by pid, invisible to by-name")
    # =============================================================================================
    ports_sh = open(os.path.join(REPO, "tools/test_workflow/ports.sh")).read()
    table = ports_sh.split("NDT_PORT_TABLE=\"$(cat <<'TABLE'\n", 1)[1].split("\nTABLE\n", 1)[0]
    listed = []
    for row in table.splitlines():
        spec_ = row.split("|", 1)[0]
        lo, _, hi = spec_.partition("-")
        listed += list(range(int(lo), int(hi or lo) + 1))
    check("🔴 every port ports.sh names is one the check treats as the lab's", [],
          [p for p in listed if c.outside_lab_ports(p)])
    check("  and no candidate is one of them", [],
          [p for p in c.THRIFT_CANDIDATES if not c.outside_lab_ports(p)])
    held = socket.socket()
    held.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
    try:
        first = c.choose_thrift_port()
        if first is None:
            bad("🔴 a candidate somebody holds is skipped", "no candidate was free at all")
        else:
            held.bind(("0.0.0.0", first))
            held.listen(1)
            second = c.choose_thrift_port()
            check("🔴 a candidate somebody holds is skipped", True, second is not None and second != first)
    finally:
        held.close()
    calls = []

    def flaky(port, _calls=calls):
        _calls.append(port)
        return len(_calls) == 1
    real_free = c.port_is_free
    c.port_is_free = flaky
    try:
        a = c.check_program(AT_JSON, [1, 2, 3], 255, tmp_parent=WORK)
    finally:
        c.port_is_free = real_free
    check("🔴 checked free again right before the launch: taken there is UNKNOWN", "unknown",
          a["verdict"])
    has("  saying so", "was taken before the launch", a.get("reason"))

    seen = {}

    def bmv2_count():
        r = subprocess.run(["bash", "-c", f"source <(sed -n '/^bmv2_count() {{/,/^}}/p' {NDT!r}); bmv2_count"],
                           capture_output=True, text=True)
        return r.stdout.strip()

    def sweep(argv):
        r = subprocess.run(["bash", "-c", f"source <(sed -n '/^sweep_matches() {{/,/^}}/p' {HELPER!r}); "
                            "sweep_matches simple_switch_grpc \"$@\" && echo match || echo none", "_"] + argv,
                           capture_output=True, text=True)
        return r.stdout.strip()

    topo_src = open(os.path.join(REPO, "p4_proxy/mininet/p4_testbed_topo.py")).read()
    tree = ast.parse(topo_src)
    ns = {"os": os}
    for node in tree.body:
        if (isinstance(node, ast.FunctionDef) and node.name in
                ("_is_a_signallable_pid", "_word_after", "process_is_a_switch")) or (
                isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "BMV2_EXECUTABLE_NAME"):
            exec(compile(ast.Module([node], []), "p4_testbed_topo", "exec"), ns)
    before_count = bmv2_count()

    def on_launch(launch):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not os.path.exists(os.path.join(launch.workdir, "notif.ipc")):
            time.sleep(0.02)
        pid = launch.pid
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            argv = [w.decode() for w in fh.read().split(b"\0")[:-1]]
        with open(f"/proc/{pid}/comm") as fh:
            comm = fh.read().strip()
        seen.update(pid=pid, argv=argv, comm=comm, workdir=launch.workdir, count=bmv2_count(),
                    sweep=sweep(argv), uid=os.stat(f"/proc/{pid}").st_uid,
                    topo=ns["process_is_a_switch"](pid, entry={"grpc_port": 30051,
                                                               "device_id": launch.device_id}),
                    ipc=os.path.exists(os.path.join(launch.workdir, "notif.ipc")),
                    device_id=launch.device_id, thrift=launch.thrift_port)

    a = c.check_program(AT_JSON, [1, 2, 3], 255, tmp_parent=WORK, on_launch=on_launch)
    check("  (the run under observation still judged)", "dropped", a["verdict"])
    check("🔴 it runs as the caller, not root", os.getuid(), seen.get("uid"))
    check("🔴 argv[0] is not a switch's name", "ndt-hbdrop-bmv2", (seen.get("argv") or [""])[0])
    check("🔴 ndt's bmv2_count does not count it", before_count, seen.get("count"))
    check("🔴 the helper's sweep does not match it", "none", seen.get("sweep"))
    check("🔴 p4_testbed_topo's switch name is not its argv[0]", True,
          os.path.basename((seen.get("argv") or [""])[0]) != ns["BMV2_EXECUTABLE_NAME"])
    check("  nor does its identity rule take it for a switch", False, seen.get("topo"))
    check("🔴 the kernel's capacity scan does not either (argv[0] does not start simple_switch)", False,
          os.path.basename((seen.get("argv") or ["simple_switch"])[0]).startswith("simple_switch"))
    cpp = open(os.path.join(REPO, "src/ndt_core/http/OpenflowCapacityReport.cpp")).read()
    has("  (that scan's rule, as the kernel has it)", 'return base.rfind("simple_switch", 0) == 0;', cpp)
    hasnt("🔴 no argv element names simple_switch_grpc (ndt's running-binary line)", "simple_switch_grpc",
          " ".join(seen.get("argv") or []))
    check("🔴 its nanomsg socket is in its own directory", True, seen.get("ipc"))
    has("  named relative to it", "ipc://notif.ipc", " ".join(seen.get("argv") or []))
    check("🔴 its Thrift port is outside the lab's", True,
          seen.get("thrift") is not None and c.outside_lab_ports(seen["thrift"]))
    check("🔴 its device id is no fabric's (above 512)", True, (seen.get("device_id") or 0) > 512)
    check("🔴 stopped by the time the check returns", False, alive(seen["pid"]) if seen.get("pid") else None)
    check("  and its directory is gone", False, os.path.exists(seen.get("workdir") or "/"))

    # Killed with the checker: a checker that dies without its `finally` (SIGKILL) takes the switch
    # with it (PR_SET_PDEATHSIG).
    probe = subprocess.Popen(
        [sys.executable, "-c",
         "import importlib.util, os, sys\n"
         "spec = importlib.util.spec_from_file_location('hbcheck', sys.argv[1])\n"
         "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
         "def die(launch):\n"
         "    print(launch.pid, flush=True)\n"
         "    os.kill(os.getpid(), 9)\n"
         "m.check_program(sys.argv[2], [1, 2, 3], 255, tmp_parent=sys.argv[3], on_launch=die)\n",
         TOOL, AT_JSON, WORK], stdout=subprocess.PIPE, text=True)
    out, _ = probe.communicate(timeout=30)
    orphan = int(out.strip()) if out.strip().isdigit() else None
    deadline = time.monotonic() + 3
    while orphan and alive(orphan) and time.monotonic() < deadline:
        time.sleep(0.05)
    survived = bool(orphan) and alive(orphan)
    check("🔴 a checker killed outright takes its switch with it", (True, False), (bool(orphan), survived))
    if survived:
        os.kill(orphan, signal.SIGKILL)       # exact pid, the one the probe printed
finally:
    shutil.rmtree(WORK, ignore_errors=True)

print(f"\nRan {PASS + FAIL} checks, {FAIL} failed")
sys.exit(1 if FAIL else 0)
