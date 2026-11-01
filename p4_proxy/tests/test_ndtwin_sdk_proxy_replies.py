"""The ndtwin Python SDK (sdk/python) reading the replies this proxy's own handler builds.

[Co-developed with claude code -- Adam]

The proxy's 502 for a failed table write is driven the way test_table_entry_route.py drives it,
turned into the bytes FastAPI would send, and served to the SDK with `X-NDTwin-Origin: proxy`, as
the kernel relays it. The SDK must read a 502 without the switch's per-update reason (the proxy's
own deadline) as a write that may have landed, and one with it as the switch's refusal; neither
is sent again. It lives with the proxy's tests because it needs the proxy's packages, which this
directory's lane gives it; the SDK itself needs only the standard library. The SDK is taken from
sdk/python, or from $NDTWIN_SDK_UNDER_TEST.
"""
import asyncio
import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import test_table_entry_route as route  # noqa: E402

sys.path.insert(0, os.environ.get("NDTWIN_SDK_UNDER_TEST") or os.path.join(REPO, "sdk", "python"))
import ndtwin  # noqa: E402

ENTRY = {"dpid": 1, "table": "MyIngress.ipv4_lpm", "match": {"hdr.ipv4.dstAddr": ["10.0.4.4", 32]},
         "action_name": "MyIngress.ipv4_forward",
         "action_params": {"dstAddr": "08:00:00:00:04:00", "port": 3}, "priority": None,
         "default_action": False}


def serve_relayed(status, raw, posts):
    """A kernel stand-in answering every POST with `status` and `raw`, relayed from the proxy."""
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            posts.append(self.path)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("X-NDTwin-Origin", "proxy")
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, args=(0.05,), daemon=True).start()
    return server


@unittest.skipUnless(route.HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class SdkReadsTheProxysRepliesTest(unittest.TestCase):
    def proxy_reply(self, rpc_error):
        """The JSON bytes of the proxy's answer to a write the switch failed with `rpc_error`."""
        api = route.api_routes
        for name in ("topology", "note_api_table_entry_write", "table_journals"):
            self.addCleanup(setattr, api, name, getattr(api, name))
        api.table_journals, api.note_api_table_entry_write = None, lambda dpid: None
        api.topology = route.FakeTopology({1: route.a_client(route.RecordingStub(rpc_error))})
        body = dict(route.AN_LPM_ENTRY, op="modify")
        with self.assertRaises(route.HTTPException) as ctx:
            asyncio.run(api.table_entry(route.a_request(body)))
        self.assertEqual(ctx.exception.status_code, 502)
        return json.dumps({"detail": ctx.exception.detail}).encode()

    def write(self, raw):
        """Send one modify through the SDK to a kernel that relays `raw`; (error, POSTs sent)."""
        posts = []
        server = serve_relayed(502, raw, posts)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        k = ndtwin.Kernel("http://127.0.0.1:%d" % server.server_address[1], timeout=5, retry_wait=0)
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            k.p4.write(ENTRY, "modify")
        return ctx.exception, len(posts)

    def test_the_proxys_own_deadline_is_an_unknown_outcome_sent_once(self):
        err, sent = self.write(self.proxy_reply(
            route.FakeRpcError(route.grpc.StatusCode.DEADLINE_EXCEEDED)))
        self.assertIsInstance(err, ndtwin.OutcomeUnknown)
        self.assertEqual(err.grpc_status, "DEADLINE_EXCEEDED")
        self.assertTrue(err.may_have_landed)
        self.assertEqual(sent, 1)

    def test_the_switchs_own_refusal_is_switch_refused_sent_once(self):
        trailers = route.per_update_trailer((route.code_pb2.NOT_FOUND, "Cannot find match entry"))
        err, sent = self.write(self.proxy_reply(
            route.FakeRpcError(route.grpc.StatusCode.UNKNOWN, details="", trailers=trailers)))
        self.assertIsInstance(err, ndtwin.SwitchRefused)
        self.assertEqual(err.p4rt_error, {"code": "NOT_FOUND", "message": "Cannot find match entry"})
        self.assertIs(err.nothing_written, True)
        self.assertEqual(sent, 1)


if __name__ == "__main__":
    unittest.main()
