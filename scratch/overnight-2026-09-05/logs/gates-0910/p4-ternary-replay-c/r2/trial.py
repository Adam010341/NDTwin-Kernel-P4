"""Cut C offline trial: does a proxy restart put the API's entries back on a warm bmv2, and only there?

[Co-developed with claude code -- Adam]

usage: <proxy venv python> trial.py <checkout> <work dir> <out.json>

Not a gate subject: a one-off observation kept with its logs, in the spirit of p4-health-ternary-d/r2/t4t7_trial.py.
For each of the two simple_switch_grpc binaries -- stock /usr/local/bin/simple_switch_grpc and the fabric's bmv2-fast
(vs_trial.fabric_binary) -- one throwaway switch, started the way S0's trials start theirs (throwaway.py: pcap mode, no
root, argv0 ndt-hc-replayc, thrift 29500-29599, gRPC 29650-29699, stopped by its pid; device id 2, the dpid the
proxy's client uses), running hc_main as S0 compiles it, with package A as S0 converts it:

  boot 1  a proxy process (trial_boot.py) on the FRESH switch: startup, then POSTs through the real route -- an exact,
          an lpm and a ternary entry at priority 10, then a delete at priority 20 (NOT_FOUND) and an insert at 20;
  boot 2  a NEW proxy process on the SAME (warm) switch: startup must confirm the cookie and replay all four, and the
          switch must hold exactly what it held after boot 1 (P4Runtime read: match and action params);
  boot 3  (round 2) lost answers on two package boot entries B and B2: each DELETE is written straight through the
          client (it lands, nothing records it), the retry through the route meets NOT_FOUND; then B2 is inserted as S;
  boot 4  a new process on the warm switch: B (put back by the package) is deleted again; B2 ends as S (the insert
          meets ALREADY_EXISTS and is retried as a modify);
  boot 5  (round 2) a new process on the warm switch; the bmv2 process is then restarted UNDER it and re-adopted
          through main.readopt_switch and the real TopologyManager: a POST while pending is 503 replay pending, the push
          carries this boot's generation, and the switch ends holding what it held after boot 4;
  boot 6  the switch is stopped and a fresh one started; a NEW proxy process: startup must set the journal aside
          (FAILED_PRECONDITION) and replay nothing.

After every boot the parent reads the three tables with thrift (table_dump), and keeps the journal directory's
listing and the live file's bytes. Every pid this script starts is recorded; it signals only those.
"""
import json
import os
import shutil
import subprocess
import sys
import time

checkout, work, out_path = (os.path.abspath(a) for a in sys.argv[1:4])
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(checkout, "tools"))
sys.path.insert(0, os.path.join(checkout, "p4_proxy"))

from p4_health import s0 as S0M                           # noqa: E402
from p4_health import throwaway as TW                     # noqa: E402
from p4_health import vs_trial as VT                      # noqa: E402
from p4_health.collect.config import default_p4dev_python  # noqa: E402
from p4_health.collect.runner import Runner               # noqa: E402

TW.DEVICE_ID = 2      # the proxy's client for dpid 2 speaks to device id 2, as on the fabric
TABLES = ("HcIngress.port_exact", "HcIngress.ipv4_lpm", "HcIngress.t_ternary")
#: What the trial's POSTs put in each table's thrift dump: the exact key 7, 10.0.77.0/24, and 10.0.77.1 at two priorities.
KEYS = {"HcIngress.port_exact": "EXACT     0007", "HcIngress.ipv4_lpm": "0a004d00/24",
        "HcIngress.t_ternary": "0a004d01 &&& ffffffff"}
os.makedirs(work, exist_ok=True)
py_p4 = os.path.join(checkout, "p4_proxy", "venv", "bin", "python")
cli = [default_p4dev_python(), "/usr/local/bin/simple_switch_CLI"]
started = []          # every pid this trial started, in order

s0 = S0M.S0(os.path.join(work, "s0"), Runner(), py_p4, log=lambda *a: None)
os.makedirs(s0.run_dir, exist_ok=True)
assert s0.compile_all(), s0.out["builds"]
pkg_a = s0.convert("A", "topology.json", "ndtwin")
assert pkg_a, s0.out["checks"]
with open(os.path.join(pkg_a, "package.json")) as fh:
    package = json.load(fh)
