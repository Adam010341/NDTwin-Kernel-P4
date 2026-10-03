#!/usr/bin/env python3
# make_gates_b4.py <gates_b3.sh> <gates_b4.sh> -- round 4's driver from round 3's.
import sys

s = open(sys.argv[1]).read()


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:80]
    s = s.replace(old, new)


rep("# gates_b3.sh -- feat/external-detect-only-0927 round 3",
    "# gates_b4.sh -- feat/external-detect-only-0927 round 4 (Adam's 09-28 ruling: no guessed destination paths\n"
    "# on an external control plane; its heartbeat only after the offline drop check; trunk 08f67b7a merged):\n"
    "# redfirst_b4, test_heartbeat_drop_check and mutate_heartbeat_drop_check added; the drop check's throwaway\n"
    "# simple_switch runs through a wrapper that records every launch in the tripwire log as ALLOWED-LAUNCH\n"
    "# (the orchestrator's conditions, 09-28), and the tripwire gate checks each launched pid is gone.\n"
    "# gates_b3.sh -- feat/external-detect-only-0927 round 3")
rep("TAG=${TAG:-extb3}", "TAG=${TAG:-extb4}")
rep('cp "${BASH_SOURCE[0]}" "$S/gates_b3.sh"', 'cp "${BASH_SOURCE[0]}" "$S/gates_b4.sh"')
rep('cp "$SP/aeg/"{redfirst_b,redfirst_b2,redfirst_b3,redfirst_lib,proxy_unit}.sh',
    'cp "$SP/aeg/"{redfirst_b,redfirst_b2,redfirst_b3,redfirst_b4,redfirst_lib,proxy_unit}.sh')
rep('''bash "$S/make_shims.sh" "$S/shims" > /dev/null
( cd "$S" && sha256sum *.sh hbsnap.sha256 shims/* > SHA256SUMS )''', '''bash "$S/make_shims.sh" "$S/shims" > /dev/null
#: [Co-developed with claude code -- Adam] The drop check's throwaway switch: allowed (orchestrator, 09-28),
#: and recorded -- every launch is a line in the tripwire log, with the pid it runs as (exec keeps it).
mkdir -p "$S/hbcheck"
cat > "$S/hbcheck/simple_switch" <<'WRAP'
#!/usr/bin/env bash
printf '%s ALLOWED-LAUNCH simple_switch pid=%s argv0=%s args=%s\\n' "$(date +%s.%N)" "$$" "${NDT_HB_CHECK_ARGV0:-?}" "$*" >> "$NOLAB_LOG"
exec -a "${NDT_HB_CHECK_ARGV0:-ndt-hbdrop-bmv2}" /usr/local/bin/simple_switch "$@"
WRAP
chmod +x "$S/hbcheck/simple_switch"
( cd "$S" && sha256sum *.sh hbsnap.sha256 shims/* hbcheck/* > SHA256SUMS )''')
rep('''export PATH="$S/shims:$PATH" NOLAB_LOG="$S/tripwire.log" NOLAB_SUITE=gates NOLAB_PASS=$TAG NOLAB_FAKE_FABRIC=0''',
    '''export PATH="$S/shims:$PATH" NOLAB_LOG="$S/tripwire.log" NOLAB_SUITE=gates NOLAB_PASS=$TAG NOLAB_FAKE_FABRIC=0
export NDT_HB_CHECK_BMV2="$S/hbcheck/simple_switch"''')
rep('''run redfirst_b3 0 - bash "$S/redfirst_b3.sh" "$WT" "$(k redfirst_b3)"
''', '''run redfirst_b3 0 - bash "$S/redfirst_b3.sh" "$WT" "$(k redfirst_b3)"
run redfirst_b4 0 - bash "$S/redfirst_b4.sh" "$WT" "$(k redfirst_b4)"
''')
rep('''run test_drive_exercise 0 -''', '''run test_heartbeat_drop_check 0 - python3 tests/shell/test_heartbeat_drop_check.py
run test_drive_exercise 0 -''')
rep('''run mutate_ndt_app_package 0 - bash tests/shell/mutate_ndt_app_package.sh
''', '''run mutate_ndt_app_package 0 - bash tests/shell/mutate_ndt_app_package.sh
run mutate_heartbeat_drop_check 0 - bash tests/shell/mutate_heartbeat_drop_check.sh
''')
old_trip = s[s.index("run nolab_tripwire 0 - bash -c '"):s.index('echo "GATES-$TAG $sha:')]
new_trip = r'''run nolab_tripwire 0 - bash -c '
echo "lab commands the gates above made past their own stubs:"
pat=" (sudo|mnexec|iperf|iperf3|ping|cmake|ninja|make|gcc|g\+\+|c\+\+|cc|clang|clang\+\+) |localhost:80[08][01]|127\.0\.0\.1:80[08][01]"
/usr/bin/grep -v " ALLOWED-LAUNCH " "$1" | /usr/bin/grep -E "$pat" | sed "s/^/  /"
n=$(/usr/bin/grep -v " ALLOWED-LAUNCH " "$1" | /usr/bin/grep -cE "$pat")
a=$(/usr/bin/grep -c " ALLOWED-LAUNCH " "$1")
echo "  ($(/usr/bin/grep -c "" "$1") line(s) in the shims log in all; $a of them the drop check'"'"'s allowed simple_switch launches)"
alive=0
for pid in $(sed -n "s/.* ALLOWED-LAUNCH simple_switch pid=\([0-9]*\) .*/\1/p" "$1" | sort -un); do
    if [[ -r /proc/$pid/cmdline ]] && [[ "$(tr "\0" " " < /proc/$pid/cmdline)" == ndt-hbdrop-bmv2* ]]; then
        echo "  🔴 allowed launch pid $pid is STILL running: $(tr "\0" " " < /proc/$pid/cmdline | cut -c1-120)"; alive=$((alive+1))
    fi
done
echo "  allowed launches still running at the end: $alive"
echo "NOLAB-TRIPWIRE: $n lab call(s) (all refused); $a allowed launch(es), $alive left running"; (( n == 0 && alive == 0 ))' _ "$NOLAB_LOG"
'''
s = s.replace(old_trip, new_trip)
open(sys.argv[2], "w").write(s)
print("ok")
