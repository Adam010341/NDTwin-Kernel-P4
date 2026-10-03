#!/usr/bin/env bash
#
# Mutation gate for tools/p4_health and its offline suites (DESIGN 5.2-③: M1-M18, plus the
# section 12 refinements, the Q3(b) cells, the seal of the reading-layer test, and recover.sh).
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
CELLS_TEST="$REPO/tests/python/test_p4_health_cells.py"
COLLECT_TEST="$REPO/tests/python/test_p4_health_collect.py"
RECOVER_TEST="$REPO/tests/shell/test_p4_health_recover.sh"

printf 'gate       : %s\n' "${BASH_SOURCE[0]}"
printf 'cwd        : %s\n' "$PWD"
printf 'interpreter: %s (%s)\n' "$(realpath "$PYTHON" 2>/dev/null || echo "MISSING: $PYTHON")" \
    "$("$PYTHON" -c 'import sys; print(sys.version.split()[0])' 2>/dev/null)"
printf 'subject    : %s\n' "$PKG"
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

# M1-M18: DESIGN 5.2-③, in its order.
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
    '            if et == ethertype and str(row.get("src_mac", "")).lower() == src \
                    and str(row.get("dst_mac", "")).lower() == dst:' \
    '            if et == ethertype:  # MUTANT: the ethertype alone' \
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
    '        exp = verdict.label  # MUTANT: the prediction is this run'"'"'s verdict' \
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
    '        for iface in self.state["netem"]:' \
    '        for iface in []:  # MUTANT: netem left on' \
    'test_the_round_in_order'

add "M17b. the finally skips the sniffers" \
    "$LABROUND" \
    '        for pid in self.state["sniffers"]:' \
    '        for pid in []:  # MUTANT: sniffers left running' \
    'test_the_round_in_order'

add "M18. a failed self-check is RED" \
    "$VERDICT" \
    '    return Verdict(PROBE_BROKEN, why, phase="compare")' \
    '    return Verdict(RED, why, phase="compare")  # MUTANT' \
    'test_a_self_check_is_never_red'

# Section 12, the Cut-1 refinements that are decisions in code.
add "12-1. SC-count accepts a delta equal to sent with loss at the receiver" \
    "$TABLE" \
    '    if not sent or got != sent:' \
    '    if not sent:  # MUTANT: loss on the path ignored' \
    'test_sc_count_without_netdev_needs_zero_loss'

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

add "12-4. SC-ttl's hop count stops at the first switch" \
    "$TABLE" \
    '        nxt = links.get((dpid, port))' \
    '        nxt = None  # MUTANT: the first hop is the last' \
    'test_sc_ttl_counts_hops_from_the_lpm_path_not_the_topology'

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

# Rule D, the negative reads, the expected refusals, the reader's read-only rule.
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

add "D4. CP2's 409 is judged a RED" \
    "$TABLE" \
    '    if a.get("http") != 409:' \
    '    if a.get("http") == 409:  # MUTANT: the refusal is a failure' \
    'test_cp2s_409_is_the_pass_and_not_a_red_candidate'

add "D5. a known-answer control that misses is not PROBE-BROKEN" \
    "$TABLE" \
    '        if http == self.expect_http:' \
    '        if http is not None:  # MUTANT: any answer passes' \
    'test_k1_neg_and_t3_neg_404_pass'

add "D6. the thrift reader lets a write through" \
    "$THRIFT" \
    '    if word not in READ_COMMANDS or any(w in word for w in ("_add", "_delete", "_set", "_write")):' \
    '    if False:  # MUTANT: writes allowed' \
    'test_the_reader_runs_read_only_commands_on_the_switchs_port_through_the_runner'

add "D7. a reply with no CLI prompt ('could not connect') is parsed as one" \
    "$THRIFT" \
    '    if "RuntimeCmd: " not in out:' \
    '    if False:  # MUTANT' \
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

