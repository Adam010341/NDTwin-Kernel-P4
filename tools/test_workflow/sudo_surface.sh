#!/usr/bin/env bash
#
# sudo_surface.sh -- the root privileges `ndt` needs, declared once, in a form that is READ.
#
# [Co-developed with claude code -- Adam]
#
# Why this file exists
#
# `ndt` calls `sudo -n` in thirteen places. Eleven go through /usr/local/sbin/ndtwin-lab,
# which the manual teaches the reader to grant. The other two do not:
#
#   ovs_bridge_count   sudo -n ovs-vsctl list-br
#   dataplane_ok       sudo -n mnexec -a <pid> ping ...
#
# The website's User Manual -> NDTwin Kernel -> Operate an Emulated (Software) Network ->
# "Native-Linux Excution Environment" teaches exactly one sudoers line, for ndtwin-lab. No
# page of the Installation or User Manual mentions ovs-vsctl, mnexec, ifconfig or tc. The
# grants for those live in doc/2026-07-29_environment_gotchas.md, which is this machine's
# gotcha list and is not on the install path a new reader walks.
#
# So a reader who follows the manual exactly ends up with the one permission set that arms the
# defect: ndtwin-lab granted, so `topo-stop` and `topo-start` work and the fabric really does
# get torn down -- and ovs-vsctl refused, so the guard that was supposed to stop that teardown
# reads zero bridges and does not fire. Neither half is dangerous alone.
#
# What a refusal used to look like
#
#   ovs_bridge_count() { sudo -n ovs-vsctl list-br 2>/dev/null | grep -c . || true; }
#
# Three separate erasures of the same evidence: `2>/dev/null` drops sudo's message, the pipe
# replaces sudo's exit status with grep's, and `|| true` drops what is left. The function
# returns 0 -- the same answer as a machine with no OVS bridges -- so `ndt up p4`'s "refuse to
# run over a live OVS fabric" guard never fires and the fabric is torn down silently. The
# other call site turned the same refusal into a specific, false assertion:
# `h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding`.
#
# 🔴 How NOT to ask the question: `sudo -n -l -- <cmd>`
#
# The obvious probe is to ask sudo whether it would allow the command. It does not answer that
# question. Measured on this machine 2026-09-03, sudo 1.9.15p5:
#
#   $ sudo -n -l -- ovs-ofctl dump-flows s1   -> rc 0, prints /usr/bin/ovs-ofctl dump-flows s1
#   $ sudo -n    ovs-ofctl --version          -> rc 1, "sudo: a password is required"
#
# `-l` answers "may this user run it", and Adam's account carries a blanket `(ALL : ALL) ALL`
# alongside the narrow NOPASSWD rules, so `-l` says yes to everything -- including the commands
# that in fact need a password this script cannot supply. A probe built on it would have had
# exactly zero discriminating power on the machine it was written for, which is the same defect
# it was meant to detect, one level up.
#
# What actually discriminates -- and the one place the wording decides
#
#   rc says whether the answer came back; the wording says why it did not.
#
# `sudo -n` exits non-zero when it refuses, and the wrapped command's exit status when it runs.
# So a caller that keeps the exit status can always tell "I got an answer" from "I did not",
# without parsing anything. That half is locale-proof and sudo-version-proof, and the callers that
# need only that half -- ovs_bridge_count, dataplane_ok, sflow_query/sflow_why in ndt, and
# guard_no_live_ovs's message -- take their verdict from the exit status and use the stderr
# classifier below (ndt_sudo_refused) only to word the message ("add this sudoers line" versus
# "the command itself failed"). For them a wrong guess makes the message wrong, never the verdict.
#
# 🔴 ndt_sudo_probe is NOT one of them. [Co-developed with claude code -- Adam] (corrected
# 2026-09-27: this paragraph used to say the classifier decides nothing, anywhere.) A probe that
# exits non-zero is ambiguous -- sudo refused it, or sudo ran it and it failed (ovs-vsctl with no
# ovsdb to talk to) -- and ndt_sudo_probe resolves that BY THE WORDING: a wording
# ndt_sudo_refused knows means refused (1); a "sudo:" line it does not know, and that is not one
# of sudo's known non-fatal warnings, means could not tell (2, ndt_sudo_unread); no "sudo:" line
# at all means the program's own failure, granted (0). Its answer is
# ndt_sudo_report's row and return code, i.e. the "sudo grants" line of `ndt status` and whether
# `ndt status --check` lists a missing grant as a problem (ndt cmd_status). So there the wording IS
# the verdict. Until fix/sudo-probe-unknown-0927 (09-27) a refusal worded some other way --
# another sudo's, a PAM or requiretty refusal, a test harness's shim -- was reported as a live
# grant; it was seen: the nolab shim of the 09-27 gates ("sudo: refused by the nolab shim (a lab
# command)") made `ndt status` print "all 3 granted" (tests/shell/lib_probe_stub.sh, "WHAT THE
# STUB FIXES"). Now only a refusal that prints no "sudo:" line at all still reads as granted.
#
# Not covered here: tools/test_workflow/faults.sh keeps its own privileged surface in
# FAULTS_TC / FAULTS_KILL (bare `tc` and bare `kill`), documented in its header and in
# doc/2026-08-17_testing-manual.md. It is a second surface with the same shape and is listed in
# doc/audit/2026-09-03_night-rounds/FIX-NDT-SUDO-SURFACE.md; it is not wired to this table.
#
# Defines functions and data only -- no side effects, so sourcing it from a test is safe.

