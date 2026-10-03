#!/usr/bin/env python3
"""Which routes the proxy's own OpenAPI document lists -- read in-process, no socket. (S0)

[Co-developed with claude code -- Adam]

DESIGN 2.1 says a route's absence is read from /openapi.json, and marks "FastAPI serves it by
default (main.py:38 does not turn it off)" as an inference for Cut 1 to verify. This verifies it
without starting the proxy: it reads main.py's `app = FastAPI(...)` call with `ast` (no
`openapi_url` / `docs_url` keyword may be there), builds an app with exactly those keywords,
includes proxy_agent.api_routes.router -- the router main.py includes (main.py:181) -- and sends
one ASGI GET /openapi.json through it in this process. TestClient is not used: the p4_proxy venv
has no httpx (checked 2026-10-03), and a raw ASGI call needs nothing else.

    p4_proxy/venv/bin/python tools/p4_health/openapi_probe.py [--repo DIR]   -> JSON on stdout
"""
import ast
import asyncio
import json
import os
import sys


def main_kwargs(main_py):
    tree = ast.parse(open(main_py, encoding="utf-8").read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call) \
                and getattr(node.value.func, "id", None) == "FastAPI" \
                and any(getattr(t, "id", None) == "app" for t in node.targets):
            return {k.arg: ast.literal_eval(k.value) for k in node.value.keywords}, node.lineno
    raise SystemExit("no `app = FastAPI(...)` in %s" % main_py)


def asgi_get(app, path):
    out = {"status": None, "body": b""}

    async def run():
        sent = []

        async def receive():
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(msg):
            sent.append(msg)

        scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "GET",
                 "scheme": "http", "path": path, "raw_path": path.encode(), "query_string": b"",
                 "root_path": "", "headers": [], "client": ("in-process", 0),
                 "server": ("in-process", 0)}
        await app(scope, receive, send)
        for msg in sent:
            if msg["type"] == "http.response.start":
                out["status"] = msg["status"]
            elif msg["type"] == "http.response.body":
                out["body"] += msg.get("body", b"")
    asyncio.run(run())
    return out


def main(argv):
    repo = argv[argv.index("--repo") + 1] if "--repo" in argv else \
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    proxy = os.path.join(repo, "p4_proxy")
    kwargs, line = main_kwargs(os.path.join(proxy, "proxy_agent", "main.py"))
    sys.path.insert(0, proxy)
    from fastapi import FastAPI
    from proxy_agent import api_routes
    app = FastAPI(**kwargs)
    app.include_router(api_routes.router)
    reply = asgi_get(app, "/openapi.json")
    doc = json.loads(reply["body"]) if reply["status"] == 200 else {}
    print(json.dumps({"main_py_line": line, "constructor_kwargs": sorted(kwargs),
                      "openapi_url": app.openapi_url, "status": reply["status"],
                      "paths": {p: sorted(m.upper() for m in v) for p, v in sorted((doc.get("paths") or {}).items())}},
                     indent=2, sort_keys=True))
    return 0 if reply["status"] == 200 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
