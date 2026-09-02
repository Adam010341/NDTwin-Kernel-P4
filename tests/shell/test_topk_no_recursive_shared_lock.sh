#!/usr/bin/env bash
#
# Structural guard for KNOWN-ISSUES §E-2: getTopKFlowInfoJson must not take
# m_flowInfoTableMutex, because the getFlowInfoJson() it calls takes it already.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WHY THIS IS A SOURCE CHECK AND NOT A RUNTIME ONE.
#   Recursively acquiring a std::shared_mutex is undefined behaviour, and the behaviour it
#   actually has on this machine is "works fine": glibc's pthread_rwlock defaults to
#   PTHREAD_RWLOCK_PREFER_READER_NP, so a reader does not yield to a waiting writer and the
#   second rdlock on the same thread succeeds. A "does it deadlock?" test would therefore be
#   green against the broken code as well as the fixed code -- no discriminating power, which is
#   the failure mode this repo keeps re-finding. The two conditions that make it deadlock (a
#   writer-preferring rwlock kind, or a libstdc++ built without _GLIBCXX_USE_PTHREAD_RWLOCK_T)
#   are properties of the toolchain, not inputs a test can supply.
#   ⇒ What is checkable is the structure. That is what this file checks, and it says so rather
#   than dressing itself up as a behavioural test.
#   The behavioural half -- bounds, row contents, field-name agreement -- is
#   tests/test_TopKFlowInfoLocking.cpp.
#
# 🔑 CHECK 3 IS WHAT KEEPS CHECKS 1 AND 2 HONEST. "getTopKFlowInfoJson does not lock" is also
#   true of a tree where NOBODY locks -- deleting the lock from getFlowInfoJson as well would
#   pass checks 1 and 2 while removing the protection entirely. So the guard asserts both sides:
#   the outer function must not lock, AND the inner one must.
#
# Usage:  bash tests/shell/test_topk_no_recursive_shared_lock.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC=src/ndt_core/collection/FlowLinkUsageCollector.cpp
MUTEX=m_flowInfoTableMutex
PASS=0
FAIL=0

check() {   # $1 = name, $2 = expected, $3 = actual
    if [[ "$2" == "$3" ]]; then
        printf '  ok       %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  FAILED   %s (expected %s, got %s)\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

if [[ ! -f "$SRC" ]]; then
    echo "  FAILED   $SRC is missing; this guard has nothing to read"
    echo "Ran 1 checks, 1 failed"
    exit 1
fi

# The body of one function, by name: from its definition line to the closing brace in column 1.
# Comments are stripped first -- this file's fix is documented in a comment that quotes the very
# line being banned, and a grep that cannot tell code from commentary would report the
# explanation as the defect.
body() {   # $1 = function name
    sed -e 's://.*::' "$SRC" |
        awk -v fn="$1" '
            $0 ~ ("FlowLinkUsageCollector::" fn "\\(") { inbody = 1 }
            inbody { print }
            inbody && /^}/ { exit }
        '
}

topk="$(body getTopKFlowInfoJson)"
inner="$(body getFlowInfoJson)"

# 0. The extractor found something. Without this, a rename turns every check below into a
#    comparison of two empty strings, which passes.
check "the two function bodies were found in the source" "yes" \
      "$([[ -n "$topk" && -n "$inner" ]] && echo yes || echo no)"
check "getTopKFlowInfoJson's body is more than its signature" "yes" \
      "$([[ "$(wc -l <<<"$topk")" -gt 5 ]] && echo yes || echo no)"

# 1. The defect itself: any acquisition of the flow-table mutex inside getTopKFlowInfoJson.
check "case 1  getTopKFlowInfoJson does not lock $MUTEX" 0 \
      "$(grep -cE "(shared_lock|unique_lock|lock_guard|scoped_lock).*$MUTEX" <<<"$topk")"

# 2. And it still delegates, so check 1 is not passing because the call was inlined -- an inlined
#    copy of the loop would need its own lock and this guard would then be silent about it.
check "case 2  getTopKFlowInfoJson still calls getFlowInfoJson()" 1 \
      "$(grep -cE 'getFlowInfoJson\(' <<<"$topk")"

# 3. The control: the lock still exists on the inner function. See the header -- without this,
#    "nobody locks anything" satisfies cases 1 and 2.
check "case 3  getFlowInfoJson does take $MUTEX" 1 \
      "$(grep -cE "shared_lock.*$MUTEX" <<<"$inner")"

# 4. The extractor itself, against a fixture rather than against the file under test. Case 1
#    passing could mean "no lock" or "the extractor returned nothing useful"; a guard that cannot
#    tell those apart reads as all-clear in both.
fixture=$(cat <<'FIXTURE'
nlohmann::json
FlowLinkUsageCollector::getTopKFlowInfoJson(int k)
{
    shared_lock lock(m_flowInfoTableMutex);
    nlohmann::json flowInfo = getFlowInfoJson();
    return flowInfo;
}
FIXTURE
)
check "case 4  the matcher sees the banned line when it is present" 1 \
      "$(grep -cE "(shared_lock|unique_lock|lock_guard|scoped_lock).*$MUTEX" <<<"$fixture")"

# 5. ...and is not fooled by the comment that documents the fix, which quotes the banned line.
check "case 5  a commented-out lock is not counted as code" 0 \
      "$(sed -e 's://.*::' <<<'    // shared_lock lock(m_flowInfoTableMutex);' |
         grep -cE "(shared_lock|unique_lock).*$MUTEX")"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