# --- the table ---------------------------------------------------------------------
#
#   key|probe|target|taught_by|consequence
#
# key          what a caller names when it wants a rule or an explanation.
# probe        a HARMLESS command with the real shape, for reporting whether the grant is
#              live. Real shape and not `--version`, because a sudoers rule may pin arguments:
#              a probe that does not look like the call it stands for can pass while the call
#              is refused.
# target       the absolute path a sudoers rule has to name. `command -v` on this machine is
#              what these were resolved from; a machine that installs the binary elsewhere
#              needs the rule to name its own path, which is why this is a column.
# taught_by    where the reader is told to grant it -- or NOWHERE, which is the finding.
# consequence  what the CALLER answers when the grant is missing. This is the column the code
#              did not have: every one of these refusals used to arrive as a plausible value.
NDT_SUDO_TABLE="$(cat <<'TABLE'
lab|/usr/local/sbin/ndtwin-lab status|/usr/local/sbin/ndtwin-lab|NDTwin User Manual > NDTwin Kernel > Operate an Emulated (Software) Network > Native-Linux Excution Environment, step 3|lab_session() reads the refusal as "no lab sessions", so `ndt status` reports an empty lab while a topology is running, and `ndt down` skips the orderly stop
ovs-vsctl|ovs-vsctl list-br|/usr/bin/ovs-vsctl|NOWHERE in the Installation or User Manual -- only doc/2026-07-29_environment_gotchas.md, which is this machine's gotcha list and not part of the install path|ovs_bridge_count() used to answer 0, which is also the answer for "there is no OVS here", so `ndt up p4`'s refusal to build over a live OVS fabric never fired and the fabric was torn down with no message
mnexec|mnexec -a 1 true|/usr/bin/mnexec|NOWHERE in the Installation or User Manual -- only doc/2026-07-29_environment_gotchas.md, as above|dataplane_ok() used to answer "does not forward", which verify_dataplane printed as `h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding`: a specific claim about the network, made from a permission error
TABLE
)"

# ndt_sudo_rows [key] -- table rows, or the one row named by key.
ndt_sudo_rows() {
    local want="${1:-}" key rest
    while IFS='|' read -r key rest; do
        [[ -z "$key" ]] && continue
        [[ -n "$want" && "$want" != all && "$want" != "$key" ]] && continue
        printf '%s|%s\n' "$key" "$rest"
    done <<<"$NDT_SUDO_TABLE"
}

# ndt_sudo_field <key> <column-number> -- one field, empty if the key is unknown.
ndt_sudo_field() {
    local row; row="$(ndt_sudo_rows "$1")"
    [[ -z "$row" ]] && return 1
    cut -d'|' -f"$2" <<<"$row"
}

# ndt_sudo_rule <key> -- the sudoers line to add, ready to paste, with the real user in it.
ndt_sudo_rule() {
    local target; target="$(ndt_sudo_field "$1" 3)" || return 1
    printf '%s ALL=(root) NOPASSWD: %s\n' "$(id -un)" "$target"
}

