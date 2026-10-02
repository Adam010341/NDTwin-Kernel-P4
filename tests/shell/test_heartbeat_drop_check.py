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
     nothing that finds the fabric's switches by name or argv takes it for one. [Co-developed with
     claude code -- Adam] What argv says is asserted on what the check WOULD launch (a recorder in
     place of the switch); only what needs a running process launches one;
  8. the command itself: SIGTERM mid-check (rc 143, the switch and its directory gone), any crash
     and root are rc 2 (never Python's traceback rc 1, which ndt reads as "does not drop"), a
     program with no data port is not applicable, the stock bmv2 must answer the fabric's version,
     a run that does not settle is UNKNOWN, NDT_HB_CHECK_BMV2 is honoured;
  9. end to end: ndt's own hb_drop_check_step, sourced, running this checker on a converted
     package -- its one-line answer, and no throwaway switch left when the fabric would start.

🔴 THE ORCHESTRATOR'S CONDITIONS HOLD FOR EVERY LAUNCH THIS SUITE MAKES, ALSO UNDER A MUTANT (the
round-4 review's M-4): every Launch.start in this process goes through launch_violation() below --
argv[0] ndt-hbdrop-bmv2, no argument naming simple_switch*, --thrift-port in 29400-29499,
--device-id >= 900000, --notifications-addr ipc://notif.ipc in its own ndt-hbdrop-* directory,
pcaps and log relative to it, not root -- and a launch that breaks one is NOT made (it is
recorded, and the last check goes red). A --version run is refused unless argv[0] is ours.
Section 9 starts other processes only after section 7's recorder found the tool's launch clean.

Every other cell launches the real stock simple_switch (NDT_HB_CHECK_BMV2 overrides it; the gates
point it at a wrapper that records each launch in their tripwire and refuses one that breaks a
condition). With no stock simple_switch this suite SKIPS, declared: nothing is checked.

Run:  python3 tests/shell/test_heartbeat_drop_check.py
Env:  CHECK_UNDER_TEST=<path to a copy of the tool>, NDT_UNDER_TEST=<path to a copy of ndt>
      (the mutation gate), HELPER_UNDER_TEST
Exit: 0 every check passed (or the declared skip), 1 some check failed
"""

# NDTWIN_L1_NEEDS: bmv2-stock

import ast
import importlib.util
import json
import os
import re
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
NDT = os.environ.get("NDT_UNDER_TEST") or os.path.join(REPO, "tools/test_workflow/ndt")
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


def lab_claim_says_wait(path, me, now=None):
    """[Co-developed with claude code -- Adam] The orchestrator's round-6 ruling on S-8: this suite
    starts throwaway switches on whatever machine runs it, and on the lab it must not add any while
    somebody else holds the lab or a measurement is declared. The reason to skip, or None. The claim
    file is ndt's (`owner=`, `expires=` in unix seconds, `measuring=`); one that is absent, expired
    or unreadable does not hold the lab -- as ndt itself reads it ("malformed (no usable expires=)
    -- treated as free")."""
    try:
        with open(path) as fh:
            fields = dict(line.rstrip("\n").split("=", 1) for line in fh if "=" in line)
    except OSError:
        return None
    try:
        live = int(fields.get("expires", "0")) > (time.time() if now is None else now)
    except ValueError:
        return None
    if not live:
        return None
    if fields.get("measuring", "").strip():
        return f"a measurement is declared on the lab ({fields['measuring'].strip()[:80]})"
    owner = fields.get("owner", "").strip()
    if owner and owner != me:
        return f"the lab is claimed by {owner}"
    return None


def lab_claim_file():
    """ndt's own answer to "which tree holds the lab" (lab_kernel_dir), and its claim file there."""
    r = subprocess.run(["bash", "-c", 'source "$1" >/dev/null 2>&1; lab_kernel_dir', "_",
                        os.path.join(REPO, "tools/test_workflow/ndt")], capture_output=True, text=True)
    return os.path.join(r.stdout.strip() or "/nonexistent", ".test_run", "lab.claim")


LAB_CLAIM = os.environ.get("NDT_LAB_CLAIM_FILE") or lab_claim_file()
_wait = lab_claim_says_wait(LAB_CLAIM, os.environ.get("NDT_OWNER", ""))
if _wait:
    print(f"SKIP: {_wait} ({LAB_CLAIM}) -- this suite starts throwaway switches and adds none while "
          f"the lab is held or measured; nothing was checked")
    sys.exit(0)
# (the claim first: its cells in tests/shell/test_l1_shell_scoring.sh tell the two skips apart)
STOCK = os.environ.get("NDT_HB_CHECK_BMV2") or "/usr/local/bin/simple_switch"
if not (os.path.isfile(STOCK) and os.access(STOCK, os.X_OK)):
    print(f"SKIP: no stock simple_switch at {STOCK} -- every cell drives one for real; nothing was "
          f"checked")
    sys.exit(0)

spec = importlib.util.spec_from_file_location("hbcheck", TOOL)
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

# [Co-developed with claude code -- Adam] The launch guard (round-4 review M-4, the orchestrator's
# 09-28 conditions), as source: section 7's SIGKILL probe runs it in its own process too.
GUARD_SRC = r"""
import os, re
LAUNCH_VIOLATIONS = []


def launch_violation(launch):
    a = list(launch.argv)
    if os.geteuid() == 0:
        return "euid 0"
    if not a or a[0] != "ndt-hbdrop-bmv2":
        return f"argv[0] is {a[:1]}"
    if any(os.path.basename(x).startswith("simple_switch") for x in a):
        return "an argument names simple_switch"

    def after(flag):
        return a[a.index(flag) + 1] if flag in a and a.index(flag) + 1 < len(a) else None
    t, dev = after("--thrift-port"), after("--device-id")
    notif, logf = after("--notifications-addr"), after("--log-file")
    if not (t and t.isdigit() and 29400 <= int(t) <= 29499):
        return f"Thrift port {t}"
    if not (dev and dev.isdigit() and int(dev) >= 900000):
        return f"device id {dev}"
    if notif != "ipc://notif.ipc":
        return f"notifications address {notif}"
    if not logf or os.path.isabs(logf):
        return f"log file {logf}"
    ifs = [a[i + 1] for i, x in enumerate(a) if x == "-i" and i + 1 < len(a)]
    if "--use-files" not in a or not ifs or any(not re.fullmatch(r"(\d+)@p\1", x) for x in ifs):
        return f"not pcap files relative to its directory: {ifs}"
    if not (os.path.basename(launch.workdir).startswith("ndt-hbdrop-")
            and os.path.isdir(launch.workdir)):
        return f"not its own directory: {launch.workdir}"
    wrapper = os.environ.get("NDT_HB_CHECK_BMV2")
    if wrapper and launch.executable != wrapper:
        return f"not the switch NDT_HB_CHECK_BMV2 names (the tripwire's wrapper): {launch.executable}"
    return None


def version_violation(module, path):
    if module.ARGV0 != "ndt-hbdrop-bmv2":
        return f"a --version run with argv[0] {module.ARGV0}"
    # under a gate (NDT_HB_CHECK_BMV2 names its wrapper) only the wrappers, or this suite's fakes
    gate = [os.environ.get(v) for v in ("NDT_HB_CHECK_BMV2", "NDT_HB_CHECK_FABRIC_BMV2")]
    if gate[0] and path not in gate and not str(path).startswith(WORK + os.sep):
        return f"a --version run of {path}, which the tripwire's wrappers would not log"
    return None


def guard(module):
    real_start, real_version = module.Launch.start, module.binary_version

    def start(self):
        why = launch_violation(self)
        if why:
            LAUNCH_VIOLATIONS.append(why)
            return self                                 # NOT launched
        return real_start(self)

    def version(path):
        why = version_violation(module, path)
        if why:
            LAUNCH_VIOLATIONS.append(why)
            return None
        return real_version(path)
    module.Launch.start, module.binary_version = start, version
    return real_start
"""
#: (a tool from before round 5 has no fabric_binary: the cells that need it go red, not the suite)
FABRIC_BINARY = getattr(c, "fabric_binary", lambda: None)
GUARD = {"WORK": None}
exec(GUARD_SRC, GUARD)
REAL_START = GUARD["guard"](c)

WORK = tempfile.mkdtemp(prefix="hbdrop-test-")
GUARD["WORK"] = WORK
os.environ["NDT_HB_CHECK_CACHE"] = os.path.join(WORK, "cache")
# [Co-developed with claude code -- Adam] Every temporary directory the tool makes in this process
# goes under WORK, which is removed at the end -- also the ones a mutant leaves behind (D21's four,
# in the round-4 gate's TMPDIR).
os.environ["TMPDIR"] = WORK
tempfile.tempdir = WORK


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


# [Co-developed with claude code -- Adam] Section 9's harness: ndt sourced as test_ndt_heartbeat.sh
# sources it, with only what would touch the machine stubbed -- NOT hb_drop_check_run, which runs
# the tool under test (copied to the fixture's tools/test_workflow, beside the modules it reads).
E2E_STUBS = r"""
REPO="@FIX@"
HERE="@FIX@/tools/test_workflow"
LAB="@FIX@/installed-ndtwin-lab"
STACK="@FIX@/stack.sh"
MANIFEST="@FIX@/manifest.json"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
LAB_CONF="@FIX@/etc/ndtwin-lab.conf"
LAB_DEFAULT_KERNEL_DIR="@FIX@"
HB_PIDFILE="@FIX@/run/heartbeat.pid"
HB_REPORT="@FIX@/run/heartbeat.json"
LINK_TELEMETRY_MANIFEST="@FIX@/ndtwin_link_telemetry.json"
export P4_PROXY_PY="@FIX@/fakepy"
export NDT_APP_PREFLIGHT="@FIX@/preflight.sh"
export NDT_PROXY_LOG="@FIX@/.test_run/logs/p4_proxy.log"
export NDT_TOPO_LOG="@FIX@/.test_run/logs/topo.log"
sudo() {
    printf "sudo %s\n" "$*" >> "$EVENTS"
    case "$*" in
        *topo-start*) echo 99 > "@FIX@/bmv2_count"
                      printf "topo-start throwaway=%s\n" "$(python3 "@FIX@/throwaway.py" "@FIX@/tmp")" >> "$EVENTS" ;;
        *"heartbeat start"*) echo 4242 > "@FIX@/run/heartbeat.pid"; echo "heartbeat started (pid 4242)"; return 0 ;;
        *"heartbeat stop"*) rm -f "@FIX@/run/heartbeat.pid"; return 0 ;;
    esac
    return 0
}
sleep() { :; }
bmv2_count() { cat "@FIX@/bmv2_count" 2>/dev/null || echo 0; }
mn_count() { echo 0; }
fabric_host_count() { echo 0; }
topo_session() { return 1; }
foreign_claim() { :; }
in_flight() { :; }
guard_no_live_ovs() { return 0; }
stale_pipeline() { return 1; }
preflight() { return 0; }
claim_note_up() { :; }
claim_note_down() { :; }
bmv2_binary() { echo "simple_switch_grpc (stub)"; }
sample_rate() { echo 256; }
rate_label() { echo "1/256"; }
wait_reaped() { return 0; }
app_probe() { APP_STATE=not-running; APP_LIVE_PIDS=(); }
mark_teardown_start() { return 0; }
mark_teardown_end() { return 0; }
lab_subject() { echo "3 bmv2 switch(es)"; }
stack_down_deferrable_ports() { :; }
ndt_port_residue() { :; }
teardown_in_flight() { return 1; }
curl() { return 1; }
git_lines() { :; }
port_open() { return 1; }
cmd_clean() { return 0; }
registry_clear_stale() { return 0; }
verify_p4() { echo "VERIFY_P4 pipe=${4:-<none>}"; return 0; }
"""
#: Run by the topo-start stub: for one second, the most processes of this run's throwaway switch
#: seen at once -- argv[0] ndt-hbdrop-bmv2, its cwd under the run's TMPDIR.
THROWAWAY_PY = r"""
import os, sys, time
root, most, end = os.path.realpath(sys.argv[1]), 0, time.monotonic() + 1.0
while time.monotonic() < end:
    n = 0
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                a0 = fh.read().split(b"\0")[0]
            cwd = os.path.realpath(os.readlink(f"/proc/{pid}/cwd"))
        except OSError:
            continue
        if a0 == b"ndt-hbdrop-bmv2" and cwd.startswith(root + os.sep):
            n += 1
    most = max(most, n)
    time.sleep(0.05)
print(most)
"""


def run_e2e(clean):
    """(out, events) of `up_p4` on the converted p4runtime package and on the same package with a
    program that floods the frame, plus the flood run's withheld record and the fixture -- or None
    when the tool's launch is not clean (its child processes run without this suite's guard)."""
    if not clean:
        return None
    fix = os.path.join(WORK, "e2e")
    for d in (".test_run/pids", ".test_run/logs", "tools/test_workflow", "p4_proxy/mininet", "setting",
              "etc", "run", "tmp"):
        os.makedirs(os.path.join(fix, d), exist_ok=True)
    shutil.copyfile(TOOL, os.path.join(fix, "tools/test_workflow/heartbeat_drop_check.py"))
    for m in ("app_package.py", "topo_from_json.py", "grpc_ports.py", "link_telemetry.py",
              "bmv2_binary_override"):
        os.symlink(os.path.join(REPO, "p4_proxy/mininet", m), os.path.join(fix, "p4_proxy/mininet", m))
    setting = os.path.join(REPO, "setting/StaticNetworkTopologyP4_10Switches_4Hosts.json")
    if os.path.exists(setting):
        shutil.copyfile(setting, os.path.join(fix, "setting", os.path.basename(setting)))
    with open(os.path.join(fix, "manifest.json"), "w") as fh:
        fh.write('{"switches":[{"dpid":1}]}\n')
    with open(os.path.join(fix, "installed-ndtwin-lab"), "w") as fh:
        fh.write("helper\n")
    with open(os.path.join(fix, "throwaway.py"), "w") as fh:
        fh.write(THROWAWAY_PY)
    for name, body in (("stack.sh", '#!/usr/bin/env bash\nprintf "stack %s\\n" "$*" >> "$EVENTS"\n'
                                    'echo "started p4_proxy"\necho "started kernel"\nexit 0\n'),
                       ("fakepy", '#!/usr/bin/env bash\nexec bash "$@"\n'),
                       ("preflight.sh", '#!/usr/bin/env bash\necho "PASS -- every check passed"\nexit 0\n')):
        with open(os.path.join(fix, name), "w") as fh:
            fh.write(body)
        os.chmod(os.path.join(fix, name), 0o755)
    stubs = E2E_STUBS.replace("@FIX@", fix)
    results = []
    for tag, program in (("ok", None), ("flood", os.path.join(FIX, "hb_flood.json"))):
        pkg = convert(os.path.join(WORK, f"e2e-pkg-{tag}"), program)
        events = os.path.join(fix, f"events-{tag}.log")
        open(events, "w").close()
        for f in ("p4_proxy/mininet/app_package_override", ".test_run/up.target",
                  ".test_run/heartbeat.withheld", "run/heartbeat.pid", "bmv2_count"):
            try:
                os.unlink(os.path.join(fix, f))
            except FileNotFoundError:
                pass
        with open(os.path.join(fix, "p4_proxy/mininet/host_count_override"), "w") as fh:
            fh.write("4\n")
        script = f"source {NDT!r} >/dev/null 2>&1\n{stubs}\nNDT_APP_DIR={pkg!r}; up_p4\necho \"RC=$?\""
        env = dict(os.environ, EVENTS=events, NO_COLOR="1", TMPDIR=os.path.join(fix, "tmp"),
                   NDT_HB_CHECK_CACHE=os.path.join(fix, f"cache-{tag}"))
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env, timeout=300)
        try:
            withheld = open(os.path.join(fix, ".test_run/heartbeat.withheld")).read()
        except OSError:
            withheld = "<no record>"
        results.append((r.stdout + r.stderr, open(events).read(), withheld))
    (out_ok, ev_ok, _w), (out_fl, ev_fl, withheld_fl) = results
    return out_ok, ev_ok, out_fl, ev_fl, withheld_fl, fix


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

    # --- 7a. [Co-developed with claude code -- Adam] What the check WOULD launch: a recorder stands
    # in for the switch, so a mutant that breaks a condition launches nothing (the round-4 review's
    # M-4) -- the argv is read where it is built.
    recorded = {}

    def recorder(self):
        recorded.update(argv=list(self.argv), workdir=self.workdir, device_id=self.device_id,
                        thrift=self.thrift_port, parent=os.path.dirname(self.workdir),
                        violation=GUARD["launch_violation"](self))
        return self                                     # nothing launched
    guarded_start, c.Launch.start = c.Launch.start, recorder
    try:
        c.check_program(AT_JSON, [1, 2, 3], 255, tmp_parent=WORK)
    finally:
        c.Launch.start = guarded_start
    argv = recorded.get("argv") or []

    def after(flag):
        return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None
    check("🔴 argv[0] is not a switch's name", "ndt-hbdrop-bmv2", (argv or [""])[0])
    check("🔴 the helper's sweep does not match it", "none", sweep(argv) if argv else "<nothing recorded>")
    check("🔴 p4_testbed_topo's switch name is not its argv[0]", True,
          bool(argv) and os.path.basename(argv[0]) != ns["BMV2_EXECUTABLE_NAME"])
    check("🔴 the kernel's capacity scan does not either (argv[0] does not start simple_switch)", False,
          os.path.basename((argv or ["simple_switch"])[0]).startswith("simple_switch"))
    cpp = open(os.path.join(REPO, "src/ndt_core/http/OpenflowCapacityReport.cpp")).read()
    has("  (that scan's rule, as the kernel has it)", 'return base.rfind("simple_switch", 0) == 0;', cpp)
    hasnt("🔴 no argv element names simple_switch_grpc (ndt's running-binary line)", "simple_switch_grpc",
          " ".join(argv) if argv else "simple_switch_grpc (nothing recorded)")
    check("🔴 its nanomsg socket is named relative to its own directory", "ipc://notif.ipc",
          after("--notifications-addr"))
    check("🔴 its pcaps and its log are relative to it too", (["1@p1", "2@p2", "3@p3", "255@p255"], "bmv2"),
          ([argv[i + 1] for i, x in enumerate(argv) if x == "-i"], after("--log-file")))
    check("🔴 and that directory is its own, under the caller's temporary directory", (True, WORK),
          (os.path.basename(recorded.get("workdir") or "").startswith("ndt-hbdrop-"), recorded.get("parent")))
    check("🔴 the CPU port is attached as well (a punt has a port to leave by)", True,
          "255@p255" in [argv[i + 1] for i, x in enumerate(argv) if x == "-i"])
    check("🔴 its Thrift port is outside the lab's", True,
          recorded.get("thrift") is not None and c.outside_lab_ports(recorded["thrift"])
          and after("--thrift-port") == str(recorded["thrift"]))
    check("🔴 its device id is no fabric's (900000 and above)", True,
          (recorded.get("device_id") or 0) >= 900000 and after("--device-id") == str(recorded.get("device_id")))
    check("🔴 every condition the gates' tripwire enforces holds for it", None,
          recorded.get("violation", "<nothing recorded>"))
    # Section 8's and 9's child processes run the tool with no guard of this suite's: only a tool
    # whose launch is clean may start them.
    CLEAN = (bool(argv) and recorded.get("violation") is None and c.ARGV0 == "ndt-hbdrop-bmv2"
             and c.binary() == (os.environ.get("NDT_HB_CHECK_BMV2") or c.binary())
             and FABRIC_BINARY() == (os.environ.get("NDT_HB_CHECK_FABRIC_BMV2") or FABRIC_BINARY()))

    # --- 7b. What needs the switch RUNNING: launched through the guard.
    seen = {}
    before_count = bmv2_count()

    def on_launch(launch):
        if launch.pid is None:
            return                                      # refused by the guard
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not os.path.exists(os.path.join(launch.workdir, "notif.ipc")):
            time.sleep(0.02)
        pid = launch.pid
        try:
            with open(f"/proc/{pid}/comm") as fh:
                comm = fh.read().strip()
        except OSError:
            comm = None
        seen.update(pid=pid, comm=comm, workdir=launch.workdir, count=bmv2_count(),
                    uid=os.stat(f"/proc/{pid}").st_uid if os.path.exists(f"/proc/{pid}") else None,
                    topo=ns["process_is_a_switch"](pid, entry={"grpc_port": 30051,
                                                               "device_id": launch.device_id}),
                    ipc=os.path.exists(os.path.join(launch.workdir, "notif.ipc")),
                    probe=subprocess.run([sys.executable, "-c", THROWAWAY_PY, WORK], capture_output=True,
                                         text=True).stdout.strip())

    a = c.check_program(AT_JSON, [1, 2, 3], 255, tmp_parent=WORK, on_launch=on_launch)
    check("  (the run under observation still judged)", "dropped", a["verdict"])
    check("🔴 it runs as the caller, not root", os.getuid(), seen.get("uid"))
    check("🔴 its comm is not a switch's either", "ndt-hbdrop-bmv2", seen.get("comm"))
    check("🔴 ndt's bmv2_count does not count it", before_count, seen.get("count"))
    check("  nor does its identity rule take it for a switch", False, seen.get("topo"))
    check("🔴 its nanomsg socket is in its own directory", True, seen.get("ipc"))
    check("🔴 stopped by the time the check returns", False, alive(seen["pid"]) if seen.get("pid") else None)
    check("  and its directory is gone", False, os.path.exists(seen.get("workdir") or "/"))
    check("  (section 9's topo-start probe sees a running throwaway switch)", "1", seen.get("probe"))

    # Killed with the checker: a checker that dies without its `finally` (SIGKILL) takes the switch
    # with it (PR_SET_PDEATHSIG). [Co-developed with claude code -- Adam] Killed once the switch is
    # RUNNING -- its socket is there (the round-4 review: the probe used to kill the checker before
    # the gate's wrapper had executed simple_switch at all) -- and the probe runs the same guard.
    probe = subprocess.Popen(
        [sys.executable, "-c",
         "import importlib.util, os, sys, time\n"
         "spec = importlib.util.spec_from_file_location('hbcheck', sys.argv[1])\n"
         "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
         "g = {'WORK': sys.argv[3]}; exec(sys.argv[4], g); g['guard'](m)\n"
         "def die(launch):\n"
         "    if launch.pid is None:\n"
         "        print('refused', flush=True); return\n"
         "    t = time.monotonic() + 5\n"
         "    ipc = os.path.join(launch.workdir, 'notif.ipc')\n"
         "    while time.monotonic() < t and not os.path.exists(ipc):\n"
         "        time.sleep(0.02)\n"
         "    print(launch.pid, os.path.exists(ipc), flush=True)\n"
         "    os.kill(os.getpid(), 9)\n"
         "m.check_program(sys.argv[2], [1, 2, 3], 255, tmp_parent=sys.argv[3], on_launch=die)\n",
         TOOL, AT_JSON, WORK, GUARD_SRC], stdout=subprocess.PIPE, text=True)
    out, _ = probe.communicate(timeout=30)
    words = out.split()
    orphan = int(words[0]) if words and words[0].isdigit() else None
    running = len(words) > 1 and words[1] == "True"
    # [Co-developed with claude code -- Adam] 10 s, not 3 (round 5's re-review): a SIGKILLed process
    # under MemoryHigh throttling can take seconds to go -- the likeliest cause of round 4's D10 crash.
    deadline = time.monotonic() + 10
    while orphan and alive(orphan) and time.monotonic() < deadline:
        time.sleep(0.05)
    survived = bool(orphan) and alive(orphan)
    check("🔴 a checker killed outright takes its RUNNING switch with it", (True, True, False),
          (bool(orphan), running, survived))
    if survived:
        try:
            os.kill(orphan, signal.SIGKILL)   # exact pid, the one the probe printed
        except ProcessLookupError:
            pass                              # it went between the two looks

    # =============================================================================================
    section("8. the command: a signal, a crash, root, no port, another bmv2 -- never a pass, never rc 1")
    # =============================================================================================
    # [Co-developed with claude code -- Adam] The round-4 review's S-4.
    import contextlib
    import io
    pkg8 = convert(os.path.join(WORK, "p4runtime-cmd"))

    # 8a. main() itself, SIGTERM'd while its switch runs: 128 + 15, the switch and its directory gone.
    sigtmp = os.path.join(WORK, "sig")
    os.makedirs(sigtmp)
    NOT_RUN = "not run: section 7 found the tool's launch breaks a condition"
    if not CLEAN:                       # every cell still printed, so positions line up for the gate
        for name in ("  (the switch was found running before the signal)", "🔴 main() SIGTERM'd mid-check: rc 143",
                     "🔴 and its switch is gone", "  and so is its directory"):
            bad(name, NOT_RUN)
    else:
        child = subprocess.Popen(
            [sys.executable, "-c",
             "import importlib.util, sys\n"
             "spec = importlib.util.spec_from_file_location('hbcheck', sys.argv[1])\n"
             "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
             "g = {'WORK': sys.argv[4]}; exec(sys.argv[3], g); g['guard'](m)\n"
             "m.settled = lambda *a: False          # it keeps polling: the signal lands mid-check\n"
             "sys.exit(m.main(['heartbeat_drop_check.py', sys.argv[2]]))\n",
             TOOL, pkg8, GUARD_SRC, WORK],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            env=dict(os.environ, TMPDIR=sigtmp, NDT_HB_CHECK_CACHE=os.path.join(WORK, "cache-sig")))
        swdir, swpid = None, None
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and swpid is None and child.poll() is None:
            for d in os.listdir(sigtmp):
                p = os.path.join(sigtmp, d)
                if d.startswith("ndt-hbdrop-") and not d.startswith("ndt-hbdrop-ver-") \
                        and os.path.exists(os.path.join(p, "notif.ipc")):
                    for pid in filter(str.isdigit, os.listdir("/proc")):
                        try:
                            if os.readlink(f"/proc/{pid}/cwd") == p:
                                swdir, swpid = p, int(pid)
                        except OSError:
                            pass
            time.sleep(0.05)
        child.send_signal(signal.SIGTERM)
        try:
            text8, _ = child.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            child.kill()
            text8, _ = child.communicate()
        time.sleep(0.2)
        check("  (the switch was found running before the signal)", True, swpid is not None)
        check("🔴 main() SIGTERM'd mid-check: rc 143", 143, child.returncode)
        check("🔴 and its switch is gone", False, alive(swpid) if swpid else None)
        check("  and so is its directory", False, os.path.exists(swdir) if swdir else None)
        if swpid and alive(swpid):
            try:
                os.kill(swpid, signal.SIGKILL)  # exact pid, found by its own directory
            except ProcessLookupError:
                pass

    # 8b. a crash is rc 2 with what crashed -- not Python's traceback rc 1 ("does NOT drop" to ndt).
    saved = [signal.getsignal(s_) for s_ in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)]
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc8 = c.main(["heartbeat_drop_check.py", pkg8, "--json", os.path.join(WORK, "no", "such", "out.json")])
    except BaseException as exc:  # noqa: BLE001 -- the cell's answer
        rc8 = f"raised {type(exc).__name__}"
    finally:
        for s_, h in zip((signal.SIGTERM, signal.SIGINT, signal.SIGHUP), saved):
            signal.signal(s_, h)
    check("🔴 a crash of the check is rc 2", 2, rc8)
    has("  saying it crashed", "could not tell -- the check itself crashed (FileNotFoundError", buf.getvalue())

    # 8c. root: refused by the command and by the launch.
    real_geteuid = os.geteuid
    buf = io.StringIO()
    os.geteuid = lambda: 0
    try:
        with contextlib.redirect_stdout(buf):
            rc8 = c.main(["heartbeat_drop_check.py", pkg8])
    except BaseException as exc:  # noqa: BLE001
        rc8 = f"raised {type(exc).__name__}"
    finally:
        os.geteuid = real_geteuid
        for s_, h in zip((signal.SIGTERM, signal.SIGINT, signal.SIGHUP), saved):
            signal.signal(s_, h)
    check("🔴 run as root (euid 0): rc 2", 2, rc8)
    has("  saying it refuses", "refusing to run as root", buf.getvalue())
    rootdir = tempfile.mkdtemp(prefix="ndt-hbdrop-", dir=WORK)
    port8 = c.choose_thrift_port()
    lr = c.Launch(AT_JSON, [1], 255, rootdir, port8 or 29499, 900000 + os.getpid() % 90000)
    why = GUARD["launch_violation"](lr)     # before euid is faked: REAL_START is unguarded
    if why:
        refused = f"not tried: {why}"
    else:
        os.geteuid = lambda: 0
        try:
            REAL_START(lr)
            refused = "launched"
        except PermissionError:
            refused = "refused"
        finally:
            os.geteuid = real_geteuid
            lr.stop()                                   # exact pid, if a mutant did launch it
    check("🔴 and a launch as root is refused", "refused", refused)

    # 8d. the modules it reads not there: rc 2, never a traceback.
    lonely = os.path.join(WORK, "lonely", "tools", "test_workflow")
    os.makedirs(lonely)
    shutil.copyfile(TOOL, os.path.join(lonely, "heartbeat_drop_check.py"))
    r = subprocess.run([sys.executable, os.path.join(lonely, "heartbeat_drop_check.py"), pkg8],
                       capture_output=True, text=True, timeout=60)
    check("🔴 its own modules missing: rc 2", 2, r.returncode)
    has("  saying what it could not load", "could not load its modules", r.stdout)

    # 8e. no data port: not applicable, never a vacuous DROPPED.
    a = c.check_program(AT_JSON, [], 255, tmp_parent=WORK)
    check("🔴 a program with no data port to inject on: not dropped-by-default", "unknown", a["verdict"])
    has("  saying nothing was asked", "no data port to inject a frame on", a.get("reason"))
    # one switch, no host, no cable: the only model with no port the loader accepts
    pkg_lonely = convert(os.path.join(WORK, "p4runtime-noports"))
    mpath, tpath = os.path.join(pkg_lonely, "package.json"), os.path.join(pkg_lonely, "ndtwin", "topology.json")
    with open(mpath) as fh:
        pmodel = json.load(fh)
    with open(tpath) as fh:
        tmodel = json.load(fh)
    pmodel["switches"], pmodel["hosts"] = {"1": pmodel["switches"]["1"]}, {}
    tmodel["nodes"] = [n for n in tmodel["nodes"] if n.get("dpid") == 1 and n.get("vertex_type") == 0]
    tmodel["edges"] = []
    with open(mpath, "w") as fh:
        json.dump(pmodel, fh)
    with open(tpath, "w") as fh:
        json.dump(tmodel, fh)
    rc, _, text = run_quiet(pkg_lonely)
    check("🔴 a package whose switches the model gives no port: rc 3", 3, rc)
    has("  saying there is no frame to inject", "no data port -- no frame to inject", text)

    # 8f. the stock bmv2 must answer the fabric's version.
    fake = os.path.join(WORK, "fake_fabric_bmv2")
    with open(fake, "w") as fh:
        fh.write("#!/bin/sh\necho 9.9.9-deadbeef\n")
    os.chmod(fake, 0o755)
    old_fabric = os.environ.get("NDT_HB_CHECK_FABRIC_BMV2")
    os.environ["NDT_HB_CHECK_CACHE"] = os.path.join(WORK, "cache8")
    try:
        os.environ["NDT_HB_CHECK_FABRIC_BMV2"] = fake
        rc, answers, text = run_quiet(pkg8)
        check("🔴 a fabric on another bmv2 version: rc 2", 2, rc)
        has("  saying the two are not the same switch", "not the same switch", text)
        has("  naming both versions", "'9.9.9-deadbeef'", text)
        os.environ["NDT_HB_CHECK_FABRIC_BMV2"] = os.path.join(WORK, "no-such-binary")
        rc, answers, text = run_quiet(pkg8)
        check("🔴 a fabric binary that answers no version: rc 2", 2, rc)
        os.environ.pop("NDT_HB_CHECK_FABRIC_BMV2")
        from_override = FABRIC_BINARY()
    finally:
        if old_fabric is None:
            os.environ.pop("NDT_HB_CHECK_FABRIC_BMV2", None)
        else:
            os.environ["NDT_HB_CHECK_FABRIC_BMV2"] = old_fabric
    comm_sh = os.path.join(WORK, "prints_its_comm")
    with open(comm_sh, "w") as fh:
        fh.write("#!/bin/sh\nread c < /proc/$$/comm; echo \"$c\"\n")
    os.chmod(comm_sh, 0o755)
    check("🔴 a --version run's comm is ndt-hbdrop-bmv2 too (bmv2_count counts comm)", "ndt-hbdrop-bmv2",
          c.binary_version(comm_sh))
    override = [ln.strip() for ln in open(os.path.join(REPO, "p4_proxy/mininet/bmv2_binary_override"))
                if ln.strip() and not ln.strip().startswith("#")][:1]
    check("🔴 the fabric's binary is p4_testbed_topo's override when nothing overrides it",
          override[0] if override else "<no directive>", from_override)

    # 8g. a run that does not settle is UNKNOWN, and what "settled" means.
    real_settled = c.settled
    c.settled = lambda *a_: False
    try:
        a = c.check_program(AT_JSON, [1, 2, 3], 255, tmp_parent=WORK, timeout=1.0)
    finally:
        c.settled = real_settled
    check("🔴 a run that never settles: unknown, though every frame it logged was dropped", "unknown", a["verdict"])
    has("  saying it did not settle", "did not settle within the time allowed", a.get("reason"))
    done = ["[00:00:00.000] [bmv2] [info] end of all input files reached"]
    pk = {(0, 0): ["Processing packet received on port 1", "Dropping packet at the end of ingress"]}
    check("  settled: every frame read, every copy with a fate, the input at its end", True,
          c.settled(pk, [1], done))
    check("🔴 not settled before bmv2 says its input files ended", False, c.settled(pk, [1], []))
    check("🔴 not settled while an injected frame is unread", False, c.settled(pk, [1, 2], done))
    check("🔴 not settled while a copy has no fate", False,
          c.settled({**pk, (0, 1): ["Egress port is 3"]}, [1], done))

    # 8h. NDT_HB_CHECK_BMV2 is the switch it runs (the gates' wrapper rides on it).
    old_bmv2 = os.environ.get("NDT_HB_CHECK_BMV2")
    try:
        os.environ["NDT_HB_CHECK_BMV2"] = "/some/other/simple_switch"
        got = c.binary()
        os.environ.pop("NDT_HB_CHECK_BMV2")
        default = c.binary()
    finally:
        if old_bmv2 is not None:
            os.environ["NDT_HB_CHECK_BMV2"] = old_bmv2
    check("🔴 NDT_HB_CHECK_BMV2 names the switch it runs", "/some/other/simple_switch", got)
    check("  and the stock build is the default", "/usr/local/bin/simple_switch", default)

    # =============================================================================================
    section("9. 🔴 end to end: ndt's own drop-check step, this checker, a real throwaway switch")
    # =============================================================================================
    # [Co-developed with claude code -- Adam] The round-4 review's S-6: ndt sourced with the REAL
    # hb_drop_check_run (only what would touch the machine is stubbed, as in test_ndt_heartbeat.sh),
    # on converted packages. The topo-start stub looks, for a second, for any throwaway switch of
    # this run still there when the fabric would start.
    e2e = run_e2e(CLEAN)
    if e2e is None:
        for name in ("🔴 end to end: the converted p4runtime package's one-line answer",
                     "🔴 the heartbeat is asked to start, once", "🔴 no throwaway switch is left when the fabric starts",
                     "  the whole answer is in the bring-up's own log, named on the line",
                     "  and it is one short line (06 keeps 6000 characters of `ndt up`)",
                     "🔴 end to end: a package whose program floods it -- NOT dropped, said",
                     "🔴 and its heartbeat is NOT started", "  the record names what it did",
                     "  no throwaway switch is left there either"):
            bad(name, NOT_RUN)
    else:
        out_ok, ev_ok, out_fl, ev_fl, withheld_fl, fix_e = e2e
        has("🔴 end to end: the converted p4runtime package's one-line answer",
            "heartbeat drop check: every program drops its frame (advanced_tunnel.json checked)", out_ok)
        check("🔴 the heartbeat is asked to start, once", 1, ev_ok.count("ndtwin-lab heartbeat start"))
        check("🔴 no throwaway switch is left when the fabric starts", "topo-start throwaway=0",
              next((l for l in ev_ok.splitlines() if l.startswith("topo-start throwaway=")), "no topo-start"))
        m_ = re.search(r"\((\.test_run/logs/heartbeat_drop_check\.[0-9TZ]+\.[0-9]+\.log)\)", out_ok)
        log_text = open(os.path.join(fix_e, m_.group(1))).read() if m_ and os.path.exists(os.path.join(fix_e, m_.group(1))) else ""
        has("  the whole answer is in the bring-up's own log, named on the line", "DROPPED -- every injected frame was dropped", log_text)
        said = [l for l in out_ok.splitlines() if "drop check" in l or "limit:" in l]
        check("  and it is one short line (06 keeps 6000 characters of `ndt up`)", (1, True),
              (len(said), 0 < sum(map(len, said)) <= 400))
        has("🔴 end to end: a package whose program floods it -- NOT dropped, said", "a program does NOT drop its frame", out_fl)
        check("🔴 and its heartbeat is NOT started", 0, ev_fl.count("ndtwin-lab heartbeat start"))
        has("  the record names what it did", "FORWARDED out of fabric port", withheld_fl)
        check("  no throwaway switch is left there either", "topo-start throwaway=0",
              next((l for l in ev_fl.splitlines() if l.startswith("topo-start throwaway=")), "no topo-start"))

    check("🔴 every launch this suite asked for met the orchestrator's conditions", [], GUARD["LAUNCH_VIOLATIONS"])
finally:
    shutil.rmtree(WORK, ignore_errors=True)

print(f"\nRan {PASS + FAIL} checks, {FAIL} failed")
sys.exit(1 if FAIL else 0)
