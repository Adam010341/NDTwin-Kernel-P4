#!/usr/bin/env bash
#
# Defaults that used to name one person's home directory now follow the checkout or the caller's HOME.
#
# [Co-developed with claude code -- Adam]
#
# A machine set up from the User Manual has no /home/<that user>/..., so a default that names it is
# a path that is simply absent there. These defaults are EXERCISED here, each in a layout where the
# old literal could not give the right answer:
#
#   1. the two P4 reference probes name the build output of the checkout they sit in. Each probe is
#      copied into a throwaway tree and imported from there, so the answer can only be right if it
#      is derived from the file's own location;
#   2. build_bmv2_fast.sh looks for its source tree under the caller's $HOME. It is run with a HOME
#      that holds nothing, so it stops at its first gate (the tree is not there) and the message
#      names the path it looked at. A shim directory stands in for git, sudo and make so that even
#      a script that went on would build nothing;
#   3. two gates' interpreter lookups (mutate_ryu_rest_topology_bounded.sh under a HOME with no
#      miniconda; mutate_a7_dispatch_status.sh in a real linked worktree whose only venv is in the
#      main one) -- each refuses before it touches anything, naming the path it looked at;
#   4. (in test_ndtwin_lab_ntg_dir.sh) the bridge's NTG_DIR fallback.
#
# The last section is a count, not an exercise, and says so: in this change's scope, what is left
# of that home directory must equal the root helper tools/test_workflow/ndtwin-lab or ndt's copy
# of it, an anchor into a doc/audit harness, a compiler's output, or a recorded build line. The
# count is per file, so it catches an added occurrence, not a swapped one. Adding another turns it red.
#
# Run:  bash tests/shell/test_defaults_follow_the_checkout.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
summary() { printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"; }

TMPROOT="$(mktemp -d /tmp/ndt-defaults-XXXXXX)"
cleanup() { [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-defaults-* ]] && rm -rf "$TMPROOT"; return 0; }
trap cleanup EXIT INT TERM
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

# --- 1. the P4 reference probes ---------------------------------------------------------------
echo "the probes' build directory is the one beside the file"

# An interpreter that can import what the probes import. A venv in this checkout, else the main
# worktree's (a git worktree has none of its own; see mutate_p4_probe.sh), else python3 on PATH.
MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python" \
         "$(command -v python3 || true)"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import grpc; from p4.v1 import p4runtime_pb2' >/dev/null 2>&1 || continue
    PY="$c"; break
done
check "an interpreter that can import grpc and the P4Runtime protobufs was found (PROXY_PY=...)" yes \
      "$([[ -n "$PY" ]] && echo yes || echo no)"

if [[ -n "$PY" ]]; then
    for probe in clone_stack_probe p4runtime_mastership_probe; do
        tree="$TMPROOT/tree-$probe"
        mkdir -p "$tree/p4_proxy/reference" "$tree/p4_proxy/mininet"
        cp "$REPO/p4_proxy/reference/$probe.py" "$tree/p4_proxy/reference/"
        cp "$REPO/p4_proxy/mininet/grpc_ports.py" "$tree/p4_proxy/mininet/"
        got="$(cd / && "$PY" -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("probe_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.BUILD); print(m.P4INFO_PATH); print(m.JSON_PATH)
' "$tree/p4_proxy/reference/$probe.py" 2>&1)"
        check "🔴 $probe: BUILD is p4_proxy/p4_src/build of the tree it sits in" \
              "$tree/p4_proxy/p4_src/build" "$(sed -n 1p <<<"$got")"
        check "  $probe: the p4info is read from there" \
              "$tree/p4_proxy/p4_src/build/ndtwin_switch.p4info.txt" "$(sed -n 2p <<<"$got")"
        check "  $probe: and the pipeline json" \
              "$tree/p4_proxy/p4_src/build/ndtwin_switch.json" "$(sed -n 3p <<<"$got")"
    done
fi

# --- 2. build_bmv2_fast.sh --------------------------------------------------------------------
echo "the bmv2 build script looks for its source tree under the caller's HOME"

H="$TMPROOT/empty-home"; mkdir -p "$H" "$TMPROOT/shim"
for c in git sudo make; do
    printf '#!/bin/sh\necho "shim: %s must not run in this test" >&2\nexit 99\n' "$c" > "$TMPROOT/shim/$c"
    chmod +x "$TMPROOT/shim/$c"
done
out="$(cd / && env -u SRC HOME="$H" PATH="$TMPROOT/shim:$PATH" timeout 60 \
        bash "$REPO/tools/test_workflow/build_bmv2_fast.sh" 2>&1)"; rc=$?
check "it refuses (rc 2) when the source tree is not there" 2 "$rc"
check "🔴 and the message names the tree it looked for, under that HOME" \
      "  SRC = $H/P4_Source_Code/behavioral-model   <-- no .git in it (missing, or not a git checkout)" \
      "$(grep -m1 '^  SRC = ' <<<"$out")"
