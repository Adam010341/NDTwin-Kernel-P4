from fastapi import APIRouter, Request, BackgroundTasks, HTTPException
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool
import json
import time
from proxy_agent.topology_manager import TopologyManager, UnsupportedMatchError, needs_five_tuple
from proxy_agent import ryu_topology, ryu_flow_stats
# [Co-developed with claude code -- Adam]
# The three refusals POST /p4/table_entry has to turn into 409 / 501 / 400. Imported as types
# rather than matched on a message, because a message is a string somebody will reword and a
# status code derived from one would silently become a 500 the day they did. No cycle:
# p4_client imports boot_identity, rule_install_times and sflow_emitter, none of which reach
# back here.
from proxy_agent.p4_client import (ControlPlaneReadOnly, TableEntryInvalid,
                                   TableEntryUnsupported)

# We will attach the topology manager instance to the router later
router = APIRouter()
topology = None # To be injected in main.py

def inject_topology(topo: TopologyManager):
    global topology
    topology = topo

# Injected alongside the topology, for POST /p4/readopt/{dpid} (Phase 7 powerOn).
# [Co-developed with claude code -- Adam]
# The factory lives in main.py because that is where the p4info/json paths and the gRPC port
# numbering are decided; this module only knows how to hand it a dpid. The sample callback is
# the sFlow emitter's, wired the same way startup() wires it.
readopt_client_factory = None
readopt_sample_callback = None
# [Co-developed with claude code -- Adam]
# The third injected piece: main.py's `readopt_switch(topology, dpid, factory, callback)`.
# TopologyManager owns the re-adoption sequence and knows nothing about app packages, and what a
# foreign pipeline changes -- no clone session, the package's entries re-applied afterwards -- is
# package knowledge. So the decision is made where the package is known (main.py) and this module
# stays the translator from a result dict to a status code, which is all it ever was.
readopt_runner = None

def inject_readopt(client_factory, sample_callback, runner):
    global readopt_client_factory, readopt_sample_callback, readopt_runner
    readopt_client_factory = client_factory
    readopt_sample_callback = sample_callback
    readopt_runner = runner


# Injected for GET /sflow/stats (ticket P). [Co-developed with claude code -- Adam]
# The emitter already counts datagrams_sent, samples_sent and send_errors and has done since it
# was written; nothing in this repository ever read them. Ticket 1 measured telemetry losing 34%
# of its bytes under CPU contention and could not say which stage lost them, because the send
# side had no observable. This is the reader those counters never had.
#
# The emitter instance is injected rather than reached through readopt_sample_callback.__self__,
# which would work -- a bound method carries its instance -- but would make "handle_sample happens
# to be a method" part of this module's contract by accident.
sflow_emitter = None


def inject_emitter(emitter):
    global sflow_emitter
    sflow_emitter = emitter


# --- what the app package switched off. [Co-developed with claude code -- Adam] --------------
#
# 🔴 SKIPPING IS NOT SILENCE (PLAN-0917 3.4). A fabric running somebody else's control plane has
# no telemetry, no discovered links and no proxy-installed routes, and every one of those looks
# from the outside exactly like a fault. `GET /p4/switch_state` is where the kernel and an
# operator already look for this switch's evidence, so it is where the answer to "why is there
# none" has to be.
#
# Callables rather than a dict so the answer is read at request time: `skipped` is null until
# startup has decided, and a snapshot taken at injection would freeze that null in place.
control_plane_report = None
entries_recorded_report = None


def inject_control_plane(report, entries_recorded):
    global control_plane_report, entries_recorded_report
    control_plane_report = report
    entries_recorded_report = entries_recorded


# --- the G4/G5 half of the same disclosure (TICKET-P2 2.2). [Co-developed with claude code -- Adam]
#
# A second injector rather than three more arguments on the one above: `control_plane` and
# `entries_recorded` answer "what did the package switch off" and "how many rules did it declare",
# and these answer "which program is each switch running" and "what actually got written". Both
# are read at request time for the reason the first pair is -- startup fills them in while the
# kernel is already polling.
#
# `note_api_table_entry_write` is the counter POST /p4/table_entry increments. It lives in main.py
# with the other per-switch bookkeeping; this module holds no state of its own so that a proxy
# restart cannot leave a stale count behind an endpoint.
pipelines_report = None
table_entries_report = None
note_api_table_entry_write = None


def inject_package_reports(pipelines, table_entries, note_api_write):
    global pipelines_report, table_entries_report, note_api_table_entry_write
    pipelines_report = pipelines
    table_entries_report = table_entries
    note_api_table_entry_write = note_api_write


