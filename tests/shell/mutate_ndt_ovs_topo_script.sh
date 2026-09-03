#!/usr/bin/env bash
#
# Mutation gate for finding #77 -- which testbed_topo.py `ndt up ovs` launches, and whether the
# sweep can still find it afterwards.
#
# Shape from tests/shell/mutate_ndt_up_target.sh: anchors travel as FILES, never as shell words,
# and a mutant is a whole COPY. Neither real file is ever written to, and byte-identity of both
# is asserted at the end anyway.
#
# TWO SUBJECTS, because the fix is two files and either half alone leaves the bug standing:
#   * tools/test_workflow/ndtwin-lab -- which file is launched, and which pattern reaps it.
#     A mutant is a copy pointed at by NDTWIN_LAB_UNDER_TEST.
#   * testbed_topo.py -- the interpreter bootstrap without which the launched file dies at its
#     first import. A mutant is a SHADOW REPO ($BK/<name>/{testbed_topo.py,tests/shell/<suite>}),
#     because the suite finds that file relative to itself.
#
# 🔴 TWO-SIDED. M1..M9 put the old behaviour back. N1..N3 are WIDENINGS -- behaviour-preserving
# rewrites (a stricter sweep pattern, the sweeps reordered, -e for -r). Each must stay GREEN. A
# gate with only the M side signs off on a suite that pins one spelling and calls every equivalent
# implementation a regression.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG check going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation caught and every widening green, 1 something survived, 2 refused
# (harness fault only), 3 a subject changed underneath the gate.
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LAB="$REPO/tools/test_workflow/ndtwin-lab"
TOPO="$REPO/testbed_topo.py"
TEST="$REPO/tests/shell/test_ndt_ovs_topo_script.sh"
[[ -r "$LAB" && -r "$TOPO" && -r "$TEST" ]] || { echo "refused: ndtwin-lab, testbed_topo.py or the suite is missing"; exit 2; }

BK="$(mktemp -d)"; trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
LAB_SUM="$(sha256sum "$LAB" | cut -d' ' -f1)"
TOPO_SUM="$(sha256sum "$TOPO" | cut -d' ' -f1)"

# apply <src> <dst> <name> -- copy src to dst with A/<name>.{old,new} applied once.
# Prints the destination, or ANCHOR:<count> when the anchor is not unique.
apply() {
    local src="$1" dst="$2" name="$3"
    cp "$src" "$dst"
    python3 - "$dst" "$A/$name.old" "$A/$name.new" <<'PY'
import sys, io
target, oldf, newf = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(target, encoding='utf-8').read()
o = io.open(oldf, encoding='utf-8').read()
n = io.open(newf, encoding='utf-8').read()
c = s.count(o)
if c != 1:
    print("ANCHOR:%d" % c); sys.exit(0)
io.open(target, 'w', encoding='utf-8').write(s.replace(o, n, 1))
print(target)
PY
}

# run_suite <lab> <repo-root-holding-the-suite> -- the suite's output
run_suite() {
    NDTWIN_LAB_UNDER_TEST="$1" timeout 300 bash "$2/tests/shell/test_ndt_ovs_topo_script.sh" 2>&1
}

# shadow <name> -- a REPO-shaped directory whose testbed_topo.py is the mutant (or the original)
shadow() {
    local name="$1" d="$BK/$name.repo"
    mkdir -p "$d/tests/shell"
    cp "$TEST" "$d/tests/shell/"
    echo "$d"
}

echo "baseline (both subjects unmutated -- must be green before any mutation):"
base_out="$(run_suite "$LAB" "$REPO")"; base_rc=$?
echo "$base_out" | tail -1 | sed 's/^/  /'
[[ $base_rc -eq 0 ]] || { echo "refused: baseline is not green"; echo "$base_out" | grep FAILED | head -5; exit 2; }

# The shadow harness has its own baseline. Without this, every topo mutant below could be
# "caught" because the shadow is broken rather than because the mutation was seen -- the
# instrument agreeing with itself.
sd="$(shadow base)"; cp "$TOPO" "$sd/testbed_topo.py"
sh_out="$(run_suite "$LAB" "$sd")"; sh_rc=$?
echo "$sh_out" | tail -1 | sed 's/^/  shadow: /'
[[ $sh_rc -eq 0 ]] || { echo "refused: the shadow-repo harness is not green with an UNMUTATED testbed_topo.py"; echo "$sh_out" | grep FAILED | head -5; exit 2; }
echo

caught=0; survived=0; widened_ok=0

