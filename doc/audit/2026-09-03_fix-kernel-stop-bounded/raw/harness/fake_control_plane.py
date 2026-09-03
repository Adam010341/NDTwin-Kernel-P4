#!/usr/bin/env python3
"""A control plane that answers some paths and wedges on others.

[Co-developed with claude code -- Adam]

FINDINGS #27 / #76 live reproduction WITHOUT the lab (three agents are queued for it tonight).

WHY IT IS NOT JUST "DON'T LISTEN"
FIX-CLOEXEC.md §2.3 measured that with :8081 closed every poll's curl fails in ~0 ms and neither
defect reproduces: *refused is fast*. What costs the full `--max-time` is a peer that completes the
handshake and then stops talking, so this server accepts, reads the request, and -- for a wedged
path -- holds the connection open forever without writing a byte.

WHY IT ALSO HAS TO ANSWER SOMETHING (for #27)
loadStaticTopologyFromFile starts every vertex at `isUp = false`, and
`isPollableForFlowTable` requires `isUp`. A proxy that never answers anything therefore leaves
every switch down, the flow-table worker polls nothing, and #27 does NOT reproduce. The finding was
measured on a fabric whose switches were already up when the control plane stopped answering. So
`--answer-topology N` serves N switches on /v1.0/topology/switches (which is what lifts them to up)
while /stats/flow/* stays wedged -- topology plane healthy, flow-stats plane wedged, which is
exactly the condition row 27 describes.

Usage:
  fake_control_plane.py --port 8081 [--port 8080] [--answer-topology 10] [--wedge-all]
"""
import argparse
import json
import socket
import sys
import threading
import time

HELD = []
LOCK = threading.Lock()
STATE = {"accepted": 0, "answered": 0, "wedged": 0}

DPID_HEX_WIDTH = 16


def _log(msg: str) -> None:
    print(f"fake-cp {time.time():.3f} {msg}", file=sys.stderr, flush=True)


def _switches_body(n: int) -> bytes:
    # Shape from p4_proxy/proxy_agent/ryu_topology.py render_switches(): dpid is a hex string,
    # which is how the kernel parses it (stoull base 16).
    rows = [{"dpid": f"{d:0{DPID_HEX_WIDTH}x}", "ports": []} for d in range(1, n + 1)]
    return json.dumps(rows).encode()


def _respond(conn: socket.socket, body: bytes) -> None:
    head = (b"HTTP/1.1 200 OK\r\n"
            b"Content-Type: application/json\r\n"
            b"Content-Length: " + str(len(body)).encode() + b"\r\n"
            b"Connection: close\r\n\r\n")
    conn.sendall(head + body)
    conn.close()


def handle(conn: socket.socket, args) -> None:
    try:
        conn.settimeout(5.0)
        try:
            request = conn.recv(65536).decode("latin-1", "replace")
        except OSError:
            request = ""
        path = ""
        if request:
            parts = request.split(" ", 2)
            if len(parts) >= 2:
                path = parts[1]

        if not args.wedge_all and path.startswith("/v1.0/topology/switches"):
            with LOCK:
                STATE["answered"] += 1
            _log(f"answered  {path}  ({args.answer_topology} switches)")
            _respond(conn, _switches_body(args.answer_topology))
            return
        if not args.wedge_all and path.startswith("/v1.0/topology/"):
            with LOCK:
                STATE["answered"] += 1
            _log(f"answered  {path}  (empty array)")
            _respond(conn, b"[]")
            return

        # Everything else -- /stats/flow/<dpid>, /p4/switch_state, and every path at all when
        # --wedge-all -- is held open and never written to. This is the wedge.
        with LOCK:
            STATE["wedged"] += 1
            HELD.append(conn)
        _log(f"WEDGED    {path or '<no request line>'}")
    except Exception as exc:  # noqa: BLE001 - a fake must never die on a malformed request
        _log(f"handler error: {exc!r}")


def serve(port: int, args) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(256)
    _log(f"listening on 127.0.0.1:{port} "
         f"(wedge_all={args.wedge_all}, answer_topology={args.answer_topology})")
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        with LOCK:
            STATE["accepted"] += 1
        threading.Thread(target=handle, args=(conn, args), daemon=True).start()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, action="append", required=True)
    ap.add_argument("--answer-topology", type=int, default=10,
                    help="how many switches /v1.0/topology/switches lists")
    ap.add_argument("--wedge-all", action="store_true",
                    help="wedge every path including topology (the #76 condition)")
    args = ap.parse_args()

    for p in args.port:
        threading.Thread(target=serve, args=(p, args), daemon=True).start()
    while True:
        time.sleep(5)
        with LOCK:
            _log(f"stats accepted={STATE['accepted']} answered={STATE['answered']} "
                 f"wedged={STATE['wedged']} held={len(HELD)}")


if __name__ == "__main__":
    sys.exit(main())
