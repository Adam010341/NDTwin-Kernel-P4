# Proxy Agent Specification

This directory contains the Python-based Proxy Agent, which acts as the intermediary (Control Plane) between the NDTwin-Kernel and the BMv2 data plane switches.

## Architecture

The Proxy Agent is designed to translate high-level network intents (from NDTwin-Kernel's REST APIs) into low-level P4Runtime gRPC calls for BMv2 switches. It also maintains a proactive shortest-path routing algorithm to ensure baseline connectivity.

### Components
1. **`main.py`**: The entry point. Initializes the FastAPI web server, establishes P4Runtime connections to all switches concurrently (to minimize startup latency), and loads initial proactive routes.
2. **`api_routes.py`**: Defines the FastAPI endpoints (e.g., `/stats/flowentry/modify`, `/stats/flowentry/delete_strict`, `/stats/flow/{dpid}`). It receives commands from NDTwin-Kernel and delegates them to the `TopologyManager`. Includes validation to ensure gRPC failures result in HTTP 400 errors.
3. **`topology_manager.py`**: Maintains the abstract view of the network graph (using `networkx`). Handles routing logic (BFS) and translates REST JSON payloads (Match/Action fields) into specific IPv4 addresses and egress ports.
4. **`p4_client.py`**: The gRPC abstraction layer. Contains `P4RuntimeClient`, which interfaces directly with the `p4runtime_pb2_grpc.P4RuntimeStub`. Provides methods to modify, insert, and delete entries specifically in the `MyIngress.ipv4_lpm` table.

## Execution
The proxy agent must be run using its dedicated virtual environment to ensure proper `grpc` and `p4runtime` module resolution:
```bash
PYTHONPATH=. p4_proxy/venv/bin/python proxy_agent/main.py
```
It listens on port `8081` by default.
