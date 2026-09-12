#!/usr/bin/env bash
#
# CELL orphans_blind_probes_not_checked -- F5. A network half that answered NOTHING is not CLEAN.
#
# [Co-developed with claude code -- Adam]
#
# Source: F-OFFLINE-1 §1.11, measured offline 2026-09-11 01:0x. A report with the kernel UP, a
# tally present, and all three lock probes answering `NOT CHECKED (http 500)` read
# `VERDICT: CLEAN` rc 0 out of orphans_verdict.sh, while `ndt` itself answered 5 for the same
# observation. Every restore gate in this project spells `grep -F 'VERDICT: CLEAN'`, so three
# blind probes were being read as a clean network.  Fix: ded00d06 (rc 3, `VERDICT: NOT CHECKED`).
#
# 🔴 This cell's observation is a STORED report, not a live one, and CELLS.md says so. Staging it
# live would mean a kernel that is up and returns http 500 to an acquire probe -- a malfunction we
# have no safe way to cause. What is live about it is the SUBJECT: the tool this drives is the
# same tools/test_workflow/orphans_verdict.sh that closes every round.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

cell_observe() {
    local d="$1"
    cell_write_ids "$d"
    # The report `ndt apps orphans` prints for this state, from ndt's own two print sites (the
    # lock probe line and the tally). Byte-for-byte the `all_blind` fixture of
    # tests/shell/test_orphans_verdict.sh, so the two instruments cannot drift apart -- and that
    # suite now CHECKS its synthetic fixtures' sentences against ndt's source, which is what
    # caught this text still saying `network residue` and `the residue question` on 2026-09-12,
    # a day after FIX-NDT-9 renamed that half to `rules-in-window`. The rename changes nothing
    # this cell judges (the verdict comes from the tally and the process half, and NOTE-WHY
    # matches `NOT CHECKED` either way) -- which is precisely why nothing went red for a day.
    cat > "$d/orphans.txt" <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
  !!    lock  routing_lock NOT CHECKED (http 500)
  !!    lock  graph_lock NOT CHECKED (http 500)
  !!    lock  power_lock NOT CHECKED (http 500)
          field (LockManager.hpp), and the kernel has no lock-status endpoint, so the
          three lines above come from an acquire probe with ttl 0, which excludes nobody.
    energy: no pidfile and no live process -- no window, so no rule can be dated
        against it. NOT 'this app left nothing'. (G-12)
        (its log is empty or absent too -- no sign it ever ran here)

    NOT deleted, and nothing here deletes them.
    (no app had a datable window in this run)
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 3 question(s) not answerable
  !!  NOT CHECKED: the rules-in-window question could not be answered -- rc 5.
  !!    this is not 'the network is clean'. see the lines above for which
  !!    reading failed. (KNOWN-ISSUES G-12)
EOF
    # 5 is what `ndt apps orphans` returns for this report (residue_verdict, ndt:5349) and is the
    # second argument every caller passes. Recorded so the fixture carries its own input.
    printf '5\n' > "$d/orphans.rc"
    bash "$NDT_ROOT/tools/test_workflow/orphans_verdict.sh" - 5 \
        < "$d/orphans.txt" > "$d/verdict.txt" 2>&1
    printf '%s\n' "$?" > "$d/verdict.rc"
}

cell_judge() {
    local d="$1"
    a_have  f5_report_present                 "$d/orphans.txt"
    a_have  f5_verdict_present                "$d/verdict.txt"
    # 🔴 THE KEY ASSERTION. rc 3 is the whole finding: 0 was the answer that made three failed
    # probes indistinguishable from three free locks.
    a_eq    f5_verdict_rc_is_3           "3"  "$(cat "$d/verdict.rc" 2>/dev/null)"
    a_has   f5_says_not_checked               "VERDICT: NOT CHECKED"       "$d/verdict.txt"
    # 🔴 The token, not the rc: every restore gate in this repo greps for this exact string, so a
    # verdict that returns 3 and still prints CLEAN would pass every one of them.
    a_hasnt f5_does_not_say_clean             "VERDICT: CLEAN"             "$d/verdict.txt"
    # The zeros must not be presented as measurements.
    a_has   f5_quotes_ndts_own_sentence       "NOT CHECKED (http 500)"     "$d/verdict.txt"
}

cell_main orphans_blind_probes_not_checked ndt none "$@"
