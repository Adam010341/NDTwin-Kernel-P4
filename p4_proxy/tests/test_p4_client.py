"""
Integration check for P4RuntimeClient against a live bmv2 switch.

This is not a unit test: it needs `simple_switch_grpc` actually listening, and it writes real
table entries. It runs only when NDTWIN_LIVE_SWITCH_OPT_IN=1 is exported; without that it
skips unconditionally, so it can sit alongside the unit tests without ever touching a switch.

The env gate is the lesson of 2026-08-13: the guards below are safety *preconditions*, but for
one night they were also the only arming switch, so "switch reachable + proxy down" was enough
to fire. A routine suite run hit exactly that window while a live round had the proxy stopped,
and pushed a pipeline config, two routes and a clone session onto the experiment's switch 1.
Reachability describes the environment; it must never consent on the operator's behalf.

It also skips when the proxy agent is running, because the two cannot share a switch: both
attach with election_id 1, and P4Runtime allows only one holder. Whoever arrives second gets
"Election id already exists", never becomes master, and every write it makes is refused --
which shows up as this test failing for a reason that has nothing to do with the code under
test. Using a higher election_id instead would make the test win, but that would *steal*
mastership from a running proxy and silently kill its telemetry, which is worse than skipping.

To exercise it, start the P4 testbed, leave the proxy stopped, and opt in explicitly:

    sudo python3 p4_proxy/mininet/p4_testbed_topo.py

then

    NDTWIN_LIVE_SWITCH_OPT_IN=1 PYTHONPATH=p4_proxy \
        p4_proxy/venv/bin/python p4_proxy/tests/test_p4_client.py

NDTWIN_L1_OPT_IN -- this token tells tools/test_workflow/l1_unit_tests.sh that a fully skipped run
of this file is the intended outcome and not a defect. Without it the runner fails any file where
every test skipped, because unittest counts skipped tests inside "Ran N" and such a file otherwise
reports "Ran 1 test / OK" while asserting nothing. Do not add the token to a unit test.

[Co-developed with claude code -- Adam]
"""

from __future__ import annotations

import os
import socket
import sys
import time
import unittest

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# p4_client imports grpc and the P4Runtime protobufs, which are not installed for every
# interpreter L1 might pick (see tools/test_workflow/l1_unit_tests.sh). Guarding the import
# lets this file report a clean skip instead of crashing the whole test run with
# ModuleNotFoundError when it lands on a plain python3.
try:
    from proxy_agent.p4_client import P4RuntimeClient
    HAVE_P4RUNTIME = True
except ImportError:
    P4RuntimeClient = None
    HAVE_P4RUNTIME = False

GRPC_HOST = "localhost"
GRPC_PORT = 50051
PROXY_PORT = 8081
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P4INFO = os.path.join(BASE_DIR, "p4_src", "build", "ndtwin_switch.p4info.txt")
PIPELINE_JSON = os.path.join(BASE_DIR, "p4_src", "build", "ndtwin_switch.json")


def something_is_listening(port: int, host: str = GRPC_HOST) -> bool:
    """
    Whether anything accepts TCP on a port.

    Checked with a plain socket rather than by attempting the RPC, because the client's start()
    raises from deep inside grpc on failure and that is what used to abort the whole file.
    """
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def a_switch_is_listening(host: str = GRPC_HOST, port: int = GRPC_PORT) -> bool:
    return something_is_listening(port, host)


@unittest.skipUnless(os.environ.get("NDTWIN_LIVE_SWITCH_OPT_IN") == "1",
                     "writes to a live switch; export NDTWIN_LIVE_SWITCH_OPT_IN=1 to opt in "
                     "(reachability alone must never arm this -- see module docstring)")
@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
@unittest.skipUnless(a_switch_is_listening(),
                     f"no bmv2 listening on {GRPC_HOST}:{GRPC_PORT}; "
                     f"start p4_proxy/mininet/p4_testbed_topo.py to run this")
@unittest.skipIf(something_is_listening(PROXY_PORT),
                 f"the proxy agent is running on :{PROXY_PORT} and holds mastership with the "
                 f"same election_id; this test would be refused every write, and outbidding it "
                 f"would kill the running proxy's telemetry. Stop the proxy to run this.")
@unittest.skipUnless(os.path.exists(P4INFO) and os.path.exists(PIPELINE_JSON),
                     "pipeline not built; run tools/test_workflow/l0_build_check.sh p4")
class LiveSwitchTest(unittest.TestCase):
    def setUp(self):
        self.client = P4RuntimeClient(device_id=1,
                                      grpc_addr=f"{GRPC_HOST}:{GRPC_PORT}",
                                      p4info_path=P4INFO,
                                      json_path=PIPELINE_JSON)
        self.client.start()
        self.addCleanup(self.client.stop)
        time.sleep(1)  # let mastership and the pipeline config settle

    def test_installs_routes_and_the_clone_session(self):
        self.assertTrue(self.client.insert_ipv4_route("10.0.0.1", 32, "00:00:00:00:00:01", 1))
        self.assertTrue(self.client.insert_ipv4_route("10.0.0.2", 32, "00:00:00:00:00:02", 2))
        # start() programs this; assert it against a real PRE, which is the one thing no unit
        # test can check -- tests/test_clone_session.py can only verify the request we build.
        self.assertTrue(self.client.write_clone_session())


if __name__ == "__main__":
    unittest.main(verbosity=2)
