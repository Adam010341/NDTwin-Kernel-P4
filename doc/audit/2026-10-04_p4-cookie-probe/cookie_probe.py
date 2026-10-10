#!/usr/bin/env python3
# Paths: <repo> is the worktree root, <scratch> is the local scratch/overnight-2026-09-05 directory; ../ternary-a0/build-ndtwin below is <scratch>/logs/gates-0910/ternary-a0/build-ndtwin.
"""cookie-probe: what the proxy's own liveness code reports for a restarted, not-readopted bmv2.

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python cookie_probe.py <bmv2 binary> <worktree>

Uses the REAL P4RuntimeClient.probe(), TopologyManager's liveness poller, switch_liveness(),
connected_switch_dpids() and readopt_switch() from <worktree>, against one throwaway
simple_switch_grpc at a time (tools/p4_health/throwaway.py: no root, argv[0] ndt-hc-*, ports
outside the lab's, stopped by its exact pid). NDTwin's own pipeline (ndtwin_switch.json, compiled
from the worktree's p4_src at dd8022fa, ../ternary-a0/build-ndtwin/) is given on the bmv2 command
line, the way p4_testbed_topo starts fabric switches.

Phases:
  A  fresh switch, client started (stream + arbitration), no pipeline pushed
  B  pipeline pushed through the client
  C  bmv2 stopped by pid (power off)
  D  bmv2 restarted on the SAME ports and device id, old client kept (power on, no readopt)
  E  readopt_switch (install_routes=False: no graph here) then probe again
"""
import json
import os
import sys
import time

BMV2 = sys.argv[1]
WT = os.path.abspath(sys.argv[2])
sys.path.insert(0, os.path.join(WT, "p4_proxy"))
sys.path.insert(0, os.path.join(WT, "tools"))

from p4_health import throwaway as TW  # noqa: E402
from p4_health.collect.config import default_p4dev_python  # noqa: E402
from proxy_agent import topology_manager as tm_mod  # noqa: E402
from proxy_agent.p4_client import P4RuntimeClient  # noqa: E402
from proxy_agent.topology_manager import TopologyManager  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "..", "ternary-a0", "build-ndtwin")
JSON = os.path.abspath(os.path.join(BUILD, "ndtwin_switch.json"))
INFO = os.path.abspath(os.path.join(BUILD, "ndtwin_switch.p4info.txtpb"))
CLI = [default_p4dev_python(), "/usr/local/bin/simple_switch_CLI"]
CPU = 510
DPID = 1
TAG = "fast" if "bmv2-fast" in BMV2 else "stock"


def w(msg):
    print(msg, flush=True)


def launch(work, thrift=None, grpc_port=None):
    os.makedirs(work, exist_ok=True)
    if thrift is not None:
        TW.THRIFT_CANDIDATES = [thrift]
        TW.GRPC_CANDIDATES = [grpc_port]
    sw = TW.Throwaway(JSON, {1: [], 2: []}, CPU, CLI, wait_s=2, bmv2=BMV2, workdir=work,
                      argv0="ndt-hc-cookieprobe-bmv2", grpc=True)
    sw.start()
    w("bmv2 up: pid %d grpc 127.0.0.1:%d thrift %d device_id %d argv=%s"
      % (sw.proc.pid, sw.grpc_port, sw.thrift_port, TW.DEVICE_ID, " ".join(sw.argv)))
    return sw


def make_client(port):
    return P4RuntimeClient(device_id=TW.DEVICE_ID, grpc_addr="127.0.0.1:%d" % port,
                           p4info_path=INFO, json_path=JSON)


