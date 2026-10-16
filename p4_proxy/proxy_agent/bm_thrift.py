"""
bmv2's thrift service, for GET /p4/register: two register reads and the switch's identity. Nothing else.

[Co-developed with claude code -- Adam]

Why thrift at all: bmv2's P4Runtime answers every RegisterEntry read UNIMPLEMENTED ("Register reads
are not supported yet"), and the PI installed with it has no register support in any layer
(doc/audit/2026-10-16_p4-register-read/DESIGN.md sections 1 and 5). bmv2's own thrift service
`standard` does have them, and simple_switch_CLI's `register_read` is that service.

Why a client written here and not bmv2's generated `bm_runtime` package: that package lives in
another virtualenv (p4dev-python-venv, built for a different interpreter -- the version trap
p4_proxy/requirements.txt describes), and vendoring it would bring 18 000 generated lines for three
calls. The wire format of the three calls is small and fixed, and it is written out below field by
field from the generated code (bm_runtime/standard/Standard.py and ttypes.py, Thrift 0.16.0):

    i64       bm_register_read(1: i32 cxt_id, 2: string register_array_name, 3: i32 idx)
    list<i64> bm_register_read_all(1: i32 cxt_id, 2: string register_array_name)
        throws (1: InvalidRegisterOperation ouch)       InvalidRegisterOperation {1: i32 code}
    BmConfig  bm_mgmt_get_info()                        BmConfig {1: i64 device_id, 2: i32 thrift_port, ...}

on TBinaryProtocol over a buffered socket, multiplexed under the service name "standard" (what
bmpy_utils.thrift_connect does).

READ ONLY. There is no write here. Measured (DESIGN-thrift.md section 0): a CLI `table_add` leaves
P4Runtime's view of a switch "out-of-sync with target"; thrift register reads, CLI register reads,
a CLI register write and a CLI counter read did not.

THE `thrift` PACKAGE IS IMPORTED ONLY WHEN A CALL IS MADE. A proxy whose interpreter lacks it starts
and serves everything else; only GET /p4/register answers 503 "thrift not installed"
(ThriftNotInstalled below).

Every read opens its own connection and closes it: no state is shared between the threads that
GET /p4/register runs on, and nothing is remembered between reads -- the route's read
(read_register_as) asks the switch who it is on that same connection, every time. Its deadline is
for the WHOLE connection -- connect, send and every receive of both calls share one budget -- so a
peer that trickles a byte at a time cannot hold a worker past it.
"""

from __future__ import annotations

import struct
import time

SERVICE = "standard"
#: bmv2's RegisterOperationErrorCode.
INVALID_REGISTER_NAME = 1
INVALID_INDEX = 2
ERROR = 3
ERROR_NAMES = {INVALID_REGISTER_NAME: "INVALID_REGISTER_NAME", INVALID_INDEX: "INVALID_INDEX",
               ERROR: "ERROR"}


class ThriftNotInstalled(RuntimeError):
    """The interpreter has no `thrift` package, so no thrift call can be made."""


class ThriftUnreachable(RuntimeError):
    """No answer: the connection could not be made, broke, or ran past its deadline."""


class RegisterReadRefused(RuntimeError):
    """bmv2 answered with InvalidRegisterOperation. `code` is its RegisterOperationErrorCode."""

    def __init__(self, code):
        super().__init__("bmv2 refused the register read: %s"
                         % ERROR_NAMES.get(code, "code %s" % code))
        self.code = code


class ThriftAnswerInvalid(RuntimeError):
    """bmv2 answered, but not with what these calls return (an application exception, a missing
    result, a field of the wrong type, an answer to another call)."""


class ThriftAnswerNotUnderstood(ThriftAnswerInvalid):
    """Something answered, and its bytes could not be decoded as thrift at all: a protocol error,
    a string that is not UTF-8, a negative or oversized length, a value that does not fit. Not a
    lost answer -- a peer that is not (this) bmv2's thrift service."""


def _thrift():
    """The thrift modules, imported on first use. ThriftNotInstalled when they cannot be."""
    try:
        from thrift.Thrift import TApplicationException, TMessageType, TType
        from thrift.protocol import TBinaryProtocol, TMultiplexedProtocol
        from thrift.protocol.TProtocol import TProtocolException
        from thrift.transport import TSocket, TTransport
    except ImportError as exc:
        raise ThriftNotInstalled("the `thrift` package is not installed in the proxy's "
                                 "interpreter: %s" % exc) from exc
    return TApplicationException, TMessageType, TType, TBinaryProtocol, TMultiplexedProtocol, \
        TProtocolException, TSocket, TTransport


