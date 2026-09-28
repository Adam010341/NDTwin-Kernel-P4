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
# worktree or a clone resolved and mkdir'ed the MAIN checkout's paths while it believed it was
# testing its own tree. A gate run that way says nothing about the tree it ran in.
#
# The property: sourced by bash from ANY checkout, with KERNEL_DIR unset and from ANY working
# directory (CDPATH set or not), EVERY variable the file exports that holds an absolute path, and
# EVERY write it asks for, is inside THAT checkout. An exported KERNEL_DIR is the one override
# (tools/test_workflow/components.env's convention); it is honoured when it names a checkout and
# refused when it does not (a relative one included: it would follow the caller's cwd). Sourced
# any other way -- by dash, or as text with no file behind it (`bash -c "$(cat round.env)"`, or
# `eval` in an INTERACTIVE bash, which must survive the refusal), or from a copy that sits in no
# checkout -- it refuses, says why, and derives nothing: the old `${BASH_SOURCE[0]:?}` guard sat
# inside two command substitutions, so it failed only its own subshell and the file went on to
# derive KERNEL_DIR=/. The dash case runs only where dash is installed and says NOT RUN otherwise.
#
# What it does NOT promise, shown as today's behaviour ("inherited"): KERNEL_DIR, CPU_BASELINE_FILE
# and PY_PROXY are overrides, so a shell that sourced another tree's round.env keeps that tree's
# values -- all of them if nothing is unset, the last two even when KERNEL_DIR and ROUND are.
#
# How it is read without touching anything: a byte-identical copy of each round.env is planted at
# its real relative path inside a temp tree that is NOT this checkout, and sourced by a child shell
# with an EMPTY environment (env -i: no inherited KERNEL_DIR, CPU_BASELINE_FILE, PY_PROXY, ...) and
# PATH shims for every command that writes (mkdir install cp mv ln touch rm rmdir tee chmod). The
# shims record their arguments and write nothing, so the pre-fix file, which pointed at
# /home/adam/..., is observed pointing there and changes nothing. Every exported variable is
# found by diffing the exported set before and after sourcing -- not from a list kept here.
#
# The two consumer suites are run too (section "consumers"), because the fix is only as good as
# the suites that source the file: with KERNEL_DIR inherited from the caller pointing at another
# tree they must still test THIS checkout, and test_cell_gate_suspect_wiring.sh must fail -- not
# skip green -- when its interpreter is missing. These runs execute the real suites, whose
# round.env mkdir's this checkout's (gitignored) doc/audit/<E round>/raw and .test_run/... as any
# run of those suites does.
#
# Run:  bash tests/shell/test_round_env_kernel_dir.sh
# Env:  E_ROUND_ENV_UNDER_TEST / F5_ROUND_ENV_UNDER_TEST=<path>  (the mutation gate's copies)
#       GATE_EXIT_SUITE_UNDER_TEST / CELL_WIRING_SUITE_UNDER_TEST=<path>  (copies in tests/shell)
#       ROUND_ENV_CONSUMERS=0  skips the consumer section (the gate, for round.env-only mutants)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
E_REL=doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env
F_REL=doc/audit/2026-08-31_f5-fine-grid-round/round.env
E_SRC="${E_ROUND_ENV_UNDER_TEST:-$REPO_ROOT/$E_REL}"
F_SRC="${F5_ROUND_ENV_UNDER_TEST:-$REPO_ROOT/$F_REL}"
GATE_EXIT_SUITE="${GATE_EXIT_SUITE_UNDER_TEST:-$HERE/test_gate_exit_code_not_tee.sh}"
CELL_WIRING_SUITE="${CELL_WIRING_SUITE_UNDER_TEST:-$HERE/test_cell_gate_suspect_wiring.sh}"

T="$(mktemp -d "${TMPDIR:-/tmp}/round-env-kdir-XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"

