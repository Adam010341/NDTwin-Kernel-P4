#!/usr/bin/env bash
#
# Tests for tools/test_workflow/sudo_surface.sh and the two `ndt` call sites that read it.
#
# [Co-developed with claude code -- Adam]
#
# The defect: `ndt` calls `sudo -n` in many places; all but one go through ndtwin-lab, which the
# manual teaches the reader to grant, and `ovs-vsctl list-br` is in no page of the Installation or
# User Manual. (The forwarding check used to call `mnexec`, which was the second such program; it
# now asks the helper's host-ping verb, and `ndt` makes no `sudo mnexec` call at all.) A refusal
# of either arrived as a plausible value:
#
#   ovs_bridge_count()  answered 0, which is also "there is no OVS here", so `ndt up p4`'s
#                       refusal to build over a live OVS fabric never fired.
#   dataplane_ok()      answered "does not forward", printed as the specific and false
#                       `h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding`. sudo's
#                       refusal and ping's no-reply are both exit 1, so the verdict comes from
#                       what ping printed (its summary, or its own error line with exit 2) and
#                       never from the exit status alone.
#
# 🔴 Both directions are tested. A version that answers "cannot tell" to everything would
# satisfy every refusal case below and make `ndt up p4` impossible to run, so each refusal case
# is paired with a control in which the grant IS live and the old answer must still come back.
# The cases marked "control" are the ones a refuse-everything implementation fails.
#
# No lab contact, no real sudo. A fake `sudo` on PATH reproduces the refusal verbatim as
# measured from sudo 1.9.15p5 on 2026-09-03 (`sudo -n ovs-ofctl --version` with no matching
# NOPASSWD rule: rc 1, "sudo: a password is required"), a fake ovs-vsctl and a fake
# ndtwin-lab that answers `host-ping` in simplified shapes of what the real helper gives (a ping summary
# whose counts are made up, ping's error line with the absolute-path prefix measured on the real ping,
# the helper's own refusal, or nothing readable) stand in for the privileged commands. Nothing here starts a
# topology, binds a port, or touches a claim -- another session may be measuring.
#
# Run:  bash tests/shell/test_ndt_sudo_surface.sh
# Env:  SURFACE_UNDER_TEST=<path>  NDT_UNDER_TEST=<path>   (the mutation gate sets both)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SURFACE="${SURFACE_UNDER_TEST:-$HERE/../../tools/test_workflow/sudo_surface.sh}"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n    %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: $2 / actual: $3"; }
has()   { grep -q -- "$2" <<<"$3" && t_ok "$1" || t_bad "$1" "no match for '$2' in: $3"; }
hasnt() { grep -q -- "$2" <<<"$3" && t_bad "$1" "unexpected '$2' in: $3" || t_ok "$1"; }

BIN="$(mktemp -d "${TMPDIR:-/tmp}/ndt-sudo-fakes-XXXXXX")"
# [Co-developed with claude code -- Adam] A scratch checkout for the one case that runs up_p4: ndt
# derives REPO from where it sits, so without this that case wrote up.target and the knobs of the
# tree the test is run from.
UPFIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-sudo-repo-XXXXXX")"; export UPFIX
trap 'rm -rf "$BIN" "$UPFIX"' EXIT

# --- the fakes -------------------------------------------------------------------------------
# `sudo` refuses the binaries named in FAKE_SUDO_DENY with sudo's own measured wording, and
# otherwise runs them. Everything downstream therefore sees a real exit status and a real
# stderr rather than a value the test chose for it.
# [Co-developed with claude code -- Adam] (09-27) FAKE_SUDO_SAY replaces that wording (set but empty:
# a refusal that prints nothing), and FAKE_SUDO_WARN is a line sudo prints on stderr BEFORE it
# refuses or runs -- its non-fatal warnings, e.g. "unable to resolve host".
cat >"$BIN/sudo" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == "-n" ]] && shift
base="${1##*/}"
# [Co-developed with claude code -- Adam] FAKE_SUDO_LOG: every call, as sudo would have been given it.
[[ -n "${FAKE_SUDO_LOG:-}" ]] && printf '%s\n' "$*" >> "$FAKE_SUDO_LOG"
[[ -n "${FAKE_SUDO_WARN:-}" ]] && printf '%s\n' "$FAKE_SUDO_WARN" >&2
# [Co-developed with claude code -- Adam] Only the ndtwin-lab that sits beside this fake may run. The table's own
# probe names /usr/local/sbin/ndtwin-lab, and this fake runs whatever it does not refuse, so without this a
# control case (or a mutant of the code under test) would run the helper installed on this machine as this user.
if [[ "$base" == ndtwin-lab && "$(dirname "$1")" != "$(dirname "$0")" ]]; then
    printf '%s\n' "sudo: a password is required" >&2
    exit 1
fi
# [Co-developed with claude code -- Adam] An entry "<base>:<verb>" refuses only that verb, so a case can
# refuse `ndtwin-lab status` and nothing else the helper does.
case " ${FAKE_SUDO_DENY:-} " in
    *" $base "*|*" $base:${2:-} "*) [[ -n "${FAKE_SUDO_SAY-x}" ]] && printf '%s\n' "${FAKE_SUDO_SAY-sudo: a password is required}" >&2
                 exit 1 ;;
esac
exec "$@"
FAKE

