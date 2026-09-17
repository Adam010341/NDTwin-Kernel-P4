"""What this P4 fabric is running: NDTwin's own artefacts, or somebody's app package.

[Co-developed with claude code -- Adam]

Why this exists. Every knob a P4 application needs to bring a fabric up -- which topology,
which pipeline, which election id, which CPU port, what to run on each host -- is currently a
literal written down in `proxy_agent/main.py` and `mininet/p4_testbed_topo.py`, several of them
in more than one file. That is fine for exactly one application (`ndtwin_switch.p4`) and is the
reason a second one cannot be run at all. This module is the one place those values come from.

🔴 THE BASELINE IS THE CONTRACT. `baseline()` returns, as data, **the literal value each
replaced site has today** -- election id `(0, 1)`, CPU port `255`, the two `p4_src/build/`
artefact paths, prefix length 24, `grpc_base` 30050, no topology override, no host commands.
With no knob file on disk every caller gets that object, so "the fabric behaves exactly as it
did" is a property a test can assert value by value rather than a claim somebody makes in a
commit message. tests/test_app_package.py asserts every one of them; if a literal here drifts
from the code it stands for, that suite is where it shows.

What this module does NOT do, on purpose:

  * It does not apply anything. It parses, validates and refuses; the proxy and the topology
    script decide what to do with the result. That is what lets one reader serve a FastAPI
    process, a Mininet script running as root, and a unit test that has neither.
  * It does not write the knob. `ndt` does (ticket C). A reader that also writes is a reader
    whose tests cannot tell a stale file from a fresh one.
  * It does not validate table entries against a p4info. `tools/p4_exercise/preflight.py` does,
    before the fabric is built. All this file counts is HOW MANY entries a package declares, so
    that `GET /p4/switch_state` can say "N recorded, none applied" instead of saying nothing.
"""
from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field
from typing import Optional, Tuple

_HERE = os.path.dirname(os.path.abspath(__file__))
# [Co-developed with claude code -- Adam]
# Same reason proxy_agent/main.py inserts this directory before importing grpc_ports: these
# modules are loaded both as a package-relative import (the Mininet script, which lives here)
# and by the proxy, which is rooted a directory up. Importing rather than re-typing 30050 is
# the F-15 lesson -- the fabric picks the ports and everything else dials them, and a second
# copy of the number is how "the whole fabric is down" gets shipped as a one-line edit.
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import grpc_ports  # noqa: E402
import topo_from_json  # noqa: E402

#: The knob. One line: the absolute path of a package directory. Same shape as the
#: `host_count_override` / `bmv2_binary_override` files beside it, and a file rather than an
#: environment variable for the same reason those are: the topology script is launched through
#: `tmux` under a fixed root environment where no operator-set variable arrives
#: (p4_testbed_topo.py's HOST_COUNT_OVERRIDE_PATH carries the long form of this argument).
KNOB_PATH = os.path.join(_HERE, "app_package_override")

#: The only format this reader understands. A package written for a later format is refused
#: rather than read with today's field meanings.
FORMAT = 1

MODE_NDTWIN = "ndtwin"
MODE_EXTERNAL = "external"
MODES = (MODE_NDTWIN, MODE_EXTERNAL)

# --- the literals. [Co-developed with claude code -- Adam] -------------------------------
#
# Each of these is the value that stands at the site this module replaces, and the comment
# names that site. They are constants rather than inline defaults so that the baseline test
# can import and compare them, and so a future edit to one of them is a one-line diff that
# the mutation gate immediately reddens.

#: p4_client.py's arbitration bid and the `election_id.low = 1` on every unary request.
BASELINE_ELECTION_ID: Tuple[int, int] = (0, 1)

#: p4_testbed_topo.py's `--cpu-port 255` and p4_client.CPU_PORT.
BASELINE_CPU_PORT = 255

#: p4_testbed_topo.py's `self.addHost(name, ip=f"{ip}/24", ...)`.
BASELINE_PREFIX_LEN = 24

#: main.build_p4_client's two artefact paths, relative to the p4_proxy root, and
#: MultiSwitchTopo's `json_path`. NDTwin's own compiled pipeline.
BASELINE_PIPELINE: Tuple[str, str] = (
    "p4_src/build/ndtwin_switch.p4info.txt",
    "p4_src/build/ndtwin_switch.json",
)

