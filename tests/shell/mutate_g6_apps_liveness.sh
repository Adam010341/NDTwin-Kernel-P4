#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_apps_liveness.sh.  KNOWN-ISSUES G-6.
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration.  This puts each defect back into
# tools/test_workflow/ndt one at a time -- the actual pre-fix text, not an invented mutation --
# runs the suite, and records WHICH NAMED CHECK went red.  "Something failed" is not the verdict:
# two of this project's suites have previously gone red on a mutation aimed at different
# behaviour, so a catch counts only when the check that fails is the one that owns that defect.
#
# 🔴 Guards its own baseline.  The file is snapshotted with `cp -p` before the first mutation, an
# EXIT trap restores it on any exit including Ctrl-C, and the run ends by asserting byte-identity
# against the snapshot.  Baseline is the WORKING TREE, not HEAD, so this runs against an
# uncommitted fix.
#
# 🔴 Never kills anything by name.  No pkill, no pgrep: `timeout` owns the only child, and the
# suite under test reaps its own fixtures and asserts that it did.
#
# 🔴 Touches no lab.  The suite replaces `sudo` and `lab_session` with shell functions, so
# nothing here can reach ndtwin-lab, ask for root, or disturb a claimed testbed.
#
# Usage:  tests/shell/mutate_g6_apps_liveness.sh
#   TEST_TIMEOUT=300   seconds allowed per suite run
#
# Exit: 0 every mutation was caught by the check named for it, and the control survived
#       1 at least one mutation survived, or was caught by the wrong check
#       2 the gate cannot render a verdict (baseline red, anchor drift, hang, failed restore, or
#         the comment-only control going red -- which would mean this gate measures "the file
#         changed" rather than "the behaviour changed")
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
NDT=tools/test_workflow/ndt
SUITE=tests/shell/test_ndt_apps_liveness.sh

if ! bash -n "${BASH_SOURCE[0]}"; then echo "🔴 this script does not parse" >&2; exit 2; fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$NDT" && -f "$SUITE" ]] || { echo "🔴 missing $NDT or $SUITE" >&2; exit 2; }

SNAP="$(mktemp /tmp/mutate-g6-XXXXXX.ndt)"
cp -p "$NDT" "$SNAP"
restore() { cp -p "$SNAP" "$NDT"; }
cleanup() { restore; rm -f "$SNAP"; }
trap cleanup EXIT INT TERM

# --- mutations ------------------------------------------------------------------------
#
# Each is (name, expected-red-check, from, to).  `from` must appear EXACTLY once: an anchor that
# matches twice would mutate a site it was not named for and the verdict would be about the wrong
# code, and an anchor that matches zero times means the source moved under the gate -- "the
# mutation could not be applied" must never be reported as "the mutation was caught".
MUT_DIR="$(mktemp -d /tmp/mutate-g6-cases-XXXXXX)"
cleanup() { restore; rm -f "$SNAP"; rm -rf "$MUT_DIR"; }

write_case() {   # write_case <name> <expected-red-substring> <<'FROM' ... '===' ... TO
    local name="$1" expect="$2"
    mkdir -p "$MUT_DIR/$name"
    printf '%s' "$expect" > "$MUT_DIR/$name/expect"
    cat > "$MUT_DIR/$name/pair"
}
CASES=()

CASES+=(start-reads-request-rc)
# 2026-09-07: re-anchored, and SHORTENED to one line. 3-51 put a comment block and the pidfile
# write BETWEEN the two lines this used to span, so the old two-line anchor matched zero times
# and the gate reported "no verdict" -- the failure mode check_gate_anchors.py exists for.
# The one line left is the one that carries the meaning: `app_wait_started` is the whole
# difference between "the lab accepted the request" and "the program is there". Replacing it
# with the old unconditional `ok` + an early return restores the C26 defect exactly, and leaves
# everything after it as dead code that still parses (a mutant that does not parse is scored as
# a broken mutation, not as a catch).
write_case start-reads-request-rc "start of an app that never came up -> rc 1" <<'PAIR'
            app_wait_started "$name" || return 1
@@@TO@@@
            ok "$name started (tmux: $name)"; return 0
PAIR

CASES+=(stop-unconditional-ok)
write_case stop-unconditional-ok "stop of a never-started lab app -> rc 2" <<'PAIR'
        energy|sim)
            app_probe "$name"
            if [[ "$APP_STATE" == not-running ]]; then
                info "$name not running (no live process carries its signature)"
@@@TO@@@
        energy|sim)
            app_probe "$name"
            if false; then
                info "$name not running (no live process carries its signature)"
PAIR

