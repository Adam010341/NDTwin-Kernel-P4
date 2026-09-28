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
# lab's tree -- compared after resolving symlinks on both sides -- is refused with rc 2, both trees
# named, and BEFORE anything is written (preflight's first act used to be a log line).
#
# Two levels. The function level extracts the shipped lab_tree_check and preflight bodies from the
# files (sed, the same way test_log_suffix_idempotent.sh reads derive_log) and runs them in a child
# bash with say/dry_note/dry_fail defined as the files define them: say appends to $LOG, so a
# preflight that got past the check leaves a log behind. The ENTRY level runs the real scripts the
# way an operator does -- gates_e.sh (gates and baseline), run_e.sh ladder, run_f5.sh arm, q3 and
# restore, DRY_RUN=0 -- from a copy of both round directories in a checkout-shaped temp tree, with
# KERNEL_DIR and ROUND unset so round.env derives the copy, and asserts rc 2 and a tree left exactly
# as it was: no file created or changed (sha256 of every file), no directory beyond the ones
# round.env itself creates when it is sourced (measured here, not listed), no restore alarm, and no
# sudo call but the config query. A control run with the lab on the temp tree shows the restore
# trap does fire and write its marker in this harness, so the refusals' silence is the check's.
#
# 🔴 No real sudo, ever. `sudo` on this suite's PATH is a stub that answers exactly
# `-n /usr/local/sbin/ndtwin-lab config` in the shape tools/test_workflow/ndtwin-lab prints (with,
# on request, the stderr preamble a refused /etc/ndtwin-lab.conf adds), naming a tree this suite
# chose, and records and refuses anything else.
#
# Run:  bash tests/shell/test_live_round_lab_tree.sh
# Env:  LIB_E_UNDER_TEST / RUN_F5_UNDER_TEST / GATES_E_UNDER_TEST=<path>  (the mutation gate's
#       copies; the entry level lays them over its copy of the round directories)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
unset KERNEL_DIR ROUND LOG_BASE
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
E_REL=doc/audit/2026-08-31_sampling-ceiling-after-merge
F_REL=doc/audit/2026-08-31_f5-fine-grid-round
LIB_E="${LIB_E_UNDER_TEST:-$REPO_ROOT/$E_REL/lib_e.sh}"
RUN_F5="${RUN_F5_UNDER_TEST:-$REPO_ROOT/$F_REL/run_f5.sh}"
GATES_E="${GATES_E_UNDER_TEST:-$REPO_ROOT/$E_REL/gates_e.sh}"

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
# records every call; answers `-n /usr/local/sbin/ndtwin-lab config` only, in the helper's shape
printf '%s\n' "$*" >> "$STUB_LOG"
if [[ "$*" == "-n /usr/local/sbin/ndtwin-lab config" ]]; then
    [[ "${STUB_RC:-0}" == 0 ]] || { echo "sudo: a password is required" >&2; exit "$STUB_RC"; }
    if [[ -n "${STUB_PREAMBLE_TREE:-}" ]]; then
        # lab_conf_gate's preamble for a refused conf -- here one written in `config`'s own format
        printf '🔴 /etc/ndtwin-lab.conf was REFUSED and is NOT in use:\n' >&2
        printf '   /etc/ndtwin-lab.conf:1: not KEY=VALUE: KERNEL_DIR: %s\n' "$STUB_PREAMBLE_TREE" >&2
        printf '   running on built-in defaults. remove it with:  sudo rm /etc/ndtwin-lab.conf\n' >&2
        printf '   (config is read-only, so it runs anyway -- on the DEFAULTS, not on that file)\n' >&2
        printf 'config:     built-in defaults (/etc/ndtwin-lab.conf was REFUSED)\n'
    else
        printf 'config:     built-in defaults (no /etc/ndtwin-lab.conf)\n'
    fi
    [[ -n "${STUB_LAB_TREE:-}" ]] && printf 'KERNEL_DIR: %s\n' "$STUB_LAB_TREE"
    printf 'BRIDGE:     %s/p4_proxy/mininet/ntg_bmv2_topo.py\n' "${STUB_LAB_TREE:-?}"
    printf 'NTG_PY:     /nonexistent/ntg-env/bin/python\n'
    printf 'ENERGY_DIR: /nonexistent/Energy-Saving-App\n'
    printf 'SIM_DIR:    /nonexistent/Simulation-Platform-Manager\n'
    exit 0
fi
echo "sudo stub: refused (not the config query): $*" >&2
exit 1
EOF
chmod +x "$STUB/sudo"

