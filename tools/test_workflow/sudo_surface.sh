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
#   ndt:1177   sudo -n ovs-vsctl list-br            (ovs_bridge_count)
#   ndt:1206   sudo -n mnexec -a <pid> ping ...     (dataplane_ok)
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
# What actually discriminates
#
#   rc decides, the message only explains.
#
# `sudo -n` exits non-zero when it refuses, and the wrapped command's exit status when it runs.
# So a caller that keeps the exit status can always tell "I got an answer" from "I did not",
# without parsing anything. That verdict is locale-proof and sudo-version-proof.
#
# The stderr classifier below exists only to word the error message ("add this sudoers line"
# versus "the command itself failed"). If it ever guesses wrong the message is wrong; the
# decision is not, because the decision was already taken from the exit status.
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

# Stderr of the last ndt_sudo_capture, for wording an error message. Never for a verdict.
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
# because the command ran and failed? Advisory: this picks the WORDING of a message. Callers
# take their verdict from the exit status, so a wrong guess here cannot produce a wrong answer.
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
        *) return 1 ;;
    esac
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
#   2 could not tell (no sudo, or the program is not installed on this machine)
ndt_sudo_probe() {
    local key="$1" probe bin
    probe="$(ndt_sudo_field "$key" 2)" || return 2
    bin="${probe%% *}"
    command -v sudo >/dev/null 2>&1 || return 2
    command -v "$bin" >/dev/null 2>&1 || return 2
    # shellcheck disable=SC2086
    ndt_sudo_capture $probe >/dev/null && return 0
    ndt_sudo_refused && return 1
    # The command ran and failed on its own account -- the grant is live.
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
               printf 'sudo: %-10s could NOT be tested on this machine (no sudo, or %s is not installed) -- not a pass\n' \
                      "$key" "$(ndt_sudo_field "$key" 3)" ;;
        esac
    done < <(ndt_sudo_rows all)
    (( rc == 1 )) && return 1
    (( blind == 1 )) && return 2
    return 0
}
