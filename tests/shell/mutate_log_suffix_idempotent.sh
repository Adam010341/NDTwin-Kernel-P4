#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_log_suffix_idempotent.sh.
#
# [Co-developed with claude code -- Adam]
#
# Mutation 1 restores the original defect: derive_log appending to the CURRENT LOG instead of
# building from the base it was handed. Mutation 4 is the one that matters most in the long run --
# the two rounds carry separate copies of derive_log because F5 has no lib file, and copies drift.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. Baseline is the WORKING TREE, not HEAD, so this
# runs against an uncommitted fix. These files are in a worktree other sessions write to.
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
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

LIB=doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh
RUNE=doc/audit/2026-08-31_sampling-ceiling-after-merge/run_e.sh
F5=doc/audit/2026-08-31_f5-fine-grid-round/run_f5.sh
FENV=doc/audit/2026-08-31_f5-fine-grid-round/round.env
TEST=tests/shell/test_log_suffix_idempotent.sh
BK=$(mktemp -d)

for f in "$LIB" "$RUNE" "$F5" "$FENV"; do cp "$f" "$BK/$(basename "$f").$(echo "$f" | md5sum | cut -c1-6)"; done
snap() { echo "$BK/$(basename "$1").$(echo "$1" | md5sum | cut -c1-6)"; }
restore() { local f; for f in "$LIB" "$RUNE" "$F5" "$FENV"; do cp "$(snap "$f")" "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
run() { bash "$TEST" 2>&1; }

# `perl -0pi -e 's/.../.../'` exits 0 when it matches NOTHING, so a moved anchor is otherwise
# invisible: the mutation is never applied, the suite stays green, and the run blames the named
# case for being decorative when in fact nothing was ever tested. report() always starts from a
# restored tree, so "still identical to the baseline" means the perl above matched nothing.
state() { sha256sum "$LIB" "$RUNE" "$F5" "$FENV" | cut -d' ' -f1 | tr '\n' ' '; }
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
    out=$(run); rc=$?
    others=$(grep -E '^  FAILED' <<<"$out")
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $2" <<<"$out"; then
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
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
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

# 1. THE ORIGINAL DEFECT: build from the live LOG instead of the base handed in.
perl -0pi -e 's/    local out="\$1"; shift/    local out="\$\{LOG:-\$1\}"; shift/' "$LIB"
report "derive_log builds from \$LOG instead of the base" "case 3"

# 2. Suffix order reversed -- composition is part of the contract, not incidental.
perl -0pi -e 's/    for w in "\$\@"; do out="\$\{out%\.log\}\.\$w\.log"; done/    for w in "\$\@"; do out="\$w.\$\{out##*\/\}"; done/' "$LIB"
report "derive_log stops composing suffixes in order" "case 2"

# 3. The enforcement goes back to being advisory.
perl -0pi -e 's/        exit 2\n    fi\n    if \[\[ "\$DRY_RUN" != 1/        :\n    fi\n    if [[ "\$DRY_RUN" != 1/' "$LIB"
report "assert_log_is_derived warns instead of stopping" "case 9b"

# 4. The two copies drift apart.
perl -0pi -e 's/(derive_log\(\) \{   # \$1 = the IMMUTABLE base path.*\n    local out="\$1"; shift\n)/${1}    out="\$out"\n/' "$F5"
report "run_f5.sh's copy of derive_log drifts from lib_e.sh's" "case 6"

# 5. A caller goes back to appending to the inherited LOG.
perl -0pi -e 's/    plan\|selftest\|restore\) LOG="\$\(derive_log "\$LOG_BASE" \$LOG_SUFFIX_DRY "\$1"\)" ;;/    plan|selftest|restore) LOG="\$\{LOG%.log\}.\$1.log" ;;/' "$F5"
report "run_f5.sh appends the mode suffix to the inherited LOG" "case 7"

# 5b. 🔴 B12 (2026-09-11). The SAME defect, respelled with bash's other strip operator.
# Until today case 7 was `grep -c 'LOG="${LOG%.log}'` over four hard-coded paths, so this
# mutation SURVIVED while mutation 5 was caught -- one extra `%` and the guard went quiet.
# F-B0-B12-REPORT.md §3.1 row (6)b.
perl -0pi -e 's/    plan\|selftest\|restore\) LOG="\$\(derive_log "\$LOG_BASE" \$LOG_SUFFIX_DRY "\$1"\)" ;;/    plan|selftest|restore) LOG="\$\{LOG%%.log\}.\$1.log" ;;/' "$F5"
report "the same append respelled \${LOG%%.log} ((6)b)" "case 7"

# 6. round.env stops exporting the anchor.
perl -0pi -e 's/^export LOG_BASE=/LOG_BASE=/m' "$FENV"
report "F5 round.env stops exporting LOG_BASE" "case 8"

restore
echo
ok=1
for f in "$LIB" "$RUNE" "$F5" "$FENV"; do cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }; done
if [[ "$ok" != 1 ]]; then
    harness_fault "the baseline was not restored -- a mutant is still on disk"
fi
echo "baseline restored: all four files byte-identical to the pre-run snapshot"
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
