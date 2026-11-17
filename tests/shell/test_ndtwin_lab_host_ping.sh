#!/usr/bin/env bash
#
# Tests for `ndtwin-lab host-ping <host> <ipv4> <count> <interval>`.
#
# [Co-developed with claude code -- Adam]
#
# The subject is a ROOT entry point: after `sudo install`, any user who holds the helper's grant can
# type it. So most of what is tested is what it refuses, and the one thing it does -- exec nsenter
# into a host's network namespace and run ping there -- is tested by recording the argv instead of
# running it. Sections:
#
#   H1 the command line: exactly four arguments, each validated before anything else happens (no
#      process snapshot is even taken for a refused one), and at most 600 s of ping per call;
#   H2 which process it enters: one `ps` snapshot nominates, /proc decides, and the process must be
#      all-uid-0, in pid 1's user namespace and NOT in pid 1's network namespace -- fixture
#      snapshots and a fixture /proc (HP_PROC) stand in for the machine's; a process that fails that
#      is not a candidate, so a decoy cannot block the host it imitates;
#   H3 what it execs: the exact argv (the network namespace only, through descriptor 3; no mnexec, no
#      mount namespace), the -w deadline, the binaries found only in root-owned places and never
#      through a symlink, and an empty environment;
#   H4 no child it starts carries the host's `mininet:` tag in its argv (`mn -c` kills by command
#      line): recording wrappers for every program it might call, and a ps, stat and readlink planted
#      first on PATH that must never run;
#   H5 how it is reached: the usage line, the dispatch line, the refused-config gate, and that it
#      names none of the user-writable trees the other verbs run code from;
#   H6 the namespace is pinned: descriptor 3 is opened BEFORE the identity check and must still name
#      what /proc/<pid>/ns/net names after it, so a pid that is replaced in between cannot redirect
#      the namespace that is entered.
#
# The fixture's ns/net is a symlink to a regular file named for the namespace, so it can be opened
# like the real one and read back like the real one (readlink of /proc/self/fd/3 names that file).
#
# 🔴 Nothing here needs root, reads the real /proc of another process, or runs nsenter or ping: the
#    exec is a recorder in every cell but H3's environment cell, where it execs a fixture script.
#
# Run:  bash tests/shell/test_ndtwin_lab_host_ping.sh
# Env:  LAB_UNDER_TEST=<path>   (the mutation gate points it at a mutated copy)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="${LAB_UNDER_TEST:-$HERE/../../tools/test_workflow/ndtwin-lab}"
[[ -r "$LAB" ]] || { echo "no helper at $LAB"; exit 2; }

PASS=0; FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: %s\n             actual:   %s\n' "$1" "$2" "$3"; fi
}
yes_if() { if "$@"; then echo yes; else echo no; fi; }

# shellcheck source=/dev/null
source "$LAB" || { echo "  FAILED   could not source $LAB"; echo "Ran 1 checks, 1 failed"; exit 1; }
# The helper runs under `set -euo pipefail`; a suite about refusals cannot.
set +e
declare -F host_ping_main >/dev/null || { echo "  FAILED   host_ping_main is not defined by $LAB"; echo "Ran 1 checks, 1 failed"; exit 1; }
# The helper's own seams, kept before the stand-ins below replace them: H3, H4 and H6 put them back.
ORIG_SNAPSHOT="$(declare -f hp_ps_snapshot)"
ORIG_EXEC="$(declare -f hp_exec)"
ORIG_IDENT="$(declare -f hp_identity_ok)"
eval "orig_${ORIG_IDENT}"

T="$(mktemp -d "${TMPDIR:-/tmp}/ndtwin-lab-host-ping-XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"          # canonical: readlink of an open descriptor names this exact path
ME="$(id -u)"
XUID=$((ME + 1000))               # a uid that is not the one the fixture expects

