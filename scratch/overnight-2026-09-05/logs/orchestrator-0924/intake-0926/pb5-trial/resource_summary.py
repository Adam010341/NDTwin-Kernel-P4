"""One row per proxy process the sampler saw: label, package, interpreter, _upb mapped?, lifetime,
CPU seconds, peak RSS. [Co-developed with claude code -- Adam]"""
import json
import os
import re
import sys

N = sys.argv[1]
procs = {}
for line in open(os.path.join(N, "sampler.jsonl")):
    e = json.loads(line)
    pid = e.get("pid")
    if e["event"] == "new":
        procs[pid] = {"label": e["label"], "interp": e["cmdline"][0] if e["cmdline"] else "?",
                      "pbenv": e["environ"].get("_PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION_present"),
                      "upb": None, "last": None, "ts": e["ts"]}
    elif e["event"] == "maps" and pid in procs:
        procs[pid]["upb"] = bool(e["upb_message_so"])
        procs[pid]["upb_path"] = e["upb_message_so"]
    elif e["event"] == "sample" and pid in procs:
        procs[pid]["last"] = e
    elif e["event"] == "gone" and pid in procs:
        procs[pid]["gone"] = True
print("%-10s %-8s %-26s %-6s %-5s %6s %6s %8s %8s %s" % (
    "label", "pid", "package", "venv", "upb", "life_s", "cpu_s", "cpu/s", "hwm_MB", "first seen"))
for pid, p in procs.items():
    pkg = "?"
    lp = os.path.join(N, "proxylogs", "%s_%d.log" % (p["label"], pid))
    if os.path.exists(lp):
        m = re.search(r"\[Proxy Agent\] app package: (\S+)", open(lp, errors="replace").read())
        pkg = os.path.basename(m.group(1)) if m else "?"
    l = p["last"] or {}
    venv = "cand" if "venv-cand" in p["interp"] else ("main" if "p4_proxy/venv" in p["interp"] else "?")
    life = l.get("age_s") or 0
    cpu = l.get("cpu_s") or 0
    print("%-10s %-8d %-26s %-6s %-5s %6.1f %6.2f %8.3f %8.1f %s%s" % (
        p["label"], pid, pkg[:26], venv, p["upb"], life, cpu, cpu / life if life else 0,
        (l.get("hwm_kb") or 0) / 1024, p["ts"], "" if p.get("gone") else "  (still alive at last read)"))
