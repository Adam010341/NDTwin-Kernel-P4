#!/usr/bin/env python3
"""Failure-injection rehearsal of p4_proxy/requirements.txt's "UPGRADING AN EXISTING VENV" text.

Worker pb5prep, after the judge's READY AFTER FIXES on 6351be15 (B1-B3). Never touches the real
p4_proxy/venv, the lab or the real `ndt`:

  * every scenario gets its own THROWAWAY REPO COPY under the worktree's scratch/ -- `git archive
    HEAD p4_proxy tools tests`, the two compiled P4 files copied in, and tools/test_workflow/ndt
    replaced by a STUB that keeps a claim file with the real one's fields (owner, expires, note,
    measuring) and refuses a foreign claim. tools/build_guard/guarded_build.sh is the real one;
  * its p4_proxy/venv is a FAITHFUL STAND-IN for the development machine's: a fresh venv from
    the same base python3 with `pip install --no-deps -r` of that venv's own `pip freeze --all`
    (not `cp -a`, whose scripts would name the real venv), same versions, same pip-check defect;
  * $HOME (the procedure's PARK) is a scratch directory; the pip cache is the real one.

The procedure's commands are run VERBATIM: taken from HEAD's committed file, pasted as a whole into
`bash -i` through a pipe -- bash reads a pipe byte by byte, so the shell step 0 opens with
guarded_build.sh reads the lines after it, exactly as a paste into that shell would, and the
outer shell gets what follows `exit`. Lines that are not the procedure's are marked in the paste:
[inject] makes a check fail, [type] is what an operator would type (OLD=..., cd, exit, a fix).
Scenario S01 holds the REAL build lock (/tmp/ndtwin-build.lock); every other scenario sets LOCK
to a private file, which the guard and the procedure's inwin() both honour.

  fi_rehearsal.py [scenario ...]        (default: all)
[Co-developed with claude code -- Adam]
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import time

WT = "/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-pb5-merge-prep-0926"
L = "/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910"
MAIN = "/home/adam/Desktop/NDTwin-Kernel"
W = WT + "/scratch/pb5prep"
BASEPY = "/home/adam/miniconda3/bin/python3"
FREEZE_MAIN = W + "/freeze.main.txt"     # the main venv's `pip freeze --all`, taken read-only
FULL = subprocess.run(["git", "-C", WT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
SHA = FULL[:8]
ROOT = f"{W}/fi-{SHA}"
LOCKFILE = f"{ROOT}/private.lock"
REQ = subprocess.run(["git", "-C", WT, "show", "HEAD:p4_proxy/requirements.txt"],
                     capture_output=True, text=True, check=True).stdout
if subprocess.run(["git", "-C", WT, "status", "--porcelain", "--untracked-files=no"],
                  capture_output=True, text=True).stdout.strip():
    sys.exit("REFUSE: tracked changes in the worktree")

STUB_NDT = r'''#!/usr/bin/env bash
# pb5prep rehearsal STUB of tools/test_workflow/ndt: claim/release only, same claim-file fields.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; CLAIM="$REPO/.test_run/lab.claim"
echo "$(date -u +%T) ndt $* owner=${NDT_OWNER:-} measuring=${NDT_MEASURING:-}" >> "$REPO/ndt-stub.log"
case "${1:-}" in
  claim)
    [ -n "${NDT_OWNER:-}" ] || { echo "set NDT_OWNER first" >&2; exit 2; }
    if [ -f "$CLAIM.foreign" ]; then echo "the lab is already claimed by someone-else (stub)" >&2; exit 1; fi
    if [ -f "$CLAIM" ] && ! grep -qx "owner=$NDT_OWNER" "$CLAIM" \
       && [ "$(sed -n 's/^expires=//p' "$CLAIM")" -gt "$(date +%s)" ]; then echo "claimed by another owner (stub)" >&2; exit 1; fi
    mkdir -p "$REPO/.test_run"
    printf 'owner=%s\nexpires=%s\nnote=%s\nexclusive_cpu=no\nmeasuring=%s\n' "$NDT_OWNER" \
        "$(( $(date +%s) + ${2:-30} * 60 ))" "${3:-}" "${NDT_MEASURING:-}" > "$CLAIM"
    echo "claimed (stub): $(tr '\n' ' ' < "$CLAIM")"; exit 0 ;;
  release)
    if [ -f "$CLAIM" ] && grep -qx "owner=${NDT_OWNER:-}" "$CLAIM"; then rm -f "$CLAIM"; echo "released (stub)"; exit 0; fi
    echo "no claim of yours to release (stub)" >&2; exit 1 ;;
  *) echo "stub ndt: $* not implemented" >&2; exit 0 ;;
esac
'''


def blocks(text):
    lines = text.splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith("# UPGRADING AN EXISTING VENV"))
    cur, out = None, {}
    for l in lines[start:]:
        m = re.match(r"^# ([0-9])\. ", l)
        if m:
            cur = m.group(1)
        elif l.startswith("# HELPERS"):
            cur = "H"
        elif l.startswith("# ROLLBACK IN PLACE"):
            cur = "IP"
        elif l.startswith("# ROLLBACK,"):
            cur = "RB"
        m = re.match(r"^#   \$ (.*)$", l)
        if m:
            out.setdefault(cur, []).append(m.group(1))
    return out


B = blocks(REQ)
SHAPE = {"0": 2, "H": 7, "1": 7, "2": 3, "3": 3, "4": 1, "5": 1, "RB": 3, "IP": 5}
if {k: len(v) for k, v in B.items()} != SHAPE:
    sys.exit(f"procedure shape changed: { {k: len(v) for k, v in B.items()} } != {SHAPE}")


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, executable="/bin/bash", **kw)


def fp(path):
    """The procedure's own fp(), run from its HELPERS text."""
    fpdef = next(c for c in B["H"] if c.startswith("fp()"))
    r = subprocess.run(["bash", "-c", fpdef + '\nfp "$1"', "_", path], capture_output=True, text=True)
    return r.stdout.strip()


