#!/usr/bin/env bash
#
# Tests for qdisc_snapshot.sh, driven through a fake `tc` (the QDISC_SNAPSHOT_TC seam).
#
# [Co-developed with claude code -- Adam]
#
# The scenario these encode is the one that motivated the tool (2026-08-13 OVS round):
# a `root netem` replaced TCLink's htb, `del root` put back the default qdisc instead, and
# every "netem residue" check stayed green because no netem was left. Only a full-tree
# before/after diff sees that shape, so the diff path is the load-bearing one here.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../../tools/test_workflow/qdisc_snapshot.sh"

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A fake tc that prints whatever state file FAKE_TC_STATE points at.
cat > "$TMP/fake_tc" <<'FAKE'
#!/usr/bin/env bash
cat "$FAKE_TC_STATE"
FAKE
chmod +x "$TMP/fake_tc"
export QDISC_SNAPSHOT_TC="$TMP/fake_tc"

# The healthy shape: TCLink's htb on a shaped link, defaults elsewhere.
cat > "$TMP/state.healthy" <<'EOF'
qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10 default 1 direct_packets_stat 0
qdisc netem 10: dev s1-eth1 parent 5:1 limit 1000
qdisc pfifo_fast 0: dev s2-eth1 root refcnt 2 bands 3
EOF
# After the classic mistake: root netem replaced htb, then del root left the default.
cat > "$TMP/state.damaged" <<'EOF'
qdisc pfifo_fast 0: dev s1-eth1 root refcnt 2 bands 3
qdisc pfifo_fast 0: dev s2-eth1 root refcnt 2 bands 3
EOF

echo "save then diff against unchanged state -> clean pass"
export FAKE_TC_STATE="$TMP/state.healthy"
out="$("$TOOL" save "$TMP/snap" 2>&1)"; rc=$?
check "save exits 0" 0 "$rc"
check "snapshot has the 3 lines" 3 "$(wc -l < "$TMP/snap")"
out="$("$TOOL" diff "$TMP/snap" 2>&1)"; rc=$?
check "diff exits 0" 0 "$rc"
check "reports unchanged" yes "$(grep -q "unchanged" <<<"$out" && echo yes || echo no)"

echo "htb silently replaced (the live 2026-08-13 shape) -> diff fails and names the loss"
export FAKE_TC_STATE="$TMP/state.damaged"
out="$("$TOOL" diff "$TMP/snap" 2>&1)"; rc=$?
check "diff exits 1" 1 "$rc"
check "the lost htb line is in the output" yes "$(grep -q -- "-qdisc htb 5: dev s1-eth1" <<<"$out" && echo yes || echo no)"
check "points at the gotcha" yes "$(grep -q "environment_gotchas" <<<"$out" && echo yes || echo no)"

echo "operator errors are exit 2, distinct from drift's exit 1"
out="$("$TOOL" diff "$TMP/never-saved" 2>&1)"; rc=$?
check "missing snapshot is 2" 2 "$rc"
out="$("$TOOL" save 2>&1)"; rc=$?
check "missing file arg is 2" 2 "$rc"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
