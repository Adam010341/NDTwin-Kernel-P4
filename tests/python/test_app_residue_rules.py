#!/usr/bin/env python3
"""Which flow entries can `ndt apps stop` / `ndt apps orphans` NOT rule out as an app's residue?

[Co-developed with claude code -- Adam]

KNOWN-ISSUES G-12, measured 2026-09-05 (R6, 1/1, OVS). An app that took a lock, installed a
rule and was then killed by pid left both behind, and every cleanliness verb went green over
them: `ndt apps orphans` answered `ok  no untracked app processes` rc 0 and `ndt status
--check` answered rc 0. Neither was broken -- they look at PROCESSES. Nothing looked at what a
process had changed and left. Adam's decision (09-05 grill round 5): list it, do not delete it.

The subject here is `suspect_rules`, the pure half of `residue_rule_lines` in
tools/test_workflow/ndt, extracted verbatim from between its BEGIN/END markers and driven with
FAKE kernel responses -- the real one needs a fabric, a kernel on :8000 and traffic.

🔴 HOW GOOD IS THE ATTRIBUTION, and the reason these cases are shaped the way they are: there
is nothing to attribute WITH. Flow entries carry `cookie`, and it is 0 --
src/ndt_core/collection/Classifier.cpp:229 says "Many hardware switches export cookie=0 for all
rules, so cookie cannot be used as identity", and p4_proxy/proxy_agent/ryu_flow_stats.py:181
writes the constant 0 into every synthesised row. The lock has no owner ON PURPOSE
(LockManager.hpp: the lease id "is deliberately not an owner field"). So the only discriminator
is TIME, and time cannot separate two callers that overlapped. Every case below is therefore a
case about a WINDOW, and `test_two_apps_that_overlapped_get_the_same_rule` pins the limit
rather than hiding it.

🔴 THREE DIRECTIONS, because "list more" has two obvious wrong answers:
  * a selector that returns EVERY rule passes every "is the residue listed" case and buries it
    under the fabric's own baseline -- `test_the_baseline_fabric_is_excluded` is that case;
  * a selector that returns NOTHING passes every "is the baseline excluded" case --
    `test_a_rule_installed_inside_the_window_is_listed` is that one;
  * a selector that silently drops a rule it cannot date reports a clean network it never
    looked at, which is G-12's own failure shape in a new place --
    `test_a_rule_with_no_duration_is_listed_as_unknown_not_dropped`.

    python3 tests/python/test_app_residue_rules.py
    NDT_UNDER_TEST=/tmp/x/ndt python3 tests/python/test_app_residue_rules.py
"""
import json
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
NDT = os.environ.get("NDT_UNDER_TEST", os.path.join(REPO, "tools", "test_workflow", "ndt"))

MARKERS = re.compile(
    r"# --- BEGIN residue_rules.*?\n(.*?)# --- END residue_rules ---", re.S)


def load_region():
    """Everything between the markers, lifted out of `ndt`.

    Extraction rather than import because the code lives inside a heredoc in a bash script:
    the alternative is a second copy of it here, and a second copy is the thing that goes
    stale while both halves stay green.
    """
    with open(NDT) as fh:
        text = fh.read()
    m = MARKERS.search(text)
    if not m:
        raise AssertionError(
            "the residue_rules markers are not in %s -- the gate cannot see the subject" % NDT)
    ns = {}
    exec(compile(m.group(1), "<residue_rules from ndt>", "exec"), ns)
    for want in ("suspect_rules", "window_blindspot"):
        if want not in ns:
            raise AssertionError("%s is not defined inside the markers" % want)
    return ns


def load_suspect_rules():
    return load_region()["suspect_rules"]


NOW = 1_757_000_000          # the wall clock the fake kernel answers were taken at
APP_STARTED = NOW - 600      # the app ran for the last ten minutes


