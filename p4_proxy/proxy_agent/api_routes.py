from fastapi import APIRouter, Request, BackgroundTasks, HTTPException
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool
import json
import time
from proxy_agent.topology_manager import TopologyManager, UnsupportedMatchError
from proxy_agent import ryu_topology, ryu_flow_stats

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

def inject_readopt(client_factory, sample_callback):
    global readopt_client_factory, readopt_sample_callback
    readopt_client_factory = client_factory
    readopt_sample_callback = sample_callback


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


def _grpc_status_name(exc):
    """
    The gRPC status name of an exception, or None if it is not a gRPC error.

    [Co-developed with claude code -- Adam]
    grpc.RpcError exposes code() but the concrete class is an internal name
    (_MultiThreadedRendezvous, _InactiveRpcError) that means nothing in a log. Duck-typed so this
    module keeps its lack of a gRPC import; a non-gRPC exception has no code() and falls back.
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

    if success:
        return {"status": "success"}
    else:
        return {"status": "error", "message": "Failed to add route"}

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
    
    try:
        success = await run_in_threadpool(topology.unroute_flow, dpid, match,
                                          data.get("priority"))
    except UnsupportedMatchError as err:
        raise HTTPException(status_code=400,
                            detail={"error": "unsupported match", "fields": err.fields,
                                    "message": str(err)})
    if success:
        return {"status": "success"}
    else:
        return {"status": "error", "message": "Failed to delete route"}

@router.post("/stats/flowentry/modify")
async def modify_flow_entry(request: Request):
    data = await _flowentry_body(request)
    dpid = data.get("dpid")
    match = data.get("match", {})
    actions = data.get("actions", [])
    
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
    return {"status": "success"}

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
    if readopt_client_factory is None:
        raise HTTPException(status_code=503,
                            detail="readopt is not wired: main.py did not inject a client "
                                   "factory, so this endpoint cannot build connections")

    result = topology.readopt_switch(dpid, readopt_client_factory, readopt_sample_callback)
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
    """
    if topology is None:
        raise HTTPException(status_code=503, detail="proxy has no topology yet")
    return topology.switch_liveness()


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
        return ryu_flow_stats.render_flow_stats(dpid, client.read_table_entries())
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