# --- asking the question -------------------------------------------------------------

# Stderr of the last ndt_sudo_capture. Callers word their error messages with it; ndt_sudo_probe
# also takes its granted / refused / could-not-tell verdict from it -- see "What actually
# discriminates" above.
NDT_SUDO_STDERR=""

# ndt_sudo_capture <binary> [args...] -- run it under `sudo -n`, keeping BOTH halves of the
# evidence: the command's stdout on stdout, sudo's stderr in NDT_SUDO_STDERR, and sudo's exit
# status as the return value. That exit status is the whole point -- the old call sites piped
# it into `grep -c` or `|| true` and then could not tell a refusal from an answer.
#
# LC_ALL/LANGUAGE are pinned so the classifier below sees one wording, not the operator's.
ndt_sudo_capture() {
    local errfile rc
    NDT_SUDO_STDERR=""
    errfile="$(mktemp "${TMPDIR:-/tmp}/ndt-sudo-err-XXXXXX")" || return 125
    LC_ALL=C LANGUAGE=C sudo -n "$@" 2>"$errfile"
    rc=$?
    NDT_SUDO_STDERR="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile"
    return "$rc"
}

# ndt_sudo_refused -- did the last ndt_sudo_capture fail because sudo refused, rather than
# because the command ran and failed? For most callers it only picks the WORDING of a message:
# they took their verdict from the exit status already. ndt_sudo_probe is the exception -- it
# takes its VERDICT from this answer: for that caller a refusal worded in a way missing here is
# "could not tell" when sudo says it on a "sudo:" line (ndt_sudo_unread), and a live grant only when
# it prints no such line (see "What actually discriminates" above).
#
# The first pattern is measured on this machine (sudo 1.9.15p5, 2026-09-03, `sudo -n
# ovs-ofctl --version` with no matching NOPASSWD rule -> rc 1, "sudo: a password is required").
# The rest are sudo's other refusal wordings, held here so a machine that produces one of them
# gets the same message rather than a shrug.
ndt_sudo_refused() {
    case "$NDT_SUDO_STDERR" in
        *"a password is required"*)                       return 0 ;;
        *"a terminal is required to read the password"*)  return 0 ;;
        *"no tty present and no askpass program"*)        return 0 ;;
        *"is not allowed to execute"*)                    return 0 ;;
        *"sudo: command not found"*)                      return 0 ;;
        *"you must have a tty"*)                          return 0 ;;   # requiretty (09-27)
        *) return 1 ;;
    esac
}

# [Co-developed with claude code -- Adam] (2026-09-27, fix/sudo-probe-unknown-0927)
# sudo's own NON-FATAL warnings. sudo prints these on stderr and then RUNS the command, so a
# "sudo:" line that is one of them says nothing about whether the grant is live. An explicit list,
# not a pattern (the orchestrator's ruling, 09-27): a pattern broad enough to catch the next warning
# is broad enough to swallow the next refusal.
#   unable to resolve host   the machine's own hostname is missing from /etc/hosts
#   setrlimit(RLIMIT_CORE)   containers, and hosts whose core-dump rlimit sudo may not raise
NDT_SUDO_WARNINGS=("unable to resolve host" "setrlimit(RLIMIT_CORE)")
NDT_SUDO_UNREAD=""

# ndt_sudo_unread -- did the last ndt_sudo_capture's sudo say something ON ITS OWN ACCOUNT -- a
# stderr line that starts with "sudo:" and is not one of NDT_SUDO_WARNINGS -- that
# ndt_sudo_refused does not know? Sets NDT_SUDO_UNREAD to the first such line. Examples:
# "sudo: PAM account management error: ...", "sudo: mnexec: command not found" (secure_path),
# and the gates' own nolab shim, "sudo: refused by the nolab shim (a lab command)". A command
# that ran and failed speaks in its own name ("ovs-vsctl: ... database connection failed"), not
# in sudo's, so it is not caught here.
ndt_sudo_unread() {
    local line w warn
    NDT_SUDO_UNREAD=""
    while IFS= read -r line; do
        [[ "$line" == "sudo:"* ]] || continue
        warn=0
        # anchored at "sudo: " and matched on the whole entry, so an entry cannot swallow a
        # fatal line that merely shares its words ("sudo: unable to execute ...")
        for w in "${NDT_SUDO_WARNINGS[@]}"; do
            [[ "$line" == "sudo: $w"* ]] && { warn=1; break; }
        done
        (( warn )) && continue
        NDT_SUDO_UNREAD="$line"
        return 0
    done <<<"$NDT_SUDO_STDERR"
    return 1
}

