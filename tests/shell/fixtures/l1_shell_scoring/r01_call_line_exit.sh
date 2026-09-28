# fixture: tests/shell/test_l1_shell_scoring.sh group R reads this text; it is never run (README.md)
PASS=0; FAIL=0
summary() { printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"; }
if [[ "$FAIL" -ne 0 ]]; then
    summary; exit 1
fi
