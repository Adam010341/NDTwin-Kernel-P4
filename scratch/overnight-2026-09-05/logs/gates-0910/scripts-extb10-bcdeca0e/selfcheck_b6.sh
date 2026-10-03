#!/usr/bin/env bash
# selfcheck_b6.sh <tripwire_b6.sh> <wrapper dir> -- every condition the wrapper refuses and the tripwire flags, each
# seen red on a fixture of its own, and the good forms green (round-6 re-review: "self-check fixtures for every
# wrapper and tripwire condition"). euid 0 needs root to exercise and is NOT run here: said, not claimed.
# rc 0 only when every expectation holds. [Co-developed with claude code -- Adam]
set -u
TW="$1"; W="$2"; bad=0; n=0
T="$(mktemp -d "${TMPDIR:-/tmp}/selfcheck-b6-XXXXXX")"; trap 'rm -rf "$T"' EXIT
export TRIPWIRE_TMP_ROOT="$T"
read -r -a st < /proc/$$/stat
OK='--use-files 0 -i 1@p1 -i 255@p255 --thrift-port 29400 --device-id 900001 --notifications-addr ipc://notif.ipc --log-file bmv2 --log-level debug --log-flush /x/a.json'
line() {   # line <kind> <which> <uid> <argv0> <cwd> <args> [pid start]
    printf '1.0 %s %s pid=%s start=%s uid=%s argv0=%s cwd=%s exe=ndt-hbdrop-bmv2 args=%s\n' "$1" "$2" "${7:-1}" "${8:-1}" "$3" "$4" "$5" "$6"
}
tw() {   # tw <label> <want rc> <want text in the output> <one log line>
    n=$((n+1)); printf '%s\n' "$4" > "$T/f.log"
    out="$(bash "$TW" "$T/f.log" 2>&1)"; rc=$?
    if [[ "$rc" == "$2" ]] && /usr/bin/grep -qF -- "$3" <<<"$out"; then echo "  ok    tripwire $1 (rc $rc)"
    else echo "  BAD   tripwire $1: rc $rc, want $2 and '$3': $(tail -3 <<<"$out" | tr '\n' ' ' | cut -c1-200)"; bad=1; fi
}
C="$T/ndt-hbdrop-a"; mkdir -p "$C"
tw "good switch line"            0 "0 breaking a condition"      "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$C" "$OK")"
tw "good probe line"             0 "0 breaking a condition"      "$(line ALLOWED-PROBE simple_switch_grpc 1000 ndt-hbdrop-bmv2 /anywhere --version)"
tw "uid 0"                       1 "uid 0"                       "$(line ALLOWED-LAUNCH simple_switch 0 ndt-hbdrop-bmv2 "$C" "$OK")"
tw "argv0"                       1 "argv0 simple_switch"         "$(line ALLOWED-LAUNCH simple_switch 1000 simple_switch "$C" "$OK")"
tw "an argument naming simple_switch" 1 "an argument names simple_switch" "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$C" "$OK /x/simple_switch_grpc")"
tw "no --use-files"              1 "not --use-files"             "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$C" "${OK/--use-files 0 /}")"
tw "a bad -i"                    1 "interfaces"                  "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$C" "${OK/1@p1/1@veth1}")"
tw "Thrift port"                 1 "thrift 9091"                 "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$C" "${OK/29400/9091}")"
tw "device id"                   1 "device id 1"                 "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$C" "${OK/900001/1}")"
tw "notifications address"       1 "notifications None"          "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$C" "${OK/ --notifications-addr ipc:\/\/notif.ipc/}")"
tw "absolute --log-file"         1 "log file /abs/bmv2"          "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$C" "${OK/--log-file bmv2/--log-file /abs/bmv2}")"
tw "a switch through the fabric wrapper" 1 "a switch from the simple_switch_grpc wrapper" "$(line ALLOWED-LAUNCH simple_switch_grpc 1000 ndt-hbdrop-bmv2 "$C" "$OK")"
tw "a ndt-hbdrop-ver-* cwd"      1 "cwd $T/ndt-hbdrop-ver-x"     "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$T/ndt-hbdrop-ver-x" "$OK")"
tw "a cwd that is not ndt-hbdrop-*" 1 "cwd $T/other"             "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$T/other" "$OK")"
tw "a cwd outside TMPDIR"        1 "not under"                   "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 /var/tmp/ndt-hbdrop-a "$OK")"
tw "a probe with other args"     1 "a probe with args"           "$(line ALLOWED-PROBE simple_switch 1000 ndt-hbdrop-bmv2 "$C" "--version --help")"
tw "a probe with another argv0"  1 "argv0 simple_switch_grpc"    "$(line ALLOWED-PROBE simple_switch 1000 simple_switch_grpc "$C" --version)"
tw "an allowed line it cannot read" 1 "cannot read"              "1.0 ALLOWED-LAUNCH simple_switch something else entirely"
tw "a refused launch"            1 "1 refused by the wrapper"    "1.0 REFUSED-LAUNCH simple_switch why=device-id-1 pid=1 start=1 uid=1000 argv0=ndt-hbdrop-bmv2 cwd=$C args=x"
tw "a launch still running (pid and start time)" 1 "1 still running" "$(line ALLOWED-LAUNCH simple_switch 1000 ndt-hbdrop-bmv2 "$C" "$OK" "$$" "${st[21]}")"
tw "a lab call"                  1 "1 lab call(s)"               "gates extb6 sudo -n true"

