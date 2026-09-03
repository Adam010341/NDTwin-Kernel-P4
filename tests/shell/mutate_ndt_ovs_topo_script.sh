#!/usr/bin/env bash
#
# Mutation gate for finding #77 -- which testbed_topo.py `ndt up ovs` launches, and whether the
# sweep can still find that process afterwards.
#
# [Co-developed with claude code -- Adam]
#
# TWO SUBJECTS, because the fix is two files and either half alone leaves the bug standing:
#
#   tools/test_workflow/ndtwin-lab   which file is launched, from which directory, and which
#                                    path suffix `cleanup` reaps it by.
#   testbed_topo.py                  the interpreter bootstrap without which the launched file
#                                    dies at its first import -- an argv check cannot see that.
#
# A mutant is a whole SHADOW REPO ($BK/<label>/) holding a copy of both files and of the suite,
# because the suite finds testbed_topo.py relative to itself and reaches ndtwin-lab through
# NDTWIN_LAB_UNDER_TEST. Neither real file is ever written to, and byte-identity of both is
# asserted at the end anyway -- another session may be executing them right now.
#
# 🔴 TWO-SIDED. M1..M9 put the old behaviour back. N1..N3 are WIDENINGS -- behaviour-preserving
# rewrites (a stricter sweep pattern, the sweeps reordered and one repeated, -e for -r). Each
# must stay GREEN. A gate with only the M side signs off on a suite that pins one spelling and
# calls every equivalent implementation a regression.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG check going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every fire caught and every widening green; 1 something survived; 2 refused (harness
# fault only); 3 a subject changed underneath the gate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LAB="$REPO/tools/test_workflow/ndtwin-lab"
TOPO="$REPO/testbed_topo.py"
TEST="$REPO/tests/shell/test_ndt_ovs_topo_script.sh"
[[ -r "$LAB" && -r "$TOPO" && -r "$TEST" ]] || { echo "refused: ndtwin-lab, testbed_topo.py or the suite is missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-ovs-topo-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
BASE_LAB="$(sha256sum "$LAB" | cut -d' ' -f1)"
BASE_TOPO="$(sha256sum "$TOPO" | cut -d' ' -f1)"

CAUGHT=0; SURVIVORS=0; WIDE_OK=0

# run_suite <shadow dir> -- the suite, reading that shadow's ndtwin-lab and its testbed_topo.py.
run_suite() {
    NDTWIN_LAB_UNDER_TEST="$1/tools/test_workflow/ndtwin-lab" \
        timeout 300 bash "$1/tests/shell/test_ndt_ovs_topo_script.sh" 2>&1
}

# shadow_of <label> -- a REPO-shaped directory with both subjects and the suite in it.
shadow_of() {
    local d="$BK/$1"
    mkdir -p "$d/tools/test_workflow" "$d/tests/shell"
    cp "$LAB" "$d/tools/test_workflow/ndtwin-lab"
    cp "$TOPO" "$d/testbed_topo.py"
    cp "$TEST" "$d/tests/shell/"
    echo "$d"
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the file and which is the anchor from this
# function's own `local ... file="$2" old="$3"` line. A gate that tool cannot read is a gate it is
# not checking -- finding #28, where two gates written the same night extracted zero anchors and
# nobody would have known. (Three gates in this directory still read NO-ANCHORS today, among them
# mutate_ndt_up_target.sh, whose `cat > $A/m1.old` heredoc form this one deliberately avoids.)
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d target
    d="$(shadow_of "$label")"
    case "${file##*/}" in
        ndtwin-lab) target="$d/tools/test_workflow/ndtwin-lab" ;;
        *)          target="$d/${file##*/}" ;;
    esac
    python3 - "$target" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(a) != 1:
    sys.stderr.write("anchor not unique (%d hits): %s\n" % (s.count(a), a[:70]))
    sys.exit(3)
open(p, "w").write(s.replace(a, b, 1))
PY
    [[ $? -eq 0 ]] || { echo "ANCHOR-FAILED"; return 0; }
    echo "$d"
}