#: grpc_ports.GRPC_PORT_BASE, imported rather than re-typed. See the sys.path note above.
BASELINE_GRPC_BASE = grpc_ports.GRPC_PORT_BASE

#: How a switch's gRPC address and P4Runtime device id are derived from its dpid. The only
#: scheme phase 1 accepts; tutorials controllers that hardcode `127.0.0.1:5005N` / `dev N-1`
#: are rewritten on the CONTROLLER side by tools/p4_exercise/run_external_controller.py, so
#: the fabric's own numbering never has to move.
BASELINE_DEVICE_ID = "dpid"

#: What a package gets when it names no election id. Deliberately NOT (0, 1): a package is by
#: definition a fabric somebody else's controller may also attach to, and an impostor bidding
#: the baseline (0, 1) against a proxy holding (0, 65535) is refused with PERMISSION_DENIED
#: instead of being accepted and wiping every table -- the 2026-08-13 measurement written up
#: in p4_client.py's mastership note. The baseline fabric keeps (0, 1) because changing it
#: would change behaviour nobody asked to change.
PACKAGE_DEFAULT_ELECTION_ID: Tuple[int, int] = (0, 65535)


class AppPackageError(ValueError):
    """
    A package cannot be used as declared.

    ValueError so a caller that already funnels malformed-input failures (the topology script's
    pre-flight does) keeps catching it, and a distinct class so the proxy can say which of the
    two readers refused. Every message names the field it is about: "the package is invalid" is
    not something an operator can act on.
    """


@dataclass(frozen=True)
class HostSpec:
    """One host, as the package declares it."""

    name: str
    ip: str
    prefix_len: int
    mac: Optional[str]
    #: Run on this host once Mininet is up, in order. Replaces the fabric's all-pairs static
    #: ARP under a package; empty means "this package wants nothing run here", which is not
    #: the same statement as baseline's "there is no package".
    commands: Tuple[str, ...] = ()


@dataclass(frozen=True)
class SwitchSpec:
    """One switch, as the package declares it."""

    dpid: int
    name: str
    #: Per-switch pipeline override. **Always None in phase 1** -- `load` refuses anything
    #: else with "G4 not implemented", because loading a foreign pipeline is a separate piece
    #: of work and a package that silently got NDTwin's pipeline instead of its own would look
    #: like a data-plane bug rather than like a feature that is not built yet.
    pipeline: Optional[Tuple[str, str]]
    #: Absolute path of this switch's runtime entries file, or None.
    entries: Optional[str]
    #: How many table entries that file declares. Phase 1 applies **none** of them; this count
    #: is what `GET /p4/switch_state` discloses so that "no rules were installed" arrives as a
    #: number rather than as silence.
    entries_recorded: int = 0


