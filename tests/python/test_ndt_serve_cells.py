#!/usr/bin/env python3
"""ndt serve, second ticket: the live_cells grid and the guided walk, against a stub grid.

[Co-developed with claude code -- Adam]

Adam's ruling (09-24 21:4x): open the live_cells in ndt serve, plus a guided mode in which the
service does a step, says where to look, and HE calls red or green. These cases pin what that
entry may and may not do:

  * the cells are the grid's OWN list (run_cells.sh --list) -- nothing else can be named;
  * old/ and new/ are shown by the cell's own judge, read-only, as GETs;
  * a run is a job in the one slot, with the grid's own argv, and SKIP is never shown as a pass;
  * a walk never runs a cell after a refused claim, never releases after a failed restore, and
    never calls the verdict -- that step is Adam's;
  * a GET never moves a walk.

The stub grid lives in the same temp repo as the stub ndt (test_ndt_serve.Serve): run_cells.sh
and one script per cell exec gridstub.py, which records every call to grid_calls.jsonl and answers
from grid.json. Fixtures carry a JUDGE file -- the judge stub prints it -- so old/ can be red and
new/ green exactly as the real fixtures are.

    python3 tests/python/test_ndt_serve_cells.py
"""
import json
import os
import signal
import sys
import textwrap
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_ndt_serve as base  # noqa: E402
from test_ndt_serve import tearDownModule  # noqa: E402,F401 -- the same leftover-server sweep

GRIDSTUB = textwrap.dedent('''\
    import json, os, sys, time
    here = os.path.dirname(os.path.realpath(__file__))
    def log(r):
        fd = os.open(os.path.join(here, "grid_calls.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        os.write(fd, (json.dumps(r) + "\\n").encode()); os.close(fd)
    grid = json.load(open(os.path.join(here, "grid.json")))
    role, argv = sys.argv[1], sys.argv[2:]
    log({"role": role, "argv": argv, "owner": os.environ.get("NDT_OWNER"),
         "ndt_root": os.environ.get("NDT_ROOT"), "t": time.time()})
    if role == "run_cells":
        if argv == ["--list"]:
            print("%-46s %-8s %s" % ("NAME", "TAG", "REQUIRES"))
            for c in grid["cells"]:
                print("%-46s %-8s %s" % (c["name"], c["tag"], c["requires"]))
            sys.exit(0)
        name, raw = argv[1], argv[3]
        b = grid.get("runs", {}).get(name, {})
        time.sleep(b.get("sleep", 0))
        d = os.path.join(raw, "2026-09-24", name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "judge.txt"), "w") as f:
            f.write(b.get("judge", ""))
        with open(os.path.join(d, "up.log"), "w") as f:
            f.write("up. ready\\n")
        print(b.get("judge", ""))
        if b.get("restore_fail"):
            print("RESTORE-FAIL after %s: 'ndt down' exited 1" % name, file=sys.stderr)
        sys.exit(b.get("rc", 0))
    name, sub = argv[0], argv[1]
    c = [c for c in grid["cells"] if c["name"] == name][0]
    if sub == "meta":
        print("name=%s\\ntag=%s\\nrequires=%s" % (name, c["tag"], c["requires"])); sys.exit(0)
    if sub == "judge":
        d = argv[2]
        if os.path.exists(os.path.join(d, "JUDGE_SLEEP")):
            log({"role": "judge-sleeping", "pid": os.getpid(), "argv": argv})
            time.sleep(float(open(os.path.join(d, "JUDGE_SLEEP")).read()))
        sys.stdout.write(open(os.path.join(d, "JUDGE")).read())
        sys.exit(int(open(os.path.join(d, "JUDGE_RC")).read()))
    sys.exit(2)
    ''')

CELLS_MD = textwrap.dedent('''\
    # live_cells (stub)

    | name | tag | requires | source | fix | expected verdict | `old/` fixture |
    |---|---|---|---|---|---|---|
    | `lab_cell` | ndt | ovs4 | ROLE-X, live | `abc` | `ndt up ovs 4` reaches rc 0 and prints no boom | captured log |
    | `offline_cell` | ndt | none | F-OFFLINE | `def` | the help no longer says the old sentence | replay |
    ''')

OLD_LAB = ("ASSERT ok   a1_log_present                         up.log present\n"
           "ASSERT FAIL a2_no_boom                             up.log still contains [boom]\n"
           "ASSERT FAIL a3_record_written                      no such raw file: up.target\n"
           "CELL: FAIL lab_cell tag=ndt kernel=aaaa ndt=bbbb at=2026-09-11T02:55:10+08:00\n")
