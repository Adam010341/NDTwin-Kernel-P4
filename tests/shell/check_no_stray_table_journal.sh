#!/usr/bin/env bash
#
# Does the p4_proxy test suite leave anything in the checkout's table-entry journal directory?
#
# [Co-developed with claude code -- Adam]
#
# `proxy_agent.main` builds its table-entry journals at import, in `p4_proxy/.run/table_entry_journal`
# unless NDTWIN_TABLE_JOURNAL_DIR says otherwise, and that is the directory a proxy on this machine
# replays at its next start. Since the replay, `main.startup` writes a header into every switch's
# file, so one test module that imports `main` without `tests/journal_isolation.py` first is enough
# to write into it. A per-file runner (one process per test file, which is how CI runs) cannot show
# one kind of leak -- one module's import order leaking into another's -- so this runs the whole
# directory in ONE process, the way `cd p4_proxy && python -m unittest discover -s tests` imports.
# And then once more, every file in a process of its own, the way CI runs them
# (tools/test_workflow/l1_unit_tests.sh section 3): a test that starts the proxy as a SUBPROCESS
# passes it this process's environment, so in a single process another module's isolation covers
# it and only the per-file run shows it (tests/test_port_guard.py did exactly that).
#
# What it compares is the directory's listing and every file's sha256, before and after: a
# checkout with a proxy that ran here has a live journal, and that is not this check's business --
# a change to it is.
#
# Usage:  tests/shell/check_no_stray_table_journal.sh
#         PROXY_PY=/path/to/python tests/shell/check_no_stray_table_journal.sh
# Exit:   0 the suite ran and the directory is as it was; 1 the directory changed, or the suite
#         failed; 2 refused (no interpreter, or the suite ran no test -- a check of nothing).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PROXY="$REPO/p4_proxy"
JDIR="$PROXY/.run/table_entry_journal"

MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$PROXY/venv/bin/python" "$PROXY/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || { echo "REFUSE: no interpreter with fastapi/networkx/grpc. Set PROXY_PY=<path>." >&2; exit 2; }

snapshot() {   # the directory as names and digests, or the word ABSENT
    if [[ -d "$JDIR" ]]; then
        ( cd "$JDIR" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum )
        echo "dir present"
    else
        echo "ABSENT"
    fi
}

echo "interpreter: $PY"
echo "journal dir: $JDIR"
before="$(snapshot)"
echo "before     : $(head -c 200 <<<"$before" | tr '\n' ' ')"
out="$( cd "$PROXY" && env -u NDTWIN_TABLE_JOURNAL_DIR -u NDTWIN_TEST_JOURNAL_ISOLATED \
        PYTHONDONTWRITEBYTECODE=1 timeout 1800 "$PY" -m unittest discover -s tests 2>&1 )"; rc=$?
after="$(snapshot)"
echo "after      : $(head -c 200 <<<"$after" | tr '\n' ' ')"
perfile_fail=0; perfile_files=0; perfile_stray=""
for f in "$PROXY"/tests/test_*.py; do
    perfile_files=$((perfile_files + 1))
    ( cd "$PROXY" && env -u NDTWIN_TABLE_JOURNAL_DIR -u NDTWIN_TEST_JOURNAL_ISOLATED \
        PYTHONPATH=. PYTHONDONTWRITEBYTECODE=1 timeout 600 "$PY" "$f" >/dev/null 2>&1 ) \
        || perfile_fail=$((perfile_fail + 1))
    now="$(snapshot)"
    if [[ "$now" != "$after" ]]; then
        perfile_stray+=" $(basename "$f")"
        after="$now"
    fi
done
echo "per file   : $perfile_files files, each in its own process; $perfile_fail exited non-zero; changed the directory:${perfile_stray:- none}"
summary="$(grep -E '^(Ran [0-9]+ tests|OK|FAILED)' <<<"$out" | tr '\n' ' ')"
echo "suite      : rc=$rc  $summary"

ran="$(grep -oE '^Ran [0-9]+ tests' <<<"$out" | grep -oE '[0-9]+')"
if [[ -z "$ran" || "$ran" -eq 0 ]]; then
    echo "REFUSE: the suite ran no test, so nothing was checked" >&2
    exit 2
fi
status=0
if [[ -n "$perfile_stray" ]]; then
    echo "🔴 STRAY (per file):$perfile_stray"
    status=1
fi
if [[ "$perfile_fail" -ne 0 ]]; then
    echo "🔴 $perfile_fail test file(s) failed when run on their own"
    status=1
fi
if [[ "$before" != "$after" ]]; then
    echo "🔴 STRAY: the suite changed $JDIR -- a test module imports main without tests/journal_isolation.py first"
    diff <(echo "$before") <(echo "$after") | sed 's/^/    /' | head -40
    status=1
fi
if [[ "$rc" -ne 0 ]]; then
    echo "🔴 the suite itself failed (rc=$rc):"
    grep -E '^(FAIL|ERROR):' <<<"$out" | head -20 | sed 's/^/    /'
    status=1
fi
[[ "$status" -eq 0 ]] && echo "ok: one process ($ran tests) and $perfile_files files one by one, and the checkout's table-entry journal is as it was"
exit "$status"
