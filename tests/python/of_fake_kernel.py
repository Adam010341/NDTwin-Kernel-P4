"""An in-process fake of the kernel's flow-entry routes for tests/python/test_ndtwin_sdk_of.py
(not a test itself).

[Co-developed with claude code -- Adam]

It serves, on 127.0.0.1 and an ephemeral port:
  * POST /ndt/install_flow_entry, /ndt/modify_flow_entry, /ndt/delete_flow_entry: 200 `queued`
    with a new request id, the body `queued` below;
  * GET /ndt/get_flow_dispatch_status?request_id=R: the record of a request that completed with
    no failure on OVS, `dispatch_ok` below.
Any other route answers the kernel's 404 `Not Found`. A test queues other replies with `script`;
each is used once, in order, before the default. A reply of None closes the connection without
answering. Every request is recorded as (method, path, query, body).

Each canned body names the line it was copied from, in the kernel at 9c0569de5
(src/ndt_core/http/HttpSession.cpp = HS.cpp) or the P4 proxy. Line numbers are of that commit.
"""
import copy
import json
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTES = ("/ndt/install_flow_entry", "/ndt/modify_flow_entry", "/ndt/delete_flow_entry")
DISPATCH = "/ndt/get_flow_dispatch_status"

# HS.cpp:665-668 (labClaimJson), with no claim file: state "none" (HS.cpp:223). Added as a body key
# to every reply of the write routes whose body is a JSON object, refusals included (HS.cpp:757,
# the list at HS.cpp:332-335).
LAB_CLAIM = {"state": "none", "owner": "", "expires_at": 0, "note": ""}

# HS.cpp:1810-1817, the `why_unknown` sentence of every switch_outcome (abridged here).
WHY_UNKNOWN = ("a count of jobs whose plane's reply is not evidence about any switch. On the "
               "OVS/OpenFlow plane that is every job and always will be until a barrier "
               "read-back exists")


def queued(request_id, accepted=1):
    """HS.cpp:2731-2738, the 200 of processFlowBatch, plus lab_claim (HS.cpp:757)."""
    return {"status": "queued", "accepted": accepted, "request_id": request_id,
            "detail": "entries accepted for programming; per-entry outcomes are reported in the "
                      "kernel log and, since they are not in this response, are readable "
                      "afterwards from GET /ndt/get_flow_dispatch_status?request_id="
                      + str(request_id) + ", which answers for this batch alone. That "
                      "endpoint's process-wide counters cannot be attributed to one caller",
            "lab_claim": dict(LAB_CLAIM)}


def record(request_id, enqueued=1, dispatched=1, ok=1, failed=0, accepted=0, rejected=0,
           unknown=None, failures=(), not_retained=0, running=True):
    """HS.cpp:1938-1965, the per-request dispatch record: counters HS.cpp:1824-1831,
    switch_outcome HS.cpp:1834-1840, `complete` HS.cpp:1949 (dispatched >= enqueued),
    failures HS.cpp:1960, failures_not_retained HS.cpp:1961, dispatcher_running HS.cpp:1965."""
    unknown = dispatched - accepted - rejected if unknown is None else unknown
    return {"request_id": request_id, "enqueued": enqueued,
            "counters": {"dispatched": dispatched, "dispatched_ok": ok, "dispatch_failed": failed},
            "switch_outcome": {"accepted_by_switch": accepted, "rejected_by_switch": rejected,
                               "unknown": unknown, "why_unknown": WHY_UNKNOWN},
            "complete": dispatched >= enqueued,
            "detail": "counters for this request only. complete=false means jobs from this "
                      "batch are still queued -- or, if dispatcher_running is false, that they "
                      "were dropped before any southbound attempt and are counted in the "
                      "process-wide counters.dropped_after_stop instead",
            "failures": [copy.deepcopy(f) for f in failures],
            "failures_not_retained": not_retained, "dispatcher_running": running}


def dispatch_ok(request_id):
    """A request of one entry that Ryu took: on OVS every dispatched job is `unknown` at the
    switch (OpenFlowRoutingStrategy.hpp:30, successConfirmsProgramming false;
    DispatchOutcomeLog.hpp:299-310)."""
    return record(request_id)


def failure(request_id, status, message, refused_by=None, dpid=1, op="install", **said):
    """One failure record, HS.cpp:1855-1869 (dispatchFailuresJson): `refused_by`, `outcome`,
    `reason` and `remedy` are present only when the strategy said them (HS.cpp:1870-1880)."""
    rec = {"seq": 1, "at_unix_ms": 1764000000000, "op": op, "dpid": dpid,
           "requested_priority": 100, "match": {"eth_type": 2048, "ipv4_dst": "10.0.0.2"},
           "controller_status": status, "message": message, "request_id": request_id}
    if refused_by:
        rec["refused_by"] = refused_by
    rec.update(said)
    return rec


class OfFakeKernel:
    def __init__(self):
        self.requests = []
        self.scripted = {}      # (method, path) -> [reply, ...]; a reply is (status, body) or None
        self.next_id = 7
        self.lock = threading.Lock()

    def script(self, method, path, *replies):
        """Answer the next requests to (method, path) with these replies, in order."""
        with self.lock:
            self.scripted.setdefault((method, path), []).extend(replies)

    def count(self, method, path=None):
        return sum(1 for m, p, _, _ in self.requests if m == method and path in (None, p))

    def handle(self, method, path, query, body):
        with self.lock:
            self.requests.append((method, path, query, body))
            queue = self.scripted.get((method, path))
            if queue:
                return queue.pop(0)
            if method == "POST" and path in ROUTES:
                self.next_id += 1
                return 200, queued(self.next_id)
            if method == "GET" and path == DISPATCH:
                return 200, dispatch_ok(int(query.get("request_id", "0")))
        return 404, {"error": "Not Found"}      # HS.cpp:3830 (handleNotFound)


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def _do(self):
            parts = urllib.parse.urlsplit(self.path)
            query = dict(urllib.parse.parse_qsl(parts.query))
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            body = json.loads(raw) if raw else None
            reply = fake.handle(self.command, parts.path, query, body)
            if reply is None:
                self.close_connection = True
                self.connection.shutdown(2)      # no answer: the client sees a broken connection
                return
            status, payload = reply
            data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = _do

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05},
                     daemon=True).start()
    return server
