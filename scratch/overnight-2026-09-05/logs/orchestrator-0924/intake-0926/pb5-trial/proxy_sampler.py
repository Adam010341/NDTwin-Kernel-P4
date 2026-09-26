#!/usr/bin/env python3
"""Read-only /proc sampler for the P4 proxy during the protobuf-5 live trial.

[Co-developed with claude code -- Adam]

Reads only: .test_run/pids/p4_proxy.pid, /proc/<pid>/{stat,status,exe,cmdline,cwd,environ,maps}
and .test_run/logs/p4_proxy.log (copied, never written). Signals nothing, kills nothing.
The proxy's python process is found as the process whose process group is the supervisor
pid recorded in p4_proxy.pid (stack.sh starts it under setsid) and whose exe is a python.

Writes JSONL events to <notes>/sampler.jsonl and copies each proxy's log to
<notes>/proxylogs/<label>_<pid>.log. The label is read from <notes>/current_label when a new
proxy pid first appears. Stops when <notes>/sampler.stop exists.
"""
import json
import os
import sys
import time

REPO = "/home/adam/Desktop/NDTwin-Kernel"
NOTES = sys.argv[1]
PIDFILE = os.path.join(REPO, ".test_run/pids/p4_proxy.pid")
PLOG = os.path.join(REPO, ".test_run/logs/p4_proxy.log")
OUT = os.path.join(NOTES, "sampler.jsonl")
LOGDIR = os.path.join(NOTES, "proxylogs")
STOP = os.path.join(NOTES, "sampler.stop")
LABEL = os.path.join(NOTES, "current_label")
TCK = os.sysconf("SC_CLK_TCK")
os.makedirs(LOGDIR, exist_ok=True)

with open("/proc/stat") as fh:
    BTIME = int([l for l in fh if l.startswith("btime")][0].split()[1])


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".%03dZ" % (int(time.time() * 1000) % 1000)


def emit(ev):
    ev["ts"] = now()
    with open(OUT, "a") as fh:
        fh.write(json.dumps(ev, sort_keys=True) + "\n")


def rd(path, mode="r"):
    try:
        with open(path, mode) as fh:
            return fh.read()
    except OSError:
        return None


def stat_fields(pid):
    s = rd("/proc/%d/stat" % pid)
    if not s:
        return None
    rest = s[s.rindex(")") + 2:].split()
    # rest[0] is field 3 (state); pgrp is field 5 -> rest[2]; utime 14 -> rest[11]; stime 15 -> rest[12];
    # starttime 22 -> rest[19]
    return {"pgrp": int(rest[2]), "utime": int(rest[11]), "stime": int(rest[12]),
            "start": BTIME + int(rest[19]) / TCK}


def status_kb(pid):
    s = rd("/proc/%d/status" % pid) or ""
    out = {}
    for line in s.splitlines():
        k = line.split(":")[0]
        if k in ("VmRSS", "VmHWM", "Threads"):
            out[k] = int(line.split()[1])
    return out


def find_proxy():
    sup = (rd(PIDFILE) or "").strip()
    if not sup.isdigit():
        return None, None
    sup = int(sup)
    if not os.path.exists("/proc/%d" % sup):
        return sup, None
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        pid = int(d)
        st = stat_fields(pid)
        if not st or st["pgrp"] != sup:
            continue
        try:
            exe = os.readlink("/proc/%d/exe" % pid)
        except OSError:
            continue
        if os.path.basename(exe).startswith("python"):
            return sup, pid
    return sup, None


def copy_log_if_ours(pid, dst):
    """Copy the live proxy log only if it is THIS pid's log (uvicorn prints its pid)."""
    body = rd(PLOG)
    if body is None:
        return "no log"
    # A proxy that died at import never prints the uvicorn line; its log is still the one to keep.
    if "Started server process [" in body and ("Started server process [%d]" % pid) not in body:
        return "log belongs to another process; kept the earlier copy"
    with open(dst, "w") as fh:
        fh.write(body)
    return dst


