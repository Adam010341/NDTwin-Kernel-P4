#!/usr/bin/env bash
# TICKET-P4-roles section 7 ruling 5, item 4: close the baseline evidence chain.
# [Co-developed with claude code -- Adam]
#
# Round 1 ran each tree's OWN test files: d492a346's constants against the base code, HEAD's
# constants against HEAD's code. That never showed HEAD's constants ARE d492a346's. Two checks:
#   (a) the four constant blocks, d492a346 vs HEAD, compared by their literal VALUES (ast), so a
#       reformatting cannot hide a changed byte and a changed byte cannot hide in a comment;
#   (b) d492a346's own four fixture test files -- constants and capture functions as recorded --
#       run against HEAD's production code (tree = git archive HEAD, those four files put back
#       to their d492a346 bytes).
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-roles-0924
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
PY=$WT/p4_proxy/venv/bin/python
BASE_CAPTURE=d492a346
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
bad=0
echo "== (a) the constant blocks, $BASE_CAPTURE vs HEAD $HEAD_SHA"
"$PY" - "$WT" "$BASE_CAPTURE" <<'PY' || bad=1
import ast, hashlib, subprocess, sys
wt, base = sys.argv[1], sys.argv[2]
blocks = [("p4_proxy/tests/test_p4_client_writes.py", "BASELINE_WRITE_REQUESTS"),
          ("p4_proxy/tests/test_ryu_flow_stats.py", "BASELINE_NDTWIN_RENDER"),
          ("p4_proxy/tests/test_app_package.py", "BASELINE_PACKAGE_FIELDS"),
          ("p4_proxy/tests/test_app_package.py", "BASELINE_PACKAGE_LOADS"),
          ("tools/p4_exercise/tests/test_convert.py", "BASELINE_CONVERSIONS")]
def value(src, name):
    """(value, exact source text) of a top-level BASELINE_* assignment. Evaluated with no
    builtins and only the BASELINE_* constants assigned above it in the same file in scope
    (BASELINE_PACKAGE_LOADS refers to BASELINE_PACKAGE_FIELDS by name)."""
    env = {}
    for node in ast.parse(src).body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id.startswith("BASELINE_")):
            val = eval(compile(ast.Expression(node.value), "<const>", "eval"),
                       {"__builtins__": {}}, dict(env))
            env[node.targets[0].id] = val
            if node.targets[0].id == name:
                return val, ast.get_source_segment(src, node)
    raise KeyError(name)
bad = 0
for rel, name in blocks:
    then, then_src = value(subprocess.run(["git", "-C", wt, "show", f"{base}:{rel}"],
                                          check=True, capture_output=True, text=True).stdout, name)
    now, now_src = value(subprocess.run(["git", "-C", wt, "show", f"HEAD:{rel}"], check=True,
                                        capture_output=True, text=True).stdout, name)
    digest = hashlib.sha256(repr(now).encode()).hexdigest()[:16]
    same = then == now and then_src == now_src
    bad |= not same
    size = len(now) if hasattr(now, "__len__") else "-"
    print(f"  {'identical' if same else 'DIFFERENT'}  {name:26s} {rel}  ({size} entries/chars; "
          f"value and source text both compared; repr sha256 {digest})")
sys.exit(bad)
PY
echo
echo "== (b) $BASE_CAPTURE's four fixture test files against HEAD's production code"
T=$SP/chain; rm -rf "$T"; mkdir -p "$T"
git -C "$WT" archive HEAD p4_proxy tools setting | tar -x -C "$T"
rm -rf "$T/p4_proxy/p4_src/build"; ln -s "$WT/p4_proxy/p4_src/build" "$T/p4_proxy/p4_src/build"
for rel in p4_proxy/tests/test_p4_client_writes.py p4_proxy/tests/test_ryu_flow_stats.py \
           p4_proxy/tests/test_app_package.py tools/p4_exercise/tests/test_convert.py; do
    git -C "$WT" show "$BASE_CAPTURE:$rel" > "$T/$rel"
    echo "  $rel <- $BASE_CAPTURE ($(sha256sum "$T/$rel" | cut -c1-16))"
done
echo "  production: HEAD's p4_proxy/proxy_agent/*.py, e.g. ryu_flow_stats.py $(sha256sum "$T/p4_proxy/proxy_agent/ryu_flow_stats.py" | cut -c1-16) = worktree $(sha256sum "$WT/p4_proxy/proxy_agent/ryu_flow_stats.py" | cut -c1-16)"
env -C "$T/p4_proxy" PYTHONPATH="$T/p4_proxy" PYTHONDONTWRITEBYTECODE=1 TMPDIR="$SP/tmp" "$PY" \
    -m unittest -v tests.test_p4_client_writes.TheNdtwinPipelinesWritesAreByteIdenticalToTheBaseTest \
    tests.test_ryu_flow_stats.TheNdtwinPipelinesFlowStatsAreByteIdenticalToTheBaseTest \
    tests.test_app_package.APackageWithoutRolesLoadsByteIdenticallyTest \
    > "$SP/chain.out" 2> "$SP/chain.err"; rc=$?
/usr/bin/grep -E ' \.\.\. |^Ran |^OK|^FAILED' "$SP/chain.err" | sed 's/^/  /'; echo "  rc=$rc"
(( rc == 0 )) || bad=1
env -C "$T/tools/p4_exercise/tests" HOME="$SP/emptyhome" PYTHONDONTWRITEBYTECODE=1 \
    TMPDIR="$SP/tmp" "$PY" -m unittest -v test_convert.WithoutTheRoleFlagTheOutputIsByteIdenticalTest \
    > "$SP/chain.out" 2> "$SP/chain.err"; rc=$?
/usr/bin/grep -E ' \.\.\. |^Ran |^OK|^FAILED' "$SP/chain.err" | sed 's/^/  /'; echo "  rc=$rc"
(( rc == 0 )) || bad=1
rm -rf "$T" "$SP/chain.out" "$SP/chain.err"
echo "BASELINE-CHAIN: $([[ $bad == 0 ]] && echo "HEAD's constants are $BASE_CAPTURE's, and $BASE_CAPTURE's tests pass on HEAD's code" || echo BROKEN)"
exit $bad