# --- the fixture machine ------------------------------------------------------------------------
INIT_USER='user:[4026531837]'; INIT_NET='net:[4026531840]'
PROC="$T/proc"
NSDIR="$T/ns"; mkdir -p "$NSDIR"
# nsfile <name> -- the regular file that stands for that namespace; prints its path.
nsfile() { : > "$NSDIR/$1"; printf '%s' "$NSDIR/$1"; }
# mkproc <pid> <uids> <userns> <netns> <argv...> -- one process in the fixture /proc.
mkproc() {
    local pid="$1" uids="$2" un="$3" nn="$4"; shift 4
    mkdir -p "$PROC/$pid/ns"
    printf 'Name:\tbash\nUid:\t%s\nGid:\t0\t0\t0\t0\n' "${uids// /$'\t'}" > "$PROC/$pid/status"
    printf '%s\0' "$@" > "$PROC/$pid/cmdline"
    ln -sfn "$un" "$PROC/$pid/ns/user"
    ln -sfn "$(nsfile "$nn")" "$PROC/$pid/ns/net"
}
reset_proc() { rm -rf "$PROC"; mkproc 1 "0 0 0 0" "$INIT_USER" "$INIT_NET" /sbin/init; }
SNAP=""          # what the stand-in ps prints
SNAP_CALLS="$T/snap.calls"
hp_ps_snapshot() { echo x >> "$SNAP_CALLS"; printf '%s\n' "$SNAP"; }
EXEC_LOG="$T/exec.log"; FD3_LOG="$T/fd3.log"; RC_FILE="$T/rc"
# The recorder: the argv, and what descriptor 3 names at the moment of the exec.
hp_exec() { printf '%s\n' "$*" > "$EXEC_LOG"; /usr/bin/readlink /proc/self/fd/3 > "$FD3_LOG" 2>/dev/null; return 0; }
BIN="$T/bin"; mkdir -p "$BIN"; chmod 755 "$BIN"
printf '#!/bin/bash\necho "argv: $*"\necho "fd3: $(/usr/bin/readlink /proc/self/fd/3)"\nenv | LC_ALL=C sort\n' > "$BIN/nsenter"
printf '#!/bin/bash\nexit 0\n' > "$BIN/ping"
for p in stat readlink ps; do printf '#!/bin/bash\nexec %q "$@"\n' "$(command -v "$p")" > "$BIN/$p"; done
chmod 755 "$BIN/nsenter" "$BIN/ping" "$BIN/stat" "$BIN/readlink" "$BIN/ps"
# mkbin <dir> [omit...] -- a copy of the fixture binaries without the named ones.
mkbin() {
    local d="$1" n; shift
    mkdir -p "$d"; chmod 755 "$d"
    for n in nsenter ping stat readlink ps; do
        [[ " $* " == *" $n "* ]] && continue
        cp "$BIN/$n" "$d/$n"
    done
}
HP_PROC="$PROC"
HP_EXPECT_UID="$ME"
SHIPPED_BIN_DIRS=("${HP_BIN_DIRS[@]}")
SHIPPED_STAT_DIRS=("${HP_STAT_DIRS[@]}")
# use_dirs <dir> -- the fixture's one directory, for the binaries and for stat alike.
use_dirs() { HP_BIN_DIRS=("$1"); HP_STAT_DIRS=("$1"); }
use_dirs "$BIN"
hp_tools || { echo "  FAILED   the fixture's stat, ps and readlink were not accepted"; echo "Ran 1 checks, 1 failed"; exit 1; }
NSE="$BIN/nsenter --net=/proc/self/fd/3"

# A Mininet host shell, as Mininet starts it.
HOSTARGV=(bash --norc --noediting -is mininet:h1)
HOSTNET='net:[4026532999]'
good_host() { mkproc 4242 "$ME $ME $ME $ME" "$INIT_USER" "$HOSTNET" "${HOSTARGV[@]}"; SNAP="4242 ${HOSTARGV[*]}"; }

# run <args...> -- host_ping_main in a subshell; sets RC, ERR, EXEC (the recorded argv or "none") and
# FD3 (what descriptor 3 named at the exec, or "none").
run() {
    rm -f "$EXEC_LOG" "$FD3_LOG" "$RC_FILE"; : > "$SNAP_CALLS"
    ERR="$( (host_ping_main "$@"; echo $? > "$RC_FILE") 2>&1 >/dev/null)"
    RC="$(cat "$RC_FILE" 2>/dev/null || echo none)"
    EXEC="$(cat "$EXEC_LOG" 2>/dev/null || echo none)"
    FD3="$(cat "$FD3_LOG" 2>/dev/null || echo none)"
}

reset_proc; good_host

