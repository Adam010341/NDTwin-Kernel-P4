#!/usr/bin/env bash
#
# Tests for `ndtwin-lab heartbeat` -- TICKET-P4-heartbeat, segment H.
#
# [Co-developed with claude code -- Adam]
#
# The subject is a ROOT entry point: after `sudo install`, anything running as adam can type
# `sudo ndtwin-lab heartbeat ...`. So most of what is tested here is what it REFUSES, and every
# refusal is exercised for real where a non-root test can make the real thing:
#
#   * the command line (section 1): one sub-verb and nothing after it. Interfaces, paths and
#     ethertypes cannot be passed in, and nothing typed is ever expanded;
#   * starting (section 2): no fabric -> refused; a live daemon -> no second one; the plan runs
#     in the foreground and a refused plan launches nothing;
#   * stopping (section 3): the pid in the pidfile is signalled only when /proc says its argv is
#     EXACTLY the daemon's and its uid is the daemon's. The stranger cases use REAL processes this
#     suite starts -- a `sleep`, and a python whose argv is one word off -- and assert they are
#     still alive afterwards. Garbage pidfiles go through a recording `hb_signal`, so a `-1` can
#     never reach a real kill;
#   * the program root runs (sections 4-7), loaded from the helper's own heredoc and driven with
#     fixture manifests, a fake /sys/class/net and a fake /proc: which interfaces it will use,
#     what counts as HEARD (the two ways that could lie), that its report decides nothing, and
#     that its cadence and ethertype are pinned to the proxy's constants and to the 13 tutorials
#     parsers.
#
# 🔴 Nothing here needs root, opens a packet socket, touches the lab or signals a process it did
#    not start itself. `cleanup` stops what this suite started, by the pid it recorded, after
#    /proc says that pid is still the thing it started.
#
# Run:  bash tests/shell/test_ndtwin_lab_heartbeat.sh
#   HB_TEST_PY  the interpreter the program is loaded with (default /usr/bin/python3 -- the one
#               root runs it with)
#   PYTHON      the proxy's venv interpreter, for section 7's pin to topology_manager's constants
#               (default: this checkout's p4_proxy/venv, else the main checkout's)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$HERE/../../tools/test_workflow/ndtwin-lab"
REPO="$(cd "$HERE/../.." && pwd)"
HB_TEST_PY="${HB_TEST_PY:-/usr/bin/python3}"
if [[ -z "${PYTHON:-}" ]]; then
    if [[ -x "$REPO/p4_proxy/venv/bin/python" ]]; then PYTHON="$REPO/p4_proxy/venv/bin/python"
    else PYTHON=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python; fi
fi

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }

# shellcheck source=/dev/null
source "$LAB" || { echo "  FAILED   could not source $LAB"; echo "Ran 1 checks, 1 failed"; exit 1; }
# The helper runs under `set -euo pipefail`; a suite about refusals cannot (test_ndtwin_lab_config.sh
# measured what errexit does to such a suite: it stops early and still looks like a pass).
set +e

TMPROOT="$(mktemp -d /tmp/ndtwin-lab-heartbeat-XXXXXX)"
STARTED=()      # pids this suite started; cleanup stops only these
cleanup() {
    local p
    for p in "${STARTED[@]}"; do
        # Only if /proc still says it is ours: a child of this shell whose argv names TMPROOT.
        if [[ -r "/proc/$p/cmdline" ]] && tr '\0' ' ' < "/proc/$p/cmdline" | grep -qF "$TMPROOT"; then
            kill -KILL "$p" 2>/dev/null
        fi
        wait "$p" 2>/dev/null
    done
    [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndtwin-lab-heartbeat-* ]] && rm -rf "$TMPROOT"
    return 0
}
trap cleanup EXIT INT TERM

# Every path the section uses, pointed into TMPROOT; the uid the daemon must have is ours.
HB_RUN_DIR="$TMPROOT/run"
mkdir -m 0755 "$HB_RUN_DIR"
HB_PROGRAM="$HB_RUN_DIR/heartbeat.py"
HB_PIDFILE="$HB_RUN_DIR/heartbeat.pid"
HB_LOG="$HB_RUN_DIR/heartbeat.log"
HB_EXPECT_UID="$(id -u)"
HB_START_STEPS=40
HB_STOP_STEPS=30
CALLS="$TMPROOT/calls"

# alive <pid> -- a live, unreaped, non-zombie process.
alive() {
    local st
    st="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)"
    [[ -n "$st" && "$st" != Z && "$st" != X ]] && echo yes || echo no
}
# fake_daemon <program-file> [extra argv...] -- a python whose argv is the daemon's (plus extras).
fake_daemon() {
    local prog="$1"; shift
    "$HB_PYTHON" -I "$prog" daemon "$@" </dev/null >/dev/null 2>&1 &
    FAKE=$!
    STARTED+=("$FAKE")
    local i; for i in $(seq 1 50); do
        [[ "$(tr '\0' ' ' < "/proc/$FAKE/cmdline" 2>/dev/null)" == *daemon* ]] && break
        sleep 0.05
    done
}
printf 'import time\ntime.sleep(30)\n' > "$TMPROOT/sleeper.py"
cp "$TMPROOT/sleeper.py" "$HB_PROGRAM"

# ============================================================================================
echo "1. the command line: one sub-verb, nothing after it"

# Every action recorded instead of performed, in a subshell so the stubs die with it.
dispatch() {   # dispatch <args...> -- "<rc>|<actions>|<stderr>"
    : > "$CALLS"
    local err rc
    err="$( ( hb_start()  { echo start  >> "$CALLS"; }
              hb_stop()   { echo stop   >> "$CALLS"; }
              hb_status() { echo status >> "$CALLS"; }
              heartbeat_main "$@" ) 2>&1 >/dev/null )"
    rc=$?
    printf '%s|%s|%s' "$rc" "$(paste -sd, "$CALLS")" "$err"
}
r="$(dispatch start)";              check "start reaches hb_start and only it"          "0|start"  "${r%|*}"
r="$(dispatch stop)";               check "stop reaches hb_stop and only it"            "0|stop"   "${r%|*}"
r="$(dispatch status)";             check "status reaches hb_status and only it"        "0|status" "${r%|*}"
r="$(dispatch)";                    check "no sub-verb is refused, nothing runs"        "1|"       "${r%%|*}|$(cut -d'|' -f2 <<<"$r")"
r="$(dispatch restart)";            check "an unknown sub-verb is refused, nothing runs" "1|"      "${r%%|*}|$(cut -d'|' -f2 <<<"$r")"
r="$(dispatch start s1-eth1)";      check "start with an interface name is refused"     "1|"       "${r%%|*}|$(cut -d'|' -f2 <<<"$r")"
check "  and the refusal says only the sub-verb is accepted" yes "$(has "nothing else is accepted" "$r")"
r="$(dispatch start --iface wlp0s20f3)";      check "start --iface is refused, nothing runs"      "1|" "${r%%|*}|$(cut -d'|' -f2 <<<"$r")"
r="$(dispatch start --ethertype 0x0800)";     check "start --ethertype is refused, nothing runs"  "1|" "${r%%|*}|$(cut -d'|' -f2 <<<"$r")"
r="$(dispatch start --manifest /tmp/mine.json)"; check "start --manifest is refused, nothing runs" "1|" "${r%%|*}|$(cut -d'|' -f2 <<<"$r")"
r="$(dispatch stop 4242)";          check "stop with a pid is refused, nothing runs"    "1|"       "${r%%|*}|$(cut -d'|' -f2 <<<"$r")"

