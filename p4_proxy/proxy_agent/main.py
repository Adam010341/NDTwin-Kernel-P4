import asyncio
import os
import uvicorn
from fastapi import FastAPI
from proxy_agent.topology_manager import TopologyManager
from proxy_agent.p4_client import P4RuntimeClient
from proxy_agent.sflow_emitter import SFlowEmitter, load_switch_agent_ips
from proxy_agent.kernel_notifier import KernelNotifier
from proxy_agent import api_routes

app = FastAPI(title="P4 Proxy Agent", description="Ryu compatible API for BMv2")

# [Co-developed with claude code -- Adam]
# Pushes switch/link state to the kernel the way Ryu does. Without this the graph stays inert:
# inform_switch_entered is the only thing that sets isEnabled. See Phase 6 of
# doc/2026-07-27_p4_bmv2_support_plan.md.
kernel = KernelNotifier()

# Built with the notifier already in hand: the beacon watchdog reports link failures through it,
# and a TopologyManager constructed without one silently keeps the bookkeeping to itself.
topo = TopologyManager(kernel_notifier=kernel)

# Build the static topology (Matches MultiSwitchTopo)
# Hosts
topo.add_host(ip="10.0.0.1", mac="00:00:00:00:00:01", switch_dpid=1, port=3)
topo.add_host(ip="10.0.0.2", mac="00:00:00:00:00:02", switch_dpid=2, port=3)
topo.add_host(ip="10.0.0.3", mac="00:00:00:00:00:03", switch_dpid=3, port=3)
topo.add_host(ip="10.0.0.4", mac="00:00:00:00:00:04", switch_dpid=4, port=3)

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
sflow = SFlowEmitter()

#: How long to let mastership settle before pushing pipelines. bmv2 accepts the arbitration
#: message before it has finished electing, and a config push in that window is rejected.
MASTERSHIP_SETTLE_S = 1.0

#: The switches this proxy expects, and how their gRPC ports are numbered. Still hardcoded --
#: deriving them from the topology JSON is Phase 3 work. Named constants so a test can drive
#: `startup` over two fake switches without pretending there are ten.
DEFAULT_SWITCH_DPIDS = tuple(range(1, 11))
DEFAULT_GRPC_PORT_BASE = 50050


def build_p4_client(dpid, port_base=DEFAULT_GRPC_PORT_BASE):
    """
    Construct (but do not start) the client for one switch.

    [Co-developed with claude code -- Adam]
    Extracted from build_p4_clients for POST /p4/readopt/{dpid}: after a power-cycle the old
    client object is unusable (closed channel, poisoned queue, dead receiver thread), and
    this is the single place that knows how a dpid becomes an address and a pair of artifact
    paths. Unstarted on purpose -- readopt owns its own start/settle/push sequence, and
    build_p4_clients starts its batch itself.
    """
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return P4RuntimeClient(
        device_id=dpid,
        grpc_addr=f'localhost:{port_base + dpid}',
        p4info_path=os.path.join(base_dir, 'p4_src', 'build', 'ndtwin_switch.p4info.txt'),
        json_path=os.path.join(base_dir, 'p4_src', 'build', 'ndtwin_switch.json')
    )


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


# Wired at import time like inject_topology above: the readopt endpoint needs to build
# clients (paths and port numbering live here) and to hand new ones the sFlow callback,
# exactly as startup() does for the originals. [Co-developed with claude code -- Adam]
api_routes.inject_readopt(build_p4_client, sflow.handle_sample)


async def startup(clients_factory, sflow, kernel, topo,
                  *, settle_seconds=MASTERSHIP_SETTLE_S,
                  agent_ips_loader=load_switch_agent_ips):
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
    """
    print("[Proxy Agent] Starting up...")

    clients = clients_factory()
    for dpid, client in clients.items():
        topo.add_switch(dpid, client)

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
        print(f"[Proxy Agent] {len(broken)} of {len(clients)} switches have no pipeline "
              f"({sorted(broken)}); they will report as down and will not be enabled in the graph")

    # --- telemetry --------------------------------------------------------------------
    # [Co-developed with claude code -- Adam]
    #
    # Must come after the pipeline is pushed: the clone session lives in the pipeline's PRE, so
    # programming it earlier would be discarded. start(push_config=False) above is why this is
    # not done inside start().
    agent_ips = agent_ips_loader()
    telemetry = []
    for i, client in clients.items():
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
        # Loud, because the symptom otherwise looks like a dead data plane rather than a
        # missed notification.
        print(f"[Proxy Agent] Kernel acknowledged only {len(entered)}/{len(usable)} switches "
              f"(missing {not_entered}); the graph will stay partly disabled and paths/rates "
              f"will be empty for the rest")

    # Start LLDP dynamic topology discovery
    try:
        topo.start_lldp_discovery()
        print("[Proxy Agent] Started LLDP Discovery...")
    except Exception as e:
        print(f"[Proxy Agent] Failed to start LLDP discovery: {e}")

    # [Co-developed with claude code -- Adam]
    # The other half of LLDP: beacons that stop arriving are how a link failure is detected, and
    # until this existed only the discovery direction was wired. A link that went down stayed up
    # in the twin forever.
    try:
        # seed_expected=True enters every link the topology file declares, so one that was already
        # broken when this process started is reported rather than merely never discovered. The
        # kernel graph is correct either way -- an undiscovered edge is never enabled -- but
        # without seeding nothing says *which* link is missing, and "38/40 edges" is a puzzle
        # rather than a diagnosis.
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

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8081)

# Developed in collaboration with Gemini 3.1 Pro.