echo "H1 the command line: four arguments, each checked before anything happens"
run h1 10.0.3.3 3000 0.02
check "control: 'h1 10.0.3.3 3000 0.02' reaches the exec (rc 0)" "0 $NSE $BIN/ping -n -q -c 3000 -i 0.02 -w 65 10.0.3.3" "$RC $EXEC"
H32="h$(printf 'x%.0s' $(seq 1 31))"
H33="${H32}x"
for bad in "h1 x|10.0.3.3|3000|0.02|host" "h1;id|10.0.3.3|3000|0.02|host" "mininet:h1|10.0.3.3|3000|0.02|host" \
           "|10.0.3.3|3000|0.02|host" "$H33|10.0.3.3|3000|0.02|host" "1h|10.0.3.3|3000|0.02|host" "-f|10.0.3.3|3000|0.02|host" \
           "h1|10.0.3.256|3000|0.02|address" "h1|10.0.3|3000|0.02|address" "h1|-f|3000|0.02|address" \
           "h1|1.2.3.4 -f|3000|0.02|address" "h1|010.0.0.1|3000|0.02|address" "h1|h3|3000|0.02|address" \
           "h1|10.0.3.3|0|0.02|count" "h1|10.0.3.3|60001|0.02|count" "h1|10.0.3.3|3e3|0.02|count" \
           "h1|10.0.3.3|-1|0.02|count" "h1|10.0.3.3|0300|0.02|count" "h1|10.0.3.3|30 0|0.02|count" \
           "h1|10.0.3.3|3000|0.009|interval" "h1|10.0.3.3|3000|1e-2|interval" "h1|10.0.3.3|3000|10.001|interval" \
           "h1|10.0.3.3|3000|0.02;|interval" "h1|10.0.3.3|3000|00.5|interval" "h1|10.0.3.3|3000|0.0001|interval" \
           "h1|10.0.3.3|3000|0|interval" "h1|10.0.3.3|3000|-0.5|interval" \
           "h1|10.0.3.3|61|10|duration" "h1|10.0.3.3|601|1|duration" "h1|10.0.3.3|60000|0.011|duration" \
           "h1|10.0.3.3|3000|10|duration" "h1|10.0.3.3|60000|10|duration"; do
    IFS='|' read -r a b c d what <<<"$bad"
    run "$a" "$b" "$c" "$d"
    check "refused (64), nothing entered: $(printf '%q ' "$a" "$b" "$c" "$d")" "64 none 0" "$RC $EXEC $(grep -c . "$SNAP_CALLS")"
    check "  and the refusal names the $what" "yes" "$(yes_if grep -q "refusing $what" <<<"$ERR")"
done
run h1 10.0.3.3 3000 0.02 extra
check "a fifth argument: refused (64), nothing entered" "64 none" "$RC $EXEC"
run h1 10.0.3.3 3000
check "three arguments: refused (64), nothing entered" "64 none" "$RC $EXEC"
check "  and the usage line says exactly four" "yes" "$(yes_if grep -q 'exactly four arguments (got 3)' <<<"$ERR")"
run
check "no arguments: refused (64)" "64 none" "$RC $EXEC"
# The edges that must still be accepted -- a validator that refused them would make the verb useless.
mkproc 4343 "$ME $ME $ME $ME" "$INIT_USER" 'net:[4026532998]' bash --norc --noediting -is "mininet:$H32"
SNAP="4343 bash --norc --noediting -is mininet:$H32"
run "$H32" 255.255.255.255 60 10
check "control: a 32-character host, 255.255.255.255, 60 x 10 s (600 s, the ceiling) are accepted" "0 -w 605" \
      "$RC $(grep -o -e '-w 605' <<<"$EXEC")"
good_host
run h1 10.0.3.3 60000 0.01
check "control: 60000 x 0.01 s is 600 s, accepted (-w 605)" "0 -w 605" "$RC $(grep -o -e '-w 605' <<<"$EXEC")"
run h1 10.0.3.3 600 1
check "control: 600 x 1 s is 600 s, accepted (-w 605)" "0 -w 605" "$RC $(grep -o -e '-w 605' <<<"$EXEC")"
run h1 0.0.0.0 1 0.01
check "control: 0.0.0.0, 1, 0.01 are accepted (-w 6)" "0 $NSE $BIN/ping -n -q -c 1 -i 0.01 -w 6 0.0.0.0" "$RC $EXEC"
run h1 10.0.3.3 7 0.3
check "control: interval 0.3, and the deadline is rounded UP: 7 x 0.3 s = 2.1 s -> -w 8" "0 $NSE $BIN/ping -n -q -c 7 -i 0.3 -w 8 10.0.3.3" "$RC $EXEC"
run h1 10.0.3.3 300 1.5
check "control: 300 x 1.5 s -> -w 455" "0 $NSE $BIN/ping -n -q -c 300 -i 1.5 -w 455 10.0.3.3" "$RC $EXEC"

