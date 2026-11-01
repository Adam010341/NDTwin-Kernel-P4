"""The exceptions the ndtwin SDK raises, and the table that maps a kernel reply onto them.

[Co-developed with claude code -- Adam]

Every exception carries `method`, `path`, `status`, `origin` ("kernel", "proxy" or None, from the
`X-NDTwin-Origin` header of the /ndt/p4 routes), `body` (the parsed reply), `lab_claim` (the
`X-NDTwin-Lab-Claim` header of the reply, parsed, or None) and `nothing_written`:

  * True   nothing was changed on any switch: no request went out, or the reply says so;
  * None   unknown: the request may have landed, or may land later (doc/2026-01-02_ndt_api.md §43).

A read changes nothing, so every error of a GET has `nothing_written` True, except the
`WriteNotVerified` of a write's read-back. `may_have_landed` is `nothing_written is not True`.

An app that writes catches `NDTwinError` and reads `may_have_landed`; the narrower classes below
are for an app that answers one case differently.
"""
import json

_DEFAULT = object()

POWER_FAILED = "Failed to change switch power state"


class NDTwinError(Exception):
    """Base class. Also raised as itself for a case no subclass names (see `error_for_reply`)."""

    default_nothing_written = None
    lab_claim = None
    written = ()        # P4.modify_all: the entries answered before the write that failed

    def __init__(self, message, *, method=None, path=None, status=None, origin=None, body=None,
                 nothing_written=_DEFAULT):
        super().__init__(message)
        self.method, self.path, self.status, self.origin, self.body = (
            method, path, status, origin, body)
        self.nothing_written = (self.default_nothing_written if nothing_written is _DEFAULT
                                else nothing_written)

    @property
    def may_have_landed(self):
        """True unless the reply says the request changed nothing."""
        return self.nothing_written is not True


class KernelUnreachable(NDTwinError):
    """No TCP connection to the kernel. Nothing was sent."""

    default_nothing_written = True


class Refused(NDTwinError):
    """A 4xx: the request was refused and nothing was written."""

    default_nothing_written = True


class NotFound(Refused):
    """A 404: an unknown switch, table, field or management address."""


class LockBusy(Refused):
    """A 423: the lock is held. `retry_after_s` and `held_by_lease` come from the reply."""

    retry_after_s = None
    held_by_lease = None


class SwitchRefused(NDTwinError):
    """The proxy's 502 with the switch's own reason: the switch took the request and refused it.

    `p4rt_error` holds the switch's answer ({"code": ..., "message": ...}) and `grpc_status` the
    proxy's summary, which is often just "UNKNOWN". A proxy 502 without `p4rt_error` (its own
    deadline, an unavailable switch, a cancelled call) is an `OutcomeUnknown`: the write may have
    landed.
    """

    default_nothing_written = True
    grpc_status = None
    p4rt_error = None


class Busy(NDTwinError):
    """The proxy answered 503, or the kernel's 502/504 says the request was not sent.

    Nothing was written. The SDK has already retried it `retries` times.
    """

    default_nothing_written = True


class OutcomeUnknown(NDTwinError):
    """A write whose result is not known: it may have landed, and may still land later.

    Raised for a kernel 502/504 with `request_sent` true, a kernel 500 on /ndt/p4, a proxy 502
    without `p4rt_error` (`grpc_status` then holds the gRPC status, such as DEADLINE_EXCEEDED), any
    proxy 5xx other than 501, 502 with `p4rt_error` and 503, and a connection that broke after the
    request went out. The SDK sends such a write once. A table read straight afterwards does not
    settle it (doc/2026-01-02_ndt_api.md §43); `P4.settle` does, when the app asks for it.
    """

    grpc_status = None


class Unsettled(OutcomeUnknown):
    """`P4.settle` could not tell whether the write landed: its budget ran out, or the re-sent
    write was refused in a way that does not say (a 4xx, a reply that is not JSON, a switch's
    code that does not decide it).

    `last` is that error of the re-sent write (its `status`, `origin`, `body` and `grpc_status`
    are copied here) and `attempts` the number of writes `settle` sent. Any copy of the write may
    still land later (doc/2026-01-02_ndt_api.md §43), and nothing on the kernel's API says when
    none can: after a different write to the same entry, read the entry back again later.
    """

    last = None
    attempts = 0


