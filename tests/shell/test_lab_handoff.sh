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

# THE FIXTURE IS DELIBERATELY UNMISTAKABLE, and that is the load-bearing part of it.
#
# The first version of this check used by=8/25 sampling / at=<today> / note=ticket D done, safe
# to tear down. The real handoff written by that session an hour later read "ticket D finished
# 20:05. Fabric left up and freshly restored -- take it or tear it down". Near enough word for
# word. When I leaked the fixture into the live workspace, the only thing distinguishing it from
# a genuine handoff was the by= and at= fields, which nobody interrogates on a note that reads
# perfectly plausibly -- and its instruction was "safe to tear down", i.e. it would have induced
# a destructive action against a fabric someone was running on.
#
# So the fixture now announces itself. An owner nobody has, an epoch timestamp, and a note whose
# first words tell a human reading it in a live workspace that a test leaked. Suggested by the
# 8/25 sampling session after the near miss; it costs nothing and removes the whole failure mode.
write_handoff() {
    printf 'by=%s\nat=%s\nfabric=up\ntopology=%s\nnote=%s\n' \
        "TEST-DO-NOT-TRUST" \
        "1970-01-01T00:00:00Z" \
        "TEST FIXTURE -- not a real topology" \
        "SYNTHETIC FIXTURE from tests/shell/test_lab_handoff.sh. If you are reading this in a live workspace a test leaked; it is NOT a handoff and says nothing about the lab." \
        > "$SANDBOX/.test_run/lab.handoff"
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
      "$(lab_section | grep -q 'TEST-DO-NOT-TRUST' && echo yes || echo no)"
check "it says what state the fabric is in" "yes" \
      "$(lab_section | grep -q 'fabric up' && echo yes || echo no)"
check "it carries the free-text note" "yes" \
      "$(lab_section | grep -q 'SYNTHETIC FIXTURE' && echo yes || echo no)"
check "it states the rule, so the reader need not remember it" "yes" \
      "$(lab_section | grep -q 'the lab is free' && echo yes || echo no)"

# 3. THE LOAD-BEARING ONE. A live claim answers the question; a leftover handoff beside it would
#    say "safe to tear down" about a fabric somebody is running on.
printf 'owner=someone else\nexpires=%s\nnote=busy\n' "$(( $(date +%s) + 3600 ))" \
    > "$SANDBOX/.test_run/lab.claim"
check "a live claim suppresses the handoff line" "no" "$(has_handoff)"
check "and the claim itself is still reported" "yes" \
      "$(lab_section | grep -q 'someone else' && echo yes || echo no)"
check "the fixture is not mistakable for a real handoff" "yes" \
      "$(write_handoff; grep -q 'TEST-DO-NOT-TRUST' "$SANDBOX/.test_run/lab.handoff" \
         && grep -q '1970' "$SANDBOX/.test_run/lab.handoff" && echo yes || echo no)"

# 4. An expired claim is treated as free everywhere else in this tool, so the handoff must come
#    back with it -- otherwise a crashed session hides the note forever.
printf 'owner=someone else\nexpires=%s\nnote=busy\n' "$(( $(date +%s) - 60 ))" \
    > "$SANDBOX/.test_run/lab.claim"
check "an expired claim does not hide the handoff" "yes" "$(has_handoff)"

# 6. Claiming invalidates the note. Adam's ruling, argued by the 8/25 sampling session: deletion
#    must follow RESPONSIBILITY, not reading. A reader who merely looked and left would otherwise
#    destroy the note for whoever actually takes the lab, two readers race, and it relies on
#    someone remembering. The rename keeps an interrupted handover reconstructable.
rm -f "$SANDBOX/.test_run/lab.claim" "$SANDBOX/.test_run/lab.handoff.prev"
write_handoff
NDT_OWNER="test-owner" bash "$NDT" claim 5 "unit test" >/dev/null 2>&1
check "claiming removes the handoff" "no" \
      "$([[ -f "$SANDBOX/.test_run/lab.handoff" ]] && echo yes || echo no)"
check "and keeps it as .prev, so an interrupted handover survives" "yes" \
      "$([[ -f "$SANDBOX/.test_run/lab.handoff.prev" ]] && echo yes || echo no)"
check "so status shows no handoff once someone owns the lab" "no" "$(has_handoff)"

# 7. Releasing must NOT resurrect it. The next holder gets "no handoff" -- which is the correct
#    direction to fail -- rather than a note describing a fabric two owners ago.
NDT_OWNER="test-owner" bash "$NDT" release >/dev/null 2>&1
check "releasing does not bring the old note back" "no" "$(has_handoff)"

# 8. Claiming with no note present must not invent one or fail.
rm -f "$SANDBOX/.test_run/lab.claim" "$SANDBOX/.test_run/lab.handoff" "$SANDBOX/.test_run/lab.handoff.prev"
NDT_OWNER="test-owner" bash "$NDT" claim 5 "unit test" >/dev/null 2>&1
check "claiming with no handoff present is fine" "0" "$?"
check "and does not create one" "no" \
      "$([[ -f "$SANDBOX/.test_run/lab.handoff" ]] && echo yes || echo no)"
NDT_OWNER="test-owner" bash "$NDT" release >/dev/null 2>&1

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