echo "H2 which process it enters"
reset_proc; good_host
run h1 10.0.3.3 3000 0.02
check "a root, init-userns, own-netns 'bash ... -is mininet:h1' -> its namespace is entered" "0 $NSDIR/$HOSTNET" "$RC $FD3"
mkproc 4242 "$XUID $XUID $XUID $XUID" "$INIT_USER" "$HOSTNET" "${HOSTARGV[@]}"
run h1 10.0.3.3 3000 0.02
check "the same argv owned by another uid -> 66, not entered" "66 none" "$RC $EXEC"
check "  and the refusal names the uids" "yes" "$(yes_if grep -q "uids (real, effective, saved, fs) are '$XUID $XUID $XUID $XUID'" <<<"$ERR")"
mkproc 4242 "$ME $XUID $ME $ME" "$INIT_USER" "$HOSTNET" "${HOSTARGV[@]}"
run h1 10.0.3.3 3000 0.02
check "real uid right but effective uid wrong -> 66" "66 none" "$RC $EXEC"
mkproc 4242 "$XUID $ME $ME $ME" "$INIT_USER" "$HOSTNET" "${HOSTARGV[@]}"
run h1 10.0.3.3 3000 0.02
check "real uid wrong, the other three right -> 66" "66 none" "$RC $EXEC"
mkproc 4242 "$ME $ME $XUID $ME" "$INIT_USER" "$HOSTNET" "${HOSTARGV[@]}"
run h1 10.0.3.3 3000 0.02
check "saved uid wrong, real and effective right -> 66" "66 none" "$RC $EXEC"
mkproc 4242 "$ME $ME $ME $XUID" "$INIT_USER" "$HOSTNET" "${HOSTARGV[@]}"
run h1 10.0.3.3 3000 0.02
check "filesystem uid wrong, the other three right -> 66" "66 none" "$RC $EXEC"
mkproc 4242 "$ME $ME $ME" "$INIT_USER" "$HOSTNET" "${HOSTARGV[@]}"
run h1 10.0.3.3 3000 0.02
check "a Uid line with three fields instead of four -> 66" "66 none" "$RC $EXEC"
mkproc 4242 "$ME $ME $ME $ME" 'user:[4026533111]' "$HOSTNET" "${HOSTARGV[@]}"
run h1 10.0.3.3 3000 0.02
check "root, but in another user namespace -> 66" "66 none" "$RC $EXEC"
check "  and the refusal names the user namespace" "yes" "$(yes_if grep -q 'user namespace (user:\[4026533111\]) is not pid 1' <<<"$ERR")"
mkproc 4242 "$ME $ME $ME $ME" "$INIT_USER" "$INIT_NET" "${HOSTARGV[@]}"
run h1 10.0.3.3 3000 0.02
check "root, but in pid 1's network namespace -> 66" "66 none" "$RC $EXEC"
check "  and the refusal names the network namespace" "yes" "$(yes_if grep -qF "network namespace ($NSDIR/$INIT_NET) is pid 1" <<<"$ERR")"
# Everything else about this process passes, so only the unreadable namespace can refuse it.
good_host
rm -f "$PROC/4242/ns/user"
run h1 10.0.3.3 3000 0.02
check "a user namespace that cannot be read -> 66" "66 none" "$RC $EXEC"
good_host
rm -f "$PROC/4242/ns/net"
run h1 10.0.3.3 3000 0.02
check "a network namespace that cannot be read or opened -> 66" "66 none" "$RC $EXEC"
good_host
chmod 000 "$NSDIR/$HOSTNET"
if [[ -r "$NSDIR/$HOSTNET" ]]; then
    echo "  (note)   this user can read a mode-000 file (root?); the unopenable-file cell is not run"
else
    run h1 10.0.3.3 3000 0.02
    check "a network namespace that exists but cannot be opened -> 66, and it says so" "66 none yes" \
          "$RC $EXEC $(yes_if grep -q 'cannot open its network namespace' <<<"$ERR")"