class WriteNotVerified(NDTwinError):
    """The write was answered, but the table read back afterwards does not show the entry, shows
    entries the API cannot render, or could not be read.

    When `P4.settle` raises it after deciding, `attempts` holds the writes it sent and
    `original_landed` what it decided (see `Settled`), except where the read contradicts that
    decision: ALREADY_EXISTS said the entry is there and the read does not show it as sent
    (another action or parameters, or no entry), or NOT_FOUND said a deleted entry is gone and the
    read still shows it. Then `original_landed`
    is None. The decision is kept when the read failed (also when it found entries the API cannot
    show), when a delete's match could not be compared with the table, and after a re-sent write
    that was applied (False). Otherwise both are None."""

    original_landed = None
    attempts = None


class PowerError(NDTwinError):
    """A power command that failed, or whose read-back does not show admin_state "off".

    `nothing_written` is always None: the command may have taken effect. The kernel answers the
    same 500 "Failed to change switch power state" whatever went wrong. For a P4 (BMv2) switch that
    covers a power helper that is missing or has no record of the switch, and also a switch that
    was sent SIGTERM and was still running 10 s later, which may still exit; for another switch,
    a plug that was switched before the kernel gave up.
    """


# The classes a write reports once the kernel has answered or the request went out: use it to tell
# them from the rest. It does NOT hold KernelUnreachable (nothing connected) or a bare NDTwinError
# (a reply that is not JSON, a 501, a broken connection of a read), so an app that must not miss
# a case catches `ndtwin.NDTwinError` and reads `may_have_landed`.
WriteError = (OutcomeUnknown, SwitchRefused, Busy, WriteNotVerified, Refused)


def _detail(body):
    """The dict that holds the reason: the proxy nests it under "detail", the kernel does not."""
    if isinstance(body, dict):
        return body["detail"] if isinstance(body.get("detail"), dict) else body
    return {}


def error_for_reply(method, path, status, origin, body):
    """The exception for a reply that was not a 2xx.

    kernel origin  502/504 request_sent false   Busy
                   502/504 otherwise, 500       OutcomeUnknown (a GET: NDTwinError)
                   404 NotFound, 405 Refused, 501 NDTwinError (nothing sent to the proxy)
    proxy origin   502 with p4rt_error          SwitchRefused (a write)
                   502 without p4rt_error       OutcomeUnknown with grpc_status (a write)
                   503                          Busy
                   400 422 409 405             Refused, 404 NotFound, 501 NDTwinError
                   any other 5xx                OutcomeUnknown (a write)
                   a GET that fails             NDTwinError, nothing_written True
    any origin     423 LockBusy, 404 NotFound, other 4xx Refused,
                   500 "Failed to change switch power state" PowerError
                   anything else                NDTwinError (nothing_written None on a write)
    """
    write = method != "GET"
    text = f"{method} {path} -> {status}: {json.dumps(body)[:400]}"
    kw = dict(method=method, path=path, status=status, origin=origin, body=body)
    detail = _detail(body)
    unknown = (OutcomeUnknown(text, **kw) if write and origin
               else NDTwinError(text, nothing_written=None if write else True, **kw))
    if origin == "kernel" and status in (502, 504):
        if isinstance(body, dict) and body.get("request_sent") is False:
            return Busy(text, **kw)
        return unknown
    if origin == "kernel" and status == 500:
        return unknown
    if origin == "proxy" and status == 502 and write:
        # Only the switch's own per-update reason says it refused. The proxy answers 502 for any
        # gRPC failure, its own 5 s deadline included, and then the write may have landed.
        grpc_status, p4rt_error = detail.get("grpc_status"), detail.get("p4rt_error")
        if p4rt_error is None:
            err = OutcomeUnknown(text, **kw)
            err.grpc_status = grpc_status
            return err
        err = SwitchRefused(text, **kw)
        err.grpc_status, err.p4rt_error = grpc_status, p4rt_error
        return err
    if origin == "proxy" and status == 503:
        return Busy(text, **kw)
    if status == 423:
        err = LockBusy(text, **kw)
        err.retry_after_s = detail.get("retry_after_s")
        err.held_by_lease = detail.get("held_by_lease")
        return err
    if status == 404:
        return NotFound(text, **kw)
    if 400 <= status < 500:
        return Refused(text, **kw)
    if status == 501 and origin:
        return NDTwinError(text, nothing_written=True, **kw)
    if status == 500 and detail.get("error") == POWER_FAILED:
        return PowerError(text, **kw)
    if status >= 500 and origin:
        return unknown
    return NDTwinError(text, nothing_written=None if write else True, **kw)