# Nothing typed is expanded, sourced or executed -- as a verb or as an extra argument.
r="$(dispatch "\$(touch $TMPROOT/pwned1)")"
check "a \$(...) verb is refused"                   1  "${r%%|*}"
check "  and the \$(...) verb did not run"          no "$( [[ -e "$TMPROOT/pwned1" ]] && echo yes || echo no )"
r="$(dispatch start "\$(touch $TMPROOT/pwned2)")"
check "a \$(...) argument after start is refused"   1  "${r%%|*}"
check "  and the \$(...) argument did not run"      no "$( [[ -e "$TMPROOT/pwned2" ]] && echo yes || echo no )"
r="$(dispatch "start;touch $TMPROOT/pwned3")"
check "'start;touch' is one unknown word"           1  "${r%%|*}"
check "  and nothing was touched"                   no "$( [[ -e "$TMPROOT/pwned3" ]] && echo yes || echo no )"
( cd "$TMPROOT" && touch globbed-a globbed-b )
r="$( cd "$TMPROOT" && dispatch '*' )"
check "a '*' is refused"                            1  "${r%%|*}"
check "  and the refusal quotes it literally"       yes "$(has 'verb \* (want' "$r")"
check "  and was not globbed into file names"       no "$(has globbed-a "$r")"

# Source reads: the dispatch is unreachable from a sourced file (sudo always execs), so the wiring
# is pinned by text. What IS tested by behaviour is heartbeat_main, above.
check "the dispatch routes 'heartbeat' to heartbeat_main with the rest of argv" 1 \
    "$(grep -cE '^    heartbeat\) +shift; hb_rc=0; heartbeat_main "\$@" \|\| hb_rc=\$\?; exit "\$hb_rc" ;;$' "$LAB")"
check "the usage line names the heartbeat verbs" yes "$(has 'heartbeat {start|stop|status}' "$(grep 'die "usage: ndtwin-lab' "$LAB")")"

# ============================================================================================
echo "2. start: a fabric first, one daemon only, the plan before the launch"

start_with() {   # start_with <topo:0|1> <plan rc> <live pid or ""> -- "<rc>|<actions>|<out+err>"
    : > "$CALLS"
    local out rc
    out="$( ( session_running() { echo "session $1" >> "$CALLS"; return "$TOPO"; }
              hb_run()           { echo "run $1" >> "$CALLS"; return "$PLAN_RC"; }
              hb_launch()        { echo launch >> "$CALLS"; HB_LAUNCHED=999999; }
              hb_install_program() { echo install >> "$CALLS"; }
              hb_pid()           { [[ -n "$LIVE" ]] && { echo "$LIVE"; return 0; }; return 1; }
              hb_proc_gone()     { return 0; }
              wait()             { return 1; }
              hb_start ) 2>&1 )"
    rc=$?
    printf '%s|%s|%s' "$rc" "$(paste -sd, "$CALLS")" "$out"
}
r="$(TOPO=1 PLAN_RC=0 LIVE="" start_with)"
check "no topo session: refused"                        1 "${r%%|*}"
check "  and nothing was installed, planned or launched" "session topo" "$(cut -d'|' -f2 <<<"$r")"
check "  and it says there is no fabric"                yes "$(has "no fabric is running" "$r")"

r="$(TOPO=0 PLAN_RC=0 LIVE=4242 start_with)"
check "a live daemon: start answers 0"                  0 "${r%%|*}"
check "  and says it is already running"                yes "$(has "already running (pid 4242)" "$r")"
check "  and launches nothing"                          no "$(has launch "$(cut -d'|' -f2 <<<"$r")")"

r="$(TOPO=0 PLAN_RC=1 LIVE="" start_with)"
check "a refused plan: start fails with the plan's rc"  1 "${r%%|*}"
check "  the plan ran, and nothing was launched"        "session topo,install,run plan" "$(cut -d'|' -f2 <<<"$r")"

r="$(TOPO=0 PLAN_RC=3 LIVE="" start_with)"
check "a fabric with no switch-to-switch link: rc 3"    3 "${r%%|*}"
check "  and nothing was launched"                      no "$(has launch "$(cut -d'|' -f2 <<<"$r")")"

r="$(TOPO=0 PLAN_RC=0 LIVE="" start_with)"
check "a good plan launches exactly once, after the plan" "session topo,install,run plan,launch" "$(cut -d'|' -f2 <<<"$r")"

# The real launch path, with a stand-in program: it writes its own pid and sleeps, the way the
# daemon does once it holds the lock. `start` must find THAT pid by argv and say so.
real_start() {   # real_start <program body> -- "<rc>|<out+err>"; the program is launched for real
    printf '%s\n' "$1" > "$TMPROOT/standin.py"
    local out rc
    out="$( ( session_running() { return 0; }
              hb_install_program() { cp "$TMPROOT/standin.py" "$HB_PROGRAM"; }
              hb_run() { return 0; }
              hb_start; hbrc=$?
              [[ -n "${HB_LAUNCHED:-}" ]] && echo "LAUNCHED=$HB_LAUNCHED"
              exit "$hbrc" ) 2>&1 )"
    rc=$?
    printf '%s|%s' "$rc" "$out"
}
rm -f "$HB_PIDFILE"
r="$(real_start "import os, time
open('$HB_PIDFILE', 'w').write(str(os.getpid()) + '\n')
time.sleep(30)")"
launched="$(sed -n 's/.*LAUNCHED=\([0-9]*\).*/\1/p' <<<"$r" | head -1)"
[[ -n "$launched" ]] && STARTED+=("$launched")
check "a daemon that reports: start answers 0"          0 "${r%%|*}"
check "  and names the pid it launched"                 yes "$(has "heartbeat started (pid $launched" "$r")"
check "  and that pid is the daemon by argv"            0 "$(hb_is_daemon "$launched"; echo $?)"
r2="$( ( session_running() { return 0; }; hb_launch() { echo "SECOND LAUNCH"; }; hb_run() { return 0; }
         hb_install_program() { :; }; hb_start ) 2>&1 )"
check "start again while it runs: no second launch"     no "$(has "SECOND LAUNCH" "$r2")"
check "  and it says which pid is running"              yes "$(has "already running (pid $launched)" "$r2")"
r3="$(hb_stop 2>&1)"
check "and stop stops it"                               yes "$(has "heartbeat stopped (pid $launched)" "$r3")"
check "  and it is gone"                                no "$(alive "$launched")"
wait "$launched" 2>/dev/null

