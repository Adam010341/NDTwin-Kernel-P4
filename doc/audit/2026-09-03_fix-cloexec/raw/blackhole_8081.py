#!/usr/bin/env python3
"""Accepts on 127.0.0.1:8081 and never answers. The precondition for FINDINGS #47.

[Co-developed with claude code -- Adam]

WHY THIS IS PART OF THE EXPERIMENT AND NOT A TRICK

The first run of port_release_experiment.sh, with nothing listening on :8081, showed the *unfixed*
kernel releasing both ports in 1-2 ms -- the defect did not reproduce. The reason is in the
kernel's own stdout: every poll `curl` failed with "Failed to connect to localhost port 8081 after
0 ms: Couldn't connect to server". A refused connection kills curl in milliseconds, so by the time
the kernel was killed it had no live children, and a socket nobody inherited is released with the
process.

The defect needs a child that is still alive when the kernel dies. That is exactly what
`curl -s --max-time 3 http://localhost:8081/p4/switch_state` does when something ACCEPTS the
connection and does not answer -- a busy or wedged proxy, which is the normal condition this
kernel's 1 Hz poll meets, and which round 3 was measuring at 02:02 (its `ss` output shows two `sh`
and two `curl` still holding :8000 a second and a half after the kernel's pid was gone).

So this program supplies the missing precondition and nothing else. It does not touch the kernel,
the ports under measurement, or the fix. Both binaries -- before and after -- are measured with it
running, and both are also measured without it.

Usage:  blackhole_8081.py            # prints its pid, then serves until killed by that pid
"""
import os
import socket
import sys

HOST, PORT = "127.0.0.1", 8081

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((HOST, PORT))
srv.listen(128)

print("blackhole pid %d listening on %s:%d" % (os.getpid(), HOST, PORT), flush=True)

held = []
try:
    while True:
        conn, _ = srv.accept()
        # Keep the connection open and say nothing. curl waits out its --max-time.
        held.append(conn)
        # Bounded, so a long run cannot exhaust this process's descriptors.
        if len(held) > 400:
            held.pop(0).close()
except KeyboardInterrupt:
    pass
finally:
    for c in held:
        try:
            c.close()
        except OSError:
            pass
    srv.close()
    sys.exit(0)