def _grpc_status_name(exc):
    """
    The gRPC status name of an exception, or None if it is not a gRPC error.

    [Co-developed with claude code -- Adam]
    grpc.RpcError exposes code() but the concrete class is an internal name
    (_MultiThreadedRendezvous, _InactiveRpcError) that means nothing in a log. Duck-typed rather
    than `isinstance(exc, grpc.RpcError)`: a non-gRPC exception has no code() and falls back, so
    this stays the one predicate for "did something below us fail with a status", whatever the
    class. (This module imports p4_client as of TICKET-P2, so gRPC is now a transitive
    dependency; an earlier version of this note said it was not, and that half has stopped
    being true.)
    """
    code = getattr(exc, "code", None)
    if not callable(code):
        return None
    try:
        status = code()
    except Exception:  # noqa: BLE001 -- reporting an error must not raise a second one
        return None
    return getattr(status, "name", None)

# --- Ryu-shaped topology, polled by the kernel -------------------------------------------
# [Co-developed with claude code -- Adam]
#
# TopologyAndFlowMonitor polls these three and parses them in updateSwitches/updateHosts/
# updateLinks. Serving Ryu's shapes means those functions work unchanged in P4 mode, the same
# way the proxy synthesises sFlow rather than adding a second ingest path.
#
# /ndt/inform_switch_entered alone is not enough: measured on a live kernel it took switches
# from 0/10 to 10/10 enabled but left edges at 0/40, so BFS still found no path. Edges are
# enabled by updateLinks(), which only runs off this poll.


@router.get("/sflow/stats")
async def sflow_stats():
    """Send-side sFlow counters, raw and cumulative. [Co-developed with claude code -- Adam]

    Ticket P splits a 34% telemetry shortfall across four stages, and this is the only one with no
    observable. samples_sent falling with the twin puts the loss upstream in bmv2; samples_sent
    holding while the twin falls puts it downstream, in the kernel, which would be a bug rather
    than a resource limit.

    Cumulative counters are returned raw, with the wall clock beside them, because the caller must
    differentiate two reads over a window. This project has already published a number obtained by
    averaging a cumulative counter, and it looked entirely reasonable.

    Not wired is an ERROR, never zeros. Returning zeros when the emitter was never injected is
    indistinguishable from "the send side stopped sending" -- which is precisely the signal this
    endpoint exists to detect, so the one failure it must not have is the one that mimics its own
    finding. This repo's largest live defect family is a writer with no reader; the second-largest
    is a reader that silently reports the absence of its own wiring as data.
    """
    if sflow_emitter is None:
        raise HTTPException(status_code=503,
                            detail="sflow emitter not injected -- this is a wiring failure, "
                                   "not a measurement of zero")
    return {
        "t": time.time(),
        "datagrams_sent": sflow_emitter.datagrams_sent,
        "samples_sent": sflow_emitter.samples_sent,
        "send_errors": sflow_emitter.send_errors,
        "batch_size": getattr(sflow_emitter, "batch_size", None),
    }


@router.get("/v1.0/topology/switches")
async def topology_switches():
    if topology is None:
        return []
    # [Co-developed with claude code -- Adam]
    # connected_switch_dpids(), not switches.keys(). render_switches' contract -- "a switch the
    # proxy cannot reach does not appear, so the kernel does not mark it enabled" -- was correct
    # and this caller was the one breaking it: switches.keys() is every client ever built, dead
    # ones included. See connected_switch_dpids for what that cost the twin.
    return ryu_topology.render_switches(topology.connected_switch_dpids())


@router.get("/v1.0/topology/links")
async def topology_links():
    if topology is None:
        return []
    # Links the beacon watchdog believes are down are omitted, or the kernel's next topology poll
    # re-enables the edge -- updateLinks has no path that sets isEnabled false.
    #
    # The poll interval is 5 s for the kernel process's first 90 s and 30 s thereafter
    # (kWhileConverging / kOnceConverged / kConvergingFor in TopologyAndFlowMonitor.cpp's run()).
    # This comment used to say "1 s ... within a second", which was a misreading of the 1 s sleep
    # slice in that same loop -- the slice exists so stop() need not wait out a whole interval.
    # The reason for filtering is unchanged; the undo window is 5-30x wider than stated.
    # See TopologyManager.down_link_endpoints for the full argument.
    # [Co-developed with claude code -- Adam]
    return ryu_topology.render_links(topology.net, topology.down_link_endpoints())


@router.get("/v1.0/topology/hosts")
async def topology_hosts():
    if topology is None:
        return []
    return ryu_topology.render_hosts(topology.net)


@router.get("/ryu_server/all_destination_paths")
async def get_all_paths():
    """
    Host-to-host paths in the shape the kernel's setAllPaths consumes.

    [Co-developed with claude code -- Adam]
    Previously returned TopologyManager's own `[{"node":..., "paths":{...}}]` structure, which
    the kernel cannot read: it requires a `{"status":"success","all_destination_paths":[...]}`
    envelope containing `[node, out_port]` pair lists, and refuses the body outright when
    `status` is absent. That mismatch is why `get_path_switch_count` answered "Path not found"
    in P4 mode even with the graph fully enabled -- `m_switchCountMap` is filled from here, not
    from the topology poll.

    The format matches intelligent_router.py, which is the working reference for OVS mode.
    """
    if not topology:
        return {"status": "success", "all_destination_paths": []}
    # Links the watchdog believes are down are excluded from the search, or m_switchCountMap ends
    # up holding a route over a dead link. [Co-developed with claude code -- Adam]
    return ryu_topology.render_destination_paths(
        topology.net, topology.down_link_endpoints(), topology.installed_routes())

