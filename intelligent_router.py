from ryu.base import app_manager
from ryu.controller import ofp_event
from ryu.controller.handler import CONFIG_DISPATCHER, MAIN_DISPATCHER, DEAD_DISPATCHER
from ryu.controller.handler import set_ev_cls
from ryu.ofproto import ofproto_v1_3
from ryu.topology import event, switches
from ryu.topology.api import get_switch, get_link, get_all_host
from ryu.lib.packet import packet, ethernet, ipv4, ether_types, arp, tcp, udp, icmp
import networkx as nx
from ryu.controller import dpset
import requests
import json
from ryu.app.wsgi import ControllerBase, WSGIApplication, route
from webob import Response
from time import time, monotonic
import ipaddress
import hashlib
import os
from pathlib import Path
import threading
import random
from ryu.lib import hub

# TODO: Change it
# (1) Static topology JSON path (update to your local file path)
#
# [Co-developed with claude code -- Adam]
# Overridable via NDTWIN_RYU_TOPO_FILE; the default is unchanged, so the normal OVS round
# behaves exactly as before. This has to be settable because the kernel takes its model from
# --topology while this file took its own from a module-level constant, and nothing checked
# that the two agreed. Run them against different models and the failure is silent and
# confusing: Ryu installs routes for the hosts *its* file declares, so on 2026-08-17 a
# 10-switch/4-host fabric got s1 rules reading `nw_dst=10.0.0.2 actions=output:4` -- port 4
# does not exist on that s1, every host pair was 100% loss, and both Ryu's topology view and
# the kernel's graph reported ten switches, forty edges, all up and enabled.
static_topology_file_path = Path(os.environ.get(
    "NDTWIN_RYU_TOPO_FILE",
    "/home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json"))

# (2) Deployment mode
# [Co-developed with claude code -- Adam]
# ⚠️ EDITING THIS LINE DOES NOTHING. `is_mininet` is unconditionally reassigned to True further
# down in this same module-level block (search for the second `is_mininet = True`), so whatever
# you set here is overwritten before anything reads it. It reads as configuration and behaves as a
# constant.
#
# What it would control if it worked: exactly one thing, `if is_mininet: hub.sleep(60)` at the end
# of `load_static_topology` -- a settle delay before the all-destination route walk. A
# physical-testbed operator who flips this line still waits the 60 s.
#
# Both assignments date to the original import (6f32bca) and neither carries a reason, so the
# override was left in place rather than deleted: making the knob live would change startup timing
# for a testbed deployment, and nothing here records whether the second assignment was a deliberate
# "always settle" or an editing accident. To actually change the behaviour today, edit the second
# assignment or the `if is_mininet:` guard, and decide the question this comment cannot.
is_mininet = True   # True: Mininet, False: physical testbed -- SEE ABOVE, this value is discarded

RYU_SERVER_INSTANCE_NAME = "ndt_ryu_app"


# [Co-developed with claude code -- Adam]
# How many switches must be online before the initial all-pair route walk runs, and which dpids
# the topology says exist. These are two different questions and used to be one constant:
#
#   how many switches are INSTALLED       -- the topology file answers this
#   how many are EXPECTED ONLINE  today   -- what this gate must actually compare against
#
# They are equal only when nothing is deliberately powered off. A site that leaves four of ten
# switches unpowered got `len(self.switches) >= 10` forever false, and since load_static_topology
# is the *only* trigger for the initial install, **no route was ever installed** -- with every
# switch that was up reporting healthy and both topology views correct. The gate itself is right
# for a site that does bring everything up; the fixed 10 is what was wrong.
#
# Order: NDTWIN_RYU_SWITCH_NUM (the deployment's own answer) -> the switch count in the topology
# file -> 10. Setting the variable is how a site with switches off says so.
def _expected_switches(path):
    """(count, sorted dpids) of the switches the topology file declares. ([], 0) if unreadable."""
    try:
        with open(path) as fh:
            topo = json.load(fh)
    except (OSError, ValueError):
        return 0, []
    dpids = sorted(
        int(n["dpid"]) for n in topo.get("nodes", [])
        if n and n.get("vertex_type") == 0 and n.get("dpid")
    )
    return len(dpids), dpids


_declared_count, expected_switch_dpids = _expected_switches(static_topology_file_path)

_env_switch_num = os.environ.get("NDTWIN_RYU_SWITCH_NUM")
if _env_switch_num and _env_switch_num.isdigit() and int(_env_switch_num) > 0:
    switch_num = int(_env_switch_num)
    _switch_num_source = "NDTWIN_RYU_SWITCH_NUM"
elif _declared_count:
    switch_num = _declared_count
    _switch_num_source = f"topology file ({static_topology_file_path.name})"
else:
    switch_num = 10
    _switch_num_source = "built-in default (topology file unreadable)"

# [Co-developed with claude code -- Adam]
# How long to wait for the full set before installing routes for whatever *is* online.
#
# Fail-open, deliberately: partial routing beats no routing. The previous behaviour was to wait
# forever and say so once, which is indistinguishable from a healthy fabric that is simply still
# converging -- and it stays that way for the life of the process. Same judgement already made
# for initial_install_wait_limit below ("on expiry it proceeds rather than giving up ... then
# there are no routes at all").
#
# Generous because the legitimate wait is long: the host-discovery gate above plus the walk
# itself. Both are measured -- the settle wait is NDTWIN_RYU_SETTLE_S (default 40, and measured
# to run its full length every time), the walk is 0.25s at 128 hosts (doc/audit/
# 2026-08-21_ryu-topology-scaling/WALK_SWEEP.md) -- so 300s has room even for a gate that runs
# its deadline out, and a switch that is merely slow to dial in must not trip this.
initial_install_deadline = int(os.environ.get("NDTWIN_RYU_INITIAL_INSTALL_DEADLINE", "300"))

# [Co-developed with claude code -- Adam]
# CEILING on the wait before walking all host pairs -- no longer a fixed sleep. See
# _await_host_discovery below for what is actually being waited for.
#
# History, because the two rewrites of this value are the whole lesson:
#
#   1. It began as a bare, undocumented `hub.sleep(60)`. Nothing recorded what it waited for.
#   2. 2026-08-21 it became NDTWIN_RYU_SETTLE_S, default 10, on the grounds that the switch-count
#      gate above already guarantees every switch has connected and 3 s forwarded 3/3. That was
#      measured honestly and it was still wrong, because it measured the wrong thing: the data
#      plane forwards fine at 3 s. What breaks is the TWIN'S VIEW of it.
#   3. Same day, measured with one variable changed and everything else held:
#
#        NDTWIN_RYU_SETTLE_S=60 -> Ryu knows 128/128 host IPv4s -> kernel graph 288 up / 0 down
#        NDTWIN_RYU_SETTLE_S=10 -> Ryu knows   0/128            -> kernel graph  32 up / 256 down
#
#      Mechanism: Ryu learns a host's IPv4 only from packet-in (ryu/topology/switches.py:877-885,
#      inside a packet-in handler). testbed_topo.py pings all 128 hosts right after building them.
#      Install the all-pairs rules BEFORE that burst and every ICMP packet matches a rule, is
#      forwarded in the data plane, and never reaches the controller -- so Ryu never learns the
#      address, the kernel skips every host at TopologyAndFlowMonitor.cpp:618, and all 256 host
#      edges keep their initial down state. IPv6 link-local has no rules, still misses the table,
#      and is learned: exactly the ipv4=[] / ipv6=[...] asymmetry that showed up in the API.
#
# So the sleep length was silently deciding whether the digital twin could see its own hosts.
# A fixed number cannot be right here -- it is a race, and the fix is to wait for the event
# rather than to guess how long the event takes. This value is now the deadline for that wait,
# not the wait itself; a healthy 128-host fabric exits it early.
#
# 0 disables the wait entirely, as before.
#
# !! READ THIS BEFORE TRUSTING THE WORD "GATE" ABOVE !!
#
# Measured 2026-08-22, two deadlines, everything else held
# (doc/audit/2026-08-22_settle-gate-acceptance/):
#
#     deadline  90s -> gate read 0/128 for the whole  90s, boot 101s, final 128/128, 288 up/0 down
#     deadline 180s -> gate read 0/128 for the whole 180s, boot 191s, final 128/128, 288 up/0 down
#
# The gate has never once observed the event it waits for. Its reading is not blind: an external
# poller on /v1.0/topology/hosts, sampling every 2 s through the same boot, agrees with it
# exactly -- 0 hosts with an IPv4 from t+6s until the very end, then 128 in a single step. Both
# readers are right. There is simply nothing to see while the gate is waiting.
#
# And the learning time TRACKS THE DEADLINE. If the burst landed at a fixed t+96s, the 180s run
# would have seen it and exited early at 96s. It did not. Hosts are learned just after the gate
# releases, whenever that is. So this is not a gate; it is a fixed sleep with a poll loop
# attached, and boot time is base + deadline.
#
# **The mechanism behind "learning follows the release" is NOT established.** Candidates not yet
# discriminated: this handler stalling its own app's event queue (it blocks inside an
# EventSwitchEnter handler, and Ryu dispatches one app's events serially); switches without a
# table-miss entry dropping the burst instead of punting it; the burst being serialised behind
# fabric bring-up. Do not write any of those down as the reason -- none has been tested.
#
# The default is 40, chosen off a measured curve rather than off margin-on-a-guess. Every cell
# is a full 128-host boot, both sides read at t+0 and again 20 s later
# (doc/audit/2026-08-22_settle-gate-acceptance/settle_bisect.txt):
#
#     settle   boot    Ryu     kernel graph      verdict
#        5      16s    0/128   288e / 256 down   BLIND
#       10      20s    0/128   288e / 256 down   BLIND   (twice)
#       15      27s    128     288e /   0 down   ok
#       20      31s    128     288e /   0 down   ok
#       30      41s    128     288e /   0 down   ok
#       40      51s    128     288e /   0 down   ok      (three times)
#       55      66s    128     288e /   0 down   ok
#       90     100s    128     288e /   0 down   ok      (three times)
#
# The cliff is between 10 and 15, and it is a cliff, not a slope: either every host is learned
# or none is. 40 sits 4x above the highest failing value and ~2.7x above the cliff's upper
# bound, with n=3 at 52 s. That is faster than the 73 s the settle=60 era cost AND correct,
# which is why the deck's OVS number improves rather than regresses.
#
# Margin is worth paying for here specifically because the failure is silent and total: the
# fabric forwards perfectly, every ping passes, and the twin simply cannot see 256 of its own
# 288 links. Nothing in the boot output says so. A slower machine or a larger fabric moves the
# cliff and nothing would announce it -- so do not tune this down toward 15 to save 25 seconds.
settle_seconds = int(os.environ.get("NDTWIN_RYU_SETTLE_S", "40"))

# [Co-developed with claude code -- Adam]
# Run load_static_topology in a spawned greenlet instead of inline in the EventSwitchEnter
# handler. See the call site for why that matters (bounded per-app event queue + this app also
# observing EventOFPPacketIn = the queue-fill cycle behind the 6-of-10 boot failures).
# Default off until the mechanism is confirmed and the async path measured -- see the call site
# for the exact test that would justify flipping it.
#: How long a single host-table read may block before it is treated as "nothing learned".
#: Not a tuning knob -- it is the thing that makes _await_host_discovery's deadline enforceable
#: at all. See _hosts_with_ipv4 for the wedge this was caught in. A few seconds is generous for
#: an in-process request-reply; anything longer means the answering app is in trouble, which is
#: exactly what the caller needs to stop waiting on. [Co-developed with claude code -- Adam]
HOST_QUERY_TIMEOUT_S = float(os.environ.get("NDTWIN_RYU_HOST_QUERY_TIMEOUT_S", "5"))

#: The same protection for the OTHER two topology reads, which are the ones actually caught
#: holding the ring. [Co-developed with claude code -- Adam]
#:
#: HOST_QUERY_TIMEOUT_S above bounds get_all_host. It was the third of three untimed
#: request-reply calls reachable from the EventSwitchEnter handler, and bounding it moved the
#: wedge to the other two rather than ending it: measured 2026-08-25, both ring-fix arms wedged
#: with the event loop parked in get_switch or get_link, never in the bounded host read
#: (doc/audit/2026-08-25_ring-edge-fix/). These two calls sit EARLIER in the same handler than
#: the async spawn does, so 72fbae6 could not help them either.
#:
#: TOPO_DEADLINE_S replaces a literal 20 that could not be enforced. The old loop re-checked
#: `time() - start < 20` between iterations, so a single call that never returned was never
#: "between iterations" and the bound never fired -- the same defect, in the same file, that
#: _await_host_discovery had. The per-call timeout is now the SMALLER of the query timeout and
#: the budget left, which is what makes the deadline mean what it says.
TOPO_QUERY_TIMEOUT_S = float(os.environ.get("NDTWIN_RYU_TOPO_QUERY_TIMEOUT_S", "5"))
TOPO_DEADLINE_S = float(os.environ.get("NDTWIN_RYU_TOPO_DEADLINE_S", "20"))

