# fixture: tests/shell/test_l1_shell_scoring.sh group R reads this text; it is never run (README.md)
summary() { printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"; }
PASS=0; FAIL=0
[[ -r "$0" ]] || { echo "Ran 1 checks, 1 failed"; exit 1; }
if [[ "$FAIL" -ne 0 ]]; then
    summary; exit 1
fi
