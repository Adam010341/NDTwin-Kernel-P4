"""Guards on the topology model reader: each must fire, and the baseline must still pass.

Added after the second review round (2026-08-21). Every case here is a defect that was found
live -- a duplicate dpid silently deleting links, an NDTWIN_P4_TOPO_FILE override skipping the
host-count check it documents, broken JSON escaping as a bare JSONDecodeError. A guard nobody
has watched fail is not a guard, so this asserts the raise, not just the happy path.

[Co-developed with claude code -- Adam]
"""
import copy
import json
import os
import sys
import tempfile

REPO = "/home/adam/Desktop/NDTwin-Kernel"
sys.path.insert(0, os.path.join(REPO, "p4_proxy", "mininet"))
import topo_from_json as T  # noqa: E402

MODEL = os.path.join(REPO, "setting", "StaticNetworkTopologyP4_10Switches_4Hosts.json")
base = T.load(MODEL)
bad = 0


def expect_raise(label, fn):
    global bad
    try:
        fn()
    except T.TopologyModelError as e:
        print(f"  ok    {label}\n          -> {str(e)[:110]}")
        return
    except Exception as e:
        print(f"  FAIL  {label}: raised {e.__class__.__name__}, wanted TopologyModelError")
        bad += 1
        return
    print(f"  FAIL  {label}: no error raised")
    bad += 1


def expect_ok(label, fn):
    global bad
    try:
        fn()
        print(f"  ok    {label}")
    except Exception as e:
        print(f"  FAIL  {label}: {e.__class__.__name__}: {e}")
        bad += 1


print("baseline must still pass")
expect_ok("unmodified 4-host model parses", lambda: (T.switches(base), T.switch_links(base),
                                                     T.hosts(base), T.host_links(base)))

print("G3 -- two switches sharing a dpid")
dup = copy.deepcopy(base)
sw = [n for n in dup["nodes"] if n.get("vertex_type") == 0]
sw[1]["dpid"] = sw[0]["dpid"]
expect_raise("duplicate dpid is refused", lambda: T.switches(dup))

print("regression: a host attached twice stays benign (reviewer confirmed it is not a defect)")
dbl = copy.deepcopy(base)
host_edge = next(e for e in dbl["edges"] if e.get("src_dpid") and not e.get("dst_dpid"))
dbl["edges"].append(copy.deepcopy(host_edge))
expect_ok("duplicate host edge still ignored", lambda: T.host_links(dbl))

print("G1 / G5 -- the NDTWIN_P4_TOPO_FILE path")
sys.path.insert(0, os.path.join(REPO, "p4_proxy", "mininet"))
os.environ["NDTWIN_P4_HOST_NUM"] = "4"
import p4_testbed_topo as P  # noqa: E402

def with_override(path, host_num=4):
    os.environ["NDTWIN_P4_TOPO_FILE"] = path
    try:
        return P._topology_model_path(host_num)
    finally:
        os.environ.pop("NDTWIN_P4_TOPO_FILE", None)

expect_ok("override matching the host count is accepted",
          lambda: with_override(MODEL, 4))
expect_raise("override whose host count disagrees is refused",
             lambda: with_override(MODEL, 128))
expect_raise("override pointing at a missing file is refused",
             lambda: with_override("/nonexistent/model.json", 4))

broken = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
broken.write("{ this is not json")
broken.close()
expect_raise("override pointing at broken JSON is refused (not a bare JSONDecodeError)",
             lambda: with_override(broken.name, 4))
empty = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
empty.close()
expect_raise("override pointing at an empty file is refused",
             lambda: with_override(empty.name, 4))
os.unlink(broken.name); os.unlink(empty.name)

print()
print("PASS" if not bad else f"FAIL -- {bad}")
sys.exit(1 if bad else 0)
