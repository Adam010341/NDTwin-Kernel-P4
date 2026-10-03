#!/usr/bin/env bash
# tripwire_b6.sh <shim log>... -- the nolab tripwire of round 6 (round 5's, plus: the cwd of every switch launch
# must sit under $TRIPWIRE_TMP_ROOT, the gates' TMPDIR -- required), ENFORCING the orchestrator's 09-28
# conditions on the drop check's throwaway switch (round-5 ruling on M-4), over every log given (this
# driver's own, and any earlier extb5 driver's). [Co-developed with claude code -- Adam]
#   1. lab calls: sudo, mnexec, iperf(3), ping, a C++ build, the lab's REST ports -- any one is red;
#   2. every launch line the wrappers wrote (make_hbwrap.sh): a REFUSED-LAUNCH line is red (a gate
#      ASKED for a switch that breaks a condition); every ALLOWED-LAUNCH line is re-checked here, not
#      trusted: argv0 ndt-hbdrop-bmv2, uid not 0, cwd a directory named ndt-hbdrop-*, --use-files,
#      every -i N@pN, --thrift-port 29400-29499, --device-id >= 900000, --notifications-addr exactly
#      ipc://notif.ipc, a relative --log-file, no argument naming simple_switch*; every ALLOWED-PROBE
#      line: argv0 ndt-hbdrop-bmv2, args exactly --version, uid not 0;
#   3. liveness BY PID: every logged pid (launches and probes) whose /proc/<pid> still exists with the
#      same start time (field 22 of /proc/<pid>/stat, as logged) is a process still running -- red.
set -u
(( $# > 0 )) || { echo "usage: tripwire_b6.sh <shim log>..."; exit 2; }
[[ -n "${TRIPWIRE_TMP_ROOT:-}" ]] || { echo "tripwire_b6.sh: TRIPWIRE_TMP_ROOT (the gates' TMPDIR) is required"; exit 2; }
pat=" (sudo|mnexec|iperf|iperf3|ping|cmake|ninja|make|gcc|g\+\+|c\+\+|cc|clang|clang\+\+) |localhost:80[08][01]|127\.0\.0\.1:80[08][01]"
lab=0; refused=0; badline=0; alive=0; launches=0; probes=0; lines=0
for log in "$@"; do
    [[ -r "$log" ]] || { echo "  🔴 unreadable log $log"; lab=$((lab+1)); continue; }
    n=$(/usr/bin/grep -c "" "$log"); lines=$((lines+n))
    echo "log $log: $n line(s)"
    m=$(/usr/bin/grep -vE " (ALLOWED-LAUNCH|ALLOWED-PROBE|REFUSED-LAUNCH) " "$log" | /usr/bin/grep -cE "$pat")
    /usr/bin/grep -vE " (ALLOWED-LAUNCH|ALLOWED-PROBE|REFUSED-LAUNCH) " "$log" | /usr/bin/grep -E "$pat" | head -5 | sed 's/^/  🔴 lab call: /'
    lab=$((lab+m))
    r=$(/usr/bin/grep -c " REFUSED-LAUNCH " "$log"); refused=$((refused+r))
    /usr/bin/grep " REFUSED-LAUNCH " "$log" | head -5 | cut -c1-240 | sed 's/^/  🔴 /'
    out="$(python3 - "$log" <<'PY'
import os, re, sys
ROOT = os.path.realpath(os.environ["TRIPWIRE_TMP_ROOT"])
bad = alive = launches = probes = 0
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"^\S+ (ALLOWED-LAUNCH|ALLOWED-PROBE) (\S+) pid=(\d+) start=(\d+) uid=(\d+) argv0=(\S+) cwd=(\S+) exe=(\S+) args=(.*)$", line.rstrip("\n"))
    if not m:
        if " ALLOWED-" in line:
            bad += 1; print(f"  🔴 an allowed line this check cannot read: {line[:200]}")
        continue
    kind, which, pid, start, uid, a0, cwd, exe, args = m.groups()
    why = []
    if uid == "0": why.append("uid 0")
    if a0 != "ndt-hbdrop-bmv2": why.append(f"argv0 {a0}")
    a = args.split()
    if any(os.path.basename(x).startswith("simple_switch") for x in a): why.append("an argument names simple_switch")
    if kind == "ALLOWED-PROBE":
        probes += 1
        if a != ["--version"]: why.append(f"a probe with args {a}")
    else:
        launches += 1
        def after(f):
            return a[a.index(f) + 1] if f in a and a.index(f) + 1 < len(a) else None
        t, dev, notif, logf = after("--thrift-port"), after("--device-id"), after("--notifications-addr"), after("--log-file")
        if which != "simple_switch": why.append(f"a switch from the {which} wrapper")
        if not os.path.basename(cwd).startswith("ndt-hbdrop-") or os.path.basename(cwd).startswith("ndt-hbdrop-ver-"): why.append(f"cwd {cwd}")
        if not os.path.realpath(cwd).startswith(ROOT + os.sep): why.append(f"cwd {cwd} not under {ROOT}")
        if "--use-files" not in a: why.append("not --use-files")
        ifs = [a[i + 1] for i, x in enumerate(a) if x == "-i" and i + 1 < len(a)]
        if not ifs or any(not re.fullmatch(r"(\d+)@p\1", x) for x in ifs): why.append(f"interfaces {ifs}")
        if not (t and t.isdigit() and 29400 <= int(t) <= 29499): why.append(f"thrift {t}")
        if not (dev and dev.isdigit() and int(dev) >= 900000): why.append(f"device id {dev}")
        if notif != "ipc://notif.ipc": why.append(f"notifications {notif}")
        if not logf or logf.startswith("/"): why.append(f"log file {logf}")
    if why:
        bad += 1; print(f"  🔴 {kind} pid {pid} breaks a condition ({'; '.join(why)}): {line[:160]}")
    try:
        st = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
        if st[19] == start:
            alive += 1; print(f"  🔴 {kind} pid {pid} (start {start}) is STILL running: {open(f'/proc/{pid}/cmdline','rb').read().replace(b'\\0', b' ')[:120]!r}")
    except (OSError, IndexError):
        pass
print(f"COUNTS {bad} {alive} {launches} {probes}")
PY
)"
    printf '%s\n' "$out" | /usr/bin/grep -v '^COUNTS ' | head -20
    read -r _ b a l p <<<"$(printf '%s\n' "$out" | /usr/bin/grep '^COUNTS ')"
    badline=$((badline+${b:-1})); alive=$((alive+${a:-0})); launches=$((launches+${l:-0})); probes=$((probes+${p:-0}))
done
echo "NOLAB-TRIPWIRE: $lab lab call(s); $launches allowed switch launch(es) and $probes --version probe(s), each re-checked: $badline breaking a condition, $refused refused by the wrapper; $alive still running (by pid and start time); $lines line(s) in all"
(( lab == 0 && refused == 0 && badline == 0 && alive == 0 ))