fi
chmod 644 "$NSDIR/$HOSTNET"
reset_proc
mkproc 4242 "$ME $ME $ME $ME" "$INIT_USER" "$INIT_NET" bash --norc --noediting -is mininet:s1
SNAP="4242 bash --norc --noediting -is mininet:s1"
run s1 10.0.3.3 3000 0.02
check "a switch's shell (same tag shape, the machine's network namespace) -> 66" "66 none" "$RC $EXEC"
reset_proc; good_host
mkproc 5151 "$ME $ME $ME $ME" "$INIT_USER" 'net:[4026532777]' "${HOSTARGV[@]}"
SNAP="4242 ${HOSTARGV[*]}"$'\n'"5151 ${HOSTARGV[*]}"
run h1 10.0.3.3 3000 0.02
check "two candidates that both pass -> 65, neither entered" "65 none" "$RC $EXEC"
check "  and the refusal names both pids" "yes" "$(yes_if grep -q 'pids 4242 5151' <<<"$ERR")"
# A process of anybody's can carry the tag; it must not be able to make the real host unreachable.
reset_proc; good_host
mkproc 5151 "$XUID $XUID $XUID $XUID" "$INIT_USER" 'net:[4026532777]' "${HOSTARGV[@]}"
SNAP="5151 ${HOSTARGV[*]}"$'\n'"4242 ${HOSTARGV[*]}"
run h1 10.0.3.3 3000 0.02
check "a decoy with the tag owned by another uid does not block the host: the real one is entered" "0 $NSDIR/$HOSTNET" "$RC $FD3"
mkproc 5151 "$ME $ME $ME $ME" 'user:[4026533111]' 'net:[4026532777]' "${HOSTARGV[@]}"
run h1 10.0.3.3 3000 0.02
check "a decoy in its own user namespace does not block it either" "0 $NSDIR/$HOSTNET" "$RC $FD3"
reset_proc
mkproc 5151 "$XUID $XUID $XUID $XUID" "$INIT_USER" 'net:[4026532777]' "${HOSTARGV[@]}"
mkproc 5252 "$ME $ME $ME $ME" 'user:[4026533111]' 'net:[4026532666]' "${HOSTARGV[@]}"
SNAP="5151 ${HOSTARGV[*]}"$'\n'"5252 ${HOSTARGV[*]}"
run h1 10.0.3.3 3000 0.02
check "only decoys carry the tag -> 66 (not 65), nothing entered" "66 none" "$RC $EXEC"
check "  and the refusal names the rejected pids" "yes" "$(yes_if grep -q 'rejected pids 5151 5252' <<<"$ERR")"
reset_proc
mkproc 4242 "$ME $ME $ME $ME" "$INIT_USER" 'net:[4026532999]' bash --norc --noediting -is mininet:h10
SNAP="4242 bash --norc --noediting -is mininet:h10"
run h1 10.0.3.3 3000 0.02
check "'mininet:h10' does not answer h1 -> 65" "65 none" "$RC $EXEC"
check "  and the refusal says no Mininet host h1" "yes" "$(yes_if grep -q 'no Mininet host h1:' <<<"$ERR")"
reset_proc
mkproc 4242 "$ME $ME $ME $ME" "$INIT_USER" 'net:[4026532999]' bash -c 'sleep 9 mininet:h1'
SNAP="4242 bash -c sleep 9 mininet:h1"
run h1 10.0.3.3 3000 0.02
check "ps's joined args end in the tag, /proc's last element is not the tag -> 65" "65 none" "$RC $EXEC"
reset_proc
SNAP="4242 ${HOSTARGV[*]}"
run h1 10.0.3.3 3000 0.02
check "nominated by ps, gone from /proc (exited) -> 65" "65 none" "$RC $EXEC"
reset_proc
mkproc 4242 "$ME $ME $ME $ME" "$INIT_USER" 'net:[4026532999]' bash --norc --noediting -is xmininet:h1
SNAP="4242 bash --norc --noediting -is xmininet:h1"
run h1 10.0.3.3 3000 0.02
check "a last word that only ENDS in the tag ('xmininet:h1') -> 65" "65 none" "$RC $EXEC"

echo "H3 what it execs"
reset_proc; good_host
run h1 10.0.3.3 3000 0.02
check "exactly: <nsenter> --net=/proc/self/fd/3 <ping> -n -q -c 3000 -i 0.02 -w 65 10.0.3.3" \
      "$NSE $BIN/ping -n -q -c 3000 -i 0.02 -w 65 10.0.3.3" "$EXEC"
check "the argv has no mnexec at all" "0" "$(grep -c mnexec <<<"$EXEC")"
check "the only namespace it joins is the network one, before ping's own path" "$BIN/nsenter --net=/proc/self/fd/3" "${EXEC%% $BIN/ping *}"
check "descriptor 3 names the host's network namespace when it execs" "$NSDIR/$HOSTNET" "$FD3"
check "the shipped search path starts with /usr/bin and holds only root's directories" \
      "/usr/bin /usr/bin /usr/sbin /bin /sbin /usr/local/bin /usr/local/sbin" "${SHIPPED_BIN_DIRS[0]} ${SHIPPED_BIN_DIRS[*]}"
