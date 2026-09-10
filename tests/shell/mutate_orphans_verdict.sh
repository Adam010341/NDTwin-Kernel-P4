#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_orphans_verdict.sh.
#
# [Co-developed with claude code -- Adam]
#
# `tools/test_workflow/orphans_verdict.sh` is the instrument every round's restore check reads
# ("verdict from the tally, NOT from the rc"), and until 2026-09-11 nothing made its suite go red.
# That is how F-OFFLINE-1 §1.11 was possible: a report with the kernel UP and all three lock
# probes answering `NOT CHECKED (http 500)` read `VERDICT: CLEAN` rc 0, and the 78 green cells of
# that suite had nothing to say about it.
#
# The eight mutations below are the eight ways this reader can lie while looking healthy. Six
# attack the 2026-09-11 floor (`NOT CHECKED`, rc 3) and its two boundaries; two attack behaviour
# that predates it, so the gate protects the whole reader and not only the newest cell:
#
#   M1  the floor never fires                       -> ALL-BLIND 1/4
#   M2  the floor fires on PARTIAL blindness        -> ALL-BLIND 2/4   (the CLEAN side)
#   M3  the discriminator matches a bare word        -> ALL-BLIND 3/4
#   M4  kernel-down loses Adam's 09-10 wording      -> ALL-BLIND 4/4
#   M5  the token is right and the rc is 0          -> ALL-BLIND 1/4   (rc, not prose)
#   M6  a window that WAS read stops counting        -> ALL-BLIND 4/4
#   M7  a dated rule stops being residue            -> RC_IS_NOT_CONSULTED
#   M8  kernel-down inferred from a missing tally    -> KERNEL DOWN 3/3
#
# 🔴 NO BUILD, NO LOCK. Both files are shell; nothing here compiles, so this gate takes no build
# lock and needs no guard. Run it bare.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. The baseline is the WORKING TREE, not HEAD, so
# this runs against an uncommitted fix. These files sit in a worktree other sessions write to.
#
# A mutation is KILLED only when the case named beside it goes red. Everything else is a
# SURVIVOR, with the reason printed: `nothing went red`, `wrong test went red`, or
# `anchor missing` (the perl matched nothing, so the mutation was never applied and proves
# nothing about the test). The run ends with "N mutations, M survived".
#
# EXIT CODES
#   0  every mutation was killed
#   1  at least one survivor -- a real verdict: the suite is weaker than it claims
#   2  harness fault -- the run measured nothing (red baseline, a baseline that was not
#      restored, or a suite still red after the final restore)
#
# Run:  bash tests/shell/mutate_orphans_verdict.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

V=tools/test_workflow/orphans_verdict.sh
TEST=tests/shell/test_orphans_verdict.sh
BK=$(mktemp -d)
cp "$V" "$BK/orphans_verdict.sh"
restore() { cp "$BK/orphans_verdict.sh" "$V"; }
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
run() { bash "$TEST" 2>&1; }

# `perl -0pi -e 's/.../.../'` exits 0 when it matches NOTHING, so a moved anchor is otherwise
# invisible: the mutation is never applied, the suite stays green, and the run blames the named
# case for being decorative when in fact nothing was ever tested. report() always starts from a
# restored tree, so "still identical to the baseline" means the perl matched nothing.
state() { sha256sum "$V" | cut -d' ' -f1; }
BASELINE_STATE=$(state)

# A harness fault means the run measured nothing. It is never a survivor count and never a 1.
harness_fault() {
    printf '\n🔴 HARNESS FAULT: %s\n' "$1" >&2
    printf '   This run measured nothing: it is not a pass and not a survivor count.\n' >&2
    exit 2
}

