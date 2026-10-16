"""
proxy_agent/bm_thrift.py -- the two bmv2 thrift register reads, on the wire.

[Co-developed with claude code -- Adam]

The client is written out by hand from bmv2's generated code (bm_runtime/standard/Standard.py),
so what it puts on the wire is pinned here byte for byte: the expected bytes below were produced
by that generated client (Standard.Client.send_bm_register_read / send_bm_register_read_all,
Thrift 0.16.0 code, TBinaryProtocol, multiplexed under "standard") on 2026-10-16 and checked
equal to this module's (LOG/r3B-evidence/wire_bytes_vs_generated.log). The answers are decoded
from bytes written the same way. A real socket covers the deadline: a server that accepts and
never answers must cost one timeout, not forever.

Run with:  p4_proxy/venv/bin/python -m unittest tests.test_bm_thrift
"""

from __future__ import annotations

import os
import socket
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    from thrift.Thrift import TMessageType, TType
    from thrift.protocol import TBinaryProtocol
    from thrift.transport import TTransport

    HAVE_THRIFT = True
except ImportError:  # pragma: no cover -- the interpreter has no thrift: an environment, not a defect
    HAVE_THRIFT = False

if HAVE_THRIFT:
    # Not guarded: with thrift present, a missing or broken bm_thrift is a failure, not a skip.
    from proxy_agent import bm_thrift as B

#: Standard.Client(...).send_bm_register_read(0, "HcIngress.r_mark", 3), multiplexed "standard".
READ_3 = bytes.fromhex(
    "80010001000000197374616e646172643a626d5f72656769737465725f7265616400000000080001000000000b"
    "0002000000104863496e67726573732e725f6d61726b0800030000000300")
#: Standard.Client(...).send_bm_register_read_all(0, "HcIngress.r_mark").
READ_ALL = bytes.fromhex(
    "800100010000001d7374616e646172643a626d5f72656769737465725f726561645f616c6c0000000008000100"
    "0000000b0002000000104863496e67726573732e725f6d61726b00")


class Pipe(TTransport.TTransportBase if HAVE_THRIFT else object):
    """A transport whose reads come from `answer` and whose writes are kept."""

    def __init__(self, answer=b""):
        self.inbuf = TTransport.TMemoryBuffer(answer)
        self.written = b""
        self._pending = b""

    def isOpen(self):
        return True

    def read(self, sz):
        data = self.inbuf.read(sz)
        if not data:
            raise EOFError("no more bytes")
        return data

    def readAll(self, sz):
        out = b""
        while len(out) < sz:
            out += self.read(sz - len(out))
        return out

    def write(self, buf):
        self._pending += buf

    def flush(self):
        self.written += self._pending
        self._pending = b""


def reply(name, write_body, mtype=None):
    buf = TTransport.TMemoryBuffer()
    p = TBinaryProtocol.TBinaryProtocol(buf)
    p.writeMessageBegin(name, TMessageType.REPLY if mtype is None else mtype, 0)
    p.writeStructBegin("result")
    write_body(p)
    p.writeFieldStop()
    p.writeStructEnd()
    p.writeMessageEnd()
    return buf.getvalue()


def success_i64(v):
    def body(p):
        p.writeFieldBegin("success", TType.I64, 0)
        p.writeI64(v)
        p.writeFieldEnd()
    return body


def success_list(vs):
    def body(p):
        p.writeFieldBegin("success", TType.LIST, 0)
        p.writeListBegin(TType.I64, len(vs))
        for v in vs:
            p.writeI64(v)
        p.writeListEnd()
        p.writeFieldEnd()
    return body


def ouch(code):
    def body(p):
        p.writeFieldBegin("ouch", TType.STRUCT, 1)
        p.writeStructBegin("InvalidRegisterOperation")
        p.writeFieldBegin("code", TType.I32, 1)
        p.writeI32(code)
        p.writeFieldEnd()
        p.writeFieldStop()
        p.writeStructEnd()
        p.writeFieldEnd()
    return body