NEW_LAB = ("ASSERT ok   a1_log_present                         up.log present\n"
           "ASSERT ok   a2_no_boom                             up.log does not contain it\n"
           "ASSERT ok   a3_record_written                      up.target present\n"
           "CELL: PASS lab_cell tag=ndt kernel=cccc ndt=dddd at=2026-09-12T10:00:00+08:00\n")
RUN_PASS = NEW_LAB.replace("2026-09-12T10:00:00", "2026-09-24T23:00:00")
RUN_FAIL = OLD_LAB.replace("2026-09-11T02:55:10", "2026-09-24T23:00:00")
RUN_SKIP = "SKIP: the lab is claimed by somebody else\nCELL: SKIP lab_cell tag=ndt kernel=x ndt=y at=z\n"
RUN_OFF = ("ASSERT ok   b1_sentence_gone                       help.txt does not contain it\n"
           "CELL: PASS offline_cell tag=ndt kernel=unknown ndt=ffff at=2026-09-24T23:00:00+08:00\n")
# the claim line as `ndt status` prints it (ndt:5664 claim_line), for each case the service must tell apart
CLAIM_YOURS = "lab\n  claim          yours -- 30m left (until 23:59:00)\n  measuring      nothing\n"
CLAIM_NONE = "lab\n  claim          none\n  prev claim     serve-test (until 23:00:00)\n"
CLAIM_FOREIGN = "lab\n  claim          orch-0924 -- 12m left (until 23:40:00)\n"
CLAIM_EXPIRED = "lab\n  claim          EXPIRED 3m ago (was serve-test) -- treated as free\n"
H4 = "up_refuses_a_model_of_another_network"
OLD_OFF = ("ASSERT FAIL b1_sentence_gone                       help.txt still contains [has run]\n"
           "CELL: FAIL offline_cell tag=ndt kernel=unknown ndt=eeee at=2026-09-11T01:00:00+08:00\n")


class GridServe(base.Serve):
    """A Serve whose temp repo also carries a stub live_cells grid and its fixtures."""

    def __init__(self, **kw):
        super().__init__(**kw)
        self.grid_dir = os.path.join(self.tmp, "repo", "tools", "test_workflow", "live_cells")
        self.fix = os.path.join(self.tmp, "repo", "tests", "fixtures", "live_cells")
        os.makedirs(self.grid_dir, exist_ok=True)
        with open(os.path.join(self.grid_dir, "gridstub.py"), "w") as f:
            f.write(GRIDSTUB)
        with open(os.path.join(self.grid_dir, "CELLS.md"), "w") as f:
            f.write(CELLS_MD)
        self.grid = {"cells": [{"name": "lab_cell", "tag": "ndt", "requires": "ovs4"},
                               {"name": "offline_cell", "tag": "ndt", "requires": "none"},
                               {"name": H4, "tag": "ndt", "requires": "idle"}],
                     "runs": {"lab_cell": {"rc": 0, "judge": RUN_PASS},
                              "offline_cell": {"rc": 0, "judge": RUN_OFF},
                              H4: {"rc": 0, "judge": RUN_OFF.replace("offline_cell", H4)}}}
        self.write_grid()
        for script, role in [("run_cells.sh", "run_cells"), ("lab_cell.sh", "cell"), ("offline_cell.sh", "cell"),
                             (H4 + ".sh", "cell")]:
            p = os.path.join(self.grid_dir, script)
            with open(p, "w") as f:
                f.write('#!/usr/bin/env bash\nexec python3 "$(dirname "$0")/gridstub.py" %s %s"$@"\n' % (
                    role, "" if role == "run_cells" else script[:-3] + " "))
            os.chmod(p, 0o755)
        self.fixture("lab_cell", "old", OLD_LAB, 1, expected="a2_no_boom\na3_record_written\n",
                     files={"up.log": "starting\nboom\n"})
        self.fixture("lab_cell", "new", NEW_LAB, 0, files={"up.log": "up. ready\n", "up.target": "topology=x.json\n"})
        self.fixture("offline_cell", "old", OLD_OFF, 1, expected="b1_sentence_gone\n")
        self.fixture(H4, "old", OLD_OFF.replace("offline_cell", H4), 1, expected="b1_sentence_gone\n")
        self.behave()

    def behave(self, **verbs):
        """The stub ndt's behaviour, with `status` saying the claim is this server's unless a case
        says otherwise -- a lab cell's run reads that line before it starts."""
        verbs.setdefault("status", {"stdout": CLAIM_YOURS})
        super().behave(**verbs)

    def write_grid(self):
        with open(os.path.join(self.grid_dir, "grid.json"), "w") as f:
            json.dump(self.grid, f)

    def fixture(self, cell, which, judge, rc, expected=None, files=None):
        d = os.path.join(self.fix, cell, which)
        os.makedirs(d, exist_ok=True)
        for name, text in dict(files or {}, JUDGE=judge, JUDGE_RC=str(rc)).items():
            with open(os.path.join(d, name), "w") as f:
                f.write(text)
        if expected is not None:
            with open(os.path.join(d, "EXPECTED-FAILS"), "w") as f:
                f.write(expected)
            with open(os.path.join(d, "PROVENANCE.md"), "w") as f:
                f.write("a3 fails because ROLE-X kept no up.target: a fixture gap.\n")

    def grid_calls(self, role=None):
        p = os.path.join(self.grid_dir, "grid_calls.jsonl")
        if not os.path.exists(p):
            return []
        rows = [json.loads(l) for l in base._read(p).splitlines() if l.strip()]
        return [r for r in rows if role is None or r["role"] == role]

    def runs(self):
        return [r for r in self.grid_calls("run_cells") if r["argv"] != ["--list"]]


