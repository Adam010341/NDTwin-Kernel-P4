import os
import uvicorn
from fastapi import FastAPI
from proxy_agent.topology_manager import TopologyManager
from proxy_agent.p4_client import P4RuntimeClient
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
    for i, client in p4_clients.items():
        if client.json_path:
            client.set_forwarding_pipeline_config()
        print(f"[Proxy Agent] Connected to Switch {i}")
            
    # Start LLDP dynamic topology discovery
    try:
        topo.start_lldp_discovery()
        print("[Proxy Agent] Started LLDP Discovery...")
    except Exception as e:
        print(f"[Proxy Agent] Failed to start LLDP discovery: {e}")

@app.on_event("shutdown")
async def shutdown_event():
    print("[Proxy Agent] Shutting down...")
    for i, client in p4_clients.items():
        client.stop()

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8081)

# Developed in collaboration with Gemini 3.1 Pro.
