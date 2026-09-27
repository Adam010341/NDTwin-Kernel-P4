#!/usr/bin/env bash
# Does each round's round.env name the checkout it is IN, or the one it was written in?
#
# [Co-developed with claude code -- Adam]
#
# Both round.env files (the E round and the F-5 round) used to open with
#
#     export KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel
#
# and derive everything else from it: ROUND, OUT, PRIOR, ROUND25, TRH, the kernel binaries, the
# staging directory, the proxy venv. tests/shell/test_gate_exit_code_not_tee.sh and
# test_cell_gate_suspect_wiring.sh source the E one, as gates_e.sh does, so a suite run from a
# worktree or a clone read and mkdir'ed the MAIN checkout's paths while it believed it was testing
# its own tree -- a no-op where both exist, a new directory where they do not, and on any other
# machine a path that is not there. A gate run that way says nothing about the tree it ran in.
#
# The property: sourced from ANY checkout, with KERNEL_DIR unset and from ANY working directory,
# every path the file exports -- and every directory it creates -- is inside THAT checkout. An
# exported KERNEL_DIR is the one override (the same convention tools/test_workflow/components.env
# has), and it is honoured.
#
# How it is read without touching anything: a byte-identical copy of each round.env is planted at
# its real relative path inside a temp tree that is NOT this checkout, and sourced in a child bash
# whose `mkdir` is a function that records its arguments instead of creating anything. So the
# pre-fix file, which pointed at /home/adam/..., is observed pointing there and writes nothing.
#
# Run:  bash tests/shell/test_round_env_kernel_dir.sh
# Env:  E_ROUND_ENV_UNDER_TEST / F5_ROUND_ENV_UNDER_TEST=<path>  (the mutation gate's copies)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
E_REL=doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env
F_REL=doc/audit/2026-08-31_f5-fine-grid-round/round.env
E_SRC="${E_ROUND_ENV_UNDER_TEST:-$REPO_ROOT/$E_REL}"
F_SRC="${F5_ROUND_ENV_UNDER_TEST:-$REPO_ROOT/$F_REL}"

T="$(mktemp -d "${TMPDIR:-/tmp}/round-env-kdir-XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}

# plant <tree> <rel> <src> -- the file under test, byte for byte, at its real place in <tree>
plant() { mkdir -p "$1/$(dirname "$2")" && cp "$3" "$1/$2"; }