if [[ "$(stat -c %u /usr/bin/ping /usr/bin/nsenter /usr/bin/stat /usr/bin/ps /usr/bin/readlink 2>/dev/null | sort -u | tr '\n' ' ')" == "0 " ]]; then
    # (hp_tools itself would run here as the wrong user's check; stat is named, and each of the five
    # is then checked as root's.)
    got="$(HP_BIN_DIRS=("${SHIPPED_BIN_DIRS[@]}"); HP_EXPECT_UID=0; HP_STAT=/usr/bin/stat
           echo "$(hp_bin stat) $(hp_bin ps) $(hp_bin readlink) $(hp_bin ping) $(hp_bin nsenter)" 2>&1)"
    check "with the shipped settings, stat, ps, readlink, ping and nsenter are all in /usr/bin" \
          "/usr/bin/stat /usr/bin/ps /usr/bin/readlink /usr/bin/ping /usr/bin/nsenter" "$got"
else
    echo "  (note)   /usr/bin/{ping,nsenter,stat,ps,readlink} are not all root's here; the shipped-settings cell is not run"
fi
cp "$BIN/ping" "$BIN/wide-ping"; chmod 775 "$BIN/wide-ping"
check "a group-writable binary is not used" "1" "$(hp_bin wide-ping >/dev/null 2>&1; echo $?)"
check "a binary owned by another uid is not used" "1" "$(HP_EXPECT_UID=$((ME + 1)); hp_bin ping >/dev/null 2>&1; echo $?)"
OTHER="$T/other"; mkdir -p "$OTHER"; chmod 777 "$OTHER"; cp "$BIN/ping" "$OTHER/ping2"; chmod 755 "$OTHER/ping2"
check "a binary in a world-writable directory is not used" "1" "$(HP_BIN_DIRS=("$OTHER"); hp_bin ping2 >/dev/null 2>&1; echo $?)"
# A symlink is refused outright: -f and stat -L follow it, and the directory that holds its TARGET
# would be checked by nobody.
ln -s "$BIN/ping" "$BIN/ping-link"
check "control: the file the link points at is accepted" "$BIN/ping" "$(hp_bin ping 2>&1)"
check "a symlink to an acceptable binary is not used" "1" "$(hp_bin ping-link >/dev/null 2>&1; echo $?)"
mkbin "$T/nonsenter" nsenter
use_dirs "$T/nonsenter"
run h1 10.0.3.3 3000 0.02
check "no nsenter where it may be -> 67, nothing executed" "67 none" "$RC $EXEC"
check "  and the refusal names nsenter" "yes" "$(yes_if grep -q 'no nsenter owned by uid' <<<"$ERR")"
for tool in stat ps readlink; do
    mkbin "$T/no$tool" "$tool"
    use_dirs "$T/no$tool"
    run h1 10.0.3.3 3000 0.02
    check "no $tool where it may be -> 67, nothing executed, and the refusal names it" "67 none yes" \
          "$RC $EXEC $(yes_if grep -q "no $tool owned by uid" <<<"$ERR")"
done
# stat is the one program that vouches for the others, so it is looked for in two directories only
# (HP_STAT_DIRS), however many HP_BIN_DIRS has. A stat in a weaker directory is never the voucher.
check "the shipped directories stat may come from are /usr/bin and /bin only" "/usr/bin /bin" "${SHIPPED_STAT_DIRS[*]}"
use_dirs "$BIN"; mkdir -p "$T/nostatdir"; HP_STAT_DIRS=("$T/nostatdir")
run h1 10.0.3.3 3000 0.02
check "a stat in HP_BIN_DIRS but not in the stat directories is not used -> 67, nothing executed" "67 none" "$RC $EXEC"
check "  and the refusal names stat" "yes" "$(yes_if grep -q 'no stat owned by uid' <<<"$ERR")"
mkdir -p "$T/statdir"; cp "$BIN/stat" "$T/statdir/stat"; chmod 755 "$T/statdir" "$T/statdir/stat"
use_dirs "$BIN"; HP_STAT_DIRS=("$T/statdir")
check "the stat that vouches is the one from the stat directories, not the first of HP_BIN_DIRS" "$T/statdir/stat" \
      "$(hp_tools; echo "$HP_STAT")"
use_dirs "$BIN"
hp_tools
# The environment: the real exec, into the fixture nsenter, which prints its argv and environment.
envout="$( (eval "$ORIG_EXEC"; export LD_LIBRARY_PATH=/nonexistent PYTHONPATH=/nonexistent NDT_PLANTED=1
            host_ping_main h1 10.0.3.3 3000 0.02) 2>&1)"
check "the real exec ran the binary it found, with the argv it built" "yes" \
      "$(yes_if grep -qxF "argv: --net=/proc/self/fd/3 $BIN/ping -n -q -c 3000 -i 0.02 -w 65 10.0.3.3" <<<"$envout")"
