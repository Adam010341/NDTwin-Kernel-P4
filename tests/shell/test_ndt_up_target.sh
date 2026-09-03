#!/usr/bin/env bash
#
# What `ndt up`'s arguments mean. Adam changed the default data plane from P4 to OVS on
# 2026-09-03; this file is what says so in a form that fails when it stops being true.
#
# The subject is resolve_up_target, reached through ndt's source seam (ndt:2141 returns early
# when sourced). No fabric is built and no lab is touched: the function decides which builder
# to call, and that decision is the whole thing under test.
#
# 🔴 Half of these checks exist for the OPPOSITE failure. A resolver that answered
# "up_ovs 128" to everything would satisfy every "the default is OVS" check while destroying
# `ndt up p4 4`; a resolver that refused everything would satisfy every "a bad size is
# refused" check while making the lab unstartable. Both are pinned below.
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; exit 2; }

# shellcheck disable=SC1090
source "$NDT" >/dev/null 2>&1
if ! declare -F resolve_up_target >/dev/null; then
    echo "resolve_up_target is not defined after sourcing $NDT"; exit 2
fi

checks=0; failed=0
section() { printf '\n%s\n' "$1"; }
t_eq() {   # label, expected, actual
    checks=$((checks+1))
    if [[ "$2" == "$3" ]]; then printf '  ok       %s\n' "$1"
    else failed=$((failed+1)); printf '  FAILED   %s\n             expected: %s\n             actual:   %s\n' "$1" "$2" "$3"; fi
}
plan() { resolve_up_target "${1:-}" "${2:-}" 2>/dev/null; }
rc_of() { resolve_up_target "${1:-}" "${2:-}" >/dev/null 2>&1; echo $?; }

section "the default plane is OVS"
t_eq "a bare 'ndt up' is OVS, not P4"            "up_ovs 128" "$(plan)"
t_eq "and it is the 128-host fabric"             "up_ovs 128" "$(plan '' '')"
t_eq "'ndt up ovs' is the same thing"            "up_ovs 128" "$(plan ovs)"
t_eq "'ndt up ovs4' is the 4-host layout"        "up_ovs 4"   "$(plan ovs4)"

section "a bare number follows the default plane -- it is a size, not a plane"
t_eq "'ndt up 4' is OVS at 4 (it used to be P4)" "up_ovs 4"   "$(plan 4)"
t_eq "'ndt up 128' is OVS at 128"                "up_ovs 128" "$(plan 128)"
t_eq "🔴 a size OVS cannot build is refused"     "2"          "$(rc_of 16)"
t_eq "and refusing means printing nothing"       ""           "$(plan 16)"
t_eq "0 is refused too, not read as a fabric"    "2"          "$(rc_of 0)"

section "🔴 P4 is still reachable -- a resolver that always said OVS would pass everything above"
t_eq "'ndt up p4' keeps the current host count"  "up_p4 "     "$(plan p4)"
t_eq "'ndt up p4 4' is P4 at 4"                  "up_p4 4"    "$(plan p4 4)"
t_eq "'ndt up p4 128' is P4 at 128"              "up_p4 128"  "$(plan p4 128)"
t_eq "'ndt up p4 16' is allowed -- P4 takes any size" "up_p4 16" "$(plan p4 16)"
t_eq "P4 is rc 0, not a refusal"                 "0"          "$(rc_of p4 4)"

section "🔴 and it does not refuse everything -- the checks above would pass if it did"
t_eq "a bare 'ndt up' is rc 0"                   "0"          "$(rc_of)"
t_eq "'ndt up ovs4' is rc 0"                     "0"          "$(rc_of ovs4)"
t_eq "'ndt up 4' is rc 0"                        "0"          "$(rc_of 4)"

section "nonsense is refused, and is not silently a plane"
t_eq "a word that is not a plane is rc 2"        "2"          "$(rc_of nonsense)"
t_eq "'ovs8' is not quietly ovs"                 "2"          "$(rc_of ovs8)"
t_eq "an empty second word does not break p4"    "up_p4 "     "$(plan p4 '')"

section "🔴 the usage text must not EXECUTE anything"
# This cost a real fabric. `cat <<EOF` is an UNQUOTED heredoc, so a backtick inside the usage
# text is command substitution, not punctuation. Three of them were added here on 2026-09-03 to
# write `ndt up` in the help; running `ndt` with no arguments then invoked ~/.local/bin/ndt --
# a symlink to this very script -- which brought up a fabric and left it orphaned under
# systemd --user when the caller's timeout killed the parent. Bare `ndt` went from 12 ms to a
# hang, and the only visible symptom was no output at all, because the substitution swallowed it.
usage_body="$(awk '/^        cat <<EOF$/,/^EOF$/' "$NDT")"
t_eq "no backtick in the usage heredoc"          "0" "$(grep -c '`' <<<"$usage_body")"
t_eq "no \$( ) in the usage heredoc"             "0" "$(grep -c '[$][(]' <<<"$usage_body")"
t_eq "the usage heredoc was actually found"      "1" "$([[ $(wc -l <<<"$usage_body") -gt 10 ]] && echo 1 || echo 0)"

printf '\nRan %d checks, %d failed\n' "$checks" "$failed"
[[ $failed -eq 0 ]]
