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

  Round 4 adds the restart-in-the-middle sequence (`one_m1`, on a switch and a journal of its own, per bmv2 binary):
    1. insert at priority 10 -> 200;       2. delete at priority 20 -> NOT_FOUND;      3. restart the proxy;
    4. insert at priority 20 -> 200, journaled;   5. restart the proxy;
    6. the priority-20 entry is on the switch (thrift and a P4Runtime read) and in the journal.

  Round 5 adds the modify-that-finds-nothing sequences (`one_m2`, `one_m2b`, a switch and a journal of their own each, per
  bmv2 binary). K is the ternary entry at priority 10 and S is the same key with another action parameter:
    m2:   1. insert K straight through the P4Runtime client (no proxy, no journal);   2. POST delete K -> 200;
          3. POST insert S at K -> 200, journaled;   4. restart the proxy;   5. restart the proxy again.
    m2b:  1, 2 as above;   restart the proxy;   3. POST insert S at K;   4. restart the proxy;   5. restart again.
  After each restart that replays the modify: retried_as_insert == [K], S read back by thrift and by P4Runtime, and the
  live journal file ends as [modify/ok S].

Added for the round-5 review's "bmv2 readopt of A" (`one_m2r`, a switch and a journal of its own, per bmv2 binary; copied
to p4-journal-r5-tests/ from merged-trunk-1015/, nothing else changed) [Co-developed with claude code -- Adam]:
    m2r:  boot 1, one proxy process: 1. insert K straight through the client;  2. POST delete K -> 200;  3. POST insert S
          -> 200, journaled;  4. the bmv2 is restarted under the proxy and re-adopted (main.readopt_switch, the real
          TopologyManager): the readopt's replay is the FIRST replay of the modify, meets NOT_FOUND, is retried as an insert;
          boot 2, a NEW proxy process on the re-adopted (warm) switch: startup replays the modify again, the same way.
  TRIAL_ONLY_M2R=1 runs only these.

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


def one_m1(bmv2, label):
    """Steps 1-6 of the restart-in-the-middle sequence on a warm switch of its own. [Co-developed with claude code -- Adam]"""
    tag = "m1-" + label
    res = {"bmv2": bmv2, "label": tag, "boots": []}
    jdir = os.path.join(work, "journal-" + tag)
    if os.path.exists(jdir):
        shutil.rmtree(jdir)
    sw = a_switch(bmv2, tag, 1)
    try:
        # boot 1 = steps 1-2; boot 2 = step 3; boot 3 = step 4; boot 4 = step 5 (and the read of step 6)
        for n, plan in ((1, "m1a"), (2, "read"), (3, "m1b"), (4, "read")):
            b, sw = boot(tag, n, sw, jdir, plan)
            res["boots"].append(b)
    finally:
        res["stop"] = sw.stop()
        print("stopped %s pid %d rc %s" % (tag, sw.proc.pid, res["stop"]), flush=True)
    res["checks"] = judge_m1(res)
    return res


def judge_m1(res):
    b1, b2, b3, b4 = res["boots"]
    c = {}
    c["m1 steps 1-2: insert at 10 is a 200, delete at 20 is a 502"] = [p["status"] for p in b1["posts"]] == [200, 502]
    c["m1 step 2: the 502 is the switch's NOT_FOUND"] = (b1["posts"][1]["answer"].get("p4rt_error") or {}).get("code") == "NOT_FOUND"
    c["m1 step 2: both are recorded (ok, not_found)"] = [r["outcome"] for r in b1["journal_after"]["records"]] == ["ok", "not_found"]
    r2 = b2["switch_state_table_entries"]["journal"]["replay"]
    c["m1 step 3 restart: a new proxy process, cookie confirmed"] = (
        b2["pid"] != b1["pid"] and r2["fresh_fabric"] is False and r2["cookie"] == "confirmed")
    c["m1 step 3 replay complete 2/2: the insert at 10, and the delete at 20 (NOT_FOUND = done)"] = (
        (r2["status"], r2["attempted"], r2["succeeded"]) == ("complete", 2, 2)
        and [x["op"] for x in r2["restored"]] == ["insert", "delete"])
    c["m1 step 3 thrift: the entry at 10 is back"] = b2["after"]["dumps"]["HcIngress.t_ternary"]["ours"] == 1
    c["m1 step 4: the insert at 20 is a 200 and says journaled"] = (
        [p["status"] for p in b3["posts"]] == [200] and b3["posts"][0]["answer"].get("journaled") is True)
    c["m1 step 4 thrift: the entries at 10 and 20 are on the switch"] = b3["after"]["dumps"]["HcIngress.t_ternary"]["ours"] == 2
    r4 = b4["switch_state_table_entries"]["journal"]["replay"]
    c["m1 step 5 restart: a new proxy process, cookie confirmed"] = (
        b4["pid"] not in (b1["pid"], b2["pid"], b3["pid"]) and r4["fresh_fabric"] is False and r4["cookie"] == "confirmed")
    c["m1 step 5 replay complete 2/2, nothing failed, nothing retried"] = (
        (r4["status"], r4["attempted"], r4["succeeded"], r4["failed"]) == ("complete", 2, 2, [])
        and r4["retried_as_modify"] == [] and not r4.get("retried_as_insert"))
    c["m1 step 5 restored ops: two inserts (20 is an insert, not a modify)"] = [x["op"] for x in r4["restored"]] == ["insert", "insert"]
    c["m1 step 6 thrift: the entries at 10 and 20 are on the switch"] = b4["after"]["dumps"]["HcIngress.t_ternary"]["ours"] == 2
    c["m1 step 6 P4Runtime read: a ternary entry at priority 20 is on the switch, and the one at 10"] = (
        sorted(x["priority"] for x in b4["on_switch"] if x["table"] == "HcIngress.t_ternary") == [10, 20])
    c["m1 step 6 P4Runtime read: what is on the switch equals what it held after step 4"] = b4["on_switch"] == b3["on_switch"]
    c["m1 step 6 the journal holds the insert at 20, recorded ok"] = any(
        r["op"] == "insert" and r["outcome"] == "ok" and r["spec"].get("priority") == 20 for r in b4["journal_after"]["records"])
    c["m1 step 6 journaled true"] = b4["switch_state_table_entries"]["journaled"] is True
    c["m1 every boot exited 0"] = all(b["rc"] == 0 for b in res["boots"])
    return c


