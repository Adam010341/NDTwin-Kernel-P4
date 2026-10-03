#!/usr/bin/env python3
"""Capture simple_switch_CLI's real output for every read the thrift oracle parses.

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python tools/p4_health/capture_thrift_fixtures.py <build dir> <out dir>

Runs one throwaway stock bmv2 (throwaway.py's rules: argv[0] ndt-hc-selfcheck-bmv2, a Thrift port
in 29500-29599, no root, stopped by pid) on hc_main with s2's runtime entries, writes a few more
objects through ITS thrift port, and saves each read's raw stdout as <out dir>/<name>.txt. The
files are the fixtures tests/python/test_p4_health_collect.py parses: the formats are this
machine's bmv2, not a transcription.
"""
import json
import os
import sys

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from p4_health import runtime_cli as RC  # noqa: E402
from p4_health import throwaway as TW  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
from p4_health.collect.config import default_p4dev_python  # noqa: E402

CLI = [default_p4dev_python(), "/usr/local/bin/simple_switch_CLI"]

WRITES = [
    "table_add HcIngress.t_ternary HcIngress.set_mark 10.0.1.1&&&255.255.255.0 => 7 10",
    "table_add HcIngress.t_ternary HcIngress.set_mark 10.0.1.0&&&255.255.0.0 => 8 20",
    "table_add HcIngress.t_range HcIngress.set_mark 40000->40010 => 5 1",
    "table_add HcIngress.t_optional HcIngress.set_mark 17&&&255 => 6 1",
    "act_prof_create_member HcIngress.ap_prof HcIngress.set_mark 9",
    "table_indirect_add HcIngress.t_ap 40001 => 0",
    "act_prof_create_member HcIngress.as_sel HcIngress.set_mark 3",
    "act_prof_create_group HcIngress.as_sel",
    "act_prof_add_member_to_group HcIngress.as_sel 0 0",
    "table_indirect_add_with_group HcIngress.t_as 40002 => 0",
    "table_add HcIngress.t_idle HcIngress.idle_hit 40003 =>",
    "table_set_timeout HcIngress.t_idle 0 5000",
    "mirroring_add_mc 9 32777",
]
BEFORE = {
    "show_tables": "show_tables", "show_ports": "show_ports",
    "table_dump_lpm": "table_dump HcIngress.ipv4_lpm",
    "table_dump_default_runtime": "table_dump HcIngress.t_default_only",
    "table_dump_port_exact_empty": "table_dump HcIngress.port_exact",
    "counter_c_in": "counter_read HcIngress.c_in 0",
    "counter_unknown": "counter_read HcIngress.nosuch 0",
    "register_r_mark": "register_read HcIngress.r_mark 0",
    "mc_dump_empty": "mc_dump",
    "mirroring_port": "mirroring_get 7",
    "mirroring_absent": "mirroring_get 5",
    "meter_unset": "meter_get_rates HcIngress.m_in 0",
    "pvs_empty": "pvs_get HcParser.vs_ports",
    "act_prof_empty": "act_prof_dump HcIngress.ap_prof",
    "table_unknown": "table_dump HcIngress.nosuch",
}
AFTER = {
    "table_dump_ternary": "table_dump HcIngress.t_ternary",
    "table_dump_range": "table_dump HcIngress.t_range",
    "table_dump_optional": "table_dump HcIngress.t_optional",
    "table_dump_ap": "table_dump HcIngress.t_ap",
    "table_dump_as": "table_dump HcIngress.t_as",
    "table_dump_idle": "table_dump HcIngress.t_idle",
    "act_prof_member": "act_prof_dump HcIngress.ap_prof",
    "act_prof_group": "act_prof_dump HcIngress.as_sel",
    "mirroring_mgid": "mirroring_get 9",
    "mc_dump_group": "mc_dump",
    "meter_set": "meter_get_rates HcIngress.m_in 0",
    "table_dump_default_compiled": "table_dump HcIngress.t_default_only",
    "table_dump_port_exact_one": "table_dump HcIngress.port_exact",
}


def main(argv):
    build, out = argv[0], argv[1]
    os.makedirs(out, exist_ok=True)
    gen_path = os.path.join(HERE, "exercise", "runtime", "s2-runtime.json")
    runtime = json.load(open(gen_path))
    keys, params = RC.p4info_orders(open(os.path.join(build, "hc_main.p4.p4info.txtpb")).read())
    work = os.path.join(out, ".work")
    os.makedirs(work, exist_ok=True)
    sw = TW.Throwaway(os.path.join(build, "hc_main.json"), {1: [], 2: [], 3: []}, 510, CLI,
                      wait_s=3, workdir=work)
    sw.start()
    try:
        sw.install(RC.commands(runtime, keys, params))
        for name, cmd in sorted(BEFORE.items()):
            open(os.path.join(out, name + ".txt"), "w").write(sw.cli([cmd]))
        for cmd in WRITES + ["table_reset_default HcIngress.t_default_only",
                             "mc_mgrp_create 2", "mc_node_create 0 1 3", "mc_node_associate 2 0",
                             "meter_set_rates HcIngress.m_in 0 0.001:1000 0.002:2000",
                             "table_add HcIngress.port_exact HcIngress.set_port_tag 3 => 5"]:
            sw.cli([cmd])
        for name, cmd in sorted(AFTER.items()):
            open(os.path.join(out, name + ".txt"), "w").write(sw.cli([cmd]))
    finally:
        sw.stop()
        sw.cleanup()
    # what the CLI prints when no switch is listening (a port the throwaway just released)
    import subprocess
    p = subprocess.run(CLI + ["--thrift-port", str(sw.thrift_port)], input="mc_dump\n",
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True,
                       timeout=60)
    open(os.path.join(out, "no_switch.txt"), "w").write(p.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
