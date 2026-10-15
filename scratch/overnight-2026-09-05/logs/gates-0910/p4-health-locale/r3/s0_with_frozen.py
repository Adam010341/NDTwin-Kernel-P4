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