# ndt_sudo_explain <key> -- the two lines an error message owes the reader when a grant is
# missing: what it costs, and the exact line that fixes it. Printed by the caller that could
# not get its answer, next to the refusal itself.
ndt_sudo_explain() {
    local key="$1" taught consequence
    taught="$(ndt_sudo_field "$key" 4)" || { printf '   (no sudo_surface.sh row for %s)\n' "$key"; return 1; }
    consequence="$(ndt_sudo_field "$key" 5)"
    printf '   without it: %s\n' "$consequence"
    printf '   grant it:   %s\n' "$(ndt_sudo_rule "$key")"
    printf '   taught in:  %s\n' "$taught"
}

# ndt_sudo_probe <key> -- run this row's harmless probe.
#   0 the grant is live
#   1 sudo refused it
#   2 could not tell: no sudo, the program is not installed on this machine, or sudo said
#     something on its own account that ndt_sudo_refused cannot read (NDT_SUDO_UNREAD holds it)
# [Co-developed with claude code -- Adam] (2026-09-27, fix/sudo-probe-unknown-0927) A probe that
# exits non-zero is ambiguous -- sudo refused, or sudo ran it and it failed (ovs-vsctl with no ovsdb
# to talk to) -- and until this date every wording ndt_sudo_refused did not know was read as the
# second, i.e. as GRANTED: requiretty, PAM, secure_path's "command not found", and the gates'
# nolab shim all made `ndt status` print a live grant. Now a "sudo:" line that is neither a
# known refusal nor a known warning is "could not tell" (2). What is still read as granted: a
# non-zero exit with no "sudo:" line at all -- the program's own failure, and equally a refusal
# that prints nothing (a silent shim); from stderr the two cannot be told apart.
ndt_sudo_probe() {
    local key="$1" probe bin
    NDT_SUDO_UNREAD=""
    probe="$(ndt_sudo_field "$key" 2)" || return 2
    bin="${probe%% *}"
    command -v sudo >/dev/null 2>&1 || return 2
    command -v "$bin" >/dev/null 2>&1 || return 2
    # shellcheck disable=SC2086
    ndt_sudo_capture $probe >/dev/null && return 0
    ndt_sudo_refused && return 1
    ndt_sudo_unread && return 2
    # The command ran and failed on its own account -- the grant is live. (Or sudo refused and said
    # so on no "sudo:" line at all -- a silent refusal: from here the two cannot be told apart.)
    return 0
}

# ndt_sudo_report -- one line per row, and the explanation for every refusal.
# Returns 0 when every grant is live, 1 when any is refused, 2 when any could not be tested.
# "Could not be tested" is a third state on purpose: it is what the caller must not fold into
# "fine", for the same reason ovs_bridge_count must not fold a refusal into 0.
ndt_sudo_report() {
    local key rest rc=0 blind=0
    while IFS='|' read -r key rest; do
        [[ -z "$key" ]] && continue
        ndt_sudo_probe "$key"
        case $? in
            0) printf 'sudo: %-10s granted\n' "$key" ;;
            1) rc=1
               printf 'sudo: %-10s REFUSED -- %s\n' "$key" "$(ndt_sudo_field "$key" 2)"
               ndt_sudo_explain "$key" ;;
            *) blind=1
               if [[ -n "$NDT_SUDO_UNREAD" ]]; then
                   printf 'sudo: %-10s could NOT be tested: sudo answered "%s", which ndt cannot read as granted or refused -- not a pass\n' \
                          "$key" "$NDT_SUDO_UNREAD"
               else
                   printf 'sudo: %-10s could NOT be tested on this machine (no sudo, or %s is not installed) -- not a pass\n' \
                          "$key" "$(ndt_sudo_field "$key" 3)"
               fi ;;
        esac
    done < <(ndt_sudo_rows all)
    (( rc == 1 )) && return 1
    (( blind == 1 )) && return 2
    return 0
}