# [Co-developed with claude code -- Adam] A fake ndtwin-lab for the cases that run the real lab_session: it
# prints FAKE_LAB_STATUS for `status` and "ran:<verb>" for any other verb. LAB is pointed at it by the case, and the
# sudo above refuses every other ndtwin-lab path, so the helper installed on this machine cannot run from here.
# [Co-developed with claude code -- Adam] `host-ping <host> <ip> <count> <interval>` answers as FAKE_HP says:
#   clean    ping's summary, 0% loss, exit 0          half     some replies: the summary and exit 1, as ping
#   lost     ping's summary, total loss, exit 1                -w 6 gives when the deadline ends the run early
#   nothing  a summary with nothing sent, exit 1      pingerr  `/usr/bin/ping: connect: ...` on stderr, exit 2, no summary
#   nsenterr nsenter's failure on stderr, exit 1      pingerr1 the same ping line with exit 1, no summary
#   bashrc2  a bash error of the helper itself on stderr, exit 2
#   refuse   the helper's own refusal line on stderr, exit FAKE_HP_RC (65 unless set)
#   garbage  a line that is no summary, exit 1        oldhelper  the usage line of a helper with no such verb
cat >"$BIN/ndtwin-lab" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == host-ping ]]; then
    case "${FAKE_HP:-clean}" in
        clean)     printf '%s\n' "--- $3 ping statistics ---" "2 packets transmitted, 2 received, 0% packet loss, time 201ms"; exit 0 ;;
        half)      printf '%s\n' "--- $3 ping statistics ---" "3 packets transmitted, 1 received, 66% packet loss, time 401ms"; exit 1 ;;
        lost)      printf '%s\n' "--- $3 ping statistics ---" "30 packets transmitted, 0 received, 100% packet loss, time 6006ms"; exit 1 ;;
        pingerr)   echo "/usr/bin/ping: connect: Network is unreachable" >&2; exit 2 ;;
        pingerr1)  echo "/usr/bin/ping: connect: Network is unreachable" >&2; exit 1 ;;
        bashrc2)   echo "/usr/local/sbin/ndtwin-lab: line 1: syntax error near unexpected token" >&2; exit 2 ;;
        nsenterr)  echo "nsenter: reassociate to namespace 'ns/net' failed: Operation not permitted" >&2; exit 1 ;;
        nothing)   printf '%s\n' "--- $3 ping statistics ---" "0 packets transmitted, 0 received, 0% packet loss, time 0ms"; exit 1 ;;
        refuse)    echo "ndtwin-lab host-ping: no Mininet host $2: no process's last argument is its tag (is a topology running, and does it have $2?)" >&2
                   exit "${FAKE_HP_RC:-65}" ;;
        garbage)   echo "something nobody expected" ; exit 1 ;;
        oldhelper) echo "ndtwin-lab: usage: ndtwin-lab {topo-start|topo-cmd <text>|topo-out [n]|status|config}" >&2; exit 1 ;;
    esac
fi
[[ "${1:-}" == status ]] || { echo "ran:${1:-}"; exit 0; }
printf '%s\n' "${FAKE_LAB_STATUS:-no lab sessions}"
FAKE

cat >"$BIN/ovs-vsctl" <<'FAKE'
#!/usr/bin/env bash
# list-br prints one bridge per name in FAKE_BRIDGES. FAKE_OVSDB_DOWN makes it fail the way a
# stopped ovsdb does: non-zero, and the message is ovs-vsctl's, not sudo's.
if [[ -n "${FAKE_OVSDB_DOWN:-}" ]]; then
    echo "ovs-vsctl: unix:/var/run/openvswitch/db.sock: database connection failed" >&2
    exit 1
fi
[[ "${1:-}" == "list-br" ]] || exit 1
for b in ${FAKE_BRIDGES:-}; do echo "$b"; done
exit 0
FAKE

chmod +x "$BIN"/sudo "$BIN"/ndtwin-lab "$BIN"/ovs-vsctl
PATH="$BIN:$PATH"; export PATH

# --- helpers ---------------------------------------------------------------------------------
# Each case runs in its own subshell with ndt sourced as a library, so a stub cannot leak into
# the next case and no case can be masked by an earlier one having already returned.
in_ndt() { NDT_LIB_ONLY=1 NDT_SUDO_SURFACE="$SURFACE" bash -c "source '$NDT' >/dev/null 2>&1; $1" 2>&1; }
in_ndt_rc() { in_ndt "$1" >/dev/null 2>&1; }

# Stubs shared by the guard cases: ndt is a library here, the lab is not running, and the OVS
# daemon question is answered by the test rather than by this machine -- a case whose verdict
# depended on whether ovs-vswitchd happens to be up would be measuring the laptop.
# [Co-developed with claude code -- Adam] T_SESSION=refused is the session look whose `ndtwin-lab status`
# call failed (rc 2), as lab_session answers it.
STUBS='topo_session() { [[ "${T_SESSION:-}" == refused ]] && return 2; [[ -n "${T_SESSION:-}" ]]; }; ovs_daemon_running() { [[ -z "${T_NO_DAEMON:-}" ]]; };'

echo "the table"

# shellcheck source=/dev/null
source "$SURFACE" || { echo "  FAILED   could not source $SURFACE"; echo "Ran 1 checks, 1 failed"; exit 1; }

rows="$(ndt_sudo_rows all)"
grep -q '^ovs-vsctl|' <<<"$rows" \
    && t_ok "ovs-vsctl has a row (ovs_bridge_count, in no page of the manual)" \
    || t_bad "ovs-vsctl has a row (ovs_bridge_count, in no page of the manual)" "$rows"
# The forwarding check asks the helper, so there is no grant of its own to declare: no row for mnexec.
grep -q '^mnexec|' <<<"$rows" \
    && t_bad "mnexec has no row (ndt makes no mnexec call; the forwarding check asks the helper)" "$rows" \
    || t_ok  "mnexec has no row (ndt makes no mnexec call; the forwarding check asks the helper)"
check "the table declares exactly the two grants ndt tests: the helper and ovs-vsctl" \
      "lab ovs-vsctl" "$(cut -d'|' -f1 <<<"$rows" | paste -sd' ' -)"

bad=0
while IFS='|' read -r key probe target taught consequence; do
    [[ -z "$key" ]] && continue
    [[ -n "$probe" && "$target" == /* && -n "$taught" && -n "$consequence" ]] || bad=$((bad+1))
done <<<"$rows"
check "every row declares a probe, an absolute target, where it is taught, and the consequence" "0" "$bad"

# The rule has to be pasteable, not described: a message that says "grant ovs-vsctl" leaves the
# reader to guess the path, which is the half of the problem a table can actually remove.
has "the rule for a key is a complete sudoers line naming the absolute path" \
    "ALL=(root) NOPASSWD: /usr/bin/ovs-vsctl" "$(ndt_sudo_rule ovs-vsctl)"
has "explain() prints the sudoers line that fixes it" \
    "NOPASSWD: /usr/bin/ovs-vsctl" "$(ndt_sudo_explain ovs-vsctl)"
has "explain() prints what the refusal costs" \
    "stops with" "$(ndt_sudo_explain ovs-vsctl)"
has "the helper's row says the forwarding check cannot run without it" \
    "forwarding check at the end of \`ndt up\` and \`ndt ping\` say they could not run" "$(ndt_sudo_explain lab)"

# 🔴 Completeness, so the NEXT sudo call cannot repeat this. Every privileged command `ndt`
# names must map to a row; an unlisted one is the state this whole change exists to end.
called="$(grep -oE '(sudo -n|ndt_sudo_capture)[[:space:]]+("?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?|[A-Za-z0-9_./-]+)' "$NDT" \
          | sed -E 's/^(sudo -n|ndt_sudo_capture)[[:space:]]+//; s/^"//; s/"$//' | sort -u)"
uncovered=""
while read -r tok; do
    [[ -z "$tok" ]] && continue
    case "$tok" in
        '$LAB'|'${LAB}') key=lab ;;
        # A literal spelling of the same command (prose in a comment counts: the extractor reads
        # the whole file on purpose, a taught `sudo -n X` needs a grant as much as a run one).
        ndtwin-lab|*/ndtwin-lab) key=lab ;;
        -*)              continue ;;
        \$*)             key="UNRESOLVED-VARIABLE:$tok" ;;
        *)               key="${tok##*/}" ;;
    esac
    ndt_sudo_rows "$key" | grep -q . || uncovered="${uncovered:+$uncovered }$tok"