# [Co-developed with claude code -- Adam]
# These three stay `async def` because they must `await request.json()`, so the blocking half is
# pushed to the threadpool by hand instead. route_flow/unroute_flow/modify_flow all end in a gRPC
# Write against one switch, and a switch that is alive but not answering blocks that call -- on the
# event loop, that is the same total outage get_flow_stats caused (see its docstring for the
# measurement). run_in_threadpool is what FastAPI itself uses for `def` endpoints, so this puts
# them on the identical footing without changing how the body is parsed or how errors propagate.

async def _flowentry_body(request: Request):
    """
    The request body as a dict, or a 400 that says what was wrong with it.

    [Co-developed with claude code -- Adam]
    `await request.json()` raises straight through to a 500 for a body that is not JSON at
    all, and `data.get(...)` does the same for a body that is JSON but not an object (live
    2026-08-16). Same defect class MalformedMatchError closed one layer down: a malformed
    request is the client's error and must be answered as one, not as a proxy crash.
    """
    try:
        data = await request.json()
    except ValueError:
        # json.JSONDecodeError and UnicodeDecodeError are both ValueError subclasses.
        raise HTTPException(status_code=400,
                            detail={"error": "malformed body",
                                    "message": "request body is not valid JSON"})
    if not isinstance(data, dict):
        raise HTTPException(status_code=400,
                            detail={"error": "malformed body",
                                    "message": "request body must be a JSON object, got "
                                               + type(data).__name__})
    return data


def _named_priority(data):
    """
    The priority this caller actually asked for, or None if they asked for none.

    [Co-developed with claude code -- Adam]
    Three values mean "no priority named", and telling them apart from a real request is the
    whole difference between a refusal that protects the fabric and one that stops it:

      * the key is absent -- HttpRoutingStrategyBase omits it entirely for the non-strict
        routes, which is every delete the control plane and the IntentTranslator make;
      * -1 -- FlowRoutingManager::deleteAnEntry's default, the "delete anything matching"
        sentinel the kernel turns into the non-strict POST;
      * 0 -- HttpSession::makeModifyJob's default for an ABSENT priority, so it arrives on
        every ordinary modify. `p4_priority` reads 0 the same way, mapping it to the lowest
        ternary band as the default for a caller who expressed no preference.

    A non-integer is not diagnosed here. It is not this predicate's error to own, and guessing
    would turn a value problem into a capability answer that names the wrong fault.
    """
    raw = data.get("priority")
    if raw is None:
        return None
    try:
        priority = int(raw)
    except (TypeError, ValueError):
        return None
    return priority if priority > 0 else None


def _refuse_unhonourable_priority(data, match, verb):
    """
    Refuse a delete or modify whose priority the destination table cannot honour.

    [Co-developed with claude code -- Adam]
    doc/audit/2026-09-03_night-rounds/DECISION-P4-PRIORITY.md. This is deliberately NOT applied
    to /stats/flowentry/add, and the difference is not squeamishness about breaking callers --
    it is that the priority means two different things on the two sides:

      * On an install it is a request about PRECEDENCE. The rule is programmed and does
        forward; what is lost is the layering. add_flow_entry answers that with
        `priority_honoured: false` and a note, per T-15 Option 0 and the 2026-08-30 §1.2
        ruling, and this change leaves that ruling exactly where it stands.

      * On delete_strict and modify it is IDENTITY -- it names WHICH entry the caller means.
        ipv4_lpm holds one entry per destination and has no priority column, so every priority
        names that same entry. Measured 2026-09-03: a modify at priority 777, a priority that
        had never existed on this switch, rewrote the entry that was there, and a delete at
        priority 999 removed it; both answered 200. A disclosure field cannot repair that,
        because it is read after the rule the caller never named is already gone.

    501, not 400. The request is well-formed OpenFlow -- nothing about it is the client's
    mistake, and answering 400 makes the same misattribution OpResult::notSent was added to
    stop (OpResult.hpp:78-98). What is true is that this data plane does not implement it, in
    exactly the sense the six group/meter endpoints already mean by it, so this reuses their
    shape: a 501 whose body names why, carrying `outcome: "unsupported_on_p4"`
    (src/ndt_core/routing_management/P4RoutingStrategy.cpp:11-23). A client that already
    handles those six needs no new code for this one.

    The kernel needs no change either: HttpRoutingStrategyBase::post turns any non-2xx into an
    OpResult::failure carrying the status and the body, HttpSession passes 400..599 through,
    and the flow path -- which answers "queued" before the southbound request is made -- books
    it as failed+1 with the reason in get_flow_dispatch_status's `recent_failures` instead of
    counting it in `succeeded`.

    🔴 `remedy` exists because of WHERE that reason is read, not because the message was unclear.
    HttpRoutingStrategyBase.cpp:62-79 puts the response body through `briefly(body, 200)` before
    it becomes OpResult::failure's message, and that string is the whole of what a caller can
    get back: it is `recent_failures[].message` in get_flow_dispatch_status and it is the
    kernel's log line. Measured 2026-09-11 (hunt-0911/ROLE-5, 4312 POSTs, 2152 of 2152 deletes
    refused): this body is 838 bytes, the cut landed mid-word at "data plan", and so every
    reader of the failure record saw the diagnosis and not one of them saw what to do instead.
    `remedy` is placed ahead of `table` so that the one sentence a caller can act on is inside
    the 200-byte window -- p4_proxy/tests/test_flowentry_endpoints.py asserts that against
    FastAPI's own serializer rather than against a hand-counted string.

    Raises HTTPException(501) or returns None.
    """
    priority = _named_priority(data)
    if priority is None or needs_five_tuple(match):
        return
    raise HTTPException(
        status_code=501,
        detail={
            "error": "priority not honourable on this table",
            "outcome": "unsupported_on_p4",
            "remedy": "omit priority, or match the full five-tuple",
            "table": "ipv4_lpm",
            "requested_priority": priority,
            "message": (
                f"this {verb} names priority {priority}, and on a P4/bmv2 data plane a match "
                "of this shape compiles to the ipv4_lpm table, which has no priority column: "
                "precedence there is the prefix length, and the table holds one entry per "
                "destination. The priority cannot select an entry, so honouring the request "
                f"would {verb} whichever entry that destination has, at whatever priority it "
                "was installed with, rather than the one named -- which is what this used to "
                "do while answering 200. A match naming more than a destination compiles to "
                "flow_5tuple, where priority is part of the entry's identity and is honoured; "
                "a request that means \"whatever is there\" should omit the priority and take "
                "the non-strict route."),
        })


