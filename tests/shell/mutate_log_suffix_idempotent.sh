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

SURVIVORS=0
run() { bash "$TEST" 2>&1; }
report() {   # $1 = mutation name, $2 = case that must fail
    local out rc
    out=$(run); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $2" <<<"$out"; then
        printf '  caught   %-54s (%s went red)\n' "$1" "$2"
    else
        printf '  SURVIVED %-54s (%s stayed green -- that case proves nothing)\n' "$1" "$2"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

echo "baseline (unmutated) must be green:"
if run | tail -2 | grep -q '0 failed'; then echo "  ok       baseline green"
else echo "  REFUSE: baseline is not green"; run | sed 's/^/    /'; exit 2; fi
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

# 6. round.env stops exporting the anchor.
perl -0pi -e 's/^export LOG_BASE=/LOG_BASE=/m' "$FENV"
report "F5 round.env stops exporting LOG_BASE" "case 8"

restore
echo
ok=1
for f in "$LIB" "$RUNE" "$F5" "$FENV"; do cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }; done
[[ "$ok" == 1 ]] && echo "baseline restored: all four files byte-identical to the pre-run snapshot"
[[ "$ok" == 1 && "$SURVIVORS" -eq 0 ]]
