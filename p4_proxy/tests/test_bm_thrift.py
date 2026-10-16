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
import subprocess
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
#: Standard.Client(...).send_bm_mgmt_get_info() (LOG/r4-evidence/wire_bytes_r2.log).
GET_INFO = bytes.fromhex(
    "80010001000000197374616e646172643a626d5f6d676d745f6765745f696e666f0000000000")
#: Standard.bm_mgmt_get_info_result(success=BmConfig(device_id=7, thrift_port=9097,
#: notifications_socket="ipc://x")) as the generated server code writes it (the same log).
GET_INFO_REPLY = bytes.fromhex(
    "8001000200000010626d5f6d676d745f6765745f696e666f000000000c00000a00010000000000000007080002000023"
    "890b0003000000076970633a2f2f780000")
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

    def test_the_identity_call_is_the_generated_clients_bytes_and_its_answer_is_read(self):
        pipe = Pipe(GET_INFO_REPLY)
        self.assertEqual(B.call(pipe, "bm_mgmt_get_info"), {"device_id": 7, "thrift_port": 9097})
        self.assertEqual(pipe.written, GET_INFO)

    def test_the_checked_read_asks_who_the_switch_is_first_on_the_same_connection(self):
        # (round 3) bm_mgmt_get_info, then the read, in that order, on one transport.
        pipe = Pipe(GET_INFO_REPLY + reply("bm_register_read", success_i64(4737)))
        self.assertEqual(B.checked_read(pipe, "HcIngress.r_mark", 3, (7, 9097)), 4737)
        self.assertEqual(pipe.written, GET_INFO + READ_3)

    def test_the_checked_read_sends_no_register_read_to_another_switch(self):
        for expected in ((8, 9097), (7, 9098)):
            with self.subTest(expected=expected):
                pipe = Pipe(GET_INFO_REPLY)
                with self.assertRaises(B.ThriftDeviceMismatch):
                    B.checked_read(pipe, "HcIngress.r_mark", 3, expected)
                self.assertEqual(pipe.written, GET_INFO, "only the identity was asked")

    def test_the_checked_whole_array_read_is_the_generated_clients_bytes(self):
        pipe = Pipe(GET_INFO_REPLY + reply("bm_register_read_all", success_list([1, 2])))
        self.assertEqual(B.checked_read(pipe, "HcIngress.r_mark", None, (7, 9097)), [1, 2])
        self.assertEqual(pipe.written, GET_INFO + READ_ALL)

    def test_a_version_that_is_not_thrifts_is_not_understood(self):
        # 0x8002...: the strict-version marker with the wrong version -> TProtocolException.
        with self.assertRaises(B.ThriftAnswerNotUnderstood):
            B.call(Pipe(bytes.fromhex("80020002") + b"\0" * 32), "bm_register_read", "HcIngress.r_mark", 0)

    def test_a_method_name_that_is_not_utf8_is_not_understood(self):
        answer = bytes.fromhex("80010002") + (2).to_bytes(4, "big") + b"\xff\xfe" + b"\0" * 16
        with self.assertRaises(B.ThriftAnswerNotUnderstood):
            B.call(Pipe(answer), "bm_register_read", "HcIngress.r_mark", 0)

    def test_a_negative_list_size_is_not_understood_and_not_unreachable(self):
        def body(p):
            p.writeFieldBegin("success", TType.LIST, 0)
            p.trans.write(bytes([TType.I64]) + (-1).to_bytes(4, "big", signed=True))
        pipe = Pipe(reply("bm_register_read_all", body))
        with self.assertRaises(B.ThriftAnswerNotUnderstood):
            B.call(pipe, "bm_register_read_all", "HcIngress.r_mark")

    def test_an_index_that_does_not_fit_an_i32_is_not_understood(self):
        with self.assertRaises(B.ThriftAnswerNotUnderstood):
            B.call(Pipe(b""), "bm_register_read", "HcIngress.r_mark", 2 ** 31)

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

    def test_a_peer_trickling_a_byte_every_2_s_is_cut_at_the_calls_deadline(self):
        # Each byte arrives inside the 3 s budget's per-receive share, so only a deadline for the
        # WHOLE call stops it: before round 2 every receive got a fresh 3 s.
        answer = reply("bm_register_read", success_i64(4737))

        def handler(conn, stop):
            conn.recv(4096)
            for b in answer:
                if stop.wait(2):
                    return
                try:
                    conn.sendall(bytes([b]))
                except OSError:
                    return
        port = self.serve(handler)
        t0 = time.monotonic()
        with self.assertRaises(B.ThriftUnreachable):
            B.read_register("127.0.0.1", port, "HcIngress.r_mark", 3, timeout_s=3)
        took = time.monotonic() - t0
        self.assertLess(took, 4.5, "the call outlived its 3 s budget")
        self.assertGreater(took, 2.5)

    def test_a_peer_that_is_not_thrift_ends_inside_the_deadline_never_as_a_crash(self):
        def handler(conn, stop):
            conn.recv(4096)
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            stop.wait(10)
        port = self.serve(handler)
        t0 = time.monotonic()
        with self.assertRaises((B.ThriftUnreachable, B.ThriftAnswerNotUnderstood)):
            B.read_register("127.0.0.1", port, "HcIngress.r_mark", 3, timeout_s=1.5)
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


class WithoutThriftTest(unittest.TestCase):
    """The proxy must start without the `thrift` package; only GET /p4/register is then refused.
    Run in a fresh interpreter in which `import thrift` fails."""

    def test_the_proxy_imports_and_the_call_says_thrift_is_not_installed(self):
        code = (
            "import sys; sys.modules['thrift'] = None\n"
            "from proxy_agent import bm_thrift\n"
            "try:\n"
            "    from proxy_agent import api_routes  # noqa\n"
            "    routes = 'imported'\n"
            "except ImportError as e:\n"
            "    routes = 'needs ' + str(e)\n"
            "try:\n"
            "    bm_thrift.read_register('127.0.0.1', 1, 'x', 0, 0.1)\n"
            "    print('NO REFUSAL', routes)\n"
            "except bm_thrift.ThriftNotInstalled:\n"
            "    print('ThriftNotInstalled', routes)\n")
        env = dict(os.environ, PYTHONPATH=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."),
                   PYTHONDONTWRITEBYTECODE="1")
        res = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(res.returncode, 0, res.stderr[-2000:])
        out = res.stdout.strip()
        self.assertTrue(out.startswith("ThriftNotInstalled"), out)
        # api_routes needs fastapi and the P4Runtime protobufs, which this interpreter may lack; when
        # they are there it must import without thrift.
        if HAVE_DEPS:
            self.assertTrue(out.endswith("imported"), out)


try:
    import fastapi  # noqa: F401
    from p4.v1 import p4runtime_pb2  # noqa: F401
    HAVE_DEPS = True
except ImportError:  # pragma: no cover
    HAVE_DEPS = False


if __name__ == "__main__":
    unittest.main(verbosity=2)
