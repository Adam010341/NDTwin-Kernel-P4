import os
import uvicorn
from fastapi import FastAPI
from proxy_agent.topology_manager import TopologyManager
from proxy_agent.p4_client import P4RuntimeClient
from proxy_agent.sflow_emitter import SFlowEmitter, load_switch_agent_ips
from proxy_agent.kernel_notifier import KernelNotifier
from proxy_agent import api_routes

app = FastAPI(title="P4 Proxy Agent", description="Ryu compatible API for BMv2")

topo = TopologyManager()

# Build the static topology (Matches MultiSwitchTopo)
# Hosts
topo.add_host(ip="10.0.0.1", mac="00:00:00:00:00:01", switch_dpid=1, port=3)
topo.add_host(ip="10.0.0.2", mac="00:00:00:00:00:02", switch_dpid=2, port=3)
topo.add_host(ip="10.0.0.3", mac="00:00:00:00:00:03", switch_dpid=3, port=3)
topo.add_host(ip="10.0.0.4", mac="00:00:00:00:00:04", switch_dpid=4, port=3)

# Links will be discovered dynamically via LLDP

api_routes.inject_topology(topo)
app.include_router(api_routes.router)

p4_clients = {}

# [Co-developed with claude code -- Adam]
sflow = SFlowEmitter()

# [Co-developed with claude code -- Adam]
# Pushes switch/link state to the kernel the way Ryu does. Without this the graph stays inert:
# inform_switch_entered is the only thing that sets isEnabled. See Phase 6 of
# doc/p4_bmv2_support_plan.md.
kernel = KernelNotifier()

@app.on_event("startup")
async def startup_event():
    print("[Proxy Agent] Starting up...")
    
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p4info_path = os.path.join(base_dir, 'p4_src', 'build', 'ndtwin_switch.p4info.txt')
    json_path = os.path.join(base_dir, 'p4_src', 'build', 'ndtwin_switch.json')
    
    # Connect to all 10 switches
    for i in range(1, 11):
        try:
            client = P4RuntimeClient(
                device_id=i, 
                grpc_addr=f'localhost:{50050+i}', 
                p4info_path=p4info_path, 
                json_path=json_path
            )
            client.start(push_config=False)
            topo.add_switch(i, client)
            p4_clients[i] = client
        except Exception as e:
            print(f"[Proxy Agent] Failed to connect to Switch {i}: {e}")
            
    # Wait ONCE for mastership to be confirmed on all switches
    import time
    time.sleep(1.0)
    
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
    for i, client in p4_clients.items():
        if not client.json_path:
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
        print(f"[Proxy Agent] {len(broken)} of {len(p4_clients)} switches have no pipeline "
              f"({sorted(broken)}); they will report as down and will not be enabled in the graph")

    # --- telemetry --------------------------------------------------------------------
    # [Co-developed with claude code -- Adam]
    #
    # Must come after the pipeline is pushed: the clone session lives in the pipeline's PRE, so
    # programming it earlier would be discarded. start(push_config=False) above is why this is
    # not done inside start().
    agent_ips = load_switch_agent_ips()
    for i, client in p4_clients.items():
        if i in broken:
            # The clone session lives in the pipeline's PRE, so there is nothing to program it into.
            # [Co-developed with claude code -- Adam]
            continue

        agent_ip = agent_ips.get(i)
        if agent_ip is None:
            print(f"[Proxy Agent] Switch {i} has no IP in the topology file; "
                  f"its samples would be attributed to nothing, so telemetry is off for it")
            continue

        sflow.register_switch(i, agent_ip)
        client.sample_callback = sflow.handle_sample
        if client.write_clone_session():
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
    # set up -- p4_clients only contains the ones that connected, and `broken` is excluded below
    # for the same reason: claiming a switch whose pipeline push failed would enable a vertex the
    # control plane demonstrably cannot drive.
    #
    # This is the call that makes the graph live. Without it every vertex and edge stays
    # isEnabled=false, which silently empties BFS pathing, flow-table polling and link-usage
    # attribution -- flows are still detected, but every `path` is [] and every rate is 0.
    usable = [i for i in p4_clients if i not in broken]
    entered = sum(1 for i in usable if kernel.switch_entered(i))
    if entered == len(usable):
        print(f"[Proxy Agent] Kernel acknowledged all {entered} usable switches")
    else:
        # Loud, because the symptom otherwise looks like a dead data plane rather than a
        # missed notification.
        print(f"[Proxy Agent] Kernel acknowledged only {entered}/{len(usable)} switches; "
              f"the graph will stay partly disabled and paths/rates will be empty for the rest")

    # Start LLDP dynamic topology discovery
    try:
        topo.start_lldp_discovery()
        print("[Proxy Agent] Started LLDP Discovery...")
    except Exception as e:
        print(f"[Proxy Agent] Failed to start LLDP discovery: {e}")

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

@app.on_event("shutdown")
async def shutdown_event():
    print("[Proxy Agent] Shutting down...")
    topo.stop_liveness_polling()
    for i, client in p4_clients.items():
        client.stop()
    sflow.close()

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8081)

# Developed in collaboration with Gemini 3.1 Pro.
