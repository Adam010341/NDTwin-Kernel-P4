#!/usr/bin/env bash
#
# Mutation gate for p4_proxy/tests/test_readopt.py's startup-reset classes:
# ClearSwitchesFromAPreviousRunTest and GrpcPortIsOpenTest.  KNOWN-ISSUES G-9, G-inst-2.
#
# [Co-developed with claude code -- Adam]
#
# The defect being replaced was one line, twice:
#
#     os.system('sudo pkill -f simple_switch_grpc > /dev/null 2>&1')
#
# in p4_proxy/mininet/p4_testbed_topo.py and again in ntg_bmv2_topo.py -- as root, on every
# bring-up, for as long as either file has existed. CLAUDE.md's engineering discipline names that
# exact form as forbidden; `-f` matches the whole command line, so it takes any process whose
# argv merely mentions the string, and Mininet switches share the root PID namespace, so there is
# no blast wall between the ten.
#
# A fix like this is easy to test into decoration, because the interesting assertions are about
# what the code no longer does. So the mutations put back the things a reader would assume are
# free: not calling the reap at all, deleting the manifest afterwards ("it is stale anyway"),
# probing one port instead of ten, and reporting a held port without saying which port or how to
# look. Each of those is a plausible edit and each one costs the fix its point.
#
# 2026-09-12 (FIX-PROXY-2 A8): the reset grew a second half. A gRPC port the reap could not
# free no longer produces a warning that the run walks past -- it aborts the bring-up, in BOTH
# mains, naming the port, its owner's `ss -ltnp` line and how to check that by hand. MS8-MS11
# below are that half, and they are aimed at the four ways a refusal quietly becomes a warning
# again: the exit disappears, a main stops asking, only the first port is looked up, or the
# owner stops being named. MS9 is the one that matters most and the one a unit test cannot
# reach on its own -- ndtwin-lab starts ntg_bmv2_topo.py, so a decision wired into only one
# main is a decision that does not run.
#
# Eleven mutations plus a control:
#   MS1       the manifest is never consulted -- a reset that resets nothing.
#   MS2       the manifest is deleted after the reap. This is the A-4 bookkeeping defect moved
#             to startup: the file is the only handle left on a switch the reap failed to stop.
#   MS3, MS4  the port probe narrows to one port, or its result is thrown away.
#   MS5, MS6  the warning survives but stops being actionable: no port number, or no way to find
#             the owner. What replaced the name match is a SENTENCE, so a sentence that does not
#             say anything is the way this fix quietly becomes worse than what it replaced.
#   MS7       the settle disappears, so a switch on its way out reads as a stranger.
#   MS8       the abort stops aborting -- the refusal becomes the warning it replaced.
#   MS9       main() stops calling it, so the policy exists and nothing executes it.
#   MS10      the owner is looked up for the first held port only.
#   MS11      the abort stops naming WHO holds the port, leaving a number the operator cannot act on.
#   C1        a comment is reworded and nothing may change.
#
# A mutation that makes the WRONG test go red is a SURVIVOR: the case it targets was never put to
# the test.
#
# 🔴 Never writes p4_proxy/mininet/p4_testbed_topo.py. Every mutation goes to a COPY in a temp
# dir and the suite is pointed at it with P4_TESTBED_TOPO_UNDER_TEST -- this worktree is shared
# and another session may be running the real file right now. Byte identity is asserted anyway.
#
# 🔴 Signals nothing. The reap and the port probe are injected in every test in the two classes;
# the one real socket is bound on an ephemeral port on 127.0.0.1 and closed by the test.
#
# 🔴 Touches no lab and builds nothing.
#
# Usage:  tests/shell/mutate_startup_clears_by_pid.sh
#   TEST_TIMEOUT=300   seconds allowed per suite run
#   PY=...             interpreter for the suite (default p4_proxy/venv/bin/python3)
#
# Exit: 0 every mutation was caught by the test named for it, and the control survived
#       1 at least one mutation survived, or was caught by the wrong test
#       2 the gate cannot render a verdict (baseline red, anchor drift, hang, failed restore, or
#         the control going red -- which would mean this gate measures "the file changed")
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SUBJECT="$REPO/p4_proxy/mininet/p4_testbed_topo.py"
SUITE="$REPO/p4_proxy/tests/test_readopt.py"
PY="${PY:-$REPO/p4_proxy/venv/bin/python3}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"