def _write_args(proto, name, register, index):
    _A, TMessageType, TType = _thrift()[:3]
    proto.writeMessageBegin(name, TMessageType.CALL, 0)
    proto.writeStructBegin(name + "_args")
    if register is not None:
        proto.writeFieldBegin("cxt_id", TType.I32, 1)
        proto.writeI32(0)
        proto.writeFieldEnd()
        proto.writeFieldBegin("register_array_name", TType.STRING, 2)
        proto.writeString(register)
        proto.writeFieldEnd()
    if index is not None:
        proto.writeFieldBegin("idx", TType.I32, 3)
        proto.writeI32(index)
        proto.writeFieldEnd()
    proto.writeFieldStop()
    proto.writeStructEnd()
    proto.writeMessageEnd()


def _read_struct(proto, fields):
    """Read one struct; `fields` maps a field id to (type, reader). Others are skipped."""
    TType = _thrift()[2]
    out = {}
    proto.readStructBegin()
    while True:
        _n, ftype, fid = proto.readFieldBegin()
        if ftype == TType.STOP:
            break
        want = fields.get(fid)
        if want is not None and ftype == want[0]:
            out[fid] = want[1](proto)
        else:
            proto.skip(ftype)
        proto.readFieldEnd()
    proto.readStructEnd()
    return out


def _read_i64_list(proto, name):
    TType = _thrift()[2]
    etype, size = proto.readListBegin()
    if etype != TType.I64:
        raise ThriftAnswerInvalid("%s answered a list of type %s, not i64" % (name, etype))
    values = [proto.readI64() for _ in range(size)]
    proto.readListEnd()
    return values


def _read_bm_config(proto):
    TType = _thrift()[2]
    got = _read_struct(proto, {1: (TType.I64, lambda p: p.readI64()),
                               2: (TType.I32, lambda p: p.readI32())})
    return {"device_id": got.get(1), "thrift_port": got.get(2)}


def _read_result(proto, name, success_type, success_reader):
    TApplicationException, TMessageType, TType = _thrift()[:3]
    rname, mtype, _seq = proto.readMessageBegin()
    if mtype == TMessageType.EXCEPTION:
        exc = TApplicationException()
        exc.read(proto)
        proto.readMessageEnd()
        raise ThriftAnswerInvalid("bmv2 answered %s with an application exception: %s"
                                  % (name, exc))
    if rname != name or mtype != TMessageType.REPLY:
        raise ThriftAnswerInvalid("bmv2 answered %r (type %s) to %s" % (rname, mtype, name))
    got = _read_struct(proto, {0: (success_type, success_reader),
                               1: (TType.STRUCT, lambda p: _read_struct(
                                   p, {1: (TType.I32, lambda q: q.readI32())}).get(1))})
    proto.readMessageEnd()
    if 1 in got:
        raise RegisterReadRefused(got[1])
    if 0 not in got:
        raise ThriftAnswerInvalid("%s answered with no result" % name)
    return got[0]


def call(transport, name, register=None, index=None):
    """One call on an OPEN transport.

    `bm_register_read` (with `index`, returns an int), `bm_register_read_all` (returns a list) or
    `bm_mgmt_get_info` (no register, returns {"device_id", "thrift_port"}). Raises the errors above:
    a transport failure is ThriftUnreachable; bytes that cannot be decoded, a negative or oversized
    length included, are ThriftAnswerNotUnderstood."""
    (_A, _M, TType, TBinaryProtocol, TMultiplexedProtocol, TProtocolException, _S,
     TTransport) = _thrift()
    proto = TMultiplexedProtocol.TMultiplexedProtocol(
        TBinaryProtocol.TBinaryProtocol(transport), SERVICE)
    if name == "bm_mgmt_get_info":
        kind = (TType.STRUCT, _read_bm_config)
    elif index is not None:
        kind = (TType.I64, lambda p: p.readI64())
    else:
        kind = (TType.LIST, lambda p: _read_i64_list(p, name))
    try:
        _write_args(proto, name, register, index)
        transport.flush()
        return _read_result(proto, name, *kind)
    except TTransport.TTransportException as exc:
        if exc.type in (TTransport.TTransportException.NEGATIVE_SIZE,
                        TTransport.TTransportException.SIZE_LIMIT):
            raise ThriftAnswerNotUnderstood("the answer to %s carried a length that is not one: "
                                            "%s" % (name, exc)) from exc
        raise ThriftUnreachable("the thrift call %s(%s) did not complete: %s"
                                % (name, register, exc)) from exc
    except (OSError, EOFError) as exc:
        raise ThriftUnreachable("the thrift call %s(%s) did not complete: %s"
                                % (name, register, exc)) from exc
    except (TProtocolException, UnicodeDecodeError, struct.error, ValueError, OverflowError) as exc:
        raise ThriftAnswerNotUnderstood("the answer to %s could not be decoded as thrift: %s: %s"
                                        % (name, type(exc).__name__, exc)) from exc