# A mutation is KILLED only when the case named here goes red. Anything else is a SURVIVOR --
# the reason names what we failed to learn, not whether the harness had a good day.
report() {   # $1 = mutation name, $2 = case that must fail
    local out rc others
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$(state)" == "$BASELINE_STATE" ]]; then
        printf '  SURVIVED %-54s (anchor missing -- never applied)\n' "$1"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! bash -n "$V" 2>/dev/null; then
        # A mutant that does not parse tests nothing: every case goes red for the same reason,
        # so a red suite here is not evidence that the named case is load-bearing.
        printf '  SURVIVED %-54s (mutant does not parse -- proves nothing)\n' "$1"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    out=$(run); rc=$?
    others=$(grep -E '^  FAILED' <<<"$out")
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $2" <<<"$out"; then
        printf '  caught   %-54s (%s went red)\n' "$1" "$2"
    elif [[ -n "$others" ]]; then
        printf '  SURVIVED %-54s (wrong test went red -- %s did not)\n' "$1" "$2"
        sed 's/^/             /' <<<"$others"
        SURVIVORS=$((SURVIVORS + 1))
    else
        # rc != 0 with no FAILED line at all is a suite that died without naming a case; that
        # is no evidence of anything, so it must not be read as "the case went red".
        printf '  SURVIVED %-54s (nothing went red -- %s proves nothing)\n' "$1" "$2"
        [[ "$rc" -ne 0 ]] && printf '             (the suite exited %s without naming a case)\n' "$rc"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

echo "baseline (unmutated) must be green:"
if run | tail -2 | grep -q '0 failed'; then echo "  ok       baseline green"
else
    echo "  REFUSE: baseline is not green"; run | sed 's/^/    /'
    harness_fault "the suite is already red before any mutation"
fi
echo
echo "mutations:"

# 1. 🔴 THE ORIGINAL DEFECT (F-OFFLINE-1 §1.11): the floor never fires, so a report in which
#    nothing could be asked reads CLEAN because every counter is still at its initial value.
perl -0pi -e 's/    if \(\( N_UNANSWERABLE > 0 && NETWORK_ANSWERED == 0 \)\); then/    if (( 0 )); then/' "$V"
report "the all-blind floor never fires" "  🔴 rc 3 -- zeros nobody could measure are not a clean network"

# 2. The floor becomes greedy and fires on ANY unanswered question. That makes this reader red on
#    a clean OVS4 fabric with one lost window -- the case Adam ruled a NOTE on 2026-09-10 and the
#    reason the helper exists at all. A floor with no ceiling is the same bug facing the other way.
perl -0pi -e 's/    if \(\( N_UNANSWERABLE > 0 && NETWORK_ANSWERED == 0 \)\); then/    if (( N_UNANSWERABLE > 0 )); then/' "$V"
report "the floor fires on partial blindness too" "  🔴 rc 0 -- partial blindness is this lab's normal state"

# 3. The discriminator stops reading the LINE `lock <name> free` and reads the bare word, so a
#    probe failure whose error text happens to contain "free" counts as a lock that was read.
perl -0pi -e "s/'lock\[\[:space:\]\]\+\[A-Za-z_\]\+ free\[\[:space:\]\]\*\\\$'/' free'/" "$V"
report "the answer test matches a bare 'free' anywhere" "  🔴 rc 3 -- an error message containing 'free' is not a lock that was read"

# 4. Kernel-down stops being CLEAN. Adam ruled on 2026-09-10 that the process half answers for a
#    report taken after `ndt down`; the new floor must not quietly annex that cell.
perl -0pi -e 's/        echo "VERDICT: CLEAN -- the process half only; the network half was NOT checked \(kernel down\)"/        echo "VERDICT: NOT CHECKED -- the network half was not checked (kernel down)"/' "$V"
report "kernel-down loses Adam's 09-10 CLEAN wording" "  🔴 and Adam's 09-10 wording is unchanged"

# 5. The prose is right and the exit code passes anyway -- the shape every `orphans && ok || fail`
#    caller reads, and the one a reader that only greps VERDICT: would never notice.
perl -0pi -e 's/^        exit 3$/        exit 0/m' "$V"
report "NOT CHECKED prints but exits 0" "  🔴 rc 3 -- zeros nobody could measure are not a clean network"

# 6. A flow table that WAS read for an app's window stops counting as an answer, so the one CLEAN
#    cell that rests on the rule half rather than the lock half flips to NOT CHECKED.
perl -0pi -e "s/   \|\| grep -qF -- 'no flow entry arrived during that window' <<<\"\\\$REPORT\" \\\\/   || grep -qF -- 'no flow entry arrived during that WINDOW' <<<\"\$REPORT\" \\\\/" "$V"
report "a window that was read stops being an answer" "  one window read, three locks blind -> rc 0 (§7-1 is open)"

# 7. PRE-2026-09-11 BEHAVIOUR: a single dated rule in a window stops being residue. This is the
#    cell that pins "read the tally, not the rc" -- the whole premise of the file.
perl -0pi -e 's/\(\( N_RULES > 0 \)\) && REASONS\+=/(( N_RULES > 1 )) \&\& REASONS+=/' "$V"
report "one dated rule in a window stops being residue" "  🔴 a dated rule is NOT CLEAN even when ndt returned 0"

# 8. PRE-2026-09-11 BEHAVIOUR: kernel-down mode inferred from the ABSENCE of a tally instead of
#    from `ndt` naming the reason. 68 real one-line reports have no tally, 8 of them taken with
#    the kernel UP, so this reads a kernel-up report as clean on no evidence at all.
perl -0pi -e 's/   && \{ grep -qF -- .the kernel is not up \(:8000 closed\) -- rules and locks CANNOT be checked. <<<"\$REPORT" \\/   \&\& { true \|\| grep -qF -- "the kernel is not up" <<<"$REPORT" \\/' "$V"
report "kernel-down inferred from a missing tally" "  🔴 rc 2 -- a real one-line report from an older ndt"

restore
echo
if ! cmp -s "$BK/orphans_verdict.sh" "$V"; then
    echo "🔴 NOT RESTORED: $V"
    harness_fault "the baseline was not restored -- a mutant is still on disk"
fi
echo "baseline restored: $V byte-identical to the pre-run snapshot"
if ! run | tail -2 | grep -q '0 failed'; then
    echo "🔴 THE SUITE IS RED AFTER RESTORE:"
    run | sed 's/^/    /'
    harness_fault "the suite is red after the final restore"
fi
echo "after restore: the suite is green again"

echo
printf '%d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
((SURVIVORS == 0)) || exit 1
exit 0
