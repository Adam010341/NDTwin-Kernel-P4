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

    sudo $HOME/miniconda3/envs/ntg-env/bin/python ntg_bmv2_topo.py

Then, at the NTG prompt -- with the P4 stack's rates in mind. Measured 2026-08-15 on a
10-switch fabric with 1400 B UDP over the 3-hop path s1->s5->s2, the stock build (-O0, full
logging) delivered at most ~40-42 Mbps and the fast build ~460-530 Mbps. This fabric runs the
fast build by default (p4_proxy/mininet/bmv2_binary_override); the fast-build figure is for a
single flow. The low-rate template next to this script (its arriving flows ask for 2 and
4 Mbit/s, its three fixed flows 8 Mbit/s each) was written for the stock build; on the stock
build, use it rather than NTG's defaults:

    flow --config <your checkout>/p4_proxy/mininet/flow_bmv2_low.json

First thing to watch on a first live run: NTG's `link_relationship_init` computes its
near/middle/far distance partition against the kernel's host list. Its own topology has 128
hosts; this one has 4. That path has never run against a 4-host fabric -- if it misbehaves,
that is an NTG finding to record, not something to patch here.
"""

import os
import shutil
import sys
import tempfile
import time

# System Mininet for a conda interpreter, exactly the trick NTG's own testbed_topo.py uses.
sys.path.append('/usr/lib/python3/dist-packages')
sys.path.append('/usr/local/lib/python3/dist-packages')

# Sibling imports: the bmv2 topology pieces next to this file, and NTG's repo for its CLI.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(HERE)
# [Co-developed with claude code -- Adam]
# Where NTG is checked out. `ndtwin-lab topo-start` always sets this, from the NTG_DIR key of
# /etc/ndtwin-lab.conf (or its built-in default, which is the value below), because the
# environment of whoever ran `ndt up` never reaches a script started under sudo in root's tmux.
# The fallback is for a bridge started by hand.
NTG_DIR = os.environ.get("NTG_DIR", "/home/adam/Network-Traffic-Generator")
#: Where the value that `topo-start` passes in comes from, for the refusal below.
LAB_CONF = "/etc/ndtwin-lab.conf"
sys.path.append(NTG_DIR)

from mininet.log import setLogLevel

# 🔴 AS A MODULE, not as a list of names. `from p4_testbed_topo import bring_up` binds a second
# name to one function and that is fine -- but it also makes every seam a test would patch live
# in two places at once, and "two places holding one answer" is the defect this file is being
# repaired for. One module object; every call site says where it came from.
import p4_testbed_topo as testbed  # noqa: E402
import topo_log  # noqa: E402
# [Co-developed with claude code -- Adam] Which hosts file NTG gets; `ndt ntg` reads the same module.
import ntg_config  # noqa: E402


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
    # [Co-developed with claude code -- Adam] The config NTG starts with: the one main prepared
    # while its log was still being written (prepare_ntg_config), or, called on its own, one
    # prepared here. Whichever prepared it removes it.
    os.chdir(NTG_DIR)
    from network_traffic_generator import command_line

    tmp = None
    config = PREPARED_CONFIG
    try:
        if config is None:
            tmp, config = prepare_ntg_config()
        _ntg_loop(net, command_line, config)
    finally:
        drop_ntg_config(tmp)


#: The config main prepared for run_ntg_cli, or None when nothing was prepared.
PREPARED_CONFIG = None


def prepare_ntg_config():
    """(temp dir or None, the config to hand NTG), with the operator's note printed.

    [Co-developed with claude code -- Adam]
    NTG resolves the hosts file its config names relative to its cwd (NTG_DIR). Which config:
    NTG.yaml, unless the hosts file it names has no Mininet_Testbed entry -- NTG as shipped
    names setting/Hardware.yaml -- in which case NTG would drive remote worker nodes instead of
    this net. ntg_config then writes a temp copy naming setting/Mininet.yaml; the checkout is
    not edited, and `ndt ntg` reports and edits that same file.

    🔴 NOTHING HERE MAY KEEP NTG FROM STARTING. A temp dir that cannot be made, or a config
    this cannot read, falls back to NTG.yaml as it is, and the note says so.
    """
    tmp = None
    try:
        try:
            tmp = tempfile.mkdtemp(prefix="ndtwin-ntg-")
            config, note = ntg_config.config_for_bridge(NTG_DIR, tmp)
        except Exception as e:   # the bridge must still reach NTG; NTG's own config is the fallback
            config = os.path.join(NTG_DIR, "NTG.yaml")
            note = f"[ntg_bmv2_topo] ntg_config failed ({e!r}); NTG gets {config} as it is."
        if note:
            print(note)
    except BaseException:
        # Anything after mkdtemp that ends this call -- a print to a broken stdout, the teardown
        # signal's SystemExit -- would leave the caller without the path to remove.
        drop_ntg_config(tmp)
        raise
    return tmp, config


def drop_ntg_config(tmp) -> None:
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)


def _ntg_loop(net, command_line, config) -> None:
    crashes = 0
    while True:
        try:
            command_line(net, config_file_path=config)
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
        # [Co-developed with claude code -- Adam] Names the config key, not an environment
        # variable: under `ndt up` the environment is not something the operator can reach.
        fail(f"NTG repo not found at {NTG_DIR}. Set NTG_DIR in {LAB_CONF} to your "
             "Network-Traffic-Generator checkout; `sudo ndtwin-lab config` shows the value "
             "topo-start passes in. That needs /usr/local/sbin/ndtwin-lab installed from this "
             "checkout (`ndt status` compares them); an older one refuses the whole file on that "
             "key.")
    try:
        import nornir  # noqa: F401  -- NTG's hard dependency; missing means wrong interpreter
    except ImportError:
        fail("this interpreter has no 'nornir'; run with the ntg-env python:\n"
             "  sudo $HOME/miniconda3/envs/ntg-env/bin/python " + __file__)

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
        plan.package, plan.model, grpc_host=plan.bmv2_host)
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

    # 🔴 THE SAME HANDLERS THE OTHER MAIN INSTALLS, from the same function. This
    # file already had the `try/finally` the topology script was missing, so the SIGHUP that
    # `ndtwin-lab topo-stop` sends ten seconds after its C-c still killed python outright --
    # a `finally` is not reached by a default-disposition signal. This is the entry point
    # `topo-start` actually launches, so it is the one where that mattered every night.
    testbed.install_teardown_signal_handlers()

    global PREPARED_CONFIG
    tmp = None
    try:
        if enter_cli is None:
            # [Co-developed with claude code -- Adam] Decided, and its note printed, while the
            # tee still copies output to topo.log, so the log records which config NTG got.
            tmp, PREPARED_CONFIG = prepare_ntg_config()
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
        PREPARED_CONFIG = None
        drop_ntg_config(tmp)
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
