"""Jobs: one directory per state-changing `ndt` command, readable after the server restarts.

[Co-developed with claude code -- Adam]

A job's state is never held only in this process's memory. It is DERIVED, every time it is
asked for, from the files in its directory and from /proc:

    exit.json present                              finished   (rc is what ndt exited with)
    no exit.json, the runner is alive              running
    no exit.json, runner gone, ndt still alive     orphaned   (ndt is running; nobody will record its rc)
    no exit.json, runner gone, ndt gone            lost       (it ended and nobody recorded how)

"Alive" is (pid, starttime) from /proc and not a zombie -- a pid alone can be reused, and a
zombie is a process that has already ended.

🔴 `running` AND `orphaned` both hold the service's one mutation slot (TICKET 3.5). An `ndt up`
whose runner was killed is still building a fabric, and a second job started beside it would be
exactly the overlap the slot exists to prevent. `ndt`'s own guards are still there behind this.
"""
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RUNNER = os.path.join(HERE, "runner.py")
JOB_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$")
HOLDS_THE_SLOT = ("running", "orphaned")


def proc_starttime(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            stat = f.read()
    except (OSError, TypeError):
        return None, None
    rest = stat[stat.rindex(")") + 2:].split()
    return rest[0], int(rest[19])


def alive(pid, starttime):
    """Is the process that was (pid, starttime) still running -- not reused, not a zombie?"""
    if not isinstance(pid, int) or pid <= 1 or starttime is None:
        return False
    state, st = proc_starttime(pid)
    return st == starttime and state not in ("Z", "X")


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_json_atomic(path, obj):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


class JobStore:
    def __init__(self, state_dir, meaning):
        self.root = os.path.join(state_dir, "jobs")
        os.makedirs(self.root, mode=0o700, exist_ok=True)
        self._meaning = meaning
        self._children = {}          # job id -> Popen of its runner, only so it gets reaped
        self._lock = threading.Lock()

    # --- creating ---------------------------------------------------------------------------
    def _new_id(self):
        return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + secrets.token_hex(3)

    def path(self, job_id, *parts):
        if not JOB_ID_RE.match(job_id or ""):
            raise KeyError(job_id)
        return os.path.join(self.root, job_id, *parts)

    def start(self, kind, argv, cwd, env, meta):
        """Write request.json and start the runner. The caller holds the mutation slot."""
        job_id = self._new_id()
        d = self.path(job_id)
        os.makedirs(d, mode=0o700)
        req = dict(meta)
        req.update({"id": job_id, "kind": kind, "argv": argv, "cwd": cwd, "created_at": time.time()})
        _write_json_atomic(os.path.join(d, "request.json"), req)
        with open(os.path.join(d, "runner.err"), "wb") as rerr:
            p = subprocess.Popen([sys.executable, RUNNER, d], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=rerr, env=env, cwd=d,
                                 close_fds=True, start_new_session=True)
        _write_json_atomic(os.path.join(d, "spawn.json"), {
            "runner_pid": p.pid, "runner_starttime": proc_starttime(p.pid)[1]})
        with self._lock:
            self._children[job_id] = p
        return job_id

    def reap(self):
        with self._lock:
            for job_id, p in list(self._children.items()):
                if p.poll() is not None:
                    del self._children[job_id]

    # --- reading ----------------------------------------------------------------------------
    def ids(self):
        try:
            names = os.listdir(self.root)
        except OSError:
            return []
        return sorted((n for n in names if JOB_ID_RE.match(n)), reverse=True)

    def view(self, job_id):
        d = self.path(job_id)
        req = _read_json(os.path.join(d, "request.json"))
        if req is None:
            raise KeyError(job_id)
        self.reap()
        spawn = _read_json(os.path.join(d, "spawn.json")) or {}
        run = _read_json(os.path.join(d, "runner.json")) or {}
        ex = _read_json(os.path.join(d, "exit.json"))
        runner_pid = run.get("runner_pid", spawn.get("runner_pid"))
        runner_st = run.get("runner_starttime", spawn.get("runner_starttime"))
        ndt_alive = alive(run.get("ndt_pid"), run.get("ndt_starttime"))
        if ex is not None:
            state, rc = "finished", ex.get("rc")
        elif alive(runner_pid, runner_st):
            state, rc = "running", None
        elif ndt_alive:
            state, rc = "orphaned", None
        else:
            state, rc = "lost", None
        v = {
            "id": job_id, "kind": req["kind"], "argv": req["argv"], "state": state, "rc": rc,
            "owner": req.get("owner"), "ndt_sha256": req.get("ndt_sha256"),
            "request": req.get("request"), "requested_by": req.get("requested_by"),
            "cell": req.get("cell"), "raw_root": req.get("raw_root"),
            "created_at": req.get("created_at"),
            "started_at": (ex or run).get("started_at"), "ended_at": (ex or {}).get("ended_at"),
            "ndt_pid": run.get("ndt_pid"), "ndt_pgid": run.get("ndt_pgid"),
            "stdout_bytes": _size(os.path.join(d, "stdout.log")),
            "stderr_bytes": _size(os.path.join(d, "stderr.log")),
        }
        if state == "finished":
            v["rc_class"], v["meaning"] = self._meaning(req["kind"], rc)
            if ex.get("spawn_error"):
                v["rc_class"], v["meaning"] = "failed", "ndt could not be started: " + ex["spawn_error"]
        elif state == "orphaned":
            v["rc_class"], v["meaning"] = "unknown", (
                "the runner is gone but ndt (pid %s) is still running; its rc will not be recorded -- "
                "read the output, then run status" % run.get("ndt_pid"))
        elif state == "lost":
            v["rc_class"], v["meaning"] = "unknown", (
                "the runner ended without recording an rc; read the output, then run status")
        else:
            v["rc_class"], v["meaning"] = None, "running"
        return v

    def list(self, limit):
        """Newest first by created_at. The id's clock has one-second resolution and its suffix is
        random, so two jobs started in the same second would otherwise come back in random order
        (live 09-24 22:01: the claim listed after the `up` it preceded)."""
        out = []
        for job_id in self.ids():
            try:
                out.append(self.view(job_id))
            except KeyError:
                continue
        out.sort(key=lambda v: (v.get("created_at") or 0, v["id"]), reverse=True)
        return out[:limit]

    def holding_the_slot(self):
        """The job that holds the mutation slot, or None -- read from disk, so a restarted server
        finds a job the previous one started."""
        for job_id in self.ids():
            d = self.path(job_id)
            if os.path.exists(os.path.join(d, "exit.json")):
                continue
            try:
                v = self.view(job_id)
            except KeyError:
                continue
            if v["state"] in HOLDS_THE_SLOT:
                return v
        return None

    def wait(self, job_id, timeout):
        deadline = time.monotonic() + timeout
        v = self.view(job_id)
        while v["state"] == "running" and time.monotonic() < deadline:
            time.sleep(0.2)
            v = self.view(job_id)
        return v

    def read_log(self, job_id, stream, offset, limit):
        if stream not in ("stdout", "stderr"):
            raise KeyError(stream)
        p = self.path(job_id, stream + ".log")
        if not os.path.exists(self.path(job_id, "request.json")):
            raise KeyError(job_id)
        size = _size(p)
        if size is None:
            return b"", 0
        with open(p, "rb") as f:
            f.seek(min(offset, size))
            return f.read(limit), size


def _size(p):
    try:
        return os.path.getsize(p)
    except OSError:
        return None
