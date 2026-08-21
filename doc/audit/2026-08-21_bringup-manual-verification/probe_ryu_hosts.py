"""What does Ryu actually say about hosts, and does the kernel drop it?

The kernel skips any hosts entry with no ipv4 (TopologyAndFlowMonitor.cpp:618), so
"256 edges down" has two possible causes that look identical from the kernel side:
  A. Ryu reports no hosts at all      -> it never learned them
  B. Ryu reports hosts with empty ipv4 -> the kernel is discarding them at line 618
This tells them apart. [Co-developed with claude code -- Adam]
"""
import json
import subprocess
import sys


def get(url):
    r = subprocess.run(["curl", "-sf", "--max-time", "5", url],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


hosts = get("http://localhost:8080/v1.0/topology/hosts")
links = get("http://localhost:8080/v1.0/topology/links")
sw = get("http://localhost:8080/v1.0/topology/switches")

print(f"ryu /topology/switches : {len(sw) if sw is not None else 'unreachable'}")
print(f"ryu /topology/links    : {len(links) if links is not None else 'unreachable'}")

if hosts is None:
    print("ryu /topology/hosts    : unreachable")
    sys.exit(1)

with_ip = [h for h in hosts if h.get("ipv4")]
print(f"ryu /topology/hosts    : {len(hosts)} entries, {len(with_ip)} with a non-empty ipv4")

if hosts:
    print("\nfirst entry verbatim:")
    print(json.dumps(hosts[0], indent=2))

print("\nverdict:")
if not hosts:
    print("  A. Ryu reports NO hosts -- it never learned them.")
    print("     The kernel cannot mark host edges up because nothing tells it to.")
elif not with_ip:
    print("  B. Ryu reports hosts but every ipv4 is empty.")
    print("     The kernel skips them at TopologyAndFlowMonitor.cpp:618, so the edges stay down.")
else:
    print(f"  C. Ryu reports {len(with_ip)} hosts WITH ipv4 -- the kernel had what it needed.")
    print("     If edges are still down, the defect is in the kernel's ingest, not in Ryu.")
