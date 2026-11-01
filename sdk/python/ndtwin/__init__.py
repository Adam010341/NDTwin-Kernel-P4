"""ndtwin: a Python client for the NDTwin kernel's HTTP API (port 8000).

[Co-developed with claude code -- Adam]

    import ndtwin
    k = ndtwin.Kernel("http://localhost:8000")
    with k.lock("routing_lock", ttl=60):
        topo = k.topology()
        table = k.p4.read_table(1, "MyIngress.ipv4_lpm")
        k.p4.modify_all([e.with_params(port=2) for e in table.entries[:1]])

Standard library only. See doc/2026-01-02_ndt_api.md for the routes it calls.
"""
from .errors import (Busy, KernelUnreachable, LockBusy, NDTwinError, NotFound, OutcomeUnknown,
                     PowerError, Refused, SwitchRefused, Unsettled, WriteError, WriteNotVerified)
from .kernel import Kernel, Lease, LinkUsage, PowerState
from .p4 import P4, Counter, DirectCounter, Register, Settled, Table, TableEntry, WriteResult
from .topology import Host, Link, Switch, Topology

__version__ = "1.0.0"
