#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndtwin_lab_config.sh.  KNOWN-ISSUES G-7.
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration.  This puts each defect back into
# tools/test_workflow/ndt one at a time -- the actual pre-fix text, not an invented mutation --
# runs the suite, and records WHICH NAMED CHECK went red.  "Something failed" is not the verdict:
# two of this project's suites have previously gone red on a mutation aimed at different
# behaviour, so a catch counts only when the check that fails is the one that owns that defect.
#
# 🔴 Guards its own baseline.  The file is snapshotted with `cp -p` before the first mutation, an
# EXIT trap restores it on any exit including Ctrl-C, and the run ends by asserting byte-identity
# against the snapshot.  Baseline is the WORKING TREE, not HEAD, so this runs against an
# uncommitted fix.
#
# 🔴 Never kills anything by name.  No pkill, no pgrep: `timeout` owns the only child, and the
# suite under test reaps its own fixtures and asserts that it did.
#
# 🔴 Touches no lab.  The suite replaces `sudo` and `lab_session` with shell functions, so
# nothing here can reach ndtwin-lab, ask for root, or disturb a claimed testbed.
#
# Usage:  tests/shell/mutate_g6_apps_liveness.sh
#   TEST_TIMEOUT=300   seconds allowed per suite run
#
# Exit: 0 every mutation was caught by the check named for it, and the control survived
#       1 at least one mutation survived, or was caught by the wrong check
#       2 the gate cannot render a verdict (baseline red, anchor drift, hang, failed restore, or
#         the comment-only control going red -- which would mean this gate measures "the file
#         changed" rather than "the behaviour changed")
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
NDT=tools/test_workflow/ndtwin-lab
SUITE=tests/shell/test_ndtwin_lab_config.sh

if ! bash -n "${BASH_SOURCE[0]}"; then echo "🔴 this script does not parse" >&2; exit 2; fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$NDT" && -f "$SUITE" ]] || { echo "🔴 missing $NDT or $SUITE" >&2; exit 2; }

SNAP="$(mktemp /tmp/mutate-g7-XXXXXX.ndt)"
cp -p "$NDT" "$SNAP"
restore() { cp -p "$SNAP" "$NDT"; }
cleanup() { restore; rm -f "$SNAP"; }
trap cleanup EXIT INT TERM

# --- mutations ------------------------------------------------------------------------
#
# Each is (name, expected-red-check, from, to).  `from` must appear EXACTLY once: an anchor that
# matches twice would mutate a site it was not named for and the verdict would be about the wrong
# code, and an anchor that matches zero times means the source moved under the gate -- "the
# mutation could not be applied" must never be reported as "the mutation was caught".
MUT_DIR="$(mktemp -d /tmp/mutate-g7-cases-XXXXXX)"
cleanup() { restore; rm -f "$SNAP"; rm -rf "$MUT_DIR"; }

write_case() {
    local name="$1" expect="$2"
    mkdir -p "$MUT_DIR/$name"
    printf '%s' "$expect" > "$MUT_DIR/$name/expect"
    cat > "$MUT_DIR/$name/pair"
}
CASES=()

