#!/usr/bin/env bash
#
# Mutation gate for `ndt up`'s argument resolution (the default plane change of 2026-09-03).
#
# Shape from tests/shell/mutate_build_guard.sh: anchors travel as FILES, never as shell words,
# and a mutant is a whole copy of `ndt` pointed at by NDT_UNDER_TEST. The real file is never
# written to, and byte-identity is asserted at the end anyway.
#
# 🔴 TWO-SIDED. M1..M5 put the old behaviour back. N1..N3 are WIDENINGS -- resolvers that say
# OVS to everything, or refuse everything. Each of those passes every "the default is OVS"
# check and would leave the lab either unable to start P4 or unable to start at all, so a gate
# with only the M mutations would sign off on both.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG check going red counts
# as SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (harness fault only).
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$REPO/tests/shell/test_ndt_up_target.sh"
[[ -r "$NDT" && -x "$TEST" ]] || { echo "refused: ndt or test missing"; exit 2; }

BK="$(mktemp -d)"; trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
# 2026-09-03 merge: ndt sources ports.sh and sudo_surface.sh from beside itself, so every copy
# in $BK needs both tables next to it or it exits at source time -- silently, because the suite
# sources it with output discarded, and every mutant then reads "red, but NOT on the named check".
cp "$(dirname "$NDT")/ports.sh" "$(dirname "$NDT")/sudo_surface.sh" "$BK/"
BASE_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"

mutant() {   # <name> -- copies ndt, applies A/<name>.{old,new}; prints the copy or ANCHOR:n
    local name="$1" d="$BK/$name.ndt"
    cp "$NDT" "$d"
    python3 - "$d" "$A/$name.old" "$A/$name.new" <<'PY'
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

echo "baseline (must be green before any mutation):"
base_out="$(NDT_UNDER_TEST="$NDT" timeout 120 bash "$TEST" 2>&1)"; base_rc=$?
echo "$base_out" | tail -1 | sed 's/^/  /'
[[ $base_rc -eq 0 ]] || { echo "refused: baseline is not green"; exit 2; }
echo

caught=0; survived=0
check() {   # <label> <name> <the check text that MUST go red>
    local label="$1" name="$2" want="$3" d
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  SURVIVED %-54s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        survived=$((survived+1)); return
    fi
    local out rc
    out="$(NDT_UNDER_TEST="$d" timeout 120 bash "$TEST" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-54s (suite still green)\n' "$label"; survived=$((survived+1)); return
    fi
    if echo "$out" | grep -qF "FAILED   $want"; then
        printf '  caught   %-54s (%s went red)\n' "$label" "$want"; caught=$((caught+1))
    else
        printf '  SURVIVED %-54s (red, but NOT on the named check)\n' "$label"
        echo "$out" | grep 'FAILED' | head -3 | sed 's/^/             /'
        survived=$((survived+1))
    fi
}

# ---- fires: the old behaviour must not come back -----------------------------------------
cat > "$A/m1.old" <<'EOF'
    case "${1:-ovs}" in
EOF
cat > "$A/m1.new" <<'EOF'
    case "${1:-p4}" in
EOF
check "M1: the default plane goes back to p4" m1 "a bare 'ndt up' is OVS, not P4"

cat > "$A/m2.old" <<'EOF'
        ovs)    printf 'up_ovs %s\n' "${2:-128}" ;;
EOF
cat > "$A/m2.new" <<'EOF'
        ovs)    printf 'up_ovs %s\n' "${2:-4}" ;;
EOF
check "M2: the OVS default size changes to 4" m2 "and it is the 128-host fabric"

cat > "$A/m3.old" <<'EOF'
        4)      printf 'up_ovs 4\n'              ;;
EOF
cat > "$A/m3.new" <<'EOF'
        4)      printf 'up_p4 4\n'               ;;
EOF
check "M3: a bare 4 goes back to meaning P4" m3 "'ndt up 4' is OVS at 4 (it used to be P4)"

cat > "$A/m4.old" <<'EOF'
        [0-9]*) return 2                          ;;
EOF
cat > "$A/m4.new" <<'EOF'
        [0-9]*) printf 'up_ovs %s\n' "$1"         ;;
EOF
check "M4: a size OVS cannot build is accepted anyway" m4 "🔴 a size OVS cannot build is refused"

cat > "$A/m5.old" <<'EOF'
        ovs4)   printf 'up_ovs 4\n'              ;;
EOF
cat > "$A/m5.new" <<'EOF'
        ovs4)   printf 'up_ovs 128\n'            ;;
EOF
check "M5: ovs4 stops meaning 4" m5 "'ndt up ovs4' is the 4-host layout"

# ---- spares: widenings that pass every M-side check above --------------------------------
cat > "$A/n1.old" <<'EOF'
        p4)     printf 'up_p4 %s\n'  "${2:-}"    ;;
EOF
cat > "$A/n1.new" <<'EOF'
        p4)     printf 'up_ovs 128\n'            ;;
EOF
check "N1 (widening): everything answers OVS, P4 unreachable" n1 "'ndt up p4' keeps the current host count"

cat > "$A/n2.old" <<'EOF'
        p4)     printf 'up_p4 %s\n'  "${2:-}"    ;;
        ovs)    printf 'up_ovs %s\n' "${2:-128}" ;;
EOF
cat > "$A/n2.new" <<'EOF'
        p4)     return 2                          ;;
        ovs)    printf 'up_ovs %s\n' "${2:-128}" ;;
EOF
check "N2 (widening): P4 is refused rather than built" n2 "P4 is rc 0, not a refusal"

cat > "$A/n3.old" <<'EOF'
        ovs4)   printf 'up_ovs 4\n'              ;;
        # A bare number follows the default plane, so it is a size, not a plane. up_ovs builds
EOF
cat > "$A/n3.new" <<'EOF'
        ovs4)   return 2                          ;;
        # A bare number follows the default plane, so it is a size, not a plane. up_ovs builds
EOF
check "N3 (widening): ovs4 is refused, so the lab cannot start small" n3 "'ndt up ovs4' is rc 0"

echo
NOW_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"
[[ "$NOW_SUM" == "$BASE_SUM" ]] || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (tools/test_workflow/ndt)"
echo "mutation gate: $((caught+survived)) mutations, $survived survived"
[[ $survived -eq 0 ]]