PASS=0; FAIL=0; NOTRUN=0
notrun() { NOTRUN=$((NOTRUN+1)); printf '  NOT RUN  %s\n' "$1"; }
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}
has() {     # <name> <needle> <haystack>
    if grep -qF -- "$2" <<<"$3"; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             no match for: [%s]\n' "$1" "$2"
         sed -n '1,4p' <<<"$3" | sed 's/^/             in: /'; fi
}

# --- the write shims: every command that could write, recorded and made harmless ---------------
SHIM="$T/shim"; mkdir -p "$SHIM"
for c in mkdir install cp mv ln touch rm rmdir tee chmod; do
    printf '#!/bin/sh\nprintf "WRITE %s %%s\\n" "$*" >> "$SHIM_LOG"\nexit 0\n' "$c" > "$SHIM/$c"
    chmod +x "$SHIM/$c"
done

# plant <tree> <rel> <src> -- the file under test, byte for byte, at its real place in <tree>
plant() { mkdir -p "$1/$(dirname "$2")" && cp "$3" "$1/$2"; }

# resolve <tag> <cwd> <file as given to `.`> [NAME=value...] -- source it with bash in an empty
# environment; leaves $T/<tag>.{rc,err,writes,exports,mkdir_is}. Exports are the variables that
# are exported afterwards and were not, or held another value, before: `name<TAB>value`.
resolve() {
    local tag="$1" cwd="$2" file="$3"; shift 3
    : > "$T/$tag.writes"
    ( cd "$cwd" && env -i PATH="$SHIM:$PATH" HOME="$HOME" SHIM_LOG="$T/$tag.writes" "$@" bash -c '
        declare -A was=()
        for v in $(compgen -e); do was[$v]="${!v}"; done
        . "$1" >/dev/null 2>"$2.err"; echo "$?" > "$2.rc"
        for v in $(compgen -e | sort); do
            [[ "$v" == SHIM_LOG || "$v" == PATH || "$v" == HOME || "$v" == PWD || "$v" == OLDPWD || "$v" == SHLVL || "$v" == _ ]] && continue
            if [[ -z "${was[$v]+set}" || "${was[$v]}" != "${!v}" || "$v" == KERNEL_DIR ]]; then
                val="${!v}"; printf "%s\t%s\n" "$v" "${val//$'"'"'\n'"'"'/\\n}"
            fi
        done > "$2.exports"
        command -v mkdir > "$2.mkdir_is"
    ' _ "$file" "$T/$tag" ) 2>/dev/null
}
val() { awk -F'\t' -v n="$2" '$1==n {print $2}' "$T/$1.exports"; }   # val <tag> <NAME>

# outside <tag> <tree> -- every exported absolute path, and every path a write names, not in <tree>
# PY_PLOT is exempt by name: it is the machine's interpreter for the plots (round.env says why),
# not a path in any checkout.
outside_exports() {
    awk -F'\t' '$1 != "PY_PLOT" && $2 ~ /^\// {print}' "$T/$1.exports" | while IFS=$'\t' read -r n v; do
        [[ "$v" == "$2" || "$v" == "$2"/* ]] && [[ "$v" != *'\n'* ]] || printf '%s=%s\n' "$n" "$v"
    done
}
outside_writes() {
    tr ' ' '\n' < "$T/$1.writes" | grep '^/' | while read -r p; do
        [[ "$p" == "$2" || "$p" == "$2"/* ]] || echo "$p"
    done
}
nwrites() { grep -c '^WRITE ' "$T/$1.writes"; }

for round in E F5; do
    if [[ "$round" == E ]]; then rel="$E_REL"; src="$E_SRC"; want_mk=2
    else rel="$F_REL"; src="$F_SRC"; want_mk=1; fi
    echo "$round round: $rel"
    [[ -r "$src" ]] || { check "$round: the file under test is readable" "yes" "no: $src"; continue; }
    slug="$(dirname "$rel")"

    A="$T/$round/tree-a"; B="$T/$round/tree-b"; X="$T/$round/explicit"; NX="$T/$round/not-a-tree"
    plant "$A" "$rel" "$src"; plant "$B" "$rel" "$src"; mkdir -p "$X/doc/audit" "$NX"

    # 1. the checkout it is in, not the one it was written in -- and every export and write in it
    resolve "$round-a" / "$A/$rel"
    check "🔴 $round: KERNEL_DIR is the tree the file sits in" "$A" "$(val "$round-a" KERNEL_DIR)"
    check "🔴 $round: every absolute path it exports is inside that tree" "" "$(outside_exports "$round-a" "$A")"
    check "🔴 $round: every write it asks for is inside that tree" "" "$(outside_writes "$round-a" "$A")"
    check "  $round: and it did ask for its directories ($want_mk mkdir argument(s))" "$want_mk" \
          "$(grep '^WRITE mkdir ' "$T/$round-a.writes" | tr ' ' '\n' | grep -c '^/')"
    check "  $round: and it exported the round's core variables" "KERNEL_DIR LOG_BASE OUT ROUND" \
          "$(awk -F'\t' '$1=="KERNEL_DIR"||$1=="ROUND"||$1=="OUT"||$1=="LOG_BASE" {print $1}' "$T/$round-a.exports" | sort | tr '\n' ' ' | sed 's/ $//')"
    check "  $round: (the write shims were in force)" "$SHIM/mkdir" "$(cat "$T/$round-a.mkdir_is")"

    # 2. not a constant that happens to equal one checkout: a second tree gets its own answer
    resolve "$round-b" / "$B/$rel"
    check "🔴 $round: a second checkout gets its own KERNEL_DIR" "$B" "$(val "$round-b" KERNEL_DIR)"
    check "  $round: and its own ROUND" "$B/$slug" "$(val "$round-b" ROUND)"

    # 3. not the caller's working directory, and not CDPATH
    resolve "$round-c" "$A/$slug" ./round.env
    check "🔴 $round: sourced as ./round.env from its own directory" "$A" "$(val "$round-c" KERNEL_DIR)"
    resolve "$round-d" "$B" "$A/$rel"
    check "🔴 $round: sourced from inside ANOTHER checkout, it still names its own" "$A" "$(val "$round-d" KERNEL_DIR)"
    resolve "$round-cdpath" "$A" "$rel" CDPATH="$B"
    check "🔴 $round: the documented relative form ignores CDPATH" "$A" "$(val "$round-cdpath" KERNEL_DIR)"

    # 4. the one override: an exported KERNEL_DIR is honoured when it is a checkout, refused if not
    resolve "$round-x" / "$A/$rel" KERNEL_DIR="$X"
    check "$round: an exported KERNEL_DIR is honoured" "$X" "$(val "$round-x" KERNEL_DIR)"
    check "  $round: and ROUND follows it" "$X/$slug" "$(val "$round-x" ROUND)"
    resolve "$round-nx" / "$A/$rel" KERNEL_DIR="$NX"
    has "🔴 $round: an exported KERNEL_DIR that is no checkout is refused" "is not a checkout" "$(cat "$T/$round-nx.err")"
    check "  $round: and nothing is written" "0" "$(nwrites "$round-nx")"
    resolve "$round-rel" "$X" "$A/$rel" KERNEL_DIR=.        # cwd IS a checkout-shaped tree
    has "🔴 $round: a relative exported KERNEL_DIR is refused, even from inside a checkout" \
        "is not a checkout (an absolute path" "$(cat "$T/$round-rel.err")"
    check "  $round: and derives nothing from it" "" "$(val "$round-rel" ROUND)"
    check "  $round: and nothing is written" "0" "$(nwrites "$round-rel")"

    # 5. sourced any other way: refused, told why, nothing derived, nothing written
    cp "$src" "$T/$round.loose.env"          # directly in the temp dir: ../../.. of it is / here
    loose_to="$(cd "$T/../../.." && pwd)"
    mkdir -p "$T/$round/deep/in/no"; cp "$src" "$T/$round/deep/in/no/round.env"
    resolve "$round-loose" / "$T/$round.loose.env"
    echo "  (a copy directly in $T: ../../.. of it is $loose_to)"
    has "🔴 $round: a copy outside any checkout refuses" "is not a checkout" "$(cat "$T/$round-loose.err")"
    check "  $round: and derives no KERNEL_DIR (the old file derived that parent)" "" "$(val "$round-loose" KERNEL_DIR)"
    check "  $round: and writes nothing" "0" "$(nwrites "$round-loose")"
    resolve "$round-deep" / "$T/$round/deep/in/no/round.env"
    has "🔴 $round: a copy in a directory that is no checkout refuses" "is not a checkout" "$(cat "$T/$round-deep.err")"

    if DASH="$(command -v dash)"; then
        : > "$T/$round-sh.writes"
        ( cd / && env -i PATH="$SHIM:$PATH" SHIM_LOG="$T/$round-sh.writes" "$DASH" -c \
            '. "$1"; echo "rc=$?"; echo "KERNEL_DIR=${KERNEL_DIR-UNSET}"' _ "$A/$rel" \
            > "$T/$round-sh.out" 2> "$T/$round-sh.err" )
        has "🔴 $round: dash is told to use bash" "round.env: source this file with bash" "$(cat "$T/$round-sh.err")"
        has "  $round: and the source fails" "rc=1" "$(cat "$T/$round-sh.out")"
        has "  $round: and derives nothing" "KERNEL_DIR=UNSET" "$(cat "$T/$round-sh.out")"
        check "  $round: and writes nothing" "0" "$(nwrites "$round-sh")"
    else
        notrun "🔴 $round: dash is told to use bash (no dash on PATH; the bash guard is untested here)"
    fi

    : > "$T/$round-text.writes"
    ( cd / && env -i PATH="$SHIM:$PATH" SHIM_LOG="$T/$round-text.writes" \
        bash -c "trap 'echo KERNEL_DIR=\${KERNEL_DIR-UNSET}' EXIT; $(cat "$A/$rel")" \
        > "$T/$round-text.out" 2> "$T/$round-text.err"; echo "exit=$?" >> "$T/$round-text.out" )
    has "🔴 $round: sourced as text (empty BASH_SOURCE) it refuses" "round.env: source this file by its path" "$(cat "$T/$round-text.err")"
    has "  $round: and exits 1" "exit=1" "$(cat "$T/$round-text.out")"
    has "  $round: and derives nothing (was / before)" "KERNEL_DIR=UNSET" "$(cat "$T/$round-text.out")"
    check "  $round: and writes nothing" "0" "$(nwrites "$round-text")"

    # eval'd in an INTERACTIVE bash: the refusal must abort the eval, not exit the operator's shell.
    # $((6*7)) is expanded only if the next command RUNS (an echoed input line shows it literally).
    : > "$T/$round-int.writes"
    printf 'eval "$(cat %q)"\necho "NEXT $((6*7)) KD=${KERNEL_DIR-UNSET}"\n' "$A/$rel" \
        | ( cd / && env -i PATH="$SHIM:$PATH" HOME="$T" HISTFILE=/dev/null SHIM_LOG="$T/$round-int.writes" \
            bash --norc --noprofile -i > "$T/$round-int.out" 2> "$T/$round-int.err" )
    has "🔴 $round: eval'd in an interactive bash it refuses" "round.env: source this file by its path" "$(cat "$T/$round-int.err")"
    has "🔴 $round: and the interactive shell survives (its next command runs)" "NEXT 42 KD=" "$(cat "$T/$round-int.out")"
    has "  $round: and the rest of the file did not run" "NEXT 42 KD=UNSET" "$(cat "$T/$round-int.out")"
    check "  $round: and writes nothing" "0" "$(nwrites "$round-int")"

    # inherited (today's behaviour, documented in round.env): no env -i between two sourcings
    : > "$T/$round-inh.writes"
    ( cd / && env -i PATH="$SHIM:$PATH" SHIM_LOG="$T/$round-inh.writes" bash -c '
        . "$1"; . "$2"
        echo "both KERNEL_DIR=$KERNEL_DIR ROUND=$ROUND PY_PROXY=$PY_PROXY CPU_BASELINE_FILE=${CPU_BASELINE_FILE-UNSET}"
        unset KERNEL_DIR ROUND; . "$2"
        echo "reset KERNEL_DIR=$KERNEL_DIR ROUND=$ROUND PY_PROXY=$PY_PROXY CPU_BASELINE_FILE=${CPU_BASELINE_FILE-UNSET}"
    ' _ "$A/$rel" "$B/$rel" > "$T/$round-inh.out" 2>&1 )
    inh() { sed -n "s/^$1 .*$2=\([^ ]*\).*/\1/p" "$T/$round-inh.out"; }
    check "  $round: (inherited) B sourced after A in one shell names A throughout" "$A $A/$slug $A/p4_proxy/venv/bin/python" \
          "$(inh both KERNEL_DIR) $(inh both ROUND) $(inh both PY_PROXY)"
    check "  $round: (inherited) with KERNEL_DIR and ROUND unset first, B is named but PY_PROXY stays A's" \
          "$B $B/$slug $A/p4_proxy/venv/bin/python" "$(inh reset KERNEL_DIR) $(inh reset ROUND) $(inh reset PY_PROXY)"
    if [[ "$round" == E ]]; then
        check "  $round: (inherited) and so does CPU_BASELINE_FILE" "$A/$slug/raw/cpu_baseline.json" "$(inh reset CPU_BASELINE_FILE)"
    fi
done

# --- consumers: the two suites that source the E round.env --------------------------------------
if [[ "${ROUND_ENV_CONSUMERS:-1}" != 0 ]]; then
    echo "consumers"
    ELSE="$T/elsewhere"; mkdir -p "$ELSE/doc/audit"    # a checkout-shaped tree round.env would accept
    PT="$T/passthru"; mkdir -p "$PT"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$MKDIR_LOG"\nexec %s "$@"\n' "$(command -v mkdir)" > "$PT/mkdir"
    chmod +x "$PT/mkdir"
    for suite in "$GATE_EXIT_SUITE" "$CELL_WIRING_SUITE"; do
        name="$(basename "$suite" .sh)"; name="${name##.mutant-*-}"
        : > "$T/$name.mkdir"
        out="$(KERNEL_DIR="$ELSE" MKDIR_LOG="$T/$name.mkdir" PATH="$PT:$PATH" timeout 600 bash "$suite" 2>&1)"
        has "🔴 $name: under an inherited KERNEL_DIR it still tests this checkout" \
            "  ok       round.env resolved KERNEL_DIR to this checkout" "$out"
        check "  $name: and nothing it creates is in the inherited tree" "" \
              "$(tr ' ' '\n' < "$T/$name.mkdir" | grep -F "$ELSE" || true)"
    done
    out="$(PY_PROXY="$T/no-such-venv/bin/python" timeout 600 bash "$CELL_WIRING_SUITE" 2>&1)"; rc=$?
    name="$(basename "$CELL_WIRING_SUITE" .sh)"; name="${name##.mutant-*-}"
    check "🔴 $name: a missing interpreter is a failure, not a green skip (rc)" "1" "$rc"
    has "  $name: and it says what is missing" "no interpreter at PY_PROXY=$T/no-such-venv/bin/python" "$out"
fi

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed$( (( NOTRUN )) && echo ", $NOTRUN NOT RUN")"
[[ "$FAIL" -eq 0 ]]
