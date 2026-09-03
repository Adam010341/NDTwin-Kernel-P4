"""
Whether the journal PRODUCTION builds is attached to the manager PRODUCTION uses.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES A-4c, finding #71. `test_rule_journal.py` proves the journal keeps its promises,
and `test_journal_wiring.py` proves `TopologyManager` writes to a journal it is handed. Neither
of them could ever have failed while the journal was, in fact, never written once: both build
their own manager and inject the dependency. `test_journal_wiring.py` states in its own
docstring that "this repository's most-repeated defect is a component that exists, is
documented, is committed, and has no caller" -- and then supplies the caller itself. Fourteen
tests were green while `main.py` constructed `TopologyManager(kernel_notifier=kernel)` with no
journal at all, so `_note_in_journal`'s first line returned on `self._journal is None` every
single time.

So this file injects nothing. It imports `proxy_agent.main` the way `python proxy_agent/main.py`
executes it and asks the module-level `topo` -- the very object `api_routes.inject_topology`
hands every REST handler -- what it is holding. Then it drives one accepted write through that
object and reads the journal FILE back off the disk, because "a journal is attached" and "a rule
reached durable storage" are two different claims and only the second one survives a restart.

THE PATH IS PART OF THE WIRING. A journal whose path differs between two runs of the proxy is
the empty-journal failure wearing a different hat: the restart that was supposed to read it
opens a new file instead and reports "nothing to replay", which is exactly the sentence A-4c
warns is misread as "there was nothing to restore". So the default path is asserted to be
absolute, inside this checkout, stable across constructions, and the same answer from any
working directory.

What this file deliberately does NOT assert: that anything replays. Replay stays opt-in and off
(`rule_journal.REPLAY_ENV_VAR`), and no call site for it exists. Recording is the half that has
to land first -- a replay over a journal nobody wrote restores nothing.
"""

from __future__ import annotations

import contextlib
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent import api_routes  # noqa: E402
from proxy_agent.rule_journal import RuleJournal  # noqa: E402

#: The checkout's p4_proxy directory -- the proxy's working directory under stack.sh, and the
#: root the default journal path has to stay under. Derived from this file rather than from
#: `os.getcwd()` for the same reason main.py derives it from `__file__`.
PROXY_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

JOURNAL_PATH_ENV = "NDTWIN_RULE_JOURNAL_PATH"

OUTPUT_3 = [{"type": "OUTPUT", "port": 3}]
LPM_MATCH = {"nw_dst": "10.0.0.4"}
#: Anything beyond a destination compiles to the ternary flow_5tuple table -- the rule class
#: `_installed_routes` structurally cannot hold, so the journal is its only record anywhere.
FIVE_TUPLE_MATCH = {"nw_dst": "10.0.0.4", "nw_src": "10.0.0.1", "tp_dst": 80}


class FakeClient:
    """A switch that accepts or refuses every write. Nothing else here is faked."""

    def __init__(self, verdict=True):
        self.verdict = verdict
        self.calls = []

    def insert_ipv4_route(self, dst, prefix, mac, port):
        self.calls.append(("insert_ipv4_route", dst, port))
        return self.verdict

    def delete_ipv4_route(self, dst, prefix):
        self.calls.append(("delete_ipv4_route", dst))
        return self.verdict

    def modify_ipv4_route(self, dst, prefix, mac, port):
        self.calls.append(("modify_ipv4_route", dst, port))
        return self.verdict

    def insert_5tuple_rule(self, keys, prio, mac, port):
        self.calls.append(("insert_5tuple_rule", prio, port))
        return self.verdict

    def delete_5tuple_rule(self, keys, prio):
        self.calls.append(("delete_5tuple_rule", prio))
        return self.verdict

    def modify_5tuple_rule(self, keys, prio, mac, port):
        self.calls.append(("modify_5tuple_rule", prio, port))
        return self.verdict


