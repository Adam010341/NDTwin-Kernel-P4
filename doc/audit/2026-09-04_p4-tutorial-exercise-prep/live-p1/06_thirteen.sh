#!/usr/bin/env bash
#
# P3 live acceptance ⑥ -- all thirteen exercises, both arms, on the NDTwin fabric.
#
# [Co-developed with claude code -- Adam]
#
# TICKET-P3 §2.7 and §8-2. This is a LOOP AND A TABLE, not a check: every judgement belongs to
# drive_exercise.py, which brings its own fabric up and tears it down per arm and writes its own
# report. What this script adds is the one thing twenty-six separate commands cannot: a single
# table that says which arms ran, what each of them exited, and -- the part that matters -- that
# every SKELETON arm was red and every SOLUTION arm was green.
#
# 🔴 THE RED ARMS ARE THE SUBJECT, AND "RED" IS A PROPERTY OF THE EXPECTATIONS, NOT OF THE RC.
# drive_exercise.py's skeleton arms assert the red things -- "h2 received 0 packets", "every
# reported port is 0", "the flow is NOT blocked" -- so a skeleton arm that behaves as the
# exercise says exits 0 with those met. What this step is for is that BOTH arms of each exercise
# were run and each held its own expectations; a round in which the skeleton's red assertions
# did not hold is the finding, because it is consistent with a fabric that forwards everything
# and with expectations written the wrong way round.
#
# 🔴 IT CLAIMS NOTHING ITSELF. `ndt claim` is taken by each drive_exercise.py round (its
# run_on_ndtwin does convert -> pre-flight -> claim -> up -> steps -> down -> release), so this
# script must NOT hold the lab while they run -- it would refuse its own children. That is why
# it does not source _common.sh's start_step: there is no fabric of its own to tear down, and
# the only state it touches is the two knobs, which it checks rather than writes.
#
# 🔴 NOTHING HERE USES pkill/pgrep, and nothing here kills anything at all.
#
# Run:  bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/06_thirteen.sh
#       ONLY=basic,calc  bash .../06_thirteen.sh      # a subset, for a re-run
# Exit: 0 every arm as expected, 1 some arm was not, 2 refused before anything was started.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
#: The driver this step runs. A seam of the same shape NDT_UNDER_TEST and STACK_UNDER_TEST are,
#: so tests/shell/test_live_p1_thirteen.sh can drive this file against a stub whose exit codes
#: are a table -- which is the only way to test the one decision this step makes without a lab.
DRIVER="${DRIVER_UNDER_TEST:-$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py}"
VENV_PY="${VENV_PY:-/home/adam/p4dev-python-venv/bin/python}"
: "${NDT_OWNER:=live-p1}"
export NDT_OWNER

#: Where this step's raw goes. A seam for the same reason DRIVER_UNDER_TEST is one: without it
#: every run of tests/shell/test_live_p1_thirteen.sh left a run directory in the CHECKOUT, which
#: is R3's defect (a test that litters) with the repo as the target instead of /tmp.
RUN="${RUNS_DIR:-$HERE/runs}/$(date -u '+%Y-%m-%dT%H%M%SZ')_06_thirteen"
mkdir -p "$RUN" || { echo "could not create $RUN" >&2; exit 2; }

