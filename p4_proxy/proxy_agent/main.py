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
    🔴 Compared by VALUE against what the baseline package answers for the same switch, rather
    than by asking whether the manifest declared an override. Those two are the same question
    only for as long as `pipeline_for`'s fallback stays the baseline pair -- and a package whose
    manifest names `p4_src/build/ndtwin_switch.*` explicitly is running our pipeline however it
    spelled it. The value is what the client is built from, so the value is what this asks.

    TICKET-P2 2.1 puts the same predicate on `Package` as `pipeline_is_ndtwin` (ticket A). It is
    computed here instead of imported ON PURPOSE, because the two branches are being written in
    parallel and an import would make this one unable to run until the other landed; the two
    collapse into one call when they merge. Until then this file must not grow a second
    DEFINITION of the rule -- which is why it is the equivalence and not a re-listing of the
    baseline's paths.

    Under phase-1 `app_package.py` every switch of every package still answers True, so every
    branch this gates is a no-op. That is the designed order, not an accident: it means this
    commit cannot change what a fabric does today.
    """
    base_dir = proxy_root() if base_dir is None else base_dir
    return (package.pipeline_for(dpid, base_dir)
            == app_package.baseline().pipeline_for(dpid, base_dir))


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
    """What `GET /p4/switch_state` says about one switch's pipeline."""
    package = profile.current() if package is None else package
    base_dir = proxy_root()
    p4info_path, _json_path = package.pipeline_for(dpid, base_dir)
    return {"ndtwin": _pipeline_is_ndtwin(package, dpid, base_dir),
            "p4info": p4info_path,
            "p4info_sha256": _p4info_fingerprint(p4info_path)}


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
    _api_writes[key] = _api_writes.get(key, 0) + 1
    return _api_writes[key]


def _record_table_entries(dpid, recorded, applied, failed):
    _table_entries[str(dpid)] = {"recorded": recorded, "applied": applied, "failed": failed}


def readopt_switch(topology, dpid, client_factory, sample_callback, package=None):
    """
    The package's half of `POST /p4/readopt/{dpid}`.

    [Co-developed with claude code -- Adam]
    `TopologyManager.readopt_switch` owns the re-adoption sequence -- build, arbitrate, settle,
    push, clone, routes -- and it knows nothing about app packages, which is right: it is the
    same sequence whatever pipeline the switch runs. What changes under a FOREIGN pipeline is
    what may be done to the switch afterwards, and that is package knowledge, so it is decided
    here and passed in rather than branched on down there.

    Two of the three rules in TICKET-P2 4.2 are expressible from this side:

      * no clone session -- `sample_callback=None` is exactly how readopt is told a switch gets
        no telemetry, and a foreign pipeline clones nothing to the CPU port, so a session
        programmed into its PRE would report zero samples forever and look like a broken
        emitter;
      * the package's entries are re-applied afterwards, because the push that just happened
        emptied every table on the switch (KNOWN-ISSUES A-4c) including the ones this proxy put
        there at startup.

    🔴 THE THIRD IS NOT, AND IT IS NOT DONE. `install_initial_routes(only_dpid=...)` is called
    unconditionally INSIDE readopt_switch, and topology_manager.py is outside this ticket's file
    ownership (TICKET-P2 0.7), so there is no seam here to suppress it through. On a foreign
    pipeline it writes NDTwin's shortest paths into `MyIngress.ipv4_lpm` -- which either does not
    exist (KeyError out of the id lookup) or, for `basic.p4`, exists under the SAME NAME and
    takes the write, putting this proxy's routes into the exercise's own table. The first is
    caught below and reported as a named failure instead of a 500; the second cannot be
    prevented from here and is written up as an objection in P2-B-SUMMARY.md.
    """
    package = profile.current() if package is None else package
    ndtwin = _pipeline_is_ndtwin(package, dpid)

    try:
        result = topology.readopt_switch(dpid, client_factory,
                                         sample_callback if ndtwin else None)
    except Exception as exc:  # noqa: BLE001
        if ndtwin:
            # Unchanged from before this ticket: on our own pipeline nothing here throws that
            # was not already throwing, and swallowing it would hide it.
            raise
        return {"status": "failed", "step": "routes", "dpid": dpid,
                "error": f"the switch was re-adopted up to the route install, which this proxy "
                         f"cannot skip for a foreign pipeline and which this pipeline cannot "
                         f"take: {type(exc).__name__}: {exc}"}

    if ndtwin or result.get("status") != "success":
        return result

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
    for i, client in clients.items():
        if read_only:
            # Not "telemetry failed" -- telemetry was never attempted. The clone session is a
            # WRITE into the pipeline's PRE, and the pipeline belongs to somebody else's
            # controller. Reported through `control_plane.skipped`, which is the only way a
            # reader can tell this apart from a fabric whose sampling broke.
            continue
        if i in broken:
            # The clone session lives in the pipeline's PRE, so there is nothing to program it into.
            # [Co-developed with claude code -- Adam]
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
            continue

        agent_ip = agent_ips.get(i)
        if agent_ip is None:
            print(f"[Proxy Agent] Switch {i} has no IP in the topology file; "
                  f"its samples would be attributed to nothing, so telemetry is off for it")
            continue

        sflow.register_switch(i, agent_ip)
        client.sample_callback = sflow.handle_sample
        if client.write_clone_session():
            telemetry.append(i)
            print(f"[Proxy Agent] Switch {i} sampling to sFlow as {agent_ip}")
        else:
            # Reported loudly: the pipeline still clones, bmv2 still drops the copy, and
            # everything downstream looks healthy while reporting zero traffic.
            print(f"[Proxy Agent] Switch {i}: clone session failed, NO telemetry from it")

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
        skipped.extend([SKIP_CLONE, SKIP_TELEMETRY, SKIP_LLDP, SKIP_WATCHDOG, SKIP_ROUTES])
        print(f"[Proxy Agent] {len(foreign)} of {len(clients)} switches "
              f"({sorted(foreign)}) run the app package's own pipeline, which carries no "
              f"controller header: this proxy will not send LLDP beacons, watch links or "
              f"install routes on ANY switch of this fabric. Skipped: "
              f"{', '.join(sorted(set(skipped)))}. Reported on GET /p4/switch_state.")
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
