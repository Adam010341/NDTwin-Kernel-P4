"""S0: everything the health check can establish without the lab. (design 4.2, Cut 1)

[Co-developed with claude code -- Adam]

    compile (six builds, one at a time, nice -n 19) -> p4info identity -> inventory
    -> convert A, B, C (+ PF-T, + the FWD control) -> pre-flight A, B, C (must PASS), PF-T (must
    FAIL with the G5 row and nothing else) -> drop check A, B, C (rc 0), FWD (rc 1)
    -> the program self-checks on a throwaway bmv2 (main, alt, and the mutant build, which must
    fail exactly SC-count, SC-ttl and SC-qstamp) -> openapi, read in-process -> PF-T's verdict.

Every subprocess goes through the injected Runner. The throwaway switch is the one exception
the Runner does not wrap (a long-lived child stopped by its pid): see throwaway.py.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil

from . import frames as F
from . import runtime_cli as RC
from . import throwaway as TW
from .cells import table as T
from .cells import verdict as V
from .collect.config import default_p4dev_python

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
EXERCISE = os.path.join(HERE, "exercise")
SRC_REL = "src/hc_main.p4"

#: (output dir under the run's exercise copy, stem, defines)
BUILDS = [
    ("build", "hc_main", []),
    ("build", "hc_alt", ["-DHC_ALT"]),
    ("build-mutant", "hc_main", ["-DHC_MUTANT_NO_COUNT", "-DHC_MUTANT_NO_TTL", "-DHC_MUTANT_NO_QSTAMP"]),
    ("build-mutant", "hc_alt", ["-DHC_ALT", "-DHC_MUTANT_NO_COUNT", "-DHC_MUTANT_NO_TTL",
                                "-DHC_MUTANT_NO_QSTAMP"]),
    ("build-fwd", "hc_main", ["-DHC_MUTANT_FWD_88B5"]),
    ("build-fwd", "hc_alt", ["-DHC_ALT", "-DHC_MUTANT_FWD_88B5"]),
]
#: Section 12 item 5: a mutant changes action bodies only, so its p4info is the plain build's.
P4INFO_SAME = [(("build-mutant", "hc_main"), ("build", "hc_main")),
               (("build-fwd", "hc_main"), ("build", "hc_main")),
               (("build-mutant", "hc_alt"), ("build", "hc_alt")),
               (("build-fwd", "hc_alt"), ("build", "hc_alt"))]
ALT_ONLY_TABLE = "HcIngress.alt_port_stamp"
ROLE_C = ("owner=ndtwin,table=HcIngress.ipv4_lpm,match_field=hdr.ipv4.dstAddr,"
          "action=HcIngress.ipv4_forward,dst_mac=dstAddr,port=port")

#: What the program must carry (design 3 and the Q3(b) constructs) -> how S0 sees it.
INVENTORY = {
    "match_exact": ("p4info", "match_type: EXACT"), "match_lpm": ("p4info", "match_type: LPM"),
    "match_ternary": ("p4info", "match_type: TERNARY"), "match_range": ("p4info", "match_type: RANGE"),
    "match_optional": ("p4info", "match_type: OPTIONAL"),
    "counter": ("p4info", "\ncounters {"), "direct_counter": ("p4info", "\ndirect_counters {"),
    "meter": ("p4info", "\nmeters {"), "direct_meter": ("p4info", "\ndirect_meters {"),
    "register": ("p4info", "\nregisters {"), "digest": ("p4info", "\ndigests {"),
    "packet_in": ("p4info", 'name: "packet_in"'), "packet_out": ("p4info", 'name: "packet_out"'),
    "action_profile": ("p4info", "\naction_profiles {"), "action_selector": ("p4info", "with_selector: true"),
    "idle_timeout": ("p4info", "idle_timeout_behavior: NOTIFY_CONTROL"),
    "value_set": ("p4info", "\nvalue_sets {"),
    "clone_i2e": ("json-op", "clone_ingress_pkt_to_egress"), "recirculate": ("json-op", "recirculate"),
    "resubmit": ("json-op", "resubmit"), "hash": ("json-op", "modify_field_with_hash_based_offset"),
    "random": ("json-op", "modify_field_rng_uniform"), "digest_op": ("json-op", "generate_digest"),
    # standard_metadata always DECLARES these two fields, so the needle is a use inside an action
    # (review MINOR 12): an assignment to mcast_grp, a read of enq_qdepth.
    "mcast_grp": ("json-assign", ["standard_metadata", "mcast_grp"]),
    "enq_qdepth": ("json-read", ["standard_metadata", "enq_qdepth"]),
    "header_union": ("json-union", None), "varbit": ("json-varbit", None),
    "header_stack": ("json-stack", None), "ipv4_checksum": ("json-checksum", None),
}


def _uses_field(node, field):
    """Whether a bmv2-JSON expression tree reads `field` (["header", "field"])."""
    if isinstance(node, dict):
        if node.get("type") == "field" and node.get("value") == field:
            return True
        return any(_uses_field(v, field) for v in node.values())
    if isinstance(node, list):
        return any(_uses_field(v, field) for v in node)
    return False


def sha16(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:16]


def inventory(json_path, p4info_path):
    with open(p4info_path, encoding="utf-8") as fh:
        p4info = "\n" + fh.read()
    with open(json_path, encoding="utf-8") as fh:
        text = fh.read()
    j = json.loads(text)
    ops = {p.get("op") for a in j.get("actions", []) for p in a.get("primitives", [])}
    found = {}
    for name, (where, needle) in INVENTORY.items():
        if where == "p4info":
            found[name] = needle in p4info
        elif where == "json-op":
            found[name] = needle in ops
        elif where == "json-assign":
            found[name] = any(p.get("op") == "assign" and (p.get("parameters") or [{}])[0].get("value") == needle
                              for a in j.get("actions", []) for p in a.get("primitives", []))
        elif where == "json-read":
            found[name] = any(_uses_field(p.get("parameters", [])[1:] if p.get("op") == "assign"
                                          else p.get("parameters", []), needle)
                              for a in j.get("actions", []) for p in a.get("primitives", []))
        elif where == "json-union":
            found[name] = bool(j.get("header_union_types"))
        elif where == "json-varbit":
            found[name] = any(f[1] == "*" for h in j.get("header_types", []) for f in h["fields"])
        elif where == "json-stack":
            found[name] = bool(j.get("header_stacks"))
        elif where == "json-checksum":
            found[name] = bool(j.get("checksums"))
    return found


def classify_pft(stdout):
    """(lines that are the G5 refusal, FAIL rows that are about anything else) in pre-flight's
    table. A continuation row (`  FAIL        <detail>`, no label) belongs to the row above it, so
    only labelled rows are classified; PF-T is the G5 answer only when the one labelled FAIL row
    is "entries match p4info" and it carries the G5 sentence (design 2.3 PF-T)."""
    g5 = sum(1 for line in (stdout or "").splitlines() if "G5 not done" in line)
    labelled = [line for line in (stdout or "").splitlines()
                if line.startswith("  FAIL  ") and line[8:9] not in (" ", "")]
    other = sum(1 for line in labelled if not line[8:].startswith("entries match p4info"))
    return g5, other


def _delta(before, after):
    """Packets counted between two counter_read answers; None when either is unreadable."""
    if before is None or after is None:
        return None
    return after[1] - before[1]


def show_ports_ok(parsed, data_ports=(1, 2, 3), cpu_port=510):
    """show_ports of a switch given `data_ports` as -i and `cpu_port` as --cpu-port: exactly the
    data ports, with the CPU port allowed beside them (fabric_view skips it)."""
    return parsed is not None and set(parsed) - {cpu_port} == set(data_ports)


def preflight_rows(stdout):
    """(FAIL rows, the problem lines under them) out of preflight.py's table."""
    return [line for line in (stdout or "").splitlines() if line.startswith("  FAIL")]