out2="$(cd / && env SRC="$TMPROOT/elsewhere" HOME="$H" PATH="$TMPROOT/shim:$PATH" timeout 60 \
        bash "$REPO/tools/test_workflow/build_bmv2_fast.sh" 2>&1)"
check "  and SRC still overrides it" \
      "  SRC = $TMPROOT/elsewhere   <-- no .git in it (missing, or not a git checkout)" \
      "$(grep -m1 '^  SRC = ' <<<"$out2")"

# --- 3. two gates' interpreter lookups ---------------------------------------------------------
echo "two gates look for their interpreters under the caller's HOME and the main worktree"

# mutate_ryu_rest_topology_bounded.sh: PYTHON defaults to $HOME/miniconda3/bin/python3, and refuses
# before it touches anything when that is not there. It uses paths relative to its cwd, so it is run
# as a copy in a temp tree whose two files are empty stubs: were the default wrong, the gate would
# go on in that tree and not in this checkout.
RYU="$TMPROOT/ryu"; mkdir -p "$RYU/tests/shell" "$RYU/tools/ryu_apps" "$RYU/tests/python"
cp "$REPO/tests/shell/mutate_ryu_rest_topology_bounded.sh" "$RYU/tests/shell/"
: > "$RYU/tools/ryu_apps/rest_topology_bounded.py"; : > "$RYU/tests/python/test_ryu_rest_topology_bounded.py"
out="$(cd "$RYU" && env -u PYTHON HOME="$H" timeout 120 bash tests/shell/mutate_ryu_rest_topology_bounded.sh 2>&1 </dev/null)"; rc=$?
check "ryu gate: refuses (rc 2) when HOME has no miniconda" 2 "$rc"
check "🔴 ryu gate: and names the interpreter it looked for, under that HOME" \
      "REFUSE: no interpreter at $H/miniconda3/bin/python3 (override with PYTHON=)." "$(grep -m1 '^REFUSE' <<<"$out")"

# mutate_a7_dispatch_status.sh: PROXY_PY is this checkout's venv, else the MAIN worktree's. A real
# linked worktree is built in the temp dir, with the only venv interpreter in the main one, and the
# gate (a copy, its files stubbed empty) is run there with nothing to find under HOME: it must get
# past the proxy interpreter and stop at the contract one, whose default is under HOME.
A7="$TMPROOT/a7"; mkdir -p "$A7/main/p4_proxy/venv/bin"
printf '#!/bin/sh\nexit 0\n' > "$A7/main/p4_proxy/venv/bin/python3"; chmod +x "$A7/main/p4_proxy/venv/bin/python3"
echo seed > "$A7/main/seed.txt"
git -C "$A7/main" init -q 2>/dev/null
git -C "$A7/main" add seed.txt
git -C "$A7/main" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m seed
git -C "$A7/main" worktree add -q -b a7-wt "$A7/wt" 2>/dev/null
mkdir -p "$A7/wt/tests/shell"
cp "$REPO/tests/shell/mutate_a7_dispatch_status.sh" "$A7/wt/tests/shell/"
for f in include/ndt_core/routing_management/FlowDispatcher.hpp src/ndt_core/routing_management/FlowDispatcher.cpp \
         src/ndt_core/http/HttpSession.cpp p4_proxy/proxy_agent/api_routes.py tools/contract_test/spec.py; do
    mkdir -p "$A7/wt/$(dirname "$f")"; : > "$A7/wt/$f"
done
out="$(cd "$A7/wt" && env -u PROXY_PY -u CONTRACT_PY HOME="$H" timeout 120 bash tests/shell/mutate_a7_dispatch_status.sh --python-only 2>&1 </dev/null)"; rc=$?
check "a7 gate: refuses (rc 2) at the contract interpreter" 2 "$rc"
check "🔴 a7 gate: the proxy interpreter was found in the main worktree, the contract one is looked for under HOME" \
      "REFUSE: contract interpreter $H/miniconda3/bin/python3 not found. Set CONTRACT_PY." "$(grep -m1 '^REFUSE' <<<"$out")"