report() {   # $1 = label, $2 = shadow dir, $3 = the check that MUST go red
    local out rc
    if [[ "$2" == ANCHOR-FAILED ]]; then
        printf '  SURVIVED %-56s (anchor did not apply -- not a skip)\n' "$1"
        SURVIVORS=$((SURVIVORS+1)); return
    fi
    out="$(run_suite "$2")"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  SURVIVED %-56s (suite stayed green -- that case proves nothing)\n' "$1"
        SURVIVORS=$((SURVIVORS+1)); return
    fi
    if grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$1" "$3"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-56s (red, but NOT on the named check)\n' "$1"
        grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS+1))
    fi
}

report_green() {   # $1 = label, $2 = shadow dir -- a widening: it must stay GREEN
    local out rc
    if [[ "$2" == ANCHOR-FAILED ]]; then
        printf '  SURVIVED %-56s (anchor did not apply -- not a skip)\n' "$1"
        SURVIVORS=$((SURVIVORS+1)); return
    fi
    out="$(run_suite "$2")"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-56s (behaviour-preserving, as it must be)\n' "$1"
        WIDE_OK=$((WIDE_OK+1))
    else
        printf '  SURVIVED %-56s (an equivalent implementation is called a regression)\n' "$1"
        grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS+1))
    fi
}

echo "baseline (the shadow harness, unmutated -- must be green before any mutation):"
# Its own baseline, not the repo's: if the shadow were broken, every mutation below would look
# caught because the instrument is broken rather than because it saw anything.
base="$(shadow_of base)"
run_suite "$base" | tail -1 | sed 's/^/  /'
run_suite "$base" >/dev/null 2>&1 || { echo "  refused: the shadow baseline is RED"; run_suite "$base" | grep FAILED | head -5; exit 2; }
echo

echo "fires -- the old behaviour must not come back:"

m=$(mutant m1 "$LAB" \
    "ovs_topo_script() { printf '%s/testbed_topo.py' \"\$KERNEL_DIR\"; }" \
    "ovs_topo_script() { printf '/home/adam/Network-Traffic-Generator/testbed_topo.py'; }")
report "M1: the launch names NTG's testbed_topo.py again" "$m" \
       "the topology comes from the kernel tree"

# Half a revert is the interesting one: the script argument is still ours, so a check that read
# only the last argv element would pass while tmux ran it from another repo's tree.
m=$(mutant m2 "$LAB" \
    "    \$TMUX new-session -d -s topo -c \"\$KERNEL_DIR\" \"\$NTG_PY\" \"\$script\"" \
    "    \$TMUX new-session -d -s topo -c /home/adam/Network-Traffic-Generator \"\$NTG_PY\" \"\$script\"")
report "M2: the tmux working directory goes back to NTG" "$m" \
       "tmux's working directory is the tree"

# The silent half: with the pattern left behind, `ndt down` reports a clean machine over a live
# 128-host fabric.
m=$(mutant m3 "$LAB" \
    "ovs_topo_pattern() { printf '%s/testbed_topo.py' \"\${KERNEL_DIR##*/}\"; }" \
    "ovs_topo_pattern() { printf 'Network-Traffic-Generator/testbed_topo.py'; }")
report "M3: cleanup keeps sweeping the OLD path suffix" "$m" \
       "cleanup's pattern matches the launched argv"

m=$(mutant m4 "$LAB" \
    "    [[ -r \"\$script\" ]] || die \"no readable OVS topology at \$script" \
    "    [[ -r /dev/null ]] || die \"no readable OVS topology at \$script")
report "M4: a missing topology starts an empty window anyway" "$m" \
       "rc is non-zero"

# Passes every check that only asks "is it the repo's file" on a default install, and puts
# FINDING-01's shape back: two places that name a tree, no message when they disagree.
m=$(mutant m5 "$LAB" \
    "ovs_topo_script() { printf '%s/testbed_topo.py' \"\$KERNEL_DIR\"; }" \
    "ovs_topo_script() { printf '/home/adam/Desktop/NDTwin-Kernel/testbed_topo.py'; }")