# resolve <cwd> <file as given to `.`> <var>... -- source it in a clean child and print
# `var=value` per variable, then `MKDIR <dir>` for every directory it asked for. KERNEL_DIR is
# unset unless the caller put KERNEL_DIR_FOR_CHILD in the environment.
resolve() {
    local cwd="$1" file="$2"; shift 2
    local set_kdir=()
    [[ -n "${KERNEL_DIR_FOR_CHILD:-}" ]] && set_kdir=("KERNEL_DIR=$KERNEL_DIR_FOR_CHILD")
    ( cd "$cwd" && env -u KERNEL_DIR -u ROUND -u OUT -u PRIOR -u ROUND25 -u TRH "${set_kdir[@]}" \
        bash -c '
            exec 3>&1     # the shim reports on fd 3: the file is sourced with stdout discarded
            mkdir() { local a; for a in "$@"; do [[ "$a" == -* ]] || printf "MKDIR %s\n" "$a" >&3; done; }
            f="$1"; shift
            . "$f" >/dev/null 2>&1
            for v in "$@"; do printf "%s=%s\n" "$v" "${!v-UNSET}"; done
            declare -F mkdir >/dev/null || echo "MKDIR-SHIM-LOST"
        ' _ "$file" "$@" ) 2>/dev/null
}

# outside <tree> <resolve output> -- every exported path and every mkdir that is NOT in <tree>
outside() {
    local tree="$1" line val
    while IFS= read -r line; do
        case "$line" in MKDIR-SHIM-LOST) echo "$line"; continue ;; esac
        val="${line#*=}"; [[ "$line" == MKDIR\ * ]] && val="${line#MKDIR }"
        [[ "$val" == /* ]] || continue
        [[ "$val" == "$tree" || "$val" == "$tree"/* ]] || echo "$line"
    done <<<"$2"
}

E_VARS=(KERNEL_DIR ROUND PRIOR PRIOR_RAW ROUND25 TOPO P4SRC P4BUILD KBIN KBIN_BACKUP KBIN_STAGE
        KBIN_1KHZ KBIN_1HZ PROXY_TREE_BLTRUE PY_PROXY OUT LOG_BASE CPU_BASELINE_FILE)
F_VARS=(KERNEL_DIR ROUND TRH OUT KBIN KBIN_PRE_T11 KBIN_BACKUP PY_PROXY LOG_BASE)

for round in E F5; do
    if [[ "$round" == E ]]; then rel="$E_REL"; src="$E_SRC"; vars=("${E_VARS[@]}"); want_mk=2
    else rel="$F_REL"; src="$F_SRC"; vars=("${F_VARS[@]}"); want_mk=1; fi
    echo "$round round: $rel"
    [[ -r "$src" ]] || { check "$round: the file under test is readable" "yes" "no: $src"; continue; }

    A="$T/$round/tree-a"; B="$T/$round/tree-b"; X="$T/$round/explicit"
    plant "$A" "$rel" "$src"; plant "$B" "$rel" "$src"; mkdir -p "$X"
    A="$(cd "$A" && pwd)"; B="$(cd "$B" && pwd)"; X="$(cd "$X" && pwd)"

    # 1. the checkout it is in, not the one it was written in
    out="$(resolve / "$A/$rel" "${vars[@]}")"
    check "🔴 $round: KERNEL_DIR is the tree the file sits in" "KERNEL_DIR=$A" "$(grep '^KERNEL_DIR=' <<<"$out")"
    check "🔴 $round: every path it exports is inside that tree" "" "$(outside "$A" "$out" | grep -v '^MKDIR ')"
    check "🔴 $round: every directory it creates is inside that tree" "" "$(outside "$A" "$out" | grep '^MKDIR ')"
    check "  $round: and it did ask to create them ($want_mk)" "$want_mk" "$(grep -c '^MKDIR /' <<<"$out")"
    check "  $round: and every variable was set" "" "$(grep '=UNSET$' <<<"$out")"

    # 2. not a constant that happens to equal one checkout: a second tree gets its own answer
    out_b="$(resolve / "$B/$rel" KERNEL_DIR ROUND OUT)"
    check "🔴 $round: a second checkout gets its own KERNEL_DIR" "KERNEL_DIR=$B" "$(grep '^KERNEL_DIR=' <<<"$out_b")"
    check "  $round: and its own ROUND" "ROUND=$B/$(dirname "$rel")" "$(grep '^ROUND=' <<<"$out_b")"

    # 3. not the caller's working directory: sourced as `. ./round.env` from the round's own
    #    directory, and from somewhere unrelated, the answer is the same
    out_c="$(resolve "$A/$(dirname "$rel")" ./round.env KERNEL_DIR)"
    check "🔴 $round: sourced relatively from its own directory" "KERNEL_DIR=$A" "$(grep '^KERNEL_DIR=' <<<"$out_c")"
    out_d="$(resolve "$B" "$A/$rel" KERNEL_DIR)"
    check "🔴 $round: sourced from inside ANOTHER checkout, it still names its own" "KERNEL_DIR=$A" "$(grep '^KERNEL_DIR=' <<<"$out_d")"

    # 4. the one override: an exported KERNEL_DIR is honoured, and everything follows it
    out_x="$(KERNEL_DIR_FOR_CHILD="$X" resolve / "$A/$rel" KERNEL_DIR ROUND)"
    check "$round: an exported KERNEL_DIR is honoured" "KERNEL_DIR=$X" "$(grep '^KERNEL_DIR=' <<<"$out_x")"
    check "  $round: and ROUND follows it" "ROUND=$X/$(dirname "$rel")" "$(grep '^ROUND=' <<<"$out_x")"

    # 5. the instrument itself: the mkdir shim was in force (a sourcing that lost it would have
    #    created real directories, and the MKDIR lines above would be missing, not wrong)
    check "  $round: (the mkdir shim was in force)" "" "$(grep 'MKDIR-SHIM-LOST' <<<"$out$out_b$out_x")"
done

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
