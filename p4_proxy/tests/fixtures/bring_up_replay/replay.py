"""Replay ONE main() over a recording net and write down what it asked the fabric to do.

[Co-developed with claude code -- Adam]

Why this is in the repo. TICKET-P1D's central claim is "with no package, both entry points
produce the argv, the ARP commands and the manifest they produced before the change" -- and a
claim like that is worth exactly as much as the ability to re-run it. So this takes a
mininet/ directory as an argument: point it at THIS tree and at a checkout of the pre-change
one (`git show 41d7950f:p4_proxy/mininet/<f>`), run both entry points against both, and diff
the four recordings. replay_ab.sh does precisely that and prints the verdict.

Usage:  replay.py <mininet dir> <topo|bridge> <repo root> <output json>
Env:    FAKE_OVERRIDE  the bmv2_binary_override file to use (so the recorded argv names a
                       binary this script made, not whatever the machine has installed)
        NDTWIN_P4_HOST_NUM  which model to size the fabric from

🔴 NOTHING HERE MAY TOUCH THE MACHINE. os.system, time.sleep, CLI, NTG's command_line, the
orphan reap and the port refusal are all replaced before either main() is entered, and
write_manifest is FORCED to a temp path -- see the note on `_write_manifest`, which is there
because the first version of this harness did write the real /tmp/ndtwin_p4_switches.json.
This is not a test (l1_unit_tests.sh globs tests/test_*.py, and this is under fixtures/); it
is evidence somebody can regenerate.
"""
import importlib.util, json, os, sys, tempfile, types

MININET_DIR, WHICH = sys.argv[1], sys.argv[2]
REPO = sys.argv[3]
sys.path.insert(0, MININET_DIR)

class Intf:
    def __init__(self, name, ip=""): self.name, self._ip = name, ip
    def IP(self): return self._ip

class SwitchBase:
    def __init__(self, name, **kw): self.name, self.intfs, self.commands = name, {}, []
    def cmd(self, line): self.commands.append(line); return "12345\n"
    def stop(self, deleteIntfs=True): pass

class TopoBase:
    def __init__(self, **o): self.switch_calls, self.host_calls, self.link_calls = [], [], []
    def addSwitch(self, name, **kw): self.switch_calls.append((name, dict(kw))); return name
    def addHost(self, name, **kw): self.host_calls.append((name, dict(kw))); return name
    def addLink(self, a, b, **kw): self.link_calls.append((a, b, dict(kw))); return (a, b)

REC = {"argv": {}, "host_setup": {}, "switch_order": [], "gets": [], "manifest": None}

class Host:
    def __init__(self, name, ip, mac): self.name, self._ip, self._mac, self.commands = name, ip.split("/")[0], mac, []
    def IP(self): return self._ip
    def MAC(self): return self._mac
    def intfList(self): return [Intf(self.name + "-eth0"), Intf("lo")]
    def cmd(self, line): self.commands.append(line); return ""

def make_net(topo_obj, switch_cls):
    class Net:
        def __init__(self):
            self.switches, self.hosts = {}, {}
            for name, kw in topo_obj.switch_calls:
                s = switch_cls(name, **{k: v for k, v in kw.items() if k != "cls"})
                self.switches[name] = s
            for name, kw in topo_obj.host_calls:
                self.hosts[name] = Host(name, kw["ip"], kw["mac"])
            for a, b, kw in topo_obj.link_calls:
                for node, port in ((a, kw.get("port1")), (b, kw.get("port2"))):
                    if node in self.switches:
                        self.switches[node].intfs[port] = Intf("%s-eth%s" % (node, port))
            self.nodes = dict(self.switches); self.nodes.update(self.hosts)
        def get(self, name):
            REC["gets"].append(name); return self.nodes[name]
        def start(self):
            for s in self.switches.values(): s.start([])
        def stop(self): pass
    return Net()

def install(json_manifest):
    mods = {
        "mininet": {},
        "mininet.net": {"Mininet": None},
        "mininet.topo": {"Topo": TopoBase},
        "mininet.node": {"Switch": SwitchBase, "Host": type("H", (), {})},
        "mininet.cli": {"CLI": lambda net: None},
        "mininet.log": {"setLogLevel": lambda *a, **k: None, "info": lambda *a, **k: None},
        "mininet.link": {"Intf": Intf},
    }
    for name, attrs in mods.items():
        m = sys.modules.get(name) or types.ModuleType(name)
        for k, v in attrs.items(): setattr(m, k, v)
        sys.modules[name] = m

