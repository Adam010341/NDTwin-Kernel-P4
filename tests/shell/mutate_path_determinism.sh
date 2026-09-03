#!/usr/bin/env bash
#
# Mutation gate for the deterministic path tie-break (round 5 P3/P5, 2026-09-03).
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. Worse here than usual: the defect
# being fixed is a *coin flip*, so a test written against it passes roughly half the time by
# luck. Each mutation below puts one specific wrong tie-break back and this records WHICH test
# went red -- naming the test matters, because "something failed" would be satisfied by the
# suite falling over on an import error.
#
# Mutations, and what each one is meant to catch:
#
#   M1  canonical_path -> nx.shortest_path            the original defect, in the renderer
#   M2  calculate_all_paths -> nx.shortest_path       the original defect, in the route installer
#   M3  digest tie-break -> lowest node token         deterministic, but collapses onto one uplink
#   M4  hop rank keyed on the source as well          advertised path stops matching the rules
#   M5  blake2b -> builtin hash()                     stable in-process, moves with PYTHONHASHSEED
#
# 🔴 A mutant that does not import, or that reddens a test other than the one named, counts as
# SURVIVED. Every way of not-proving-it is counted the same way.
#
# 🔴 Guards its own baseline: snapshots before the first mutation, an EXIT trap restores on any
# exit, and the run asserts byte-identity at the end. The baseline is the WORKING TREE, not HEAD,
# so this runs against an uncommitted fix.
#
# Usage:  tests/shell/mutate_path_determinism.sh          (cwd = repo root; no build needed)
# Exit:   0 all mutations caught, 1 a mutation survived, 2 refused (harness fault).
set -uo pipefail

REPO="${REPO:-$(pwd)}"
# The proxy's own venv, not miniconda: these modules need networkx. A missing interpreter is a
# harness fault, not a survivor -- it proves nothing either way.
PY="${PROXY_PY:-$REPO/p4_proxy/venv/bin/python3}"

RT="$REPO/p4_proxy/proxy_agent/ryu_topology.py"
TM="$REPO/p4_proxy/proxy_agent/topology_manager.py"
TEST=tests/test_path_determinism.py
FILES=("$RT" "$TM")

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'

for f in "${FILES[@]}" "$REPO/p4_proxy/$TEST"; do
    [[ -f "$f" ]] || { echo "${R}REFUSED${N} missing $f"; exit 2; }
done
[[ -x "$PY" ]] || { echo "${R}REFUSED${N} no proxy interpreter at $PY"; exit 2; }

SNAP="$(mktemp -d)"
for f in "${FILES[@]}"; do cp -p "$f" "$SNAP/$(basename "$f")"; done
restore() { for f in "${FILES[@]}"; do cp -p "$SNAP/$(basename "$f")" "$f"; done; }
trap 'restore; rm -rf "$SNAP"' EXIT

run_suite() {   # -> writes $LOG, returns pytest-ish rc
    (cd "$REPO/p4_proxy" && PYTHONPATH=. "$PY" "$TEST" -v) >"$LOG" 2>&1
}

# --- baseline ---------------------------------------------------------------------------------
LOG="$(mktemp)"
echo "== baseline (working tree) =="
if ! run_suite; then
    echo "${R}REFUSED${N} baseline is red; a mutation gate over a red baseline proves nothing"
    sed -n '/FAILED\|ERROR\|AssertionError/p' "$LOG" | head -10
    exit 2
fi
BASE_RAN=$(grep -oE '^Ran [0-9]+ test' "$LOG" | tail -1 | grep -oE '[0-9]+')
echo "${G}PASS${N}  ${D}${BASE_RAN} tests${N}"

MUTATIONS=0
SURVIVED=0

