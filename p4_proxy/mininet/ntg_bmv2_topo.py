#!/usr/bin/env python3
"""
The bmv2 topology with NTG's CLI attached: the ~40 lines that were missing.

[Co-developed with claude code -- Adam]

NTG's Mininet mode must live in the process that owns the net (MininetCommunicator drives
hosts through `host.cmd`/`host.popen`), and its only shipped entry point builds an OVS
topology. This script is the P4-side twin of that entry point: it builds the same bmv2 fabric
as p4_testbed_topo.py -- reusing its pre-flight, its bring-up, its manifest and its teardown
wholesale -- and then hands the net to NTG's `command_line()` instead of Mininet's CLI.
Recorded as the pending feature `ntg-bmv2-support-pending-feature` on 2026-08-15; nothing in
NTG itself is modified.

🔴 "REUSING WHOLESALE" IS NOW TRUE AND WAS NOT. `ndtwin-lab topo-start` launches THIS file, not
p4_testbed_topo.py, so the code that ran on every single bring-up was this one -- and until
2026-09-18 everything below `MultiSwitchTopo` was a TRANSCRIBED COPY of p4_testbed_topo.main()
rather than a call to it. When the app-package work landed in that file, this copy kept its
literals: `ndtwin_switch.json` by hand, `grpc_port_block(range(1, 11))`, the all-pairs ARP with
no idea that a package brings its own host commands, and `[net.get(f's{i}') for i in range(1,
11)]`. The first live `ndt up p4 --app` therefore died at `net.get('s5')` on a four-switch
fabric, before write_manifest, with no try/finally -- so the process went, tmux reaped the
session, and the pane holding the traceback went with it. `ndt up` could only report "0/4
switches, manifest missing". Both of those are fixed here: ONE bring-up function in
p4_testbed_topo.py, called by both mains, and this script's output is tee'd to
`.test_run/logs/topo.log` so that the next time something dies there is something left to read.

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

from mininet.log import setLogLevel

# 🔴 AS A MODULE, not as a list of names. `from p4_testbed_topo import bring_up` binds a second
# name to one function and that is fine -- but it also makes every seam a test would patch live
# in two places at once, and "two places holding one answer" is the defect this file is being
# repaired for. One module object; every call site says where it came from.
import p4_testbed_topo as testbed  # noqa: E402
import topo_log  # noqa: E402


def fail(msg: str) -> None:
    print(f"Error: {msg}")
    sys.exit(1)


def run_ntg_cli(net) -> None:
    """NTG's command loop, with the crash armour that keeps a fabric alive through a bad flow.

    [Co-developed with claude code -- Adam]
    Verified necessary live (2026-08-15): an uncaught exception inside NTG's command loop --
    e.g. a flow config that draws from an empty distance bucket dies at randrange(0) in
    _handle_flow_command -- used to unwind straight through here into the caller's teardown,
    tearing down all ten switches because one command went wrong. Print the crash, keep the
    fabric, re-enter the CLI; only a real exit (EOF/Ctrl-C/`exit`, which return instead of
    raising) gets out of here.

    Re-entry needs two extra pieces, both learned from the armour's own first live round:
    command_line is single-shot per process -- its logger_config calls loguru's remove(0), and
    handler 0 only exists the first time, so a bare re-entry dies at line 307 before reaching
    the prompt. The no-op patch below (our process's copy of the module; NTG's file is
    untouched) makes re-entry real. And a crash budget keeps a fault that fires before the
    input loop from spinning hot forever.
    """
    # NTG resolves NTG.yaml -> ./setting/Mininet.yaml relative to its cwd.
    os.chdir(NTG_DIR)
    from network_traffic_generator import command_line

    crashes = 0
    while True:
        try:
            command_line(net, config_file_path=os.path.join(NTG_DIR, "NTG.yaml"))
            return
        except (KeyboardInterrupt, EOFError):
            return
        except Exception:
            import traceback
            traceback.print_exc()
            crashes += 1
            if crashes >= 5:
                print("\n[ntg_bmv2_topo] NTG crashed 5 times; giving up and tearing down.\n")
                return
            import network_traffic_generator as _ntg_mod
            _ntg_mod.logger_config = lambda *a, **k: None
            time.sleep(1)
            print("\n[ntg_bmv2_topo] NTG's command loop crashed (see traceback above). "
                  "The fabric is still up; returning to the NTG prompt.\n")


def main(tee=None, enter_cli=None) -> None:
    setLogLevel('info')

    # NTG's own two preconditions first. They describe this interpreter and this checkout, they
    # touch nothing, and "wrong python" is the failure an operator meets most often -- there is
    # no reason to read a package before saying it.
    if not os.path.isdir(NTG_DIR):
        fail(f"NTG repo not found at {NTG_DIR} (override with the NTG_DIR env var)")
    try:
        import nornir  # noqa: F401  -- NTG's hard dependency; missing means wrong interpreter
    except ImportError:
        fail("this interpreter has no 'nornir'; run with the ntg-env python:\n"
             "  sudo /home/adam/miniconda3/envs/ntg-env/bin/python " + __file__)

    # 🔴 THE SAME PRE-FLIGHT THE OTHER MAIN RUNS, not a copy of it: which package, which model,
    # which compiled JSON, which binary, and a gRPC port block for the switches THE MODEL
    # declares. All of it before `reset_for_bring_up` destroys anything.
    try:
        plan = testbed.plan_fabric()
    except (testbed.app_package.AppPackageError, testbed.topo_from_json.TopologyModelError,
            testbed.grpc_ports.PortBlockError, ValueError) as e:
        fail(str(e))

    testbed.reset_for_bring_up(plan.ports)

    net, switches, fatal, report, _host_setup = testbed.bring_up(
        plan.package, plan.model)
    ports = plan.ports

    print("\n======================================================================")
    if report:
        print(report)
    else:
        print(f"All {len(switches)} BMv2 switches listening on gRPC "
              f"{ports[0]} ~ {ports[-1]}.")
        print(f"Switch manifest: {testbed.MANIFEST_PATH}")
    if fatal:
        # This one mattered more than the topology script's: the next statement used to be
        # NTG's traffic generator, so the advice "do not generate traffic on a partial fabric"
        # was printed directly above the prompt that generates traffic on a partial fabric.
        print("======================================================================\n")
        testbed.tear_down(net)
        sys.exit(1)
    print("Start the P4 proxy + kernel now (stack.sh up p4 answers its Mininet prompt),")
    print("then use the NTG prompt below. Low-rate template (the CLI needs the flag AND an")
    print("absolute path -- the cwd moves to NTG's repo before the prompt appears):")
    print(f"    flow --config {os.path.join(HERE, 'flow_bmv2_low.json')}")
    print("NTG cannot interrupt an experiment -- let flows finish.")
    print("======================================================================\n")

    try:
        if tee is not None:
            # 🔴 THE TEE COMES OFF FOR THE PROMPT, and this is not a convenience. NTG's
            # command_line reaches prompt_toolkit's PromptSession, and prompt_toolkit's
            # create_output returns a PlainTextOutput the moment `sys.stdout.isatty()` is false
            # (output/defaults.py: "Stdout is not a TTY? Render as plain text."). A prompt
            # rendered as plain text into a pipe is not one `ndtwin-lab topo-cmd` can drive.
            # What is captured is the bring-up -- the part that fails and takes the pane with
            # it -- and the teardown; the interactive session is the operator's, on the pane.
            tee.note("[ntg_bmv2_topo] the NTG prompt needs the terminal itself, so output "
                     f"stops being copied to {tee.path} until teardown.")
            tee.stop()
        (enter_cli or run_ntg_cli)(net)
    finally:
        if tee is not None:
            tee.start()
        # p4_testbed_topo's teardown, which is now literally p4_testbed_topo's teardown: stop
        # the net, then reap any switch the power helper restarted (net.stop cannot address
        # those) before the manifest goes.
        testbed.tear_down(net)


def run(tee=None, main_=None) -> None:
    """Start the log, run main, and make sure a crash is written down somewhere that survives.

    [Co-developed with claude code -- Adam]
    The whole reason this wrapper exists: on 2026-09-18 this script died of a KeyError inside a
    root-owned tmux pane, tmux reaped the session on exit, and the traceback that named the
    line existed nowhere afterwards -- `ndtwin-lab topo-out` answered "no topo session" and
    `ndt up` could only print "look at the pane". The pane is not a record.
    """
    if tee is None:
        tee = topo_log.Tee(topo_log.default_path())
    # 🔴 BEFORE anything else can fail.
    tee.start()
    try:
        (main_ or main)(tee=tee)
    except SystemExit:
        # `fail()` already said why, on a stream the tee was copying. A traceback here would
        # only name the exit.
        raise
    except BaseException:
        tee.record_traceback()
        raise
    finally:
        tee.close()


if __name__ == '__main__':
    run()
