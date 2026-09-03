#!/usr/bin/env bash
#
# Which testbed_topo.py `ndt up ovs` actually launches -- finding #77.
#
# [Co-developed with claude code -- Adam]
#
# The defect: `ovs-topo-start` started /home/adam/Network-Traffic-Generator/testbed_topo.py, a
# file in ANOTHER REPO, while components.env:80 (OVS_TOPO_SCRIPT) and stack.sh:775 both name
# THIS repo's copy -- so the path the manual tells an operator to run and the path `ndt up ovs`
# runs were two different files. Finding #42 then fixed this repo's copy so its closing banner is
# derived from the ping self-test, and an operator running `ndt up ovs` still saw NTG's constant
# "Host internet: OK | sFlow reachability: OK | Switch identification: OK". Adam decided
# 2026-09-03 (N13): ndt's paths run this repo's copy; NTG is not modified.
#
# 🔑 WHY THIS SUITE EXERCISES RATHER THAN GREPS. A grep for the NTG path is exactly the test that
#    would have passed on 2026-09-03 while the bug was live -- the string was in the file, in a
#    comment as well as in the launch, and no assertion connected either to what root was handed.
#    So `ovs_topo_start` is CALLED here, with $TMUX replaced by a recorder, and the checks read
#    back the argv that tmux would have received. The recorder is the only stub: KERNEL_DIR,
#    NTG_PY, the config loader, the sweep and the script on disk are all the real ones.
#
# 🔴 The half that is easy to miss is the SWEEP. `cleanup` finds this process by PATH SUFFIX
#    ("<tree>/testbed_topo.py"), so changing which file runs changes which suffix identifies it;
#    a fix that stopped there would leave `ndt down` reporting a clean machine over a live
#    128-host fabric. Section 4 spawns a real process wearing the launched command line and makes
#    the sweep find it -- and pins that the OLD pattern does not, which is the regression that
#    would otherwise have been silent.
#
# Run:  bash tests/shell/test_ndt_ovs_topo_script.sh
#       NDTWIN_LAB_UNDER_TEST=<copy> bash tests/shell/test_ndt_ovs_topo_script.sh   (gate)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LAB="${NDTWIN_LAB_UNDER_TEST:-$REPO/tools/test_workflow/ndtwin-lab}"
[[ -r "$LAB" ]] || { echo "no ndtwin-lab at $LAB"; echo "Ran 1 checks, 1 failed"; exit 2; }

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }
yn()  { if "$@"; then echo yes; else echo no; fi; }
summary() { printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"; }

# Sourced, not executed: ndtwin-lab returns before its root guard and before its dispatch, so a
# non-root test gets the functions and no verb can fire.
# shellcheck source=/dev/null
source "$LAB" || { echo "  FAILED   could not source $LAB"; echo "Ran 1 checks, 1 failed"; exit 1; }
# Sourcing turns on errexit. A suite whose subject includes a deliberate refusal cannot run under
# it: the first `die` would end the run while every check already printed still reads ok.
set +e

# The seam itself is the first check, and it is a check rather than a bail-out because its
# absence IS the finding: with the launch written inline in the root-only dispatch, nothing short
# of root can see which file tmux is handed, and that is how the NTG path survived here.
echo "the launch is reachable at all"
for fn in ovs_topo_script ovs_topo_pattern ovs_topo_start; do
    check "ndtwin-lab defines $fn" defined \
        "$(declare -F "$fn" >/dev/null && echo defined || echo 'not defined -- the launch is inline in the root-only dispatch')"
done
for fn in sweep_matches sweep_count; do
    check "  and still defines $fn (the sweep)" defined \
        "$(declare -F "$fn" >/dev/null && echo defined || echo 'not defined')"
done
if ! declare -F ovs_topo_start >/dev/null; then
    echo "  ... the remaining sections need ovs_topo_start and cannot run"
    summary; exit 1
fi

TMPROOT="$(mktemp -d /tmp/ndt-ovs-topo-XXXXXX)"
FIXTURE_REG="$TMPROOT/fixtures"; : > "$FIXTURE_REG"
cleanup_all() {
    local pid
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] && kill -KILL "$pid" 2>/dev/null
    done < "$FIXTURE_REG"
    [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-ovs-topo-* ]] && rm -rf "$TMPROOT"
    return 0
}
trap cleanup_all EXIT INT TERM

