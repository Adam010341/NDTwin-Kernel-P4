#!/usr/bin/env bash
#
# Tests for G-7: ndtwin-lab's install-time config file.
#
# [Co-developed with claude code -- Adam]
#
# What this is fixing, and what it is deliberately NOT doing:
#
# FINDING-01 (2026-08-30) -- a round pinned the kernel to a worktree and exported KERNEL_DIR.
# ndtwin-lab is outside the reach of that variable, so topo-start built the MAIN tree's 128-host
# fabric while `ndt up p4 4` handed the kernel a 4-host model. Fabric 128, model 4, every
# structural check green, and no message anywhere saying which tree was used.
#
# The file's own header spent twenty lines arguing that an ENV OVERRIDE is not the fix, because
# it would let anything running as adam choose which .py root executes. That argument is about
# WHO CHOOSES and WHEN -- the caller, at call time -- and it does not carry over to a file only
# root can write. It does carry over completely to a config file anyone can write, which is why
# the checks below are the substance of this change and not paperwork around it.
#
# 🔑 The escalation that already exists is not closed here and this suite does not pretend it is:
#    the DEFAULT KERNEL_DIR is adam-writable, so root has been executing an adam-writable .py all
#    along. What is under test is that the CHOICE of tree cannot be made by a non-root user.
#
# The two halves are tested differently, on purpose:
#
#   * lab_config_trusted -- the REFUSAL direction is what protects anything, and every refusal
#     below is exercised against real files with real ownership and real modes; nothing is
#     stubbed. The ACCEPTANCE direction uses /etc/hostname: a real root-owned, non-symlink,
#     0644 file in a real root-owned 0755 directory. Using the machine's own facts rather than
#     a stub is what keeps this from being a test of a mock.
#   * lab_config_parse -- reachable by a non-root test precisely because it is a separate
#     function, which is why it is one.
#
# `die` exits, so every call is made in a subshell and judged by its rc and its stderr.
#
# Run:  bash tests/shell/test_ndtwin_lab_config.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$HERE/../../tools/test_workflow/ndtwin-lab"
REPO="$(cd "$HERE/../.." && pwd)"

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }

# shellcheck source=/dev/null
source "$LAB" || { echo "  FAILED   could not source $LAB"; echo "Ran 1 checks, 1 failed"; exit 1; }

# ndtwin-lab runs under `set -euo pipefail`, and sourcing it turns errexit on HERE. A suite whose
# subject matter is deliberate failures cannot run under errexit: the first refusal it provokes
# would exit the suite mid-run, and -- this is the part that makes it dangerous rather than
# merely annoying -- a suite that stops early still prints every check it managed to reach as
# `ok`, so it looks like a pass that simply ends. Measured here: the run stopped after "and it
# says what is missing" with no summary line at all.
set +e

TMPROOT="$(mktemp -d /tmp/ndtwin-lab-config-XXXXXX)"
cleanup() { [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndtwin-lab-config-* ]] && rm -rf "$TMPROOT"; return 0; }
trap cleanup EXIT INT TERM

# rc_of / err_of -- still a subshell. The config predicates record rather than exit now, but the
# dispatch gate still dies, and a subshell is the only form that is right for both.
#
# err_of reads LAB_CONF_ERROR rather than stderr for the predicates: a refusal is RECORDED, not
# printed, and asserting on stderr would quietly pass for the wrong reason once nothing prints.
rc_of()  { ( "$@" >/dev/null 2>&1 ); echo $?; }
err_of() { ( "$@" >/dev/null 2>&1; printf '%s' "$LAB_CONF_ERROR" ); }

# --- 0. the default: a machine with no config file behaves as it always did -------------
echo "no config file (the behaviour that must not change)"