# [Co-developed with claude code -- Adam]
# 2026-08-25: default flipped OFF -> ON (Adam's ruling). Set the variable to "0" to opt out.
#
# THE ONLY EVIDENCE FOR THIS FLIP IS BOOT TIME: wall 26s vs 52s, n=10 per arm, single variable,
# same machine and evening, on an IDLE machine, with the banner below asserted present on all
# ten async boots (doc/audit/2026-08-24_boot-ring-verify/).
#
# 🔴 IT IS NOT A FIX FOR THE BOOT RING, and this must not drift into being described as one.
# It was tested against a live reproducing ring on 2026-08-25 and WEDGED TWICE with the flag
# asserted active (doc/audit/2026-08-25_ring-fix-verify/). Two counterexamples are on record.
# The ring survives this fix and d1d973d individually; §5-P's "cut any one edge and the ring
# cannot close" is refuted by measurement.
#
# Also unmeasured, so also not claimable: whether the 26s holds under CPU load, and whether this
# helps or hurts the separate post-install host-learning failure.
_async_topology_install = os.environ.get("NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL", "1") == "1"
if _async_topology_install:
    # The leading sentence is stable ON PURPOSE: harnesses grep it to assert the flag actually
    # reached Ryu (doc/audit/2026-08-24_boot-ring-verify, .../2026-08-25_ring-fix-verify). Do not
    # reword it without updating those. The parenthetical now distinguishes default-on from
    # explicitly-on -- it used to print "=1" unconditionally, which became a lie the moment the
    # default flipped, and an assertion that reads a lie is worse than no assertion.
    _how = "explicitly set" if os.environ.get("NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL") else "default since 2026-08-25"
    print("NDTWIN: load_static_topology will run OFF the event handler "
          f"(NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL, {_how}; set 0 to opt out)", flush=True)
else:
    print("NDTWIN: load_static_topology runs INSIDE the event handler "
          "(NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL=0)", flush=True)

detecting_time = 60


# ---------------------------------------------------------------------------------------------
# SIGUSR2 -> dump every greenlet's stack. [Co-developed with claude code -- Adam]
#
# Built for one specific open question and kept because the answer needs re-checking after any
# fix: on 2026-08-24 six of ten default OVS boots wedged with LLDP link discovery producing
# nothing at all, and py-spy could not name the culprit. Two dumps of a wedged Ryu ten seconds
# apart were byte-identical -- one thread, parked in eventlet's epoll, no runnable greenlet
# (doc/audit/2026-08-24_full-stack-run/REPORT.md). That rules out any busy-spin, and it is where
# py-spy stops being useful: it reads THREAD stacks, and a parked greenlet's frames live on the
# heap, not on any thread.
#
# The surviving hypothesis is a queue cycle -- each Ryu app has a bounded hub.Queue(128), a put
# into a full queue blocks the emitter, and blocking work inside an EventSwitchEnter handler
# lets LLDP packet-ins fill that app's queue until the Switches app's own emitter blocks and
# stops draining its queue, where LLDP processing lives. It survived its falsification attempt
# but stays INFERRED, because nothing so far can see the parked frames.
#
# This is what sees them. Sending SIGUSR2 walks the heap for greenlet objects and writes each
# one's stack, so a wedged process can say where every coroutine is parked. If the hypothesis is
# right, the dump shows a datapath greenlet inside a queue `put`; if it shows something else,
# the hypothesis dies and that is worth just as much.
#
# Three deliberate choices:
#   * Inert until signalled, so installing it changes nothing about a normal run.
#   * Every step wrapped -- a diagnostic that can crash the control plane it is diagnosing is
#     worse than no diagnostic. Failures here degrade to a line in the log.
#   * Appends rather than truncates, and stamps each dump, so two dumps taken seconds apart can
#     be diffed the way the py-spy pair was -- "identical" was itself the finding that ruled out
#     busy-spin.
GREENLET_DUMP_PATH = os.environ.get("NDTWIN_RYU_GREENLET_DUMP",
                                    "/tmp/ndtwin_ryu_greenlets.txt")


#: Set by IntelligentRyu.__init__ so the SIGUSR2 dump can read the topology worker's heartbeat.
#: A plain module global rather than anything cleverer: there is exactly one instance of this app
#: per process, and the dump must work even when the app is wedged. [Co-developed with claude code -- Adam]
_APP_FOR_DUMP = None


def _dump_greenlets(signum=None, frame=None):
    """Write every live greenlet's parked stack to GREENLET_DUMP_PATH."""
    try:
        import gc
        import traceback
        import greenlet as _greenlet
        from datetime import datetime

        lines = ["", "=" * 78,
                 f"greenlet dump  pid={os.getpid()}  at={datetime.now().isoformat(timespec='seconds')}",
                 "=" * 78]
        found = 0
        for obj in gc.get_objects():
            try:
                if not isinstance(obj, _greenlet.greenlet):
                    continue
            except Exception:            # isinstance can trip on odd heap objects
                continue
            found += 1
            try:
                state = ("dead" if obj.dead
                         else "current" if obj is _greenlet.getcurrent()
                         else "parked")
                lines.append(f"\n--- greenlet {hex(id(obj))}  state={state}"
                             f"  parent={hex(id(obj.parent)) if obj.parent else 'none'}")
                gr_frame = getattr(obj, "gr_frame", None)
                if gr_frame is None:
                    lines.append("    (no frame -- not started, or dead)")
                else:
                    # The frames of a PARKED greenlet: exactly what py-spy cannot reach.
                    lines.extend("    " + ln.rstrip()
                                 for ln in traceback.format_stack(gr_frame))
            except Exception as exc:     # noqa: BLE001 -- one bad greenlet must not stop the dump
                lines.append(f"    (unreadable: {exc!r})")
        lines.append(f"\n{found} greenlet object(s) on the heap")

        # [Co-developed with claude code -- Adam]
        # Per-app event queue depth, and who is blocked trying to write to it.
        #
        # The stacks above show a greenlet parked in `_send_event -> _events_sem.acquire()`, but
        # NOT which app's queue it is blocking on: `send_event_to_observers` loops over observers
        # and the observer name is not in the frame. Every wedge dump so far has had to close that
        # gap by elimination -- "the only event loop that is parked is IntelligentRyu's, so its
        # queue must be the full one" -- which is an inference, not an observation.
        #
        # These two numbers make it an observation:
        #   qsize/maxsize  -- a queue AT maxsize is the one emitters are blocking on.
        #   sem balance    -- eventlet's Semaphore.balance is counter minus waiters, so a NEGATIVE
        #                     balance names the app whose queue has blocked emitters waiting, and
        #                     its magnitude counts them.
        # A ring is then readable directly off the dump: app X's queue full with N waiters, while
        # X's own event loop is parked in a request-reply to app Y.
        #
        # Same three rules as the dump above: inert until signalled, every step wrapped, appended.
        # [Co-developed with claude code -- Adam]
        # Topology worker heartbeat. Moving the rebuild off the event loop removes the wedge and
        # buys a quieter failure in its place: a worker that stops rebuilding reports nothing,
        # where a wedge at least hung the boot visibly. These four numbers are what makes that
        # detectable -- rebuilds that never advance, or a last_start with no matching last_ok,
        # is a stalled worker, and the stack above says where it stalled.
        try:
            _app = _APP_FOR_DUMP
            if _app is not None:
                _now = time()
                def _ago(t):
                    return "never" if t is None else f"{_now - t:.1f}s ago"
                lines.append("\n--- topology worker heartbeat ---")
                lines.append(f"    rebuilds={_app._topology_rebuilds}"
                             f"  coalesced={_app._topology_coalesced}"
                             f"  pending_dpids={sorted(_app._pending_switch_dpids)}")
                lines.append(f"    last_start={_ago(_app._topology_last_start)}"
                             f"  last_ok={_ago(_app._topology_last_ok)}"
                             f"  dirty={_app._topology_dirty.is_set()}")
                # Arrival rate and the fill time it implies. t_fill is what a BLOCKED loop would
                # take to overflow 128 slots at this rate -- the pre-B question, answered by
                # arithmetic on a measured rate rather than by a failure-rate A/B that B made
                # impossible to run.
                _pc = _app._pktin_count
                _pt = _app._pktin_first_t
                if _pt is not None and _now > _pt:
                    _rate = _pc / (_now - _pt)
                    _fill = (128.0 / _rate) if _rate > 0 else float("inf")
                    lines.append(f"    packet_in={_pc} over {_now - _pt:.1f}s"
                                 f"  rate={_rate:.2f}/s  t_fill(128 slots)={_fill:.1f}s")
                else:
                    lines.append(f"    packet_in={_pc}  rate=n/a (none yet)")
                if (_app._topology_last_start is not None
                        and (_app._topology_last_ok is None
                             or _app._topology_last_ok < _app._topology_last_start)):
                    lines.append("    <== a rebuild STARTED and has not finished: worker is in it now")
        except Exception as exc:             # noqa: BLE001
            lines.append(f"--- topology worker heartbeat unavailable: {exc!r}")

        try:
            from ryu.base.app_manager import SERVICE_BRICKS
            lines.append("\n--- app event queues (qsize/maxsize, sem balance) ---")
            for _name, _brick in sorted(SERVICE_BRICKS.items()):
                try:
                    _q = getattr(_brick, "events", None)
                    _sem = getattr(_brick, "_events_sem", None)
                    _qs = _q.qsize() if _q is not None else "?"
                    _mx = getattr(_q, "maxsize", "?") if _q is not None else "?"
                    _bal = getattr(_sem, "balance", "?") if _sem is not None else "?"
                    _flag = ""
                    if isinstance(_bal, int) and _bal < 0:
                        _flag = f"   <== {-_bal} emitter(s) BLOCKED writing to this queue"
                    elif _qs == _mx:
                        _flag = "   <== FULL"
                    lines.append(f"    {_name:<28} {_qs}/{_mx}  balance={_bal}{_flag}")
                except Exception as exc:     # noqa: BLE001 -- one bad brick must not stop the dump
                    lines.append(f"    {_name:<28} (unreadable: {exc!r})")
        except Exception as exc:             # noqa: BLE001
            lines.append(f"--- app event queues unavailable: {exc!r}")

        with open(GREENLET_DUMP_PATH, "a") as fh:
            fh.write("\n".join(lines) + "\n")
    except Exception as exc:             # noqa: BLE001 -- never let the diagnostic kill Ryu
        try:
            print(f"NDTWIN: greenlet dump failed: {exc!r}", flush=True)
        except Exception:
            pass


def _install_greenlet_dump_handler():
    try:
        import signal
        signal.signal(signal.SIGUSR2, _dump_greenlets)
        print(f"NDTWIN: SIGUSR2 dumps greenlet stacks to {GREENLET_DUMP_PATH} "
              f"(kill -USR2 <ryu pid>)", flush=True)
    except Exception as exc:             # noqa: BLE001
        print(f"NDTWIN: could not install SIGUSR2 greenlet dump: {exc!r}", flush=True)


_install_greenlet_dump_handler()