# --- the recorder -------------------------------------------------------------------------
#
# $TMUX is used unquoted in ndtwin-lab (it is "tmux -L ndtwinlab", two words), so replacing it
# with one path is enough. Every argument lands in $REC_LOG, NUL-separated, so an argument
# containing a space cannot be read back as two.
REC="$TMPROOT/rec-tmux"
REC_LOG="$TMPROOT/tmux.argv"
# Absolute shebang, not `/usr/bin/env bash`: section 6 empties PATH inside its subshell, and
# `env bash` would then fail to find bash and record nothing -- a stub that silently stops
# recording turns every check that reads it into a green-for-the-wrong-reason.
cat > "$REC" <<'REC_EOF'
#!/bin/bash
printf '%s\0' "$@" >> "$REC_LOG"
printf '\036' >> "$REC_LOG"
REC_EOF
chmod 755 "$REC"
export REC_LOG

rec_reset() { : > "$REC_LOG"; }
rec_calls() { tr -cd '\036' < "$REC_LOG" | wc -c; }        # how many times tmux was invoked
rec_argv()  {                                              # the recorded argv, one per line
    tr '\0' '\n' < "$REC_LOG" | tr -d '\036'
}
rec_arg_after() {                                          # the argv element following <flag>
    local flag="$1" prev="" line
    while IFS= read -r line; do
        [[ "$prev" == "$flag" ]] && { printf '%s' "$line"; return 0; }
        prev="$line"
    done < <(rec_argv)
    return 1
}
rec_last() { rec_argv | grep -v '^$' | tail -1; }

TMUX="$REC"

# --- 1. what the launch hands root ---------------------------------------------------------
echo "what \`ndt up ovs\` launches"

rec_reset
out="$(ovs_topo_start 2>&1)"; rc=$?

check "the launch succeeds"                        0 "$rc"
check "🔴 it really launched something"            1 "$(rec_calls)"
check "the topology comes from the kernel tree"    "$KERNEL_DIR/testbed_topo.py" "$(rec_last)"
check "  and that file exists on disk"             yes "$([[ -r "$KERNEL_DIR/testbed_topo.py" ]] && echo yes || echo no)"
check "the interpreter is the lab's NTG_PY"        "$NTG_PY" "$(rec_argv | grep -v '^$' | tail -2 | head -1)"
check "tmux's working directory is the tree"       "$KERNEL_DIR" "$(rec_arg_after -c)"
check "it is still the 'topo' session"             topo "$(rec_arg_after -s)"
check "🔴 nothing in the launch names the NTG tree" no "$(has Network-Traffic-Generator "$(rec_argv)")"
check "it says which file it started"              yes "$(has "$KERNEL_DIR/testbed_topo.py" "$out")"

# --- 2. the tree is derived, not a second constant -----------------------------------------
#
# A fix that swapped one hard-coded absolute path for another would pass every check above. This
# is what says the launched file follows KERNEL_DIR, i.e. follows an install-time config file
# (G-7) -- the property FINDING-01 cost a whole round for lacking.
echo "the tree the config chose is the tree that runs"

ALT="$TMPROOT/alt-tree"; mkdir -p "$ALT"; : > "$ALT/testbed_topo.py"
REAL_KERNEL_DIR="$KERNEL_DIR"
KERNEL_DIR="$ALT"
rec_reset
alt_out="$(ovs_topo_start 2>&1)"; alt_rc=$?
check "a different KERNEL_DIR moves the script"    "$ALT/testbed_topo.py" "$(rec_last)"
check "  and moves the working directory too"      "$ALT" "$(rec_arg_after -c)"
check "  and it still starts"                      0 "$alt_rc"
# The PROPERTY, not the spelling: the pattern has to name the file that was just launched and
# must not name some other tree's. Asserting the literal string here would pin one implementation
# and call any equivalent one a regression.
check "  and the sweep pattern moves with it"      yes "$(yn sweep_matches "$(ovs_topo_pattern)" "$NTG_PY" "$ALT/testbed_topo.py")"
check "  and does not name another tree's copy"    no  "$(yn sweep_matches "$(ovs_topo_pattern)" "$NTG_PY" /nonexistent/NDT-TEST-FIXTURE/other/testbed_topo.py)"

