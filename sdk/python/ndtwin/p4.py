"""Reading and writing a P4 switch's tables, and reading its counters and registers, through the
kernel (doc/2026-01-02_ndt_api.md §43).

[Co-developed with claude code -- Adam]

The routes are `GET` and `POST /ndt/p4/table_entry`; the kernel relays them to the P4 proxy. A table
entry is a dict in the exact JSON shape those routes use, so a value the API gives (a MAC address,
a `"0x..."` wide value, `idle_timeout_ns`) goes back unchanged.
"""
import copy
import ipaddress
import json
import math
import re
import time
import urllib.parse
from dataclasses import dataclass, field
from typing import Optional

from .errors import (Busy, KernelUnreachable, NDTwinError, OutcomeUnknown, SwitchRefused,
                     TableFull, Unsettled, WriteNotVerified)

TABLE_ENTRY = "/ndt/p4/table_entry"
OPS = ("insert", "modify", "delete")
# The switch's answer to the re-sent write that says the first one landed.
LANDED_CODE = {"insert": "ALREADY_EXISTS", "delete": "NOT_FOUND"}
# The switch's answers that say the write itself is not valid, so the first one was refused too.
# This follows P4Runtime's meaning of the codes; it has not been observed on bmv2.
INVALID_CODES = ("INVALID_ARGUMENT", "OUT_OF_RANGE", "UNIMPLEMENTED")
_MAC = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")


class TableEntry(dict):
    """A table entry in the wire shape: dpid, table, match, action_name, action_params, priority,
    default_action and, where the table has them, idle_timeout_ns."""

    dpid = property(lambda self: self["dpid"])
    table = property(lambda self: self["table"])
    match = property(lambda self: self["match"])
    params = property(lambda self: self["action_params"])
    priority = property(lambda self: self.get("priority"))
    is_default = property(lambda self: bool(self.get("default_action")))

    def with_params(self, **params):
        """A copy with these action parameters changed, ready to send as a modify."""
        new = TableEntry(copy.deepcopy(self))
        new.setdefault("action_params", {}).update(params)
        return new


@dataclass
class Table:
    dpid: int
    name: str                                         # the full table name
    entries: list = field(default_factory=list)       # without the default entry
    default: TableEntry = None
    unrendered: list = field(default_factory=list)    # entries the API cannot show


@dataclass
class WriteResult:
    body: dict           # the proxy's reply
    lab_claim: dict      # X-NDTwin-Lab-Claim, parsed; None when the header is absent


@dataclass
class Settled:
    """What `P4.settle` found.

    `entry` is the entry as read back (None after a delete). `original_landed` is True when the
    switch answered the re-sent write with ALREADY_EXISTS (insert) or NOT_FOUND (delete), False
    when it applied the re-sent write (no earlier copy had landed by then), and None when that
    cannot be told: for a modify and for a default entry (the proxy sends a default entry's insert
    as a modify), which are applied again either way, and when an earlier re-send of `settle`'s
    own got OutcomeUnknown, since the switch's answer may then be about that one.
    `attempts` counts the writes `settle` sent.
    """

    entry: Optional[TableEntry]
    original_landed: Optional[bool]
    attempts: int


@dataclass
class Counter:
    """One cell of an indexed counter. `bytes` or `packets` is None for a unit it does not count."""

    dpid: int
    name: str
    index: int
    bytes: int
    packets: int


@dataclass
class DirectCounter:
    """A direct counter: `entries` holds one dict per table entry, {"match", "priority", "bytes",
    "packets"}, with the match fields as the proxy gives them (doc/2026-01-02_ndt_api.md §3)."""

    dpid: int
    name: str            # the full name
    table: str
    unit: str            # "bytes", "packets" or "both"
    entries: list = field(default_factory=list)


@dataclass
class Register:
    """Cells of a register from `start` on. `size` is the array's number of cells."""

    dpid: int
    name: str
    bitwidth: int
    size: int
    start: int
    values: list = field(default_factory=list)
    source: str = None