# The hole this design usually has: check the file, forget the directory it can be replaced in.
CASES+=(no-directory-check)
write_case no-directory-check "  but world-writable, so it is refused" <<'PAIR'
lab_conf_dir_trusted() {
    local dir="$1" owner perms
    owner="$(stat -c '%u' "$dir" 2>/dev/null)"
    perms="$(stat -c '%a' "$dir" 2>/dev/null)"
@@@TO@@@
lab_conf_dir_trusted() {
    local dir="$1" owner perms
    owner=0
    perms=755
PAIR

# Checking the directory but not FIRST: the file's own message answers instead, from a path whose
# directory was never examined.
CASES+=(directory-checked-second)
write_case directory-checked-second "a bad directory refuses before the file" <<'PAIR'
    lab_conf_dir_trusted "$(dirname "$conf")"
    lab_conf_file_trusted "$conf"
@@@TO@@@
    lab_conf_file_trusted "$conf"
    lab_conf_dir_trusted "$(dirname "$conf")"
PAIR

# The whole point: a config anyone can write is the env override wearing a hat.
CASES+=(no-owner-check)
write_case no-owner-check "a file owned by this user is refused" <<'PAIR'
    [[ "$owner" == 0 ]] || die "$conf must be owned by root (it is owned by uid ${owner:-?}).
  A config anyone can write is the environment override this script refuses, wearing a hat:
  it would let a non-root user choose which .py root executes."
@@@TO@@@
    :
PAIR

# stat reports the LINK; following one lets a link in a trusted directory name an untrusted file.
CASES+=(symlink-allowed)
write_case symlink-allowed "  and says it will not read the target" <<'PAIR'
    if [[ -L "$conf" ]]; then
        die "$conf is a symlink (-> $(readlink "$conf")); refusing to read it.
  What gets read would be the target, and the target is not in the directory this checked."
    fi
@@@TO@@@
    :
PAIR

# Parsed, not sourced. The file is root-only-writable, so this is not an escalation -- it is the
# difference between a typo being an error and a typo being a root shell command.
CASES+=(source-instead-of-parse)
write_case source-instead-of-parse "  and was NOT executed" <<'PAIR'
    local conf="$1" line key val n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
@@@TO@@@
    local conf="$1" line key val n=0
    # shellcheck disable=SC1090
    source "$conf"
    while false; do
PAIR

# An unknown key silently ignored is a config the writer believes took effect and did not.
CASES+=(unknown-key-ignored)
write_case unknown-key-ignored "unknown-key is refused" <<'PAIR'
            *) die "$conf:$n: unknown key '$key' (known: KERNEL_DIR NTG_PY ENERGY_DIR SIM_DIR)" ;;
@@@TO@@@
            *) continue ;;
PAIR

# Fail at load, not halfway through topo-start with root already building a fabric.
CASES+=(no-bridge-validation)
write_case no-bridge-validation "a KERNEL_DIR with no bridge script" <<'PAIR'
    [[ -f "$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py" ]] ||
        die "$conf: KERNEL_DIR=$KERNEL_DIR has no p4_proxy/mininet/ntg_bmv2_topo.py.
  topo-start would otherwise have failed at run time, with root halfway through a fabric."
@@@TO@@@
    :
PAIR

# The header's original argument, which this change must not quietly undo.
CASES+=(environment-gets-a-vote)
write_case environment-gets-a-vote "an exported KERNEL_DIR is ignored" <<'PAIR'
KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel
NTG_PY=/home/adam/miniconda3/envs/ntg-env/bin/python
@@@TO@@@
KERNEL_DIR="${KERNEL_DIR:-/home/adam/Desktop/NDTwin-Kernel}"
NTG_PY=/home/adam/miniconda3/envs/ntg-env/bin/python
PAIR

# "A missing config file changes NOTHING" is a claim about specific literal values, so it is
# pinned to those values rather than to the sentence.
CASES+=(default-tree-changed)
write_case default-tree-changed "KERNEL_DIR is the pre-G-7 default" <<'PAIR'
ENERGY_DIR=/home/adam/Energy-Saving-App
@@@TO@@@
ENERGY_DIR=/home/adam/Energy-Saving-App
KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel-somewhere-else
PAIR

CASES+=(control-comment-only)
write_case control-comment-only "" <<'PAIR'
# Refuses rather than falls back. A config file that is present but unusable means someone meant
@@@TO@@@
# Refuses rather than falls back. (x) A config file that is present but unusable means someone meant
PAIR

apply() {   # apply <name>; echo ok|drift
    python3 - "$NDT" "$MUT_DIR/$1/pair" <<'PYAPPLY'
import sys, pathlib
src, pair = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text()
frm, to = pair.split("@@@TO@@@\n")
frm = frm
s = src.read_text()
n = s.count(frm)
if n != 1:
    print(f"drift {n}"); sys.exit(0)
src.write_text(s.replace(frm, to))
print("ok")
PYAPPLY
}

