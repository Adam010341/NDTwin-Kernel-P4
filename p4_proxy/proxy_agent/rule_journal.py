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

**What the journal is read for instead: the loss is reported, never replayed.** Every pipeline push this proxy makes closes the pushed switch's generation
(`RuleJournal.wiped`): the records since that switch's last `wiped` marker, written under the
pipeline cookie the switch held before the push, are folded to the rules the push discarded
(`discarded_rules`) and served as `ryu_rules_lost` on GET /p4/switch_state (`loss_record`). The
kernel logs them and puts them on its graph; whoever installed them resends. Nothing is written
back. [Co-developed with claude code -- Adam]
"""

from __future__ import annotations

import contextlib
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

#: The journal line a pipeline push leaves behind for one switch (`RuleJournal.wiped`): every
#: record of that switch above it was on tables that no longer exist. [Co-developed with claude
#: code -- Adam]
WIPED_OP = "wiped"

#: How many lost rules a loss record names one by one (`loss_record`). The count is always the
#: whole number; past this many the list stops and `rules_omitted` says how many it left out,
#: because the record is copied onto a kernel graph node once a second.
LOST_RULES_SHOWN = 100

#: The journal's verbs, as `fold_records` spells them.
_FOLD_OP = {"install": "insert", "modify": "modify", "delete": "delete"}


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


def _same_cookie(recorded, wiped):
    """Whether a record's cookie names the generation a push wiped. None never matches."""
    if recorded is None or wiped is None:
        return False
    try:
        return int(recorded) == int(wiped)
    except (TypeError, ValueError):
        return False


def _names_any_generation(recorded, wiped):
    """Whether a record's cookie names one of the generations a push wiped. `wiped` is one
    cookie or a tuple/list of them; None never matches. [Co-developed with claude code -- Adam]"""
    generations = wiped if isinstance(wiped, (tuple, list, set, frozenset)) else (wiped,)
    return any(_same_cookie(recorded, one) for one in generations)


def _since_last_wipe(scanned, dpid):
    """The records of switch `dpid` after its last `wiped` marker, and how many unreadable lines
    came after that marker. `scanned` is `RuleJournal.scan()`'s list, None standing for a line
    that could not be read; an unreadable line names no switch, so it is counted against every
    switch whose last marker it follows. A torn line from before the marker is not counted
    again: the push that wrote the marker already reported it."""
    since, unreadable = [], 0
    for entry in scanned:
        if entry is None:
            unreadable += 1
            continue
        if not isinstance(entry, dict) or str(entry.get("dpid")) != str(dpid):
            continue
        if entry.get("op") == WIPED_OP:
            since, unreadable = [], 0
            continue
        since.append(entry)
    return since, unreadable


def _rule_identity(entry):
    """The switch entry a journal record wrote, as the fold keys it: the `rule` the manager
    recorded (`TopologyManager._journal_rule`), or for a record without one the (match,
    priority) pair."""
    rule = entry.get("rule")
    if rule is not None:
        return key_digest(json.dumps(rule, sort_keys=True, default=str))
    match = entry.get("match") if isinstance(entry.get("match"), dict) else {}
    return key_digest((json.dumps(match, sort_keys=True), entry.get("priority")))


def discarded_rules(entries, dpid, cookie):
    """
    The Ryu-path rules a pipeline push of switch `dpid` discarded, from the journal's entries.

    [Co-developed with claude code -- Adam]
    The records of that switch after its last `wiped` marker whose cookie is `cookie` -- the
    generation the switch's tables were under right before the push -- folded per switch entry
    (`fold_records`). An entry is what the manager recorded as the write's `rule`: on ipv4_lpm
    the destination alone (one entry per destination, whatever priority an install or a modify
    named; a non-strict delete names none), on flow_5tuple the match and the P4 priority.

    Only a net install or modify is lost. A net delete is not: on ipv4_lpm a delete hands the
    slot back to the control-plane route (KNOWN-ISSUES A-4d) or leaves the destination empty
    when the control plane has no route there, and a restart's route refill leaves the same
    state; on flow_5tuple nothing recreates an entry. Returns
    `[{"op", "match", "actions", "priority"}]` in first-written order, `op` in the journal's
    own words.

    `cookie` None (the switch said none, or could not be asked) discards nothing that can be
    named: the tables the push replaced were not this journal's. A tuple of cookies folds every
    generation in it (a readopt names both the generation the switch held and the one its old
    client wrote under). Entries that are None (unreadable lines) are skipped. Pure: no I/O.
    """
    since, _unreadable = _since_last_wipe(entries, dpid)
    records = []
    for entry in since:
        if entry.get("op") not in _FOLD_OP or not _names_any_generation(entry.get("cookie"),
                                                                        cookie):
            continue
        match = entry.get("match") if isinstance(entry.get("match"), dict) else {}
        records.append({"key": _rule_identity(entry), "op": _FOLD_OP[entry["op"]],
                        "spec": {"match": match, "actions": entry.get("actions"),
                                 "priority": entry.get("priority")}})
    lost = []
    for item in fold_records(records):
        if item["op"] == "delete":
            continue
        spec = item["spec"]
        lost.append({"op": "install" if item["op"] == "insert" else item["op"],
                     "match": spec.get("match"), "actions": spec.get("actions"),
                     "priority": spec.get("priority")})
    return lost