check "sourcing as a non-root user works"        1 "$NDTWIN_LAB_SOURCED"
check "KERNEL_DIR is the pre-G-7 default"        /home/adam/Desktop/NDTwin-Kernel "$KERNEL_DIR"
check "NTG_PY is the pre-G-7 default"            /home/adam/miniconda3/envs/ntg-env/bin/python "$NTG_PY"
check "ENERGY_DIR is the pre-G-7 default"        /home/adam/Energy-Saving-App "$ENERGY_DIR"
check "SIM_DIR is the pre-G-7 default"           /home/adam/Simulation-Platform-Manager "$SIM_DIR"
check "BRIDGE is built from KERNEL_DIR"          "$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py" "$BRIDGE"
check "a missing config file is not an error"    0 "$(rc_of lab_config_load "$TMPROOT/does-not-exist.conf")"
check "  and it says the defaults are in use"    yes "$(has "built-in defaults" "$LAB_CONF_SOURCE")"
check "the fixed path is /etc/ndtwin-lab.conf"   /etc/ndtwin-lab.conf "$LAB_CONF"

# --- 1. trust: who is allowed to choose which .py root executes -------------------------
#
# Every file below is real, with real ownership and real permissions. This suite runs as a
# non-root user, so a file it creates is genuinely one "anything running as adam" could write --
# which is exactly the thing that must be refused.
echo "trust (the refusals are what protect anything)"

MINE="$TMPROOT/mine.conf"; : > "$MINE"; chmod 644 "$MINE"

# The two halves are asked separately, because the directory is judged first and would otherwise
# answer every question here. There is no directory a non-root user can write to that is also
# root-owned, so "an adam-owned file in a trusted directory" is not a fixture that can exist --
# and a combined predicate would leave every file-level check below permanently unreachable.
echo "  the file half"
check "a file owned by this user is refused"     1 "$(rc_of lab_conf_file_trusted "$MINE")"
check "  and it says who owns it"                yes "$(has "owned by uid $(id -u)" "$(err_of lab_conf_file_trusted "$MINE")")"

chmod 646 "$MINE"
check "a world-writable file is refused"         1 "$(rc_of lab_conf_file_trusted "$MINE")"
chmod 644 "$MINE"

# A symlink in a trusted directory pointing at an untrusted file: stat reports the LINK.
#
# 🔑 The rc here does not depend on the explicit symlink check, and the mutation gate is what
#    established that: with the check deleted, a symlink is STILL refused -- `stat` does not
#    dereference, so it reports the link, and a link is mode 777, which the group/other-writable
#    rule rejects. The explicit refusal earns its place by saying WHY (an operator reading
#    "mode 777" about a file they made 0644 learns nothing), and by standing in the way of a
#    later "stat -L would be more correct" that would silently open the hole. So the assertion
#    that discriminates is the message, not the exit code, and it is written that way on purpose
#    rather than because the exit code happened to be convenient.
ln -s "$MINE" "$TMPROOT/link.conf"
check "a symlink is refused outright"            1 "$(rc_of lab_conf_file_trusted "$TMPROOT/link.conf")"
check "  and says it will not read the target"   yes "$(has "symlink" "$(err_of lab_conf_file_trusted "$TMPROOT/link.conf")")"

mkdir -p "$TMPROOT/notafile.conf"
check "a directory is not a config file"         1 "$(rc_of lab_conf_file_trusted "$TMPROOT/notafile.conf")"

# The machine's own facts, not a stub: root-owned, non-symlink, 0644.
check "a real root-owned file IS trusted"        0 "$(rc_of lab_conf_file_trusted /etc/hostname)"
check "  /etc/hostname really is root-owned"     0 "$(stat -c '%u' /etc/hostname)"
check "  and really is not group/other writable" 644 "$(stat -c '%a' /etc/hostname)"

echo "  the directory half"
check "a directory owned by this user is refused" 1 "$(rc_of lab_conf_dir_trusted "$TMPROOT")"
check "  and it says who owns it"                yes "$(has "owned by uid $(id -u)" "$(err_of lab_conf_dir_trusted "$TMPROOT")")"

