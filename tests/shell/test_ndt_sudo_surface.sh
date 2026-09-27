#!/usr/bin/env bash
#
# Tests for tools/test_workflow/sudo_surface.sh and the two `ndt` call sites that read it.
#
# [Co-developed with claude code -- Adam]
#
# The defect: `ndt` calls `sudo -n` in thirteen places; eleven go through ndtwin-lab, which the
# manual teaches the reader to grant, and two -- `ovs-vsctl list-br` and `mnexec` -- are in no
# page of the Installation or User Manual. A refusal of either arrived as a plausible value:
#
#   ovs_bridge_count()  answered 0, which is also "there is no OVS here", so `ndt up p4`'s
#                       refusal to build over a live OVS fabric never fired.
#   dataplane_ok()      answered "does not forward", printed as the specific and false
#                       `h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding`.
#
# 🔴 Both directions are tested. A version that answers "cannot tell" to everything would
# satisfy every refusal case below and make `ndt up p4` impossible to run, so each refusal case
# is paired with a control in which the grant IS live and the old answer must still come back.
# The cases marked "control" are the ones a refuse-everything implementation fails.
#
# No lab contact, no real sudo. A fake `sudo` on PATH reproduces the refusal verbatim as
# measured from sudo 1.9.15p5 on 2026-09-03 (`sudo -n ovs-ofctl --version` with no matching
# NOPASSWD rule: rc 1, "sudo: a password is required"), and fake ovs-vsctl / mnexec / ping
# stand in for the privileged commands. Nothing here starts a topology, binds a port, or
# touches a claim -- another session may be measuring.
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
trap 'rm -rf "$BIN"' EXIT

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
[[ -n "${FAKE_SUDO_WARN:-}" ]] && printf '%s\n' "$FAKE_SUDO_WARN" >&2
case " ${FAKE_SUDO_DENY:-} " in
    *" $base "*) [[ -n "${FAKE_SUDO_SAY-x}" ]] && printf '%s\n' "${FAKE_SUDO_SAY-sudo: a password is required}" >&2
                 exit 1 ;;
esac
exec "$@"
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

cat >"$BIN/mnexec" <<'FAKE'
#!/usr/bin/env bash
# mnexec -a <pid> <command...>
shift 2
exec "$@"
FAKE

cat >"$BIN/ping" <<'FAKE'
#!/usr/bin/env bash
exit "${FAKE_PING_RC:-0}"
FAKE

chmod +x "$BIN"/sudo "$BIN"/ovs-vsctl "$BIN"/mnexec "$BIN"/ping
PATH="$BIN:$PATH"; export PATH

# --- helpers ---------------------------------------------------------------------------------
# Each case runs in its own subshell with ndt sourced as a library, so a stub cannot leak into
# the next case and no case can be masked by an earlier one having already returned.
in_ndt() { NDT_LIB_ONLY=1 NDT_SUDO_SURFACE="$SURFACE" bash -c "source '$NDT' >/dev/null 2>&1; $1" 2>&1; }
in_ndt_rc() { in_ndt "$1" >/dev/null 2>&1; }

# Stubs shared by the guard cases: ndt is a library here, the lab is not running, and the OVS
# daemon question is answered by the test rather than by this machine -- a case whose verdict
# depended on whether ovs-vswitchd happens to be up would be measuring the laptop.
STUBS='topo_session() { [[ -n "${T_SESSION:-}" ]]; }; ovs_daemon_running() { [[ -z "${T_NO_DAEMON:-}" ]]; };'

echo "the table"

# shellcheck source=/dev/null
source "$SURFACE" || { echo "  FAILED   could not source $SURFACE"; echo "Ran 1 checks, 1 failed"; exit 1; }

rows="$(ndt_sudo_rows all)"
grep -q '^ovs-vsctl|' <<<"$rows" \
    && t_ok "ovs-vsctl has a row (ovs_bridge_count, in no page of the manual)" \
    || t_bad "ovs-vsctl has a row (ovs_bridge_count, in no page of the manual)" "$rows"