def loss_record(lost, unreadable, cause, record_id, at=None, count_known=True,
                unknown_reason=None, write_failures=0):
    """
    What `GET /p4/switch_state` says about one push's Ryu-path loss (`ryu_rules_lost`).

    [Co-developed with claude code -- Adam]
    `count` is every rule `lost` holds, or null when the proxy cannot know (`count_known`
    False: the push raised, or the switch did not say which generation it held) -- then
    `count_unknown` says why and `rules` lists what the journal holds as candidates. `rules`
    names the first LOST_RULES_SHOWN and `rules_omitted` the rest. `journal_unreadable` (lines
    after this switch's last mark that could not be read) and `journal_write_failures` (writes
    the switch took that the journal could not record) mean the count may be short.
    `replayed` is always false: nothing put these back, and whoever installed them has to
    resend them. `id` changes with every push, so a reader acts once per record.
    """
    return {"id": record_id,
            "cause": cause,
            "at": time.time() if at is None else at,
            "count": len(lost) if count_known else None,
            "count_unknown": None if count_known else unknown_reason,
            "rules": list(lost[:LOST_RULES_SHOWN]),
            "rules_omitted": max(0, len(lost) - LOST_RULES_SHOWN),
            "journal_unreadable": unreadable,
            "journal_write_failures": write_failures,
            "replayed": False}


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

    def record(self, op, dpid, match, actions, priority=None, cookie=None, rule=None):
        """
        Append one accepted write. Returns True if it reached the file.

        Never raises: a journal that cannot be written must not take down the rule install it
        is describing. It returns False instead, and the caller decides how loud to be -- the
        alternative is a proxy that refuses to route because a disk is full.

        `cookie` is the pipeline cookie of the client the write went through: the fabric
        generation the switch's tables were under when it took the rule. `discarded_rules`
        counts a record as lost by a push only when its cookie is the one the push wiped, so
        a record without one (None, or written before this field existed) is never reported.
        `rule` names the switch entry the write touched (`TopologyManager._journal_rule`), which
        is what the loss fold keys on. [Co-developed with claude code -- Adam]
        """
        entry = {
            "t": time.time(),
            "op": op,
            "dpid": dpid,
            "match": match,
            "actions": actions,
            "priority": priority,
            "cookie": cookie,
            "rule": rule,
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

    def _append_marker_locked(self, marker_line):
        """`wiped`'s marker, appended and fsynced like `record`'s lines. The caller holds the
        lock. Its own body rather than a share of `record`'s, whose lines are a mutation gate's
        anchors (tests/shell/mutate_rule_journal_is_wired.sh)."""
        directory = os.path.dirname(self.path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(marker_line)
            fh.flush()
            os.fsync(fh.fileno())

    def wiped(self, dpid, cookie, cause, mark=True):
        """
        A pipeline push has just emptied switch `dpid`: what it discarded, and a mark after it.

        [Co-developed with claude code -- Adam]
        KNOWN-ISSUES A-4c: nothing is replayed (a journal holds requests, not the reasons
        behind them), the loss is reported instead. Returns `(lost, unreadable)`:
        `discarded_rules` for the switch and the cookie(s) its tables were under before the push
        (one cookie, or a tuple of them, each folded),
        and how many unreadable lines follow the switch's last mark (one of them may be a lost
        rule). Then, with `mark`, appends a `wiped` marker for the switch, so the next push of
        it counts only what was written after this one. Read and mark under one lock hold, so a
        write recorded meanwhile lands either before the mark (and is counted now) or after it
        (and is counted next time), never neither. `mark=False` is for a push that raised:
        whether it emptied the tables is unknown, so the next push counts these again.

        Never raises, like `record`: a journal that cannot be read must not fail the push it
        describes. An unreadable file comes back as `([], 1)`.
        """
        marker = {"t": time.time(), "op": WIPED_OP, "dpid": dpid, "cookie": cookie,
                  "cause": cause}
        marker_line = json.dumps(marker, separators=(",", ":"), sort_keys=True) + "\n"
        try:
            with self._lock:
                scanned = self.scan()
                lost = discarded_rules(scanned, dpid, cookie)
                _since, unreadable = _since_last_wipe(scanned, dpid)
                if mark:
                    try:
                        self._append_marker_locked(marker_line)
                    except OSError:
                        # The count is still right; the next push of this switch may count
                        # these rules a second time, which errs loud.
                        pass
            return lost, unreadable
        except Exception:  # noqa: BLE001 -- see the docstring
            return [], 1

    def scan(self):
        """
        Every line in order: the parsed entry, or None for a line that could not be read (an
        unreadable file is one None). What `wiped` needs and `entries` does not keep: where in
        the file each unreadable line sits. [Co-developed with claude code -- Adam]
        """
        out = []
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        parsed = json.loads(line)
                    except ValueError:
                        out.append(None)
                        continue
                    out.append(parsed if isinstance(parsed, dict) else None)
        except FileNotFoundError:
            pass
        except (OSError, UnicodeDecodeError):
            out.append(None)
        return out

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
        # A `wiped` marker is not a rule. [Co-developed with claude code -- Adam]
        entries = [e for e in entries if e.get("op") != WIPED_OP]
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
# The table-entry journal. POST /p4/table_entry's record.
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
# THE REPLAY. A proxy restart, and a readopt, push the pipeline, and the push
# empties the tables. What puts the API's entries back is `TableJournals.replay`, called by
# `main.startup` for every switch it pushed and by `main.readopt_switch` after the package's own
# entries: it re-reads the file, folds it, writes the net entries back through the writer and
# replaces the file by a snapshot of what went back.
#
# 🔴 ONLY ON A FABRIC THIS PROXY CAN RECOGNISE. Every push carries a fabric generation in the
# pipeline cookie, and every journal header names it. Before the first push of a startup the
# cookie each switch holds is read back (COOKIE_ONLY) and compared with its file's header; a
# switch that cannot confirm it -- a freshly started bmv2 answers FAILED_PRECONDITION, an old
# header names no cookie, the switch does not answer at all -- has its file set aside and gets
# nothing back. Yesterday's entries are never written into today's fabric.
# =============================================================================================

#: True since the replay exists. Every claim that an entry "survives a restart" -- the POST
#: response's `journaled`, the switch_state's `table_entries.journaled`, and through it the health
#: check's T8 -- is computed through this constant, so there is exactly one line that decides
#: whether this proxy says it.
TABLE_JOURNAL_REPLAYS = True

#: What a POST response's `journal.replay` says: when, and on what condition, its entry comes back.
REPLAYED_WHEN = ("at proxy startup, on a switch whose pipeline cookie confirms it is the fabric "
                 "this journal was written on, and after a readopt later in the same proxy run "
                 "(a readopt reads no cookie: this run's startup already decided)")

#: Overrides the directory the per-switch files live in. Same reason as RULE_JOURNAL_PATH_ENV_VAR:
#: a test has to be able to point the production construction at a temp directory.
TABLE_JOURNAL_DIR_ENV_VAR = "NDTWIN_TABLE_JOURNAL_DIR"

#: "off" turns recording off. Read by `table_journal_enabled`, so the parsing is testable.
TABLE_JOURNAL_ENV_VAR = "NDTWIN_TABLE_JOURNAL"

#: How many set-aside generations a switch's journal keeps. A confirmed start uses two
#: of them (step 0's header rewrite and the replay's snapshot), so ten is about five boots.
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


class SwitchBusy(RuntimeError):
    """Another write to the same switch held its lock for longer than the caller was willing to
    wait. Nothing was written, and nothing was validated either: the request never reached the
    writer, so sending it again may meet any answer the writer gives (a 400 or a 409 among
    them). The route answers 503."""


# The report's reason for a write that is stale because the package's entries file changed.
# [Co-developed with claude code -- Adam]
_STALE_ENTRIES = ("stale_entries: the package's entries file changed, and this write may have "
                  "been aimed at one of its entries")


class ReplayPending(RuntimeError):
    """The switch is being re-adopted: its pipeline is being pushed and its journal replayed.
    Nothing was written and nothing was validated; the route answers 503 `replay
    pending` at once rather than queueing the write behind the re-adoption, which holds the
    switch's lock for the whole of it."""


@contextlib.contextmanager
def _held(lock, timeout, what):
    """`with lock:` that gives up after `timeout` seconds (None waits for ever) and says so."""
    if not lock.acquire(timeout=-1 if timeout is None else timeout):
        raise SwitchBusy(f"{what} is busy: another write to it held the lock for {timeout}s")
    try:
        yield
    finally:
        lock.release()


class SwitchGone(LookupError):
    """The switch a write was addressed to left the proxy's table between the route's check and
    the lock. The route answers it exactly as it answers an unknown dpid."""


def _was_absent(rec):
    """Whether a record says the switch did not have the entry: a delete answered NOT_FOUND."""
    return rec.get("op") == "delete" and rec.get("outcome") == "not_found"


def fold_records(records):
    """
    Collapse an ordered list of journal records to the net write each entry needs.

    The FIRST record of an entry says whether it existed before the API
    touched it (an insert means it did not; a modify or delete means it did -- a boot entry, or
    a default), and the LAST says whether it exists after and with what spec:

        not there -> there      insert(last spec)
        there     -> there      modify(last spec)
        there     -> not there  delete(last spec)
        not there -> not there  nothing

    🔴 A FIRST DELETE THE SWITCH ANSWERED NOT_FOUND SAYS "UNKNOWN".
    The switch said the entry was absent at that moment -- but the reason may be an earlier
    delete whose answer was lost and which therefore was never recorded, of a package boot entry
    that every push and package reload puts back. So such a key starts neither present nor
    absent, and its LAST record decides:
      * last absent (a delete): a net delete, marked `unknown_before`. Replayed after the boot
        entries, it removes the boot entry again; a NOT_FOUND then means the goal is reached
        (a delete only makes the key absent). The mark is what lets a snapshot of it
        (`records_from_net`: a NOT_FOUND delete, then the delete) fold back to a delete that
        began unknown, so an insert of the same key made after the next start still folds to an
        insert and not to a modify the emptied switch would refuse.
      * last present: a net insert, marked `unknown_before`. If the replay's insert meets
        ALREADY_EXISTS -- only a boot entry the push and the package put back can be there --
        it is retried once as a modify to the journalled spec. No other insert is retried.
    A first delete the switch ACCEPTED still starts "there": it removed something.

    A table's default entry is never inserted and never deleted, so whatever its history it nets
    to one modify of its last spec (or to nothing if the last thing recorded was a delete,
    which a switch refuses and so cannot be in a journal).

    Returns a list of `{"key", "op", "spec", "records"}` in the order each key first appeared;
    an item whose key began unknown also has `"unknown_before": True`.
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
        after = l.get("op") != "delete"
        unknown = _was_absent(f)
        before = f.get("op") != "insert" and not (unknown and after)
        if not before and after:
            op = "insert"
        elif before and after:
            op = "modify"
        elif before and not after:
            op = "delete"
        else:
            continue
        item = {"key": key, "op": op, "spec": spec, "records": count[key]}
        if unknown:
            item["unknown_before"] = True
        net.append(item)
    return net


def records_from_net(net, now=None):
    """
    The journal records that say exactly what `fold_records` computed, one per net write.

    What the replay's snapshot is made of: the folded history, re-expressed as records,
    so that folding the new file again gives the same net -- `fold_records(records_from_net(n))`
    equals `n` in key, op and spec for every `n` a fold can produce (its `records` count is not
    kept: a snapshot has one record per write, two for one that began unknown). A write whose
    entry began unknown (`unknown_before`) is written as the NOT_FOUND delete it began with and
    then the write itself, so the next fold marks it again: an insert may still meet a boot
    entry on its replay, and a delete followed by a later insert of the key still folds to an
    insert.
    """
    now = time.time() if now is None else now
    out = []
    for item in net:
        if item.get("unknown_before"):
            out.append({"v": 1, "t": now, "op": "delete", "key": item["key"],
                        "spec": item["spec"], "outcome": "not_found"})
        out.append({"v": 1, "t": now, "op": item["op"], "key": item["key"],
                    "spec": item["spec"], "outcome": "ok"})
    return out


def _jsonl(obj):
    """One journal line as bytes. Named, so the table-entry journal does not repeat the spelling
    the routing journal's anchors (tests/shell/mutate_rule_journal_is_wired.sh) are unique on."""
    return (json.dumps(obj, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")


def _is_header_line(raw):
    """Whether one raw journal line is a header."""
    try:
        parsed = json.loads(raw)
    except ValueError:
        return False
    return isinstance(parsed, dict) and bool(parsed.get("header"))


def _created_mode(path):
    """The mode of the live file, or 0644 for a first one. (Not "0666 less the umask": reading
    the umask means setting it, process-wide, from a threadpool thread.)"""
    try:
        return os.stat(path).st_mode & 0o777
    except OSError:
        return 0o644


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
    one exception: a delete the switch answered NOT_FOUND is recorded as `not_found`,
    because a delete whose answer was lost may have landed.

    **The caller holds `lock` around the switch write AND the `record`, and around every
    snapshot.** The journal does not take it itself: the lock has to cover the write that
    precedes the record, or two writes can land in one order on the switch and be journaled in
    the other; and a readopt holds it from before its push until after its snapshot.
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

    def _header_bytes(self, fields):
        """The header line, in ONE shape whoever writes it: every key present (None when not
        given), nothing else, and always this journal's own dpid."""
        header = {"v": 1, "header": True, "dpid": self.dpid, "fabric_cookie": None,
                  "p4info_sha256": None, "entries_sha256": None, "boot_id": None}
        header.update({k: v for k, v in dict(fields or {}).items()
                       if k in header and k not in ("v", "header", "dpid")})
        return _jsonl(header)

    def _header_line(self):
        fields = {}
        if self._header_fn is not None:
            try:
                fields = dict(self._header_fn() or {})
            except Exception:  # noqa: BLE001 -- a header that cannot be built must not lose the record
                fields = {}
        return self._header_bytes(fields)

    def record(self, op, spec, key, outcome="ok"):
        """
        Append one accepted write. Returns True if it reached the disk, False if it did not.

        Never raises, for the reason `RuleJournal.record` does not: a journal that cannot be
        written must not turn an accepted write into an error, because the write IS on the switch.
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

        Order matters and is the point: write the new content to a
        temp file in the same directory and fsync it; HARD LINK the live file to the quarantine
        name; `os.replace` the temp file over the live name; fsync the directory. A crash between
        any two steps leaves a complete live file -- the old one before the replace, the new one
        after -- and never none, which a rename-then-write would. Returns the quarantine path, or
        None when there was no live file. Raises OSError; the caller decides what a failed
        snapshot means.

        🔴 THE CALLER HOLDS `self.lock`, and this raises RuntimeError when nobody does (one
        lock covers the append and the snapshot). A record appended while a snapshot is
        between its link and its replace lands in the set-aside inode and is lost from the live
        file. The snapshot does not take the lock itself because its one caller that races with
        writes, a readopt, has to hold it from before the push until after the snapshot,
        and a `threading.Lock` taken twice by one thread deadlocks.
        """
        lines = [_jsonl(rec) for rec in records]
        return self._replace_with(self._header_bytes(header), lines, keep)

    def reheader(self, header, keep=QUARANTINE_KEEP):
        """
        Replace the header line and keep every other line of the live file byte for byte -- the
        torn ones too, so a later read still counts them. That is step 0's rule: rewrite the
        header's boot_id, records as they are. Same order, same lock rule, same return value as
        `write_snapshot`.
        """
        body = []
        try:
            with open(self.path, "rb") as fh:
                raw = fh.read()
        except FileNotFoundError:
            raw = b""
        dropped_header = False
        for line in raw.splitlines(keepends=True):
            if not dropped_header and _is_header_line(line):
                dropped_header = True
                continue
            if not line.strip():
                continue
            body.append(line if line.endswith(b"\n") else line + b"\n")
        return self._replace_with(self._header_bytes(header), body, keep)

    def _replace_with(self, head, lines, keep):
        if not self.lock.locked():
            raise RuntimeError(f"{self.path}: a snapshot is taken under the switch's lock, and "
                               f"nobody holds it")
        directory = os.path.dirname(self.path) or "."
        os.makedirs(directory, exist_ok=True)
        self._sweep_temp(directory)
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(self.path) + ".tmp.", dir=directory)
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(head)
                for encoded in lines:
                    fh.write(encoded)
                fh.flush()
                os.fsync(fh.fileno())
            # mkstemp makes the file 0600; the live journal keeps the mode a record() would
            # have created it with, so a snapshot does not quietly change who can read it.
            os.chmod(tmp, _created_mode(self.path))
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

    def _sweep_temp(self, directory):
        """Remove the temp files an earlier snapshot of THIS journal left behind when its process
        died between mkstemp and the replace. Safe because the caller holds the lock, so no
        snapshot of this file is in flight in this process."""
        prefix = os.path.basename(self.path) + ".tmp."
        try:
            names = [n for n in os.listdir(directory) if n.startswith(prefix)]
        except OSError:
            return
        for name in names:
            try:
                os.unlink(os.path.join(directory, name))
                print(f"[table journal] removed {name}, left by a snapshot that did not finish")
            except OSError:
                pass

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
        Read as bytes and decoded one line at a time, inside the per-line try: a line that is not
        UTF-8 is one unreadable line, not an exception out of startup's step 0.
        """
        header = None
        records = []
        unreadable = 0
        try:
            with open(self.path, "rb") as fh:
                for raw in fh:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        parsed = json.loads(raw.decode("utf-8"))
                    except ValueError:  # UnicodeDecodeError is one
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


# --- the fabric generation: `fabric_cookie` ---------------------------------------------------


def cookie_hex(value):
    """A pipeline cookie (a u64) as the header stores it: 16 lower-case hex digits, or None."""
    return None if value is None else format(int(value) & 0xFFFFFFFFFFFFFFFF, "016x")


def cookie_value(text):
    """The header's `fabric_cookie` back as an int, or None when it names none (a Cut B file,
    whose header always said null) or names something that is not one."""
    if not isinstance(text, str):
        return None
    try:
        return int(text, 16)
    except ValueError:
        return None


def cookie_verdict(header, seen):
    """
    Step 0 for one switch: can its pipeline cookie confirm its journal?

    `header` is the switch's journal header, None when there is no file or no header line.
    `seen` is what COOKIE_ONLY answered: `("cookie", <int, or None for has_cookie false>)`, or
    `("error", "<what went wrong>")` -- a fresh bmv2's FAILED_PRECONDITION, a switch that does
    not answer, anything. Returns `{"confirmed", "cookie", "reason"}`, `cookie` being the
    switch's own (None when it has none or did not say).

    Confirmed only when the switch holds a cookie AND the header names one AND they are equal.
    Every other case is unconfirmed and says which it is, because "fresh fabric" is an
    operator's answer to "where did my entries go" and the reason is the rest of the sentence.
    """
    kind, value = seen
    if kind != "cookie":
        return {"confirmed": False, "cookie": None,
                "reason": f"the switch did not answer COOKIE_ONLY ({value})"}
    if value is None:
        return {"confirmed": False, "cookie": None,
                "reason": "the switch's pipeline carries no cookie"}
    switch = int(value)
    if header is None:
        reason = "this switch has no journal header to compare the cookie with"
    elif cookie_value(header.get("fabric_cookie")) is None:
        reason = "the journal header names no fabric cookie"
    elif cookie_value(header.get("fabric_cookie")) != switch:
        reason = (f"the switch's cookie {cookie_hex(switch)} is not the journal's "
                  f"{header.get('fabric_cookie')}")
    else:
        return {"confirmed": True, "cookie": switch, "reason": "confirmed"}
    return {"confirmed": False, "cookie": switch, "reason": reason}


def cookie_seen(client):
    """
    What one switch's COOKIE_ONLY says: ("cookie", int | None) or ("error", text).

    [Co-developed with claude code -- Adam]
    Never raises: every failure is "cannot confirm", and the text says which (the gRPC status
    name when the exception carries one). Shared by startup's step 0 (`main._cookie_seen`) and
    the readopt push, which both ask the switch what it holds before they empty it.
    """
    try:
        return ("cookie", client.read_pipeline_cookie())
    except Exception as exc:  # noqa: BLE001 -- every failure is "cannot confirm", and says which
        code = getattr(exc, "code", None)
        name = None
        try:
            name = code().name if callable(code) and code() is not None else None
        except Exception:  # noqa: BLE001
            name = None
        details = getattr(exc, "details", None)
        try:
            text = details() if callable(details) else None
        except Exception:  # noqa: BLE001
            text = None
        return ("error", f"{name}: {text}" if name else f"{type(exc).__name__}: {exc}")


def cookie_before_push(seen):
    """
    What one switch's COOKIE_ONLY answer says about the tables a push is about to empty, for the
    Ryu-path loss record. [Co-developed with claude code -- Adam]

    `seen` is `main._cookie_seen`'s answer. Returns `{"cookie", "unknown"}`:
      * a cookie: the generation the tables are under; the journal's records under it are lost;
      * no cookie, or FAILED_PRECONDITION (a bmv2 that has been pushed no pipeline): by the
        switch's account its tables hold nothing this journal wrote, so startup counts a known
        zero. (Readopt also folds its old client's cookie, whose writes went with the reboot.)
      * any other error (UNAVAILABLE, a deadline, ...): the switch did not say, and `unknown`
        is why -- the push may still succeed and empty tables nobody can describe.
    """
    kind, value = seen
    if kind == "cookie":
        return {"cookie": None if value is None else int(value), "unknown": None}
    text = str(value)
    if "FAILED_PRECONDITION" in text:
        return {"cookie": None, "unknown": None}
    return {"cookie": None, "unknown": text}


def fabric_generation(verdicts, mint):
    """
    The one fabric generation G for this boot, and the verdicts it leaves standing.

    Every confirmed switch must hold the same cookie, and G is that cookie. When no switch
    confirmed, or the confirmed ones disagree, G is `mint()` -- and on a disagreement every switch
    becomes unconfirmed, because two generations on one fabric means at least one of them is
    not this fabric's, and nothing says which.
    """
    values = {v["cookie"] for v in verdicts.values() if v["confirmed"]}
    if len(values) == 1:
        return values.pop(), dict(verdicts)
    out = dict(verdicts)
    if len(values) > 1:
        shown = ", ".join(sorted(cookie_hex(v) for v in values))
        for key, verdict in verdicts.items():
            if verdict["confirmed"]:
                out[key] = dict(verdict, confirmed=False,
                                reason=f"the switches that confirmed disagree on the fabric "
                                       f"cookie ({shown})")
    return mint(), out


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
        self._not_found = {}
        #: {dpid: how many readopts of it are under way}: a POST to one is a 503. A
        #: count, not a set: two overlapping readopts of one switch must not have the first one's
        #: end clear the flag the second still holds.
        self._pending = {}
        #: {dpid: step 0's verdict for this boot} and {dpid: the last replay's report}.
        self._fabric = {}
        self._replays = {}
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
                self._not_found.setdefault(key, 0)
            return self._journals[key]

    def known_dpids(self):
        """The switches (as strings) this process has written or tried to journal for."""
        with self._registry_lock:
            return set(self._journals)

    # --- the write ----------------------------------------------------------------

    def write_and_journal(self, get_client, dpid, spec, op, refusal_is_not_found=None,
                          lock_timeout=None):
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
        exception: a DELETE the switch answered NOT_FOUND is recorded as
        `not_found` and then re-raised, so the caller still sees the 502.

        A switch that is being re-adopted (`replaying`) raises ReplayPending, before the lock and
        again once it is held -- the second for a write that got past the first check just as
        the re-adoption began. Nothing is written either way.
        """
        journal = self.journal_for(dpid)
        self._refuse_pending(dpid)
        with _held(journal.lock, lock_timeout, f"switch {dpid}"):
            self._refuse_pending(dpid)
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

    # --- re-adoption: pending, and the lock held across it ----------------------------------

    def pending(self, dpid):
        """Whether `dpid` is being re-adopted right now."""
        with self._registry_lock:
            return self._pending.get(str(dpid), 0) > 0

    def _refuse_pending(self, dpid):
        if self.pending(dpid):
            raise ReplayPending(f"switch {dpid} is being re-adopted: its pipeline is being "
                                f"pushed and its journal replayed")

    @contextlib.contextmanager
    def replaying(self, dpid):
        """
        Hold `dpid`'s lock with `pending` set, for a readopt: yields the switch's journal.

        `pending` goes up BEFORE the lock is waited for, so a POST that arrives while a write
        ahead of the readopt finishes is answered 503 at once instead of queueing behind the
        whole re-adoption; it comes down, in `finally`, before the lock is released, so a POST
        that was already waiting goes through the new client. A readopt that fails still
        clears it -- exactly once: the count goes down by one whether or not the lock was ever
        taken.
        """
        journal = self.journal_for(dpid)
        key = str(dpid)
        with self._registry_lock:
            self._pending[key] = self._pending.get(key, 0) + 1
        dropped = []

        def drop():
            if not dropped:
                dropped.append(True)
                with self._registry_lock:
                    left = self._pending.get(key, 0) - 1
                    if left > 0:
                        self._pending[key] = left
                    else:
                        self._pending.pop(key, None)
        try:
            with journal.lock:
                try:
                    yield journal
                finally:
                    drop()
        finally:
            drop()

    # --- step 0: confirm or set aside, under the lock ----------------------------------------

    def settle(self, dpid, verdict, header_now):
        """
        Act on one switch's step-0 verdict. The caller holds the switch's lock.

        Confirmed: the header is rewritten to name this boot (and this generation, the same
        value) and every record stays as it is -- so a switch whose push fails right after is
        still marked "confirmed this boot", and a readopt later replays it. Unconfirmed: the
        file is set aside and the live one becomes a header with nothing under it (`header_now`:
        this boot, this generation, today's digests) -- and that is what any later readopt of
        this switch will find. Returns the set-aside path, or None.
        """
        journal = self.journal_for(dpid)
        key = str(dpid)
        self._fabric[key] = {"fresh_fabric": not verdict["confirmed"],
                             "cookie": verdict["reason"]}
        try:
            if verdict["confirmed"]:
                old, _records, _unreadable = journal.read()
                kept = dict(old or {})
                kept.update(boot_id=header_now.get("boot_id"),
                            fabric_cookie=header_now.get("fabric_cookie"))
                return journal.reheader(kept)
            return journal.write_snapshot(header_now, [])
        except OSError as exc:
            # The journal could not be kept for this boot. Counted like a record that did not
            # reach the disk: `journaled` is false for this switch until the proxy restarts.
            self._fabric[key]["error"] = f"{type(exc).__name__}: {exc}"
            with self._registry_lock:
                self._failures[key] = self._failures.get(key, 0) + 1
            return None

    # --- steps 1, 3-6: read, guard, fold, apply, snapshot ----------------------------------

    def replay(self, dpid, apply, header_now, is_not_found=None, when="startup", describe=None,
               is_already_exists=None, outcome_unknown=None):
        """
        Put this switch's journaled entries back and replace its file by what went back.

        The replay, for startup and readopt alike. The caller holds the lock.
        `apply(spec, op)` is the writer (`main` passes `write_table_entry` under the `replay`
        source, so V1-V9 and the owner check are met again); it is called directly, never
        through `write_and_journal`, so nothing is appended. `describe(exc)`, when given, is
        what the report says about a refusal. `is_already_exists(exc)` recognises the switch's
        ALREADY_EXISTS, for the one retry an `unknown_before` insert gets (a modify, see
        `fold_records`); `is_not_found(exc)` its NOT_FOUND, for a net delete that has reached its
        goal and for the one retry a net modify gets (an insert). `outcome_unknown(exc)` says a
        failure carries no per-update answer -- a deadline, an unavailable switch, any status
        without a per-update error: such a write may have landed, so its record stays in the
        snapshot and the next start tries again. `header_now` is the header the new file gets:
        this boot, this generation, today's p4info and entries digests.

          1. read the file AGAIN -- a readopt replays what was POSTed after startup too;
             a header that does not name THIS boot was not confirmed by this boot's step 0, so
             the file is set aside and nothing is replayed (`unconfirmed_header`);
          3. the p4info digest differs (or is unknown): nothing is replayed (`stale_pipeline`).
             The entries file's digest differs: a net insert still goes back, a net modify or
             delete -- which may have been aimed at a boot entry of the old file -- does not
             (`stale_entries`);
          4. fold (`fold_records`);
          5. apply each net write in the order its entry first appeared; a net delete the switch
             answers NOT_FOUND has reached its goal and counts as restored; an `unknown_before`
             insert answered ALREADY_EXISTS is retried once as a modify -- unless the entries
             file changed, when what is there is the new package's and the write is stale
             (`stale_entries`); a net modify of a non-default entry answered NOT_FOUND is
             retried once as an insert, because after the push only the package's entries are on
             the switch, so the key's earlier existence was wiped by it (or the package's own
             entry did not go back on) and the journal's last word -- present with this spec --
             is restored by inserting it. The key is named in `retried_as_modify` /
             `retried_as_insert` BEFORE the retry is sent, and a retry that fails is in `failed`
             with `"retried_as"` set; the entry there keeps the journal's op. The snapshot keeps
             the journal's own op, so each boot repeats the fallback;
          6. snapshot: the header and the records of what went back, and of every write whose
             outcome is unknown. What the switch refused, or was stale, stays in the set-aside
             file and in this report, not in the live file.

        Returns the report, which is also what `report(dpid)["replay"]` serves until the next.
        """
        journal = self.journal_for(dpid)
        key = str(dpid)
        report = self._blank_replay(key, when)
        header, records, unreadable = journal.read()
        report["unreadable"] = unreadable
        if header is None or header.get("boot_id") != header_now.get("boot_id"):
            report["skipped_reason"] = "unconfirmed_header"
            self._snapshot(journal, key, header_now, [], report)
            return self._store(key, report)
        net = fold_records(records)
        report["attempted"] = len(net)
        pipeline_changed = (header.get("p4info_sha256") is None
                            or header.get("p4info_sha256") != header_now.get("p4info_sha256"))
        entries_changed = header.get("entries_sha256") != header_now.get("entries_sha256")
        restored = []
        kept_unknown = []
        for item in net:
            entry = {"key": item["key"], "op": item["op"], "spec": item["spec"]}
            if pipeline_changed:
                report["stale_pipeline"] += 1
                report["failed"].append({"entry": entry, "reason": "stale_pipeline: the p4info "
                                         "this journal was written against is not the one "
                                         "loaded now", "kept": False})
                continue
            if entries_changed and item["op"] != "insert":
                report["stale_entries"] += 1
                report["failed"].append({"entry": entry, "reason": _STALE_ENTRIES, "kept": False})
                continue
            retried_as = None
            try:
                try:
                    apply(item["spec"], item["op"])
                except Exception as exc:  # noqa: BLE001 -- inspected, maybe retried, re-raised
                    if (item["op"] == "insert" and item.get("unknown_before")
                            and is_already_exists is not None and is_already_exists(exc)):
                        if entries_changed:
                            # What is there is an entry of the package's NEW entries file, not
                            # the one the journal's history was about: a modify would overwrite
                            # it. Stale, like a modify or a delete aimed at that file.
                            # [Co-developed with claude code -- Adam]
                            report["stale_entries"] += 1
                            report["failed"].append({"entry": entry, "reason": _STALE_ENTRIES,
                                                     "kept": False})
                            continue
                        # The key began unknown and something is there already: a boot entry
                        # the push and the package put back. The journal's spec is what it
                        # should be. Named before the modify is sent, so a modify that fails is
                        # still visible.
                        retried_as = "modify"
                        report["retried_as_modify"].append(item["key"])
                        apply(item["spec"], "modify")
                    elif (item["op"] == "modify" and not item["spec"].get("default_action")
                          and is_not_found is not None and is_not_found(exc)):
                        # Nothing is there to modify. After the startup push only the package's
                        # entries are on the switch, so the key's earlier existence was wiped by
                        # it, or the package's own entry did not go back on; the journal's last
                        # word is "present with this spec", and an insert of it restores exactly
                        # that. Named before the insert is sent, so an insert that fails is
                        # still visible.
                        # [Co-developed with claude code -- Adam]
                        retried_as = "insert"
                        report["retried_as_insert"].append(item["key"])
                        apply(item["spec"], "insert")
                    else:
                        raise
            except Exception as exc:  # noqa: BLE001 -- one entry must not cost the others
                if (item["op"] == "delete" and is_not_found is not None
                        and is_not_found(exc)):
                    # The entry the delete was for is not there: that IS the state the journal
                    # describes. Kept in the snapshot, so a later boot deletes it again.
                    restored.append(item)
                    continue
                unknown_outcome = outcome_unknown is not None and outcome_unknown(exc)
                if unknown_outcome:
                    kept_unknown.append(item)
                reason = None
                if describe is not None:
                    try:
                        reason = describe(exc)
                    except Exception:  # noqa: BLE001 -- a report must not fail the replay
                        reason = None
                failure = {"entry": entry, "reason": reason or f"{type(exc).__name__}: {exc}",
                           "kept": bool(unknown_outcome)}
                if retried_as is not None:
                    # The write that failed is the retry, not the journal's op in `entry`.
                    failure["retried_as"] = retried_as
                report["failed"].append(failure)
                continue
            restored.append(item)
        report["succeeded"] = len(restored)
        report["restored"] = [{"key": i["key"], "op": i["op"], "spec": i["spec"]}
                              for i in restored]
        keep = {i["key"] for i in restored} | {i["key"] for i in kept_unknown}
        kept = [i for i in net if i["key"] in keep]
        self._snapshot(journal, key, header_now, records_from_net(kept), report)
        return self._store(key, report)

    def note_skipped(self, dpid, reason, when="startup"):
        """A switch whose replay did not run, and why: an external control plane, a journal
        that is off, a pipeline push that failed. Nothing is read or written."""
        key = str(dpid)
        report = self._blank_replay(key, when)
        report["skipped_reason"] = reason
        return self._store(key, report)

    def _blank_replay(self, key, when):
        fabric = self._fabric.get(key, {})
        return {"when": when, "attempted": 0, "succeeded": 0, "unreadable": 0, "failed": [],
                "restored": [], "retried_as_modify": [], "retried_as_insert": [],
                "fresh_fabric": fabric.get("fresh_fabric"),
                "cookie": fabric.get("cookie"), "step0_error": fabric.get("error"),
                "stale_pipeline": 0, "stale_entries": 0, "skipped_reason": None}

    def _snapshot(self, journal, key, header, records, report):
        try:
            journal.write_snapshot(header, records)
        except OSError as exc:
            report["snapshot_error"] = f"{type(exc).__name__}: {exc}"
            with self._registry_lock:
                self._failures[key] = self._failures.get(key, 0) + 1

    def _store(self, key, report):
        status = ReplayReport(report["attempted"], report["succeeded"], report["failed"],
                              report["unreadable"]).status
        report = dict(report, status=status)
        self._replays[key] = report
        return report

    def _record(self, journal, op, spec, digest, outcome):
        ok = journal.record(op, spec, digest, outcome)
        key = str(journal.dpid)
        if ok and outcome == "not_found":
            # Counted on its own: this record is of a write the switch REFUSED (a 502), so
            # folding it into `recorded` would make that number disagree with `api_writes`.
            self._not_found[key] = self._not_found.get(key, 0) + 1
        elif ok:
            self._recorded[key] = self._recorded.get(key, 0) + 1
        else:
            self._failures[key] = self._failures.get(key, 0) + 1
        return ok

    # --- what to say --------------------------------------------------------------

    def record_complete(self, dpid):
        """
        True while every accepted API write of this boot is in the journal: recording is on, the
        switch is ours to write (not an external control plane's), and no record -- nor a step-0
        or replay snapshot -- failed. The three conditions of `journaled`.
        """
        key = str(dpid)
        return (self.enabled and not self._read_only()
                and self._failures.get(key, 0) == 0)

    def journaled(self, dpid):
        """What `switch_state.table_entries.journaled` says: every accepted write of this boot is
        in a journal that the next startup or readopt replays (on a fabric it can confirm)."""
        return self.record_complete(dpid) and TABLE_JOURNAL_REPLAYS

    def report(self, dpid):
        """
        `table_entries.journal` for one switch.

            enabled          recording is on (NDTWIN_TABLE_JOURNAL is not `off`)
            recorded         ACCEPTED API writes of this boot that reached the file (the same
                             writes `api_writes` counts)
            not_found        NOT_FOUND deletes of this boot that reached the file as `not_found`
                             records -- refused writes, so not in `recorded`
            failures         records of this boot that did NOT reach the file -- once this is
                             above zero `record_complete` stays false until the proxy restarts
            record_complete  every accepted write of this boot is in the file
            replay           the last replay of this switch (startup's, or a readopt's), or None
                             before one has run:
                               status/attempted/succeeded/unreadable/failed  as ReplayReport
                               restored        the net writes that took effect, {key, op, spec}
                                               -- deletes too: entries that are NOT there
                               retried_as_modify  keys whose unknown-start insert met
                                               ALREADY_EXISTS and were sent again as a modify
                                               (which may have failed: the key is then also
                                               in `failed`)
                               retried_as_insert  keys whose modify met NOT_FOUND and were sent
                                               again as an insert (likewise)
                               fresh_fabric    step 0 set this switch's file aside this boot
                               cookie          step 0's reason ("confirmed", or why not)
                               step0_error     step 0's own write failure, or None
                               failed[].kept   the write's outcome is unknown, so its record
                                               stayed in the journal for the next start
                               failed[].retried_as  "modify" or "insert" when the write that
                                               failed was the retry of the journal's op (the
                                               entry there keeps the journal's op), else absent
                               stale_pipeline  net writes not replayed: the p4info changed
                               stale_entries   net modifies/deletes -- and unknown-start inserts --
                                               not replayed: the entries file changed
                               skipped_reason  why nothing was even read, or None
                               when            "startup" or "readopt"
        """
        key = str(dpid)
        return {"enabled": self.enabled,
                "recorded": self._recorded.get(key, 0),
                "not_found": self._not_found.get(key, 0),
                "failures": self._failures.get(key, 0),
                "record_complete": self.record_complete(key),
                "replay": (dict(self._replays[key]) if key in self._replays else None)}
