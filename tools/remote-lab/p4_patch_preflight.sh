#!/usr/bin/env bash
# p4_patch_preflight.sh -- answer the ONE question that can waste 2 hours of build,
# in about 2 minutes, without root.
# [Co-developed with claude code -- Adam]
#
# Background: on 2026-08-28 the v10 installer was shown to fail because p4-guide's
# patches had gone stale against behavioral-model's MOVING HEAD (the installer does
# not pin it). v8's two patches still applied THAT DAY. Six days have passed. If v8
# has rotted too, the install manual's Step 6.1 advice is now broken for every reader,
# and we would only discover it ~15 minutes into a 2-hour build.
#
# So: clone both, run every candidate patch with --dry-run, record rc per patch.
# v10 is included as a CONTROL: we already know its patches fail. If v10 suddenly
# passes, the instrument is wrong, not the world.
set -uo pipefail

WORK="$HOME/p4-preflight"
OUT="$HOME/p4_patch_preflight.out"
exec > >(tee "$OUT") 2>&1
echo "=== p4 patch preflight  $(date -Is)  host=$(hostname) ==="

rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK" || exit 1

echo "--- cloning p4-guide (unpinned: this is what a reader gets today) ---"
git clone -q https://github.com/jafingerhut/p4-guide.git || { echo "FATAL: p4-guide clone failed"; exit 1; }
echo "p4-guide HEAD: $(git -C p4-guide log -1 --format='%H %ci %s')"

echo
echo "--- which installer scripts exist (manual 6.1 says: take the highest version) ---"
ls p4-guide/bin/install-p4dev-v*.sh | sed 's/^/  /'

echo
echo "--- cloning behavioral-model at HEAD (the installer does NOT pin it) ---"
git clone -q https://github.com/p4lang/behavioral-model.git || { echo "FATAL: bmv2 clone failed"; exit 1; }
BM_HEAD=$(git -C behavioral-model log -1 --format='%H')
echo "behavioral-model HEAD: $(git -C behavioral-model log -1 --format='%h %ci %s')"
echo "(2026-08-28's run saw fdd3b893, dated 2026-08-24)"

echo
echo "=== which patches does each installer apply to behavioral-model? ==="
for v in v8 v10; do
    s="p4-guide/bin/install-p4dev-$v.sh"
    [ -f "$s" ] || { echo "  $v: script absent"; continue; }
    echo "  $v:"
    grep -oE '[A-Za-z0-9_.-]*behavioral-model[A-Za-z0-9_.-]*\.patch' "$s" | sort -u | sed 's/^/    /'
done

echo
echo "=== DRY-RUN RESULT (rc 0 = applies cleanly, non-zero = rotted) ==="
printf '  %-6s %-58s %s\n' "FROM" "PATCH" "rc"
fail_v8=0; pass_v10=0; tested=0
for v in v8 v10; do
    s="p4-guide/bin/install-p4dev-$v.sh"
    [ -f "$s" ] || continue
    for p in $(grep -oE '[A-Za-z0-9_.-]*behavioral-model[A-Za-z0-9_.-]*\.patch' "$s" | sort -u); do
        # v8 line 875 defines PATCH_DIR="${script_dir}/patches" and the script lives
        # in bin/ -- so bin/patches/. Searching instead of assuming, because the first
        # run of this harness assumed bin/ and reported "no patches found".
        f=$(find p4-guide -name "$p" -type f | head -1)
        if [ ! -f "$f" ]; then printf '  %-6s %-58s %s\n' "$v" "$p" "PATCH FILE NOT FOUND"; continue; fi
        ( cd behavioral-model && patch -p1 --dry-run --force >/dev/null 2>&1 < "../$f" )
        rc=$?
        printf '  %-6s %-58s %s\n' "$v" "$p" "$rc"
        tested=$((tested+1))
        [ "$v" = v8 ]  && [ "$rc" -ne 0 ] && fail_v8=$((fail_v8+1))
        [ "$v" = v10 ] && [ "$rc" -eq 0 ] && pass_v10=$((pass_v10+1))
    done
done

echo
echo "=== VERDICT ==="
if [ "$tested" -eq 0 ]; then
    echo "  INCONCLUSIVE -- no patches tested. The instrument found nothing to test;"
    echo "  that is a finding about this script, not about p4-guide."
elif [ "$pass_v10" -gt 0 ]; then
    echo "  🔴 CONTROL FAILED -- v10 patches now apply, but 08-28 measured them failing."
    echo "  Do NOT trust the v8 column either. Something changed upstream or this"
    echo "  harness is wrong. Investigate before building anything."
elif [ "$fail_v8" -eq 0 ]; then
    echo "  PASS -- v8's patches still apply against behavioral-model $BM_HEAD."
    echo "  Safe to run install-p4dev-v8.sh unpinned. Control behaved (v10 still fails)."
else
    echo "  🔴 v8 HAS ROTTED -- $fail_v8 of its patches no longer apply."
    echo "  This is a manual-level finding: Step 6.1's advice fails for readers today."
    echo "  Fix for us = pin INSTALL_BEHAVIORAL_MODEL_SOURCE_VERSION to a commit whose"
    echo "  patches apply. Fix for the manual = a separate decision."
fi
echo
echo "raw: $OUT   worktree kept at: $WORK"