rm -f "$HB_PIDFILE"
r="$(real_start "import sys
print('heartbeat: the running fabric has no switch-to-switch link; nothing to send', file=sys.stderr)
sys.exit(3)")"
check "a daemon that finds no link exits 3, and start answers 3" 3 "${r%%|*}"
r="$(real_start "import sys
print('heartbeat: refusing: stand-in reason', file=sys.stderr)
sys.exit(1)")"
check "a daemon that refuses at once: start fails"      1 "${r%%|*}"
check "  and shows the daemon's own reason from its log" yes "$(has "stand-in reason" "$r")"

# The run directory root writes the program into.
check "our 0755 run dir is trusted (the control)"       0 "$(hb_dir_trusted "$HB_RUN_DIR" 2>/dev/null; echo $?)"
mkdir -m 0775 "$TMPROOT/gw"
check "a group-writable run dir is refused"             1 "$(hb_dir_trusted "$TMPROOT/gw" 2>/dev/null; echo $?)"
ln -s "$HB_RUN_DIR" "$TMPROOT/linkdir"
check "a symlinked run dir is refused"                  1 "$(hb_dir_trusted "$TMPROOT/linkdir" 2>/dev/null; echo $?)"
check "a run dir owned by another uid is refused"       1 "$( HB_EXPECT_UID=0; hb_dir_trusted "$HB_RUN_DIR" 2>/dev/null; echo $? )"
( hb_install_program ) 2>/dev/null
check "hb_install_program writes the embedded program verbatim" yes \
    "$( [[ -s "$HB_PROGRAM" ]] && cmp -s <(hb_program) "$HB_PROGRAM" && echo yes || echo no )"
check "  mode 0644"                                     644 "$(stat -c '%a' "$HB_PROGRAM" 2>/dev/null)"
cp "$TMPROOT/sleeper.py" "$HB_PROGRAM"

# ============================================================================================
echo "3. stop: pid AND argv AND uid, or nothing is signalled"

rm -f "$HB_PIDFILE"
r="$(hb_stop 2>&1)"; rc=$?
check "no pidfile: stop is a clean no-op"               "0 yes" "$rc $(has "not running" "$r")"

sleep 30 &
STRANGER=$!; STARTED+=("$STRANGER")
echo "$STRANGER" > "$HB_PIDFILE"
r="$(hb_stop 2>&1)"; rc=$?
check "a pidfile naming a live stranger: rc 0"          0 "$rc"
check "  it says stale, nothing signalled"              yes "$(has "stale pidfile" "$r")"
check "  and the stranger is still alive"               yes "$(alive "$STRANGER")"
check "  and the stale pidfile is gone"                 no "$( [[ -e "$HB_PIDFILE" ]] && echo yes || echo no )"
kill "$STRANGER" 2>/dev/null; wait "$STRANGER" 2>/dev/null     # our own child: its pid cannot have been reused

fake_daemon "$HB_PROGRAM"
DAEMON=$FAKE
echo "$DAEMON" > "$HB_PIDFILE"
check "the stand-in daemon is recognised by argv and uid" 0 "$(hb_is_daemon "$DAEMON"; echo $?)"
check "  but not when root's uid is required of it"     1 "$( HB_EXPECT_UID=0; hb_is_daemon "$DAEMON"; echo $? )"
r="$( HB_EXPECT_UID=0; hb_stop 2>&1 )"
check "stop as if root: our-uid process is a stranger, not signalled" yes "$(alive "$DAEMON")"
echo "$DAEMON" > "$HB_PIDFILE"
r="$(hb_stop 2>&1)"; rc=$?
check "the daemon itself: stop answers 0"               0 "$rc"
check "  and says it stopped that pid"                  yes "$(has "heartbeat stopped (pid $DAEMON)" "$r")"
check "  and it is gone"                                no "$(alive "$DAEMON")"
check "  and the pidfile is gone"                       no "$( [[ -e "$HB_PIDFILE" ]] && echo yes || echo no )"
wait "$DAEMON" 2>/dev/null

fake_daemon "$HB_PROGRAM" extra
ONE_OFF=$FAKE
echo "$ONE_OFF" > "$HB_PIDFILE"
check "one extra argv word is not the daemon"           1 "$(hb_is_daemon "$ONE_OFF"; echo $?)"
"$HB_PYTHON" -I "$TMPROOT/sleeper.py" daemon </dev/null >/dev/null 2>&1 &
OTHER_PROG=$!; STARTED+=("$OTHER_PROG"); sleep 0.3
check "another program path with the same shape is not the daemon" 1 "$(hb_is_daemon "$OTHER_PROG"; echo $?)"
r="$(hb_stop 2>&1)"
check "stop leaves the one-word-off process alive"      yes "$(alive "$ONE_OFF")"

# Garbage in the pidfile: a recording hb_signal, so nothing here can reach a real kill.
# (label|content) -- the labels are fixed so the mutation gate can name the check that goes red.
while IFS='|' read -r label bad; do
    bad="${bad//@TMP@/$TMPROOT}"
    printf '%s\n' "$bad" > "$HB_PIDFILE"
    : > "$CALLS"
    r="$( ( hb_signal() { echo "signal $*" >> "$CALLS"; }; hb_stop ) 2>&1 )"; rc=$?
    check "pidfile $label: nothing is signalled"        "" "$(cat "$CALLS")"
    if [[ "$bad" == 1 ]]; then
        # A well-formed number that is not the daemon (it is init): stale, by the argv check.
        check "pidfile $label: called stale, not signalled" yes "$(has "stale pidfile" "$r")"
    else
        check "pidfile $label: refused as not a pid"    yes "$(has "does not hold a pid" "$r")"
    fi
done <<'BAD'
'-1' (every process)|-1
'0' (the process group)|0
two numbers|12 34
a command substitution|$(touch @TMP@/pwned4)
a path|../../etc/passwd
an empty line|
a number with a tail|4242x
'1' (init)|1
BAD
check "  and no pidfile content was executed"           no "$( [[ -e "$TMPROOT/pwned4" ]] && echo yes || echo no )"
rm -f "$HB_PIDFILE"
ln -s "$TMPROOT/sleeper.py" "$HB_PIDFILE"
: > "$CALLS"
r="$( ( hb_signal() { echo "signal $*" >> "$CALLS"; }; hb_stop ) 2>&1 )"; rc=$?
check "a symlinked pidfile is refused"                  "1 yes" "$rc $(has symlink "$r")"
check "  and nothing is signalled"                      "" "$(cat "$CALLS")"
rm -f "$HB_PIDFILE"

# ============================================================================================
echo "4-7. the program root runs"

PROG="$TMPROOT/program.py"
hb_program > "$PROG" 2>/dev/null
check "the embedded program is valid python for $HB_TEST_PY" 0 \
    "$("$HB_TEST_PY" -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$PROG" >/dev/null 2>&1; echo $?)"

# The tutorials tree (section 7's collision check) is outside the repo; say so if it is absent.
TUT_EXERCISES="${TUT_EXERCISES:-$HOME/tutorials/exercises}"