if ! bash -n "${BASH_SOURCE[0]}"; then echo "🔴 this script does not parse" >&2; exit 2; fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$SUBJECT" && -f "$SUITE" ]] || { echo "🔴 missing $SUBJECT or $SUITE" >&2; exit 2; }
[[ -x "$PY" ]] || { echo "🔴 no interpreter at $PY (override with PY=)" >&2; exit 2; }

BK=$(mktemp -d "${TMPDIR:-/tmp}/startup-clear-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT INT TERM
BASE_SHA=$(sha256sum "$SUBJECT" | cut -d' ' -f1)

MUTATIONS=0
SURVIVORS=0
VERDICT=0

# The suite, driven against whichever copy of the subject it is handed. `cd p4_proxy` is how
# tools/test_workflow/l1_unit_tests.sh runs these files, and PYTHONPATH=. is what makes
# `from proxy_agent import ...` resolve.
run_against() {
    ( cd "$REPO/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=. \
        P4_TESTBED_TOPO_UNDER_TEST="$1" timeout "$TEST_TIMEOUT" "$PY" tests/test_readopt.py \
        2>&1 )
}

report() {   # $1 = mutation name, $2 = mutated copy, $3 = the test that must go red
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" == 124 ]]; then
        printf '  🔴 %-56s suite HUNG -- never a catch\n' "$1" >&2
        VERDICT=2; return
    fi
    if (( rc > 128 )); then
        printf '  🔴 %-56s suite died of signal %s -- not an assertion\n' "$1" "$((rc-128))" >&2
        VERDICT=2; return
    fi
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS + 1))
        VERDICT=1
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$1" "$3" >&2
        grep -E '^(FAIL|ERROR): |^Ran |^OK|^FAILED' <<<"$out" | sed 's/^/             /' >&2
    fi
}

control() {  # $1 = name, $2 = mutated copy -- must NOT go red
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  SURVIVED %-56s (control, as required)\n' "$1"
    else
        printf '  🔴 %-56s CONTROL WENT RED -- this gate measures "the file changed"\n' "$1" >&2
        grep -E '^(FAIL|ERROR): |^Ran ' <<<"$out" | sed 's/^/             /' >&2
        VERDICT=2
    fi
}