def one_poll(topo):
    """Run the real poller until it has completed one fresh probe of DPID, then stop it."""
    with topo._liveness_lock:
        topo._last_probe.pop(DPID, None)
    topo.start_liveness_polling()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        with topo._liveness_lock:
            if DPID in topo._last_probe:
                break
        time.sleep(0.05)
    topo.stop_liveness_polling()
    entry = topo.switch_liveness()["switches"][str(DPID)]
    keep = {k: entry[k] for k in ("probe_ok", "probe_detail", "probe_age_s", "stream_alive",
                                  "last_lldp_age_s", "table_generation", "pipeline_commits")}
    w("  switch_liveness[%d] = %s" % (DPID, json.dumps(keep, sort_keys=True)))
    w("  connected_switch_dpids() = %s" % topo.connected_switch_dpids())
    return entry


def main():
    work = os.path.join(HERE, "work-%s" % TAG)
    os.makedirs(work, exist_ok=True)
    w("# cookie-probe -- bmv2 %s -- %s" % (BMV2, time.strftime("%Y-%m-%d %H:%M:%S")))
    w("# worktree %s ; LIVENESS_PROBE_TIMEOUT_S=%s" % (WT, tm_mod.LIVENESS_PROBE_TIMEOUT_S))
    topo = TopologyManager()
    sw = launch(os.path.join(work, "first"))
    thrift, gport = sw.thrift_port, sw.grpc_port
    client = make_client(gport)
    sw2 = None
    new_clients = []
    try:
        w("################ A. client started (stream + arbitration), NO pipeline pushed")
        client.start(push_config=False)
        time.sleep(1.0)
        w("  mastership_confirmed=%s stream_alive=%s"
          % (getattr(client, "mastership_confirmed", None), client.stream_alive))
        w("  client.probe() -> %s" % client.probe())
        topo.switches[DPID] = client
        one_poll(topo)

        w("################ B. pipeline pushed through the client")
        client.set_forwarding_pipeline_config()
        w("  client.probe() -> %s" % client.probe())
        one_poll(topo)

        w("################ C. bmv2 stopped by pid (power off)")
        pid = sw.proc.pid
        rc = sw.stop()
        w("  pid %d stopped, exit status %s" % (pid, rc))
        time.sleep(0.5)
        w("  client.probe() -> %s" % client.probe(timeout_s=1.5))
        one_poll(topo)

        w("################ D. bmv2 restarted on the same ports + device id; OLD client kept")
        sw2 = launch(os.path.join(work, "second"), thrift, gport)
        results = []
        t0 = time.monotonic()
        while time.monotonic() - t0 < 20:
            r = client.probe(timeout_s=1.5)
            results.append((round(time.monotonic() - t0, 2), r))
            if not r["detail"].startswith(("UNAVAILABLE", "DEADLINE_EXCEEDED")):
                break
            time.sleep(0.5)
        for t, r in results:
            w("  t+%5.2fs old client.probe() -> %s" % (t, r))
        w("  old client stream_alive=%s" % client.stream_alive)
        e = one_poll(topo)
        w("  => probe_ok=%s with no fresh LLDP (last_lldp_age_s=%s)" % (e["probe_ok"],
                                                                        e["last_lldp_age_s"]))

        w("################ E. readopt_switch (install_routes=False), then probe")

        def factory(dpid):
            c = make_client(gport)
            new_clients.append(c)
            return c
        res = topo.readopt_switch(DPID, factory, sample_callback=None, settle_s=1.0,
                                  install_routes=False)
        w("  readopt_switch -> %s" % json.dumps(res, sort_keys=True))
        w("  topo.switches[%d] is the new client: %s" % (DPID, topo.switches[DPID] is not client))
        w("  new client.probe() -> %s" % topo.switches[DPID].probe())
        one_poll(topo)
    finally:
        topo.stop_liveness_polling()
        for c in [client] + new_clients:
            try:
                c.stop()
            except Exception as exc:  # noqa: BLE001
                w("  (client stop: %s: %s)" % (type(exc).__name__, exc))
        for s in (sw, sw2):
            if s is not None and s.alive():
                pid = s.proc.pid
                w("  stopping bmv2 pid %d -> exit %s" % (pid, s.stop()))
        w("# done; no throwaway left alive: %s"
          % all(s is None or not s.alive() for s in (sw, sw2)))


if __name__ == "__main__":
    main()