done <<<"$called"
check "every privileged command ndt names has a row (nothing new can go unlisted)" "" "$uncovered"

echo "a refusal is not a measurement: ovs_bridge_count"

# Assert the injection took effect before asserting anything about the response to it -- a tool
# that answers "cannot tell" against a sudo that never refused proves nothing.
inj="$(FAKE_SUDO_DENY=ovs-vsctl sudo -n ovs-vsctl list-br 2>&1)"; irc=$?
if [[ "$irc" -ne 0 ]] && grep -q 'password is required' <<<"$inj"; then
    t_ok "injection took effect: sudo really refuses ovs-vsctl (rc $irc, sudo's own wording)"
else
    t_bad "injection took effect: sudo really refuses ovs-vsctl (rc $irc, sudo's own wording)" "$inj"
fi

out="$(in_ndt "$STUBS export FAKE_SUDO_DENY=ovs-vsctl; n=\$(ovs_bridge_count); echo \"rc=\$? n=[\$n]\"")"
check "refused: ovs_bridge_count returns 2 and prints no number" "rc=2 n=[]" "$out"

# control -- the same function, grant live: it must still answer, or the case above is passed
# by a function that never looks.
out="$(in_ndt "$STUBS export FAKE_BRIDGES='s1 s2 s3'; n=\$(ovs_bridge_count); echo \"rc=\$? n=[\$n]\"")"
check "control, permitted: ovs_bridge_count returns 0 and the real count" "rc=0 n=[3]" "$out"

# The discrimination that matters, stated as the pair: three bridges, one machine, and the only
# difference is the sudoers rule. Before this change both readings were 0.
a="$(in_ndt "$STUBS export FAKE_BRIDGES='s1 s2 s3'; ovs_bridge_count")"
b="$(in_ndt "$STUBS export FAKE_BRIDGES='s1 s2 s3' FAKE_SUDO_DENY=ovs-vsctl; ovs_bridge_count")"
[[ "$a" == "3" && "$b" != "0" ]] \
    && t_ok "same three bridges: permitted reads 3, refused does NOT read 0" \
    || t_bad "same three bridges: permitted reads 3, refused does NOT read 0" "permitted=[$a] refused=[$b]"

# control -- a machine with no OVS at all is a real zero, not an unknown. Without this the fix
# would refuse every bring-up on a P4-only machine.
out="$(in_ndt "$STUBS export T_NO_DAEMON=1 FAKE_OVSDB_DOWN=1; n=\$(ovs_bridge_count); echo \"rc=\$? n=[\$n]\"")"
check "control, no ovs-vswitchd: a definite 0, answered without sudo" "rc=0 n=[0]" "$out"

echo "the guard: 'I could not tell' stops ndt up p4"

in_ndt_rc "$STUBS export T_SESSION=1 FAKE_BRIDGES='s1 s2'; guard_no_live_ovs" \
    && t_bad "a live OVS fabric stops the bring-up (unchanged)" "guard returned 0" \
    || t_ok  "a live OVS fabric stops the bring-up (unchanged)"
# [Co-developed with claude code -- Adam] control for the 5s below: a fabric the guard SAW is "measured, and dirty".
out="$(in_ndt "$STUBS export T_SESSION=1 FAKE_BRIDGES='s1 s2'; guard_no_live_ovs; echo \"rc=\$?\"")"
check "control: a live OVS fabric it saw is rc 1, not 5" "rc=1" "$(grep -o 'rc=[0-9]*' <<<"$out")"

out="$(in_ndt "$STUBS export T_SESSION=1 FAKE_SUDO_DENY=ovs-vsctl; guard_no_live_ovs; echo \"rc=\$?\"")"
# [Co-developed with claude code -- Adam] rc 5, like every refusal that never looked and touched nothing
# (2026-11-06; it was 1, the code for "measured, and dirty"). A live OVS fabric it DID see stays 1, below.
has "refused: the guard stops the bring-up, rc 5" "rc=5"              "$out"
has "refused: and says it could not tell"        "cannot tell"       "$out"
has "refused: and blames sudo, not OVS"          "the reason is sudo" "$out"
has "refused: and prints the line that fixes it" "NOPASSWD: /usr/bin/ovs-vsctl" "$out"

# [Co-developed with claude code -- Adam]
# The session look itself can fail: `ndtwin-lab status` refused (or the helper missing) is rc 2 from
# lab_session, and used to read as "no session", so the guard returned 0 and `ndt up p4` built over a
# fabric it could not check. Same shape as the OVS look above: cannot tell stops the bring-up.
inj="$(FAKE_SUDO_DENY=ndtwin-lab:status sudo -n "$BIN/ndtwin-lab" status 2>&1)"; irc=$?
if [[ "$irc" -ne 0 ]] && grep -q 'password is required' <<<"$inj"; then
    t_ok "injection took effect: sudo really refuses ndtwin-lab status (rc $irc, sudo's own wording)"
else
    t_bad "injection took effect: sudo really refuses ndtwin-lab status (rc $irc, sudo's own wording)" "$inj"
fi
inj="$(FAKE_SUDO_DENY=ndtwin-lab:status sudo -n "$BIN/ndtwin-lab" topo-stop 2>&1)"; irc=$?
[[ "$irc" -eq 0 && "$inj" == "ran:topo-stop" ]] \
    && t_ok  "injection is only for status: another verb is not refused by it" \
    || t_bad "injection is only for status: another verb is not refused by it" "[$inj] rc=$irc"