# /tmp is the shape that matters and it is real: root-owned, and world-writable. Owning the file
# would not help -- anyone can rename it away and put their own there.
check "/tmp is root-owned"                       0 "$(stat -c '%u' /tmp)"
check "  but world-writable, so it is refused"   1 "$(rc_of lab_conf_dir_trusted /tmp)"
check "  and it explains it can be replaced"     yes "$(has "replace" "$(err_of lab_conf_dir_trusted /tmp)")"

check "/etc IS trusted"                          0 "$(rc_of lab_conf_dir_trusted /etc)"
check "  /etc really is root-owned"              0 "$(stat -c '%u' /etc)"

echo "  and the directory is judged FIRST"
# A file that does not exist at all, in an untrusted directory. If the directory were checked
# second, the answer would be "not a regular file" -- a message about the file, from a path whose
# directory was never examined. The ordering is the check, so the message is how it is asserted.
check "a bad directory refuses before the file"  yes \
    "$(has "replace" "$(err_of lab_config_trusted /tmp/ndtwin-lab-nonexistent.conf)")"

# --- 2. parse: what the file is allowed to say ------------------------------------------
#
# A tree that looks enough like a kernel checkout for KERNEL_DIR's validation to accept it.
echo "parse (only four keys, absolute paths, and the tree must exist)"

FAKETREE="$TMPROOT/tree"
mkdir -p "$FAKETREE/p4_proxy/mininet"
: > "$FAKETREE/p4_proxy/mininet/ntg_bmv2_topo.py"

good="$TMPROOT/good.conf"
cat > "$good" <<CONF
# a comment, and a blank line follow

KERNEL_DIR=$FAKETREE
   SIM_DIR = /opt/sim
CONF
out="$( set -e; lab_config_parse "$good" >/dev/null 2>&1; echo "$KERNEL_DIR|$SIM_DIR|$NTG_PY|$LAB_CONF_SOURCE" )"
check "a good file sets what it names"           "$FAKETREE|/opt/sim|/home/adam/miniconda3/envs/ntg-env/bin/python|$good" "$out"

for case_name in unknown-key relative-path dotdot no-equals; do
    f="$TMPROOT/$case_name.conf"
    case "$case_name" in
        unknown-key)   printf 'KERNEL_DIR=%s\nKERNEL_DIRS=/tmp\n' "$FAKETREE" > "$f" ;;
        relative-path) printf 'KERNEL_DIR=tree\n' > "$f" ;;
        dotdot)        printf 'KERNEL_DIR=%s/../tree\n' "$FAKETREE" > "$f" ;;
        no-equals)     printf 'KERNEL_DIR %s\n' "$FAKETREE" > "$f" ;;
    esac
    check "$case_name is refused"                1 "$(rc_of lab_config_parse "$f")"
    check "  and names the line number"          yes "$(has "$(basename "$f"):" "$(err_of lab_config_parse "$f")")"
done

# The two that matter most operationally: a config that points somewhere real but wrong must
# fail at LOAD, not halfway through topo-start with root already building a fabric.
printf 'KERNEL_DIR=%s/nope\n' "$TMPROOT" > "$TMPROOT/missing.conf"
check "a KERNEL_DIR that does not exist"         1 "$(rc_of lab_config_parse "$TMPROOT/missing.conf")"
printf 'KERNEL_DIR=%s\n' "$TMPROOT" > "$TMPROOT/notree.conf"
check "a KERNEL_DIR with no bridge script"       1 "$(rc_of lab_config_parse "$TMPROOT/notree.conf")"
check "  and it says what is missing"            yes "$(has "ntg_bmv2_topo.py" "$(err_of lab_config_parse "$TMPROOT/notree.conf")")"