def env_subset(pid):
    raw = rd("/proc/%d/environ" % pid, "rb")
    if raw is None:
        return {"_unreadable": True}
    keep = {}
    names = []
    for item in raw.split(b"\0"):
        if not item or b"=" not in item:
            continue
        k, v = item.split(b"=", 1)
        k = k.decode(errors="replace")
        names.append(k)
        if k.startswith(("PROTOCOL_BUFFERS", "P4_PROXY", "PYTHON", "NDTWIN", "NDT_")):
            keep[k] = v.decode(errors="replace")
    keep["_PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION_present"] = \
        "PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION" in names
    return keep


def maps_subset(pid):
    s = rd("/proc/%d/maps" % pid)
    if s is None:
        return None
    paths = set()
    for line in s.splitlines():
        parts = line.split(None, 5)
        if len(parts) == 6:
            p = parts[5]
            if "/google/" in p or "_upb" in p or "protobuf" in p or "/grpc/" in p or \
                    "site-packages" in p or "libpython" in p or p.endswith("python3.13"):
                paths.add(p)
    return sorted(paths)


seen = {}          # pid -> dict(label, first, last sample, maps)
last_copy = {}

emit({"event": "sampler_start", "pid": os.getpid(), "notes": NOTES})
while not os.path.exists(STOP):
    sup, pid = find_proxy()
    t = time.time()
    if pid and pid not in seen:
        label = (rd(LABEL) or "unlabelled").strip()
        st = stat_fields(pid)
        try:
            exe = os.readlink("/proc/%d/exe" % pid)
            cwd = os.readlink("/proc/%d/cwd" % pid)
        except OSError:
            exe = cwd = None
        cmd = (rd("/proc/%d/cmdline" % pid) or "").split("\0")
        seen[pid] = {"label": label, "first": t, "start": st["start"] if st else None,
                     "maps": None, "last": None, "sup": sup}
        emit({"event": "new", "label": label, "pid": pid, "supervisor": sup, "exe": exe,
              "cwd": cwd, "cmdline": [c for c in cmd if c],
              "start_epoch": st["start"] if st else None, "environ": env_subset(pid)})
    if pid and pid in seen:
        rec = seen[pid]
        st = stat_fields(pid)
        kb = status_kb(pid)
        if st:
            rec["last"] = {"t": t, "cpu_s": (st["utime"] + st["stime"]) / TCK,
                           "rss_kb": kb.get("VmRSS"), "hwm_kb": kb.get("VmHWM"),
                           "threads": kb.get("Threads"), "age_s": round(t - st["start"], 2)}
            emit(dict(event="sample", label=rec["label"], pid=pid, **rec["last"]))
        # maps: record the first reading taken at least 3 s after start, and any later change
        if st and t - st["start"] >= 3:
            m = maps_subset(pid)
            if m is not None and m != rec["maps"]:
                rec["maps"] = m
                emit({"event": "maps", "label": rec["label"], "pid": pid, "age_s": round(t - st["start"], 2),
                      "paths": m, "upb_message_so": [p for p in m if "/google/_upb/_message" in p]})
        if t - last_copy.get(pid, 0) >= 5:
            dst = os.path.join(LOGDIR, "%s_%d.log" % (rec["label"], pid))
            copy_log_if_ours(pid, dst)
            last_copy[pid] = t
    # anything we saw that is now gone
    for gp in list(seen):
        rec = seen[gp]
        if rec.get("gone"):
            continue
        if not os.path.exists("/proc/%d" % gp):
            rec["gone"] = True
            dst = os.path.join(LOGDIR, "%s_%d.log" % (rec["label"], gp))
            copied = copy_log_if_ours(gp, dst)
            emit({"event": "gone", "label": rec["label"], "pid": gp, "last": rec["last"],
                  "log_copy": copied})
    time.sleep(1.0)
emit({"event": "sampler_stop", "pid": os.getpid()})
