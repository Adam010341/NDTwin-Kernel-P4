#!/usr/bin/env python3
"""Did a heartbeat frame reach this host? Run INSIDE a Mininet host's namespace, for a bounded time.

[Co-developed with claude code -- Adam]

    sudo -n mnexec -a <host pid> /usr/bin/python3 -I hb_sniff.py <host> <seconds> <session-hex> [<stop-file>]
    python3 hb_sniff.py --self-test

One ETH_P_ALL packet socket, NOT bound to an interface -- so every interface in this namespace
(the host's hN-eth0 and anything else it has, lo excepted) -- then one JSON line. It ends at the
FIRST heartbeat frame, when <stop-file> appears, or after <seconds>, whichever is first; it never
sends and it never outlives its own timer.

A frame counts as a heartbeat when EITHER its ethertype is 0x88B5 OR its bytes carry the magic
anywhere with this session six bytes after it (the daemon's body layout). The second test is the one that matters if a pipeline rewrote
or encapsulated the frame (a tunnel exercise wrapping it, say): the ethertype would change, the
payload would not.

Why here and not only on the switch side: the daemon's `forwarded_to_hosts` counts a frame
LEAVING a host-facing switch port. That is the same event from the other end, and ruling 4 is
about what ARRIVES at a host -- so both are read, and the census stops on either.
"""
import json
import os
import select
import shutil
import socket
import sys
import tempfile
import time

ETH_P_ALL = 3
ETHERTYPE = 0x88B5
MAGIC = b"NDHB"


def classify(frame, session):
    """(is_heartbeat, how) for one frame.

    The payload test follows the daemon's BODY layout (ndtwin-lab's heartbeat program: magic,
    version, flags, session, ...): the session is the eight bytes that start six after the
    magic. The spike's self-test encodes a frame with the daemon's own code and asks this.
    """
    if len(frame) >= 14 and int.from_bytes(frame[12:14], "big") == ETHERTYPE:
        return True, "ethertype"
    if session:
        i = frame.find(MAGIC)
        while i != -1:
            if frame[i + 6:i + 14] == session:
                return True, "payload"
            i = frame.find(MAGIC, i + 1)
    return False, ""


#: How often a sniffer that hears nothing looks for the stop file.
STOP_POLL_S = 0.5


def sniff(host, seconds, session, stop_file=None, sock=None):
    """Count frames for at most `seconds`; return the JSON-able summary.

    Ends at the FIRST heartbeat frame -- ruling 4 needs one, not a count, and every further round
    the heartbeat sends into a pipeline that forwards it to hosts is another one delivered -- or
    as soon as `stop_file` exists (the census writes it when any host has one), or at the
    deadline. `sock` is the offline self-test's seam; the real run opens the packet socket.
    """
    out = {"host": host, "seconds": seconds, "frames_total": 0, "frames_hb": 0,
           "by_ethertype": 0, "by_payload": 0, "interfaces": {}, "first_hb_hex": None,
           "stopped": "time"}
    s = sock
    if s is None:
        try:
            s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
        except OSError as exc:
            out["error"] = f"cannot open a packet socket: {exc}"
            return out
    s.setblocking(False)
    end = time.monotonic() + seconds
    try:
        while True:
            if stop_file and os.path.exists(stop_file):
                out["stopped"] = "stop file"
                break
            left = end - time.monotonic()
            if left <= 0:
                break
            r, _, _ = select.select([s], [], [], min(left, STOP_POLL_S))
            if not r:
                continue
            hit = False
            while True:
                try:
                    frame, addr = s.recvfrom(65535)
                except BlockingIOError:
                    break
                ifname = addr[0]
                if ifname == "lo":
                    continue
                out["frames_total"] += 1
                box = out["interfaces"].setdefault(ifname, {"frames": 0, "hb": 0})
                box["frames"] += 1
                is_hb, how = classify(frame, session)
                if is_hb:
                    out["frames_hb"] += 1
                    box["hb"] += 1
                    out["by_" + how] += 1
                    out["first_hb_hex"] = frame[:64].hex()
                    hit = True
                    break
            if hit:
                out["stopped"] = "first heartbeat frame"
                break
    finally:
        s.close()
    return out