run_suite() {   # echo "<rc>|<comma separated FAILED check names>"
    local out rc
    out="$(timeout "$TEST_TIMEOUT" bash "$SUITE" 2>&1)"; rc=$?
    printf '%s|%s' "$rc" "$(printf '%s\n' "$out" | sed -n 's/^  FAILED  *//p' | paste -sd, -)"
}

# --- 0. baseline must be green --------------------------------------------------------
echo "=== baseline (the fix, unmutated) ==="
base="$(run_suite)"; base_rc="${base%%|*}"
printf '  rc=%s  red=%s\n' "$base_rc" "${base#*|}"
if [[ "$base_rc" == 124 ]]; then echo "  🔴 baseline HUNG" >&2; exit 2; fi
if (( base_rc > 128 )); then echo "  🔴 baseline died of signal $((base_rc-128))" >&2; exit 2; fi
if [[ "$base_rc" != 0 ]]; then echo "  🔴 baseline is RED -- nothing below is interpretable" >&2; exit 2; fi

# --- 1. one mutation at a time --------------------------------------------------------
echo
echo "=== mutations ==="
verdict=0
for name in "${CASES[@]}"; do
    expect="$(cat "$MUT_DIR/$name/expect")"
    # Leading spaces are stripped from the suite's FAILED lines by run_suite's sed, so a check
    # name that is indented (a sub-assertion) would never match its own expectation and the gate
    # would report "red, but NOT the named check" with two identical-looking strings. Trim here
    # so both sides are compared in the same shape.
    expect="${expect#"${expect%%[![:space:]]*}"}"
    restore
    a="$(apply "$name")"
    if [[ "$a" != ok ]]; then
        echo "  🔴 $name: anchor $a (must be exactly 1) -- the source moved under the gate" >&2
        verdict=2; continue
    fi
    if ! bash -n "$NDT" 2>/dev/null; then
        echo "  🔴 $name: the mutant does not parse -- that is a broken mutation, not a catch" >&2
        verdict=2; continue
    fi
    r="$(run_suite)"; rc="${r%%|*}"; red="${r#*|}"
    if [[ "$rc" == 124 ]]; then
        echo "  🔴 $name: suite HUNG -- never a catch" >&2; verdict=2; continue
    fi
    if (( rc > 128 )); then
        echo "  🔴 $name: suite died of signal $((rc-128)) -- not an assertion" >&2; verdict=2; continue
    fi
    if [[ -z "$expect" ]]; then                      # the control
        if [[ "$rc" == 0 ]]; then
            printf '  %-26s SURVIVED (control, as required)\n' "$name"
        else
            printf '  %-26s 🔴 CONTROL WENT RED: %s\n' "$name" "$red" >&2
            verdict=2
        fi
        continue
    fi
    if [[ "$rc" == 0 ]]; then
        printf '  %-26s 🔴 SURVIVED -- the suite does not test this\n' "$name" >&2
        verdict=1
    elif [[ ",$red," == *",$expect,"* ]]; then
        printf '  %-26s caught by: %s\n' "$name" "$expect"
    else
        printf '  %-26s 🔴 red, but NOT the named check\n' "$name" >&2
        printf '  %-26s    wanted: %s\n' "" "$expect" >&2
        printf '  %-26s    got:    %s\n' "" "$red" >&2
        verdict=1
    fi
done

# --- 2. the baseline must be back, byte for byte --------------------------------------
restore
echo
if cmp -s "$NDT" "$SNAP"; then
    echo "restore: $NDT is byte-identical to the pre-gate snapshot"
else
    echo "🔴 restore FAILED -- $NDT differs from the snapshot" >&2
    verdict=2
fi

echo
case "$verdict" in
    0) echo "VERDICT: every mutation was caught by the check named for it; the control survived" ;;
    1) echo "VERDICT: at least one mutation survived or was caught by the wrong check" >&2 ;;
    *) echo "VERDICT: no verdict -- the gate could not run cleanly" >&2 ;;
esac
exit "$verdict"