def flow(duration_sec, dpid=2, priority=96, actions=None, match=None, table_id=0):
    """One row in the shape /ndt/get_switch_openflow_table_entries really returns.

    Field names and types copied from doc/2026-01-02_ndt_api.md section 5, including the
    `cookie: 0` that is the reason none of this can be attributed properly.
    """
    row = {
        "actions": actions if actions is not None else ["OUTPUT:2"],
        "byte_count": 0,
        "cookie": 0,
        "duration_nsec": 91000000,
        "flags": 0,
        "hard_timeout": 0,
        "idle_timeout": 0,
        "length": 96,
        "match": match if match is not None else {"dl_type": 2048, "nw_dst": "10.0.0.3"},
        "packet_count": 0,
        "priority": priority,
        "table_id": table_id,
    }
    if duration_sec is not None:
        row["duration_sec"] = duration_sec
    return (dpid, row)


def entries(*rows):
    """Group (dpid, row) pairs into the per-switch envelope the endpoint wraps them in."""
    by_dpid = {}
    for dpid, row in rows:
        by_dpid.setdefault(dpid, []).append(row)
    return [{"dpid": d, "flows": {str(d): rs}} for d, rs in sorted(by_dpid.items())]


class SuspectRules(unittest.TestCase):
    def setUp(self):
        self.suspect_rules = load_suspect_rules()

    def run_it(self, data, started=APP_STARTED, now=NOW):
        return self.suspect_rules(data, started, now)

    # --- the finding itself ---------------------------------------------------------------

    def test_a_rule_installed_inside_the_window_is_listed(self):
        """G-12's own residue: s2, pri 96, ["OUTPUT:2"], installed while the app was alive."""
        out = self.run_it(entries(flow(300)))
        self.assertEqual(1, len(out), out)
        self.assertIn("dpid=2", out[0])
        self.assertIn("pri=96", out[0])
        self.assertIn('"OUTPUT:2"', out[0])
        self.assertIn("installed 5m00s ago", out[0])

    def test_the_baseline_fabric_is_excluded(self):
        """🔴 The direction that makes the report readable at all.

        `ndt up` installs the fabric's own routing rules, and on a 128-host fabric that is
        thousands of them. A selector that returns everything satisfies every case above and
        buries the one rule that matters.
        """
        out = self.run_it(entries(
            flow(300, priority=96),                       # the app's
            flow(9000, priority=10, dpid=1),              # installed at `ndt up`, long before
            flow(9000, priority=0, dpid=1),
            flow(9000, priority=65535, dpid=1),
        ))
        self.assertEqual(1, len(out), out)
        self.assertIn("pri=96", out[0])

    def test_a_rule_installed_one_second_before_the_window_is_excluded(self):
        out = self.run_it(entries(flow(601)))
        self.assertEqual([], out)

    def test_a_rule_installed_exactly_at_the_window_edge_is_kept(self):
        """Inclusive at the start: the app's very first write must not fall through the seam."""
        out = self.run_it(entries(flow(600)))
        self.assertEqual(1, len(out), out)

    # --- "could not tell" is not "not there" ----------------------------------------------

    def test_a_rule_with_no_duration_is_listed_as_unknown_not_dropped(self):
        """🔴 G-12's failure shape in a new place, and the one a tidy implementation invites.

        A rule that does not say how old it is can be placed neither inside nor outside the
        window. Dropping it produces a shorter, cleaner report that has silently stopped
        looking -- exactly what `ndt apps orphans` was doing over the residue in the first
        place.
        """
        out = self.run_it(entries(flow(None)))
        self.assertEqual(1, len(out), out)
        self.assertIn("age=UNKNOWN", out[0])
        self.assertIn("neither inside nor outside", out[0])

    def test_a_non_integer_duration_is_unknown_rather_than_believed(self):
        dpid, row = flow(300)
        row["duration_sec"] = "300"
        self.assertIn("age=UNKNOWN", self.run_it(entries((dpid, row)))[0])

    def test_a_boolean_duration_is_not_read_as_a_number(self):
        """bool is an int in Python; True would otherwise date a rule to one second ago."""
        dpid, row = flow(300)
        row["duration_sec"] = True
        self.assertIn("age=UNKNOWN", self.run_it(entries((dpid, row)))[0])

    def test_a_negative_duration_is_unknown(self):
        dpid, row = flow(300)
        row["duration_sec"] = -5
        self.assertIn("age=UNKNOWN", self.run_it(entries((dpid, row)))[0])

    def test_unknown_age_rules_are_listed_after_the_dated_ones(self):
        out = self.run_it(entries(flow(300), flow(None, dpid=3)))
        self.assertEqual(2, len(out), out)
        self.assertIn("installed", out[0])
        self.assertIn("age=UNKNOWN", out[1])

    # --- the limit of the method, pinned rather than hidden --------------------------------

    def test_two_apps_that_overlapped_get_the_same_rule(self):
        """🔴 The precision ceiling, asserted so nobody reads the output as attribution.

        Two windows that both contain the install produce the same line. With no cookie and no
        owner there is no way to do better, and the report says SUSPECTED for this reason.
        """
        data = entries(flow(300))
        self.assertEqual(1, len(self.run_it(data, started=NOW - 600)))
        self.assertEqual(1, len(self.run_it(data, started=NOW - 400)))

    def test_a_rule_installed_by_anyone_in_the_window_is_listed(self):
        """A curl by hand looks exactly like an app's write. It is listed, and that is honest."""
        out = self.run_it(entries(flow(120, dpid=7, priority=42,
                                       actions=["OUTPUT:3"], match={"in_port": 1})))
        self.assertEqual(1, len(out), out)
        self.assertIn("dpid=7", out[0])

    # --- shapes the endpoint really produces ----------------------------------------------

    def test_no_switches_at_all_is_empty_not_an_error(self):
        self.assertEqual([], self.run_it([]))
        self.assertEqual([], self.run_it(None))

    def test_a_switch_with_no_flows_key_is_skipped(self):
        self.assertEqual([], self.run_it([{"dpid": 1}]))

    def test_a_switch_whose_flow_list_is_null_is_skipped(self):
        self.assertEqual([], self.run_it([{"dpid": 1, "flows": {"1": None}}]))

    def test_every_switch_is_walked_not_just_the_first(self):
        out = self.run_it(entries(flow(100, dpid=1), flow(100, dpid=2), flow(100, dpid=3)))
        self.assertEqual(3, len(out), out)
        self.assertEqual(["dpid=1", "dpid=2", "dpid=3"],
                         [l.split()[0] for l in out])

    def test_rules_on_one_switch_are_ordered_by_priority_descending(self):
        out = self.run_it(entries(flow(100, priority=10), flow(100, priority=99),
                                  flow(100, priority=50)))
        self.assertEqual(["pri=99", "pri=50", "pri=10"], [l.split()[2] for l in out])

    def test_the_match_and_actions_are_printed_verbatim_enough_to_delete_by(self):
        """The line has to carry what /ndt/delete_flow_entry needs: dpid, priority, match."""
        out = self.run_it(entries(flow(100, dpid=4, priority=96,
                                       match={"in_port": 1, "dl_type": 2048})))
        self.assertIn("dpid=4", out[0])
        self.assertIn("pri=96", out[0])
        self.assertIn('"in_port": 1', out[0])
        self.assertIn('"dl_type": 2048', out[0])

    def test_the_age_is_readable_at_three_scales(self):
        self.assertIn("installed 30s ago", self.run_it(entries(flow(30)))[0])
        self.assertIn("installed 5m00s ago", self.run_it(entries(flow(300)))[0])
        self.assertIn("installed 2h00m ago",
                      self.run_it(entries(flow(7200)), started=NOW - 86400)[0])


