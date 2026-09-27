#!/usr/bin/env bash
# redfirst_lib.sh -- the red-first checks every round's redfirst script sources (Q2, 09-27).
# [Co-developed with claude code -- Adam]
#   green <label> <output file>              -- a CLEAN SELF-TEST PASS: that line is the LAST line,
#                                               and no red line anywhere above it
#   exactly_red <label> <output file> <case>... -- SELF-TEST FAIL with exactly those cases red, once
# Both KEEP the output of any run that does not answer as expected -- under $KEEP (default: a
# directory beside the script's temp root) -- and print why, in one of four words: no PASS line;
# PASS not last (with how many lines follow it and the first of them); red lines above a PASS;
# (exactly_red) the red set differs. redfirst_r2b's first green() kept nothing, printed "not a
# clean PASS", and one 08-at-HEAD run in 56 is unexplained to this day because of it.
#   bash redfirst_lib.sh --self-check        -- the four answers above, and the keeping, on fixtures
: "${bad:=0}"
_rf_keep() {   # _rf_keep <label> <output file> -> where it was kept
    local k="${KEEP:-${TMPDIR:-/tmp}/redfirst-kept}" n
    mkdir -p "$k"; n="$k/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_').out.txt"
    cp "$2" "$n"; printf '%s' "$n"
}
green() {   # green <label> <output file>
    local label="$1" out="$2" total pl reds why=""
    total="$(wc -l < "$out")"
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

if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --self-check ]]; then
    set -u
    T="$(mktemp -d "${TMPDIR:-/tmp}/redfirst-lib-XXXXXX")"; trap 'rm -rf "$T"' EXIT
    export KEEP="$T/kept"; fails=0
    chk() { if [[ "$2" == "$3" ]]; then echo "  ok    $1"; else echo "  🔴    $1 -- got '$3', want '$2'"; fails=1; fi; }
    printf '  ok    a\n  ok    b\nSELF-TEST PASS\n' > "$T/clean"
    printf '  ok    a\nSELF-TEST PASS\n08_heartbeat.sh: line 1386: 4242 Killed  setsid python3 -I -c ...\n' > "$T/trailing"
    printf '  ok    a\n  🔴    b -- wrong\nSELF-TEST PASS\n' > "$T/redpass"
    printf '  ok    a\n  🔴    b -- wrong\nSELF-TEST FAIL\n' > "$T/fail"
    : > "$T/empty"
    o="$(green clean "$T/clean")"; r=$?
    chk "a clean PASS is green, and nothing is kept" "0 ok" "$r $( [[ -d "$KEEP" ]] && echo kept || echo ok)"
    o="$(green trailing "$T/trailing")"; r=$?
    chk "🔴 a line AFTER SELF-TEST PASS is told apart from a clean pass" "1" "$r"
    chk "  and says what it is" "yes" "$( [[ "$o" == *"SELF-TEST PASS is not the last line: 1 line(s) after it, the first '08_heartbeat.sh: line 1386: 4242 Killed"* ]] && echo yes || echo "no: $o")"
    chk "  and keeps the output" "yes" "$( cmp -s "$KEEP/trailing.out.txt" "$T/trailing" && echo yes || echo no)"
    o="$(green redpass "$T/redpass")"; r=$?
    chk "a PASS line under a red line is not green" "1 yes" "$r $( [[ "$o" == *"1 red line(s) above SELF-TEST PASS"* ]] && echo yes || echo no)"
    o="$(green fail "$T/fail")"; r=$?
    chk "a FAIL is not green" "1 yes" "$r $( [[ "$o" == *"no SELF-TEST PASS line (last line: 'SELF-TEST FAIL')"* ]] && echo yes || echo no)"
    o="$(green empty "$T/empty")"; r=$?
    chk "no output at all is not green" "1" "$r"
    o="$(exactly_red fail "$T/fail" "b")"; r=$?
    chk "exactly_red: the one expected case, red once, FAIL last" "0" "$r"
    o="$(exactly_red fail2 "$T/fail" "b" "c")"; r=$?
    chk "exactly_red: a case expected but not red is BAD, and kept" "1 yes" "$r $( [[ -s "$KEEP/fail2.out.txt" ]] && echo yes || echo no)"
    o="$(exactly_red trailing "$T/trailing")"; r=$?
    chk "exactly_red: a PASS is not a red-first run" "1" "$r"
    echo "REDFIRST-LIB SELF-CHECK: $([[ $fails == 0 ]] && echo PASS || echo FAIL)"
    exit $fails
fi