def _priority_disclosure(match):
    """
    `table` and `priority_honoured` for a write that was not refused.

    [Co-developed with claude code -- Adam]
    The same two fields add_flow_entry already returns, derived by the same predicate the
    topology branches on so they cannot drift from where the rule actually went. Additive, so
    the kernel -- whose only check on this body is `status == "error"`,
    HttpRoutingStrategyBase.cpp:123-125 -- cannot see the difference.

    They describe the TABLE's capability, not this request: a priority-less delete against
    ipv4_lpm reports `priority_honoured: false` even though it asked for nothing, exactly as
    the add endpoint does. Making the field mean "your particular priority survived" would give
    the same word two readings across three endpoints.
    """
    table = "flow_5tuple" if needs_five_tuple(match) else "ipv4_lpm"
    return {"table": table, "priority_honoured": table == "flow_5tuple"}


@router.post("/stats/flowentry/add")
async def add_flow_entry(request: Request):
    """
    Parses OpenFlow match/actions and delegates to P4 Client

    [Co-developed with claude code -- Adam]
    The kernel sends `priority` on every install and `idle_timeout` when an app asks for one.

    `priority` is now READ, and this comment used to say it never was. It had no meaning while
    every rule went to ipv4_lpm -- an LPM table's tiebreak is the prefix length and nothing
    else -- but a match naming more than a destination now compiles to the ternary flow_5tuple
    table, where priority is both meaningful and mandatory. It is still ignored for the
    destination-only path, which is every rule the kernel itself writes, so this changes nothing
    for existing callers. [Co-developed with claude code -- Adam]

    `idle_timeout` is still read nowhere, and still deliberately: no producer in this system
    asks for ageing, and rejecting it would refuse nothing since nothing sends one.
    """
    data = await _flowentry_body(request)
    dpid = data.get("dpid")
    match = data.get("match", {})
    actions = data.get("actions", [])
    
    # [Co-developed with claude code -- Adam]
    # 400 with the offending field names, rather than servicing a narrowed version of the rule
    # and answering 200. The kernel's HttpRoutingStrategyBase already treats a non-2xx as a
    # failure and logs it with the endpoint, so this reaches an operator instead of becoming a
    # rule that quietly covers more traffic than was asked for.
    try:
        success = await run_in_threadpool(topology.route_flow, dpid, match, actions,
                                          data.get("priority"))
    except UnsupportedMatchError as err:
        raise HTTPException(status_code=400,
                            detail={"error": "unsupported match", "fields": err.fields,
                                    "message": str(err)})

    if not success:
        return {"status": "error", "message": "Failed to add route"}

    # [Co-developed with claude code -- Adam]
    # FINDING-07's residue, and the only part of it that is fixable anywhere: the value was
    # never dropped by any layer. A destination-only match compiles to `ipv4_lpm`, a P4 LPM
    # table with no priority column at all -- precedence there is the prefix length -- so the
    # priority the caller sent is unrepresentable at the destination rather than lost in
    # transit. What was wrong was answering `success` and saying nothing: the answer was true
    # about the request and false about the consequence. Seventeen rules were posted at 902 and
    # 910-927 on 2026-08-30 and every one read back at priority 0, and no response said why.
    #
    # Disclosed, not refused. A 200 -> 400 here is a breaking change for a caller that does not
    # read status codes and this project has one, so the refusal half stays with T-15 Option 0
    # and the 2026-08-30 §1.2 ruling. Additive fields cost that caller nothing: the kernel's
    # only check on this body is `status == "error"`
    # (src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:123-125).
    #
    # Derived from the match by the same predicate route_flow branches on, so it cannot drift
    # from where the rule actually went -- the property T-15 Option 1 wants of a capability
    # answer, at the one place a caller is already looking.
    table = "flow_5tuple" if needs_five_tuple(match) else "ipv4_lpm"
    body = {"status": "success", "table": table, "priority_honoured": table == "flow_5tuple"}
    if data.get("priority") is not None and table == "ipv4_lpm":
        # Only when a priority was actually asked for. Every rule the kernel writes itself is
        # destination-only and sends none; a note on all of those is a note nobody still reads
        # by the time one matters.
        body["priority_note"] = (
            "ipv4_lpm has no priority column, so this rule's precedence is its prefix length "
            "and the requested priority was not programmed. A match naming more than a "
            "destination compiles to flow_5tuple, where priority is honoured.")
    return body

