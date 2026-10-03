#!/usr/bin/env bash
#
# Mutation gate for tools/p4_health and its offline suites (design 5.2-③: M1-M18, plus the
# section 12 refinements, the Q3(b) cells, the seal of the reading-layer test, recover.sh, and one
# mutant per decision branch the Cut 1 review listed).
#
# [Co-developed with claude code -- Adam]
#
# 🔴 THE MUTANT IS A COPY, AND THE ORIGINAL IS NEVER WRITTEN (the rule of
# mutate_drive_exercise.sh:16-30). tools/p4_health is copied whole into a temp directory, the
# copy is mutated, and the suites are pointed at it through P4_HEALTH_UNDER_TEST (recover.sh
# through P4_HEALTH_RECOVER_UNDER_TEST). Every source's sha256 is taken before the first
# mutation and again at the end.
#
# Every mutation names the ONE test that must go red. A mutant that does not parse, an anchor
# that moved or matches twice, a run that hung, or the wrong test going red are SURVIVORS. A
# comment-only edit must leave every suite green (the negative control).
#
# Usage:  tests/shell/mutate_p4_health.sh
#         PYTHON=... tests/shell/mutate_p4_health.sh
#         ANCHOR_CHECK=1 tests/shell/mutate_p4_health.sh     # counts anchors only; NOT a verdict
# Exit:   0 all caught and the control green; 1 a survivor; 2 refused.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && cd .. && pwd)"
PYTHON="${PYTHON:-$HOME/miniconda3/envs/ryu-env/bin/python}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"
PKG="$REPO/tools/p4_health"
TABLE="$PKG/cells/table.py"
VERDICT="$PKG/cells/verdict.py"
EXPECTEDPY="$PKG/expected.py"
LABROUND="$PKG/lab_round.py"
SNIFF="$PKG/collect/sniff.py"
OBSERVE="$PKG/observe.py"
THRIFT="$PKG/collect/thrift.py"
CONFIG="$PKG/collect/config.py"
PROXY="$PKG/collect/proxy.py"
S0PY="$PKG/s0.py"
RECOVER="$PKG/recover.sh"
REPORTPY="$PKG/report.py"
THROWAWAY="$PKG/throwaway.py"
KERNEL="$PKG/collect/kernel.py"
FRAMES="$PKG/frames.py"
PROBEPY="$PKG/probe.py"
CELLS_TEST="$REPO/tests/python/test_p4_health_cells.py"
COLLECT_TEST="$REPO/tests/python/test_p4_health_collect.py"
RECOVER_TEST="$REPO/tests/shell/test_p4_health_recover.sh"

printf 'gate       : %s\n' "${BASH_SOURCE[0]}"
printf 'cwd        : %s\n' "$PWD"
printf 'interpreter: %s (%s)\n' "$(realpath "$PYTHON" 2>/dev/null || echo "MISSING: $PYTHON")" \
    "$("$PYTHON" -c 'import sys; print(sys.version.split()[0])' 2>/dev/null)"
printf 'subject    : %s\n' "$PKG"
printf 'HEAD       : %s (commit)\n' "$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
printf 'tree       : %s (git tree of tools/p4_health at HEAD)%s\n' "$(git -C "$REPO" rev-parse HEAD:tools/p4_health 2>/dev/null)" \
    "$([[ -n "$(git -C "$REPO" status --porcelain -- tools/p4_health tests/python/test_p4_health_cells.py tests/python/test_p4_health_collect.py tests/shell/test_p4_health_recover.sh 2>/dev/null)" ]] && echo ' +UNCOMMITTED changes in the subject or its suites')"
printf 'subject sha: %s\n' "$(cd "$PKG" && find . -name '*.py' -o -name '*.sh' | sort | xargs sha256sum | sha256sum | cut -c1-16)"
echo

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
[[ -d "$PKG" ]] || { echo "REFUSE: $PKG not found" >&2; exit 2; }
[[ -x "$PYTHON" ]] || { echo "REFUSE: no interpreter" >&2; exit 2; }

refuse_anchor_count() {
    echo; echo "🔴 REFUSED: the gate could not count anchors, so it measured nothing. No verdict."; exit 2
}
anchor_count() {
    local out rc
    out="$(ANCHOR="$2" "$PYTHON" - "$1" 2>&1 <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
)"; rc=$?
    if [[ "$rc" -ne 0 || ! "$out" =~ ^[0-9]+$ ]]; then
        echo "🔴 REFUSED: anchor_count could not run (rc=$rc): ${out:-<nothing>}" >&2
        return 2
    fi
    printf '%s\n' "$out"
}

# --- the mutation table --------------------------------------------------------------------------

MUT_LABEL=(); MUT_SRC=(); MUT_ANCHOR=(); MUT_REPL=(); MUT_EXPECT=()
add() { MUT_LABEL+=("$1"); MUT_SRC+=("$2"); MUT_ANCHOR+=("$3"); MUT_REPL+=("$4"); MUT_EXPECT+=("$5"); }

# M1-M18: design 5.2-③, in its order.
add "M1. a 2xx answer is GREEN whatever it says" \
    "$TABLE" \
    '    mine = counter_reading(a)' \
    '    mine = counter_reading(a)
    if 200 <= (a.get("http") or 0) < 300:
        return green("MUTANT: a 2xx is a pass")' \
    'test_k1_thrift_n_ndtwin_n_plus_1_is_red'

add "M2. a route that does not exist reads as an object that is absent" \
    "$TABLE" \
    '    return A(obs).get("route") is False' \
    '    return False  # MUTANT: no route is just no value' \
    'test_r2_with_no_route_is_a_structural_red_not_an_absent_value'

add "M3. sent is what the sender was asked to send" \
    "$SNIFF" \
    '            total = (total or 0) + int(m.group(2))' \
    '            total = (total or 0) + int(m.group(4) or m.group(2))  # MUTANT: requested' \
    'test_sent_is_what_the_sender_says_it_sent'

add "M4. the oracle column reads the proxy" \
    "$OBSERVE" \
    '    oracle = {"delta": th1[1] - th0[1]} if (th0 is not None and th1 is not None) else None' \
    '    oracle = {"delta": mine1 - mine0} if (th0 is not None and th1 is not None) else None  # MUTANT' \
    'test_the_oracle_is_thrifts_and_never_the_proxys'

add "M5. a 503 counter read is a zero" \
    "$TABLE" \
    '    if a.get("http") != 200:
        return None
    return a.get("delta")' \
    '    if a.get("http") == 503:
        return 0  # MUTANT: 503 is a zero
    if a.get("http") != 200:
        return None
    return a.get("delta")' \
    'test_k1_503_is_not_a_zero'

add "M6. NOT RUN counts as green" \
    "$VERDICT" \
    '    counted = [v for v in verdicts if v in COUNTED]' \
    '    counted = [GREEN if v == NOT_RUN else v for v in verdicts if v in COUNTED + (NOT_RUN,)]  # MUTANT' \
    'test_a_dimension_with_only_not_run_cells_is_undecided'

add "M7. the rollup is best-of" \
    "$VERDICT" \
    '    if all(v == GREEN for v in counted):' \
    '    if any(v == GREEN for v in counted):  # MUTANT: best-of' \
    'test_green_and_red_in_one_dimension_is_partial_not_the_best'

add "M8. the side table is matched on its ethertype alone" \
    "$TABLE" \
    '        if et == ethertype and str(row.get("src_mac", "")).lower() == src \
                and str(row.get("dst_mac", "")).lower() == dst:' \
    '        if et == ethertype:  # MUTANT: the ethertype alone' \
    'test_ch7_row_with_the_wrong_mac_pair_or_no_new_samples_is_not_green'

