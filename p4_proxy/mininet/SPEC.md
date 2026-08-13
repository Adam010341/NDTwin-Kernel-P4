# Mininet Topology Scripts Specification

This directory contains the Python scripts used to construct the emulated network topology for the P4 BMv2 environment using Mininet.

## Key Files
- `p4_testbed_topo.py`: The primary script to launch the Mininet environment. It instantiates the custom `BMv2Switch` class (wrapping `simple_switch_grpc`) and defines the network topology (e.g., a 10-switch, 4-host configuration).

## Responsibilities
1. **Network Emulation**: Uses Mininet API to create virtual switches, hosts, and links.
2. **BMv2 Instantiation**: Replaces standard OVS switches with BMv2 (`simple_switch_grpc`) processes.
3. **Port Binding**: Assigns specific gRPC and Thrift ports to each switch for control plane access (e.g., gRPC ports 50051-50060).
4. **Static ARP Configuration**: Pre-populates the ARP tables of all simulated hosts to bypass the need for dynamic ARP resolution and packet-in handling by the control plane.
5. **Startup verification**: confirms each switch is actually usable before reporting success.
6. **Switch manifest**: records each switch's PID and ports so one switch can be managed alone.

## Startup verification and the manifest

[Co-developed with claude code -- Adam]

`start()` captures the launched PID (`echo $!`), and `verify_switches()` polls until every
switch both exists as a process and accepts TCP on its gRPC port. Both signals are needed:
bmv2 stays up briefly before its gRPC server binds, and it reports a bind failure by exiting.
Polling rather than sleeping a fixed amount avoids false failures on a slow machine.

This exists because the script previously printed
`10 BMv2 Switches listening on gRPC ports 50051 ~ 50060` **unconditionally**. When s10 died
at startup it said so anyway, and the real cause sat in a file nothing read:

```
/tmp/s10_bmv2.log:  No address added out of total 1 resolved for '0.0.0.0:50060'
                      -> Address already in use {syscall:"bind", errno:98}
```

`failure_reason()` now reads that log and names the leftover-process case specifically, and
the banner reports the true count and tells the operator to fix and restart.

`stop()` kills the recorded PID. It used `kill %simple_switch_grpc` — a shell **job spec**,
which only works inside the shell that launched it, so closing the Mininet terminal left
every switch running. Those orphans are what hold the gRPC port and make the next run's
matching switch fail to bind. Startup therefore also clears stale `simple_switch_grpc`
processes, which `mn -c` does not touch.

### `/tmp/ndtwin_p4_switches.json`

Written on startup, removed on exit. Maps switch name to `pid`, `device_id`, `grpc_port`,
`thrift_port`, `log_file` and the launch `argv`.

`P4PowerStrategy` needs this (Phase 7 of `doc/2026-07-27_p4_bmv2_support_plan.md`): Mininet switches
share the root PID namespace, so powering one switch off by pattern-matching the process
name kills all ten — which is what the current implementation does. Only verified-live
switches are listed; an entry for a dead switch would be worse than no entry, because a
caller would trust it.

## Usage
Must be run with `sudo` privileges to manipulate Linux network namespaces:
```bash
sudo python3 p4_testbed_topo.py
```

Expect `All 10 BMv2 switches verified listening on gRPC 50051 ~ 50060`. A `WARNING:` line
naming the failed switches means the topology is not usable — fix the cause and restart
rather than continuing, since the proxy expects all ten.