# Parsed, not sourced: a line that would be a command if this file were sourced must not run.
printf 'KERNEL_DIR=%s\ntouch %s/PWNED\n' "$FAKETREE" "$TMPROOT" > "$TMPROOT/cmd.conf"
rc_of lab_config_parse "$TMPROOT/cmd.conf" >/dev/null
check "a shell command in the file is refused"   1 "$(rc_of lab_config_parse "$TMPROOT/cmd.conf")"
check "  and was NOT executed"                   no  "$(if [[ -e "$TMPROOT/PWNED" ]]; then echo yes; else echo no; fi)"

# --- 3. it is still not overridable from the environment --------------------------------
#
# The header's original argument, kept as an assertion so a later "convenience" cannot quietly
# reintroduce it.
# --- 2b. a refused config file: what it costs, verb by verb ----------------------------
#
# [Co-developed with claude code -- Adam]
# Revised 2026-09-03 after review. Failing closed is right for anything that ACTS -- an
# untrusted file must not choose which tree root runs. It was wrong for `status` and `config`:
# read-only, touch nothing, and exactly what an operator reaches for after a typo. Locking them
# out leaves the rescue path as "already know to run `sudo rm /etc/ndtwin-lab.conf`", and
# someone who does not know that concludes the lab is broken.
echo "a refused config file (the rescue path has to stay open)"

# A file that is fine in every way except the directory it lives in -- which is the whole point:
# a world-writable directory means the file can be swapped out, so nothing about it is believable.
BADDIR="$TMPROOT/opendir"
mkdir -p "$BADDIR"; chmod 777 "$BADDIR"
BADCONF="$BADDIR/ndtwin-lab.conf"
printf 'KERNEL_DIR=%s\n' "$FAKETREE" > "$BADCONF"

check "load of a refused file -> rc 1"           1 "$(rc_of lab_config_load "$BADCONF")"

# The values must be the BUILT-IN defaults afterwards, not the file's, and not a mixture.
# lab_config_parse assigns as it reads, so a file whose later line is bad has already applied
# its earlier ones -- a half-applied config matches nothing anybody wrote down.
after="$( lab_config_load "$BADCONF" >/dev/null 2>&1
          printf '%s|%s|%s|%s' "$KERNEL_DIR" "$NTG_PY" "$ENERGY_DIR" "$SIM_DIR" )"
check "  the built-in defaults are in force"     "$LAB_DEFAULT_KERNEL_DIR|$LAB_DEFAULT_NTG_PY|$LAB_DEFAULT_ENERGY_DIR|$LAB_DEFAULT_SIM_DIR" "$after"

# The residue case, and getting AT it takes one deliberate step: a file this test can create is
# always refused by the trust check first, so parse never runs and there is nothing to restore --
# a check written the obvious way passes without the restore existing at all (measured: the
# mutation that deletes the restore SURVIVED it). So the half-application is produced directly,
# and then load is asked to clean up after it.
#
# That is not a contrived shape. It is exactly "load runs when the values are already not the
# defaults", which is why the restore reads LAB_DEFAULT_* rather than snapshotting whatever the
# variables happened to hold on entry.
half="$TMPROOT/half.conf"
printf 'SIM_DIR=/opt/sim\nKERNEL_DIR=relative\n' > "$half"
after="$( lab_config_parse "$half" >/dev/null 2>&1; printf '%s' "$SIM_DIR" )"
check "  parse alone DOES half-apply"            /opt/sim "$after"
after="$( lab_config_parse "$half" >/dev/null 2>&1
          lab_config_load "$BADCONF" >/dev/null 2>&1
          printf '%s' "$SIM_DIR" )"
check "  a half-applied file leaves no residue"  "$LAB_DEFAULT_SIM_DIR" "$after"

after="$( lab_config_load "$BADCONF" >/dev/null 2>&1; printf '%s' "$LAB_CONF_SOURCE" )"
check "  and the source says it was REFUSED"     yes "$(has "REFUSED" "$after")"

