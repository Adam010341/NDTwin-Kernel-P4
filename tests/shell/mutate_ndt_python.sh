#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_python.sh (`ndt python`).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one way `ndt python` can run an app against the wrong SDK, hide its exit
# code, run it on a Python the SDK does not support, or ask the lab for something, and must turn its
# NAMED check red. A mutation caught by some other check says nothing about the check that was
# supposed to own it.
#
# 🔴 Mutations are applied to COPIES in a temp dir and the suite is pointed at them with
#    NDT_UNDER_TEST; no source file is written, and the sha256 of ndt is compared at the end. A copy
#    is a small tree in the repo's layout: tools/test_workflow/ carries ndt and the three files it
#    sources or reads from beside itself, and sdk/python/ndtwin is there because the SDK the suite
#    expects is the one beside the ndt under test (with its pyproject.toml: the suite reads the
#    Python floor, requires-python, from it).
# 🔴 A mutation that will not apply, a non-unique anchor, or the wrong check going red counts as a
#    SURVIVOR. A comment-only edit is the control and must stay green.
# 🔴 Touches no lab: the suite's sudo is a fake that refuses and records.
#
# Env:  MUTANT_EVIDENCE=<dir>  keeps each mutant as <label>.patch and the suite's output as <label>.log.
# Exit: 0 every mutation caught and the control stayed green, 1 a mutation survived (or the control
#       went red), 2 refused (baseline red / harness), 3 ndt changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
PYPROJECT="$REPO/sdk/python/pyproject.toml"
SH_TEST="$HERE/test_ndt_python.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-python-mutate-XXXXXX")
trap 'rm -rf "${BK:?}"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$NDT" && -f "$SH_TEST" && -f "$REPO/sdk/python/ndtwin/__init__.py" ]] || {
    echo "🔴 missing $NDT, $SH_TEST or sdk/python/ndtwin" >&2; exit 2; }

SURVIVORS=0
MUTATIONS=0

run_sh() { (cd "$1" && NDT_UNDER_TEST="$1/tools/test_workflow/ndt" timeout 300 bash "$SH_TEST" 2>&1); }

tree() {   # <dir> -- the files the suite reads, in the repo's layout
    mkdir -p "$1/tools/test_workflow" "$1/sdk/python"
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" \
       "$REPO/tools/test_workflow/components.env" "$1/tools/test_workflow/"
    cp -r "$REPO/sdk/python/ndtwin" "$REPO/sdk/python/pyproject.toml" "$1/sdk/python/"
    find "$1/sdk/python" -name __pycache__ -prune -exec rm -rf {} +
    chmod +x "$1/tools/test_workflow/ndt"
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the check that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ ! -f "$2/tools/test_workflow/ndt" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (the mutant was not built)\n' "$1"; return
    fi
    out=$(run_sh "$2"); rc=$?
    if [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
        { printf '%s\nthe check that must fail: %s\n\n' "$1" "$3"; printf '%s\n' "$out"; echo "exit code: $rc"; } \
            > "$MUTANT_EVIDENCE/$(basename "$2").log"
    fi
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that check proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

control() {   # $1 = name, $2 = mutant dir -- must NOT turn the suite red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_sh "$2"); rc=$?
    if [[ -f "$2/tools/test_workflow/ndt" && "$rc" -eq 0 ]]; then
        printf '  survived %-58s (control, as required)\n' "$1"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 CONTROL WENT RED %-47s\n' "$1"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    tree "$d"
    local target="$d/${file#"$REPO"/}"
    if ! python3 - "$target" "$old" "$new" <<'PY' >&2
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        rm -f "$d/tools/test_workflow/ndt"     # not built: `report` counts it as a survivor
    elif [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
        mkdir -p "$MUTANT_EVIDENCE"
        diff -u --label "a/${file#"$REPO"/}" --label "b/${file#"$REPO"/}" "$file" "$target" \
            > "$MUTANT_EVIDENCE/$label.patch"
    fi
    echo "$d"
}

echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; tree "$base"
run_sh "$base" | tail -1
run_sh "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- mutations prove nothing"; exit 2; }
echo

m=$(mutant y1 "$NDT" \
    '    export PYTHONPATH="$REPO/sdk/python${PYTHONPATH:+:$PYTHONPATH}"' \
    '    :')
report "Y1: PYTHONPATH is not set" "$m" \
       "from another directory: ndtwin is sdk/python of the tree ndt is in"

m=$(mutant y2 "$NDT" \
    '    export PYTHONPATH="$REPO/sdk/python${PYTHONPATH:+:$PYTHONPATH}"' \
    '    export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$REPO/sdk/python"')
report "Y2: the SDK is appended, not prepended" "$m" \
       "a decoy package already on PYTHONPATH -> still this checkout's"

m=$(mutant y2b "$NDT" \
    '    export PYTHONPATH="$REPO/sdk/python${PYTHONPATH:+:$PYTHONPATH}"' \
    '    export PYTHONPATH="$REPO/sdk/python"')
report "Y2b: the caller's PYTHONPATH is dropped" "$m" \
       "and the caller's own entry is kept, after the SDK"

m=$(mutant y3 "$NDT" \
    '    exec python3 "$@"
}' \
    '    python3 "$@"
    return 0
}')
report "Y3: python's exit code is swallowed" "$m" \
       "SystemExit(7) -> 7"

m=$(mutant y3b "$NDT" \
    '    exec python3 "$@"
}' \
    '    exec python3 $*
}')
report "Y3b: arguments are re-split on spaces" "$m" \
       "an argument with a space arrives whole"

m=$(mutant y4 "$NDT" \
    '    if (( major < NDT_PY_MIN_MAJOR || (major == NDT_PY_MIN_MAJOR && minor < NDT_PY_MIN_MINOR) )); then' \
    '    if false; then')
report "Y4: the version check is removed" "$m" \
       "a Python one minor below requires-python -> rc 5"

m=$(mutant y4b "$NDT" \
    'NDT_PY_MIN_MINOR=10' \
    'NDT_PY_MIN_MINOR=11')
report "Y4b: the floor drifts from the SDK's (3.11)" "$m" \
       "control: requires-python's own version is accepted and the script runs (rc 0)"

m=$(mutant y4c "$PYPROJECT" \
    'requires-python = ">=3.10"' \
    'requires-python = ">=3.11"')
report "Y4c: the SDK's requires-python moves up and ndt does not follow" "$m" \
       "a Python one minor below requires-python -> rc 5"

m=$(mutant y5 "$NDT" \
    '    export PYTHONPATH="$REPO/sdk/python${PYTHONPATH:+:$PYTHONPATH}"' \
    '    lab_session topo >/dev/null 2>&1
    export PYTHONPATH="$REPO/sdk/python${PYTHONPATH:+:$PYTHONPATH}"')
report "Y5: a lab read is added" "$m" \
       "the fake sudo was never called"

m=$(mutant y6 "$NDT" \
    '    python)  shift; cmd_python "$@" ;;' \
    '')
report "Y6: the dispatch line is missing" "$m" \
       "from another directory: ndtwin is sdk/python of the tree ndt is in"

# --- the control -------------------------------------------------------------------------------
m=$(mutant y0 "$NDT" \
    '# cmd_python [args] -- python3 with this checkout'"'"'s SDK (sdk/python) first on its path.' \
    '# cmd_python [args] -- python3 with this checkout'"'"'s SDK (sdk/python) first on its path (x).')
control "Y0: a comment-only edit" "$m"

echo
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- ndt was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
echo "baseline byte-identical: yes  ndt sha256 $BASE_NDT"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