fire() {   # <label> <name> <subject: lab|topo> <the check text that MUST go red>
    local label="$1" name="$2" subject="$3" want="$4" d out rc lab_use repo_use
    if [[ "$subject" == lab ]]; then
        d="$(apply "$LAB" "$BK/$name.lab" "$name")"; lab_use="$d"; repo_use="$REPO"
    else
        repo_use="$(shadow "$name")"
        d="$(apply "$TOPO" "$repo_use/testbed_topo.py" "$name")"; lab_use="$LAB"
    fi
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  SURVIVED %-56s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        survived=$((survived+1)); return
    fi
    out="$(run_suite "$lab_use" "$repo_use")"; rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-56s (suite still green)\n' "$label"; survived=$((survived+1)); return
    fi
    if echo "$out" | grep -qF "FAILED   $want"; then
        printf '  caught   %-56s (%s went red)\n' "$label" "$want"; caught=$((caught+1))
    else
        printf '  SURVIVED %-56s (red, but NOT on the named check)\n' "$label"
        echo "$out" | grep 'FAILED' | head -3 | sed 's/^/             /'
        survived=$((survived+1))
    fi
}

widen() {  # <label> <name> <subject> -- a behaviour-preserving rewrite that must stay GREEN
    local label="$1" name="$2" subject="$3" d out rc lab_use repo_use
    if [[ "$subject" == lab ]]; then
        d="$(apply "$LAB" "$BK/$name.lab" "$name")"; lab_use="$d"; repo_use="$REPO"
    else
        repo_use="$(shadow "$name")"
        d="$(apply "$TOPO" "$repo_use/testbed_topo.py" "$name")"; lab_use="$LAB"
    fi
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  SURVIVED %-56s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        survived=$((survived+1)); return
    fi
    out="$(run_suite "$lab_use" "$repo_use")"; rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '  green    %-56s (behaviour-preserving, as it must be)\n' "$label"
        widened_ok=$((widened_ok+1))
    else
        printf '  SURVIVED %-56s (the suite calls an equivalent implementation a regression)\n' "$label"
        echo "$out" | grep 'FAILED' | head -3 | sed 's/^/             /'
        survived=$((survived+1))
    fi
}

echo "fires -- the old behaviour must not come back:"

# ---- M1: the launch names NTG's file again (the finding itself) ---------------------------
cat > "$A/m1.old" <<'EOF'
ovs_topo_script() { printf '%s/testbed_topo.py' "$KERNEL_DIR"; }
EOF
cat > "$A/m1.new" <<'EOF'
ovs_topo_script() { printf '/home/adam/Network-Traffic-Generator/testbed_topo.py'; }
EOF
fire "M1: the launch names NTG's testbed_topo.py again" m1 lab "the topology comes from the kernel tree"

# ---- M2: only the working directory goes back -----------------------------------------------
# Half a revert is the interesting one: the script argument is still ours, so an argv check that
# looked only at the last element would pass while tmux ran it from another repo's tree.
cat > "$A/m2.old" <<'EOF'
    $TMUX new-session -d -s topo -c "$KERNEL_DIR" "$NTG_PY" "$script"
EOF
cat > "$A/m2.new" <<'EOF'
    $TMUX new-session -d -s topo -c /home/adam/Network-Traffic-Generator "$NTG_PY" "$script"
EOF
fire "M2: the tmux working directory goes back to NTG" m2 lab "tmux's working directory is the tree"

# ---- M3: the sweep pattern is left behind ---------------------------------------------------
# The silent half: `ndt down` reports a clean machine over a live 128-host fabric.
cat > "$A/m3.old" <<'EOF'
ovs_topo_pattern() { printf '%s/testbed_topo.py' "${KERNEL_DIR##*/}"; }
EOF
cat > "$A/m3.new" <<'EOF'
ovs_topo_pattern() { printf 'Network-Traffic-Generator/testbed_topo.py'; }
EOF
fire "M3: cleanup keeps sweeping the OLD path suffix" m3 lab "cleanup's pattern matches the launched argv"

# ---- M4: the refusal is dropped -------------------------------------------------------------
cat > "$A/m4.old" <<'EOF'
    [[ -r "$script" ]] || die "no readable OVS topology at $script
  KERNEL_DIR is $KERNEL_DIR ($LAB_CONF_SOURCE).
  This is the file components.env calls OVS_TOPO_SCRIPT and stack.sh prints for the operator."
EOF
cat > "$A/m4.new" <<'EOF'
    :
EOF
fire "M4: a missing topology starts an empty window anyway" m4 lab "rc is non-zero"

# ---- M5: derived becomes constant -----------------------------------------------------------
# Passes every check that only asks "is it the repo's file" on a default install, and reintroduces
# FINDING-01's shape: two places that name a tree, no message when they disagree.
cat > "$A/m5.old" <<'EOF'
ovs_topo_script() { printf '%s/testbed_topo.py' "$KERNEL_DIR"; }
EOF
cat > "$A/m5.new" <<'EOF'
ovs_topo_script() { printf '/home/adam/Desktop/NDTwin-Kernel/testbed_topo.py'; }
EOF
fire "M5: the path is a second constant, not the configured tree" m5 lab "a different KERNEL_DIR moves the script"

