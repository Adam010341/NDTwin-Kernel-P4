import asyncio
import hashlib
import json
import os
import socket
import sys
import threading
import uvicorn
from fastapi import FastAPI
from proxy_agent.topology_manager import TopologyManager
from proxy_agent.p4_client import P4RuntimeClient
from proxy_agent.sflow_emitter import SFlowEmitter, load_switch_agent_ips
from proxy_agent.kernel_notifier import KernelNotifier
from proxy_agent.rule_journal import RuleJournal
from proxy_agent import api_routes
from proxy_agent import kernel_notifier
# Decides, at import, which app package this process serves, and prints it. Imported before the
# host table below because the host table is built from the package's topology model.
# [Co-developed with claude code -- Adam]
from proxy_agent import profile
import app_package  # noqa: E402 -- profile put mininet/ on sys.path
import topo_from_json  # noqa: E402

app = FastAPI(title="P4 Proxy Agent", description="Ryu compatible API for BMv2")

# --- the rule journal ---------------------------------------------------------------------
# [Co-developed with claude code -- Adam]
#
# KNOWN-ISSUES A-4c, finding #71. rule_journal.py, its 19 tests and test_journal_wiring.py's 14
# all shipped while the line below read `TopologyManager(kernel_notifier=kernel)`. Every one of
# those tests handed a manager a journal itself, so not one of them could see that PRODUCTION
# handed it none: `_note_in_journal` returned on `self._journal is None` on every call, and the
# journal a restart was meant to read came back empty -- which rule_journal.py's own docstring
# says is read as "there was nothing to fall back on". A component that exists, is documented,
# is committed and has no caller; the suite named "journal wiring" was 14/14 green throughout.
#
# 🔴 RECORDING ONLY. Nothing here replays anything. Replay stays opt-in and off
# (rule_journal.REPLAY_ENV_VAR) and still has no call site anywhere -- see rule_journal.py for
# why re-applying requests whose reasons have expired is a decision rather than a default.

#: Overrides where the journal is written. It exists so a test can point the *real* construction
#: path at a temp directory instead of writing into the checkout: wiring is only worth asserting
#: when it can be asserted on the production factory rather than on a copy of it.
RULE_JOURNAL_PATH_ENV_VAR = "NDTWIN_RULE_JOURNAL_PATH"

#: Under `.run/` rather than the proxy root so the checkout does not grow a file per artefact,
#: and gitignored there (see the repo .gitignore) because a journal is per-machine state.
DEFAULT_RULE_JOURNAL_RELPATH = os.path.join(".run", "rule_journal.jsonl")


def default_journal_path():
    """
    Where the journal lives when nobody has said otherwise.

    [Co-developed with claude code -- Adam]
    Anchored to THIS FILE, not to the working directory. stack.sh happens to cd into p4_proxy
    before launching (`cd '$KERNEL_DIR/p4_proxy' && python proxy_agent/main.py`), but nothing
    enforces that, and a cwd-relative path would mean a proxy restarted from anywhere else opens
    a different, empty file and reports "nothing to replay" -- the precise failure the journal
    exists to prevent, arriving as a reassuring sentence. The path has to be the same string on
    the next run or the record is one nobody can find.

    Same derivation as `build_p4_client`'s base_dir, so the journal sits beside the p4info and
    JSON artefacts this proxy already resolves that way.
    """
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base_dir, DEFAULT_RULE_JOURNAL_RELPATH)


def build_rule_journal(env=None):
    """
    The journal this proxy records accepted rule writes into.

    `env` is injectable so the path decision stays a pure function of its input rather than of
    process state -- the argument `RuleJournal.replay_enabled` makes for its own gate.
    """
    if env is None:
        env = os.environ
    override = str(env.get(RULE_JOURNAL_PATH_ENV_VAR, "")).strip()
    return RuleJournal(override or default_journal_path())


journal = build_rule_journal()

# [Co-developed with claude code -- Adam]
# Pushes switch/link state to the kernel the way Ryu does. The push is the fast path for
# isEnabled, not the only one -- the kernel's topology poll enables reported switches itself
# (TopologyAndFlowMonitor.cpp:566). See kernel_notifier.py's module docstring and Phase 6 of
# doc/2026-07-27_p4_bmv2_support_plan.md.
kernel = KernelNotifier()

# Built with the notifier already in hand: the beacon watchdog reports link failures through it,
# and a TopologyManager constructed without one silently keeps the bookkeeping to itself. Same
# argument for the journal, and it was the one that went unmade: a manager constructed without
# one silently keeps every rule install to itself too, and the only place that shows is a
# restart with nothing to fall back on. [Co-developed with claude code -- Adam]
topo = TopologyManager(kernel_notifier=kernel, journal=journal)

# Build the static topology (Matches MultiSwitchTopo)
#
# [Co-developed with claude code -- Adam]
# This block was four hard-coded add_host calls for 10.0.0.1-4, then a "quarters" formula
# (`1 + (i-1)//(N//4)`, ports from 3) that reproduced them at any multiple of four. That is why
# P4 had never been measured at 128 hosts: the fabric builds fine (verified -- 10/10 bmv2
# switches up, twin sees 10 switches / 128 hosts / 288 edges), but the proxy only ever knew four
# hosts, and at 128 the hard-coded switch/port were also WRONG -- h2 sits on s1 port 4 in that
# layout, not s2 port 3 -- so even the hosts it did know were unreachable.
#
# The formula is gone now too. It was the THIRD statement of a layout the kernel's topology model
# already states exactly, and it could only ever describe a fabric whose hosts divide evenly over
# s1-s4 -- pod-topo's four hosts sit on four different switches in four different /24s, so the
# formula would have attached every one of them to the wrong port while reporting nothing.
# `tools/test_workflow/test_topo_from_json.py` asserts that what the model produces here is
# element-for-element what the formula produced, at 4 hosts and at 128.


def load_fabric_model(package=None, host_count=None):
    """The topology model this proxy describes: the package's, or the one the host count picks.

    Same decision the Mininet side makes (p4_testbed_topo.fabric_model), through the same two
    functions, because a proxy and a fabric that chose different models is the 2026-08-21 defect
    -- routes computed for 128 hosts on a 4-host fabric, every topology view reading correct.
    """
    package = profile.current() if package is None else package
    if host_count is None:
        host_count = topo_from_json.host_count_override()
    return topo_from_json.load(app_package.topology_path(package, host_count))


def build_host_table(topo, model, package=None):
    """Tell `topo` where every host in `model` plugs in. Returns what it added, for tests.

    Injectable rather than inline so the equivalence with the formula it replaces is assertable
    without a TopologyManager, a model file or an import of this module's globals.
    """
    package = profile.current() if package is None else package
    attach = {name: (dpid, port) for name, dpid, port in topo_from_json.host_links(model)}
    added = []
    for name, ip, mac in topo_from_json.hosts(model):
        where = attach.get(name)
        if where is None:
            # Refused, not skipped. A host in the model with no access link is a host the proxy
            # would compute paths *to* and never be able to program a route for, and the symptom
            # is an empty path rather than an error. topo_from_json.host_links raises for a host
            # attached twice; this is the other half of that check.
            raise topo_from_json.TopologyModelError(
                f"host {name} ({ip}) has no access link in the topology model; the proxy would "
                f"route to it and never be able to install the rule")
        dpid, port = where
        mac_str = topo_from_json.mac_str(mac, name)
        topo.add_host(ip=ip, mac=mac_str, switch_dpid=dpid, port=port)
        added.append((ip, mac_str, dpid, port))
    return added


def switch_dpids(model):
    """The dpids this proxy expects, from the model. `(1, ..., 10)` for both baseline models."""
    return tuple(dpid for dpid, _name in topo_from_json.switches(model))


MODEL = load_fabric_model()
build_host_table(topo, MODEL)

# Links will be discovered dynamically via LLDP

api_routes.inject_topology(topo)
app.include_router(api_routes.router)

# [Co-developed with claude code -- Adam]
# There is deliberately no module-global `p4_clients` here any more. There used to be one,
# assigned once from startup()'s summary and iterated by shutdown_event -- a second copy of a
# mapping TopologyManager already owns. POST /p4/readopt/{dpid} replaces topo.switches[dpid]
# with a freshly built client, and that copy did not follow: shutdown then stopped the
# already-stopped old client and left the new one's channel and receiver thread running.
# topo.switches is the authority, so shutdown reads it directly. (The Phase 7 design doc said
# this swap was safe because only api_routes and main held references -- main's reference was
# exactly the problem.)
# [Co-developed with claude code -- Adam]
# Ticket E wiring. batch_size defaults to 1, which the emitter documents as byte-for-byte the old
# behaviour -- so with the variable unset nothing changes, and the A/B differs by one value.
#
# 🔴 An env var whose reader does not exist is this repo's most-repeated bug shape: NDTWIN_CLONE_DISABLE
# shipped a committed setter, committed docs and zero readers, so a run that set it was sampling
# normally while being labelled a zero point. This IS the reader. The gate does not take its
# existence on trust either -- it checks that the datagram count actually falls, which is the only
# evidence that the value reached the emitter.
sflow = SFlowEmitter(batch_size=int(os.environ.get("NDTWIN_SFLOW_BATCH", "1")))

#: How long to let mastership settle before pushing pipelines. bmv2 accepts the arbitration
#: message before it has finished electing, and a config push in that window is rejected.
MASTERSHIP_SETTLE_S = 1.0

#: The switches this proxy expects, and how their gRPC ports are numbered. Derived from the
#: topology model rather than written as `range(1, 11)`: that literal was one of four copies of
#: "this fabric has ten switches" and the only one the proxy owned, so a fabric built from a
#: model with a different switch count left the proxy dialling ports nothing listens on and
#: ignoring switches that were up. Both 10-switch models produce (1, ..., 10), which
#: tests/test_app_package.py asserts. Named so a test can drive `startup` over two fake switches
#: without pretending there are ten. [Co-developed with claude code -- Adam]
DEFAULT_SWITCH_DPIDS = switch_dpids(MODEL)