@contextlib.contextmanager
def production_main(journal_path=None):
    """
    `proxy_agent.main` as a fresh import, which is all launching the proxy does to build `topo`.

    [Co-developed with claude code -- Adam]
    ONLY `main` is dropped from sys.modules, never the modules it imports. Reloading
    topology_manager or rule_journal as well would give the reloaded main a *different*
    TopologyManager and a different RuleJournal class from the ones this file imported, and
    every isinstance assertion below would then be comparing two classes that merely share a
    name -- an assertion that cannot fail is the defect this file exists to catch.

    `journal_path=None` means "import it exactly as production does": the environment override
    is removed rather than left at whatever the caller's shell had, so the default path is
    really the default. Importing constructs a journal but writes nothing, so this is safe to do
    against the real default path.

    Everything main mutates on the way through is put back -- api_routes' four injected globals
    and sys.modules -- and the sFlow emitter's socket is closed, so a suite that runs this
    alongside test_startup.py is not left holding a topology built for this test.
    """
    saved_env = os.environ.get(JOURNAL_PATH_ENV)
    saved_main = sys.modules.get("proxy_agent.main")
    saved_api = (api_routes.topology, api_routes.readopt_client_factory,
                 api_routes.readopt_sample_callback, api_routes.sflow_emitter)
    if journal_path is None:
        os.environ.pop(JOURNAL_PATH_ENV, None)
    else:
        os.environ[JOURNAL_PATH_ENV] = journal_path
    sys.modules.pop("proxy_agent.main", None)
    main = None
    try:
        import proxy_agent.main as main  # noqa: PLC0415 -- a fresh import is the point
        yield main
    finally:
        if main is not None:
            try:
                main.sflow.close()
            except Exception:  # noqa: BLE001 -- cleanup must not mask the assertion
                pass
        if saved_main is not None:
            sys.modules["proxy_agent.main"] = saved_main
        else:
            sys.modules.pop("proxy_agent.main", None)
        (api_routes.topology, api_routes.readopt_client_factory,
         api_routes.readopt_sample_callback, api_routes.sflow_emitter) = saved_api
        if saved_env is None:
            os.environ.pop(JOURNAL_PATH_ENV, None)
        else:
            os.environ[JOURNAL_PATH_ENV] = saved_env