# ...and pointed at THIS checkout it launches THIS checkout's file. That is the sentence finding
# #77 is about, and it is the one an operator cares about: `ndt up ovs` runs the repo copy, the
# same file components.env calls OVS_TOPO_SCRIPT and stack.sh prints.
KERNEL_DIR="$REPO"
rec_reset
ovs_topo_start >/dev/null 2>&1
check "pointed here, it launches this repo's copy" "$REPO/testbed_topo.py" "$(rec_last)"
KERNEL_DIR="$REAL_KERNEL_DIR"

# --- 3. a topology that is not there is refused, not started --------------------------------
#
# Without this, a missing file makes tmux's window exit instantly, `ovs-topo-start` still prints
# "started", and `ndt up ovs` waits 300 s for a fabric nobody is building.
echo "🔴 a missing topology refuses instead of starting an empty window"

EMPTY="$TMPROOT/empty-tree"; mkdir -p "$EMPTY"
rec_reset
miss_err="$( ( KERNEL_DIR="$EMPTY"; ovs_topo_start ) 2>&1 >/dev/null )"
miss_rc="$( ( KERNEL_DIR="$EMPTY"; ovs_topo_start ) >/dev/null 2>&1; echo $? )"
check "rc is non-zero"                             1 "$([[ "$miss_rc" -ne 0 ]] && echo 1 || echo 0)"
check "  and the message names the missing file"   yes "$(has "$EMPTY/testbed_topo.py" "$miss_err")"
check "  and nothing was launched"                 0 "$(rec_calls)"

# --- 4. the sweep still finds what the launch starts ----------------------------------------
#
# `ndt down` -> `ndtwin-lab cleanup` -> sweep_kill, and sweep_matches decides identity by path
# suffix. This section is the reason the fix is two changes and not one.
echo "the sweep still finds what the launch starts (ndt down)"

rec_reset; ovs_topo_start >/dev/null 2>&1
mapfile -t LAUNCHED < <(rec_argv | grep -v '^$')
LAUNCHED_SCRIPT="$(rec_last)"

check "cleanup's pattern matches the launched argv" yes "$(yn sweep_matches "$(ovs_topo_pattern)" "${LAUNCHED[@]}")"
check "🔴 the OLD NTG pattern does not match it"    no  "$(yn sweep_matches "Network-Traffic-Generator/testbed_topo.py" "${LAUNCHED[@]}")"
check "the NTG pattern still finds an NTG orphan"   yes "$(yn sweep_matches "Network-Traffic-Generator/testbed_topo.py" python /home/adam/Network-Traffic-Generator/testbed_topo.py)"
check "another tree's testbed_topo.py is not it"    no  "$(yn sweep_matches "$(ovs_topo_pattern)" python /nonexistent/NDT-TEST-FIXTURE/other/testbed_topo.py)"
check "a mention of it is still not a process"      no  "$(yn sweep_matches "$(ovs_topo_pattern)" bash -c "echo restarting $LAUNCHED_SCRIPT now")"

# A real process wearing the launched command line: the sweep has to find THAT, not a string.
( exec -a "$LAUNCHED_SCRIPT" sleep 120 ) >/dev/null 2>&1 </dev/null &
fix_pid=$!
disown "$fix_pid" 2>/dev/null
echo "$fix_pid" >> "$FIXTURE_REG"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(tr '\0' '\n' < "/proc/$fix_pid/cmdline" 2>/dev/null | head -1)" == "$LAUNCHED_SCRIPT" ]] && break
    sleep 0.1
done
check "a live process with that command line is found" 1 "$(sweep_count "$(ovs_topo_pattern)")"
check "🔴 sweeping the old pattern alone is blind to it" 0 "$(sweep_count "Network-Traffic-Generator/testbed_topo.py")"
kill -KILL "$fix_pid" 2>/dev/null; sleep 0.3
check "  and it is gone once reaped"               0 "$(sweep_count "$(ovs_topo_pattern)")"

# --- 5. the launched file is one the launching interpreter can actually run ------------------
#
# The two `sys.path.append` lines this repo's copy lost when it was imported. Without them the
# launch above is a command line that dies at its first import, which no argv check can see.
#
# Guarded, and the guard says so: mininet is a system package, and on a machine without it this
# check cannot mean anything. It is not silently skipped -- a machine that HAS mininet runs it.
echo "the file it launches is one that interpreter can run"

PY_UNDER_TEST=""
for cand in "$NTG_PY" /usr/bin/python3 python3; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c "import sys; sys.path.append('/usr/lib/python3/dist-packages'); import mininet" >/dev/null 2>&1; then
        PY_UNDER_TEST="$cand"; break
    fi