@dataclass(frozen=True)
class Package:
    """Everything the fabric reads out of a package -- or, for `baseline()`, out of nowhere."""

    #: The package directory, or None when this is the baseline. The one field that answers
    #: "is anything non-default in play", and the one reported to operators.
    dir: Optional[str] = None
    name: str = "baseline"
    #: Absolute path of the topology model to build from, or None for "pick one by host count",
    #: which is what the fabric does today.
    topology: Optional[str] = None
    mode: str = MODE_NDTWIN
    election_id: Tuple[int, int] = BASELINE_ELECTION_ID
    grpc_base: int = BASELINE_GRPC_BASE
    device_id: str = BASELINE_DEVICE_ID
    cpu_port: int = BASELINE_CPU_PORT
    prefix_len: int = BASELINE_PREFIX_LEN
    #: The fabric-wide pipeline, relative to the p4_proxy root. Phase 1 is always NDTwin's own.
    pipeline: Tuple[str, str] = BASELINE_PIPELINE
    hosts: Tuple[HostSpec, ...] = ()
    switches: Tuple[SwitchSpec, ...] = ()
    #: Recorded verbatim from the package, applied by nobody in phase 1 (G2-C is phase 3).
    #: Kept so that `ndt status` and the converter round-trip can show what was declared.
    links: Tuple[dict, ...] = field(default_factory=tuple)

    # --- what callers actually ask ------------------------------------------------------

    @property
    def is_baseline(self) -> bool:
        return self.dir is None

    @property
    def arbitration(self) -> bool:
        """
        Whether this proxy should open a P4Runtime arbitration stream and claim mastership.

        False under `external`: the exercise brings its own controller, and two controllers
        bidding for one switch is not a degraded mode, it is the 2026-08-13 table wipe.
        """
        return self.mode != MODE_EXTERNAL

    @property
    def read_only(self) -> bool:
        """The other half of the same fact, named for the callers that ask it that way."""
        return self.mode == MODE_EXTERNAL

    def pipeline_for(self, dpid, base_dir):
        """(p4info_path, json_path) for one switch, absolute, under `base_dir` (p4_proxy root).

        The per-switch override is consulted first and is always None in phase 1 (see
        SwitchSpec.pipeline), so this returns the fabric-wide pair -- NDTwin's own artefacts --
        for every switch of every package. When G4 lands, this is the only function that changes.
        """
        for spec in self.switches:
            if spec.dpid == int(dpid) and spec.pipeline:
                p4info, json_path = spec.pipeline
                return (_under(base_dir, p4info), _under(base_dir, json_path))
        p4info, json_path = self.pipeline
        return (_under(base_dir, p4info), _under(base_dir, json_path))

    def host_commands(self):
        """
        {host name: [command, ...]} for a package, or **None** for the baseline.

        None rather than {} is load-bearing. The topology script reads this to decide whether
        to run its own all-pairs static ARP, and "this package asked for no commands" must not
        be able to look like "there is no package": the first means run nothing, the second
        means run the 128-host ARP fan-out the fabric has always run.
        """
        if self.is_baseline:
            return None
        return {h.name: list(h.commands) for h in self.hosts}

    def host_prefix_len(self, name):
        """This host's prefix length, falling back to the fabric-wide one."""
        for h in self.hosts:
            if h.name == name:
                return h.prefix_len
        return self.prefix_len

    def entries_recorded(self):
        """{dpid as string: count} -- what `GET /p4/switch_state` discloses per switch."""
        return {str(s.dpid): s.entries_recorded for s in self.switches}

    def switch_names(self):
        """{dpid: Mininet name}, for a fabric that cannot assume `s<dpid>`."""
        return {s.dpid: s.name for s in self.switches}


def baseline() -> Package:
    """
    The fabric as it stands today, expressed as a package.

    🔴 Every default on `Package` is the literal from the site it replaces, so this returns the
    current behaviour by construction. It is a function rather than a module-level singleton so
    that a caller cannot mutate the one copy everybody shares (the dataclass is frozen, but its
    tuples are not the only way to reach it).
    """
    return Package()


# --- the knob -------------------------------------------------------------------------------


def read_knob(path=None) -> Optional[str]:
    """
    The package directory this machine is configured for, or None for the baseline.

    First non-blank, non-`#` line wins -- the same directive-file shape as `host_count_override`
    and `bmv2_binary_override` next to it, so an operator who has seen one has seen all three.

    Two deliberate differences from those two, both in the refusing direction:

      * the line must be an ABSOLUTE path, and it must name a directory that exists. A relative
        path would resolve against whatever cwd the reader happened to have -- the proxy is
        started from `p4_proxy/` by stack.sh and the topology script from anywhere -- so the
        same file would mean two different packages;
      * a file that exists but carries no directive line is REFUSED, where `host_count_override`
        would fall back to its default. An empty knob is the state `ndt down` is supposed to
        leave behind by deleting the file, so an empty one means a writer stopped halfway, and
        answering "baseline" to that is the silent degradation this whole module exists to avoid.
    """
    path = path or KNOB_PATH
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if not os.path.isabs(line):
                raise AppPackageError(
                    f"{path}: the app package knob must be an absolute path, got {line!r}; a "
                    f"relative one would resolve against the reader's working directory and the "
                    f"proxy and the topology script do not share one")
            if not os.path.isdir(line):
                raise AppPackageError(
                    f"{path}: app package directory {line!r} does not exist")
            return line
    raise AppPackageError(
        f"{path}: exists but names no package directory. Delete the file to run the baseline "
        f"fabric -- an empty knob is a half-finished write, not a default")


