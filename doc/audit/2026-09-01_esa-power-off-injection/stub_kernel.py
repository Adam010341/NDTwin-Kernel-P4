#!/usr/bin/env python3
"""Stub NDTwin kernel: the injection vehicle for the ESA power-off round.

[Co-developed with claude code -- Adam]

This stands in for the real kernel on 127.0.0.1:8000 so that
`/ndt/set_switches_power_state` can be made to answer a non-2xx on demand.
It is deliberately dumb: it does not model the kernel, it only answers.

Two properties matter and are the reason this file exists rather than a
one-liner:

  1. It records EVERY request it served, with the status it answered, to a
     jsonl.  Without that record, "the app reported no error" is
     indistinguishable from "the app never sent the request" -- the injection
     has to assert its own success (the arm's check reads this file).

  2. The injected status is applied to ONE target only.  Everything else keeps
     answering 200, so an arm that goes quiet cannot be explained by the whole
     stub having gone dark.

The 404 and 500 bodies are copied from what the real kernel actually sends
(`HttpSession::handleNotFound` -> {"error":"Not Found"}, and the
std::exception catch -> {"error":"Internal server error",...}), because the
client parses the body and a body-shape difference would be a confound.
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("STUB_PORT", "8000"))

# The one target the injection applies to. Everything else is answered 200.
INJECT_TARGET = os.environ.get("INJECT_TARGET", "/ndt/set_switches_power_state")
INJECT_STATUS = int(os.environ.get("INJECT_STATUS", "200"))

REQUEST_LOG = os.environ.get("STUB_LOG", "stub_requests.jsonl")
GRAPH_FIXTURE = os.environ.get("GRAPH_FIXTURE", "fixture_graph.json")

with open(GRAPH_FIXTURE, "rb") as fh:
    GRAPH_BODY = fh.read()

_lock = threading.Lock()
_seq = [0]


def _record(method, target, status):
    with _lock:
        _seq[0] += 1
        entry = {"seq": _seq[0], "method": method, "target": target, "status": status}
        with open(REQUEST_LOG, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
            fh.flush()


def _body_for(status):
    """Match the real kernel's error bodies, so the client parses the same shapes."""
    if status == 404:
        return json.dumps({"error": "Not Found"}).encode()
    if status >= 500:
        return json.dumps(
            {"error": "Internal server error", "details": "injected by stub_kernel.py"}
        ).encode()
    return json.dumps({"result": "ok"}).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # silence the default stderr spam
        pass

    def _answer(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _dispatch(self, method):
        target = self.path
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

        if target.startswith("/ndt/get_graph_data"):
            status, body = 200, GRAPH_BODY
        elif target.startswith(INJECT_TARGET):
            status = INJECT_STATUS
            body = _body_for(status)
        else:
            status, body = 200, json.dumps({"result": "ok"}).encode()

        _record(method, target, status)
        self._answer(status, body)

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")


if __name__ == "__main__":
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(
        f"stub_kernel listening on {HOST}:{PORT}; "
        f"injecting {INJECT_STATUS} on {INJECT_TARGET}; log={REQUEST_LOG}",
        file=sys.stderr,
        flush=True,
    )
    srv.serve_forever()