check "descriptor 3 survived the exec, still naming the host's network namespace" "yes" \
      "$(yes_if grep -qxF "fd3: $NSDIR/$HOSTNET" <<<"$envout")"
check "nothing of the caller's environment reaches it (LD_LIBRARY_PATH, PYTHONPATH, HOME, USER, a planted name)" "" \
      "$(grep -E '^(LD_LIBRARY_PATH|PYTHONPATH|NDT_PLANTED|HOME|USER|LANG|LC_ALL)=' <<<"$envout")"
check "control: the caller's environment did hold them (a cell that cannot see them proves nothing)" "yes" \
      "$(held="$(env LD_LIBRARY_PATH=/nonexistent "$BIN/nsenter")"; grep -q '^LD_LIBRARY_PATH=' <<<"$held" && echo yes || echo no)"

echo "H4 no child argv carries the host's mininet: tag, and nothing planted on PATH runs"
SHIM="$T/shim"; mkdir -p "$SHIM"; ARGV_LOG="$T/argv.log"; : > "$ARGV_LOG"
for p in cat grep awk sed tr cut head tail sort; do
    real="$(command -v "$p")"
    [[ -n "$real" ]] || continue
    printf '#!/bin/bash\nprintf "%%s %%s\\n" %q "$*" >> %q\nexec %q "$@"\n' "$p" "$ARGV_LOG" "$real" > "$SHIM/$p"
    chmod 755 "$SHIM/$p"
done
# The helper finds ps, stat and readlink in its fixed directories: these are the ones it must find,
# recording their argv.
RECBIN="$T/recbin"; mkbin "$RECBIN" ps stat readlink
printf '#!/bin/bash\nprintf "%%s %%s\\n" ps "$*" >> %q\nprintf "%%s\\n" "4242 bash --norc --noediting -is mininet:h1"\n' "$ARGV_LOG" > "$RECBIN/ps"
for p in stat readlink; do
    printf '#!/bin/bash\nprintf "%%s %%s\\n" %q "$*" >> %q\nexec %q "$@"\n' "$p" "$ARGV_LOG" "$(command -v "$p")" > "$RECBIN/$p"
done
chmod 755 "$RECBIN/ps" "$RECBIN/stat" "$RECBIN/readlink"
# ...and these are the ones on PATH ahead of everything, which must never run.
PLANT="$T/plant"; mkdir -p "$PLANT"
for p in ps stat readlink; do printf '#!/bin/bash\ntouch %q\nexit 1\n' "$T/planted.$p" > "$PLANT/$p"; chmod 755 "$PLANT/$p"; done
(PATH="$PLANT:$PATH"; ps >/dev/null 2>&1; stat / >/dev/null 2>&1; readlink / >/dev/null 2>&1)
check "control: the planted programs do run when PATH is how they are found" "yes yes yes" \
      "$([[ -e "$T/planted.ps" ]] && echo yes || echo no) $([[ -e "$T/planted.stat" ]] && echo yes || echo no) $([[ -e "$T/planted.readlink" ]] && echo yes || echo no)"
rm -f "$T"/planted.*
reset_proc; good_host
eval "$ORIG_SNAPSHOT"
use_dirs "$RECBIN"
got="$(PATH="$PLANT:$SHIM:$PATH"; (host_ping_main h1 10.0.3.3 3000 0.02) >/dev/null 2>&1; echo $?)"
check "control: the shimmed run still reached the exec (rc 0)" "0" "$got"
check "control: the recording works -- the ps wrapper was called" "yes" "$(yes_if grep -q '^ps ' "$ARGV_LOG")"
check "🔴 no recorded child argv contains 'mininet:'" "" "$(grep -F 'mininet:' "$ARGV_LOG")"
for p in ps stat readlink; do
    check "🔴 a $p planted first on PATH is not run" "no" "$([[ -e "$T/planted.$p" ]] && echo yes || echo no)"
done
use_dirs "$BIN"
hp_tools
hp_ps_snapshot() { echo x >> "$SNAP_CALLS"; printf '%s\n' "$SNAP"; }

echo "H5 how it is reached"
check "the usage line names host-ping and its four arguments" "1" \
      "$(grep -c 'host-ping <host> <ipv4> <count> <interval>|status|config}"$' "$LAB")"
check "the dispatch hands host-ping everything after the verb, and exits with its rc" "1" \
      "$(grep -c '^    host-ping) shift; hp_rc=0; host_ping_main "\$@" || hp_rc=\$?; exit "\$hp_rc" ;;$' "$LAB")"
