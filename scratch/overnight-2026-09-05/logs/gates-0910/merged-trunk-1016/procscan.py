"""procscan.py <out> : append every process (other than this one and its ancestors) whose argv mentions mutate_ or
probe.py, read from /proc, never signalled. Exit 0 none, 1 some found. [Co-developed with claude code -- Adam]

A process whose argv also mentions this log directory is OURS (the driver's own waiting shells and tools, which are not
on this process's ancestor chain); it is listed as ours and does not count."""
import os, sys
L = os.path.dirname(os.path.abspath(__file__))
def read(p):
    try:
        with open(p, "rb") as fh: return fh.read()
    except OSError: return b""
def ppid(pid):
    for line in read("/proc/%s/status" % pid).decode(errors="replace").splitlines():
        if line.startswith("PPid:"): return line.split()[1]
    return None
mine, p = set(), str(os.getpid())
while p and p != "0":
    mine.add(p); p = ppid(p)
found, ours = [], []
for d in os.listdir("/proc"):
    if not d.isdigit() or d in mine: continue
    argv = read("/proc/%s/cmdline" % d).split(b"\0")
    text = " ".join(a.decode(errors="replace") for a in argv if a)
    if "mutate_" in text or "probe.py" in text:
        (ours if L in text or "c-replay" in text else found).append("pid %s ppid %s: %s" % (d, ppid(d), text[:200]))
with open(sys.argv[1], "a") as fh:
    fh.write("procscan: %d other mutate_/probe.py process(es), %d of this run's own skipped\n" % (len(found), len(ours)))
    for f in found: fh.write("  other " + f + "\n")
    for f in ours: fh.write("  ours  " + f + "\n")
sys.exit(1 if found else 0)