def _deadline_socket(host, port, deadline):
    """A TSocket whose every connect and receive is bounded by what is left of ONE budget."""
    TSocket, TTransport = _thrift()[6:8]

    class DeadlineSocket(TSocket.TSocket):
        def _left(self):
            left = deadline - time.monotonic()
            if left <= 0:
                raise TTransport.TTransportException(TTransport.TTransportException.TIMED_OUT,
                                                     "the call's deadline has passed")
            return left

        def open(self):
            self.setTimeout(self._left() * 1000)
            return super().open()

        def read(self, sz):
            if self.handle is not None:
                self.handle.settimeout(self._left())
            return super().read(sz)

        def write(self, buff):
            if self.handle is not None:
                self.handle.settimeout(self._left())
            return super().write(buff)

    return DeadlineSocket(host, port)


def _open(host, port, timeout_s):
    """An open buffered transport whose every step shares one `timeout_s` budget."""
    TTransport = _thrift()[7]
    transport = TTransport.TBufferedTransport(_deadline_socket(host, port,
                                                               time.monotonic() + timeout_s))
    try:
        transport.open()
    except (TTransport.TTransportException, OSError) as exc:
        raise ThriftUnreachable("no thrift connection to %s:%s: %s" % (host, port, exc)) from exc
    return transport


def _one_call(host, port, name, register, index, timeout_s):
    transport = _open(host, port, timeout_s)
    try:
        return call(transport, name, register, index)
    finally:
        transport.close()


def read_register(host, port, register, index=None, timeout_s=5.0):
    """bmv2's value of `register[index]` (an int, as bmv2's i64 carries it), or with `index` None
    the whole array (a list). One connection, every step of it inside one `timeout_s` budget.
    Asks nobody who the switch is: GET /p4/register uses read_register_as."""
    if index is None:
        return _one_call(host, port, "bm_register_read_all", register, None, timeout_s)
    return _one_call(host, port, "bm_register_read", register, index, timeout_s)


def device_info(host, port, timeout_s=5.0):
    """{"device_id", "thrift_port"} of the bmv2 listening on `port` (bm_mgmt_get_info): which
    switch this thrift port actually is."""
    return _one_call(host, port, "bm_mgmt_get_info", None, None, timeout_s)


class ThriftDeviceMismatch(RuntimeError):
    """The thrift port answers as another switch: bm_mgmt_get_info's (device id, thrift port) is
    not the one asked for. Nothing was read."""

    def __init__(self, found, expected):
        super().__init__("thrift port %s answers as device %s on port %s, not as device %s"
                         % (expected[1], found.get("device_id"), found.get("thrift_port"),
                            expected[0]))
        self.found, self.expected = found, expected


def read_register_as(host, port, register, index, expected, timeout_s=5.0):
    """read_register, but only from the switch `expected` = (device id, thrift port) names.

    [Co-developed with claude code -- Adam]
    On ONE connection: bm_mgmt_get_info first, then -- only when it answers `expected` -- the
    register read. The identity is asked on every read, never remembered, so a process that
    replaced the switch since the last read is caught (a remembered answer was the round-2 hole:
    a replaced process got 200 until the next readopt). Raises ThriftDeviceMismatch, and sends no
    register read, when the answer is another switch's. One `timeout_s` budget for both calls."""
    transport = _open(host, port, timeout_s)
    try:
        return checked_read(transport, register, index, expected)
    finally:
        transport.close()


def checked_read(transport, register, index, expected):
    """read_register_as's two calls on an OPEN transport: the identity, then -- only if it is
    `expected` -- the register read."""
    found = call(transport, "bm_mgmt_get_info")
    if (found.get("device_id"), found.get("thrift_port")) != tuple(expected):
        raise ThriftDeviceMismatch(found, tuple(expected))
    if index is None:
        return call(transport, "bm_register_read_all", register)
    return call(transport, "bm_register_read", register, index)
