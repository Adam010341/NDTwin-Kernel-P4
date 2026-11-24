#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_ndtwin_sdk_link.py (`k.link_down`, `k.restore_link`:
# sdk/python/ndtwin/link.py, kernel.py and the `down_reason` of topology.py).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one way the SDK can tell an app something the kernel did not say about a
# cut link: a link said to be cut on the wire that is not (or the reverse), a netem left on one end
# taken for a clean cut, a recovery said to have restored a link it did not clear, a refusal read
# as "may be cut" or an unknown outcome read as "nothing changed", a block whose exception or
# Ctrl-C skips the recovery or loses the exception, a POST sent twice, a link the kernel would
# address wrongly sent anyway, a reply the SDK cannot read taken as an answer. Each must turn its
# NAMED test red; a mutation caught by some other test says nothing about the test that was
# supposed to own it. No two mutations are the same edit.
#
# 🔴 Mutations are applied to COPIES of sdk/python/ndtwin in a temp dir, and the suite is pointed
#    at a copy with NDTWIN_SDK_UNDER_TEST; no source file is written, and the sha256 of every SDK
#    file is compared at the end. The suite runs with PYTHONDONTWRITEBYTECODE=1, so nothing is
#    written under the worktree either.
# 🔴 Each mutated copy must compile (`python -m py_compile`) and `import ndtwin` before it is
#    scored: one that does not is NOT APPLIED, never caught. A mutation that will not apply, a
#    non-unique anchor, or the wrong test going red fails the gate. A comment-only edit is the
#    control and must stay green.
# 🔴 Touches no lab and no network beyond 127.0.0.1: the suite's kernel is an in-process fake.
#
# Env:  PYTHON=<interpreter>       the suite's interpreter (default python3)
#       MUTANT_EVIDENCE=<dir>      keeps each mutant as <label>.patch and the suite's output as <label>.log
# Exit: 0 every mutation caught and the control stayed green, 1 a mutation survived or was not
#       applied (or the control went red), 2 refused (baseline red / harness), 3 the SDK changed
#       while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SDK="$REPO/sdk/python/ndtwin"
LINK="$REPO/sdk/python/ndtwin/link.py"
KERNEL="$REPO/sdk/python/ndtwin/kernel.py"
TOPO="$REPO/sdk/python/ndtwin/topology.py"
SUITE="$REPO/tests/python/test_ndtwin_sdk_link.py"
PY="${PYTHON:-python3}"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndtwin-sdk-link-mutate-XXXXXX")
trap 'rm -rf "${BK:?}"' EXIT

command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
for f in "$LINK" "$KERNEL" "$TOPO" "$SUITE"; do
    [[ -f "$f" ]] || { echo "🔴 missing $f" >&2; exit 2; }