# --- the wrapper: every refusal, and a good call of each kind ----------------------------------
export NOLAB_LOG="$T/wrap.log" HBWRAP_ROOT="$T"
wr() {   # wr <label> <want reason, or ALLOWED> <binary> <argv0> <cwd> <args...>
    local label="$1" want="$2" bin="$W/$3" a0="$4" cwd="$5"; shift 5; n=$((n+1)); : > "$NOLAB_LOG"
    mkdir -p "$cwd"
    out="$(cd "$cwd" && NDT_HB_CHECK_ARGV0="$a0" timeout 10 "$bin" "$@" 2>&1)"; rc=$?
    if [[ "$want" == ALLOWED ]]; then
        if [[ "$rc" == 0 ]] && /usr/bin/grep -q " ALLOWED-" "$NOLAB_LOG"; then echo "  ok    wrapper $label (rc 0, logged allowed)"
        else echo "  BAD   wrapper $label: rc $rc, log '$(cut -c1-120 "$NOLAB_LOG")'"; bad=1; fi
    elif [[ "$rc" == 97 ]] && /usr/bin/grep -qF "REFUSED-LAUNCH" "$NOLAB_LOG" && /usr/bin/grep -qF -- "why=$want" "$NOLAB_LOG"; then
        echo "  ok    wrapper $label (rc 97, why=$want, nothing exec'd)"
    else echo "  BAD   wrapper $label: rc $rc, want 97 why=$want; log '$(cut -c1-160 "$NOLAB_LOG")' out '$(cut -c1-100 <<<"$out")'"; bad=1; fi
}
read -r -a A <<<"$OK"
wr "a good --version"            ALLOWED simple_switch ndt-hbdrop-bmv2 "$T/ndt-hbdrop-ver-p" --version
wr "a good fabric --version"     ALLOWED simple_switch_grpc ndt-hbdrop-bmv2 "$T/ndt-hbdrop-ver-q" --version
wr "argv0"                       argv0-simple_switch simple_switch simple_switch "$C" --version
wr "an argument naming simple_switch" an-argument-names-simple_switch simple_switch ndt-hbdrop-bmv2 "$C" "${A[@]}" /x/simple_switch
wr "the fabric binary as a switch" the-fabric-binary-only-answers---version simple_switch_grpc ndt-hbdrop-bmv2 "$C" "${A[@]}"
wr "a cwd that is not its own"   cwd-not-its-own simple_switch ndt-hbdrop-bmv2 "$T/other" "${A[@]}"
wr "a ndt-hbdrop-ver-* cwd"      cwd-not-its-own simple_switch ndt-hbdrop-bmv2 "$T/ndt-hbdrop-ver-r" "${A[@]}"
wr "a cwd outside TMPDIR"        "cwd-not-under-$(realpath -m "$T")" simple_switch ndt-hbdrop-bmv2 "$(mktemp -d /tmp/claude-1000/ndt-hbdrop-out-XXXX)" "${A[@]}"
wr "a bad -i"                    interface-1@veth1 simple_switch ndt-hbdrop-bmv2 "$C" "${A[@]/1@p1/1@veth1}"
wr "no --use-files"              not-use-files simple_switch ndt-hbdrop-bmv2 "$C" -i 1@p1 --thrift-port 29400 --device-id 900001 --notifications-addr ipc://notif.ipc --log-file bmv2 /x/a.json
wr "Thrift port"                 thrift-port-9091 simple_switch ndt-hbdrop-bmv2 "$C" "${A[@]/29400/9091}"
wr "device id"                   device-id-1 simple_switch ndt-hbdrop-bmv2 "$C" "${A[@]/900001/1}"
wr "no notifications address"    notifications-addr-default simple_switch ndt-hbdrop-bmv2 "$C" --use-files 0 -i 1@p1 --thrift-port 29400 --device-id 900001 --log-file bmv2 /x/a.json
wr "an absolute --log-file"      log-file-/abs/bmv2 simple_switch ndt-hbdrop-bmv2 "$C" "${A[@]/#bmv2/\/abs\/bmv2}"
echo "  --    wrapper euid 0: not exercised (needs root); the refusal is the first line of the wrapper, '(( EUID != 0 ))'"
rmdir /tmp/claude-1000/ndt-hbdrop-out-* 2>/dev/null
echo "SELFCHECK-B6: $n fixture(s), $([[ $bad == 0 ]] && echo 'every one as expected' || echo 'SOME NOT AS EXPECTED')"
exit $bad