add "M9. journaled is ignored" \
    "$TABLE" \
    '    if A(obs).get("journaled") is False:' \
    '    if False:  # MUTANT: journaled ignored' \
    'test_t8_journaled_false_is_red'

add "M10. the link-down deadline is infinite" \
    "$TABLE" \
    'LINK_DOWN_DEADLINE_S = 20.0' \
    'LINK_DOWN_DEADLINE_S = float("inf")  # MUTANT' \
    'test_tp2_past_the_deadline_is_red'

add "M11. the decision order is reversed: the oracle first" \
    "$VERDICT" \
    '    obs = obs or {}' \
    '    obs = obs or {}
    if spec.needs_oracle and obs.get("oracle") is None:  # MUTANT: the oracle first
        return Verdict(NOT_RUN, "oracle unreadable", phase="oracle")' \
    'test_a_cannot_answer_with_the_oracle_unreadable_is_a_red_candidate_not_not_run'

add "M12. the prediction is made from this run" \
    "$EXPECTEDPY" \
    '        exp = (expected.get(cid) or {}).get("expected")' \
    '        exp = verdict.label  # MUTANT: the prediction is the verdict of this run' \
    'test_the_prediction_comes_from_the_file_not_from_the_run'

add "M13. a RED whose attribution failed is still RED" \
    "$VERDICT" \
    '    ok = attribution_holds(spec.red_attribution, out.evidence, obs)' \
    '    ok = True  # MUTANT: attribution never checked' \
    'test_a_red_whose_bmv2_attribution_failed_is_unattributed'

add "M14. the knobs are not put back" \
    "$LABROUND" \
    '        ok, why = self.restore_knobs()' \
    '        ok, why = True, ""  # MUTANT: knobs not restored' \
    'test_the_knobs_go_back_as_bytes_and_the_override_is_not_touched'

add "M15. the heartbeat only has to be there" \
    "$TABLE" \
    '    return isinstance(hb, dict) and hb.get("state") == "usable"' \
    '    return hb is not None  # MUTANT' \
    'test_tp4_with_a_heartbeat_that_is_there_but_not_usable_is_not_run'

add "M16. Q1 does not require the stamp flag" \
    "$TABLE" \
    '    stamped = [r for r in (o.get("received") or []) if int(r.get("ident", 0)) & 0x8000]' \
    '    stamped = list(o.get("received") or [])  # MUTANT: no flag required' \
    'test_q1_with_id_1_and_no_stamp_is_not_green'

add "M17a. the finally skips the netem" \
    "$LABROUND" \
    '        for iface in list(self.state["netem"]):' \
    '        for iface in []:  # MUTANT: netem left on' \
    'test_the_round_in_order'

add "M17b. the finally skips the sniffers" \
    "$LABROUND" \
    '        for entry in list(self.state["sniffers"]):' \
    '        for entry in []:  # MUTANT: sniffers left running' \
    'test_the_round_in_order'

add "M18. a failed self-check is RED" \
    "$VERDICT" \
    '    return Verdict(PROBE_BROKEN, why, phase="compare")' \
    '    return Verdict(RED, why, phase="compare")  # MUTANT' \
    'test_a_self_check_is_never_red'

# Section 12, the Cut-1 refinements that are decisions in code.
add "12-1. SC-count passes over a lossy path" \
    "$TABLE" \
    '    if not sent or got != sent:' \
    '    if not sent:  # MUTANT: loss on the path ignored' \
    'test_sc_count_without_loss_and_with_it'

add "12-2. SC-reg accepts any non-zero value" \
    "$TABLE" \
    '    if got != chosen:' \
    '    if not got:  # MUTANT: any non-zero value' \
    'test_sc_reg_needs_the_markers_own_nonzero_value'

add "12-3. SC-qstamp does not ask what identification the sender used" \
    "$TABLE" \
    '    if set(obs.get("sent_idents") or ()) != {0}:' \
    '    if False:  # MUTANT' \
    'test_sc_qstamp_needs_the_sender_to_have_sent_id_0'

add "12-4. SC-ttl hop count stops at the first switch" \
    "$TABLE" \
    '        nxt = links.get((dpid, port))' \
    '        nxt = None  # MUTANT: the first hop is the last' \
    'test_sc_ttl_counts_hops_from_the_lpm_path_not_the_topology'

add "12-4b. SC-union counts hops from the topology instead of v6_host (review MINOR 4)" \
    "$TABLE" \
    '    hops = obs.get("hops_v6")' \
    '    hops = obs.get("hops")  # MUTANT' \
    'test_sc_recirc_and_sc_union'

add "12-7. K3 does not depend on SC-count" \
    "$TABLE" \
    '    Cell("K3", "counters", "core", "active", "B", 4, counter_equal, self_checks=("SC-count",),' \
    '    Cell("K3", "counters", "core", "active", "B", 4, counter_equal,  # MUTANT' \
    'test_rule_d_edges_are_the_designs'

add "12-8. P4 received is GREEN" \
    "$TABLE" \
    '        return partial("b", "the controller got its packet-in; no NDTwin code is on that path")' \
    '        return green("MUTANT")' \
    'test_p4_received_is_partial_b'

add "12-10a. a failed ndt down is released anyway" \
    "$LABROUND" \
    '            self.write_state(phase="down-failed")
            return' \
    '            self.write_state(phase="down-failed")  # MUTANT: released anyway' \
    'test_a_failed_down_is_not_released'

add "12-10b. a qdisc mismatch stops the teardown" \
    "$LABROUND" \
    '                                       % diff.stdout.strip()[:200])' \
    '                                       % diff.stdout.strip()[:200])
                return  # MUTANT: a mismatch blocks the down' \
    'test_a_qdisc_mismatch_does_not_stop_down_restore_or_release'

add "12-12. the qdisc snapshot is taken before the up" \
    "$LABROUND" \
    '            up = self.ndt(["up", "p4", "--app", self.package_dir], timeout=1800)' \
    '            self.runner.run([self.cfg.qdisc_snapshot, "save", "early"], timeout=60)  # MUTANT
            up = self.ndt(["up", "p4", "--app", self.package_dir], timeout=1800)' \
    'test_the_qdisc_snapshot_is_taken_after_up'

# Rule D, the negative reads, the expected refusals, the reader's read-only rule, the lab.
add "D1. rule D ignores the gate cells" \
    "$VERDICT" \
    '    for gate in spec.gates:' \
    '    for gate in ():  # MUTANT: gates ignored' \
    'test_a_red_gate_makes_its_dependants_not_run_and_the_round_publishable'

add "D2. a GREEN without its negative read stands" \
    "$VERDICT" \
    '        if neg is None:' \
    '        if neg is None and False:  # MUTANT' \
    'test_no_negative_read_no_green'

add "D3. a failed negative read is ignored" \
    "$VERDICT" \
    '        if neg.get("absent") is not True:' \
    '        if False:  # MUTANT' \
    'test_an_error_read_as_a_match_fails_the_negative_read'

add "D4. CP2s 409 is a RED" \
    "$TABLE" \
    '    if a["http"] != 409:' \
    '    if a["http"] == 409:  # MUTANT: the refusal is a failure' \
    'test_cp2s_409_is_the_pass_and_not_a_red_candidate'

add "D5. a known-answer control that misses is not PROBE-BROKEN" \
    "$TABLE" \
    '        if a["http"] == self.expect_http and a.get("error") == self.ERROR:' \
    '        if a["http"] is not None:  # MUTANT: any answer passes' \
    'test_k1_neg_and_t3_neg_404_pass'