gate="$( ( LAB_CONF_ERROR="something is wrong"; lab_conf_gate host-ping ) 2>&1)"; grc=$?
check "under a refused config, host-ping fails closed (rc 1)" "1" "$grc"
check "  and says it refuses host-ping" "yes" "$(yes_if grep -q "refusing to run 'host-ping'" <<<"$gate")"
( LAB_CONF_ERROR="something is wrong"; lab_conf_gate status ) >/dev/null 2>&1
check "control: the same config lets status run (rc 0)" "0" "$?"
body="$(declare -f host_ping_main hp_find_host hp_identity_ok hp_bin hp_tools hp_exec hp_cmdline_last hp_ps_snapshot \
        hp_valid_host hp_valid_ipv4 hp_valid_count hp_interval_ms hp_deadline hp_duration_ok hp_pin_netns hp_refuse)"
check "it names none of the trees user code runs from (KERNEL_DIR, NTG_DIR, NTG_PY, BRIDGE, TMUX)" "" \
      "$(grep -oE 'KERNEL_DIR|NTG_DIR|NTG_PY|BRIDGE|TMUX|ENERGY_DIR|SIM_DIR' <<<"$body" | sort -u | tr '\n' ' ')"

echo "H6 the namespace is pinned before it is checked"
# The process is replaced right after the identity check has looked at it: the hook runs the real
# check, then re-points (or removes) the pid's ns/net, which is what a pid that exited and was
# reused looks like to the helper. Only the hook's second kind waits for descriptor 3 to be open.
SWAPS=0; SWAP_MODE=""
hook_identity() {
    orig_hp_identity_ok "$@"; local rc=$?
    SWAPS=$((SWAPS + 1))
    case "$SWAP_MODE" in
        same) ln -sfn "$(nsfile "$HOSTNET")" "$PROC/$1/ns/net" ;;
        new)  ln -sfn "$(nsfile "net:[9$BASHPID.$SWAPS]")" "$PROC/$1/ns/net" ;;
        gone) [[ -e /proc/self/fd/3 ]] && rm -f "$PROC/$1/ns/net" ;;
        # The pid is reused BEFORE descriptor 3 is opened: the first call is the candidate filter's.
        nonroot)  [[ $SWAPS == 1 ]] && mkproc "$1" "$XUID $XUID $XUID $XUID" "$INIT_USER" 'net:[4026540777]' "${HOSTARGV[@]}" ;;
        roothost) [[ $SWAPS == 1 ]] && mkproc "$1" "$ME $ME $ME $ME" "$INIT_USER" 'net:[4026540888]' "${HOSTARGV[@]}" ;;
    esac
    return $rc
}
hp_identity_ok() { hook_identity "$@"; }
reset_proc; good_host
SWAP_MODE=same; run h1 10.0.3.3 3000 0.02
check "control: a hook that leaves ns/net where it was changes nothing (rc 0, executed)" "0 $NSE $BIN/ping -n -q -c 3000 -i 0.02 -w 65 10.0.3.3" "$RC $EXEC"
reset_proc; good_host
SWAP_MODE=new; run h1 10.0.3.3 3000 0.02
check "ns/net re-pointed at another namespace after the check -> 66, nothing executed" "66 none" "$RC $EXEC"
check "  and the refusal says it changed" "yes" "$(yes_if grep -q 'network namespace changed' <<<"$ERR")"
reset_proc; good_host
SWAP_MODE=gone; run h1 10.0.3.3 3000 0.02
check "ns/net gone after the check (the process exited) -> 66, nothing executed" "66 none" "$RC $EXEC"
# The other side of the race: the pid is reused BEFORE the open. Descriptor 3 and the second reading
# then both name the newcomer's namespace and match, so only the identity check that runs after the
# open can stop it -- and it stops exactly what it checks: a process that is not root-made.
reset_proc; good_host
SWAP_MODE=nonroot; run h1 10.0.3.3 3000 0.02
check "a pid replaced BEFORE the open by a non-root process in a new namespace -> 66, nothing executed" "66 none" "$RC $EXEC"
check "  and the refusal names its uids" "yes" "$(yes_if grep -q "uids (real, effective, saved, fs) are '$XUID $XUID $XUID $XUID'" <<<"$ERR")"
reset_proc; good_host
SWAP_MODE=roothost; run h1 10.0.3.3 3000 0.02
check "the stated residual: a root-made newcomer with the tag, replaced BEFORE the open, is entered (its own namespace)" \
      "0 $NSDIR/net:[4026540888]" "$RC $FD3"
SWAP_MODE=""
eval "$ORIG_IDENT"
reset_proc; good_host

echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
