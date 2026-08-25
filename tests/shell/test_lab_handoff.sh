#!/usr/bin/env bash
#
# Tests for `ndt status`'s handoff line.
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS EXISTS. On 2026-08-25 a session released its lab claim at 18:44 and deliberately left a
# 128-host P4 fabric running, because rebuilding one costs 35-40 s and the next user would want it.
# Three minutes later `status` said `claim none` while ten bmv2 switches, a kernel and a proxy were
# all still listening. Nothing in the repo could tell "free, take it" apart from "someone is
# mid-experiment", so the human ended up being the one who had to judge -- which is the single thing
# the claim mechanism exists to prevent. Two sessions agreed a convention, and this is the half of it
# that lives in the shared tool.
#
# The load-bearing case is number 3. A live claim must SUPPRESS the handoff line: a claim and a
# stale handoff note are two voices answering the same question, and the failure mode is the worse
# direction -- reading "safe to tear down" while someone is running on it.
#
# Driven against the real script in an isolated worktree-shaped copy, so REPO resolves to the
# sandbox and the shared .test_run is never touched. An earlier version of this check wrote a
# fabricated handoff file into the live workspace while another session held the lab; that is
# exactly the sort of thing this file is meant to stop, so it does not do it.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT_SRC="$HERE/../../tools/test_workflow/ndt"

PASS=0
FAIL=0

check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

if [[ ! -f "$NDT_SRC" ]]; then
    echo "SKIP: $NDT_SRC not found"
    exit 0
fi

# A sandbox shaped like the repo: ndt derives REPO from its own path as $HERE/../..
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/tools/test_workflow" "$SANDBOX/.test_run"
cp "$NDT_SRC" "$SANDBOX/tools/test_workflow/ndt"
NDT="$SANDBOX/tools/test_workflow/ndt"

lab_section() { bash "$NDT" status 2>/dev/null | sed -n '/^lab/,/^$/p'; }
has_handoff()  { lab_section | grep -qi "handoff" && echo yes || echo no; }

write_handoff() {
    printf 'by=8/25 sampling\nat=2026-08-25T20:15:00+08:00\nfabric=up\ntopology=p4 128\nnote=%s\n' \
        "ticket D done, safe to tear down" > "$SANDBOX/.test_run/lab.handoff"
}

echo "ndt status handoff line"

# 1. Nothing to report. The line must not appear at all -- an always-present line is one nobody
#    reads, which this repo has shipped before.
rm -f "$SANDBOX/.test_run/lab.handoff" "$SANDBOX/.test_run/lab.claim"
check "no handoff file, no handoff line" "no" "$(has_handoff)"

# 2. The case the convention is for: nobody holds the lab, someone left a fabric behind.
write_handoff
check "handoff shown when the lab is unclaimed" "yes" "$(has_handoff)"
check "it says who left it" "yes" \
      "$(lab_section | grep -q '8/25 sampling' && echo yes || echo no)"
check "it says what state the fabric is in" "yes" \
      "$(lab_section | grep -q 'fabric up' && echo yes || echo no)"
check "it carries the free-text note" "yes" \
      "$(lab_section | grep -q 'safe to tear down' && echo yes || echo no)"
check "it states the rule, so the reader need not remember it" "yes" \
      "$(lab_section | grep -q 'the lab is free' && echo yes || echo no)"

# 3. THE LOAD-BEARING ONE. A live claim answers the question; a leftover handoff beside it would
#    say "safe to tear down" about a fabric somebody is running on.
printf 'owner=someone else\nexpires=%s\nnote=busy\n' "$(( $(date +%s) + 3600 ))" \
    > "$SANDBOX/.test_run/lab.claim"
check "a live claim suppresses the handoff line" "no" "$(has_handoff)"
check "and the claim itself is still reported" "yes" \
      "$(lab_section | grep -q 'someone else' && echo yes || echo no)"

# 4. An expired claim is treated as free everywhere else in this tool, so the handoff must come
#    back with it -- otherwise a crashed session hides the note forever.
printf 'owner=someone else\nexpires=%s\nnote=busy\n' "$(( $(date +%s) - 60 ))" \
    > "$SANDBOX/.test_run/lab.claim"
check "an expired claim does not hide the handoff" "yes" "$(has_handoff)"

# 5. A truncated handoff must degrade, not break: the writer is a peer session, not this tool,
#    so half-written and hand-edited files are expected input.
rm -f "$SANDBOX/.test_run/lab.claim"
printf 'by=someone\n' > "$SANDBOX/.test_run/lab.handoff"
check "a handoff missing every optional field still prints" "yes" "$(has_handoff)"
: > "$SANDBOX/.test_run/lab.handoff"
check "an empty handoff file does not crash status" "0" \
      "$(bash "$NDT" status >/dev/null 2>&1; echo $?)"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