@router.post("/stats/flowentry/delete")
@router.post("/stats/flowentry/delete_strict")
async def delete_flow_entry(request: Request):
    """
    Both delete routes, because ofctl_rest serves both and the kernel uses both.

    [Co-developed with claude code -- Adam]
    FlowRoutingManager::deleteAnEntry defaults priority to -1, which HttpRoutingStrategyBase
    turns into the non-strict POST /stats/flowentry/delete -- the route every priority-less
    delete takes, and the IntentTranslator's only delete call. This proxy served only
    /delete_strict, so the kernel's most natural delete answered 404 in P4 mode (live
    2026-08-16). One handler serves both routes: ipv4_lpm keys on the destination alone and
    holds one entry per destination, so "this exact rule" and "every rule matching this
    destination" name the same rule here -- the reason delete_strict already ignores
    priority. The OpenFlow wildcard half of non-strict (an empty match clears the table) is
    deliberately not honoured: a match without nw_dst is refused, because an accidental
    table wipe is the worse failure.
    """
    data = await _flowentry_body(request)
    dpid = data.get("dpid")
    match = data.get("match", {})

    # [Co-developed with claude code -- Adam] Before the topology call, not after: a refusal
    # that answers 501 once the entry is already gone is the same defect wearing a status code.
    _refuse_unhonourable_priority(data, match, "delete")

    try:
        success = await run_in_threadpool(topology.unroute_flow, dpid, match,
                                          data.get("priority"))
    except UnsupportedMatchError as err:
        raise HTTPException(status_code=400,
                            detail={"error": "unsupported match", "fields": err.fields,
                                    "message": str(err)})
    if success:
        return {"status": "success", **_priority_disclosure(match)}
    else:
        return {"status": "error", "message": "Failed to delete route"}

@router.post("/stats/flowentry/modify")
async def modify_flow_entry(request: Request):
    data = await _flowentry_body(request)
    dpid = data.get("dpid")
    match = data.get("match", {})
    actions = data.get("actions", [])

    # [Co-developed with claude code -- Adam] As delete_flow_entry: before the write, because
    # the harm this refuses is an edit to an entry the caller never named.
    _refuse_unhonourable_priority(data, match, "modify")

    # [Co-developed with claude code -- Adam]
    # The two branches after the raise were unreachable. More importantly the raise itself
    # fired on every *successful* modify, because modify_ipv4_route had no `return True` on
    # its success path and the None propagated to here as falsy.
    try:
        success = await run_in_threadpool(topology.modify_flow, dpid, match, actions,
                                          data.get("priority"))
    except UnsupportedMatchError as err:
        raise HTTPException(status_code=400,
                            detail={"error": "unsupported match", "fields": err.fields,
                                    "message": str(err)})
    if not success:
        raise HTTPException(status_code=400, detail="Failed to modify flow entry in P4 switch")
    return {"status": "success", **_priority_disclosure(match)}

@router.post("/p4/readopt/{dpid}")
def readopt(dpid: int):
    """
    Rebuild the proxy's relationship with one restarted bmv2 switch (Phase 7 powerOn).

    [Co-developed with claude code -- Adam]
    P4PowerStrategy calls this after ndtwin-p4-power has relaunched the process and seen its
    gRPC port open. The open port is where the helper's knowledge ends and this endpoint's
    work begins: mastership, pipeline, clone session and routes are all gone with the old
    process, and the liveness probe cannot tell (see readopt_switch's docstring).

    Deliberately `def`, not `async def`: the sequence sleeps for the mastership settle and
    then blocks on gRPC round trips, so FastAPI must run it on the threadpool. As an async
    handler it would stall the event loop -- and with it every other endpoint, including the
    /p4/switch_state poll the kernel reads once a second -- for the whole readopt.

    502 for a readopt that failed at a named step, 404 for a dpid startup never knew;
    both carry the step detail so the kernel's log says what actually broke.
    """
    if topology is None:
        raise HTTPException(status_code=503, detail="proxy has no topology yet")
    if readopt_client_factory is None or readopt_runner is None:
        raise HTTPException(status_code=503,
                            detail="readopt is not wired: main.py did not inject a client "
                                   "factory, so this endpoint cannot build connections")

    # [Co-developed with claude code -- Adam]
    # Through main.py's wrapper, not straight at the TopologyManager: under a foreign pipeline
    # the switch gets no clone session and the package's own entries go back on afterwards, and
    # both of those are decisions only the side that holds the package can make. The wrapper
    # returns the same result dict, so the three status codes below are unchanged.
    result = readopt_runner(topology, dpid, readopt_client_factory, readopt_sample_callback)
    if result["status"] == "unknown-switch":
        raise HTTPException(status_code=404, detail=result)
    if result["status"] != "success":
        raise HTTPException(status_code=502, detail=result)
    return result