# The hint probes the table's `lab` row, which names /usr/local/sbin/ndtwin-lab. Every hint case therefore
# replaces the table with a one-row copy that names the fixture's helper, so the answer does not depend on
# whether this machine has the real one installed.
LABROW="lab|$BIN/ndtwin-lab status|$BIN/ndtwin-lab|taught-in-the-manual|consequence"
FIXT="NDT_SUDO_TABLE='$LABROW';"
out="$(in_ndt "$STUBS $FIXT export T_SESSION=refused FAKE_SUDO_DENY=ndtwin-lab:status; guard_no_live_ovs; echo \"rc=\$?\"")"
has "status call failed: the guard stops the bring-up, rc 5" "rc=5"                 "$out"
has "status call failed: and says it could not tell"        "cannot tell whether a topo session is running" "$out"
has "status call failed: and names the cause in plain words" "the 'ndtwin-lab status' call failed" "$out"
has "status call failed: and blames sudo, not the lab"      "the reason is sudo"    "$out"
has "status call failed: and prints the line that fixes it" "NOPASSWD: $BIN/ndtwin-lab" "$out"

# 🔴 The hint when the probe cannot tell either (rc 2): sudo said something ndt cannot read, or the helper is not
# installed. "The reason is sudo" and a sudoers line are not true then; the hint says what ndt_sudo_report says.
out="$(in_ndt "$STUBS $FIXT export T_SESSION=refused FAKE_SUDO_DENY=ndtwin-lab:status FAKE_SUDO_SAY='sudo: refused by the nolab shim (a lab command)'; guard_no_live_ovs; echo \"rc=\$?\"")"
has   "status call failed, probe cannot read sudo: the guard still stops"        "rc=5" "$out"
has   "status call failed, probe cannot read sudo: the hint quotes what sudo said" 'whether sudo grants the status call could not be checked: sudo answered "sudo: refused by the nolab shim (a lab command)"' "$out"
hasnt "status call failed, probe cannot read sudo: no claim that the reason is sudo" "the reason is sudo" "$out"
hasnt "status call failed, probe cannot read sudo: no sudoers line is offered"   "NOPASSWD" "$out"
NOHELP="NDT_SUDO_TABLE='lab|$BIN/no-such-helper status|$BIN/no-such-helper|taught|consequence';"
out="$(in_ndt "$STUBS $NOHELP export T_SESSION=refused; guard_no_live_ovs; echo \"rc=\$?\"")"
has   "status call failed, helper not installed: the guard still stops"          "rc=5" "$out"
has   "status call failed, helper not installed: the hint says so and names the path" "whether sudo grants the status call could not be checked on this machine (no sudo, or $BIN/no-such-helper is not installed)" "$out"
hasnt "status call failed, helper not installed: no claim that the reason is sudo" "the reason is sudo" "$out"
hasnt "status call failed, helper not installed: no sudoers line for a missing binary" "NOPASSWD" "$out"
# controls: the two answers the hint already had keep their text
out="$(in_ndt "$STUBS $FIXT export T_SESSION=refused; guard_no_live_ovs; echo \"rc=\$?\"")"
has   "control, probe says granted: the hint says the grant is permitted"        "the grant is permitted but the call did not answer" "$out"
hasnt "control, probe says granted: and does not claim a refusal"                "the reason is sudo" "$out"
# the fake itself: an ndtwin-lab outside the fixture is refused (a path that does not exist, so a broken fake runs nothing)
inj="$(sudo -n /ndt-no-such-dir/ndtwin-lab status 2>&1)"; irc=$?
if [[ "$irc" -eq 1 ]] && grep -q 'password is required' <<<"$inj"; then
    t_ok "injection took effect: the fake sudo refuses an ndtwin-lab outside the fixture"
else
    t_bad "injection took effect: the fake sudo refuses an ndtwin-lab outside the fixture" "rc=$irc $inj"
fi

# The real predicate, not the stub: a fake sudo that refuses only `ndtwin-lab status`, LAB pointed at
# the fake helper, and nothing else replaced but the question about the OVS daemon.
REAL='ovs_daemon_running() { return 1; }; LAB="'"$BIN"'/ndtwin-lab"; '"$FIXT"
out="$(in_ndt "$REAL export FAKE_SUDO_DENY=ndtwin-lab:status; topo_session; echo \"look=\$?\"; guard_no_live_ovs; echo \"rc=\$?\"")"
has "real lab_session: a refused status call is rc 2, not 'no session'" "look=2" "$out"
has "real lab_session: the guard refuses the bring-up"      "rc=5"                  "$out"
has "real lab_session: and says it could not tell"          "cannot tell whether a topo session is running" "$out"
# 🔴 controls, same real code, same fake helper, sudo allows the call: no session is a pass, a session
# with no bridges is a pass, and the answer is not "cannot tell".
out="$(in_ndt "$REAL topo_session; echo \"look=\$?\"; guard_no_live_ovs; echo \"rc=\$?\"")"
has   "control, real lab_session: no session is rc 1"         "look=1"          "$out"
has   "control, real lab_session: and the guard PASSES"       "rc=0"            "$out"
hasnt "control, real lab_session: and does not say it could not tell" "cannot tell" "$out"
out="$(in_ndt "$REAL export FAKE_LAB_STATUS='topo: 1 windows (created X)'; topo_session; echo \"look=\$?\"; guard_no_live_ovs; echo \"rc=\$?\"")"
has "control, real lab_session: a listed session is rc 0"      "look=0"          "$out"
has "control, real lab_session: no bridges under it, the guard PASSES" "rc=0"    "$out"

# What the table says the refusal costs is what ndt now does (the row used to claim an empty lab and a
# skipped stop; no path of `ndt down` skips its stop).
has   "the lab row says what ndt does now: stops before the fabric" "stops before it touches the fabric" "$(ndt_sudo_explain lab)"
hasnt "the lab row no longer claims an empty lab"      'reports an empty lab'          "$(ndt_sudo_explain lab)"
hasnt "the lab row no longer claims a skipped stop"    'skips the orderly stop'        "$(ndt_sudo_explain lab)"
has   "the lab row says down's stop and sweep are refused too"  "the missing grant refuses those too" "$(ndt_sudo_explain lab)"
# [Co-developed with claude code -- Adam] and the exit code each row's refusal answers with
has   "the lab row gives up's refusal rc 5"                 "stops before it touches the fabric (rc 5)" "$(ndt_sudo_explain lab)"
has   "the ovs-vsctl row gives up's refusal rc 5"           "running under the topo session\" (rc 5)" "$(ndt_sudo_explain ovs-vsctl)"
has   "the lab row says down keeps the record"              "ends non-zero and keeps the 'ndt up' record" "$(ndt_sudo_explain lab)"
hasnt "the lab row does not say down still runs them"  'still runs its stop and sweep'   "$(ndt_sudo_explain lab)"