class GridCase(unittest.TestCase):
    def setUp(self):
        self.s = GridServe().start()

    def tearDown(self):
        self.s.close()

    def walk(self, cell="lab_cell"):
        st, j, _, _ = self.s.post("/cells/%s/guided" % cell)
        self.assertEqual(st, 201, j)
        return j["walk"]["id"]

    def next(self, gid, want=200):
        st, j, _, _ = self.s.post("/guided/%s/next" % gid)
        self.assertEqual(st, want, j)
        return j

    def settle(self, gid, timeout=20):
        """Wait until the current step is no longer running."""
        deadline = time.monotonic() + timeout
        while True:
            st, j, _, _ = self.s.get("/guided/" + gid)
            w = j["walk"]
            cur = w["current"]
            if cur is None or w["steps"][cur]["state"] != "running" or time.monotonic() > deadline:
                return w
            time.sleep(0.1)


# --- the catalog: the grid's own list, its red, its green -------------------------------------

class CellsCatalog(GridCase):
    def test_cells_are_the_grids_own_list(self):
        st, j, _, _ = self.s.get("/cells")
        self.assertEqual(st, 200, j)
        by = {c["name"]: c for c in j["cells"]}
        self.assertEqual(sorted(by), ["lab_cell", "offline_cell", H4])
        self.assertEqual((by["lab_cell"]["requires"], by["lab_cell"]["old"], by["lab_cell"]["new"]), ("ovs4", True, True))
        self.assertEqual((by["offline_cell"]["requires"], by["offline_cell"]["new"]), ("none", False))
        self.assertIn("prints no boom", by["lab_cell"]["expected"])
        self.assertEqual({tuple(c["argv"]) for c in self.s.grid_calls("run_cells")}, {("--list",)})
        self.assertEqual({c["ndt_root"] for c in self.s.grid_calls()}, {os.path.join(self.s.tmp, "repo")})

    def test_unknown_cell_is_refused_and_runs_nothing(self):
        for name in ("no_such_cell", "..", "lab_cell.sh", "LAB_CELL", "lab_cell;id", "run_cells"):
            for method, path in (("GET", "/cells/%s" % name), ("GET", "/cells/%s/old" % name),
                                 ("POST", "/cells/%s/run" % name), ("POST", "/cells/%s/guided" % name)):
                st, _, _, _ = self.s.request(method, "/api/v1" + path, body={} if method == "POST" else None)
                self.assertIn(st, (404, 405), (method, path))
        self.assertEqual(self.s.runs(), [])
        self.assertEqual(self.s.grid_calls("cell"), [c for c in self.s.grid_calls("cell") if c["argv"][1] == "meta"])

    def test_old_is_judged_read_only_and_shows_the_red(self):
        st, j, _, _ = self.s.get("/cells/lab_cell/old")
        self.assertEqual(st, 200, j)
        self.assertEqual(j["verdict"]["state"], "FAIL")
        self.assertEqual(j["failing"], ["a2_no_boom", "a3_record_written"])
        self.assertTrue(j["failing_matches_expected"])
        self.assertIn("fixture gap", j["provenance"])
        self.assertIn("not automatically the finding", j["gap_note"])
        self.assertEqual([a["file"] for a in j["asserts"]], ["up.log", "up.log", "up.target"])
        judge = [c for c in self.s.grid_calls("cell") if c["argv"][1] != "meta"]
        self.assertEqual([c["argv"][:2] for c in judge], [["lab_cell", "judge"]])
        self.assertTrue(judge[0]["argv"][2].endswith("tests/fixtures/live_cells/lab_cell/old"))
        self.assertEqual(self.s.runs(), [])

    def test_new_is_judged_and_shows_the_green(self):
        st, j, _, _ = self.s.get("/cells/lab_cell/new")
        self.assertEqual((j["verdict"]["state"], j["failing"]), ("PASS", []))
        st, _, _, _ = self.s.get("/cells/offline_cell/new")
        self.assertEqual(st, 404)

    def test_fixture_raw_cannot_leave_the_fixture(self):
        st, _, _, raw = self.s.get("/cells/lab_cell/old/raw/up.log")
        self.assertEqual((st, raw), (200, b"starting\nboom\n"))
        os.symlink("/etc/hostname", os.path.join(self.s.fix, "lab_cell", "old", "escape"))
        for rel in ("..%2F..%2Fnew%2FJUDGE", "escape", "nope"):
            st, _, _, _ = self.s.get("/cells/lab_cell/old/raw/" + rel)
            self.assertEqual(st, 404, rel)


