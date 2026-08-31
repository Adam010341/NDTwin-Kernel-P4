#!/usr/bin/env bash
# =================================================================================================
# build_1khz_binary.sh -- stage the E round's TWO kernel arms.  RUN THIS BEFORE THE WINDOW OPENS.
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS IS A SEPARATE SCRIPT AND NOT A STEP OF run_e.sh.
#   PREREG §4 and the local fabric queue both forbid building inside the measurement window
#   ("窗內全 repo 禁 commit／build／VM"), and this round's readout is a CPU plateau, so a compile
#   during it is a treatment rather than noise.  A build step hidden inside the measurement driver
#   would violate the round's own environment clause the first time it was needed.
#
# WHY THERE HAS TO BE A SECOND BINARY AT ALL  (PREREG 【TBD-1】).
#   There is no flag.  `kFlowPathRecomputeInterval` is
#       include/ndt_core/collection/FlowLinkUsageCollector.hpp:51
#           constexpr auto kFlowPathRecomputeInterval = std::chrono::seconds(1);
#   with a single use site at src/ndt_core/collection/FlowLinkUsageCollector.cpp:2969, and the
#   only getenv anywhere in the kernel's collection tree is NDTWIN_TOPO_FILE.  So 【TBD-1】's
#   "flag vs revert patch" has only one arm that exists: a second binary.  The remaining choice is
#   WHICH second binary, and that is a decision for the reviewer -- see TBD-DRAFT.md D3.  This
#   script implements the recommended option and refuses to pretend it is the only one.
#
# WHY NOT .test_run/binaries/ndtwin_kernel.ab2d7ed1, WHICH IS ALREADY 1 kHz.
#   Its own provenance file records commit=UNKNOWN and dirty_worktree=UNKNOWN.  Its delta from the
#   1 Hz binary beside it is therefore NOT established to be the one line this round wants to
#   vary; it is "everything that changed between two unrecorded trees".  Building both arms here,
#   from one frozen tree, makes the delta exactly one line and says so with a patch hash.
#
# 🔴 THE VALUE IS PROVEN, NOT ASSUMED.
#   Both arms carry the same SYMBOL, so `nm | grep` cannot tell them apart -- it separated the
#   older binaries only because they predate the constant's existence.  What separates these two
#   is a gtest that 2f57ba5 shipped for exactly this purpose:
#       FlowPathRecomputeInterval.IsOneSecondNotOneMillisecond
#   It must PASS on the 1 Hz build and FAIL on the 1 kHz build.  Both directions are required: a
#   check that can only come out one colour is not a check.  A 1 kHz build on which that test
#   passes has not got the patch in it.
#
# Usage:   ./build_1khz_binary.sh [<commit-ish to freeze at, default HEAD>]
#          DRY_RUN=1 ./build_1khz_binary.sh          # print the whole plan, build nothing
# =================================================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${ROUND:-}" ]] || . "$HERE/round.env"
LOG="$ROUND/build_arms.log"
# shellcheck source=lib_e.sh
. "$HERE/lib_e.sh"

FREEZE="${1:-HEAD}"
HPP="$KERNEL_DIR/include/ndt_core/collection/FlowLinkUsageCollector.hpp"
LINE_1HZ='constexpr auto kFlowPathRecomputeInterval = std::chrono::seconds(1);'
LINE_1KHZ='constexpr auto kFlowPathRecomputeInterval = std::chrono::microseconds(1000);'
BUILD="$KERNEL_DIR/build"

# -- preconditions -------------------------------------------------------------------------------
# 🔴 A build is the thing the measurement window forbids, so this script refuses to run while a
# measurement claim is held -- including this round's own.  The order is: build, THEN claim.
avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
say "=== build_1khz_binary: freeze=$FREEZE disk=${avail}G DRY_RUN=$DRY_RUN ==="
if (( avail < 5 )); then
    printf 'REFUSE: %sG free on /.  A kernel build needs headroom, and on 08-31 two container\n' "$avail" >&2
    printf '        builds took this machine to zero bytes free -- df itself stopped printing.\n' >&2
    exit 1
