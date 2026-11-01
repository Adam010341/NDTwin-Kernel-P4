"""One HTTP request at a time to the kernel, with the retry rule.

[Co-developed with claude code -- Adam]
"""
import http.client
import json
import math
import time
import urllib.parse
from typing import NamedTuple

from .errors import (Busy, KernelUnreachable, NDTwinError, OutcomeUnknown, error_for_reply)


class Reply(NamedTuple):
    body: object        # the parsed JSON body (None when empty)
    origin: str         # X-NDTwin-Origin: "kernel", "proxy" or None
    lab_claim: dict     # X-NDTwin-Lab-Claim, parsed, or None


def retryable(err, method):
    """Whether sending the request again is safe and may help.

    A request that was not sent (`KernelUnreachable`) or that the proxy or the kernel says changed
    nothing and may succeed later (`Busy`, which includes the kernel's 504 with `request_sent`
    false) is repeated. A GET is also repeated after a broken connection or a kernel 502, since a
    read cannot write. It is not repeated after a kernel 504 that says the request was sent: the
    first read may still be running in the proxy and holding one of its read slots. The proxy's
    502 on a read is deterministic (an unreadable answer) and is not repeated either. A write
    whose outcome is unknown is never repeated: it can still land (doc/2026-01-02_ndt_api.md §43).
    """
    if isinstance(err, (KernelUnreachable, Busy)):
        return True
    if method != "GET":
        return False
    if err.origin == "kernel":
        return err.status == 502
    return err.status is None or (err.origin is None and err.status in (502, 503, 504))


class Transport:
    def __init__(self, url, timeout, retries, retry_wait):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ValueError(f"not an http(s) URL: {url!r}")
        if retries < 0:
            raise ValueError(f"retries must be 0 or more, not {retries!r}")
        if not (math.isfinite(retry_wait) and retry_wait >= 0):
            raise ValueError(f"retry_wait must be finite and 0 or more, not {retry_wait!r}")
        self.parts, self.prefix = parts, parts.path.rstrip("/")
        self.timeout, self.retries, self.retry_wait = timeout, retries, retry_wait

    def call(self, method, path, query=None, body=None, retries=None):
        """`_once`, repeated up to `retries` times (the client's own when None) when `retryable`.
        Returns a Reply."""
        retries = self.retries if retries is None else retries
        if retries < 0:
            raise ValueError(f"retries must be 0 or more, not {retries!r}")
        for attempt in range(retries + 1):
            try:
                return self._once(method, path, query, body)
            except NDTwinError as err:
                if attempt == retries or not retryable(err, method):
                    raise
                time.sleep(self.retry_wait)
        raise AssertionError("unreachable: the last attempt returns or raises")

    def _once(self, method, path, query, body):
        target = self.prefix + path + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else (b"" if method == "POST" else None)
        kind = http.client.HTTPSConnection if self.parts.scheme == "https" else http.client.HTTPConnection
        conn = kind(self.parts.hostname, self.parts.port, timeout=self.timeout)
        where = {"method": method, "path": path}
        try:
            try:
                conn.connect()
            except OSError as exc:
                raise KernelUnreachable(f"{method} {path}: cannot connect to the kernel at "
                                        f"{self.parts.netloc}: {exc}", **where) from None
            try:
                conn.request(method, target, body=data, headers={"Content-Type": "application/json"})
                resp = conn.getresponse()
                raw = resp.read()
            except (OSError, http.client.HTTPException) as exc:
                text = f"{method} {path}: the connection broke after the request went out: {exc!r}"
                if method == "GET":
                    raise NDTwinError(text, nothing_written=True, **where) from None
                raise OutcomeUnknown(text, **where) from None
            status, origin = resp.status, resp.getheader("X-NDTwin-Origin")
            claim = resp.getheader("X-NDTwin-Lab-Claim")
        finally:
            conn.close()
        try:
            lab_claim = json.loads(claim) if claim else None
        except ValueError:
            lab_claim = None
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = {"raw": raw.decode("utf-8", "replace")}
            if 200 <= status < 300:
                err = NDTwinError(f"{method} {path} -> {status}: the reply is not JSON",
                                  status=status, origin=origin, body=parsed,
                                  nothing_written=True if method == "GET" else None, **where)
                err.lab_claim = lab_claim
                raise err
        if not 200 <= status < 300:
            err = error_for_reply(method, path, status, origin, parsed)
            err.lab_claim = lab_claim
            raise err
        return Reply(parsed, origin, lab_claim)
