"""
When this proxy wrote each rule, and the one entry key both sides are required to compute.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES G-13. A bmv2 table entry has no age. P4Runtime's TableEntry carries a match, an
action, a priority and (with a direct counter) byte and packet counts -- and nothing that says
when it was installed. So `ryu_flow_stats` had nothing to put in `duration_sec`/`duration_nsec`
and emitted 0/0 for every rule, which the kernel serves verbatim through
`GET /ndt/get_switch_openflow_table_entries`. Measured 2026-09-07 (W16-3, P4 plane, 4 hosts):
one route installed, read back at +12 s and again at +32 s, and that rule -- along with every
rule that was already there -- reported `duration_sec: 0, duration_nsec: 0` while its counters
moved. Every rule on the P4 plane looked equally new, so `ndt`'s residue window could not tell
a rule an app left behind from a bring-up route, and had to mark the whole table UNKNOWN.

The switch cannot answer the question, so the only place an answer can come from is the writer.
This module is that record: the proxy stamps an entry when the switch accepts a write of it, and
the flow-stats renderer subtracts.

**Two properties are load-bearing, and both are about not lying.**

  - **One key function, used by the writer and by the reader.** An install-time record is
    useless if the write side and the read side name the same entry differently: every lookup
    misses, every rule reports 0/0, and nothing anywhere says why. So the key is computed here,
    by `entry_key`, from the shape `p4_client.read_table_entries` produces -- and the write
    paths build that same shape rather than a second, parallel one. Values are canonicalised to
    integers because bmv2 strips leading zero bytes on read-back: `b"\\x0a\\x00\\x00\\x04"`
    going in can come back as three bytes, and a bytes-comparison key would never match its own
    entry (`p4_client._ipv4_route_present` learned this the hard way).

  - **A rule with no record keeps 0/0.** Not the proxy's start time, not the time of the poll.
    0/0 already means "unknown age" to `ndt`, and that is the honest answer for a rule this
    proxy did not install: a bring-up rule from a previous proxy generation, a rule written by
    another controller, or -- most importantly -- a rule installed before this module existed.
    Substituting any available timestamp would turn "I do not know" into a confident wrong
    number, and the residue scan reading it cannot tell the two apart.

**An unchanged rewrite does not restart the clock.** `install_initial_routes` is deliberately
idempotent (`insert_ipv4_route` falls back to MODIFY), and the link watchdog re-runs it on every
link transition -- so a fabric that flaps a link every few seconds would reset every rule's age
every few seconds, and no rule would ever look older than the last flap. `record` therefore
compares an action fingerprint and keeps the earlier stamp when the entry is being rewritten to
what it already was. A rewrite that *changes* the entry does restart it, and that is the point:
the question `ndt` asks is "when did this switch last become what it now is", and an app that
reroutes a bring-up destination has left residue exactly as surely as one that added a rule.

**The record dies with the process, and that is consistent rather than lossy.** A proxy restart
re-pushes the pipeline to every switch, and a VERIFY_AND_COMMIT
`SetForwardingPipelineConfig` empties every table (KNOWN-ISSUES A-4c, and `rule_journal`'s
docstring for the measurement). `install_initial_routes` then refills the bring-up paths through
`insert_ipv4_route`, which stamps them. So no rule survives a restart carrying an age from
before it -- the rules that survive were re-installed, and their stamps are true.
"""

from __future__ import annotations

import threading
import time


def _value_key(value):
    """
    One P4Runtime field value in a hashable, leading-zero-insensitive form.

    Bytes become the integer they encode, so a value that bmv2 canonicalised on the way out
    still matches the padded form the write side put on the wire. Never raises: this runs under
    the kernel's 1 Hz flow-stats poll, and a shape neither side anticipated must degrade to a
    key that cannot be confused with a number rather than take the polling path down.
    """
    if isinstance(value, (bytes, bytearray)):
        return int.from_bytes(bytes(value), "big")
    if isinstance(value, int):
        return int(value)
    if value is None:
        return 0
    return ("raw", repr(value))


def is_dont_care(spec):
    """
    Whether this match field says nothing about the packet.

    A ternary field masked to zero matches everything, which is the same as not being in the
    entry at all -- P4Runtime treats an absent key that way, and `ryu_flow_stats` already
    refuses to render one. It is excluded from the key for the same reason, and defined once
    here so the renderer and the key cannot drift into two different opinions about it.
    """
    spec = spec or {}
    return spec.get("type") == "ternary" and _value_key(spec.get("mask", b"")) == 0


def _spec_key(spec):
    """One match field's type and values, hashable. An unknown type keeps its own shape."""
    spec = spec or {}
    kind = spec.get("type")
    if kind == "exact":
        return ("exact", _value_key(spec.get("value")))
    if kind == "lpm":
        return ("lpm", _value_key(spec.get("value")), int(spec.get("prefix_len") or 0))
    if kind == "ternary":
        return ("ternary", _value_key(spec.get("value")), _value_key(spec.get("mask")))
    if kind == "range":
        return ("range", _value_key(spec.get("low")), _value_key(spec.get("high")))
    # A match type this proxy does not model. Kept, rather than dropped, so two entries that
    # differ only in it cannot collide onto one install time -- an unknown field is a reason to
    # be more careful, not less.
    return ("unknown", str(kind),
            tuple(sorted(((str(k), _value_key(v)) for k, v in spec.items() if k != "type"),
                         key=lambda kv: kv[0])))