# Developed in collaboration with Gemini 3.1 Pro.

@router.get("/p4/switch_state")
async def switch_state():
    """
    Per-switch liveness evidence, for the kernel's pingWorker.

    [Co-developed with claude code -- Adam]
    Not a Ryu shape, because Ryu has no equivalent: OVS liveness is answered by `ovs-vsctl list-br`
    on the same host, and there is nothing to impersonate. This is the one endpoint the kernel talks
    to that is openly P4-specific, so it is namespaced under /p4/ rather than pretending otherwise.

    Reports facts, not a verdict. The kernel applies the Up/Down/Unknown policy, so that the
    distinction between "I asked the switch and it did not answer" and "I could not ask" survives
    the trip -- conflating those is what made a single failed `ovs-vsctl` call mark an entire fabric
    dead on the OVS side.

    503 when the proxy has no topology at all, which is a different thing from every switch being
    down and must not be answerable with an empty switch map.

    [Co-developed with claude code -- Adam]
    Two additive fields carry the app package's disclosure (PLAN-0917 3.4, TICKET-P1 2.3):

      * top-level `control_plane` -- {mode, package, skipped}. `skipped` is null before startup
        has run and a list afterwards, so "nothing was skipped" cannot be confused with "nobody
        has started yet".
      * per switch, `entries_recorded` -- how many table entries the package declares for it.
        Phase 1 applies NONE of them, so this number is the difference between "the package's
        rules are not on the switch because we have not built that yet" and "the package had no
        rules". It is 0 on the baseline fabric, which has no package.

    Both are emitted on the baseline fabric too, where they read `mode: ndtwin, package: null,
    skipped: []` and `entries_recorded: 0`. That IS a change to the baseline response, and it is
    deliberate: a disclosure field that only appears when there is something to disclose is
    indistinguishable, to a reader, from a proxy too old to disclose anything -- which is the
    same "reports zero rather than reports an error" shape the fields exist to close.

    Additive in the sense the kernel cares about: it looks up "switches" by name and then named
    keys inside each entry (DeviceConfigurationAndPowerManager::p4LivenessFor), so an unknown
    top-level key and an unknown per-switch key are both inert to that parse.
    """
    if topology is None:
        raise HTTPException(status_code=503, detail="proxy has no topology yet")
    state = topology.switch_liveness()
    if control_plane_report is not None:
        state["control_plane"] = control_plane_report()
    if entries_recorded_report is not None:
        recorded = entries_recorded_report()
        for dpid, entry in state.get("switches", {}).items():
            entry["entries_recorded"] = recorded.get(str(dpid), 0)
    # [Co-developed with claude code -- Adam]
    # Two more per-switch keys, TICKET-P2 2.2. In a loop of their own rather than folded into the
    # one above, because that loop is `tests/shell/mutate_app_package.sh` M20's anchor and a gate
    # cell that stops resolving is a cell that reports SURVIVOR for everything.
    #
    #   pipeline       which program this switch is running, and a stable identifier for it. The
    #                  sha is of the p4info, never of the bmv2 JSON: that file carries the
    #                  absolute path of its source, so the same program compiled twice in two
    #                  directories has two hashes.
    #   table_entries  recorded / applied / failed / api_writes / journaled. `journaled: false`
    #                  is a constant and is emitted anyway: these rules do NOT survive a proxy
    #                  restart and nothing replays them (Adam 2026-09-18, option a), and a reader
    #                  who is not told that finds an empty table with no explanation.
    if pipelines_report is not None:
        pipelines = pipelines_report()
        for dpid, entry in state.get("switches", {}).items():
            entry["pipeline"] = pipelines.get(str(dpid))
    if table_entries_report is not None:
        written = table_entries_report()
        for dpid, entry in state.get("switches", {}).items():
            entry["table_entries"] = written.get(
                str(dpid), {"recorded": 0, "applied": 0, "failed": 0, "api_writes": 0,
                            "journaled": False})
    return state


