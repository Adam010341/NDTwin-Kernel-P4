"""One proxy process for the Cut C trial: the real `main.startup`, then the real route handlers.

[Co-developed with claude code -- Adam]

usage: <proxy venv python> trial_boot.py <checkout> <package dir> <grpc port> <journal dir> <work dir> <plan> <out.json>

A new process per "proxy boot", so each has its own boot_identity.BOOT_ID, as a real restart does. It:
  1. points the table-entry journal at <journal dir> (NDTWIN_TABLE_JOURNAL_DIR, the production override) and the
     routing journal into <work dir>, makes the converted package the one `profile` serves, then imports main;
  2. builds the switch's client with `main.build_p4_client` (the production construction: the package's p4info,
     election id and route binding) for dpid 2 on <grpc port>, and starts it (arbitration stream, no push);
  3. runs `main.startup` with that client, a real TopologyManager with no kernel notifier, a kernel that
     acknowledges every switch, and an sFlow sink (the package's telemetry is `link`, so neither is used);
  4. answers the plan's POSTs with the real `api_routes.table_entry`, and reads `GET /p4/switch_state` with the
     real handler; T8 is observed with tools/p4_health observe_a.observe_t8 and judged by the real cells;
  5. stops its liveness poller and its client, and writes everything it saw to <out.json>.
Kills nothing: the switch belongs to the parent, which started it.
"""
import asyncio
import json
import os
import sys
import threading
import time
import types

checkout, pkg_dir, grpc_port, jdir, work, plan, out_path = sys.argv[1:8]
grpc_port = int(grpc_port)
os.environ["NDTWIN_TABLE_JOURNAL_DIR"] = jdir
os.environ["NDTWIN_RULE_JOURNAL_PATH"] = os.path.join(work, "rule_journal.jsonl")
sys.path.insert(0, os.path.join(checkout, "p4_proxy"))
sys.path.insert(0, os.path.join(checkout, "tools"))

from proxy_agent import profile                  # noqa: E402
import app_package                               # noqa: E402

package = app_package.load(pkg_dir)
profile._CURRENT = package                       # what a proxy started on this package serves

import proxy_agent.main as main                  # noqa: E402
from proxy_agent import api_routes, boot_identity  # noqa: E402
from proxy_agent.topology_manager import TopologyManager  # noqa: E402
from p4_health import observe_a as OA            # noqa: E402
from p4_health.cells import table as T           # noqa: E402
from p4_health.cells import verdict as V         # noqa: E402

DPID = 2
result = {"pid": os.getpid(), "boot_id": boot_identity.BOOT_ID, "plan": plan, "journal_dir": jdir,
          "journal_dir_main_built": main.table_journals.directory}
assert main.table_journals.directory == jdir, main.table_journals.directory


class Kernel(object):
    def switch_entered(self, dpid):
        return True


class Sflow(object):
    def register_switch(self, dpid, agent_ip):
        pass

    def handle_sample(self, *a, **kw):
        pass

    def close(self):
        pass


class Reply(object):
    def __init__(self, status, body):
        self.status, self.body = status, body


def a_request(body):
    from starlette.requests import Request
    payload = json.dumps(body).encode()

    async def receive():
        return {"type": "http.request", "body": payload, "more_body": False}
    return Request({"type": "http", "http_version": "1.1", "method": "POST", "path": "/p4/table_entry",
                    "raw_path": b"/p4/table_entry", "root_path": "", "scheme": "http", "query_string": b"",
                    "headers": [(b"content-type", b"application/json")], "client": ("127.0.0.1", 0),
                    "server": ("127.0.0.1", 8081)}, receive)


def post(body):
    from fastapi import HTTPException
    try:
        return {"body": body, "status": 200, "answer": asyncio.run(api_routes.table_entry(a_request(body)))}
    except HTTPException as exc:
        return {"body": body, "status": exc.status_code, "answer": exc.detail}


class Proxy(object):
    """cfg.proxy for the observer: GET /p4/switch_state is the real handler."""
    def get(self, path):
        assert path == "/p4/switch_state", path
        return Reply(200, asyncio.run(api_routes.switch_state()))


ACTION = {"action_name": "HcIngress.set_mark", "action_params": {"v": 5}}
EXACT = {"dpid": DPID, "table": "HcIngress.port_exact", "match": {"standard_metadata.ingress_port": 7},
         "action_name": "HcIngress.set_port_tag", "action_params": {"tag": 77}}
LPM = {"dpid": DPID, "table": "HcIngress.ipv4_lpm", "match": {"hdr.ipv4.dstAddr": ["10.0.77.0", 24]},
       "action_name": "HcIngress.ipv4_forward", "action_params": {"dstAddr": "08:00:00:00:07:77", "port": 2}}
TERN10 = dict({"dpid": DPID, "table": "HcIngress.t_ternary", "priority": 10,
               "match": {"hdr.ipv4.srcAddr": ["10.0.77.1", "255.255.255.255"]}}, **ACTION)
TERN20 = dict(TERN10, priority=20)

client = main.build_p4_client(DPID, port_base=grpc_port - DPID, package=package)
client.start(push_config=False)
topo = TopologyManager()
api_routes.inject_topology(topo)
summary = asyncio.run(main.startup(lambda: {DPID: client}, Sflow(), Kernel(), topo, agent_ips_loader=lambda: {}))
result["startup"] = {"broken": summary["broken"], "table_entries": summary["table_entries"].get(str(DPID)),
                     "entry_errors": summary.get("entry_errors")}
