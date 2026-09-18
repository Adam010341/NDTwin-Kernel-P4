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
# 🔴 THE RED ARMS ARE THE SUBJECT, NOT THE LEFTOVERS. A round in which every solution passed and
# every skeleton ALSO passed has established nothing at all: it is consistent with a fabric that
# forwards everything, with a driver whose assertions never ran, and with thirteen expectations
# written the wrong way round. So a skeleton arm that exits 0 fails this step, by name.
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
DRIVER="$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py"
VENV_PY="${VENV_PY:-/home/adam/p4dev-python-venv/bin/python}"
: "${NDT_OWNER:=live-p1}"
export NDT_OWNER

RUN="$HERE/runs/$(date -u '+%Y-%m-%dT%H%M%SZ')_06_thirteen"
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

# 🔴 WHAT "AS EXPECTED" MEANS, per arm, and it is not "rc 0".
#   solution  rc 0. Anything else is the exercise failing on this fabric.
#   skeleton  rc 1 -- the red arm being red. rc 0 means the arm was NOT red, which is the
#             finding; rc 2 means the round never ran and is not evidence either way.
expected_rc() { [[ "$1" == solution ]] && echo 0 || echo 1; }

run_arm() {   # run_arm <exercise> <which>
    local ex="$1" which="$2" log="$RUN/${ex}_${which}.log" rc want verdict report
    say "$ex / $which"
    "$VENV_PY" "$DRIVER" "$ex" --which "$which" --fabric ndtwin > "$log" 2>&1
    rc=$?
    want="$(expected_rc "$which")"
    verdict="$(/usr/bin/grep -m1 '^>>> ' "$log" | sed 's/^>>> //')"
    report="$(/usr/bin/grep -m1 '^report: ' "$log" | sed 's/^report: //')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$ex" "$which" "$rc" "${verdict:-<no verdict line>}" "${report:-<none>}" >> "$TABLE"
    ROWS=$((ROWS+1))
    note "rc=$rc (want $want)   ${verdict:-<no verdict line>}"
    [[ -n "$report" ]] && note "report: $report"
    if [[ "$rc" == "$want" ]]; then
        return 0
    fi
    if [[ "$which" == skeleton && "$rc" == 0 ]]; then
        bad "$ex/skeleton PASSED. The red arm is not red: with the skeleton behaving like the"
        bad "  solution, that exercise's solution arm is not evidence about the solution."
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
    printf 'PASS 06_thirteen -- %d arm(s), every skeleton red and every solution green\n' "$ROWS"
    exit 0
fi
printf 'FAIL 06_thirteen -- %d of %d arm(s) were not what the exercise says they should be\n' "$FAILED" "$ROWS"
exit 1