# The proxy half on its own: the contract interpreter is given (a stub), and the main worktree's
# venv is taken away, so there is no proxy interpreter anywhere. The refusal names the last place
# the gate looked, the main worktree's. A default that still pointed at a fixed tree would find an
# interpreter on a machine that has one (and go on), or name that tree on one that has not.
printf '#!/bin/sh\nexit 0\n' > "$TMPROOT/stub-contract-py"; chmod +x "$TMPROOT/stub-contract-py"
rm -rf "$A7/main/p4_proxy/venv"
out="$(cd "$A7/wt" && env -u PROXY_PY CONTRACT_PY="$TMPROOT/stub-contract-py" HOME="$H" timeout 120 bash tests/shell/mutate_a7_dispatch_status.sh --python-only 2>&1 </dev/null)"; rc=$?
check "a7 gate: with no venv anywhere it refuses (rc 2)" 2 "$rc"
check "🔴 a7 gate: and names the main worktree's venv as the proxy interpreter it looked for" \
      "REFUSE: proxy interpreter $A7/main/p4_proxy/venv/bin/python3 not found. Set PROXY_PY." "$(grep -m1 '^REFUSE' <<<"$out")"

# --- (the bridge's NTG_DIR fallback is checked in test_ndtwin_lab_ntg_dir.sh, section 1) ------

# --- 4. what is left, counted ------------------------------------------------------------------
echo "what remains of that home directory in this change's scope (a count, not an exercise)"
# The needle is the /home/<name> prefix of the helper's own default tree, read at run time, so this
# file does not spell it out. No prefix to read means nothing can be counted: refuse.
HELPER="$REPO/tools/test_workflow/ndtwin-lab"
NEEDLE="$(sed -n 's/^LAB_DEFAULT_KERNEL_DIR=//p' "$HELPER" 2>/dev/null | head -1 | grep -oE '^/home/[^/]+' || true)"
if [[ -z "$NEEDLE" ]]; then
    echo "  FAILED   no /home/<name> prefix in LAB_DEFAULT_KERNEL_DIR of $HELPER, so there is nothing to count"
    FAIL=$((FAIL+1)); summary; exit 2
fi
# file:count. Each remaining occurrence is one of: a copy of a default of the root helper
# tools/test_workflow/ndtwin-lab (which users reinstall, so it is not edited here) or of ndt's copy
# of it, whether anchored on by a gate or pinned by a config suite; an anchor into a doc/audit
# harness (mutate_drive_exercise.sh); a compiler's output in a fixture (test_convert.py); or the
# configure line of the one binary a recovered build record describes (manifest_backfill.sh).
EXPECTED='
tests/shell/mutate_drive_exercise.sh:1
tests/shell/mutate_g7_ndtwin_lab_config.sh:1
tests/shell/mutate_ndt_helper_apps_window.sh:1
tests/shell/mutate_ndt_ntg_mode.sh:1
tests/shell/mutate_ndt_ovs_topo_script.sh:2
tests/shell/mutate_ndtwin_lab_ntg_dir.sh:1
tests/shell/test_ndt_ntg_mode.sh:1
tests/shell/test_ndtwin_lab_config.sh:6
tools/p4_exercise/tests/test_convert.py:1
tools/test_workflow/manifest_backfill.sh:1
'
TOUCHED='
p4_proxy/mininet/ntg_bmv2_topo.py
p4_proxy/reference/clone_stack_probe.py
p4_proxy/reference/p4runtime_mastership_probe.py
p4_proxy/tests/test_exact_one_element_list.py
tests/shell/mutate_a7_dispatch_status.sh
tests/shell/mutate_drive_exercise.sh
tests/shell/mutate_g7_ndtwin_lab_config.sh
tests/shell/mutate_ndt_helper_apps_window.sh
tests/shell/mutate_ndt_ntg_mode.sh
tests/shell/mutate_ndt_ovs_topo_script.sh
tests/shell/mutate_ndtwin_lab_ntg_dir.sh
tests/shell/mutate_ovs4_has_sflow.sh
tests/shell/mutate_round_env_kernel_dir.sh
tests/shell/mutate_ryu_rest_topology_bounded.sh
tests/shell/test_defaults_follow_the_checkout.sh
tests/shell/test_ndt_ntg_mode.sh
tests/shell/test_ndtwin_lab_config.sh
tests/shell/test_ndtwin_lab_heartbeat.sh
tests/shell/test_ndtwin_lab_ntg_dir.sh
tests/shell/test_ndtwin_lab_sweep.sh
tests/test_OpenflowCapacityReport.cpp
tools/p4_exercise/tests/fixtures/README
tools/p4_exercise/tests/test_convert.py
tools/test_workflow/build_bmv2_fast.sh
tools/test_workflow/greenlet_dump_smoke.py
tools/test_workflow/live_cells/CELLS.md
tools/test_workflow/manifest_backfill.sh
tools/test_workflow/test_ndt_lab_session.sh
'
actual=""
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    n="$(grep -cF -- "$NEEDLE" "$REPO/$f" || true)"
    [[ "$n" == 0 ]] || actual+="$f:$n"$'\n'
done <<<"$TOUCHED"
check "🔴 only the mirrored occurrences remain" "$(sed '/^$/d' <<<"$EXPECTED")" "$(sed '/^$/d' <<<"$actual")"

summary
[[ "$FAIL" -eq 0 ]]
