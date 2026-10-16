"""
The priority each ipv4_lpm slot was last written with, so a destination-only modify can name it.

[Co-developed with claude code -- Adam]

ipv4_lpm has no priority column and holds one entry per destination ("slot"), so a priority on
a destination-only modify cannot select an entry by itself. The 2026-09-03 decision
(doc/audit/2026-09-03_night-rounds/DECISION-P4-PRIORITY.md §2) therefore refused every named
priority there with 501: measured that day, a modify at 777 rewrote an entry nobody had named.

Adam's 2026-10-16 ruling amends that for one case. The proxy remembers, per slot, the priority
the entry in it was last written with -- CONTROL_PLANE_ROUTE_PRIORITY for the proxy's own routes
(the refill and the A-4d restore), the requested priority for an application's install -- and a
destination-only modify naming exactly that priority names the entry it names on OVS, so it is
honoured. Every other named priority on a modify, and every named priority on a strict delete,
stays 501.

Four rules keep the record from ever pointing at the wrong entry:

  * No record means 501. A slot this process has not written (or has forgotten) is not assumed
    to hold anything in particular.
  * Any write the proxy cannot confirm forgets the slot. A refused write, a False, an exception,
    and above all a DEADLINE_EXCEEDED -- which can hide a write that landed (p4_client.py's
    RPC_TIMEOUT_S comment) -- all drop the record instead of keeping the old one.
  * The check and the write are one step per slot. Handlers run on a threadpool, and the
    IntentTranslator posts to the proxy without going through the kernel's per-dpid dispatcher,
    so two writers can reach one slot at once. Every write to a slot holds that slot's lock
    from before it reads the record until after it has settled it.
  * A pipeline push to a switch forgets that switch's records. The push empties every table.
    The record is stamped with the client object and its `pipeline_push_epoch`, which the client
    bumps on both sides of every push attempt (a refused or timed-out push included); a record
    whose stamp no longer matches the switch's current client is no record. That covers startup
    and readopt (a new client object) without either call site having to remember to clear it.
    A write that BEGAN before a push, or while one was in flight, never counts once that push
    has returned: its stamp is an epoch the push's second bump has moved past. (A write that
    began and ended wholly inside a push is recorded until the push returns, then stops
    counting with everything else -- the window is the push's own RPC.)

A slot is the switch's entry, not the caller's string: "10.0.0.2", "10.0.0.02" and "10.2" name
the same ipv4_lpm entry once inet_aton has encoded them, so the record and the lock are keyed
on that encoding (`slot_key`).
"""

from __future__ import annotations

import socket
import threading
import weakref

#: The priority NDTwin's OVS control plane writes every destination route at:
#: intelligent_router.py, `self.add_flow(datapath, priority=10, match=match, actions=actions)`
#: under `OFPMatch(eth_type=0x0800, ipv4_dst=dst_ip)`. The proxy's own routes are the P4
#: counterpart of those, so they are recorded at this value; TE and Energy-Saving modify them
#: at this value on both planes. p4_proxy/tests/test_modify_at_slot_priority.py pins it to the
#: router's source. [Co-developed with claude code -- Adam]
CONTROL_PLANE_ROUTE_PRIORITY = 10

#: `settle(after=KEEP)`: the write did not change the entry's priority (a modify).
KEEP = object()


def named_priority(raw):
    """
    The priority a caller actually named, or None if they named none.

    [Co-developed with claude code -- Adam]
    Three values mean "no priority named", and telling them apart from a real request is the
    whole difference between a refusal that protects the fabric and one that stops it:

      * absent (None) -- HttpRoutingStrategyBase omits the key for the non-strict routes, which
        is every delete the control plane and the IntentTranslator make;
      * -1 -- FlowRoutingManager::deleteAnEntry's default, the "delete anything matching"
        sentinel the kernel turns into the non-strict POST;
      * 0 -- HttpSession::makeModifyJob's default for an ABSENT priority, so it arrives on
        every ordinary modify. `p4_priority` reads 0 the same way.

    A non-integer is not diagnosed here: guessing would turn a value problem into a capability
    answer that names the wrong fault.
    """
    if raw is None:
        return None
    try:
        priority = int(raw)
    except (TypeError, ValueError):
        return None
    return priority if priority > 0 else None


def install_priority(raw):
    """
    The priority an install leaves its slot recorded at, or None if it cannot be said.

    [Co-developed with claude code -- Adam]
    An install with no priority (or a sentinel) is recorded at 0, which no modify can name, so a
    modify at 10 against it is refused rather than guessed. A value that is not an integer is
    forgotten: what the caller meant by it is not known here.
    """
    if raw is None:
        return 0
    try:
        priority = int(raw)
    except (TypeError, ValueError):
        return None
    return priority if priority > 0 else 0