report "M5: the path is a second constant, not the configured tree" "$m" \
       "a different KERNEL_DIR moves the script"

# "Existence is not wiring": every function-level check stays green while the verb root actually
# reaches runs the old launch. That is exactly the shape finding #77 had.
m=$(mutant m6 "$LAB" \
    "        ovs_topo_start" \
    "        \$TMUX new-session -d -s topo -c /home/adam/Network-Traffic-Generator \"\$NTG_PY\" /home/adam/Network-Traffic-Generator/testbed_topo.py")
report "M6: the verb inlines the old launch again" "$m" \
       "the ovs-topo-start branch launches that file"

m=$(mutant m7 "$LAB" \
    "        sweep_kill \"OVS testbed_topo\" \"\$(ovs_topo_pattern)\" || rc=1" \
    "        :")
report "M7: cleanup stops sweeping the file it starts" "$m" \
       "cleanup sweeps the pattern the launch uses"

m=$(mutant m8 "$LAB" \
    "        sweep_kill \"NTG testbed_topo\" \"Network-Traffic-Generator/testbed_topo.py\" || rc=1" \
    "        :")
report "M8: cleanup stops reaping NTG orphans from old rounds" "$m" \
       "  and still sweeps the NTG suffix (orphans)"

# The other half of the fix. Without this line the argv is perfect and the process dies at its
# first import; /usr/local/lib/python3/dist-packages alone does not carry mininet (measured).
m=$(mutant m9 "$TOPO" \
    "sys.path.append('/usr/lib/python3/dist-packages')" \
    "pass  # interpreter bootstrap removed")
report "M9: testbed_topo.py loses its interpreter bootstrap" "$m" \
       "it imports under"

echo
echo "widenings -- behaviour-preserving rewrites that must stay green:"

m=$(mutant n1 "$LAB" \
    "ovs_topo_pattern() { printf '%s/testbed_topo.py' \"\${KERNEL_DIR##*/}\"; }" \
    "ovs_topo_pattern() { printf '%s/testbed_topo.py' \"\${KERNEL_DIR#/}\"; }")
report_green "N1 (widening): the sweep pattern is the full path suffix" "$m"

m=$(mutant n2 "$LAB" \
    "        sweep_kill \"OVS testbed_topo\" \"\$(ovs_topo_pattern)\" || rc=1" \
    "        sweep_kill \"NTG orphans first\" \"Network-Traffic-Generator/testbed_topo.py\" || rc=1
        sweep_kill \"OVS testbed_topo\" \"\$(ovs_topo_pattern)\" || rc=1")
report_green "N2 (widening): the sweeps reordered and one repeated" "$m"

m=$(mutant n3 "$LAB" \
    "    [[ -r \"\$script\" ]] || die \"no readable OVS topology at \$script" \
    "    [[ -e \"\$script\" ]] || die \"no readable OVS topology at \$script")
report_green "N3 (widening): the refusal tests -e rather than -r" "$m"

echo
NOW_LAB="$(sha256sum "$LAB" | cut -d' ' -f1)"
NOW_TOPO="$(sha256sum "$TOPO" | cut -d' ' -f1)"
[[ "$NOW_LAB" == "$BASE_LAB" ]] || { echo "🔴 baseline CHANGED -- ndtwin-lab was written during the gate"; exit 3; }
[[ "$NOW_TOPO" == "$BASE_TOPO" ]] || { echo "🔴 baseline CHANGED -- testbed_topo.py was written during the gate"; exit 3; }
echo "baselines byte-identical: yes (tools/test_workflow/ndtwin-lab, testbed_topo.py)"
echo "mutation gate: $((CAUGHT+SURVIVORS+WIDE_OK)) mutations, $CAUGHT caught, $WIDE_OK widenings green, $SURVIVORS survived"
[[ $SURVIVORS -eq 0 ]]