add "D6. the thrift reader lets a write through" \
    "$THRIFT" \
    '    if word not in READ_COMMANDS:' \
    '    if False:  # MUTANT: writes allowed' \
    'test_the_reader_runs_read_only_commands_on_the_switchs_port_through_the_runner'

add "D6b. the thrift reader lets a second command ride on a newline (review MINOR 8)" \
    "$THRIFT" \
    '    if "\n" in command or "\r" in command or ";" in command:' \
    '    if False:  # MUTANT' \
    'test_the_reader_runs_read_only_commands_on_the_switchs_port_through_the_runner'

add "D7. a reply with no CLI prompt is parsed as one (review MINOR 17: the assertion, not a crash)" \
    "$THRIFT" \
    '    if "RuntimeCmd: " not in out:          # "Could not connect ...": the CLI never got a prompt
        return None' \
    '    if "RuntimeCmd: " not in out:          # MUTANT
        return out' \
    'test_absent_is_a_recognised_reply_and_unreadable_is_none'

add "D8. a busy lab is claimed" \
    "$LABROUND" \
    '        if busy:' \
    '        if False:  # MUTANT: a busy lab is claimed' \
    'test_a_busy_lab_is_not_claimed'

add "D9. a refused claim brings the fabric up anyway" \
    "$LABROUND" \
    '        if claim.rc != 0:' \
    '        if False:  # MUTANT' \
    'test_a_refused_claim_is_incomplete_and_brings_nothing_up'

add "D10. ndt is called without NDT_OWNER" \
    "$CONFIG" \
    '        return {"NDT_OWNER": self.owner}' \
    '        return {}  # MUTANT' \
    'test_every_ndt_call_carries_the_owner'

add "D11. the netem is applied before it is recorded" \
    "$LABROUND" \
    '        self.write_state(netem=self.state["netem"] + [iface])
        res = self.runner.run(TC.netem_add_argv(iface), timeout=30)' \
    '        res = self.runner.run(TC.netem_add_argv(iface), timeout=30)
        self.write_state(netem=self.state["netem"] + [iface])  # MUTANT: after' \
    'test_netem_is_recorded_before_it_is_applied'

add "D12. PF-T counts every FAIL row as the G5 row" \
    "$S0PY" \
    '    other = sum(1 for line in labelled if not line[8:].startswith("entries match p4info"))' \
    '    other = 0  # MUTANT' \
    'test_pft_is_the_g5_answer_only_when_nothing_else_failed'

# Review MAJ-1: a missing or empty reading is never a pass.
add "N1. a reading the row needs may be missing" \
    "$VERDICT" \
    '        if not has(doc, key):' \
    '        if False:  # MUTANT' \
    'test_every_need_key_is_needed'

add "N2. a write-then-read cell ignores the http answer" \
    "$TABLE" \
    '        if a["http"] != 200:
            return red("%s answered %s" % (what, a["http"]), "structural")' \
    '        if False:  # MUTANT
            return red("%s answered %s" % (what, a["http"]), "structural")' \
    'test_compare_branches_after_a_route_exists'

add "N3. TP1 reads empty fabric lists as equal" \
    "$TABLE" \
    '    if not nonempty(*[o[i] for i in TP1_ITEMS]):' \
    '    if False:  # MUTANT' \
    'test_empty_fabric_or_ethtool_oracles_are_not_green'

add "N4. T1 runs on an expectation that does not cover s1-s4" \
    "$TABLE" \
    '        return broken("the probe'"'"'s own expectation does not cover s1-s4")' \
    '        pass  # MUTANT' \
    'test_t1_and_pl1_need_all_four_switches'

add "N5. PL1 runs on an expectation that does not cover s1-s4" \
    "$TABLE" \
    '        return broken("the probe'"'"'s own expectation does not name s1-s4'"'"'s programs")' \
    '        pass  # MUTANT' \
    'test_t1_and_pl1_need_all_four_switches'

add "N6. CS1 with no host answer reads green" \
    "$TABLE" \
    '        return not_run("no host'"'"'s ethtool answer")' \
    '        return green("MUTANT")' \
    'test_empty_fabric_or_ethtool_oracles_are_not_green'

add "N7. T1 accepts a switch missing from switch_state" \
    "$TABLE" \
    '            return red("s%s: switch_state carries no table_entries counts" % dpid, "structural")' \
    '            continue  # MUTANT' \
    'test_t1_and_pl1_need_all_four_switches'

# Review MAJ-2: NDTwin's answer unreadable is NOT RUN.
add "A1. an unreadable answer goes on to be decided" \
    "$VERDICT" \
    '    if spec.needs_answer and obs.get("answer") is None:' \
    '    if False:  # MUTANT' \
    'test_an_unreadable_answer_is_not_run'

add "A2. an unreadable switch_state becomes an empty answer" \
    "$OBSERVE" \
    '    return (state or {}).get("switches") if isinstance((state or {}).get("switches"), dict) else None' \
    '    return (state or {}).get("switches") if isinstance((state or {}).get("switches"), dict) else {}  # MUTANT' \
    'test_unreadable_switch_state_is_no_answer'

# Review MAJ-3: the controls gate K1 and T3.
add "C1. a cell ignores its control" \
    "$VERDICT" \
    '    for ctl in spec.controls:' \
    '    for ctl in ():  # MUTANT' \
    'test_k1_and_t3_follow_their_controls'

add "C2. the controls are never judged" \
    "$VERDICT" \
    '    for ctl in table.controls:          # first: K1 and T3 read their controls (step 0b)' \
    '    for ctl in ():  # MUTANT' \
    'test_the_whole_table_reads_green_from_green_fixtures'

add "C3. K1 is not tied to K1-neg" \
    "$TABLE" \
    '         self_checks=("SC-count",), controls=("K1-neg",), red_attribution=("structural", "thrift"),' \
    '         self_checks=("SC-count",), red_attribution=("structural", "thrift"),  # MUTANT' \
    'test_k1_and_t3_follow_their_controls'

add "C4. any 404 passes the control (review MINOR 21)" \
    "$TABLE" \
    '        if a["http"] == self.expect_http and a.get("error") == self.ERROR:' \
    '        if a["http"] == self.expect_http:  # MUTANT' \
    'test_k1_neg_and_t3_neg_404_pass'

add "C5. health.json drops the controls" \
    "$REPORTPY" \
    '                     for c in table.controls if c.id in ctx.cells],' \
    '                     for c in [] if c.id in ctx.cells],  # MUTANT' \
    'test_controls_are_in_health_json'

# Review MAJ-4: every branch listed, decided on its own.
add "B1. T1 never compares the dump" \
    "$TABLE" \
    '        if set(got) != set(expect[dpid]):' \
    '        if False:  # MUTANT' \
    'test_t1s_dump_half_decides_on_its_own'

add "B2. PL1 never reads the alt table" \
    "$TABLE" \
    '    if (o.get("alt_table") or {}).get("1") is not True:' \
    '    if False:  # MUTANT' \
    'test_pl1s_thrift_half_decides_on_its_own'

add "B3. G1 ignores the integral and the off-path links" \
    "$TABLE" \
    '    return bool(g1.get("on_path")) and g1["main_integral"] > 0 and g1["off_path_max"] < 1' \
    '    return bool(g1.get("on_path"))  # MUTANT' \
    'test_g1_needs_a_positive_integral_and_a_quiet_off_path'

add "B4. TP4 runs without the drop check" \
    "$TABLE" \
    '    if a.get("drop_check_rc") != 0:' \
    '    if False:  # MUTANT' \
    'test_tp4_needs_the_drop_check_and_no_withheld_file'

