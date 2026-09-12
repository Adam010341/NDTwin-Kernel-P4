#!/usr/bin/env bash
#
# The A12 section of tools/test_workflow/README.md has a test.
#
# [Co-developed with claude code -- Adam]
#
# WHAT IT GATES. tools/test_workflow/sudo_surface.sh declares three privileges `ndt` needs. Two of
# them -- `ovs-vsctl` and `mnexec` -- have `NOWHERE in the Installation or User Manual` in their
# `taught_by` column, which is the finding that table exists to carry. `mnexec` is the one that
# matters most: `sudo -n mnexec -a <pid> <anything>` runs that anything inside a namespace as
# root, so the allowlist beside it is a convenience and not a boundary, and ROLE-8 used exactly
# that on 2026-09-11. FIX-NDT-5 wrote that up in README.md's "sudo 面" section.
#
# 🔴 AND NOTHING WOULD HAVE GONE RED IF SOMEBODY DELETED IT. That is the whole reason this file
# exists (WAKEUP-S8-DRAFT A-7, DECISIONS-0912-NIGHT N5-5; Adam's form-2 Q7: 加 mnexec 文件格).
# A paragraph no test reads is a paragraph that survives until the next person tidies the file.
#
# 🔴 THE NEEDLE COMES OUT OF THE TABLE, NOT OUT OF THE README. `ndt_sudo_field mnexec 2` is the
# probe the surface declares; this file takes the binary and its argument form from there and
# requires the README to carry them. Quoting a sentence of the README's own prose instead would
# make this gate a copy of the paragraph -- it would go green on a paragraph that had been
# reworded into meaning nothing, and it would go red on a rewrite that improved it.
#
# WHAT IT DOES NOT GATE, said out loud because a reader could take this file for more than it is:
#   * `ovs-vsctl`, the OTHER key whose taught_by says NOWHERE, is NOT required here -- and
#     tools/test_workflow/README.md does not mention it at all (measured 2026-09-12: `grep -c
#     ovs-vsctl` is 0). Requiring it would make this gate red on delivery over a paragraph
#     nobody has written yet. It is in CELLS-2-SUMMARY §7 for Adam.
#   * whether the sudoers rule is actually granted on this machine. That is what
#     `ndt_sudo_probe` answers, live, and it is not a documentation question.
#
# No lab, no build, no network, no sudo: this reads two files.
#
# Run:  bash tests/shell/test_readme_mentions_mnexec.sh
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SURFACE="$REPO/tools/test_workflow/sudo_surface.sh"
README="$REPO/tools/test_workflow/README.md"

PASS=0
FAIL=0
check() {   # <name> <ok?0/1> <detail>
    if (( $2 == 0 )); then PASS=$((PASS+1)); printf '  ok       %-52s %s\n' "$1" "${3:-}"
    else FAIL=$((FAIL+1)); printf '  FAILED   %-52s %s\n' "$1" "${3:-}"; fi
}

for f in "$SURFACE" "$README"; do
    [[ -r "$f" ]] || { echo "  FAILED   no such file: $f"; echo "Ran 1 checks, 1 failed"; exit 1; }
done
# shellcheck source=/dev/null
if ! source "$SURFACE" >/dev/null 2>&1 || ! declare -F ndt_sudo_field >/dev/null; then
    echo "  FAILED   sudo_surface.sh does not define ndt_sudo_field -- there is no table to read"
    echo "Ran 1 checks, 1 failed"
    exit 1
fi

# mentions <needle> -- 0 when README carries it. Fixed string, never a regex: the needles are
# command lines and they contain `-`, `/` and `.`.
mentions() { grep -qF -- "$1" "$README"; }

# --- the premise: the table still says what this gate was written about -------------------------
# A gate whose subject left the table would otherwise pass forever over a README that no longer
# has to say anything.
KEY=mnexec
PROBE="$(ndt_sudo_field "$KEY" 2 2>/dev/null || true)"
TARGET="$(ndt_sudo_field "$KEY" 3 2>/dev/null || true)"
TAUGHT="$(ndt_sudo_field "$KEY" 4 2>/dev/null || true)"
[[ -n "$PROBE" ]]; check "sudo_surface declares a $KEY row" $? "probe [$PROBE] target [$TARGET]"
case "$TAUGHT" in
    NOWHERE*) check "and its taught_by still says NOWHERE" 0 "so the README is where a reader is told" ;;
    *)        check "and its taught_by still says NOWHERE" 1 "taught_by is now [$TAUGHT] -- if the manual teaches it, this gate is about the wrong file" ;;
esac

# --- the check itself ---------------------------------------------------------------------------
# The binary, by the name the table calls it.
mentions "$KEY"; check "README mentions $KEY" $? "the key from the table"
# The argument form, the first two words of the table's own probe (`mnexec -a 1 true` -> `mnexec
# -a`). This is what makes it root: -a joins another process's namespaces, and a README that names
# the binary without that shape has not said what the grant is.
ARGFORM="$(awk '{print $1, $2}' <<<"$PROBE")"
mentions "$ARGFORM"; check "README carries the probe's argument form" $? "[$ARGFORM], from the table's probe column"
# And the file the reader is sent to for the rule, so the README's paragraph and the table cannot
# drift into describing different privileges.
mentions "sudo_surface.sh"; check "README names the surface it is about" $? "tools/test_workflow/sudo_surface.sh"

# --- 🔴 the control: this gate can go red -------------------------------------------------------
# Every check above is a grep for something that IS there, and a grep that matches everything
# would pass all three. So the same function is asked for a needle built the same way out of a key
# that is not in the README, and it must say no. Without this, a `mentions()` that had been
# broken into always returning 0 would read as a fully green gate.
if mentions "$KEY-NOT-A-REAL-KEY-$$"; then
    check "the control: a needle that is not there is reported missing" 1 \
          "mentions() matched a string that cannot be in the README -- every ok above is worthless"
else
    check "the control: a needle that is not there is reported missing" 0 "mentions() can say no"
fi

printf '\nNOT CHECKED HERE: ovs-vsctl, the other row whose taught_by says NOWHERE. README does not\n'
printf '                  mention it (measured 2026-09-12). Requiring it would make this gate red\n'
printf '                  on delivery; it is written up in CELLS-2-SUMMARY.md section 7.\n\n'
# 🔴 The summary is the last `echo "..."` in this file, and it has to be: group C of
# tests/shell/test_l1_shell_scoring.sh reads the corpus's SOURCE and takes each suite's last
# quoted echo as its green-path summary line. The note above was an `echo` in the first draft and
# this suite became that gate's thirteenth failure -- a new one, on the day it landed, which is
# exactly the defect group C exists to catch. printf for the prose, echo for the summary.
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
