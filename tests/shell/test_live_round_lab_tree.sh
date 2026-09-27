#!/usr/bin/env bash
# Does a LIVE E / F-5 round refuse to run from a tree the lab is not running?
#
# [Co-developed with claude code -- Adam]
#
# round.env now derives KERNEL_DIR from the checkout it sits in (N7). The fabric does not follow:
# `ndtwin-lab topo-start` starts the bridge from the tree `sudo ndtwin-lab config` names, and the
# bridge loads THAT tree's compiled P4. So a live round started from a worktree would compile and
# check one program while the switches run another, write cells where measure.sh does not, and
# consult a claim and a restore marker nobody else can see. lib_e.sh's and run_f5.sh's preflights
# therefore call lab_tree_check first: in a live run (DRY_RUN != 1), a KERNEL_DIR that is not the
# lab's tree -- compared after resolving symlinks -- is refused with rc 2, both trees named, and
# BEFORE anything is written (preflight's first act used to be a log line).
#
# 🔴 No real sudo, ever. `sudo` on this suite's PATH is a stub that answers exactly
# `-n /usr/local/sbin/ndtwin-lab config` with a canned config naming a tree this suite chose, and
# records and refuses anything else. The shipped function bodies are extracted from the files
# (sed, the same way test_log_suffix_idempotent.sh reads derive_log) and run in a child bash with
# say/dry_note/dry_fail defined as the files define them: say appends to $LOG, so a preflight
# that got past the check leaves a log behind.
#
# Run:  bash tests/shell/test_live_round_lab_tree.sh
# Env:  LIB_E_UNDER_TEST / RUN_F5_UNDER_TEST=<path>  (the mutation gate's copies)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
unset KERNEL_DIR
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LIB_E="${LIB_E_UNDER_TEST:-$REPO_ROOT/doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh}"
RUN_F5="${RUN_F5_UNDER_TEST:-$REPO_ROOT/doc/audit/2026-08-31_f5-fine-grid-round/run_f5.sh}"

T="$(mktemp -d "${TMPDIR:-/tmp}/live-round-lab-tree-XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"

PASS=0; FAIL=0
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}
has() {     # <name> <needle> <haystack>
    if grep -qF -- "$2" <<<"$3"; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             no match for: [%s]\n' "$1" "$2"
         sed -n '1,4p' <<<"$3" | sed 's/^/             in: /'; fi
}

# --- the sudo stub ------------------------------------------------------------------------------
STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/sudo" <<'EOF'
#!/bin/bash
# records every call; answers `-n /usr/local/sbin/ndtwin-lab config` only
printf '%s\n' "$*" >> "$STUB_LOG"
if [[ "$*" == "-n /usr/local/sbin/ndtwin-lab config" ]]; then
    [[ "${STUB_RC:-0}" == 0 ]] || { echo "sudo: a password is required" >&2; exit "$STUB_RC"; }
    printf 'config:     built-in defaults (stub)\n'
    [[ -n "${STUB_LAB_TREE:-}" ]] && printf 'KERNEL_DIR: %s\n' "$STUB_LAB_TREE"
    printf 'BRIDGE:     %s/p4_proxy/mininet/ntg_bmv2_topo.py\n' "${STUB_LAB_TREE:-?}"
    exit 0
fi
echo "sudo stub: refused (not the config query): $*" >&2
exit 1
EOF
chmod +x "$STUB/sudo"

MINE="$T/mine"; LABT="$T/lab"; mkdir -p "$MINE" "$LABT" "$T/logs"
ln -s "$MINE" "$T/link-to-mine"

# run_in <file> <script> [NAME=value...] -- the file's shipped lab_tree_check and preflight, in a
# child bash under the stub, with the variables round.env would have exported
run_in() {
    local file="$1" script="$2"; shift 2
    env PATH="$STUB:$PATH" STUB_LOG="$T/stub.log" LAB="sudo -n /usr/local/sbin/ndtwin-lab" \
        DRY_RUN=0 DRY_FAIL= NDT_OWNER="lab-tree-suite-$$" ARM=q1-p4-post FABRIC=p4 \
        KERNEL_DIR="$MINE" LOG="$T/logs/preflight.log" "$@" bash -c '
        set -u
        eval "$(sed -n "/^lab_tree_check() {/,/^}/p" "$1")"
        eval "$(sed -n "/^preflight() {/,/^}/p" "$1")"
        say() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
        dry_note() { :; }
        dry_fail() { return 1; }
        '"$script" _ "$file"
}

for pair in "E:$LIB_E" "F5:$RUN_F5"; do
    round="${pair%%:*}"; file="${pair#*:}"
    echo "$round: $file"
    [[ -r "$file" ]] || { check "$round: the file under test is readable" yes "no: $file"; continue; }

    # 1. the defect: a live preflight from a tree the lab is not running
    : > "$T/stub.log"; rm -f "$T/logs/preflight.log"
    err="$(run_in "$file" 'preflight gates' STUB_LAB_TREE="$LABT" 2>&1 >/dev/null)"; rc=$?
    check "🔴 $round: a live preflight from another tree is refused with rc 2" 2 "$rc"
    has "  $round: the refusal names this round's tree" "KERNEL_DIR=$MINE" "$err"
    has "  $round: and the lab's tree" "but the lab runs the tree $LABT" "$err"
    has "  $round: and says live rounds run only from the lab's tree" "Live rounds run only from the lab's tree" "$err"
    check "🔴 $round: and it refused before writing anything (no preflight log)" "absent" \
          "$([[ -e "$T/logs/preflight.log" ]] && echo present || echo absent)"
    check "  $round: the only thing it ran was the config query" "-n /usr/local/sbin/ndtwin-lab config" \
          "$(cat "$T/stub.log")"

    # 2. the same tree, directly and through a symlink, is let through
    : > "$T/stub.log"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$MINE" >/dev/null 2>&1; rc=$?
    check "$round: the lab's own tree passes the check" 0 "$rc"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$MINE" KERNEL_DIR="$T/link-to-mine" >/dev/null 2>&1; rc=$?
    check "🔴 $round: the lab's tree reached through a symlink passes too" 0 "$rc"

    # 3. a dry run never asks the lab (it must stay runnable from any checkout)
    : > "$T/stub.log"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$LABT" DRY_RUN=1 >/dev/null 2>&1; rc=$?
    check "🔴 $round: a dry run is exempt" 0 "$rc"
    check "  $round: and does not call sudo at all" "" "$(cat "$T/stub.log")"

    # 4. when the lab cannot say, that is a refusal too -- not agreement
    err="$(run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$MINE" STUB_RC=1 2>&1 >/dev/null)"; rc=$?
    check "🔴 $round: a lab that cannot be asked is a refusal (rc 2)" 2 "$rc"
    has "  $round: and says it could not ask" "could not ask the lab which tree it runs" "$err"
    err="$(run_in "$file" 'lab_tree_check' STUB_LAB_TREE= 2>&1 >/dev/null)"; rc=$?
    check "🔴 $round: a config that names no KERNEL_DIR is a refusal (rc 2)" 2 "$rc"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$T/does-not-exist" >/dev/null 2>&1; rc=$?
    check "  $round: a lab tree that does not exist is a refusal (rc 2)" 2 "$rc"

    # 5. the instrument: the sudo that answered was the stub, not the machine's
    : > "$T/stub.log"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$MINE" >/dev/null 2>&1
    check "  $round: (the sudo on PATH was this suite's stub)" "-n /usr/local/sbin/ndtwin-lab config" "$(cat "$T/stub.log")"
done

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
