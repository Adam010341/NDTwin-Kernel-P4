#!/usr/bin/env bash
# Does claim_guard identify the right PRINCIPAL? -- reproduction for
# doc/audit/2026-08-31_completeness-experiments/FINDING-claim-guard-truncates-owner.md
# [Co-developed with claude code -- Adam]
#
# ===========================================================================
#  WHY THIS IS A SEPARATE FILE, AND WHAT IT ADDS TO test_vm_coordination.sh
#
#  That gate asks "does every mutating verb have a guard, and does every
#  guard fire in both directions?" Both answers are yes. This asks a third
#  question it never asks:
#
#      when the guard fires, is it comparing the right two things?
#
#  owner_of() is awk '/^owner:/{print $2}' -- the FIRST WORD of the name --
#  while me() returns NDT_OWNER whole. So a session called
#  "8/29 poster-reviewer" is refused by its own VM, and "8/31 auditor" and
#  "8/31 mainDev" are the same principal as far as the guard can tell.
#
#  🔴 The reason the existing gate cannot see this is worth more than the bug:
#  every OWNER fixture it uses is a SINGLE TOKEN -- bmv2paper, mainDev,
#  tester, someone-else. Eight fixtures, no spaces. The guard's correctness
#  depends on a property of the user's naming habit, and the gate was written
#  by someone with the same habit, so the gate's population and the failure's
#  population never intersect. G-I5 below asserts on the fixtures themselves,
#  because that is the only check that would have caught this class rather
#  than this instance.
#
#  🔴 EXPECTED RED until the fix lands. It is kept out of the main gate on
#  purpose: `開機手冊` is running two VMs through this tool right now, and a
#  suite that goes red mid-round cannot be told apart from a tool that broke
#  mid-round. Fold these cases into test_vm_coordination.sh with the fix.
#
#  Point it at a patched copy to prove it discriminates:
#      NDTVM_UNDER_TEST=/tmp/patched.sh ./test_claim_guard_identity.sh
# ===========================================================================
set -uo pipefail

HERE=$(dirname -- "$(readlink -f -- "$0")")
VM="${NDTVM_UNDER_TEST:-$HERE/ndtwin-vm.sh}"
GATE="$HERE/test_vm_coordination.sh"
[ -r "$VM" ] || { echo "🔴 no tool at $VM"; exit 2; }
echo "testing: $VM"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

expect() {  # expect <label> <want-rc> <want-substring> -- then the command
    local label="$1" want_rc="$2" want="$3"; shift 3
    local out rc
    out=$("$@" 2>&1 </dev/null); rc=$?
    if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want"; then
        printf '  ✅ %s\n' "$label"; pass=$((pass+1))
    else
        printf '  🔴 %s\n     want rc=%s containing %s\n     got  rc=%s: %s\n' \
            "$label" "$want_rc" "'$want'" "$rc" "$(printf '%s' "$out" | head -2 | tr '\n' '|')"
        fail=$((fail+1))
    fi
}

claim() {  # claim <dir> <owner string>
    mkdir -p "$T/$1"
    printf 'owner: %s\nsince: 2026-09-01T14:00:00+08:00\nport:  2223\nnote:  n\n' \
        "$2" > "$T/$1/OWNER"
}

# `destroy` is the verb used here for the same reason G1/G2 use it: it calls
# claim_guard first and then stops at an interactive confirmation, so a guard
# that lets us through is observable ("Type DESTROY") without anything running.

echo "=== G-I1  an owner whose name contains a space must pass its own guard ==="
claim s1 "8/29 poster-reviewer"
expect "GREEN-- the real owner gets through" 1 "Type DESTROY" \
    env NDT_OWNER="8/29 poster-reviewer" VM_DIR="$T/s1" bash "$VM" destroy

echo "=== G-I2  a same-first-word stranger must NOT pass ==="
claim s2 "8/31 auditor"
expect "RED  -- 8/31 mainDev is refused by 8/31 auditor's VM" 3 "belongs to another session" \
    env NDT_OWNER="8/31 mainDev" VM_DIR="$T/s2" bash "$VM" destroy
expect "RED  -- the truncated token is not an identity either" 3 "belongs to another session" \
    env NDT_OWNER="8/31" VM_DIR="$T/s2" bash "$VM" destroy

echo "=== G-I3  control: a space-free owner still passes (harness is not just failing) ==="
claim s3 "bmv2paper"
expect "GREEN-- space-free owner unaffected" 1 "Type DESTROY" \
    env NDT_OWNER=bmv2paper VM_DIR="$T/s3" bash "$VM" destroy

echo "=== G-I4  control: the guard still guards (fix must not open it) ==="
expect "RED  -- an unrelated session is still refused" 3 "belongs to another session" \
    env NDT_OWNER=someone-else VM_DIR="$T/s3" bash "$VM" destroy
expect "RED  -- unset owner is still refused" 1 "NDT_OWNER is not set" \
    env -u NDT_OWNER VM_DIR="$T/s3" bash "$VM" destroy

echo "=== G-I5  the fixture population itself -- the check that catches the CLASS ==="
# Not a test of the tool. A test of the other test: a gate whose fixtures are
# all single tokens cannot observe a guard that only breaks on multi-token
# names, no matter how many directions it exercises.
if [ -r "$GATE" ]; then
    spaced=$(grep -o "owner: [A-Za-z0-9/_-]* [A-Za-z0-9/_-]*" "$GATE" | wc -l)
    if [ "$spaced" -ge 1 ]; then
        echo "  ✅ the main gate exercises at least one multi-token owner"; pass=$((pass+1))
    else
        echo "  🔴 the main gate has NO multi-token owner fixture"
        echo "     -> its 32/32 green is silent about every name with a space in it,"
        echo "        which is 5 of this project's 7 session names."
        fail=$((fail+1))
    fi
else
    echo "  ⚠️  main gate not found next to this file -- G-I5 skipped (not counted)"
fi

echo
printf 'pass %d   fail %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || { echo "🔴 RED -- expected until the owner_of fix lands"; exit 1; }
echo "✅ all green"
