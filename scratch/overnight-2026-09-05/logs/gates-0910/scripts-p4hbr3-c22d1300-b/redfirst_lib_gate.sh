#!/usr/bin/env bash
# redfirst_lib_gate.sh <redfirst_lib.sh> -- Q2: the lib's self-check passes, and a mutant that stops
# telling a line after SELF-TEST PASS apart (the `pl < total` branch gone) fails exactly that check.
# [Co-developed with claude code -- Adam]
set -u
LIB="$1"; T=$(mktemp -d "${TMPDIR:-/tmp}/rflib-gate-XXXXXX"); trap 'rm -rf "$T"' EXIT
echo "== the lib"
bash "$LIB" --self-check; rc1=$?
echo "== mutant Q2-1: SELF-TEST PASS need not be the last line"
sed 's/^    elif (( pl < total )); then$/    elif false; then/' "$LIB" > "$T/m.sh"
/usr/bin/grep -q '^    elif false; then$' "$T/m.sh" || { echo "the mutation did not apply"; exit 2; }
out="$(bash "$T/m.sh" --self-check 2>&1)"; rc2=$?
/usr/bin/grep '🔴' <<<"$out" | sed 's/^/    /'
if [[ $rc1 == 0 && $rc2 != 0 ]] && /usr/bin/grep -qF '🔴    🔴 a line AFTER SELF-TEST PASS is told apart from a clean pass' <<<"$out"; then
    echo "REDFIRST-LIB-GATE: self-check PASS; Q2-1 caught by its named check"; exit 0
fi
echo "REDFIRST-LIB-GATE: BROKEN (self-check rc $rc1, mutant rc $rc2)"; exit 1
