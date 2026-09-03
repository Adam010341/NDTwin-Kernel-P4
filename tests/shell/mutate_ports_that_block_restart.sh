#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ports_that_block_restart.sh.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation restores one piece of the defect the port table replaces, and must turn its
# named case red. A mutation nobody catches means that case proves nothing.
#
# 🔴 Not one of these mutations is caught by holding :8000, :8080 or :8081. That is the point:
# the previous discrimination check for this code was validated by holding :8081 -- one of the
# three the broken version already covered -- so it could not have failed. M3 and M8 are only
# observable on a port outside those three, and M3 only on a UDP one.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is
# pointed at them with PORTS_UNDER_TEST / NDT_UNDER_TEST. tools/test_workflow/{ports.sh,ndt}
# are never written -- another session may be executing them right now.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORTS="$REPO/tools/test_workflow/ports.sh"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ports_that_block_restart.sh"
BK=$(mktemp -d /tmp/ports-mutate-XXXXXX)
trap 'rm -rf "$BK"' EXIT
BASE_PORTS=$(sha256sum "$PORTS" | cut -d' ' -f1)
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() { PORTS_UNDER_TEST="$1/ports.sh" NDT_UNDER_TEST="$1/ndt" timeout 300 bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $3" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole directory: ndt sources ports.sh from beside itself, so both files travel
# together and a mutation to either is exercised through the real seam.
mutant() {   # $1 = name, $2 = file to mutate (ports.sh|ndt), $3 = "old<US>new"; prints the dir
    local d="$BK/$1"; mkdir -p "$d"
    cp "$PORTS" "$d/ports.sh"; cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    python3 - "$d/$2" "$3" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
a, b = spec.split("\x1f")
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; cp "$PORTS" "$base/ports.sh"; cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the table's content: rows that used to live in comments -------------------------------
m=$(mutant m1 ports.sh "$(printf '6343|udp|both\x1fNOPE-6343|udp|both')")
report "M1: drop the sFlow row (the 09-02 incident's own port)" "$m" \
       "6343 is in the table AND declared udp (the 09-02 incident)"

m=$(mutant m2 ports.sh "$(printf '\n6633|tcp|ovs\x1f\nNOPE-6633|tcp|ovs')")
report "M2: cover 6653 but not 6633 (the half-fix)" "$m" \
       "BOTH 6653 and 6633 are rows (the probe order reaches both)"

m=$(mutant m3 ports.sh "$(printf '30051-30060|tcp|p4\x1fNOPE|tcp|p4')")
report "M3: drop the bmv2 gRPC block (ndt:635's comment, unexecuted)" "$m" \
       "the bmv2 gRPC block is a row (ndt:635 said :3005x in a comment)"

# --- the proto column: the reason :6343 was invisible even to a check that looked -----------
m=$(mutant m4 ports.sh "$(printf 'if [[ "$proto" == udp ]]; then\n        command -v ss\x1fif false; then\n        command -v ss')")
report "M4: ndt_port_open ignores proto (TCP-only, the original probe)" "$m" \
       "injection took effect: something really is holding udp :45902"

# --- the residue report: holder and consequence, not a count -------------------------------
m=$(mutant m5 ports.sh "$(printf "printf 'residue: %%s holding :%%s (%%s)\\\\n' \"\$(ndt_port_holder \"\$port\" \"\$proto\")\"\x1fprintf 'residue: 1 listener on :%%s (%%s)\\\\n' \"\"")")
report "M5: residue prints a count instead of naming the holder" "$m" \
       "the residue line names the HOLDER by pid, not a count"

m=$(mutant m6 ports.sh "$(printf "            printf '         -> if something else holds it: %%s\\\\n' \"\$consequence\"\n\x1f")")
report "M6: residue drops the consequence column" "$m" \
       "the residue line states the consequence from the row"

# --- ranges ---------------------------------------------------------------------------------
m=$(mutant m7 ports.sh "$(printf 'if [[ "$spec" == *-* ]]; then\x1fif false; then')")
report "M7: ranges are not expanded (30051-30060 stays a string)" "$m" \
       "30051-30060 expands to all ten device ports"

# --- zero-discrimination guard ---------------------------------------------------------------
# If residue reported unconditionally, every "it caught the holder" case above would pass
# against a function that never looked. The free-port control is what forbids that.
m=$(mutant m8 ports.sh "$(printf '                *) continue ;;\x1f                *) : ;;')")
report "M8: residue reports whether or not the port is held" "$m" \
       "a free port produces no residue and returns 0"

# --- the wiring: cmd_clean must READ the table, not keep a copy -------------------------------
m=$(mutant m9 ndt "$(printf 'residue="$(ndt_port_residue all)"; local prc=$?\x1fresidue=""; local prc=0')")
report "M9: cmd_clean stops reading the table (its own list again)" "$m" \
       "cmd_clean's port residue comes from the shared table function"

echo
[[ "$(sha256sum "$PORTS" | cut -d' ' -f1)" == "$BASE_PORTS" ]] || { echo "🔴 baseline CHANGED -- ports.sh was written during the gate"; exit 3; }
[[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_NDT" ]] || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (ports.sh and ndt)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