# [Co-developed with claude code -- Adam]
# Imported, not written again. This was `DEFAULT_GRPC_PORT_BASE = 50050`, a second copy of the
# number p4_testbed_topo.py assigns from -- the fabric picks the ports and this file dials
# them, and nothing tied the two together. F-15 had to change that number (50051-50060 sat
# inside the kernel's ephemeral range, so switches randomly failed to bind); had the copies
# stayed, changing one of them would have left the proxy dialling ports no switch listens on,
# which presents as "the whole fabric is down" rather than as an edit that was half applied.
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mininet"))
from grpc_ports import GRPC_PORT_BASE  # noqa: E402

DEFAULT_GRPC_PORT_BASE = GRPC_PORT_BASE


def build_p4_client(dpid, port_base=DEFAULT_GRPC_PORT_BASE, package=None):
    """
    Construct (but do not start) the client for one switch.

    [Co-developed with claude code -- Adam]
    Extracted from build_p4_clients for POST /p4/readopt/{dpid}: after a power-cycle the old
    client object is unusable (closed channel, poisoned queue, dead receiver thread), and
    this is the single place that knows how a dpid becomes an address and a pair of artifact
    paths. Unstarted on purpose -- readopt owns its own start/settle/push sequence, and
    build_p4_clients starts its batch itself.

    The artefact paths and the election id now come from the app package. Without one that is
    `p4_src/build/ndtwin_switch.{p4info.txt,json}` and `(0, 1)` -- the two literals this call
    used to spell out -- so a baseline fabric builds the identical client.
    """
    package = profile.current() if package is None else package
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p4info_path, json_path = package.pipeline_for(dpid, base_dir)
    return P4RuntimeClient(
        device_id=dpid,
        grpc_addr=f'localhost:{port_base + dpid}',
        p4info_path=p4info_path,
        json_path=json_path,
        election_id=package.election_id,
        # 🔴 `external` means the exercise brought its own controller. This client then opens no
        # arbitration stream and refuses every write -- see P4RuntimeClient and startup() for
        # what that switches off and where it is disclosed.
        arbitration=package.arbitration,
    )


# --- what this proxy is not doing, and why. [Co-developed with claude code -- Adam] ---------
#
# 🔴 SKIPPING IS NOT SILENCE. Under `control_plane.mode: external` the proxy deliberately does
# not push a pipeline, does not program a clone session, does not beacon LLDP, does not watch
# links and does not install routes -- every one of which is a thing the twin normally reports
# on. A switch with no telemetry reports zero samples; a fabric with no LLDP reports no links; a
# fabric with no routes reports empty paths. All three of those look EXACTLY like a fault, which
# is GAP-ANALYSIS section 5's "reports zero rather than reporting an error". So each skipped step
# is named here, returned by startup(), and served on `GET /p4/switch_state`.
#
# 🔴 THE NAMES LIVE HERE, ABOVE THE PIPELINE SECTION, because the per-switch disclosure below
# needs them. They used to sit further down, next to `_control_plane`, and every reader of them
# was a function body -- so a forward reference worked by accident of call order. TICKET-P2
# round 2 gave `pipeline_report_for` a `skipped` list, which is built from these at import time,
# and that is exactly the call that would have found them undefined.
#
#: The step names startup() reports. Written down rather than built from strings at the call
#: sites so that a step which stops being skipped, or starts being, changes this list too.
SKIP_PIPELINE = "pipeline_push"
SKIP_CLONE = "clone_session"
SKIP_TELEMETRY = "sflow_telemetry"
SKIP_LLDP = "lldp_discovery"
SKIP_WATCHDOG = "link_watchdog"
SKIP_ROUTES = "install_initial_routes"

#: Everything `external` turns off, in the order startup() would have done it.
EXTERNAL_SKIPS = (SKIP_PIPELINE, SKIP_CLONE, SKIP_TELEMETRY, SKIP_LLDP, SKIP_WATCHDOG,
                  SKIP_ROUTES)

#: What a FOREIGN pipeline turns off ON ONE SWITCH, reported in that switch's own `pipeline`
#: object rather than in the fabric-wide `control_plane.skipped`.
#:
#: 🔴 The distinction is the whole point and it was got wrong once (TICKET-P2 round 2, found by
#: the judge). A mixed fabric -- one package switch beside nine NDTwin ones -- DOES program a
#: clone session, on the nine. Putting `clone_session` in the fabric-wide list there says
#: something about the whole fabric that is true of one switch, and a reader who acts on it goes
#: looking for a telemetry fault on nine switches that have none.
FOREIGN_PIPELINE_SWITCH_SKIPS = (SKIP_CLONE, SKIP_TELEMETRY)

#: What a foreign pipeline ANYWHERE turns off for the WHOLE fabric. All three ride packet-out /
#: packet-in through a controller header a tutorials pipeline does not declare, and a beacon
#: leaves one switch to arrive at another -- so one foreign switch is enough to make the answer
#: no for every link. TICKET-P2 2.2 (:48) names exactly these three.
FOREIGN_PIPELINE_FABRIC_SKIPS = (SKIP_LLDP, SKIP_WATCHDOG, SKIP_ROUTES)


# --- whose pipeline is on each switch (G4/G5). [Co-developed with claude code -- Adam] -------
#
# A package may now name its own compiled artefacts per switch, and almost everything this proxy
# does to a switch assumes NDTwin's: the clone session targets a session ndtwin_switch.p4
# declares, the telemetry path reads a header only that program emits, LLDP rides packet-in /
# packet-out through a controller header a tutorials pipeline does not have at all (measured on
# the p4info: ndtwin_switch declares 2 controller_packet_metadata, `basic` and `source_routing`
# declare none), and install_initial_routes writes `MyIngress.ipv4_lpm` by name.
#
# So the question "is this switch running our pipeline" decides several branches below, and it
# has exactly one definition:


def proxy_root():
    """The p4_proxy directory -- what the package's relative artefact paths resolve against.

    Same derivation as `build_p4_client` and `default_journal_path`, named once so the three
    cannot answer differently for the same process.
    """
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _pipeline_is_ndtwin(package, dpid, base_dir=None):
    """
    Whether switch `dpid` runs NDTwin's own compiled pipeline under this package.

    [Co-developed with claude code -- Adam]
    🔴 ONE DEFINITION, ON `Package`. This used to compute the equivalence here -- TICKET-P2 2.1
    (:44) forbade importing ticket A's `Package.pipeline_is_ndtwin` while the two branches were
    being written in parallel, because an import would have made this branch unable to run until
    the other landed. A is merged, so the rule collapses onto its owner exactly as the ticket
    said it would, and what is left here is the default for `base_dir`: every caller in this file
    means the p4_proxy root, and making each of them say so was ten chances to say something
    else.

    The predicate itself is a comparison of RESOLVED PATHS, not `spec.pipeline is not None` --
    see app_package.pipeline_is_ndtwin for why that distinction is not cosmetic.
    """
    base_dir = proxy_root() if base_dir is None else base_dir
    return package.pipeline_is_ndtwin(dpid, base_dir)


# --- where each switch's samples come from (TICKET-P3 2.1). [Co-developed with claude code -- Adam]
#
# One word, three readers: this proxy, the fabric bring-up (which hangs `tc ... action sample`
# filters and runs the psample emitter) and `ndt` (which writes the knob and prints it). They
# must agree per switch, because the two sources DOUBLE-COUNT if both run: the pipeline clones a
# sampled packet to the CPU port and the veth filter samples the same packet on the wire, and
# the kernel adds both into the same link's byte total. Nothing errors; every rate reads twice
# what it should, uniformly -- the exact shape the 2026-08-16 clone-stacking incident had.
#
#   none         nothing samples. The control arm of the three-group measurement.
#   cooperative  today's path: the P4 pipeline clones to the CPU, this proxy synthesises sFlow.
#   link         the switch-side veths are sampled instead; this proxy does NOT program a clone
#                session and does NOT register the switch with the emitter.
#   auto         per switch: NDTwin's pipeline -> cooperative, anybody else's -> link.

TELEMETRY_AUTO = "auto"
TELEMETRY_NONE = "none"
TELEMETRY_COOPERATIVE = "cooperative"
TELEMETRY_LINK = "link"

#: The resolved values -- what `_telemetry_source` may return.
TELEMETRY_SOURCES = (TELEMETRY_NONE, TELEMETRY_COOPERATIVE, TELEMETRY_LINK)
#: Everything that may be WRITTEN, knob or package. `auto` is a question, not an answer.
TELEMETRY_WORDS = (TELEMETRY_AUTO,) + TELEMETRY_SOURCES

#: The knob `ndt up p4 --telemetry <word>` writes, beside `host_count_override` and the app
#: package knob and in the same directive-file shape. A file rather than an environment
#: variable for the reason app_package.KNOB_PATH is one: the proxy, the topology script and
#: `ndt` are three processes started by three different parents.
TELEMETRY_KNOB_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mininet", "telemetry_override")


class TelemetryConfigError(RuntimeError):
    """
    The telemetry configuration is one this proxy will not start under.

    [Co-developed with claude code -- Adam]
    🔴 A REFUSAL, NOT A WARNING (TICKET-P3 2.1). Both cases it covers -- a knob naming a word
    that is not a telemetry source, and a switch asked for `cooperative` whose program has no
    controller header -- produce a fabric that comes up, connects, pushes pipelines, accepts a
    clone session and then reports ZERO samples for the whole run. A warning about that scrolls
    past in a tmux pane and the measurement it silently spoiled is discovered days later, if at
    all. See doc/audit/2026-08-20 for the last time a telemetry knob failed quietly.
    """