fi
claim="$KERNEL_DIR/.test_run/lab.claim"
if [[ -f "$claim" ]] && [[ "$DRY_RUN" != 1 ]]; then
    exp=$(sed -n 's/^expires=//p' "$claim"); now=$(date +%s)
    if [[ "${exp:-0}" =~ ^[0-9]+$ ]] && (( exp > now )); then
        printf 'REFUSE: a live lab claim exists (owner=%s, expires %s).\n' \
               "$(sed -n 's/^owner=//p' "$claim")" "$(date -d "@$exp" +%H:%M:%S)" >&2
        printf '        Building inside a measurement window is exactly what PREREG §4 forbids,\n' >&2
        printf '        and a compile is a treatment for a round whose readout is a CPU plateau.\n' >&2
        printf '        Build first, claim second.\n' >&2
        exit 1
    fi
fi
if [[ "$DRY_RUN" != 1 ]] && [[ -n "$(git -C "$KERNEL_DIR" status --porcelain -- "$HPP")" ]]; then
    printf 'REFUSE: %s already has uncommitted changes.\n' "$HPP" >&2
    printf '        This script edits that file and restores it; starting from a dirty state\n' >&2
    printf '        means the restore would not restore anything identifiable.\n' >&2
    exit 1
fi

RUN mkdir -p "$KBIN_STAGE"
FREEZE_SHA=$(git -C "$KERNEL_DIR" rev-parse "$FREEZE")
say "freezing at $FREEZE_SHA"

# -- one build ------------------------------------------------------------------------------------
build_arm() {   # $1 = tag (1hz|1khz), $2 = expected line, $3 = expect gtest pass|fail
    local tag="$1" want_line="$2" expect="$3" dest
    dest="$KBIN_STAGE/ndtwin_kernel.recompute-$tag"
    say "--- building arm '$tag' ---"

    # Assert the source says what this arm claims BEFORE compiling.  A sed that matched nothing is
    # reported by sed as success, and a build from an unchanged source is the failure that looks
    # exactly like a build from a changed one.
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would assert $HPP contains: $want_line"
        dry_note "would run: cmake --build $BUILD -j and copy bin/ndtwin_kernel -> $dest"
        dry_note "would run: ctest -R FlowPathRecomputeInterval and require it to $expect"
        dry_note "would write $dest.provenance"
        return 0
    fi
    grep -qF "$want_line" "$HPP" || {
        say "🔴 FATAL: $HPP does not contain the line this arm needs:"; say "    $want_line"; exit 1; }

    cmake --build "$BUILD" -j "$(nproc)" >>"$LOG" 2>&1 || { say "🔴 FATAL: build failed for $tag"; exit 1; }
    [[ -x "$BUILD/bin/ndtwin_kernel" ]] || { say "🔴 FATAL: no binary after build"; exit 1; }

    # 🔴 The two-directional proof.  2f57ba5 shipped this test so that a silent revert could not
    # stay green; here it is used the other way round, as the assay that says which arm this is.
    local rc=0
    ctest --test-dir "$BUILD" -R FlowPathRecomputeInterval --output-on-failure >>"$LOG" 2>&1 || rc=$?
    case "$expect" in
        pass) (( rc == 0 )) || { say "🔴 FATAL: arm '$tag' should PASS FlowPathRecomputeInterval, rc=$rc"; exit 1; }
              say "    gtest FlowPathRecomputeInterval: PASS, as required for the 1 Hz arm" ;;
        fail) (( rc != 0 )) || { say "🔴 FATAL: arm '$tag' should FAIL FlowPathRecomputeInterval but it PASSED.
    The one-line change is not in this binary.  Both arms would be the 1 Hz arm under two names,
    and Q2 would read a null result that never had a treatment in it."; exit 1; }
              say "    gtest FlowPathRecomputeInterval: FAIL (rc=$rc), as required for the 1 kHz arm" ;;
    esac

    cp -f "$BUILD/bin/ndtwin_kernel" "$dest"
    local sha; sha=$(sha256sum "$dest" | cut -d' ' -f1)
    {
        printf '# provenance for ndtwin_kernel.recompute-%s (E round arm)\n' "$tag"
        printf '# Written AT BUILD TIME, unlike .test_run/binaries/*.provenance which were\n'
        printf '# reconstructed after the fact and had to record commit=UNKNOWN.\n'
        printf 'sha256=%s\n' "$sha"
        printf 'size=%s\n' "$(stat -c%s "$dest")"
        printf 'commit=%s\n' "$FREEZE_SHA"
        printf 'dirty_worktree=%s\n' "$(git -C "$KERNEL_DIR" status --porcelain | grep -cv "$(basename "$HPP")")"
        printf 'recompute_interval_source_line=%s\n' "$want_line"
        printf 'source_file_sha256=%s\n' "$(sha256sum "$HPP" | cut -d' ' -f1)"
        printf 'gtest_FlowPathRecomputeInterval=%s (required: %s)\n' \
               "$( ((rc==0)) && echo pass || echo "fail(rc=$rc)")" "$expect"
        printf 'built_at=%s\n' "$(date -Is)"
        printf '# 🔴 mtime is NOT evidence: this repository has a binary on record as 26 s OLDER\n'
        printf '#    than the commit that describes it.  Use sha256.\n'
        printf -- '--- readelf -d (RUNPATH decides which .so actually loads; the environment does not) ---\n'
        readelf -d "$dest" | grep -E 'RUNPATH|RPATH|NEEDED'
        printf -- '--- ldd ---\n'
        ldd "$dest"
    } >"$dest.provenance"
    say "    staged $dest  sha256=$sha"
}

