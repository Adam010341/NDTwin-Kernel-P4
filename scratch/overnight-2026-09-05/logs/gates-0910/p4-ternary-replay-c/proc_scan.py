"""proc_scan.py: the throwaway bmv2 processes around one S0 run, read from /proc, never signalled.

  proc_scan.py pre <out>                       every process whose comm or exe looks like a bmv2 or a throwaway
  proc_scan.py watch <out> <pid> <run_dir>     every 0.1 s until <pid> ends: each such process whose parent chain
                                               reaches <pid>, recorded once (pid, ppid, comm, exe, cwd)
  proc_scan.py post <out> <run_dir> <watched>  every such process left, and whether it is ours (sampled by watch,
                                               or its cwd in <run_dir>)
A match: comm starting simple_switch, ndt-hc- or ndt-hb (the names the drop check and throwaway.py give theirs; comm
is cut at 15 bytes), or an exe whose name starts simple_switch.
"""
import os, sys, time

def read(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return None

def link(path):
    try:
        return os.readlink(path)
    except OSError:
        return None

def ppid(pid):
    s = read("/proc/%s/status" % pid) or ""
    for line in s.splitlines():
        if line.startswith("PPid:"):
            return line.split()[1]
    return None

def match(pid):
    comm, exe = read("/proc/%s/comm" % pid), link("/proc/%s/exe" % pid)
    ok = bool(comm) and comm.startswith(("simple_switch", "ndt-hc-", "ndt-hb")) or \
        bool(exe) and os.path.basename(exe).startswith("simple_switch")
    return ok, comm, exe

def pids():
    return [d for d in os.listdir("/proc") if d.isdigit()]

def chain_has(pid, root):
    p, n = pid, 0
    while p and p not in ("0", "1") and n < 64:
        if p == root:
            return True
        p, n = ppid(p), n + 1
    return False

mode, out = sys.argv[1], sys.argv[2]
with open(out, "a") as fh:
    stamp = lambda: time.strftime("%Y-%m-%dT%H:%M:%S%z")
    if mode == "pre":
        fh.write("%s pre-scan\n" % stamp())
        for p in pids():
            ok, comm, exe = match(p)
            if ok:
                fh.write("present pid %s comm %s exe %s\n" % (p, comm, exe))
        fh.write("pre-scan done\n")
    elif mode == "watch":
        root, run = sys.argv[3], sys.argv[4]
        seen = set()
        fh.write("%s watching the parent chains under pid %s\n" % (stamp(), root))
        while os.path.exists("/proc/%s" % root):
            for p in pids():
                if p in seen:
                    continue
                ok, comm, exe = match(p)
                if ok and chain_has(p, root):
                    seen.add(p)
                    fh.write("%s started pid %s ppid %s comm %s exe %s cwd %s\n"
                             % (stamp(), p, ppid(p), comm, exe, link("/proc/%s/cwd" % p)))
                    fh.flush()
            time.sleep(0.1)
        fh.write("%s pid %s ended; %d recorded\n" % (stamp(), root, len(seen)))
    elif mode == "post":
        run, watched = sys.argv[3], sys.argv[4]
        recorded = set()
        for line in (read(watched) or "").splitlines():
            if " started pid " in line:
                recorded.add(line.split(" started pid ")[1].split()[0])
        fh.write("%s post-scan\n" % stamp())
        for p in pids():
            ok, comm, exe = match(p)
            if ok:
                cwd = link("/proc/%s/cwd" % p) or ""
                ours = "yes (recorded)" if p in recorded else ("yes (cwd in the run dir)" if cwd.startswith(run) else "no")
                fh.write("left pid %s comm %s exe %s ours=%s\n" % (p, comm, exe, ours))
        fh.write("post-scan done\n")
