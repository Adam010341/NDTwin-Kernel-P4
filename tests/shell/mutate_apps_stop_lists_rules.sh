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
BK=$(mktemp -d "${TMPDIR:-/tmp}/apps-residue-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_sh() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$SH_TEST" 2>&1; }
run_py() { NDT_UNDER_TEST="$1/ndt" timeout 600 python3 "$PY_TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail, $4 = sh|py
    local out rc pat
    MUTATIONS=$((MUTATIONS+1))
    if [[ "${4:-sh}" == py ]]; then out=$(run_py "$2"); rc=$?; pat="$3"
    else                            out=$(run_sh "$2"); rc=$?; pat="FAILED   $3"; fi
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

echo "baseline (both suites must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
run_sh "$base" | tail -1
run_py "$base" | tail -1
run_sh "$base" >/dev/null 2>&1 || { echo "  shell baseline is RED -- mutations prove nothing"; exit 2; }
run_py "$base" >/dev/null 2>&1 || { echo "  python baseline is RED -- mutations prove nothing"; exit 2; }
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
    '    python3 - "$1" "$2" 3<&0 <<'\''PY'\''' \
    '    python3 - "$1" "$2" <<'\''PY'\''')
report "M12: the flow table is read from the heredoc, not the pipe" "$m" \
       "🔴 the rule installed during the app's window"

# 🔴 And the defect the shell suite caught on 2026-09-06: rebinding the function's own positional
# parameters from inside the lock loop, so the first HELD lock replaced the app list.
m=$(mutant m13 "$NDT" \
    '                read -r _ lease retry <<<"$lock"' \
    '                set -- $lock; lease="${2:-}"; retry="${3:-}"')
report "M13: the lock loop rebinds the app list" "$m" \
       "  and the rule it left"

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
