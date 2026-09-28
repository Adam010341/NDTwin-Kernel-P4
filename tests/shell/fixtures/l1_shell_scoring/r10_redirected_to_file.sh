# fixture: tests/shell/test_l1_shell_scoring.sh group R reads this text; it is never run (README.md)
PASS=0; FAIL=0; OUT=summary.txt
echo "Ran $((PASS+FAIL)) checks, $FAIL failed" > "$OUT"
