"""Does the adapter move a tutorials controller onto NDTwin's ports -- both numbers, together?

[Co-developed with claude code -- Adam]

No real `p4runtime_lib` and no real controller: the subject is the rewrite, and a fake module
with a recording `Bmv2SwitchConnection` is enough to see it. Running the real thing needs a
fabric, and a test that needs a fabric is not a test that runs here.

    p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests \
        -t tools/p4_exercise/tests -v
"""
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(os.path.dirname(HERE))
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

from p4_exercise import run_external_controller as adapter  # noqa: E402


def fake_p4runtime_lib_bmv2():
    """A stand-in with the shape the adapter patches: a subclass with an inherited __init__."""
    calls = []

    class SwitchConnection:
        def __init__(self, name=None, address="127.0.0.1:50051", device_id=0,
                     proto_dump_file=None):
            calls.append({"name": name, "address": address, "device_id": device_id,
                          "proto_dump_file": proto_dump_file})

    class Bmv2SwitchConnection(SwitchConnection):
        pass

    module = types.SimpleNamespace(SwitchConnection=SwitchConnection,
                                   Bmv2SwitchConnection=Bmv2SwitchConnection)
    return module, calls


class Remap(unittest.TestCase):
    def test_device_id_moves_with_the_address(self):
        # 🔴 THE MUTATION THIS FILE EXISTS FOR. Dialling 30051 while still claiming device_id 0
        # gets a NOT_FOUND from bmv2 on every request -- the connection succeeds and nothing
        # else does, which reads as "the switch is up but the rules did not take".
        address, device_id, dpid = adapter.remap(address="127.0.0.1:50051", device_id=0)
        self.assertEqual(address, "localhost:30051")
        self.assertEqual(device_id, 1)
        self.assertEqual(dpid, 1)

    def test_the_second_switch_moves_too(self):
        self.assertEqual(adapter.remap(address="127.0.0.1:50052", device_id=1),
                         ("localhost:30052", 2, 2))

    def test_the_address_is_the_pivot_not_the_device_id(self):
        # A controller that passes a device_id disagreeing with its own address (tutorials'
        # convention is i-1) still lands on the switch its ADDRESS named.
        self.assertEqual(adapter.remap(address="127.0.0.1:50053", device_id=99),
                         ("localhost:30053", 3, 3))

    def test_a_connection_named_only_by_switch_name_still_lands(self):
        self.assertEqual(adapter.remap(address=None, name="s2"), ("localhost:30052", 2, 2))

    def test_a_grpc_base_from_the_package_is_honoured(self):
        self.assertEqual(adapter.remap(address="127.0.0.1:50051", grpc_base=31000),
                         ("localhost:31001", 1, 1))

    def test_an_address_outside_the_tutorials_block_is_refused_not_passed_through(self):
        # 🔴 Passing it through would dial a port nothing is listening on and block inside
        # MasterArbitrationUpdate, which looks like a slow switch rather than a wrong address.
        with self.assertRaises(adapter.AdapterError):
            adapter.remap(address="10.0.0.5:9559", device_id=0)
        with self.assertRaises(adapter.AdapterError):
            adapter.remap(address="127.0.0.1:50050", device_id=0)

    def test_a_switch_the_package_does_not_declare_is_refused(self):
        with self.assertRaises(adapter.AdapterError) as cm:
            adapter.remap(address="127.0.0.1:50054", dpids={1, 2, 3})
        self.assertIn("s4", str(cm.exception))


class Install(unittest.TestCase):
    def test_the_patch_rewrites_a_real_construction(self):
        module, calls = fake_p4runtime_lib_bmv2()
        logged = []
        adapter.install(module, dpids={1, 2, 3}, log=logged.append)
        module.Bmv2SwitchConnection(name="s1", address="127.0.0.1:50051", device_id=0,
                                    proto_dump_file="logs/s1.txt")
        module.Bmv2SwitchConnection(name="s2", address="127.0.0.1:50052", device_id=1,
                                    proto_dump_file="logs/s2.txt")
        self.assertEqual([c["address"] for c in calls], ["localhost:30051", "localhost:30052"])
        self.assertEqual([c["device_id"] for c in calls], [1, 2])
        # Everything else the controller passed survives untouched.
        self.assertEqual([c["proto_dump_file"] for c in calls], ["logs/s1.txt", "logs/s2.txt"])
        self.assertEqual([c["name"] for c in calls], ["s1", "s2"])

    def test_every_rewrite_is_printed(self):
        module, _calls = fake_p4runtime_lib_bmv2()
        logged = []
        adapter.install(module, dpids={1, 2, 3}, log=logged.append)
        module.Bmv2SwitchConnection(name="s1", address="127.0.0.1:50051", device_id=0)
        self.assertEqual(len(logged), 1)
        self.assertIn("127.0.0.1:50051", logged[0])
        self.assertIn("localhost:30051", logged[0])
        self.assertIn("device_id=1", logged[0])

    def test_the_patch_refuses_a_switch_outside_the_package(self):
        module, calls = fake_p4runtime_lib_bmv2()
        adapter.install(module, dpids={1, 2}, log=lambda _m: None)
        with self.assertRaises(adapter.AdapterError):
            module.Bmv2SwitchConnection(name="s9", address="127.0.0.1:50059", device_id=8)
        self.assertEqual(calls, [])

    def test_the_base_class_is_left_alone(self):
        # Only bmv2 connections are redirected; a controller talking to some other target must
        # fail rather than be quietly pointed at a bmv2 switch.
        module, _calls = fake_p4runtime_lib_bmv2()
        before = module.SwitchConnection.__init__
        adapter.install(module, dpids={1}, log=lambda _m: None)
        self.assertIs(module.SwitchConnection.__init__, before)


class Locating(unittest.TestCase):
    def test_the_tutorials_utils_directory_is_found_by_walking_up(self):
        real = "/home/adam/tutorials/exercises/p4runtime"
        if not os.path.isdir(os.path.join("/home/adam/tutorials", "utils", "p4runtime_lib")):
            self.skipTest("no ~/tutorials on this machine")
        self.assertEqual(adapter.find_tutorials_utils(real), "/home/adam/tutorials/utils")

    def test_a_tree_without_p4runtime_lib_is_refused(self):
        with self.assertRaises(adapter.AdapterError):
            adapter.find_tutorials_utils(HERE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