class ThePlaneWithNoClock(unittest.TestCase):
    """W16-3: on P4 the flow stats are synthesised and every rule reports duration 0/0.

    🔴 MEASURED, 2026-09-07 (DECISIONS 09-07 01:0x; P4 4 hosts, trunk 862c4bf8, logs/w163-*).
    A route to 10.0.0.3 was installed and /ndt/get_switch_openflow_table_entries read at +12 s
    and +32 s. That entry AND every pre-existing entry answered duration_sec 0, duration_nsec
    0, while packet_count and byte_count moved. p4_proxy/proxy_agent/ryu_flow_stats.py has no
    install time to put in the rows it synthesises.

    Read as an age, that 0 means "installed just now", which places EVERY rule on the plane
    inside EVERY window -- the widening failure M3 exists for, arriving through the data
    instead of through the code. Adam's decision: age=UNKNOWN, list them all, say why.
    """

    def setUp(self):
        ns = load_region()
        self.suspect_rules = ns["suspect_rules"]
        self.window_blindspot = ns["window_blindspot"]

    def p4row(self, **kw):
        dpid, row = flow(0, **kw)
        row["duration_nsec"] = 0
        return (dpid, row)

    # --- the plane says so ------------------------------------------------------------------

    def test_on_p4_every_rule_is_unknown_however_old_it_claims_to_be(self):
        out = self.suspect_rules(entries(flow(300), flow(9000, dpid=1)),
                                 APP_STARTED, NOW, "p4")
        self.assertEqual(2, len(out), out)
        for line in out:
            self.assertIn("age=UNKNOWN (P4 plane", line)

    def test_on_p4_the_baseline_is_listed_too_because_nothing_can_be_excluded(self):
        """🔴 The one place "list everything" is right -- and it has to SAY that is why."""
        out = self.suspect_rules(entries(flow(300, priority=96),
                                         flow(9000, priority=65535, dpid=1)),
                                 APP_STARTED, NOW, "p4")
        self.assertEqual(2, len(out), out)
        self.assertTrue(any("pri=65535" in l for l in out), out)

    def test_p4_is_named_as_blind_before_any_rule_is_read(self):
        why = self.window_blindspot(entries(flow(300)), "p4")
        self.assertIn("synthesise", why)
        self.assertIn("carry NO install time", why)

    def test_p4_is_blind_even_with_an_empty_table(self):
        """The plane's answer must not depend on what happens to be installed right now."""
        self.assertNotEqual("", self.window_blindspot([], "p4"))

    # --- or the data says so ----------------------------------------------------------------

    def test_duration_zero_and_nsec_zero_is_unknown_not_zero_seconds_ago(self):
        out = self.suspect_rules(entries(self.p4row()), APP_STARTED, NOW, "ovs")
        self.assertEqual(1, len(out), out)
        self.assertIn("age=UNKNOWN", out[0])
        self.assertIn("duration_sec=0 AND duration_nsec=0", out[0])
        self.assertNotIn("installed 0s ago", out[0])

    def test_a_table_that_is_entirely_0_0_is_reported_blind_whatever_the_plane(self):
        why = self.window_blindspot(entries(self.p4row(), self.p4row(dpid=1)), "unknown")
        self.assertIn("duration_sec=0 AND duration_nsec=0", why)

    # --- 🔴 and the other direction, without which "call everything unknown" would pass -----

    def test_a_genuinely_sub_second_rule_is_still_dated(self):
        """sec 0 with nsec set is a rule installed this second. A real switch reports that."""
        dpid, row = flow(0)
        row["duration_nsec"] = 4_000_000
        out = self.suspect_rules(entries((dpid, row)), APP_STARTED, NOW, "ovs")
        self.assertEqual(1, len(out), out)
        self.assertIn("installed 0s ago", out[0])
        self.assertNotIn("age=UNKNOWN", out[0])

    def test_an_ovs_table_with_real_durations_is_not_reported_blind(self):
        self.assertEqual("", self.window_blindspot(entries(flow(300), flow(9000)), "ovs"))

    def test_an_empty_table_is_not_reported_blind_on_ovs(self):
        """No rows is "nothing installed", not "no clock". Saying blind here would make every
        idle OVS fabric look unmeasurable."""
        self.assertEqual("", self.window_blindspot([], "ovs"))
        self.assertEqual("", self.window_blindspot(None, "ovs"))

    def test_one_dated_row_among_zeros_is_enough_to_keep_the_table_readable(self):
        why = self.window_blindspot(entries(self.p4row(), flow(300, dpid=1)), "ovs")
        self.assertEqual("", why)

    def test_the_window_still_excludes_old_rules_on_a_readable_plane(self):
        """🔴 The plane argument must not switch the whole selector off."""
        out = self.suspect_rules(entries(flow(9000)), APP_STARTED, NOW, "ovs")
        self.assertEqual([], out)


