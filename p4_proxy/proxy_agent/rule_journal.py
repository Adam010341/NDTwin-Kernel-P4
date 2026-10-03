"""
An append-only record of the rules this proxy was asked to install, and what a replay of it
is allowed to claim.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES A-4c. A proxy restart re-pushes the pipeline to every switch and a
VERIFY_AND_COMMIT push empties every table (`p4_client.set_forwarding_pipeline_config`; the
live measurement is in `write_clone_session`'s docstring). `install_initial_routes` then
refills the bring-up shortest paths, so afterwards the tables are *not* empty -- what is gone
is every rule installed since bring-up. Concretely:

  * an LPM rule an app had rewritten away from the shortest path is reverted to it,
  * an LPM rule an app had deleted is resurrected,
  * every `flow_5tuple` rule is gone and nothing recreates it, because
    `topology_manager.route_flow` deliberately does not record 5-tuple rules in
    `_installed_routes` (that map is `(dpid, ipv4_dst) -> out_port` and a 5-tuple rule has no
    single-valued answer to fit in it).

Nothing else in the system can supply the missing rules. `_installed_routes` is a dict built
in `TopologyManager.__init__` with no persistence. Kernel-side there is no intent store at
all: `FlowRoutingManager` keeps no map of installed entries, `DispatchOutcomeLog` discards a
successful job's actions -- so even its retained failures cannot be replayed -- and
`m_cachedOpenFlowTables` is replaced wholesale by the poll roughly every ten seconds. This
file is therefore the only place such a record can exist without new C++ state.

**What this module refuses to do is as important as what it does.**

Replay is opt-in, default off. A journal records *requests*, never the reasons behind them.
A Traffic-Engineering detour installed because a link was congested is still in the journal
twenty minutes later when the congestion has cleared, and replaying it programs a path nobody
wants. The journal cannot tell the difference, so it does not get to decide.

A replay outcome has no success boolean. A replay that half succeeds is worse than no replay:
it leaves the fabric matching neither the journal nor what was there before, while a caller
reading a boolean concludes the rules are back. `ReplayReport.status` is four-valued and an
empty journal reports `nothing-to-replay` rather than the arithmetically-true "complete" --
because the empty case is exactly when a human most needs to be told there is nothing to fall
back on.

An entry that could not be parsed keeps a replay from claiming completeness even when every
entry it *could* read succeeded. A journal holding a rule nobody can read is a fabric missing
something nobody can name, and "complete" is the wrong word for it.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import threading
import time

#: Turning replay on. Read through `RuleJournal.replay_enabled` so the parsing lives in one
#: place and can be tested without touching the environment.
REPLAY_ENV_VAR = "NDTWIN_RULE_JOURNAL_REPLAY"

#: Values that mean "on". Everything else -- including "0" and "false", which is what someone
#: writes when they mean off -- means off. A gate that read those as on would be worse than no
#: gate at all.
_TRUTHY = frozenset({"1", "true", "yes", "on"})


class ReplayReport:
    """
    What a replay actually achieved. Deliberately not a boolean.

    `status` is one of:

      ``nothing-to-replay``  the journal held no readable entries. Not a success: nothing was
                             restored, and this is the normal state after the journal itself
                             has been lost, which is when a human most needs to know there is
                             no fallback.
      ``complete``           every entry was read and every one was applied.
      ``partial``            some applied and some did not -- or everything applied but an
                             entry could not be read. The fabric now matches neither the
                             journal nor its pre-restart state.
      ``failed``             nothing applied. Usually categorical (the switch is refusing
                             writes) rather than N individual rejections.
    """

    def __init__(self, attempted, succeeded, failed, unreadable):
        self.attempted = attempted
        self.succeeded = succeeded
        #: [{"entry": <the journal entry>, "reason": str}] -- the entry itself, not just a
        #: count. A partial replay is only recoverable by a human who can see WHICH rules are
        #: missing.
        self.failed = failed
        #: Lines that would not parse. Counted separately from failures because the failure is
        #: at a different layer: nobody can even say what the rule was.
        self.unreadable = unreadable

    @property
    def status(self):
        if self.attempted == 0:
            # Ahead of the unreadable check on purpose: with nothing applied there is no
            # partial state to describe, and "nothing-to-replay" with unreadable > 0 is
            # already visible in the report.
            return "nothing-to-replay"
        if self.succeeded == 0:
            return "failed"
        if self.succeeded == self.attempted and self.unreadable == 0:
            return "complete"
        return "partial"

    def as_dict(self):
        """
        JSON-ready, so a reader can exist.

        This repository's most-repeated defect is a writer with no reader, and a replay
        outcome that only ever reached stdout would be exactly that shape: the one process
        that knows the fabric is incomplete would be the one nobody can query.
        """
        return {
            "status": self.status,
            "attempted": self.attempted,
            "succeeded": self.succeeded,
            "unreadable": self.unreadable,
            "failed": self.failed,
        }

    def __repr__(self):  # pragma: no cover - diagnostics
        return (f"<ReplayReport {self.status} {self.succeeded}/{self.attempted}"
                f" unreadable={self.unreadable}>")


class RuleJournal:
    """
    Append-only JSONL of accepted rule writes.

    One JSON object per line, `fsync`ed on append. JSONL rather than a single JSON document
    because a process killed mid-write leaves a torn *last line* instead of an unparseable
    whole file -- the difference between losing one rule and losing the journal.

    Only ACCEPTED writes are recorded. A rule the switch refused was never installed, and
    replaying it later would install something that never existed.
    """

    def __init__(self, path):
        self.path = path
        # Appends come from the FastAPI threadpool (route_flow and friends run under
        # run_in_threadpool), so more than one can be in flight. [Co-developed with claude
        # code -- Adam]
        self._lock = threading.Lock()
        self._unreadable = 0

    # --- writing ------------------------------------------------------------------

    def record(self, op, dpid, match, actions, priority=None):
        """
        Append one accepted write. Returns True if it reached the file.

        Never raises: a journal that cannot be written must not take down the rule install it
        is describing. It returns False instead, and the caller decides how loud to be -- the
        alternative is a proxy that refuses to route because a disk is full.
        """
        entry = {
            "t": time.time(),
            "op": op,
            "dpid": dpid,
            "match": match,
            "actions": actions,
            "priority": priority,
        }
        line = json.dumps(entry, separators=(",", ":"), sort_keys=True) + "\n"
        try:
            with self._lock:
                directory = os.path.dirname(self.path)
                if directory:
                    os.makedirs(directory, exist_ok=True)
                with open(self.path, "a", encoding="utf-8") as fh:
                    fh.write(line)
                    fh.flush()
                    # The whole point is surviving a process that did not shut down cleanly,
                    # and a line still in the page cache does not. One rule install is already
                    # a gRPC round trip, so an fsync is not what makes this path slow.
                    os.fsync(fh.fileno())
            return True
        except OSError:
            return False

    # --- reading ------------------------------------------------------------------

    def entries(self):
        """
        Every readable entry, in the order it was written.

        Order is the contract: install -> delete -> install of the same destination are three
        different end states, and collapsing them into a set would replay the wrong one.

        A line that will not parse is skipped and counted (see `unreadable_lines`), never
        raised: one torn line from a killed process must not make the whole journal unreadable.
        A missing file is empty, not an error -- that is first boot.
        """
        out = []
        unreadable = 0
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        parsed = json.loads(line)
                    except ValueError:
                        unreadable += 1
                        continue
                    if isinstance(parsed, dict):
                        out.append(parsed)
                    else:
                        # A JSON scalar is readable but is not an entry. Counted with the torn
                        # lines because the consequence is identical: a rule nobody can name.
                        unreadable += 1
        except FileNotFoundError:
            pass
        except OSError:
            # An unreadable journal is not an empty one. Reported through the same counter so
            # a replay over it cannot come back "complete".
            unreadable += 1
        self._unreadable = unreadable
        return out

    def unreadable_lines(self):
        """
        How many lines the last `entries()` call could not turn into an entry.

        Read after `entries()`, and refreshed by it, so a caller cannot get a stale count
        alongside a fresh list.
        """
        self.entries()
        return self._unreadable

    # --- replay -------------------------------------------------------------------

    @staticmethod
    def replay_enabled(env=None):
        """
        Whether replay has been turned on. Default off; see the module docstring.

        `env` is injectable so the decision can be tested without mutating os.environ -- and
        so this stays a pure function of its input rather than of process state.
        """
        if env is None:
            env = os.environ
        return str(env.get(REPLAY_ENV_VAR, "")).strip().lower() in _TRUTHY

    def replay(self, apply_entry):
        """
        Re-apply every readable entry in order, and report honestly what happened.

        `apply_entry(entry) -> bool` does the actual write. An applier that raises counts as a
        failure for that entry and the walk continues: one switch refusing a write must not
        abandon the other nine, the same argument main.startup's per-switch try/except makes
        for the pipeline push.

        This method does NOT check `replay_enabled`. The gate belongs at the call site, where
        the caller can say what it decided and log it; burying it here would make a disabled
        replay indistinguishable from an empty journal in the returned report.
        """
        entries = self.entries()
        unreadable = self._unreadable
        succeeded = 0
        failed = []
        for entry in entries:
            try:
                ok = bool(apply_entry(entry))
                reason = "applier reported failure"
            except Exception as exc:  # noqa: BLE001 -- one bad entry must not end the replay
                ok = False
                reason = f"{type(exc).__name__}: {exc}"
            if ok:
                succeeded += 1
            else:
                failed.append({"entry": entry, "reason": reason})
        return ReplayReport(attempted=len(entries), succeeded=succeeded, failed=failed,
                            unreadable=unreadable)

    # --- lifecycle ----------------------------------------------------------------

    def quarantine(self, boot_id):
        """
        Set the previous generation's journal aside, named for the boot that wrote it.

        Returns the new path, or None when there was no journal to move.

        Without this one file accumulates every generation's rules, and a later replay
        reinstalls rules that were deliberately deleted three restarts ago. Renamed rather
        than deleted because the file is the only surviving evidence of what the fabric was
        asked to do, and a replay that went wrong is investigated from it.
        """
        with self._lock:
            if not os.path.exists(self.path):
                return None
            target = f"{self.path}.{boot_id}.{int(time.time())}"
            os.replace(self.path, target)
            return target


# =============================================================================================
# The table-entry journal. POST /p4/table_entry's record, DESIGN.md section 5.
# [Co-developed with claude code -- Adam]
#
# Separate from `RuleJournal` above, on purpose. That one records the kernel's OpenFlow-shaped
# routing requests and its replay is off and has no caller, because a routing request is stale
# the moment the reason for it passes. An API table entry has no such reason behind it: the
# operator wrote it, nothing in this proxy can recompute it, and the journal is the only place
# it will ever exist again. Different shape, different replay policy, so a different file --
# `.run/table_entry_journal/s<dpid>.jsonl`, one per switch, which also means the lock that
# serialises one switch's writes never has to be held over another's.
#
# 🔴 WHAT THIS CUT DOES NOT DO: REPLAY. Nothing here puts a journaled entry back on a switch. A
# proxy restart (and a readopt) pushes the pipeline, the push empties the tables, and a journaled
# entry stays in its file -- recorded, not restored. So this module deliberately never says
# "journaled": it says `recorded`, and `journaled_claim()` below answers False until the one
# constant `TABLE_JOURNAL_REPLAYS` is flipped by the change that actually replays. A writer with
# no reader is this repository's most-repeated defect; the half-built version of it that must not
# ship is a field that reads GREEN for a record nothing reads back.
# =============================================================================================

#: Flipped to True by the change that replays the journal (startup and readopt) and by nothing
#: else. Every claim that an entry "survives a restart" -- the POST response's `journaled`, the
#: switch_state's `table_entries.journaled`, and through it the health check's T8 -- is computed
#: through this constant, so there is exactly one line that decides whether this proxy says it.
TABLE_JOURNAL_REPLAYS = False

#: What `journal.replay` says in a response and in switch_state while the constant above is False.
#: A string rather than a boolean so the sentence a reader meets is the sentence that is true.
REPLAY_NOT_IMPLEMENTED = "not implemented"

#: Overrides the directory the per-switch files live in. Same reason as RULE_JOURNAL_PATH_ENV_VAR:
#: a test has to be able to point the production construction at a temp directory.
TABLE_JOURNAL_DIR_ENV_VAR = "NDTWIN_TABLE_JOURNAL_DIR"

#: "off" turns recording off. Read by `table_journal_enabled`, so the parsing is testable.
TABLE_JOURNAL_ENV_VAR = "NDTWIN_TABLE_JOURNAL"

#: How many set-aside generations a switch's journal keeps. DESIGN 10-11.
QUARANTINE_KEEP = 10


def table_journal_enabled(env=None):
    """Whether the table-entry journal records. On unless NDTWIN_TABLE_JOURNAL says `off`."""
    if env is None:
        env = os.environ
    return str(env.get(TABLE_JOURNAL_ENV_VAR, "")).strip().lower() not in ("off", "0", "false", "no")


def journaled_claim(recorded):
    """
    Whether one accepted write may be reported as journaled: recorded AND something replays it.

    The single place the POST response's `journaled` is decided, so that the day replay lands the
    flip is one constant and not a hunt.
    """
    return bool(recorded) and TABLE_JOURNAL_REPLAYS


def key_digest(key):
    """
    One entry identity (`rule_install_times.entry_key`) as the short hex string the file stores.

    The key is built from encoded values, so `"10.0.1.1"` and `167772417` give the same digest;
    that is the whole point -- a delete in one spelling must remove an insert in the other.
    """
    return hashlib.sha256(repr(key).encode("utf-8")).hexdigest()[:32]


class SwitchGone(LookupError):
    """The switch a write was addressed to left the proxy's table between the route's check and
    the lock. The route answers it exactly as it answers an unknown dpid."""


def fold_records(records):
    """
    Collapse an ordered list of journal records to the net write each entry needs.

    DESIGN 5.4 step 4. The FIRST record of an entry says whether it existed before the API
    touched it (an insert means it did not; a modify or delete means it did -- a boot entry, or
    a default), and the LAST says whether it exists after and with what spec:

        not there -> there      insert(last spec)
        there     -> there      modify(last spec)
        there     -> not there  delete(last spec)
        not there -> not there  nothing

    A table's default entry is never inserted and never deleted, so whatever its history it nets
    to one modify of its last spec (or to nothing if the last thing recorded was a delete,
    which a switch refuses and so cannot be in a journal).

    Returns a list of `{"key", "op", "spec", "records"}` in the order each key first appeared.
    Header lines and anything that is not a record are skipped. Pure: no I/O, so it is tested
    without a file.
    """
    order = []
    first = {}
    last = {}
    count = {}
    for rec in records:
        if not isinstance(rec, dict) or rec.get("header") or "key" not in rec:
            continue
        key = rec["key"]
        if key not in first:
            first[key] = rec
            order.append(key)
        last[key] = rec
        count[key] = count.get(key, 0) + 1
    net = []
    for key in order:
        f, l = first[key], last[key]
        spec = l.get("spec") or {}
        if spec.get("default_action"):
            if l.get("op") != "delete":
                net.append({"key": key, "op": "modify", "spec": spec, "records": count[key]})
            continue
        before = f.get("op") != "insert"
        after = l.get("op") != "delete"
        if not before and after:
            op = "insert"
        elif before and after:
            op = "modify"
        elif before and not after:
            op = "delete"
        else:
            continue
        net.append({"key": key, "op": op, "spec": spec, "records": count[key]})
    return net


def records_from_net(net, now=None):
    """
    The journal records that say exactly what `fold_records` computed, one per net write.

    What a snapshot is made of (DESIGN 5.4 step 6): the folded history, re-expressed as records,
    so that folding the new file again gives the same net -- `fold_records(records_from_net(n))`
    equals `n` in key, op and spec for every `n` a fold can produce (its `records` count is of
    course 1 each, the history having been collapsed).
    """
    now = time.time() if now is None else now
    return [{"v": 1, "t": now, "op": item["op"], "key": item["key"], "spec": item["spec"],
             "outcome": "ok"} for item in net]


def _jsonl(obj):
    """One journal line as bytes. Named, so the table-entry journal does not repeat the spelling
    the routing journal's anchors (tests/shell/mutate_rule_journal_is_wired.sh) are unique on."""
    return (json.dumps(obj, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")


def _fsync_directory(directory):
    """Make a create or rename in `directory` durable. Best effort: a filesystem that cannot
    open a directory for fsync has no stronger guarantee to offer."""
    try:
        fd = os.open(directory or ".", os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


class TableEntryJournal:
    """
    One switch's journal of the table-entry writes it accepted through the API.

    Line 1 is a header (which p4info and entries file the records were made against, and which
    proxy boot wrote it); every later line is one accepted write:

        {"v":1,"t":<s>,"op":"insert|modify|delete","key":"<digest>","spec":{...},
         "outcome":"ok|not_found"}

    `spec` is the validated request body, so a replay can go back through the writer and meet
    every refusal again. Only ACCEPTED writes are recorded (a refused entry never existed), with
    one exception: a delete the switch answered NOT_FOUND is recorded as `not_found` (DESIGN
    10-4), because a delete whose answer was lost may have landed.

    **The caller holds `lock` around the switch write AND the `record`.** The journal does not
    take it itself: the lock has to cover the write that precedes the record, or two writes can
    land in one order on the switch and be journaled in the other.
    """

    def __init__(self, path, dpid, header=None):
        self.path = path
        self.dpid = dpid
        #: () -> {"fabric_cookie", "p4info_sha256", "entries_sha256", "boot_id"}; read only when
        #: a file is created, and allowed to return less. Never raises into `record`.
        self._header_fn = header
        self.lock = threading.Lock()
        self._unreadable = 0

    # --- writing ------------------------------------------------------------------

    def _header_line(self):
        fields = {}
        if self._header_fn is not None:
            try:
                fields = dict(self._header_fn() or {})
            except Exception:  # noqa: BLE001 -- a header that cannot be built must not lose the record
                fields = {}
        header = {"v": 1, "header": True, "dpid": self.dpid, "fabric_cookie": None,
                  "p4info_sha256": None, "entries_sha256": None, "boot_id": None}
        header.update({k: v for k, v in fields.items() if k in header and k not in ("v", "header")})
        return _jsonl(header)

    def record(self, op, spec, key, outcome="ok"):
        """
        Append one accepted write. Returns True if it reached the disk, False if it did not.

        Never raises, for the reason `RuleJournal.record` does not: a journal that cannot be
        written must not turn an accepted write into an error, because the rule IS on the switch.
        The caller counts the False and says so.
        """
        entry = {"v": 1, "t": time.time(), "op": op, "key": key, "spec": spec,
                 "outcome": outcome}
        try:
            encoded = _jsonl(entry)
            directory = os.path.dirname(self.path)
            if directory:
                os.makedirs(directory, exist_ok=True)
            created = not os.path.exists(self.path)
            with open(self.path, "a+b") as fh:
                size = fh.seek(0, os.SEEK_END)
                if size == 0:
                    fh.write(self._header_line())
                else:
                    # A crash can leave a last line with no newline. Appending straight after it
                    # would glue the new record onto the torn one and lose both.
                    fh.seek(-1, os.SEEK_END)
                    if fh.read(1) != b"\n":
                        fh.write(b"\n")
                fh.write(encoded)
                fh.flush()
                os.fsync(fh.fileno())
            if created:
                _fsync_directory(directory)
            return True
        except (OSError, TypeError, ValueError):
            return False

    def write_snapshot(self, header, records, keep=QUARANTINE_KEEP):
        """
        Replace the live file by `header` + `records`, keeping the old one under a new name.

        Order matters and is the point (DESIGN 5.4, 10-10, 10-12): write the new content to a
        temp file in the same directory and fsync it; HARD LINK the live file to the quarantine
        name; `os.replace` the temp file over the live name; fsync the directory. A crash between
        any two steps leaves a complete live file -- the old one before the replace, the new one
        after -- and never none, which a rename-then-write would. Returns the quarantine path, or
        None when there was no live file. Raises OSError; the caller decides what a failed
        snapshot means.
        """
        directory = os.path.dirname(self.path) or "."
        os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(self.path) + ".tmp.", dir=directory)
        try:
            with os.fdopen(fd, "wb") as fh:
                head = dict(header)
                head.update({"v": 1, "header": True, "dpid": self.dpid})
                fh.write(_jsonl(head))
                for rec in records:
                    fh.write(_jsonl(rec))
                fh.flush()
                os.fsync(fh.fileno())
            quarantined = None
            if os.path.exists(self.path):
                quarantined = f"{self.path}.q{time.time_ns()}"
                os.link(self.path, quarantined)
            os.replace(tmp, self.path)
            tmp = None
            _fsync_directory(directory)
        finally:
            if tmp is not None:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
        self._prune_quarantine(keep)
        return quarantined

    def _prune_quarantine(self, keep):
        directory = os.path.dirname(self.path) or "."
        prefix = os.path.basename(self.path) + ".q"
        try:
            names = sorted(n for n in os.listdir(directory) if n.startswith(prefix))
        except OSError:
            return
        for name in names[:max(0, len(names) - keep)]:
            try:
                os.unlink(os.path.join(directory, name))
                print(f"[table journal] dropped set-aside generation {name} (keeping {keep})")
            except OSError:
                pass

    # --- reading ------------------------------------------------------------------

    def read(self):
        """
        `(header, records, unreadable)` -- the header dict or None, every readable record in
        file order, and how many lines would not parse.

        A torn line is skipped and counted, never raised; a missing file is empty. A header-less
        file is readable too (the records are still the records) and reports `header` None.
        """
        header = None
        records = []
        unreadable = 0
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                for raw in fh:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        parsed = json.loads(raw)
                    except ValueError:
                        unreadable += 1
                        continue
                    if not isinstance(parsed, dict):
                        unreadable += 1
                    elif parsed.get("header"):
                        if header is None:
                            header = parsed
                    else:
                        records.append(parsed)
        except FileNotFoundError:
            pass
        except OSError:
            unreadable += 1
        self._unreadable = unreadable
        return header, records, unreadable

    def fold(self):
        """The net writes this file's records amount to. See `fold_records`."""
        _header, records, _unreadable = self.read()
        return fold_records(records)


class TableJournals:
    """
    Every switch's `TableEntryJournal`, the lock each one needs, and what to say about them.

    The route holds one of these; `main.py` builds it with the real directory and header
    provider. `read_only` is a callable so "external control plane" is read at request time.
    """

    def __init__(self, directory, enabled=True, read_only=None, header_for=None):
        self.directory = directory
        self.enabled = bool(enabled)
        self._read_only = read_only if read_only is not None else (lambda: False)
        self._header_for = header_for
        self._journals = {}
        self._failures = {}
        self._recorded = {}
        self._registry_lock = threading.Lock()

    def journal_for(self, dpid):
        key = str(dpid)
        with self._registry_lock:
            if key not in self._journals:
                header = None
                if self._header_for is not None:
                    header = (lambda d=dpid: self._header_for(d))
                self._journals[key] = TableEntryJournal(
                    os.path.join(self.directory, f"s{key}.jsonl"), dpid, header=header)
                self._failures.setdefault(key, 0)
                self._recorded.setdefault(key, 0)
            return self._journals[key]

    def known_dpids(self):
        """The switches (as strings) this process has written or tried to journal for."""
        with self._registry_lock:
            return set(self._journals)

    # --- the write ----------------------------------------------------------------

    def write_and_journal(self, get_client, dpid, spec, op, refusal_is_not_found=None):
        """
        Put one entry on the switch, then record it. Returns `(written, recorded)`.

        Runs in a worker thread (the route hands it to `run_in_threadpool`), so the lock is a
        `threading.Lock` and is never held across an `await`. The order is the contract: switch
        first, journal second, response last -- a journal written first would hold rules the
        switch refused, and a crash between the two leaves an entry on the switch that is not in
        the journal (an unconfirmed write, which the caller was never told succeeded) rather than
        in the journal and not on the switch.

        `get_client()` is called INSIDE the lock, so a client a readopt swapped in a moment ago
        is the one written through.

        An exception from the write propagates untouched and nothing is recorded -- with the one
        exception DESIGN 10-4 makes: a DELETE the switch answered NOT_FOUND is recorded as
        `not_found` and then re-raised, so the caller still sees the 502.
        """
        journal = self.journal_for(dpid)
        with journal.lock:
            client = get_client()
            if client is None:
                raise SwitchGone(f"switch {dpid} is no longer connected")
            try:
                written = client.write_table_entry(spec, op)
            except Exception as exc:  # noqa: BLE001 -- inspected, then re-raised unchanged
                if (self.enabled and op == "delete" and refusal_is_not_found is not None
                        and refusal_is_not_found(exc)):
                    key = client.table_entry_key(spec)
                    if key is not None:
                        self._record(journal, "delete", spec, key_digest(key), "not_found")
                raise
            if not self.enabled:
                return written, False
            recorded = self._record(journal, written["op"], spec,
                                    key_digest(written["entry_key"]), "ok")
            return written, recorded

    def _record(self, journal, op, spec, digest, outcome):
        ok = journal.record(op, spec, digest, outcome)
        key = str(journal.dpid)
        if ok:
            self._recorded[key] = self._recorded.get(key, 0) + 1
        else:
            self._failures[key] = self._failures.get(key, 0) + 1
        return ok

    # --- what to say --------------------------------------------------------------

    def record_complete(self, dpid):
        """
        True while every accepted API write of this boot is in the journal: recording is on, the
        switch is ours to write (not an external control plane's), and no record failed. The
        three conditions `journaled` will need once something replays them.
        """
        key = str(dpid)
        return (self.enabled and not self._read_only()
                and self._failures.get(key, 0) == 0)

    def journaled(self, dpid):
        """What `switch_state.table_entries.journaled` says. False while nothing replays."""
        return self.record_complete(dpid) and TABLE_JOURNAL_REPLAYS

    def report(self, dpid):
        """
        `table_entries.journal` for one switch.

            enabled          recording is on (NDTWIN_TABLE_JOURNAL is not `off`)
            recorded         accepted API writes of this boot that reached the file
            failures         accepted API writes of this boot that did NOT -- once this is above
                             zero `record_complete` stays false until the proxy restarts
            record_complete  every accepted write of this boot is in the file
            replay           "not implemented": nothing puts a record back on the switch
        """
        key = str(dpid)
        return {"enabled": self.enabled,
                "recorded": self._recorded.get(key, 0),
                "failures": self._failures.get(key, 0),
                "record_complete": self.record_complete(key),
                "replay": REPLAY_NOT_IMPLEMENTED if not TABLE_JOURNAL_REPLAYS else "implemented"}
