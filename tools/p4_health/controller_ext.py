#!/usr/bin/env python3
"""Bring-up B's controller: push the pipeline, write the routes, and the eleven attributions.

[Co-developed with claude code -- Adam]

design 4.2: a tutorials-shaped controller (`p4runtime_lib`, Bmv2SwitchConnection to
127.0.0.1:5005<i> with device id i-1) that tools/p4_exercise/run_external_controller.py rewrites
onto the fabric's ports (30050+i, device id i). It pushes each switch's pipeline, writes the
package's routes, and then does on switch `attr_dpid` (s2) the eleven things NDTwin's A half
could not -- each ONLY a P4Runtime call here; whether it took effect is decided by the probe from
thrift or from a receiving host (attribution.py), never from this process's own word:

   1 ternary   2 range   3 optional   4 priority (two overlapping ternary entries)
   5 MeterEntry   6 DirectMeterEntry   7 DigestEntry, then a DigestList received
   8 CloneSessionEntry   9 RegisterEntry write   10 DirectCounterEntry read
   11 packet-in received, packet-out sent

run_external_controller.py runs this file with no arguments, so its instructions come from the
JSON file $P4H_CTRL_CONFIG names (written by round_b.py):

   {"out": <result json>, "ready": <file written after the writes>, "go": <file the probe
    touches after its stimuli>, "build": <dir with hc_main/hc_alt .json and .p4info.txtpb>,
    "programs": {"1": "hc_alt", ...}, "runtimes": {"1": <runtime doc>, ...}, "attr_dpid": 2,
    "token": <the run's 8-char marker token>, "packet_out": {"port": 1, "dst_mac": .., ...},
    "connect": {"<dpid>": ["<address>", <device id>]} (optional: a throwaway switch),
    "tutorials_utils": <dir> (optional, when not run through the adapter), "go_timeout_s": 90}

It never writes anywhere but the switches it was told about, and it exits when done.
"""
from __future__ import annotations

import json
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
if os.path.dirname(HERE) not in sys.path:
    sys.path.insert(0, os.path.dirname(HERE))

TUTORIALS_PORT_BASE = 50050
ELECTION_LOW = 1          # what p4runtime_lib's own requests carry (switch.py)

#: The attributions' objects: none of them collides with what bring-up A wrote, and each is
#: what attribution.py looks for in thrift.
TERNARY = {"table": "HcIngress.t_ternary", "field": "hdr.ipv4.srcAddr",
           "value": "10.0.4.0", "mask": "255.255.255.0", "priority": 10, "mark": 41}
RANGE = {"table": "HcIngress.t_range", "field": "hdr.udp.dstPort", "low": 40100, "high": 40110,
         "priority": 10, "mark": 51}
OPTIONAL = {"table": "HcIngress.t_optional", "field": "hdr.ipv4.protocol", "value": 17,
            "priority": 10, "mark": 61}
PRIORITY = ({"value": "10.0.6.6", "mask": "255.255.255.255", "priority": 30, "mark": 71},
            {"value": "10.0.6.0", "mask": "255.255.255.0", "priority": 20, "mark": 72})
#: bytes per second and bytes; thrift prints the rate per microsecond (0.125) and the burst
METER = {"cir": 125000, "cburst": 12500, "pir": 125000, "pburst": 12500}
METER_INDEX = 0
DIRECT_METER_DPORT = 40023
DIRECT_COUNTER_DPORT = 40012
CLONE = {"session": 9, "port": 1}
REGISTER = {"name": "HcIngress.r_mark", "index": 1, "value": 0xBEEF}


def load_config():
    path = os.environ.get("P4H_CTRL_CONFIG")
    if not path:
        raise SystemExit("controller_ext: P4H_CTRL_CONFIG is not set")
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def encode(value, bitwidth):
    nbytes = (bitwidth + 7) // 8
    if isinstance(value, str):
        if value.count(".") == 3:
            value = int.from_bytes(bytes(int(x) for x in value.split(".")), "big")
        elif value.count(":") == 5:
            value = int(value.replace(":", ""), 16)
        else:
            value = int(value, 0)
    return int(value).to_bytes(nbytes, "big")


