#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_apps_residue.sh and tests/python/test_app_residue_rules.py
# (KNOWN-ISSUES G-12, W16).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of G-12 -- an app that took a lock, installed a rule and was
# killed by pid, over which `ndt apps orphans` answered `ok  no untracked app processes` rc 0 --
# or one of the wrong answers "print the residue" invites, and must turn its NAMED case red.
#
# 🔴 Two directions. The mutations marked (widening) stay GREEN where the suites require RED: one
# lists every rule in the table, burying G-12's single pri-96 entry under the fabric's own
# baseline; one reports an unreadable answer as no residue, which is G-12's failure shape moved
# into the tool that exists to fix it. Both look exactly like a working report.
#
# 🔴 A DELETING mutation is included (M9). Adam's decision was "list, do not delete", and a gate
# that only checks the listing would not notice a later edit that started removing flow entries
# from a reporting verb.
#
# 🔴 BOTH SUITES ARE DRIVEN. The python one owns the rule-selection logic (fake kernel answers,
# no fabric); the shell one owns the wiring and the prose. A mutation is reported against
# whichever suite names it, so a mutation that breaks the logic but not the wiring, or the other
# way round, still has to be caught by something.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and both suites are
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written -- another
# session may be executing it -- and the sha256 line at the bottom says so.
#
# 🔴 A mutant directory carries ports.sh and sudo_surface.sh: ndt sources both from beside
# itself, so a copy without them exits 2 at source time and every case goes red for the wrong
# reason.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness),
#       3 the file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
SH_TEST="$HERE/test_apps_residue.sh"
PY_TEST="$REPO/tests/python/test_app_residue_rules.py"
ROW_TEST="$HERE/test_ndt_status_residue_row.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/apps-residue-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_sh()  { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$SH_TEST" 2>&1; }
run_py()  { NDT_UNDER_TEST="$1/ndt" timeout 600 python3 "$PY_TEST" 2>&1; }
run_row() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$ROW_TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail, $4 = sh|py|row
    local out rc pat
    MUTATIONS=$((MUTATIONS+1))
    if   [[ "${4:-sh}" == py  ]]; then out=$(run_py "$2");  rc=$?; pat="$3"
    elif [[ "${4:-sh}" == row ]]; then out=$(run_row "$2"); rc=$?; pat="FAILED   $3"
    else                               out=$(run_sh "$2");  rc=$?; pat="FAILED   $3"; fi
    if [[ "$rc" -ne 0 ]] && grep -qF "$pat" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran |^FAIL|^ERROR' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$d/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (all three suites must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
run_sh  "$base" | tail -1
run_py  "$base" | tail -1
run_row "$base" | tail -1
run_sh  "$base" >/dev/null 2>&1 || { echo "  shell baseline is RED -- mutations prove nothing"; exit 2; }
run_py  "$base" >/dev/null 2>&1 || { echo "  python baseline is RED -- mutations prove nothing"; exit 2; }
run_row "$base" >/dev/null 2>&1 || { echo "  --check-row baseline is RED -- mutations prove nothing"; exit 2; }
echo

# --- the wiring: G-12 is a report nobody runs -------------------------------------------------

# The measured case exactly: the app was already dead, so `apps stop` had nothing to stop. A
# residue report wired to the "something was stopped" branch prints nothing here.
m=$(mutant m1 "$NDT" \
    '            residue_report $targets' \
    '            :')
report "M1: 'ndt apps stop' stops reporting residue" "$m" \
       "🔴 and the residue is printed anyway"

m=$(mutant m2 "$NDT" \
    '            residue_report $APP_NAMES' \
    '            :')
report "M2: 'ndt apps orphans' stops reporting residue" "$m" \
       "'apps orphans' prints the residue too"

# --- the rules: what is listed, and what is not -----------------------------------------------