# --- loading ---------------------------------------------------------------------------------


def _under(base, path):
    """`path` resolved against `base`, unless it is already absolute."""
    return path if os.path.isabs(path) else os.path.join(base, path)


def _require(obj, key, kind, where):
    if key not in obj:
        raise AppPackageError(f"{where}: required field {key!r} is missing")
    value = obj[key]
    if not isinstance(value, kind):
        raise AppPackageError(
            f"{where}: {key!r} must be {getattr(kind, '__name__', kind)}, got "
            f"{type(value).__name__}")
    return value


def _existing_file(package_dir, value, where):
    path = _under(package_dir, str(value))
    if not os.path.isfile(path):
        raise AppPackageError(f"{where}: {value!r} does not exist (looked at {path})")
    return path


def _election_id(value, where, default):
    if value is None:
        return default
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        raise AppPackageError(f"{where}: election_id must be [high, low], got {value!r}")
    try:
        high, low = int(value[0]), int(value[1])
    except (TypeError, ValueError):
        raise AppPackageError(f"{where}: election_id entries must be integers, got {value!r}")
    if high < 0 or low < 0 or (high == 0 and low == 0):
        # (0, 0) is not a bid, it is the absence of one: P4Runtime treats an unset election id
        # as "no mastership wanted", so a client carrying it would be refused every write with
        # a status that reads like a permissions problem.
        raise AppPackageError(
            f"{where}: election_id must be a non-zero, non-negative pair, got {value!r}")
    return (high, low)


def _hosts(raw, where):
    if not isinstance(raw, dict):
        raise AppPackageError(f"{where}: 'hosts' must be an object, got {type(raw).__name__}")
    out = []
    for name in sorted(raw, key=_host_sort_key):
        spec = raw[name]
        hw = f"{where}: hosts.{name}"
        if not isinstance(spec, dict):
            raise AppPackageError(f"{hw} must be an object, got {type(spec).__name__}")
        ip = str(_require(spec, "ip", str, hw))
        # 🔴 The naming rule, refused rather than papered over. topo_from_json.hosts() derives a
        # host's name from the LAST OCTET of its address (`h{idx}`, topo_from_json.py:86) and
        # every downstream lookup -- the proxy's host table, the topology script's `net.get`,
        # the static ARP fan-out -- keys on that name. A package whose h3 is 10.0.1.7 builds a
        # fabric in which half the code means one host by "h3" and half means another, and
        # nothing anywhere reports it. pod-topo satisfies this (10.0.1.1 -> h1 .. 10.0.4.4 -> h4).
        if not (name.startswith("h") and name[1:].isdigit()):
            raise AppPackageError(
                f"{hw}: host names must be h<N>, got {name!r}; topo_from_json.hosts() derives "
                f"the name from the address and every lookup downstream keys on it")
        last_octet = str(ip).rsplit(".", 1)[-1]
        if not last_octet.isdigit() or int(last_octet) != int(name[1:]):
            raise AppPackageError(
                f"{hw}: name {name!r} does not match the last octet of ip {ip!r}; "
                f"topo_from_json.hosts() would call this host h{last_octet}, so the two halves "
                f"of the fabric would disagree about which host is which")
        prefix_len = spec.get("prefix_len", BASELINE_PREFIX_LEN)
        if not isinstance(prefix_len, int) or isinstance(prefix_len, bool) \
                or not 1 <= prefix_len <= 32:
            raise AppPackageError(f"{hw}: prefix_len must be an integer 1..32, got {prefix_len!r}")
        mac = spec.get("mac")
        if mac is not None and not isinstance(mac, str):
            raise AppPackageError(f"{hw}: mac must be a string like '08:00:00:00:01:11'")
        commands = spec.get("commands", [])
        if not isinstance(commands, list) or any(not isinstance(c, str) for c in commands):
            raise AppPackageError(f"{hw}: commands must be a list of strings")
        out.append(HostSpec(name=name, ip=ip, prefix_len=prefix_len, mac=mac,
                            commands=tuple(commands)))
    return tuple(out)


def _host_sort_key(name):
    return (int(name[1:]), name) if name[1:].isdigit() else (1 << 30, name)