#: Attached to every accepted `POST /p4/table_entry`. Adam's 2026-09-18 ruling (option a) is that
#: phase 2 does not journal these, and the consequence is stated in the response itself rather
#: than only in a document: an operator who POSTs a rule and restarts the proxy gets an empty
#: table, and the only warning they will ever read is this one.
#: [Co-developed with claude code -- Adam]
TABLE_ENTRY_NOT_JOURNALED = ("not journaled: this entry is lost when the proxy restarts "
                             "(Adam 2026-09-18, option a)")


@router.post("/p4/table_entry")
async def table_entry(request: Request):
    """
    Write one table entry, in the shape tutorials' `sX-runtime.json` already uses. TICKET-P2 2.3.

    [Co-developed with claude code -- Adam]
    The existing `/stats/flowentry/*` endpoints speak OpenFlow and compile a match down to one of
    NDTwin's own two tables. This one speaks P4: it names a table, an action and their parameters
    out of the pipeline the switch is actually running, which is the only way to program a
    package that brought its own program.

        {"dpid": 1, "op": "insert",
         "table": "MyIngress.ipv4_lpm",
         "match": {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]},
         "action_name": "MyIngress.ipv4_forward",
         "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1},
         "default_action": false, "priority": null}

    🔴 NOT JOURNALED, AND THE RESPONSE SAYS SO. `rule_journal` records what the kernel's routing
    asks for so a restart has something to fall back on; a rule POSTed here is recorded nowhere
    and is gone with the process. Adam ruled that phase 2 ships it that way (option a), so the
    duty this endpoint has is to be honest about it in the one place a caller definitely reads --
    `journaled: false` plus a note, on every success. `switch_state`'s `table_entries.api_writes`
    is the other half: it counts them, so the rules that will vanish are countable before they do.

    Status codes, and what each one means happened to the switch:

        200  the switch accepted the write.
        400  the request cannot be represented in this pipeline -- a value wider than its field,
             an lpm prefix out of range, a default action carrying a match, a priority on a
             table with no priority column, an unknown `op`. NOTHING was written.
        404  an unknown dpid, or a table / field / action / parameter this switch's p4info does
             not describe. NOTHING was written.
        409  this fabric's package declares an external control plane, so the proxy reads only.
             NOTHING was written.
        501  the entry needs a ternary, range or optional match, which this phase does not
             build. NOTHING was written.
        502  the switch itself refused it; the body carries the gRPC status name.

    Every non-200 above is reached before `stub.Write`, and tests/test_table_entry_route.py
    asserts the stub saw no request for each of them -- "nothing was written" is a claim about
    the wire, so it is checked on the wire.

    `def`-shaped work inside an `async def`: the body has to be awaited, and the write blocks on
    a gRPC round trip, so the blocking half goes to the threadpool by hand -- the same treatment
    and the same reason as the three flowentry endpoints above.
    """
    data = await _flowentry_body(request)
    if topology is None:
        raise HTTPException(status_code=503, detail="proxy has no topology yet")

    raw_dpid = data.get("dpid")
    if isinstance(raw_dpid, bool) or not isinstance(raw_dpid, int):
        raise HTTPException(
            status_code=400,
            detail={"error": "malformed body",
                    "message": f"'dpid' must be an integer, got {raw_dpid!r}"})
    client = topology.switches.get(raw_dpid)
    if client is None:
        # 404, the same answer an unknown table gets: from the caller's side both are "the thing
        # you named is not here". A 503 would say "try again", and a dpid the proxy never
        # connected to will not appear by being retried.
        raise HTTPException(
            status_code=404,
            detail={"error": "unknown switch",
                    "message": f"switch {raw_dpid} is not connected to the proxy",
                    "dpid": raw_dpid})

    op = data.get("op", "insert")
    spec = {key: data.get(key) for key in
            ("table", "match", "action_name", "action_params", "default_action", "priority")
            if key in data}

    try:
        written = await run_in_threadpool(client.write_table_entry, spec, op)
    except ControlPlaneReadOnly as err:
        raise HTTPException(
            status_code=409,
            detail={"error": "external control plane", "dpid": raw_dpid,
                    "message": str(err)})
    except TableEntryUnsupported as err:
        raise HTTPException(
            status_code=501,
            detail={"error": "match type not supported", "outcome": "unsupported_on_p4",
                    "remedy": "use an exact or lpm match, or wait for the ternary writer",
                    "dpid": raw_dpid, "message": str(err)})
    except TableEntryInvalid as err:
        raise HTTPException(
            status_code=400,
            detail={"error": "invalid table entry", "dpid": raw_dpid, "message": str(err)})
    except KeyError as err:
        # KeyError stringifies with its own quotes (`"table 'x' not found"`), so the argument is
        # unwrapped -- a message a caller reads should not be double-quoted.
        raise HTTPException(
            status_code=404,
            detail={"error": "not in this pipeline", "dpid": raw_dpid,
                    "message": err.args[0] if err.args else str(err)})
    except Exception as err:  # noqa: BLE001 -- gRPC, or anything else the switch did
        reason = _grpc_status_name(err)
        if reason is None:
            raise
        raise HTTPException(
            status_code=502,
            detail={"error": "the switch refused the write", "dpid": raw_dpid,
                    "grpc_status": reason,
                    "message": f"switch {raw_dpid} refused this entry: {reason}"})

    if note_api_table_entry_write is not None:
        note_api_table_entry_write(raw_dpid)
    return {"status": "success", "dpid": raw_dpid, "op": written["op"],
            "table": written["table"], "match_types": written["match_types"],
            "priority_honoured": written["priority_honoured"],
            "journaled": False, "note": TABLE_ENTRY_NOT_JOURNALED}