def one_m2(bmv2, label, variant):
    """The modify-that-finds-nothing sequence, `m2` or `m2b`, on a warm switch of its own. [Co-developed with claude code -- Adam]"""
    tag = variant + "-" + label
    res = {"bmv2": bmv2, "label": tag, "boots": []}
    jdir = os.path.join(work, "journal-" + tag)
    if os.path.exists(jdir):
        shutil.rmtree(jdir)
    sw = a_switch(bmv2, tag, 1)
    plans = ("m2", "read", "read") if variant == "m2" else ("m2a", "read", "m2c", "read", "read")
    try:
        for n, plan in enumerate(plans, 1):
            b, sw = boot(tag, n, sw, jdir, plan)
            res["boots"].append(b)
    finally:
        res["stop"] = sw.stop()
        print("stopped %s pid %d rc %s" % (tag, sw.proc.pid, res["stop"]), flush=True)
    res["checks"] = judge_m2(res, variant)
    return res


def ternary_s(b):
    """The (priority, v) of every ternary entry the P4Runtime read of boot `b` found."""
    return sorted((x["priority"], int(x["params"]["v"], 16)) for x in b["on_switch"] if x["table"] == "HcIngress.t_ternary")


def judge_m2(res, variant):
    boots = res["boots"]
    v = variant
    b1 = boots[0]
    # the journal after the first boot: [delete/ok K] (m2b) or [delete/ok K, insert/ok S] (m2) -- K's key is the first record's
    recs1 = b1["journal_after"]["records"]
    k = recs1[0]["key"] if recs1 else None
    c = {}
    if v == "m2":
        c["m2 steps 1-3: delete K is a 200 (it was there), insert S is a 200 and says journaled"] = (
            [p["status"] for p in b1["posts"]] == [200, 200] and b1["posts"][1]["answer"].get("journaled") is True)
        c["m2 steps 1-3: the journal holds [delete/ok, insert/ok] and nothing for the insert that went through the client"] = (
            [(r["op"], r["outcome"]) for r in recs1] == [("delete", "ok"), ("insert", "ok")] and recs1[0]["key"] == recs1[1]["key"])
        c["m2 step 3 thrift: S (v 6) is on the switch before any restart"] = (
            b1["after"]["dumps"]["HcIngress.t_ternary"]["ours"] == 1 and "set_mark - 06" in b1["after"]["dumps"]["HcIngress.t_ternary"]["raw"])
        restarts = ((2, "m2 step 4"), (3, "m2 step 5"))
    else:
        b2 = boots[1]
        c["m2b steps 1-2: delete K is a 200 (it was there)"] = [p["status"] for p in b1["posts"]] == [200]
        c["m2b steps 1-2: the journal holds [delete/ok] and nothing for the insert that went through the client"] = (
            [(r["op"], r["outcome"]) for r in recs1] == [("delete", "ok")])
        r2 = b2["switch_state_table_entries"]["journal"]["replay"]
        c["m2b restart after step 2: a new proxy process, cookie confirmed"] = (
            b2["pid"] != b1["pid"] and r2["fresh_fabric"] is False and r2["cookie"] == "confirmed")
        c["m2b restart after step 2: replay complete 1/1, the delete (NOT_FOUND = done), nothing retried"] = (
            (r2["status"], r2["attempted"], r2["succeeded"], r2["failed"]) == ("complete", 1, 1, [])
            and [x["op"] for x in r2["restored"]] == ["delete"] and not r2.get("retried_as_insert") and r2.get("retried_as_modify") == [])
        c["m2b restart after step 2: K is not on the switch (thrift and P4Runtime)"] = (
            b2["after"]["dumps"]["HcIngress.t_ternary"]["ours"] == 0 and ternary_s(b2) == [])
        b3 = boots[2]
        c["m2b step 3: insert S is a 200 and says journaled"] = (
            [p["status"] for p in b3["posts"]] == [200] and b3["posts"][0]["answer"].get("journaled") is True)
        c["m2b step 3: the journal holds [delete/ok, insert/ok]"] = (
            [(r["op"], r["outcome"]) for r in b3["journal_after"]["records"]] == [("delete", "ok"), ("insert", "ok")])
        restarts = ((4, "m2b step 4"), (5, "m2b step 5"))
    prev = boots[restarts[0][0] - 2]
    for n, name in restarts:
        b = boots[n - 1]
        r = b["switch_state_table_entries"]["journal"]["replay"]
        c["%s restart: a new proxy process, cookie confirmed" % name] = (
            b["pid"] != prev["pid"] and r["fresh_fabric"] is False and r["cookie"] == "confirmed")
        c["%s replay complete 1/1, nothing failed" % name] = (
            (r["status"], r["attempted"], r["succeeded"], r["failed"]) == ("complete", 1, 1, []))
        c["%s retried_as_insert == [K], retried_as_modify == []" % name] = (
            k is not None and r.get("retried_as_insert") == [k] and r.get("retried_as_modify") == [])
        c["%s restored op is the journal's modify" % name] = [x["op"] for x in r["restored"]] == ["modify"]
        c["%s thrift: S (v 6) is on the switch, once, and K's old action (v 5) is not" % name] = (
            b["after"]["dumps"]["HcIngress.t_ternary"]["ours"] == 1 and "set_mark - 06" in b["after"]["dumps"]["HcIngress.t_ternary"]["raw"]
            and "set_mark - 05" not in b["after"]["dumps"]["HcIngress.t_ternary"]["raw"])
        c["%s P4Runtime read: one ternary entry, priority 10, v 6" % name] = ternary_s(b) == [(10, 6)]
        live = [(r_["op"], r_["outcome"]) for r_ in b["journal_after"]["records"]]
        c["%s the live journal file ends as [modify/ok S]" % name] = (
            live == [("modify", "ok")] and b["journal_after"]["records"][0]["spec"]["action_params"] == {"v": 6}
            and b["journal_after"]["records"][0]["key"] == k)
        c["%s journaled true" % name] = b["switch_state_table_entries"]["journaled"] is True
        prev = b
    c["%s every boot exited 0" % v] = all(b["rc"] == 0 for b in boots)
    return c