# The gate: read-only verbs survive it, acting verbs do not.
gate_rc() { ( LAB_CONF_ERROR="something is wrong"; lab_conf_gate "$1" >/dev/null 2>&1 ); echo $?; }
gate_err() { ( LAB_CONF_ERROR="something is wrong"; lab_conf_gate "$1" 2>&1 >/dev/null ); }

check "status still runs"                        0 "$(gate_rc status)"
check "config still runs"                        0 "$(gate_rc config)"
check "topo-start does NOT"                      1 "$(gate_rc topo-start)"
check "cleanup does NOT"                         1 "$(gate_rc cleanup)"
check "energy-start does NOT"                    1 "$(gate_rc energy-start)"
check "sim-stop does NOT"                        1 "$(gate_rc sim-stop)"

# Adam 2026-09-25, ruling (b) of the heartbeat round: `heartbeat stop` and `heartbeat status`
# touch only /run/ndtwin-lab -- nothing in them reads KERNEL_DIR or this file -- so a broken
# config must not lock an operator out of stopping a root daemon. `heartbeat start` stays
# fail-closed, like every other verb that starts something.
# [Co-developed with claude code -- Adam]
gate2_rc() { ( LAB_CONF_ERROR="something is wrong"; lab_conf_gate "$1" "$2" >/dev/null 2>&1 ); echo $?; }
gate2_err() { ( LAB_CONF_ERROR="something is wrong"; lab_conf_gate "$1" "$2" 2>&1 >/dev/null ); }
check "heartbeat stop still runs"                0 "$(gate2_rc heartbeat stop)"
check "heartbeat status still runs"              0 "$(gate2_rc heartbeat status)"
check "heartbeat start does NOT"                 1 "$(gate2_rc heartbeat start)"
check "heartbeat with no sub-verb does NOT"      1 "$(gate2_rc heartbeat '')"
check "heartbeat with an unknown sub-verb does NOT" 1 "$(gate2_rc heartbeat restart)"
check "  heartbeat stop still says the file was refused" yes "$(has "sudo rm /etc/ndtwin-lab.conf" "$(gate2_err heartbeat stop)")"
# The dispatch is unreachable from a sourced file (sudo always execs), so that it HANDS the gate
# the sub-verb is pinned by its text.
check "the dispatch hands the gate the sub-verb" 1 "$(grep -c '^lab_conf_gate "${1:-}" "${2:-}"$' "$LAB")"

check "the refusal is announced"                 yes "$(has "was REFUSED and is NOT in use" "$(gate_err status)")"
check "  and says how to remove the file"        yes "$(has "sudo rm /etc/ndtwin-lab.conf" "$(gate_err status)")"
check "  and says defaults are in use"           yes "$(has "built-in defaults" "$(gate_err status)")"
check "  even on the verb that dies"             yes "$(has "sudo rm /etc/ndtwin-lab.conf" "$(gate_err topo-start)")"

# Nothing is announced when there is nothing wrong -- otherwise every run would carry a banner
# and the banner would stop being read.
check "a good config prints no banner"           "" "$( LAB_CONF_ERROR=""; lab_conf_gate status 2>&1 >/dev/null )"
check "  and does not block anything"            0 "$(rc_of lab_conf_gate topo-start)"

echo "the environment still does not get a vote"

envout="$(KERNEL_DIR=/tmp/attacker LAB_CONF=/tmp/attacker.conf bash -c 'source "$1" >/dev/null 2>&1; echo "$KERNEL_DIR|$LAB_CONF"' _ "$LAB")"
check "an exported KERNEL_DIR is ignored"        "/home/adam/Desktop/NDTwin-Kernel|/etc/ndtwin-lab.conf" "$envout"

check "no 'source' of the config anywhere"       0 "$(grep -cE '^\s*(source|\.)\s+"?\$(conf|LAB_CONF)' "$LAB" || true)"

echo
if (( FAIL > 0 )); then echo "Ran $((PASS+FAIL)) checks, $FAIL failed"; exit 1; fi
echo "Ran $((PASS+FAIL)) checks, all passed"