# 🔴 controls. A guard that always returns 1 passes every case above and makes `ndt up p4`
# impossible; these are the cases it fails.
in_ndt_rc "$STUBS export T_SESSION=1; guard_no_live_ovs" \
    && t_ok  "control, permitted and no bridges: the guard PASSES and the bring-up proceeds" \
    || t_bad "control, permitted and no bridges: the guard PASSES and the bring-up proceeds" \
             "$(in_ndt "$STUBS export T_SESSION=1; guard_no_live_ovs")"

in_ndt_rc "$STUBS export T_NO_DAEMON=1 FAKE_OVSDB_DOWN=1 T_SESSION=1; guard_no_live_ovs" \
    && t_ok  "control, a machine with no OVS: the guard PASSES" \
    || t_bad "control, a machine with no OVS: the guard PASSES" \
             "$(in_ndt "$STUBS export T_NO_DAEMON=1 FAKE_OVSDB_DOWN=1 T_SESSION=1; guard_no_live_ovs")"

in_ndt_rc "$STUBS export FAKE_SUDO_DENY=ovs-vsctl; guard_no_live_ovs" \
    && t_ok  "control, no topo session: the guard does not ask and PASSES" \
    || t_bad "control, no topo session: the guard does not ask and PASSES" "guard returned non-zero"

echo "the other call site: a permission error is not a routing failure"

# [Co-developed with claude code -- Adam]
# dataplane_ok asks the helper's host-ping verb and reads the verdict from the OUTPUT: sudo's refusal and
# ping's no-reply are both exit 1, so the exit status cannot tell them apart. Each answer the fake helper can
# give is one cell, and the refusal is paired with controls in which the ping really ran.
# LAB points at the fake helper that sits beside the fake sudo; the fake sudo refuses any other path.
HP='LAB="'"$BIN"'/ndtwin-lab";'
hp() {   # hp VAR=value... -- dataplane_ok h1 10.0.0.2 under that fake, "rc=N why=[...]"
    local envs="$*"
    in_ndt "$HP ${envs:+export $envs;} dataplane_ok h1 10.0.0.2; echo \"rc=\$? why=[\$NDT_DATAPLANE_WHY]\""
}

# Assert the injections before the responses to them. A dataplane_ok that answers "not tested" against a sudo
# that never refused, or "forwards" against a helper that never answered, proves nothing.
inj="$(FAKE_SUDO_DENY=ndtwin-lab:host-ping sudo -n "$BIN/ndtwin-lab" host-ping h1 10.0.0.2 2 0.2 2>&1)"; irc=$?
if [[ "$irc" -eq 1 ]] && grep -q 'password is required' <<<"$inj"; then
    t_ok "injection took effect: sudo really refuses host-ping (rc $irc, sudo's own wording)"
else
    t_bad "injection took effect: sudo really refuses host-ping (rc $irc, sudo's own wording)" "$inj"
fi
inj="$(FAKE_HP=lost sudo -n "$BIN/ndtwin-lab" host-ping h1 10.0.0.2 2 0.2 2>&1)"; irc=$?
if [[ "$irc" -eq 1 ]] && grep -q '100% packet loss' <<<"$inj"; then
    t_ok "injection took effect: the fake helper answers a lost ping with rc 1, the same rc as a refusal"
else
    t_bad "injection took effect: the fake helper answers a lost ping with rc 1, the same rc as a refusal" "rc=$irc $inj"
fi
inj="$(FAKE_HP=pingerr sudo -n "$BIN/ndtwin-lab" host-ping h1 10.0.0.2 2 0.2 2>&1 >/dev/null)"; irc=$?
if [[ "$irc" -eq 2 ]] && grep -q '^/usr/bin/ping: ' <<<"$inj"; then
    t_ok "injection took effect: the fake helper answers a ping error with rc 2 and ping's line, named by its path, on stderr"
else
    t_bad "injection took effect: the fake helper answers a ping error with rc 2 and ping's line, named by its path, on stderr" "rc=$irc $inj"
fi
inj="$(FAKE_HP=half sudo -n "$BIN/ndtwin-lab" host-ping h1 10.0.0.2 2 0.2 2>&1)"; irc=$?
if [[ "$irc" -eq 1 ]] && grep -q ' 1 received' <<<"$inj"; then
    t_ok "injection took effect: the fake helper answers some replies with a summary and exit 1, as ping does"
else
    t_bad "injection took effect: the fake helper answers some replies with a summary and exit 1, as ping does" "rc=$irc $inj"
fi
inj="$(FAKE_HP=refuse FAKE_HP_RC=66 sudo -n "$BIN/ndtwin-lab" host-ping h9 10.0.0.2 2 0.2 2>&1 >/dev/null)"; irc=$?
if [[ "$irc" -eq 66 ]] && grep -q '^ndtwin-lab host-ping: no Mininet host h9' <<<"$inj"; then
    t_ok "injection took effect: the fake helper refuses in its own words, with the rc it is given"
else
    t_bad "injection took effect: the fake helper refuses in its own words, with the rc it is given" "rc=$irc $inj"
fi

check "forwards: a ping summary with no loss is 0, nothing to say" "rc=0 why=[]" "$(hp FAKE_HP=clean)"
# 🔴 control -- a reply is forwarding, and the exit status is not what says so. ping run with a deadline exits 1
# when it was cut short even though some packets were answered; a check that wanted every reply, or that read the
# exit status once a summary exists, would fail a fabric whose first packet was spent on ARP.
check "control: some replies in the summary (ping's exit 1) is still 0" "rc=0 why=[]" "$(hp FAKE_HP=half)"
check "control: a ping that really got no reply is 1 -- the outage is still said" "rc=1 why=[]" "$(hp FAKE_HP=lost)"
# A ping that ran in the host and could not send is a verdict about the data plane, as it was before the helper
# (`ping ... || return 1`): exit 2 and ping's own line. Anything that is not ping's line never becomes a 1.
check "a ping that ran and could not send (its own error, exit 2) is 1, with ping's line kept" \
      "rc=1 why=[/usr/bin/ping: connect: Network is unreachable]" "$(hp FAKE_HP=pingerr)"
# 🔴 each half of that condition alone is not enough: exit 2 with no ping line is not a verdict about the network
# (here a bash error of the helper), and neither is a ping line with another exit status.
check "control: exit 2 with no ping line (the helper's own bash error) is 2, not a verdict" \
      "rc=2 why=[host-ping answered no ping summary (exit 2): /usr/local/sbin/ndtwin-lab: line 1: syntax error near unexpected token]" \
      "$(hp FAKE_HP=bashrc2)"
