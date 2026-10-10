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
GATE_TEST="$HERE/test_p4_health_gate_scripts.sh"
GATEPY="$HERE/mutate_p4_health.sh"
SUMPY="$HERE/sum_p4_health_gate_shards.sh"

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
    'bringups_complete=doc.get("bringups_complete") is True,' \
    'bringups_complete=doc.get("bringups_complete", True),  # MUTANT' \
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
    'if [[ "$c_owner" == "$OWNER" && "$c_exp" -gt "$now" && "$claim_same" -eq 1 && "$override_ours" -eq 1 && "$note_ours" -eq 1 ]]; then' \
    'if true; then' \
    'nothing was run'

add "R2. recover.sh releases after a failed down" \
    "$RECOVER" \
    'if [[ "$down_rc" -ne 0 ]]; then' \
    'if false; then  # MUTANT' \
    'no release'

add "R3. recover.sh takes over an expired claim of somebody else" \
    "$RECOVER" \
    'elif [[ ( -z "$c_owner" || "$c_owner" == "$OWNER" ) && "$c_exp" -le "$now" && "$claim_same" -eq 1 \' \
    'elif [[ "$c_exp" -le "$now" && "$claim_same" -eq 1 \' \
    'an expired foreign claim: the claim stub was never called'

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

add "R-upnote. recover.sh accepts an up note written for another owner" \
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
    'if [[ "$SKIP_DOWN" -eq 0 ]]; then' \
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

add "R5-1b. a down-done claim file that names no owner is re-claimed" \
    "$RECOVER" \
    '( -z "$ov" && "$PHASE" == down-done && "$c_owner" == "$OWNER" )' \
    '( -z "$ov" && "$PHASE" == down-done )' \
    'down-done, an expired claim file that is the recorded one but names no owner: rc 3, nothing written'

# R5-1c moves the check; it does not delete it (r6): the fabric is looked at only AFTER the re-claim wrote,
# so what goes red is "the claim stub never called" (the release and the knob are never reached either way).
add "R5-1c. the fabric is checked after the re-claim, not before (r5 follow-up 1b)" \
    "$RECOVER" \
    '    down_done_fabric_check
    busy="$(measuring_now)"
    if [[ -n "$c_meas" || -n "$busy" ]]; then
        echo "STOP: the claim is expired, but a measurement is declared or running:"
        echo "  ${c_meas:+claim measuring=$c_meas }$busy"
        echo "  nothing written."
        exit 3
    fi
    echo "  the claim is expired, it is the one the probe recorded, the override still names this run'"'"'s"
    echo "  package (or, in down-done, ndt down cleared it and the claim file is ours) and nothing is"
    echo "  measuring: re-claiming as $OWNER"
    if ! NDT_OWNER="$OWNER" "$NDT" claim 30 "p4-health $RUNID $BRINGUP recover state=$STATE"; then
        echo "STOP: the re-claim was refused; nothing written."; exit 3
    fi' \
    '    busy="$(measuring_now)"
    if [[ -n "$c_meas" || -n "$busy" ]]; then
        echo "STOP: the claim is expired, but a measurement is declared or running:"
        echo "  ${c_meas:+claim measuring=$c_meas }$busy"
        echo "  nothing written."
        exit 3
    fi
    echo "  the claim is expired, it is the one the probe recorded, the override still names this run'"'"'s"
    echo "  package (or, in down-done, ndt down cleared it and the claim file is ours) and nothing is"
    echo "  measuring: re-claiming as $OWNER"
    if ! NDT_OWNER="$OWNER" "$NDT" claim 30 "p4-health $RUNID $BRINGUP recover state=$STATE"; then
        echo "STOP: the re-claim was refused; nothing written."; exit 3
    fi
    down_done_fabric_check  # MUTANT: after the re-claim' \
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

# Round 6 (the run's identity: its own package directory, its own claim's expires, a state file that
# is complete). Each mutant names the ONE check that must go red.
add "R6-1a. recover.sh does not ask that the package is inside the run dir" \
    "$RECOVER" \
    'if [[ "$pkg_abs" != "$run_abs"/* ]]; then' \
    'if false; then  # MUTANT' \
    'a package outside the run dir, every other thing matching (owner, live claim, override, expires): rc 3, no stub called'

add "R6-1b. recover.sh takes a sibling directory whose name starts with the run dir's" \
    "$RECOVER" \
    'if [[ "$pkg_abs" != "$run_abs"/* ]]; then' \
    'if [[ "$pkg_abs" != "$run_abs"* ]]; then  # MUTANT: no path boundary' \
    'a package in a sibling dir whose name starts with the run dir'"'"'s: rc 3, no stub called'

add "R6-1c. recover.sh does not resolve the package path (.. and links)" \
    "$RECOVER" \
    'run_abs="$(readlink -m "$RUN")"; pkg_abs="$(readlink -m "$PKG")"' \
    'run_abs="$(readlink -m "$RUN")"; pkg_abs="$PKG"  # MUTANT' \
    'a package that climbs out of the run dir with ..: rc 3, no stub called'

add "R6-1d. LabRound takes a package outside its run dir" \
    "$LABROUND" \
    '        if not package_inside(package_real, cfg.run_dir):' \
    '        if False:  # MUTANT' \
    'test_a_package_outside_the_run_dir_is_refused_and_nothing_is_touched'

add "R6-1e. package_inside has no path boundary" \
    "$LABROUND" \
    '    return pkg != run and pkg.startswith(run.rstrip(os.sep) + os.sep)' \
    '    return pkg != run and pkg.startswith(run)  # MUTANT' \
    'test_a_package_outside_the_run_dir_is_refused_and_nothing_is_touched'

add "R6-1f. LabRound does not follow links in the package path" \
    "$LABROUND" \
    '        package_real = os.path.realpath(package_dir)' \
    '        package_real = os.path.abspath(package_dir)  # MUTANT' \
    'test_a_package_outside_the_run_dir_is_refused_and_nothing_is_touched'

add "R6-1g. package_inside accepts the run dir itself" \
    "$LABROUND" \
    '    return pkg != run and pkg.startswith(run.rstrip(os.sep) + os.sep)' \
    '    return pkg.startswith(run.rstrip(os.sep) + os.sep) or pkg == run  # MUTANT' \
    'test_a_package_outside_the_run_dir_is_refused_and_nothing_is_touched'

add "R6-2a. recover.sh trusts a live claim of the owner whatever its expires" \
    "$RECOVER" \
    '"$c_exp" -gt "$now" && "$claim_same" -eq 1 && "$override_ours" -eq 1' \
    '"$c_exp" -gt "$now" && "$override_ours" -eq 1' \
    'a live claim of our owner with another expires than the probe recorded: rc 3, no stub called'

add "R6-2b. recover.sh re-claims over an expired claim of the owner whatever its expires" \
    "$RECOVER" \
    '"$c_exp" -le "$now" && "$claim_same" -eq 1 \' \
    '"$c_exp" -le "$now" \' \
    'an expired claim of our owner that is not the one the probe recorded: rc 3, no stub called'

add "R6-2c. the claim is the same when it merely has some expires" \
    "$RECOVER" \
    'claim_same=0; [[ "$c_exp" -gt 0 && "$c_exp" -eq "$CLAIM_EXPIRES" ]] && claim_same=1' \
    'claim_same=0; [[ "$c_exp" -gt 0 ]] && claim_same=1  # MUTANT' \
    'an older down-done run dir under a later same-owner round'"'"'s live claim: rc 3, no stub called'

add "R6-2d. recover.sh forgets the new expires after its own re-claim" \
    "$RECOVER" \
    '&& state_set claim_expires "$new_exp"' \
    '&& true' \
    'after the re-claim the state records the new claim'"'"'s expires'

add "R6-2e. LabRound records no expires after the claim" \
    "$LABROUND" \
    '        self.write_state(claim_expires=int(exp))' \
    '        self.write_state()  # MUTANT' \
    'test_the_claims_expires_is_recorded_right_after_the_claim_and_before_the_up'

add "R6-2f. LabRound records the expires it computed, not the one the file shows" \
    "$LABROUND" \
    '        self.write_state(claim_expires=int(exp))' \
    '        self.write_state(claim_expires=int(self.clock()) + 60 * self.minutes)  # MUTANT' \
    'test_the_claims_expires_is_recorded_right_after_the_claim_and_before_the_up'

add "R6-2g. LabRound brings the lab up on a claim the file does not show" \
    "$LABROUND" \
    '        if mine.get("owner") != self.cfg.owner or not re.match(r"[1-9][0-9]*\Z", exp):' \
    '        if False:  # MUTANT' \
    'test_a_claim_the_file_does_not_show_as_ours_is_not_brought_up_on'

add "R6-2h. LabRound takes somebody else's claim for its own" \
    "$LABROUND" \
    '        if mine.get("owner") != self.cfg.owner or not re.match(r"[1-9][0-9]*\Z", exp):' \
    '        if not re.match(r"[1-9][0-9]*\Z", exp):  # MUTANT' \
    'test_a_claim_the_file_does_not_show_as_ours_is_not_brought_up_on'

add "R6-3a. recover.sh does not ask for an owner" \
    "$RECOVER" \
    '    "owner:$OWNER" \' \
    '    "ok:x" \' \
    'LAB_STATE.json without owner: rc 2, no stub called'

add "R6-3b. recover.sh does not ask for a run id" \
    "$RECOVER" \
    '    "run:$RUNID" \' \
    '    "ok:x" \' \
    'LAB_STATE.json without run: rc 2, no stub called'

add "R6-3c. recover.sh does not ask for a package" \
    "$RECOVER" \
    '    "package:$PKG" \' \
    '    "ok:x" \' \
    'LAB_STATE.json without package: rc 2, no stub called'

add "R6-3d. recover.sh does not ask for a claim file" \
    "$RECOVER" \
    '    "claim_file:$CLAIM_FILE" \' \
    '    "ok:x" \' \
    'LAB_STATE.json without claim_file: rc 2, no stub called'

add "R6-3e. recover.sh does not ask for the override path" \
    "$RECOVER" \
    '    "app_package_override:$OVERRIDE"; do' \
    '    "ok:x"; do' \
    'LAB_STATE.json without app_package_override: rc 2, no stub called'

add "R6-3g. recover.sh takes any claim_expires for a time" \
    "$RECOVER" \
    'if ! [[ "$CLAIM_EXPIRES" =~ ^[1-9][0-9]*$ ]]; then' \
    'if false; then  # MUTANT' \
    'LAB_STATE.json without claim_expires: rc 2, no stub called'

add "R6-3h. recover.sh takes 0 for a time" \
    "$RECOVER" \
    'if ! [[ "$CLAIM_EXPIRES" =~ ^[1-9][0-9]*$ ]]; then' \
    'if ! [[ "$CLAIM_EXPIRES" =~ ^[0-9]+$ ]]; then  # MUTANT' \
    'LAB_STATE.json with a claim_expires of 0: rc 2, no stub called'

# Round 7 (the review of the run-identity branch: the knob as ndt writes it, the phase after recover's own
# ndt down, an absent knob under a live claim, the claim looked at again, the messages).
add "R7-1a. recover.sh reads the first line of the knob (head -1), a comment in real ndt" \
    "$RECOVER" \
    'ov=""
if [[ -f "$OVERRIDE" ]]; then
    while read -r knob_line; do
        knob_line="${knob_line%%$'"'"'\r'"'"'}"      # (read already trims the blanks around a line, as in the reader of ndt itself)
        [[ -z "$knob_line" || "$knob_line" == \#* ]] && continue
        ov="$knob_line"; break
    done < "$OVERRIDE"
fi' \
    'ov=""; [[ -f "$OVERRIDE" ]] && ov="$(head -1 "$OVERRIDE")"  # MUTANT' \
    "the knob in ndt's two-line format: the recovery reads the path, not the comment: rc 0"

add "R7-1b. the knob reader does not skip blank lines" \
    "$RECOVER" \
    '        [[ -z "$knob_line" || "$knob_line" == \#* ]] && continue' \
    '        [[ "$knob_line" == \#* ]] && continue  # MUTANT' \
    "a knob with blank lines, an indented comment and a CR-LF path (ndt's reader skips them): rc 0"

add "R7-1d. the knob reader keeps the CR of a CR-LF path" \
    "$RECOVER" \
    '        knob_line="${knob_line%%$'"'"'\r'"'"'}"      # (read already trims the blanks around a line, as in the reader of ndt itself)' \
    '        :  # MUTANT: the CR of a CR-LF path stays' \
    "a knob with blank lines, an indented comment and a CR-LF path (ndt's reader skips them): rc 0"

add "R7-4a. recover.sh does not record down-done after its own ndt down" \
    "$RECOVER" \
    'state_set phase down-done
fi   # steps 4-5' \
    ': # MUTANT
fi   # steps 4-5' \
    "after its own ndt down the state says down-done"

add "R7-4b. recover.sh does not record down-failed after its own failed ndt down" \
    "$RECOVER" \
    '    state_set phase down-failed' \
    '    : # MUTANT' \
    "after its own failed ndt down the state says down-failed"

add "R7-2a. an absent knob is backed by an ndt up note" \
    "$RECOVER" \
    'if [[ -z "$ov" && "$c_note" == "in use: ndt up p4 "* ]]; then note_ours=0; fi' \
    ':  # MUTANT' \
    "teardown, knob absent, our live claim with the note of somebody's ndt up: rc 3, no stub called"

add "R7-2b. the up-note rule leaves out down-done" \
    "$RECOVER" \
    'if [[ -z "$ov" && "$c_note" == "in use: ndt up p4 "* ]]; then note_ours=0; fi' \
    'if [[ -z "$ov" && "$PHASE" != down-done && "$c_note" == "in use: ndt up p4 "* ]]; then note_ours=0; fi  # MUTANT' \
    "down-done, knob absent, our live claim with an ndt up note: rc 3, no stub called"

add "R7-2c. a forced up past this run's claim is not looked at" \
    "$RECOVER" \
    '    claim_overridden=1; claim_same=0' \
    '    claim_overridden=1  # MUTANT' \
    "a forced up past this run's live claim is on record: rc 3, no stub called"

add "R7-2d. any forced up on record counts, not only one past this run's claim" \
    "$RECOVER" \
    '
        '"'"'{ for (i = 1; i <= NF; i++) if ($i == e) f = 1 } END { exit !f }'"'"' "$CLAIM_FILE.overrides"; then' \
    '
        '"'"'{ for (i = 1; i <= NF; i++) if (index($i, "claim_expires=") == 1) f = 1 } END { exit !f }'"'"' "$CLAIM_FILE.overrides"; then' \
    "a forced up past ANOTHER claim is on record: no effect, rc 0"

add "R7-3a. the claim is not looked at again after the down" \
    "$RECOVER" \
    'if [[ "$(claim_get owner)" != "$OWNER" || "$(claim_get expires)" != "$CLAIM_EXPIRES" ]]; then' \
    'if false; then  # MUTANT' \
    "a claim of the same owner taken while ndt down ran: rc 3"

add "R7-3b. the second look at the claim reads only the owner" \
    "$RECOVER" \
    'if [[ "$(claim_get owner)" != "$OWNER" || "$(claim_get expires)" != "$CLAIM_EXPIRES" ]]; then' \
    'if [[ "$(claim_get owner)" != "$OWNER" ]]; then  # MUTANT' \
    "a claim of the same owner taken while ndt down ran: rc 3"

add "R7-5a. the gone claim file is not said to be gone" \
    "$RECOVER" \
    '        echo "  the claim file is gone ($CLAIM_FILE)."' \
    '        :  # MUTANT' \
    "a claim file that is gone, its released copy kept as .prev: rc 3 and the output says which claim it was"

add "R7-5b. the kept released claim is never said to be this run's" \
    "$RECOVER" \
    '            [[ "$p_exp" == "$CLAIM_EXPIRES" ]] && echo' \
    '            false && echo  # MUTANT' \
    "a claim file that is gone, its released copy kept as .prev: rc 3 and the output says which claim it was"

add "R7-5c. the unrecorded claim's release command is not printed" \
    "$RECOVER" \
    '        echo "  Release it with:  NDT_OWNER=$OWNER $NDT release"' \
    '        :  # MUTANT' \
    "no claim_expires and the claim's note names this run: rc 2 and the output prints the release command"

add "R7-5d. the release command is printed for any claim of the owner" \
    "$RECOVER" \
    '&& "$(claim_get note)" == "p4-health $RUNID $BRINGUP state=$STATE" ]]; then' \
    ']]; then  # MUTANT' \
    "no claim_expires and a claim that is not this run's: rc 2 and no release command"

add "R7-L1. LabRound uses the path as given, not the resolved one" \
    "$LABROUND" \
    '        self.bringup, self.package_dir, self.run_id = bringup, package_real, run_id' \
    '        self.bringup, self.package_dir, self.run_id = bringup, package_dir, run_id  # MUTANT' \
    'test_the_package_path_is_resolved_once_and_that_path_is_used_everywhere'

add "R7-L2. LabRound takes expires 0 for a time" \
    "$LABROUND" \
    '        if mine.get("owner") != self.cfg.owner or not re.match(r"[1-9][0-9]*\Z", exp):' \
    '        if mine.get("owner") != self.cfg.owner or not re.match(r"[0-9]+\Z", exp):  # MUTANT' \
    'test_a_claim_the_file_does_not_show_as_ours_is_not_brought_up_on'

add "R7-L3. LabRound takes str.isdigit for a time" \
    "$LABROUND" \
    '        if mine.get("owner") != self.cfg.owner or not re.match(r"[1-9][0-9]*\Z", exp):' \
    '        if mine.get("owner") != self.cfg.owner or not exp.isdigit() or int(exp) <= 0:  # MUTANT' \
    'test_a_claim_the_file_does_not_show_as_ours_is_not_brought_up_on'

# Round 8 (a down that already ran leaves no interfaces; recover.sh's own re-claim records the round's host
# count as the release baseline; the unrecorded-claim hint). The stubs follow ndt: see the test.
add "R8-1a. a down is taken for done without asking ndt status" \
    "$RECOVER" \
    '    if [[ "$n_bmv2" == 0 && "$n_mn" == 0 ]]; then' \
    '    if true; then  # MUTANT' \
    "teardown, knob absent, our live claim with this run's own note: rc 0 (tc, down, release)"

add "R8-1b. an absent knob does not ask ndt status: the qdisc diff runs against a fabric that is gone" \
    "$RECOVER" \
    'elif [[ -z "$ov" ]]; then' \
    'elif false; then  # MUTANT' \
    "  ... the retry finds no fabric and finishes: rc 0"

add "R8-1c. ndt down exiting 3 (measured nothing) is a failure" \
    "$RECOVER" \
    'if [[ "$down_rc" -eq 3 ]]; then' \
    'if false; then' \
    "ndt down exits 3 (measured nothing, the lab was down): the down is done, rc 0"

add "R9-1. the down-already-ran branch skips ndt down too, and releases without any down having succeeded" \
    "$RECOVER" \
    '        SKIP_NETEM=1' \
    '        SKIP_NETEM=1; SKIP_DOWN=1' \
    "down-failed, knob absent, status 0/0, the probe's did-NOT-verify-clean note, the retry's ndt down exits 1: rc 5"

add "R8-2a. every recovery releases with --force" \
    "$RECOVER" \
    'if [[ -n "$recover_exp" && "$recover_exp" == "$(claim_get expires)" ]] && knobs_match_snapshot; then' \
    'if true; then  # MUTANT' \
    "stop sniffer, stop controller, netem off, qdisc diff, down, release, status"

add "R8-2b. recover.sh's own re-claim is released plainly" \
    "$RECOVER" \
    'if [[ -n "$recover_exp" && "$recover_exp" == "$(claim_get expires)" ]] && knobs_match_snapshot; then' \
    'if false; then  # MUTANT' \
    "an expired claim, the package changed the host count: rc 0 and the host knob at its pre-round value"

add "R8-2c. recover.sh does not record which claim is its own re-claim" \
    "$RECOVER" \
    '&& state_set recover_claim_expires "$new_exp"' \
    '&& true  # MUTANT' \
    "  ... and the retry under that live claim finishes: rc 0"

add "R8-2d. a refused release tells the person to do what ndt printed (write the baseline back)" \
    "$RECOVER" \
    '    echo "STOP: ndt release refused (above). The knobs were put back to their pre-round snapshot in step 6: do NOT write"' \
    '    echo "STOP: ndt release refused (above); do what it printed (pre-round snapshot)"' \
    "a release refused for another reason: rc 6 and the output says what was restored, not to write the baseline back"

add "R8-3a. the unrecorded-claim hint ignores the forced-up record" \
    "$RECOVER" \
    '-v e="claim_expires=$(claim_get expires)" \' \
    '-v e="claim_expires=nomatch" \' \
    "a forced up on record over the unrecorded claim: rc 2, the output warns and does not say nothing was brought up"

add "R8-3b. the unrecorded-claim hint never says nothing was brought up" \
    "$RECOVER" \
    '            echo "  Nothing was brought up under it (no forced up is on record for it)."' \
    '            :  # MUTANT' \
    "no forced up on record over it: rc 2 and the output says nothing was brought up under it"

add "R9-3a. a status with a missing row is read as 0 in the down-already-ran branch" \
    "$RECOVER" \
    '    if [[ "$n_bmv2" == 0 && "$n_mn" == 0 ]]; then' \
    '    if [[ "${n_bmv2:-0}" == 0 && "${n_mn:-0}" == 0 ]]; then' \
    "knob absent and ndt status printed nothing: steps 4-5 as before (qdisc drift: rc 4), no release"

add "R9-3b. a status with a missing row is read as 0 in the down-done fabric check" \
    "$RECOVER" \
    '    if [[ "$n_bmv2" != 0 || "$n_mn" != 0 ]]; then' \
    '    if [[ "${n_bmv2:-0}" != 0 || "${n_mn:-0}" != 0 ]]; then' \
    "down-done and ndt status printed nothing: rc 4, nothing released (the fabric is not shown to be gone)"

add "R9-4. a claim that is not live now is adopted as this script's own re-claim" \
    "$RECOVER" \
    '(( new_exp > $(date +%s) )) && ' \
    '' \
    "an expired claim, ndt claim exits 0 and writes nothing: the probe's old expires is not adopted, plain release, rc 0"

add "R9-5. the second look at the claim reads only the expires" \
    "$RECOVER" \
    'if [[ "$(claim_get owner)" != "$OWNER" || "$(claim_get expires)" != "$CLAIM_EXPIRES" ]]; then' \
    'if [[ "$(claim_get expires)" != "$CLAIM_EXPIRES" ]]; then' \
    "another owner takes the claim during ndt down (the expires stays): rc 3, nothing released, the knob not written"


# --- Cut 2: bring-up A's observers, B's attributions, the lab run ----------------------------------
OBSA="$PKG/observe_a.py"
ROUNDA="$PKG/round_a.py"
ROUNDB="$PKG/round_b.py"
ATTR="$PKG/attribution.py"
LABPY="$PKG/lab.py"
HOSTSPY="$PKG/collect/hosts.py"
FROZENPY="$PKG/frozen.py"

add "C2-V1. a cell never observed reads as an unreadable answer" \
    "$VERDICT" \
    '    if obs is None:
        return Verdict(NOT_RUN, "not observed in this run", phase="unobserved")' \
    '    if False:  # MUTANT
        return Verdict(NOT_RUN, "not observed in this run", phase="unobserved")' \
    'test_a_cell_never_observed_is_not_run_for_that_reason'

add "C2-RA1. --only forgets the cells that produce a self-check's readings" \
    "$ROUNDA" \
    '            todo.append(SC_PRODUCER[cid])' \
    '            pass  # MUTANT' \
    'test_only_expands_to_the_gates_controls_and_self_check_producers'

add "C2-RA2. --only forgets the controls" \
    "$ROUNDA" \
    '        todo += list(spec.gates) + list(getattr(spec, "controls", ())) + list(spec.self_checks)' \
    '        todo += list(spec.gates) + list(spec.self_checks)  # MUTANT' \
    'test_only_expands_to_the_gates_controls_and_self_check_producers'

add "C2-RA3. the pingall counts every other host as reached" \
    "$ROUNDA" \
    '            got += len(srcs - {self.hosts.ip(dst)})' \
    '            got += len(HOSTS) - 1  # MUTANT' \
    'test_a_host_the_pingall_cannot_reach_is_sc_fwd_probe_broken'

add "C2-RA4. SC-count takes the sender's count for what arrived" \
    "$ROUNDA" \
    '        received = None if rx.get("text") is None else len(S.received(rx["text"], "K1"))' \
    '        received = obs.get("sent")  # MUTANT' \
    'test_k1_markers_lost_on_the_path_leave_sc_count_undecided'

add "C2-OA1. a write cell's negative read is taken after the write" \
    "$OBSA" \
    '    negative = None if before is None else {"absent": not find(before),' \
    '    negative = None if before is None else {"absent": not find(after),  # MUTANT' \
    'test_bring_up_a_reads_as_predicted'

add "C2-OA2. thrift's priority is read as the P4Runtime number" \
    "$OBSA" \
    '    return BMV2_PRIORITY_TOP - int(p4rt_priority)' \
    '    return int(p4rt_priority)  # MUTANT' \
    'test_a_proxy_that_writes_ternary_turns_t4_to_t7_green'

add "C2-OA3. T7's order is read the P4Runtime way round" \
    "$OBSA" \
    'n[0]["priority"] < w[0]["priority"]}' \
    'n[0]["priority"] > w[0]["priority"]}  # MUTANT' \
    'test_a_proxy_that_writes_ternary_turns_t4_to_t7_green'

add "C2-OA4. T1's negative read ignores a foreign sentinel" \
    "$OBSA" \
    '        negative = {"absent": not foreign,' \
    '        negative = {"absent": True,  # MUTANT' \
    'test_a_foreign_sentinel_fails_t1s_negative_read'

add "C2-OA5. an unreadable table dump is an empty one" \
    "$OBSA" \
    '                got = None
                break' \
    '                continue  # MUTANT' \
    'test_an_unreachable_switch_leaves_t1_not_run'

add "C2-OA6. T2 takes s2's runtime default as applied whatever the counts say" \
    "$OBSA" \
    '            answer = {"applied": bool(te.get("failed") == 0 and te.get("recorded", 0) > 0' \
    '            answer = {"applied": True or bool(te.get("failed") == 0 and te.get("recorded", 0) > 0  # MUTANT' \
    'test_a_failed_entry_on_s2_is_t2_red'

add "C2-OA7. T2's negative read passes whatever s3 shows" \
    "$OBSA" \
    '        negative = {"absent": got == ("HcIngress.stamp", (0,)),' \
    '        negative = {"absent": True,  # MUTANT' \
    'test_s3_not_on_the_compiled_default_fails_t2s_negative_read'

add "C2-OA8. C1's negative read ignores a session on another switch" \
    "$OBSA" \
    'else {"absent": not any(o[0] for o in others)}' \
    'else {"absent": True}  # MUTANT' \
    'test_a_missing_clone_session_is_c1_red_and_a_stray_one_fails_the_negative'

add "C2-OA9. a missing clone session is an unread oracle" \
    "$OBSA" \
    '    if s2 is not None and not s2[0]:
        oracle = {"ports": frozenset()}' \
    '    if False:  # MUTANT
        oracle = {"ports": frozenset()}' \
    'test_a_missing_clone_session_is_c1_red_and_a_stray_one_fails_the_negative'

add "C2-OA10. M2's negative read passes with group 2 already there" \
    "$OBSA" \
    '{"absent": 2 not in before}' \
    '{"absent": True}  # MUTANT' \
    'test_group_2_there_before_the_write_fails_m2s_negative_read'

add "C2-OA11. one host's unreadable ethtool still yields an oracle" \
    "$OBSA" \
    '    if any(v is None for v in got.values()):
        return {"oracle": None}' \
    '    if False:  # MUTANT
        return {"oracle": None}' \
    'test_checksum_unreadable_on_one_host_is_not_run'

add "C2-OA12. an unreadable openapi means no digest / packet-in exit" \
    "$OBSA" \
    '    if route is None:
        return None' \
    '    if route is None:
        route = False  # MUTANT' \
    'test_an_unreadable_openapi_is_not_a_missing_route'

add "C2-OA13. an exit the probe cannot read is taken for no exit" \
    "$OBSA" \
    'exit=route, fields=None)' \
    'exit=False, fields=None)  # MUTANT' \
    'test_an_exit_the_probe_has_no_client_for_is_not_run'

add "C2-OA14. K2's thrift oracle reads the indirect counter" \
    "$OBSA" \
    '    th0 = None if handle is None else reader.read(dpid, "counter_read %s %d" % (full, handle))' \
    '    th0 = None if handle is None else reader.read(dpid, "counter_read HcIngress.c_in 0")  # MUTANT' \
    'test_a_proxy_that_reads_direct_counters_turns_k2_green'

add "C2-OA15. the meter cells' negative read passes with the rates already set" \
    "$OBSA" \
    '{"absent": before != METER_TARGET}' \
    '{"absent": True}  # MUTANT' \
    'test_a_kernel_that_installs_meters_turns_mt1_green_and_needs_the_before_read'

add "C2-OA16. the kernel's MAC integer is read little-endian" \
    "$OBSA" \
    'to_bytes(6, "big"))' \
    'to_bytes(6, "little"))  # MUTANT' \
    'test_bring_up_a_reads_as_predicted'

add "C2-OA17. the kernel's IPv4 integer is read big-endian" \
    "$OBSA" \
    'to_bytes(4, "little"))' \
    'to_bytes(4, "big"))  # MUTANT' \
    'test_bring_up_a_reads_as_predicted'

add "C2-OA18. SC-ttl's links point back at the switch itself" \
    "$OBSA" \
    '            out[(a[1], a[2])] = b[1]' \
    '            out[(a[1], a[2])] = a[1]  # MUTANT' \
    'test_bring_up_a_reads_as_predicted'

add "C2-HO1. the stimulus runs although a sniffer never listened" \
    "$HOSTSPY" \
    '        out = stimulate() if all(ready) else ""' \
    '        out = stimulate()  # MUTANT' \
    'test_a_sniffer_that_never_listens_sends_nothing'

add "C2-HO2. a sniffer is not recorded in LAB_STATE" \
    "$HOSTSPY" \
    '                self.register("sniffer", proc.pid, self.token)' \
    '                pass  # MUTANT' \
    'test_every_reading_goes_through_the_one_runner'

add "C2-AT1. a table attribution stands on thrift alone" \
    "$ATTR" \
    '        if not ok:
            return put(item, False, "controller: %s" % err)
        found = _entries(read(cmd), key, params)' \
    '        found = _entries(read(cmd), key, params)  # MUTANT' \
    'test_a_failed_call_fails_its_item_whatever_thrift_shows'

add "C2-AT2. a table attribution ignores the priority thrift shows" \
    "$ATTR" \
    '        if found[0]["priority"] != thrift_priority(priority):' \
    '        if False:  # MUTANT' \
    'test_thrift_that_does_not_show_the_effect_fails_the_item'

add "C2-AT3. the priority attribution wants the P4Runtime order in thrift's numbers" \
    "$ATTR" \
    'and a[0]["priority"] < b[0]["priority"]):' \
    'and a[0]["priority"] > b[0]["priority"]):  # MUTANT' \
    'test_every_item_confirmed'

add "C2-AT4. a meter attribution holds whenever thrift answered" \
    "$ATTR" \
    '        if rates != METER_RATES:' \
    '        if rates is None:  # MUTANT' \
    'test_thrift_that_does_not_show_the_effect_fails_the_item'

add "C2-AT5. any DigestList confirms the digest" \
    "$ATTR" \
    '    elif want not in got:' \
    '    elif not got:  # MUTANT' \
    'test_the_stream_messages_must_carry_what_the_probe_sent'

add "C2-AT6. a clone session to any port confirms the clone" \
    "$ATTR" \
    '        if ports != frozenset([CX.CLONE["port"]]):' \
    '        if not ports:  # MUTANT' \
    'test_thrift_that_does_not_show_the_effect_fails_the_item'

add "C2-AT7. the register attribution does not read the register" \
    "$ATTR" \
    '        put("register", v == CX.REGISTER["value"],' \
    '        put("register", True,' \
    'test_thrift_that_does_not_show_the_effect_fails_the_item'

add "C2-AT8. the direct counter attribution takes the controller's own number" \
    "$ATTR" \
    '    elif not mine or mine != th[1]:' \
    '    elif not mine:  # MUTANT' \
    'test_thrift_that_does_not_show_the_effect_fails_the_item'

add "C2-AT9. a packet-in from any port confirms" \
    "$ATTR" \
    '    elif any(p.get("ingress_port") != expect.get("packet_in_port") for p in ours):' \
    '    elif False:  # MUTANT' \
    'test_the_stream_messages_must_carry_what_the_probe_sent'

add "C2-AT10. any packet-in confirms, marker or not" \
    "$ATTR" \
    '    ours = [p for p in pins if (p.get("marker") or [None, None])[:2] == [expect.get("token"), expect.get("packet_in_cell", "P2")]]' \
    '    ours = list(pins)  # MUTANT' \
    'test_the_stream_messages_must_carry_what_the_probe_sent'

add "C2-AT11. a packet-out nobody received confirms" \
    "$ATTR" \
    '    elif not p3_received:' \
    '    elif p3_received is None:  # MUTANT' \
    'test_the_packet_out_needs_the_receiving_host'

add "C2-AT12. every cell gets a bmv2 attribution" \
    "$ATTR" \
    '    return {cell: {"bmv2": bool((confirmed or {}).get(item, {}).get("ok"))}' \
    '    return {cell: {"bmv2": True}  # MUTANT' \
    'test_each_cell_gets_its_items_attribution'

add "C2-RB1. B never tells its controller the stimuli are done" \
    "$ROUNDB" \
    '            open(self.path("controller.go"), "w").close()' \
    '            pass  # MUTANT' \
    'test_the_eleven_attributions_confirmed_from_thrift_and_the_receiver'

add "C2-RB2. B's controller is not recorded in LAB_STATE" \
    "$ROUNDB" \
    '            lab_round.register("controller", proc.pid, os.path.realpath(self.cfg.run_dir))' \
    '            pass  # MUTANT' \
    'test_the_eleven_attributions_confirmed_from_thrift_and_the_receiver'

add "C2-LAB1. B's attributions never reach A's cells" \
    "$LABPY" \
    '            out[cell] = dict(out[cell], attribution=dict(out[cell].get("attribution") or {}, **attr))' \
    '            pass  # MUTANT' \
    'test_a_then_b_then_the_verdicts'

add "C2-LAB2. the lab runs after an incomplete S0" \
    "$LABPY" \
    '    if s0_out.get("verdict") != "COMPLETE":' \
    '    if False:  # MUTANT' \
    'test_an_incomplete_s0_touches_nothing'

add "C2-LAB3. the see-red run brings up the plain package" \
    "$LABPY" \
    '"A-MUT" if mutant else "A")' \
    '"A")  # MUTANT' \
    'test_the_see_red_run_uses_the_mutant_package_and_only_its_cells'

add "C2-LAB4. a run with an incomplete bring-up reads as complete" \
    "$LABPY" \
    '    complete = bool(recs) and all(r.get("complete") is True for r in recs)' \
    '    complete = True  # MUTANT' \
    'test_a_refused_claim_makes_the_run_incomplete'

# --- Cut 2 review fixes (r2) -----------------------------------------------------------------------
FABRIC="$PKG/collect/fabric.py"
HOSTSIDE="$PKG/hostside.py"

add "R2-M1a. a veth peer printed by name is dropped (MAJOR-1)" \
    "$FABRIC" \
    '        out[m.group(2)] = int(idx.group(1)) if idx else peer' \
    '        if idx:  # MUTANT: only the @ifK form
            out[m.group(2)] = int(idx.group(1))' \
    'test_bring_up_a_reads_as_predicted'

add "R2-M1b. a switch port nobody could place is not an unread oracle (MAJOR-1's mirror)" \
    "$OBSA" \
    '    if d_["unplaced"]:
        return fail(' \
    '    if False:  # MUTANT
        return fail(' \
    'test_switch_links_lost_on_both_sides_are_not_a_green'

add "R2-M2a. the sniffer takes any frame that quotes a marker (MAJOR-2)" \
    "$HOSTSIDE" \
    '    if p.get("proto") != F.PROTO_UDP or p.get("dport") != dport or p.get("ip_dst") != ip:
        return None' \
    '    if False:  # MUTANT
        return None' \
    'test_bring_up_a_reads_as_predicted'

add "R2-M2b. the sniffer checks only the destination address, not that it is UDP to the cell's port" \
    "$HOSTSIDE" \
    '    if p.get("proto") != F.PROTO_UDP or p.get("dport") != dport or p.get("ip_dst") != ip:' \
    '    if p.get("ip_dst") != ip:  # MUTANT' \
    'test_an_icmp_error_quoting_a_marker_is_not_a_received_marker'

add "R2-M2c. the sniffer ignores the destination address" \
    "$HOSTSIDE" \
    '    if p.get("proto") != F.PROTO_UDP or p.get("dport") != dport or p.get("ip_dst") != ip:' \
    '    if p.get("proto") != F.PROTO_UDP or p.get("dport") != dport:  # MUTANT' \
    'test_record_filters_on_every_field'

add "R2-M2d. the sniffer on a host is not told its own address" \
    "$HOSTSPY" \
    '                                                      "--ip", self.ip(host)])' \
    '                                                      "--ip", self.ip("h1")])  # MUTANT' \
    'test_bring_up_a_reads_as_predicted'

add "R2-m3a. the sniffer counts the host's own outgoing frames" \
    "$HOSTSIDE" \
    '    return len(addr) > 2 and addr[2] == PACKET_OUTGOING' \
    '    return False  # MUTANT' \
    'test_the_sniff_loop_skips_outgoing_frames_and_stops_at_until'

add "R2-m3b. the sniffer never stops early" \
    "$HOSTSIDE" \
    '            if until and n >= until:
                break' \
    '            if False:  # MUTANT
                break' \
    'test_the_sniff_loop_skips_outgoing_frames_and_stops_at_until'

add "R2-m3c. the SENT line reports what was asked for" \
    "$HOSTSIDE" \
    '    return "SENT cell=%s n=%d ident=%d requested=%d" % (cell, n, ident, requested)' \
    '    return "SENT cell=%s n=%d ident=%d requested=%d" % (cell, requested, ident, requested)  # MUTANT' \
    'test_its_lines_are_the_ones_collect_sniff_reads'

add "R2-m3d. pick_iface guesses among several interfaces" \
    "$HOSTSIDE" \
    '    if len(names) != 1:' \
    '    if not names:  # MUTANT' \
    'test_pick_iface'

add "R2-w1. the root python writes .pyc beside the sources" \
    "$HOSTSPY" \
    '        return [self.cfg.p4dev_python, "-B", "-X",' \
    '        return [self.cfg.p4dev_python, "-X",  # MUTANT' \
    'test_the_root_python_writes_nothing_beside_the_sources'

add "R2-M3a. B is brought up whatever A's teardown left (MAJOR-3)" \
    "$LABPY" \
    '        if why and "B" in bringups:' \
    '        if False:  # MUTANT' \
    'test_a_failed_down_in_a_keeps_b_out'

add "R2-M3b. ended_clean looks at the phase only" \
    "$LABPY" \
    '    if any("could not stop" in p for p in rec.get("problems") or []):
        why.append("a process it could not stop")
    left = [k for k in ("sniffers", "controllers", "netem") if st.get(k)]
    if left:' \
    '    left = []  # MUTANT
    if left:' \
    'test_a_failed_kill_in_a_keeps_b_out'

add "R2-M3c. a round overwrites a state file recover.sh still needs" \
    "$LABROUND" \
    '        in_use = state_in_use(cfg.lab_state_path)' \
    '        in_use = None  # MUTANT' \
    'test_an_unfinished_round_refuses_the_next'

add "R2-M3d. a released round that left a process counts as finished" \
    "$LABROUND" \
    '    left = [k for k in ("sniffers", "controllers", "netem") if st.get(k)]
    if left:
        return "bring-up' \
    '    left = []  # MUTANT
    if left:
        return "bring-up' \
    'test_an_unfinished_round_refuses_the_next'

add "R2-M3e. B starts its controller on a fabric that is not external" \
    "$ROUNDB" \
    '        if mode != "external":' \
    '        if False:  # MUTANT' \
    'test_b_spawns_no_controller_on_a_fabric_that_is_not_external'

add "R2-m4f. only the last bring-up's state file is kept" \
    "$LABPY" \
    '        keep_state(cfg, "A")' \
    '        pass  # MUTANT' \
    'test_each_bring_ups_last_state_is_kept'

add "R2-m1. an unobserved cell reads as a flip of its prediction" \
    "$EXPECTEDPY" \
    '    if phase == "unobserved":
        return NOT_OBSERVED' \
    '    if False:  # MUTANT
        return NOT_OBSERVED' \
    'test_a_cell_this_run_did_not_observe_has_no_delta'

add "R2-m1b. an alias of an unobserved cell reads as a flip" \
    "$VERDICT" \
    '                                         phase="unobserved" if src.phase == "unobserved" else "alias",' \
    '                                         phase="alias",  # MUTANT' \
    'test_a_then_b_then_the_verdicts'

add "R2-m2a. one observer raising ends the round's observing" \
    "$ROUNDA" \
    '        except Exception as exc:  # noqa: BLE001 -- recorded in problems and in the observation' \
    '        except ZeroDivisionError as exc:  # MUTANT' \
    'test_the_rest_of_the_round_is_still_observed'

add "R2-m2b. the step guard swallows a signal" \
    "$ROUNDA" \
    '        except SignalAbort:
            raise                                   # a signal still ends the round (lab_round)
        except Exception as exc:' \
    '        except BaseException as exc:  # MUTANT: catches the signal too' \
    'test_a_signal_still_ends_the_round'

add "R2-m7. VS1's negative read reads after the write" \
    "$OBSA" \
    '            "negative": None if before is None else {"absent": VS1_VALUE not in before}}' \
    '            "negative": None if before is None else {"absent": VS1_VALUE in before}}  # MUTANT' \
    'test_bring_up_a_reads_as_predicted'

add "R2-m5a. the see-red run's package is not drop-checked" \
    "$S0PY" \
    '        want = {"A": 0, "B": 0, "C": 0, "FWD": 1, "A-MUT": 0}' \
    '        want = {"A": 0, "B": 0, "C": 0, "FWD": 1}  # MUTANT' \
    'test_the_mutant_package_is_drop_checked'

add "R2-m5b. the adapter dry run passes whatever controller it names" \
    "$S0PY" \
    '        ok = (res.rc == 0 and ("controller: %s" % controller) in out' \
    '        ok = (res.rc == 0  # MUTANT' \
    'test_the_adapter_dry_run_names_our_controller_and_four_rewrites'

add "R2-m5c. the adapter dry run passes any rewrite" \
    "$S0PY" \
    '              and sorted(l.split("  ->  ")[1].strip() for l in rewrites) == want' \
    '              and len(rewrites) == 4  # MUTANT' \
    'test_the_adapter_dry_run_names_our_controller_and_four_rewrites'

IDPY="$PKG/identity.py"

add "R2-m4a. a lab run starts on a dirty probe tree" \
    "$PROBEPY" \
    '    if dirty:
        print("refused: tools/p4_health has uncommitted changes' \
    '    if False:  # MUTANT
        print("refused: tools/p4_health has uncommitted changes' \
    'test_a_dirty_probe_tree_is_refused_before_anything_runs'

add "R2-m4b. the root-run sflow_emitter.py may differ" \
    "$IDPY" \
    'MAY_DIFFER = (re.compile(r"^p4_proxy/proxy_agent/(?!sflow_emitter\.py$)"),' \
    'MAY_DIFFER = (re.compile(r"^p4_proxy/proxy_agent/"),  # MUTANT' \
    'test_the_may_differ_classes_are_the_designs'

add "R2-m4c. an unread part of the fingerprint still gives a digest" \
    "$IDPY" \
    '    total = UNREAD if any(v == UNREAD for v in parts.values()) else digest(parts.items())' \
    '    total = digest(parts.items())  # MUTANT' \
    'test_the_fingerprint_moves_with_what_must_be_the_same_only'

add "R2-m4d. the fingerprint ignores uncommitted edits (HEAD's blob instead of the file)" \
    "$IDPY" \
    '    return {"repo_tracked": digest((p, file_sha(os.path.join(repo, p)) or "absent") for p in keep_t),' \
    '    return {"repo_tracked": digest((p, "x") for p in keep_t),  # MUTANT' \
    'test_the_fingerprint_moves_with_what_must_be_the_same_only'


# --- Cut 2 second review (labels C2R3-) ------------------------------------------------------------------------

add "C2R3-N1a. a round stopped by a signal lets B claim the lab" \
    "$LABPY" \
    '        if signalled(recs[-1]):
            # (Cut 2 review N1) a stop is a stop' \
    '        if False:  # MUTANT
            # (Cut 2 review N1) a stop is a stop' \
    'test_a_signal_in_an_observer_ends_the_run'

add "C2R3-N1b. the stop signal is an Exception again (every except Exception swallows it)" \
    "$LABROUND" \
    'class SignalAbort(BaseException):' \
    'class SignalAbort(Exception):  # MUTANT' \
    'test_a_signal_while_a_sniffer_is_waited_for_ends_the_round_there'

add "C2R3-N1c. no handler between the rounds" \
    "$LABPY" \
    '    old_handlers = _stop_on_signals() if signals else None' \
    '    old_handlers = None  # MUTANT' \
    'test_a_signal_between_the_rounds_ends_the_run'

add "C2R3-N2. a B whose controller did nothing leaves the run complete" \
    "$LABPY" \
    '        elif b.failed:' \
    '        elif False:  # MUTANT' \
    'test_b_on_a_fabric_that_is_not_external_is_incomplete'

add "C2R3-N3a. a git that could not answer reads as a clean tree" \
    "$PROBEPY" \
    '    if git_rc != 0:
        # (Cut 2 review N3) no answer is not "clean"' \
    '    if False:  # MUTANT
        # (Cut 2 review N3) no answer is not "clean"' \
    'test_a_git_that_cannot_answer_is_refused_before_s0'

add "C2R3-N3b. the lab starts without a system-under-test record" \
    "$PROBEPY" \
    '    if sut is None or gate.get("sha256") in (None, "incomplete"):' \
    '    if gate.get("sha256") in (None, "incomplete"):  # MUTANT' \
    'test_a_missing_identity_record_stops_the_run_before_the_lab'

add "C2R3-N3c. the lab starts on an incomplete fingerprint" \
    "$PROBEPY" \
    '    if sut is None or gate.get("sha256") in (None, "incomplete"):' \
    '    if sut is None:  # MUTANT' \
    'test_a_missing_identity_record_stops_the_run_before_the_lab'

add "C2R3-N4a. a listed CPU port is taken for a fabric port" \
    "$OBSA" \
    '            if port == CPU_PORT:' \
    '            if False:  # MUTANT' \
    'test_a_listed_cpu_port_is_not_a_fabric_port'

add "C2R3-N4b. TP1 keeps no raw ip link text" \
    "$OBSA" \
    '    d_["ip_link"] = res.stdout' \
    '    d_["ip_link"] = None  # MUTANT' \
    'test_an_unplaced_port_is_not_run_and_tp1_keeps_what_it_read'

add "C2R3-N4c. TP1 does not say which read failed" \
    "$OBSA" \
    '            return fail("show_ports on s%d unreadable" % d)' \
    '            return None  # MUTANT' \
    'test_a_read_that_failed_is_named'

add "C2R3-N4d. S0's show_ports check rejects a listed CPU port" \
    "$S0PY" \
    '    return parsed is not None and set(parsed) - {cpu_port} == set(data_ports)' \
    '    return parsed is not None and set(parsed) == set(data_ports)  # MUTANT' \
    'test_show_ports_with_a_cpu_port_is_judged_on_the_data_ports'

add "C2R3-N7. an unobserved control reads as a flip" \
    "$TABLE" \
    '        if obs is None:
            # (Cut 2 second review N7)' \
    '        if False:  # MUTANT
            # (Cut 2 second review N7)' \
    'test_a_cell_this_run_did_not_observe_has_no_delta'

add "C2R3-N8a. root runs the shared tree's hostside.py, not the run's frozen copy" \
    "$LABPY" \
    '    a_kwargs = dict({"hostside": frozen.hostside}, **(a_kwargs or {}))' \
    '    a_kwargs = dict(a_kwargs or {})  # MUTANT' \
    'test_root_runs_a_frozen_copy_of_its_code_from_the_run_dir'

add "C2R3-N8b. the frozen copy's record is not of the copy root runs" \
    "$FROZENPY" \
    '            with open(dst, "rb") as fh:
                sums[rel] = hashlib.sha256(fh.read()).hexdigest()' \
    '            sums[rel] = "not recorded"  # MUTANT' \
    'test_root_runs_a_frozen_copy_of_its_code_from_the_run_dir'


# --- Cut 2, round 4 -----------------------------------------------------------------------------

add "C2R4-F1a. a stop signal during the teardown is not kept" \
    "$LABROUND" \
    '        if self.teardown_signal is None:
            self.teardown_signal = signum' \
    '        pass  # MUTANT' \
    'test_a_stop_during_a_teardown_ends_the_run_before_b_claims'

add "C2R4-F1b. the last stop signal of a teardown is kept, not the first" \
    "$LABROUND" \
    '        if self.teardown_signal is None:' \
    '        if True:  # MUTANT' \
    'test_a_stop_during_the_teardown_finishes_the_cleanup_and_is_recorded'

add "C2R4-F1c. the round does not record a stop that came during its teardown" \
    "$LABROUND" \
    '            rec["problems"].append("aborted by signal %d (during the teardown)" % self.teardown_signal)' \
    '            pass  # MUTANT' \
    'test_a_stop_during_b_teardown_is_not_complete'

add "C2R4-F1d. a round stopped during its teardown still reads complete" \
    "$LABROUND" \
    '% self.teardown_signal)
            rec["complete"] = False' \
    '% self.teardown_signal)
            pass  # MUTANT' \
    'test_a_stop_during_the_teardown_finishes_the_cleanup_and_is_recorded'

add "C2R4-F2a. a B whose result file cannot be read is not a failed B" \
    "$ROUNDB" \
    '            # a result file that cannot be read -- a B without a result is a failed B
            self.failed = self.failed or self.problems[-1]' \
    '            # a result file that cannot be read -- a B without a result is a failed B
            pass  # MUTANT' \
    'test_b_whose_result_file_is_unreadable_is_a_failed_b'

add "C2R4-F2b. a B whose sniffer never listened gives no reason of its own" \
    "$ROUNDB" \
    '                                 "controller was never told to go" % SRC)
            self.failed = self.failed or self.problems[-1]' \
    '                                 "controller was never told to go" % SRC)
            pass  # MUTANT' \
    'test_b_whose_sniffer_is_not_ready_is_a_failed_b'

add "C2R4-F2c. a controller that could not be started gives no reason of its own" \
    "$ROUNDB" \
    '            self.problems.append("B'"'"'s controller could not be started")
            self.failed = self.problems[-1]' \
    '            self.problems.append("B'"'"'s controller could not be started")  # MUTANT' \
    'test_b_whose_controller_cannot_be_started_is_a_failed_b'

add "C2R4-F2d. a controller that wrote no result gives no reason of its own" \
    "$ROUNDB" \
    '                self.problems.append("B'"'"'s controller wrote no result")
                self.failed = self.problems[-1]' \
    '                self.problems.append("B'"'"'s controller wrote no result")  # MUTANT' \
    'test_b_whose_controller_writes_no_result_is_a_failed_b'

add "C2R4-F2e. a controller that never got ready gives no reason of its own" \
    "$ROUNDB" \
    '            self.problems.append("B'"'"'s controller never wrote its ready file (rc %s)" % proc.poll())
            self.failed = self.problems[-1]' \
    '            self.problems.append("B'"'"'s controller never wrote its ready file (rc %s)" % proc.poll())  # MUTANT' \
    'test_b_whose_controller_never_gets_ready_is_a_failed_b'

add "C2R4-F2f. a fabric that is not external gives no reason of its own" \
    "$ROUNDB" \
    '                                 "not started" % (mode,))
            self.failed = self.problems[-1]' \
    '                                 "not started" % (mode,))  # MUTANT' \
    'test_b_whose_fabric_is_not_external_is_a_failed_b'

add "C2R4-F3a. a recorded stop does not override PROBE-BROKEN" \
    "$VERDICT" \
    '    if stopped:
        return "INCOMPLETE", 2' \
    '    if False:  # MUTANT
        return "INCOMPLETE", 2' \
    'test_a_recorded_stop_overrides_a_probe_broken_cell'

add "C2R4-F3b. the run ignores a stop that no round carries" \
    "$LABPY" \
    '    stopped = any(signalled(r) for r in recs) or bool(run_stopped)' \
    '    stopped = any(signalled(r) for r in recs)  # MUTANT' \
    'test_a_stop_between_the_rounds_overrides_a_probe_broken_cell'

add "C2R4-F3c. the run ignores a stop that a round carries" \
    "$LABPY" \
    '    stopped = any(signalled(r) for r in recs) or bool(run_stopped)' \
    '    stopped = bool(run_stopped)  # MUTANT' \
    'test_a_recorded_stop_overrides_a_probe_broken_cell'

add "C2R4-F3d. a see-red run that was not complete still passes on PROBE-BROKEN" \
    "$VERDICT" \
    '        if see_red and not bringups_complete:
            return "INCOMPLETE", 2' \
    '        if False:  # MUTANT
            return "INCOMPLETE", 2' \
    'test_a_see_red_run_whose_round_did_not_end_clean_is_incomplete'

add "C2R4-F3e. the run does not tell run_verdict that it is a see-red run" \
    "$LABPY" \
    'stopped=stopped, see_red=bool(mutant))' \
    'stopped=stopped, see_red=False)  # MUTANT' \
    'test_a_see_red_run_whose_round_did_not_end_clean_is_incomplete'

add "C2R4-F3f. a see-red pass ignores the run's own problems" \
    "$LABPY" \
    '    complete = bool(recs) and all(r.get("complete") is True for r in recs) and not problems' \
    '    complete = bool(recs) and all(r.get("complete") is True for r in recs)  # MUTANT' \
    'test_a_see_red_run_with_a_problem_of_the_run_is_incomplete'

add "C2R4-F4a. the freeze does not compare a copy with HEAD's blob" \
    "$FROZENPY" \
    '            if h != blob:' \
    '            if False:  # MUTANT' \
    'test_an_edit_between_the_clean_check_and_the_freeze_is_refused_before_s0'

add "C2R4-F4b. two empty answers from git count as equal hashes" \
    "$FROZENPY" \
    '            if h_rc != 0 or b_rc != 0 or not h or not blob:' \
    '            if h_rc != 0 or b_rc != 0:  # MUTANT' \
    'test_a_git_that_cannot_confirm_a_copy_refuses_the_freeze'

add "C2R4-F4c. probe.py freezes without asking git" \
    "$PROBEPY" \
    '        frozen = FZ.freeze(run_dir, repo=REPO, git=_git_run)' \
    '        frozen = FZ.freeze(run_dir, repo=REPO, git=None)  # MUTANT' \
    'test_an_edit_between_the_clean_check_and_the_freeze_is_refused_before_s0'

add "C2R4-F4d. a refused freeze does not stop the run" \
    "$PROBEPY" \
    '        print("refused: %s" % exc, file=sys.stderr)
        return 2
    py = args.py_p4' \
    '        print("refused: %s" % exc, file=sys.stderr)
        frozen = None  # MUTANT
    py = args.py_p4' \
    'test_an_edit_between_the_clean_check_and_the_freeze_is_refused_before_s0'

add "C2R4-F4e. the freeze leaves out B's controller and the adapter" \
    "$FROZENPY" \
    '    for rel in ROOT_FILES + B_FILES:' \
    '    for rel in ROOT_FILES:  # MUTANT' \
    'test_b_runs_its_controller_and_the_adapter_from_the_frozen_copy'

add "C2R4-F4f. B's controller runs from the shared tree" \
    "$LABPY" \
    '    b_kwargs = dict({"hostside": frozen.hostside, "controller": frozen.controller,' \
    '    b_kwargs = dict({"hostside": frozen.hostside,  # MUTANT' \
    'test_b_runs_its_controller_and_the_adapter_from_the_frozen_copy'

add "C2R4-F4g. the adapter runs from the shared tree" \
    "$LABPY" \
    '                     "adapter": frozen.adapter}, **(b_kwargs or {}))' \
    '                     }, **(b_kwargs or {}))  # MUTANT' \
    'test_b_runs_its_controller_and_the_adapter_from_the_frozen_copy'

add "C2R4-F4h. run_lab freezes a second set instead of running the one it is given" \
    "$LABPY" \
    '    frozen = frozen or FZ.freeze(run_dir)' \
    '    frozen = FZ.freeze(run_dir)  # MUTANT' \
    'test_run_lab_runs_the_frozen_code_it_is_given'

add "C2R4-F4i. probe.py does not hand its frozen code to run_lab" \
    "$PROBEPY" \
    '                         frozen=frozen)' \
    '                         )  # MUTANT' \
    'test_the_run_gets_the_frozen_code_that_probe_froze'

add "C2R4-F4j. health.json does not record the hashes of B's files" \
    "$LABPY" \
    '    doc["frozen_code"] = frozen.sums ' \
    '    doc["frozen_code"] = {}  # MUTANT ' \
    'test_b_runs_its_controller_and_the_adapter_from_the_frozen_copy'

add "C2R4-F6. B's controller is registered by the unresolved run dir" \
    "$ROUNDB" \
    '            lab_round.register("controller", proc.pid, os.path.realpath(self.cfg.run_dir))' \
    '            lab_round.register("controller", proc.pid, self.cfg.run_dir)  # MUTANT' \
    'test_b_controller_is_recorded_when_the_run_dir_path_has_a_link'

add "C2R4-F8a. an unreadable bmv2 override is not caught" \
    "$PROBEPY" \
    '    except OSError:
        fabric = None' \
    '    except ZeroDivisionError:  # MUTANT
        fabric = None' \
    'test_an_unreadable_bmv2_override_is_an_incomplete_fingerprint_and_stops_the_run'

add "C2R4-F8b. an unreadable bmv2 override reads as a binary" \
    "$PROBEPY" \
    '        fabric = None                   # unreadable override: the fingerprint says incomplete' \
    '        fabric = "/bin/sh"  # MUTANT' \
    'test_an_unreadable_bmv2_override_is_an_incomplete_fingerprint_and_stops_the_run'

add "C2R4-F9. C2R3-N8b tightened: the record is of the source, not of the copy" \
    "$FROZENPY" \
    '            with open(dst, "rb") as fh:
                sums[rel] = hashlib.sha256(fh.read()).hexdigest()' \
    '            with open(os.path.join(repo, "tools", rel), "rb") as fh:  # MUTANT
                sums[rel] = hashlib.sha256(fh.read()).hexdigest()' \
    'test_the_recorded_hash_is_of_the_copy_not_of_the_source'

# --- round 5 (C2R5-): the second review of the fourth round's fixes ------------------------------------
add "C2R5-2a. probe.py lab answers rc 1 for an S0 that is not complete" \
    "$PROBEPY" \
    '                             mutant=args.mutant, frozen=frozen)
        return rc' \
    '                             mutant=args.mutant, frozen=frozen)
        return 1  # MUTANT' \
    'test_an_s0_with_a_failing_check_is_rc_2_with_a_health_json_and_no_identity_work'

add "C2R5-2b. probe.py lab does the identity work after an S0 that is not complete" \
    "$PROBEPY" \
    '    if s0.out["verdict"] != "COMPLETE":
        # (Cut 2 round 5' \
    '    if False:  # MUTANT
        # (Cut 2 round 5' \
    'test_an_s0_with_a_failing_check_is_rc_2_with_a_health_json_and_no_identity_work'

add "C2R5-2c. run_lab does not say why S0 is not complete" \
    "$LABPY" \
    '        bad = [c.get("name") for c in s0_out.get("checks") or [] if not c.get("ok")]' \
    '        bad = []  # MUTANT' \
    'test_an_incomplete_s0_touches_nothing'

add "C2R5-2d. an exception out of a round (StateInUse) leaves run_lab" \
    "$LABPY" \
    '        except Exception as exc:  # noqa: BLE001 -- (round 5, #2) StateInUse' \
    '        except ZeroDivisionError as exc:  # MUTANT: (round 5, #2) StateInUse' \
    'test_a_leftover_lab_state_is_incomplete_rc_2_and_stays_for_recover'

add "C2R5-2e. a run that ended on an exception reads PROBE-BROKEN when a cell is" \
    "$LABPY" \
    '    stopped = any(signalled(r) for r in recs) or bool(run_stopped) or ended_early' \
    '    stopped = any(signalled(r) for r in recs) or bool(run_stopped)  # MUTANT' \
    'test_a_round_that_cannot_be_built_ends_the_run_incomplete_with_the_earlier_rounds_kept'

add "C2R5-2f. a load_model failure leaves run_lab" \
    "$LABPY" \
    '        except Exception as exc:  # noqa: BLE001 -- a run that cannot be set up' \
    '        except ZeroDivisionError as exc:  # MUTANT: a run that cannot be set up' \
    'test_a_load_model_failure_is_incomplete_rc_2'

add "C2R5-2g. an expectations failure leaves run_lab" \
    "$LABPY" \
    '            pipelines, runtimes, orders = expectations(s0_out, run_dir, model)
            prepared = (model, pipelines, runtimes, orders)
        except Exception' \
    '            pipelines, runtimes, orders = (None, None, None)  # MUTANT: expectations not asked for
            prepared = (model, pipelines, runtimes, orders)
        except Exception' \
    'test_an_expectations_failure_is_incomplete_rc_2'

add "C2R5-2h. probe.py lab lets an exception out as Python's status 1" \
    "$PROBEPY" \
    '        except Exception:  # noqa: BLE001
            # (Cut 2 round 5, #2) Python' \
    '        except ZeroDivisionError:  # noqa: BLE001  MUTANT
            # (Cut 2 round 5, #2) Python' \
    'test_an_exception_out_of_the_lab_path_is_rc_2_not_pythons_status_1'

add "C2R5-3a. a see-red run in which no cell is PROBE-BROKEN reads COMPLETE" \
    "$VERDICT" \
    '    if see_red:
        # (round 5, #3)' \
    '    if False:  # MUTANT
        # (round 5, #3)' \
    'test_a_see_red_run_whose_mutant_is_not_caught_is_not_a_pass'

add "C2R5-3b. a see-red run that sees no red exits 0" \
    "$VERDICT" \
    '        return "SEE-RED-NOT-SEEN", 2' \
    '        return "SEE-RED-NOT-SEEN", 0  # MUTANT' \
    'test_a_see_red_run_that_sees_no_red_is_not_a_pass'

add "C2R5-3c. an unfinished see-red run reads SEE-RED-NOT-SEEN instead of INCOMPLETE" \
    "$VERDICT" \
    '    if not bringups_complete:
        return "INCOMPLETE", 2
    if see_red:' \
    '    if see_red:
        return "SEE-RED-NOT-SEEN", 2  # MUTANT
    if not bringups_complete:
        return "INCOMPLETE", 2
    if see_red:' \
    'test_a_see_red_run_that_sees_no_red_is_not_a_pass'

add "C2R5-4a. a B that confirmed nothing but register is not a failed B" \
    "$ROUNDB" \
    '        if not [k for k, v in (confirmed or {}).items() if v.get("ok") and k != "register"]:' \
    '        if False:  # MUTANT' \
    'test_b_whose_controller_reached_no_switch_is_a_failed_b'

add "C2R5-4b. register counts as an attribution B confirmed" \
    "$ROUNDB" \
    'if v.get("ok") and k != "register"]:' \
    'if v.get("ok")]:  # MUTANT' \
    'test_b_that_confirmed_only_register_is_a_failed_b'

add "C2R5-4c. a B that is not primary on s2 is not a failed B" \
    "$ROUNDB" \
    '        if s2 and "connect_error" not in s2 and s2.get("primary") is not True:' \
    '        if False:  # MUTANT' \
    'test_b_whose_controller_is_not_primary_on_s2_is_a_failed_b'

add "C2R5-4d. run_lab-level: finish() does not ask whether B did its part" \
    "$ROUNDB" \
    '            for why in self.did_nothing(result, self.confirmed):' \
    '            for why in []:  # MUTANT' \
    'test_b_whose_controller_reached_no_switch_is_a_failed_b'

add "C2R5-7a. the blobs are asked for by HEAD at that moment, not by the pinned sha" \
    "$FROZENPY" \
    '            b_rc, blob = git("rev-parse", "%s:tools/%s" % (head, rel))' \
    '            b_rc, blob = git("rev-parse", "HEAD:tools/%s" % rel)  # MUTANT' \
    'test_a_commit_that_lands_mid_freeze_cannot_give_a_set_that_matches_no_commit'

add "C2R5-7b. the Frozen does not carry the sha it was checked against" \
    "$FROZENPY" \
    '    return Frozen(base, sums, head)' \
    '    return Frozen(base, sums)  # MUTANT' \
    'test_head_is_resolved_once_and_every_blob_is_asked_for_by_that_sha'

add "C2R5-7c. probe.py writes the identity of HEAD as it is now, not of the frozen commit" \
    "$PROBEPY" \
    '    ident = repo_identity(head=frozen.head)' \
    '    ident = repo_identity()  # MUTANT' \
    'test_probe_lab_records_the_frozen_head_in_the_identity_and_in_health_json'

add "C2R5-7d. repo_identity ignores the sha it is given" \
    "$PROBEPY" \
    '    return {"head": head or _git("rev-parse", "HEAD") or "unknown", "probe_tree": probe_version(head),' \
    '    return {"head": _git("rev-parse", "HEAD") or "unknown", "probe_tree": probe_version(head),  # MUTANT' \
    'test_the_identity_of_a_run_names_the_head_the_freeze_pinned'

add "C2R5-7e. health.json does not record the commit the copies were checked against" \
    "$LABPY" \
    '    doc["frozen_head"] = frozen.head ' \
    '    doc["frozen_head"] = None  # MUTANT ' \
    'test_probe_lab_records_the_frozen_head_in_the_identity_and_in_health_json'

add "C2R5-8. the copy is hashed through git's input filters" \
    "$FROZENPY" \
    '            h_rc, h = git("hash-object", "--no-filters", dst)' \
    '            h_rc, h = git("hash-object", dst)  # MUTANT' \
    'test_a_copy_is_hashed_as_its_bytes_not_as_a_filter_would_see_them'

add "C2R5-9a. an existing <run>/frozen is overwritten" \
    "$FROZENPY" \
    '    if os.path.lexists(base):' \
    '    if False:  # MUTANT' \
    'test_a_frozen_directory_that_is_already_there_is_refused_and_left_alone'

add "C2R5-9b. a copy is written through a link planted at its destination" \
    "$FROZENPY" \
    '    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)' \
    '    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)  # MUTANT' \
    'test_a_symlink_planted_at_a_destination_is_not_written_through'

add "C2R5-9c. a link planted for a subdirectory is followed" \
    "$FROZENPY" \
    '                os.mkdir(sub)' \
    '                os.makedirs(sub, exist_ok=True)  # MUTANT' \
    'test_a_symlink_planted_for_a_subdirectory_is_not_followed'

CTRLTRIAL="$PKG/ctrl_trial.py"
add "C2R5-5a. probe.py lab does not load the lab path's modules up front" \
    "$PROBEPY" \
    '    load_lab_path()
    from p4_health import lab as L' \
    '    from p4_health import lab as L  # MUTANT' \
    'test_an_edit_to_identity_during_s0_cannot_reach_the_probe_process'

add "C2R5-5b. identity.py is left out of the modules loaded up front" \
    "$PROBEPY" \
    '"p4_health.frames", "p4_health.frozen", "p4_health.identity", "p4_health.lab",' \
    '"p4_health.frames", "p4_health.frozen", "p4_health.lab",  # MUTANT' \
    'test_an_edit_to_identity_during_s0_cannot_reach_the_probe_process'

add "C2R5-5c. probe.py lab does not hand its frozen copies to S0" \
    "$PROBEPY" \
    '    s0 = S0(run_dir, runner, py, frozen=frozen)' \
    '    s0 = S0(run_dir, runner, py)  # MUTANT' \
    'test_probe_lab_hands_its_frozen_code_to_s0'

add "C2R5-5d. S0's adapter dry-run runs the shared tree's adapter" \
    "$S0PY" \
    '        adapter, controller = (fz.adapter, fz.controller) if fz else (RB.ADAPTER, RB.CONTROLLER)' \
    '        adapter, controller = (RB.ADAPTER, RB.CONTROLLER)  # MUTANT' \
    'test_the_adapter_dry_run_runs_the_frozen_adapter_with_the_frozen_controller'

add "C2R5-5e. S0's controller trial runs the shared tree's controller" \
    "$S0PY" \
    '            ctrl = {"controller": self.frozen.controller} if self.frozen else {}' \
    '            ctrl = {}  # MUTANT' \
    'test_the_controller_trial_runs_the_frozen_controller'

add "C2R5-5f. the controller trial ignores the controller it is given" \
    "$CTRLTRIAL" \
    'controller or os.path.join(HERE, "controller_ext.py")], env=env,' \
    'os.path.join(HERE, "controller_ext.py")], env=env,  # MUTANT' \
    'test_the_controller_trial_starts_the_controller_it_is_given'

add "C2R5-5g. the dry-run check accepts a controller that is not the one it was handed" \
    "$S0PY" \
    '        ok = (res.rc == 0 and ("controller: %s" % controller) in out' \
    '        ok = (res.rc == 0 and ("controller: %s" % RB.CONTROLLER) in out  # MUTANT' \
    'test_the_adapter_dry_run_runs_the_frozen_adapter_with_the_frozen_controller'

add "C2R5-10a. the body's stop handler does not put the teardown's handler in before it raises" \
    "$LABROUND" \
    '                self._swap_handlers({s: self._noter for s in self.SIGS})
                raise SignalAbort(signum)' \
    '                raise SignalAbort(signum)  # MUTANT' \
    'test_a_second_stop_before_the_teardown_handler_is_in_place_does_not_skip_the_teardown'

add "C2R5-10b. the record is finished after the run-level handlers are back" \
    "$LABROUND" \
    '                self._finish(rec, t0)
                self._restore_handlers()' \
    '                self._restore_handlers()
                self._finish(rec, t0)  # MUTANT' \
    'test_a_stop_just_after_a_rounds_handlers_are_restored_keeps_that_rounds_record'

add "C2R5-10c. a stop between a round and its record being appended loses the record" \
    "$LABPY" \
    '        except SignalAbort as exc:
            take_unrecorded(cfg, holder, recs)' \
    '        except SignalAbort as exc:
            pass  # MUTANT' \
    'test_a_stop_just_after_a_rounds_handlers_are_restored_keeps_that_rounds_record'

add "C2R5-10d. an exception between a round and its record being appended loses the record" \
    "$LABPY" \
    '        except Exception as exc:  # noqa: BLE001 -- (round 5, #2) StateInUse, a package outside the run dir, ...
            take_unrecorded(cfg, holder, recs)' \
    '        except Exception as exc:  # noqa: BLE001 -- (round 5, #2) StateInUse, a package outside the run dir, ...
            pass  # MUTANT' \
    'test_an_exception_after_a_rounds_record_is_final_keeps_that_rounds_record'

add "C2R5-13. a knob that was not put back does not make the round incomplete" \
    "$LABROUND" \
    '                or rec["knobs_restored"] is not True):' \
    '                ):  # MUTANT' \
    'test_a_knob_that_does_not_go_back_makes_the_round_incomplete_even_when_the_release_succeeds'

add "C2R5-11a. the offline judge ignores a stop" \
    "$PROBEPY" \
    '                                stopped=stopped, see_red=see_red)' \
    '                                see_red=see_red)  # MUTANT' \
    'test_a_stopped_recording_reads_incomplete_offline'

add "C2R5-11b. the offline judge ignores a see-red recording" \
    "$PROBEPY" \
    '                                stopped=stopped, see_red=see_red)' \
    '                                stopped=stopped)  # MUTANT' \
    'test_a_see_red_recording_that_sees_no_red_reads_so_offline'

add "C2R5-11c. the offline judge does not read the recording's stopped flag" \
    "$PROBEPY" \
    '    stopped = (doc.get("stopped") is True or any(signalled(b) for b in doc.get("bringups") or [])' \
    '    stopped = (any(signalled(b) for b in doc.get("bringups") or [])  # MUTANT' \
    'test_a_stopped_recording_reads_incomplete_offline'

add "C2R5-11d. the offline judge does not read a stop recorded as a problem of the run" \
    "$PROBEPY" \
    '               or any(str(p).startswith("stop signal") for p in doc.get("problems") or []))' \
    '               or False)  # MUTANT' \
    'test_a_stopped_recording_reads_incomplete_offline'

add "C2R5-11e. observations.json does not say whether the run was stopped" \
    "$LABPY" \
    '"bringups_complete": complete, "stopped": stopped, "see_red": bool(mutant),' \
    '"bringups_complete": complete, "stopped": False, "see_red": bool(mutant),  # MUTANT' \
    'test_the_observations_a_run_writes_carry_what_the_offline_judge_reads'

add "C2R5-11f. observations.json does not carry the rounds' records" \
    "$LABPY" \
    '                   "bringups": recs, "problems": problems}, fh,' \
    '                   "bringups": [], "problems": problems}, fh,  # MUTANT' \
    'test_the_observations_a_run_writes_carry_what_the_offline_judge_reads'

add "C2R5-12. the frozen set leaves out the adapter's common.py" \
    "$FROZENPY" \
    '"p4_exercise/run_external_controller.py", "p4_exercise/common.py", "p4_exercise/__init__.py")' \
    '"p4_exercise/run_external_controller.py", "p4_exercise/__init__.py")  # MUTANT' \
    'test_the_frozen_adapter_and_controller_launched_as_b_launches_them_load_nothing_from_the_shared_tree'

# --- #6: the gate script and the shard-sum script, mutated as copies and tested by test_p4_health_gate_scripts.sh
# (its check names, in brackets, are what must go red). The banner printed at the END of a real shard log is
# not reached by any check that does not run a whole shard: it is the banner at the top, and the synthetic logs
# the shard-sum tests read, that are pinned.
add "C2R5-6a. the gate script lets k reach n" \
    "$GATEPY" \
    '    (( SHARD_K ''< SHARD_N )) || refuse_config' \
    '    (( 1 )) || refuse_config  # MUTANT' \
    '[MUT_SHARD with k equal to n is refused]'

add "C2R5-6b. the gate script lets n exceed the table" \
    "$GATEPY" \
    '    (( SHARD_N ''<= ${#MUT_LABEL[@]} )) \' \
    '    (( 1 )) \' \
    '[MUT_SHARD with n just above the table size is refused too]'

add "C2R5-6c. the gate script runs when no mutation is selected" \
    "$GATEPY" \
    '(( SELECTED ''> 0 )) \' \
    '(( 1 )) \' \
    '[an ONLY_LABEL_PREFIX that matches nothing is refused (no mutation is selected)]'

add "C2R5-6d. the gate script takes a shard with a leading zero" \
    "$GATEPY" \
    '=~ ^(0|[1-9]''[0-9]*)/([1-9][0-9]*)$ ]]' \
    '=~ ^([0-9]+)/([1-9][0-9]*)$ ]]' \
    '[MUT_SHARD with a leading zero is refused]'

add "C2R5-6e. the gate script does not say a shard is not the gate" \
    "$GATEPY" \
    'NOT THE GATE BY ITSELF: shard %s/''%s (%s of %s mutations;' \
    'a shard: %s/%s (%s of %s mutations;' \
    '[a shard log opens with NOT THE GATE BY ITSELF: shard k/n]'

add "C2R5-6f. the gate script announces a banner for the whole gate" \
    "$GATEPY" \
    'if [[ -n "$SHARD_N" '']]; then
    printf ' \
    'if true; then
    printf ' \
    '[the whole gate does not]'

add "C2R5-6g. the shard-sum script takes shards of different commits" \
    "$SUMPY" \
    '        if len({f[key] for f in facts}) != 1:' \
    '        if False:  # MUTANT' \
    '[a shard of another commit (first line and HEAD line)]'

add "C2R5-6h. the shard-sum script lets n exceed the table" \
    "$SUMPY" \
    '        if n > labels:' \
    '        if False:  # MUTANT' \
    '[n larger than the table (two shards would have run nothing)]'

add "C2R5-6i. the shard-sum script does not compare the first line with the HEAD line" \
    "$SUMPY" \
    '    elif first and first.group(1) != head[0]:' \
    '    elif False:  # MUTANT' \
    '[a shard whose first line is not the commit HEAD says]'

add "C2R5-6j. the shard-sum script accepts uncommitted changes" \
    "$SUMPY" \
    '    elif tree[1].strip():' \
    '    elif False:  # MUTANT' \
    '[a shard of a tree with uncommitted changes]'

add "C2R5-6k. the shard-sum script does not look at the rc line" \
    "$SUMPY" \
    '    if last != "rc=0":' \
    '    if False:  # MUTANT' \
    '[a shard that ended rc=1]'

add "C2R5-6l. the shard-sum script accepts a survivor" \
    "$SUMPY" \
    '    if m_s is not None and int(m_s[1]) != 0:' \
    '    if False:  # MUTANT' \
    '[a shard that survived a mutation, even with rc 0 written]'

add "C2R5-6m. the shard-sum script accepts a partial run" \
    "$SUMPY" \
    '    if "PARTIAL RUN" in "\n".join(lines):' \
    '    if False:  # MUTANT' \
    '[a partial run]'

add "C2R5-6n. the shard-sum script does not look for the banner" \
    "$SUMPY" \
    '    elif not (len([l for l in lines if l ==' \
    '    elif False and not (len([l for l in lines if l ==' \
    '[a shard without the not-the-gate banner (not a log of this script)]'

add "C2R5-6o. the shard-sum script does not look at the baseline" \
    "$SUMPY" \
    '    if len(bi) != 1 or lines[bi[0] + 1:bi[0] + 2] != ["  ok       baseline green"]:' \
    '    if False:' \
    '[a shard whose baseline is not green]'

add "C2R5-6p. the shard-sum script does not look at the negative control" \
    "$SUMPY" \
    '    if text.count("  ✅ green: the suites do not react to a comment") != 1:' \
    '    if False:  # MUTANT' \
    '[a shard whose negative control is not green]'

add "C2R5-6q. the shard-sum script does not look at the byte-identical line" \
    "$SUMPY" \
    '    if len(re.findall(r"^  byte-identical  tools/p4_health  ", text, re.M)) != 1:' \
    '    if False:  # MUTANT' \
    '[a shard that does not say the original is byte-identical]'

add "C2R5-6r. the shard-sum script does not look at the after-check" \
    "$SUMPY" \
    '    if text.count("  suites green against the real files") != 1:' \
    '    if False:  # MUTANT' \
    '[a shard whose after-check is not green]'

add "C2R5-6s. the shard-sum script lets a shard be given twice" \
    "$SUMPY" \
    '        if k in shards:' \
    '        if False:  # MUTANT' \
    '[the same shard twice in place of another]'

add "C2R5-6t. the shard-sum script does not check that the shards are 0..n-1" \
    "$SUMPY" \
    '        if sorted(shards) != list(range(n)):' \
    '        if False:  # MUTANT' \
    '[three shards of four]'

add "C2R5-6u. the shard-sum script does not check each shard's share" \
    "$SUMPY" \
    '            if f["m"] != share:' \
    '            if False:  # MUTANT' \
    '[a shard that ran more mutations than its share (the counts no longer add up)]'

add "C2R5-6v. the shard-sum script lets n differ between the logs" \
    "$SUMPY" \
    '    if len(ns) != 1:' \
    '    if False:  # MUTANT' \
    '[shards of different n]'

add "C2R5-6w. the shard-sum script lets the size of the table differ" \
    "$SUMPY" \
    '    if len(ls) != 1:' \
    '    if False:  # MUTANT' \
    '[shards that disagree on the size of the table]'

add "C2R5-6x. the shard-sum script takes no logs" \
    "$SUMPY" \
    'if not logs:' \
    'if False:' \
    '[no logs at all is refused, with a reason]'

add "C2R5-6y. the shard-sum script takes a refused run's log" \
    "$SUMPY" \
    '        if "REFUSED" in l or "\U0001f534" in l:' \
    '        if False:  # MUTANT' \
    '[a log of a refused run]'

add "C2R5-6z. the shard-sum script prints another line when all is well" \
    "$SUMPY" \
    'print("GATE: %d mutations, %d survived, shards %d/%d ok"' \
    'print("GATE ok: %d mutations, %d survived, shards %d/%d"' \
    '[four good shards of ten: the one GATE line, rc 0]'


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

# --- refusing what cannot be the gate, or a shard of it, BEFORE the baseline (round 5, #6) -------------

# MUT_SHARD=k/n  runs only the mutations whose position in the table is k modulo n (k from 0): n shards
# started side by side, with the same head, cover the table once between them. Each shard runs its own
# baseline and negative control. A shard is never the gate by itself: the gate is the sum of all n, and
# tests/shell/sum_p4_health_gate_shards.sh adds them up (one commit, tree and subject sha; every
# baseline, control and after-check green; every rc 0; the counts adding up to the table).
# ONLY_LABEL_PREFIX=C2R5-  runs only the mutations whose label starts so: a PARTIAL run, never the gate.
refuse_config() { echo "REFUSED: $1"; exit 2; }
SHARD_K=""; SHARD_N=""
if [[ -n "${MUT_SHARD:-}" ]]; then
    [[ "$MUT_SHARD" =~ ^(0|[1-9][0-9]*)/([1-9][0-9]*)$ ]] \
        || refuse_config "MUT_SHARD=$MUT_SHARD is not k/n (whole numbers, n >= 1, no leading zeros)"
    SHARD_K="${BASH_REMATCH[1]}"; SHARD_N="${BASH_REMATCH[2]}"
    (( SHARD_K < SHARD_N )) || refuse_config "MUT_SHARD=$MUT_SHARD: k must be below n (shards are numbered from 0)"
    (( SHARD_N <= ${#MUT_LABEL[@]} )) \
        || refuse_config "MUT_SHARD=$MUT_SHARD: n is larger than the ${#MUT_LABEL[@]} mutations in the table, so a shard would run nothing"
fi
selected() {    # selected <index>: is mutation <index> in this run?
    if [[ -n "${ONLY_LABEL_PREFIX:-}" && "${MUT_LABEL[$1]}" != "$ONLY_LABEL_PREFIX"* ]]; then return 1; fi
    if [[ -n "$SHARD_N" ]] && (( $1 % SHARD_N != SHARD_K )); then return 1; fi
    return 0
}
SELECTED=0
for i in "${!MUT_LABEL[@]}"; do selected "$i" && SELECTED=$((SELECTED + 1)); done
(( SELECTED > 0 )) \
    || refuse_config "no mutation is selected (MUT_SHARD=${MUT_SHARD:-}, ONLY_LABEL_PREFIX=${ONLY_LABEL_PREFIX:-}): a run of none is not a result"
if [[ -n "$SHARD_N" ]]; then
    printf 'NOT THE GATE BY ITSELF: shard %s/%s (%s of %s mutations; the gate is the sum of all %s shards)\n\n' \
        "$SHARD_K" "$SHARD_N" "$SELECTED" "${#MUT_LABEL[@]}" "$SHARD_N"
fi
[[ -n "${ONLY_LABEL_PREFIX:-}" ]] && printf 'NOT THE GATE: only labels starting %s (%s mutations)\n\n' "$ONLY_LABEL_PREFIX" "$SELECTED"

# --- running --------------------------------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4-health-mutate-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SURVIVORS=0; MUTATIONS=0
BASE_SUM="$(cd "$PKG" && find . -type f \( -name '*.py' -o -name '*.sh' -o -name '*.p4' \) | sort | xargs sha256sum | sha256sum)"
GATES_SUM="$(sha256sum "$GATEPY" "$SUMPY" "$GATE_TEST" | sha256sum)"

fresh_copy() {
    rm -rf "$WORK/tools"; mkdir -p "$WORK/tools"
    cp -r "$PKG" "$WORK/tools/p4_health"
    # the one repo file the package reads by its own path (throwaway.py's lab port list)
    mkdir -p "$WORK/p4_proxy/mininet" && cp "$REPO/p4_proxy/mininet/grpc_ports.py" "$WORK/p4_proxy/mininet/"
    # (round 4, F4) the three p4_exercise files a lab run freezes next to its own (frozen.py)
    mkdir -p "$WORK/tools/p4_exercise" && cp "$REPO/tools/p4_exercise/"{__init__,common,run_external_controller}.py "$WORK/tools/p4_exercise/"
    find "$WORK/tools" -name __pycache__ -prune -exec rm -rf {} +
}

# red_tests [package root] [recover.sh] [dir of the gate scripts] -- names of the tests that went red, space-separated;
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
    # (round 5, #6) the gate's own refusals and the shard-sum script, run against the scripts in "$3"
    out=$(P4_HEALTH_GATE_UNDER_TEST="${3:-$HERE}" timeout 300 bash "$GATE_TEST" 2>&1); rc=$?
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
    local target="$WORK/tools/p4_health/${src#"$PKG"/}" gates=""
    if [[ "$src" == "$HERE/"* ]]; then
        # (round 5, #6) a mutation of one of the gate's own scripts: all three are copied, the one is mutated,
        # and the suite that tests them is pointed at the copies
        gates="$WORK/tests/shell"; mkdir -p "$gates"
        cp "$GATEPY" "$SUMPY" "$GATE_TEST" "$gates/"
        target="$gates/$(basename "$src")"
    fi
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
    if [[ -n "$gates" ]]; then failed=$(red_tests "$REPO/tools" "$RECOVER" "$gates")
    elif [[ "$target" == *.sh ]]; then failed=$(red_tests "$REPO/tools" "$target")
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
    selected "$i" || continue
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
if [[ "$(sha256sum "$GATEPY" "$SUMPY" "$GATE_TEST" | sha256sum)" != "$GATES_SUM" ]]; then
    echo "  🔴 THE GATE'S OWN SCRIPTS CHANGED DURING THE GATE"; exit 2; fi
echo "  byte-identical  the gate's own scripts  ${GATES_SUM:0:16}"
after_red=$(red_tests)
[[ -n "$after_red" ]] && { echo "🔴 a suite is red against the real files: $after_red"; exit 2; }
echo "  suites green against the real files"

(( MUTATIONS == SELECTED )) || { echo "REFUSED: $MUTATIONS mutations ran, $SELECTED were selected"; exit 2; }
printf '\n%s mutations, %s survived\n' "$MUTATIONS" "$SURVIVORS"
[[ -n "$SHARD_N" ]] && printf 'SHARD %s/%s of %s mutations in the table\nNOT THE GATE BY ITSELF: shard %s/%s\n' \
    "$SHARD_K" "$SHARD_N" "${#MUT_LABEL[@]}" "$SHARD_K" "$SHARD_N"
[[ -n "${ONLY_LABEL_PREFIX:-}" ]] && printf 'PARTIAL RUN: only labels starting %s -- this is not the gate\n' "$ONLY_LABEL_PREFIX"
[[ "$SURVIVORS" -eq 0 ]]