def one_m2r(bmv2, label):
    """m2r: the m2 steps, then a bmv2 restart under the proxy and its readopt; then a new proxy process. [Co-developed with claude code -- Adam]"""
    tag = "m2r-" + label
    res = {"bmv2": bmv2, "label": tag, "boots": []}
    jdir = os.path.join(work, "journal-" + tag)
    if os.path.exists(jdir):
        shutil.rmtree(jdir)
    sw = a_switch(bmv2, tag, 1)
    switches = [sw]

    def restart_under_the_proxy(bwork, old):
        ready = os.path.join(bwork, "ready")
        for _ in range(1200):
            if os.path.exists(ready):
                break
            time.sleep(0.1)
        res["stop_1"] = old.stop()
        print("stopped %s #1 pid %d rc %s (under a running proxy)" % (tag, old.proc.pid, res["stop_1"]), flush=True)
        new = a_switch(bmv2, tag, 2)
        switches.append(new)
        with open(os.path.join(bwork, "restarted"), "w") as fh:
            fh.write(str(new.grpc_port))
        return new
    try:
        b, sw = boot(tag, 1, sw, jdir, "m2r", during=restart_under_the_proxy)
        res["boots"].append(b)
        b, sw = boot(tag, 2, sw, jdir, "read")
        res["boots"].append(b)
    finally:
        for w in switches:
            if w.alive():
                rc = w.stop()
                print("stopped %s pid %d rc %s" % (tag, w.proc.pid, rc), flush=True)
    res["checks"] = judge_m2r(res)
    return res