# [Co-developed with claude code -- Adam]
# How long Ryu's link discovery waits between two LLDP sends, in seconds. Ryu's default is
# 0.05 and it is the single largest term in OVS failover.
#
# `Switches.lldp_loop` walks every port it knows and sleeps this long after each send, so the
# interval between two sends to the SAME port is ports x guard -- and `link_loop` will not
# declare a link down until LINK_LLDP_DROP=5 consecutive sends have gone unanswered. Detection
# therefore costs about six sweeps, and a sweep is charged for every port including the
# host-facing ones, which discover nothing because nothing on a host answers LLDP.
#
# Measured 2026-08-21, injecting netem loss 100% into an inter-switch link:
#
#   4 hosts    36 ports   detection 13.1 s   of a 15.70 s outage   (84%)
#   128 hosts  160 ports  detection 44.9 s   of a 51.75 s outage   (87%)
#
# So a fabric that adds hosts slows down its own failure detection, with the switch topology
# unchanged. P4 does not have this shape: its proxy beacons on a fixed interval that does not
# depend on port count, which is why 4 -> 128 hosts costs OVS 3.30x and P4 only 1.21x.
#
# Left at Ryu's default unless the environment says otherwise, because lowering it raises the
# LLDP packet rate on the control channel (at 160 ports, 0.05 -> 0.01 takes it from 20 to 100
# packets/s) and that trade has not been measured at scale. Set the variable to try it.
#
# The override announces itself. This repo has shipped a flag whose setter was committed and
# whose reader never existed, and a reader with no setter anywhere -- both produced runs that
# looked like they had been configured and had not. A run that cannot show the line below in
# its Ryu log was not using the knob, whatever the command line said.
# [Co-developed with claude code -- Adam]
# 2026-08-25: 0.01 is now the DEFAULT rather than an opt-in override (Adam's ruling).
#
# Evidence for the value, and only this evidence: the loaded false-positive study measured
# ZERO false positives across all six cells (doc/audit/2026-08-22_loaded-fp-study/), and the
# detection speed-up was 3.9x. Nothing here bears on the boot ring or on settle -- those are
# separate open defects and this knob is not a fix for either.
#
# Ryu's own default is 0.05. At 160 ports the packet rate on the control channel goes from
# 20/s to 100/s, which is the cost being accepted for the 3.9x.
NDTWIN_LLDP_GUARD_DEFAULT = 0.01
switches.Switches.LLDP_SEND_GUARD = NDTWIN_LLDP_GUARD_DEFAULT
print(f"NDTWIN: LLDP_SEND_GUARD default is {NDTWIN_LLDP_GUARD_DEFAULT}s "
      f"(Ryu ships 0.05; override with NDTWIN_RYU_LLDP_GUARD)", flush=True)

_lldp_guard = os.environ.get("NDTWIN_RYU_LLDP_GUARD")
if _lldp_guard:
    try:
        switches.Switches.LLDP_SEND_GUARD = float(_lldp_guard)
        print(f"NDTWIN: LLDP_SEND_GUARD overridden to "
              f"{switches.Switches.LLDP_SEND_GUARD}s (default {NDTWIN_LLDP_GUARD_DEFAULT})", flush=True)
    except ValueError:
        # A malformed value keeps the default rather than crashing the control plane -- but
        # says so, because silently falling back is how a measurement gets mislabelled.
        print(f"NDTWIN: ignoring malformed NDTWIN_RYU_LLDP_GUARD={_lldp_guard!r}; "
              f"keeping {switches.Switches.LLDP_SEND_GUARD}s", flush=True)

# [Co-developed with claude code -- Adam]
# Probe ports that have never answered an LLDP only every Nth sweep, instead of every sweep.
#
# The detection numbers above are charged per port, and on the 128-host fabric 128 of the 160
# ports are host-facing: nothing on a host answers LLDP, so probing them buys nothing and costs
# a guard-sleep each, every sweep, forever. One bit tells the two kinds of silent port apart --
# a failed sw-sw port HAS answered before, a host port never has. Backing off never-answered
# ports makes sweep cost track switch count rather than host count, without touching the guard
# (packet rate on the control channel stays put) and without touching `link_loop`'s six-missed-
# probes threshold: a never-answered port cannot be the source of any link in `self.links`, so
# the evidence chain for declaring a real link dead is exactly Ryu's. That distinction is the
# whole justification -- LINK_LLDP_DROP could reach the same speedup, but only by lowering the
# evidence needed to kill a link, and topology_manager.py argues itself why flappy link reports
# are worse than slow ones. The price is discovery, not detection: a newly cabled or healed
# port is noticed up to N sweeps late.
#
# Off unless the environment says otherwise: the false-positive rate of faster detection has
# not been measured, and that measurement is the gate for changing any default here.
_lldp_backoff = os.environ.get("NDTWIN_RYU_LLDP_BACKOFF")
if _lldp_backoff:
    try:
        _backoff_n = int(_lldp_backoff)
        if _backoff_n < 2:
            raise ValueError
    except ValueError:
        print(f"NDTWIN: ignoring malformed NDTWIN_RYU_LLDP_BACKOFF={_lldp_backoff!r} "
              f"(want an integer >= 2); probing every port every sweep as Ryu does", flush=True)
    else:
        # The answered-bit rides on PortData via the one call that means "an LLDP sent out of
        # this port came back": lldp_packet_in_handler -> PortDataState.lldp_received(src).
        _ryu_lldp_received = switches.PortDataState.lldp_received

        def _lldp_received_marking(self, port):
            self[port].ever_received = True
            _ryu_lldp_received(self, port)

        switches.PortDataState.lldp_received = _lldp_received_marking

        def _lldp_loop_with_backoff(self):
            # Ryu's Switches.lldp_loop with one change: due ports that have never answered are
            # "sent" by advancing their clock (ports.lldp_sent moves them to the back of the
            # sweep order, same as a real send would) without a packet-out or a guard-sleep,
            # except on every Nth pass. Everything else -- the ordered expiry scan, the
            # timestamp-None fast path for new ports, the wait arithmetic -- is verbatim,
            # because the scan's early `break` assumes one shared period and list order by
            # timestamp, and a second period would silently break that assumption.
            tick = 0
            while self.is_active:
                self.lldp_event.clear()
                tick += 1

                now = time()
                timeout = None
                ports_now = []
                ports = []
                for (key, data) in self.ports.items():
                    if data.timestamp is None:
                        ports_now.append(key)
                        continue

                    expire = data.timestamp + self.LLDP_SEND_PERIOD_PER_PORT
                    if expire <= now:
                        ports.append((key, data))
                        continue

                    timeout = expire - now
                    break

                for port in ports_now:
                    self.send_lldp_packet(port)
                for port, data in ports:
                    if getattr(data, "ever_received", False) or tick % _backoff_n == 0:
                        self.send_lldp_packet(port)
                        hub.sleep(self.LLDP_SEND_GUARD)      # don't burst
                    else:
                        try:
                            self.ports.lldp_sent(port)
                        except KeyError:
                            # same race send_lldp_packet tolerates: ports can be
                            # modified while this loop runs
                            pass

                if timeout is not None and ports:
                    timeout = 0     # We have already slept
                self.lldp_event.wait(timeout=timeout)

        switches.Switches.lldp_loop = _lldp_loop_with_backoff
        print(f"NDTWIN: LLDP backoff enabled: never-answered ports probed every "
              f"{_backoff_n}th sweep (default: every port, every sweep)", flush=True)

# [Co-developed with claude code -- Adam]
# How long the topology must be quiet before routes are recomputed. One `link a b down` raises an
# EventLinkDelete per direction, and a switch joining raises a burst, so recomputing on each event
# would repeat the whole 16256-pair walk several times for one operator action. 3s is well past the
# gap between the paired events while still recovering promptly.
reinstall_quiet_period = 3

# [Co-developed with claude code -- Adam]
# How long the reinstall worker will wait for the *initial* install before recomputing anyway. The
# initial walk is ~60s on the 128-host topology and is preceded by a 60s settle sleep in Mininet
# mode, so this has to clear both with room to spare. On expiry it proceeds rather than giving up:
# an initial install that late has probably thrown, and then there are no routes at all.
initial_install_wait_limit = 240
is_all_dst_biased = False
all_dst_ecmp_biased_factor = 1

# [Co-developed with claude code -- Adam]
# THIS is the assignment that wins -- it silently overrides the documented "(2) Deployment mode"
# knob above. Left in place deliberately (removing it would change startup timing for a
# physical-testbed deployment, and neither assignment records why there are two), but no longer
# unlabelled. If you are making the knob real, delete this line; see the comment on the first
# assignment for what that changes.
is_mininet = True


def normalize_sort_key(v):
    if isinstance(v, str) and "." in v:
        try:
            return (1, ipaddress.IPv4Address(v))  # host IP
        except:
            return (2, v)  # fallback for weird strings
    elif isinstance(v, int):
        return (0, v)  # switch ID
    else:
        return (2, str(v))  # other types as string fallback