MINE="$T/mine"; LABT="$T/lab"; mkdir -p "$MINE" "$LABT" "$T/logs" "$T/tmp"
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

    # 2. the same tree, directly and through a symlink on EITHER side, is let through
    : > "$T/stub.log"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$MINE" >/dev/null 2>&1; rc=$?
    check "$round: the lab's own tree passes the check" 0 "$rc"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$MINE" KERNEL_DIR="$T/link-to-mine" >/dev/null 2>&1; rc=$?
    check "🔴 $round: the lab's tree reached through a symlink passes too" 0 "$rc"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$T/link-to-mine" >/dev/null 2>&1; rc=$?
    check "🔴 $round: and so does a lab config that names this tree through a symlink" 0 "$rc"

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
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$T/gone" KERNEL_DIR="$T/gone" >/dev/null 2>&1; rc=$?
    check "  $round: the same missing path on both sides is no agreement (rc 2)" 2 "$rc"

    # 5. a refused /etc/ndtwin-lab.conf: its stderr preamble is merged into the answer (2>&1) and
    #    may itself contain "KERNEL_DIR: <path>" -- only the line that STARTS with it is the answer
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$MINE" STUB_PREAMBLE_TREE="$LABT" >/dev/null 2>&1; rc=$?
    check "  $round: a refused-conf preamble naming another tree does not decide it (rc 0)" 0 "$rc"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$LABT" STUB_PREAMBLE_TREE="$MINE" >/dev/null 2>&1; rc=$?
    check "🔴 $round: nor does one naming THIS tree while the lab runs another (rc 2)" 2 "$rc"

    # 6. a partial environment (N-9): no KERNEL_DIR, or a relative one, is refused before asking
    : > "$T/stub.log"
    err="$(run_in "$file" 'unset KERNEL_DIR; lab_tree_check' STUB_LAB_TREE="$MINE" 2>&1 >/dev/null)"; rc=$?
    check "🔴 $round: an unset KERNEL_DIR is a refusal (rc 2)" 2 "$rc"
    has "  $round: and it says KERNEL_DIR is not an absolute path" "KERNEL_DIR=<unset> is not an absolute path" "$err"
    check "  $round: and does not ask the lab" "" "$(cat "$T/stub.log")"
    err="$(cd "$MINE" && run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$MINE" KERNEL_DIR=. 2>&1 >/dev/null)"; rc=$?
    check "🔴 $round: a relative KERNEL_DIR is refused even from inside the lab's tree (rc 2)" 2 "$rc"

    # 7. the instrument: the sudo that answered was the stub, not the machine's
    : > "$T/stub.log"
    run_in "$file" 'lab_tree_check' STUB_LAB_TREE="$MINE" >/dev/null 2>&1
    check "  $round: (the sudo on PATH was this suite's stub)" "-n /usr/local/sbin/ndtwin-lab config" "$(cat "$T/stub.log")"
done

# --- entry level: the real scripts, run the way an operator runs them ---------------------------
echo "entry points (DRY_RUN=0, a checkout-shaped temp tree, the lab on another tree)"
# the template tree: both round directories from this checkout without their raw/, the files
# under test laid over them
TPL="$T/tpl"
for rel in "$E_REL" "$F_REL"; do
    mkdir -p "$TPL/$rel"
    tar -C "$REPO_ROOT/$rel" --exclude=./raw -cf - . | tar -C "$TPL/$rel" -xf -
done
cp "$LIB_E" "$TPL/$E_REL/lib_e.sh"; cp "$GATES_E" "$TPL/$E_REL/gates_e.sh"; cp "$RUN_F5" "$TPL/$F_REL/run_f5.sh"