check "control: a ping line with exit 1 and no summary is 2, not a verdict" \
      "rc=2 why=[host-ping answered no ping summary (exit 1): /usr/bin/ping: connect: Network is unreachable]" \
      "$(hp FAKE_HP=pingerr1)"
check "control: nsenter's failure (exit 1, no summary) is 2, not a verdict about the network" \
      "rc=2 why=[host-ping answered no ping summary (exit 1): nsenter: reassociate to namespace 'ns/net' failed: Operation not permitted]" \
      "$(hp FAKE_HP=nsenterr)"
out="$(in_ndt "$HP export FAKE_HP=pingerr; verify_dataplane h1 10.0.0.2 'the hint'; echo rc=\$?")"
has   "a ping error: verify_dataplane says not forwarding, as before" "not forwarding" "$out"
has   "a ping error: and keeps ping's own line under it"            "ping said: /usr/bin/ping: connect: Network is unreachable" "$out"
has   "a ping error: and returns 1"                                  "rc=1" "$out"
hasnt "a ping error: and is not reported as NOT tested"              "NOT tested" "$out"
# the reading arm (under a package's own program): a verdict is never failed there, but ping's line is kept
out="$(in_ndt "$HP export FAKE_HP=pingerr; verify_dataplane_reading h1 10.0.0.2 sha; echo rc=\$?")"
has   "a ping error, reading arm: said as a READING"                 "a READING" "$out"
has   "a ping error, reading arm: with ping's own line"              "ping said: /usr/bin/ping: connect: Network is unreachable" "$out"
has   "a ping error, reading arm: and returns 0"                     "rc=0" "$out"
# a total loss is a verdict about the network and carries no ping line
out="$(in_ndt "$HP export FAKE_HP=lost; verify_dataplane h1 10.0.0.2 'the hint'; echo rc=\$?")"
hasnt "total loss: no 'ping said:' line is printed"                  "ping said:" "$out"
out="$(in_ndt "$HP export FAKE_HP=lost; verify_dataplane_reading h1 10.0.0.2 sha; echo rc=\$?")"
hasnt "total loss, reading arm: no 'ping said:' line is printed"     "ping said:" "$out"
check "refused: dataplane_ok returns 2 (not tested), and says why" \
      "rc=2 why=[sudo refused the helper]" "$(hp FAKE_SUDO_DENY=ndtwin-lab:host-ping)"
# The other wording sudo has for the same refusal, and the whole helper refused rather than one verb.
check "refused (a terminal is required): still 2, the helper" \
      "rc=2 why=[sudo refused the helper]" \
      "$(hp FAKE_SUDO_DENY=ndtwin-lab "FAKE_SUDO_SAY='sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper'")"

out="$(in_ndt "$HP export FAKE_SUDO_DENY=ndtwin-lab:host-ping; verify_dataplane h1 10.0.0.2 hint; echo rc=\$?")"
has   "refused: the message says NOT tested"                "NOT tested"                   "$out"
# The claim itself is an err() line, which prints an XX marker; the row's consequence column
# quotes the old sentence, so the absence has to be asserted on the marker rather than on the
# words -- matching the words would be satisfied by the quotation and prove nothing.
hasnt "refused: no XX line claiming the host cannot be reached" "XX  data plane"           "$out"
has   "refused: returns 0 -- not tested is not a routing failure" "rc=0"                    "$out"
has   "refused: and prints the helper's sudoers line"       "NOPASSWD: /usr/local/sbin/ndtwin-lab" "$out"
hasnt "refused: and does not send the reader to mnexec"     "mnexec"                       "$out"
out="$(in_ndt "$HP export FAKE_SUDO_DENY=ndtwin-lab:host-ping; verify_dataplane_reading h1 10.0.0.2 sha; echo rc=\$?")"
has   "refused, under a package's own program: also NOT tested, with the helper's line" "NOPASSWD: /usr/local/sbin/ndtwin-lab" "$out"
hasnt "refused, under a package's own program: no 'reading' sentence about the network" "a READING" "$out"

# 🔴 control -- the true version of that sentence must survive. If a refusal and a lost ping
# were folded together in the other direction, this is the case that goes red.
out="$(in_ndt "$HP export FAKE_HP=lost; verify_dataplane h1 10.0.0.2 'the hint'; echo rc=\$?")"
has "control, permitted and the ping really fails: 'not forwarding' is still said" "not forwarding" "$out"
has "control, permitted and the ping really fails: verify_dataplane returns 1"     "rc=1"           "$out"
out="$(in_ndt "$HP export FAKE_HP=clean; verify_dataplane h1 10.0.0.2 'the hint'; echo rc=\$?")"
has "control, permitted and forwarding: verify_dataplane says so" "forwards" "$out"

# The helper's own refusals, 64 to 67: its line is what the reader gets, and the exit code alone is not read as a verdict.
for hrc in 64 65 66 67; do
    check "the helper refused (rc $hrc): 2, carrying the helper's own line" \
          "rc=2 why=[ndtwin-lab host-ping: no Mininet host h1: no process's last argument is its tag (is a topology running, and does it have h1?)]" \
          "$(hp FAKE_HP=refuse FAKE_HP_RC=$hrc)"
done
out="$(in_ndt "$HP export FAKE_HP=refuse; verify_dataplane h1 10.0.0.2 hint; echo rc=\$?")"
has   "the helper refused: the message says NOT tested and quotes the line" "forwarding NOT tested -- ndtwin-lab host-ping: no Mininet host h1" "$out"
hasnt "the helper refused: no XX line claiming the host cannot be reached" "XX  data plane" "$out"
hasnt "the helper refused: and it is not blamed on sudo"                    "NOPASSWD"        "$out"

check "garbage: an answer that is no ping summary is 2, and says what it said" \
      "rc=2 why=[host-ping answered no ping summary (exit 1): something nobody expected]" "$(hp FAKE_HP=garbage)"
check "a helper with no host-ping verb is 2, and says to reinstall it" \
      "rc=2 why=[the installed helper has no host-ping verb: reinstall it from this checkout (user guide 3.1)]" "$(hp FAKE_HP=oldhelper)"
check "a summary with nothing sent is 2, not a verdict" "rc=2 why=[ping sent nothing: no message]" "$(hp FAKE_HP=nothing)"

# 🔴 the call itself: exactly one helper verb, and no mnexec from ndt's own verify.
LOG="$UPFIX/sudo.log"; : >"$LOG"
in_ndt "$HP export FAKE_SUDO_LOG='$LOG' FAKE_HP=clean; verify_dataplane h1 10.0.0.2 hint; verify_dataplane_reading h1 10.0.0.2 sha" >/dev/null
check "verify's whole sudo footprint: one host-ping per check, and nothing else" \
      "$BIN/ndtwin-lab host-ping h1 10.0.0.2 2 0.2