# (widening) Every rule in the table is listed. On a 128-host fabric that is thousands of lines
# and G-12's single pri-96 entry is in there somewhere. It satisfies every "is the residue
# listed" case in both suites.
m=$(mutant m3 "$NDT" \
    '                if now - dur < started:
                    continue' \
    '                if False:
                    continue')
report "M3 (widening): every rule in the table is listed" "$m" \
       "test_the_baseline_fabric_is_excluded" py

# The opposite widening: nothing is ever listed. Every "the baseline is excluded" case passes.
m=$(mutant m4 "$NDT" \
    '                inside.append((dpid, pri, head + "  installed %s ago" % _age(dur)))' \
    '                pass')
report "M4 (widening): no rule is ever listed" "$m" \
       "test_a_rule_installed_inside_the_window_is_listed" py

# 🔴 G-12's own shape, moved into the tool that exists to fix it: a rule whose age cannot be read
# is dropped, so the report is shorter, cleaner, and has silently stopped looking.
m=$(mutant m5 "$NDT" \
    '                    unknown.append(head + "  age=UNKNOWN (no usable duration_sec -- it can be"
                                          " placed neither inside nor outside the window)")
                    continue' \
    '                    continue')
report "M5: a rule that cannot be dated is silently dropped" "$m" \
       "test_a_rule_with_no_duration_is_listed_as_unknown_not_dropped" py

# Only the first switch is walked. On the measured fabric the residue was on s2.
m=$(mutant m6 "$NDT" \
    '    for sw in entries or []:' \
    '    for sw in (entries or [])[:1]:')
report "M6: only the first switch is looked at" "$m" \
       "test_every_switch_is_walked_not_just_the_first" py

# --- the locks --------------------------------------------------------------------------------

m=$(mutant m7 "$NDT" \
    '        423) echo "held $(json_field "$body" held_by_lease) $(json_field "$body" retry_after_s)" ;;' \
    '        423) echo "free" ;;')
# Named against 5H, not 5A: groups 5A-5G stub lock_probe out, so this mutation is invisible to
# them. It survived until 5H was written, which is what the gate is for.
report "M7: a 423 is read as a free lock" "$m" \
       "🔴 a 423 is a HELD lock, with the lease it named"

# 🔴 "Could not look" reported as "nothing there" -- the conflation this repository keeps
# finding, here on the only channel that can see a lock at all.
m=$(mutant m8 "$NDT" \
    '        *)   echo "unknown http ${code:-none}" ;;' \
    '        *)   echo "free" ;;')
report "M8: an unanswerable probe is reported as free" "$m" \
       "🔴 any other code is NOT CHECKED, never free"

# --- the decision: list, do not delete --------------------------------------------------------

# 🔴 Adam ruled "列出該 app 的規則、不自動刪". This is the edit that would quietly undo it, and it
# would look like an improvement in a diff.
m=$(mutant m9 "$NDT" \
    '    info "  NOT deleted, and nothing here deletes them."' \
    '    curl -s -X POST http://localhost:8000/ndt/delete_flow_entry >/dev/null 2>&1
    info "  NOT deleted, and nothing here deletes them."')
report "M9: the report starts deleting what it finds" "$m" \
       "test_nothing_in_the_residue_path_deletes_anything" py

# --- the window ------------------------------------------------------------------------------

# No pidfile means no window; defaulting to one attributes the entire flow table to an app that
# may never have written a line of it.
m=$(mutant m10 "$NDT" \
    '    return 1
}

http_get_flow_entries() {' \
    '    echo 0
}

http_get_flow_entries() {')
report "M10: an app with no record gets a window of all time" "$m" \
       "🔴 and refuses to read that as 'left nothing'"

# A kernel that is not answering reported as a clean network -- the sentence 5F exists for.
m=$(mutant m11 "$NDT" \
    '        warn "the kernel is not up (:8000 closed) -- rules and locks CANNOT be checked."
        warn "this is not '\''the lab is clean'\''. it is '\''nobody asked'\''. (KNOWN-ISSUES G-12)"' \
    '        ok "nothing to report"')
report "M11: a kernel that is down is reported as nothing to report" "$m" \
       "it says rules and locks cannot be checked"

# 🔴 The plumbing bug this code was actually written with, kept as a mutation because it produced
# a perfectly clean-looking report: `python3 - <<'\''PY'\''` puts the SCRIPT on stdin, so reading
# the flow table from sys.stdin reads the end of its own source and answers "unreadable".
m=$(mutant m12 "$NDT" \
    '    python3 - "$1" "$2" "${3:-unknown}" "${4:-}" 3<&0 <<'\''PY'\''' \
    '    python3 - "$1" "$2" "${3:-unknown}" "${4:-}" <<'\''PY'\''')
report "M12: the flow table is read from the heredoc, not the pipe" "$m" \
       "🔴 the rule installed during the app's window"

# 🔴 And the defect the shell suite caught on 2026-09-06: rebinding the function's own positional
# parameters from inside the lock loop, so the first HELD lock replaced the app list.
m=$(mutant m13 "$NDT" \
    '                read -r _ lease retry <<<"$lock"' \
    '                set -- $lock; lease="${2:-}"; retry="${3:-}"')
report "M13: the lock loop rebinds the app list" "$m" \
       "  and the rule it left"

# --- W16-1: the exit code Adam ruled into existence on 09-06 -----------------------------------
#
# 🔴 The recommendation had been to leave `orphans`' rc meaning "processes" so the gates that
# read it kept working. Adam ruled the other way, and these are the edits that would quietly
# put the old behaviour back -- each of them looks like a tidy-up in a diff.

m=$(mutant m14 "$NDT" \
    '            residue_verdict; local rrc=$?' \
    '            local rrc=0')
report "M14: 'apps orphans' stops taking its code from the residue" "$m" \
       "🔴 a held lock and a rule in the window -> rc 4, not 0"

# (widening) Everything is residue, so the verb is red on every P4 fabric and on every machine
# where an app was never started. It satisfies every "goes red" case and destroys the gate.
m=$(mutant m15 "$NDT" \
    '    (( RESIDUE_UNDATABLE > 0 || RESIDUE_BLIND > 0 )) && return 5' \
    '    (( RESIDUE_UNDATABLE > 0 || RESIDUE_BLIND > 0 )) && return 4')
report "M15 (widening): 'could not check' is reported as residue" "$m" \
       "🔴 undatable is rc 5 (NOT CHECKED), never rc 4 (residue)"

# The opposite widening: nothing is ever a blind spot, so a machine whose window records are
# gone reports a clean network it never looked at -- G-12's own shape.
m=$(mutant m16 "$NDT" \
    '                warn "      not absent. rules it installed cannot be found by this tool."
                RESIDUE_BLIND=$(( RESIDUE_BLIND + 1 ))' \
    '                warn "      not absent. rules it installed cannot be found by this tool."')
report "M16: a lost window is not counted against the code" "$m" \
       "🔴 and that is rc 5 -- not checked, not clean"

# ...and the other direction: an app that was never started counts as a blind spot, so the verb
# answers 5 on every clean machine. A gate that can never pass is ignored within a day.
m=$(mutant m17 "$NDT" \
    '                info "      (its log is empty or absent too -- no sign it ever ran here)"' \
    '                info "      (its log is empty or absent too -- no sign it ever ran here)"
                RESIDUE_BLIND=$(( RESIDUE_BLIND + 1 ))')
report "M17 (widening): never-started apps count as unchecked" "$m" \
       "🔴 a clean network -> rc 0 (the codes are not always red)"

# --- W16-2: the same question asked by `ndt status --check` ------------------------------------

m=$(mutant m18 "$NDT" \
    '    if [[ -n "$check" ]]; then
        status_residue_row
        (( ${#STATUS_RESIDUE_PROBLEMS[@]} > 0 )) && problems+=("${STATUS_RESIDUE_PROBLEMS[@]}")
    fi' \
    '    :')
report "M18: '--check' stops looking at the network" "$m" \
       "🔴 --check prints a residue row" row

# The residue is printed but not counted -- exactly the state G-12 was measured in, where every
# verb printed something and rc was 0.
m=$(mutant m19 "$NDT" \
    '           STATUS_RESIDUE_PROBLEMS+=("the network carries app residue:' \
    '           : ("the network carries app residue:')
report "M19: --check prints residue and still exits 0" "$m" \
       "🔴 and --check exits 1 (it exited 0 over this on 09-05)" row

# (widening) --check is red on "could not check" too. Permanently red on every healthy P4
# fabric, where doc/2026-08-17_testing-manual.md:279 makes rc 0 the acceptance criterion.
m=$(mutant m20 "$NDT" \
    '           printf '\''  %-14s %s\n'\'' "" "the locks WERE checked: $RESIDUE_LOCKS held.  details:  ndt apps orphans" ;;' \
    '           STATUS_RESIDUE_PROBLEMS+=("the residue could not be checked") ;;')
report "M20 (widening): --check goes red on 'could not check'" "$m" \
       "🔴 but a healthy P4 fabric still passes: rc 0" row

# (widening) The scan moves into plain `ndt status`: a flow-table GET and three acquire POSTs on
# a page sessions read dozens of times an hour, and three lock probes each one of which is a
# write to the kernel.
m=$(mutant m21 "$NDT" \
    '    if [[ -n "$check" ]]; then
        status_residue_row' \
    '    if true; then
        status_residue_row')
report "M21 (widening): plain 'ndt status' pays for the scan" "$m" \
       "🔴 and the flow table is not fetched at all" row

# --- W16-3: the plane with no clock ------------------------------------------------------------
#
# 🔴 Measured 2026-09-07 (DECISIONS 09-07 01:0x). Every P4 flow entry answers duration 0/0.
# Read as an age that is "installed just now", which places the WHOLE TABLE inside every window.

m=$(mutant m22 "$NDT" \
    '                if blind:
                    unknown.append(head + "  age=UNKNOWN (P4 plane: synthesised flow stats"
                                          " carry no install time)")
                    continue
                if _no_time_axis(f):
                    unknown.append(head + "  age=UNKNOWN (duration_sec=0 AND duration_nsec=0:"
                                          " a synthesised counter, not a rule installed now)")
                    continue' \
    '                if False:
                    continue')
report "M22: a duration of 0 is read as '0 seconds ago'" "$m" \
       "test_on_p4_every_rule_is_unknown_however_old_it_claims_to_be" py

# Only the data-driven half: a table that says 0/0 through a path that never named the plane.
m=$(mutant m23 "$NDT" \
    '    dur, nsec = f.get("duration_sec"), f.get("duration_nsec")' \
    '    return False
    dur, nsec = f.get("duration_sec"), f.get("duration_nsec")')
report "M23: 0/0 is believed when the plane is not named" "$m" \
       "test_duration_zero_and_nsec_zero_is_unknown_not_zero_seconds_ago" py

# (widening) duration_nsec is ignored, so a genuine sub-second install becomes UNKNOWN too and
# every OVS table with one fresh rule in it is reported as unwindowable.
m=$(mutant m24 "$NDT" \
    '    return not (isinstance(nsec, int) and not isinstance(nsec, bool) and nsec > 0)' \
    '    return True')
report "M24 (widening): a real just-installed rule is called undatable" "$m" \
       "test_a_genuinely_sub_second_rule_is_still_dated" py

# The plane is read but never handed over -- the "the fix is in the file and nothing calls it"
# shape. Every python case stays green; only the shipped tool is blind.
m=$(mutant m25 "$NDT" \
    '        done < <(printf '\''%s'\'' "$entries" | residue_rule_lines "$started" "$now" "$plane" "$wend")' \
    '        done < <(printf '\''%s'\'' "$entries" | residue_rule_lines "$started" "$now")')
report "M25: the plane never reaches the selector" "$m" \
       "🔴 but with age UNKNOWN, not an age"

# The blindness is not announced: the reader sees a list of UNKNOWN rules and no reason.
m=$(mutant m26 "$NDT" \
    '    print("CANNOTWINDOW " + blind)' \
    '    pass')
report "M26: the plane's blindness is never announced" "$m" \
       "🔴 it says the plane cannot be windowed"

# --- H2: what of the STACK is up (ROLE-2, 2026-09-11) -----------------------------------------

# M20 restores H2: `apps orphans` says nothing about the kernel, the fabric or the proxy, so a
# reader of its report calls a half-up stack clean -- which is what happened three times on
# 09-11 (a kernel serving a graph of a fabric that was gone; a fabric with no kernel).
m=$(mutant m27 "$NDT" \
    '            say "stack"
            stack_report' \
    '            :')
report "M27: 'apps orphans' says nothing about the stack (H2)" "$m" \
       "🔴 the stack line is printed"

# M21: the halves are read and never compared, so the line is facts with no verdict word -- and
# the reader that parses `verdict=` gets nothing.
m=$(mutant m28 "$NDT" \
    '    if [[ "$kernel" == up && "$dp" == none ]]; then verdict=HALF' \
    '    if false; then verdict=HALF')
report "M28: a control plane with no data plane is not HALF" "$m" \
       "🔴 and the verdict word a reader can parse"

# M22: the other half of the disagreement -- a fabric with no kernel.
m=$(mutant m29 "$NDT" \
    '    elif [[ "$kernel" == down && "$dp" != none ]]; then verdict=HALF' \
    '    elif false; then verdict=HALF')
report "M29: a data plane with no kernel is not HALF" "$m" \
       "🔴 a fabric with no kernel is HALF too"

# M23 (widening): everything that is up is HALF. Every cell above passes; the CONTROL is what
# catches it, and without that control this line would make every mid-round check a failure.
m=$(mutant m30 "$NDT" \
    '    elif [[ "$kernel" == up ]]; then verdict=whole-up' \
    '    elif [[ "$kernel" == up ]]; then verdict=HALF')
report "M30 (widening): a healthy fabric is called HALF" "$m" \
       "🔴 a healthy P4 fabric is whole-up, not HALF"


echo
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/ndt was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/ndt  sha256 $BASE_NDT"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