def pbver(venv):
    r = subprocess.run([venv + "/bin/python", "-c", "import google.protobuf as g, p4.v1.p4runtime_pb2; "
                        "from google.protobuf.internal import api_implementation as a; print(g.__version__, a.Type())"],
                       capture_output=True, text=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
    return r.stdout.strip() if r.returncode == 0 else f"<import failed rc={r.returncode}>"


def mk_repo(repo):
    os.makedirs(repo)
    sh(f"git -C {WT} archive HEAD p4_proxy tools tests | tar -x -C {repo}", check=True)
    os.makedirs(f"{repo}/p4_proxy/p4_src/build", exist_ok=True)
    for n in ("ndtwin_switch.json", "ndtwin_switch.p4info.txt"):
        shutil.copy2(f"{MAIN}/p4_proxy/p4_src/build/{n}", f"{repo}/p4_proxy/p4_src/build/{n}")
    with open(f"{repo}/tools/test_workflow/ndt", "w") as f:
        f.write(STUB_NDT)
    os.chmod(f"{repo}/tools/test_workflow/ndt", 0o755)


def mk_old(venv, log):
    r = sh(f"{BASEPY} -m venv {venv} && PIP_DISABLE_PIP_VERSION_CHECK=1 {venv}/bin/pip install -q --no-deps -r {FREEZE_MAIN}"
           f" && PYTHONDONTWRITEBYTECODE=1 {venv}/bin/python -m pip freeze --all | diff - {FREEZE_MAIN}")
    log.append(f"# stand-in (old) {venv}: build+freeze-diff rc={r.returncode} {r.stdout.strip()[:300]} {r.stderr.strip()[-300:]}")
    assert r.returncode == 0, "stand-in is not the main venv's freeze"


def mk_new(venv, repo, log):
    r = sh(f"{BASEPY} -m venv {venv} && PIP_DISABLE_PIP_VERSION_CHECK=1 {venv}/bin/pip install -q -r {repo}/p4_proxy/requirements.txt"
           f" && {venv}/bin/python {repo}/p4_proxy/regen_p4runtime_pb2.py >/dev/null")
    log.append(f"# stand-in (already migrated) {venv}: rc={r.returncode} {r.stderr.strip()[-300:]}")
    assert r.returncode == 0


def compose(parts):
    """parts: block names, or ('inject'|'type', command). Returns (paste text, annotated listing)."""
    text, listing = [], []
    for p in parts:
        if isinstance(p, tuple) and p[0] == "doc":     # one command of the procedure, verbatim
            text.append(p[1])
            listing.append(f"[doc, one command] {p[1]}")
        elif isinstance(p, tuple):
            kind, cmd = p
            text.append(f'echo "[{kind}] "{sh_quote(cmd)}')
            text.append(cmd)
            listing.append(f"[{kind}] {cmd}")
        else:
            for c in B[p]:
                text.append(c)
                listing.append(f"[doc {p}] {c}")
    return "\n".join(text) + "\n", listing


def sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run_paste(cwd, home, paste, real_lock=False, extra_env=None):
    env = {k: v for k, v in os.environ.items() if k not in (
        "P4_PROXY_PY", "PYTHONPATH", "PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION", "NDTWIN_GUARD_HELD",
        "NDT_OWNER", "NDT_MEASURING", "LOCK", "STEP", "OLD", "V", "R")}
    env.update(HOME=home, TERM="dumb", PIP_CACHE_DIR=os.path.expanduser("~adam/.cache/pip"),
               PIP_DISABLE_PIP_VERSION_CHECK="1", PS1="$ ")
    if not real_lock:
        env["LOCK"] = LOCKFILE
    env.update(extra_env or {})
    t0 = time.time()
    r = subprocess.run(["bash", "-i"], input=paste, cwd=cwd, env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=2400)
    # One stream, in order: an interactive bash echoes each line it reads (the '<...$ cmd' lines,
    # cut to 80 columns by readline) on stderr, so the commands and their output interleave.
    return r.returncode, r.stdout, time.time() - t0


# ---------------------------------------------------------------------------------------------
class Scn:
    def __init__(self, name, what):
        self.name, self.what = name, what
        self.base = f"{ROOT}/{name}"
        self.repo = f"{self.base}/repo"
        self.home = f"{self.base}/home"
        self.V = f"{self.repo}/p4_proxy/venv"
        self.log = [f"# HEAD {FULL}  fi rehearsal scenario {name}: {what}",
                    f"# {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}  root {self.base}"]
        self.checks = []

    def setup(self, old=True, home=None):
        shutil.rmtree(self.base, ignore_errors=True)
        mk_repo(self.repo)
        self.home = home or self.home
        os.makedirs(self.home, exist_ok=True)
        if old:
            mk_old(self.V, self.log)

    def paste(self, parts, cwd=None, real_lock=False, extra_env=None, label="paste"):
        text, listing = compose(parts)
        self.log.append(f"== {label}: into `bash -i` in {cwd or self.repo}, HOME={self.home}, "
                        f"lock={'REAL /tmp/ndtwin-build.lock' if real_lock else LOCKFILE}")
        self.log += ["   " + l for l in listing]
        rc, out, dt = run_paste(cwd or self.repo, self.home, text, real_lock, extra_env)
        self.log.append(f"-- output (rc {rc}, {dt:.0f}s); prompts and bash's no-tty warnings dropped:")
        for l in out.splitlines():
            if not l.strip() or re.match(r"^(bash: (cannot set terminal|no job control)|To run a command as|See \"man sudo)", l):
                continue
            self.log.append("   | " + l)
        return out

    def parked(self):
        return sorted(d for d in os.listdir(self.home) if d.startswith("p4_proxy-venv.") and os.path.isdir(f"{self.home}/{d}"))

    def check(self, desc, ok):
        self.checks.append((desc, bool(ok)))

    def finish(self):
        self.log.append("== checks")
        for d, ok in self.checks:
            self.log.append(f"CHECK {'ok  ' if ok else 'FAIL'} {d}")
        good = all(ok for _, ok in self.checks) and self.checks
        self.log.append(f"RESULT {'GREEN' if good else 'RED'}")
        self.log.append(f"rc={0 if good else 1}")
        path = f"{L}/fi_{self.name}.pb5prep-{SHA}.log"
        if os.path.exists(path):
            sys.exit(f"REFUSE: {path} exists")
        with open(path, "w") as f:
            f.write("\n".join(self.log) + "\n")
        shutil.rmtree(self.base, ignore_errors=True)   # the venvs are ~90 MB each; the log keeps what was seen
        return good


def claim_file(s):
    return os.path.exists(f"{s.repo}/.test_run/lab.claim")


def stub_log(s):
    try:
        return open(f"{s.repo}/ndt-stub.log").read()
    except OSError:
        return ""


FULLRUN = ["0", "H", "1", "2", "3", "4", "5"]


def s01_happy():
    s = Scn("S01_happy", "the whole procedure, nothing injected, holding the REAL build lock; then three "
            "rollbacks of that migration: from a new shell in $HOME, from another checkout, and the right way")
    s.setup()
    before = fp(s.V)
    s.log.append(f"# old stand-in fingerprint (the procedure's fp): {before}; {pbver(s.V)}")
    out = s.paste(FULLRUN, real_lock=True)
    s.check("claimed through the stub with NDT_OWNER and NDT_MEASURING", "ndt claim 90 p4_proxy venv migration owner=p4-venv-migration measuring=p4_proxy venv migration" in stub_log(s))
    s.check("the guarded shell held the REAL lock", "lock=/tmp/ndtwin-build.lock" in out)
    s.check("parked:", "parked: OLD=" in out)
    s.check("VERIFIED", "VERIFIED:" in out)
    s.check("no STOP, no skipped", "STOP" not in out and "(skipped" not in out)
    s.check("released from the outer shell", "released (stub)" in out and not claim_file(s))
    s.check("V is now 5.29.6 upb", pbver(s.V) == "5.29.6 upb")
    pk = s.parked()
    s.check(f"one parked venv in $HOME: {pk}", len(pk) == 1 and pk[0].startswith("p4_proxy-venv.protobuf3.20.3-"))
    OLD = f"{s.home}/{pk[0]}" if pk else "/nonexistent"
    s.check(".origin is the absolute V", open(OLD + ".origin").read().strip() == s.V if pk else False)
    s.check("the parked venv's fp is the recorded one and the one taken before", pk and fp(OLD) == open(OLD + ".fingerprint").read().strip() == before)
    s.check("baseline == new suites", pk and open(OLD + ".baseline").read() == open(OLD + ".new").read())
    s.log.append("# baseline: " + (open(OLD + ".baseline").read().replace("\n", " | ") if pk else "-"))

    # -- rollback from a new shell whose cwd is $HOME: step 0 cannot even find ndt there
    out = s.paste(["0", "H", ("type", f"OLD={OLD}"), "RB", "5"], cwd=s.home, label="rollback from a new shell in $HOME")
    s.check("$HOME: refused (STOP at rb1), nothing moved", "STOP at rb1" in out and pbver(s.V) == "5.29.6 upb" and os.path.isdir(OLD))
    # -- rollback from another checkout (a second repo copy, its own stub ndt, no venv)
    other = f"{s.base}/other-checkout"
    mk_repo(other)
    out = s.paste(["0", "H", ("type", f"OLD={OLD}"), "RB", ("type", "exit"), "5"], cwd=other,
                  label="rollback from a new shell in ANOTHER checkout (its own claim and guarded shell)")
    s.check("other checkout: refused (the window is not held on the venv's checkout), nothing moved, nothing created there",
            "STOP" in out and "rolling back" not in out and pbver(s.V) == "5.29.6 upb" and os.path.isdir(OLD)
            and not os.path.exists(f"{other}/p4_proxy/venv"))
    # -- the right way: window at the main copy, then cd anywhere
    out = s.paste(["0", ("type", 'cd "$HOME"'), "H", ("type", f"OLD={OLD}"), "RB", ("type", "exit"), "5"],
                  label="rollback the right way: step 0 at the checkout, cd $HOME, HELPERS, OLD=, ROLLBACK")
    s.check("old venv restored unchanged", "old venv restored unchanged" in out)
    s.check("V is 3.20.3 python again, fp as before", pbver(s.V) == "3.20.3 python" and fp(s.V) == before)
    failed = [d for d in os.listdir(s.home) if d.startswith("p4_proxy-venv.failed-")]
    s.check(f"the new venv parked as failed-*: {failed}", len(failed) == 1 and pbver(f"{s.home}/{failed[0]}") == "5.29.6 upb")
    s.check("claim released", not claim_file(s))
    return s.finish()


def simple_refusal(name, what, expect, setup=None, parts=FULLRUN, cwd=None, home=None, extra_env=None, cleanup=None):
    s = Scn(name, what)
    s.setup(old=setup is None or setup.get("old", True), home=home)
    pre = None
    try:
        if setup and setup.get("fn"):
            setup["fn"](s)
        pre = fp(s.V) if os.path.exists(s.V) else None
        s.log.append(f"# before: V fp {pre}; {pbver(s.V) if os.path.exists(s.V) else 'no V'}")
        out = s.paste(parts, cwd=cwd, extra_env=extra_env)
        s.check(f"prints {expect!r}", expect in out)
        s.check("only one STOP, and every later command skipped", out.count("STOP at") <= 1 or expect == "STOP: not inside")
        s.check("V untouched (same fp)", (fp(s.V) if os.path.exists(s.V) else None) == pre)
        s.check("nothing parked in $HOME", not [d for d in s.parked() if not d.endswith("-blocker-by-injection")])
        s.check("no VERIFIED, no 'parked:'", "VERIFIED" not in out and "parked: OLD=" not in out)
    finally:
        if cleanup:
            cleanup(s)
    return s.finish()


def with_rollback(name, what, stop, inject_after, inject_cmds, repo_fix=None, extra_after=None):
    """Park, fail at `stop` via an injection, then ROLLBACK in the same shell."""
    s = Scn(name, what)
    s.setup()
    if repo_fix:
        repo_fix(s)
    before = fp(s.V)
    blocks_ = ["0", "H", "1", "2", "3", "4"]
    i = blocks_.index(inject_after) + 1
    parts = blocks_[:i] + [("inject", c) for c in inject_cmds] + blocks_[i:] + (extra_after or []) + \
        ["RB", ("type", "exit"), "5"]
    out = s.paste(parts)
    s.check(f"STOP at {stop}", f"STOP at {stop}" in out)
    s.check("no VERIFIED", "VERIFIED" not in out)
    s.check("old venv restored unchanged", "old venv restored unchanged" in out)
    s.check("V is 3.20.3 python, same fp as before", pbver(s.V) == "3.20.3 python" and fp(s.V) == before)
    s.check("nothing left parked as protobuf*", not [d for d in s.parked() if d.startswith("p4_proxy-venv.protobuf")])
    s.check("claim released", not claim_file(s))
    return s.finish(), out


def main(which):
    os.makedirs(ROOT, exist_ok=True)
    results = {}
    step1 = B["1"]

    def run(name, fn):
        if which and name not in which:
            return
        print(f"=== {name}", flush=True)
        try:
            r = fn()
            ok = r[0] if isinstance(r, tuple) else r
        except Exception as e:   # noqa: BLE001 -- a harness error is RED, never silent
            print(f"    HARNESS ERROR {type(e).__name__}: {e}", flush=True)
            ok = False
        results[name] = ok
        print(f"    {'GREEN' if ok else 'RED'}", flush=True)

    run("S01_happy", s01_happy)
    run("S02_no_window", lambda: simple_refusal(
        "S02_no_window", "steps pasted into a shell with no claim and no guard (the 'pasted into the first shell' mistake)",
        "STOP: not inside", parts=["H", "1", "2", "3", "4"]))

    def foreign(s):
        os.makedirs(f"{s.repo}/.test_run", exist_ok=True)
        open(f"{s.repo}/.test_run/lab.claim.foreign", "w").close()
    run("S03_foreign_claim", lambda: simple_refusal(
        "S03_foreign_claim", "somebody else holds the lab: step 0's claim fails, so no guarded shell opens and the rest runs outside",
        "STOP: not inside", setup={"fn": foreign}))

    def already5(s):
        mk_new(s.V, s.repo, s.log)
    run("S04_already_protobuf5", lambda: simple_refusal(
        "S04_already_protobuf5", "V is already the new set (a second run after a migration)", "STOP at 1b",
        setup={"old": False, "fn": already5}))

    def symlink(s):
        real = f"{s.base}/real-venv"
        mk_old(real, s.log)
        os.symlink(real, s.V)
    run("S05_symlink", lambda: simple_refusal(
        "S05_symlink", "p4_proxy/venv is a symlink to a venv elsewhere", "STOP at 1b", setup={"old": False, "fn": symlink}))

    def parked_exists(s):
        os.makedirs(f"{s.home}/p4_proxy-venv.protobuf3.20.3-20000101-000000-blocker-by-injection")
    run("S06_park_occupied", lambda: simple_refusal(
        "S06_park_occupied", "$HOME already holds a parked p4_proxy venv", "STOP at 1c", setup={"fn": parked_exists}))

    shm_home = f"/dev/shm/pb5prep-fi-{SHA}-S07"
    run("S07_park_other_fs", lambda: simple_refusal(
        "S07_park_other_fs", f"$HOME ({shm_home}, tmpfs) is not on the venv's filesystem", "STOP at 1c",
        home=shm_home, cleanup=lambda s: shutil.rmtree(shm_home, ignore_errors=True)))

    def minor(s):
        x = f"{s.base}/fakebase"
        os.makedirs(f"{x}/bin")
        os.symlink("/usr/bin/python3.12", f"{x}/bin/python3")
        os.symlink("/home/adam/miniconda3/lib", f"{x}/lib")
        cfg = open(f"{s.V}/pyvenv.cfg").read()
        open(f"{s.V}/pyvenv.cfg", "w").write(re.sub(r"(?m)^home = .*$", f"home = {x}/bin", cfg))
        s.log.append(f"# [inject] pyvenv.cfg home -> {x}/bin (python3 there = /usr/bin/python3.12; lib -> miniconda's so the 3.13 venv still starts): "
                     f"{pbver(s.V)}")
    run("S08_base_minor", lambda: simple_refusal(
        "S08_base_minor", "pyvenv.cfg's home python3 is 3.12 while the venv runs 3.13", "STOP at 1d", setup={"fn": minor}))

    procs = {}

    def user_maps(s):
        code = f"import sys; sys.path.insert(0, '{s.V}/lib/python3.13/site-packages'); import grpc, time; time.sleep(600)"
        procs["S09"] = subprocess.Popen([BASEPY, "-c", code], start_new_session=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        time.sleep(3)
        s.log.append(f"# [inject] pid {procs['S09'].pid}: the BASE python importing grpc from V's site-packages "
                     "(argv names no venv path; only /proc/<pid>/maps shows it)")

    def kill(key):
        def k(s):
            p = procs.pop(key, None)
            if p:
                os.killpg(p.pid, signal.SIGTERM)
                p.wait(timeout=10)
                s.log.append(f"# killed the injected pid {p.pid} by its process group (never by name)")
        return k
    run("S09_in_use_maps", lambda: simple_refusal(
        "S09_in_use_maps", "a process maps a file of the venv", "STOP at 1e", setup={"fn": user_maps}, cleanup=kill("S09")))

    def user_rel(s):
        procs["S09b"] = subprocess.Popen(["p4_proxy/venv/bin/python", "-c", "import time; time.sleep(600)"],
                                         cwd=s.repo, start_new_session=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        time.sleep(2)
        s.log.append(f"# [inject] pid {procs['S09b'].pid}: `p4_proxy/venv/bin/python` by a RELATIVE path from the repo copy "
                     "(pure python; nothing of the venv is mapped)")
    run("S09b_in_use_relative", lambda: simple_refusal(
        "S09b_in_use_relative", "a process runs the venv's python by a relative path", "STOP at 1e",
        setup={"fn": user_rel}, cleanup=kill("S09b")))

    run("S10_baseline_fails", lambda: simple_refusal(
        "S10_baseline_fails", "the suites fail on the OLD venv (p4_proxy/p4_src/build removed)", "STOP at 1f",
        setup={"fn": lambda s: shutil.rmtree(f"{s.repo}/p4_proxy/p4_src/build")}))

    def s11():
        s = Scn("S11_move_fails", "the rename fails (a directory put at $OLD between 1f and 1g)")
        s.setup()
        pre = fp(s.V)
        out = s.paste(["0", "H"] + [("doc", c) for c in step1[:6]] + [("inject", 'mkdir -p "$OLD/blocker"')] +
                      [("doc", step1[6])] + ["2", "3", "4", "5"])
        s.check("STOP at 1g: nothing moved", "STOP at 1g: nothing moved" in out)
        s.check("V untouched", fp(s.V) == pre)
        s.check("no VERIFIED", "VERIFIED" not in out)
        s.check("claim NOT released (the migration shell was never left)", claim_file(s))
        return s.finish()
    run("S11_move_fails", s11)

    run("S12_V_reappears", lambda: with_rollback(
        "S12_V_reappears", "something recreates p4_proxy/venv after step 1 parked the old one", "2a", "1",
        ['mkdir "$V"']))
    run("S13_pip_fails_then_repaste", lambda: s13())

    def regen_break(s):
        open(f"{s.repo}/p4_proxy/regen_p4runtime_pb2.py", "w").write("import sys\nprint('injected failure')\nsys.exit(1)\n")
        s.log.append("# [inject] the repo copy's regen_p4runtime_pb2.py replaced by `sys.exit(1)`")
    run("S14_regen_fails", lambda: with_rollback(
        "S14_regen_fails", "the regeneration fails", "2c", "H", [], repo_fix=regen_break))
    run("S15_pipcheck_then_fix", lambda: s15())
    run("S16_backend", lambda: with_rollback(
        "S16_backend", "the backend is not upb (PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python after HELPERS)", "3b", "2",
        ["export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python"]))
    run("S17_suites_differ", lambda: with_rollback(
        "S17_suites_differ", "the new venv fails a suite the old one passed (hypothesis uninstalled)", "3c", "2",
        ['"$V/bin/pip" uninstall -y hypothesis']))
    run("S18_fingerprint_mismatch", lambda: s18())
    run("S19_rollback_in_place", lambda: s19())

    summ = f"{L}/fi_summary-{time.strftime('%H%M%S')}.pb5prep-{SHA}.log"
    with open(summ, "w") as f:
        f.write(f"# HEAD {FULL}  failure-injection rehearsal summary (fi_<scenario>.pb5prep-{SHA}.log)\n")
        for k, v in results.items():
            f.write(f"{'GREEN' if v else 'RED  '} {k}\n")
        bad = sum(1 for v in results.values() if not v)
        f.write(f"{len(results) - bad} of {len(results)} GREEN\nrc={1 if bad else 0}\n")
    print(open(summ).read())
    return 1 if any(not v for v in results.values()) else 0


def s13():
    s = Scn("S13_pip_fails_then_repaste", "pip install fails at 2b; the operator re-pastes steps 1-3 as they are "
            "(the index fixed); step 1 must refuse the half-built venv; then ROLLBACK")
    s.setup()
    before = fp(s.V)
    bad_pip = "export PIP_INDEX_URL=http://127.0.0.1:9/simple PIP_NO_CACHE_DIR=1 PIP_RETRIES=0 PIP_TIMEOUT=2"
    out = s.paste(["0", "H", "1", ("inject", bad_pip), "2", "3", "4",
                   ("type", "unset PIP_INDEX_URL PIP_NO_CACHE_DIR PIP_RETRIES PIP_TIMEOUT"),
                   "1", "2", "3", "4", "RB", ("type", "exit"), "5"])
    first, _, second = out.partition("[type] unset PIP_INDEX_URL")
    s.check("first paste: STOP at 2b", "STOP at 2b" in first)
    s.check("re-paste: STOP at 1b (the half-built venv has no protobuf 3), no second 'parked:'",
            "STOP at 1b" in second and second.count("parked: OLD=") == 0)
    s.check("exactly one parked venv until the rollback", out.count("parked: OLD=") == 1)
    s.check("old venv restored unchanged", "old venv restored unchanged" in out)
    s.check("V is 3.20.3 python, same fp as before", pbver(s.V) == "3.20.3 python" and fp(s.V) == before)
    s.check("claim released", not claim_file(s))
    return s.finish()


def s15():
    s = Scn("S15_pipcheck_then_fix", "pip check fails at 3a (h11 removed); the operator fixes it, types STEP=2 and "
            "pastes step 3 again, as the STOP says")
    s.setup()
    out = s.paste(["0", "H", "1", "2", ("inject", '"$V/bin/pip" uninstall -y h11'), "3", "4",
                   ("type", '"$V/bin/pip" install -q h11==0.16.0 && STEP=2'), "3", "4", "5"])
    s.check("STOP at 3a first", "STOP at 3a" in out)
    s.check("then VERIFIED", "VERIFIED:" in out)
    s.check("released", "released (stub)" in out and not claim_file(s))
    s.check("V is 5.29.6 upb", pbver(s.V) == "5.29.6 upb")
    return s.finish()


def s18():
    s = Scn("S18_fingerprint_mismatch", "the parked venv is changed while parked; ROLLBACK must say ERROR, not 'unchanged'")
    s.setup()
    out = s.paste(["0", "H", "1", "2", ("inject", 'touch "$OLD/tampered-while-parked"'), "RB", ("type", "exit")])
    s.check("ERROR at rb3", "ERROR at rb3" in out)
    s.check("never 'restored unchanged'", "restored unchanged" not in out)
    s.check("the claim is kept (step 5 not reached)", claim_file(s))
    return s.finish()


def s19():
    s = Scn("S19_rollback_in_place", "a migrated venv (the three commands, fresh) and no parked one to move back: "
            "ROLLBACK IN PLACE, in the window")
    s.setup()
    out = s.paste(["0", "H", "1", "2", "3", ("type", 'rm -rf "$OLD"   # no parked venv left'), "IP",
                   ("type", "exit"), "5"])
    s.check("VERIFIED first (a real migrated venv as the starting point)", "VERIFIED:" in out)
    s.check("rolled back in place", "rolled back in place:" in out)
    s.check("V is 3.20.3 python", pbver(s.V) == "3.20.3 python")
    r = sh(f"PYTHONDONTWRITEBYTECODE=1 {s.V}/bin/python -m pip freeze --all | diff {FREEZE_MAIN} -; "
           f"PYTHONDONTWRITEBYTECODE=1 {s.V}/bin/python -m pip check")
    s.log.append("# freeze vs the main venv's (< main, > after ROLLBACK IN PLACE), then pip check:")
    s.log += ["   " + l for l in (r.stdout + r.stderr).splitlines()]
    s.check("released", not claim_file(s))
    return s.finish()


if __name__ == "__main__":
    sys.exit(main(set(sys.argv[1:])))