snap_files() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum); }
snap_dirs()  { (cd "$1" && find . -type d | LC_ALL=C sort); }
changed_files() {   # <before> <after> -- the paths whose line differs (created, changed, removed)
    diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | sed -n 's/^[<>] [0-9a-f]\{64\}  //p' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

# op_env <tree> <lab tree> NAME=value... -- an operator's shell: nothing inherited but PATH (the
# stub first) and HOME; KERNEL_DIR and ROUND unset unless named
op_env() {
    local tree="$1" lab="$2"; shift 2
    env -i PATH="$STUB:$PATH" HOME="$HOME" TMPDIR="$T/tmp" LANG=C.UTF-8 STUB_LOG="$T/stub.log" \
        STUB_LAB_TREE="$lab" NDT_OWNER="lab-tree-suite-$$" DRY_RUN=0 "$@"
}

# what sourcing round.env creates by itself (mkdir -p "$OUT" ...): the only new directories allowed
probe="$T/probe"; cp -a "$TPL" "$probe"
pre_f="$(snap_files "$probe")"; pre_d="$(snap_dirs "$probe")"
op_env "$probe" "$LABT" bash -c '. "$1/'"$E_REL"'/round.env" && . "$1/'"$F_REL"'/round.env"' _ "$probe" >/dev/null 2>&1
ALLOWED_DIRS="$(LC_ALL=C comm -13 <(printf '%s\n' "$pre_d") <(snap_dirs "$probe"))"
check "  (sourcing both round.env files creates directories only)" "" "$(changed_files "$pre_f" "$(snap_files "$probe")")"
echo "    round.env's own directories: $(tr '\n' ' ' <<<"$ALLOWED_DIRS")"
check "  (the sudo an operator's shell finds here is this suite's stub)" "$STUB/sudo" \
      "$(op_env "$probe" "$LABT" bash -c 'command -v sudo')"

NT=0
# entry <label> <round rel> <script> [args...] -- a fresh tree, the script run from its root
entry() {
    local label="$1" rel="$2" script="$3"; shift 3
    local tree="$T/e$((++NT))" out rc pre_f pre_d post_d
    cp -a "$TPL" "$tree"
    pre_f="$(snap_files "$tree")"; pre_d="$(snap_dirs "$tree")"
    : > "$T/stub.log"
    out="$(cd "$tree" && op_env "$tree" "$LABT" timeout 120 bash "$tree/$rel/$script" "$@" 2>&1)"; rc=$?
    post_d="$(snap_dirs "$tree")"
    check "🔴 $label: refused with rc 2" 2 "$rc"
    check "🔴 $label: no file created or changed in the tree" "" "$(changed_files "$pre_f" "$(snap_files "$tree")")"
    check "  $label: no directory but round.env's own" "" \
          "$(LC_ALL=C comm -23 <(LC_ALL=C comm -13 <(printf '%s\n' "$pre_d") <(printf '%s\n' "$post_d")) <(printf '%s\n' "$ALLOWED_DIRS") | tr '\n' ' ' | sed 's/ $//')"
    has "  $label: the refusal names the lab's tree" "but the lab runs the tree $LABT" "$out"
    check "🔴 $label: no restore alarm (nothing was armed)" "" \
          "$(grep -E 'NOT RESTORED|do not release|RESTORE FAILED|RESTORE-FAILED' <<<"$out")"
    check "  $label: sudo was asked the config query and nothing else" "-n /usr/local/sbin/ndtwin-lab config" \
          "$(cat "$T/stub.log")"
}
entry "gates_e.sh"           "$E_REL" gates_e.sh
entry "gates_e.sh baseline"  "$E_REL" gates_e.sh baseline
entry "run_e.sh ladder"      "$E_REL" run_e.sh ladder
entry "run_f5.sh arm"        "$F_REL" run_f5.sh arm
entry "run_f5.sh q3"         "$F_REL" run_f5.sh q3
entry "run_f5.sh restore"    "$F_REL" run_f5.sh restore

# N-9: ROUND (and what the script's top level needs) exported, KERNEL_DIR not -- rc 2, not a death
# under set -u, and nothing armed or written
n9() {   # n9 <label> <round rel> <script> <arg> NAME=value...
    local label="$1" rel="$2" script="$3" arg="$4"; shift 4
    local tree="$T/e$((++NT))" out rc pre_f
    cp -a "$TPL" "$tree"; pre_f="$(snap_files "$tree")"
    : > "$T/stub.log"
    out="$(cd "$tree" && op_env "$tree" "$LABT" ROUND="$tree/$rel" "${@//@T@/$tree/$rel}" \
           timeout 120 bash "$tree/$rel/$script" "$arg" 2>&1)"; rc=$?
    check "🔴 $label: ROUND exported without KERNEL_DIR -- refused with rc 2" 2 "$rc"
    has "  $label: and says KERNEL_DIR is not set" "KERNEL_DIR=<unset> is not an absolute path" "$out"
    check "  $label: and nothing was created or changed" "" "$(changed_files "$pre_f" "$(snap_files "$tree")")"
}
n9 "N-9 run_f5.sh arm"    "$F_REL" run_f5.sh arm    LOG_BASE=@T@/run_f5.log
n9 "N-9 run_e.sh ladder"  "$E_REL" run_e.sh ladder  LOG_BASE=@T@/run_e.log OUT=@T@/raw

# control: the lab on THIS temp tree -- arm gets past the tree check, is refused later (no claim),
# and the restore trap fires and leaves its marker. So the silence above is the tree check's.
tree="$T/e$((++NT))"; cp -a "$TPL" "$tree"; : > "$T/stub.log"
out="$(cd "$tree" && op_env "$tree" "$tree" timeout 120 bash "$tree/$F_REL/run_f5.sh" arm 2>&1)"; rc=$?
check "  control: with the lab on this tree, arm passes the tree check and is refused later (rc 2)" 2 "$rc"
has "  control: by a later preflight refusal" "REFUSE: " "$out"
check "🔴 control: and the restore trap fired and wrote its marker in this harness" present \
      "$([[ -s "$tree/$F_REL/raw/LAB-NOT-RESTORED" ]] && echo present || echo absent)"

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