class S0(object):
    def __init__(self, run_dir, runner, py_p4, bmv2=TW.DEFAULT_BMV2,
                 thrift_cli=None,
                 p4c="p4c-bm2-ss", hb_cache=None, log=print):
        self.run_dir = os.path.abspath(run_dir)
        self.runner = runner
        self.py = py_p4
        self.bmv2 = bmv2
        self.thrift_cli = list(thrift_cli or [default_p4dev_python(), "/usr/local/bin/simple_switch_CLI"])
        self.p4c = p4c
        self.hb_cache = hb_cache or os.path.join(self.run_dir, "hb-cache")
        self.log = log
        self.ex = os.path.join(self.run_dir, "exercise")
        self.out = {"checks": [], "builds": {}, "inventory": {}, "preflight": {}, "drop_check": {},
                    "self_checks": {}, "program_probes": {}, "openapi": None}

    def check(self, name, ok, detail=""):
        self.out["checks"].append({"name": name, "ok": bool(ok), "detail": detail})
        self.log("  %s  %-44s %s" % ("ok  " if ok else "FAIL", name, detail))
        return ok

    def run_cmd(self, argv, timeout=600, env=None, cwd=None):
        res = self.runner.run(argv, timeout=timeout, env=env, cwd=cwd)
        with open(os.path.join(self.run_dir, "s0.commands.log"), "a", encoding="utf-8") as fh:
            fh.write("$ %s\nrc=%s\n%s%s\n" % (" ".join(argv), res.rc, res.stdout[-4000:], res.stderr[-2000:]))
        return res

    # --- 1. compile -------------------------------------------------------------------------------
    def compile_all(self):
        if os.path.exists(self.ex):
            shutil.rmtree(self.ex)
        shutil.copytree(EXERCISE, self.ex, ignore=shutil.ignore_patterns("__pycache__", "build*"))
        src = os.path.join(self.ex, SRC_REL)
        for outdir, stem, defines in BUILDS:
            d = os.path.join(self.ex, outdir)
            os.makedirs(d, exist_ok=True)
            js, info = os.path.join(d, stem + ".json"), os.path.join(d, stem + ".p4.p4info.txtpb")
            res = self.run_cmd(["nice", "-n", "19", self.p4c, "--p4v", "16"] + defines +
                               ["--p4runtime-files", info, "-o", js, src])
            key = "%s/%s" % (outdir, stem)
            ok = res.rc == 0 and os.path.isfile(js) and os.path.isfile(info)
            self.out["builds"][key] = {"defines": defines, "rc": res.rc,
                                       "json_sha16": sha16(js) if ok else None,
                                       "p4info_sha16": sha16(info) if ok else None}
            self.check("compile %s %s" % (key, " ".join(defines)), ok,
                       "p4info %s" % (self.out["builds"][key]["p4info_sha16"],))
        return all(b["rc"] == 0 for b in self.out["builds"].values())

    def p4info_identity(self):
        b = self.out["builds"]
        for (m_dir, m_stem), (p_dir, p_stem) in P4INFO_SAME:
            m, p = b["%s/%s" % (m_dir, m_stem)], b["%s/%s" % (p_dir, p_stem)]
            self.check("p4info %s/%s == %s/%s" % (m_dir, m_stem, p_dir, p_stem),
                       m["p4info_sha16"] == p["p4info_sha16"] and m["p4info_sha16"] is not None,
                       "%s vs %s" % (m["p4info_sha16"], p["p4info_sha16"]))
        main_i = os.path.join(self.ex, "build", "hc_main.p4.p4info.txtpb")
        alt_i = os.path.join(self.ex, "build", "hc_alt.p4.p4info.txtpb")
        main_t = set(re.findall(r'name: "(HcIngress\.[A-Za-z_]+)"', open(main_i).read()))
        alt_t = set(re.findall(r'name: "(HcIngress\.[A-Za-z_]+)"', open(alt_i).read()))
        self.check("hc_alt has exactly one object hc_main lacks", alt_t - main_t == {ALT_ONLY_TABLE}
                   and not (main_t - alt_t), "alt-only: %s" % sorted(alt_t - main_t))

    def take_inventory(self):
        for stem in ("hc_main", "hc_alt"):
            inv = inventory(os.path.join(self.ex, "build", stem + ".json"),
                            os.path.join(self.ex, "build", stem + ".p4.p4info.txtpb"))
            self.out["inventory"][stem] = inv
            missing = sorted(k for k, v in inv.items() if not v)
            self.check("inventory %s: every construct compiled in" % stem, not missing,
                       "missing %s" % missing if missing else "%d constructs" % len(inv))

    # --- 2. packages ---------------------------------------------------------------------------
    def convert(self, name, topology, mode, exercise=None, role=None):
        pkg = os.path.join(self.run_dir, "packages", name)
        if os.path.exists(pkg):
            shutil.rmtree(pkg)
        argv = [self.py, os.path.join(REPO, "tools", "p4_exercise", "convert.py"), exercise or self.ex,
                "--topology", topology, "--p4", SRC_REL, "--out", pkg, "--mode", mode,
                "--name", "p4-health-%s" % name]
        if role:
            argv += ["--role-ipv4-route", role]
        res = self.run_cmd(argv)
        ok = res.rc == 0 and os.path.isfile(os.path.join(pkg, "package.json"))
        if ok:
            # design 2.2: every package states telemetry.source = link (convert has no flag for it).
            path = os.path.join(pkg, "package.json")
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
            doc["telemetry"] = {"source": "link"}
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(doc, fh, indent=2, sort_keys=True)
                fh.write("\n")
        self.check("convert %s (%s)" % (name, mode), ok, "rc %s" % res.rc)
        return pkg if ok else None

    def packages(self):
        fwd_ex = os.path.join(self.run_dir, "exercise-fwd")
        if os.path.exists(fwd_ex):
            shutil.rmtree(fwd_ex)
        shutil.copytree(self.ex, fwd_ex, ignore=shutil.ignore_patterns("build", "build-mutant"))
        os.rename(os.path.join(fwd_ex, "build-fwd"), os.path.join(fwd_ex, "build"))
        # (Cut 2) A with the mutant artefact, for the live see-red run (design 5.2-④: --only
        # K1,TTL1 must give PROBE-BROKEN by SC-count and SC-ttl). Its p4info is the plain one.
        mut_ex = os.path.join(self.run_dir, "exercise-mutant")
        if os.path.exists(mut_ex):
            shutil.rmtree(mut_ex)
        shutil.copytree(self.ex, mut_ex, ignore=shutil.ignore_patterns("build", "build-fwd"))
        os.rename(os.path.join(mut_ex, "build-mutant"), os.path.join(mut_ex, "build"))
        self.pkgs = {
            "A": self.convert("A", "topology.json", "ndtwin"),
            "B": self.convert("B", "topology-b.json", "external"),
            "C": self.convert("C", "topology.json", "ndtwin", role=ROLE_C),
            "PF-T": self.convert("PF-T", "topology-pft.json", "ndtwin"),
            "FWD": self.convert("FWD", "topology.json", "ndtwin", exercise=fwd_ex),
            "A-MUT": self.convert("A-MUT", "topology.json", "ndtwin", exercise=mut_ex),
        }

    def preflight(self):
        script = os.path.join(REPO, "tools", "p4_exercise", "preflight.py")
        for name in ("A", "B", "C", "PF-T", "A-MUT"):
            pkg = self.pkgs.get(name)
            if pkg is None:
                self.check("pre-flight %s" % name, False, "no package")
                continue
            res = self.run_cmd(["nice", "-n", "19", self.py, script, pkg])
            fails = preflight_rows(res.stdout)
            g5 = [l for l in res.stdout.splitlines() if "G5 not done" in l]
            other = 0
            self.out["preflight"][name] = {"rc": res.rc, "fail_rows": fails}
            if name != "PF-T":
                self.check("pre-flight %s PASS" % name, res.rc == 0 and not fails,
                           "rc %s, %d FAIL row(s)" % (res.rc, len(fails)))
            else:
                g5n, other = classify_pft(res.stdout)
                self.out["preflight"][name].update({"g5_rows": g5n, "other_fail_rows": other})
                self.check("pre-flight PF-T FAILs on the ternary row only",
                           res.rc == 1 and g5n >= 1 and other == 0,
                           "rc %s, G5 lines %d, other FAIL rows %d" % (res.rc, g5n, other))

    def drop_check(self):
        script = os.path.join(REPO, "tools", "test_workflow", "heartbeat_drop_check.py")
        os.makedirs(self.hb_cache, exist_ok=True)
        env = {"NDT_HB_CHECK_CACHE": self.hb_cache}
        want = {"A": 0, "B": 0, "C": 0, "FWD": 1, "A-MUT": 0}
        for name, rc_want in sorted(want.items()):
            pkg = self.pkgs.get(name)
            if pkg is None:
                self.check("drop check %s" % name, False, "no package")
                continue
            out_json = os.path.join(self.run_dir, "dropcheck.%s.json" % name)
            res = self.run_cmd([self.py, script, pkg, "--json", out_json], env=env, timeout=300)
            self.out["drop_check"][name] = {"rc": res.rc, "want": rc_want}
            self.check("drop check %s rc %d" % (name, rc_want), res.rc == rc_want, "rc %s" % res.rc)

    # --- 3. the program on a throwaway switch ----------------------------------------------------
    def _switch_inputs(self, dpid):
        import importlib.util
        spec = importlib.util.spec_from_file_location("hc_gen", os.path.join(self.ex, "gen_runtime.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        return gen

    def selfcheck_run(self, label, build_dir, dpid):
        """One throwaway switch: dpid's program and entries, markers in, outputs read."""
        gen = self._switch_inputs(dpid)
        stem = gen.program(dpid)
        js = os.path.join(self.ex, build_dir, stem + ".json")
        info = os.path.join(self.ex, build_dir, stem + ".p4.p4info.txtpb")
        runtime = gen.runtime(dpid)
        keys, params = RC.p4info_orders(open(info, encoding="utf-8").read())
        lines = RC.commands(runtime, keys, params)
        ports = sorted({p for p in gen.ROUTES[dpid].values()})
        here = {h: gen.HOST_PORT[h] for h, s in gen.HOSTS.items() if s == dpid}
        src_port = min(here.values())                       # a host port of this switch
        transit = [p for p in ports if p not in here.values()]
        in_port = transit[0] if transit else src_port       # where "remote" markers come in
        local = min(here)                                   # a host on this switch
        hm, hip = gen.host_mac(local), gen.host_ip(local)
        rm, rip = "08:00:00:00:aa:01", "10.0.9.9"
        out_port = gen.ROUTES[dpid][local]
        inputs = {p: [] for p in ports}
        # SC-fwd: one marker per destination host, from a host port
        for h in sorted(gen.ROUTES[dpid]):
            inputs[src_port].append(F.udp_marker(hm, "08:00:00:00:01:00", hip, gen.host_ip(h), 40001,
                                                 cell="SCfwd", seq=h))
        k = [F.udp_marker(rm, hm, rip, hip, T.DPORTS["K1"], cell="K1", seq=i) for i in range(5)]
        inputs[in_port] += k
        inputs[in_port].append(F.udp_marker(rm, hm, rip, hip, T.DPORTS["R2"], sport=4660, cell="R2"))
        inputs[in_port] += [F.udp_marker(rm, hm, rip, hip, T.DPORTS["Q1"], ident=0, cell="Q1", seq=i)
                            for i in range(3)]
        inputs[in_port].append(F.udp_marker(rm, hm, rip, hip, T.DPORTS["Q1"], ident=1, cell="Q1ctl"))
        inputs[in_port].append(F.udp_marker(rm, hm, rip, hip, T.DPORTS["TTL1"], cell="TTL1"))
        inputs[in_port].append(F.udp_marker(rm, hm, rip, hip, T.DPORTS["RC1"], cell="RC1"))
        inputs[in_port].append(F.ipv6_marker(rm, hm, 9, local, cell="HU1"))
        # program probes (not self-checks): custom headers, punt, clone, multicast, Q3(b)
        inputs[in_port].append(F.tunnel_frame(rm, hm, local, rip, hip))
        inputs[in_port].append(F.hcl2_frame(rm, hm, local))
        inputs[in_port].append(F.alt6_frame(rm, hm, local))
        inputs[in_port].append(F.srcroute_frame(rm, hm, [out_port], rip, hip))
        inputs[in_port].append(F.vlan_frame(rm, hm, 7, rip, hip))
        inputs[in_port].append(F.shim_frame(rm, hm, rip, hip))
        inputs[in_port].append(F.udp_marker(rm, hm, rip, hip, T.DPORTS["VB1"], cell="VB1",
                                            extra=b"\x10" + b"\xab" * 16))
        inputs[in_port].append(F.udp_marker(rm, hm, rip, hip, T.DPORTS["CH6"], cell="CH6",
                                            extra=b"\xc6\xc6\xc6\xc6"))
        inputs[in_port].append(F.udp_marker(rm, hm, rip, hip, T.DPORTS["P2"], cell="P2"))
        inputs[in_port].append(F.udp_marker(rm, hm, rip, hip, T.DPORTS["C1"], cell="C1"))
        inputs[in_port].append(F.udp_marker(rm, hm, rip, hip, T.DPORTS["MCAST"], cell="MC"))
        h4 = gen.host_ip(4)
        for i in range(16):
            inputs[src_port].append(F.udp_marker(hm, "08:00:00:00:01:00", hip, h4, T.DPORTS["HR1"],
                                                 sport=41000 + i * 7, cell="HR1", seq=i))
            inputs[src_port].append(F.udp_marker(hm, "08:00:00:00:01:00", hip, h4, T.DPORTS["HR2"],
                                                 cell="HR2", seq=i))
        for p in ports:
            inputs[p].append(F.heartbeat_like())
        sw = TW.Throwaway(js, inputs, gen.CPU_PORT, self.thrift_cli, wait_s=8, bmv2=self.bmv2,
                          workdir=os.path.join(self.run_dir, "throwaway-%s" % label), runner=self.runner)
        os.makedirs(sw.workdir, exist_ok=True)
        res = {"label": label, "dpid": dpid, "program": "%s/%s" % (build_dir, stem)}
        sw.start()
        try:
            res["install_out_tail"] = sw.install(lines)[-300:]
            res["installed_before_s"] = round(sw.installed_before_s, 2)
            before = sw.cli(["counter_read HcIngress.c_in 0"])
            sw.wait_processed()
            reads = {}
            for cmd in ("counter_read HcIngress.c_in 0", "register_read HcIngress.r_mark 0",
                        "table_dump HcIngress.ipv4_lpm", "table_dump HcIngress.v6_host", "show_tables"):
                reads[cmd] = sw.cli([cmd])
            # PF-T's static attribution: this bmv2 holds a ternary entry and dumps it back.
            sw.cli(["table_add HcIngress.t_ternary HcIngress.set_mark 10.0.1.1&&&255.255.255.255 => 7 10"])
            reads["table_dump HcIngress.t_ternary"] = sw.cli(["table_dump HcIngress.t_ternary"])
            outs = sw.outputs()
        finally:
            res["stop_rc"] = sw.stop()
        from .collect import thrift as TH
        from . import observe as OB
        res["reads"] = reads
        res["c_in_before"] = TH.parse_counter(TH.body(before))
        res["missing_outputs"] = sorted(p for p, fs in outs.items() if fs is None)
        parsed = {p: [F.parse(f) if p != gen.CPU_PORT else dict(F.parse(F.packet_in_split(f)[1]),
                                                                  packet_in_port=F.packet_in_split(f)[0])
                      for f in (fs or [])] for p, fs in outs.items()}
        res["outputs"] = {str(p): len(v) for p, v in parsed.items()}

        def marked(cell):
            return [(p, x) for p, xs in parsed.items() for x in xs if (x.get("marker") or (0, ""))[1] == cell]

        # --- the self-checks, judged by the same functions a live run uses
        fwd = marked("SCfwd")
        good = [x for p, x in fwd if p == gen.ROUTES[dpid][x["marker"][2]]]
        dump = TH.parse_table_dump(TH.body(reads["table_dump HcIngress.ipv4_lpm"]))
        got = {(TH.key_value(k, v)[0], TH.key_value(k, v)[1]) for e in (dump or {}).get("entries", [])
               for (_f, k, v) in e["keys"]}
        want = set()
        for e in runtime["table_entries"]:
            if e["table"] == "HcIngress.ipv4_lpm" and e.get("match"):
                ip, pl = e["match"]["hdr.ipv4.dstAddr"]
                want.add((int.from_bytes(F.ip_bytes(ip), "big"), pl))
        sc_obs = {
            "SC-fwd": {"pingall": (len(good), len(fwd)), "expected_total": len(gen.ROUTES[dpid]),
                       "dump_ok": dump is not None and got == want},
            "SC-count": {"thrift_delta": _delta(res["c_in_before"],
                                                TH.parse_counter(TH.body(reads["counter_read HcIngress.c_in 0"]))),
                         "sent": len(k), "received": len(marked("K1"))},
            "SC-reg": {"chosen": 4660, "register": TH.parse_register(TH.body(reads["register_read HcIngress.r_mark 0"]))},
            "SC-qstamp": {"sent_idents": {0}, "stamped": sum(1 for _p, x in marked("Q1") if x.get("ident", 0) & 0x8000)},
            "SC-ttl": {"hops_lpm": T.hops_from_lpm({dpid: OB.lpm_routes(dump)}, {}, dpid, gen.host_ip(local)),
                       "ttls": [x.get("ttl") for _p, x in marked("TTL1")], "sent_ttl": 64},
            "SC-recirc": {"flags": [x.get("diffserv", 0) for _p, x in marked("RC1")]},
            "SC-union": {"hops_v6": T.hops_from_lpm(
                             {dpid: OB.v6_routes(TH.parse_table_dump(TH.body(reads["table_dump HcIngress.v6_host"])))},
                             {}, dpid, local),
                         "hop_limits": [x.get("hop_limit") for xs in parsed.values() for x in xs
                                        if x.get("ethertype") == F.ETH_IPV6]},
        }
        states = {}
        for sc in T.SELF_CHECKS:
            ok, why = sc.check(sc_obs[sc.id])
            states[sc.id] = {"ok": ok, "why": why}
        res["self_checks"] = states
        # --- probes: what the program did with every other kind of frame
        hb_out = sum(1 for xs in parsed.values() for x in xs if x.get("ethertype") == F.ETH_HB)
        ctl = [x for _p, x in marked("Q1ctl")]
        punted = [x for x in parsed.get(gen.CPU_PORT, []) if (x.get("marker") or (0, ""))[1] == "P2"]
        hr = {c: sorted({p for p, _x in marked(c)}) for c in ("HR1", "HR2")}
        res["probes"] = {
            "heartbeat_frames_out_with_entries": hb_out,
            "q1_control_id1_unstamped": bool(ctl) and all(not (x["ident"] & 0x8000) for x in ctl),
            "punt_to_cpu_with_packet_in": bool(punted) and punted[0].get("packet_in_port") == in_port,
            "clone_copies_on_p1": len([1 for p, _x in marked("C1") if p == 1]),
            "mcast_ports": sorted({p for p, _x in marked("MC")}),
            "tunnel_out": sorted({p for p, xs in parsed.items() for x in xs if x.get("ethertype") == F.ETH_TUNNEL}),
            "hcl2_out": sorted({p for p, xs in parsed.items() for x in xs if x.get("ethertype") == F.ETH_HCL2}),
            "alt6_out": sorted({p for p, xs in parsed.items() for x in xs if x.get("ethertype") == F.ETH_UALT}),
            "srcroute_popped_to_ipv4": sorted({p for p, x in marked("CH2")}),
            "vlan_out": sorted({p for p, xs in parsed.items() for x in xs if x.get("ethertype") == F.ETH_VLAN}),
            "shim_out": sorted({p for p, x in marked("CH4")}),
            "varbit_out": sorted({p for p, x in marked("VB1")}),
            "l4shim_out": sorted({p for p, x in marked("CH6")}),
            "ip_checksums_ok": all(x.get("ip_csum_ok", True) for xs in parsed.values() for x in xs),
            "hash_uplinks": hr["HR1"], "random_uplinks": hr["HR2"],
            "alt_table_listed": ALT_ONLY_TABLE in (reads["show_tables"] or ""),
        }
        tern = TH.parse_table_dump(TH.body(reads["table_dump HcIngress.t_ternary"]))
        res["ternary_held"] = bool(tern and any(e["priority"] == 10 and e["keys"] and
                                                TH.key_value(e["keys"][0][1], e["keys"][0][2]) == (0x0A000101, 0xFFFFFFFF)
                                                for e in tern["entries"]))
        res["local_port"] = out_port
        return res

    def self_checks(self):
        want_fail = {"main": set(), "alt": set(), "mutant": {"SC-count", "SC-ttl", "SC-qstamp"},
                     "fwd": set()}
        # fwd: the heartbeat check below must be seen red once (review MINOR 13)
        runs = {"main": ("build", 2), "alt": ("build", 1), "mutant": ("build-mutant", 2),
                "fwd": ("build-fwd", 2)}
        for label, (bdir, dpid) in sorted(runs.items()):
            try:
                r = self.selfcheck_run(label, bdir, dpid)
            except (TW.ThrowawayError, OSError, RC.Untranslatable) as exc:
                self.check("throwaway %s" % label, False, "%s: %s" % (type(exc).__name__, exc))
                continue
            self.out["self_checks"][label] = r
            failed = {k for k, v in r["self_checks"].items() if not v["ok"]}
            self.check("self-checks on the throwaway (%s, s%d)" % (label, dpid), failed == want_fail[label],
                       "failed %s, expected %s" % (sorted(failed), sorted(want_fail[label])))
            pr = r["probes"]
            self.check("  %s: every output pcap readable" % label, not r["missing_outputs"],
                       "missing %s" % r["missing_outputs"])
            if label == "fwd":
                self.check("  fwd: the 0x88B5 check goes red on the forwarding build",
                           pr["heartbeat_frames_out_with_entries"] > 0,
                           "%d heartbeat frame(s) left the switch" % pr["heartbeat_frames_out_with_entries"])
            else:
                self.check("  %s: 0x88B5 dropped with every entry installed" % label,
                           pr["heartbeat_frames_out_with_entries"] == 0,
                           "%d heartbeat frame(s) left the switch" % pr["heartbeat_frames_out_with_entries"])
            if label == "main":
                lp = r["local_port"]
                self.check("  main: custom headers parsed and forwarded to the host port",
                           all(pr[k] == [lp] for k in ("tunnel_out", "hcl2_out", "alt6_out",
                                                       "srcroute_popped_to_ipv4", "vlan_out",
                                                       "shim_out", "varbit_out", "l4shim_out")),
                           json.dumps({k: pr[k] for k in ("tunnel_out", "hcl2_out", "alt6_out",
                                                         "srcroute_popped_to_ipv4", "vlan_out",
                                                         "shim_out", "varbit_out", "l4shim_out")}))
                self.check("  main: punt carries packet_in; clone mirrors to p1; Q1 id=1 unstamped",
                           pr["punt_to_cpu_with_packet_in"] and pr["clone_copies_on_p1"] == 2
                           and pr["q1_control_id1_unstamped"],
                           "punt %s, clone copies on p1 %s, id1 unstamped %s"
                           % (pr["punt_to_cpu_with_packet_in"], pr["clone_copies_on_p1"],
                              pr["q1_control_id1_unstamped"]))
                self.check("  main: IPv4 header checksums valid on every output", pr["ip_checksums_ok"])
                self.check("  main: bmv2 holds a ternary entry (PF-T's static attribution)",
                           r["ternary_held"])
            if label == "alt":
                self.check("  alt: multicast group 1 replicates to p1, p2", pr["mcast_ports"] == [1, 2],
                           "ports %s" % pr["mcast_ports"])
                self.check("  alt: the hash and the coin each use both uplinks",
                           pr["hash_uplinks"] == [4, 5] and pr["random_uplinks"] == [4, 5],
                           "hash %s random %s" % (pr["hash_uplinks"], pr["random_uplinks"]))
                self.check("  alt: show_tables lists the hc_alt-only table", pr["alt_table_listed"])

    def identity(self):
        """What binaries this S0 ran (review MINOR 14): sha256[:16] of each, and `--version` run
        through a symlink named ndt-hc-version (so not even a version run reads as a switch)."""
        vdir = os.path.join(self.run_dir, ".version-bin")
        os.makedirs(vdir, exist_ok=True)
        out = {}
        fabric = None
        try:
            from .vs_trial import fabric_binary
            fabric = fabric_binary()
        except Exception:  # noqa: BLE001
            pass
        p4c = shutil.which(self.p4c) or self.p4c
        for name, path in (("p4c", p4c), ("simple_switch", self.bmv2),
                           ("simple_switch_grpc_stock", "/usr/local/bin/simple_switch_grpc"),
                           ("simple_switch_grpc_fabric", fabric),
                           ("simple_switch_CLI", self.thrift_cli[-1])):
            if not path or not os.path.isfile(path):
                out[name] = {"path": path, "sha16": None, "version": None}
                continue
            link = os.path.join(vdir, "ndt-hc-version-%s" % name)
            if not os.path.lexists(link):
                os.symlink(os.path.realpath(path), link)
            ver = None
            if name != "simple_switch_CLI":
                env = None
                lib = os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(path)), "..", "lib"))
                if name.endswith("_fabric") and os.path.isdir(lib):
                    env = {"LD_LIBRARY_PATH": lib}
                res = self.runner.run([link, "--version"], timeout=20, env=env)
                ver = ((res.stdout or res.stderr).strip().splitlines() or [None])[-1]
            out[name] = {"path": os.path.realpath(path), "sha16": sha16(path), "version": ver}
        self.out["identity"] = out
        self.check("identity of p4c and the bmv2 binaries recorded",
                   all(out[k]["sha16"] for k in ("p4c", "simple_switch", "simple_switch_CLI")),
                   " ".join("%s=%s" % (k, (v["sha16"] or "-")) for k, v in sorted(out.items())))

    def vs_trial(self):
        """VS1's Cut 2 safety question (review MAJ-8), asked of throwaway simple_switch_grpc."""
        try:
            from . import vs_trial as VT
            results = [VT.trial(os.path.join(self.ex, "build"), b, self.thrift_cli,
                                os.path.join(self.run_dir, "vs_trial_work"))
                       for b in ("/usr/local/bin/simple_switch_grpc", VT.fabric_binary())]
        except Exception as exc:  # noqa: BLE001
            self.check("ValueSetEntry trial on throwaway simple_switch_grpc", False,
                       "%s: %s" % (type(exc).__name__, exc))
            return
        self.out["vs_trial"] = results
        alive = all(r.get("alive_after_write") and r.get("alive_after_read") for r in results)
        refused = all(any(e.get("canonical_code") == 12 for e in (r.get("write_errors") or []))
                      for r in results)
        self.check("ValueSetEntry write: switch survives, write UNIMPLEMENTED (both builds)",
                   alive and refused,
                   "; ".join("%s: %s alive=%s" % (os.path.basename(os.path.dirname(os.path.dirname(r["bmv2"]))),
                                                   (r.get("write_errors") or [{}])[0].get("message"),
                                                   r.get("alive_after_write")) for r in results))

    def ctrl_trial(self):
        """(Cut 2) B's controller and attribution.confirm on throwaway simple_switch_grpc
        switches, stock and fabric build: every attribution confirmed except the RegisterEntry
        write, which bmv2's P4Runtime refuses ("Register writes are not supported yet", seen in
        Cut 2) -- R3's bmv2 half therefore cannot be established and R3 reads UNATTRIBUTED."""
        want_false = {"register"}
        try:
            from . import ctrl_trial as CT
            from .vs_trial import fabric_binary
            utils = os.path.join(os.path.expanduser("~"), "tutorials", "utils")
            results = [CT.trial(os.path.join(self.ex, "build"), b, self.thrift_cli,
                                os.path.join(self.run_dir, "ctrl_trial_work", "%d" % i),
                                default_p4dev_python(), utils)
                       for i, b in enumerate(("/usr/local/bin/simple_switch_grpc", fabric_binary()))]
        except Exception as exc:  # noqa: BLE001
            self.check("B's controller on throwaway simple_switch_grpc", False,
                       "%s: %s" % (type(exc).__name__, exc))
            return
        self.out["ctrl_trial"] = results
        for r in results:
            failed = {k for k, v in r["confirmed"].items() if not v["ok"]}
            self.check("B's controller on throwaway %s: 11 attributions" % os.path.basename(
                           os.path.dirname(os.path.dirname(r["bmv2"]))),
                       failed == want_false and r.get("controller_rc") == 0 and r.get("alive"),
                       "unconfirmed %s (expected %s), controller rc %s"
                       % (sorted(failed), sorted(want_false), r.get("controller_rc")))

    def show_ports_trial(self):
        """(Cut 2 second review N4, r1's test 10) What show_ports lists on a simple_switch_grpc
        started the way BMv2Switch starts a fabric switch -- data ports as -i, then
        `-- --grpc-server-addr ... --cpu-port 510` -- on throwaway switches, stock and fabric
        build. TP1's oracle must place every port listed, so a listed CPU port would matter;
        observe_a.fabric_view skips port 510 either way, and this records which it is."""
        try:
            from .vs_trial import fabric_binary
            got = {}
            for i, b in enumerate(("/usr/local/bin/simple_switch_grpc", fabric_binary())):
                work = os.path.join(self.run_dir, "show_ports_trial", "%d" % i)
                os.makedirs(work, exist_ok=True)
                sw = TW.Throwaway(os.path.join(self.ex, "build", "hc_main.json"), {1: [], 2: [], 3: []},
                                  510, self.thrift_cli, wait_s=2, bmv2=b, workdir=work,
                                  argv0="ndt-hc-ports-bmv2", grpc=True, runner=self.runner)
                sw.start()
                try:
                    from .collect import thrift as TH
                    got[b] = TH.parse_show_ports(TH.body(sw.cli(["show_ports"])))
                finally:
                    sw.stop()
        except Exception as exc:  # noqa: BLE001
            self.check("show_ports on throwaway simple_switch_grpc with --cpu-port 510", False,
                       "%s: %s" % (type(exc).__name__, exc))
            return
        self.out["show_ports_trial"] = {b: sorted(p) if p else None for b, p in got.items()}
        self.check("show_ports with --cpu-port 510 lists the -i data ports (510 only if at all)",
                   all(show_ports_ok(p) for p in got.values()),
                   "; ".join("%s: %s" % (os.path.basename(os.path.dirname(os.path.dirname(b))),
                                         sorted(p) if p else p) for b, p in got.items()))

    def adapter_dry_run(self):
        """(Cut 2 review m5) The live B path through the adapter, without running anything: the
        same argv bring-up B spawns, with --dry-run. It must name controller_ext.py and rewrite
        s1-s4 onto the fabric's ports 30051-30054 with device id = dpid."""
        from . import round_b as RB
        pkg = (getattr(self, "pkgs", None) or {}).get("B")
        if pkg is None:
            self.check("adapter --dry-run on package B", False, "no package")
            return
        utils = os.path.join(os.path.expanduser("~"), "tutorials", "utils")
        res = self.run_cmd(RB.adapter_argv(default_p4dev_python(), pkg, utils) + ["--dry-run"], timeout=60)
        out = res.stdout or ""
        want = ["localhost:%d device_id=%d" % (30050 + d, d) for d in (1, 2, 3, 4)]
        rewrites = [l for l in out.splitlines() if "  ->  " in l]
        ok = (res.rc == 0 and ("controller: %s" % RB.CONTROLLER) in out
              and sorted(l.split("  ->  ")[1].strip() for l in rewrites) == want
              and all(l.strip().startswith("s%d:" % d) for l, d in zip(rewrites, (1, 2, 3, 4))))
        self.check("adapter --dry-run on package B: controller_ext.py, s1-s4 onto 30051-30054", ok,
                   "rc %s, %d rewrite(s)" % (res.rc, len(rewrites)))

    def openapi(self):
        res = self.run_cmd([self.py, os.path.join(HERE, "openapi_probe.py"), "--repo", REPO], timeout=120)
        try:
            doc = json.loads(res.stdout)
        except ValueError:
            doc = None
        self.out["openapi"] = doc
        self.check("openapi.json served in-process (FastAPI default kept)",
                   bool(doc) and doc.get("status") == 200 and doc.get("openapi_url") == "/openapi.json",
                   "%d paths" % len((doc or {}).get("paths") or {}))

    def pft_verdict(self):
        pf = self.out["preflight"].get("PF-T") or {}
        main = self.out["self_checks"].get("main") or {}
        obs = {"answer": {"rc": pf.get("rc"), "g5_rows": pf.get("g5_rows", 0),
                          "other_fail_rows": pf.get("other_fail_rows", 0)},
               "attribution": {"static": bool(main.get("ternary_held"))}}
        v = V.decide(T.TABLE.cell("PF-T"), obs, V.Context())
        self.out["pft"] = v.as_dict()
        self.check("PF-T verdict RED (structural + static)", v.verdict == V.RED, v.label + ": " + v.reason)
        return v

    def run(self):
        os.makedirs(self.run_dir, exist_ok=True)
        if self.compile_all():
            self.p4info_identity()
            self.take_inventory()
            self.packages()
            self.preflight()
            self.drop_check()
            self.self_checks()
            self.vs_trial()
            self.ctrl_trial()
            self.adapter_dry_run()
            self.show_ports_trial()
        self.identity()
        self.openapi()
        self.pft_verdict()
        ok = all(c["ok"] for c in self.out["checks"])
        self.out["verdict"] = "COMPLETE" if ok else "PROBE-BROKEN"
        with open(os.path.join(self.run_dir, "s0.json"), "w", encoding="utf-8") as fh:
            json.dump(self.out, fh, indent=2, sort_keys=True, default=sorted)
            fh.write("\n")
        return 0 if ok else 1
