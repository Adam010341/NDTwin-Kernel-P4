#!/usr/bin/env python3
"""Run an exercise's own P4Runtime controller against NDTwin's fabric (TICKET-P1 §3).

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python tools/p4_exercise/run_external_controller.py \
        <package_dir> <controller.py>

The problem this solves is two hard-coded numbers. `exercises/p4runtime/mycontroller.py:142-151`
opens `127.0.0.1:50051` with `device_id=0` for s1 and `127.0.0.1:50052` with `device_id=1` for
s2 -- tutorials' convention of port 50050+i and device id i-1. NDTwin's fabric puts switch i at
`grpc_ports.GRPC_PORT_BASE + i` (30051, 30052, ...) with device id i, and that block is not
negotiable: it was moved below the kernel's ephemeral port range on purpose (F-15,
p4_proxy/mininet/grpc_ports.py). So one side has to move, and it is this one -- the fabric's
ports stay where they are and the controller is rewritten as it is loaded.

🔴 THE ADDRESS IS THE PIVOT, NOT THE DEVICE ID. Both have to change together: dialling the
right port with the wrong device id gets a `NOT_FOUND` from bmv2 on every request, and the two
numbers only agree if one of them is derived from the other. The port is what says which switch
the controller *meant*, so the device id is set from it rather than incremented on its own.

A connection this cannot place is refused, never passed through. A pass-through would dial
127.0.0.1:50051, find nothing listening, and hang in `MasterArbitrationUpdate` -- a silence
that looks like a slow switch.

This tool does not need root and does not start a fabric. It is only useful with one already
running (`ndt up p4 --app <p4runtime package>`); with nothing listening it will simply block.
"""
import argparse
import os
import runpy
import sys

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from p4_exercise import common
else:
    from . import common

#: tutorials puts switch i at 50050+i (utils/run_exercise.py and every mycontroller.py).
TUTORIALS_PORT_BASE = 50050


class AdapterError(RuntimeError):
    """A connection the adapter cannot place onto this fabric. Refused, never passed through."""


def switch_index(address=None, name=None):
    """Which switch a tutorials connection meant: from its port, else from its name."""
    if address:
        text = str(address)
        port = text.rsplit(":", 1)[-1]
        if port.isdigit():
            index = int(port) - TUTORIALS_PORT_BASE
            if index >= 1:
                return index
            raise AdapterError(
                f"address {address!r} names port {port}, which is not "
                f"{TUTORIALS_PORT_BASE}+i for any switch i >= 1. This adapter rewrites the "
                f"tutorials port convention; an address outside it has to be fixed in the "
                f"controller")
    if name and str(name)[:1] == "s" and str(name)[1:].isdigit():
        return int(str(name)[1:])
    raise AdapterError(
        f"cannot tell which switch a connection to {address!r} (name={name!r}) meant. Passing "
        f"it through unchanged would dial a port nothing is listening on and block in "
        f"MasterArbitrationUpdate, which looks like a slow switch rather than a wrong address")


def remap(address=None, device_id=None, name=None, grpc_base=common.REQUIRED_GRPC_BASE,
          dpids=None):
    """(new_address, new_device_id, dpid) for one tutorials switch connection."""
    index = switch_index(address=address, name=name)
    if dpids is not None and index not in dpids:
        raise AdapterError(
            f"the controller wants switch s{index} (from {address!r}), which this package does "
            f"not declare -- it has {sorted(dpids)}. The controller and the package disagree "
            f"about the topology")
    return (f"localhost:{grpc_base + index}", index, index)


def install(module, grpc_base=common.REQUIRED_GRPC_BASE, dpids=None, log=print):
    """Patch `p4runtime_lib.bmv2.Bmv2SwitchConnection` so every connection it makes is remapped.

    `Bmv2SwitchConnection` defines no `__init__` of its own -- it inherits SwitchConnection's --
    so the wrapper is set on the subclass and calls the inherited one. Patching the subclass and
    not `SwitchConnection` is deliberate: a controller that talks to something other than bmv2
    is not one this fabric can host, and it should fail rather than be quietly redirected.
    """
    original = module.Bmv2SwitchConnection.__init__

    def patched(self, name=None, address="127.0.0.1:50051", device_id=0, *args, **kwargs):
        new_address, new_device_id, dpid = remap(address=address, device_id=device_id,
                                                 name=name, grpc_base=grpc_base, dpids=dpids)
        log(f"[adapter] {name or f's{dpid}'}: {address} device_id={device_id}"
            f"  ->  {new_address} device_id={new_device_id}")
        return original(self, name=name, address=new_address, device_id=new_device_id,
                        *args, **kwargs)

    module.Bmv2SwitchConnection.__init__ = patched
    return original


