from fastapi import APIRouter, Request, BackgroundTasks, HTTPException
import json
from proxy_agent.topology_manager import TopologyManager
from proxy_agent import ryu_topology

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
    return ryu_topology.render_links(topology.net)


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
    
    success = topology.route_flow(dpid, match, actions)
    
    if success:
        return {"status": "success"}
    else:
        return {"status": "error", "message": "Failed to add route"}

@router.post("/stats/flowentry/delete_strict")
async def delete_flow_entry(request: Request):
    data = await request.json()
    dpid = data.get("dpid")
    match = data.get("match", {})
    
    success = topology.unroute_flow(dpid, match)
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
    success = topology.modify_flow(dpid, match, actions)
    if not success:
        raise HTTPException(status_code=400, detail="Failed to modify flow entry in P4 switch")
    return {"status": "success"}

# Developed in collaboration with Gemini 3.1 Pro.

@router.get("/stats/flow/{dpid}")
async def get_flow_stats(dpid: int):
    """Dummy endpoint for NDTwin-Kernel's flow table polling"""
    # In the future, this should query P4Runtime to dump tables and format them like Ryu
    return []