def body_of(text, opener):
    """One shell function's body, from its `name() {` to the first line that is just `}`."""
    start = text.index(opener)
    return text[start:text.index("\n}\n", start)]


class TheSubjectIsTheShippedCode(unittest.TestCase):
    """🔴 Extraction is only worth anything if it is extracting the code that RUNS."""

    def test_the_markers_are_present_and_wrap_a_definition(self):
        self.assertTrue(callable(load_suspect_rules()))

    def test_ndt_calls_it_exactly_once(self):
        with open(NDT) as fh:
            text = fh.read()
        self.assertEqual(
            1, text.count("for line in suspect_rules(entries, started, now, plane):"),
            "suspect_rules is defined but the block does not call it with the plane")

    def test_the_plane_reaches_the_selector_from_the_shell(self):
        """🔴 W16-3 is only fixed if the plane the shell read is the plane python is given.

        A `plane` parameter that defaults to "unknown" and is never passed would leave every
        case in ThePlaneWithNoClock green and the shipped tool blind, which is the shape of
        every "the fix is in the file but nothing calls it" defect in this repository.
        """
        with open(NDT) as fh:
            text = fh.read()
        report = body_of(text, "residue_report() {")
        self.assertEqual(1, report.count('residue_rule_lines "$started" "$now" "$plane"'))
        self.assertEqual(1, report.count('plane="$(live_dataplane_kind)"'))
        self.assertEqual(1, text.count('plane = sys.argv[3]'))

    def test_the_blindspot_is_announced_by_the_shell_too(self):
        with open(NDT) as fh:
            text = fh.read()
        self.assertEqual(1, text.count('print("CANNOTWINDOW " + blind)'))
        self.assertIn('CANNOTWINDOW\\ *', text)

    def test_the_three_call_sites_that_report_residue_are_wired(self):
        """`stop`, `orphans` and (since 09-07) `status --check`. One wired and one not is the
        shape G-12 was found in."""
        with open(NDT) as fh:
            text = fh.read()
        self.assertEqual(1, text.count("residue_report $targets"))
        self.assertEqual(1, body_of(text, "cmd_apps() {").count("residue_report $APP_NAMES"))
        self.assertEqual(1, body_of(text, "status_residue_row() {")
                         .count("residue_report $APP_NAMES"))

    def test_the_exit_code_is_wired_to_both_verbs_that_can_carry_one(self):
        """W16-1/W16-2. Adam ruled residue must make these red; a report nobody can fail is
        one more green check, which is what G-12 is a finding about."""
        with open(NDT) as fh:
            text = fh.read()
        self.assertEqual(1, body_of(text, "cmd_apps() {").count("residue_verdict; local rrc=$?"),
                         "`ndt apps orphans` does not take its exit code from the residue")
        self.assertEqual(1, body_of(text, "status_residue_row() {")
                         .count("residue_verdict; local rrc=$?"),
                         "the --check row does not take its verdict from the residue")
        self.assertEqual(1, text.count("status_residue_row"
                                       "\n        (( ${#STATUS_RESIDUE_PROBLEMS[@]} > 0 ))"),
                         "`ndt status --check` does not feed the residue into its problems")

    def test_nothing_in_the_residue_path_deletes_anything(self):
        """Adam's decision, 09-05 grill round 5: list it, do not delete it.

        🔴 Checked per LINE, not by searching the body for a word. The body legitimately
        CONTAINS "delete_flow_entry" and "curl" -- inside the `info` lines that hand the
        operator the command to remove a rule by hand -- so a substring search over the whole
        function has to be written so loosely that a real `curl -X POST .../delete_flow_entry`
        slips past it. That is not hypothetical: the mutation gate's M9 survived exactly that
        version of this test. A line that is not an output statement may not name a mutating
        verb at all.

        🔴 BOTH functions that walk the residue, since 09-07: `status_residue_row` drives the
        same scan for `ndt status --check`, and a checker that stopped at residue_report would
        leave the newer caller unguarded.
        """
        with open(NDT) as fh:
            text = fh.read()
        prints = ("info ", "warn ", "err ", "ok ", "say ", "printf ", "echo", "#")
        for fn in ("residue_report() {", "status_residue_row() {"):
            start = text.index(fn)
            end = text.index("\n}\n", start)
            body = text[start:end]
            for raw in body.splitlines():
                line = raw.strip()
                if not line or line.startswith(prints):
                    continue
                for verb in ("curl", "delete_", "release_lock", "rm ", "ovs-ofctl del", "wget"):
                    self.assertNotIn(
                        verb, line,
                        "%s must report, never remove -- this line acts: %r" % (fn, raw))


if __name__ == "__main__":
    unittest.main(verbosity=2)