done
sdk_sums() { (cd "$SDK" && sha256sum ./*.py); }
BASE_SUMS=$(sdk_sums)

CAUGHT=0
SURVIVED=0
NOT_APPLIED=0
CONTROL_RED=0

run_suite() {   # <copy dir> -- the suite against that copy's SDK
    (cd "$REPO" && NDTWIN_SDK_UNDER_TEST="$1/sdk/python" PYTHONDONTWRITEBYTECODE=1 \
        timeout 300 "$PY" "$SUITE" -v 2>&1)
}

tree() {   # <dir> -- a copy of the SDK package in the repo's layout
    mkdir -p "$1/sdk/python"
    cp -r "$SDK" "$1/sdk/python/"
    find "$1/sdk/python" -name __pycache__ -prune -exec rm -rf {} +
}

red_test() {   # <log text> <Class.test> -- whether that test FAILED or ERRORed
    local cls="${2%%.*}" fn="${2#*.}"
    grep -qE "^(FAIL|ERROR): ${fn} \\(__main__\\.${cls}[.)]" <<<"$1"
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test that must go red (Class.test)
    local out rc
    if [[ ! -f "$2/APPLIED" ]]; then
        NOT_APPLIED=$((NOT_APPLIED+1))
        printf '  NOT APPLIED %-62s (the mutant did not apply, compile or import)\n' "$1"; return
    fi
    out=$(run_suite "$2"); rc=$?
    if [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
        { printf '%s\nthe test that must go red: %s\n\n' "$1" "$3"; printf '%s\n' "$out"
          echo "exit code: $rc"; } > "$MUTANT_EVIDENCE/$(basename "$2").log"
    fi
    if [[ "$rc" -ne 0 ]] && red_test "$out" "$3"; then
        CAUGHT=$((CAUGHT+1))
        printf '  caught      %-62s (%s went red)\n' "$1" "$3"
    else
        SURVIVED=$((SURVIVED+1))
        printf '  SURVIVED    %-62s (%s stayed green -- that test proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR):|^Ran ' <<<"$out" | sed 's/^/                /'
    fi
}

control() {   # $1 = name, $2 = mutant dir -- must NOT turn the suite red
    local out rc
    if [[ ! -f "$2/APPLIED" ]]; then
        CONTROL_RED=$((CONTROL_RED+1)); printf '  🔴 CONTROL NOT APPLIED %s\n' "$1"; return
    fi
    out=$(run_suite "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green       %-62s (control, as required)\n' "$1"
    else
        CONTROL_RED=$((CONTROL_RED+1))
        printf '  🔴 CONTROL WENT RED %s\n' "$1"
        grep -E '^(FAIL|ERROR):|^Ran ' <<<"$out" | sed 's/^/                /'
    fi
}

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    tree "$d"
    local target="$d/${file#"$REPO"/}"
    if python3 - "$target" "$old" "$new" <<'PY' >&2
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        if "$PY" -m py_compile "$target" >&2 \
                && (cd "$d" && PYTHONPATH="$d/sdk/python" PYTHONDONTWRITEBYTECODE=1 \
                    "$PY" -c "import ndtwin" >&2); then
            touch "$d/APPLIED"
        fi
        find "$d/sdk/python" -name __pycache__ -prune -exec rm -rf {} +
        if [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
            mkdir -p "$MUTANT_EVIDENCE"
            diff -u --label "a/${file#"$REPO"/}" --label "b/${file#"$REPO"/}" "$file" "$target" \
                > "$MUTANT_EVIDENCE/$label.patch"
        fi
    fi
    echo "$d"
}

echo "interpreter: $("$PY" -c 'import sys; print(sys.executable, sys.version.split()[0])')"
echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; tree "$base"
base_out=$(run_suite "$base"); base_rc=$?
grep -E '^Ran |^OK|^FAILED' <<<"$base_out" | sed 's/^/  /'
[[ "$base_rc" -eq 0 ]] || { echo "  baseline is RED -- mutations prove nothing"; exit 2; }
echo

# --- on the wire: what the injection's reply says --------------------------------------------
m=$(mutant l1 "$LINK" \
    '    if end["ok"]:' \
    '    if False:')
report "L1: an end the kernel cut is not counted as carrying the netem" "$m" \
       "CutAndRestoreTest.test_the_cut_says_it_is_on_the_wire_and_where"

m=$(mutant l2 "$LINK" \
    'return back is not None and not (isinstance(back, dict) and back.get("ok") is True)' \
    'return False')
report "L2: a netem the kernel could not roll back is taken as gone" "$m" \
       "OnTheWireTest.test_a_netem_left_on_one_end_does_not_enter_and_is_taken_off"

m=$(mutant l3 "$LINK" \
    'return back is not None and not (isinstance(back, dict) and back.get("ok") is True)' \
    'return back is not None')
report "L3: a rollback that worked is taken as a netem left behind" "$m" \
       "OnTheWireTest.test_a_rollback_that_worked_is_not_on_the_wire"

m=$(mutant l4 "$LINK" \
    'on_wire = (False if not carrying else True if len(carrying) == n else None)' \
    'on_wire = (False if not carrying else True)')
report "L4: a netem on one end only reads as on the wire" "$m" \
       "OnTheWireTest.test_a_netem_left_on_one_end_does_not_enter_and_is_taken_off"

m=$(mutant l5 "$LINK" \
    '    if tc == SKIPPED:' \
    '    if False:')
report "L5: tc skipped (not MININET) is not understood" "$m" \
       "OnTheWireTest.test_tc_skipped_is_not_on_the_wire_and_the_block_runs"

m=$(mutant l6 "$LINK" \
    '    if (isinstance(tc, list) and tc' \
    '    if (isinstance(tc, list)')
report "L6: an empty tc list reads as a cut that attached nothing" "$m" \
       "UnreadableReplyTest.test_an_injection_reply_the_sdk_cannot_read_is_outcome_unknown"

m=$(mutant l7 "$LINK" \
    ' and isinstance(e.get("ok"), bool)' \
    '')
report "L7: a tc entry without ok is read (and the SDK fails on it)" "$m" \
       "UnreadableReplyTest.test_a_recovery_reply_the_sdk_cannot_read_is_link_not_restored"

m=$(mutant l8 "$LINK" \
    '    if not isinstance(status, str) or carrying is None:' \
    '    if carrying is None:')
report "L8: an injection reply without a status line is taken" "$m" \
       "UnreadableReplyTest.test_an_injection_reply_the_sdk_cannot_read_is_outcome_unknown"

# --- nothing changed, or unknown: the POST's failures ---------------------------------------------
m=$(mutant l9 "$LINK" \
    'and body.get("error") != "JSON parsing error":' \
    ':')
report "L9: a 400 JSON parsing error reads as a refusal" "$m" \
       "UnknownOutcomeTest.test_an_unknown_injection_is_outcome_unknown_naming_the_restore"

m=$(mutant l10 "$LINK" \
    'if status == 500 and body.get("error") == _NOTHING_CHANGED[path]:' \
    'if status == 500:')
report "L10: any 500 reads as nothing changed" "$m" \
       "UnknownOutcomeTest.test_an_unknown_recovery_is_link_not_restored_and_sent_once"

m=$(mutant l11 "$LINK" \
    'status=status, origin=err.origin, body=err.body, nothing_written=True)' \
    'status=status, origin=err.origin, body=err.body, nothing_written=None)')
report "L11: the 500 that says nothing was injected reads as may have landed" "$m" \
       "RefusalsTest.test_the_injections_500_that_says_nothing_was_injected_is_not_unknown"

m=$(mutant l12 "$LINK" \
    'if status is not None and 400 <= status < 500' \
    'if status is not None and 400 <= status < 400')
report "L12: a refusal of the injection reads as may be cut" "$m" \
       "RefusalsTest.test_each_refusal_of_the_injection_changes_nothing_and_runs_no_block"

m=$(mutant l13 "$LINK" \
    '    new.lab_claim, new.remedy = err.lab_claim, remedy' \
    '    new.lab_claim = err.lab_claim')
report "L13: an unknown injection does not name the restore" "$m" \
       "UnknownOutcomeTest.test_an_unknown_injection_is_outcome_unknown_naming_the_restore"

m=$(mutant l14 "$LINK" \
    '        return http.call("POST", path, body=_body(ends)).body' \
    '        try:
            return http.call("POST", path, body=_body(ends)).body
        except NDTwinError:
            return http.call("POST", path, body=_body(ends)).body')
report "L14: a POST is sent again after an unknown outcome" "$m" \
       "UnknownOutcomeTest.test_an_unknown_recovery_is_link_not_restored_and_sent_once"

m=$(mutant l15 "$LINK" \
    '"dst_interface": bp}' \
    '"dst_interface": ap}')
report "L15: the body names the far end with the near end's port" "$m" \
       "CutAndRestoreTest.test_the_body_names_each_end_with_its_own_port"

# --- restored: what the recovery's reply says -----------------------------------------------------
m=$(mutant l16 "$LINK" \
    '        problems = still_cut' \
    '        problems = ()')
report "L16: restore_link returns over a netem it did not clear" "$m" \
       "RestoreLinkTest.test_a_netem_left_standing_raises"

m=$(mutant l17 "$LINK" \
    '        problems = tuple(i for i in attached if i not in cleared)' \
    '        problems = ()')
report "L17: the block ends cleanly over an interface it attached and did not clear" "$m" \
       "ExitNotCleanTest.test_an_unreadable_tree_on_an_attached_interface_is_not_a_clean_exit"

m=$(mutant l18 "$LINK" \
    'cleared = {e.get("interface") for e in entries if e["ok"]}' \
    'cleared = {e.get("interface") for e in entries}')
report "L18: an interface the recovery refused counts as cleared" "$m" \
       "ExitNotCleanTest.test_a_netem_left_standing_on_an_attached_interface_is_not_a_clean_exit"

m=$(mutant l19 "$LINK" \
    '    if attached is None:' \
    '    if not attached:')
report "L19: a netem the injection did not attach fails the end of the block" "$m" \
       "OnTheWireTest.test_a_refused_cut_is_not_on_the_wire_and_a_netem_it_did_not_attach_is_reported"

m=$(mutant l20 "$LINK" \
    '    if not isinstance(status, str) or tc is None:' \
    '    if tc is None:')
report "L20: a recovery reply without a status line is taken" "$m" \
       "UnreadableReplyTest.test_a_restore_link_reply_the_sdk_cannot_read_is_link_not_restored"

m=$(mutant l21 "$LINK" \
    '                still = tuple(str(i) for i in theirs)' \
    '                pass')
report "L21: the 409 does not name the netem that is not this kernel's" "$m" \
       "RefusalsTest.test_the_409_names_the_netem_that_is_not_this_kernels"

m=$(mutant l22 "$LINK" \
    'nothing_written=err.nothing_written,' \
    'nothing_written=None,')
report "L22: a refused recovery reads as may have changed something" "$m" \
       "RestoreLinkTest.test_after_a_kernel_restart_the_409_raises_and_changes_nothing"

m=$(mutant l23 "$LINK" \
    'if e["ok"] and "noop" not in e)' \
    'if e["ok"])')
report "L23: a noop is reported as a netem removed" "$m" \
       "RestoreLinkTest.test_a_link_with_nothing_to_restore_is_a_noop"

m=$(mutant l32 "$LINK" \
    '    out = [str(i) for i in ifaces if i is not None]' \
    '    out = list(ifaces)')
report "L32: an end the kernel did not name makes a message raise TypeError" "$m" \
       "UnnamedEndTest.test_an_unnamed_end_refused_at_exit_is_reported_as_such"

# --- the block --------------------------------------------------------------------------------------
m=$(mutant k1 "$KERNEL" \
    '        if cut.on_wire is None:' \
    '        if False:')
report "K1: the block runs over a netem left on one end" "$m" \
       "OnTheWireTest.test_a_netem_left_on_one_end_does_not_enter_and_is_taken_off"

m=$(mutant k2 "$KERNEL" \
    '            done = self._recover_cut(ends, cut.interfaces)' \
    '            done = None')
report "K2: a netem left on one end is not taken off" "$m" \
       "OnTheWireTest.test_a_netem_left_on_one_end_that_stays_raises_link_not_restored"

m=$(mutant k3 "$KERNEL" \
    '        except BaseException as exc:' \
    '        except Exception as exc:')
report "K3: Ctrl-C in the block skips the recovery" "$m" \
       "BlockEndsTest.test_ctrl_c_in_the_block_still_restores"

m=$(mutant k4 "$KERNEL" \
    '                cut.restored = self._recover_cut(ends, cut.interfaces)' \
    '                cut.restored = None')
report "K4: a block that raises skips the recovery" "$m" \
       "BlockEndsTest.test_the_restore_is_sent_when_the_block_raises_and_its_exception_goes_on"

m=$(mutant k5 "$KERNEL" \
    '                _attach(exc, err)' \
    '                pass')
report "K5: a failed recovery under a raising block is dropped" "$m" \
       "BlockEndsTest.test_a_failed_restore_while_the_block_raised_keeps_the_blocks_exception"

m=$(mutant k6 "$KERNEL" \
    '                _attach(exc, err)' \
    '                raise err')
report "K6: a failed recovery replaces the block's own exception" "$m" \
       "BlockEndsTest.test_a_failed_restore_after_ctrl_c_keeps_the_interrupt"

m=$(mutant k7 "$KERNEL" \
    '            cut.restore_error = err
            raise

    def restore_link' \
    '            cut.restore_error = err

    def restore_link')
report "K7: a failed recovery after a clean block is not raised" "$m" \
       "BlockEndsTest.test_a_failed_restore_after_a_clean_block_says_the_link_may_still_be_cut"

m=$(mutant k18 "$KERNEL" \
    'f"only; the block did not run, and the recovery the SDK sent "' \
    'f"only ({cut.why}); the block did not run, and the recovery the SDK sent "')
report "K18: the half-cut error repeats the kernel's nothing-attached sentence" "$m" \
       "OnTheWireTest.test_the_half_cut_error_carries_the_recovery_and_may_have_landed"

# --- refused before sending -------------------------------------------------------------------------
m=$(mutant k8 "$KERNEL" \
    '    if 0 in (ends[0][0], ends[1][0]):' \
    '    if False:')
report "K8: a host-facing link is sent" "$m" \
       "BeforeSendingTest.test_a_host_facing_link_of_the_topology_is_refused_before_sending"

m=$(mutant k9 "$KERNEL" \
    '        if not same:' \
    '        if False:')
report "K9: a link not in the topology as given is sent" "$m" \
       "BeforeSendingTest.test_a_link_not_in_the_topology_as_given_is_not_found_before_sending"

m=$(mutant k10 "$KERNEL" \
    '        if other:' \
    '        if False:')
report "K10: a link that shares its switches with another is sent" "$m" \
       "BeforeSendingTest.test_a_link_that_shares_its_switches_with_another_is_refused_before_sending"

m=$(mutant k11 "$KERNEL" \
    '        if refuse_declared and declared:' \
    '        if False:')
report "K11: a link already declared down is cut again" "$m" \
       "BeforeSendingTest.test_a_link_already_declared_down_is_refused_before_sending"

m=$(mutant k12 "$KERNEL" \
    '        return _link.recover(self._http, self._cuttable(link, refuse_declared=False))' \
    '        return _link.recover(self._http, _link.ends_of(link))')
report "K12: restore_link sends a link the kernel would address wrongly" "$m" \
       "BeforeSendingTest.test_restore_link_refuses_a_link_the_kernel_would_address_wrongly"

m=$(mutant k13 "$KERNEL" \
    'self._cuttable(link, refuse_declared=False))' \
    'self._cuttable(link, refuse_declared=True))')
report "K13: restore_link refuses the declared link it is for" "$m" \
       "RestoreLinkTest.test_it_takes_off_what_this_kernel_attached"

m=$(mutant k14 "$KERNEL" \
    '            err.nothing_written = None' \
    '            pass')
report "K14: a recovery refused at the end of the block says nothing was written" "$m" \
       "BlockEndsTest.test_a_kernel_that_restarted_during_the_block_leaves_the_link_maybe_cut"

m=$(mutant k15 "$KERNEL" \
    'status=200, body=cut.body, nothing_written=None)' \
    'status=200, body=cut.body, nothing_written=True)')
report "K15: the half-cut error says nothing was written" "$m" \
       "OnTheWireTest.test_the_half_cut_error_carries_the_recovery_and_may_have_landed"

m=$(mutant k16 "$KERNEL" \
    '            err.lab_claim, err.restore = cut.lab_claim, done' \
    '            err.lab_claim = cut.lab_claim')
report "K16: the half-cut error drops what the recovery did" "$m" \
       "OnTheWireTest.test_the_half_cut_error_carries_the_recovery_and_may_have_landed"

m=$(mutant k17 "$KERNEL" \
    '        except (TypeError, KeyError, AttributeError, ValueError) as exc:' \
    '        except ZeroDivisionError as exc:')
report "K17: a graph the SDK cannot read escapes as TypeError" "$m" \
       "BeforeSendingTest.test_a_graph_the_sdk_cannot_read_is_an_sdk_error"

m=$(mutant l26 "$LINK" \
    '    if isinstance(err, KernelUnreachable):' \
    '    if False:')
report "L26: an unreachable kernel at the injection reads as may be cut" "$m" \
       "RefusalsTest.test_a_kernel_unreachable_at_the_injection_changes_nothing"

m=$(mutant l27 "$LINK" \
    '        still = tuple(attached) if attached else None' \
    '        still = None')
report "L27: a failed recovery does not name the interfaces it may have left cut" "$m" \
       "BlockEndsTest.test_a_kernel_unreachable_at_the_end_of_the_block_leaves_the_link_maybe_cut"

m=$(mutant l28 "$LINK" \
    '(isinstance(e.get("interface"), str) or e.get("interface") is None
                         and e["ok"] is False)' \
    'isinstance(e.get("interface"), str)')
report "L28: an end the kernel cannot name makes the reply unreadable" "$m" \
       "OnTheWireTest.test_an_end_the_kernel_cannot_name_is_not_on_the_wire_and_the_block_runs"

m=$(mutant l29 "$LINK" \
    '            remedy = _by_hand(still)' \
    '            pass')
report "L29: a 409 names a restore that is refused again" "$m" \
       "RefusalsTest.test_the_409_names_the_netem_that_is_not_this_kernels"

m=$(mutant l30 "$LINK" \
    '    if any(i not in refused for i in problems):' \
    '    if True:')
report "L30: a netem left standing is told to restore_link" "$m" \
       "RestoreLinkTest.test_a_netem_left_standing_raises"

m=$(mutant l31 "$LINK" \
    '                            _remedy(ends, entries, problems), status=200, body=body, tc=tc,' \
    '                            restore_call(ends), status=200, body=body, tc=tc,')
report "L31: a 200 that left a netem standing names the restore call only" "$m" \
       "ExitNotCleanTest.test_a_netem_left_standing_on_an_attached_interface_is_not_a_clean_exit"

m=$(mutant l24 "$LINK" \
    'dpid >= 0 and port >= 0' \
    'True')
report "L24: a negative dpid or port is not a ValueError" "$m" \
       "BeforeSendingTest.test_what_is_not_a_link_is_a_value_error"

m=$(mutant l25 "$LINK" \
    '    return isinstance(value, int) and not isinstance(value, bool)' \
    '    return isinstance(value, int)')
report "L25: True is taken as dpid 1" "$m" \
       "BeforeSendingTest.test_what_is_not_a_link_is_a_value_error"

m=$(mutant t1 "$TOPO" \
    'down_reason=e.get("down_reason")))' \
    'down_reason=None))')
report "T1: the topology drops down_reason" "$m" \
       "CutAndRestoreTest.test_the_topology_shows_the_link_declared_inside_the_block"

# --- the control --------------------------------------------------------------------------------
m=$(mutant l0 "$LINK" \
    '        return err      # nothing was sent; the transport already tried again' \
    '        return err      # nothing was sent; the transport already tried again (x)')
control "L0: a comment-only edit" "$m"

echo
NOW_SUMS=$(sdk_sums)
if [[ "$NOW_SUMS" != "$BASE_SUMS" ]]; then
    echo "🔴 the SDK CHANGED during the gate -- a source file was written"
    diff <(echo "$BASE_SUMS") <(echo "$NOW_SUMS") | sed 's/^/   /'
    exit 3
fi
echo "SDK byte-identical: yes  link.py sha256 $(sha256sum "$LINK" | cut -d' ' -f1)"
echo "mutation gate: $((CAUGHT+SURVIVED+NOT_APPLIED)) mutations: $CAUGHT caught, $SURVIVED survived," \
     "$NOT_APPLIED not applied; control $([[ $CONTROL_RED -eq 0 ]] && echo green || echo RED)"
[[ "$SURVIVED" -eq 0 && "$NOT_APPLIED" -eq 0 && "$CONTROL_RED" -eq 0 ]]