grep -q '^mnexec|' <<<"$rows" \
    && t_ok "mnexec has a row (dataplane_ok, in no page of the manual)" \
    || t_bad "mnexec has a row (dataplane_ok, in no page of the manual)" "$rows"

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
    "NOPASSWD: /usr/bin/mnexec" "$(ndt_sudo_explain mnexec)"
has "explain() prints what the refusal costs" \
    "not forwarding" "$(ndt_sudo_explain mnexec)"

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

out="$(in_ndt "$STUBS export T_SESSION=1 FAKE_SUDO_DENY=ovs-vsctl; guard_no_live_ovs; echo \"rc=\$?\"")"
has "refused: the guard stops the bring-up"      "rc=1"              "$out"
has "refused: and says it could not tell"        "cannot tell"       "$out"
has "refused: and blames sudo, not OVS"          "the reason is sudo" "$out"
has "refused: and prints the line that fixes it" "NOPASSWD: /usr/bin/ovs-vsctl" "$out"

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

DP='host_pid() { echo 4242; };'
out="$(in_ndt "$DP export FAKE_SUDO_DENY=mnexec; dataplane_ok h1 10.0.0.2; echo \"rc=\$? why=[\$NDT_DATAPLANE_WHY]\"")"
check "refused: dataplane_ok returns 2 (not tested), and says why" \
      "rc=2 why=[sudo refused mnexec]" "$out"

out="$(in_ndt "$DP export FAKE_SUDO_DENY=mnexec; verify_dataplane h1 10.0.0.2 hint; echo rc=\$?")"
has   "refused: the message says NOT tested"                "NOT tested"                   "$out"
# The claim itself is an err() line, which prints an XX marker; the row's consequence column
# quotes the old sentence, so the absence has to be asserted on the marker rather than on the
# words -- matching the words would be satisfied by the quotation and prove nothing.
hasnt "refused: no XX line claiming the host cannot be reached" "XX  data plane"           "$out"
has   "refused: returns 0 -- not tested is not a routing failure" "rc=0"                    "$out"
has   "refused: and prints the mnexec sudoers line"         "NOPASSWD: /usr/bin/mnexec"    "$out"

# 🔴 control -- the true version of that sentence must survive. If a refusal and a lost ping
# were folded together in the other direction, this is the case that goes red.
out="$(in_ndt "$DP export FAKE_PING_RC=1; verify_dataplane h1 10.0.0.2 'the hint'; echo rc=\$?")"
has "control, permitted and the ping really fails: 'not forwarding' is still said" "not forwarding" "$out"
has "control, permitted and the ping really fails: verify_dataplane returns 1"     "rc=1"           "$out"

out="$(in_ndt "$DP export FAKE_PING_RC=0; dataplane_ok h1 10.0.0.2; echo rc=\$?")"
check "control, permitted and forwarding: dataplane_ok returns 0" "rc=0" "$out"

out="$(in_ndt "host_pid() { return 1; }; dataplane_ok h1 10.0.0.2; echo \"rc=\$? why=[\$NDT_DATAPLANE_WHY]\"")"
check "no namespace is still its own reason, not folded into the sudo one" \
      "rc=2 why=[no namespace for h1]" "$out"

echo "the probe: what sudo's own words decide (ndt_sudo_probe -> the 'sudo grants' line of ndt status)"

# [Co-developed with claude code -- Adam] (2026-09-27, fix/sudo-probe-unknown-0927) ndt_sudo_probe
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

# up_p4 must take its verdict from guard_no_live_ovs. Everything the function touches before
# the guard is stubbed, so this asserts the seam and nothing else.
UP_STUBS='
host_count() { echo 4; }; topo_for_hosts() { echo /tmp/x.json; }; bmv2_binary() { echo b; };
sample_rate() { echo 1; }; rate_label() { echo r; }; foreign_claim() { :; }; in_flight() { :; };
preflight() { return 0; }; bmv2_count() { echo 0; }; fabric_host_count() { echo 0; };
topo_session() { return 1; }; stale_pipeline() { return 1; };
guard_no_live_ovs() { echo GUARD-SENTINEL; return 1; };'
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
