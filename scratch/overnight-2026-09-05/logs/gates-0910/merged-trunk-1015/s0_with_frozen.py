"""s0_with_frozen.py <clone> <run-dir> : one offline S0 run WITH a Frozen pinned to the clone's HEAD.

Builds the Frozen exactly as probe.cmd_lab does (pin HEAD once, clean check of tools/p4_health, freeze with the
pinned-head git, S0(run_dir, Runner(), py, frozen=frozen), s0.run()) and stops where cmd_lab would go on to
run_lab: no lab, no ndt, no sudo, no mininet. check_exercise is wrapped only to log each call and its result; after
s0.run() the copy is checked once more (what run_lab's check does) and listed, so a write into the copy after
compile_all, or a __pycache__ in it, shows. [Co-developed with claude code -- Adam]
"""
import os, sys, hashlib, json

clone, run_dir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
os.chdir(clone)
sys.path.insert(0, os.path.join(clone, "tools"))
from p4_health import probe  # noqa: E402
assert os.path.realpath(probe.REPO) == os.path.realpath(clone), (probe.REPO, clone)
probe.load_lab_path()
from p4_health import frozen as FZ  # noqa: E402
from p4_health.collect.runner import Runner  # noqa: E402
from p4_health.s0 import S0  # noqa: E402

h_rc, pinned = probe._git_run("rev-parse", "--verify", "HEAD")
assert h_rc == 0 and pinned
git_rc, dirty = probe._git_run("status", "--porcelain", "--", "tools/p4_health")
assert git_rc == 0 and not dirty, ("dirty", dirty)


def git_at_pinned_head(*a):
    if a == ("rev-parse", "--verify", "HEAD"):
        return 0, pinned
    return probe._git_run(*a)


os.makedirs(run_dir)
frozen = FZ.freeze(run_dir, repo=probe.REPO, git=git_at_pinned_head)
py = os.path.join(probe.REPO, "p4_proxy", "venv", "bin", "python")
print("pinned HEAD", pinned, "frozen.head", frozen.head, flush=True)

calls = []
real_check = frozen.check_exercise


def logged(copy_dir):
    try:
        real_check(copy_dir)
    except FZ.Refused as exc:
        calls.append(("REFUSED", copy_dir, str(exc)))
        print("check_exercise REFUSED:", copy_dir, exc, flush=True)
        raise
    calls.append(("ok", copy_dir, ""))
    print("check_exercise ok:", copy_dir, flush=True)


frozen.check_exercise = logged
s0 = S0(run_dir, Runner(), py, frozen=frozen)
s0.out["repo"] = probe.repo_identity(head=frozen.head)
refused = None
try:
    rc = s0.run()
except FZ.Refused as exc:
    refused, rc = str(exc), None
print("S0 verdict:", s0.out.get("verdict"), "rc", rc, "refused:", refused, flush=True)
bad = [c for c in s0.out.get("checks", []) if not c.get("ok")]
print("S0 checks: %d, failed: %d" % (len(s0.out.get("checks", [])), len(bad)))
for c in bad:
    print("  FAILED:", c.get("name"), "--", str(c.get("detail"))[:300])
# (merged-head gate addition, Q8 m1) what probe.cmd_lab (probe.py ~239-251) does between S0 COMPLETE and run_lab, called the same
# way and with the same arguments: the identity record of the system under test and the gate fingerprint. Read-only (git, file
# hashes, importlib.metadata in each interpreter); no lab, no ndt, no sudo, no mininet.
if s0.out.get("verdict") == "COMPLETE":
    from p4_health import identity as ID  # noqa: E402
    from p4_health.collect.config import Config  # noqa: E402
    from p4_health.vs_trial import fabric_binary  # noqa: E402
    cfg = Config(run_dir, owner=os.environ.get("NDT_OWNER") or "mg-gate")
    live = os.path.join(probe.REPO, "doc", "audit", "2026-09-04_p4-tutorial-exercise-prep", "live-p1")
    sut = ID.system_under_test(Runner(), probe.REPO, run_dir, py, os.path.join(live, "code_identity.py"))
    try:
        fabric = fabric_binary()
    except OSError:
        fabric = None
    gate = ID.fingerprint(Runner(), probe.REPO, run_dir,
                          [py, cfg.p4dev_python, os.path.join(os.path.expanduser("~"), "miniconda3", "envs",
                                                              "ntg-env", "bin", "python")],
                          fabric_bmv2=fabric, fp_script=os.path.join(live, "venv_fingerprint.sh"))
    ID.dump(os.path.join(run_dir, "gate_fingerprint.json"), gate)
    print("gate fingerprint %s; system under test %s" % (gate["sha256"], sut), flush=True)
    id_refused = sut is None or gate.get("sha256") in (None, "incomplete")
    print("cmd_lab would %s here (identity record %s)" % ("REFUSE" if id_refused else "go on to run_lab",
                                                         "incomplete" if id_refused else "complete"), flush=True)
    if id_refused:
        print("  parts that are not recorded:", sorted(k for k, v in gate.get("parts", {}).items() if v in (None, "incomplete", "unreadable")), flush=True)
# what run_lab's check does, after everything S0 ran
try:
    frozen.check_exercise(os.path.join(run_dir, "exercise"))
    final = "ok"
except FZ.Refused as exc:
    final = "REFUSED: %s" % exc
print("final check of the copy after s0.run():", final)
print("check_exercise calls (in order):", json.dumps([c[:2] + (c[2][:200],) for c in calls]))
ex = os.path.join(run_dir, "exercise")
pyc = [os.path.join(d, n) for d, ds, fs in os.walk(ex) for n in ds + fs if n == "__pycache__"]
print("__pycache__ entries in the copy:", pyc)
print("build outputs recorded at the first check:", json.dumps(sorted(frozen.outputs.get(os.path.abspath(ex), {}))))
listing = {}
for d, ds, fs in os.walk(ex):
    for n in fs:
        p = os.path.join(d, n)
        listing[os.path.relpath(p, ex)] = hashlib.sha256(open(p, "rb").read()).hexdigest()[:12]
print("files in the copy at the end: %d" % len(listing))
sys.exit(0 if (refused is None and final == "ok" and not pyc) else 3)
