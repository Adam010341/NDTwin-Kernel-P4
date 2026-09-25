#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndtwin_lab_heartbeat.sh.  TICKET-P4-heartbeat, segment H.
#
# [Co-developed with claude code -- Adam]
#
# The heartbeat is a root entry point, and every rule the ticket gives it -- the interfaces come
# only from the running fabric, no second daemon, stop by pid AND argv, nothing taken from argv,
# nothing decided -- is a rule whose absence would be silent. This gate takes each one out of
# tools/test_workflow/ndtwin-lab, one at a time, runs the suite, and requires that the check NAMED
# for it goes red. "Something failed" is not the verdict: a catch counts only when the check that
# fails is the one that owns that defect.
#
# The shape is mutate_g7_ndtwin_lab_config.sh's, unchanged: (name, expected red check, from, to);
# `from` must occur EXACTLY once; a comment-only control must survive.
#
# 🔴 Guards its own baseline. The helper is snapshotted with `cp -p` before the first mutation, an
# EXIT trap restores it on any exit including Ctrl-C, and the run ends by asserting byte-identity
# against the snapshot. Baseline is the WORKING TREE, not HEAD.
#
# 🔴 Never kills anything by name. No pkill, no pgrep: `timeout` owns the only child, and the suite
# under test stops only what it started, by the pid it recorded.
#
# 🔴 Touches no lab and needs no root. The suite runs as the operator against fixtures; the helper's
# dispatch -- the only path to root -- is unreachable from it.
#
# 🔴 ONE MUTANT NEEDS THE MACHINE, NOT JUST THE REPO (judge #10, round 2): `ethertype-collides`
# is caught by the scan of the tutorials parsers, which exist only where $HOME/tutorials/exercises
# does (26 .p4 files on this laptop). Without that tree the suite prints "the collision half was
# NOT checked", the mutant SURVIVES, and this gate exits 1 -- loudly, never a silent pass. On such
# a machine that one survivor is the environment, and says so; every other mutant is repo-only.
#
# 🔴 ONE MUTANT IS OF THE SUITE, AND RUNS IN CI'S SHAPE (2026-09-26). From 377a1271 the pin in
# section 7 was green wherever a proxy venv exists and red in GitHub CI, which has none: it never
# tried the python3 that CI does have. `pin-no-path-fallback` takes that fallback back out
# of the suite, and it and its baseline run with the venvs hidden (HB_PIN_VENVS names nothing
# that exists, PYTHON empty) and PATH's first python3 a shim for an interpreter that CAN import
# topology_manager. That baseline must be green AND say the shim answered -- otherwise the shape
# is not CI's and the gate has no verdict. The suite is snapshotted and restored like the helper.
#
# Usage:  JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh ./tests/shell/mutate_ndtwin_lab_heartbeat.sh
#   TEST_TIMEOUT=180   seconds allowed per suite run
#
# Exit: 0 every mutation was caught by the check named for it, and the control survived
#       1 at least one mutation survived, or was caught by the wrong check
#       2 the gate cannot render a verdict (baseline red, anchor drift, hang, failed restore, or the
#         comment-only control going red)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

TEST_TIMEOUT="${TEST_TIMEOUT:-180}"
NDT=tools/test_workflow/ndtwin-lab
SUITE=tests/shell/test_ndtwin_lab_heartbeat.sh

if ! bash -n "${BASH_SOURCE[0]}"; then echo "🔴 this script does not parse" >&2; exit 2; fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$NDT" && -f "$SUITE" ]] || { echo "🔴 missing $NDT or $SUITE" >&2; exit 2; }

SNAP="$(mktemp /tmp/mutate-hb-XXXXXX.ndtwin-lab)"
cp -p "$NDT" "$SNAP"
SUITE_SNAP="$(mktemp /tmp/mutate-hb-XXXXXX.suite)"
cp -p "$SUITE" "$SUITE_SNAP"
restore() { cp -p "$SNAP" "$NDT"; cp -p "$SUITE_SNAP" "$SUITE"; }
cleanup() { restore; rm -f "$SNAP" "$SUITE_SNAP"; }
trap cleanup EXIT INT TERM