class SlotPriorityNotHeld(Exception):
    """
    A destination-only modify named a priority its slot's entry was not written with. -> 501.

    [Co-developed with claude code -- Adam]
    Raised under the slot's lock and before anything reaches the switch. `held` is the recorded
    priority, or None when there is no record (never written by this process, or forgotten after
    a write that could not be confirmed, or after a pipeline push).
    """

    def __init__(self, dpid, ipv4_dst, requested, held):
        self.dpid = dpid
        self.ipv4_dst = ipv4_dst
        self.requested = requested
        self.held = held
        super().__init__(
            f"switch {dpid}: modify of {ipv4_dst} names priority {requested}, and the entry in "
            f"that slot was " + (f"written at priority {held}" if held is not None
                                 else "not written by this proxy at a known priority"))


def slot_key(dpid, ipv4_dst):
    """
    The key of the ipv4_lpm entry `ipv4_dst` writes on `dpid`: the address as inet_aton encodes
    it, written back canonically.

    [Co-developed with claude code -- Adam] Review r1 MAJOR-1. The switch entry is built from
    socket.inet_aton(dst) (p4_client._lpm_match), and check_match_values accepts every spelling
    inet_aton does, so two spellings of one address are ONE entry -- and were two records and
    two locks here, which let a modify at 10 in one spelling edit an install at 100 made in the
    other. Same encoder as _lpm_match, so the key cannot disagree with the entry. A value
    inet_aton refuses never reaches this: check_match_values runs first on every write path
    (route_flow, unroute_flow, modify_flow), and install_initial_routes writes host addresses
    from the graph.
    """
    return dpid, socket.inet_ntoa(socket.inet_aton(ipv4_dst))


def _push_epoch(client):
    """The client's push epoch; 0 for a double that has none (and so never pushes)."""
    return getattr(client, "pipeline_push_epoch", 0)


class SlotPriorities:
    """
    slot_key(dpid, ipv4_dst) -> the priority the entry in that ipv4_lpm slot was last written
    with. Every entry point (lock, held, settle) keys through slot_key.

    [Co-developed with claude code -- Adam]
    See the module docstring for the four rules. `lock(dpid, dst)` is the slot's own lock and
    the OUTER one: a writer takes it first, then (briefly) TopologyManager._net_lock for
    _installed_routes, and this object's `_guard` is a leaf taken last and never held across a
    call out. Nothing may take a slot lock while holding _net_lock.
    """

    def __init__(self):
        self._guard = threading.Lock()
        self._locks = {}
        #: (dpid, dst) -> (priority, weakref to the client written through, its push epoch).
        self._records = {}

    def lock(self, dpid, ipv4_dst):
        key = slot_key(dpid, ipv4_dst)
        with self._guard:
            lock = self._locks.get(key)
            if lock is None:
                lock = self._locks[key] = threading.Lock()
            return lock

    def _valid(self, record, client):
        _priority, ref, epoch = record
        return ref() is client and epoch == _push_epoch(client)

    def held(self, dpid, ipv4_dst, client):
        """The recorded priority if the record still describes `client`'s switch, else None."""
        key = slot_key(dpid, ipv4_dst)
        with self._guard:
            record = self._records.get(key)
            if record is None:
                return None
            if not self._valid(record, client):
                del self._records[key]
                return None
            return record[0]

    @staticmethod
    def begin(client):
        """The stamp a write takes before it goes to the wire; hand it back to `settle`."""
        return _push_epoch(client)

    def settle(self, dpid, ipv4_dst, client, begun, accepted, after):
        """
        Record what a finished write left in the slot.

        `after` is the priority the entry now has, KEEP for "unchanged" (a modify), or None for
        "nothing known" (a removal, or a priority that cannot be stated). A write that was not
        confirmed (`accepted` false) forgets the slot.

        The record is stamped with `begun`, the epoch from BEFORE the write, not with the epoch
        now: a push that began while the write was in flight has moved the epoch since, so
        `held` finds the stamp stale and the record counts as none. That is the whole of the
        "a write that overlaps a push is not recorded" rule; stamping the current epoch here
        would let such a write through.
        """
        key = slot_key(dpid, ipv4_dst)
        with self._guard:
            if not accepted or after is None:
                self._records.pop(key, None)
                return
            if after is KEEP:
                return
            self._records[key] = (int(after), weakref.ref(client), begun)

    def snapshot(self):
        """{(dpid, dst): priority} as recorded, stale or not. For tests and diagnostics."""
        with self._guard:
            return {key: record[0] for key, record in self._records.items()}