PYOUT="$TMPROOT/py.out"
"$HB_TEST_PY" -I - "$PROG" "$TMPROOT" "$REPO" "$TUT_EXERCISES" "$PYTHON" > "$PYOUT" 2>&1 <<'PYTEST'
import errno, glob, json, os, re, stat, subprocess, sys, tempfile, time, traceback
sys.dont_write_bytecode = True
# 🔴 This machine's login umask is 002: a directory made without an explicit mode is
# group-writable, and the program REFUSES that -- every "refused" below would then be refused for
# the wrong reason. The fixtures state their modes; this makes the ones that do not say 0755.
os.umask(0o022)
prog_path, tmp, repo, tut, venv_py = sys.argv[1:6]
counts = {"ok": 0, "fail": 0}


def check(name, expected, actual):
    if expected == actual:
        print(f"  ok       {name}")
        counts["ok"] += 1
    else:
        print(f"  FAILED   {name}\n             expected: {expected!r}\n             actual:   {actual!r}")
        counts["fail"] += 1


def refused(fn, *a, **k):
    """The Refusal's message, or 'NOT REFUSED'."""
    try:
        fn(*a, **k)
    except hb.Refusal as exc:
        return str(exc)
    return "NOT REFUSED"


def load(path):
    import importlib.util
    spec = importlib.util.spec_from_file_location("hbprog", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    hb = load(prog_path)
except Exception as exc:                                   # noqa: BLE001
    print(f"  FAILED   the embedded program loads as a module\n             {exc!r}")
    print("PYHARNESS 0 1")
    sys.exit(1)

# One subprocess shape for the checks that must run in a process of their own.
LOADER = ("import importlib.util,sys\n"
          "s=importlib.util.spec_from_file_location('h',sys.argv[1]);m=importlib.util.module_from_spec(s);"
          "s.loader.exec_module(m)\n")

# ------------------------------------------------------------ fixtures: pod-topo, four switches
# 07_roles_basic.sh's cables: s1-p3<->s3-p1, s1-p4<->s4-p2, s2-p3<->s4-p1, s2-p4<->s3-p2;
# s1 and s2 carry the hosts on ports 1 and 2.
CABLES = [(1, 3, 3, 1), (1, 4, 4, 2), (2, 3, 4, 1), (2, 4, 3, 2)]
PORTS = {1: [1, 2, 3, 4], 2: [1, 2, 3, 4], 3: [1, 2], 4: [1, 2]}
PIDS = {1: 5001, 2: 5002, 3: 5003, 4: 5004}
HOST_FACING = ["s1-eth1", "s1-eth2", "s2-eth1", "s2-eth2"]


def ifname(d, p):
    return f"s{d}-eth{p}"


def argv_of(d, ports=None):
    binds = " ".join(f"-i {p}@{ifname(d, p)}" for p in (PORTS[d] if ports is None else ports))
    return (f"LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib /usr/local/bmv2-fast/bin/simple_switch_grpc "
            f"{binds} --thrift-port 909{d} --device-id {d} /x/build/basic.json -- "
            f"--grpc-server-addr 0.0.0.0:3005{d} --cpu-port 255")


def entry(d, **over):
    e = {"pid": PIDS[d], "device_id": d, "grpc_port": 30050 + d, "thrift_port": 9090 + d,
         "log_file": f"/tmp/s{d}_bmv2.log", "argv": argv_of(d)}
    e.update(over)
    return e


def manifest_doc(**over):
    doc = {f"s{d}": entry(d) for d in PIDS}
    doc.update(over)
    return doc


def write_manifest(doc, name, mode=0o644, dir_mode=0o755):
    d = os.path.join(tmp, "mdir-" + name)
    os.makedirs(d, exist_ok=True)
    os.chmod(d, dir_mode)
    p = os.path.join(d, "ndtwin_p4_switches.json")
    if os.path.lexists(p):
        os.remove(p)
    with open(p, "w") as fh:
        fh.write(json.dumps(doc))
    os.chmod(p, mode)
    return p


# A fake /sys/class/net: ifindex from 100, veth peers per CABLES.
index, n = {}, 100
for d in sorted(PORTS):
    for p in PORTS[d]:
        index[ifname(d, p)] = n
        n += 1
peer = {}
for a, ap, b, bp in CABLES:
    peer[ifname(a, ap)] = index[ifname(b, bp)]
    peer[ifname(b, bp)] = index[ifname(a, ap)]
# 🔴 A host-facing veth's peer lives in the host's namespace, and its ifindex there can equal one
# of OURS. Every host-facing iflink below is deliberately s3-eth1's number: the coincidence the
# both-ways check exists for, built into the fixture every check runs on.
for name in HOST_FACING:
    peer[name] = index["s3-eth1"]


def write_sys(root, index, peer):
    for name, i in index.items():
        os.makedirs(os.path.join(root, name), exist_ok=True)
        with open(os.path.join(root, name, "ifindex"), "w") as fh:
            fh.write(f"{i}\n")
        with open(os.path.join(root, name, "iflink"), "w") as fh:
            fh.write(f"{peer[name]}\n")
        with open(os.path.join(root, name, "address"), "w") as fh:
            fh.write(f"02:00:00:00:{i >> 8:02x}:{i & 255:02x}\n")


def write_proc(root, pids, argv0="/usr/local/bmv2-fast/bin/simple_switch_grpc"):
    os.makedirs(root, exist_ok=True)
    for pid in pids:
        os.makedirs(os.path.join(root, str(pid)), exist_ok=True)
        with open(os.path.join(root, str(pid), "cmdline"), "wb") as fh:
            fh.write(argv0.encode() + b"\0-i\0" + b"1@x\0")


SYS = os.path.join(tmp, "sys")
write_sys(SYS, index, peer)
PROC = os.path.join(tmp, "proc")
write_proc(PROC, PIDS.values())
uid = os.getuid()
veth = lambda _name: "veth"                                   # noqa: E731
good = write_manifest(manifest_doc(), "good")
kw = dict(expect_uid=uid, proc_root=PROC, sysfs=SYS, driver_of=veth)
state = {}


# ------------------------------------------------------------------------------------------
def section_interfaces():
    print("  -- 4. interfaces come only from the running fabric's own declaration")
    P = hb.plan(good, **kw)
    state["P"] = P
    check("a whole pod-topo fabric: 4 links", 4, len(P.links))
    want = sorted(CABLES + [(b, bp, a, ap) for a, ap, b, bp in CABLES])
    check("  8 directions, exactly the cables both ways", want,
          sorted((d.tx.dpid, d.tx.port, d.rx.dpid, d.rx.port) for d in P.directions))
    check("  every direction sends on its own port's interface and reads at its peer's", True,
          all(d.tx.ifname == ifname(d.tx.dpid, d.tx.port) and d.rx.ifname == ifname(d.rx.dpid, d.rx.port)
              for d in P.directions))
    check("  the 4 host-facing interfaces are listened on only", HOST_FACING, sorted(p.ifname for p in P.watch))
    check("  no host-facing interface is ever a tx", set(), {d.tx.ifname for d in P.directions} & set(HOST_FACING))
    check("  the interface set is exactly the manifest's -i bindings", sorted(index), sorted(P.macs))

    real = os.path.join(repo, "doc/audit/2026-09-19_telemetry-three-groups/tests/fixtures/"
                              "ndtwin_p4_switches.real.json")
    rports, _ = hb.switch_ports(json.load(open(real)))
    check("the manifest a real bring-up wrote parses, every -i as <switch>-eth<port>", True,
          len(rports) > 0 and all(p.ifname == f"{p.switch}-eth{p.port}" for p in rports))

    none_dir = os.path.join(tmp, "mdir-none")
    os.makedirs(none_dir, exist_ok=True)
    check("no manifest: refused as 'no fabric is running'", True,
          "no fabric is running" in refused(hb.plan, os.path.join(none_dir, "ndtwin_p4_switches.json"), **kw))

    # 🔴 THE FILE-OWNER CHECK, ON ITS OWN. Every directory this suite can create is its own, so a
    # manifest this uid owns in a directory that is also this uid's is refused by the DIRECTORY
    # rule first, and a missing file-owner check would hide behind it. /tmp is the production
    # shape -- root-owned, 1777 -- and it is what isolates the file's own owner check.
    fd, mine = tempfile.mkstemp(dir="/tmp", prefix="ndtwin-lab-heartbeat-manifest-")
    try:
        os.write(fd, json.dumps(manifest_doc()).encode())
        os.close(fd)
        os.chmod(mine, 0o644)
        check("a manifest this uid owns, in root's sticky /tmp, is refused when root's is required", True,
              "is owned by uid" in refused(hb.load_manifest, mine, expect_uid=0) and "/tmp " not in
              refused(hb.load_manifest, mine, expect_uid=0))
    finally:
        os.remove(mine)
    check("a manifest in a directory another uid owns is refused", True,
          "owned by uid" in refused(hb.load_manifest, good, expect_uid=0))
    gw = write_manifest(manifest_doc(), "gw", mode=0o664)
    check("a group-writable manifest is refused", True,
          "writable by group or other" in refused(hb.load_manifest, gw, expect_uid=uid))
    link_dir = os.path.join(tmp, "mdir-link")
    os.makedirs(link_dir, exist_ok=True)
    lp = os.path.join(link_dir, "ndtwin_p4_switches.json")
    if not os.path.lexists(lp):
        os.symlink(good, lp)
    check("a symlinked manifest is refused", True, "symlink" in refused(hb.load_manifest, lp, expect_uid=uid))
    fifo_dir = os.path.join(tmp, "mdir-fifo")
    os.makedirs(fifo_dir, exist_ok=True)
    fp = os.path.join(fifo_dir, "ndtwin_p4_switches.json")
    if not os.path.lexists(fp):
        os.mkfifo(fp, 0o644)
    try:
        r = subprocess.run([sys.executable, "-I", "-c", LOADER +
                            "try:\n m.load_manifest(sys.argv[2], expect_uid=int(sys.argv[3])); print('NOT REFUSED')\n"
                            "except m.Refusal as e:\n print(e)\n", prog_path, fp, str(uid)],
                           capture_output=True, text=True, timeout=5)
        got = r.stdout
    except subprocess.TimeoutExpired:
        got = "HUNG at open() for 5 s"
    check("a FIFO planted at the name is refused without hanging the reader", True, "not a regular file" in got)
    ww = write_manifest(manifest_doc(), "ww", dir_mode=0o777)
    check("a manifest in a world-writable, non-sticky directory is refused", True,
          "not sticky" in refused(hb.load_manifest, ww, expect_uid=uid))
    os.chmod(os.path.dirname(ww), 0o1777)
    check("  the same directory made sticky (the /tmp shape) is accepted", "NOT REFUSED",
          refused(hb.load_manifest, ww, expect_uid=uid))
    os.chmod(os.path.dirname(ww), 0o755)

    one_dead = os.path.join(tmp, "proc-one-dead")
    write_proc(one_dead, [5001, 5002, 5003])
    check("one switch not a live bmv2: refused as not whole", True,
          "not whole" in refused(hb.plan, good, **dict(kw, proc_root=one_dead)))
    none = os.path.join(tmp, "proc-none")
    os.makedirs(none, exist_ok=True)
    check("no switch alive: refused as 'no fabric is running'", True,
          "no fabric is running" in refused(hb.plan, good, **dict(kw, proc_root=none)))
    impostor = os.path.join(tmp, "proc-impostor")
    write_proc(impostor, PIDS.values(), argv0="/usr/bin/sleep")
    check("pids whose argv is not simple_switch_grpc are not a fabric", True,
          "no fabric is running" in refused(hb.plan, good, **dict(kw, proc_root=impostor)))

    odd = write_manifest(manifest_doc(s1=entry(1, argv=argv_of(1).replace("-i 3@s1-eth3", "-i 3@wlp0s20f3"))), "odd")
    check("an -i binding not named <switch>-eth<port> refuses the whole manifest", True,
          "not s1-eth3" in refused(hb.plan, odd, **kw))
    check("a non-veth interface is refused", True,
          "not veth" in refused(hb.plan, good, **dict(kw, driver_of=lambda n: "e1000e" if n == "s3-eth2" else "veth")))
    oneway = os.path.join(tmp, "sys-oneway")
    peer1 = dict(peer)
    peer1["s3-eth1"] = 9999                        # s1-eth3 names s3-eth1; s3-eth1 names a stranger
    write_sys(oneway, index, peer1)
    P1 = hb.plan(good, **dict(kw, sysfs=oneway))
    check("a one-way iflink is not a cable: s1-eth3/s3-eth1 are not a link", False,
          any({a.ifname, b.ifname} == {"s1-eth3", "s3-eth1"} for a, b in P1.links))
    check("  and neither end is ever sent on", set(), {d.tx.ifname for d in P1.directions} & {"s1-eth3", "s3-eth1"})
    missing = os.path.join(tmp, "sys-missing")
    write_sys(missing, {k: v for k, v in index.items() if k != "s4-eth2"}, peer)
    state["SYS_MISSING"] = missing
    check("an -i interface missing from /sys is refused", True,
          "s4-eth2" in refused(hb.plan, good, **dict(kw, sysfs=missing)))
    for label, doc in (("a non-object manifest", ["s1"]), ("an empty manifest", {}),
                       ("a port past bmv2's range", manifest_doc(s1=entry(1, argv=argv_of(1, [600])))),
                       ("a boolean device_id", manifest_doc(s1=entry(1, device_id=True))),
                       ("a duplicate dpid", manifest_doc(s2=entry(2, device_id=1)))):
        p = write_manifest(doc, "bad")
        check(f"{label} is refused", True, refused(hb.plan, p, **kw) != "NOT REFUSED")
    check("the real ethtool lookup does not call lo a veth", False, hb.ethtool_driver("lo") == "veth")
    reals = [x for x in sorted(os.listdir("/sys/class/net")) if x.startswith("veth")]
    if reals:
        check(f"  and does call a real veth on this machine ({reals[0]}) a veth", "veth", hb.ethtool_driver(reals[0]))
    else:
        print("  --       no real veth on this machine; the positive half of the ethtool check was NOT run")


def section_heard():
    print("  -- 5. heard means arrived, at the far end, from this session")
    P = state["P"]
    S = b"\x01\x02\x03\x04\x05\x06\x07\x08"
    H = hb.Heartbeat(P, S, 1000.0, 1.7e9)
    state["H"], state["S"] = H, S
    frames = H.frames()
    check("one frame per direction per round", len(P.directions), len(frames))
    check("  each on its own direction's tx interface", True, all(i == d.tx.ifname for i, _f, d in frames))
    f0, d0 = frames[0][1], frames[0][2]
    state["f0"], state["d0"] = f0, d0
    check("frames are 60 bytes", 60, len(f0))
    check("  to 02:4e:44:54:48:42, ethertype 0x88b5", (b"\x02NDTHB", 0x88B5), (f0[0:6], int.from_bytes(f0[12:14], "big")))
    check("  from the tx interface's own MAC", P.macs[d0.tx.ifname], f0[6:12])
    dec = hb.decode(f0)
    check("decode(encode) round-trips", (S, d0.id, 1, d0.tx.dpid, d0.tx.port, d0.rx.dpid, d0.rx.port),
          tuple(dec) if dec else None)
    check("decode refuses another ethertype", None, hb.decode(f0[:12] + b"\x08\x00" + f0[14:]))
    check("decode refuses another magic", None, hb.decode(f0[:14] + b"XXXX" + f0[18:]))
    check("decode refuses another version", None, hb.decode(f0[:18] + b"\x09" + f0[19:]))
    check("decode refuses a short frame", None, hb.decode(f0[:40]))
    check("the next round's seq moves on", 2, hb.decode(H.frames()[0][1]).seq)

    IN, OUT = 0, hb.PACKET_OUTGOING
    rec = H.dirs[d0.id]
    check("nothing is heard before anything arrives", (0, None), (rec["heard"], rec["last_heard_mono"]))
    check("an OUTGOING copy on the rx interface is NOT heard", "forwarded",
          H.on_frame(d0.rx.ifname, f0, OUT, 1001.0, 1.7e9 + 1))
    check("  heard is still 0 after the outgoing copy", 0, rec["heard"])
    check("an INCOMING frame on another interface is NOT heard", "misdelivered",
          H.on_frame(d0.tx.ifname, f0, IN, 1001.0, 1.7e9 + 1))
    check("  heard is still 0 after the misdelivery", 0, rec["heard"])
    other = hb.encode(d0, b"\xff" * 8, 1, P.macs[d0.tx.ifname])
    check("another session's frame is NOT heard", "foreign", H.on_frame(d0.rx.ifname, other, IN, 1001.0, 1.7e9 + 1))
    check("  heard is still 0 after the other session", 0, rec["heard"])
    d1 = P.directions[1]
    forged = hb.encode(d0._replace(tx=d1.tx), S, 1, P.macs[d0.tx.ifname])
    check("a frame whose endpoints disagree with its direction id is NOT heard", "foreign",
          H.on_frame(d0.rx.ifname, forged, IN, 1001.0, 1.7e9 + 1))
    check("  heard is still 0 after the forgery", 0, rec["heard"])
    check("the frame arriving at the direction's rx IS heard", "heard", H.on_frame(d0.rx.ifname, f0, IN, 1002.5, 1.7e9 + 2))
    check("  heard 1, at the time it arrived", (1, 1002.5, 1), (rec["heard"], rec["last_heard_mono"], rec["last_seq"]))
    check("our own transmission seen on its tx interface is 'own', not heard", "own",
          H.on_frame(d0.tx.ifname, f0, OUT, 1003.0, 1.7e9 + 3))
    check("  heard is still 1 after our own copy", 1, rec["heard"])

    def bpf_run(prog, pkt):
        """Just enough of classic BPF for this filter: ldh, jeq, ret."""
        pc, A = 0, 0
        while pc < len(prog):
            code, jt, jf, k = prog[pc]
            if code == 0x28:
                if k + 2 > len(pkt):
                    return 0
                A = int.from_bytes(pkt[k:k + 2], "big")
                pc += 1
            elif code == 0x15:
                pc += 1 + (jt if A == k else jf)
            elif code == 0x06:
                return k
            else:
                return f"unknown opcode {code:#x}"
        return "fell off the end"
    check("the kernel filter accepts our frames", True, bpf_run(hb.bpf_program(), f0) not in (0, "fell off the end"))
    check("  and drops IPv4", 0, bpf_run(hb.bpf_program(), f0[:12] + b"\x08\x00" + f0[14:]))
    check("  and drops LLDP", 0, bpf_run(hb.bpf_program(), f0[:12] + b"\x88\xcc" + f0[14:]))


def section_report():
    print("  -- 6. the report is observations, never a verdict")
    P, H, S, f0 = state["P"], state["H"], state["S"], state["f0"]
    H.on_frame(P.watch[0].ifname, f0, hb.PACKET_OUTGOING, 1004.0, 1.7e9 + 4)
    doc = H.document("running", None, 1005.0, 1.7e9 + 5)
    check("per direction: exactly these keys (no up/down/is_up/state)",
          sorted(["id", "tx", "rx", "sent", "send_errors", "last_send_error", "heard",
                  "last_heard_mono", "last_heard_wall", "last_seq"]), sorted(doc["directions"][0]))
    check("top level: exactly these keys",
          sorted(["format", "source", "status", "stop_reason", "pid", "session", "ethertype", "dst_mac",
                  "period_s", "clock", "started_mono", "started_wall", "written_mono", "written_wall",
                  "fabric", "directions", "watch_only", "interfaces", "side_effects"]), sorted(doc))
    check("a direction never heard reports last_heard_mono null", None,
          next(r for r in doc["directions"] if r["id"] == P.directions[-1].id)["last_heard_mono"])
    check("a frame leaving a host-facing port counts as forwarded_to_hosts", 1, doc["side_effects"]["forwarded_to_hosts"])
    check("  and one leaving a switch port as forwarded_between_switches", 1,
          doc["side_effects"]["forwarded_between_switches"])
    check("the report says the ethertype, the period and the session", ("0x88b5", hb.PERIOD_S, S.hex()),
          (doc["ethertype"], doc["period_s"], doc["session"]))
    out = os.path.join(tmp, "state")
    os.makedirs(out, exist_ok=True)
    hb.write_json_atomic(os.path.join(out, "heartbeat.json"), doc)
    st = os.stat(os.path.join(out, "heartbeat.json"))
    check("the report is written 0644 and parses back", (0o644, doc),
          (stat.S_IMODE(st.st_mode), json.load(open(os.path.join(out, "heartbeat.json")))))
    check("  and leaves no temp file behind", ["heartbeat.json"], sorted(os.listdir(out)))
    lines = hb.render(doc, 1010.0)
    check("status renders ages, not verdicts", True,
          any("last heard 7.5 s ago" in x for x in lines)
          and not any(w in " ".join(lines).lower() for w in (" down", "is_up", " dead")))


def section_lifecycle():
    print("  -- 7. one daemon, a fabric that goes away, the command line, and the pins")
    P = state["P"]
    lock = os.path.join(tmp, "heartbeat.lock")
    holder = subprocess.Popen([sys.executable, "-I", "-c", LOADER +
                               "import time\nfd=m.acquire_lock(sys.argv[2]);"
                               "print('held' if fd is not None else 'busy',flush=True);time.sleep(20)\n",
                               prog_path, lock], stdout=subprocess.PIPE, text=True)
    try:
        first = holder.stdout.readline().strip()
        second = hb.acquire_lock(lock)
    finally:
        holder.kill()
        holder.wait()
    check("the first daemon takes the lock", "held", first)
    check("  a second one cannot, while the first lives", None, second)
    third = hb.acquire_lock(lock)
    check("  and can once the first is gone (the control)", True, third is not None)
    if third is not None:
        os.close(third)

    check("an unchanged fabric is not 'changed'", None, hb.fabric_changed(P, sysfs=SYS))
    rebuilt = os.path.join(tmp, "sys-rebuilt")
    idx2 = dict(index)
    idx2["s3-eth2"] = 999
    write_sys(rebuilt, idx2, peer)
    check("a rebuilt fabric (new ifindex) is 'changed'", True, "rebuilt" in (hb.fabric_changed(P, sysfs=rebuilt) or ""))
    check("a vanished interface is 'changed'", True, "gone" in (hb.fabric_changed(P, sysfs=state["SYS_MISSING"]) or ""))
    check("a vanished manifest is 'changed'", True,
          "gone" in (hb.fabric_changed(P, sysfs=SYS, manifest_exists=lambda _p: False) or ""))

    for label, args in (("no command", []), ("an unknown command", ["bogus"]),
                        ("daemon with an interface", ["daemon", "--iface", "eth0"]),
                        ("plan with a manifest path", ["plan", "/tmp/mine.json"])):
        r = subprocess.run([sys.executable, "-I", prog_path] + args, capture_output=True, text=True, timeout=20)
        check(f"the program refuses {label}", (1, True), (r.returncode, "nothing else is accepted" in r.stderr))

    # 🔴 THE PINS. PERIOD_S is not read from the proxy at run time (root, sha-pinned, env_reset --
    # see the constant's comment); it is held equal to the proxy's here, with the proxy's
    # experiment override removed from the environment so the DEFAULTS are what is compared.
    env = {k: v for k, v in os.environ.items() if k != "NDTWIN_P4_BEACON_S"}
    if os.path.exists(venv_py):
        r = subprocess.run([venv_py, "-c", "import sys; sys.path.insert(0, sys.argv[1]); "
                            "from proxy_agent import topology_manager as t; "
                            "print(t.LLDP_BEACON_INTERVAL_S, t.LINK_BEACON_TIMEOUT_S)",
                            os.path.join(repo, "p4_proxy")], capture_output=True, text=True, env=env, timeout=60)
        got = r.stdout.split() if r.returncode == 0 else ["import-failed", r.stderr[-300:]]
    else:
        got = ["no-venv", venv_py]
    check("PERIOD_S is the proxy's LLDP_BEACON_INTERVAL_S", str(hb.PERIOD_S), got[0])
    check("the proxy's LINK_BEACON_TIMEOUT_S is 3 heartbeat periods", str(3 * hb.PERIOD_S), got[1] if len(got) > 1 else None)

    check("the ethertype is IEEE 802 local experimental (0x88B5/0x88B6)", True, hb.ETHERTYPE in (0x88B5, 0x88B6))

    def ethertypes(paths):
        found = {}
        for p in paths:
            text = open(p, errors="replace").read()
            for m in re.finditer(r"bit<16>\s+\w+\s*=\s*(0x[0-9A-Fa-f]+)", text):
                found.setdefault(int(m.group(1), 16), set()).add(p)
            for m in re.finditer(r"(0x[0-9A-Fa-f]+)\s*:\s*\w+\s*;", text):
                found.setdefault(int(m.group(1), 16), set()).add(p)
        return found
    ours = ethertypes(glob.glob(os.path.join(repo, "p4_proxy", "p4_src", "*.p4")))
    check("ndtwin_switch.p4 does not use it (and the scan sees its 0x88CC)", (False, True),
          (hb.ETHERTYPE in ours, 0x88CC in ours))
    tp = sorted(glob.glob(os.path.join(tut, "*", "*.p4")) + glob.glob(os.path.join(tut, "*", "solution", "*.p4")))
    if tp:
        theirs = ethertypes(tp)
        check(f"no tutorials parser uses it ({len(tp)} .p4 files scanned)", [], sorted(theirs.get(hb.ETHERTYPE, ())))
        check("  and the scan is not blind: it sees 0x0800, 0x0812, 0x1212 and 0x1234", True,
              all(x in theirs for x in (0x0800, 0x0812, 0x1212, 0x1234)))
    else:
        print(f"  --       no tutorials tree at {tut}; the collision half was NOT checked")


# ------------------------------------------------------------------------------------------
# The daemon's own loop, end to end, in a process of its own: run_daemon() exactly as `main`
# calls it except for its keyword seams -- a fixture fabric, and unix datagram sockets standing in
# for the packet sockets (one per interface, bound in TMPROOT). A frame is "delivered" by sending
# it to that interface's socket, its first byte the pkttype the kernel would have reported.
DAEMON = LOADER + r"""
import json, os, socket, sys
tmp, kw = sys.argv[2], json.loads(sys.argv[3])
class FakeSock:
    def __init__(self, ifname):
        self.ifname = ifname
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        path = os.path.join(tmp, "sock-" + ifname)
        if os.path.exists(path):
            os.remove(path)
        self.s.bind(path)
        self.s.setblocking(False)
    def fileno(self):
        return self.s.fileno()
    def sendto(self, frame, addr):
        with open(os.path.join(tmp, "sent-" + self.ifname), "ab") as fh:
            fh.write(frame)
        return len(frame)
    def recvfrom(self, n):
        data = self.s.recv(n + 1)
        return data[1:], (self.ifname, 0x88B5, data[0], 1, b"")
    def getsockopt(self, *a):
        return 0
    def close(self):
        self.s.close()
sys.exit(m.run_daemon(open_socket=FakeSock, driver_of=lambda n: "veth", **kw))
"""


def section_daemon():
    print("  -- 8. the daemon's loop, end to end, with stand-in sockets")
    P = state["P"]
    drun = os.path.join(tmp, "drun")
    os.makedirs(drun, exist_ok=True)
    os.chmod(drun, 0o755)
    kwj = json.dumps(dict(run_dir=drun, manifest=good, expect_uid=uid, proc_root=PROC, sysfs=SYS))
    statef, pidf = os.path.join(drun, "heartbeat.json"), os.path.join(drun, "heartbeat.pid")

    def wait_for(pred, seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                v = pred()
                if v:
                    return v
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(0.05)
        return None

    def report():
        return json.load(open(statef))

    def deliver(ifname, frame, pkttype):
        c = __import__("socket").socket(__import__("socket").AF_UNIX, __import__("socket").SOCK_DGRAM)
        c.sendto(bytes([pkttype]) + frame, os.path.join(tmp, "sock-" + ifname))
        c.close()

    first = subprocess.Popen([sys.executable, "-I", "-c", DAEMON, prog_path, tmp, kwj],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        up = wait_for(lambda: report()["status"] == "running" and
                      open(pidf).read().strip() == str(first.pid), 5)
        check("the daemon comes up: pidfile names it, report says running", True, bool(up))
        doc = report()
        check("  its report names the fabric's 8 directions", 8, len(doc["directions"]))
        tx = sorted(x for x in os.listdir(tmp) if x.startswith("sent-"))
        check("  the first round sent one frame on each tx interface, none on a host port",
              sorted("sent-" + d.tx.ifname for d in P.directions), tx)
        check("  60 bytes each", True, all(os.path.getsize(os.path.join(tmp, x)) == 60 for x in tx))
        frame = open(os.path.join(tmp, "sent-s1-eth3"), "rb").read()[:60]
        did = next(r["id"] for r in doc["directions"]
                   if (r["tx"]["ifname"], r["rx"]["ifname"]) == ("s1-eth3", "s3-eth1"))
        deliver("s3-eth1", frame, 4)
        deliver("s3-eth1", frame, 0)
        got = wait_for(lambda: next(r for r in report()["directions"] if r["id"] == did)["heard"] >= 1, 3)
        rec = next(r for r in report()["directions"] if r["id"] == did)
        check("a frame delivered to the peer is heard, and the report shows it within 3 s",
              (1, True), (rec["heard"], rec["last_heard_mono"] is not None) if got else ("not heard", rec))
        check("  the OUTGOING copy delivered first was not heard, it was counted as forwarded",
              1, report()["interfaces"]["s3-eth1"]["forwarded"])

        second = subprocess.run([sys.executable, "-I", "-c", DAEMON, prog_path, tmp, kwj],
                                capture_output=True, text=True, timeout=20)
        check("a second daemon on the same run dir exits 2 (the lock)", 2, second.returncode)
        check("  and the first still owns the pidfile", str(first.pid), open(pidf).read().strip())
        check("  and is still running", None, first.poll())

        first.send_signal(15)
        try:
            rc = first.wait(timeout=5)
        except subprocess.TimeoutExpired:
            rc = "still running 5 s after SIGTERM"
        check("SIGTERM stops it promptly with rc 0", 0, rc)
        doc = report()
        check("  its last report says stopped, by SIGTERM", ("stopped", True),
              (doc["status"], "SIGTERM" in (doc["stop_reason"] or "")))
        check("  and it removed its own pidfile", False, os.path.exists(pidf))
    finally:
        if first.poll() is None:
            first.kill()
            first.wait()

    # A fabric torn down under a running daemon: it notices at its next round and stops itself.
    gone_dir = os.path.join(tmp, "mdir-gone")
    os.makedirs(gone_dir, exist_ok=True)
    os.chmod(gone_dir, 0o755)
    gone = os.path.join(gone_dir, "ndtwin_p4_switches.json")
    with open(gone, "w") as fh:
        fh.write(open(good).read())
    os.chmod(gone, 0o644)
    kwg = json.dumps(dict(run_dir=drun, manifest=gone, expect_uid=uid, proc_root=PROC, sysfs=SYS))
    d2 = subprocess.Popen([sys.executable, "-I", "-c", DAEMON, prog_path, tmp, kwg],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(lambda: report()["status"] == "running" and report()["pid"] == d2.pid, 5)
        os.remove(gone)
        try:
            rc = d2.wait(timeout=hb.PERIOD_S + 5)
        except subprocess.TimeoutExpired:
            rc = f"still running {hb.PERIOD_S + 5} s after its manifest went"
        check("a daemon whose fabric goes away stops itself at the next round, rc 4", 4, rc)
        check("  and says why in its last report", True, "gone" in (report()["stop_reason"] or ""))
    finally:
        if d2.poll() is None:
            d2.kill()
            d2.wait()

    single = write_manifest({"s1": entry(1, argv=argv_of(1, [1, 2]))}, "single")
    kws = json.dumps(dict(run_dir=drun, manifest=single, expect_uid=uid, proc_root=PROC, sysfs=SYS))
    r = subprocess.run([sys.executable, "-I", "-c", DAEMON, prog_path, tmp, kws],
                       capture_output=True, text=True, timeout=20)
    check("a fabric with no switch-to-switch link: the daemon exits 3", 3, r.returncode)
    kwb = json.dumps(dict(run_dir=drun, manifest=os.path.join(tmp, "mdir-none", "ndtwin_p4_switches.json"),
                          expect_uid=uid, proc_root=PROC, sysfs=SYS))
    r = subprocess.run([sys.executable, "-I", "-c", DAEMON, prog_path, tmp, kwb],
                       capture_output=True, text=True, timeout=20)
    check("no fabric: the daemon refuses, rc 1, and says so", (1, True),
          (r.returncode, "no fabric is running" in r.stderr))


for fn in (section_interfaces, section_heard, section_report, section_lifecycle, section_daemon):
    try:
        fn()
    except Exception:                                      # noqa: BLE001
        print(f"  FAILED   {fn.__name__} ran without raising")
        print("\n".join("             " + x for x in traceback.format_exc().rstrip().splitlines()[-6:]))
        counts["fail"] += 1

print(f"PYHARNESS {counts['ok']} {counts['fail']}")
PYTEST
PYRC=$?
grep -v '^PYHARNESS ' "$PYOUT"
summary="$(grep '^PYHARNESS ' "$PYOUT" | tail -1)"
if [[ -n "$summary" ]]; then
    read -r _ py_ok py_fail <<<"$summary"
    PASS=$((PASS + py_ok)); FAIL=$((FAIL + py_fail))
    check "the program's checks ran to the end" 0 "$PYRC"
else
    echo "  FAILED   the program's checks ran to the end (no summary; rc $PYRC)"
    FAIL=$((FAIL+1))
fi
check "the helper's HB_PIDFILE default is the program's PIDFILE" "/run/ndtwin-lab/heartbeat.pid" \
    "$( ( source "$LAB" 2>/dev/null; echo "$HB_PIDFILE" ) )"
check "the helper's HB_RUN_DIR default is the program's RUN_DIR" \
    "$("$HB_TEST_PY" -I -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("h",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(m.RUN_DIR, m.PIDFILE)' "$PROG" 2>/dev/null)" \
    "$( ( source "$LAB" 2>/dev/null; echo "$HB_RUN_DIR $HB_PIDFILE" ) )"

echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