def judge_m2r(res):
    b1, b2 = res["boots"]
    c = {}
    pre = (b1.get("journal_before_readopt") or {}).get("records") or []
    k = pre[0]["key"] if pre else None
    c["m2r steps 1-3: delete K is a 200 (it was there), insert S is a 200 and says journaled"] = (
        [p["status"] for p in b1["posts"]] == [200, 200] and b1["posts"][1]["answer"].get("journaled") is True)
    c["m2r steps 1-3: before the readopt the journal holds [delete/ok K, insert/ok S]"] = (
        [(r["op"], r["outcome"]) for r in pre] == [("delete", "ok"), ("insert", "ok")] and pre[0]["key"] == pre[1]["key"])
    ro = b1.get("readopt") or {}
    c["m2r step 4: the readopt of the restarted bmv2 succeeded"] = ro.get("status") == "success"
    pw = b1.get("post_while_pending") or {}
    c["m2r step 4: a POST while the readopt is pending is 503 replay pending"] = (
        isinstance(pw, dict) and pw.get("status") == 503 and (pw.get("answer") or {}).get("error") == "replay pending")
    c["m2r step 4: the readopt's push carries this boot's generation"] = b1["cookie_after_readopt"] == b1["generation"]
    rr = (ro.get("table_entries") or {}).get("replay") or {}
    c["m2r step 4: the readopt replayed: when readopt, complete 1/1, nothing failed"] = (
        rr.get("when") == "readopt" and (rr.get("status"), rr.get("attempted"), rr.get("succeeded"), rr.get("failed"))
        == ("complete", 1, 1, []))
    c["m2r step 4: retried_as_insert == [K], retried_as_modify == []"] = (
        k is not None and rr.get("retried_as_insert") == [k] and rr.get("retried_as_modify") == [])
    c["m2r step 4: restored op is the journal's modify"] = [x["op"] for x in rr.get("restored") or []] == ["modify"]
    r1 = b1["switch_state_table_entries"]["journal"]["replay"]
    c["m2r step 4: switch_state serves the readopt's replay"] = (
        r1.get("when") == "readopt" and r1.get("status") == "complete" and r1.get("retried_as_insert") == [k])
    for b, name in ((b1, "m2r step 4 (after the readopt)"), (b2, "m2r restart (new process)")):
        t = b["after"]["dumps"]["HcIngress.t_ternary"]
        c["%s thrift: S (v 6) is on the switch, once, and K's old action (v 5) is not" % name] = (
            t["ours"] == 1 and "set_mark - 06" in t["raw"] and "set_mark - 05" not in t["raw"])
        c["%s P4Runtime read: one ternary entry, priority 10, v 6" % name] = ternary_s(b) == [(10, 6)]
        live = b["journal_after"]["records"]
        c["%s the live journal file ends as [modify/ok S]" % name] = (
            [(r_["op"], r_["outcome"]) for r_ in live] == [("modify", "ok")]
            and live[0]["spec"]["action_params"] == {"v": 6} and live[0]["key"] == k)
        c["%s journaled true" % name] = b["switch_state_table_entries"]["journaled"] is True
    r2 = b2["switch_state_table_entries"]["journal"]["replay"]
    c["m2r restart: a new proxy process, cookie confirmed (the readopt's push)"] = (
        b2["pid"] != b1["pid"] and r2["fresh_fabric"] is False and r2["cookie"] == "confirmed")
    c["m2r restart: replay complete 1/1, nothing failed, retried_as_insert == [K]"] = (
        (r2["status"], r2["attempted"], r2["succeeded"], r2["failed"]) == ("complete", 1, 1, [])
        and r2.get("retried_as_insert") == [k] and r2.get("retried_as_modify") == [])
    c["m2r every boot exited 0"] = all(b["rc"] == 0 for b in res["boots"])
    return c


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
# TRIAL_ONLY_M1=1 skips the six-boot series and the m2 sequences, for a run that wants only the restart-in-the-middle
# sequence; TRIAL_ONLY_M2=1 runs only the m2 and m2b sequences (the red runs at the code before each fix). The trial of
# record runs everything.
ONLY_M1, ONLY_M2 = os.environ.get("TRIAL_ONLY_M1"), os.environ.get("TRIAL_ONLY_M2")
ONLY_M2R = os.environ.get("TRIAL_ONLY_M2R")      # [Co-developed with claude code -- Adam]
BINARIES = (("/usr/local/bin/simple_switch_grpc", "stock"), (VT.fabric_binary(), "fast"))
for bmv2, label in BINARIES:
    if not ONLY_M1 and not ONLY_M2 and not ONLY_M2R:
        results.append(one(bmv2, label))
for bmv2, label in BINARIES:
    if not ONLY_M2 and not ONLY_M2R:
        results.append(one_m1(bmv2, label))
for bmv2, label in BINARIES:
    if not ONLY_M1 and not ONLY_M2R:
        results.append(one_m2(bmv2, label, "m2"))
        results.append(one_m2(bmv2, label, "m2b"))
for bmv2, label in BINARIES:
    if not ONLY_M1 and not ONLY_M2:
        results.append(one_m2r(bmv2, label))
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