class Controller(object):
    def __init__(self, conf):
        self.conf = conf
        self.result = {"switches": {}, "attributions": {}, "digests": [], "packet_ins": [],
                       "errors": []}
        if conf.get("tutorials_utils"):
            sys.path.insert(0, conf["tutorials_utils"])
        import p4runtime_lib.bmv2 as bmv2      # noqa: E402 -- the path is set first
        import p4runtime_lib.helper as helper  # noqa: E402
        import p4runtime_lib.switch as switch  # noqa: E402
        from p4.v1 import p4runtime_pb2        # noqa: E402
        self.bmv2, self.helper_mod, self.pb = bmv2, helper, p4runtime_pb2
        self._patch_dispatcher(switch)
        self.conns, self.helpers = {}, {}

    # p4runtime_lib's dispatcher prints a DigestList as "Unknown StreamMessageResponse" and
    # drops it; this keeps it (and keeps every other message type where the library put it).
    @staticmethod
    def _patch_dispatcher(switch):
        def loop(self):
            self.digest_queue = getattr(self, "digest_queue", None) or __import__("queue").Queue()
            for msg in self.stream:
                if not self.running:
                    break
                if msg.HasField("arbitration"):
                    self.arbitration_queue.put(msg.arbitration)
                elif msg.HasField("packet"):
                    self.packet_in_queue.put(msg.packet)
                elif msg.HasField("digest"):
                    self.digest_queue.put(msg.digest)
                elif msg.HasField("idle_timeout_notification"):
                    self.timeout_queue.put(msg.idle_timeout_notification)
                elif msg.HasField("error"):
                    self.error_queue.put(msg.error)
        switch.StreamDispatcher._dispatch_loop = loop

    def step(self, name, fn):
        try:
            detail = fn()
            self.result["attributions"][name] = {"ok": True, "detail": detail}
        except Exception as exc:  # noqa: BLE001 -- every attribution is reported, none stops the rest
            self.result["attributions"][name] = {"ok": False, "error": _rpc_error(exc)}

    # --- connections -----------------------------------------------------------------------------
    def connect(self, dpid):
        explicit = (self.conf.get("connect") or {}).get(str(dpid))
        if explicit:
            address, device_id = explicit[0], int(explicit[1])
        else:
            address, device_id = "127.0.0.1:%d" % (TUTORIALS_PORT_BASE + dpid), dpid - 1
        sw = self.bmv2.Bmv2SwitchConnection(name="s%d" % dpid, address=address, device_id=device_id)
        self.conns[dpid] = sw
        stem = self.conf["programs"][str(dpid)]
        info = os.path.join(self.conf["build"], stem + ".p4.p4info.txtpb")
        self.helpers[dpid] = self.helper_mod.P4InfoHelper(info)
        rec = {"address": address, "device_id": device_id, "program": stem}
        req = self.pb.StreamMessageRequest()
        req.arbitration.device_id = sw.device_id
        req.arbitration.election_id.high = 0
        req.arbitration.election_id.low = ELECTION_LOW
        sw.requests_stream.put(req)
        reply = sw.dispatcher.arbitration_queue.get(timeout=20)
        rec["primary"] = reply.status.code == 0
        rec["arbitration_status"] = reply.status.code
        try:
            sw.SetForwardingPipelineConfig(p4info=self.helpers[dpid].p4info,
                                           bmv2_json_file_path=os.path.join(self.conf["build"], stem + ".json"))
            rec["set_pipeline_ok"] = True
        except Exception as exc:  # noqa: BLE001
            rec["set_pipeline_ok"] = False
            rec["set_pipeline_error"] = _rpc_error(exc)
        self.result["switches"][str(dpid)] = rec
        return sw

    def write(self, dpid, entity_setter, update_type="INSERT"):
        sw = self.conns[dpid]
        req = self.pb.WriteRequest()
        req.device_id = sw.device_id
        req.election_id.low = ELECTION_LOW
        upd = req.updates.add()
        upd.type = getattr(self.pb.Update, update_type)
        entity_setter(upd.entity)
        sw.client_stub.Write(req)

    def read(self, dpid, entity_setter):
        sw = self.conns[dpid]
        req = self.pb.ReadRequest()
        req.device_id = sw.device_id
        entity_setter(req.entities.add())
        out = []
        for resp in sw.client_stub.Read(req):
            out.extend(resp.entities)
        return out

    # --- the routes ---------------------------------------------------------------------------
    def table_entry(self, dpid, spec):
        h = self.helpers[dpid]
        match = {}
        for k, v in (spec.get("match") or {}).items():
            match[k] = tuple(v) if isinstance(v, list) else v
        entry = h.buildTableEntry(table_name=spec["table"], match_fields=match or None,
                                  default_action=bool(spec.get("default_action")),
                                  action_name=spec["action_name"],
                                  action_params=spec.get("action_params") or None,
                                  priority=spec.get("priority"))
        return entry

    def write_routes(self, dpid):
        doc = self.conf["runtimes"].get(str(dpid)) or {}
        n = failed = 0
        for spec in doc.get("table_entries") or []:
            try:
                entry = self.table_entry(dpid, spec)
                self.write(dpid, lambda e: e.table_entry.CopyFrom(entry),
                           "MODIFY" if spec.get("default_action") else "INSERT")
                n += 1
            except Exception as exc:  # noqa: BLE001
                failed += 1
                self.result["errors"].append("s%d %s: %s" % (dpid, spec.get("table"), _rpc_error(exc)))
        self.result["switches"][str(dpid)].update({"routes_written": n, "routes_failed": failed})

    # --- the attributions --------------------------------------------------------------------------
    def ternary(self, d):
        e = self.helpers[d].buildTableEntry(TERNARY["table"],
                                            {TERNARY["field"]: (TERNARY["value"], TERNARY["mask"])},
                                            action_name="HcIngress.set_mark",
                                            action_params={"v": TERNARY["mark"]}, priority=TERNARY["priority"])
        self.write(d, lambda x: x.table_entry.CopyFrom(e))

    def range_(self, d):
        e = self.helpers[d].buildTableEntry(RANGE["table"], {RANGE["field"]: (RANGE["low"], RANGE["high"])},
                                            action_name="HcIngress.set_mark",
                                            action_params={"v": RANGE["mark"]}, priority=RANGE["priority"])
        self.write(d, lambda x: x.table_entry.CopyFrom(e))

    def optional(self, d):
        h = self.helpers[d]
        e = h.buildTableEntry(OPTIONAL["table"], None, action_name="HcIngress.set_mark",
                              action_params={"v": OPTIONAL["mark"]}, priority=OPTIONAL["priority"])
        mf = h.get_match_field(OPTIONAL["table"], OPTIONAL["field"])
        fm = e.match.add()
        fm.field_id = mf.id
        fm.optional.value = encode(OPTIONAL["value"], mf.bitwidth)
        self.write(d, lambda x: x.table_entry.CopyFrom(e))

    def priority(self, d):
        for p in PRIORITY:
            e = self.helpers[d].buildTableEntry(TERNARY["table"], {TERNARY["field"]: (p["value"], p["mask"])},
                                                action_name="HcIngress.set_mark",
                                                action_params={"v": p["mark"]}, priority=p["priority"])
            self.write(d, lambda x: x.table_entry.CopyFrom(e))

    def _meter_config(self, cfg):
        cfg.cir, cfg.cburst, cfg.pir, cfg.pburst = METER["cir"], METER["cburst"], METER["pir"], METER["pburst"]

    def meter(self, d):
        mid = self.helpers[d].get_meters_id("HcIngress.m_in")

        def setter(x):
            x.meter_entry.meter_id = mid
            x.meter_entry.index.index = METER_INDEX
            self._meter_config(x.meter_entry.config)
        self.write(d, setter, "MODIFY")

    def _keyed(self, d, table, field, value):
        h = self.helpers[d]
        e = self.pb.TableEntry()
        e.table_id = h.get_tables_id(table)
        e.match.extend([h.get_match_field_pb(table, field, value)])
        return e

    def direct_meter(self, d):
        e = self._keyed(d, "HcIngress.t_dmeter", "hdr.udp.dstPort", DIRECT_METER_DPORT)

        def setter(x):
            x.direct_meter_entry.table_entry.CopyFrom(e)
            self._meter_config(x.direct_meter_entry.config)
        self.write(d, setter, "MODIFY")

    def digest(self, d):
        did = self.helpers[d].get_digests_id("digest_t")

        def setter(x):
            x.digest_entry.digest_id = did
            x.digest_entry.config.max_timeout_ns = 0
            x.digest_entry.config.max_list_size = 1
            x.digest_entry.config.ack_timeout_ns = 1000000000
        self.write(d, setter)

    def clone(self, d):
        e = self.helpers[d].buildCloneSessionEntry(CLONE["session"], [{"egress_port": CLONE["port"], "instance": 1}])
        self.write(d, lambda x: x.packet_replication_engine_entry.CopyFrom(e))

    def register(self, d):
        rid = self.helpers[d].get_registers_id(REGISTER["name"])

        def setter(x):
            x.register_entry.register_id = rid
            x.register_entry.index.index = REGISTER["index"]
            x.register_entry.data.bitstring = encode(REGISTER["value"], 32)
        self.write(d, setter, "MODIFY")

    def direct_counter(self, d):
        e = self._keyed(d, "HcIngress.t_dcount", "hdr.udp.dstPort", DIRECT_COUNTER_DPORT)

        def setter(x):
            x.direct_counter_entry.table_entry.CopyFrom(e)
        ents = self.read(d, setter)
        data = [x.direct_counter_entry.data for x in ents]
        if len(data) != 1:
            raise RuntimeError("DirectCounterEntry read returned %d entries" % len(data))
        return {"packets": int(data[0].packet_count), "bytes": int(data[0].byte_count)}

    def packet_out(self, d):
        from p4_health import frames as F
        po = self.conf["packet_out"]
        frame = F.udp_marker(po["src_mac"], po["dst_mac"], po["src_ip"], po["dst_ip"], 40051,
                             run_id=self.conf["token"], cell="P3", seq=0)
        sw = self.conns[d]
        for seq in range(int(po.get("count", 5))):
            frame = F.udp_marker(po["src_mac"], po["dst_mac"], po["src_ip"], po["dst_ip"], 40051,
                                 run_id=self.conf["token"], cell="P3", seq=seq)
            sw.PacketOut(frame, [{"value": int(po["port"]), "bitwidth": 2}, {"value": 0, "bitwidth": 1}])
        return {"frames": int(po.get("count", 5)), "port": int(po["port"])}

    # --- the stream ------------------------------------------------------------------------------
    def drain(self, d):
        from p4_health import frames as F
        disp = self.conns[d].dispatcher
        q = getattr(disp, "digest_queue", None)
        while q is not None and not q.empty():
            dl = q.get()
            for data in dl.data:
                members = [int.from_bytes(m.bitstring, "big") for m in data.struct.members]
                self.result["digests"].append({"digest_id": dl.digest_id, "members": members})
            ack = self.pb.StreamMessageRequest()
            ack.digest_ack.digest_id = dl.digest_id
            ack.digest_ack.list_id = dl.list_id
            self.conns[d].requests_stream.put(ack)
        while not disp.packet_in_queue.empty():
            pkt = disp.packet_in_queue.get()
            meta = {m.metadata_id: int.from_bytes(m.value, "big") for m in pkt.metadata}
            parsed = F.parse(bytes(pkt.payload))
            self.result["packet_ins"].append({"ingress_port": meta.get(1), "marker": parsed.get("marker"),
                                              "dport": parsed.get("dport")})

    def run(self):
        conf = self.conf
        dpids = sorted(int(k) for k in conf["programs"])
        for d in dpids:
            try:
                self.connect(d)
                self.write_routes(d)
            except Exception as exc:  # noqa: BLE001
                self.result["errors"].append("s%d: %s" % (d, _rpc_error(exc)))
                self.result["switches"].setdefault(str(d), {})["connect_error"] = _rpc_error(exc)
        a = int(conf.get("attr_dpid", 2))
        if a in self.conns:
            for name, fn in (("ternary", self.ternary), ("range", self.range_),
                             ("optional", self.optional), ("priority", self.priority),
                             ("meter", self.meter), ("direct_meter", self.direct_meter),
                             ("digest", self.digest), ("clone", self.clone),
                             ("register", self.register)):
                self.step(name, lambda fn=fn: fn(a))
        _write_json(conf["ready"], self.result)
        deadline = time.monotonic() + float(conf.get("go_timeout_s", 90))
        while not os.path.exists(conf["go"]) and time.monotonic() < deadline:
            time.sleep(0.2)
        self.result["go_seen"] = os.path.exists(conf["go"])
        if a in self.conns:
            time.sleep(1.0)
            self.step("direct_counter", lambda: self.direct_counter(a))
            self.step("packet_out", lambda: self.packet_out(a))
            time.sleep(float(conf.get("settle_s", 2.0)))
            self.drain(a)
        _write_json(conf["out"], self.result)
        for sw in self.conns.values():
            try:
                sw.shutdown()
            except Exception:  # noqa: BLE001
                pass
        return 0