# Q3(b): the decision code of the cells added in Cut 1.
add "Q3b-1. HR1 never compares the twin with netdev" \
    "$TABLE" \
    '        wrong = sorted(l for l in ("s1-eth4", "s1-eth5") if bool(carried.get(l)) != bool(seen.get(l)))' \
    '        wrong = []  # MUTANT' \
    'test_red_fixtures_are_red_or_partial'

add "Q3b-2. HR2 runs when the coin used one uplink" \
    "$TABLE" \
    '    if all(carried.get(l) for l in ("s1-eth4", "s1-eth5")):' \
    '    if True:  # MUTANT' \
    'test_hr2_needs_both_uplinks_carrying'

add "Q3b-3. RC1 accepts doubled bytes" \
    "$TABLE" \
    '        return red("link usage is not netdev'"'"'s bytes: the twin counted a recirculated or "' \
    '        return green("MUTANT"); red("link usage is not netdev'"'"'s bytes: the twin counted a recirculated or "' \
    'test_red_fixtures_are_red_or_partial'

add "Q3b-4. HU1 looks for the wrong ethertype" \
    "$TABLE" \
    '"HU1": 0x86DD' \
    '"HU1": 0x0800' \
    'test_red_fixtures_are_red_or_partial'

add "Q3b-5. IT1's structural answer is not read" \
    "$TABLE" \
    '    if a.get("idle_field") is False or a.get("notification_exit") is False:' \
    '    if False:  # MUTANT' \
    'test_it1_today_is_a_structural_cannot'

add "Q3b-6. VB1 is judged instead of NOT RUN by design" \
    "$VERDICT" \
    '    if spec.by_design is not None:' \
    '    if False:  # MUTANT' \
    'test_vb1_is_not_run_by_design'

add "Q3b-7. SC-recirc accepts a packet that was not resubmitted" \
    "$TABLE" \
    '    bad = [f for f in flags if f & 0x0C != 0x0C]' \
    '    bad = []  # MUTANT' \
    'test_sc_recirc_and_sc_union'

add "Q3b-8. SC-union accepts any hop limit" \
    "$TABLE" \
    '    if any(h != want for h in lims):' \
    '    if False:  # MUTANT' \
    'test_sc_recirc_and_sc_union'

# The seal of the reading-layer test: two deliberately non-hermetic changes must go red there.
add "H1. a collector runs a real subprocess instead of the injected Runner" \
    "$OBSERVE" \
    '    reader = TH.ThriftReader(cfg, runner)
    full = name if "." in name else "HcIngress." + name' \
    '    from .collect.runner import Runner
    reader = TH.ThriftReader(cfg, Runner())  # MUTANT: a real runner
    full = name if "." in name else "HcIngress." + name' \
    'test_the_oracle_is_thrifts_and_never_the_proxys'

add "H2. a collector dials the proxy instead of using the Config's client" \
    "$PROXY" \
    '    reply = cfg.proxy.get("/p4/counter/%s?dpid=%d&index=%d" % (name, int(dpid), int(index)))' \
    '    from .config import HttpClient
    reply = HttpClient("http://localhost:8081").get("/p4/counter/%s?dpid=%d&index=%d" % (name, int(dpid), int(index)))  # MUTANT' \
    'test_the_counter_endpoints_three_answers'

# recover.sh: its offline test must see these red.
add "R1. recover.sh does not check that the lab is this run's" \
    "$RECOVER" \
    'if [[ "$c_owner" == "$OWNER" && "$c_note" == *"p4-health $RUNID $BRINGUP"* && "${c_exp:-0}" -gt "$now" \' \
    'if true || [[ "$c_owner" == "$OWNER" && "$c_note" == *"p4-health $RUNID $BRINGUP"* && "${c_exp:-0}" -gt "$now" \' \
    'nothing was run'

add "R2. recover.sh releases after a failed down" \
    "$RECOVER" \
    'if ! NDT_OWNER="$OWNER" "$NDT" down; then' \
    'if ! NDT_OWNER="$OWNER" "$NDT" down && false; then' \
    'no release'

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
    echo "$names" | xargs
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