def read_telemetry_knob(path=None):
    """
    The telemetry word this machine is configured for, or None when the file is absent.

    [Co-developed with claude code -- Adam]
    First non-blank, non-`#` line wins -- `host_count_override`'s shape, so an operator who has
    seen one directive file has seen all of them. Absent means `auto`, which is why the absence
    is a plain None and not an error: `ndt down` deletes the file and the next bring-up is the
    baseline.

    A word outside the value domain RAISES rather than falling back to `auto`. The fallback is
    what makes a typo ("cooperatvie") into a silent change of measurement conditions -- and this
    knob exists precisely so that three processes agree, so the one that cannot read it must not
    guess.
    """
    path = path or TELEMETRY_KNOB_PATH
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line not in TELEMETRY_WORDS:
                raise TelemetryConfigError(
                    f"{path}: {line!r} is not a telemetry source. Expected one of "
                    f"{', '.join(TELEMETRY_WORDS)}. A fabric started on a word nobody reads "
                    f"samples nothing and reports zero, which is indistinguishable from a "
                    f"fabric with no traffic")
            return line
    raise TelemetryConfigError(
        f"{path}: exists but names no telemetry source. Delete the file for 'auto' -- an empty "
        f"knob is a half-finished write, not a default")


def package_telemetry_source(package):
    """What the app package DECLARES, as a word in TELEMETRY_WORDS.

    [Co-developed with claude code -- Adam]
    Read with getattr rather than as an attribute: `Package.telemetry_source` is ticket B's
    field (TICKET-P3 2.1) and this branch was written in parallel with it, so until B lands
    every package answers the default. That is not a workaround -- it is the same arrangement
    TICKET-P2 2.1 used for `pipeline_is_ndtwin`, and it means this file's branches are exercised
    from the day they are written instead of waiting on somebody else's merge.
    """
    declared = getattr(package, "telemetry_source", TELEMETRY_AUTO)
    word = str(declared or TELEMETRY_AUTO)
    if word not in TELEMETRY_WORDS:
        raise TelemetryConfigError(
            f"app package {package.name!r} declares telemetry source {declared!r}, which is not "
            f"one of {', '.join(TELEMETRY_WORDS)}")
    return word


def _telemetry_source(package, dpid, knob_path=None, base_dir=None):
    """
    Where switch `dpid`'s samples come from: `none`, `cooperative` or `link`. Never `auto`.

    [Co-developed with claude code -- Adam]
    🔴 THE LOCAL EQUIVALENT OF `app_package.telemetry_source`, ON PURPOSE (TICKET-P3 2.1). Ticket
    B owns that function and is being written beside this one; importing it would make every
    branch here unrunnable until B merged, and the orchestrator collapses the two afterwards --
    exactly as TICKET-P2 2.1 did with `pipeline_is_ndtwin`, which is now one function called
    from here. Three layers, most specific first:

      1. the knob, when it names a source. An operator who typed `--telemetry link` means it for
         this fabric, whatever the package prefers.
      2. the package, when it declares one.
      3. `auto`, which is PER SWITCH: our pipeline can clone to the CPU port and somebody else's
         cannot, so a mixed fabric gets cooperative telemetry on our switches and link telemetry
         on theirs -- and the whole fabric is measured either way, which is the point.
    """
    knob = read_telemetry_knob(knob_path)
    if knob and knob != TELEMETRY_AUTO:
        return knob
    declared = package_telemetry_source(package)
    if declared != TELEMETRY_AUTO:
        return declared
    return (TELEMETRY_COOPERATIVE if _pipeline_is_ndtwin(package, dpid, base_dir)
            else TELEMETRY_LINK)


def _p4info_fingerprint(path):
    """`sha256[:16]` of a p4info file, or None if it cannot be read.

    A stable identifier for "which program is this", per CLAUDE.md's rule that a benchmark names
    its binary. The bmv2 JSON is deliberately NOT fingerprinted: it carries the absolute path of
    the source in a `program` field, so the same program compiled in two directories has two
    hashes and the difference says nothing.
    """
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()[:16]
    except OSError:
        return None


def pipeline_report_for(dpid, package=None):
    """
    What `GET /p4/switch_state` says about one switch's pipeline.

    [Co-developed with claude code -- Adam]
    `skipped` is PER SWITCH and is not the same list as `control_plane.skipped`. The clone
    session and the sFlow registration are programmed into one switch's own PRE, so on a mixed
    fabric they are skipped for the package's switches and done for everybody else -- which is a
    sentence about a switch, not about a fabric. Empty for an NDTwin switch, and emitted anyway:
    `[]` says "nothing was skipped here", and an absent key cannot be told from a proxy too old
    to have one.
    """
    package = profile.current() if package is None else package
    base_dir = proxy_root()
    p4info_path, _json_path = package.pipeline_for(dpid, base_dir)
    ndtwin = _pipeline_is_ndtwin(package, dpid, base_dir)
    return {"ndtwin": ndtwin,
            "p4info": p4info_path,
            "p4info_sha256": _p4info_fingerprint(p4info_path),
            "skipped": [] if ndtwin else sorted(FOREIGN_PIPELINE_SWITCH_SKIPS)}


def package_entries_path(package, dpid):
    """The runtime-entries file this package declares for one switch, or None."""
    for spec in package.switches:
        if spec.dpid == int(dpid):
            return spec.entries
    return None


