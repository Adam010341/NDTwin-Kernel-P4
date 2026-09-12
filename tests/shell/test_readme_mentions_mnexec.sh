#!/usr/bin/env bash
#
# Every `taught_by=NOWHERE` row of the sudo surface has a paragraph in
# tools/test_workflow/README.md, and this is what says so.
#
# [Co-developed with claude code -- Adam]
#
# WHAT IT GATES. tools/test_workflow/sudo_surface.sh declares the root privileges `ndt` needs,
# and its `taught_by` column says where a reader is told to grant each one -- or `NOWHERE`,
# which is the finding that table exists to carry. A grant no manual teaches is missing on every
# machine installed from the manual, and its absence arrives at the caller as a plausible value
# rather than as an error (that is the `consequence` column). The README is then the only place
# a reader can be told, so this file requires it to carry one paragraph per NOWHERE row.
#
# 🔴 AND NOTHING WOULD HAVE GONE RED IF SOMEBODY DELETED IT. That is the whole reason this file
# exists (WAKEUP-S8-DRAFT A-7, DECISIONS-0912-NIGHT N5-5; Adam's form-2 Q7: 加 mnexec 文件格).
# A paragraph no test reads is a paragraph that survives until the next person tidies the file.
#
# 🔴 THE NEEDLES COME OUT OF THE TABLE, NOT OUT OF THE README. For each key this takes the
# binary and the first two words of the table's own probe and requires the README to carry them.
# Quoting a sentence of the README's own prose instead would make this gate a copy of the
# paragraph -- it would go green on a paragraph that had been reworded into meaning nothing, and
# red on a rewrite that improved it.
#
# 🔴 2026-09-12 (FIX-NDT-10 item 3, from CELLS-2-SUMMARY §7-6): this gate used to name `mnexec`
# and only `mnexec`, and it said so out loud -- `ovs-vsctl`, the other NOWHERE row, was excluded
# because the README did not mention it at all (`grep -c ovs-vsctl` was 0 that morning) and a
# gate that is red on delivery gets edited rather than obeyed. The README now has that paragraph,
# so the gate reads the WHOLE column: a third NOWHERE row added tomorrow is red here until
# somebody writes about it, which is the property "mnexec has a test" never had.
#
# WHAT IT DOES NOT GATE, said out loud because a reader could take this file for more than it is:
#   * whether the sudoers rule is actually granted on this machine. That is what
#     `ndt_sudo_probe` answers, live, and it is not a documentation question.
#   * whether the paragraph is any good. It requires the key and the probe's argument form to
#     appear; it cannot require them to have been explained.
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

# --- the premise: which rows the manual leaves to this README ------------------------------------
# Read from the table every time rather than listed here, so a row that changes side -- a manual
# that starts teaching `ovs-vsctl`, a new grant that nothing teaches -- moves this gate with it.
NOWHERE_KEYS=()
TAUGHT_KEYS=()
while IFS='|' read -r key probe target taught rest; do
    [[ -n "$key" ]] || continue
    case "$taught" in
        NOWHERE*) NOWHERE_KEYS+=("$key") ;;
        *)        TAUGHT_KEYS+=("$key") ;;
    esac
done < <(ndt_sudo_rows all)

(( ${#NOWHERE_KEYS[@]} > 0 ))
check "sudo_surface still has NOWHERE rows" $? "keys: ${NOWHERE_KEYS[*]:-none}"
# 🔴 The filter has to be able to say no, or "every NOWHERE row is documented" is a sentence
# about the empty set -- and about every set. `lab` is taught by the User Manual, by name and by
# step number, and it must NOT be in the list above.
if (( ${#TAUGHT_KEYS[@]} > 0 )); then
    check "and rows the manual DOES teach are excluded" 0 "keys: ${TAUGHT_KEYS[*]}"
else
    check "and rows the manual DOES teach are excluded" 1 \
          "every row came back NOWHERE -- the taught_by filter is not discriminating, so the checks below are worthless"
fi

# --- the check itself, once per NOWHERE row ------------------------------------------------------
for KEY in "${NOWHERE_KEYS[@]}"; do
    PROBE="$(ndt_sudo_field "$KEY" 2 2>/dev/null || true)"
    [[ -n "$PROBE" ]]
    check "$KEY: the table declares a probe" $? "[$PROBE]"
    # The binary, by the name the table calls it.
    mentions "$KEY"; check "$KEY: README mentions it" $? "the key from the table"
    # The argument form, the first two words of the table's own probe (`mnexec -a 1 true` ->
    # `mnexec -a`; `ovs-vsctl list-br` -> itself). This is what makes `mnexec` root -- -a joins
    # another process's namespaces -- and what makes `ovs-vsctl`'s refusal look like a count. A
    # README that names the binary without the shape has not said what the grant is.
    ARGFORM="$(awk '{print $1, $2}' <<<"$PROBE")"
    mentions "$ARGFORM"
    check "$KEY: README carries the probe's argument form" $? "[$ARGFORM], from the probe column"
done

# And the file the reader is sent to for the rule, so the README's paragraphs and the table
# cannot drift into describing different privileges.
mentions "sudo_surface.sh"; check "README names the surface it is about" $? "tools/test_workflow/sudo_surface.sh"

# --- 🔴 the control: this gate can go red -------------------------------------------------------
# Every check above is a grep for something that IS there, and a grep that matches everything
# would pass all of them. So the same function is asked for a needle built the same way out of a
# key that is not in the README, and it must say no. Without this, a `mentions()` that had been
# broken into always returning 0 would read as a fully green gate.
if mentions "mnexec-NOT-A-REAL-KEY-$$"; then
    check "the control: a needle that is not there is reported missing" 1 \
          "mentions() matched a string that cannot be in the README -- every ok above is worthless"
else
    check "the control: a needle that is not there is reported missing" 0 "mentions() can say no"
fi

# 🔴 The summary is the last `echo "..."` in this file, and it has to be: group C of
# tests/shell/test_l1_shell_scoring.sh reads the corpus's SOURCE and takes each suite's last
# quoted echo as its green-path summary line. Prose above it is printf for that reason.
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
