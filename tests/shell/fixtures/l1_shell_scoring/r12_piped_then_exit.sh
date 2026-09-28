# fixture: tests/shell/test_l1_shell_scoring.sh group R reads this text; it is never run (README.md)
PASS=0; FAIL=0
LOG=suite.log
if (( FAIL )); then echo "Ran $((PASS+FAIL)) checks, $FAIL failed" | tee -a "$LOG"; exit 1; fi