CASES+=(probe-session-only)
write_case probe-session-only "session up + NO process     -> not-running" <<'PAIR'
            if app_running "$name"; then
                if (( ${#APP_LIVE_PIDS[@]} > 0 )); then
                    APP_STATE=running
                else
@@@TO@@@
            if app_running "$name"; then
                if true; then
                    APP_STATE=running
                else
PAIR

CASES+=(notrunning-rc-zero)
# 2026-09-04: re-anchored. The poisoned-pidfile guard around the `rm -f "$p"` cleanup a few
# lines up added its own if/fi, pushing this branch's body one indent level deeper (20 -> 24
# spaces) and separating `return 2` from the `fi ;;` that used to sit on the same line as it.
# Same two lines, same fix being reverted; only the whitespace and the now-separate `fi ;;`
# changed.
write_case notrunning-rc-zero "stop of a never-started pidfile app -> rc 2" <<'PAIR'
                        (( poisoned == 1 )) && return 1
                        return 2
@@@TO@@@
                        return "$poisoned"
PAIR

CASES+=(aggregate-or-rc1)
write_case aggregate-or-rc1 "nothing was running -> rc 2" <<'PAIR'
            (( n_fail > 0 )) && { err "$n_fail app(s) could not be stopped"; return 1; }
            if (( n_stopped == 0 )); then
                info "nothing to stop ($n_noop app(s) were already not running)"
                return 2
            fi
@@@TO@@@
            (( n_fail + n_noop > 0 )) && return 1
PAIR

# The control. A comment-only edit must NOT turn the suite red; if it does, this gate is
# measuring "the file changed" rather than "the behaviour changed" and every catch above is
# uninterpretable.
CASES+=(control-comment-only)
write_case control-comment-only "" <<'PAIR'
# app_wait_started <name> -- poll until the app is really there; explain it if it is not.
@@@TO@@@
# app_wait_started <name> -- poll until the app is really there; explain it if it is not. (x)
PAIR

apply() {   # apply <name>; echo ok|drift
    python3 - "$NDT" "$MUT_DIR/$1/pair" <<'PYAPPLY'
import sys, pathlib
src, pair = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text()
frm, to = pair.split("@@@TO@@@\n")
frm = frm
s = src.read_text()
n = s.count(frm)
if n != 1:
    print(f"drift {n}"); sys.exit(0)
src.write_text(s.replace(frm, to))
print("ok")
PYAPPLY
}

run_suite() {   # echo "<rc>|<comma separated FAILED check names>"
    local out rc
    out="$(timeout "$TEST_TIMEOUT" bash "$SUITE" 2>&1)"; rc=$?
    printf '%s|%s' "$rc" "$(printf '%s\n' "$out" | sed -n 's/^  FAILED  *//p' | paste -sd, -)"
}

# --- 0. baseline must be green --------------------------------------------------------
echo "=== baseline (the fix, unmutated) ==="
base="$(run_suite)"; base_rc="${base%%|*}"
printf '  rc=%s  red=%s\n' "$base_rc" "${base#*|}"
if [[ "$base_rc" == 124 ]]; then echo "  🔴 baseline HUNG" >&2; exit 2; fi
if (( base_rc > 128 )); then echo "  🔴 baseline died of signal $((base_rc-128))" >&2; exit 2; fi
if [[ "$base_rc" != 0 ]]; then echo "  🔴 baseline is RED -- nothing below is interpretable" >&2; exit 2; fi

# --- 1. one mutation at a time --------------------------------------------------------
echo
echo "=== mutations ==="
verdict=0
for name in "${CASES[@]}"; do
    expect="$(cat "$MUT_DIR/$name/expect")"
    # Leading spaces are stripped from the suite's FAILED lines by run_suite's sed, so a check
    # name that is indented (a sub-assertion) would never match its own expectation and the gate
    # would report "red, but NOT the named check" with two identical-looking strings. Trim here
    # so both sides are compared in the same shape.
    expect="${expect#"${expect%%[![:space:]]*}"}"
    restore
    a="$(apply "$name")"
    if [[ "$a" != ok ]]; then
        echo "  🔴 $name: anchor $a (must be exactly 1) -- the source moved under the gate" >&2
        verdict=2; continue
    fi
    if ! bash -n "$NDT" 2>/dev/null; then
        echo "  🔴 $name: the mutant does not parse -- that is a broken mutation, not a catch" >&2
        verdict=2; continue
    fi
    r="$(run_suite)"; rc="${r%%|*}"; red="${r#*|}"
    if [[ "$rc" == 124 ]]; then
        echo "  🔴 $name: suite HUNG -- never a catch" >&2; verdict=2; continue
    fi
    if (( rc > 128 )); then
        echo "  🔴 $name: suite died of signal $((rc-128)) -- not an assertion" >&2; verdict=2; continue
    fi
    if [[ -z "$expect" ]]; then                      # the control
        if [[ "$rc" == 0 ]]; then
            printf '  %-26s SURVIVED (control, as required)\n' "$name"
        else
            printf '  %-26s 🔴 CONTROL WENT RED: %s\n' "$name" "$red" >&2
            verdict=2
        fi
        continue
    fi
    if [[ "$rc" == 0 ]]; then
        printf '  %-26s 🔴 SURVIVED -- the suite does not test this\n' "$name" >&2
        verdict=1
    elif [[ ",$red," == *",$expect,"* ]]; then
        printf '  %-26s caught by: %s\n' "$name" "$expect"
    else
        printf '  %-26s 🔴 red, but NOT the named check\n' "$name" >&2
        printf '  %-26s    wanted: %s\n' "" "$expect" >&2
        printf '  %-26s    got:    %s\n' "" "$red" >&2
        verdict=1
    fi
done

# --- 2. the baseline must be back, byte for byte --------------------------------------
restore
echo
if cmp -s "$NDT" "$SNAP"; then
    echo "restore: $NDT is byte-identical to the pre-gate snapshot"
else
    echo "🔴 restore FAILED -- $NDT differs from the snapshot" >&2
    verdict=2
fi

echo
case "$verdict" in
    0) echo "VERDICT: every mutation was caught by the check named for it; the control survived" ;;
    1) echo "VERDICT: at least one mutation survived or was caught by the wrong check" >&2 ;;
    *) echo "VERDICT: no verdict -- the gate could not run cleanly" >&2 ;;
esac
exit "$verdict"