def apply_package_entries(client, entries_path):
    """
    Write every entry a package declares for one switch. Returns counts; never raises.

    [Co-developed with claude code -- Adam]
        {"applied": n, "failed": n, "errors": ["<table>: <reason>", ...]}

    🔴 One refused entry does not stop the rest, and it does not take startup down either. A
    tutorials runtime file is a list of independent rules: `ipv4_lpm` entries for four hosts plus
    a default action, say. Stopping at the first failure would leave a fabric programmed up to an
    arbitrary point with no record of where, and raising would put us back in the state the
    per-switch guard around the pipeline push was written to fix -- one switch's problem ending
    the whole proxy's startup.

    Each failure is printed AND counted AND named in `errors`. The count reaches
    `GET /p4/switch_state` as `table_entries.failed`, because "the package's rules are not on
    this switch" has to be a number somewhere: a fabric that forwards nothing because five
    inserts were refused looks, from every other view, exactly like a fabric whose links are
    down.
    """
    out = {"applied": 0, "failed": 0, "errors": []}
    if not entries_path:
        return out
    try:
        with open(entries_path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        # Counted as neither applied nor failed, because with no file there is no denominator:
        # how many entries it held is exactly what could not be read. `errors` is the disclosure,
        # and app_package.load already refuses a package whose entries file will not parse, so
        # reaching this means the file changed under a running proxy.
        out["errors"].append(f"{entries_path} could not be read: {type(exc).__name__}: {exc}")
        print(f"[Proxy Agent] switch {getattr(client, 'device_id', '?')}: {out['errors'][-1]}")
        return out
    entries = doc.get("table_entries") or []
    for index, spec in enumerate(entries):
        table = spec.get("table") if isinstance(spec, dict) else None
        op = spec.get("op", "insert") if isinstance(spec, dict) else "insert"
        try:
            client.write_table_entry(spec, op)
            out["applied"] += 1
        except Exception as exc:  # noqa: BLE001 -- one entry must not cost the other four
            out["failed"] += 1
            out["errors"].append(f"entry {index} ({table}): {type(exc).__name__}: {exc}")
            print(f"[Proxy Agent] switch {getattr(client, 'device_id', '?')}: table entry "
                  f"{index} into {table} was NOT applied -- {type(exc).__name__}: {exc}")
    return out


def build_p4_clients(dpids=DEFAULT_SWITCH_DPIDS, port_base=DEFAULT_GRPC_PORT_BASE):
    """
    Connect to each bmv2 switch and return {dpid: client} for the ones that came up.

    [Co-developed with claude code -- Adam]
    Split out of `startup` as the injection point for tests: everything else in startup is
    decision-making about which switches to claim, and this is the only part that needs a real
    gRPC channel. Note that grpc connects lazily, so a client returned here has *not* been
    proven reachable -- `set_forwarding_pipeline_config` in startup is the first real round trip.
    """
    clients = {}
    for i in dpids:
        try:
            client = build_p4_client(i, port_base)
            client.start(push_config=False)
            clients[i] = client
        except Exception as e:
            print(f"[Proxy Agent] Failed to connect to Switch {i}: {e}")
    return clients


# The emitter itself, for GET /sflow/stats. [Co-developed with claude code -- Adam]
# Ticket P needs the send-side counters readable; sflow_emitter.py is deliberately untouched
# because four measurement rounds were taken against its current uncommitted contents.
api_routes.inject_emitter(sflow)


#: The live control-plane report, served on `GET /p4/switch_state`. `skipped` is None until
#: startup() has run, and that is not the same statement as `[]`: "nothing was skipped" and
#: "nobody has started yet" are the two answers this disclosure exists to keep apart.
_control_plane = {"mode": profile.current().mode, "package": profile.current().dir,
                  "skipped": None}


def control_plane_report():
    """What the proxy is and is not doing to this fabric. A copy, so a reader cannot edit it."""
    return dict(_control_plane)


def _record_control_plane(package, skipped):
    _control_plane.update({"mode": package.mode, "package": package.dir,
                           "skipped": sorted(skipped)})
    return control_plane_report()


def entries_recorded_report():
    """{dpid as string: entries the package declares}. How many, never which."""
    return profile.current().entries_recorded()


# --- what is running on each switch, and what got written to it. TICKET-P2 2.2 ---------------
# [Co-developed with claude code -- Adam]
#
# Two more per-switch disclosures, for the same reason `entries_recorded` exists: under a foreign
# pipeline this proxy stops doing several things, and every one of them presents downstream as a
# fault rather than as a decision.
#
#   pipeline       {"ndtwin": bool, "p4info": <abs>, "p4info_sha256": <16 hex>}
#   table_entries  {"recorded", "applied", "failed", "api_writes", "journaled"}
#
# `journaled` is a constant `False` and is emitted anyway (Adam 2026-09-18, option a): entries
# applied here are NOT written to the rule journal, so they are gone after a proxy restart and
# nothing replays them. A field that says so is the difference between an operator who knows to
# re-run `ndt up p4 --app` and one who finds an empty table with no explanation.

#: Accepted `POST /p4/table_entry` writes, per switch, for the life of this process. Separate
#: from `applied`, which counts only what the package's own entries file put on the switch: an
#: operator asking "where did these rules come from" is asking exactly which of the two, and one
#: combined number cannot answer it.
_api_writes = {}

#: 🔴 `+= 1` is a read, an add and a store, and the store is not the read's turn of the GIL.
#: `POST /p4/table_entry` runs its write on FastAPI's threadpool, so two operators posting at
#: once can both read 4 and both write 5 -- one rule counted zero times. Every other dict here
#: is written by startup alone, on the event loop, one whole key at a time; this is the only
#: read-modify-write in the file. Three lines, no test: a lock has no observable behaviour to
#: assert that would not just be re-running the race. [Co-developed with claude code -- Adam]
_api_writes_lock = threading.Lock()


def _describe_pipelines(package, dpids):
    return {str(dpid): pipeline_report_for(dpid, package) for dpid in dpids}


def _blank_entry_counts(package):
    return {dpid: {"recorded": count, "applied": 0, "failed": 0}
            for dpid, count in package.entries_recorded().items()}


#: Filled at import so the endpoint can answer before startup() has run -- the kernel polls it
#: from the moment the port is open -- and re-recorded by startup() against the switches that
#: actually connected.
_pipelines = _describe_pipelines(profile.current(), DEFAULT_SWITCH_DPIDS)
_table_entries = _blank_entry_counts(profile.current())


def pipelines_report():
    """{dpid as string: what that switch's pipeline is}. A copy per switch."""
    return {dpid: dict(entry) for dpid, entry in _pipelines.items()}


def _dpid_order(key):
    return (0, int(key), "") if str(key).isdigit() else (1, 0, str(key))


def table_entries_report():
    """{dpid as string: how many entries were declared, applied, refused and POSTed}."""
    out = {}
    for dpid in sorted(set(_table_entries) | set(_api_writes), key=_dpid_order):
        counts = _table_entries.get(dpid, {"recorded": 0, "applied": 0, "failed": 0})
        out[dpid] = {"recorded": counts.get("recorded", 0),
                     "applied": counts.get("applied", 0),
                     "failed": counts.get("failed", 0),
                     "api_writes": _api_writes.get(dpid, 0),
                     # Not a variable. Nothing in this proxy journals a table entry, and the
                     # constant is emitted so that "these rules do not survive a restart" is
                     # something the endpoint SAYS rather than something a reader has to know.
                     "journaled": False}
    return out


def note_api_table_entry_write(dpid):
    """One accepted `POST /p4/table_entry`. Called by the route, never by startup."""
    key = str(dpid)
    with _api_writes_lock:
        _api_writes[key] = _api_writes.get(key, 0) + 1
        return _api_writes[key]


def _record_table_entries(dpid, recorded, applied, failed):
    _table_entries[str(dpid)] = {"recorded": recorded, "applied": applied, "failed": failed}


# --- what telemetry each switch has, and why. TICKET-P3 2.6 -----------------------------------
# [Co-developed with claude code -- Adam]
#
# 🔴 THE SAME ARGUMENT AS `pipeline.skipped`, one layer up. A switch with `link` telemetry has no
# clone session and is not registered with the emitter, and every one of those absences is also
# what a BROKEN cooperative switch looks like. `pipeline.skipped` already names the two steps --
# and it stays exactly as it was (TICKET-P2 7-7), because they really were skipped -- but it
# cannot say WHY, and "why" is the whole difference between a decision and a fault.
#
#   telemetry  {"source", "clone_session", "sflow_registered", "packet_in_ids", "reason"}
#
# `packet_in_ids` is the five metadata ids this switch's own p4info gave, or null for a program
# that declares no controller header. It is disclosed because G1 made them a per-switch fact:
# "the proxy reads field `egress_port` as id 3" used to be a constant anybody could look up in
# the source, and is now an answer that depends on which program is loaded.

#: {dpid as string: the object above}. Written by startup(), read by the endpoint.
_telemetry = {}

#: Where the fabric bring-up writes what its psample emitter is doing (TICKET-P3 2.5). Read,
#: never written, by this process: the emitter is ticket B's and lives in the topology script's
#: process tree. Absent is the ordinary answer -- no `link` switch, no manifest.
LINK_TELEMETRY_MANIFEST = "/tmp/ndtwin_link_telemetry.json"


def _telemetry_blank(package, dpids):
    """What `telemetry` says before startup has asked a switch anything.

    Resolvable without a client -- the source is a function of the knob, the package and the
    dpid -- so the endpoint answers the kernel's first poll with the truth rather than with a
    null that a reader cannot tell from "this proxy is too old to say".
    """
    out = {}
    for dpid in dpids:
        try:
            source = _telemetry_source(package, dpid)
        except TelemetryConfigError as exc:
            # Recorded, not raised: this runs at import, and a knob nobody can read must fail
            # the STARTUP (where it is a refusal with a message) rather than the module import,
            # which would leave the proxy dead with a traceback and no endpoint to ask.
            out[str(dpid)] = {"source": None, "clone_session": False, "sflow_registered": False,
                              "packet_in_ids": None, "reason": str(exc)}
            continue
        out[str(dpid)] = {"source": source, "clone_session": False, "sflow_registered": False,
                          "packet_in_ids": None,
                          "reason": "startup has not reached this switch yet"}
    return out


def _record_telemetry(dpid, source, clone_session, sflow_registered, packet_in_ids, reason):
    _telemetry[str(dpid)] = {"source": source,
                             "clone_session": bool(clone_session),
                             "sflow_registered": bool(sflow_registered),
                             "packet_in_ids": packet_in_ids,
                             "reason": reason}


def telemetry_report():
    """{dpid as string: that switch's telemetry disclosure}. A copy per switch."""
    return {dpid: dict(entry) for dpid, entry in _telemetry.items()}


def link_emitter_report(path=None):
    """
    A summary of ticket B's psample emitter, or None when there is no manifest.

    [Co-developed with claude code -- Adam]
    🔴 `alive` IS A LIVE CHECK, NOT A FIELD OF THE FILE. The manifest records a pid; a manifest
    left behind by a bring-up that died says the emitter is running just as confidently as one
    written a second ago, and `link` telemetry with a dead emitter is a fabric that samples into
    nothing -- zero on every edge, no error. `/proc/<pid>` is the cheapest question that
    distinguishes them, and it is asked at request time so the answer is never a cached yes.
    ⚠️ It says a process with that pid exists, not that it is the emitter: pids are reused. The
    stronger check (the pid's cmdline) belongs to `ndt verify_p4`, which owns the fabric; this
    endpoint reports what it can cheaply and truthfully see.
    """
    path = path or LINK_TELEMETRY_MANIFEST
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    pid = doc.get("emitter_pid") or doc.get("pid")
    alive = False
    if isinstance(pid, int) and pid > 0:
        alive = os.path.exists(f"/proc/{pid}")
    switches = doc.get("switches") or {}
    return {"manifest": path,
            "pid": pid,
            "alive": alive,
            "switches": sorted(str(k) for k in switches),
            "rate": doc.get("rate")}


def control_plane_telemetry(package=None, knob_path=None, manifest_path=None):
    """
    The fabric-wide half of the telemetry disclosure: what was asked for, and who is emitting.

    [Co-developed with claude code -- Adam]
    `knob` and `package` are the two INPUTS to `_telemetry_source`, reported separately from the
    per-switch answers they produce. A reader looking at a fabric that is sampling nothing has to
    be able to tell "nobody asked for telemetry" from "somebody asked and it did not happen", and
    a resolved word per switch cannot answer the first.
    """
    package = profile.current() if package is None else package
    try:
        knob = read_telemetry_knob(knob_path)
    except TelemetryConfigError as exc:
        knob = f"refused: {exc}"
    try:
        declared = getattr(package, "telemetry_source", None)
    except Exception:  # noqa: BLE001 -- a disclosure must not raise
        declared = None
    return {"knob": "absent" if knob is None else knob,
            "package": declared,
            "link_emitter": link_emitter_report(manifest_path)}


# --- the PRE entries a package declares (G9a). [Co-developed with claude code -- Adam] --------
#
# 🔴 NOT TABLE ENTRIES, AND THE DIFFERENCE IS WHY THEY ARE APPLIED WHERE TABLE ENTRIES ARE NOT.
# A package's `table_entries` name tables inside the exercise's own program, so on an NDTwin
# pipeline they are recorded and deliberately never written (`MyIngress.ipv4_lpm` in `basic.p4`
# is not the one in `ndtwin_switch.p4` even though the strings match). A multicast group and a
# clone session are TARGET-level objects in the PRE: they have no program in them at all, they
# exist on every pipeline, and an exercise whose group is missing forwards nothing to the hosts
# that group was for -- the tutorials `multicast` exercise is exactly that, h1 to h2/h3/h4.

#: {dpid as string: {"multicast": {...}, "clone": {...}}}, each with recorded/applied/failed.
_pre_entries = {}

PRE_ENTRY_KINDS = ("multicast", "clone")


def _blank_pre_counts():
    return {kind: {"recorded": 0, "applied": 0, "failed": 0} for kind in PRE_ENTRY_KINDS}


def pre_entries_report():
    """{dpid as string: how many PRE entries were declared, programmed and refused}."""
    return {dpid: {kind: dict(counts) for kind, counts in entry.items()}
            for dpid, entry in _pre_entries.items()}


def _record_pre_entries(dpid, counts):
    _pre_entries[str(dpid)] = {kind: dict(counts.get(kind, {"recorded": 0, "applied": 0,
                                                            "failed": 0}))
                               for kind in PRE_ENTRY_KINDS}


def read_pre_entries(entries_path):
    """The `multicast_group_entries` / `clone_session_entries` a runtime file declares.

    Returns `{"multicast": [...], "clone": [...]}`; empty lists when the file has neither, which
    is every tutorials exercise but `multicast` and `flowcache`. Never raises: a file that will
    not parse is already refused by `app_package.load`, so reaching that here means it changed
    under a running proxy and the caller counts it as zero declared rather than dying.
    """
    out = {"multicast": [], "clone": []}
    if not entries_path:
        return out
    try:
        with open(entries_path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return out
    if isinstance(doc, dict):
        out["multicast"] = list(doc.get("multicast_group_entries") or [])
        out["clone"] = list(doc.get("clone_session_entries") or [])
    return out


def apply_package_pre_entries(client, entries_path):
    """
    Program every multicast group and clone session a package declares. Returns counts.

    [Co-developed with claude code -- Adam]
        {"multicast": {"recorded", "applied", "failed"}, "clone": {...}, "errors": [...]}

    One refusal does not stop the rest, for `apply_package_entries`' reason: a runtime file is a
    list of independent objects and stopping half way leaves a fabric programmed to an arbitrary
    point with no record of where.

    🔴 A FAILURE IS COUNTED AS A FAILURE. `write_multicast_group` returns False for a switch that
    refused the write, and False is falsy in the same way a successful write of zero groups is --
    so the count is taken from the return value explicitly rather than from "did anything raise".
    A group counted as applied that is not on the switch makes `pre_entries.failed == 0` a
    sentence about nothing.
    """
    out = {"multicast": {"recorded": 0, "applied": 0, "failed": 0},
           "clone": {"recorded": 0, "applied": 0, "failed": 0},
           "errors": []}
    declared = read_pre_entries(entries_path)
    out["multicast"]["recorded"] = len(declared["multicast"])
    out["clone"]["recorded"] = len(declared["clone"])
    dpid = getattr(client, "device_id", "?")

    for index, spec in enumerate(declared["multicast"]):
        spec = spec if isinstance(spec, dict) else {}
        try:
            ok = client.write_multicast_group(spec.get("multicast_group_id"),
                                              spec.get("replicas") or [],
                                              spec.get("op", "insert"))
        except Exception as exc:  # noqa: BLE001 -- one group must not cost the others
            ok = False
            out["errors"].append(f"multicast entry {index}: {type(exc).__name__}: {exc}")
            print(f"[Proxy Agent] switch {dpid}: multicast group entry {index} was NOT "
                  f"programmed -- {type(exc).__name__}: {exc}")
        if ok:
            out["multicast"]["applied"] += 1
        else:
            out["multicast"]["failed"] += 1
            if len(out["errors"]) == 0 or not out["errors"][-1].startswith(
                    f"multicast entry {index}:"):
                out["errors"].append(
                    f"multicast entry {index}: the switch refused multicast group "
                    f"{spec.get('multicast_group_id')!r}")

    for index, spec in enumerate(declared["clone"]):
        spec = spec if isinstance(spec, dict) else {}
        try:
            ok = client.write_clone_session(
                session_id=spec.get("clone_session_id", spec.get("session_id")),
                replicas=spec.get("replicas") or None)
        except Exception as exc:  # noqa: BLE001
            ok = False
            out["errors"].append(f"clone entry {index}: {type(exc).__name__}: {exc}")
            print(f"[Proxy Agent] switch {dpid}: clone session entry {index} was NOT programmed "
                  f"-- {type(exc).__name__}: {exc}")
        if ok:
            out["clone"]["applied"] += 1
        else:
            out["clone"]["failed"] += 1
            if len(out["errors"]) == 0 or not out["errors"][-1].startswith(
                    f"clone entry {index}:"):
                out["errors"].append(
                    f"clone entry {index}: the switch refused clone session "
                    f"{spec.get('clone_session_id', spec.get('session_id'))!r}")
    return out


#: Filled at import for the reason `_pipelines` is: the kernel polls `GET /p4/switch_state` from
#: the moment the port is open, and a telemetry object that only appears once startup has
#: finished is indistinguishable, to that reader, from a proxy too old to have one.
_telemetry.update(_telemetry_blank(profile.current(), DEFAULT_SWITCH_DPIDS))
_pre_entries.update({str(dpid): _blank_pre_counts() for dpid in DEFAULT_SWITCH_DPIDS})


def readopt_switch(topology, dpid, client_factory, sample_callback, package=None):
    """
    The package's half of `POST /p4/readopt/{dpid}`.

    [Co-developed with claude code -- Adam]
    `TopologyManager.readopt_switch` owns the re-adoption sequence -- build, arbitrate, settle,
    push, clone, routes -- and it knows nothing about app packages, which is right: it is the
    same sequence whatever pipeline the switch runs. What changes under a FOREIGN pipeline is
    what may be done to the switch afterwards, and that is package knowledge, so it is decided
    here and passed in rather than branched on down there.

    All three rules in TICKET-P2 4.2 are expressible from this side, as of round 2:

      * no clone session -- `sample_callback=None` is exactly how readopt is told a switch gets
        no telemetry, and a foreign pipeline clones nothing to the CPU port, so a session
        programmed into its PRE would report zero samples forever and look like a broken
        emitter;
      * no route refill -- `install_routes=False`. That parameter was added to
        `TopologyManager.readopt_switch` in round 2 (the orchestrator's ruling on objection ①);
        before it existed the refill ran unconditionally and wrote NDTwin's shortest paths into
        `MyIngress.ipv4_lpm` by name -- which against `basic.p4` SUCCEEDS, because that program
        declares the same table with the same action and the same parameter names, so this
        proxy's routes landed on top of the exercise's own forwarding with both sides reporting
        success;
      * the package's entries are re-applied afterwards, because the push that just happened
        emptied every table on the switch (KNOWN-ISSUES A-4c) including the ones this proxy put
        there at startup.

    🔴 NOTHING IS CAUGHT HERE. An earlier version wrapped the call in `except Exception` to turn
    the KeyError the route refill raised against a foreign pipeline into a named failure instead
    of a 500. That was a workaround for not having the parameter; with the parameter the refill
    does not run, so an exception coming out of readopt now means something genuinely went wrong
    and both branches re-raise it unchanged.

    🔴 TWO KEYS ARE OVERWRITTEN for a foreign switch, and both are "reported success without
    doing it" otherwise. `readopt_switch` answers `clone_session: True` when it was handed no
    sample callback -- which means "nothing failed" there and is right for a fabric whose sFlow
    is simply not wired, but here it would tell an operator a session was programmed when the
    decision was that none should be. And `routes_installed: 0` with nothing beside it reads as
    a switch that refused its routes rather than one that was deliberately not offered any.
    """
    package = profile.current() if package is None else package
    ndtwin = _pipeline_is_ndtwin(package, dpid)

    # [Co-developed with claude code -- Adam]
    # TICKET-P3 2.1: the telemetry source decides the clone session here for the same reason it
    # does in startup -- a switch whose samples come from the link emitter must not also clone
    # to the CPU port, or every byte it carries is counted twice. `sample_callback=None` is how
    # readopt is told a switch gets no telemetry, so the two conditions meet in one expression
    # rather than becoming a second parameter nobody passes.
    #
    # 🔴 THE ROUTE REFILL IS NOT TELEMETRY. `install_routes` stays on `ndtwin` alone: a fabric
    # measured by the link emitter still runs NDTwin's pipeline and still wants NDTwin's
    # shortest paths back after a power-cycle. Folding the two conditions together would make
    # `--telemetry link` silently stop refilling the routes of every switch that power-cycles.
    telemetry_source = _telemetry_source(package, dpid)
    cooperative = ndtwin and telemetry_source == TELEMETRY_COOPERATIVE

    result = topology.readopt_switch(dpid, client_factory,
                                     sample_callback if cooperative else None,
                                     install_routes=ndtwin)

    if result.get("status") == "success":
        # The push inside readopt empties this switch's PRE along with its tables, so whatever
        # the package declared there goes back on -- on every pipeline, for the reason startup's
        # own PRE loop gives. Recorded, not added to: the counts describe what is on the switch
        # now. [Co-developed with claude code -- Adam]
        pre = apply_package_pre_entries(topology.switches.get(dpid),
                                        package_entries_path(package, dpid))
        _record_pre_entries(dpid, pre)
        result["pre_entries"] = {kind: dict(pre[kind]) for kind in PRE_ENTRY_KINDS}
        _record_telemetry(
            dpid, telemetry_source, bool(result.get("clone_session")) and cooperative,
            cooperative, None if not cooperative else _telemetry.get(
                str(dpid), {}).get("packet_in_ids"),
            f"re-adopted: telemetry source '{telemetry_source}'"
            + ("" if cooperative else ", so no clone session was programmed"))

    if ndtwin or result.get("status") != "success":
        if ndtwin and result.get("status") == "success" and not cooperative:
            # 🔴 SAME LIE, OTHER CAUSE (TICKET-P2 7-8). `readopt_switch` answers
            # `clone_session: True` when it was handed no sample callback, which means "nothing
            # failed" -- correct for a fabric whose sFlow is simply not wired, and wrong here,
            # where the decision was that this switch gets none.
            result["clone_session"] = False
            result["telemetry_note"] = (
                f"telemetry source '{telemetry_source}': no clone session was programmed for "
                f"this switch on purpose. Its samples come from somewhere else, and programming "
                f"one here would count every packet twice")
        return result

    result["clone_session"] = False
    result["routes"] = "skipped"
    result["routes_note"] = (
        "this switch runs the app package's own pipeline: no clone session was programmed (it "
        "does not clone to the CPU port) and no NDTwin route was installed (the refill names "
        "NDTwin's own tables). Its forwarding is the package's table entries below.")

    # The pipeline push inside readopt emptied the switch. Whatever the package declared for it
    # is gone with everything else, so it goes back on -- and the counts are re-recorded, not
    # added to, because they describe what is on the switch now.
    counts = apply_package_entries(topology.switches.get(dpid),
                                   package_entries_path(package, dpid))
    _record_table_entries(dpid, _table_entries.get(str(dpid), {}).get("recorded", 0),
                          counts["applied"], counts["failed"])
    result["table_entries"] = dict(counts)
    return result


# Wired the same way the topology is, and at the same point: the endpoints have to be able to
# answer before startup() finishes, because the kernel begins polling the moment the port is
# open. The readopt factory is here too -- that endpoint needs to build clients (paths and port
# numbering live in this file) and to hand new ones the sFlow callback, exactly as startup()
# does for the originals. [Co-developed with claude code -- Adam]
api_routes.inject_readopt(build_p4_client, sflow.handle_sample, readopt_switch)
api_routes.inject_control_plane(control_plane_report, entries_recorded_report)
api_routes.inject_package_reports(pipelines_report, table_entries_report,
                                  note_api_table_entry_write)
api_routes.inject_telemetry_reports(telemetry_report, pre_entries_report,
                                    control_plane_telemetry)


async def startup(clients_factory, sflow, kernel, topo,
                  *, settle_seconds=MASTERSHIP_SETTLE_S,
                  agent_ips_loader=load_switch_agent_ips,
                  package=None):
    """
    Bring the proxy up, and report what it actually claimed.

    [Co-developed with claude code -- Adam]
    Extracted from the `@app.on_event("startup")` body, which could not be tested at all: it read
    four module globals, opened real gRPC channels, and recorded every decision it made in
    `print`. The decisions are the interesting part -- which switches get a pipeline, which get
    telemetry, and above all which get `inform_switch_entered`, the one call that sets isEnabled --
    so they are returned as data:

        {"clients": {dpid: client}, "broken": [...], "telemetry": [...],
         "entered": [...], "not_entered": [...]}

    `broken`, `telemetry` and `entered` are deliberately three separate lists rather than one
    health flag: a switch can hold mastership, take a pipeline, and still have no telemetry, and
    that switch must appear in the graph. Collapsing them would hide the case.

    A fourth key, `control_plane`, says which of the steps below ran at all. Under an app package
    in `external` mode most of them do not, and every one of them is a step whose absence looks
    like a fault downstream -- see EXTERNAL_SKIPS.

    [Co-developed with claude code -- Adam]
    A fifth and sixth, `pipelines` and `table_entries`, say which program each switch is running
    and how many of the package's own rules went onto it. Under a FOREIGN pipeline (TICKET-P2
    2.2) three more things change, all of them disclosed through the same two keys and
    `control_plane.skipped`:

      * per switch -- no clone session and no sFlow registration, because the exercise's
        pipeline does not clone to the CPU port. The PRE write would SUCCEED and produce nothing,
        which is the "reports zero rather than reports an error" shape exactly;
      * per switch -- the package's declared entries are APPLIED, through the same writer
        `POST /p4/table_entry` uses;
      * fabric-wide -- no LLDP, no watchdog and therefore no initial routes, because all three
        ride packet-in/packet-out through a controller header a tutorials pipeline does not
        declare. The watchdog would additionally report every seeded link down inside its
        timeout: a fabric-wide false alarm.

    🔴 THE TWO DISCLOSURES ARE NOT ONE LIST. `control_plane.skipped` carries the FABRIC-wide
    three only; the per-switch pair lands on that switch's `pipeline.skipped`. On a mixed fabric
    the switches beside the package's still get a clone session and still sample, so saying
    `clone_session` at fabric level would be a true sentence about one switch told about ten.
    """
    print("[Proxy Agent] Starting up...")

    package = profile.current() if package is None else package
    read_only = package.read_only
    skipped = list(EXTERNAL_SKIPS) if read_only else []

    clients = clients_factory()
    for dpid, client in clients.items():
        topo.add_switch(dpid, client)

    # Which program each switch is about to run, recorded before anything is done to it so the
    # endpoint can answer while the pushes are still in flight. `foreign` is the set this
    # ticket's branches turn on; on the baseline fabric, and on any package whose switches all
    # declare `pipeline: null`, it is empty and every branch below is the one that ran before.
    _pipelines.clear()
    _pipelines.update(_describe_pipelines(package, sorted(clients)))
    foreign = {dpid for dpid in clients if not _pipelines[str(dpid)]["ndtwin"]}

    # --- where each switch's samples are to come from. TICKET-P3 2.1.
    # [Co-developed with claude code -- Adam]
    #
    # Resolved for EVERY connected switch before anything is done to any of them, and resolved
    # once: `_telemetry_source` reads a file, and asking it again inside the telemetry loop
    # would let a knob rewritten mid-startup give two switches two answers on one fabric.
    #
    # 🔴 THE REFUSAL IS HERE, BEFORE THE PIPELINE PUSH. `cooperative` on a program with no
    # @controller_header("packet_in") is not a degraded mode: the pipeline cannot clone to the
    # CPU port, the PRE accepts the clone session anyway, the emitter registers an agent, and
    # the switch reports zero samples for the entire run with every intermediate step green.
    # Raising takes the proxy down with a message naming the switch and the missing fields,
    # which is the only moment the difference is still visible. `link` and `none` are silent by
    # design and say so in the disclosure instead.
    telemetry_sources = {}
    for dpid, client in clients.items():
        source = _telemetry_source(package, dpid)
        telemetry_sources[dpid] = source
        if source == TELEMETRY_COOPERATIVE and getattr(client, "packet_in_ids", None) is None:
            raise TelemetryConfigError(
                f"switch {dpid} is configured for 'cooperative' telemetry and the pipeline it "
                f"runs cannot carry it: {getattr(client, 'packet_in_ids_error', None)} "
                f"(p4info {_pipelines[str(dpid)]['p4info']}). Ask for telemetry 'link' or "
                f"'none', or build this switch's program with "
                f"p4_proxy/p4_src/ndtwin_telemetry.p4 included")

    if read_only:
        # 🔴 The whole point of `external`: the exercise's own controller owns this fabric's
        # tables. Two controllers on one bmv2 is not a degraded mode -- P4Runtime identifies the
        # sender of a unary RPC by the election id in the message rather than by the connection
        # it arrived on, so a second controller's SetForwardingPipelineConfig is ACCEPTED and
        # wipes every table the first one installed (measured 2026-08-13, p4_client.py:60-74).
        #
        # Announced in full, because every step below is a capability the twin normally has and
        # does not have now. The branches that skip them are marked `not read_only` one by one
        # rather than by returning early from here: the kernel-acknowledgement block below owns
        # a background retry that matters just as much on this fabric (stack.sh starts the
        # kernel AFTER the proxy, so the first push always lands on a closed port), and an early
        # return is how that kind of thing gets quietly dropped from the second code path.
        print(f"[Proxy Agent] app package {package.name} declares an EXTERNAL control plane: "
              f"this proxy will not push pipelines, program clone sessions, send LLDP beacons, "
              f"watch links or install routes on any of the {len(clients)} switches it "
              f"connected to. It reads only. Skipped: {', '.join(sorted(skipped))}. "
              f"Reported on GET /p4/switch_state.")

    # Wait ONCE for mastership to be confirmed on all switches.
    # asyncio.sleep, not time.sleep: this coroutine runs on the event loop, and a blocking sleep
    # here stalls every other startup task uvicorn has queued. [Co-developed with claude code -- Adam]
    await asyncio.sleep(settle_seconds)

    # Batch push pipeline config
    #
    # [Co-developed with claude code -- Adam]
    # Guarded per switch. This call used to be bare, and set_forwarding_pipeline_config raises
    # grpc._channel._InactiveRpcError when the switch is not listening -- so **one dead bmv2 out of
    # ten stopped the whole proxy from starting**. uvicorn treats an exception in a startup event as
    # fatal, so the process exited with status 3 after printing a traceback, and the other nine
    # switches lost their telemetry, topology feed and flow installs along with it.
    #
    # Found while testing liveness, and it also undermined it: if the proxy cannot run at all while
    # a switch is down, the Down verdict could only ever be reached for a switch that died *after*
    # startup. A switch that was already dead was simply never mentioned.
    #
    # The first loop's try/except does not cover this: grpc connects lazily, so start() succeeds
    # against a dead switch and the failure surfaces here, or asynchronously in the stream receiver.
    broken = set()
    for i, client in clients.items():
        if read_only or not client.json_path:
            continue
        try:
            client.set_forwarding_pipeline_config()
            print(f"[Proxy Agent] Connected to Switch {i}")
        except Exception as e:  # noqa: BLE001 -- one switch must not take down the other nine
            broken.add(i)
            print(f"[Proxy Agent] Switch {i}: pipeline push failed, continuing without it: "
                  f"{type(e).__name__}: {e}")

    if broken:
        # Loud and explicit about the consequence, because a partially-started proxy looks healthy.
        # These switches keep their P4RuntimeClient, so the liveness poller still probes them and
        # `GET /p4/switch_state` reports probe_ok=false -- which is what lets the kernel show them as
        # down rather than merely absent. What they do not get is `inform_switch_entered`: isEnabled
        # means "the control plane can drive this switch", and one with no pipeline cannot forward.
        print(f"[Proxy Agent] {len(broken)} of {len(clients)} switches have no pipeline "
              f"({sorted(broken)}); they will report as down and will not be enabled in the graph")

    # --- the package's own table entries (G5). [Co-developed with claude code -- Adam] ------
    #
    # 🔴 ONLY ON A FOREIGN PIPELINE, and only after the push that loaded it. Under NDTwin's own
    # pipeline a package's entries stay RECORDED AND UNAPPLIED, which is what phase 1 shipped
    # and what `live-p1/02` asserts: those files are written against the exercise's tables, and
    # `MyIngress.ipv4_lpm` in `basic.p4` is not `MyIngress.ipv4_lpm` in `ndtwin_switch.p4` even
    # though the two strings are equal -- applying them would put the exercise's forwarding
    # decisions into our pipeline, on top of the routes install_initial_routes computes, and
    # both would report success.
    #
    # Recorded per switch whether or not anything was applied: `recorded` with `applied: 0` on
    # our own pipeline is a sentence ("these exist and were deliberately not used"), and the
    # same pair on a foreign one after a failure is a different sentence that must not look
    # like it.
    entry_errors = {}
    for i, client in clients.items():
        recorded = package.entries_recorded().get(str(i), 0)
        counts = {"applied": 0, "failed": 0, "errors": []}
        if i in foreign and i not in broken and not read_only:
            counts = apply_package_entries(client, package_entries_path(package, i))
            print(f"[Proxy Agent] Switch {i} runs the package's own pipeline: "
                  f"{counts['applied']} of {recorded} declared table entries applied, "
                  f"{counts['failed']} refused")
        _record_table_entries(i, recorded, counts["applied"], counts["failed"])
        if counts["errors"]:
            entry_errors[str(i)] = counts["errors"]

        # --- the PRE half of the same file (G9a). [Co-developed with claude code -- Adam]
        #
        # 🔴 ON EVERY SWITCH, NOT ONLY THE FOREIGN ONES -- the one place this loop treats the two
        # kinds differently. A multicast group and a clone session are target objects with no
        # program in them, so `mcast_grp 1 -> ports 2,3,4` means the same thing under
        # ndtwin_switch.p4 as under the exercise's own, and a package that brings NDTwin's
        # pipeline WITH its own topology (`convert --ndtwin-pipeline`, which live-p1/02 uses) is
        # exactly the case that would otherwise silently lose its groups.
        #
        # After the table entries, before the telemetry loop. Before, because this proxy's own
        # clone session is written down there and must win if a package declares the same id;
        # after, because a package's groups are part of its forwarding and its table entries are
        # what reference them.
        pre = _blank_pre_counts()
        if i not in broken and not read_only:
            pre = apply_package_pre_entries(client, package_entries_path(package, i))
            if pre["multicast"]["recorded"] or pre["clone"]["recorded"]:
                print(f"[Proxy Agent] Switch {i}: "
                      f"{pre['multicast']['applied']}/{pre['multicast']['recorded']} multicast "
                      f"group(s) and {pre['clone']['applied']}/{pre['clone']['recorded']} clone "
                      f"session(s) from the package programmed, "
                      f"{pre['multicast']['failed'] + pre['clone']['failed']} refused")
            if pre.get("errors"):
                entry_errors.setdefault(str(i), []).extend(pre["errors"])
        _record_pre_entries(i, pre)

    # --- telemetry --------------------------------------------------------------------
    # [Co-developed with claude code -- Adam]
    #
    # Must come after the pipeline is pushed: the clone session lives in the pipeline's PRE, so
    # programming it earlier would be discarded. start(push_config=False) above is why this is
    # not done inside start().
    # [Co-developed with claude code -- Adam]
    # Loaded unconditionally. This used to read `{} if read_only else agent_ips_loader()`, which
    # made the read-only skip below unreachable: with no agent IPs every switch fell out of the
    # loop one branch earlier, at "no IP in the topology file", so the two guards masked each
    # other and tests/shell/mutate_app_package.sh's M19 survived -- deleting either one changed
    # nothing observable. One guard, one reason, and the message a reader sees is the true one.
    agent_ips = agent_ips_loader()
    telemetry = []

    def _ids_of(client):
        """The five packet_in ids this switch's p4info gave, as a dict, or None."""
        ids = getattr(client, "packet_in_ids", None)
        return None if ids is None else ids.as_dict()

    for i, client in clients.items():
        source = telemetry_sources[i]
        if read_only:
            # Not "telemetry failed" -- telemetry was never attempted. The clone session is a
            # WRITE into the pipeline's PRE, and the pipeline belongs to somebody else's
            # controller. Reported through `control_plane.skipped`, which is the only way a
            # reader can tell this apart from a fabric whose sampling broke.
            _record_telemetry(i, source, False, False, _ids_of(client),
                              "the app package declares an external control plane: this proxy "
                              "writes nothing, so no clone session was programmed whatever the "
                              "telemetry source says")
            continue
        if i in broken:
            # The clone session lives in the pipeline's PRE, so there is nothing to program it into.
            # [Co-developed with claude code -- Adam]
            _record_telemetry(i, source, False, False, _ids_of(client),
                              "the pipeline push failed for this switch, so there is no PRE to "
                              "program a clone session into")
            continue
        if i in foreign:
            # [Co-developed with claude code -- Adam]
            # 🔴 The PRE write would SUCCEED. A clone session is a target-level object, not part
            # of the P4 program, so bmv2 accepts it against any pipeline -- and then nothing ever
            # clones into it, because `clone_preserving_field_list` only exists in
            # ndtwin_switch.p4. The result is a switch registered for sFlow, a session programmed,
            # no error anywhere, and zero samples for the rest of the run: "reports zero rather
            # than reports an error" with every intermediate step green.
            #
            # register_switch is skipped for the same reason. A registered switch that never
            # samples is an agent address the kernel attributes nothing to.
            print(f"[Proxy Agent] Switch {i} runs the package's own pipeline, which does not "
                  f"clone to the CPU port; no clone session and no sFlow registration for it "
                  f"({SKIP_CLONE}, {SKIP_TELEMETRY} on GET /p4/switch_state)")
            _record_telemetry(i, source, False, False, _ids_of(client),
                              f"this switch runs the app package's own pipeline, which does not "
                              f"clone to the CPU port; its samples come from '{source}'")
            continue

        # --- the source decides, and the two others are not failures. TICKET-P3 2.1.
        # [Co-developed with claude code -- Adam]
        #
        # 🔴 EXCLUSIVE, AND THAT IS THE WHOLE POINT. Under `link` the switch-side veths are
        # sampled by tc filters and a separate emitter synthesises the sFlow. If this proxy ALSO
        # programmed a clone session, the same packet would be counted twice -- once cloned to
        # the CPU and once sampled on the wire -- into the same edge's byte total, and the twin
        # would read exactly double with nothing anywhere reporting an error. `none` is the
        # measurement's control arm and must sample nothing at all.
        #
        # Placed after the `foreign` branch so that branch's message and behaviour are untouched
        # (TICKET-P2 7-7 froze its `pipeline.skipped` list), and so an `auto` fabric on NDTwin's
        # own pipeline reaches the code below exactly as it did before this ticket.
        if source != TELEMETRY_COOPERATIVE:
            print(f"[Proxy Agent] Switch {i}: telemetry source is '{source}', so this proxy "
                  f"programs no clone session and registers no sFlow agent for it "
                  f"({SKIP_CLONE}, {SKIP_TELEMETRY} on GET /p4/switch_state). "
                  f"{'Its samples come from the link emitter.' if source == TELEMETRY_LINK else 'Nothing samples this switch.'}")
            _record_telemetry(i, source, False, False, _ids_of(client),
                              f"telemetry source '{source}': the cooperative path is off for "
                              f"this switch on purpose, so that nothing is counted twice")
            continue

        agent_ip = agent_ips.get(i)
        if agent_ip is None:
            print(f"[Proxy Agent] Switch {i} has no IP in the topology file; "
                  f"its samples would be attributed to nothing, so telemetry is off for it")
            _record_telemetry(i, source, False, False, _ids_of(client),
                              "this switch has no IP in the topology file, so its samples would "
                              "be attributed to no edge")
            continue

        sflow.register_switch(i, agent_ip)
        client.sample_callback = sflow.handle_sample
        if client.write_clone_session():
            telemetry.append(i)
            print(f"[Proxy Agent] Switch {i} sampling to sFlow as {agent_ip}")
            _record_telemetry(i, source, True, True, _ids_of(client),
                              f"cooperative telemetry: the pipeline clones 1-in-N to the CPU "
                              f"port and this proxy emits sFlow as {agent_ip}")
        else:
            # Reported loudly: the pipeline still clones, bmv2 still drops the copy, and
            # everything downstream looks healthy while reporting zero traffic.
            print(f"[Proxy Agent] Switch {i}: clone session failed, NO telemetry from it")
            _record_telemetry(i, source, False, True, _ids_of(client),
                              "cooperative telemetry was asked for and the clone session could "
                              "not be programmed: this switch is registered with the emitter "
                              "and will produce no samples")

    # --- tell the kernel these switches exist -----------------------------------------
    # [Co-developed with claude code -- Adam]
    #
    # Deliberately after the pipeline push, not on mastership: `isEnabled` means "the control
    # plane can drive this switch", and a switch holding mastership with no pipeline loaded
    # cannot forward anything. Doing it here also means we only claim switches we really did
    # set up -- `clients` only contains the ones that connected, and `broken` is excluded below
    # for the same reason: claiming a switch whose pipeline push failed would enable a vertex the
    # control plane demonstrably cannot drive.
    #
    # This is the call that makes the graph live. Without it every vertex and edge stays
    # isEnabled=false, which silently empties BFS pathing, flow-table polling and link-usage
    # attribution -- flows are still detected, but every `path` is [] and every rate is 0.
    usable = [i for i in clients if i not in broken]
    entered = [i for i in usable if kernel.switch_entered(i)]
    not_entered = [i for i in usable if i not in entered]
    if not not_entered:
        print(f"[Proxy Agent] Kernel acknowledged all {len(entered)} usable switches")
    else:
        # [Co-developed with claude code -- Adam]
        # Under stack.sh's ordering this is the NORMAL case, not a failure: the kernel
        # deliberately starts after the proxy, so the startup push always lands on a closed
        # port. Nothing stays broken -- the kernel's topology poll enables switches on its own
        # (TopologyAndFlowMonitor.cpp:566) -- and a bounded background retry re-pushes so the
        # notification path still delivers once the kernel is up. The previous message here
        # declared the graph permanently degraded; the 2026-08-15 overnight audit took it at
        # its word and misdiagnosed a healthy era.
        print(f"[Proxy Agent] Kernel did not acknowledge {len(not_entered)}/{len(usable)} "
              f"switches yet ({not_entered}) -- normal when the kernel starts after the proxy. "
              f"Its topology poll enables switches on its own; retrying the push in the "
              f"background for up to 5 minutes.")
        threading.Thread(
            target=kernel_notifier.renotify_until_acknowledged,
            args=(kernel.switch_entered, not_entered),
            daemon=True,
            name="switch-entered-retry",
        ).start()

    # --- what a foreign pipeline takes away from the whole fabric. TICKET-P2 2.2 -----------
    # [Co-developed with claude code -- Adam]
    #
    # LLDP discovery, the link watchdog and (through them) install_initial_routes all ride
    # packet-out and packet-in. Those need a controller header, and the p4info says which
    # programs have one: `ndtwin_switch` declares two `controller_packet_metadata` entries,
    # `basic` and `source_routing` declare none. A packet-out into such a pipeline is not an
    # error, it is a frame the parser was never written to emit -- so discovery would find
    # nothing and the watchdog, which seeds every declared link and waits for beacons, would
    # report the ENTIRE fabric down inside its timeout. A fabric-wide false alarm is worse than
    # the absence it replaces, which is the same argument `external` mode already makes.
    #
    # Fabric-wide on ONE switch being foreign, not per switch: a beacon leaves one switch and
    # arrives at another, so a link between an NDTwin switch and a package switch cannot be
    # discovered either, and a watchdog seeded with every declared link would mark it down.
    #
    # 🔴 REBOUND ONTO `read_only` RATHER THAN ADDED AS A SECOND CONDITION. From this line down,
    # every `if not read_only:` is asking one question -- "may this proxy drive this fabric
    # through the CPU port?" -- and the answer is now no for a second reason. The two reasons
    # stay apart where a reader looks for them: `control_plane.mode` says which one, and every
    # switch's `pipeline.ndtwin` says which switches. (The mechanical constraint is real too:
    # `tests/shell/mutate_app_package.sh` M18 anchors on those exact three lines, and that gate
    # belongs to another ticket's file.)
    if foreign and not read_only:
        skipped.extend(FOREIGN_PIPELINE_FABRIC_SKIPS)
        print(f"[Proxy Agent] {len(foreign)} of {len(clients)} switches "
              f"({sorted(foreign)}) run the app package's own pipeline, which carries no "
              f"controller header: this proxy will not send LLDP beacons, watch links or "
              f"install routes on ANY switch of this fabric. Skipped: "
              f"{', '.join(sorted(set(skipped)))}. The per-switch skips (no clone session, no "
              f"sFlow) are on each switch's own `pipeline.skipped`, because the switches "
              f"beside these still have both. Reported on GET /p4/switch_state.")
        read_only = True

    # Start LLDP dynamic topology discovery
    #
    # Skipped under an external control plane: discovery works by sending packet-outs and
    # reading the packet-ins they cause, and both ride the arbitration stream this client did
    # not open. It would also be a write. The consequence -- no discovered links, so
    # `install_initial_routes` is never reached either (its only automatic callers are this and
    # the watchdog below) -- is exactly why both appear in `control_plane.skipped`.
    if not read_only:
        try:
            topo.start_lldp_discovery()
            print("[Proxy Agent] Started LLDP Discovery...")
        except Exception as e:
            print(f"[Proxy Agent] Failed to start LLDP discovery: {e}")

    # [Co-developed with claude code -- Adam]
    # The other half of LLDP: beacons that stop arriving are how a link failure is detected, and
    # until this existed only the discovery direction was wired. A link that went down stayed up
    # in the twin forever.
    #
    # Skipped under an external control plane for the same reason discovery is: the beacons it
    # waits for are packet-outs this proxy is not allowed to send, so every link would be
    # reported down within the timeout -- a fabric-wide false alarm, which is worse than the
    # absence it replaces. Named in `control_plane.skipped` so "no link failures reported" is
    # not read as "no link failures".
    if not read_only:
        try:
            # seed_expected=True enters every link the topology file declares, so one that was
            # already broken when this process started is reported rather than merely never
            # discovered. The kernel graph is correct either way -- an undiscovered edge is never
            # enabled -- but without seeding nothing says *which* link is missing, and
            # "38/40 edges" is a puzzle rather than a diagnosis.
            #
            # Safe to enable as of 2026-08-10: the receive-side port assumption it rests on was
            # verified live on ten bmv2 switches (32/32 statically, 16/16 observed ingress ports).
            # The startup grace is 30 s against a measured discovery time of ~2 s.
            #
            # ⚠️ That verification is specific to this topology file plus p4_testbed_topo.py. A
            # topology declaring links Mininet does not wire would report them down forever.
            # [Co-developed with claude code -- Adam]
            topo.start_link_watchdog(seed_expected=True)
            print("[Proxy Agent] Started LLDP link watchdog...")
        except Exception as e:
            print(f"[Proxy Agent] Failed to start link watchdog: {e}; link failures will not be "
                  f"reported and the graph will keep showing failed links as up")

    # [Co-developed with claude code -- Adam]
    # Feeds GET /p4/switch_state, which the kernel's pingWorker reads once a second. Without it
    # every switch reports probe_ok=null forever, and the kernel's policy answers Unknown -- so the
    # graph keeps whatever liveness it was last told rather than reporting a fault. That is the safe
    # direction, but it means a failure to start here is invisible on the kernel side, so say so.
    try:
        topo.start_liveness_polling()
        print("[Proxy Agent] Started liveness polling...")
    except Exception as e:
        print(f"[Proxy Agent] Failed to start liveness polling: {e}; /p4/switch_state will report "
              f"no probe results and the kernel will not update bmv2 switch liveness")

    return {
        "clients": clients,
        "broken": sorted(broken),
        "telemetry": telemetry,
        "entered": entered,
        "not_entered": not_entered,
        # What this proxy did NOT do to the fabric, recorded where `GET /p4/switch_state` can
        # serve it. `[]` here means every step ran -- which is the baseline fabric's answer, and
        # is a different statement from the `null` the endpoint serves before startup has run.
        "control_plane": _record_control_plane(package, skipped),
        # [Co-developed with claude code -- Adam]
        # Which program each switch runs, and what this proxy managed to write onto it. Returned
        # as well as served so a test can assert the decision without an HTTP layer, and so the
        # numbers a live run reports come from the same dictionaries the endpoint reads.
        "pipelines": pipelines_report(),
        "table_entries": table_entries_report(),
        # Non-empty only when an entry was refused. The counts say how many; this says which,
        # and a count with no reason is a number nobody can act on.
        "entry_errors": entry_errors,
        # [Co-developed with claude code -- Adam]
        # TICKET-P3 2.1/2.6. `telemetry` above stays what it has always been -- the dpids whose
        # clone session went in -- because `live-p1/01` reads it and a key that changes meaning
        # under the same name is the worst of both. These two are new: the word each switch
        # resolved to, and the full per-switch disclosure the endpoint serves.
        "telemetry_sources": {str(dpid): word for dpid, word in telemetry_sources.items()},
        "telemetry_report": telemetry_report(),
        "pre_entries": pre_entries_report(),
    }


@app.on_event("startup")
async def startup_event():
    await startup(build_p4_clients, sflow, kernel, topo)


@app.on_event("shutdown")
async def shutdown_event():
    print("[Proxy Agent] Shutting down...")
    # [Co-developed with claude code -- Adam]
    # All three background loops, not just the poller: the LLDP beacon thread had no stop at all,
    # so it kept calling send_packet_out on clients that shutdown() had already torn down.
    topo.stop_lldp_discovery()
    topo.stop_link_watchdog()
    topo.stop_liveness_polling()
    # topo.switches, not a startup-time copy: readopt swaps entries in it, and the copy went
    # stale the first time a switch was power-cycled. list() because readopt may be mid-swap.
    for dpid, client in list(topo.switches.items()):
        try:
            client.stop()
        except Exception as e:  # noqa: BLE001
            print(f"[Proxy Agent] switch {dpid} refused to stop cleanly "
                  f"({type(e).__name__}: {e}); continuing shutdown")
    sflow.close()

HOST = "0.0.0.0"
PORT = 8081


def claim_listen_socket(host: str = HOST, port: int = PORT):
    """
    Take the listening socket before uvicorn is allowed to run the app.

    [Co-developed with claude code -- Adam]
    uvicorn runs the ASGI lifespan *before* it binds -- `server.py:103-104` awaits
    `lifespan.startup()` and the bind comes afterwards; the ordering is the same in every
    uvicorn installed here (0.49.0, 0.51.0, 0.52.1), so it is not a version quirk. This
    proxy's startup event opens gRPC channels, pushes pipeline config and installs forwarding
    rules, which means a second instance launched against a taken port writes to the fabric
    first and discovers it cannot serve second. Measured: ten `Setting Forwarding Pipeline
    Config...` calls, LLDP discovery started and the link watchdog seeded, all before
    `[Errno 98] address already in use`.

    So the guard cannot live in uvicorn's bind-failure path -- by the time that runs, the
    damage is done. It has to be here, ahead of `Server.run`.

    The socket is handed to uvicorn rather than closed and re-bound, because closing it would
    reopen exactly the race this exists to remove.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind((host, port))
    except OSError as exc:
        sock.close()
        print(
            f"[Proxy Agent] REFUSING to start: port {port} is already in use ({exc.strerror}).\n"
            f"[Proxy Agent] Another proxy agent is almost certainly running. This process has\n"
            f"[Proxy Agent] NOT connected to any switch and has NOT installed any rules --\n"
            f"[Proxy Agent] two agents writing to the same BMv2 fabric corrupt each other's\n"
            f"[Proxy Agent] forwarding state, and `curl :{port}` would answer from the other one.\n"
            f"[Proxy Agent] Stop the running agent first, or free port {port}.",
            file=sys.stderr,
        )
        sys.exit(1)
    sock.listen(2048)
    return sock


if __name__ == "__main__":
    listen_sock = claim_listen_socket()
    uvicorn.Server(uvicorn.Config(app, host=HOST, port=PORT)).run(sockets=[listen_sock])

# Developed in collaboration with Gemini 3.1 Pro.