mutant() {   # $1 = name, $2 = anchor \x1f replacement; prints the path to the mutated copy
    # 🔴 The whole mininet/ directory, not just the one file: p4_testbed_topo.py puts its OWN
    # directory on sys.path and imports topo_from_json and grpc_ports out of it, so a lone copy
    # in a temp dir dies at import and every setUpClass errors -- which the gate would have
    # reported as seven survivors and one red control. Measured, first run of this gate.
    local dir="$BK/$1"; mkdir -p "$dir"
    cp "$REPO"/p4_proxy/mininet/*.py "$dir/"
    local out="$dir/p4_testbed_topo.py"
    "$PY" - "$out" "$2" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
old, new = spec.split("\x1f")
s = open(p).read()
assert s.count(old) == 1, "anchor is not unique (%d matches): %r" % (s.count(old), old[:70])
open(p, "w").write(s.replace(old, new))
PY
    echo "$out"
}

echo "baseline (must be green before any mutation):"
run_against "$SUBJECT" | grep -E '^(Ran|OK|FAILED)' | tail -2
if ! run_against "$SUBJECT" >/dev/null 2>&1; then
    echo "  🔴 baseline is RED -- nothing below is interpretable" >&2
    run_against "$SUBJECT" | grep -E '^(FAIL|ERROR): ' | sed 's/^/    /' >&2
    exit 2
fi
echo

# --- the reset resets nothing --------------------------------------------------------------------

ms1=$(mutant ms1 '    reaped = reap(manifest_path)'$'\x1f''    reaped = []')
report "MS1: the manifest is never consulted" "$ms1" \
       "test_the_pids_come_from_the_manifest"

ms2=$(mutant ms2 '    held = [port for port in ports if port_is_open(port)]'$'\x1f''    os.remove(manifest_path)
    held = [port for port in ports if port_is_open(port)]')
report "MS2: the manifest is deleted after the reap (A-4, at startup)" "$ms2" \
       "test_the_manifest_file_is_not_deleted"

# --- the probe stops answering about the fabric --------------------------------------------------

ms3=$(mutant ms3 '    held = [port for port in ports if port_is_open(port)]'$'\x1f''    held = [port for port in ports[:1] if port_is_open(port)]')
report "MS3: only the first gRPC port is probed" "$ms3" \
       "test_every_wanted_port_is_probed"

ms4=$(mutant ms4 '    if held:
        report("")'$'\x1f''    if False:
        report("")')
report "MS4: a held port is found and then ignored" "$ms4" \
       "test_a_port_still_held_is_reported_with_its_number"

# --- the warning survives but stops being actionable ---------------------------------------------
# The name match was replaced by a SENTENCE. A sentence that does not say which port, or does not
# say how to look, leaves the operator with exactly the instrument this fix removed.

ms5=$(mutant ms5 '               % (len(held), manifest_path, ", ".join(str(p) for p in held)))'$'\x1f''               % (len(held), manifest_path, "some of them"))')
report "MS5: the warning does not say WHICH port" "$ms5" \
       "test_a_port_still_held_is_reported_with_its_number"

ms6=$(mutant ms6 '        report("    sudo ss -ltnp \"sport = :%d\"" % held[0])'$'\x1f''        report("    (look it up yourself)")')
report "MS6: the warning does not say how to find the owner" "$ms6" \
       "test_the_report_says_how_to_find_the_owner_by_its_port"

# --- the settle ----------------------------------------------------------------------------------

ms7=$(mutant ms7 '        if settle_s:
            time.sleep(settle_s)'$'\x1f''        if False:
            time.sleep(settle_s)')
report "MS7: no settle, so a switch on its way out reads as a stranger" "$ms7" \
       "test_the_settle_runs_once_when_something_was_reaped"

# --- the refusal (2026-09-12, A8) ----------------------------------------------------------------
# What replaced "warn and continue" is an ABORT. Each mutation below leaves the abort in place
# and takes away one thing that makes it a decision rather than a louder warning.

ms8=$(mutant ms8 '    report("")
    exit_(1)'$'\x1f''    report("")
    return')
report "MS8: the abort reports and then goes on anyway" "$ms8" \
       "test_a_held_port_stops_the_run_with_a_non_zero_status"

ms9=$(mutant ms9 '    abort_if_grpc_ports_are_held(still_held)'$'\x1f''    pass  # the policy is defined, and main does not ask it')
report "MS9: main() defines the refusal and never calls it" "$ms9" \
       "test_each_main_aborts_on_what_the_reset_could_not_free"

ms10=$(mutant ms10 '    for port in held:
        line = owner_of(port)'$'\x1f''    for port in held[:1]:
        line = owner_of(port)')
report "MS10: only the first held port has its owner looked up" "$ms10" \
       "test_the_owner_is_asked_about_every_held_port"

ms11=$(mutant ms11 '            report("  :%d is held by  %s" % (port, line))'$'\x1f''            report("  :%d is held" % port)')
report "MS11: the abort stops saying WHO holds the port" "$ms11" \
       "test_the_owner_of_each_held_port_is_printed_verbatim"

# --- the control ---------------------------------------------------------------------------------

c1=$(mutant c1 '        # One settle for the whole set: a port is released when the process exits, and the'$'\x1f''        # One settle for the whole set (a port is released when the process exits) and the')
control "C1 (control): a comment is reworded" "$c1"

# --- the subject must be untouched ---------------------------------------------------------------
echo
NOW_SHA=$(sha256sum "$SUBJECT" | cut -d' ' -f1)
if [[ "$NOW_SHA" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes  p4_proxy/mininet/p4_testbed_topo.py (never written)"
else
    echo "🔴 $SUBJECT WAS WRITTEN -- $BASE_SHA -> $NOW_SHA" >&2
    VERDICT=2
fi

echo
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
case "$VERDICT" in
    0) echo "VERDICT: every mutation was caught by the test named for it; the control survived" ;;
    1) echo "VERDICT: at least one mutation survived or was caught by the wrong test" >&2 ;;
    *) echo "VERDICT: no verdict -- the gate could not run cleanly" >&2 ;;
esac
exit "$VERDICT"
