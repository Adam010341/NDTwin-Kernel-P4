#!/usr/bin/env bash
#
# Tests for faults.sh's topo_pid -- the replacement for the `pgrep -f` snippet that faults.sh
# used to PRINT AT THE OPERATOR when the tc grant was the wrong shape.  KNOWN-ISSUES G-9.
#
# [Co-developed with claude code -- Adam]
#
# Why an advice string got its own test: the value this produces is handed to `mnexec -a`, which
# runs tc as uid 0 inside whatever namespace that pid is in.  A wrong pid here is not a wrong
# answer, it is root in a stranger's namespace.  `pgrep -f '[t]estbed_topo.py' | head -1` could
# return one three ways -- the bracket trick does not stop the calling SHELL from matching (ndt
# header trap note 2), -f matches a log path or an open editor, and `| head -1` under pipefail is
# the SIGPIPE trap from 2026-08-20.
#
# Safe on a shared machine: read-only, signals nothing, and its fixtures wear
# /nonexistent/NDT-TEST-FIXTURE/... argv0s.  It does need the real ps, so the assertions are
# one-directional -- "the fixture I started is found", "the decoy I started is not" -- which stay
# true however busy the machine is.  The one check that needs an EMPTY machine is skipped when a
# real topology is running, and says so rather than failing.
#
# Run:  bash tests/shell/test_faults_topo_pid.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAULTS="$HERE/../../tools/test_workflow/faults.sh"

PASS=0; FAIL=0; SKIP=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
skip() { echo "  skipped  $1"; SKIP=$((SKIP+1)); }

# shellcheck source=/dev/null
source "$FAULTS" || { echo "  FAILED   could not source $FAULTS"; echo "Ran 1 checks, 1 failed"; exit 1; }

TMPROOT="$(mktemp -d /tmp/faults-topo-pid-XXXXXX)"
FIXTURE_REG="$TMPROOT/fixtures"; : > "$FIXTURE_REG"
FIXTURE_TTL=90
reap() {
    local pid left=0
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || continue
        kill -KILL "$pid" 2>/dev/null
    done < "$FIXTURE_REG"
    sleep 0.3
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] && left=$((left+1))
    done < "$FIXTURE_REG"
    echo "$left"
}
cleanup() {
    [[ -f "$FIXTURE_REG" ]] && reap >/dev/null
    [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/faults-topo-pid-* ]] && rm -rf "$TMPROOT"
    return 0
}
trap cleanup EXIT INT TERM

spawn() {
    local want="$1" pid i; local -a argv=()
    ( exec -a "$want" sleep "$FIXTURE_TTL" ) >/dev/null 2>&1 </dev/null &
    pid=$!; echo "$pid" >> "$FIXTURE_REG"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        argv=(); mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null
        [[ "${argv[0]:-}" == "$want" ]] && { echo "$pid"; return 0; }
        sleep 0.1
    done
    echo "  FAILED   fixture never took argv0=$want" >&2; exit 1
}

SCRIPT=NDT-TEST-FIXTURE-topo.py
FIXP="/nonexistent/NDT-TEST-FIXTURE/$SCRIPT"
DECOYP="/nonexistent/NDT-TEST-FIXTURE/tail-of-$SCRIPT.log"

echo "topo_pid (the value that gets handed to 'mnexec -a')"

# Nothing running under that name: must print nothing AND fail, so `$(topo_pid)` cannot expand to
# an empty string that then makes `mnexec -a  tc` run against pid 0 / argument-shift garbage.
out="$(topo_pid "$SCRIPT" 2>/dev/null)"; rc=$?
if [[ -z "$out" ]]; then
    check "nothing running -> rc 1"              1 "$rc"
    check "  and it prints nothing"              "" "$out"
else
    skip "nothing running (something already matches $SCRIPT on this machine)"
fi

FIX="$(spawn "$FIXP")"
out="$(topo_pid "$SCRIPT" 2>/dev/null)"; rc=$?
check "one topology -> rc 0"                     0 "$rc"
check "  and it is the right pid"                "$FIX" "$out"