def load_package(package_dir):
    pkg = common.load_json(os.path.join(os.path.abspath(package_dir), "package.json"))
    cp = pkg.get("control_plane") or {}
    if cp.get("mode") != "external":
        raise AdapterError(
            f"this package's control plane mode is {cp.get('mode')!r}. Running a second "
            f"controller against a fabric whose proxy is writing to it is how a table gets "
            f"cleared (p4_client.py:60-74); convert with --mode external, or do not run this")
    return pkg


def find_tutorials_utils(exercise_dir):
    """The `utils` directory holding `p4runtime_lib`, found by walking up from the exercise."""
    path = os.path.abspath(exercise_dir)
    while True:
        candidate = os.path.join(path, "utils")
        if os.path.isdir(os.path.join(candidate, "p4runtime_lib")):
            return candidate
        parent = os.path.dirname(path)
        if parent == path:
            raise AdapterError(
                f"no utils/p4runtime_lib above {exercise_dir}; pass --tutorials-utils")
        path = parent


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("package_dir")
    ap.add_argument("controller", help="the exercise's controller, e.g. mycontroller.py")
    ap.add_argument("--tutorials-utils", default=None,
                    help="the tutorials utils/ directory (default: found above the exercise)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the rewrite this package would apply and exit; runs nothing")
    args = ap.parse_args(argv)

    try:
        package = load_package(args.package_dir)
    except (AdapterError, OSError, ValueError) as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1

    grpc_base = (package.get("control_plane") or {}).get("grpc_base", common.REQUIRED_GRPC_BASE)
    dpids = {int(k) for k in (package.get("switches") or {}) if str(k).isdigit()}
    exercise_dir = (package.get("source") or {}).get("exercise_dir") or os.path.dirname(
        os.path.abspath(args.controller))

    controller = args.controller
    if not os.path.isabs(controller):
        candidate = os.path.join(exercise_dir, controller)
        controller = candidate if os.path.isfile(candidate) else os.path.abspath(controller)
    if not os.path.isfile(controller):
        print(f"REFUSED: no controller at {controller}", file=sys.stderr)
        return 1

    if args.dry_run:
        print(f"package  : {package.get('name')}  (mode external, grpc_base {grpc_base})")
        print(f"controller: {controller}")
        print(f"cwd       : {exercise_dir}")
        print("rewrites this package's switches would receive:")
        for dpid in sorted(dpids):
            old = f"127.0.0.1:{TUTORIALS_PORT_BASE + dpid}"
            new_address, new_device_id, _ = remap(address=old, device_id=dpid - 1,
                                                 grpc_base=grpc_base, dpids=dpids)
            print(f"  s{dpid}: {old} device_id={dpid - 1}  ->  {new_address} "
                  f"device_id={new_device_id}")
        print("(--dry-run: nothing was imported, patched or run)")
        return 0

    utils_dir = args.tutorials_utils or find_tutorials_utils(exercise_dir)
    if utils_dir not in sys.path:
        sys.path.insert(0, utils_dir)
    import p4runtime_lib.bmv2  # noqa: E402  (path has to be set first)

    install(p4runtime_lib.bmv2, grpc_base=grpc_base, dpids=dpids)
    print(f"[adapter] tutorials utils : {utils_dir}")
    print(f"[adapter] grpc base       : {grpc_base} (device id = dpid)")
    print(f"[adapter] running          {controller}  (cwd {exercise_dir})")

    os.chdir(exercise_dir)
    sys.argv = [controller]
    runpy.run_path(controller, run_name="__main__")
    return 0


if __name__ == "__main__":
    sys.exit(main())
