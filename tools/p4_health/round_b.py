"""Bring-up B, minimal (Cut 2): run B's controller and confirm its eleven attributions.

[Co-developed with claude code -- Adam]

`BRound(...).body(lab_round)` is what probe.py hands LabRound.run for bring-up B (the external
package). In order:

  1. write the controller's instructions (controller_ext.py reads $P4H_CTRL_CONFIG);
  2. start it through tools/p4_exercise/run_external_controller.py <B package> controller_ext.py
     (design 4.2: the adapter rewrites tutorials' 127.0.0.1:5005<i> / device i-1 onto the
     fabric's 30050+i / device i), as the caller, under the p4dev interpreter (the one with
     p4runtime_lib's p4.tmp); record it in LAB_STATE.json, its marker the run directory (the
     round's package lies inside it, so the argv carries it);
  3. wait for its `ready` file (the writes are done), then send the markers it needs -- K2's
     direct-counter markers, D1's digest markers and P2's packet-in markers, h4 -> h6 -- with a
     sniffer on h4 for the packet-out;
  4. touch `go`; the controller reads the direct counter, sends the packet-out and writes its
     result; wait for it to exit (the teardown stops it if it does not);
  5. confirm each attribution from thrift on s2 and the sniffer (attribution.confirm).

B's own cells (PL2, K3, P4, TP4, CP2) are Cut 4's and are not observed here.
"""
from __future__ import annotations

import json
import os
import time

from . import attribution as AT
from . import controller_ext as CX
from .collect import proxy as P
from .collect import sniff as S
from .collect import thrift as TH
from .collect.hosts import Hosts

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ADAPTER = os.path.join(REPO, "tools", "p4_exercise", "run_external_controller.py")
CONTROLLER = os.path.join(HERE, "controller_ext.py")
SRC, DST, ATTR_DPID = "h4", "h6", 2
D1_SPORT = 40041
P3_DPORT = CX.PACKET_OUT_DPORT


def adapter_argv(python, package_dir, tutorials_utils, adapter=ADAPTER, controller=CONTROLLER):
    """How bring-up B starts its controller; S0 runs the same argv with --dry-run. A lab run hands
    the copies it froze (frozen.py); the defaults are the shared tree's own."""
    return [python, adapter, package_dir, controller, "--tutorials-utils", tutorials_utils]