$BIN/ndtwin-lab host-ping h1 10.0.0.2 2 0.2" "$(cat "$LOG")"
check "no mnexec call reached sudo" "0" "$(grep -c mnexec "$LOG")"

echo "the probe: what sudo's own words decide (ndt_sudo_probe -> the 'sudo grants' line of ndt status)"

# [Co-developed with claude code -- Adam] (2026-09-27) ndt_sudo_probe
# reads a probe that exits non-zero by its stderr: a refusal ndt_sudo_refused knows is 1; a "sudo:"
# line that is neither a known refusal nor a known non-fatal warning is 2, could not tell; no
# "sudo:" line at all is the program's own failure, 0 (granted). Until this date every wording it
# did not know was 0 -- a refusal reported as a live grant. The ovs-vsctl row is probed (its
# program is the fake here, so no case depends on what this machine has installed).
probe_rc() {   # probe_rc VAR=value... -> ndt_sudo_probe ovs-vsctl's rc, and the line it could not read
    env "$@" bash -c 'source "$1" >/dev/null 2>&1; ndt_sudo_probe ovs-vsctl >/dev/null 2>&1; echo "rc=$? unread=[$NDT_SUDO_UNREAD]"' _ "$SURFACE"
}
W_HOST="sudo: unable to resolve host lab-7: Name or service not known"
W_CORE="sudo: setrlimit(RLIMIT_CORE): Operation not permitted"
# Assert the injection before the response to it: the fake must really print what each case says.
inj="$(FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_WARN="$W_HOST" FAKE_SUDO_SAY="sudo: PAM account management error: x" sudo -n ovs-vsctl list-br 2>&1)"
[[ "$inj" == "$W_HOST"$'\n'"sudo: PAM account management error: x" ]] \
    && t_ok  "injection took effect: the fake prints the warning, then the refusal it is given" \
    || t_bad "injection took effect: the fake prints the warning, then the refusal it is given" "[$inj]"

check "probe: a refusal ndt_sudo_refused knows ('a password is required') is 1, refused" \
      "rc=1 unread=[]" "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl)"
check "probe: requiretty ('sorry, you must have a tty to run sudo') is 1, refused" \
      "rc=1 unread=[]" "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: sorry, you must have a tty to run sudo')"
check "probe: an unknown sudo: line (PAM) is 2, could not tell -- not granted" \
      "rc=2 unread=[sudo: PAM account management error: Authentication service cannot retrieve authentication info]" \
      "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: PAM account management error: Authentication service cannot retrieve authentication info')"
check "probe: secure_path's 'sudo: <cmd>: command not found' is 2, could not tell" \
      "rc=2 unread=[sudo: ovs-vsctl: command not found]" \
      "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: ovs-vsctl: command not found')"
check "probe: the gates' nolab shim wording is 2, could not tell (it was read as granted)" \
      "rc=2 unread=[sudo: refused by the nolab shim (a lab command)]" \
      "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: refused by the nolab shim (a lab command)')"
# 🔴 controls: the program's own failure is still a live grant, or a machine with sudo granted and
# ovsdb stopped would lose its green `ndt status --check` to this change.
check "control, probe: rc!=0 with no sudo: line (ovsdb down, ovs-vsctl's own words) is 0, granted" \
      "rc=0 unread=[]" "$(probe_rc FAKE_OVSDB_DOWN=1)"
check "control, probe: the grant is live and the probe succeeds -- 0" \
      "rc=0 unread=[]" "$(probe_rc FAKE_BRIDGES=s1)"
check "control, probe: a refusal that prints nothing is read as granted -- the rule's known limit" \
      "rc=0 unread=[]" "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY=)"
# the non-fatal warning list: each entry, with the program's own failure behind it, is still 0 ...
check "control, probe: warning 'unable to resolve host' + ovsdb down is 0, granted" \
      "rc=0 unread=[]" "$(probe_rc FAKE_SUDO_WARN="$W_HOST" FAKE_OVSDB_DOWN=1)"
check "control, probe: warning 'setrlimit(RLIMIT_CORE)' + ovsdb down is 0, granted" \
      "rc=0 unread=[]" "$(probe_rc FAKE_SUDO_WARN="$W_CORE" FAKE_OVSDB_DOWN=1)"
# ... and the list cannot hide a refusal standing next to it
check "probe: a warning AND an unknown sudo: refusal together is 2 -- the list hides only itself" \
      "rc=2 unread=[sudo: refused by the nolab shim (a lab command)]" \
      "$(probe_rc FAKE_SUDO_WARN="$W_HOST" FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: refused by the nolab shim (a lab command)')"
check "probe: a warning AND a known refusal is 1, refused" \
      "rc=1 unread=[]" "$(probe_rc FAKE_SUDO_WARN="$W_CORE" FAKE_SUDO_DENY=ovs-vsctl)"
# a warning entry matches from "sudo: " on, as a whole: a fatal line that shares its first words
# is not a warning
check "probe: a fatal 'sudo: unable to execute ...' is 2 -- a warning entry is matched whole, from 'sudo: '" \
      "rc=2 unread=[sudo: unable to execute /usr/bin/ovs-vsctl: Permission denied]" \
      "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: unable to execute /usr/bin/ovs-vsctl: Permission denied')"
# ... and only right after "sudo: ": a fatal line that carries an entry's words further on is not
# that warning
check "probe: a fatal sudo: line with a warning entry further on is 2 -- entries match only right after 'sudo: '" \
      "rc=2 unread=[sudo: error initializing audit plugin sudoers_audit (setrlimit(RLIMIT_CORE): Operation not permitted)]" \
      "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: error initializing audit plugin sudoers_audit (setrlimit(RLIMIT_CORE): Operation not permitted)')"
check "probe: a fatal sudo: line naming a command before a warning entry is 2 -- not matched after any ': '" \
      "rc=2 unread=[sudo: ovs-vsctl: setrlimit(RLIMIT_CORE): Operation not permitted]" \
      "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: ovs-vsctl: setrlimit(RLIMIT_CORE): Operation not permitted')"
# 🔴 KNOWN LIMIT, pinned: sudo prints only a listed warning, then refuses without a word -- nothing
# in stderr says "refused", so it reads as the program's own failure, i.e. granted.
check "control, probe: a listed warning followed by a silent refusal is read as granted -- the rule's known limit" \
      "rc=0 unread=[]" \
      "$(probe_rc FAKE_SUDO_WARN="$W_HOST" FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY=)"