MUT_DIR="$(mktemp -d /tmp/mutate-hb-cases-XXXXXX)"
cleanup() { restore; rm -f "$SNAP" "$SUITE_SNAP"; rm -rf "$MUT_DIR"; }

write_case() {
    local name="$1" expect="$2"
    mkdir -p "$MUT_DIR/$name"
    printf '%s' "$expect" > "$MUT_DIR/$name/expect"
    cat > "$MUT_DIR/$name/pair"
}
CASES=()

# --- the command line ---------------------------------------------------------------------
# An interface, a path or an ethertype after the verb would reach root.
CASES+=(extra-args-accepted)
write_case extra-args-accepted "start with an interface name is refused" <<'PAIR'
    if (( $# != 1 )); then
        hb_refuse "usage: ndtwin-lab heartbeat {start|stop|status} -- nothing else is accepted (got $# argument(s)); the interfaces come from the running fabric"
        return 1
    fi
@@@TO@@@
    :
PAIR

# The program's own argv: one word, or nothing runs.
CASES+=(program-accepts-extra-args)
write_case program-accepts-extra-args "the program refuses daemon with an interface" <<'PAIR'
    if len(argv) != 2 or argv[1] not in COMMANDS:
@@@TO@@@
    if len(argv) < 2 or argv[1] not in COMMANDS:
PAIR

# --- start ----------------------------------------------------------------------------------
CASES+=(no-topo-check)
write_case no-topo-check "no topo session: refused, and the refusal names the missing topo session" <<'PAIR'
    session_running topo ||
        { hb_refuse "refusing to start: no fabric is running (there is no topo session; 'sudo ndtwin-lab topo-start' first)"; return 1; }
@@@TO@@@
    :
PAIR

CASES+=(second-daemon-launched)
write_case second-daemon-launched "a live daemon: start answers 0" <<'PAIR'
    if pid="$(hb_pid)"; then
        echo "heartbeat already running (pid $pid) -- not starting a second one"
        return 0
    fi
    hb_install_program || return 1
@@@TO@@@
    hb_install_program || return 1
PAIR

CASES+=(plan-skipped)
write_case plan-skipped "the plan ran, and nothing was launched" <<'PAIR'
    hb_run plan && rc=0 || rc=$?
    (( rc == 0 )) || return "$rc"
@@@TO@@@
    rc=0
PAIR

CASES+=(run-dir-mode-unchecked)
write_case run-dir-mode-unchecked "a group-writable run dir is refused" <<'PAIR'
    if (( (0$perms & 0022) != 0 )); then
        hb_refuse "$dir is mode $perms; group- or other-writable would let a non-root user replace the program root runs"
        return 1
    fi
@@@TO@@@
    :
PAIR

# The one lock that settles two racing starts.
CASES+=(lock-shared)
write_case lock-shared "a second one cannot, while the first lives" <<'PAIR'
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
@@@TO@@@
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
PAIR

# --- stop -------------------------------------------------------------------------------------
# pid only: the number was the daemon once.
CASES+=(stop-by-pid-only)
write_case stop-by-pid-only "and the stranger is still alive" <<'PAIR'
    mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline" || return 1
    (( ${#argv[@]} == 4 )) || return 1
    [[ "${argv[0]}" == "$HB_PYTHON" && "${argv[1]}" == "-I" && "${argv[2]}" == "$HB_PROGRAM" &&
       "${argv[3]}" == daemon ]] || return 1
@@@TO@@@
    [[ -d "/proc/$pid" ]] || return 1
PAIR

CASES+=(stop-no-uid-check)
write_case stop-no-uid-check "but not when root's uid is required of it" <<'PAIR'
    uid="$(awk '/^Uid:/{print $2, $3; exit}' "/proc/$pid/status" 2>/dev/null)" || return 1
    [[ "$uid" == "$HB_EXPECT_UID $HB_EXPECT_UID" ]]
@@@TO@@@
    return 0
PAIR

CASES+=(pidfile-not-validated)
write_case pidfile-not-validated "pidfile '-1' (every process): refused as not a pid" <<'PAIR'
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || return 3
    echo "$pid"
@@@TO@@@
    echo "$pid"
PAIR

CASES+=(pidfile-symlink-followed)
write_case pidfile-symlink-followed "a symlinked pidfile is refused" <<'PAIR'
    [[ -L "$HB_PIDFILE" ]] && return 2
@@@TO@@@
PAIR

# --- the fabric's own declaration -------------------------------------------------------------
CASES+=(manifest-owner-unchecked)
write_case manifest-owner-unchecked "a manifest this uid owns, in root's sticky /tmp, is refused when root's is required" <<'PAIR'
        if st.st_uid != expect_uid:
            raise Refusal(f"{path} is owned by uid {st.st_uid}, not {expect_uid}: it is not the "
                          f"file the root topology writes, and its interface list is not believed")
@@@TO@@@
        pass
PAIR

CASES+=(manifest-mode-unchecked)
write_case manifest-mode-unchecked "a group-writable manifest is refused" <<'PAIR'
        if st.st_mode & 0o022:
            raise Refusal(f"{path} is mode {oct(st.st_mode & 0o777)}: writable by group or other, "
                          f"so its interface list is not believed")
@@@TO@@@
        pass
PAIR

CASES+=(manifest-symlink-followed)
write_case manifest-symlink-followed "a symlinked manifest is refused" <<'PAIR'
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
@@@TO@@@
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
PAIR

# A FIFO at the name, opened blocking, hangs a root process at open().
CASES+=(manifest-fifo-blocks)
write_case manifest-fifo-blocks "a FIFO planted at the name is refused without hanging the reader" <<'PAIR'
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
@@@TO@@@
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
PAIR

CASES+=(manifest-dir-unchecked)
write_case manifest-dir-unchecked "a manifest in a world-writable, non-sticky directory is refused" <<'PAIR'
    if st.st_mode & 0o022 and not st.st_mode & stat.S_ISVTX:
        raise Refusal(f"{path} is mode {oct(st.st_mode & 0o7777)}: writable by others and not "
                      f"sticky, so anybody could replace the fabric's manifest in it")
@@@TO@@@
    pass
PAIR

CASES+=(dead-switch-accepted)
write_case dead-switch-accepted "one switch not a live bmv2: refused as not whole" <<'PAIR'
    if dead:
        raise Refusal(f"the fabric is not whole: {', '.join(dead)} named in {manifest} is not a "
                      f"live {SWITCH_BINARY.decode()}; not heartbeating a fabric that is half there")
@@@TO@@@
    pass
PAIR

CASES+=(ifname-not-tied-to-switch)
write_case ifname-not-tied-to-switch "an -i binding not named <switch>-eth<port> refuses the whole manifest" <<'PAIR'
            if ifname != f"{name}-eth{port}" or not IFNAME_RE.match(ifname):
@@@TO@@@
            if not IFNAME_RE.match(ifname):
PAIR

CASES+=(no-veth-check)
write_case no-veth-check "a non-veth interface is refused" <<'PAIR'
        if drv != "veth":
@@@TO@@@
        if False:
PAIR

# One-way: a host-facing veth's peer number coincides with one of ours.
CASES+=(one-way-peer-is-a-cable)
write_case one-way-peer-is-a-cable "a one-way iflink is not a cable: s1-eth3/s3-eth1 are not a link" <<'PAIR'
        if peer is not None and peer != p.ifname and info[peer].iflink == me.ifindex:
@@@TO@@@
        if peer is not None and peer != p.ifname:
PAIR

# --- what counts as heard -----------------------------------------------------------------------
CASES+=(outgoing-counted-as-heard)
write_case outgoing-counted-as-heard "an OUTGOING copy on the rx interface is NOT heard" <<'PAIR'
        if pkttype == PACKET_OUTGOING:
            if ifname == d.tx.ifname:
                return "own"
            if box is not None:
                box["forwarded"] += 1
            return "forwarded"
@@@TO@@@
        pass
PAIR

CASES+=(wrong-interface-heard)
write_case wrong-interface-heard "an INCOMING frame on another interface is NOT heard" <<'PAIR'
        if ifname != d.rx.ifname:
            if box is not None:
                box["misdelivered"] += 1
            return "misdelivered"
@@@TO@@@
        pass
PAIR

CASES+=(session-unchecked)
write_case session-unchecked "another session's frame is NOT heard" <<'PAIR'
        d = self.by_id.get(f.dir_id) if f is not None and f.session == self.session else None
@@@TO@@@
        d = self.by_id.get(f.dir_id) if f is not None else None
PAIR

CASES+=(bpf-wrong-ethertype)
write_case bpf-wrong-ethertype "the kernel filter accepts our frames" <<'PAIR'
            (0x15, 0, 1, ETHERTYPE),       # jeq #ETHERTYPE, accept, drop
@@@TO@@@
            (0x15, 0, 1, 0x0800),          # jeq #ETHERTYPE, accept, drop
PAIR

# --- the report decides nothing ---------------------------------------------------------------
CASES+=(report-makes-a-verdict)
write_case report-makes-a-verdict "per direction: exactly these keys (no up/down/is_up/state)" <<'PAIR'
            rec.update({"id": d.id, "tx": end(d.tx), "rx": end(d.rx)})
@@@TO@@@
            rec.update({"id": d.id, "tx": end(d.tx), "rx": end(d.rx), "is_up": rec["heard"] > 0})
PAIR

# --- the daemon's loop --------------------------------------------------------------------------
CASES+=(heard-not-reported)
write_case heard-not-reported "a frame delivered to the peer is heard, and the report shows it within 3 s" <<'PAIR'
                    if hb.on_frame(name, frame, addr[2], time.monotonic(),
                                   time.time()) == "heard":
                        dirty = True
@@@TO@@@
                    if hb.on_frame(name, frame, addr[2], time.monotonic(),
                                   time.time()) == "heard":
                        pass
PAIR

CASES+=(fabric-change-ignored)
write_case fabric-change-ignored "a rebuilt fabric (new ifindex) is 'changed'" <<'PAIR'
        if now != ifindex:
            return f"{ifname} is ifindex {now}, was {ifindex} (the fabric was rebuilt)"
@@@TO@@@
        pass
PAIR

CASES+=(loop-never-asks-the-fabric)
write_case loop-never-asks-the-fabric "a daemon whose fabric goes away stops itself at the next round, rc 4" <<'PAIR'
            if now >= next_round:
                reason = fabric_changed(p, sysfs=sysfs)
@@@TO@@@
            if now >= next_round:
                reason = None
PAIR

CASES+=(sigterm-ignored)
write_case sigterm-ignored "SIGTERM stops it promptly with rc 0" <<'PAIR'
    signal.signal(signal.SIGTERM, on_signal)
@@@TO@@@
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
PAIR

# --- the pins -----------------------------------------------------------------------------------
CASES+=(period-drift)
write_case period-drift "PERIOD_S is the proxy's LLDP_BEACON_INTERVAL_S" <<'PAIR'
PERIOD_S = 5
@@@TO@@@
PERIOD_S = 2
PAIR

CASES+=(ethertype-collides)
write_case ethertype-collides "no tutorials parser uses it (26 .p4 files scanned)" <<'PAIR'
ETHERTYPE = 0x88B5
@@@TO@@@
ETHERTYPE = 0x1234
PAIR

CASES+=(pidfile-path-drift)
write_case pidfile-path-drift "the helper's HB_RUN_DIR default is the program's RUN_DIR" <<'PAIR'
    return tuple(os.path.join(run_dir, n) for n in ("heartbeat.pid", "heartbeat.lock", "heartbeat.json"))
@@@TO@@@
    return tuple(os.path.join(run_dir, n) for n in ("heartbeat.pidfile", "heartbeat.lock", "heartbeat.json"))
PAIR

# --- round 2 (Adam's ruling (a), judge #6, #7, #9) ---------------------------------------------
CASES+=(ndtwin-pipeline-accepted)
write_case ndtwin-pipeline-accepted "a fabric running NDTwin's own pipeline is refused (one switch of four)" <<'PAIR'
    if own:
        raise Refusal(f"{', '.join(own)} run(s) NDTwin's own pipeline ({NDTWIN_PIPELINE}). That "
@@@TO@@@
    if False:
        raise Refusal(f"{', '.join(own)} run(s) NDTwin's own pipeline ({NDTWIN_PIPELINE}). That "
PAIR

CASES+=(bmv2-uid-unchecked)
write_case bmv2-uid-unchecked "bmv2 pids owned by another uid are not a fabric" <<'PAIR'
    return uids == [str(expect_uid), str(expect_uid)]
@@@TO@@@
    return True
PAIR

CASES+=(race-branch-dropped)
write_case race-branch-dropped "two starts race and this one's daemon loses the lock: start answers 0" <<'PAIR'
            if (( rc == 2 )) && pid="$(hb_pid)"; then
                echo "heartbeat already running (pid $pid) -- another start won the race; not starting a second one"
                return 0
            fi
@@@TO@@@
            :
PAIR

CASES+=(kill-fallback-dropped)
write_case kill-fallback-dropped "a daemon that ignores TERM: stop falls back to KILL and answers 0" <<'PAIR'
    if hb_is_daemon "$pid"; then
        hb_signal KILL "$pid" || true
        sleep 0.2
    fi
@@@TO@@@
    :
PAIR

CASES+=(kill-path-leaves-pidfile)
write_case kill-path-leaves-pidfile "and the KILL path removed the pidfile" <<'PAIR'
    [[ "$(hb_read_pidfile 2>/dev/null)" == "$pid" ]] && rm -f "$HB_PIDFILE"
@@@TO@@@
    :
PAIR

# Arithmetic before validation: `(( pid > 1 ))` on 'a[$(cmd)]' runs cmd, as root.
CASES+=(is-daemon-arithmetic-first)
write_case is-daemon-arithmetic-first "hb_is_daemon refuses an arithmetic payload without evaluating it" <<'PAIR'
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    (( pid > 1 )) || return 1
@@@TO@@@
    (( pid > 1 )) || return 1
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
PAIR

CASES+=(control-comment-only)
write_case control-comment-only "" <<'PAIR'
# hb_dir_trusted <dir> -- root's directory, and nobody else can write in it.
@@@TO@@@
# hb_dir_trusted <dir> -- root's directory, and nobody else can write in it. (x)
PAIR

apply() {   # apply <name>; echo ok|drift
    python3 - "$NDT" "$MUT_DIR/$1/pair" <<'PYAPPLY'
import sys, pathlib
src, pair = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text()
frm, to = pair.split("@@@TO@@@\n")
s = src.read_text()
n = s.count(frm)
if n != 1:
    print(f"drift {n}"); sys.exit(0)
src.write_text(s.replace(frm, to))
print("ok")
PYAPPLY
}

run_suite() {   # echo "<rc>|<comma separated FAILED check names>"
    local out rc
    out="$(timeout "$TEST_TIMEOUT" bash "$SUITE" 2>&1)"; rc=$?
    printf '%s\n' "$out" > "$MUT_DIR/last.out"
    printf '%s|%s' "$rc" "$(printf '%s\n' "$out" | sed -n 's/^  FAILED  *//p' | paste -sd, -)"
}

# --- 0. baseline must be green ----------------------------------------------------------------
echo "=== baseline (the fix, unmutated) ==="
base="$(run_suite)"; base_rc="${base%%|*}"
printf '  rc=%s  red=%s\n' "$base_rc" "${base#*|}"
if [[ "$base_rc" == 124 ]]; then echo "  🔴 baseline HUNG" >&2; exit 2; fi
if (( base_rc > 128 )); then echo "  🔴 baseline died of signal $((base_rc-128))" >&2; exit 2; fi
if [[ "$base_rc" != 0 ]]; then echo "  🔴 baseline is RED -- nothing below is interpretable" >&2; exit 2; fi

# --- 1. one mutation at a time ----------------------------------------------------------------
echo
echo "=== mutations ==="
verdict=0
caught=0; survived=0; invalid=0
for name in "${CASES[@]}"; do
    expect="$(cat "$MUT_DIR/$name/expect")"
    expect="${expect#"${expect%%[![:space:]]*}"}"
    restore
    a="$(apply "$name")"
    if [[ "$a" != ok ]]; then
        echo "  🔴 $name: anchor $a (must be exactly 1) -- the source moved under the gate" >&2
        verdict=2; invalid=$((invalid+1)); continue
    fi
    if ! bash -n "$NDT" 2>/dev/null; then
        echo "  🔴 $name: the mutant does not parse -- that is a broken mutation, not a catch" >&2
        verdict=2; invalid=$((invalid+1)); continue
    fi
    r="$(run_suite)"; rc="${r%%|*}"; red="${r#*|}"
    if [[ "$rc" == 124 ]]; then
        echo "  🔴 $name: suite HUNG -- never a catch" >&2; verdict=2; invalid=$((invalid+1)); continue
    fi
    if (( rc > 128 )); then
        echo "  🔴 $name: suite died of signal $((rc-128)) -- not an assertion" >&2; verdict=2; invalid=$((invalid+1)); continue
    fi
    if [[ -z "$expect" ]]; then                      # the control
        if [[ "$rc" == 0 ]]; then
            printf '  %-30s SURVIVED (control, as required)\n' "$name"
        else
            printf '  %-30s 🔴 CONTROL WENT RED: %s\n' "$name" "$red" >&2
            verdict=2
        fi
        continue
    fi
    if [[ "$rc" == 0 ]]; then
        printf '  %-30s 🔴 SURVIVED -- the suite does not test this\n' "$name" >&2
        (( verdict == 0 )) && verdict=1
        survived=$((survived+1))
    elif [[ ",$red," == *",$expect,"* ]]; then
        printf '  %-30s caught by: %s\n' "$name" "$expect"
        caught=$((caught+1))
    else
        printf '  %-30s 🔴 red, but NOT the named check\n' "$name" >&2
        printf '  %-30s    wanted: %s\n' "" "$expect" >&2
        printf '  %-30s    got:    %s\n' "" "$red" >&2
        (( verdict == 0 )) && verdict=1
        survived=$((survived+1))
    fi
done

# --- 1b. the suite's own python3 fallback, in CI's shape ------------------------------------------
echo
echo "=== the pin's python3 fallback, in CI's shape (no venv; python3 on PATH can import the proxy) ==="
restore
# The interpreter the shim stands in for setup-python's python3 with: one that CAN import it.
MAIN_WT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PIN_OK=""
for c in "${PYTHON:-}" "$PWD/p4_proxy/venv/bin/python" "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python" \
         "$(command -v python3)"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import sys; sys.path.insert(0, "p4_proxy"); import proxy_agent.topology_manager' >/dev/null 2>&1 || continue
    PIN_OK="$c"; break
done
SHIM="$MUT_DIR/ci-shim"
mkdir -p "$SHIM"
printf '#!/bin/bash\nexec %q "$@"\n' "$PIN_OK" > "$SHIM/python3"
chmod +x "$SHIM/python3"
ci_run_suite() { PYTHON= HB_PIN_VENVS=/nonexistent/p4_proxy/venv/bin/python PATH="$SHIM:$PATH" run_suite; }
note="the pins' interpreter: $SHIM/python3 (python3 on PATH)"
expect="PERIOD_S is the proxy's LLDP_BEACON_INTERVAL_S"
if [[ -z "$PIN_OK" ]]; then
    echo "  🔴 no interpreter here can import proxy_agent.topology_manager -- CI's shape cannot be built" >&2
    verdict=2; invalid=$((invalid+1))
else
    b="$(ci_run_suite)"
    shim_answered="$(grep -qF -- "$note" "$MUT_DIR/last.out" && echo yes || echo no)"
    printf '  %-30s rc=%s red=%s; python3 on PATH (%s) answered the pin: %s\n' \
        "ci-shape baseline" "${b%%|*}" "${b#*|}" "$PIN_OK" "$shim_answered"
    if [[ "${b%%|*}" != 0 || "$shim_answered" != yes ]]; then
        echo "  🔴 the unmutated suite is not green through the fallback in CI's shape -- no verdict" >&2
        verdict=2; invalid=$((invalid+1))
    else
        python3 - "$SUITE" <<'PYSUITE'
import sys, pathlib
src = pathlib.Path(sys.argv[1])
old = "    PIN_PYS+=(python3)\n"
s = src.read_text()
if s.count(old) != 1:
    print(f"  anchor drift {s.count(old)} (must be exactly 1)")
    sys.exit(3)
src.write_text(s.replace(old, ""))
PYSUITE
        arc=$?
        if (( arc != 0 )) || ! bash -n "$SUITE" 2>/dev/null; then
            echo "  🔴 pin-no-path-fallback: not applied (rc $arc) or does not parse -- the suite moved under the gate" >&2
            verdict=2; invalid=$((invalid+1))
        else
            r="$(ci_run_suite)"; rc="${r%%|*}"; red="${r#*|}"
            if [[ "$rc" == 124 ]] || (( rc > 128 )); then
                echo "  🔴 pin-no-path-fallback: suite hung or died (rc $rc) -- never a catch" >&2
                verdict=2; invalid=$((invalid+1))
            elif [[ "$rc" == 0 ]]; then
                printf '  %-30s 🔴 SURVIVED -- CI would be green without the fallback?\n' pin-no-path-fallback >&2
                (( verdict == 0 )) && verdict=1
                survived=$((survived+1))
            elif [[ ",$red," == *",$expect,"* ]]; then
                printf '  %-30s caught by: %s\n' pin-no-path-fallback "$expect"
                caught=$((caught+1))
            else
                printf '  %-30s 🔴 red, but NOT the named check\n  %-30s    wanted: %s\n  %-30s    got:    %s\n' \
                    pin-no-path-fallback "" "$expect" "" "$red" >&2
                (( verdict == 0 )) && verdict=1
                survived=$((survived+1))
            fi
        fi
    fi
fi

# --- 2. the baseline must be back, byte for byte ------------------------------------------------
restore
echo
if cmp -s "$NDT" "$SNAP" && cmp -s "$SUITE" "$SUITE_SNAP"; then
    echo "restore: $NDT and $SUITE are byte-identical to the pre-gate snapshots"
else
    echo "🔴 restore FAILED -- $NDT or $SUITE differs from its snapshot" >&2
    verdict=2
fi
after="$(run_suite)"
if [[ "${after%%|*}" == 0 ]]; then
    echo "after restore: the suite is green again"
else
    echo "🔴 after restore the suite is RED: ${after#*|}" >&2
    verdict=2
fi

echo
echo "mutants: $(( ${#CASES[@]} - 1 )) named + 1 control, and 1 of the suite in CI's shape; caught $caught, survived $survived, invalid $invalid"
case "$verdict" in
    0) echo "VERDICT: every mutation was caught by the check named for it; the control survived" ;;
    1) echo "VERDICT: at least one mutation survived or was caught by the wrong check" >&2 ;;
    *) echo "VERDICT: no verdict -- the gate could not run cleanly" >&2 ;;
esac
exit "$verdict"