DECOY="$(spawn "$DECOYP")"
out="$(topo_pid "$SCRIPT" 2>/dev/null)"; rc=$?
check "a log file named after it is not it"      "$FIX" "$out"
check "  still rc 0"                             0 "$rc"

# Two of them is the case where guessing is worst: `| head -1` silently picked one, and mnexec
# would have run tc as root in whichever namespace won the race.
FIX2="$(spawn "$FIXP")"
out="$(topo_pid "$SCRIPT" 2>/dev/null)"; rc=$?
check "two topologies -> refuses, rc 1"          1 "$rc"
check "  and prints no pid at all"               "" "$out"
err_out="$(topo_pid "$SCRIPT" 2>&1 >/dev/null)"
check "  and says why"                           yes "$(case "$err_out" in *"more than one"*) echo yes ;; *) echo no ;; esac)"

# The red line is about what this file DOES and what it TELLS PEOPLE TO DO. Quoting the bad
# form inside an explanation is how the rule gets taught -- CLAUDE.md itself contains the string
# -- so the assertion is about executable lines and about output, not about the characters
# appearing anywhere in the file.
#
# 🔴 B12 (2026-09-11). Until today these two checks were
#
#     grep -n 'pgrep -f' "$FAULTS" | grep -vc '^[0-9]*:[[:space:]]*#'
#     grep -E '^[[:space:]]*(err|say|echo|printf)' "$FAULTS" | grep -c 'pgrep'
#
# and hunt-0911/F-B0-B12-REPORT.md §3.1 rows (3)b..(3)e put four inputs through them and got 0 out
# of every one: `pgrep --full`, `pgrep` with TWO SPACES before -f, `pkill -f`, and the same advice
# string printed by `warn` instead of `err`. What was guarded was the string `pgrep -f`, spelled
# that way, on a line whose first word is one of four; what is meant to be guarded is "find or
# signal a process by its name". They also read ONE hard-coded path, while
# tools/test_workflow/run_layers.sh has been looking a process up by name the whole time.
#
# The rule now lives in tests/shell/check_process_by_name.py -- it needs to know what is a comment,
# what is a single-quoted mutation anchor and what is a heredoc body, and that is not a grep. The
# cases below put the four escapes to it on SYNTHETIC files, next to the controls that say the
# instrument can tell the difference.
# 🔴 Not "$HERE": sourcing faults.sh above rebound HERE to tools/test_workflow. BASH_SOURCE[0]
# is still this file, so this is the one spelling that survives the source.
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
BY_NAME="$SUITE_DIR/check_process_by_name.py"
[[ -f "$BY_NAME" ]] || { echo "  FAILED   no checker at $BY_NAME"; exit 2; }

# by_name <RUNS|TEACHES> <text> -- how many sites of that kind the checker finds in that script.
# The two kinds are scored SEPARATELY, the way F-B0-B12-REPORT.md §3.1 scored the two pipelines
# these replace: summing them hides (3)e, whose whole point is that pipeline 1 saw the string and
# pipeline 2 -- the one that owns "anything it prints" -- did not.
by_name() {
    local f="$TMPROOT/by_name_case.sh"
    printf '%s' "$2" > "$f"
    # Only the SITE lines: the verdict lines carry the kind word too, and counting those turned
    # every "1" below into a "2".
    python3 "$BY_NAME" "$f" 2>/dev/null | grep -cE "^.+:[0-9]+: +$1( |$)" || true
}

