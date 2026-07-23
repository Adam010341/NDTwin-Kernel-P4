# Mininet Topology Scripts Specification

This directory contains the Python scripts used to construct the emulated network topology for the P4 BMv2 environment using Mininet.

## Key Files
- `p4_testbed_topo.py`: The primary script to launch the Mininet environment. It instantiates the custom `BMv2Switch` class (wrapping `simple_switch_grpc`) and defines the network topology (e.g., a 10-switch, 4-host configuration).

## Responsibilities
1. **Network Emulation**: Uses Mininet API to create virtual switches, hosts, and links.
2. **BMv2 Instantiation**: Replaces standard OVS switches with BMv2 (`simple_switch_grpc`) processes.
3. **Port Binding**: Assigns specific gRPC and Thrift ports to each switch for control plane access (e.g., gRPC ports 50051-50060).
4. **Static ARP Configuration**: Pre-populates the ARP tables of all simulated hosts to bypass the need for dynamic ARP resolution and packet-in handling by the control plane.

## Usage
Must be run with `sudo` privileges to manipulate Linux network namespaces:
```bash
sudo python3 p4_testbed_topo.py
```