say()  { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
bad()  { printf '   !! %s\n' "$*" >&2; }

printf '== 06_thirteen\n   repo: %s\n   raw : %s\n   owner: %s\n' "$REPO" "$RUN" "$NDT_OWNER"
[[ -r "$DRIVER" ]]  || { bad "no driver at $DRIVER"; exit 2; }
[[ -x "$VENV_PY" ]] || { bad "no interpreter at $VENV_PY -- send.py/receive.py have no scapy"; exit 2; }
# 🔴 EUID 0 IS REFUSED HERE TOO, and before anything is written. The driver refuses it per round
# (it would leave root-owned files in .test_run/ and runs/), so a sudo'd loop would produce
# twenty-six identical rc 2 rows and a table that looked like thirteen broken exercises.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    bad "refusing: this must NOT be run as root. drive_exercise.py --fabric ndtwin refuses euid 0"
    bad "per round, so under sudo every row below would be rc 2 for the same reason."
    rmdir "$RUN" 2>/dev/null || true
    exit 2
fi

# The order is the cheap ones first, so a broken fabric is visible in two minutes rather than in
# forty. Within that, the two external-controller exercises last: they are the only ones whose
# round starts a process of their own.
ALL="basic source_routing calc multicast basic_tunnel load_balance qos link_monitor firewall ecn mri p4runtime flowcache"
EXERCISES="${ONLY:-}"
if [[ -n "$EXERCISES" ]]; then
    EXERCISES="${EXERCISES//,/ }"
else
    EXERCISES="$ALL"
fi

TABLE="$RUN/00_table.tsv"
printf 'exercise\twhich\trc\tverdict\treport\n' > "$TABLE"
FAILED=0
ROWS=0

# 🔴 WHAT "AS EXPECTED" MEANS, per arm -- AND A CORRECT SKELETON ARM EXITS 0.
#
# Round 1 had this inverted (judge A2, TICKET-P3 section 9 ruling 9). "The red arm is red" is a
# statement about the EXERCISE, and drive_exercise.py expresses it as an EXPECTATION -- the
# skeleton arm asserts "h2 received 0 packets", "every reported port is 0", "the flow is NOT
# blocked". When the skeleton behaves as the exercise says, every one of those PASSES and the
# driver exits 0. The 2026-09-08 and 2026-09-18 real runs are that: `>>> PASS (2/2)` and
# `PASS (4/4)` on skeleton arms, exit 0, in runs/. With rc 1 expected, a completely correct
# round of twenty-six arms would have printed `FAIL 06_thirteen -- 11 of 26`.
#
#   solution  rc 0 -- every expectation met.
#   skeleton  rc 0 -- every expectation met, and the skeleton's expectations are the red ones.
#             rc 1 means one of them did NOT hold, i.e. the skeleton did not behave the way the
#             exercise says it does; that is the finding, and it is what "the red arm is not
#             red" looks like from here.
#   EXCEPT    the two arms whose red is a REFUSAL rather than a data-plane reading, which
#             drive_exercise.py reports as `RED ARM (1/1): ... by design` and exit 1:
#               * flowcache/skeleton, on either fabric -- p4c refuses it (README:29);
#               * basic_tunnel/skeleton, on EITHER fabric -- its runtime entries name a table
#                 the skeleton does not declare (README:41-43). NDTwin refuses them in
#                 pre-flight; tutorials raises inside the harness. Round 2 reported those two
#                 as different verdicts (`RED ARM (1/1)`/1 vs `PASS (1/1)`/0); round 3 made the
#                 driver report the same refusal the same way on both, so this table does too.
#
# 🔴 rc 2 IS NOT EVIDENCE EITHER WAY on any arm: the round never ran.
expected_rc() {   # expected_rc <exercise> <which>
    local ex="$1" which="$2"
    [[ "$which" == solution ]] && { echo 0; return; }
    case "$ex" in
        flowcache)    echo 1 ;;
        basic_tunnel) echo 1 ;;          # both fabrics now; this script drives ndtwin
        *)            echo 0 ;;
    esac
}