def _batch_details(exc):
    """The per-update p4.v1.Error list a Write's UNKNOWN status carries (as vs_trial.py reads it)."""
    out = []
    try:
        from google.rpc import status_pb2
        from p4.v1 import p4runtime_pb2
        for key, value in (exc.trailing_metadata() or ()):
            if key != "grpc-status-details-bin":
                continue
            st = status_pb2.Status()
            st.ParseFromString(value)
            for detail in st.details:
                err = p4runtime_pb2.Error()
                if detail.Unpack(err):
                    out.append("canonical_code %d: %s" % (err.canonical_code, err.message))
    except Exception:  # noqa: BLE001
        pass
    return out


def _rpc_error(exc):
    code = getattr(exc, "code", None)
    if callable(code):
        try:
            details = _batch_details(exc)
            return "%s: %s%s" % (code().name, exc.details(), (" [%s]" % "; ".join(details)) if details else "")
        except Exception:  # noqa: BLE001
            pass
    return "%s: %s" % (type(exc).__name__, exc)


def _write_json(path, doc):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def main():
    conf = load_config()
    try:
        return Controller(conf).run()
    except Exception:  # noqa: BLE001 -- the probe reads the result file; a crash leaves the trace
        sys.stderr.write(traceback.format_exc())
        return 1


if __name__ == "__main__":
    sys.exit(main())
