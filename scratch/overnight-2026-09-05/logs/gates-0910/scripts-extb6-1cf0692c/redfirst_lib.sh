#!/usr/bin/env bash
# redfirst_lib.sh -- the red-first checks every round's redfirst script sources (Q2, 09-27; R3-N1 and
# R3-N2 of the r3 opus judge, 09-27). [Co-developed with claude code -- Adam]
#   green <label> <output file>              -- a CLEAN SELF-TEST PASS: that line is the LAST line,
#                                               and no red line anywhere above it
#   exactly_red <label> <output file> <case>... -- SELF-TEST FAIL with exactly those cases red, once
# Both KEEP the output of any run that does not answer as expected -- under $KEEP -- and print why,
# in one of four words: no PASS line; PASS not last (with how many lines follow it and the first of
# them); red lines above a PASS; (exactly_red) the red set differs.
#   R3-N1: lines are counted with awk's NR, not `wc -l` -- wc counts NEWLINES, so a last line with
#          none (a trailing "Killed" cut off mid-write) was not a line, and a PASS above it read as
#          the last one.
#   R3-N2: KEEP, unset, is a per-run directory under logs/gates-0910 -- beside the gate logs, where
#          it survives the run (the r3 driver's default sat inside its own temp root, deleted at exit).
#   bash redfirst_lib_check.sh <this file>   -- the answers above, and the keeping, on fixtures
: "${bad:=0}"
RF_GATES_DIR="${RF_GATES_DIR:-/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910}"
RF_KEEP_DEFAULT="$RF_GATES_DIR/redfirst-kept/$(date -u +%Y%m%dT%H%M%SZ)-$$"
_rf_lines() { awk 'END { print NR }' "$1"; }
_rf_keep() {   # _rf_keep <label> <output file> -> where it was kept
    local k="${KEEP:-$RF_KEEP_DEFAULT}" n
    mkdir -p "$k"; n="$k/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_').out.txt"
    cp "$2" "$n"; printf '%s' "$n"
}
green() {   # green <label> <output file>
    local label="$1" out="$2" total pl reds why=""
    total="$(_rf_lines "$out")"
    pl="$(/usr/bin/grep -n '^SELF-TEST PASS$' "$out" | tail -1 | cut -d: -f1)"
    reds="$(/usr/bin/grep -c '^  🔴 ' "$out")"
    if [[ -z "$pl" ]]; then
        why="no SELF-TEST PASS line (last line: '$(tail -1 "$out" | cut -c1-120)')"
    elif (( pl < total )); then
        why="SELF-TEST PASS is not the last line: $((total - pl)) line(s) after it, the first '$(sed -n "$((pl + 1))p" "$out" | cut -c1-120)'"
    elif (( reds > 0 )); then
        why="$reds red line(s) above SELF-TEST PASS"
    fi
    if [[ -z "$why" ]]; then
        echo "  ok    $label: SELF-TEST PASS, the last line ($(/usr/bin/grep -c '^  ok ' "$out") ok, 0 red)"
        return 0
    fi
    echo "  BAD   $label: $why"
    /usr/bin/grep '^  🔴 ' "$out" | cut -c1-240 | sed 's/^/    /'
    echo "    (output kept: $(_rf_keep "$label" "$out"))"
    bad=1; return 1
}
exactly_red() {   # exactly_red <label> <output file> <expected red case>...
    local label="$1" out="$2" n want got fine=1; shift 2
    got="$(/usr/bin/grep -c '^  🔴 ' "$out")"
    /usr/bin/grep '^  🔴 ' "$out" | cut -c1-190 | sed 's/^/    /'
    [[ "$got" == "$#" ]] && echo "  ok    $label: $got red line(s), as many as expected" \
        || { echo "  BAD   $label: $got red line(s), $# expected"; fine=0; }
    for want in "$@"; do
        n="$(/usr/bin/grep '^  🔴 ' "$out" | /usr/bin/grep -cF -- "$want")"
        [[ "$n" == 1 ]] && echo "  ok    $label: red once -- $want" || { echo "  BAD   $label: '$want' red $n time(s)"; fine=0; }
    done
    [[ "$(tail -1 "$out")" == "SELF-TEST FAIL" ]] && echo "  ok    $label: SELF-TEST FAIL, the last line" \
        || { echo "  BAD   $label: last line '$(tail -1 "$out" | cut -c1-120)'"; fine=0; }
    (( fine )) && return 0
    echo "    (output kept: $(_rf_keep "$label" "$out"))"
    bad=1; return 1
}