run_arm() {   # run_arm <exercise> <which>
    # 🔴 THE PATH IS ASSIGNED ON ITS OWN LINE, and that is not style. Under `set -u` bash 5.2
    # declares every name in a `local` list BEFORE assigning any of them, so a later assignment
    # that reads an earlier one expands an UNSET variable and the function dies on its first
    # line: `which: unbound variable`. Both live scripts had it, neither had ever been run, and
    # tests/shell/test_live_p1_thirteen.sh is what found it (TICKET-P3 §9 ruling 9, round 2).
    local ex="$1" which="$2"
    local log rc want verdict report
    log="$RUN/${ex}_${which}.log"
    say "$ex / $which"
    "$VENV_PY" "$DRIVER" "$ex" --which "$which" --fabric ndtwin > "$log" 2>&1
    rc=$?
    want="$(expected_rc "$ex" "$which")"
    verdict="$(/usr/bin/grep -m1 '^>>> ' "$log" | sed 's/^>>> //')"
    report="$(/usr/bin/grep -m1 '^report: ' "$log" | sed 's/^report: //')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$ex" "$which" "$rc" "${verdict:-<no verdict line>}" "${report:-<none>}" >> "$TABLE"
    ROWS=$((ROWS+1))
    note "rc=$rc (want $want)   ${verdict:-<no verdict line>}"
    [[ -n "$report" ]] && note "report: $report"
    # 🔴 rc 1 ALONE CANNOT TELL "by design" FROM "the red arm is not red" (round-3 ruling 2).
    # The two exception arms are expected to exit 1 -- but so does an arm that FAILED an
    # expectation. `flowcache/skeleton` that COMPILED prints `FAIL (1/1): the skeleton COMPILED`
    # and exits 1; `basic_tunnel/skeleton` whose entries INSTALLED prints `FAIL (1/n)` and exits
    # 1. Comparing rc only, this step printed PASS for both -- for exactly the finding it exists
    # to report. The verdict line is already in `$verdict`; it just was not asserted on.
    if [[ "$rc" == "$want" ]]; then
        if [[ "$want" == 1 && "$verdict" != "RED ARM"* ]]; then
            bad "$ex/$which exited 1 as expected, but its verdict is not a designed refusal:"
            bad "    $verdict"
            bad "  This arm's red is supposed to be a REFUSAL -- p4c for flowcache, the control"
            bad "  plane for basic_tunnel -- which the driver reports as 'RED ARM (n/n): ... by"
            bad "  design'. A 'FAIL (n/m)' here means the refusal did NOT happen and an"
            bad "  expectation went red instead: the red arm is not red, which is the finding."
            tail -20 "$log" | sed 's/^/     /'
            FAILED=$((FAILED+1))
            return 1
        fi
        return 0
    fi
    if [[ "$which" == skeleton && "$rc" == 1 ]]; then
        bad "$ex/skeleton FAILED an expectation. Its expectations ARE the red ones -- 'received"
        bad "  0 packets', 'every reported port is 0', 'the flow is NOT blocked' -- so one of"
        bad "  them not holding means the skeleton did not behave the way the exercise says it"
        bad "  does, and that exercise's solution arm is then not evidence about the solution."
    elif [[ "$rc" == 2 ]]; then
        bad "$ex/$which exited 2 -- the round never ran (pre-flight, claim, compile or root)."
        bad "  That is not a result about the exercise, and it is not a pass."
    else
        bad "$ex/$which exited $rc, want $want"
    fi
    tail -20 "$log" | sed 's/^/     /'
    FAILED=$((FAILED+1))
    return 1
}

for ex in $EXERCISES; do
    run_arm "$ex" skeleton || true
    run_arm "$ex" solution || true
done

say "the table"
column -t -s $'\t' "$TABLE" 2>/dev/null | sed 's/^/   /' || sed 's/^/   /' "$TABLE"

# 🔴 THE TWO KNOBS, CHECKED RATHER THAN WRITTEN. Every round puts them back itself (the driver's
# ndtwin_teardown); this is the assertion that it did. A loop that quietly restored them would be
# hiding the one failure that survives into the next session.
say "what the rounds left behind"
for knob in p4_proxy/mininet/host_count_override p4_proxy/mininet/app_package_override \
            p4_proxy/mininet/telemetry_override; do
    if [[ -e "$REPO/$knob" ]]; then
        note "$knob: $(tr -d '\n' < "$REPO/$knob" | head -c 60)"
    else
        note "$knob: absent"
    fi
done
if [[ -e "$REPO/p4_proxy/mininet/app_package_override" ]]; then
    bad "p4_proxy/mininet/app_package_override SURVIVED every round -- the next 'ndt up p4' and"
    bad "  the next proxy read it. Remove it by hand."
    FAILED=$((FAILED+1))
fi

printf '\nraw: %s\n' "$RUN"
if (( FAILED == 0 )); then
    printf 'PASS 06_thirteen -- %d arm(s), every arm as the exercise says it should be\n' "$ROWS"
    exit 0
fi
printf 'FAIL 06_thirteen -- %d of %d arm(s) were not what the exercise says they should be\n' "$FAILED" "$ROWS"
exit 1
