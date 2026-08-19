#!/usr/bin/env python3
"""
The bmv2 topology with NTG's CLI attached: the ~40 lines that were missing.

[Co-developed with claude code -- Adam]

NTG's Mininet mode must live in the process that owns the net (MininetCommunicator drives
hosts through `host.cmd`/`host.popen`), and its only shipped entry point builds an OVS
topology. This script is the P4-side twin of that entry point: it builds the same 10-switch
bmv2 fabric as p4_testbed_topo.py -- reusing its classes, manifest and teardown wholesale --
and then hands the net to NTG's `command_line()` instead of Mininet's CLI. Recorded as the
pending feature `ntg-bmv2-support-pending-feature` on 2026-08-15; nothing in NTG itself is
modified.

Run it (Mininet needs root; nornir/loguru live in the ntg-env conda env, and the
dist-packages append below borrows the system Mininet the same way NTG's own topo does):

    sudo /home/adam/miniconda3/envs/ntg-env/bin/python ntg_bmv2_topo.py

Then, at the NTG prompt -- with the P4 stack's rates in mind. This bmv2 is an unoptimized
-O0 build and literature puts the grpc variant around ~170 Mbps per switch (see
doc/2026-08-15_bmv2-performance-report.md), so use the low-rate template next to this
script rather than NTG's defaults:

    flow --config /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/flow_bmv2_low.json

First thing to watch on a first live run: NTG's `link_relationship_init` computes its
near/middle/far distance partition against the kernel's host list. Its own topology has 128
hosts; this one has 4. That path has never run against a 4-host fabric -- if it misbehaves,
that is an NTG finding to record, not something to patch here.
"""

import os
import sys
import time

# System Mininet for a conda interpreter, exactly the trick NTG's own testbed_topo.py uses.
sys.path.append('/usr/lib/python3/dist-packages')
sys.path.append('/usr/local/lib/python3/dist-packages')

# Sibling imports: the bmv2 topology pieces next to this file, and NTG's repo for its CLI.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(HERE)
NTG_DIR = os.environ.get("NTG_DIR", "/home/adam/Network-Traffic-Generator")
sys.path.append(NTG_DIR)

from mininet.net import Mininet
from mininet.log import setLogLevel

from p4_testbed_topo import (MANIFEST_PATH, MultiSwitchTopo, _host_count_override,
                             disable_host_offloads, reap_manifest_switches,
                             resolve_bmv2_launcher, verify_switches, write_manifest)


def fail(msg: str) -> None:
    print(f"Error: {msg}")
    sys.exit(1)


