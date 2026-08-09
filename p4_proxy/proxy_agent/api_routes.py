from fastapi import APIRouter, Request, BackgroundTasks, HTTPException
import json
from proxy_agent.topology_manager import TopologyManager, UnsupportedMatchError
from proxy_agent import ryu_topology, ryu_flow_stats

# We will attach the topology manager instance to the router later
router = APIRouter()
topology = None # To be injected in main.py

def inject_topology(topo: TopologyManager):
    global topology
    topology = topo

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


@router.get("/v1.0/topology/switches")
async def topology_switches():
    if topology is None:
        return []
    return ryu_topology.render_switches(topology.switches.keys())


@router.get("/v1.0/topology/links")
async def topology_links():
    if topology is None:
        return []
    # Links the beacon watchdog believes are down are omitted, or the kernel's 1 s topology poll
    # re-enables the edge within a second of the failure being reported -- updateLinks has no path
    # that sets isEnabled false. [Co-developed with claude code -- Adam]
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
    return ryu_topology.render_destination_paths(topology.net)

@router.post("/stats/flowentry/add")
async def add_flow_entry(request: Request):
    """Parses OpenFlow match/actions and delegates to P4 Client"""
    data = await request.json()
    dpid = data.get("dpid")
    match = data.get("match", {})
    actions = data.get("actions", [])
    
    # [Co-developed with claude code -- Adam]
    # 400 with the offending field names, rather than servicing a narrowed version of the rule
    # and answering 200. The kernel's HttpRoutingStrategyBase already treats a non-2xx as a
    # failure and logs it with the endpoint, so this reaches an operator instead of becoming a
    # rule that quietly covers more traffic than was asked for.
    try:
        success = topology.route_flow(dpid, match, actions)
    except UnsupportedMatchError as err:
        raise HTTPException(status_code=400,
                            detail={"error": "unsupported match", "fields": err.fields,
                                    "message": str(err)})

    if success:
        return {"status": "success"}
    else:
        return {"status": "error", "message": "Failed to add route"}

@router.post("/stats/flowentry/delete_strict")
async def delete_flow_entry(request: Request):
    data = await request.json()
    dpid = data.get("dpid")
    match = data.get("match", {})
    
    try:
        success = topology.unroute_flow(dpid, match)
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
    data = await request.json()
    dpid = data.get("dpid")
    match = data.get("match", {})
    actions = data.get("actions", [])
    
    # [Co-developed with claude code -- Adam]
    # The two branches after the raise were unreachable. More importantly the raise itself
    # fired on every *successful* modify, because modify_ipv4_route had no `return True` on
    # its success path and the None propagated to here as falsy.
    try:
        success = topology.modify_flow(dpid, match, actions)
    except UnsupportedMatchError as err:
        raise HTTPException(status_code=400,
                            detail={"error": "unsupported match", "fields": err.fields,
                                    "message": str(err)})
    if not success:
        raise HTTPException(status_code=400, detail="Failed to modify flow entry in P4 switch")
    return {"status": "success"}

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
async def get_flow_stats(dpid: int):
    """
    This switch's tables in Ryu's /stats/flow/<dpid> shape.

    [Co-developed with claude code -- Adam]
    The kernel polls this and feeds the body to Classifier::updateFromQueriedTables, which is
    what produces every flow's `path`. Previously a hardcoded `[]`, which is why P4 paths were
    always empty -- and, because the kernel wraps the body as {"dpid": N, "flows": <body>}, a
    bare list also made `flows` a list where the documented shape is a map.

    Returns the empty map rather than an error when the switch is unknown or unreadable: this is
    polled once per second per switch, so a transient gRPC failure should cost one poll, not
    produce an HTTP error the kernel would log as a JSON parse failure.
    """
    client = topology.switches.get(dpid) if topology else None
    if client is None:
        return {str(dpid): []}
    try:
        return ryu_flow_stats.render_flow_stats(dpid, client.read_table_entries())
    except Exception as e:
        print(f"[Proxy Agent] Reading tables from switch {dpid} failed: "
              f"{type(e).__name__}: {e}")
        return {str(dpid): []}