def self_test():
    rc = 0
    sess = bytes.fromhex("0102030405060708")
    hb = b"\x02NDTHB" + b"\x02\x00\x00\x00\x00\x65" + b"\x88\xb5" + MAGIC + b"\x01\x00" + sess
    ip = b"\xff" * 6 + b"\x02" * 6 + b"\x08\x00" + b"\x45" + b"\x00" * 40
    tunnelled = b"\xff" * 6 + b"\x02" * 6 + b"\x12\x12" + b"\x08\x00\x00\x02" + hb[14:]
    for label, frame, want in (("a heartbeat by ethertype", hb, (True, "ethertype")),
                               ("an IPv4 frame is not", ip, (False, "")),
                               ("a rewritten one is found by its payload", tunnelled, (True, "payload")),
                               ("another session's payload under another type is not",
                                tunnelled.replace(sess, b"\xff" * 8), (False, ""))):
        got = classify(frame, sess)
        ok = got == want
        rc |= 0 if ok else 1
        print(f"  {'ok' if ok else '🔴'}    {label:55s} {got}")

    # 🔴 THE FIRST HIT ENDS THE WINDOW (judge #11, round 2), and so does the stop file the census
    # writes when ANY host has one. A socketpair stands in for the packet socket.
    class Fake:
        def __init__(self):
            self.a, self.b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        def fileno(self):
            return self.a.fileno()
        def setblocking(self, flag):
            self.a.setblocking(flag)
        def recvfrom(self, n):
            return self.a.recv(n), ("h1-eth0", ETH_P_ALL, 0, 1, b"")
        def close(self):
            self.a.close()
            self.b.close()
    fake = Fake()
    fake.b.send(ip)
    fake.b.send(hb)
    t0 = time.monotonic()
    try:
        out = sniff("h1", 10, sess, sock=fake)
    except TypeError as exc:
        out = {"error": f"no seam: {exc}"}
    took = time.monotonic() - t0
    ok = out.get("frames_hb") == 1 and out.get("stopped") == "first heartbeat frame" and took < 3
    rc |= 0 if ok else 1
    print(f"  {'ok' if ok else '🔴'}    {'the first heartbeat frame ends the sniff at once':55s} "
          f"{out.get('stopped', out.get('error'))} after {took:.1f} s")
    stopdir = tempfile.mkdtemp(prefix="hb-sniff-selftest-")
    try:
        stop = os.path.join(stopdir, "stop")
        open(stop, "w").close()
        t0 = time.monotonic()
        try:
            out = sniff("h1", 10, sess, stop_file=stop, sock=Fake())
        except TypeError as exc:
            out = {"error": f"no seam: {exc}"}
        took = time.monotonic() - t0
    finally:
        shutil.rmtree(stopdir, ignore_errors=True)
    ok = out.get("stopped") == "stop file" and out.get("frames_hb") == 0 and took < 3
    rc |= 0 if ok else 1
    print(f"  {'ok' if ok else '🔴'}    {'the stop file ends a quiet sniff at once':55s} "
          f"{out.get('stopped', out.get('error'))} after {took:.1f} s")
    print("SELF-TEST PASS" if rc == 0 else "SELF-TEST FAIL")
    return rc


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    host, seconds, session_hex = argv[1], float(argv[2]), argv[3]
    stop_file = argv[4] if len(argv) == 5 else None
    if not 0 < seconds <= 600:
        print("seconds must be in (0, 600]", file=sys.stderr)
        return 2
    session = bytes.fromhex(session_hex) if session_hex else b""
    print(json.dumps(sniff(host, seconds, session, stop_file=stop_file)), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
