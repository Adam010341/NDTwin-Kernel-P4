"""Race three find_host_by_ip variants under the real install_all_pair_paths.

[Co-developed with claude code -- Adam]

Question: the live 128-host walk got SLOWER after 957a646's index (2.166 s -> 3.634 s, n=1
each, different fabric-liveness conditions). Suspect: the cache token in the indexed helper
calls net.number_of_edges() on every lookup, and networkx's number_of_edges() -> size() ->
sum over every node's degree -- O(V) per call, same order as the scan it replaced.

Method: extract the real install_all_pair_paths from intelligent_router.py (AST, same as
tests/python/test_walk_instrumentation.py) and run it over one identical fabric per variant,
changing only find_host_by_ip:

  scan     the 91229f5 linear scan            (from `git show 91229f5:...`)
  shipped  957a646's index with its per-call number_of_edges() token (from `git show e44e956:...`)
  fixed    the helper as it stands in today's intelligent_router.py (O(1) token)
  hoisted  the same index built once per walk, no token at all -- the floor

The two git-pinned variants are extracted from their commits, not from anyone's memory of
them, so the race stays runnable after the working tree moves on.

add_flow is a list append, so absolute numbers are smaller than live; only the ratios and
slopes transfer (same caveat as WALK_SWEEP.md's intervention table).
"""
import ast
import statistics
import subprocess
import sys
from time import monotonic

import networkx as nx

REPO = "/home/adam/Desktop/NDTwin-Kernel"
ROUTER = f"{REPO}/intelligent_router.py"


def source_at(commit):
    return subprocess.run(["git", "-C", REPO, "show", f"{commit}:intelligent_router.py"],
                          capture_output=True, text=True, check=True).stdout


def extract(src, name):
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return ast.get_source_segment(src, node)
    raise SystemExit(f"{name} not found")


def compile_fn(src, name):
    ns = {"monotonic": monotonic, "is_all_dst_biased": False,
          "all_dst_ecmp_biased_factor": 1}
    exec(compile(ast.parse(src), ROUTER, "exec"), ns)
    return ns[name]


WALK = compile_fn(extract(open(ROUTER).read(), "install_all_pair_paths"),
                  "install_all_pair_paths")
FIXED_HELPER = compile_fn(extract(open(ROUTER).read(), "find_host_by_ip"), "find_host_by_ip")
SCAN_HELPER = compile_fn(extract(source_at("91229f5"), "find_host_by_ip"), "find_host_by_ip")
SHIPPED_HELPER = compile_fn(extract(source_at("e44e956"), "find_host_by_ip"),
                            "find_host_by_ip")


def hoisted_helper(self, net, target_ip):
    # 957a646's index with the per-call token check removed: built once, reused for the walk.
    index = getattr(self, "_hoisted_index", None)
    if index is None:
        index = {}
        for node in net.nodes:
            for ip in net.nodes[node].get("ip_list", ()) or ():
                index.setdefault(ip, node)
        self._hoisted_index = index
    return index.get(target_ip)


class FakeLogger:
    def _noop(self, *a, **k):
        pass
    info = warning = error = _noop


class FakeParser:
    def OFPMatch(self, **kw):
        return ("match",)

    def OFPActionOutput(self, port):
        return ("output", port)


class FakeDatapath:
    ofproto_parser = FakeParser()


def build_fabric(host_count, switch_count=10):
    """switch_count switches in a ring with chords (roughly the real 10-switch shape),
    hosts spread evenly. Same builder for every variant -- only the helper changes."""
    net = nx.DiGraph()
    for d in range(1, switch_count + 1):
        net.add_node(d)
    edges = set()
    for a in range(1, switch_count + 1):
        for b in (a % switch_count + 1, (a + 1) % switch_count + 1):
            if a != b and (a, b) not in edges:
                edges.add((a, b))
                edges.add((b, a))
    for i, (a, b) in enumerate(sorted(edges)):
        net.add_edge(a, b, port=100 + i)
    n = 0
    for d in range(1, switch_count + 1):
        for _ in range(host_count // switch_count + (1 if d <= host_count % switch_count else 0)):
            n += 1
            host = f"h{n:03d}"
            net.add_node(host, ip_list=[f"10.0.0.{n}"])
            net.add_edge(d, host, port=n)
            net.add_edge(host, d, port=0)
    return net


class Router:
    def __init__(self, net, helper):
        self.logger = FakeLogger()
        self.switches = {n: FakeDatapath() for n in net.nodes if isinstance(n, int)}
        self.all_destination_paths = []
        self._helper = helper

    def debug_print_graph(self, net):
        pass

    def is_switch(self, node):
        return isinstance(node, int) and node in self.switches

    def find_host_by_ip(self, net, ip):
        return self._helper(self, net, ip)

    def find_connected_switch(self, net, host):
        return next(n for n in net.neighbors(host) if isinstance(n, int))

    def get_host_port(self, net, host, switch):
        return net[switch][host]["port"]

    def hash_dst_ip(self, s):
        return hash(s)

    def add_flow(self, datapath, priority, match, actions):
        pass


Router.install_all_pair_paths = WALK

VARIANTS = {"scan": SCAN_HELPER, "shipped": SHIPPED_HELPER, "fixed": FIXED_HELPER,
            "hoisted": hoisted_helper}

if __name__ == "__main__":
    sizes = [int(s) for s in sys.argv[1:]] or [32, 64, 128]
    reps = 3
    print(f"{'hosts':>5}  {'variant':<8} {'walk median (s)':>16}  runs")
    for hosts in sizes:
        for name, helper in VARIANTS.items():
            times = []
            for _ in range(reps):
                net = build_fabric(hosts)
                r = Router(net, helper)
                t0 = monotonic()
                r.install_all_pair_paths(net)
                times.append(monotonic() - t0)
                assert r.all_destination_paths, "walk produced no paths -- harness broken"
            print(f"{hosts:>5}  {name:<8} {statistics.median(times):>16.4f}  "
                  + " ".join(f"{t:.4f}" for t in times))