done
if [[ -z "$PY_UNDER_TEST" ]]; then
    echo "  n/a      no interpreter on this machine can import mininet at all -- 2 checks not run"
else
    imp_rc="$("$PY_UNDER_TEST" - "$REPO/testbed_topo.py" <<'PY' >/dev/null 2>&1; echo $?
import importlib.util, sys
spec = importlib.util.spec_from_file_location("topo_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
PY
)"
    check "it imports under $PY_UNDER_TEST"        0 "$imp_rc"

    # ...and it is the file finding #42 fixed: the banner is derived, and says NOT MEASURED for
    # the two claims nothing in it tests. NTG's copy has neither symbol.
    banner="$("$PY_UNDER_TEST" - "$REPO/testbed_topo.py" 2>/dev/null <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("topo_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
s = mod.PingSummary(expected=4, attempted=4, distinct=4, replied=4, lost=0, unreadable=0,
                    loss_pct=0.0)
print("\n".join(mod.banner_lines(s)))
PY
)"
    check "  and its banner is finding #42's, not the constant one" yes \
        "$([[ "$(has 'NOT MEASURED' "$banner")" == yes && "$(has '4/4 pings replied' "$banner")" == yes ]] && echo yes || echo no)"
fi

# --- 6. the verbs are wired to what was tested ---------------------------------------------
#
# 🔑 Everything above tests the FUNCTIONS. The dispatch that root actually reaches is a `case`
#    below a root guard, so a verb could stop calling any of it and every check above would stay
#    green -- "existence is not wiring", and that is the exact shape finding #77 had.
#
# So the two branches are EXECUTED here, extracted from the file under test and evaluated with
# the recorder in place. Not grepped: the body runs, and what it does is what is read back.
#
# Seatbelt, because this evaluates code that is meant to run as root: PATH is emptied inside the
# subshell, so anything not stubbed as a shell function cannot be found at all (`mn -c` and the
# manifest `rm` in the cleanup branch are both external). A future edit that adds a destructive
# command here fails with 127 rather than running.
echo "the verbs are wired to what was tested"

NOBIN="$TMPROOT/nobin"; mkdir -p "$NOBIN"

branch_body() {   # <verb> -- the lines of that case branch, without its label and its ;;
    awk -v v="    $1)" '$0 == v {inb=1; next} inb && $0 == "        ;;" {exit} inb {print}' "$LAB"
}

start_body="$(branch_body ovs-topo-start)"
clean_body="$(branch_body cleanup)"
check "the ovs-topo-start branch was found"        yes "$([[ $(grep -c . <<<"$start_body") -ge 2 ]] && echo yes || echo no)"
check "the cleanup branch was found"               yes "$([[ $(grep -c . <<<"$clean_body") -ge 3 ]] && echo yes || echo no)"

rec_reset
(
    PATH="$NOBIN"
    session_running() { return 1; }
    eval "$start_body"
) >/dev/null 2>&1
check "the ovs-topo-start branch launches that file" "$KERNEL_DIR/testbed_topo.py" "$(rec_last)"
check "  and hands it to NTG_PY"                   "$NTG_PY" "$(rec_argv | grep -v '^$' | tail -2 | head -1)"
check "  🔴 and names no file in the NTG tree"     no "$(has Network-Traffic-Generator "$(rec_argv)")"

# The cleanup branch, with sweep_kill replaced by a recorder of the patterns it is asked to sweep.
swept="$(
    PATH="$NOBIN"
    sweep_kill() { printf '%s\n' "$2"; return 0; }
    # The 127s are the seatbelt firing: `mn -c` and the manifest `rm` are external and PATH is
    # empty, which is the intended outcome and not a failure of this check.
    eval "$clean_body" 2>/dev/null
    true
)"
check "cleanup sweeps the pattern the launch uses" yes "$(has "$(ovs_topo_pattern)" "$swept")"
check "  and still sweeps the NTG suffix (orphans)" yes "$(has "Network-Traffic-Generator/testbed_topo.py" "$swept")"
check "  and has not lost the bmv2 sweeps"         yes \
    "$([[ "$(has ntg_bmv2_topo.py "$swept")" == yes && "$(has simple_switch_grpc "$swept")" == yes ]] && echo yes || echo no)"

summary
[[ $FAIL -eq 0 ]]