def main() -> None:
    setLogLevel('info')

    # Same preconditions as p4_testbed_topo.main, checked before anything is torn down.
    json_path = os.path.join(HERE, '../p4_src/build/ndtwin_switch.json')
    if not os.path.exists(json_path):
        fail(f"compiled P4 JSON not found at {json_path}; run p4c-bm2-ss in p4_src first")
    if not os.path.isdir(NTG_DIR):
        fail(f"NTG repo not found at {NTG_DIR} (override with the NTG_DIR env var)")
    try:
        import nornir  # noqa: F401  -- NTG's hard dependency; missing means wrong interpreter
    except ImportError:
        fail("this interpreter has no 'nornir'; run with the ntg-env python:\n"
             "  sudo /home/adam/miniconda3/envs/ntg-env/bin/python " + __file__)

    # Pre-flight the binary choice before anything is torn down: a broken override should
    # fail here, not after mn -c has already destroyed the running fabric.
    try:
        binary, lib_dir = resolve_bmv2_launcher()
    except ValueError as e:
        fail(str(e))
    print(f"bmv2 binary: {binary}" + (f"  (LD_LIBRARY_PATH={lib_dir})" if lib_dir else ""))

    # Reset exactly the way p4_testbed_topo.main does: mn -c does not touch bmv2, and an
    # orphaned switch holding its gRPC port kills this run's twin with "Address already in use".
    os.system('sudo mn -c > /dev/null 2>&1')
    os.system('sudo pkill -f simple_switch_grpc > /dev/null 2>&1')
    time.sleep(0.5)

    net = Mininet(topo=MultiSwitchTopo(), controller=None, autoSetMacs=True)
    net.start()

    # Static ARPs between the hosts, as the plain topology does.
    #
    # This was `range(1, 5)` and it is the fourth hard-coded four-host list in this fabric
    # (the others: the topology's own wiring and ARP loop, and the proxy's add_host table).
    # It is also the one that actually runs, because ndtwin-lab starts THIS script, not
    # p4_testbed_topo.py -- which imports cleanly and hides the difference, since the Topo
    # class does come from there. At 128 hosts every switch installs its 128 routes and the
    # paths are computed correctly, but nothing pings: the sender never learns the
    # destination MAC. Measured: adding the pair by hand takes h1 -> h33 from 100% loss to
    # 0% at 1.6 ms.
    #
    # Batched, but in chunks of 32 rather than one command per host. One command per host is
    # too long: all 127 entries in a single cmd() is ~4.4 kB and Mininet truncates it --
    # measured, h1 ended up with entries for h2..h112 and nothing after, and a partial ARP
    # table fails exactly like a broken data plane. 16256 individual cmd() calls is the other
    # extreme and takes minutes. Chunking is 4 calls per host.
    hosts = [net.get(f'h{i}') for i in range(1, _host_count_override() + 1)]
    for src in hosts:
        peers = [dst for dst in hosts if dst is not src]
        for i in range(0, len(peers), 32):
            src.cmd(" ; ".join(f"arp -s {d.IP()} {d.MAC()}" for d in peers[i:i + 32]))
    # Without this, bulk TCP stalls at zero through bmv2 -- see the helper's docstring.
    disable_host_offloads(hosts)

    switches = [net.get(f's{i}') for i in range(1, 11)]
    failures = verify_switches(switches)
    write_manifest(switches)

    print("\n======================================================================")
    if failures:
        print(f"WARNING: {len(failures)} of {len(switches)} BMv2 switches did NOT come up:")
        for name, reason in failures:
            print(f"  {name}: {reason}")
        print("Fix the cause and restart rather than generating traffic on a partial fabric.")
    else:
        print(f"All {len(switches)} BMv2 switches listening on gRPC 50051 ~ 50060.")
        print(f"Switch manifest: {MANIFEST_PATH}")
    print("Start the P4 proxy + kernel now (stack.sh up p4 answers its Mininet prompt),")
    print("then use the NTG prompt below. Low-rate template (the CLI needs the flag AND an")
    print("absolute path -- the cwd moves to NTG's repo before the prompt appears):")
    print(f"    flow --config {os.path.join(HERE, 'flow_bmv2_low.json')}")
    print("NTG cannot interrupt an experiment -- let flows finish.")
    print("======================================================================\n")

    # NTG resolves NTG.yaml -> ./setting/Mininet.yaml relative to its cwd.
    os.chdir(NTG_DIR)
    from network_traffic_generator import command_line
    try:
        # Crash armour, verified necessary live (2026-08-15): an uncaught exception inside
        # NTG's command loop -- e.g. a flow config that draws from an empty distance bucket
        # dies at randrange(0) in _handle_flow_command -- used to unwind straight through
        # here into the finally below, tearing down all ten switches because one command
        # went wrong. Print the crash, keep the fabric, and re-enter the CLI; only a real
        # exit (EOF/Ctrl-C/`exit`, which return instead of raising) reaches teardown.
        #
        # Re-entry needs two extra pieces, both learned from the armour's own first live
        # round: command_line is single-shot per process -- its logger_config calls
        # loguru's remove(0), and handler 0 only exists the first time, so a bare re-entry
        # dies at line 307 before reaching the prompt. The no-op patch below (our process's
        # copy of the module; NTG's file is untouched) makes re-entry real. And a crash
        # budget keeps a fault that fires before the input loop from spinning hot forever.
        crashes = 0
        while True:
            try:
                command_line(net, config_file_path=os.path.join(NTG_DIR, "NTG.yaml"))
                break
            except (KeyboardInterrupt, EOFError):
                break
            except Exception:
                import traceback
                traceback.print_exc()
                crashes += 1
                if crashes >= 5:
                    print("\n[ntg_bmv2_topo] NTG crashed 5 times; giving up and tearing down.\n")
                    break
                import network_traffic_generator as _ntg_mod
                _ntg_mod.logger_config = lambda *a, **k: None
                time.sleep(1)
                print("\n[ntg_bmv2_topo] NTG's command loop crashed (see traceback above). "
                      "The fabric is still up; returning to the NTG prompt.\n")
    finally:
        # p4_testbed_topo.main's teardown, verbatim: stop the net, then reap any switch the
        # power helper restarted (net.stop cannot address those) before the manifest goes.
        net.stop()
        reaped = reap_manifest_switches()
        if reaped:
            print(f"Reaped {len(reaped)} switch(es) that outlived the topology: "
                  f"{', '.join(reaped)}")
        try:
            os.remove(MANIFEST_PATH)
        except OSError:
            pass


if __name__ == '__main__':
    main()
