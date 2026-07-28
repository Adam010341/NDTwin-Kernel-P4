from fastapi import APIRouter, Request, BackgroundTasks, HTTPException
import json
from proxy_agent.topology_manager import TopologyManager

# We will attach the topology manager instance to the router later
router = APIRouter()
topology = None # To be injected in main.py

def inject_topology(topo: TopologyManager):
    global topology
    topology = topo

@router.get("/ryu_server/all_destination_paths")
async def get_all_paths():
    """Returns the BFS calculated paths in Ryu JSON format"""
    if not topology:
        return []
    # Ensure paths are updated before returning
    topology.calculate_all_paths()
    paths = topology.get_all_destination_paths_formatted()
    # NDTwin expects a JSON string or JSON array. 
    # FastAPI returns JSON response by default for dict/lists.
    return paths

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