echo "a name-based lookup is caught however it is spelled"
# (3)a: the one spelling the old pipelines did catch. Here so that a zero below means "not
# present" rather than "the instrument is broken".
check "control: pgrep -f in a substitution"      1 "$(by_name RUNS '#!/usr/bin/env bash
p="$(pgrep -f ndtwin_kernel)"
')"
check "(3)b --full instead of -f"                1 "$(by_name RUNS '#!/usr/bin/env bash
pgrep --full ndtwin_kernel
')"
check "(3)c two spaces before -f"                1 "$(by_name RUNS '#!/usr/bin/env bash
pgrep  -f ndtwin_kernel
')"
check "(3)d pkill instead of pgrep"              1 "$(by_name RUNS '#!/usr/bin/env bash
pkill -f ndtwin_kernel
')"
check "-x is still by name"                      1 "$(by_name RUNS '#!/usr/bin/env bash
pids="$(pgrep -x ndtwin_kernel 2>/dev/null)"
')"
check "killall"                                  1 "$(by_name RUNS '#!/usr/bin/env bash
killall ndtwin_kernel
')"
check "pidof"                                    1 "$(by_name RUNS '#!/usr/bin/env bash
pidof ndtwin_kernel
')"
check "ps read for a name, not for a pid"        1 "$(by_name RUNS '#!/usr/bin/env bash
pids=$(ps -eo pid=,comm= | awk "\$2==\"iperf3\"{print \$1}")
')"

echo "and so is the advice, whoever prints it"
check "control: printed by echo"                 1 "$(by_name TEACHES '#!/usr/bin/env bash
echo "try pgrep -f ndtwin_kernel"
')"
check "(3)e printed by warn, not err"            1 "$(by_name TEACHES '#!/usr/bin/env bash
warn "try pgrep -f ndtwin_kernel"
')"

# 🔴 The other half, and the reason this cannot be a grep: this tree TEACHES the rule by quoting
# what it forbids. A checker that reported these would report its own instrument first.
echo "quoting the forbidden form is not doing it"
check "a comment is not an executable line"      0 "$(by_name RUNS '#!/usr/bin/env bash
# never pgrep -f anything; use the pid
true
')"
check "  nor something it prints"                0 "$(by_name TEACHES '#!/usr/bin/env bash
# never pgrep -f anything; use the pid
true
')"
check "a single-quoted anchor is data"           0 "$(by_name RUNS '#!/usr/bin/env bash
mutant m6 '"'"'pids=$(pgrep -f iperf3)'"'"' >/dev/null
')"
check "a heredoc body belongs to its own file"   0 "$(by_name TEACHES '#!/usr/bin/env bash
cat > "$out" <<'"'"'PAIR'"'"'
err "  use $(pgrep -f topo.py | head -1)"
PAIR
')"
check "ps read for a pid is not by name"         0 "$(by_name RUNS '#!/usr/bin/env bash
ps -o etimes= -p "$pid"
')"

echo "the advice strings no longer teach pgrep -f"
check "no pgrep -f on an executable line"        0 \
    "$(python3 "$BY_NAME" "$FAULTS" 2>/dev/null | grep -c 'RUNS' || true)"
check "no pgrep -f inside anything it prints"    0 \
    "$(python3 "$BY_NAME" "$FAULTS" 2>/dev/null | grep -c 'TEACHES' || true)"

# 🔴 And the surface, which was one path. tools/test_workflow/*.sh + tests/shell/*.sh, minus the
# four files whose subject IS this rule. Every site the widened scan finds is REGISTERED in the
# checker with the reason it is still there -- product code is out of scope for the ticket that
# widened this -- and the verdict compares found against registered IN BOTH DIRECTIONS, so a new
# site is red and a registered site someone has fixed is red too.
echo "the whole scan surface, not one hard-coded path"
scan_out="$(cd "$REPO_ROOT" && python3 tests/shell/check_process_by_name.py 2>&1)"; scan_rc=$?
check "no unregistered name-based site"          0 "$scan_rc"
check "  and it looked at more than one file"    yes \
    "$(case "$scan_out" in *" file(s) scanned"*) echo yes ;; *) echo no ;; esac)"
printf '%s\n' "$scan_out" | sed 's/^/           | /'

echo "the suite reaps its own fixtures"
check "no fixture survives this run"             0 "$(reap)"

echo
if (( FAIL > 0 )); then echo "Ran $((PASS+FAIL)) checks, $FAIL failed${SKIP:+ ($SKIP skipped)}"; exit 1; fi
echo "Ran $((PASS+FAIL)) checks, all passed${SKIP:+ ($SKIP skipped)}"