# ---- M6: the verb stops calling what was tested ---------------------------------------------
# "Existence is not wiring": every function-level check stays green while the verb root reaches
# runs the old launch. This is the exact shape finding #77 had.
cat > "$A/m6.old" <<'EOF'
        ovs_topo_start
        ;;
EOF
cat > "$A/m6.new" <<'EOF'
        $TMUX new-session -d -s topo -c /home/adam/Network-Traffic-Generator \
            "$NTG_PY" /home/adam/Network-Traffic-Generator/testbed_topo.py
        ;;
EOF
fire "M6: the verb inlines the old launch again" m6 lab "the ovs-topo-start branch launches that file"

# ---- M7/M8: cleanup loses one of its two topology sweeps ------------------------------------
cat > "$A/m7.old" <<'EOF'
        sweep_kill "OVS testbed_topo" "$(ovs_topo_pattern)" || rc=1
EOF
cat > "$A/m7.new" <<'EOF'
        :
EOF
fire "M7: cleanup stops sweeping the file it starts" m7 lab "cleanup sweeps the pattern the launch uses"

cat > "$A/m8.old" <<'EOF'
        sweep_kill "NTG testbed_topo" "Network-Traffic-Generator/testbed_topo.py" || rc=1
EOF
cat > "$A/m8.new" <<'EOF'
        :
EOF
fire "M8: cleanup stops reaping NTG orphans from old rounds" m8 lab "  and still sweeps the NTG suffix (orphans)"

# ---- M9: the launched file can no longer be launched ----------------------------------------
# The other half of the fix. Without these two lines the argv above is perfect and the process
# dies at its first import -- which no argv check can see.
cat > "$A/m9.old" <<'EOF'
sys.path.append('/usr/lib/python3/dist-packages')
sys.path.append('/usr/local/lib/python3/dist-packages')
EOF
cat > "$A/m9.new" <<'EOF'
pass
EOF
fire "M9: testbed_topo.py loses its interpreter bootstrap" m9 topo "it imports under"

echo
echo "widenings -- behaviour-preserving rewrites that must stay green:"

# ---- N1: a STRICTER sweep pattern (full path suffix instead of two components) --------------
cat > "$A/n1.old" <<'EOF'
ovs_topo_pattern() { printf '%s/testbed_topo.py' "${KERNEL_DIR##*/}"; }
EOF
cat > "$A/n1.new" <<'EOF'
ovs_topo_pattern() { printf '%s/testbed_topo.py' "${KERNEL_DIR#/}"; }
EOF
widen "N1 (widening): the sweep pattern is the full path suffix" n1 lab

# ---- N2: the two topology sweeps in the other order -----------------------------------------
cat > "$A/n2.old" <<'EOF'
        sweep_kill "OVS testbed_topo" "$(ovs_topo_pattern)" || rc=1
EOF
cat > "$A/n2.new" <<'EOF'
        sweep_kill "NTG testbed_topo" "Network-Traffic-Generator/testbed_topo.py" || rc=1
        sweep_kill "OVS testbed_topo" "$(ovs_topo_pattern)" || rc=1
        sweep_kill "a harmless duplicate" "$(ovs_topo_pattern)" || rc=1
EOF
widen "N2 (widening): the sweeps reordered and one repeated" n2 lab

# ---- N3: -e instead of -r in the refusal ----------------------------------------------------
cat > "$A/n3.old" <<'EOF'
    [[ -r "$script" ]] || die "no readable OVS topology at $script
EOF
cat > "$A/n3.new" <<'EOF'
    [[ -e "$script" ]] || die "no readable OVS topology at $script
EOF
widen "N3 (widening): the refusal tests -e rather than -r" n3 lab

echo
NOW_LAB="$(sha256sum "$LAB" | cut -d' ' -f1)"
NOW_TOPO="$(sha256sum "$TOPO" | cut -d' ' -f1)"
[[ "$NOW_LAB" == "$LAB_SUM" ]] || { echo "🔴 baseline CHANGED -- ndtwin-lab was written during the gate"; exit 3; }
[[ "$NOW_TOPO" == "$TOPO_SUM" ]] || { echo "🔴 baseline CHANGED -- testbed_topo.py was written during the gate"; exit 3; }
echo "baselines byte-identical: yes (tools/test_workflow/ndtwin-lab, testbed_topo.py)"
echo "mutation gate: $((caught+survived+widened_ok)) mutations, $caught caught, $widened_ok widenings green, $survived survived"
[[ $survived -eq 0 ]]