# --- a run: one job in the one slot, the grid's own argv --------------------------------------

class CellsRun(GridCase):
    def run_cell(self, cell="lab_cell"):
        st, j, _, _ = self.s.post("/cells/%s/run" % cell)
        self.assertEqual(st, 202, j)
        return self.s.wait(j["job"]["id"])

    def test_cell_run_is_a_job_with_the_grids_own_argv(self):
        job = self.run_cell()
        grid = os.path.join(self.s.tmp, "repo", "tools", "test_workflow", "live_cells")
        self.assertEqual(job["argv"][:3], [os.path.join(grid, "run_cells.sh"), "--cell", "lab_cell"])
        self.assertEqual(job["argv"][3], "--raw-root")
        self.assertTrue(job["argv"][4].startswith(os.path.join(self.s.state, "cells-raw", "lab_cell-")))
        run = self.s.runs()[0]
        self.assertEqual((run["owner"], run["ndt_root"]), (base.OWNER, os.path.join(self.s.tmp, "repo")))
        self.assertEqual((job["rc"], job["rc_class"], job["cell_verdict"]["state"]), (0, "pass", "PASS"))

    def test_lab_cell_run_needs_your_claim(self):
        """Judge r2 finding 1: with ndt's OVS `up` ignoring a foreign claim, a lab cell run without a
        claim of your own can build a fabric under somebody else's -- and its restore's `down` is
        then refused (rc 5) and the fabric stays. The run reads `ndt status`'s claim line first."""
        for text in (CLAIM_NONE, CLAIM_FOREIGN, CLAIM_EXPIRED, "lab\n  measuring nothing\n"):
            self.s.behave(status={"stdout": text})
            st, j, _, _ = self.s.post("/cells/lab_cell/run")
            self.assertEqual((st, j["error"]), (409, "claim"), text)
        self.assertEqual(self.s.runs(), [])
        self.s.behave(status={"stdout": CLAIM_YOURS})
        self.assertEqual(self.run_cell()["rc_class"], "pass")
        self.assertEqual(len(self.s.runs()), 1)

    def test_only_ndts_own_claim_form_is_yours(self):
        """Intake judge 09-26, finding 2: the check was a PREFIX match on "yours", so a foreign
        owner whose name merely starts with it -- `yours-x` -- passed as this server's own claim.
        ndt prints its own claim as exactly `yours -- <n>m left (until HH:MM:SS)` (ndt:5677,
        claim_line). Every other value -- another owner's, one named to contain the own form,
        EXPIRED, malformed -- is somebody else's or nobody's, and runs nothing."""
        for value in ("yours-x -- 12m left (until 23:40:00)",
                      "yoursx -- 12m left (until 23:40:00)",
                      "yours -- 5m left (until 12:00:00) -- 12m left (until 23:40:00)",
                      "yours -- 12m left",
                      "EXPIRED 3m ago (was yours) -- treated as free",
                      "malformed (no usable expires=) -- treated as free"):
            self.s.behave(status={"stdout": "lab\n  claim          %s\n" % value})
            st, j, _, _ = self.s.post("/cells/lab_cell/run")
            self.assertEqual((st, j.get("error"), j.get("claim")), (409, "claim", value), value)
        self.assertEqual(self.s.runs(), [])
        # ...and the own form itself, whatever the minutes, is yours
        self.s.behave(status={"stdout": "lab\n  claim          yours -- 240m left (until 03:59:00)\n"})
        self.assertEqual(self.run_cell()["rc_class"], "pass")
        self.assertEqual(len(self.s.runs()), 1)

    def test_no_read_slot_is_not_a_claim_and_says_so(self):
        """Intake judge 09-26, finding 5: with both read slots taken past --read-queue-wait, the
        claim was never read at all -- ndt status did not run. The run is refused (409 claim, so a
        walk records it as blocked), and the answer says THAT, not "ndt status did not answer"."""
        import threading
        s = GridServe(extra=["--read-queue-wait", "1"]).start()
        try:
            s.behave(status={"stdout": CLAIM_YOURS, "sleep": 5})
            held = []
            ts = [threading.Thread(target=lambda: held.append(s.get("/status")[0])) for _ in range(2)]
            for t in ts:
                t.start()
            deadline = time.monotonic() + 10
            while len(s.calls()) < 2 and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertEqual(len(s.calls()), 2, "the two reads that hold the slots did not start")
            st, j, _, _ = s.post("/cells/lab_cell/run")
            for t in ts:
                t.join(30)
            self.assertEqual((st, j.get("error")), (409, "claim"), j)
            self.assertIn("no read slot", j["note"])
            self.assertNotIn("did not answer", j["note"])
            self.assertEqual(len(s.calls()), 2, "the claim read ran ndt without a read slot")
            self.assertEqual(s.runs(), [])
            self.assertEqual(held, [200, 200])
        finally:
            s.close()

    def test_a_status_past_its_timeout_is_not_a_claim(self):
        """Intake judge 09-26, finding 5: ndt status printed `yours` and then hung past
        --read-timeout. A read that was stopped is not a reading: the run is refused, the answer
        says it timed out, and what ndt printed before it was stopped is kept, by read id."""
        s = GridServe(extra=["--read-timeout", "2"]).start()
        try:
            s.behave(status={"stdout": CLAIM_YOURS, "sleep_after": 30})
            st, j, _, _ = s.post("/cells/lab_cell/run")
            self.assertEqual((st, j.get("error")), (409, "claim"), j)
            self.assertIn("did not answer within 2 s", j["note"])
            self.assertEqual(s.runs(), [])
            st, _, _, raw = s.get("/reads/%s/log/stdout" % j.get("read"))
            self.assertEqual(st, 200)
            self.assertIn(b"yours -- 30m left", raw, "the partial output was not kept")
        finally:
            # under a mutation that stops killing the group the stub sleeps on: stopped here by
            # the pid it recorded
            for c in s.calls():
                if base._pid_alive(c["pid"]):
                    os.kill(c["pid"], signal.SIGKILL)
            s.close()

    def test_offline_cell_run_does_not_ask_for_the_claim(self):
        self.s.behave(status={"stdout": CLAIM_NONE})
        self.assertEqual(self.run_cell("offline_cell")["rc_class"], "pass")
        self.assertEqual([c["argv"] for c in self.s.calls()], [], "a `requires none` cell read the claim")

    def test_a_cell_that_writes_shared_state_needs_confirmation(self):
        """Judge r2 finding 2: this cell parks host_count_override at 128 and writes it back; killed
        in between (systemd-oomd does that here) it stays 128. Said, and confirmed, before it runs."""
        st, j, _, _ = self.s.get("/cells")
        by = {c["name"]: c for c in j["cells"]}
        self.assertIn("host_count_override", by[H4]["writes_shared_state"] or "")
        self.assertIsNone(by["lab_cell"].get("writes_shared_state", "absent"))
        st, j, _, _ = self.s.post("/cells/%s/run" % H4)
        self.assertEqual((st, j["error"]), (400, "confirm"))
        self.assertIn("host_count_override", j["note"])
        for bad in ({"confirm_shared_state_write": "yes"}, {"confirm_shared_state_write": 1}, {"confirm": True}):
            st, _, _, _ = self.s.post("/cells/%s/run" % H4, bad)
            self.assertEqual(st, 400, bad)
        self.assertEqual(self.s.runs(), [])
        st, j, _, _ = self.s.post("/cells/%s/run" % H4, {"confirm_shared_state_write": True})
        self.assertEqual(st, 202, j)
        self.s.wait(j["job"]["id"])
        self.assertEqual(len(self.s.runs()), 1)

    def test_a_judge_past_its_timeout_is_stopped(self):
        """Judge r2 finding 4: the grid's calls had subprocess.run(timeout=60) -- a kill of the child
        only, an unbounded wait for the pipe after it, and a 500 from TimeoutExpired."""
        s = GridServe(extra=["--read-timeout", "1"]).start()
        try:
            with open(os.path.join(s.fix, "lab_cell", "old", "JUDGE_SLEEP"), "w") as f:
                f.write("20")
            t0 = time.monotonic()
            st, j, _, _ = s.get("/cells/lab_cell/old")
            self.assertLess(time.monotonic() - t0, 10)
            self.assertEqual((st, j.get("timed_out"), j.get("verdict")), (200, True, None))
            time.sleep(0.3)
            pids = [c["pid"] for c in s.grid_calls("judge-sleeping")]
            self.assertEqual(len(pids), 1)
            self.assertFalse(base._pid_alive(pids[0]), "the timed-out judge is still running")
        finally:
            # under a mutation that stops killing the group (C23) the stub sleeps on: stopped here
            # by the pid it recorded, so a gate run leaves nothing behind
            for c in s.grid_calls("judge-sleeping"):
                if base._pid_alive(c["pid"]):
                    os.kill(c["pid"], signal.SIGKILL)
            s.close()

    def test_cell_run_needs_the_token(self):
        st, j, _, _ = self.s.post("/cells/lab_cell/run", token=None)
        self.assertEqual((st, j["error"]), (403, "token"))
        st, _, _, _ = self.s.post("/cells/lab_cell/run", {"force": True})
        self.assertEqual(st, 400)
        self.assertEqual(self.s.runs(), [])

    def test_cell_run_skip_is_not_a_pass(self):
        self.s.grid["runs"]["lab_cell"] = {"rc": 0, "judge": RUN_SKIP}
        self.s.write_grid()
        job = self.run_cell()
        self.assertEqual((job["rc"], job["rc_class"], job["cell_verdict"]["state"]), (0, "skip", "SKIP"))

    def test_cell_run_restore_failure_is_harness(self):
        self.s.grid["runs"]["lab_cell"] = {"rc": 2, "judge": RUN_PASS, "restore_fail": True}
        self.s.write_grid()
        job = self.run_cell()
        self.assertEqual((job["rc"], job["rc_class"]), (2, "harness"))
        self.assertIn("NOT restored", job["meaning"])

    def test_cell_run_marks_red_to_green(self):
        job = self.run_cell()
        st, j, _, _ = self.s.get("/cells/lab_cell/runs/" + job["id"])
        rows = {r["id"]: r for r in j["compare"]}
        self.assertEqual({k for k, r in rows.items() if r["red_to_green"]}, {"a2_no_boom", "a3_record_written"})
        self.assertEqual([k for k, r in rows.items() if r["still_red"]], [])
        self.assertIn("prints no boom", j["expected"])
        st, _, _, _ = self.s.get("/cells/offline_cell/runs/" + job["id"])
        self.assertEqual(st, 404, "a run is read back only under its own cell")

    def test_cell_run_holds_the_slot(self):
        self.s.grid["runs"]["lab_cell"] = {"rc": 0, "judge": RUN_PASS, "sleep": 2}
        self.s.write_grid()
        st, j, _, _ = self.s.post("/cells/lab_cell/run")
        first = j["job"]["id"]
        for p, b in (("/up", {"plane": "ovs", "hosts": 4}), ("/cells/offline_cell/run", {}), ("/release", {})):
            st, j, _, _ = self.s.post(p, b)
            self.assertEqual((st, j["job"]["id"]), (409, first), p)
        self.s.wait(first)
        self.assertEqual(len(self.s.runs()), 1)
        # the one ndt call is the first run's claim read -- the refused writes ran nothing
        self.assertEqual([c["argv"] for c in self.s.calls()], [["status"]])

    def test_job_raw_cannot_leave_the_raw_root(self):
        job = self.run_cell()
        st, _, _, raw = self.s.get("/jobs/%s/raw/2026-09-24/lab_cell/up.log" % job["id"])
        self.assertEqual((st, raw), (200, b"up. ready\n"))
        for rel in ("../../../token", "2026-09-24/../../../jobs", "/etc/passwd"):
            st, _, _, _ = self.s.get("/jobs/%s/raw/%s" % (job["id"], rel))
            self.assertEqual(st, 404, rel)