# 🔴 KNOWN LIMIT, pinned: a refusal that does not start "sudo:" -- another implementation's prefix,
# e.g. sudo-rs (its exact wording is not verified here) -- is read as the program's own failure,
# i.e. granted. The rule reads sudo's own diagnostics by their prefix and nothing else.
check "control, probe: a refusal worded without a 'sudo:' prefix (sudo-rs) is read as granted -- the rule's known limit" \
      "rc=0 unread=[]" \
      "$(probe_rc FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo-rs: interactive authentication is required')"

# ndt_sudo_report -- what `ndt status` prints and returns -- over the ovs-vsctl row alone, so no
# case asks this machine's /usr/local/sbin/ndtwin-lab anything.
report_of() {   # report_of VAR=value... -> "rc=N <its line>"
    env "$@" bash -c 'source "$1" >/dev/null 2>&1; NDT_SUDO_TABLE="$(ndt_sudo_rows ovs-vsctl)"
                      out="$(ndt_sudo_report)"; echo "rc=$? $(head -1 <<<"$out")"' _ "$SURFACE"
}
check "report: an unknown sudo: line is rc 2, 'could NOT be tested', and quotes what sudo said" \
      'rc=2 sudo: ovs-vsctl  could NOT be tested: sudo answered "sudo: refused by the nolab shim (a lab command)", which ndt cannot read as granted or refused -- not a pass' \
      "$(report_of FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: refused by the nolab shim (a lab command)')"
check "control, report: a known refusal is still rc 1, REFUSED" \
      "rc=1 sudo: ovs-vsctl  REFUSED -- ovs-vsctl list-br" "$(report_of FAKE_SUDO_DENY=ovs-vsctl)"
check "control, report: ovsdb down behind a warning is still rc 0, granted" \
      "rc=0 sudo: ovs-vsctl  granted" "$(report_of FAKE_SUDO_WARN="$W_HOST" FAKE_OVSDB_DOWN=1)"
# Two rows, the way `ndt status` reports them: the first answers with a line ndt cannot read, the
# second's program is not installed. The second row must say so -- not repeat what sudo said for
# the first (the probe clears NDT_SUDO_UNREAD before its early returns).
report_two() {
    env "$@" bash -c 'source "$1" >/dev/null 2>&1
        NDT_SUDO_TABLE="$(ndt_sudo_rows ovs-vsctl)"$'"'"'\n'"'"'"nosuch|ndt-no-such-program --probe|/usr/bin/ndt-no-such-program|nowhere|nothing"
        out="$(ndt_sudo_report)"; rc=$?; printf "rc=%s | %s" "$rc" "$(paste -sd"|" <<<"$out" | sed "s/|/ | /g")"' _ "$SURFACE"
}
check "report, two rows: an unknown sudo: line, then a program that is not installed -- each row its own reason" \
      'rc=2 | sudo: ovs-vsctl  could NOT be tested: sudo answered "sudo: refused by the nolab shim (a lab command)", which ndt cannot read as granted or refused -- not a pass | sudo: nosuch     could NOT be tested on this machine (no sudo, or /usr/bin/ndt-no-such-program is not installed) -- not a pass' \
      "$(report_two FAKE_SUDO_DENY=ovs-vsctl FAKE_SUDO_SAY='sudo: refused by the nolab shim (a lab command)')"

echo "the wiring: the callers read the table rather than keeping a copy"

# up_p4 must take its verdict from guard_no_live_ovs. Everything the function reads before
# the guard is stubbed, and every path it can write (up.target, the knobs, the claim) is pointed
# at $UPFIX, so this asserts the seam and nothing else and touches no real checkout.
# [Co-developed with claude code -- Adam] sudo and sleep are stubbed as well: a bring-up that got
# past the guard (the gate's mutant does) would otherwise reach `sudo -n $LAB topo-start` through
# the pass-through fake above and run the real helper.
# [Co-developed with claude code -- Adam] lab_ntg_dir is stubbed to name no checkout: up_p4 asks
# ntg_up_refusal once it is past the guard (the gate's mutant gets there), and that would read this
# machine's lab config and its NTG checkout. With no checkout named it answers "not refused".
UP_STUBS='
REPO="$UPFIX"; CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff";
mkdir -p "$REPO/.test_run" "$REPO/p4_proxy/mininet";
sudo() { return 1; }; sleep() { :; };
host_count() { echo 4; }; topo_for_hosts() { echo /tmp/x.json; }; bmv2_binary() { echo b; };
sample_rate() { echo 1; }; rate_label() { echo r; }; foreign_claim() { :; }; in_flight() { :; };
preflight() { return 0; }; bmv2_count() { echo 0; }; fabric_host_count() { echo 0; };
topo_session() { return 1; }; stale_pipeline() { return 1; };
guard_no_live_ovs() { echo GUARD-SENTINEL; return 1; }; lab_ntg_dir() { :; };'
out="$(in_ndt "$UP_STUBS up_p4; echo rc=\$?")"
has "up_p4 asks guard_no_live_ovs"          "GUARD-SENTINEL" "$out"
has "up_p4 stops when the guard says stop"  "rc=1"           "$out"

# cmd_status --check must read the table too, or the grant a run depends on stays invisible
# until the run has already produced a number.
# port_open and curl are stubbed too: without them this case reaches out to whatever is
# listening on :8000/:8080/:8081 on the machine running the test, which makes the result depend
# on another session's stack and puts a probe on a live one.
ST_STUBS='
host_count() { echo 4; }; topo_for_hosts() { echo /tmp/x.json; }; sample_rate() { echo 1; };
rate_label() { echo r; }; bmv2_binary() { echo b; }; bmv2_count() { echo 0; };
fabric_host_count() { echo 0; }; mn_count() { echo 0; }; topo_session() { return 1; };
lab_session() { return 1; }; http_get_graph() { :; }; netem_count() { echo 0; };
app_probe() { APP_STATE=stopped; }; claim_line() { :; }; stale_pipeline() { return 1; };
port_open() { return 1; }; curl() { return 1; }; foreign_claim() { :; }; in_flight() { :; };
ndt_sudo_report() { echo "REPORT-SENTINEL"; return 1; };'
out="$(in_ndt "$ST_STUBS cmd_status --check; echo rc=\$?")"
has "cmd_status --check reads ndt_sudo_report"                    "REPORT-SENTINEL" "$out"
has "a refused grant is a --check problem, not a cosmetic line"   "sudo grant"      "$out"

echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