def _switches(raw, package_dir, where):
    if not isinstance(raw, dict):
        raise AppPackageError(f"{where}: 'switches' must be an object, got {type(raw).__name__}")
    out = []
    for key in sorted(raw, key=lambda k: (int(k) if str(k).isdigit() else 1 << 30, str(k))):
        spec = raw[key]
        sw = f"{where}: switches.{key}"
        if not (str(key).isdigit() and int(key) > 0):
            raise AppPackageError(
                f"{sw}: switch keys are dpids and must be positive integers, got {key!r}")
        if not isinstance(spec, dict):
            raise AppPackageError(f"{sw} must be an object, got {type(spec).__name__}")
        dpid = int(key)
        name = spec.get("name", f"s{dpid}")
        if not isinstance(name, str) or not name:
            raise AppPackageError(f"{sw}: name must be a non-empty string")
        if spec.get("pipeline") is not None:
            raise AppPackageError(
                f"{sw}: pipeline must be null in format {FORMAT} -- per-switch pipeline loading "
                f"is G4 and is NOT implemented. This package would have run on NDTwin's own "
                f"pipeline while looking as though it ran on its own")
        entries_path, entries_recorded = None, 0
        if spec.get("entries") is not None:
            entries_path = _existing_file(package_dir, spec["entries"], f"{sw}: entries")
            entries_recorded = _count_entries(entries_path, f"{sw}: entries")
        out.append(SwitchSpec(dpid=dpid, name=name, pipeline=None,
                              entries=entries_path, entries_recorded=entries_recorded))
    seen = {}
    for spec in out:
        if spec.name in seen:
            raise AppPackageError(
                f"{where}: switches {seen[spec.name]} and {spec.dpid} are both named "
                f"{spec.name!r}; the fabric addresses switches by name")
        seen[spec.name] = spec.dpid
    return tuple(out)


def _count_entries(path, where):
    """
    How many table entries this runtime file declares. Not what they are -- that is preflight.

    Counted rather than trusted from a field, and a file that cannot be parsed is refused here:
    reporting "0 entries recorded" for a file we could not read is the same sentence a package
    with genuinely no entries produces, and those two must not be confusable.
    """
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise AppPackageError(f"{where}: {path} is not readable JSON: {exc}") from exc
    entries = doc.get("table_entries")
    if entries is None:
        return 0
    if not isinstance(entries, list):
        raise AppPackageError(f"{where}: {path} has a 'table_entries' that is not a list")
    return len(entries)