assert "roles" not in package, package.get("roles")
sw2 = package["switches"]["2"]["pipeline"]
js = os.path.join(pkg_a, sw2["bmv2_json"])


def a_switch(bmv2, label, n):
    sw = TW.Throwaway(js, {1: [], 2: [], 3: []}, 510, cli, wait_s=2, bmv2=bmv2,
                      workdir=os.path.join(work, "switch-%s-%d" % (label, n)), argv0="ndt-hc-replayc", grpc=True)
    os.makedirs(sw.workdir, exist_ok=True)
    sw.start()
    started.append({"what": "simple_switch_grpc %s #%d" % (label, n), "pid": sw.proc.pid,
                    "thrift": sw.thrift_port, "grpc": sw.grpc_port})
    print("started %s #%d pid %d thrift %d grpc %d" % (label, n, sw.proc.pid, sw.thrift_port, sw.grpc_port),
          flush=True)
    return sw


def dumps(sw):
    out = {}
    for t in TABLES:
        text = sw.cli(["table_dump %s" % t])
        out[t] = {"raw": text, "entries": text.count("Dumping entry"), "ours": text.count(KEYS[t])}
    return out


def journal_state(jdir):
    files = sorted(os.listdir(jdir)) if os.path.isdir(jdir) else []
    live = os.path.join(jdir, "s2.jsonl")
    data = open(live, "rb").read().decode() if os.path.exists(live) else None
    return {"files": files, "live": data}