@unittest.skipUnless(HAVE_THRIFT, "thrift is not installed in this interpreter")
class OnTheWireTest(unittest.TestCase):
    def test_one_cell_is_the_generated_clients_bytes(self):
        pipe = Pipe(reply("bm_register_read", success_i64(4737)))
        self.assertEqual(B.call(pipe, "bm_register_read", "HcIngress.r_mark", 3), 4737)
        self.assertEqual(pipe.written, READ_3)

    def test_the_whole_array_is_the_generated_clients_bytes(self):
        pipe = Pipe(reply("bm_register_read_all", success_list([4737, 0, 7])))
        self.assertEqual(B.call(pipe, "bm_register_read_all", "HcIngress.r_mark"), [4737, 0, 7])
        self.assertEqual(pipe.written, READ_ALL)

    def test_a_negative_i64_is_passed_on_as_bmv2_sent_it(self):
        pipe = Pipe(reply("bm_register_read", success_i64(-1)))
        self.assertEqual(B.call(pipe, "bm_register_read", "HcIngress.r_mark", 0), -1)

    def test_a_zero_is_a_zero_and_not_a_missing_result(self):
        pipe = Pipe(reply("bm_register_read", success_i64(0)))
        self.assertEqual(B.call(pipe, "bm_register_read", "HcIngress.r_mark", 0), 0)

    def test_an_empty_array_is_an_empty_list(self):
        pipe = Pipe(reply("bm_register_read_all", success_list([])))
        self.assertEqual(B.call(pipe, "bm_register_read_all", "HcIngress.r_mark"), [])

    def test_bmv2s_refusal_carries_its_code(self):
        pipe = Pipe(reply("bm_register_read", ouch(B.INVALID_INDEX)))
        with self.assertRaises(B.RegisterReadRefused) as caught:
            B.call(pipe, "bm_register_read", "HcIngress.r_mark", 99)
        self.assertEqual(caught.exception.code, B.INVALID_INDEX)

    def test_no_result_at_all_is_invalid_not_a_zero(self):
        pipe = Pipe(reply("bm_register_read", lambda p: None))
        with self.assertRaises(B.ThriftAnswerInvalid):
            B.call(pipe, "bm_register_read", "HcIngress.r_mark", 0)

    def test_an_answer_to_another_call_is_invalid(self):
        pipe = Pipe(reply("bm_counter_read", success_i64(5)))
        with self.assertRaises(B.ThriftAnswerInvalid):
            B.call(pipe, "bm_register_read", "HcIngress.r_mark", 0)

    def test_an_application_exception_is_invalid(self):
        def body(p):
            p.writeFieldBegin("message", TType.STRING, 1)
            p.writeString("Invalid method name")
            p.writeFieldEnd()
        pipe = Pipe(reply("bm_register_read", body, mtype=TMessageType.EXCEPTION))
        with self.assertRaises(B.ThriftAnswerInvalid):
            B.call(pipe, "bm_register_read", "HcIngress.r_mark", 0)

    def test_a_list_of_another_type_is_invalid(self):
        def body(p):
            p.writeFieldBegin("success", TType.LIST, 0)
            p.writeListBegin(TType.I32, 1)
            p.writeI32(1)
            p.writeListEnd()
            p.writeFieldEnd()
        pipe = Pipe(reply("bm_register_read_all", body))
        with self.assertRaises(B.ThriftAnswerInvalid):
            B.call(pipe, "bm_register_read_all", "HcIngress.r_mark")

    def test_an_answer_cut_short_is_unreachable(self):
        whole = reply("bm_register_read", success_i64(4737))
        with self.assertRaises(B.ThriftUnreachable):
            B.call(Pipe(whole[:-6]), "bm_register_read", "HcIngress.r_mark", 0)


@unittest.skipUnless(HAVE_THRIFT, "thrift is not installed in this interpreter")
class ARealSocketTest(unittest.TestCase):
    """127.0.0.1 on a port the kernel picks; nothing of the lab's is touched."""

    def serve(self, handler):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        self.addCleanup(srv.close)
        stop = threading.Event()
        self.addCleanup(stop.set)

        def run():
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            with conn:
                handler(conn, stop)
        threading.Thread(target=run, daemon=True).start()
        return srv.getsockname()[1]

    def test_a_server_that_never_answers_costs_one_deadline(self):
        port = self.serve(lambda conn, stop: stop.wait(10))
        t0 = time.monotonic()
        with self.assertRaises(B.ThriftUnreachable):
            B.read_register("127.0.0.1", port, "HcIngress.r_mark", 0, timeout_s=0.5)
        self.assertLess(time.monotonic() - t0, 3.0)

    def test_nothing_listening_is_unreachable(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        with self.assertRaises(B.ThriftUnreachable):
            B.read_register("127.0.0.1", port, "HcIngress.r_mark", 0, timeout_s=0.5)

    def test_one_read_over_a_real_connection(self):
        answer = reply("bm_register_read", success_i64(4737))
        got = {}

        def handler(conn, stop):
            got["request"] = conn.recv(4096)
            conn.sendall(answer)
        port = self.serve(handler)
        self.assertEqual(B.read_register("127.0.0.1", port, "HcIngress.r_mark", 3, timeout_s=2), 4737)
        self.assertEqual(got["request"], READ_3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
