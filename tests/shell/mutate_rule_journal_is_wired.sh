#!/usr/bin/env bash
#
# Mutation gate for p4_proxy/tests/test_journal_is_wired_in_main.py.
#
# [Co-developed with claude code -- Adam]
#
# KNOWN-ISSUES A-4c, finding #71. The rule journal shipped with 19 tests of its own and a suite
# literally named "journal wiring" with 14 more, and was never written once in production:
# main.py built `TopologyManager(kernel_notifier=kernel)` and `_note_in_journal` returned on
# `self._journal is None` every call. Both suites injected the journal themselves, so neither
# could see it. Each mutation below puts one piece of that defect back, and must turn its named
# case red -- a mutation nobody catches means that case proves nothing.
#
# 🔴 Two directions, because one is not enough here. Every "the journal must be written" case is
# ALSO satisfied by an implementation that writes MORE: one that journals refused writes (rules
# that were never installed, which a replay would then create), one that opens a fresh journal
# per proxy start (green on every wiring assertion, empty on every restart), one that puts the
# file outside the checkout. The mutations labelled (control) are those implementations, and
# each must turn a control case red. A gate with only the first kind would sign off on a journal
# that is written diligently and cannot be read back by the restart it exists for.
#
# 🔴 Guards its own baseline: every mutation is applied to a COPY of p4_proxy under a temp dir
# and the test is run there. Nothing under p4_proxy/ is written -- another session may be
# executing those files right now -- and the three source files are re-hashed at the end.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
TOPO="$REPO/p4_proxy/proxy_agent/topology_manager.py"
JOURNAL="$REPO/p4_proxy/proxy_agent/rule_journal.py"
TEST="$REPO/p4_proxy/tests/test_journal_is_wired_in_main.py"
MODULE="tests.test_journal_is_wired_in_main"