def boot(label, n, sw, jdir, plan, during=None):
    """One proxy process. `during(work)`, when given, runs while the child is up (the readopt plan
    hands the bmv2 restart to it) and returns the switch the child ends on."""
    out = os.path.join(work, "boot-%s-%d.json" % (label, n))
    bwork = os.path.join(work, "boot-%s-%d" % (label, n))
    argv = [py_p4, os.path.join(HERE, "trial_boot.py"), checkout, pkg_a, str(sw.grpc_port), jdir, bwork, plan, out]
    os.makedirs(bwork, exist_ok=True)
    proc = subprocess.Popen(argv, cwd=checkout, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    started.append({"what": "proxy boot %s #%d (%s)" % (label, n, plan), "pid": proc.pid})
    if during is not None:
        sw = during(bwork, sw)
    text, _ = proc.communicate(timeout=300)
    with open(os.path.join(work, "boot-%s-%d.log" % (label, n)), "w") as fh:
        fh.write(text)
    print(text.strip().splitlines()[-1] if text.strip() else "(no output)", flush=True)
    res = json.load(open(out)) if os.path.exists(out) else {"error": "no result", "rc": proc.returncode}
    res["rc"] = proc.returncode
    res["after"] = {"dumps": dumps(sw), "journal": journal_state(jdir)}
    return res, sw


def one(bmv2, label):
    res = {"bmv2": bmv2, "label": label, "boots": []}
    jdir = os.path.join(work, "journal-" + label)
    if os.path.exists(jdir):
        shutil.rmtree(jdir)
    sw = a_switch(bmv2, label, 1)
    switches = [sw]

    def restart_under_the_proxy(bwork, old):
        ready = os.path.join(bwork, "ready")
        for _ in range(1200):
            if os.path.exists(ready):
                break
            time.sleep(0.1)
        res["stop_1"] = old.stop()
        print("stopped %s #1 pid %d rc %s (under a running proxy)" % (label, old.proc.pid, res["stop_1"]), flush=True)
        new = a_switch(bmv2, label, 2)
        switches.append(new)
        with open(os.path.join(bwork, "restarted"), "w") as fh:
            fh.write(str(new.grpc_port))
        return new
    try:
        for n, plan in ((1, "write"), (2, "read"), (3, "lostanswer"), (4, "read")):
            b, sw = boot(label, n, sw, jdir, plan)
            res["boots"].append(b)
        b, sw = boot(label, 5, sw, jdir, "readopt", during=restart_under_the_proxy)
        res["boots"].append(b)
        res["warm_live_before_restart"] = journal_state(jdir)["live"]
    finally:
        for w in switches:
            if w.alive():
                rc = w.stop()
                print("stopped %s pid %d rc %s" % (label, w.proc.pid, rc), flush=True)
    sw = a_switch(bmv2, label, 3)
    try:
        b, sw = boot(label, 6, sw, jdir, "read")
        res["boots"].append(b)
    finally:
        res["stop_3"] = sw.stop()
        print("stopped %s #3 pid %d rc %s" % (label, sw.proc.pid, res["stop_3"]), flush=True)
    res["checks"] = judge(res, jdir)
    return res


def lpm_key(e):
    v, plen = e["match"]["hdr.ipv4.dstAddr"]
    return "%08x" % int.from_bytes(bytes(int(x) for x in v.split(".")), "big"), int(plen)


def find_lpm(on, e):
    want = lpm_key(e)
    for x in on:
        m = x["match"].get("hdr.ipv4.dstAddr") or {}
        if x["table"] == "HcIngress.ipv4_lpm" and (str(m.get("value", "")).rjust(8, "0"), m.get("prefix_len")) == want:
            return x
    return None


def judge(res, jdir):
    b1, b2, b3, b4, b5, b6 = res["boots"]
    c = {}
    st = [p["status"] for p in b1["posts"]]
    c["boot1 posts 200,200,200,502,200"] = st == [200, 200, 200, 502, 200]
    c["boot1 the 502 is the switch's NOT_FOUND"] = (b1["posts"][3]["answer"].get("p4rt_error") or {}).get("code") == "NOT_FOUND"
    c["boot1 every 200 says journaled true"] = all(p["answer"].get("journaled") is True for p in b1["posts"] if p["status"] == 200)
    c["boot1 the not_found delete is recorded"] = [r["outcome"] for r in b1["journal_after"]["records"]] == ["ok", "ok", "ok", "not_found", "ok"]
    r1 = b1["switch_state_table_entries"]["journal"]["replay"]
    c["boot1 startup on a fresh switch: fresh_fabric, FAILED_PRECONDITION"] = (r1["fresh_fabric"] is True and "FAILED_PRECONDITION" in r1["cookie"])
    c["boot1 T8 GREEN"] = b1["t8"]["verdict"] == "GREEN"
    r2 = b2["switch_state_table_entries"]["journal"]["replay"]
    c["boot2 a new proxy process"] = b2["boot_id"] != b1["boot_id"] and b2["pid"] != b1["pid"]
    c["boot2 cookie confirmed, not fresh"] = r2["fresh_fabric"] is False and r2["cookie"] == "confirmed"
    c["boot2 the same generation"] = b2["generation"] == b1["generation"]
    c["boot2 replay complete 4/4"] = (r2["status"], r2["attempted"], r2["succeeded"]) == ("complete", 4, 4)
    c["boot2 restored ops: four inserts (priority 20 is an insert)"] = [x["op"] for x in r2["restored"]] == ["insert"] * 4
    c["boot2 journaled true"] = b2["switch_state_table_entries"]["journaled"] is True
    c["boot2 T8 GREEN"] = b2["t8"]["verdict"] == "GREEN"
    d2 = b2["after"]["dumps"]
    c["boot2 thrift: exact, lpm and both ternary entries are on the switch"] = (
        d2["HcIngress.port_exact"]["ours"] == 1 and d2["HcIngress.ipv4_lpm"]["ours"] == 1
        and d2["HcIngress.t_ternary"]["ours"] == 2)
    d1 = b1["after"]["dumps"]
    c["boot2 thrift: the same entry counts as after boot 1"] = all(d1[t]["ours"] == d2[t]["ours"] and d1[t]["entries"] == d2[t]["entries"] for t in TABLES)
    c["boot2 P4Runtime read: every entry, match and action params, equal to boot 1's"] = b2["on_switch"] == b1["on_switch"] and len(b1["on_switch"]) > 0
    c["boot2 header names boot 2"] = b2["journal_after"]["header"]["boot_id"] == b2["boot_id"]
    used = b3["boot_entries_used"]
    p3 = [(p["status"], (p["answer"].get("p4rt_error") or {}).get("code") if p["status"] != 200 else None) for p in b3["posts"]]
    c["boot3 lost-answer deletes: the retries are NOT_FOUND, then S is a 200"] = p3 == [(502, "NOT_FOUND"), (502, "NOT_FOUND"), (200, None)]
    c["boot3 B and B2 are off the switch, S is on"] = (find_lpm(b3["on_switch"], used["B"]) is None
                                                    and find_lpm(b3["on_switch"], used["S"]) is not None)
    r4 = b4["switch_state_table_entries"]["journal"]["replay"]
    on4 = b4["on_switch"]
    s4 = find_lpm(on4, used["S"])
    c["boot4 B, re-installed by the package, is deleted again"] = find_lpm(on4, used["B"]) is None
    c["boot4 B2 ends as S (the insert met ALREADY_EXISTS and was retried as a modify)"] = (
        s4 is not None and int(s4["params"]["port"], 16) == int(used["S"]["action_params"]["port"])
        and len(r4["retried_as_modify"]) == 1)
    c["boot4 replay complete, nothing failed"] = r4["status"] == "complete" and r4["failed"] == []
    tail = [(r["op"], r["outcome"]) for r in b4["journal_after"]["records"]][-3:]
    c["boot4 snapshot: B's delete, and S with its unknown start"] = tail == [("delete", "ok"), ("delete", "not_found"), ("insert", "ok")] or \
        sorted(tail) == sorted([("delete", "ok"), ("delete", "not_found"), ("insert", "ok")])
    ro = b5.get("readopt") or {}
    c["boot5 readopt of the restarted bmv2 succeeded"] = ro.get("status") == "success"
    pw = b5.get("post_while_pending") or {}
    c["boot5 a POST while the readopt is pending is 503 replay pending"] = (
        isinstance(pw, dict) and pw.get("status") == 503 and (pw.get("answer") or {}).get("error") == "replay pending")
    c["boot5 the readopt's push carries G"] = b5["cookie_after_readopt"] == b5["generation"] and b5["generation"] == b4["generation"]
    rr = (ro.get("table_entries") or {}).get("replay") or {}
    c["boot5 the readopt replayed (not fresh)"] = rr.get("when") == "readopt" and rr.get("status") == "complete"
    c["boot5 after the readopt the switch holds exactly what it held after boot 4"] = b5["on_switch"] == on4
    r6 = b6["switch_state_table_entries"]["journal"]["replay"]
    c["boot6 fresh bmv2: fresh_fabric, FAILED_PRECONDITION"] = r6["fresh_fabric"] is True and "FAILED_PRECONDITION" in r6["cookie"]
    c["boot6 nothing replayed"] = r6["attempted"] == 0 and r6["restored"] == []
    d6 = b6["after"]["dumps"]
    c["boot6 thrift: none of the API's entries"] = all(d6[t]["ours"] == 0 for t in TABLES)
    c["boot6 live journal: a header and nothing else"] = b6["journal_after"]["records"] == []
    sets = [os.path.join(jdir, n) for n in b6["after"]["journal"]["files"] if ".q" in n]
    kept = [open(p).read() for p in sets]
    c["boot6 the warm journal is set aside byte for byte"] = res["warm_live_before_restart"] in kept
    c["boot6 a new generation"] = b6["generation"] != b5["generation"]
    c["every boot exited 0"] = all(b["rc"] == 0 for b in res["boots"])
    return c


results = []
for bmv2, label in (("/usr/local/bin/simple_switch_grpc", "stock"), (VT.fabric_binary(), "fast")):
    results.append(one(bmv2, label))
doc = {"started": started, "results": results}
with open(out_path, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True, default=repr)
ok = True
for r in results:
    print("%-5s %s" % (r["label"], r["bmv2"]))
    for name, passed in r["checks"].items():
        print("      %-4s %s" % ("ok" if passed else "FAIL", name))
        ok = ok and passed
print("pids started: %s" % ", ".join("%s=%d" % (s["what"], s["pid"]) for s in started))
print("ALL CHECKS PASS" if ok else "NOT ALL CHECKS PASS")
sys.exit(0 if ok else 1)