def journal_lines(path):
    """Every entry the journal file holds, parsed. A missing file is no entries, not an error."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return [json.loads(line) for line in fh if line.strip()]
    except FileNotFoundError:
        return []


class TheProxyBuildsAJournalTest(unittest.TestCase):
    """
    The construction site itself: `main.topo`, imported the way the proxy imports it.

    This is the assertion that was missing. Everything else in the two journal suites holds
    while `main.py` passes no journal at all.
    """

    def test_the_module_level_topology_holds_a_real_rule_journal(self):
        with production_main() as main:
            self.assertIsNotNone(
                main.topo._journal,
                "main.topo was built with no journal: _note_in_journal returns on its first "
                "line and no rule this proxy installs is ever recorded")
            self.assertIsInstance(main.topo._journal, RuleJournal)

    def test_the_topology_the_rest_handlers_use_is_the_journalled_one(self):
        # inject_topology is how every REST handler reaches the manager. A journal attached to
        # some other TopologyManager would record nothing an app ever asked for.
        with production_main() as main:
            self.assertIs(api_routes.topology, main.topo)
            self.assertIsInstance(api_routes.topology._journal, RuleJournal)


class TheDefaultPathSurvivesARestartTest(unittest.TestCase):
    """
    Where the journal lives, when nobody has said.

    A path that is not the same string on the next run of the proxy makes the journal useless
    for the one job it has -- and does it silently, because a fresh file reads as an empty one.
    """

    def test_the_default_path_is_inside_this_checkout(self):
        with production_main() as main:
            path = main.topo._journal.path
        self.assertTrue(os.path.isabs(path), f"journal path is not absolute: {path!r}")
        self.assertTrue(
            os.path.realpath(path).startswith(os.path.realpath(PROXY_DIR) + os.sep),
            f"journal path {path!r} is outside {PROXY_DIR!r} -- a path hardcoded to one "
            f"machine's home directory is not a path this checkout can be run from")

    def test_the_default_path_does_not_move_between_constructions(self):
        # A fresh journal per construction (a tempfile, a timestamped name) passes every
        # "is it wired" assertion above and still loses the entire journal on restart.
        self.assertEqual(main_default_path(), main_default_path())

    def test_the_default_path_does_not_depend_on_the_working_directory(self):
        # stack.sh cds into p4_proxy before launching, but nothing enforces that, and a proxy
        # restarted from elsewhere must open the same file the last one wrote.
        here = os.getcwd()
        first = main_default_path()
        try:
            os.chdir(tempfile.gettempdir())
            second = main_default_path()
        finally:
            os.chdir(here)
        self.assertEqual(first, second)

    def test_the_environment_override_is_read(self):
        # Also what keeps this suite's own writes out of the checkout; a build_rule_journal that
        # ignored it would make every test below write to the real production path.
        with tempfile.TemporaryDirectory() as tmp:
            wanted = os.path.join(tmp, "rules.jsonl")
            with production_main(journal_path=wanted) as main:
                self.assertEqual(main.topo._journal.path, wanted)

    def test_importing_the_proxy_does_not_create_the_file(self):
        # Construction records a path; only an accepted write creates the file. It matters
        # because `entries()` treats a missing file as first boot, and a file created empty at
        # import would be indistinguishable from a journal whose writer is broken.
        with tempfile.TemporaryDirectory() as tmp:
            wanted = os.path.join(tmp, "rules.jsonl")
            with production_main(journal_path=wanted):
                self.assertFalse(os.path.exists(wanted))


class ARuleReachesTheDiskTest(unittest.TestCase):
    """
    The end-to-end claim: one call through the production manager, one line in the file.

    Read back from the filesystem rather than from a recording double, because durability is
    the whole point -- an in-memory list would be green against a journal whose `record` never
    reaches `open()`.
    """

    @contextlib.contextmanager
    def wired_proxy(self, verdict=True):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "rule_journal.jsonl")
            with production_main(journal_path=path) as main:
                main.topo.switches[1] = FakeClient(verdict=verdict)
                yield main.topo, path

    def test_one_accepted_install_is_one_line_in_the_journal_file(self):
        with self.wired_proxy() as (topo, path):
            self.assertTrue(topo.route_flow(1, LPM_MATCH, OUTPUT_3, 100))

            entries = journal_lines(path)
            self.assertEqual(len(entries), 1, f"journal file holds {entries!r}")
            self.assertEqual(entries[0]["op"], "install")
            self.assertEqual(entries[0]["dpid"], 1)
            self.assertEqual(entries[0]["match"], LPM_MATCH)
            self.assertEqual(entries[0]["actions"], OUTPUT_3)

    def test_a_five_tuple_install_is_in_the_journal_file(self):
        # The rule class with no record anywhere else in the system: `_installed_routes` is
        # keyed (dpid, ipv4_dst) and a 5-tuple rule has no single-valued answer to fit in it.
        with self.wired_proxy() as (topo, path):
            self.assertTrue(topo.route_flow(1, FIVE_TUPLE_MATCH, OUTPUT_3, 42))

            entries = journal_lines(path)
            self.assertEqual(len(entries), 1)
            self.assertEqual(entries[0]["match"], FIVE_TUPLE_MATCH)
            self.assertEqual(entries[0]["priority"], 42)

    def test_a_refused_install_leaves_the_journal_file_empty(self):
        # A rule the switch never took must not be replayable. This is the direction a "wire it
        # up" change breaks first: recording everything looks more complete and is wrong.
        with self.wired_proxy(verdict=False) as (topo, path):
            self.assertFalse(topo.route_flow(1, LPM_MATCH, OUTPUT_3, 100))

            self.assertEqual(journal_lines(path), [])

    def test_two_writes_append_rather_than_replace(self):
        # Order is the contract (rule_journal.entries): install -> delete of the same
        # destination are two different end states, and one file rewritten per call keeps only
        # the last one.
        with self.wired_proxy() as (topo, path):
            self.assertTrue(topo.route_flow(1, LPM_MATCH, OUTPUT_3, 100))
            self.assertTrue(topo.unroute_flow(1, LPM_MATCH, 100))

            self.assertEqual([e["op"] for e in journal_lines(path)], ["install", "delete"])

    def test_the_journal_the_proxy_wrote_is_readable_by_rule_journal(self):
        # The consumer side of A-4c: whatever a restart does with it, it has to be able to
        # parse it. A writer and a reader that disagree is the same empty-journal outcome.
        with self.wired_proxy() as (topo, path):
            self.assertTrue(topo.route_flow(1, LPM_MATCH, OUTPUT_3, 100))

            reader = RuleJournal(path)
            entries = reader.entries()
            self.assertEqual(len(entries), 1)
            self.assertEqual(reader.unreadable_lines(), 0)


def main_default_path():
    """
    The path a proxy started right now would use.

    Always through a fresh import, never through whatever `proxy_agent.main` another test
    module left in sys.modules: a stale module answers for the environment IT was imported
    under, and this function's callers are asking what production would do now.
    """
    with production_main() as main:
        return main.default_journal_path()


if __name__ == "__main__":
    unittest.main()
