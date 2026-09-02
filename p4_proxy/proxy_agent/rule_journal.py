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