result["generation"] = main._generation["cookie"]
result["posts"] = []


def on_switch(c):
    """Every non-default entry the switch holds, read back through P4Runtime, bytes as hex."""
    out = []
    for e in c.read_table_entries():
        if e.get("is_default"):
            continue
        m = {k: {kk: (vv.hex() if isinstance(vv, bytes) else vv) for kk, vv in v.items()}
             for k, v in (e.get("match") or {}).items()}
        a = e.get("action") or {}
        out.append({"table": e["table"], "priority": e.get("priority"), "match": m,
                    "action": a.get("name"),
                    "params": {k: (v.hex() if isinstance(v, bytes) else v) for k, v in (a.get("params") or {}).items()}})
    return sorted(out, key=lambda x: json.dumps(x, sort_keys=True))


with open(main.package_entries_path(package, DPID)) as fh:
    BOOTS = [e for e in json.load(fh)["table_entries"]
             if e["table"] == "HcIngress.ipv4_lpm" and not e.get("default_action")]
#: two package boot entries: B (deleted with a lost answer) and B2 (deleted with a lost answer, then inserted as S)
B, B2 = (dict(BOOTS[0], dpid=DPID), dict(BOOTS[1], dpid=DPID))
S = dict(B2, action_params=dict(B2["action_params"], port=int(B2["action_params"]["port"]) % 3 + 1))
result["boot_entries_used"] = {"B": B, "B2": B2, "S": S}
if plan == "write":
    # exact, lpm, ternary at 10; then M1's sequence: a delete at 20 the switch answers NOT_FOUND, an insert at 20.
    for body in (EXACT, LPM, TERN10, dict(TERN20, op="delete"), TERN20):
        result["posts"].append(post(body))
elif plan == "m1a":
    # Steps 1 and 2 of the restart-in-the-middle sequence: an insert at priority 10, then a delete at priority 20,
    # which the switch answers NOT_FOUND (nothing is there to delete). [Co-developed with claude code -- Adam]
    for body in (TERN10, dict(TERN20, op="delete")):
        result["posts"].append(post(body))
elif plan == "m1b":
    # Step 4: the insert at priority 20, made after a proxy restart that replayed the NOT_FOUND delete.
    result["posts"].append(post(TERN20))
elif plan == "lostanswer":
    # The DELETE lands but its answer is lost: written straight through the client, so nothing records it. The
    # retry through the route meets NOT_FOUND and is recorded not_found. B ends there; B2 is then inserted as S.
    spec = lambda e: {k: v for k, v in e.items() if k != "dpid"}   # noqa: E731
    for e in (B, B2):
        client.write_table_entry(spec(e), "delete")
        result["posts"].append(post(dict(e, op="delete")))
    result["posts"].append(post(S))
elif plan == "readopt":
    # The bmv2 process under this proxy is restarted by the parent; then the real readopt entry point re-adopts it.
    with open(os.path.join(work, "ready"), "w") as fh:
        fh.write("ready")
    restarted = os.path.join(work, "restarted")
    for _ in range(600):
        if os.path.exists(restarted):
            break
        time.sleep(0.1)
    new_port = int(open(restarted).read().strip())
    during = {}

    def post_while_pending():
        for _ in range(400):
            if main.table_journals.pending(DPID):
                during["answer"] = post(dict(EXACT, match={"standard_metadata.ingress_port": 8}))
                return
            time.sleep(0.01)
        during["answer"] = "pending never seen"
    t = threading.Thread(target=post_while_pending, daemon=True)
    t.start()
    factory = lambda d: main.build_p4_client(d, port_base=new_port - DPID, package=package)  # noqa: E731
    readopt = main.readopt_switch(topo, DPID, factory, None, package=package)
    t.join(5)
    result["readopt"] = readopt
    result["post_while_pending"] = during.get("answer")
    client = topo.switches[DPID]
    result["cookie_after_readopt"] = client.read_pipeline_cookie()
state = asyncio.run(api_routes.switch_state())
result["switch_state_table_entries"] = state["switches"][str(DPID)].get("table_entries")
result["on_switch"] = on_switch(client)
obs = OA.observe_t8(types.SimpleNamespace(proxy=Proxy()))
result["t8_observation"] = obs
result["t8"] = V.judge_all(T.TABLE, {"T8": obs}, {}).cells["T8"].as_dict()
journal = main.table_journals.journal_for(DPID)
header, records, unreadable = journal.read()
result["journal_after"] = {"header": header, "records": records, "unreadable": unreadable,
                           "files": sorted(os.listdir(jdir))}
try:
    topo.stop_liveness_polling()
except Exception as exc:  # noqa: BLE001
    result["stop_liveness_error"] = repr(exc)
try:
    client.stop()
except Exception as exc:  # noqa: BLE001
    result["client_stop_error"] = repr(exc)
with open(out_path, "w") as fh:
    json.dump(result, fh, indent=2, sort_keys=True, default=repr)
print("boot %s pid %d BOOT_ID %s: t8 %s" % (plan, os.getpid(), boot_identity.BOOT_ID, result["t8"]["verdict"]),
      flush=True)
