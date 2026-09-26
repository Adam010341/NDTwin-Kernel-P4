#!/usr/bin/env bash
# Segment W R2: the first cut's gate's class scan (tests/shell/mutate_roles_binding.sh, the block
# from its "NEW_CLASSES IS TYPED" comment to `rm -rf "$base"`), run on its own against the
# situations it must tell apart. The "later ticket" cases run on a COPY of the test directories
# with one extra class, in a temp dir whose .git file points at this worktree's git dir (read-only
# git: show, ls-tree, merge-base). The old block (1a3ebd7f) is run beside the new one on that copy.
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; PY="$WT/p4_proxy/venv/bin/python"; GATE=tests/shell/mutate_roles_binding.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/hbw-rscan-XXXXXX"); trap 'rm -rf "$T"' EXIT
bad=0
echo "HEAD $(git -C "$WT" rev-parse HEAD)"
extract() {   # extract <rev> <out>
    if [[ "$1" == worktree ]]; then cp "$WT/$GATE" "$T/gate.sh"; else git -C "$WT" show "$1:$GATE" > "$T/gate.sh"; fi
    local s e
    s=$(/usr/bin/grep -n "NEW_CLASSES IS TYPED; THIS IS WHAT KEEPS IT HONEST" "$T/gate.sh" | head -1 | cut -d: -f1)
    e=$(awk -v s="$s" 'NR>s && /^rm -rf "\$base"$/ {print NR; exit}' "$T/gate.sh")
    [[ -n "$s" && -n "$e" ]] || { echo "  cannot find the scan block at $1"; exit 2; }
    sed -n "${s},$((e-1))p" "$T/gate.sh" > "$2"
    # NEW_CLASSES and TICKET_BASE as that revision of the gate defines them
    sed -n '/^TICKET_BASE=/p' "$T/gate.sh" > "$2.vars"
    awk '/^NEW_CLASSES="/{on=1} on{print; if ($0 ~ /"$/) exit}' "$T/gate.sh" >> "$2.vars"
}
extract "${NEW_REV:-HEAD}" "$T/new.sh"
extract 1a3ebd7f "$T/old.sh"
run() {   # run <block> <repo> [CLASSES_AT] [NEW_CLASSES override]
    ( REPO="$2"; SURVIVORS=0; source "$1.vars"
      [[ -n "${3:-}" ]] && CLASSES_AT="$3"
      [[ -n "${4:-}" ]] && NEW_CLASSES="$4"
      source "$1"; echo "SURVIVORS=$SURVIVORS" ) 2>&1
}
expect() {    # expect <what> <output> <must-match ERE>
    if tr '\n' ' ' <<<"$2" | /usr/bin/grep -qE "$3"; then echo "  ok    $1"
    else echo "  BAD   $1 -- got: $(tr '\n' ' ' <<<"$2" | cut -c1-400)"; bad=1; fi
}
NC="$( source "$T/new.sh.vars"; printf '%s' "$NEW_CLASSES" )"
o=$(run "$T/new.sh" "$WT")
expect "the pin 177b9f03: every class named, the control saw an omission" "$o" "names every TestCase class added between 6291db35 and 177b9f03.*control.*SURVIVORS=0"
o=$(run "$T/new.sh" "$WT" "" "${NC/tests.test_readopt:ReadoptOnAFabricThatSkipsItsRoutesTest/}")
expect "one named class left off the list: it is named, one survivor" "$o" "tests.test_readopt:ReadoptOnAFabricThatSkipsItsRoutesTest.*SURVIVORS=1"
o=$(run "$T/new.sh" "$WT" 094f417f)
expect "a pin that is not an ancestor of HEAD (trunk's 094f417f): refused" "$o" "REFUSE: CLASSES_AT 094f417f is not an ancestor"
o=$(run "$T/new.sh" "$WT" 6291db35)
expect "a pin that reads no added class (the base): the control refuses" "$o" "REFUSE: the class scan cannot see an omission"
o=$(run "$T/old.sh" "$WT")
expect "the 1a3ebd7f scan at this head: segment W's classes counted as its survivor (the defect)" "$o" "test_heartbeat_fabric:.*SURVIVORS=1"
L="$T/later"; mkdir -p "$L/p4_proxy/tests" "$L/tools/p4_exercise/tests"; cp "$WT/.git" "$L/.git"
cp "$WT"/p4_proxy/tests/test_*.py "$L/p4_proxy/tests/"; cp "$WT"/tools/p4_exercise/tests/test_*.py "$L/tools/p4_exercise/tests/"
printf 'import unittest\n\n\nclass SomeLaterTicketsTest(unittest.TestCase):\n    def test_it(self):\n        pass\n' \
    > "$L/p4_proxy/tests/test_some_later_ticket.py"
o=$(run "$T/new.sh" "$L")
expect "a later ticket's class in the tree, this head's scan: not its business" "$o" "names every TestCase class added between 6291db35 and 177b9f03.*SURVIVORS=0"
o=$(run "$T/new.sh" "$L" worktree)
expect "  the same tree with CLASSES_AT=worktree: it is named (the worktree mode reads the files)" "$o" "test_some_later_ticket:SomeLaterTicketsTest.*SURVIVORS=1"
echo "ROLES-SCAN-PROBE: $([[ $bad == 0 ]] && echo 'every situation answered as it must' || echo BROKEN)"
exit $bad
