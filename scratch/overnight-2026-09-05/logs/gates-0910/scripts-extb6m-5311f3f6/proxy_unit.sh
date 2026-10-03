#!/usr/bin/env bash
# proxy_unit.sh <worktree> -- every p4_proxy/tests/test_*.py, each file executed directly the way the
# L1 lane does (they are not a package: `unittest discover` cannot import them), with the proxy's
# venv, no byte-code. [Co-developed with claude code -- Adam]
#
# rc 0 only if every file ran tests, said OK, and at least one of its tests was NOT skipped. Skipped
# tests are counted and printed apart from passed ones (the opus judge's N4 on the aeg4 run, 09-27:
# `OK (skipped=N)` read as plain OK, and a file whose every test skipped -- a proxy dependency
# missing -- would have been "ok"). The one exception is the L1 lane's own: a file carrying the token
# NDTWIN_L1_OPT_IN (test_p4_client.py, the opt-in live-switch check) is skipped by design.
set -u
cd "$1/p4_proxy" || exit 2
bad=0; files=0; ran=0; skipped_total=0; passed=0; failed_files=0
for f in tests/test_*.py; do
    files=$((files+1))
    out="$(PYTHONDONTWRITEBYTECODE=1 timeout 600 venv/bin/python "$f" 2>&1)"; rc=$?
    n="$(sed -n -E 's/^Ran ([0-9]+) tests?.*/\1/p' <<<"$out" | tail -1)"; n="${n:-0}"
    last="$(/usr/bin/grep -E '^(OK|FAILED)' <<<"$out" | tail -1)"
    sk="$(sed -n -E 's/.*skipped=([0-9]+).*/\1/p' <<<"$last")"; sk="${sk:-0}"
    ran=$((ran+n)); skipped_total=$((skipped_total+sk))
    if [[ $rc != 0 || "$last" != OK* || $n == 0 ]]; then
        bad=1; failed_files=$((failed_files+1)); echo "  FAILED   $f: rc $rc, ran $n, '$last'"
        /usr/bin/grep -E '^(FAIL|ERROR):' <<<"$out" | head -5 | sed 's/^/             /'
    elif (( sk == n )) && /usr/bin/grep -q NDTWIN_L1_OPT_IN "$f"; then
        # the repo's own L1 lane convention (tools/test_workflow/l1_unit_tests.sh): a file carrying
        # this token is a live-switch opt-in whose fully skipped run is the intended outcome
        echo "  ok       $f: $n skipped by design (NDTWIN_L1_OPT_IN: an opt-in live-switch test)"
    elif (( sk == n )); then
        bad=1; failed_files=$((failed_files+1)); echo "  FAILED   $f: every one of its $n test(s) SKIPPED -- nothing was tested ('$last')"
    else
        passed=$((passed+n-sk)); echo "  ok       $f: $((n-sk)) passed, $sk skipped"
    fi
done
# (the AEG judge's N-9, 09-28: "passed" used to be ran - skipped, counting a failed file's tests)
echo "PROXY-UNIT: $files file(s), $ran test(s): $passed passed in OK files, $skipped_total skipped, $failed_files file(s) FAILED -- $([[ $bad == 0 ]] && echo 'all OK' || echo 'SOME FAILED')"
exit $bad
