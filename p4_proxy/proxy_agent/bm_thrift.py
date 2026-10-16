"""
bmv2's thrift register reads: the two RPCs GET /p4/register needs, and nothing else.

[Co-developed with claude code -- Adam]

Why thrift at all: bmv2's P4Runtime answers every RegisterEntry read UNIMPLEMENTED ("Register reads
are not supported yet"), and the PI installed with it has no register support in any layer
(doc/audit/2026-10-16_p4-register-read/DESIGN.md sections 1 and 5). bmv2's own thrift service
`standard` does have them, and simple_switch_CLI's `register_read` is that service.

Why a client written here and not bmv2's generated `bm_runtime` package: that package lives in
another virtualenv (p4dev-python-venv, built for a different interpreter -- the version trap
p4_proxy/requirements.txt describes), and vendoring it would bring 18 000 generated lines for two
calls. The wire format of the two calls is small and fixed, and it is written out below field by
field from the generated code (bm_runtime/standard/Standard.py, Thrift 0.16.0):

    i64       bm_register_read(1: i32 cxt_id, 2: string register_array_name, 3: i32 idx)
    list<i64> bm_register_read_all(1: i32 cxt_id, 2: string register_array_name)
        throws (1: InvalidRegisterOperation ouch)       InvalidRegisterOperation {1: i32 code}

on TBinaryProtocol over a buffered socket, multiplexed under the service name "standard" (what
bmpy_utils.thrift_connect does). The only dependency is the `thrift` package the venv pins.

READ ONLY. There is no write here: a write through bmv2's CLI is what leaves P4Runtime's view of
a switch "out-of-sync with target", and a register read was measured not to
(DESIGN-thrift.md, the sync probe).

Every call opens its own connection, with a socket timeout (connect and every receive), and
closes it: no state is shared between the threads that GET /p4/register runs on.
"""

from __future__ import annotations

from thrift.Thrift import TApplicationException, TMessageType, TType
from thrift.protocol import TBinaryProtocol, TMultiplexedProtocol
from thrift.transport import TSocket, TTransport

SERVICE = "standard"
#: bmv2's RegisterOperationErrorCode.
INVALID_REGISTER_NAME = 1
INVALID_INDEX = 2
ERROR = 3
ERROR_NAMES = {INVALID_REGISTER_NAME: "INVALID_REGISTER_NAME", INVALID_INDEX: "INVALID_INDEX",
               ERROR: "ERROR"}


class ThriftUnreachable(RuntimeError):
    """No answer: the connection could not be made, broke, or ran past its deadline."""


class RegisterReadRefused(RuntimeError):
    """bmv2 answered with InvalidRegisterOperation. `code` is its RegisterOperationErrorCode."""

    def __init__(self, code):
        super().__init__("bmv2 refused the register read: %s"
                         % ERROR_NAMES.get(code, "code %s" % code))
        self.code = code


class ThriftAnswerInvalid(RuntimeError):
    """bmv2 answered, but not with what these two calls return (an application exception, a
    missing result, a field of the wrong type)."""


def _write_args(proto, name, register, index):
    proto.writeMessageBegin(name, TMessageType.CALL, 0)
    proto.writeStructBegin(name + "_args")
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


def _read_ouch(proto):
    code = None
    proto.readStructBegin()
    while True:
        _n, ftype, fid = proto.readFieldBegin()
        if ftype == TType.STOP:
            break
        if fid == 1 and ftype == TType.I32:
            code = proto.readI32()
        else:
            proto.skip(ftype)
        proto.readFieldEnd()
    proto.readStructEnd()
    return code


def _read_result(proto, name, success_type):
    rname, mtype, _seq = proto.readMessageBegin()
    if mtype == TMessageType.EXCEPTION:
        exc = TApplicationException()
        exc.read(proto)
        proto.readMessageEnd()
        raise ThriftAnswerInvalid("bmv2 answered %s with an application exception: %s"
                                  % (name, exc))
    if rname != name or mtype != TMessageType.REPLY:
        raise ThriftAnswerInvalid("bmv2 answered %r (type %s) to %s" % (rname, mtype, name))
    success = ouch = None
    have_success = False
    proto.readStructBegin()
    while True:
        _n, ftype, fid = proto.readFieldBegin()
        if ftype == TType.STOP:
            break
        if fid == 0 and ftype == success_type == TType.I64:
            success, have_success = proto.readI64(), True
        elif fid == 0 and ftype == success_type == TType.LIST:
            etype, size = proto.readListBegin()
            if etype != TType.I64:
                raise ThriftAnswerInvalid("%s answered a list of type %s, not i64" % (name, etype))
            success, have_success = [proto.readI64() for _ in range(size)], True
            proto.readListEnd()
        elif fid == 1 and ftype == TType.STRUCT:
            ouch = _read_ouch(proto)
        else:
            proto.skip(ftype)
        proto.readFieldEnd()
    proto.readStructEnd()
    proto.readMessageEnd()
    if ouch is not None:
        raise RegisterReadRefused(ouch)
    if not have_success:
        raise ThriftAnswerInvalid("%s answered with no result" % name)
    return success


def call(transport, name, register, index=None):
    """One call on an OPEN transport: bm_register_read when `index` is given (returns an int),
    else bm_register_read_all (returns a list). Raises the three errors above; a transport
    failure surfaces as ThriftUnreachable."""
    proto = TMultiplexedProtocol.TMultiplexedProtocol(
        TBinaryProtocol.TBinaryProtocol(transport), SERVICE)
    try:
        _write_args(proto, name, register, index)
        transport.flush()
        return _read_result(proto, name, TType.I64 if index is not None else TType.LIST)
    except (TTransport.TTransportException, OSError, EOFError) as exc:
        raise ThriftUnreachable("the thrift call %s(%s) did not complete: %s"
                                % (name, register, exc)) from exc


def read_register(host, port, register, index=None, timeout_s=5.0):
    """bmv2's value of `register[index]` (an int, signed as bmv2's i64 carries it), or with
    `index` None the whole array (a list). One connection, opened and closed here, every step of
    it bounded by `timeout_s`."""
    sock = TSocket.TSocket(host, port)
    sock.setTimeout(int(timeout_s * 1000))
    transport = TTransport.TBufferedTransport(sock)
    try:
        transport.open()
    except (TTransport.TTransportException, OSError) as exc:
        raise ThriftUnreachable("no thrift connection to %s:%s: %s" % (host, port, exc)) from exc
    try:
        if index is None:
            return call(transport, "bm_register_read_all", register)
        return call(transport, "bm_register_read", register, index)
    finally:
        transport.close()