# --- the guided walk --------------------------------------------------------------------------

class GuidedWalk(GridCase):
    def steps(self, gid):
        return [s["step"] for s in self.s.get("/guided/" + gid)[1]["walk"]["steps"]]

    def test_the_lab_is_released_before_the_verdict(self):
        gid = self.walk()
        steps = self.steps(gid)
        self.assertLess(steps.index("release"), steps.index("verdict"))
        self.assertEqual(steps.index("release"), steps.index("run") + 1)

    def test_walk_steps_for_a_lab_cell(self):
        gid = self.walk("lab_cell")
        self.assertEqual(self.steps(gid), ["old", "new", "status", "claim", "run", "release", "compare", "verdict"])
        w = self.s.get("/guided/" + gid)[1]["walk"]
        self.assertTrue(all(s["look_at"] for s in w["steps"]))
        self.assertIn("prints no boom", w["steps"][4]["look_at"])

    def test_walk_steps_for_an_offline_cell(self):
        self.assertEqual(self.steps(self.walk("offline_cell")), ["old", "run", "compare", "verdict"])

    def test_next_needs_the_token(self):
        gid = self.walk()
        st, j, _, _ = self.s.post("/guided/%s/next" % gid, token=None)
        self.assertEqual((st, j["error"]), (403, "token"))
        st, _, _, _ = self.s.post("/cells/lab_cell/guided", token=None)
        self.assertEqual(st, 403)
        st, _, _, _ = self.s.post("/guided/%s/verdict" % gid, {"verdict": "green"}, token=None)
        self.assertEqual(st, 403)

    def test_happy_walk_runs_exactly_the_expected_calls(self):
        gid = self.walk()
        for step in ("old", "new", "status", "claim", "run", "release", "compare"):
            w = self.settle(gid)
            self.assertEqual(w["steps"][w["current"]]["step"], step)
            self.next(gid)
        w = self.settle(gid)
        self.assertEqual(w["steps"][w["current"]]["step"], "verdict")
        # the lab is already given back while the walk waits on Adam
        self.assertEqual([c["argv"][0] for c in self.s.calls()], ["status", "claim", "status", "release"])
        cmp_ = [s for s in w["steps"] if s["step"] == "compare"][0]["result"]
        self.assertEqual(sorted(cmp_["red_to_green"]), ["a2_no_boom", "a3_record_written"])
        st, j, _, _ = self.s.post("/guided/%s/verdict" % gid, {"verdict": "green", "note": "saw a2 flip"})
        self.assertEqual(st, 200, j)
        w = self.settle(gid)
        self.assertTrue(w["done"])
        self.assertEqual(w["verdict"]["verdict"], "green")
        self.assertEqual([c["argv"][0] for c in self.s.calls()], ["status", "claim", "status", "release"])
        self.assertEqual(self.s.calls()[1]["argv"][:2], ["claim", "30"])
        self.assertEqual(len(self.s.runs()), 1)
        self.next(gid, want=409)

    def test_refused_claim_blocks_the_run(self):
        self.s.behave(claim={"rc": 1, "stderr": "the lab is already claimed by orch-0924\n"})
        gid = self.walk()
        for _ in range(4):                       # old, new, status, claim
            self.settle(gid)
            self.next(gid)
        w = self.settle(gid)
        self.assertEqual(w["steps"][w["current"]]["step"], "claim")
        self.assertIn("refused", w["blocked"])
        self.next(gid)                           # retries the claim, not the run
        self.settle(gid)
        self.assertEqual([c["argv"][0] for c in self.s.calls()], ["status", "claim", "claim"])
        self.assertEqual(self.s.runs(), [])

    def test_failed_restore_blocks_and_never_releases(self):
        self.s.grid["runs"]["lab_cell"] = {"rc": 2, "judge": RUN_PASS, "restore_fail": True}
        self.s.write_grid()
        gid = self.walk()
        for _ in range(5):                       # old, new, status, claim, run
            self.settle(gid)
            self.next(gid)
        w = self.settle(gid)
        self.assertEqual(w["steps"][w["current"]]["step"], "run")
        self.assertIn("harness", w["blocked"])
        st, j, _, _ = self.s.post("/guided/%s/abort" % gid)
        self.assertIn("still held", j["note"])
        self.next(gid, want=409)
        self.assertEqual([c["argv"][0] for c in self.s.calls()], ["status", "claim", "status"])

    def test_red_cell_still_reaches_the_verdict(self):
        self.s.grid["runs"]["lab_cell"] = {"rc": 1, "judge": RUN_FAIL}
        self.s.write_grid()
        gid = self.walk()
        for _ in range(7):                       # old, new, status, claim, run, release, compare
            self.settle(gid)
            self.next(gid)
        w = self.settle(gid)
        self.assertEqual(w["steps"][w["current"]]["step"], "verdict")
        cmp_ = [s for s in w["steps"] if s["step"] == "compare"][0]["result"]
        self.assertEqual(sorted(cmp_["still_red"]), ["a2_no_boom", "a3_record_written"])
        self.assertEqual([c["argv"][0] for c in self.s.calls()], ["status", "claim", "status", "release"],
                         "a red cell whose restore passed still gives the lab back")
        self.assertEqual(cmp_["red_to_green"], [])

    def test_a_run_with_no_verdict_line_blocks(self):
        self.s.grid["runs"]["offline_cell"] = {"rc": 0, "judge": ""}
        self.s.write_grid()
        gid = self.walk("offline_cell")
        for _ in range(2):                       # old, run
            self.settle(gid)
            self.next(gid)
        w = self.settle(gid)
        self.assertEqual(w["steps"][w["current"]]["step"], "run")
        self.assertTrue(w["blocked"])

    def test_walk_run_rechecks_the_claim(self):
        """Judge r2 finding 3, second half: the walk's claim step passed, and by its run step the
        claim is gone (another tab's walk released it). The run is not started."""
        gid = self.walk()
        for _ in range(4):                       # old, new, status, claim
            self.settle(gid)
            self.next(gid)
        self.settle(gid)
        self.s.behave(status={"stdout": CLAIM_NONE})
        self.next(gid)                           # run
        w = self.settle(gid)
        self.assertEqual(w["steps"][w["current"]]["step"], "run")
        self.assertIn("claim", w["blocked"] or "")
        self.assertEqual(self.s.runs(), [])

    def test_walk_for_a_shared_state_cell_needs_confirmation(self):
        st, j, _, _ = self.s.post("/cells/%s/guided" % H4)
        self.assertEqual((st, j.get("error")), (400, "confirm"))
        st, j, _, _ = self.s.post("/cells/%s/guided" % H4, {"confirm_shared_state_write": True})
        self.assertEqual(st, 201, j)
        run = [x for x in j["walk"]["steps"] if x["step"] == "run"][0]
        self.assertIn("host_count_override", run["look_at"])
        gid = j["walk"]["id"]
        for _ in range(4):                       # old, status, claim, run
            self.settle(gid)
            self.next(gid)
        self.settle(gid)
        self.assertEqual(len(self.s.runs()), 1, "a confirmed walk still runs the cell")

    def test_the_verdict_is_adams(self):
        gid = self.walk("offline_cell")
        st, _, _, _ = self.s.post("/guided/%s/verdict" % gid, {"verdict": "green"})
        self.assertEqual(st, 409, "no verdict before the compare step")
        for _ in range(3):                       # old, run, compare
            self.settle(gid)
            self.next(gid)
        self.settle(gid)
        j = self.next(gid, want=409)
        self.assertEqual(j["error"], "yours")
        for bad in ({"verdict": "pass"}, {"verdict": "green", "x": 1}, {"verdict": "red", "note": "a\x00b"}, {}):
            st, _, _, _ = self.s.post("/guided/%s/verdict" % gid, bad)
            self.assertEqual(st, 400, bad)
        st, j, _, _ = self.s.post("/guided/%s/verdict" % gid, {"verdict": "red", "note": "b1 still says it\nline 2"})
        self.assertEqual((st, j["walk"]["done"], j["walk"]["verdict"]["verdict"]), (200, True, "red"))

    def test_get_does_not_move_a_walk(self):
        gid = self.walk()
        self.settle(gid)
        self.next(gid)                           # old
        path = os.path.join(self.s.state, "guided", gid + ".json")
        before = base._read(path)

        def acting():   # grid calls other than the list and the meta reads a lookup makes
            return [c for c in self.s.grid_calls() if c["argv"] != ["--list"] and c["argv"][1:2] != ["meta"]]
        calls, grid_before = len(self.s.calls()), len(acting())
        for _ in range(3):
            self.s.get("/guided/" + gid)
            self.s.get("/guided")
        self.assertEqual(base._read(path), before)
        self.assertEqual(len(self.s.calls()), calls)
        self.assertEqual(len(acting()), grid_before)
        self.assertEqual(self.s.runs(), [])
        w = self.s.get("/guided/" + gid)[1]["walk"]
        self.assertEqual(w["steps"][w["current"]]["step"], "new")

    def test_walk_survives_a_restart(self):
        gid = self.walk()
        self.settle(gid)
        self.next(gid)
        self.s.stop(signal.SIGKILL, group=True)
        self.s.start()
        w = self.s.get("/guided/" + gid)[1]["walk"]
        self.assertEqual((w["cell"], w["steps"][w["current"]]["step"]), ("lab_cell", "new"))

    def test_old_that_no_longer_fails_blocks_the_walk(self):
        self.s.fixture("lab_cell", "old", NEW_LAB, 0, expected="a2_no_boom\n")
        gid = self.walk()
        self.next(gid)
        w = self.settle(gid)
        self.assertEqual(w["steps"][w["current"]]["step"], "old")
        self.assertIn("no longer judges FAIL", w["blocked"])


class SharedStateRegistry(unittest.TestCase):
    """cells.WRITES_SHARED_STATE is this service's own list, so it is held to the real grid of
    this tree: a cell that names one of the P4 knob files is on it, and nothing else is."""

    def test_the_registry_matches_the_real_grid(self):
        sys.path.insert(0, base.SERVE_DIR)
        try:
            import importlib
            cells = importlib.reload(importlib.import_module("cells"))
        finally:
            sys.path.remove(base.SERVE_DIR)
        grid = os.path.join(base.REPO, "tools", "test_workflow", "live_cells")
        touching = set()
        for f in sorted(os.listdir(grid)):
            if not f.endswith(".sh") or f in ("run_cells.sh", "_cell_lib.sh"):
                continue
            text = base._read(os.path.join(grid, f))
            if any(k in text for k in cells.SHARED_STATE_FILES):
                touching.add(f[:-3])
        self.assertEqual(touching, set(cells.WRITES_SHARED_STATE))
        self.assertIn(H4, touching)


if __name__ == "__main__":
    unittest.main(verbosity=2)
