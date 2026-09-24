#!/usr/bin/env bash
# secret-scan.sh -- scan the ADDED lines of a git range for credential shapes, with a positive control.
# Usage: secret-scan.sh <git-dir> <range>      e.g.  secret-scan.sh "$AR" 1872be70..HEAD
# Exit 0 = range clean AND the control hit exactly 3; anything else is non-zero.
# [Co-developed with claude code -- Adam]
set -u
GD="$1"; RANGE="$2"
PAT='-----BEGIN [A-Z ]*PRIVATE KEY-----|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|sk-(ant-)?[A-Za-z0-9_-]{24,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|(api[_-]?key|secret|token|passw(or)?d)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"' ]{8,}["'"'"']'

# Positive control: three synthetic credentials that MUST be found (built at run time so this
# file itself never contains a matching literal).
ctl=$(printf '+%s\n+%s\n+%s\n' \
    "ghp_$(printf 'x%.0s' {1..36})" \
    "sk-ant-$(printf 'Q%.0s' {1..40})" \
    "AKIA$(printf 'Z%.0s' {1..16})" | grep -cE "$PAT")

hits=$(git -C "$GD" diff "$RANGE" --no-color -U0 --text \
       | grep -E '^\+' | grep -v '^+++' | grep -nE -i "$PAT")
n=$(printf '%s' "$hits" | grep -c . || true)

echo "range     : $RANGE ($(git -C "$GD" diff --shortstat "$RANGE"))"
echo "scan hits : $n"
[[ -n "$hits" ]] && printf '%s\n' "$hits" | cut -c1-200
echo "control   : $ctl (want 3)"
[[ "$ctl" == 3 && "$n" == 0 ]]
