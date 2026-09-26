#!/usr/bin/env bash
# Segment W: the class scan of mutate_p4_heartbeat_w.sh, run on its own (the block between its
# "THE SCAN READS" comment and `rm -rf "$base"`) against six situations, each with the answer it
# must give. The "later ticket" case runs on a COPY of p4_proxy/tests with one extra class, in a
# temp dir whose .git file points at this worktree's git dir (read-only git: show, ls-tree,
# merge-base). [Co-developed with claude code -- Adam]
set -u
WT="$1"; PY="$WT/p4_proxy/venv/bin/python"; GATE=tests/shell/mutate_p4_heartbeat_w.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/hbw-scan-XXXXXX"); trap 'rm -rf "$T"' EXIT
bad=0
echo "HEAD $(git -C "$WT" rev-parse HEAD)"
extract() {   # extract <rev> <first-line regex> <out>
    git -C "$WT" show "$1:$GATE" > "$T/gate.sh"
    local s e
    s=$(/usr/bin/grep -n -E "$2" "$T/gate.sh" | head -1 | cut -d: -f1)
    e=$(awk -v s="$s" 'NR>s && /^rm -rf "\$base"$/ {print NR; exit}' "$T/gate.sh")
    [[ -n "$s" && -n "$e" ]] || { echo "  cannot find the scan block at $1"; exit 2; }
    sed -n "${s},$((e-1))p" "$T/gate.sh" > "$3"
}
extract HEAD "THE SCAN READS THIS SEGMENT'S OWN HEAD" "$T/new.sh"
extract d57531d9 '^missing=\$\("\$PY" - "\$REPO" "\$TICKET_BASE" "\$NEW_CLASSES"' "$T/old.sh"
# The gate's own NEW_CLASSES at HEAD (round 1 of this probe typed the list, and went stale when round
# 2 added test_heartbeat_contract to the gate -- an instrument error, logged as such).
ALL="$(git -C "$WT" show HEAD:$GATE | awk '/^NEW_CLASSES="/{on=1} on{print; if ($0 ~ /"$/) exit}' \
       | sed -e 's/^NEW_CLASSES="//' -e 's/"$//' -e 's/\\$//' | tr '\n' ' ')"
[[ "$ALL" == *"tests.test_flowentry_read_only:*"* ]] || { echo "  cannot read NEW_CLASSES from the gate at HEAD: '$ALL'"; exit 2; }
echo "NEW_CLASSES at HEAD: $ALL"
run() {   # run <block> <repo> <NEW_CLASSES> [CLASSES_AT]
    ( REPO="$2"; TICKET_BASE=580767a8; NEW_CLASSES="$3"; SURVIVORS=0
      [[ -n "${4:-}" ]] && CLASSES_AT="$4"
      source "$1"; echo "SURVIVORS=$SURVIVORS" ) 2>&1
}
expect() {    # expect <what> <output> <must-match ERE>
    if tr '\n' ' ' <<<"$2" | /usr/bin/grep -qE "$3"; then echo "  ok    $1"
    else echo "  BAD   $1 -- got: $(tr '\n' ' ' <<<"$2")"; bad=1; fi
}
o=$(run "$T/new.sh" "$WT" "$ALL")
expect "the pinned head: every class named, the control saw an omission" "$o" "names every TestCase class added between 580767a8 and f8309d02.*control.*SURVIVORS=0"
o=$(run "$T/new.sh" "$WT" "$ALL" worktree)
expect "CLASSES_AT=worktree: the same answer from the files on disk" "$o" "names every TestCase class added between 580767a8 and worktree.*SURVIVORS=0"
o=$(run "$T/new.sh" "$WT" "${ALL/tests.test_heartbeat_fabric:\*/}")
expect "a module left off the list: its three classes named, one survivor" "$o" "WhichFabricGetsTheHeartbeatWatchdogTest.*SURVIVORS=1"
o=$(run "$T/new.sh" "$WT" "$ALL" 318e6391)
expect "a pin that is not an ancestor of HEAD: refused" "$o" "REFUSE: CLASSES_AT 318e6391 is not an ancestor"
o=$(run "$T/new.sh" "$WT" "$ALL" 580767a8)
expect "a pin that reads no added class: the control refuses" "$o" "REFUSE: the class scan cannot see an omission"
L="$T/later"; mkdir -p "$L/p4_proxy/tests"; cp "$WT/.git" "$L/.git"; cp "$WT"/p4_proxy/tests/test_*.py "$L/p4_proxy/tests/"
printf 'import unittest\n\n\nclass SomeLaterTicketsTest(unittest.TestCase):\n    def test_it(self):\n        pass\n' \
    > "$L/p4_proxy/tests/test_some_later_ticket.py"
o=$(run "$T/old.sh" "$L" "$ALL")
expect "a later ticket's class in the tree, the d57531d9 scan: listed as omitted (the defect)" "$o" "test_some_later_ticket:SomeLaterTicketsTest.*SURVIVORS=1"
o=$(run "$T/new.sh" "$L" "$ALL")
expect "the same tree, this head's scan: not its business" "$o" "names every TestCase class added between 580767a8 and f8309d02.*SURVIVORS=0"
echo "CLASS-SCAN-PROBE: $([[ $bad == 0 ]] && echo 'every situation answered as it must' || echo BROKEN)"
exit $bad
