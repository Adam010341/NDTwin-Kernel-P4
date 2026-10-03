"""NDTwin's half, as the proxy answers it: switch_state, openapi, counters, the two writers.

[Co-developed with claude code -- Adam]

Every call goes through `cfg.proxy`, the HTTP client object the Config carries (DESIGN 12-9):
production hands it a urllib client for localhost:8081, the tests an in-process fake.
"""
from __future__ import annotations


def switch_state(cfg):
    """The /p4/switch_state document, or None when the proxy did not answer 200 with JSON."""
    reply = cfg.proxy.get("/p4/switch_state")
    if reply.status != 200 or not isinstance(reply.body, dict):
        return None
    return reply.body


def openapi_paths(cfg):
    """{path: set(methods)} from /openapi.json, or None when it could not be read.

    DESIGN 2.1 "route 存在與否": a route that is not in the proxy's own OpenAPI document is
    NDTwin saying it has no such endpoint -- a structural answer, read before any oracle.
    """
    reply = cfg.proxy.get("/openapi.json")
    if reply.status != 200 or not isinstance(reply.body, dict):
        return None
    paths = reply.body.get("paths")
    if not isinstance(paths, dict):
        return None
    return {p: set(m.upper() for m in (v or {})) for p, v in paths.items()}


def counter(cfg, name, dpid, index=0):
    """(status, packets or None) of GET /p4/counter/<name>?dpid=&index= (api_routes.py:963-1029:
    200 {"bytes", "packets"}; 404 not in this pipeline; 503 EXPLICITLY NOT A ZERO)."""
    reply = cfg.proxy.get("/p4/counter/%s?dpid=%d&index=%d" % (name, int(dpid), int(index)))
    packets = None
    if reply.status == 200 and isinstance(reply.body, dict) and isinstance(reply.body.get("packets"), int):
        packets = reply.body["packets"]
    return reply.status, packets


def post_table_entry(cfg, entry):
    reply = cfg.proxy.post("/p4/table_entry", entry)
    return reply.status, reply.body


def post_multicast_group(cfg, group):
    reply = cfg.proxy.post("/p4/multicast_group", group)
    return reply.status, reply.body