@router.get("/stats/flow/{dpid}")
def get_flow_stats(dpid: int):
    """
    This switch's tables in Ryu's /stats/flow/<dpid> shape.

    [Co-developed with claude code -- Adam]
    The kernel polls this and feeds the body to Classifier::updateFromQueriedTables, which is
    what produces every flow's `path`. Previously a hardcoded `[]`, which is why P4 paths were
    always empty -- and, because the kernel wraps the body as {"dpid": N, "flows": <body>}, a
    bare list also made `flows` a list where the documented shape is a map.

    A failure answers 503 with {"error": ...} -- it used to answer the empty map, on the theory
    that a transient gRPC failure should cost one poll rather than produce a parse-error log
    line. But the kernel's side of this contract says the opposite: an empty table is a snapshot
    that MUST be applied (Classifier::updateFromQueriedTables sweeps every rule absent from it),
    and its only guard was latency -- a read that failed *fast* sailed under the 0.5 s suspicion
    threshold and blanked every flow's path for that switch, with nothing logged kernel-side.
    The two policies contradicted each other, and the kernel's is the one grounded in a measured
    incident (the 2026-08-07 Ryu wedge), so the proxy now says "failed" distinguishably.

    The kernel shells out `curl -s`, which never sees the status code -- the *body shape* is the
    signal. classifyFlowStatsReply treats an object carrying "error" as ReportedFailure and keeps
    the previous table. The unknown-switch case answers the same way because it is the same
    situation from the caller's side: right after a proxy restart the switch map is empty while
    the kernel is still polling every dpid it knows, and an empty-map answer here would have
    blanked all ten switches' tables until discovery caught up.

    [Co-developed with claude code -- Adam]
    Deliberately `def`, not `async def` -- the same reason readopt is, and this endpoint is where
    that reason was learned. read_table_entries blocks on a gRPC stream, so as a coroutine it ran
    that block *on the event loop*: one bmv2 that stopped answering took the entire agent down,
    every endpoint, for as long as it stayed stopped. Measured 2026-08-13 with s5 SIGSTOPed --
    /p4/switch_state went from 1.9 ms to no response at all, and the kernel, unable to read any
    switch's liveness, walked the graph down from 40/40 edges to 32/40. A single switch's fault
    amplified into total loss of fabric state.

    py-spy on the live proxy named the frame: MainThread, inside run_endpoint_function ->
    get_flow_stats -> read_table_entries, with `run_forever` underneath it. The same dump showed
    the liveness prober idle and healthy and the AnyIO worker pool completely unused -- the
    Unknown-state evidence the kernel needed was sitting in the cache the whole time, and a free
    threadpool worker was sitting right there to serve it. Hence `def`: FastAPI dispatches
    non-coroutine endpoints to that pool, and the loop stays free to answer everyone else.
    """
    client = topology.switches.get(dpid) if topology else None
    if client is None:
        return JSONResponse(
            status_code=503,
            content={"error": f"switch {dpid} is not connected to the proxy"},
        )
    try:
        # [Co-developed with claude code -- Adam]
        # The client's OWN install record, not a fresh one and not a module global: it is the
        # object the write paths on this same client stamped, and the switch it describes is the
        # switch these entries were just read from. KNOWN-ISSUES G-13.
        #
        # Read as a plain attribute rather than through getattr(..., None): an optional argument
        # production forgets to pass is the exact shape of finding #71, where the rule journal
        # had 33 green tests and no caller because every one of them injected the journal itself.
        # If a client cannot answer this, the endpoint must fail loudly here rather than serve
        # duration 0/0 forever and let the silence read as "P4 has no clock".
        return ryu_flow_stats.render_flow_stats(dpid, client.read_table_entries(),
                                                install_times=client.rule_install_times)
    except Exception as e:
        # [Co-developed with claude code -- Adam]
        # The gRPC status name, not the Python class name. A deadline against a stopped switch
        # raises _MultiThreadedRendezvous, and that is what the kernel used to log verbatim in its
        # ReportedFailure warning -- an internal grpc class telling an operator nothing about what
        # went wrong. `probe()` already made this argument and already reads e.code().name; this
        # path just never got the same treatment. Found by the 2026-08-13 live run of this fix.
        #
        # Read by duck-typing rather than importing grpc: this module has no gRPC dependency today
        # and the reason to add one would be a single attribute lookup.
        reason = _grpc_status_name(e) or type(e).__name__
        print(f"[Proxy Agent] Reading tables from switch {dpid} failed: {reason}: {e}")
        return JSONResponse(
            status_code=503,
            content={"error": f"reading tables from switch {dpid} failed: {reason}"},
        )