# 1 Hz first: it is the tree as frozen, so if this one does not build there is no point patching.
build_arm 1hz "$LINE_1HZ" pass

say "--- applying the one-line revert of 2f57ba5 (value only) ---"
if [[ "$DRY_RUN" == 1 ]]; then
    dry_note "would sed $HPP: seconds(1) -> microseconds(1000), then assert the line changed"
else
    sed -i "s|^${LINE_1HZ}\$|${LINE_1KHZ}|" "$HPP"
    grep -qF "$LINE_1KHZ" "$HPP" || { say "🔴 FATAL: the revert sed matched nothing"; exit 1; }
    # The patch is an artefact of the round and gets a hash, because "a one-line revert" is a
    # description and PREREG §4 asks for the patch's identity.
    git -C "$KERNEL_DIR" diff -- "$HPP" >"$KBIN_STAGE/revert-2f57ba5.patch"
    say "    patch sha256=$(sha256sum "$KBIN_STAGE/revert-2f57ba5.patch" | cut -d' ' -f1)"
fi

build_arm 1khz "$LINE_1KHZ" fail

say "--- restoring the frozen source ---"
if [[ "$DRY_RUN" == 1 ]]; then
    dry_note "would: git checkout -- $HPP ; rebuild ; assert the tree is clean again"
else
    git -C "$KERNEL_DIR" checkout -- "$HPP"
    grep -qF "$LINE_1HZ" "$HPP" || { say "🔴 FATAL: restore failed; $HPP is not back at seconds(1)"; exit 1; }
    cmake --build "$BUILD" -j "$(nproc)" >>"$LOG" 2>&1 || say "🔴 rebuild of the restored tree failed"
    # Negative control on the whole exercise: if the two staged arms are byte-identical, the
    # revert never reached the compiler and there is no second arm.
    a=$(sha256sum "$KBIN_1HZ" | cut -d' ' -f1); b=$(sha256sum "$KBIN_1KHZ" | cut -d' ' -f1)
    [[ "$a" != "$b" ]] || { say "🔴 FATAL: the two arms are byte-identical -- there is no second arm"; exit 1; }
    say "    1hz=$a"
    say "    1khz=$b"
fi
say "=== both arms staged in $KBIN_STAGE.  Claim the lab AFTER this, never before. ==="
