#!/usr/bin/env python3
"""Run one `ndt` command for ndt serve, detached from the server, and record how it ended.

[Co-developed with claude code -- Adam]

    runner.py <job-dir>

The server starts this in a NEW SESSION (setsid) and returns. From then on this process, not the
server, owns the job: it starts `ndt` -- in a session of its own again -- with stdout and stderr
going straight to files, waits for it, and writes exit.json. The server can die, be restarted, or
never come back, and the job still runs to the end and still leaves its rc on disk (TICKET 3.5).

Why two sessions and not one:

  * the runner's own session keeps the job out of the server's process group, so a Ctrl-C or a
    closed terminal that takes the server down does not take the job with it;
  * `ndt`'s session keeps the runner out of `ndt`'s process group. `ndt up`/`ndt down` have killed
    the shell that called them (exit 144, 2026-08-29, memory ndt-one-command-lab-lifecycle) --
    the runner is that caller here, and a runner that dies there leaves an rc nobody recorded.

Output goes to FILES, never to a pipe back to the server: a pipe whose reader has died turns the
next write into SIGPIPE, which would be the server's death killing the job by another route.

Files in <job-dir> (the server wrote request.json before starting this):

    request.json   the argv, read here              (server)
    runner.json    runner pid, ndt pid/pgid/start   (here, as soon as ndt is running)
    stdout.log     ndt's stdout, byte for byte      (ndt)
    stderr.log     ndt's stderr, byte for byte      (ndt)
    exit.json      {"rc": <int>, ...}               (here, atomically, once ndt has been reaped)

🔴 No signal is ever sent from here, and there is no pattern-matching of process names anywhere
in this service (TICKET 3.6).
"""
import json
import os
import subprocess
import sys
import time


def _write_json_atomic(path, obj):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def proc_starttime(pid):
    """Field 22 of /proc/<pid>/stat: when the process started, in clock ticks since boot.

    A pid can be reused; (pid, starttime) cannot. Everything that later asks "is it still alive"
    compares both.
    """
    try:
        with open("/proc/%d/stat" % pid) as f:
            stat = f.read()
    except OSError:
        return None
    # comm is in parentheses and may itself contain spaces or parentheses; split after the LAST ')'
    return int(stat[stat.rindex(")") + 2:].split()[19])


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: runner.py <job-dir>\n")
        return 2
    job = argv[1]
    with open(os.path.join(job, "request.json")) as f:
        req = json.load(f)
    started = time.time()
    with open(os.path.join(job, "stdout.log"), "wb") as out, \
         open(os.path.join(job, "stderr.log"), "wb") as err:
        try:
            p = subprocess.Popen(req["argv"], stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                 cwd=req["cwd"], close_fds=True, start_new_session=True)
        except OSError as e:
            _write_json_atomic(os.path.join(job, "exit.json"), {
                "rc": None, "spawn_error": str(e), "started_at": started, "ended_at": time.time()})
            return 1
        _write_json_atomic(os.path.join(job, "runner.json"), {
            "runner_pid": os.getpid(), "runner_starttime": proc_starttime(os.getpid()),
            "runner_sid": os.getsid(0),
            "ndt_pid": p.pid, "ndt_pgid": p.pid, "ndt_starttime": proc_starttime(p.pid),
            "started_at": started})
        rc = p.wait()
    _write_json_atomic(os.path.join(job, "exit.json"), {
        "rc": rc, "started_at": started, "ended_at": time.time()})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
