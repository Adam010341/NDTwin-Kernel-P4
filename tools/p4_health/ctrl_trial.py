#!/usr/bin/env python3
"""B's controller against a throwaway simple_switch_grpc: the eleven attributions, offline. (Cut 2)

[Co-developed with claude code -- Adam]

S0 runs this so the first live bring-up B does not meet an untried controller. Under
throwaway.py's rules (pcap mode, no root, argv[0] `ndt-hc-ctrltrial-bmv2`, Thrift 29500-29599,
gRPC 29650-29699, stopped by pid): controller_ext.py connects, becomes primary, pushes hc_main,
writes s2's routes and the attributions; the switch's input pcap carries the D1, P2 and K2
markers; after they are processed the controller reads the direct counter and sends the
packet-out; then the SAME attribution.confirm the live round uses reads the throwaway over thrift
and the port-1 output pcap.

    p4_proxy/venv/bin/python tools/p4_health/ctrl_trial.py <build dir> <out.json> [bmv2]
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import time

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from p4_health import attribution as AT  # noqa: E402
from p4_health import frames as F  # noqa: E402
from p4_health import throwaway as TW  # noqa: E402
from p4_health.collect import thrift as TH  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "ctltrial"


def gen():
    spec = importlib.util.spec_from_file_location("hc_gen", os.path.join(HERE, "exercise", "gen_runtime.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def trial(build, bmv2, cli_argv, work, ctrl_python, tutorials_utils, wait_s=15):
    g = gen()
    os.makedirs(work, exist_ok=True)
    h4m, h4ip, h6ip, gw = g.host_mac(4), g.host_ip(4), g.host_ip(6), "08:00:00:00:04:00"
    inputs = {1: [], 2: [], 3: []}
    for i in range(3):
        inputs[1].append(F.udp_marker(h4m, gw, h4ip, h6ip, 40041, run_id=TOKEN, cell="D1", seq=i, sport=40041))
        inputs[1].append(F.udp_marker(h4m, gw, h4ip, h6ip, 40050, run_id=TOKEN, cell="P2", seq=i))
    for i in range(5):
        inputs[1].append(F.udp_marker(h4m, gw, h4ip, h6ip, 40012, run_id=TOKEN, cell="K2", seq=i))
    sw = TW.Throwaway(os.path.join(build, "hc_main.json"), inputs, g.CPU_PORT, cli_argv, wait_s=wait_s,
                      bmv2=bmv2, workdir=os.path.join(work, "switch"), argv0="ndt-hc-ctrltrial-bmv2",
                      grpc=True)
    os.makedirs(sw.workdir, exist_ok=True)
    paths = {k: os.path.join(work, k) for k in ("ready.json", "result.json", "go", "conf.json", "ctl.out")}
    for k in ("ready.json", "result.json", "go"):
        if os.path.exists(paths[k]):
            os.remove(paths[k])
    out = {"bmv2": bmv2}
    sw.start()
    ctl = None
    try:
        conf = {"out": paths["result.json"], "ready": paths["ready.json"], "go": paths["go"],
                "build": build, "programs": {"2": "hc_main"}, "runtimes": {"2": g.runtime(2)},
                "attr_dpid": 2, "token": TOKEN, "go_timeout_s": 60,
                "packet_out": {"port": 1, "dst_mac": h4m, "src_mac": "08:00:00:00:ff:02",
                               "src_ip": h6ip, "dst_ip": h4ip, "count": 3},
                "connect": {"2": ["127.0.0.1:%d" % sw.grpc_port, TW.DEVICE_ID]},
                "tutorials_utils": tutorials_utils}
        with open(paths["conf.json"], "w") as fh:
            json.dump(conf, fh)
        env = dict(os.environ, P4H_CTRL_CONFIG=paths["conf.json"])
        with open(paths["ctl.out"], "w") as log:
            ctl = subprocess.Popen([ctrl_python, os.path.join(HERE, "controller_ext.py")], env=env,
                                   stdout=log, stderr=subprocess.STDOUT)
        t0 = time.monotonic()
        while not os.path.exists(paths["ready.json"]) and ctl.poll() is None and time.monotonic() - t0 < 60:
            time.sleep(0.2)
        out["ready_before_input_s"] = round(sw.started_at + wait_s - time.monotonic(), 1)
        sw.wait_processed(settle_s=3)
        open(paths["go"], "w").close()
        ctl.wait(timeout=90)
        out["controller_rc"] = ctl.returncode

        def read(cmd):
            return TH.PARSERS[cmd.split()[0]](TH.body(sw.cli([cmd])))
        try:
            with open(paths["result.json"]) as fh:
                result = json.load(fh)
        except (OSError, ValueError):
            result = None
        outs = sw.outputs()
        p3 = sum(1 for f in (outs.get(1) or []) if (F.parse(f).get("marker") or (0, ""))[1] == "P3")
        expect = {"digest": [AT.ip_int(h4ip), 40041, 40041], "packet_in_port": 1,
                  "packet_in_cell": "P2", "token": TOKEN}
        out["confirmed"] = AT.confirm(result, read, p3, expect)
        out["controller"] = result
        out["alive"] = sw.alive()
    finally:
        if ctl is not None and ctl.poll() is None:
            ctl.kill()
            ctl.wait(timeout=5)
        out["stop_rc"] = sw.stop()
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    build, path = argv[0], argv[1]
    bmv2 = argv[2] if len(argv) > 2 else "/usr/local/bin/simple_switch_grpc"
    from p4_health.collect.config import default_p4dev_python
    py = default_p4dev_python()
    res = trial(build, bmv2, [py, "/usr/local/bin/simple_switch_CLI"],
                os.path.join(os.path.dirname(os.path.abspath(path)), "ctrl_trial_work"), py,
                os.path.join(os.path.expanduser("~"), "tutorials", "utils"))
    with open(path, "w") as fh:
        json.dump(res, fh, indent=2, sort_keys=True, default=sorted)
    print(json.dumps({k: v["ok"] for k, v in res["confirmed"].items()}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
