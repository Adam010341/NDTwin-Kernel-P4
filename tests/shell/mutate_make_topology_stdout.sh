#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_make_topology_stdout_is_json.sh (L-9).
#
# [Co-developed with claude code -- Adam]
#
#   M1  the report goes to stdout again (the original defect)   -> case 2 (stdout is JSON)
#   M2  the report goes to stderr ALWAYS                        -> case 5 (--check unchanged)
#   M3  --stdout suppresses the report instead of moving it     -> case 4 (the report survives)
#
# M2 and M3 are the two wrong fixes that make case 2 green on their own, which is why the test
# states three directions rather than one.
#
# 🔴 Guards its own baseline AND the repo's setting/: each mutant is a copy in a temp tree whose
# `setting/` holds SYMLINKS to the two shipped models, so the mutant computes the same REPO-
# relative paths (make_topology.py derives REPO from __file__) while a stray write would land in
# the temp tree. tools/make_topology.py itself is never written -- another session may run it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOOL="$REPO/tools/make_topology.py"
TEST="$HERE/test_make_topology_stdout_is_json.sh"
BK="$(mktemp -d /tmp/make-topo-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$TOOL" | cut -d' ' -f1)"

SURVIVORS=0
run_against() { MAKE_TOPOLOGY_UNDER_TEST="$1" bash "$TEST" 2>&1; }
report() {   # $1 = name, $2 = mutant path, $3 = case that must go red
    local out rc
    out="$(run_against "$2")"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $3" <<<"$out"; then
        printf '  caught   %-54s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-54s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}
mutant() {   # $1 = name, $2 = old text, $3 = new text; prints the path to the mutated copy
    # 2026-09-04: `name`/`old`/`new` are read nowhere below ($1/$2/$3 are used directly, as
    # before) -- they exist only so tests/shell/check_gate_anchors.py's role-based reading can
    # see that argument 2 is the anchor text, the same way every OTHER hand-rolled applier in
    # this repo names its own roles. The file itself stays baked into this function's body
    # ($TOOL, a few lines down) and is picked up the same way it always was.
    local name="$1" old="$2" new="$3"
    local d="$BK/$1"
    mkdir -p "$d/tools" "$d/setting"
    ln -sf "$REPO/setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json" "$d/setting/"
    ln -sf "$REPO/setting/StaticNetworkTopologyMininet_10Switches.json"    "$d/setting/"
    cp "$TOOL" "$d/tools/make_topology.py"
    python3 - "$d/tools/make_topology.py" "$2" "$3" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor is not unique (%d hits): %r" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d/tools/make_topology.py"
}

echo "baseline (must be green before any mutation):"
# The baseline runs against a mutant-shaped copy with NO mutation, so a failure of the temp-tree
# scaffolding cannot be mistaken for a caught mutation later.
base="$(mutant base 'report = sys.stderr if args.stdout else sys.stdout' \
                    'report = sys.stderr if args.stdout else sys.stdout')"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

m1=$(mutant m1 'report = sys.stderr if args.stdout else sys.stdout' 'report = sys.stdout')
report "M1: the report goes to stdout again (the original defect)" "$m1" \
       "case 2  --stdout writes a parseable model to stdout (8 hosts: 10 switches + 8 hosts, 48 edges)"

m2=$(mutant m2 'report = sys.stderr if args.stdout else sys.stdout' 'report = sys.stderr')
report "M2: the report goes to stderr unconditionally" "$m2" \
       "case 5  without --stdout the report still goes to stdout (--check unchanged)"

m3=$(mutant m3 'report = sys.stderr if args.stdout else sys.stdout' \
               'report = open("/dev/null", "w") if args.stdout else sys.stdout')
report "M3: --stdout suppresses the report instead of moving it" "$m3" \
       "case 4  the round-trip report IS on stderr (not deleted -- it carries the refusal too)"

echo
[[ "$(sha256sum "$TOOL" | cut -d' ' -f1)" == "$BASE_SHA" ]] \
    && echo "baseline byte-identical: yes" \
    || { echo "🔴 baseline CHANGED -- tools/make_topology.py was written during the gate"; exit 3; }
if [[ "$SURVIVORS" -eq 0 ]]; then echo "mutation gate: 3 mutations, 0 survived"; exit 0
else echo "mutation gate: $SURVIVORS survived"; exit 1; fi