TMP = tempfile.mkdtemp(prefix="replay.")
MANIFEST = os.path.join(TMP, "manifest.json")
install(MANIFEST)

def load(fn, as_name):
    spec = importlib.util.spec_from_file_location(as_name, os.path.join(MININET_DIR, fn))
    m = importlib.util.module_from_spec(spec); sys.modules[as_name] = m
    spec.loader.exec_module(m); return m

import app_package
topo = load("p4_testbed_topo.py", "p4_testbed_topo")

class RecSwitch(topo.BMv2Switch):
    def is_alive(self): return True
    def grpc_is_listening(self, timeout=0.3): return True

NET = {}
def Mininet(topo=None, controller=None, autoSetMacs=None):
    NET["net"] = make_net(topo, RecSwitch); return NET["net"]

sys.modules["mininet.net"].Mininet = Mininet
topo.Mininet = Mininet
topo.MANIFEST_PATH = MANIFEST
topo.BINARY_OVERRIDE_PATH = os.environ["FAKE_OVERRIDE"]
topo.CLI = lambda net: None
topo.os.system = lambda cmd: 0            # never `sudo mn -c`
topo.time.sleep = lambda s: None
topo.clear_switches_from_a_previous_run = lambda **kw: ([], [])
topo.abort_if_grpc_ports_are_held = lambda held, **kw: None
app_package.KNOB_PATH = os.path.join(TMP, "no_knob")
if hasattr(topo, "build_net"):
    topo.build_net = lambda package, model: Mininet(topo=topo.MultiSwitchTopo(package=package, model=model))
if hasattr(topo, "reset_for_bring_up"):
    topo.reset_for_bring_up = lambda ports, settle_s=0.5: None

_real_write_manifest = topo.write_manifest
def _write_manifest(switches, path=None):
    # 🔴 FORCED to the temp path. The OLD code calls write_manifest(switches) with no path and
    # the default was bound at def time to the real /tmp/ndtwin_p4_switches.json, so a replay
    # that did not do this WROTE THE MACHINE'S OWN MANIFEST. It did, once, at 11:40 on 09-18.
    _real_write_manifest(switches, path=MANIFEST)
    snapshot()
topo.write_manifest = _write_manifest

def snapshot():
    try:
        with open(MANIFEST) as fh: REC["manifest"] = json.load(fh)
    except (OSError, ValueError): REC["manifest"] = None

if WHICH == "topo":
    real_remove = os.remove
    def guarded_remove(p):
        if p == MANIFEST: snapshot()
        return real_remove(p)
    topo.os.remove = guarded_remove
    topo.main()
else:
    bridge = load("ntg_bmv2_topo.py", "ntg_bmv2_topo")
    bridge.NTG_DIR = TMP
    sys.modules["nornir"] = types.ModuleType("nornir")
    class Stop(BaseException): pass
    ntgmod = types.ModuleType("network_traffic_generator")
    def command_line(net, config_file_path=None):
        snapshot(); raise Stop()
    ntgmod.command_line = command_line
    ntgmod.logger_config = lambda *a, **k: None
    sys.modules["network_traffic_generator"] = ntgmod
    if hasattr(bridge, "testbed"):
        bridge.testbed = topo
    for attr in ("Mininet", "MANIFEST_PATH", "MultiSwitchTopo", "clear_switches_from_a_previous_run",
                 "abort_if_grpc_ports_are_held", "disable_host_offloads", "verify_switches",
                 "write_manifest", "reap_manifest_switches", "partial_fabric_verdict",
                 "resolve_bmv2_launcher", "_host_count_override"):
        if hasattr(bridge, attr) and hasattr(topo, attr):
            setattr(bridge, attr, getattr(topo, attr))
    if hasattr(bridge, "MANIFEST_PATH"):
        bridge.MANIFEST_PATH = MANIFEST
    bridge.os.system = lambda cmd: 0
    bridge.time.sleep = lambda s: None
    try:
        if "enter_cli" in bridge.main.__code__.co_varnames:
            bridge.main(enter_cli=lambda net: (snapshot(), (_ for _ in ()).throw(Stop()))[0])
        else:
            bridge.main()
    except Stop:
        pass

net = NET["net"]
REC["argv"] = {n: s.launch_argv for n, s in net.switches.items()}
REC["host_setup"] = {n: [c for c in h.commands if not c.startswith("ethtool ")] for n, h in net.hosts.items()}
REC["switch_order"] = list(net.switches)
open(sys.argv[4], "w").write(json.dumps(REC, indent=2, sort_keys=True) + "\n")
