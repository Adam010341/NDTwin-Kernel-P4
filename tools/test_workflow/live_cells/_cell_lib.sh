#!/usr/bin/env bash
#
# live_cells/_cell_lib.sh -- the two halves every regression cell is made of.
#
# [Co-developed with claude code -- Adam]
#
# A CELL is one reproducible action sequence plus one expected verdict. It is not a role and it
# is not a test suite: a cell enters this directory when a defect was seen RED on the live lab
# (or run for real offline) and then fixed, and it never leaves. The monotone number the night
# round reports is "how many cells are red"; a cell going red is a 🔴 at the top of the wakeup
# note and a must-fix that night.
#
# Every cell script has exactly two sub-commands, and the split is the whole design:
#
#   observe <rawdir>   drives the lab (or the tool) and writes RAW files. It judges nothing.
#   judge   <rawdir>   a pure function of that directory. It touches no lab, no network, no
#                      clock and no git -- so it can be pointed at LAST NIGHT'S logs, which is
#                      how the cell's own red is obtained without rebuilding last night's binary.
#
# 🔴 The judge may not read anything outside <rawdir>. The moment it consults the machine, the
# fixture stops being able to reproduce a verdict and `tests/shell/mutate_live_cells.sh` is
# grading an instrument against itself.
#
# Assertion vocabulary. Every assertion carries an ID, and the ID is load-bearing: the gate
# compares the SET of failing ids against the fixture's EXPECTED-FAILS file, so deleting an
# assertion changes the set and the gate goes red. A judge whose assertions are anonymous can
# lose one silently.
#
#   a_have <id> <file>              the raw file exists and is not empty
#   a_eq   <id> <expected> <actual> exact string equality
#   a_has  <id> <needle> <file>     the file contains this fixed string
#   a_hasnt <id> <needle> <file>    ... and this one it must NOT contain
#   a_re   <id> <ere> <file>        the file matches this extended regex
#
# Output shape, one line per assertion, machine-read by the gate and by run_cells.sh:
#
#   ASSERT ok   <id>  <detail>
#   ASSERT FAIL <id>  <detail>
#
# and one verdict line per cell:
#
#   CELL: PASS|FAIL|SKIP <name> tag=<tag> kernel=<sha16> ndt=<git blob sha> at=<date>
#
# kernel= and ndt= are read from <rawdir>/ids.txt, which `observe` writes -- the identification
# travels WITH the raw, so a judge run months later still names the binary that produced it and
# an old fixture names last night's. Absent means `unknown`, never this machine's current sha:
# benchmark 必指認 binary, and a judge that fills the gap from its own tree would be inventing
# provenance for somebody else's evidence.
#
# Exit: 0 PASS, 1 FAIL, 3 SKIP (the cell declined to run -- its precondition was not there).
set -uo pipefail
export NO_COLOR=1

CELL_FAILS=0
CELL_ASSERTS=0

_a_ok()   { CELL_ASSERTS=$((CELL_ASSERTS+1)); printf 'ASSERT ok   %-38s %s\n' "$1" "${2:-}"; }
_a_bad()  { CELL_ASSERTS=$((CELL_ASSERTS+1)); CELL_FAILS=$((CELL_FAILS+1))
            printf 'ASSERT FAIL %-38s %s\n' "$1" "${2:-}"; }

a_have() {  # <id> <file>
    if [[ -s "$2" ]]; then _a_ok "$1" "$(basename "$2") present"
    else _a_bad "$1" "$(basename "$2") is missing or empty"; fi
}

a_eq() {    # <id> <expected> <actual>
    if [[ "$2" == "$3" ]]; then _a_ok "$1" "= [$2]"
    else _a_bad "$1" "expected [$2] actual [$3]"; fi
}

a_has() {   # <id> <needle> <file>
    if [[ ! -r "$3" ]]; then _a_bad "$1" "no such raw file: $(basename "$3")"; return; fi
    if grep -qF -- "$2" "$3"; then _a_ok "$1" "$(basename "$3") contains it"
    else _a_bad "$1" "$(basename "$3") does not contain [$2]"; fi
}

a_hasnt() { # <id> <needle> <file>
    if [[ ! -r "$3" ]]; then _a_bad "$1" "no such raw file: $(basename "$3")"; return; fi
    if grep -qF -- "$2" "$3"; then _a_bad "$1" "$(basename "$3") still contains [$2]"
    else _a_ok "$1" "$(basename "$3") does not contain it"; fi
}

a_re() {    # <id> <ere> <file>
    if [[ ! -r "$3" ]]; then _a_bad "$1" "no such raw file: $(basename "$3")"; return; fi
    if grep -qE -- "$2" "$3"; then _a_ok "$1" "$(basename "$3") matches"
    else _a_bad "$1" "$(basename "$3") does not match /$2/"; fi
}