class IntelligentRyu(app_manager.RyuApp):
    OFP_VERSIONS = [ofproto_v1_3.OFP_VERSION]
    _CONTEXTS = {
        "dpset": dpset.DPSet,
        "topology_api_app": switches.Switches,
        "wsgi": WSGIApplication, 
        "topology": event.EventHostRequest,
    }

    def __init__(self, *args, **kwargs):
        super(IntelligentRyu, self).__init__(*args, **kwargs)
        self.topology_api_app = kwargs["topology_api_app"]
        self.is_dynamically_detect_topo = False
        self.static_net = nx.DiGraph()
        self.dynamic_net = nx.DiGraph()
        self.switches = {}
        self.ip_to_mac = {}
        self.flow_stats_reply = {}  # dpid -> latest flow stats list

        wsgi = kwargs["wsgi"]
        wsgi.register(RyuServerController, {RYU_SERVER_INSTANCE_NAME: self})

        self.install_initial_openflow_entries_completed = False
        self.all_destination_paths = []

        # [Co-developed with claude code -- Adam]
        # Debounce state for recomputing routes after a topology change. See
        # _schedule_route_reinstall for why this exists at all.
        self.topology_change_seq = 0
        self.reinstall_worker_running = False

        # [Co-developed with claude code -- Adam]
        # Spawned once, by the first switch to connect; see _initial_install_watchdog.
        self._initial_watchdog_started = False
        # Same shape, for the async load_static_topology path: set BEFORE the spawn, because
        # install_initial_openflow_entries_completed is only set after the walk finishes and
        # several enter events can arrive inside that window.
        self._static_topology_spawned = False

        # [Co-developed with claude code -- Adam]
        # Topology rebuilds run on a worker greenlet, never on the event loop. See
        # _topology_worker for why, and doc/audit/2026-08-25_ring-edge-fix/PREREG-B.md for the
        # invariant this exists to establish.
        #
        # A set rather than a list: the dpids are what to notify, and an enter arriving twice for
        # the same switch is one notification, not two.
        self._pending_switch_dpids = set()
        self._topology_dirty = hub.Event()
        self._topology_worker_started = False
        # Heartbeat, read by the SIGUSR2 dump. A worker that stops updating the topology in
        # silence is the failure mode this design TRADES FOR the wedge, so it has to be visible:
        # a wedge announces itself by hanging the boot, a stalled worker announces nothing.
        self._topology_rebuilds = 0
        self._topology_coalesced = 0
        self._topology_last_start = None
        self._topology_last_ok = None
        # [Co-developed with claude code -- Adam]
        # Arrival rate into THIS app's 128-slot event queue. Every packet-in punted to the
        # controller lands here, and LLDP dominates that traffic at boot, so this is the number
        # the LLDP guard actually moves.
        #
        # It exists to answer a question the post-B measurement cannot: whether guard 0.05 -> 0.01
        # changed how long a blocked event loop needs before its queue overflows. After B the
        # queue never fills at any guard value, so comparing failure rates between guard settings
        # proves nothing about the pre-B fabric -- but 128 slots divided by the measured arrival
        # rate gives the fill time directly, and that IS comparable.
        self._pktin_count = 0
        self._pktin_first_t = None
        global _APP_FOR_DUMP
        _APP_FOR_DUMP = self


    # [Co-developed with claude code -- Adam]
    #
    # Until these existed, a link failure changed nothing. on_link_delete logged the event and
    # POSTed /ndt/link_failure_detected to the digital twin, and stopped there:
    #
    #   - nothing removed the edge from the graph paths are computed from -- there was no
    #     remove_edge anywhere in this file -- so the graph kept reporting a link that was down; and
    #   - install_all_pair_paths ran exactly once per process, because
    #     install_initial_openflow_entries_completed is set on the line immediately before the call.
    #
    # So the rules installed ~60s after startup were the final state for the life of the run.
    # Observed: `link s1 s5 down` with a flow crossing that link -- traffic stopped arriving, was
    # never rerouted, and the twin (correctly) showed the edge down while Ryu's own graph still had
    # it. See doc/2026-07-29_HANDOFF.md section 1g.
    def _active_net(self):
        """The graph routes are computed from: whichever of the two this run is using."""
        return self.dynamic_net if self.is_dynamically_detect_topo else self.static_net

    def _initial_install_watchdog(self):
        """Install routes for whatever is online once the wait for the full set has gone on too long.

        [Co-developed with claude code -- Adam]
        Fail-open. `load_static_topology` behind the switch-count gate is the only trigger for the
        initial route install, so a threshold that is never reached means no route is ever
        installed -- and that state is indistinguishable, from outside, from a fabric that is
        still converging. Every switch that is up answers every probe, both topology views are
        correct, and nothing forwards.

        Safe to run on a partial fabric: the installer looks its datapaths up with
        `self.switches.get(...)` and skips the ones that are not connected, which was already
        made true for the link-event path.

        Deliberately does NOT set install_initial_openflow_entries_completed itself --
        load_static_topology owns that flag. If more switches arrive later, the link events they
        raise go through _schedule_route_reinstall and the routes are recomputed with them
        included.
        """
        hub.sleep(initial_install_deadline)

        if self.install_initial_openflow_entries_completed:
            return
        if not self.switches:
            self.logger.error(
                "%ds after the first switch connected, no switch is connected any more; "
                "no routes installed", initial_install_deadline,
            )
            return

        online = sorted(self.switches)
        missing = [d for d in expected_switch_dpids if d not in self.switches]
        self.logger.warning(
            "installing routes after waiting %ds: %d of %d switches online (threshold from %s). "
            "Online: %s.%s This is partial routing -- traffic to or through the missing switches "
            "will not be forwarded. Set NDTWIN_RYU_SWITCH_NUM to the number this deployment "
            "actually brings up to remove the wait.",
            initial_install_deadline, len(online), switch_num, _switch_num_source,
            ", ".join(str(d) for d in online),
            (" Missing: %s." % ", ".join(str(d) for d in missing)) if missing else "",
        )
        self.load_static_topology()

    def _schedule_route_reinstall(self, reason):
        """
        Recompute and reinstall all-pair routes, once, shortly after the topology stops changing.

        Debounced rather than immediate for two reasons. `link a b down` raises one EventLinkDelete
        per direction, and a switch coming up raises a burst, so an immediate recompute would run
        several times over for one operator action. And install_all_pair_paths walks every host pair
        -- 16256 of them on the 128-host topology -- which is far too much work to do inline in an
        event handler, where it would stall LLDP discovery and every other Ryu greenlet.
        """
        self.topology_change_seq += 1
        self.logger.warning("topology changed (%s); route reinstall scheduled", reason)
        if self.reinstall_worker_running:
            return
        self.reinstall_worker_running = True
        hub.spawn(self._route_reinstall_worker)

    def _route_reinstall_worker(self):
        try:
            # The outer loop exists because _schedule_route_reinstall returns early while this worker
            # is running, so a change arriving during install_all_pair_paths is *dropped* -- and the
            # only place it can still be noticed is here, after the walk.
            #
            # Without it the window was the duration of the walk: 16256 host pairs, about 60s (see
            # doc/2026-07-29_HANDOFF.md 1g). A second link failing in that window was never recomputed, which is
            # the same silent non-recovery 2c81b26 was written to fix -- and the log said "route
            # reinstall done", meaning the *previous* change. Found by review, not by a test; the
            # tests below cover the debounce but nothing yet drives a change into the walk.
            while True:
                # Wait for the graph to stop moving: if another change arrives while we sleep, start
                # the quiet period again.
                while True:
                    seen = self.topology_change_seq
                    hub.sleep(reinstall_quiet_period)
                    if self.topology_change_seq == seen:
                        break

                if not self.install_initial_openflow_entries_completed:
                    # [Co-developed with claude code -- Adam]
                    # Waits rather than returning. The old comment claimed "the initial install will
                    # cover the current graph when it does" -- but the initial walk may have *started
                    # before* this change arrived, in which case it is walking a graph that predates
                    # it and will not cover it at all. Returning here dropped the change silently,
                    # which is the same class of loss as the mid-walk window above.
                    #
                    # Bounded, and on expiry it proceeds anyway: if the initial install is that late
                    # it has probably thrown, and in that case there are no routes at all and a walk
                    # is exactly what is wanted.
                    self.logger.warning(
                        "route reinstall waiting for the initial install to finish")
                    waited = 0
                    while (not self.install_initial_openflow_entries_completed
                           and waited < initial_install_wait_limit):
                        hub.sleep(1)
                        waited += 1
                    if not self.install_initial_openflow_entries_completed:
                        self.logger.error(
                            "initial install still not done after %ds; recomputing anyway",
                            waited)
                    # Falls through to the walk either way. `continue`-ing here was an infinite
                    # loop when the flag never arrives: the outer loop re-checks it, waits again,
                    # and never walks. Caught by the test for that case, not by reading.

                self.logger.warning("recomputing all-pair routes after topology change")
                self.install_all_pair_paths(self._active_net())
                self.logger.warning("route reinstall done")

                if self.topology_change_seq == seen:
                    return
                # Anything that arrived mid-walk was silently discarded by the early return in
                # _schedule_route_reinstall. Go round again rather than leaving those rules stale.
                self.logger.warning(
                    "topology changed again during the recompute (seq %d -> %d); recomputing",
                    seen, self.topology_change_seq)
        except Exception as e:
            # A greenlet that dies takes its traceback with it and nothing else notices, which is
            # how a silent non-recovery would come back.
            self.logger.error("route reinstall failed: %s", e, exc_info=True)
        finally:
            self.reinstall_worker_running = False

    @set_ev_cls(ofp_event.EventOFPSwitchFeatures, CONFIG_DISPATCHER)
    def switch_features_handler(self, ev):
        # Install table-miss flow entry
        datapath = ev.msg.datapath
        parser = datapath.ofproto_parser
        ofproto = datapath.ofproto

        self.logger.info(f"Datapath ID: {datapath.id}")

        match = parser.OFPMatch()
        actions = [
            parser.OFPActionOutput(ofproto.OFPP_CONTROLLER, ofproto.OFPCML_NO_BUFFER)
        ]
        self.add_flow(datapath, 0, match, actions)

    def add_flow(self, datapath, priority, match, actions):
        ofproto = datapath.ofproto
        parser = datapath.ofproto_parser

        inst = [parser.OFPInstructionActions(ofproto.OFPIT_APPLY_ACTIONS, actions)]
        mod = parser.OFPFlowMod(
            datapath=datapath, priority=priority, match=match, instructions=inst
        )
        datapath.send_msg(mod)

    def safe_add_or_modify_flow(self, datapath, priority, match, actions):
        ofproto = datapath.ofproto
        parser = datapath.ofproto_parser

        inst = [parser.OFPInstructionActions(ofproto.OFPIT_APPLY_ACTIONS, actions)]

        # Try MODIFY_STRICT first
        mod = parser.OFPFlowMod(
            datapath=datapath,
            command=ofproto.OFPFC_MODIFY_STRICT,
            priority=priority,
            match=match,
            instructions=inst,
        )
        datapath.send_msg(mod)

        # Also try ADD — if MODIFY failed (no existing flow), ADD will succeed
        mod_add = parser.OFPFlowMod(
            datapath=datapath, priority=priority, match=match, instructions=inst
        )
        datapath.send_msg(mod_add)

    def _bounded_topo_read(self, what, budget_s, fn):
        """Run one topology request-reply with a ceiling. Returns None if it did not answer.

        [Co-developed with claude code -- Adam]
        `get_switch`/`get_link` are request-reply: send the event to the `switches` app and block
        on `reply_q.get()`, which has no timeout of its own (ryu/base/app_manager.py:279). When
        the answering app is itself blocked, that get never returns -- and because this runs ON
        this app's event loop, the loop stops draining, its 128-slot queue fills, and the very app
        we are waiting for blocks trying to emit EventLinkAdd into it. That is the ring, observed
        rather than argued: both queues at 128/128, twelve emitters blocked on ours and this
        loop parked in here (doc/audit/2026-08-25_ring-edge-fix/raw/boot{1,2}_greenlets.txt).

        Returning None instead of raising keeps each caller free to choose: the switch read
        retries until its deadline, the link read gives up the round. Neither may park the loop.

        The warning is not decoration -- it is how a run proves the timeout was actually in the
        binary. A boot that wedges with zero of these lines means the fix did not land, which is
        a different finding from the fix not working, and PREREG 5-bis R2 orders them apart.
        """
        if budget_s <= 0:
            return None
        try:
            with hub.Timeout(min(budget_s, TOPO_QUERY_TIMEOUT_S)):
                return fn()
        except hub.Timeout:
            self.logger.warning(
                "topology read did not answer within %.1fs (%s) -- the topology app may be "
                "blocked; giving up this attempt rather than parking the event loop",
                min(budget_s, TOPO_QUERY_TIMEOUT_S), what)
            return None

    @set_ev_cls(event.EventSwitchEnter)
    def get_topology_data(self, ev):
        """Queue a rebuild and return. NOTHING in this method may block.

        [Co-developed with claude code -- Adam]
        This used to be where the whole topology rebuild happened, and that is what made the boot
        ring possible: a synchronous request-reply to the `switches` app, running ON this app's
        event loop, so that when `switches` was slow this loop stopped draining, its 128-slot
        queue filled, and `switches` blocked emitting EventLinkAdd into it -- each side waiting
        for the other. Bounding the calls (fix A) made that recoverable. Moving them off the loop
        makes it impossible, which is a different and better property.

        The invariant, stated so it can be tested rather than believed: no unbounded operation and
        no synchronous topology request-reply runs on this app's event loop. It is checked
        directly against SIGUSR2 dumps -- the `_event_loop` greenlet's frames must never contain
        get_switch/get_link/get_all_host -- and that check does not need the wedge to be
        reproducible, which every other test of this bug has.

        The per-switch notification moved too. It is bounded at (2,5)s, so it cannot deadlock, but
        bounded is not the same as free: ten switches at five seconds each is fifty seconds of a
        loop that is not draining a 128-slot queue, and filling that queue is half of the ring.
        """
        dpid = ev.switch.dp.id
        # Separates "events arrived" from "rebuilds ran", which coalescing otherwise makes
        # impossible to tell apart -- `Topology update triggered` now counts rebuilds, not events.
        self.logger.info("switch-enter queued for topology rebuild (dpid=%s)", dpid)
        self._pending_switch_dpids.add(dpid)
        if self._topology_dirty.is_set():
            self._topology_coalesced += 1
        self._topology_dirty.set()

        if not self._topology_worker_started:
            self._topology_worker_started = True
            hub.spawn(self._topology_worker)

    def _topology_worker(self):
        """Rebuild the topology whenever something marked it dirty. Runs off the event loop.

        [Co-developed with claude code -- Adam]
        Coalescing, not one rebuild per event. Ten switches entering at boot would otherwise run
        ten concurrent rebuilds racing over the same graph, each with its own twenty-second
        get_switch loop. What is actually required is weaker and cheaper: *at least one complete
        rebuild after the last event*. The dirty flag is cleared BEFORE the rebuild starts, so an
        event arriving during a rebuild re-marks it and earns another pass -- clearing it after
        would drop exactly that event and break the property.
        """
        while True:
            self._topology_dirty.wait()
            self._topology_dirty.clear()
            self._topology_rebuilds += 1
            self._topology_last_start = time()
            try:
                self._rebuild_topology()
                self._topology_last_ok = time()
            except Exception:            # noqa: BLE001 -- a worker that dies stops the twin
                # Silently, which is the whole risk of this design. Log loudly and keep the
                # loop alive; the heartbeat in the SIGUSR2 dump is what catches the rest.
                self.logger.exception("topology rebuild failed; worker continues")

    def _rebuild_topology(self):
        # ------ Update topology info ------
        self.logger.info("Topology update triggered")

        start = time()
        switch_list = []
        while True:
            remaining = TOPO_DEADLINE_S - (time() - start)
            if remaining <= 0:
                break
            switch_list = self._bounded_topo_read(
                "get_switch", remaining,
                lambda: get_switch(self.topology_api_app, None)) or []
            if switch_list:
                break
            hub.sleep(1)

        if not switch_list:
            self.logger.warning(
                "Switch list is empty after timeout — aborting topology update"
            )
            return

        self.logger.info("Complete get_switch")
        self.switches = {sw.dp.id: sw.dp for sw in switch_list}

        # [Co-developed with claude code -- Adam]
        # Start the clock on the first switch to arrive, not at process start: Ryu is up well
        # before the fabric is, and timing from process start would spend the budget waiting for
        # the first switch rather than for the last one.
        if not self._initial_watchdog_started and not self.install_initial_openflow_entries_completed:
            self._initial_watchdog_started = True
            hub.spawn(self._initial_install_watchdog)
        
        
        for sw in switch_list:
            if not self.dynamic_net.has_node(sw.dp.id):
                self.dynamic_net.add_node(sw.dp.id)

        links_list = self._bounded_topo_read(
            "get_link", TOPO_QUERY_TIMEOUT_S,
            lambda: get_link(self.topology_api_app, None))
        if links_list is None:
            # Abort rather than continue with no links. Continuing would hand the all-pair walk a
            # graph with nodes and no edges, and the paths it computed from that would be wrong
            # rather than merely missing. Aborting matches what the empty-switch-list branch above
            # already does, and the next EventSwitchEnter runs the whole thing again.
            #
            # 🔴 THIS BRANCH HAS NEVER EXECUTED. Stated up front because the comment that
            # stood here claimed it had, and misattributed the evidence: the seven aborts and all
            # 28 timeouts measured in Phase 2 (fixa1) were the get_switch exit above, never this
            # one -- `grep -c "Link list unavailable" ` is 0 across every log in doc/audit.
            #
            # So the get_switch ceiling is what Phase 2 verified. This one is unexercised
            # insurance, and the case it insures against is real rather than theoretical: Phase 0
            # boot1 wedged with the event loop parked in exactly this call.
            #
            # The fidelity cost I predicted for it is therefore also unmeasured. What IS measured,
            # from the get_switch exit that did run: aborting does not cost the twin anything,
            # because the twin does not learn topology from the notification this returns before.
            # The kernel POLLS Ryu's REST API -- every push from this handler failed with
            # ECONNREFUSED in all six boots of both arms, the kernel not being up yet when
            # switches enter -- and what a wedge actually breaks is that poll: 4 GET
            # /v1.0/topology/switches on a wedged boot against 26 on a recovered one, with the
            # kernel blind for 148s in between before it catches up.
            #
            # Aborting rather than falling through stands on its own reason regardless: a walk
            # over nodes-without-edges computes wrong paths, not missing ones.
            self.logger.warning(
                "Link list unavailable after timeout — aborting topology update"
            )
            return
        self.logger.info("Complete get_link")
        
        for link in links_list:
            src, dst = link.src.dpid, link.dst.dpid
            src_port, dst_port = link.src.port_no, link.dst.port_no
            # self.logger.info(f"Add edge ({src},{src_port}) -> ({dst},{dst_port})")
            # Add forward and reverse edges
            self.dynamic_net.add_edge(src, dst, port=src_port)
            self.dynamic_net.add_edge(dst, src, port=dst_port)

        # ------ Update switch is_up state ------
        # [Co-developed with claude code -- Adam]
        # Drained under coalescing: one rebuild may answer for several enters, so this notifies
        # every dpid queued since the last pass instead of the single `ev` it used to receive.
        # Taken by swap rather than iterated in place -- an enter arriving mid-loop must land in
        # the NEXT batch, not mutate the set being walked. Extracted so that property has a test
        # of its own: left inline, a mutation to it survived the worker suite untouched, because
        # the suite stubs out the rebuild this used to be buried in.
        for dpid in self._drain_pending_dpids():
            api_url = f"http://localhost:8000/ndt/inform_switch_entered?dpid={dpid}"
            self.logger.info("Switch entered: %s", dpid)
            self._notify_switch_entered(dpid, api_url)

        self._maybe_install_initial_routes()

    def _drain_pending_dpids(self):
        """Take the queued dpids and leave an empty set behind, in one step.

        [Co-developed with claude code -- Adam]
        The swap is the point. Notifying is bounded but not instant -- (2,5)s per switch -- and an
        EventSwitchEnter can land anywhere inside that window. Iterating the live set would either
        raise or silently drop whichever arrived mid-walk; swapping first means it is simply part
        of the next batch. Sorted so a run's log order is stable and diffable.
        """
        pending, self._pending_switch_dpids = self._pending_switch_dpids, set()
        return sorted(pending)

    def _notify_switch_entered(self, dpid, api_url):
        """One bounded switch-enter notification. Runs on the worker, not the event loop.

        [Co-developed with claude code -- Adam]
        Unchanged in behaviour from when this was inline; only its caller moved. Kept as its own
        method so the per-dpid loop above stays readable and so the (2,5) timeout has one home.
        """
        try:
            # [Co-developed with claude code -- Adam] (connect, read) -- see _state_change_handler.
            response = requests.get(api_url, timeout=(2, 5))
            self.logger.info(
                "Notified NDT (switch enter), status: %s", response.status_code
            )
            # [Co-developed with claude code -- Adam]
            # requests does NOT raise on 4xx/5xx -- only on transport failures -- so the line above
            # reported a kernel REJECTION as though it were a delivery: HTTP 500 read exactly like
            # 200. The `Failed to notify` warning below therefore covers the network layer only,
            # which is why counting that string measures reachability and not acceptance. Inherited
            # defect -- present on main at all four notify sites. Found by the shadow review (R-1).
            if response.status_code >= 400:
                self.logger.warning(
                    "NDT REJECTED the switch-enter notification: HTTP %s from %s -- delivered "
                    "but not accepted, so the kernel's view of this switch is stale",
                    response.status_code, api_url
                )
        except Exception as e:
            self.logger.warning("Failed to notify NDT (switch enter): %s", str(e))

    def _maybe_install_initial_routes(self):
        """Install the initial routes once enough switches are up. Worker context, not the loop.

        [Co-developed with claude code -- Adam]
        Split out of the EventSwitchEnter handler when the rebuild moved to _topology_worker.
        Behaviour is unchanged; what changed is what "blocking here" costs. It used to stall the
        event loop, which is how the ring formed. It now stalls only the worker, which delays the
        next rebuild and nothing else -- so NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL stops being the
        difference between a wedge and a boot, and becomes an ordinary latency choice. Left as it
        is rather than retired: that claim deserves its own measurement, not a same-commit
        assumption.
        """
        # After connecting to all switches, try to read static topology file first, if it dose not exist, then try to detect topolody dynamically
        self.logger.info(f"len(self.switches) {len(self.switches)}")
        if len(self.switches) >= switch_num:
            if not self.install_initial_openflow_entries_completed:
                # [Co-developed with claude code -- Adam]
                # HISTORICAL, and no longer the situation -- kept because it is why this branch
                # exists. `load_static_topology` blocks for the settle wait plus the all-pairs
                # walk, and this USED TO RUN inside the EventSwitchEnter handler, so that blocking
                # happened ON THIS APP'S EVENT QUEUE, which Ryu bounds at 128
                # (app_manager.py:160). A put into a full queue blocks the emitter, and this app
                # also observes EventOFPPacketIn, so every punted packet-in landed in the same
                # queue. Since the rebuild moved to _topology_worker, none of this runs on the
                # event loop at all.
                #
                # CORRECTED 2026-08-25, and the correction is not cosmetic. This comment used to
                # read "punted LLDP ... at ~2.5/s: 128 slots fill in ~50 s". Nobody had ever
                # measured that. Phase 5 of doc/audit/2026-08-25_ring-edge-fix instrumented the
                # counter and got 56-72/s averaged over a boot and 136-210/s over the opening six
                # seconds, so 128 slots fill in 1.8-2.3 s -- 0.6-0.9 s during the burst. The
                # comment was off by 20-80x, in the direction that makes the ring EASIER to form:
                # every blocking event down here (the settle wait, the walk, the 10x5s notify
                # chain) outruns the fill time by one to two orders of magnitude, so the queue is
                # already full long before any of them return.
                #
                # The "LLDP" half is wrong too. Cutting NDTWIN_RYU_LLDP_GUARD five-fold
                # (0.05 -> 0.01) moved the measured rate only 1.22x (57.8 -> 70.5/s) where an
                # LLDP-dominated stream would move ~5x. Two lines of the library say why the
                # guard has so little leverage: switches.py:947-949 throttles only the REFRESH
                # sends (ceiling 1/guard = 20/s at stock, already under the 57.8/s we measured),
                # while switches.py:945-946 sends to never-probed ports with no throttle at all
                # -- and boot is exactly when that list is long. Which source actually fills the
                # queue is still unmeasured; treat "LLDP" as the guess it always was.
                #
                # That is the cycle the review session's phase-1 diagnosis describes
                # (doc/audit/2026-08-24_full-stack-run/REPORT.md) for the 6-of-10 boot failures,
                # and their conclusion is the reason this branch exists: *any fix that keeps
                # blocking work inside EventSwitchEnter keeps the cycle*. Spawning returns the
                # handler immediately so the queue keeps draining.
                #
                # OFF BY DEFAULT, and that is not timidity: the mechanism is still INFERRED (the
                # SIGUSR2 dump added alongside this is what would confirm it), and shipping an
                # unverified change to the boot path is exactly how the settle regression got in.
                # This flag has a named owner and a named test rather than being a dead switch:
                # flip it after a defaults x10 on a fabric that shows the async path taking the
                # walk, and compare the failure rate against the 6-of-10 baseline.
                #
                # The spawn guard is separate from install_initial_openflow_entries_completed
                # because that flag is only set AFTER the walk finishes -- several enter events
                # can arrive inside that window, and without its own guard each would spawn its
                # own walk. That is the same defect this file already fixed once for the
                # reinstall worker.
                if _async_topology_install:
                    if not self._static_topology_spawned:
                        self._static_topology_spawned = True
                        self.logger.info(
                            "spawning load_static_topology off the event handler "
                            "(NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL=1)")
                        hub.spawn(self.load_static_topology)
                else:
                    self.load_static_topology()
        elif not self.install_initial_openflow_entries_completed:
            # [Co-developed with claude code -- Adam]
            # Waiting for the full set is correct for a site that brings everything up: the
            # all-pair walk is ~60s over 16256 pairs on the 128-host topology, and running it on
            # a partial graph produces paths that have to be thrown away and redone.
            #
            # What must not happen is waiting *forever* in silence, which is what this did when
            # the threshold was a fixed 10 and the site had switches deliberately unpowered.
            # _initial_install_watchdog now bounds the wait; this line says how long is left.
            missing = [d for d in expected_switch_dpids if d not in self.switches]
            self.logger.warning(
                "%d of %d switches connected (threshold from %s); waiting up to %ds before "
                "installing routes for whatever is online.%s",
                len(self.switches), switch_num, _switch_num_source, initial_install_deadline,
                (" Not yet connected: %s." % ", ".join(str(d) for d in missing)) if missing else "",
            )
                
    @set_ev_cls(ofp_event.EventOFPStateChange,
                [CONFIG_DISPATCHER, MAIN_DISPATCHER, DEAD_DISPATCHER])
    def _state_change_handler(self, ev):
        dp = ev.datapath
        if ev.state == MAIN_DISPATCHER:
            if dp.id == None:
                return
            self.logger.info("Switch %016x connected (EventOFPStateChange)", dp.id)
            # ------ Update switch is_up state ------
            dpid = ev.datapath.id
            api_url = f"http://localhost:8000/ndt/inform_switch_entered?dpid={dpid}"
            # self.logger.info("Switch entered: %s", dpid)
            try:
                # [Co-developed with claude code -- Adam]
                # (connect, read) timeout. This call had none, and it is the worst place in the file
                # to be missing one: it runs inside an *OpenFlow event handler*, once per switch that
                # connects. When Ryu is started against an already-running Mininet all ten switches
                # reconnect at once -- they have been retrying -- so ten of these fire together,
                # each blocking that datapath's event processing until the kernel answers.
                #
                # A datapath greenlet parked here does not drain its socket. Measured on a wedged Ryu
                # after exactly that startup order: 88 KB of unread data per OpenFlow connection,
                # every /stats/flow request timing out at 1.001s and returning an empty table, LLDP
                # packet-ins never delivered so no link event ever fired, and HTTP connections left
                # in CLOSE-WAIT. It never recovered, not when the walk finished and not when the only
                # client stopped.
                #
                # NOT PROVEN to be the cause -- that needs a py-spy dump taken at the moment of the
                # wedge, and the wedge does not reproduce with the correct startup order (Ryu first):
                # 125 samples over four minutes stayed at a 0.025s mean with Recv-Q at zero. But the
                # timeout is correct regardless, and the two notification POSTs in this file had the
                # identical defect.
                response = requests.get(api_url, timeout=(2, 5))
                self.logger.info(
                    "Notified NDT (switch enter), status: %s", response.status_code
                )
                # [Co-developed with claude code -- Adam]
                # requests does NOT raise on 4xx/5xx -- only on transport failures -- so the line above
                # reported a kernel REJECTION as though it were a delivery: HTTP 500 read exactly like
                # 200. The `Failed to notify` warning below therefore covers the network layer only,
                # which is why counting that string measures reachability and not acceptance. Inherited
                # defect -- present on main at all four notify sites. Found by the shadow review (R-1).
                if response.status_code >= 400:
                    self.logger.warning(
                        "NDT REJECTED the switch-enter notification: HTTP %s from %s -- delivered "
                        "but not accepted, so the kernel's view of this switch is stale",
                        response.status_code, api_url
                    )
            except Exception as e:
                self.logger.warning("Failed to notify NDT (switch enter): %s", str(e))
        elif ev.state == DEAD_DISPATCHER:
            if dp.id == None:
                return
            self.logger.info("Switch %016x disconnected (EventOFPStateChange)", dp.id)
    
    def _dynamic_topology_worker(self):
        self.logger.info("No static topo file, falling back to dynamic detection. Waiting 60s...")
        hub.sleep(detecting_time)  # this will NOT block the main Ryu thread

        self.print_all_hosts(self.dynamic_net)
        try:
            self.install_all_pair_paths(self.dynamic_net)
            self.install_initial_openflow_entries_completed = True
            self.logger.info("Dynamic topology initialized, all-destination paths installed.")
        except Exception as e:
            self.logger.error(f"Dynamic topology init failed: {e}")
            
    def find_target_by_src_port(self, G, src_node, src_port_attr, attr_name="port"):
        for _, v, data in G.out_edges(src_node, data=True):
            if data.get(attr_name) == src_port_attr:
                return v
        return None
    
    def int_to_mac(self, n: int) -> str:
        if not (0 <= n < (1 << 48)):
            raise ValueError("MAC int must be in [0, 2^48)")
        return ":".join(f"{(n >> (8*i)) & 0xff:02x}" for i in reversed(range(6)))

    def _hosts_with_ipv4(self) -> int:
        """How many hosts Ryu currently has an IPv4 address for.

        [Co-developed with claude code -- Adam]
        `h.ipv4` is a list and is empty until a packet-in from that host carries an IPv4 or ARP
        header (ryu/topology/switches.py:877-885). Truthiness, not `is not None`: the empty list
        is the state being waited out.
        """
        # [Co-developed with claude code -- Adam]
        # THE TIMEOUT IS LOAD-BEARING, and its absence was a defect in this function.
        #
        # `get_all_host` is a request-reply: send_request -> reply_q.get(), and that get has no
        # timeout of its own. If the app that must answer is itself blocked, this waits forever.
        # That is not hypothetical -- it is where the 2026-08-24 wedge was caught red-handed
        # (raw/usr2_attempt4_d{1,2}.txt): IntelligentRyu's event loop parked at
        #   get_topology_data -> load_static_topology -> _await_host_discovery
        #     -> _hosts_with_ipv4 -> send_request -> reply_q.get()
        # waiting on a Switches app that was itself blocked emitting EventLinkAdd into this app's
        # full buffer. Both sides unbounded, so the cycle was permanent.
        #
        # The subtle part, and the reason a deadline did not save it: _await_host_discovery
        # checks its deadline BETWEEN polls. A poll that never returns is never between polls, so
        # the 40 s ceiling could not fire. A deadline that the operation it bounds can evade by
        # blocking inside a single iteration is not a deadline.
        #
        # Timing out and reporting 0 keeps the existing fail-open contract: the caller keeps
        # waiting and eventually proceeds without full discovery, which degrades the twin's view
        # rather than the network.
        try:
            with hub.Timeout(HOST_QUERY_TIMEOUT_S):
                return sum(1 for h in get_all_host(self) if h.ipv4)
        except hub.Timeout:
            self.logger.warning(
                "host-table read did not answer within %ss -- the topology app may be blocked; "
                "treating as 0 learned and letting the deadline run",
                HOST_QUERY_TIMEOUT_S)
            return 0
        except Exception:                          # noqa: BLE001 -- see below
            # Never let a topology-API hiccup abort start-up. Reporting 0 makes the caller wait
            # out its deadline and proceed, which is the same fail-open behaviour the switch-count
            # watchdog uses. Crashing here would take the whole control plane down at boot.
            self.logger.exception("could not read Ryu's host table; treating as 0 learned")
            return 0

    def _await_host_discovery(self, expected: int, deadline_s: int) -> None:
        """Block until Ryu knows an IPv4 for every host, or `deadline_s` passes.

        [Co-developed with claude code -- Adam]
        This replaced a fixed `hub.sleep`. What is really being waited for is the ping burst
        testbed_topo.py fires after building the hosts: those packets miss the flow table, reach
        the controller, and are how Ryu learns each host's address. Install the all-pairs rules
        first and the burst is answered in the data plane instead -- no packet-in, no addresses,
        and the kernel drops every host at TopologyAndFlowMonitor.cpp:618, leaving all 256 host
        edges down in a fabric that forwards perfectly. See the NDTWIN_RYU_SETTLE_S comment for
        the two-arm measurement.

        Waiting for the event rather than for a duration is the point: the old fixed value was a
        race whose outcome depended on how fast the machine built 128 hosts that day.

        **That intent is not what this code achieves -- see the NDTWIN_RYU_SETTLE_S comment.**
        Measured at two deadlines, the loop below never once saw a host acquire an IPv4: the
        addresses appear only after it releases, in a single step, at whatever time that is. So
        it behaves as a fixed sleep, and the early-exit path has never been taken on a 128-host
        boot. It is kept because fail-open costs nothing and the early exit is correct if the
        coupling is ever broken -- not because it is doing the job its name claims.

        **Fail-open.** A deadline that expires is logged and then ignored. A control plane that
        refuses to install any routes because discovery was incomplete is worse than one whose
        twin under-reports host links -- the first breaks the network, the second breaks a view.
        """
        if expected <= 0 or deadline_s <= 0:
            # Nothing to gate on (no hosts in the model, or the wait is disabled). Fall back to
            # the old behaviour so this cannot become a silent no-wait on an unexpected model.
            if deadline_s > 0:
                self.logger.info("no hosts in the model; sleeping %ss instead", deadline_s)
                hub.sleep(deadline_s)
            return

        waited = 0
        learned = self._hosts_with_ipv4()
        while learned < expected and waited < deadline_s:
            hub.sleep(1)
            waited += 1
            learned = self._hosts_with_ipv4()
            # Progress, not just a verdict. The first live run of this gate reported "0/128 after
            # 90s" while the REST endpoint served 128/128 a few seconds later, and a single
            # end-of-wait line cannot tell "the count never moved" from "it moved and we missed
            # the moment". One line every 10s makes the shape of the wait recoverable from
            # ryu.log alone. [Co-developed with claude code -- Adam]
            if waited % 10 == 0:
                self.logger.info("host discovery: %d/%d after %ss", learned, expected, waited)

        if learned >= expected:
            self.logger.info(
                "host discovery complete: %d/%d hosts have an IPv4 after %ss "
                "(NDTWIN_RYU_SETTLE_S=%s is the ceiling, not the wait)",
                learned, expected, waited, deadline_s)
        else:
            self.logger.warning(
                "host discovery incomplete after %ss: %d/%d hosts have an IPv4. Installing "
                "paths anyway. The data plane will forward, but the kernel skips hosts with no "
                "address, so expect %d host edges to read as down in get_graph_data.",
                deadline_s, learned, expected, (expected - learned) * 2)

    def load_static_topology(self, path: Path = static_topology_file_path):
        if not path.exists():
            self.logger.info(f"Static topology file not found: {path}")
            self.is_dynamically_detect_topo = True
            self.logger.info(f"self.is_dynamically_detect_topo {self.is_dynamically_detect_topo}")

            # Start background thread instead of blocking with sleep
            t = threading.Thread(target=self._dynamic_topology_worker, daemon=True)
            t.start()

            return None

        try:
            with path.open("r") as f:
                topo = json.load(f)
            self.logger.info(f"Loaded static topology from {path}")

            expected_hosts = set()

            # Add nodes and edges to net
            for node in topo.get("nodes", []):
                if not node: continue
                # self.logger.info(f"n {node.get('nickname', '')}")
                if node.get("vertex_type", "") == 0:    # switch
                    ecmp_groups = node.get("ecmp_groups", [])
                    self.static_net.add_node(int(node.get("dpid")), ecmp_groups=ecmp_groups)
                elif node.get("vertex_type", "") == 1: # host
                    ip_list = node.get("ip")
                    mac = node.get("mac")
                    self.static_net.add_node(self.int_to_mac(mac), ip_list=ip_list)
                    # Counted by MAC, not by len(ip_to_mac): a host may carry several addresses,
                    # and this number is compared against a count of *hosts* Ryu has learned.
                    # [Co-developed with claude code -- Adam]
                    expected_hosts.add(mac)
                    for ip in ip_list:
                        self.ip_to_mac[ip] = mac
                    
            for edge in topo.get("edges", []):
                if not edge: continue
                # self.logger.info(f"e src_dpid {edge.get('src_dpid', '')} -> dst_dpid {edge.get('dst_dpid', '')}")
                if edge.get("src_dpid") == 0:   # host to sw
                    # self.logger.info("host to sw")
                    # Look up mac from vertex
                    first_src_ip = edge.get("src_ip")[0]
                    mac = self.int_to_mac(self.ip_to_mac[first_src_ip])
                    # self.logger.info(f"src mac {mac} target dst_dpid {edge.get('dst_dpid')} port 0")
                    self.static_net.add_edge(mac, edge.get("dst_dpid"), port=0)
                elif edge.get("dst_dpid") == 0: # sw to host
                    # self.logger.info("sw to host")
                    # Look up mac from vertex
                    first_dst_ip = edge.get("dst_ip")[0]
                    mac = self.int_to_mac(self.ip_to_mac[first_dst_ip])
                    # self.logger.info(f"src src_dpid {edge.get('src_dpid')} target mac {mac} port {edge.get('src_interface')}")
                    self.static_net.add_edge(edge.get("src_dpid"), mac, port=edge.get("src_interface"))
                else:
                    # self.logger.info("sw to sw")
                    self.static_net.add_edge(edge.get("src_dpid"), edge.get("dst_dpid"), port=edge.get("src_interface"))
            # Install all-destination routing entries, after letting the fabric settle.
            #
            # [Co-developed with claude code -- Adam]
            # This was a bare `if is_mininet: hub.sleep(60)` with no recorded reason, gated on a
            # flag that cannot be changed (is_mininet is reassigned True unconditionally at
            # module level). It dominates OVS bring-up: the whole control-plane start was ~73 s
            # and the walk it is waiting for takes 0.25 s of that (128 hosts, live n=3, after the
            # O(1)-token fix in 4810e8f; the 2.166 s and the slower index figures this comment
            # carried before are two superseded generations -- see WALK_SWEEP.md).
            #
            # It is now a gate on the event rather than a guess at its duration. The seam that
            # made the question answerable by measurement did its job: measuring it showed the
            # length was deciding whether Ryu ever learns a host address, and therefore whether
            # the twin can see 256 of its own 288 links. NDTWIN_RYU_SETTLE_S is the deadline.
            self._await_host_discovery(len(expected_hosts), settle_seconds)
            # [Co-developed with claude code -- Adam]
            # The flag is set AFTER the walk, matching the dynamic path above. It used to be set
            # before, so it was True for the whole ~60 s of the initial install -- and the reinstall
            # worker's guard is `if not ...completed: return`. A link event during the walk therefore
            # passed the guard and started a *second* concurrent walk. hub is cooperative so nothing
            # corrupts, but both walks issue OFPFC_ADD for the same (switch, ipv4_dst) at the same
            # priority, which overwrites -- so whichever finished last won, and the one that started
            # first was walking the pre-failure graph. Each also assigns its own local list to
            # self.all_destination_paths, which the kernel then pulls. Nondeterministic routing and a
            # nondeterministic answer to get_path_switch_count, with nothing logging a conflict.
            self.install_all_pair_paths(self.static_net)
            self.install_initial_openflow_entries_completed = True
            self.logger.info("Static topology initialized, all-destination paths installed.")
            
        except Exception as e:
            self.logger.error(f"Failed to load static topology file {path}: {e}")


    def print_all_hosts(self, net):
        # Sort nodes by first IP
        sorted_nodes = sorted(
            net.nodes,
            key=lambda node: (
                ipaddress.IPv4Address(net.nodes[node]["ip_list"][0])
                if "ip_list" in net.nodes[node]
                else ipaddress.IPv4Address("255.255.255.255")
            ),  # Put at the end
        )

        # Create a new graph
        ordered_net = nx.DiGraph()

        # Add nodes and edges in order
        for node in sorted_nodes:
            ordered_net.add_node(node, **net.nodes[node])

        ordered_net.add_edges_from(net.edges(data=True))

        # Replace self.net
        net = ordered_net

        all_ips_num = 0
        self.logger.info("All IPs in all hosts (sorted):")
        for node in net.nodes:
            node_data = net.nodes[node]
            if "ip_list" in node_data:
                # Sort all collected IPs
                node_data["ip_list"] = sorted(
                    node_data["ip_list"], key=lambda ip: ipaddress.IPv4Address(ip)
                )
                self.logger.info(f"{node_data['ip_list']}")
                all_ips_num += len(node_data["ip_list"])

        print(f"all_ips_num: {all_ips_num}")


    
    def find_host_by_ip(self, net, target_ip):
        """The host node owning this address, or None.

        [Co-developed with claude code -- Adam]
        Indexed rather than scanned. This is called from the innermost loop of the all-pairs
        path reconstruction, so a linear scan of net.nodes made that walk cubic in host count
        rather than quadratic. Measured by intervention (2026-08-21 sweep, doc/audit/
        2026-08-21_ryu-topology-scaling/WALK_SWEEP.md): swapping this one helper for a dict cut
        the 128-host report phase 13.7x and dropped the log-log slope from 2.75 to 1.86 -- the
        cubic term was this line and nothing else.

        The cache is rebuilt when the graph gains a node. That is the only event that can
        change the mapping: the index reads nothing but per-node ip_list, which is written when
        a node is added and never mutated afterwards, and nothing in this program removes a
        node. Keyed on id(net) as well because two graphs are in play -- static_net and
        dynamic_net -- and _active_net picks between them.

        The token must be O(1) or it IS the scan. The first version of this cache keyed on
        net.number_of_edges() too, believing it O(1); in networkx it is size(), a sum over
        every node's degree, evaluated per lookup -- which made the "indexed" walk 1.69x
        SLOWER than the linear scan it replaced (offline intervention, n=3 at 32/64/128 hosts,
        ratio matching the live 3.634 s vs 2.166 s pair). Edge count also never belonged in
        the token: edges do not feed the index. number_of_nodes() is len(a dict).

        First match wins, exactly as the scan it replaces: two nodes claiming one address kept
        the earlier one in iteration order, and setdefault preserves that rather than quietly
        changing which host a duplicate resolves to.
        """
        token = (id(net), net.number_of_nodes())
        if getattr(self, "_host_ip_token", None) != token:
            index = {}
            for node in net.nodes:
                for ip in net.nodes[node].get("ip_list", ()) or ():
                    index.setdefault(ip, node)
            self._host_ip_index = index
            self._host_ip_token = token
        return self._host_ip_index.get(target_ip)


    
    def find_connected_switch(self, net, host):
        return list(net.neighbors(host))[0]

    
    def get_host_port(self, net, host, switch):
        return net[switch][host]["port"]

    def is_switch(self, node):
        return isinstance(node, int) and node in self.switches

    def hash_dst_ip(self, str):
        # Use SHA256 or any hash to make it deterministic
        return int(hashlib.sha256(str.encode()).hexdigest(), 16)

    def debug_print_graph(self, net):
        print(f"=== NODES {len(net.nodes)} ===")
        for n, data in net.nodes(data=True):
            print(f"{n}: {data}")

        print(f"\n=== EDGES {len(net.edges)} ===")
        for u, v, data in net.edges(data=True):
            print(f"{u} -> {v}: {data}")


    def install_all_pair_paths(self, net):
        # [Co-developed with claude code -- Adam]
        # Timed because this walk is the largest unattributed term in the 128-host failover
        # budget, and the two figures on record disagree by 4.6x. Neither was a measurement of
        # this function:
        #
        #   ~13 s  derived -- the OVS control plane was measured starting in 73 s (2026-08-19)
        #          and the hub.sleep(60) below accounts for 60 of them, leaving <=13 s for the
        #          JSON parse, the graph build AND this walk. So 13 s is an upper bound on the
        #          three together, not a reading of the walk.
        #   ~60 s  asserted -- the comments beside initial_install_deadline and
        #          initial_install_wait_limit, this method's own tests, and 5affd93's commit
        #          message all say "the walk is ~60 s over 16256 pairs", sourced from
        #          doc/2026-07-29_HANDOFF.md 1g -- which predates cc249c8, i.e. predates 128
        #          hosts being runnable at all.
        #
        # Split into two phases because they scale differently and only one of them is what
        # "16256 pairs" names. The BFS installs one rule per (switch, dst): 1280 at 128 hosts.
        # The reporting loop that follows builds one entry per ORDERED HOST PAIR -- 16256 --
        # purely to populate all_destination_paths for the kernel to read. A budget that blames
        # "path computation" needs to know which half it is blaming, and a fix would differ:
        # one is OpenFlow writes, the other is a nested Python loop over a list.
        #
        # monotonic() rather than the time() imported above: this method runs across hub yields
        # and a wall-clock step would be indistinguishable from walk time. Logged at warning to
        # sit at the level the reinstall worker already uses for its own milestones, so one
        # grep over a run's Ryu log yields every walk it did, startup and failover alike.
        walk_started = monotonic()
        report_seconds = 0.0
        rules_installed = 0
        self.logger.info("install_all_pair_paths")
        self.debug_print_graph(net)
        all_hosts_ip_list = []
        all_destination_paths = []
        for node in net.nodes:
            node_data = net.nodes[node]
            if "ip_list" in node_data:
                all_hosts_ip_list.extend(node_data["ip_list"])

        for dst_ip in all_hosts_ip_list:
            dst_host = self.find_host_by_ip(net, dst_ip)
            dst_switch = self.find_connected_switch(net, dst_host)
            # self.logger.info("Installing paths toward host %s via BFS", dst_ip)
            parent_hash = {}
            parent_hash[dst_ip] = None


            # BFS traversal starting from dst_switch
            visited = set()
            queue = [(dst_switch, None)]  # (current_switch, previous_switch)

            while queue:
                current_switch, prev_switch = queue.pop(0)
                if current_switch in visited:
                    continue
                visited.add(current_switch)

                # Determine out_port toward dst_host
                if prev_switch is not None:
                    # [Co-developed with claude code -- Adam]
                    # Enqueue already proved this edge existed, but add_flow yields to the event
                    # loop, so a link event can remove it mid-walk. Losing one switch's entry for
                    # one round is recoverable -- whatever removed the edge also schedules another
                    # recompute. Losing the whole round to a KeyError is what froze routing.
                    edge = net[current_switch].get(prev_switch)
                    if edge is None:
                        self.logger.warning(
                            "edge %s->%s vanished mid-recompute; skipping switch %s for dst %s",
                            current_switch, prev_switch, current_switch, dst_ip)
                        continue
                    out_port = edge["port"]
                    parent_hash[current_switch] = prev_switch
                else:
                    out_port = self.get_host_port(net, dst_host, current_switch)
                    parent_hash[current_switch] = dst_ip

                # Install OpenFlow entry for forwarding to dst_ip
                # self.logger.info(f"current_switch type {type(current_switch)}")
                # self.logger.info(f"current_switch {current_switch}")
                datapath = self.switches.get(current_switch)
                # [Co-developed with claude code -- Adam]
                # None once this runs on link events rather than only at startup: a switch can be
                # gone from self.switches while still present in the graph. Reaching straight for
                # .ofproto_parser raised AttributeError, which aborted the whole recompute part-way
                # and left routes half-installed.
                if datapath is None:
                    self.logger.warning(
                        "skipping switch %s while installing routes to %s: not connected",
                        current_switch,
                        dst_ip,
                    )
                    continue
                parser = datapath.ofproto_parser
                match = parser.OFPMatch(eth_type=0x0800, ipv4_dst=dst_ip)
                actions = [parser.OFPActionOutput(out_port)]
                self.add_flow(datapath, priority=10, match=match, actions=actions)
                rules_installed += 1

                # self.logger.info(
                #     "Installing flow on switch %s: match(ipv4_dst=%s) -> output(port=%d)",
                #     current_switch,
                #     dst_ip,
                #     out_port,
                # )


                
                # Add neighbors to BFS queue randomly
                # neighbors = list(net.neighbors(current_switch))
                # print(f"neighbors {neighbors}")
                # random.shuffle(neighbors)  # Randomize neighbor order

                # Add neighbors to BFS queue deterministically
                neighbors = list(net.neighbors(current_switch))
                # self.logger.info(f"neighbors {neighbors}")

                        
                # Sort neighbors based on hash of (dst_ip + neighbor)
                neighbors.sort(key=lambda neighbor: (self.hash_dst_ip(dst_ip + str(neighbor))))
                # self.logger.info(f"sorted neighbors {neighbors}")
                
                
                if is_all_dst_biased:
                    ecmp_groups = net.nodes[current_switch]["ecmp_groups"]
                    ecmp_groups_member_in_neighbors = []
                    if ecmp_groups != []:
                        for group in ecmp_groups:
                            members = group["members"]
                            temp = [] 
                            for member in members:
                                port_id = member["port_id"]
                                target_node = self.find_target_by_src_port(net, current_switch, port_id, "port")
                                self.logger.info(f"target_node {target_node}")
                                
                                if target_node in neighbors:
                                    temp.append(target_node)
                                    
                            ecmp_groups_member_in_neighbors.append(temp)
                                
                    self.logger.info(f"ecmp_groups_member_in_neighbors {ecmp_groups_member_in_neighbors}")
                    
                    for group in ecmp_groups_member_in_neighbors:
                        r = random.random()
                        r2 = int((random.random() * 10)) % len(group)-1
                        self.logger.info(f"r {r} r2 {r2}")
                        temp = 0
                        if r <= all_dst_ecmp_biased_factor: # choose first element
                            temp = group[0]
                        else:   # choose others
                            temp = group[r2+1]
                        group.remove(temp)
                        group.append(temp)
                        
                
                    for group in ecmp_groups_member_in_neighbors:
                        for ele in group:
                            neighbors.remove(ele)
                            neighbors.insert(0,ele)
                
                    self.logger.info(f"biased neighbors {neighbors}")
                
                # [Co-developed with claude code -- Adam]
                # Only walk a link that exists in BOTH directions. The graph is a DiGraph kept in
                # sync by per-direction LLDP events, and a unidirectional dataplane failure removes
                # exactly one of the two directed edges -- the paired EventLinkDelete never fires,
                # so the asymmetry is a steady state, not a transient. The entry installed at
                # `neighbor` forwards neighbor -> current and needs the neighbor->current edge for
                # its out port; walking the half-dead link crashed the whole recompute at that
                # lookup (KeyError), which froze every route while the twin kept reporting the
                # flow as healthy (live 2026-08-13: 291 s blackhole, zero self-heal). Skipping the
                # pair lets BFS reach the switch through any healthy neighbor instead, so traffic
                # routes around the dead direction.
                for neighbor in neighbors:
                    if (neighbor not in visited and self.is_switch(neighbor)
                            and net.has_edge(neighbor, current_switch)):
                        queue.append((neighbor, current_switch))


            # Reconstruct path from any switch back to dst_switch
            report_started = monotonic()
            for switch in parent_hash:
                path = []
                node = switch
                # [Co-developed with claude code -- Adam]
                # Same mid-walk hazard as the install loop above: these lookups re-read the graph
                # after every yield, so a vanished edge must cost this one reported path, not the
                # whole recompute.
                try:
                    while node is not None:
                        if parent_hash.get(node) is not None:
                            next_hop = parent_hash[node]
                            if self.is_switch(next_hop):
                                out_port = net[node][next_hop]["port"]
                            else:
                                host = self.find_host_by_ip(net, next_hop)
                                out_port = net[node][host]["port"]
                            path.append((node, out_port))
                        else:
                            path.append((node, 0))
                        node = parent_hash.get(node)
                except KeyError:
                    self.logger.warning(
                        "edge vanished mid-recompute while reporting the path via switch %s to "
                        "%s; dropping that path for this round", switch, dst_ip)
                    continue


                # print(f"Flow path to {dst_ip} through switch {switch}: {' -> '.join(str(n) for n in path)}")
                full_path = []
                for src_ip in all_hosts_ip_list:
                    if src_ip == dst_ip:
                        continue
                    src_host = self.find_host_by_ip(net, src_ip)
                    src_switch = self.find_connected_switch(net, src_host)
                    out_port = net[src_switch][src_host]["port"]
                    # print(f"src out_port {out_port}")
                    if src_switch == switch:
                        full_path = [(src_ip, out_port)] + path
                        # self.logger.info("Flow path from %s to %s path %s\n\n\n\n\n", src_ip, dst_ip, full_path)
                        all_destination_paths.append(full_path)
            report_seconds += monotonic() - report_started

        self.all_destination_paths = all_destination_paths
        # [Co-developed with claude code -- Adam]
        # See the note at the top of this method. `pairs` is n*(n-1) -- ordered, because the
        # loop above builds an entry per direction -- and is printed so the line can be read
        # without knowing the host count convention. install = total - report by construction,
        # so the two always sum; they are not measured independently.
        walk_seconds = monotonic() - walk_started
        hosts = len(all_hosts_ip_list)
        # Milliseconds, not centiseconds: the point of this line is a sweep across host counts,
        # and the small end of that sweep is fast. A 4-host walk lands around single-digit
        # milliseconds, which %.2f flattens to 0.00 -- the one scale where the ratio to 128
        # hosts is most informative would be the one that reads as zero.
        self.logger.warning(
            "install_all_pair_paths done: hosts=%d pairs=%d rules=%d paths=%d "
            "walk=%.3fs install=%.3fs report=%.3fs",
            hosts, hosts * (hosts - 1), rules_installed, len(all_destination_paths),
            walk_seconds, walk_seconds - report_seconds, report_seconds)
                        


    @set_ev_cls(ofp_event.EventOFPPacketIn, MAIN_DISPATCHER)
    def _packet_in_handler(self, ev):
        # [Co-developed with claude code -- Adam] see _pktin_count in __init__.
        if self._pktin_first_t is None:
            self._pktin_first_t = time()
        self._pktin_count += 1
        msg = ev.msg
        datapath = msg.datapath
        dpid = datapath.id
        ofproto = datapath.ofproto
        parser = datapath.ofproto_parser
        in_port = msg.match["in_port"]

        pkt = packet.Packet(msg.data)
        eth = pkt.get_protocol(ethernet.ethernet)

        # Ignore LLDP packets
        if eth.ethertype == ether_types.ETH_TYPE_LLDP:
            # self.logger.info("LLDP from switch %s", dpid)
            return

        # Ignore ARP packets
        arp_pkt = pkt.get_protocol(arp.arp)
        if arp_pkt:
            return

        # Ignore mDNS, SSDP, LLMNR
        if eth.ethertype == ether_types.ETH_TYPE_IP:
            ip_pkt = pkt.get_protocol(ipv4.ipv4)

            # Define a set of multicast IPs to ignore.
            # This is more efficient than multiple 'if' statements.
            multicast_ips_to_ignore = {
                "224.0.0.251",  # mDNS (Multicast DNS)
                "224.0.0.252",  # LLMNR (Link-Local Multicast Name Resolution)
                "239.255.255.250",  # SSDP (Simple Service Discovery Protocol)
            }

            # If the destination IP is in our ignore list, simply drop the packet and return.
            if ip_pkt.dst in multicast_ips_to_ignore:
                # self.logger.debug(f"Ignoring multicast packet to {ip_pkt.dst} from DPID {dpid}")
                return

        # self.logger.info("Packet in triggered")

        eth_dst = eth.dst
        eth_src = eth.src

        ip_pkt = pkt.get_protocol(ipv4.ipv4)

        if not ip_pkt:
            return  # Only process IPv4 packets

        ip_dst = ip_pkt.dst
        ip_src = ip_pkt.src

        tcp_pkt = pkt.get_protocol(tcp.tcp)
        udp_pkt = pkt.get_protocol(udp.udp)
        icmp_pkt = pkt.get_protocol(icmp.icmp)

        if icmp_pkt:  # Use ping to let Ryu detect all IPs (IP alias)
            port_no = in_port
            # print(f"ip_src {ip_src} packet in")
            host_id = eth_src
            # if self.install_initial_openflow_entries_completed == True:
            #     print(f"ip_src {ip_src} packet in")
            
            # self.logger.info(f"self.is_dynamically_detect_topo {self.is_dynamically_detect_topo}")
            if self.is_dynamically_detect_topo:
                # self.logger.info(f"packet in host_id {host_id}")
                if not self.dynamic_net.has_node(host_id):
                    # self.logger.info("self.dynamic_net.add_node")
                    self.dynamic_net.add_node(host_id, ip_list=[ip_src])
                else:
                    # self.logger.info("else self.dynamic_net.add_node")
                    ip_list = self.dynamic_net.nodes[host_id]["ip_list"]
                    if ip_src not in ip_list:
                        ip_list.append(ip_src)

                if not self.dynamic_net.has_edge(dpid, host_id):
                    self.dynamic_net.add_edge(dpid, host_id, port=port_no)

                if not self.dynamic_net.has_edge(host_id, dpid):
                    self.dynamic_net.add_edge(host_id, dpid, port=0)
           

    @set_ev_cls(event.EventLinkDelete)
    def on_link_delete(self, ev):
        self.logger.warning("Link deleted: %s", ev.link)
        link = ev.link
        src_dpid = link.src.dpid
        src_port = link.src.port_no
        dst_dpid = link.dst.dpid
        dst_port = link.dst.port_no

        # [Co-developed with claude code -- Adam]
        # Our own state first, the remote notification second.
        #
        # The graph is a DiGraph and EventLinkDelete fires once per direction, so removing the one
        # directed edge named by this event is exactly right -- when both directions die, the
        # paired event removes the other. A unidirectional failure fires only this one event and
        # the asymmetry is then a steady state, which is why install_all_pair_paths refuses to
        # walk a link that is missing its reverse edge (live 2026-08-13: recompute crashed on the
        # asymmetric graph and traffic blackholed until the link recovered).
        # Without this the graph kept a link that was down, and every path computed from it was
        # wrong, silently.
        #
        # This used to sit *below* the notification, which meant it inherited an unbounded
        # `requests.post`. A refused connection returns at once, but a process that accepts and never
        # answers blocks forever and raises nothing, so the `except` below does not help -- and
        # HANDOFF 1j records a wedged kernel holding :8000 biting three times. The edge would never
        # have been removed and no reinstall scheduled: exactly the pre-2c81b26 behaviour, silently.
        # Beyond the hang, this graph is this application's own state and has no business being
        # conditional on a remote call at all.
        net = self._active_net()
        if net.has_edge(src_dpid, dst_dpid):
            net.remove_edge(src_dpid, dst_dpid)
            self.logger.warning("removed edge %s -> %s from the routing graph", src_dpid, dst_dpid)
        self._schedule_route_reinstall(f"link {src_dpid} -> {dst_dpid} down")

        # Notify NDT
        api_url = "http://localhost:8000/ndt/link_failure_detected"

        headers = {"Content-Type": "application/json"}

        data = {
            "src_dpid": src_dpid,
            "src_interface": src_port,
            "dst_dpid": dst_dpid,
            "dst_interface": dst_port,
        }

        try:
            # (connect, read). Without a timeout this blocks indefinitely against a listener that
            # accepts and never replies, parking the greenlet.
            response = requests.post(api_url, json=data, headers=headers, timeout=(2, 5))
            self.logger.warning("Notified NDT, status code: %s", response.status_code)
            # See the R-1 note at the switch-enter site: requests does not raise on 4xx/5xx,
            # so this line alone cannot distinguish accepted from rejected.
            if response.status_code >= 400:
                self.logger.warning(
                    "NDT REJECTED this notification: HTTP %s from %s -- delivered but not "
                    "accepted; the kernel's view is now stale",
                    response.status_code, api_url
                )
        except Exception as e:
            self.logger.warning("Failed to notify NDT: %s", str(e))

    @set_ev_cls(event.EventLinkAdd)
    def on_link_add(self, ev):
        self.logger.warning("Link added: %s", ev.link)
        link = ev.link
        src_dpid = link.src.dpid
        src_port = link.src.port_no
        dst_dpid = link.dst.dpid
        dst_port = link.dst.port_no

        # [Co-developed with claude code -- Adam]
        # Applied to whichever graph this run computes routes from. It used to update dynamic_net
        # only, so in static-topology mode -- the mode the user manual documents -- a link coming
        # back was never reflected, and after on_link_delete started removing edges that would have
        # made the loss permanent.
        #
        # Only the direction this event names is added, matching on_link_delete. The reverse arrives
        # as its own event; adding it here from dst_port would guess at a link that may not be up.
        net = self._active_net()
        if not net.has_edge(src_dpid, dst_dpid):
            net.add_edge(src_dpid, dst_dpid, port=src_port)
            self.logger.info(
                "Added edge to the routing graph: %s:%s -> %s:%s",
                src_dpid,
                src_port,
                dst_dpid,
                dst_port,
            )

        # [Co-developed with claude code -- Adam] As on_link_delete: a link coming back is a
        # topology change, and routes that were moved off it should be able to move back.
        #
        # Scheduled before the notification, for the same reason the edge removal in on_link_delete
        # is: this is local state and must not be conditional on a remote call. It used to sit below
        # an unbounded requests.post, so a kernel that accepted the connection and never answered
        # would block here forever -- raising nothing, so the `except` did not help -- and the routes
        # would never move back onto the recovered link.
        self._schedule_route_reinstall(f"link {src_dpid} -> {dst_dpid} up")

        # Notify NDT link is recovered
        api_url = "http://localhost:8000/ndt/link_recovery_detected"

        headers = {"Content-Type": "application/json"}

        data = {
            "src_dpid": src_dpid,
            "src_interface": src_port,
            "dst_dpid": dst_dpid,
            "dst_interface": dst_port,
        }

        try:
            response = requests.post(api_url, json=data, headers=headers, timeout=(2, 5))
            self.logger.warning("Notified NDT, status code: %s", response.status_code)
            # See the R-1 note at the switch-enter site: requests does not raise on 4xx/5xx,
            # so this line alone cannot distinguish accepted from rejected.
            if response.status_code >= 400:
                self.logger.warning(
                    "NDT REJECTED this notification: HTTP %s from %s -- delivered but not "
                    "accepted; the kernel's view is now stale",
                    response.status_code, api_url
                )
        except Exception as e:
            self.logger.warning("Failed to notify NDT: %s", str(e))

    @set_ev_cls(ofp_event.EventOFPFlowStatsReply, MAIN_DISPATCHER)
    def flow_stats_reply_handler(self, ev):
        dpid = ev.msg.datapath.id
        stats = []

        for stat in ev.msg.body:
            # Safely extract match
            try:
                match = {k: v for k, v in stat.match.items()}
            except Exception as e:
                self.logger.error("Failed to extract match for DPID %s: %s", dpid, e)
                match = {}

            # Extract instructions and actions
            actions_list = []
            for instruction in stat.instructions:
                if hasattr(instruction, "actions"):
                    for action in instruction.actions:
                        action_info = {
                            "type": action.__class__.__name__,
                            "port": getattr(action, "port", None),
                            "max_len": getattr(action, "max_len", None),
                        }
                        actions_list.append(action_info)

            entry = {
                "table_id": stat.table_id,
                "priority": stat.priority,
                "match": match,
                "instructions": actions_list,
                "duration_sec": stat.duration_sec,
                "packet_count": stat.packet_count,
                "byte_count": stat.byte_count,
            }
            stats.append(entry)

        self.flow_stats_reply[dpid] = stats
        # self.logger.info(
        #     "Flow stats for DPID %s: %s", dpid, json.dumps(stats, indent=2)
        # )




# For NDT API
class RyuServerController(ControllerBase):
    # use the same key you passed to wsgi.register()
    def __init__(self, req, link, data, **config):
        super().__init__(req, link, data, **config)
        self.ndt_app = data[RYU_SERVER_INSTANCE_NAME]

    @route("ndt", "/ryu_server/all_destination_paths", methods=["GET", "POST"])
    def get_all_paths(self, req, **kwargs):
        print("all_destination_paths in")
        payload = {
            "status": "success",
            "all_destination_paths": self.ndt_app.all_destination_paths
        }
        return Response(
            content_type="application/json",
            body=json.dumps(payload).encode('utf-8')
        )