def normalise_match(match):
    """The match fields that identify an entry, ordered, canonicalised, hashable."""
    fields = [(str(name), _spec_key(spec))
              for name, spec in (match or {}).items()
              if not is_dont_care(spec)]
    fields.sort(key=lambda kv: kv[0])
    return tuple(fields)


def entry_key(dpid, table, priority, match):
    """
    The identity of one table entry: switch, table, priority, match.

    Priority is part of it because on a ternary table it is part of the entry's identity -- two
    `flow_5tuple` rules with the same keys at different priorities are two rules, and
    `delete_5tuple_rule`'s docstring records what happens when that is forgotten. `dpid` is
    stringified so an `int` from a write path and whatever a route handler was given agree.
    """
    return (str(dpid), str(table), int(priority or 0), normalise_match(match))


def action_key(action):
    """
    A fingerprint of what an entry does, or None when the caller did not say.

    Only ever compared for equality, never stored as identity: this decides whether a write
    changed the entry or merely rewrote it as it already was. `None` compares equal to `None`,
    so a caller that does not supply an action gets the conservative answer -- the earlier
    stamp is kept, and no rule is ever made to look newer than it is on a guess.
    """
    if action is None:
        return None
    params = ((str(k), _value_key(v)) for k, v in (action.get("params") or {}).items())
    return (str(action.get("name") or ""),
            tuple(sorted(params, key=lambda kv: kv[0])))


class RuleInstallTimes:
    """
    Install times for the entries one switch accepted from this proxy.

    Lives on the `P4RuntimeClient`, so its lifetime is the client's: `readopt_switch` builds a
    new client and pushes a pipeline that empties the switch, and the replacement starts with an
    empty record -- which is correct, because the entries it would have described are gone.
    """

    def __init__(self, monotonic=None, wall=None):
        # Injectable so a test can move time without sleeping, and so the age can never be a
        # function of process state a test cannot see. Monotonic is the load-bearing one: a
        # stepped system clock must not turn a rule installed a minute ago into one installed in
        # the future. [Co-developed with claude code -- Adam]
        self._monotonic = monotonic if monotonic is not None else time.monotonic
        self._wall = wall if wall is not None else time.time
        # Writes arrive from the FastAPI threadpool (the flow-entry handlers run under
        # run_in_threadpool) and from the link watchdog thread, so more than one can be in
        # flight, and the flow-stats poll reads while they do.
        self._lock = threading.Lock()
        #: entry_key -> (monotonic_at_install, action fingerprint)
        self._at = {}

    # --- writing ------------------------------------------------------------------

    def record(self, dpid, table, priority, match, action=None):
        """
        Note that the switch has just accepted a write of this entry. Returns its key.

        Call this only after the write succeeded. A refused write installed nothing, and dating
        a rule that is not on the switch would put an age on somebody else's entry the next time
        the same key appeared -- the same rule `rule_journal.record` follows for the same reason.
        """
        key = entry_key(dpid, table, priority, match)
        fingerprint = action_key(action)
        with self._lock:
            previous = self._at.get(key)
            if previous is not None and previous[1] == fingerprint:
                # Rewritten as it already was: idempotent reinstall, not a new rule.
                return key
            self._at[key] = (self._monotonic(), fingerprint)
        return key

    def forget(self, dpid, table, priority, match):
        """
        Drop this entry's record, because it is no longer on the switch. Returns whether one was
        held.

        A stamp outliving its entry is how a later rule at the same key would inherit an age it
        never had.
        """
        key = entry_key(dpid, table, priority, match)
        with self._lock:
            return self._at.pop(key, None) is not None

    def clear(self):
        """
        Forget everything -- every entry this record described has just ceased to exist.

        The pipeline push is the caller: a VERIFY_AND_COMMIT SetForwardingPipelineConfig empties
        every table on the switch (KNOWN-ISSUES A-4c), so keeping the stamps would date the
        refill by the wipe it replaced.
        """
        with self._lock:
            self._at.clear()

    # --- reading ------------------------------------------------------------------

    def age_seconds(self, dpid, table, priority, match):
        """
        How long ago this entry was installed, or **None** if this proxy did not install it.

        None rather than 0.0, and the distinction is the whole point: 0.0 is a rule installed
        just now, None is a rule whose age nobody knows. The renderer maps None to 0/0, which is
        what `ndt` already reads as UNKNOWN.

        Clamped at zero. Monotonic clocks do not run backwards, but an injected one can, and a
        negative duration in an unsigned OpenFlow field would be a very large positive one by
        the time the kernel parsed it.
        """
        key = entry_key(dpid, table, priority, match)
        with self._lock:
            record = self._at.get(key)
        if record is None:
            return None
        return max(0.0, self._monotonic() - record[0])

    def installed_at_epoch(self, dpid, table, priority, match):
        """
        Wall-clock time of the install, or None -- for correlating with the rule journal and the
        kernel log, which are both stamped in epoch seconds.

        Derived from the monotonic age rather than stored alongside it. A second stored clock is
        a second answer, and the two disagree the moment the system clock is stepped; deriving
        it means it can never contradict the duration the same entry reports.
        """
        age = self.age_seconds(dpid, table, priority, match)
        return None if age is None else self._wall() - age

    def __len__(self):
        with self._lock:
            return len(self._at)

    def __repr__(self):  # pragma: no cover - diagnostics
        return f"<RuleInstallTimes {len(self)} entries>"