class BRound(object):
    def __init__(self, cfg, runner, run_id, model, build_dir, runtimes, tutorials_utils,
                 out_dir=None, hosts=None, sleep=time.sleep, clock=time.monotonic,
                 ready_timeout_s=120.0, exit_timeout_s=120.0, hostside=None, controller=None, adapter=None):
        self.cfg, self.runner, self.run_id, self.model = cfg, runner, run_id, model
        self.build_dir, self.runtimes = build_dir, runtimes
        self.tutorials_utils = tutorials_utils
        self.out_dir = out_dir or os.path.join(cfg.run_dir, "B")
        self.hosts = hosts
        self.sleep, self.clock = sleep, clock
        self.ready_timeout_s, self.exit_timeout_s = ready_timeout_s, exit_timeout_s
        self.hostside = hostside            # the frozen copy root runs (lab.run_lab), or None
        self.controller = controller or CONTROLLER      # (round 4, F4b) the frozen copies B runs, or the tree's
        self.adapter = adapter or ADAPTER
        self.confirmed = None
        self.problems = []
        #: (Cut 2 review N2) why B's controller did not do its part, or None: the run is then
        #: INCOMPLETE, not COMPLETE with every bmv2 attribution quietly missing
        self.failed = None

    def path(self, name):
        return os.path.join(self.out_dir, name)

    def config(self):
        return {"out": self.path("controller.result.json"), "ready": self.path("controller.ready.json"),
                "go": self.path("controller.go"), "build": self.build_dir,
                "programs": {str(d): self.model.program(d) for d in (1, 2, 3, 4)},
                "runtimes": {str(d): self.runtimes[d] for d in (1, 2, 3, 4)},
                "attr_dpid": ATTR_DPID, "token": self.hosts.token, "go_timeout_s": 120,
                "packet_out": {"port": self.model.HOST_PORT[4], "dst_mac": self.hosts.mac(SRC),
                               "src_mac": "08:00:00:00:ff:02", "src_ip": self.hosts.ip(DST),
                               "dst_ip": self.hosts.ip(SRC), "count": 5},
                "tutorials_utils": self.tutorials_utils}

    def _wait_file(self, path, proc, timeout):
        deadline = self.clock() + timeout
        while not os.path.exists(path):
            if proc.poll() is not None or self.clock() >= deadline:
                return os.path.exists(path)
            self.sleep(0.2)
        return True

    def _load(self, path):
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return None

    def body(self, lab_round):
        os.makedirs(self.out_dir, exist_ok=True)
        if self.hosts is None:
            self.hosts = Hosts(self.cfg, self.runner, self.run_id, self.out_dir, self.model,
                               register=lab_round.register,
                               **({"hostside": self.hostside} if self.hostside else {}))
        # (Cut 2 review MAJOR-3) the adapter checks the package FILE; the fabric that is up must
        # itself say external, or this controller would be a second writer on NDTwin's tables
        mode = (((P.switch_state(self.cfg) or {}).get("control_plane")) or {}).get("mode")
        if mode != "external":
            self.problems.append("the fabric's control_plane.mode is %r, not external: B's controller "
                                 "not started" % (mode,))
            self.failed = self.problems[-1]
            return self.finish(None, None)
        conf_path = self.path("controller.conf.json")
        with open(conf_path, "w", encoding="utf-8") as fh:
            json.dump(self.config(), fh, indent=2, sort_keys=True)
        argv = adapter_argv(self.cfg.p4dev_python, lab_round.package_dir, self.tutorials_utils,
                            adapter=self.adapter, controller=self.controller)
        proc = self.runner.spawn(argv, self.path("controller.log"), env={"P4H_CTRL_CONFIG": conf_path})
        if proc is None:
            self.problems.append("B's controller could not be started")
            self.failed = self.problems[-1]
            return self.finish(None, None)
        try:
            # the marker is the run directory, RESOLVED: the package path in the argv lies inside it
            # and LabRound hands that path out with its links followed (round 4, F6)
            lab_round.register("controller", proc.pid, os.path.realpath(self.cfg.run_dir))
        except ValueError as exc:
            self.problems.append("controller not recorded: %s" % exc)
        if not self._wait_file(self.path("controller.ready.json"), proc, self.ready_timeout_s):
            self.problems.append("B's controller never wrote its ready file (rc %s)" % proc.poll())
            self.failed = self.problems[-1]
            return self.finish(None, None)
        sent = {}

        def stimulate():
            outs = [self.hosts.send(SRC, DST, "K2", 40012, 200),
                    self.hosts.send(SRC, DST, "D1", 40041, 5, sport=D1_SPORT),
                    self.hosts.send(SRC, DST, "P2", 40050, 5)]
            for cell, out in zip(("K2", "D1", "P2"), outs):
                sent[cell] = S.sent(out, cell)
            open(self.path("controller.go"), "w").close()
            if not self._wait_file(self.path("controller.result.json"), proc, self.exit_timeout_s):
                self.problems.append("B's controller wrote no result")
                self.failed = self.problems[-1]
            return ""
        _out, rx = self.hosts.window([(SRC, ["P3"], P3_DPORT)], stimulate, seconds=180.0, until=5)
        if not sent:
            # (round 4, F2) hosts.window runs stimulate() only when every sniffer listens: without
            # it nothing was sent and `go` was never written, so the controller waits for nothing
            self.problems.append("B's sniffer on %s never listened: no marker was sent and the "
                                 "controller was never told to go" % SRC)
            self.failed = self.failed or self.problems[-1]
        if proc.poll() is None:
            try:
                proc.wait(timeout=30)
            except Exception:  # noqa: BLE001 -- left for the teardown, which stops it by pid
                self.problems.append("B's controller did not exit")
        p3 = None if rx.get(SRC) is None else len(S.received(rx[SRC], "P3"))
        return self.finish(self._load(self.path("controller.result.json")), p3, sent)

    @staticmethod
    def did_nothing(result, confirmed):
        """(round 5, #4) Why a controller that wrote a result still did not do its part, as a list of
        sentences ([] when it did). A result file says nothing of the sort by itself: the controller writes
        it whether or not it connected or became primary (controller_ext.py:330-359), and an unconfirmed
        item only counts as False (attribution.py:187-190). Two things are not a B that ran:

          * nothing but the expected `register` (bmv2 refuses RegisterEntry writes) is confirmed;
          * s2, where the attributions are made, is not primary. The record `connect()` writes
            (controller_ext.py:148-157) carries `primary`; a switch that never answered carries only
            `connect_error` (:338-339) and is named in the first sentence.
        """
        out = []
        switches = (result or {}).get("switches") or {}
        if not [k for k, v in (confirmed or {}).items() if v.get("ok") and k != "register"]:
            errors = ["s%s connect_error: %s" % (d, rec["connect_error"])
                      for d, rec in sorted(switches.items()) if rec.get("connect_error")]
            out.append("B's controller confirmed nothing but register%s" % (
                " (%s)" % "; ".join(errors) if errors else ""))
        s2 = switches.get(str(ATTR_DPID)) or {}
        if s2 and "connect_error" not in s2 and s2.get("primary") is not True:
            out.append("B's controller is not primary on s%d (arbitration status %s, pipeline set: %s)"
                       % (ATTR_DPID, s2.get("arbitration_status"), s2.get("set_pipeline_ok")))
        return out

    def finish(self, result, p3, sent=None):
        reader = TH.ThriftReader(self.cfg, self.runner)
        expect = {"digest": [AT.ip_int(self.model.host_ip(4)), D1_SPORT, 40041],
                  "packet_in_port": self.model.HOST_PORT[4], "packet_in_cell": "P2",
                  "token": self.hosts.token if self.hosts else None}
        self.confirmed = AT.confirm(result, lambda cmd: reader.read(ATTR_DPID, cmd), p3, expect)
        if result is None:
            self.problems.append("no controller result: every attribution is unconfirmed")
            # (round 4, F2) whatever the way here -- the exits above, a sniffer that never listened,
            # a result file that cannot be read -- a B without a result is a failed B
            self.failed = self.failed or self.problems[-1]
        else:
            for why in self.did_nothing(result, self.confirmed):
                self.problems.append(why)
                self.failed = self.failed or why
        doc = {"confirmed": self.confirmed, "sent": sent or {}, "p3_received": p3,
               "controller": result, "problems": self.problems + (self.hosts.problems if self.hosts else [])}
        with open(self.path("attributions.json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True, default=sorted)
            fh.write("\n")
        return self.confirmed
