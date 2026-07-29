# Proxy Agent Specification

This directory contains the Python-based Proxy Agent, which acts as the intermediary (Control Plane) between the NDTwin-Kernel and the BMv2 data plane switches.

## Architecture

The Proxy Agent is designed to translate high-level network intents (from NDTwin-Kernel's REST APIs) into low-level P4Runtime gRPC calls for BMv2 switches. It also maintains a proactive shortest-path routing algorithm to ensure baseline connectivity.

### Components
1. **`main.py`**: The entry point. Initializes the FastAPI web server, establishes P4Runtime connections to all switches concurrently (to minimize startup latency), and loads initial proactive routes.
2. **`api_routes.py`**: Defines the FastAPI endpoints (e.g., `/stats/flowentry/modify`, `/stats/flowentry/delete_strict`, `/stats/flow/{dpid}`). It receives commands from NDTwin-Kernel and delegates them to the `TopologyManager`. Includes validation to ensure gRPC failures result in HTTP 400 errors.
3. **`topology_manager.py`**: Maintains the abstract view of the network graph (using `networkx`). Handles routing logic (BFS) and translates REST JSON payloads (Match/Action fields) into specific IPv4 addresses and egress ports.
4. **`p4_client.py`**: The gRPC abstraction layer. Contains `P4RuntimeClient`, which interfaces directly with the `p4runtime_pb2_grpc.P4RuntimeStub`. Provides methods to modify, insert, and delete entries specifically in the `MyIngress.ipv4_lpm` table.

   It also owns the two things telemetry depends on: `write_clone_session()`, which programs the
   PRE clone session the pipeline samples into, and the `handle_packet_in` split that routes a
   CPU packet to either the telemetry path or LLDP discovery based on `packet_in.reason`. That
   split matters for load as much as correctness -- sampling is 1-in-256 of *all* traffic, so
   letting samples reach the LLDP parser would bury discovery in frames it cannot use.

   **Ordering contract for `start(push_config)`.** The clone session lives in the pipeline's
   PRE, so bmv2 rejects it with `FAILED_PRECONDITION: No forwarding pipeline config set for
   this device` if no pipeline is loaded. `start()` therefore programs it **only when it
   pushed the pipeline itself**. With `push_config=False` the caller owns the ordering and
   must call `write_clone_session()` after its own push -- which `main.py` does, in its
   telemetry setup, because it batches the pipeline pushes across all ten switches. Getting
   this wrong is not subtle in effect but is invisible in the request: all ten sessions fail
   and no sample is ever produced. `tests/test_clone_session.py::StartOrderingTest` asserts
   the order rather than the counts, because the pre-existing tests checked only what the
   `WriteRequest` contained, never when it was sent.

5. **`sflow_emitter.py`**: Synthesises sFlow v5 flow samples and sends them to the kernel's
   collector on UDP 6343, so `FlowLinkUsageCollector` and `Classifier` work unmodified and
   cannot tell OVS from P4. bmv2 emits no sFlow of its own.

   The kernel's decoder is a hand-rolled fixed-word-offset parser, not a general sFlow library,
   so "valid sFlow" is not sufficient -- the datagram must have the same *shape* OVS produces,
   in particular two flow records (`extended_switch` then `raw header`). The module docstring
   records the measured word layout. `tests/test_sflow_emitter.py` compares byte for byte
   against captured OVS datagrams, and `tests/test_SFlowEmitterRoundtrip.cpp` feeds this
   emitter's actual output through the actual C++ parser.

   Agent addresses come from the same topology JSON the kernel loads (`load_switch_agent_ips`),
   because the kernel attributes a sample to an edge by `AgentKey{agentIP, port}`: an address it
   does not recognise yields telemetry attributed to nothing, with no error.

## Execution
The proxy agent must be run using its dedicated virtual environment to ensure proper `grpc` and `p4runtime` module resolution:
```bash
PYTHONPATH=. p4_proxy/venv/bin/python proxy_agent/main.py
```
It listens on port `8081` by default.
