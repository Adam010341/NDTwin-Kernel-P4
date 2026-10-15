#!/usr/bin/env bash
# klane.sh : run section "3b. kernel-side Python and shell tests" of $PWD/tools/test_workflow/l1_unit_tests.sh VERBATIM (sed-extracted),
# after sourcing the script in its NDTWIN_L1_LIB_ONLY mode (colours, KERNEL_DIR, LOG_DIR, scoring functions, L1_NEED_MET as the script defines them).
# The clone is $PWD (ci4.sh does the cd). NDT_HB_CHECK_BMV2 points at a path that does not exist (a hosted runner has no simple_switch).
c="$PWD"
export NDTWIN_L1_LIB_ONLY=1
source "$c/tools/test_workflow/l1_unit_tests.sh"
unset NDTWIN_L1_LIB_ONLY
FAILURES=0
step() { echo; echo "${D}--- $* ---${N}"; }
mkdir -p "$LOG_DIR"
eval "$(sed -n '/^# --- 3b\. kernel-side Python and shell tests/,/^# --- 4\. cross-check/p' "$c/tools/test_workflow/l1_unit_tests.sh" | sed '$d')"
echo "FAILURES=$FAILURES"
exit $FAILURES