add "B5. TP4 runs with the heartbeat withheld" \
    "$TABLE" \
    '    if a.get("withheld") is not False:' \
    '    if False:  # MUTANT' \
    'test_tp4_needs_the_drop_check_and_no_withheld_file'

add "B6. CP4 loses its negative read" \
    "$TABLE" \
    '               "o:port_after_cut"), **NEG),' \
    '               "o:port_after_cut")),  # MUTANT' \
    'test_the_negative_read_cells_are_exactly_the_pinned_ones'

add "B7. HU1 loses its SC-union edge" \
    "$TABLE" \
    '         self_checks=("SC-union",), q3b=True, need=("a:v6", "a:x"), **IDENT),' \
    '         q3b=True, need=("a:v6", "a:x"), **IDENT),  # MUTANT' \
    'test_rule_d_edges_are_the_designs'

add "B8. the meter rates are never compared" \
    "$TABLE" \
    '    if o["rates_after"] != o["target"]:' \
    '    if False:  # MUTANT' \
    'test_compare_branches_after_a_route_exists'

add "B9. R2 never compares the register value" \
    "$TABLE" \
    '    if a["value"] != o["value"]:' \
    '    if False:  # MUTANT' \
    'test_compare_branches_after_a_route_exists'

add "B10. R3 never compares what it wrote" \
    "$TABLE" \
    '    if o["value_after"] != o["target"]:' \
    '    if False:  # MUTANT' \
    'test_compare_branches_after_a_route_exists'

add "B11. D1 never compares the digest" \
    "$TABLE" \
    '    if a["fields"] != o["fields"]:' \
    '    if False:  # MUTANT' \
    'test_compare_branches_after_a_route_exists'

add "B12. delivered without anything arriving" \
    "$TABLE" \
    '    if o["received"] >= 1:
        return green("delivered")' \
    '    if True:  # MUTANT
        return green("delivered")' \
    'test_compare_branches_after_a_route_exists'

add "B13. IT1 green without a report" \
    "$TABLE" \
    '    if deadline_met(a["reported_after_s"], IT1_REPORT_DEADLINE_S):' \
    '    if True:  # MUTANT' \
    'test_it1_reads_the_switchs_own_aging'

add "B14. an incomplete round is COMPLETE" \
    "$VERDICT" \
    '    if not bringups_complete:' \
    '    if False:  # MUTANT' \
    'test_an_incomplete_round_is_incomplete'

add "B15. the throwaway CLI dials a lab port" \
    "$THROWAWAY" \
    '        if self.thrift_port is None or not outside_lab_ports(self.thrift_port):' \
    '        if self.thrift_port is None:  # MUTANT' \
    'test_the_throwaway_cli_only_ever_dials_its_own_port'

# Review MAJ-5/MAJ-6: process identity, the claim during teardown.
add "L1. a pid without the run marker is registered" \
    "$LABROUND" \
    '        if ident is None or marker not in ident[1]:' \
    '        if ident is None:  # MUTANT' \
    'test_a_pid_without_the_marker_is_not_registered'

add "L2. a recycled pid is signalled" \
    "$LABROUND" \
    '        elif ident[0] != entry["start"] or entry["marker"] not in ident[1]:' \
    '        elif False:  # MUTANT' \
    'test_a_recycled_or_vanished_pid_is_never_signalled'

add "L3. a lost claim does not stop the teardown" \
    "$LABROUND" \
    '        ours, why = self.claim_ours()
        if ours:' \
    '        ours, why = self.claim_ours()
        if True:  # MUTANT' \
    'test_a_lost_claim_stops_the_teardown_before_anything_shared_changes'

add "L4. an expired claim of ours still counts as ours" \
    "$LABROUND" \
    '        if expires <= int(self.clock()):' \
    '        if False:  # MUTANT' \
    'test_a_lost_claim_stops_the_teardown_before_anything_shared_changes'