# The interpreter. A git worktree has no venv of its own (p4_proxy/venv/ is gitignored and lives
# in the main checkout), so the main worktree is consulted before giving up -- asked of git
# rather than spelled as somebody's home directory, which would make this gate runnable on one
# machine. Override with PROXY_PY= .
MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$REPO/p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || {
    echo "REFUSE: found no interpreter with fastapi/networkx/grpc. Set PROXY_PY=<path>." >&2
    echo "        A gate that cannot run its test has not checked anything, so it does not"
    echo "        get to exit 0." >&2
    exit 2
}
echo "interpreter: $PY"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-journal-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_MAIN=$(sha256sum "$MAIN" | cut -d' ' -f1)
BASE_TOPO=$(sha256sum "$TOPO" | cut -d' ' -f1)
BASE_JOURNAL=$(sha256sum "$JOURNAL" | cut -d' ' -f1)
BASE_TEST=$(sha256sum "$TEST" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

# The test imports proxy_agent.main the way the proxy is launched, so it needs the package, the
# tests beside it, and mininet/ (main.py reads host_count_override and grpc_ports.py at import).
# PYTHONDONTWRITEBYTECODE so a mutant cannot be run from a .pyc of its unmutated self.
run_against() {
    ( cd "$1" && PYTHONPATH="$1" PYTHONDONTWRITEBYTECODE=1 timeout 300 "$PY" -m unittest "$MODULE" -v 2>&1 )
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test case that must go red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-62s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-62s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole copy of p4_proxy's importable tree: main.py, topology_manager.py and
# rule_journal.py are three links in one chain and a mutation to any of them has to be exercised
# through the real import, not through a stub of the other two. The anchor must be unique, so a
# mutation cannot quietly land somewhere other than where it is described.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from a function's
# own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is not checking
# (finding #28).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$d/"
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    python3 - "$d/${file#"$REPO/p4_proxy/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$base/"
find "$base" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
run_against "$base" | grep -E '^(Ran |OK|FAILED)'
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the defect itself: a journal nobody hands to anybody ----------------------------------------

m=$(mutant m1 "$MAIN" \
    'topo = TopologyManager(kernel_notifier=kernel, journal=journal)' \
    'topo = TopologyManager(kernel_notifier=kernel)')
report "M1: main.py stops passing the journal (the line as it stood)" "$m" \
       "test_the_module_level_topology_holds_a_real_rule_journal"

m=$(mutant m2 "$MAIN" \
    'kernel_notifier=kernel, journal=journal)' \
    'kernel_notifier=kernel, journal=None)')
report "M2: the journal is BUILT and then not passed" "$m" \
       "test_the_module_level_topology_holds_a_real_rule_journal"

m=$(mutant m3 "$MAIN" \
    'api_routes.inject_topology(topo)' \
    'api_routes.inject_topology(TopologyManager(kernel_notifier=kernel))')
report "M3: the REST handlers get a second, journal-less manager" "$m" \
       "test_the_topology_the_rest_handlers_use_is_the_journalled_one"

m=$(mutant m4 "$TOPO" \
    'if not accepted or self._journal is None:' \
    'if not accepted or self._journal is not None:')
report "M4: _note_in_journal's guard is inverted" "$m" \
       "test_one_accepted_install_is_one_line_in_the_journal_file"

m=$(mutant m5 "$TOPO" \
    '            return self._note_in_journal(
                "install", dpid, match_dict, actions_dict, priority,
                bool(client.insert_5tuple_rule(keys, prio, next_hop_mac, out_port)))' \
    '            return bool(client.insert_5tuple_rule(keys, prio, next_hop_mac, out_port))')
report "M5: the 5-tuple branch stops journalling (no other record exists)" "$m" \
       "test_a_five_tuple_install_is_in_the_journal_file"

m=$(mutant m6 "$JOURNAL" \
    '                    fh.write(line)' \
    '                    pass')
report "M6: record() reports success without writing anything" "$m" \
       "test_one_accepted_install_is_one_line_in_the_journal_file"

m=$(mutant m7 "$JOURNAL" \
    '        line = json.dumps(entry, separators=(",", ":"), sort_keys=True) + "\n"' \
    '        line = repr(entry) + "\n"')
report "M7: the file is written in a format its own reader cannot parse" "$m" \
       "test_the_journal_the_proxy_wrote_is_readable_by_rule_journal"

m=$(mutant m8 "$MAIN" \
    '    override = str(env.get(RULE_JOURNAL_PATH_ENV_VAR, "")).strip()' \
    '    override = ""')
report "M8: the path override is ignored (an env var with no reader again)" "$m" \
       "test_the_environment_override_is_read"

# --- 🔴 the other direction: write MORE, in six shapes --------------------------------------------
# Each of these passes every mutation above. They are caught only by the controls, and without
# them this gate would sign off on a journal that is diligently written and useless on restart.

m=$(mutant n1 "$TOPO" \
    'if not accepted or self._journal is None:' \
    'if self._journal is None:')
report "N1 (control): refused writes are journalled too" "$m" \
       "test_a_refused_install_leaves_the_journal_file_empty"

m=$(mutant n2 "$MAIN" \
    '    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base_dir, DEFAULT_RULE_JOURNAL_RELPATH)' \
    '    return os.path.join(__import__("tempfile").mkdtemp(), "rule_journal.jsonl")')
report "N2 (control): a brand new journal for every proxy start" "$m" \
       "test_the_default_path_does_not_move_between_constructions"

m=$(mutant n3 "$MAIN" \
    '    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base_dir, DEFAULT_RULE_JOURNAL_RELPATH)' \
    '    return os.path.abspath(DEFAULT_RULE_JOURNAL_RELPATH)')
report "N3 (control): the path follows the working directory" "$m" \
       "test_the_default_path_does_not_depend_on_the_working_directory"

m=$(mutant n4 "$MAIN" \
    '    return os.path.join(base_dir, DEFAULT_RULE_JOURNAL_RELPATH)' \
    '    return os.path.join(os.path.expanduser("~"), "ndtwin_rule_journal.jsonl")')
report "N4 (control): the journal is written to one machine's home directory" "$m" \
       "test_the_default_path_is_inside_this_checkout"

m=$(mutant n5 "$JOURNAL" \
    '                with open(self.path, "a", encoding="utf-8") as fh:' \
    '                with open(self.path, "w", encoding="utf-8") as fh:')
report "N5 (control): each entry replaces the file instead of appending" "$m" \
       "test_two_writes_append_rather_than_replace"

m=$(mutant n6 "$MAIN" \
    '    return RuleJournal(override or default_journal_path())' \
    '    _j = RuleJournal(override or default_journal_path())
    os.makedirs(os.path.dirname(_j.path), exist_ok=True)
    open(_j.path, "a").close()
    return _j')
report "N6 (control): the file is created empty at import" "$m" \
       "test_importing_the_proxy_does_not_create_the_file"

echo
[[ "$(sha256sum "$MAIN" | cut -d' ' -f1)" == "$BASE_MAIN" ]] || { echo "🔴 baseline CHANGED -- main.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TOPO" | cut -d' ' -f1)" == "$BASE_TOPO" ]] || { echo "🔴 baseline CHANGED -- topology_manager.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$JOURNAL" | cut -d' ' -f1)" == "$BASE_JOURNAL" ]] || { echo "🔴 baseline CHANGED -- rule_journal.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST" | cut -d' ' -f1)" == "$BASE_TEST" ]] || { echo "🔴 baseline CHANGED -- the test was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (main.py, topology_manager.py, rule_journal.py, the test)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