# $1 label  $2 expected-red test name  $3.. sed programme applied to the file named by $MUT_FILE
mutate() {
    local label="$1" expect="$2" file="$3"; shift 3
    MUTATIONS=$((MUTATIONS + 1))
    printf '  %-46s ' "$label"
    restore
    "$PY" - "$file" "$@" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
if src.count(old) != 1:
    sys.exit(9)          # anchor moved or is ambiguous: refuse rather than mutate blindly
open(path, "w").write(src.replace(old, new))
PYEOF
    local rc=$?
    if [[ $rc -eq 9 ]]; then
        echo "${R}SURVIVED${N} ${D}anchor not found exactly once -- mutation not applied${N}"
        SURVIVED=$((SURVIVED + 1)); return
    fi
    run_suite
    if [[ $? -eq 0 ]]; then
        echo "${R}SURVIVED${N} ${D}suite still green${N}"
        SURVIVED=$((SURVIVED + 1)); return
    fi
    if grep -qE "(FAIL|ERROR): ${expect}\b" "$LOG"; then
        local reds
        reds=$(grep -cE '^(FAIL|ERROR): ' "$LOG")
        echo "${G}caught${N} ${D}by ${expect} (${reds} red)${N}"
    else
        echo "${R}SURVIVED${N} ${D}suite went red, but not via ${expect}${N}"
        grep -E '^(FAIL|ERROR): ' "$LOG" | head -4 | sed 's/^/        /'
        SURVIVED=$((SURVIVED + 1))
    fi
}

echo "== mutations =="

# M1 -- the original defect, restored in the renderer's path helper.
mutate "M1 canonical_path -> nx.shortest_path" \
    "test_every_host_pair_is_insertion_order_independent" "$RT" \
'def canonical_path(net, src, dst, dist=None):' \
'def canonical_path(net, src, dst, dist=None):
    import networkx as _nx
    try:
        return _nx.shortest_path(net, source=src, target=dst)
    except Exception:
        return None'

# M2 -- the original defect, restored in the route installer.
mutate "M2 calculate_all_paths -> nx.shortest_path" \
    "test_topology_manager_all_pairs_is_stable" "$TM" \
'                src: {"path": path, "length": len(path) - 1}
                for src, path in ryu_topology.canonical_paths_to(search, dst).items()' \
'                src: {"path": nx.shortest_path(search, source=src, target=dst),
                      "length": len(nx.shortest_path(search, source=src, target=dst)) - 1}
                for src in nodes
                if src != dst and nx.has_path(search, src, dst)'

# M3 -- deterministic, and concentrates every tie onto the lowest-numbered neighbour. This is the
# mutation a reviewer is most likely to propose as a simplification, which is why it is here.
mutate "M3 digest -> lowest node token" \
    "test_no_switch_on_a_shortest_path_is_left_dark" "$RT" \
'        key = (_hop_rank(dst, node, nxt), _node_token(nxt))' \
'        key = (_node_token(nxt),)'

# M4 -- rank the candidates by the SOURCE instead of the destination. Still deterministic, still
# spread; the path stops being the one the switches themselves would follow.
mutate "M4 hop rank keyed on the source" \
    "test_advertised_hops_match_each_switch_own_next_hop" "$RT" \
'        node = canonical_next_hop(net, node, dst, dist)' \
'        _cands = [v for v in net.successors(node) if dist.get(v) == dist[node] - 1]
        node = min(_cands, key=lambda v: (_hop_rank(src, node, v), _node_token(v))) if _cands else None'

# M5 -- builtin hash(): identical within a process, different between processes.
mutate "M5 blake2b -> builtin hash()" \
    "test_same_answer_under_different_hash_seeds" "$RT" \
'    import hashlib
    h = hashlib.blake2b(digest_size=16)
    for tok in (_node_token(dst), _node_token(here), _node_token(candidate)):
        h.update(len(tok).to_bytes(2, "big"))
        h.update(tok)
    return h.digest()' \
'    return hash((str(dst), str(here), str(candidate))).to_bytes(8, "big", signed=True)'

# --- restore and prove it ---------------------------------------------------------------------
restore
echo "== baseline restored =="
DIRTY=0
for f in "${FILES[@]}"; do
    cmp -s "$f" "$SNAP/$(basename "$f")" || { echo "${R}NOT RESTORED${N} $f"; DIRTY=1; }
done
[[ $DIRTY -eq 0 ]] && echo "${G}byte-identical${N}"
if ! run_suite; then
    echo "${R}REFUSED${N} suite red after restore"; exit 2
fi

echo
echo "${MUTATIONS} mutations, ${SURVIVED} survived"
[[ $DIRTY -ne 0 ]] && exit 2
[[ $SURVIVED -eq 0 ]] || exit 1
exit 0