add "L5. a failed netem add is deleted anyway (review MINOR 20)" \
    "$LABROUND" \
    '        if res.rc != 0:
            self.write_state(netem=' \
    '        if False:  # MUTANT
            self.write_state(netem=' \
    'test_a_netem_whose_add_failed_is_not_deleted'

add "L6. a stopped process stays in the state file" \
    "$LABROUND" \
    '        self.write_state(**{key: [e for e in self.state[key] if e["pid"] != pid]})' \
    '        pass  # MUTANT' \
    'test_processes_are_recorded_by_pid_start_and_marker_and_leave_once_stopped'

# Review MAJ-7: deliberately non-hermetic edits the sealed suite must catch.
add "H1. a collector runs a real subprocess instead of the injected Runner" \
    "$OBSERVE" \
    '    reader = TH.ThriftReader(cfg, runner)
    full = name if "." in name else "HcIngress." + name' \
    '    from .collect.runner import Runner
    reader = TH.ThriftReader(cfg, Runner())  # MUTANT: a real runner
    full = name if "." in name else "HcIngress." + name' \
    'test_the_oracle_is_thrifts_and_never_the_proxys'

add "H2. a collector dials the proxy instead of using the Config client" \
    "$PROXY" \
    '    reply = cfg.proxy.get("/p4/counter/%s?dpid=%d&index=%d" % (name, int(dpid), int(index)))' \
    '    from .config import HttpClient
    reply = HttpClient("http://localhost:8081").get("/p4/counter/%s?dpid=%d&index=%d" % (name, int(dpid), int(index)))  # MUTANT' \
    'test_the_counter_endpoints_three_answers'

add "H3. a collector shells out with os.system" \
    "$OBSERVE" \
    '    status, _packets, error = P.counter(cfg, name, dpid, 0)' \
    '    import os as _os
    _os.system("ndt status")  # MUTANT
    status, _packets, error = P.counter(cfg, name, dpid, 0)' \
    'test_the_counter_control_needs_the_endpoints_own_refusal'

add "H4. a collector dials 127.0.1.1" \
    "$PROXY" \
    '    reply = cfg.proxy.post("/p4/table_entry", entry)' \
    '    from .config import HttpClient
    HttpClient("http://127.0.1.1:8081").get("/openapi.json")  # MUTANT
    reply = cfg.proxy.post("/p4/table_entry", entry)' \
    'test_post_table_entry_goes_through_the_config_client'

# Review MAJ-8 and MAJ-9/10: the Q3(b) cells and the rollups.
add "Q1. HR1 never compares the twin with netdev" \
    "$TABLE" \
    '    wrong = sorted(u for u in UPLINKS if carried[u] != seen[u])' \
    '    wrong = []  # MUTANT' \
    'test_red_fixtures_are_red'

add "Q2. HR1/HR2 read bytes without the quiet window" \
    "$TABLE" \
    '        out[up] = (w["during"] - w["base"]) >= CARRY_SHARE * flow_bytes' \
    '        out[up] = w["during"] >= CARRY_SHARE * flow_bytes  # MUTANT' \
    'test_hr_quiet_window_is_subtracted'

add "Q3. HR1 runs on a flow that is not on exactly one uplink" \
    "$TABLE" \
    '        if n != want:' \
    '        if False:  # MUTANT' \
    'test_hr1_needs_exactly_one_uplink_and_hr2_both'

add "Q4. IT1 runs before the entry aged" \
    "$TABLE" \
    '    if o["since_hit_ms"] <= o["timeout_ms"]:' \
    '    if False:  # MUTANT' \
    'test_it1_reads_the_switchs_own_aging'

add "Q5. IT1 ignores the timeout thrift shows" \
    "$TABLE" \
    '    if o["timeout_ms"] != a["requested_timeout_ms"]:' \
    '    if False:  # MUTANT' \
    'test_it1_reads_the_switchs_own_aging'

add "Q6. IT1 structural answer is not read" \
    "$TABLE" \
    '    if a.get("idle_field") is False or a.get("notification_exit") is False:' \
    '    if False:  # MUTANT' \
    'test_it1_today_is_a_structural_cannot'

add "Q7. HU1 never asks about the 0x1238 member" \
    "$TABLE" \
    '    if not side_row_grew(x, ETHERTYPES["HU1x"]):' \
    '    if False:  # MUTANT' \
    'test_hu1_judges_both_members_and_the_side_table_cap'

add "Q8. HU1 ignores the side table cap" \
    "$TABLE" \
    '    if size is None or size > SIDE_TABLE_ROOM:' \
    '    if size is None:  # MUTANT' \
    'test_hu1_judges_both_members_and_the_side_table_cap'

add "Q9. HU1 looks for the wrong ethertype" \
    "$TABLE" \
    '"HU1": 0x86DD' \
    '"HU1": 0x0800' \
    'test_hu1_judges_both_members_and_the_side_table_cap'

add "Q10. AS1 never checks the group" \
    "$TABLE" \
    '("present_after", "points_to_group")' \
    '("present_after",)' \
    'test_compare_branches_after_a_route_exists'

add "Q11. VB1 aliases the wrong cell" \
    "$TABLE" \
    'alias_of="CH3",' \
    'alias_of="CH6",' \
    'test_aliases_carry_their_sources_verdict'

add "Q13. SC-recirc accepts a packet that was not resubmitted" \
    "$TABLE" \
    '    bad = [f for f in flags if f & 0x0C != 0x0C]' \
    '    bad = []  # MUTANT' \
    'test_sc_recirc_and_sc_union'

add "Q14. SC-union accepts any hop limit" \
    "$TABLE" \
    '    if any(h != want for h in lims):' \
    '    if False:  # MUTANT' \
    'test_sc_recirc_and_sc_union'

add "Q15. full silently grows to 22 dimensions (review MAJ-10)" \
    "$VERDICT" \
    '    dims = table.q3b_dimensions if scope == "q3b" else table.core_dimensions' \
    '    dims = table.q3b_dimensions if scope == "q3b" else (table.core_dimensions + (table.q3b_dimensions if scope == "full" else ()))  # MUTANT' \
    'test_three_rollups_sixteen_sixteen_and_six'

# The rest of the review MINORs that are decisions in code.
add "m10a. an unreadable flow document reads as no side rows" \
    "$KERNEL" \
    '        return list(flow_doc["non_ipv4_flows"])
    return None' \
    '        return list(flow_doc["non_ipv4_flows"])
    return []  # MUTANT' \
    'test_side_rows_and_pcaps'

add "m10b. a missing pcap reads as no frames" \
    "$FRAMES" \
    '    except OSError:
        return None
    if len(data) < 24' \
    '    except OSError:
        return []  # MUTANT
    if len(data) < 24' \
    'test_side_rows_and_pcaps'

add "m12. the inventory counts a declared field as used" \
    "$S0PY" \
    '        if node.get("type") == "field" and node.get("value") == field:' \
    '        if node.get("type") == "field":  # MUTANT' \
    'test_the_inventory_needles_need_a_use_not_a_declaration'

add "m19. probe judge assumes the bring-ups completed" \
    "$PROBEPY" \
    'bringups_complete=doc.get("bringups_complete") is True)' \
    'bringups_complete=doc.get("bringups_complete", True))  # MUTANT' \
    'test_a_recording_that_does_not_say_it_completed_is_incomplete'

add "m2. a PF-T with no observation is decided" \
    "$VERDICT" \
    '    obs = obs or {}
    # 0. NDTwin' \
    '    if not obs:  # MUTANT
        return Verdict(PROBE_BROKEN, "x", phase="answer")
    obs = obs or {}
    # 0. NDTwin' \
    'test_pft_with_no_observation_is_not_run'

add "m-hermetic. Config defaults are allowed under P4H_HERMETIC" \
    "$CONFIG" \
    '            if left:' \
    '            if False:  # MUTANT' \
    'test_a_config_that_would_default_to_the_machine_is_refused'

# recover.sh: its offline test must see these red.
add "R1. recover.sh does not check that the lab is this run" \
    "$RECOVER" \
    'if [[ "$c_owner" == "$OWNER" && "$c_exp" -gt "$now" && "$override_ours" -eq 1 && "$note_ours" -eq 1 ]]; then' \
    'if true; then' \
    'a live foreign claim: rc 3'

add "R2. recover.sh releases after a failed down" \
    "$RECOVER" \
    'if ! NDT_OWNER="$OWNER" "$NDT" down; then' \
    'if ! NDT_OWNER="$OWNER" "$NDT" down && false; then' \
    'no release'

add "R3. recover.sh takes over an expired claim of somebody else" \
    "$RECOVER" \
    'elif [[ ( -z "$c_owner" || "$c_owner" == "$OWNER" ) && "$c_exp" -le "$now" \' \
    'elif [[ "$c_exp" -le "$now" \' \
    'an expired foreign claim: rc 3, no re-claim'

add "R4. recover.sh re-claims over a measurement" \
    "$RECOVER" \
    '    if [[ -n "$c_meas" || -n "$busy" ]]; then' \
    '    if false; then' \
    'an expired claim that declares a measurement: rc 3'

add "R5. recover.sh signals a recycled pid" \
    "$RECOVER" \
    '    [[ "$start" == "$2" && "$cmd" == *"$3"* ]]' \
    '    true' \
    'no signal to the recycled sniffer pid or the vanished controller'

add "R6. recover.sh accepts an up note written for another owner" \
    "$RECOVER" \
    '    "in use: ndt up p4 "*" by $OWNER")          note_ours=1 ;;' \
    '    "in use: ndt up p4 "*)          note_ours=1 ;;' \
    'an up note written for another owner: rc 3, nothing run'

# Round 3 (the Cut 1 re-review: NEW-A, NEW-B, NEW-C, the RC1 cell, the alias marks, MINORs).
add "R3-A1. the sample floor gates on NDTwin's emitter count again (NEW-A)" \
    "$VERDICT" \
    '        if spec.min_sent is not None and sent < spec.min_sent:' \
    '        if spec.min_sent is not None and (obs.get("oracle") or {}).get("sampled", 0) < 1:  # MUTANT' \
    'test_telemetry_none_through_the_real_cells'

add "R3-A2. the floor is one expected sample" \
    "$TABLE" \
    'MIN_EXPECTED_SAMPLES = 19' \
    'MIN_EXPECTED_SAMPLES = 1  # MUTANT' \
    'test_the_sample_floor_comes_from_the_sender_not_the_emitter'

add "R3-B1. a link that never went down meets the deadline (NEW-B)" \
    "$TABLE" \
    '    if seconds == NEVER:
        return False' \
    '    if seconds == NEVER:
        return True  # MUTANT' \
    'test_a_link_that_never_went_down_is_red_not_not_read'

add "R3-B2. never-went-down reads as not read" \
    "$TABLE" \
    '    if a["down_after_s"] == NEVER and not watched_enough(a):' \
    '    if a["down_after_s"] == NEVER:  # MUTANT' \
    'test_a_link_that_never_went_down_is_red_not_not_read'

add "R3-B3. a route gone after the cut reads as not read" \
    "$TABLE" \
    '        return red("thrift: s1'"'"'s route to h6 is gone after the cut", "structural", "thrift")' \
    '        return not_run("MUTANT: route not read")' \
    'test_a_route_gone_after_the_cut_is_red'

add "R3-B4. never-rerouted reads as not read" \
    "$TABLE" \
    '    if a["rerouted_after_s"] == NEVER and not watched_enough(a):' \
    '    if a["rerouted_after_s"] == NEVER:  # MUTANT' \
    'test_a_route_gone_after_the_cut_is_red'

add "R3-C1. lab_round records no down-done (NEW-C)" \
    "$LABROUND" \
    '        if down.rc == 0:
            # (r3, review NEW-C)' \
    '        if False:  # MUTANT
            # (r3, review NEW-C)' \
    'test_a_successful_down_is_recorded_before_the_knobs_and_the_release'

add "R3-C2. recover.sh in down-done still compares qdiscs" \
    "$RECOVER" \
    'if [[ "$PHASE" != down-done ]]; then' \
    'if true; then  # MUTANT' \
    'down-done: rc 0'

add "R3-C3. recover.sh in down-done does not check that no fabric is up" \
    "$RECOVER" \
    '    if [[ "$n_bmv2" != 0 || "$n_mn" != 0 ]]; then' \
    '    if false; then  # MUTANT' \
    'down-done but ndt status shows a fabric: rc 4'

add "R3-D1. RC1 loses its SC-recirc dependency" \
    "$TABLE" \
    '    Cell("RC1", "recirculate", "ext", "active", "A", 3, identity_cell(None), self_checks=("SC-recirc",),' \
    '    Cell("RC1", "recirculate", "ext", "active", "A", 3, identity_cell(None),  # MUTANT' \
    'test_rule_d_edges_are_the_designs'

add "R3-D2. alias-only dimensions are not marked" \
    "$VERDICT" \
    '        if counted and all(c.alias_of for c in counted):' \
    '        if False:  # MUTANT' \
    'test_alias_only_dimensions_are_marked'

add "R3-D3. an alias row does not say whose verdict it carries" \
    "$REPORTPY" \
    '            attribution = "ALIAS of %s%s" % (c.alias_of, ("; " + attribution) if attribution else "")' \
    '            pass  # MUTANT' \
    'test_alias_only_dimensions_are_marked'

add "R3-m3a. a control with no route is PROBE-BROKEN (MINOR 3)" \
    "$TABLE" \
    '        if isinstance(a, dict) and a.get("route") is False:' \
    '        if False:  # MUTANT' \
    'test_a_missing_route_makes_the_cell_red_and_the_round_publishable'

add "R3-m3b. a cell may claim a route its control did not find" \
    "$VERDICT" \
    '            return PROBE_BROKEN, "control %s found no route, the cell'"'"'s own answer does not say so" % ctl' \
    '            continue  # MUTANT' \
    'test_a_missing_route_makes_the_cell_red_and_the_round_publishable'

add "R3-m3c. K1 ignores a missing route" \
    "$TABLE" \
    '        return red("no route: the proxy'"'"'s openapi has no GET /p4/counter", "structural", *thrift_ev(obs))' \
    '        pass  # MUTANT' \
    'test_a_missing_route_makes_the_cell_red_and_the_round_publishable'

add "R3-m1a. empty target rates are a RED, not the probe's fault (MINOR 1)" \
    "$TABLE" \
    '        return broken("the probe'"'"'s own target rates are empty")' \
    '        pass  # MUTANT' \
    'test_empty_probe_side_inputs_are_probe_broken'

add "R3-m1b. an empty marker field list is a RED" \
    "$TABLE" \
    '        return broken("the marker'"'"'s own fields are empty")' \
    '        pass  # MUTANT' \
    'test_empty_probe_side_inputs_are_probe_broken'

add "R3-m2. HU1 decides without its nested readings (MINOR 2)" \
    "$TABLE" \
    '        if lacking:
            return not_run("reading not taken: answer.%s.%s"' \
    '        if False:  # MUTANT
            return not_run("reading not taken: answer.%s.%s"' \
    'test_hu1s_nested_readings_are_needed'

add "R3-m4. HR stimulus too small to trust (MINOR 4)" \
    "$TABLE" \
    'HR_FRAMES = 24000' \
    'HR_FRAMES = 2000  # MUTANT' \
    'test_hr_stimulus_size_and_order'

add "R3-m5. IT1 accepts a report after its deadline (MINOR 5)" \
    "$TABLE" \
    '    if deadline_met(a["reported_after_s"], IT1_REPORT_DEADLINE_S):' \
    '    if a["reported_after_s"] != NEVER:  # MUTANT' \
    'test_it1_reads_the_switchs_own_aging'

add "R3-m6a. a failed kill drops the process from the state file (MINOR 6)" \
    "$LABROUND" \
    '        if outcome.startswith("kill rc"):' \
    '        if False:  # MUTANT' \
    'test_a_failed_kill_keeps_the_process_for_recover'

add "R3-m6b. recover.sh takes a recycled pid for the probe" \
    "$RECOVER" \
    '    if [[ -z "$PID_START" || -z "$now_start" || "$now_start" == "$PID_START" ]]; then' \
    '    if true; then  # MUTANT' \
    'rc 0: a live pid with another start time is a recycled pid'

add "R3-m6c. recover.sh measuring check fails open" \
    "$RECOVER" \
    '        echo "ndt status --measuring did not answer"; return' \
    '        return  # MUTANT' \
    'an expired claim and ndt status --measuring not answering: rc 3 (fails closed)'


# Round 4 (the Cut 1 follow-ups: recover after an expired claim in down-done, the HR bound, the
# K1/T3 route, HU1's key, the timed-reading encodings, a failed kill, measuring_now).
add "R4-1a. recover.sh re-claims only while the override names the package (follow-up 1)" \
    "$RECOVER" \
    '( -z "$ov" && "$PHASE" == down-done && "$c_owner" == "$OWNER" )' \
    '( 1 -eq 0 )' \
    'down-done, own claim expired, override absent: rc 0'

add "R5-1a. an absent override is evidence in every phase, not only down-done (r5 follow-up 1)" \
    "$RECOVER" \
    '( -z "$ov" && "$PHASE" == down-done && "$c_owner" == "$OWNER" )' \
    '( -z "$ov" && "$c_owner" == "$OWNER" )' \
    'teardown, own claim expired, override absent: rc 3, no stub called'

add "R5-1b. a down-done run with no claim file is re-claimed" \
    "$RECOVER" \
    '( -z "$ov" && "$PHASE" == down-done && "$c_owner" == "$OWNER" )' \
    '( -z "$ov" && "$PHASE" == down-done )' \
    'down-done, no lab.claim: rc 3, nothing written'

add "R5-1c. the fabric is checked after the re-claim, not before (r5 follow-up 1b)" \
    "$RECOVER" \
    '    # the expired claim file is OUR owner'"'"'s. The fabric check comes first: it writes nothing.
    down_done_fabric_check' \
    '    # MUTANT: no fabric check before the claim' \
    'down-done, own claim expired, fabric up: rc 4 and the claim stub never called'

add "R5-2a. a released run falls through to the claim branches (r5 follow-up 2)" \
    "$RECOVER" \
    'if [[ "$PHASE" == released ]]; then' \
    'if false; then  # MUTANT' \
    'released with recorded live processes: rc 0, only the two kills'

add "R5-2b. a released run whose kill failed exits 0" \
    "$RECOVER" \
    '(above); a person stops them."; exit 7' \
    '(above); a person stops them."; exit 0' \
    'released with a kill that fails: rc 7, only the kills'

add "R5-3. a failed kill ends the recovery as done (r5 follow-up 3)" \
    "$RECOVER" \
    '(kill failed above): rc 7"
    exit 7' \
    '(kill failed above): rc 7"' \
    'a controller kill fails in a live recovery: the recovery finishes, then rc 7'

add "R4-2a. recover.sh skips the process step in down-done (follow-up 2)" \
    "$RECOVER" \
    'procs() {  # procs <key> -- "pid start marker" per recorded process' \
    'procs() { [[ "$PHASE" == down-done ]] && return 0  # MUTANT: procs <key>' \
    'down-done with a kept sniffer and controller: ndt status, both signalled, release -- no qdisc, no netem, no down'

add "R4-2b. a failed kill is not a problem and the round stays complete (follow-up 2)" \
    "$LABROUND" \
    '        if not outcome.startswith("kill rc"):
            return' \
    '        if True:  # MUTANT: every kill reads as fine
            return' \
    'test_a_failed_kill_is_a_problem_and_the_round_is_not_complete'

add "R4-2c. a failed kill is a problem but the round stays complete" \
    "$LABROUND" \
    '                               "recover.sh" % (what, entry["pid"], outcome))
        rec["complete"] = False' \
    '                               "recover.sh" % (what, entry["pid"], outcome))  # MUTANT' \
    'test_a_failed_kill_is_a_problem_and_the_round_is_not_complete'

add "R4-3a. HR stimulus back to 20000 frames, whose false-RED rate is 2e-5 (follow-up 3)" \
    "$TABLE" \
    'HR_FRAMES = 24000' \
    'HR_FRAMES = 20000  # MUTANT' \
    'test_hr_stimulus_size_and_order'

add "R4-3b. HR1 may go out the shaped uplink" \
    "$TABLE" \
    '        if want == 1 and not carried[HR1_UPLINK]:' \
    '        if False:  # MUTANT' \
    'test_hr1_is_pinned_to_the_unshaped_uplink'

add "R4-3c. HR1 is pinned to the shaped uplink" \
    "$TABLE" \
    'HR1_UPLINK = [u for u in UPLINKS if u not in SHAPED_IFACES][0]' \
    'HR1_UPLINK = [u for u in UPLINKS if u in SHAPED_IFACES][0]  # MUTANT' \
    'test_hr1_is_pinned_to_the_unshaped_uplink'

add "R4-4a. K1's counter observer says nothing about the route (follow-up 4)" \
    "$OBSERVE" \
    '    return {"answer": with_route(answer, cfg, cell), "oracle": oracle, "sent": S.sent(out, cell)}' \
    '    return {"answer": answer, "oracle": oracle, "sent": S.sent(out, cell)}  # MUTANT' \
    'test_a_missing_counter_route_is_red_no_route_through_the_observers'

add "R4-4b. K1-neg's observer says nothing about the route" \
    "$OBSERVE" \
    '    return {"answer": with_route(answer_or_none(status, {"http": status, "error": error}), cfg, "K1-neg")}' \
    '    return {"answer": answer_or_none(status, {"http": status, "error": error})}  # MUTANT' \
    'test_a_missing_counter_route_is_red_no_route_through_the_observers'

add "R4-4c. an unreadable openapi reads as a missing route" \
    "$OBSERVE" \
    '    route = route_answer(P.openapi_paths(cfg), cell)' \
    '    route = bool(route_answer(P.openapi_paths(cfg), cell))  # MUTANT' \
    'test_a_missing_counter_route_is_red_no_route_through_the_observers'

add "R4-5. HU1 decides without the IPv6 member's flow_identity (follow-up 5)" \
    "$TABLE" \
    '("v6", v6, ("g1", "pair", "side_after", "flow_identity")),' \
    '("v6", v6, ("g1", "pair", "side_after")),  # MUTANT' \
    'test_hu1s_nested_readings_are_needed'

add "R4-6a. a negative time is a time (follow-up 6)" \
    "$TABLE" \
    '    if not _real(value) or value < 0:' \
    '    if not _real(value):  # MUTANT' \
    'test_malformed_timed_readings_are_probe_broken'

add "R4-6b. Never in any case is NEVER" \
    "$TABLE" \
    '    if value == NEVER:
        return None
    if not _real(value)' \
    '    if str(value).lower() == NEVER:  # MUTANT
        return None
    if not _real(value)' \
    'test_malformed_timed_readings_are_probe_broken'

add "R4-6c. a time larger than its own watched_s is a time" \
    "$TABLE" \
    '    if value > watched:' \
    '    if False:  # MUTANT' \
    'test_malformed_timed_readings_are_probe_broken'

add "R4-6d. watched_s is not validated" \
    "$TABLE" \
    '    if not _real(watched) or watched < 0:' \
    '    if False:  # MUTANT' \
    'test_malformed_timed_readings_are_probe_broken'

add "R4-6e. deadline_met takes a negative time" \
    "$TABLE" \
    '    return _real(seconds) and 0 <= seconds <= deadline' \
    '    return _real(seconds) and seconds <= deadline  # MUTANT' \
    'test_malformed_timed_readings_are_probe_broken'

add "R4-6f. TP2 / TP4 do not validate the encoding" \
    "$TABLE" \
    '    bad = timing_problem(a, "down_after_s")' \
    '    bad = None  # MUTANT' \
    'test_malformed_timed_readings_are_probe_broken'

add "R4-6g. CP4 does not validate the encoding" \
    "$TABLE" \
    '    bad = timing_problem(a, "rerouted_after_s")' \
    '    bad = None  # MUTANT' \
    'test_malformed_timed_readings_are_probe_broken'

add "R4-6h. IT1 does not validate the encoding" \
    "$TABLE" \
    '    bad = timing_problem(a, "reported_after_s")' \
    '    bad = None  # MUTANT' \
    'test_malformed_timed_readings_are_probe_broken'

add "R4-6i. CP4 reads gone before it checks how long it watched" \
    "$TABLE" \
    '    if a["rerouted_after_s"] == NEVER and not watched_enough(a):
        return not_run("the route was watched for %s s, less than the %d s deadline" % (a.get("watched_s"), LINK_DOWN_DEADLINE_S))
    if o["port_after_cut"] == GONE:
        return red("thrift: s1'"'"'s route to h6 is gone after the cut", "structural", "thrift")' \
    '    if o["port_after_cut"] == GONE:  # MUTANT: gone first
        return red("thrift: s1'"'"'s route to h6 is gone after the cut", "structural", "thrift")
    if a["rerouted_after_s"] == NEVER and not watched_enough(a):
        return not_run("the route was watched for %s s, less than the %d s deadline" % (a.get("watched_s"), LINK_DOWN_DEADLINE_S))' \
    'test_a_route_read_as_gone_during_a_short_watch_is_not_run'

add "R4-8a. recover.sh takes an answer with no measuring or orphaned row for idle (follow-up 8)" \
    "$RECOVER" \
    "    if ! printf '%s\n' \"\$out\" | awk '\$1 == \"measuring\" || \$1 == \"orphaned\" { found = 1 } END { exit !found }'; then" \
    '    if false; then  # MUTANT' \
    'an expired claim and an empty ndt status --measuring answer: rc 3 (fails closed)'

add "R4-8b. recover.sh takes only a measuring row for evidence (an orphaned row alone is busy)" \
    "$RECOVER" \
    "awk '\$1 == \"measuring\" || \$1 == \"orphaned\" { found = 1 }" \
    "awk '\$1 == \"measuring\" { found = 1 }" \
    'an expired claim and only an orphaned row (leftovers, no fabric): rc 0, re-claimed'


CTRL_SRC="$TABLE"
CTRL_ANCHOR='def g1_holds(g1):'
CTRL_REPL='# MUTANT: a comment, and nothing else.
def g1_holds(g1):'

if [[ "$ANCHOR_CHECK" == 1 ]]; then
    echo "=== ANCHOR CHECK (no verdict) ==="
    for i in "${!MUT_LABEL[@]}"; do
        n=$(anchor_count "${MUT_SRC[$i]}" "${MUT_ANCHOR[$i]}") || refuse_anchor_count
        printf '  %-3s %s\n' "$n" "${MUT_LABEL[$i]}"
    done
    n=$(anchor_count "$CTRL_SRC" "$CTRL_ANCHOR") || refuse_anchor_count
    printf '  %-3s %s\n' "$n" "negative control"
    exit 2
fi

# --- running --------------------------------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4-health-mutate-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SURVIVORS=0; MUTATIONS=0
BASE_SUM="$(cd "$PKG" && find . -type f \( -name '*.py' -o -name '*.sh' -o -name '*.p4' \) | sort | xargs sha256sum | sha256sum)"

fresh_copy() {
    rm -rf "$WORK/tools"; mkdir -p "$WORK/tools"
    cp -r "$PKG" "$WORK/tools/p4_health"
    # the one repo file the package reads by its own path (throwaway.py's lab port list)
    mkdir -p "$WORK/p4_proxy/mininet" && cp "$REPO/p4_proxy/mininet/grpc_ports.py" "$WORK/p4_proxy/mininet/"
    find "$WORK/tools" -name __pycache__ -prune -exec rm -rf {} +
}

# red_tests [package root] [recover.sh] -- names of the tests that went red, space-separated;
# NO-SUITE when a python suite printed no `Ran N tests`; HUNG on a timeout.
red_tests() {
    local root="${1:-$REPO/tools}" rec="${2:-$RECOVER}" out rc names="" f
    for f in "$CELLS_TEST" "$COLLECT_TEST"; do
        out=$(P4_HEALTH_UNDER_TEST="$root" timeout 300 "$PYTHON" "$f" 2>&1); rc=$?
        [[ $rc -eq 124 ]] && { echo "HUNG"; return; }
        /usr/bin/grep -qE '^Ran [0-9]+ tests?' <<<"$out" || { echo "NO-SUITE"; return; }
        [[ $rc -ne 0 ]] && names+=" $(sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_][A-Za-z0-9_]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' ')"
    done
    out=$(P4_HEALTH_RECOVER_UNDER_TEST="$rec" timeout 300 bash "$RECOVER_TEST" 2>&1); rc=$?
    [[ $rc -eq 124 ]] && { echo "HUNG"; return; }
    /usr/bin/grep -qE '^Ran [0-9]+ checks' <<<"$out" || { echo "NO-SUITE"; return; }
    [[ $rc -ne 0 ]] && names+=" $(sed -n 's/^  FAIL  \(.*\)$/[\1]/p' <<<"$out" | tr '\n' ' ')"
    # trimmed with parameter expansion, not xargs: recover check names carry apostrophes
    names="${names#"${names%%[![:space:]]*}"}"; names="${names%"${names##*[![:space:]]}"}"
    printf '%s\n' "$names"
}

mutate() {
    local label="$1" src="$2" anchor="$3" repl="$4" expected="$5"
    local n; n=$(anchor_count "$src" "$anchor") || refuse_anchor_count
    printf '\n=== %s ===\n' "$label"
    printf '  subject           : %s  (mutated as a copy in %s)\n' "$src" "$WORK"
    printf '  anchor occurrences: %s\n' "$n"
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- SURVIVOR"; SURVIVORS=$((SURVIVORS + 1)); return
    fi
    fresh_copy
    local target="$WORK/tools/p4_health/${src#"$PKG"/}"
    if ! ANCHOR="$anchor" REPL="$repl" "$PYTHON" - "$target" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1
p.write_text(s.replace(a, r, 1))
PY
    then echo "  🔴 could not apply -- SURVIVOR"; SURVIVORS=$((SURVIVORS + 1)); return; fi
    if [[ "$target" == *.py ]]; then
        "$PYTHON" -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$target" >/dev/null 2>&1 \
            || { echo "  🔴 MUTANT DOES NOT PARSE -- SURVIVOR"; SURVIVORS=$((SURVIVORS + 1)); return; }
    else
        bash -n "$target" || { echo "  🔴 MUTANT DOES NOT PARSE -- SURVIVOR"; SURVIVORS=$((SURVIVORS + 1)); return; }
    fi
    local failed
    if [[ "$target" == *.sh ]]; then failed=$(red_tests "$REPO/tools" "$target")
    else failed=$(red_tests "$WORK/tools"); fi
    if [[ "$failed" == "NO-SUITE" ]]; then
        echo "🔴 REFUSED: a suite did not run at all while measuring: $label. No verdict."; exit 2
    fi
    if [[ "$failed" == "HUNG" ]]; then
        echo "  🔴 HUNG -- SURVIVOR"; SURVIVORS=$((SURVIVORS + 1))
    elif [[ -z "$failed" ]]; then
        echo "  🔴 SURVIVED -- every suite stayed green"; SURVIVORS=$((SURVIVORS + 1))
    elif [[ " $failed " == *" $expected "* || "$failed" == *"[$expected]"* ]]; then
        echo "  ✅ caught by $expected"
        printf '     also red: %s\n' "$failed"
    else
        echo "  🔴 WRONG TEST went red (wanted $expected) -- SURVIVOR"
        printf '     red: %s\n' "$failed"
        SURVIVORS=$((SURVIVORS + 1))
    fi
}

printf '=== BASELINE: every suite green against the real files ===\n'
BASE_RED=$(red_tests)
[[ "$BASE_RED" == "NO-SUITE" ]] && { echo "🔴 REFUSED: a suite did not run at baseline"; exit 2; }
[[ -n "$BASE_RED" ]] && { echo "🔴 REFUSED: baseline is red: $BASE_RED"; exit 2; }
echo "  ok       baseline green"

for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_SRC[$i]}" "${MUT_ANCHOR[$i]}" "${MUT_REPL[$i]}" "${MUT_EXPECT[$i]}"
done

printf '\n=== NEGATIVE CONTROL: comment-only edit must stay GREEN ===\n'
n=$(anchor_count "$CTRL_SRC" "$CTRL_ANCHOR") || refuse_anchor_count
printf '  anchor occurrences: %s\n' "$n"
if [[ "$n" -ne 1 ]]; then
    echo "  🔴 control anchor not unique"; SURVIVORS=$((SURVIVORS + 1))
else
    fresh_copy
    ANCHOR="$CTRL_ANCHOR" REPL="$CTRL_REPL" "$PYTHON" - "$WORK/tools/p4_health/cells/table.py" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace(os.environ["ANCHOR"], os.environ["REPL"], 1))
PY
    ctrl_red=$(red_tests "$WORK/tools")
    if [[ -z "$ctrl_red" ]]; then echo "  ✅ green: the suites do not react to a comment"
    else printf '  🔴 A COMMENT TURNED A SUITE RED: %s\n' "$ctrl_red"; SURVIVORS=$((SURVIVORS + 1)); fi
fi

printf '\n--- was the original written? ---\n'
NOW_SUM="$(cd "$PKG" && find . -type f \( -name '*.py' -o -name '*.sh' -o -name '*.p4' \) | sort | xargs sha256sum | sha256sum)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then echo "  🔴 tools/p4_health CHANGED DURING THE GATE"; exit 2; fi
echo "  byte-identical  tools/p4_health  ${BASE_SUM:0:16}"
after_red=$(red_tests)
[[ -n "$after_red" ]] && { echo "🔴 a suite is red against the real files: $after_red"; exit 2; }
echo "  suites green against the real files"

printf '\n%s mutations, %s survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$SURVIVORS" -eq 0 ]]
