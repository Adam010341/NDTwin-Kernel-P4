"""
Records the HTTP body `GET /stats/flow/1` answers for a switch on NDTwin's own pipeline.

[Co-developed with claude code -- Adam]
TICKET-P4-roles section 7 ruling 5, item 4. The roles ticket promises that NDTwin's own
/stats/flow body does not move by one byte. Round 1 pinned the renderer's output serialised with
`json.dumps(sort_keys=True)` -- which cannot see a change of key order, and key order is exactly
what the kernel's parser receives. This records the bytes FastAPI itself hands the ASGI server as
the response body (its own serialisation: key order, separators, escaping), with no
re-serialisation by the test, so the constant it produced can be compared byte for byte.

PROVENANCE of `BASELINE_NDTWIN_HTTP_BODY` in tests/test_flow_stats_route.py:
  This file, copied VERBATIM into a `git archive d492a346 p4_proxy setting` tree -- d492a346 is
  the commit that added the round-1 base captures and changes no production file, so its
  p4_proxy/proxy_agent is trunk 6291db35's (`git diff 6291db35 d492a346 -- p4_proxy/proxy_agent
  p4_proxy/mininet` is empty) -- and run there, on 2026-09-24, as

      cd p4_proxy && PYTHONPATH=. PYTHONDONTWRITEBYTECODE=1 venv/bin/python \
          tests/record_stats_flow_http_body.py

  printed the constant, its length and its sha256; the run is logged in
  scratch/overnight-2026-09-05/logs/gates-0910/record_stats_flow_http_body_at_base.p4r-*.log.
  Only what existed at d492a346 is used: `api_routes.router` / `api_routes.topology`,
  `RuleInstallTimes`, and `tests.test_ryu_flow_stats.ndtwin_pipeline_rows` (which d492a346
  itself added: every row shape ndtwin_switch.p4's tables can hold).

The client double carries NO `route_binding`, as no client did at the base; the HEAD test runs
it both ways (absent, and bound to BASELINE -- what every real NDTwin client carries now).
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


class NdtwinClient:
    """What get_flow_stats reads off a client: the rows and the client's own install record."""

    def __init__(self, rows):
        from proxy_agent.rule_install_times import RuleInstallTimes

        self.rule_install_times = RuleInstallTimes()
        self._rows = rows

    def read_table_entries(self):
        return list(self._rows)


class Topology:
    def __init__(self, switches):
        self.switches = switches


def asgi_get(app, path):
    """(status, content-type, body bytes) of one GET, through the ASGI interface itself."""
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
             "method": "GET", "scheme": "http", "path": path, "raw_path": path.encode(),
             "root_path": "", "query_string": b"", "headers": [],
             "client": ("127.0.0.1", 50000), "server": ("127.0.0.1", 8081)}
    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    asyncio.run(app(scope, receive, send))
    start = next(m for m in sent if m["type"] == "http.response.start")
    body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    headers = {k.decode("latin-1"): v.decode("latin-1") for k, v in start["headers"]}
    return start["status"], headers.get("content-type"), body


def record(client_attributes=None):
    """GET /stats/flow/1 for an NDTwin-pipeline client holding every row shape it can hold."""
    from fastapi import FastAPI

    from proxy_agent import api_routes
    from tests.test_ryu_flow_stats import ndtwin_pipeline_rows

    client = NdtwinClient(ndtwin_pipeline_rows())
    for name, value in (client_attributes or {}).items():
        setattr(client, name, value)
    app = FastAPI()
    app.include_router(api_routes.router)
    saved = api_routes.topology
    api_routes.topology = Topology({1: client})
    try:
        return asgi_get(app, "/stats/flow/1")
    finally:
        api_routes.topology = saved


if __name__ == "__main__":
    status, content_type, body = record()
    print(f"status       {status}")
    print(f"content-type {content_type}")
    print(f"length       {len(body)}")
    print(f"sha256       {hashlib.sha256(body).hexdigest()}")
    print("BASELINE_NDTWIN_HTTP_BODY = (")
    for i in range(0, len(body), 76):
        print(f"    {body[i:i + 76]!r}")
    print(")")