def load(package_dir) -> Package:
    """
    Read and validate one package directory. Raises AppPackageError naming the bad field.

    Everything refused here is refused BEFORE a switch is started, which is the whole point:
    the failure mode this replaces is a fabric that comes up, forwards nothing, and reports
    zero rather than an error (GAP-ANALYSIS section 5).
    """
    if not isinstance(package_dir, str) or not package_dir:
        raise AppPackageError(f"package_dir must be a path, got {package_dir!r}")
    package_dir = os.path.abspath(package_dir)
    if not os.path.isdir(package_dir):
        raise AppPackageError(f"app package directory {package_dir!r} does not exist")
    manifest_path = os.path.join(package_dir, "package.json")
    where = os.path.join(os.path.basename(package_dir), "package.json")
    try:
        with open(manifest_path) as fh:
            doc = json.load(fh)
    except OSError as exc:
        raise AppPackageError(f"{manifest_path} cannot be read: {exc}") from exc
    except ValueError as exc:
        raise AppPackageError(f"{manifest_path} is not valid JSON: {exc}") from exc
    if not isinstance(doc, dict):
        raise AppPackageError(f"{where}: the manifest must be an object")

    fmt = doc.get("format")
    if fmt != FORMAT:
        raise AppPackageError(
            f"{where}: 'format' must be {FORMAT}, got {fmt!r}. A package written for another "
            f"format would be read with this one's field meanings")

    name = doc.get("name") or os.path.basename(package_dir)
    if not isinstance(name, str):
        raise AppPackageError(f"{where}: 'name' must be a string")

    topology = _existing_file(package_dir, _require(doc, "topology", str, where),
                              f"{where}: topology")
    # Parsed here, not merely existence-checked: an unreadable model is a fabric that cannot be
    # built, and finding that out at `addLink` time means Mininet has already been torn down.
    try:
        topo_from_json.switches(topo_from_json.load(topology))
    except (OSError, ValueError, KeyError) as exc:
        raise AppPackageError(
            f"{where}: topology {topology} is not a usable NDTwin topology model: "
            f"{type(exc).__name__}: {exc}") from exc

    hosts = _hosts(doc.get("hosts", {}), where)
    switches = _switches(doc.get("switches", {}), package_dir, where)

    cp = doc.get("control_plane") or {}
    if not isinstance(cp, dict):
        raise AppPackageError(f"{where}: 'control_plane' must be an object")
    mode = cp.get("mode", MODE_NDTWIN)
    if mode not in MODES:
        raise AppPackageError(
            f"{where}: control_plane.mode must be one of {list(MODES)}, got {mode!r}")
    election_id = _election_id(cp.get("election_id"), f"{where}: control_plane",
                              PACKAGE_DEFAULT_ELECTION_ID)
    grpc_base = cp.get("grpc_base", BASELINE_GRPC_BASE)
    if grpc_base != BASELINE_GRPC_BASE:
        raise AppPackageError(
            f"{where}: control_plane.grpc_base must be {BASELINE_GRPC_BASE} in format {FORMAT}, "
            f"got {grpc_base!r}. The fabric's port block is pre-flighted against the kernel's "
            f"ephemeral range at that base (grpc_ports.py, F-15); a controller that wants "
            f"different ports is rewritten on the controller side")
    device_id = cp.get("device_id", BASELINE_DEVICE_ID)
    if device_id != BASELINE_DEVICE_ID:
        raise AppPackageError(
            f"{where}: control_plane.device_id must be {BASELINE_DEVICE_ID!r} in format "
            f"{FORMAT}, got {device_id!r}")

    bmv2 = doc.get("bmv2") or {}
    if not isinstance(bmv2, dict):
        raise AppPackageError(f"{where}: 'bmv2' must be an object")
    cpu_port = bmv2.get("cpu_port", BASELINE_CPU_PORT)
    if not isinstance(cpu_port, int) or isinstance(cpu_port, bool) or not 0 <= cpu_port <= 511:
        raise AppPackageError(f"{where}: bmv2.cpu_port must be an integer 0..511, got {cpu_port!r}")

    links = doc.get("links", [])
    if not isinstance(links, list):
        raise AppPackageError(f"{where}: 'links' must be a list")

    return Package(
        dir=package_dir,
        name=name,
        topology=topology,
        mode=mode,
        election_id=election_id,
        grpc_base=grpc_base,
        device_id=device_id,
        cpu_port=cpu_port,
        prefix_len=BASELINE_PREFIX_LEN,
        pipeline=BASELINE_PIPELINE,
        hosts=hosts,
        switches=switches,
        links=tuple(links),
    )


def current(knob_path=None) -> Package:
    """`load(read_knob())`, or `baseline()` when there is no knob. The whole decision."""
    directory = read_knob(knob_path)
    return baseline() if directory is None else load(directory)


# --- choosing the topology model -------------------------------------------------------------


def topology_path(package, host_num, setting_dir=None, env=None):
    """
    Which topology model this fabric builds from.

    A package states it; without one the host count picks it, which is the rule `ndt up` and
    the topology script already use (topo_from_json.model_path).

    🔴 A package and `NDTWIN_P4_TOPO_FILE` that disagree are refused rather than silently
    ranked. That pairing is the 2026-08-21 defect in a new costume -- an override naming one
    model while the rest of the run sized itself from another built a fabric the twin had no
    model for, and every topology view still read correct.
    """
    if package is not None and package.topology:
        env = os.environ if env is None else env
        override = env.get("NDTWIN_P4_TOPO_FILE")
        if override and os.path.abspath(override) != os.path.abspath(package.topology):
            raise AppPackageError(
                f"NDTWIN_P4_TOPO_FILE={override} disagrees with the app package's topology "
                f"{package.topology}. One of them would build the fabric while the other was "
                f"handed to the kernel; unset the variable or point it at the package's model")
        return package.topology
    return topo_from_json.model_path(host_num, setting_dir=setting_dir, env=env)


# [Co-developed with claude code -- Adam]