# rawfield <rawdir> <file> <key> -- the value of `key=` in a key=value raw file, first hit.
rawfield() { sed -n "s/^$3=//p" "$1/$2" 2>/dev/null | head -1; }

# --- identification --------------------------------------------------------------------------
# Written by observe, read by judge. `git hash-object` and not a sha256 for ndt: the blob sha is
# the identifier that can be looked up in this repository's history, which is what a reader of a
# red cell needs -- and it is the identifier CELLS.md's "fix commit" column is in.
cell_write_ids() {  # <rawdir>   (uses NDT_ROOT and REPO_ROOT from the caller)
    local d="$1" kern="unknown" ndtid="unknown" root="${NDT_ROOT:-${REPO_ROOT:-.}}"
    if [[ -r "$root/build/bin/ndtwin_kernel" ]]; then
        kern="$(sha256sum "$root/build/bin/ndtwin_kernel" | cut -c1-16)"
    fi
    if [[ -r "$root/tools/test_workflow/ndt" ]]; then
        ndtid="$(git -C "$root" hash-object "$root/tools/test_workflow/ndt" 2>/dev/null \
                 || git hash-object "$root/tools/test_workflow/ndt" 2>/dev/null || echo unknown)"
    fi
    { printf 'kernel=%s\n' "$kern"
      printf 'ndt=%s\n' "$ndtid"
      printf 'ndt_root=%s\n' "$root"
      printf 'at=%s\n' "$(date -Iseconds)"
    } > "$d/ids.txt"
}

# cell_skip <rawdir> <reason> -- observe declined. judge reports SKIP and asserts nothing.
cell_skip() { printf '%s\n' "$2" > "$1/SKIP"; printf 'SKIP: %s\n' "$2"; }

# cell_verdict <name> <tag> <rawdir> -- the last line, and this function's rc is the cell's rc.
cell_verdict() {
    local name="$1" tag="$2" d="$3" state kern ndtid at
    kern="$(rawfield "$d" ids.txt kernel)";  kern="${kern:-unknown}"
    ndtid="$(rawfield "$d" ids.txt ndt)";    ndtid="${ndtid:-unknown}"
    at="$(rawfield "$d" ids.txt at)";        at="${at:-unknown}"
    if [[ -f "$d/SKIP" ]]; then
        state=SKIP
    elif (( CELL_FAILS > 0 )); then
        state=FAIL
    elif (( CELL_ASSERTS == 0 )); then
        # 🔴 A judge that asserted NOTHING is not a pass. This is the zero-discriminating-power
        # case the night rounds keep re-learning: an empty raw directory, a judge whose every
        # `a_has` was deleted, or a cell whose observe wrote no files at all would otherwise
        # report PASS and be counted as evidence.
        printf 'ASSERT FAIL %-38s %s\n' "judge_asserted_something" \
               "the judge made no assertions -- an empty judge cannot pass"
        state=FAIL
    else
        state=PASS
    fi
    printf 'CELL: %s %s tag=%s kernel=%s ndt=%s at=%s\n' "$state" "$name" "$tag" "$kern" "$ndtid" "$at"
    case "$state" in PASS) return 0 ;; SKIP) return 3 ;; *) return 1 ;; esac
}

# --- the boilerplate every cell script ends with ----------------------------------------------
# cell_main <name> <tag> <requires> "$@" -- dispatches observe/judge/meta.
# `meta` is how run_cells.sh reads a cell's tag and requirement without sourcing it, so a cell
# that cannot even be parsed is a loud error in the runner rather than an absent row.
cell_main() {
    local name="$1" tag="$2" requires="$3"; shift 3
    local sub="${1:-}"; shift || true
    case "$sub" in
        meta)    printf 'name=%s\ntag=%s\nrequires=%s\n' "$name" "$tag" "$requires"; return 0 ;;
        observe) [[ -n "${1:-}" ]] || { echo "usage: $name observe <rawdir>" >&2; return 2; }
                 mkdir -p "$1" || return 2
                 cell_observe "$1" ;;
        judge)   [[ -n "${1:-}" ]] || { echo "usage: $name judge <rawdir>" >&2; return 2; }
                 [[ -d "$1" ]] || { echo "no such raw directory: $1" >&2; return 2; }
                 cell_judge "$1"
                 cell_verdict "$name" "$tag" "$1" ;;
        *)       echo "usage: $(basename "$0") {observe|judge|meta} [rawdir]" >&2; return 2 ;;
    esac
}
