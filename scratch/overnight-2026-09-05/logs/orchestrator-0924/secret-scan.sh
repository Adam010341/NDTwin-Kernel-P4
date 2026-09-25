#!/usr/bin/env bash
# secret-scan.sh -- scan the ADDED lines of a git range for credential shapes, with a positive control.
# Usage: secret-scan.sh <git-dir> <range>      e.g.  secret-scan.sh "$AR" 1872be70..HEAD
# Exit 0 = range clean AND the control hit exactly 3; anything else is non-zero.
# [Co-developed with claude code -- Adam]
set -u
GD="$1"; RANGE="$2"
PAT='-----BEGIN [A-Z ]*PRIVATE KEY-----|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|sk-(ant-)?[A-Za-z0-9_-]{24,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|(api[_-]?key|secret|token|passw(or)?d)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"' ]{8,}["'"'"']'

# Positive control: three synthetic credentials APPENDED TO THE SAME STREAM that is scanned, so a
# failure of the stream itself (an option-parsed pattern, grep's binary-file suppression) also
# silences the control. Built at run time so this file never contains a matching literal.
C1="ghp_$(printf 'x%.0s' {1..36})"; C2="sk-ant-$(printf 'Q%.0s' {1..40})"; C3="AKIA$(printf 'Z%.0s' {1..16})"
all=$( { git -C "$GD" diff "$RANGE" --no-color -U0 --text; printf '+%s\n+%s\n+%s\n' "$C1" "$C2" "$C3"; } \
       | grep -a -E '^\+' | grep -a -v '^+++' | grep -a -nE -i -e "$PAT")
ctl=$(printf '%s\n' "$all" | grep -a -c -F -e "$C1" -e "$C2" -e "$C3" || true)
hits=$(printf '%s\n' "$all" | grep -a -v -F -e "$C1" -e "$C2" -e "$C3" | grep -a . || true)
n=$(printf '%s' "$hits" | grep -a -c . || true)

echo "range     : $RANGE ($(git -C "$GD" diff --shortstat "$RANGE"))"
echo "scan hits : $n"
[[ -n "$hits" ]] && printf '%s\n' "$hits" | cut -c1-200
echo "control   : $ctl (want 3)"
# The control only proves the TEXT path works. A binary (a .gz above all) reaches grep as compressed
# bytes, so it is never really read; list them so each one is scanned on its own (zcat + the control).
bin=$(git -C "$GD" diff --numstat "$RANGE" | awk -F'\t' '$1=="-" {print $3}')
echo "binary    : $(printf '%s' "$bin" | grep -c .) file(s) NOT read by this scan -- scan each separately"
[[ -n "$bin" ]] && printf '            %s\n' $bin
[[ "$ctl" == 3 && "$n" == 0 ]]
