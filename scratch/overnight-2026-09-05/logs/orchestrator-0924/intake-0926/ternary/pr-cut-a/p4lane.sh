#!/usr/bin/env bash
# p4lane.sh <clone>: run section "3. P4 proxy Python tests" of <clone>/tools/test_workflow/l1_unit_tests.sh VERBATIM (sed-extracted),
# after sourcing the script in its NDTWIN_L1_LIB_ONLY mode (colours, KERNEL_DIR, LOG_DIR, P4_BUILD_DIR as the script defines them).
c="${1:-$PWD}"; cd "$c" || exit 2
export NDTWIN_L1_LIB_ONLY=1
source "$c/tools/test_workflow/l1_unit_tests.sh"
unset NDTWIN_L1_LIB_ONLY
FAILURES=0
step() { echo; echo "${D}--- $* ---${N}"; }
mkdir -p "$LOG_DIR"
eval "$(sed -n '/^# --- 3\. P4 proxy Python tests/,/^# --- 3b\./p' "$c/tools/test_workflow/l1_unit_tests.sh" | sed '$d')"
echo "FAILURES=$FAILURES"
exit $FAILURES