class P4:
    """`kernel.p4`."""

    def __init__(self, http):
        self._http = http

    def read_table(self, dpid, table, strict=True, retries=None):
        """Read one table. With `strict`, a table the API cannot show in full raises NDTwinError
        (a route through that switch could be missed); `strict=False` returns it with `unrendered`.
        `retries` overrides the client's for this read (0: one request)."""
        reply = self._http.call("GET", TABLE_ENTRY, {"dpid": dpid, "table": table},
                                retries=retries).body
        if not isinstance(reply, dict) or not isinstance(reply.get("entries"), list):
            raise NDTwinError(f"GET {TABLE_ENTRY}: unexpected reply {json.dumps(reply)[:200]}",
                              method="GET", path=TABLE_ENTRY, body=reply, nothing_written=True)
        entries = [TableEntry(e) for e in reply["entries"]]
        unrendered = reply.get("unrendered") or []
        if unrendered and strict:
            raise NDTwinError(f"s{dpid} {table}: entries the API cannot show: {unrendered}",
                              method="GET", path=TABLE_ENTRY, status=200, body=reply,
                              nothing_written=True)
        return Table(dpid=dpid, name=reply.get("table", table),
                     entries=[e for e in entries if not e.is_default],
                     default=next((e for e in entries if e.is_default), None),
                     unrendered=unrendered)

    def counter(self, name, dpid, index=0):
        """Read one cell of an indexed counter (GET /ndt/p4/counter/{name})."""
        r = self._read(f"/ndt/p4/counter/{urllib.parse.quote(name, safe='')}",
                       {"dpid": dpid, "index": index})
        return Counter(dpid=r["dpid"], name=r["counter"], index=r["index"], bytes=r["bytes"],
                       packets=r["packets"])

    def direct_counter(self, name, dpid):
        """Read a direct counter, one entry per table entry (GET /ndt/p4/direct_counter/{name})."""
        r = self._read(f"/ndt/p4/direct_counter/{urllib.parse.quote(name, safe='')}", {"dpid": dpid})
        return DirectCounter(dpid=r["dpid"], name=r["counter"], table=r["table"], unit=r["unit"],
                             entries=r["entries"])

    def register(self, name, dpid, index=None, start=None, count=None):
        """Read a register (GET /ndt/p4/register/{name}): one cell with `index`, a range with
        `start` and `count`, the whole array with none of them. bmv2 only, at most 4096 cells."""
        query = {"dpid": dpid, **{k: v for k, v in
                                  (("index", index), ("start", start), ("count", count))
                                  if v is not None}}
        r = self._read(f"/ndt/p4/register/{urllib.parse.quote(name, safe='')}", query)
        return Register(dpid=r["dpid"], name=r["register"], bitwidth=r["bitwidth"], size=r["size"],
                        start=r["start"], values=r["values"], source=r.get("source"))

    def _read(self, path, query):
        reply = self._http.call("GET", path, query).body
        if not isinstance(reply, dict):
            raise NDTwinError(f"GET {path}: unexpected reply {json.dumps(reply)[:200]}",
                              method="GET", path=path, status=200, body=reply, nothing_written=True)
        return reply

    def write(self, entry, op="insert", table_size=None):
        """Send one entry with `op` "insert", "modify" or "delete". No read-back.

        An insert the switch refuses with `RESOURCE_EXHAUSTED` raises TableFull, without reading
        the table. bmv2 answers a full table with `UNKNOWN` instead, whose text names no cause, so
        an insert refused with `UNKNOWN` raises TableFull only when you pass `table_size`, the
        size the P4 program declares for the table, and a read of the table straight afterwards
        (one request) holds at least that many entries; otherwise it stays a SwitchRefused whose
        `note` says what was found. The default entry is not counted, as bmv2 does not count it.
        `table_size` must be a positive integer (ValueError otherwise).
        [Co-developed with claude code -- Adam]
        """
        if op not in OPS:
            raise ValueError(f"op must be insert, modify or delete, not {op!r}")
        if table_size is not None and (isinstance(table_size, bool)
                                       or not isinstance(table_size, int) or table_size < 1):
            raise ValueError(f"table_size must be a positive integer, not {table_size!r}")
        try:
            reply = self._http.call("POST", TABLE_ENTRY, body=dict(entry, op=op))
        except SwitchRefused as err:
            full = self._table_full(TableEntry(entry), err, table_size) if op == "insert" else None
            if full is None:
                raise
            raise full from err
        return WriteResult(body=reply.body, lab_claim=reply.lab_claim)

    def _table_full(self, entry, err, size):
        """A TableFull for the refused insert when the evidence says the table is full; else None,
        after giving `err` a `note` when the switch's code was UNKNOWN."""
        code = (err.p4rt_error or {}).get("code")
        if code not in ("RESOURCE_EXHAUSTED", "UNKNOWN"):
            return None
        held, note = None, ("the switch's UNKNOWN names no cause; bmv2 answers a full table "
                            "with it: pass table_size to have the table counted")
        if size is not None and code == "UNKNOWN":
            try:
                table = self.read_table(entry.dpid, entry.table, strict=False, retries=0)
                held = len(table.entries) + sum(
                    1 for u in table.unrendered
                    if not (isinstance(u, dict) and u.get("default_action")))
                note = (f"the table held {held} entries of the {size} declared when read, so it "
                        f"was not full then")
            except NDTwinError as read_err:
                note = f"the read that would tell whether the table is full failed: {read_err}"
        if code == "RESOURCE_EXHAUSTED" or (held is not None and held >= size):
            full = TableFull(f"s{entry.dpid} {entry.table}: the table is full ("
                             + (f"{held} entries, {size} declared" if held is not None
                                else "the switch says RESOURCE_EXHAUSTED")
                             + f"): {err}", method=err.method, path=err.path, status=err.status,
                             origin=err.origin, body=err.body)
            full.grpc_status, full.p4rt_error, full.lab_claim = (
                err.grpc_status, err.p4rt_error, err.lab_claim)
            full.entries, full.size = held, size
            return full
        err.note = note
        err.args = (f"{err}; {note}",)
        return None

    def settle(self, entry, op="insert", budget_s=60.0, wait_s=None):
        """Find out whether a write that raised OutcomeUnknown is on the switch. Opt-in: the SDK
        never does this by itself.

        It sends the identical write again and reads the answer: a 200 means the write is applied
        now; ALREADY_EXISTS after an insert means the entry is there, which an earlier copy did;
        NOT_FOUND after a delete means the entry is gone, which an earlier copy did unless the
        entry never existed or another writer deleted it; a modify, and an insert of a default
        entry (the proxy sends it as a modify), are simply applied again. Then it reads the table
        once, with no retry, checks the entry is there as sent (or gone, after a delete), and
        returns a `Settled`.

        It waits `wait_s` seconds (the client's `retry_wait` when None) before each re-send, the
        first one included. While the answer says nothing about the switch (Busy,
        KernelUnreachable, OutcomeUnknown again) it sends the write again; it sends at least one,
        and starts no further one once `budget_s` seconds have passed since it was called, time
        spent waiting for answers included. So it takes at most max(budget_s, wait_s) seconds
        plus one write and the one read; the client's `timeout` bounds each socket operation of
        a request, not the whole request. Negative, infinite or NaN values are refused.

        Raises Unsettled, carrying the last error as `last`, when the budget runs out and also
        when the re-send is refused in a way that does not say whether an earlier copy landed:
        a 4xx from the kernel or the proxy, a reply that is not JSON, or a switch's code other
        than the landed ones above and INVALID_ARGUMENT, OUT_OF_RANGE or UNIMPLEMENTED. In
        P4Runtime those three say the write itself is invalid, so no copy of it can have landed,
        and the SwitchRefused is raised as is (that follows the codes' meaning; it has not been
        observed on bmv2). A modify of an entry that is gone is expected to get NOT_FOUND each
        time (not yet observed on bmv2) and then ends in Unsettled at once; `isinstance(err.last,
        SwitchRefused) and err.last.p4rt_error["code"] == "NOT_FOUND"` tells it from a budget that
        ran out. Raises WriteNotVerified when the table read does not confirm the outcome, or
        cannot; after a decision, it carries `original_landed` and `attempts`.

        When it returns, an earlier copy of the write (the first one, or a re-send of its own
        that got OutcomeUnknown) can still be waiting in the P4 proxy and land later (§43). It is
        the same write, so it changes nothing on its own, but it can undo a different write to
        the same entry (same table, match and priority) sent after it. Nothing on the kernel's
        API says when no copy can still land: after a different write to that entry, read it back
        again later. Pass the entry in the form `read_table` gives it, as for `modify`.
        """
        if op not in OPS:
            raise ValueError(f"op must be insert, modify or delete, not {op!r}")
        entry = TableEntry(entry)
        wait_s = self._http.retry_wait if wait_s is None else wait_s
        if not all(math.isfinite(v) and v >= 0 for v in (budget_s, wait_s)):
            raise ValueError(f"budget_s and wait_s must be finite and 0 or more, not {budget_s!r}, "
                             f"{wait_s!r}")
        deadline = time.monotonic() + budget_s
        attempts, resent_unknown = 0, False
        while True:
            time.sleep(wait_s)
            attempts += 1
            try:
                self._http.call("POST", TABLE_ENTRY, body=dict(entry, op=op), retries=0)
                # A modify, or a default entry (sent as a modify), is applied either way.
                original = None if op == "modify" or entry.is_default else False
                break
            except SwitchRefused as err:
                code = (err.p4rt_error or {}).get("code")
                if code in INVALID_CODES:
                    raise
                if code != LANDED_CODE.get(op):
                    raise self._unsettled(entry, op, err, attempts) from err
                original = None if resent_unknown else True
                break
            except (Busy, KernelUnreachable) as err:
                last = err
            except OutcomeUnknown as err:
                last, resent_unknown = err, True
            except NDTwinError as err:  # a 4xx, a reply that is not JSON: they decide nothing
                raise self._unsettled(entry, op, err, attempts) from err
            if time.monotonic() + wait_s >= deadline:
                raise self._unsettled(entry, op, last, attempts) from last
        try:
            table = self.read_table(entry.dpid, entry.table, retries=0)
        except NDTwinError as err:
            raise self._decided(WriteNotVerified(
                f"s{entry.dpid} {entry.table}: the {op} is settled, the read that confirms it "
                f"failed: {err}", method="GET", path=TABLE_ENTRY, status=err.status,
                origin=err.origin, body=err.body), original, attempts) from err
        if op != "delete":
            try:
                return Settled(self._check(entry, table), original, attempts)
            except WriteNotVerified as err:
                # Only ALREADY_EXISTS (True) is contradicted by a read that does not show the entry
                # as sent (another action or parameters, or no entry); a re-send that was applied
                # (False) stays applied whatever the read shows.
                raise self._decided(err, None if original else original, attempts) from None
        key = (_norm(entry.get("match")), _priority(entry.get("priority")))
        if _has_text(key[0]):  # the GET never shows such a form, so it could never match
            raise self._decided(WriteNotVerified(
                f"s{entry.dpid} {table.name}: the delete is settled, but its match "
                f"{entry.get('match')} is in a form the table cannot be compared with; send it as "
                f"read_table gives it", method="GET", path=TABLE_ENTRY, status=200,
                nothing_written=None), original, attempts)
        if any((_norm(e.get("match")), _priority(e.get("priority"))) == key for e in table.entries):
            # Only a decided True (NOT_FOUND: "gone") is contradicted by the entry being there; a
            # re-sent delete that was applied (False) stays applied.
            raise self._decided(WriteNotVerified(
                f"s{entry.dpid} {table.name}: the delete is settled and the table still shows "
                f"{entry.get('match')}", method="GET", path=TABLE_ENTRY, status=200,
                nothing_written=None), None if original else original, attempts)
        return Settled(None, original, attempts)

    @staticmethod
    def _decided(err, original, attempts):
        err.original_landed, err.attempts = original, attempts
        return err

    @staticmethod
    def _unsettled(entry, op, last, attempts):
        err = Unsettled(f"s{entry.dpid} {entry.get('table')}: the {op} is still not settled after "
                        f"{attempts} attempts: {last}", method=last.method, path=last.path,
                        status=last.status, origin=last.origin, body=last.body)
        err.last, err.attempts, err.lab_claim = last, attempts, last.lab_claim
        err.grpc_status = getattr(last, "grpc_status", None)
        return err

    def modify(self, entry, verify=True):
        """Modify one entry; with `verify`, read the table back and check the entry is there.

        Returns the entry as read back, or as sent when `verify` is False. Raises WriteNotVerified
        when the read-back fails, does not show the entry, or shows a table that has entries the
        API cannot render (the read-back is as strict as `read_table`).

        The check compares values in the form the GET returns them: send a MAC address, a
        `"0x..."` wide value or an `idle_timeout_ns` back in that form, or the write lands and the
        check still fails.
        """
        return self.modify_all([entry], verify=verify)[0]

    def modify_all(self, entries, verify=True):
        """Modify every entry in order, then read each affected table once and check them.

        A write that fails stops the run: the entries before it were written (the exception's
        `written` lists them), the ones after were not sent. Returns the entries as read back (as
        sent when `verify` is False). The read-back is strict and compares in the form the GET
        returns, as in `modify`.
        """
        entries = [TableEntry(e) for e in entries]
        for done, entry in enumerate(entries):
            try:
                self.write(entry, "modify")
            except NDTwinError as err:
                err.written = entries[:done]
                raise
        if not verify:
            return entries
        shown = {}
        for dpid, table in sorted({(e.dpid, e.table) for e in entries}):
            try:
                shown[dpid, table] = self.read_table(dpid, table)
            except NDTwinError as err:
                raise WriteNotVerified(f"s{dpid} {table}: the write was answered, the read-back "
                                       f"failed: {err}", method="GET", path=TABLE_ENTRY,
                                       status=err.status, origin=err.origin, body=err.body) from err
        return [self._check(e, shown[e.dpid, e.table]) for e in entries]

    @staticmethod
    def _check(sent, table):
        """The entry on the switch that matches `sent` (match and priority), if it shows the
        action and parameters that were sent."""
        pool = [table.default] if sent.is_default and table.default else table.entries
        found = [e for e in pool if e.get("match") == sent.get("match")
                 and e.get("priority") == sent.get("priority")]
        ok = bool(found) and found[0].get("action_params") == sent.get("action_params") and (
            sent.get("action_name") in (None, found[0].get("action_name"))
            or (found[0].get("action_name") or "").endswith("." + sent["action_name"])) and (
            "idle_timeout_ns" not in sent
            or found[0].get("idle_timeout_ns") == sent["idle_timeout_ns"])
        if not ok:
            raise WriteNotVerified(
                f"s{sent.dpid} {table.name}: read back {found} after writing {dict(sent)}",
                method="GET", path=TABLE_ENTRY, status=200, nothing_written=None)
        return found[0]


def _norm(value):
    """A match value in one form whatever form it was written in, so a delete is not confirmed
    by a table that shows the same entry written another way: an IPv4 address, a MAC address
    and a "0x..." string become integers, other strings lower case, a one-element list (an
    exact or optional match may be sent so) its element, other lists and dicts item by item."""
    if isinstance(value, dict):
        return {k: _norm(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return _norm(value[0]) if len(value) == 1 else [_norm(v) for v in value]
    if isinstance(value, str):
        if _MAC.match(value):
            return int(value.replace(":", ""), 16)
        if value[:2].lower() == "0x":
            try:
                return int(value, 16)
            except ValueError:
                return value.lower()
        try:
            return int(ipaddress.IPv4Address(value))
        except ValueError:
            return value.lower()
    return value


def _priority(value):
    """A priority as the GET shows it: a table without priorities shows None, and P4Runtime
    takes 0 there, so 0 reads as None."""
    return None if value == 0 else value


def _has_text(value):
    """Whether `_norm` left a string anywhere in `value`."""
    if isinstance(value, dict):
        return any(_has_text(v) for v in value.values())
    if isinstance(value, list):
        return any(_has_text(v) for v in value)
    return isinstance(value, str)
