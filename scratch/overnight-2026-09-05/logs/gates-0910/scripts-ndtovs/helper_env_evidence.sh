#!/usr/bin/env bash
# helper_env_evidence.sh -- is test_ndt_helper_apps_window.sh's one red cell this branch's diff, or
# the machine? Read-only for the repo: the older tree is exported with `git archive` into a temp
# dir, never checked out. [Co-developed with claude code -- Adam]
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
echo "== installed helper"; ls -l --time-style=full-iso /usr/local/sbin/ndtwin-lab; sha256sum /usr/local/sbin/ndtwin-lab
echo "== this tree's copy, and where each sha lives"
for r in 62f76cf5 e1420df2 HEAD trunk; do
    printf '%-10s %s\n' "$r" "$(git show "$r:tools/test_workflow/ndtwin-lab" | sha256sum | cut -d' ' -f1)"
done
echo "   (this branch's diff to it since base: $(git diff --stat 62f76cf5 HEAD -- tools/test_workflow/ndtwin-lab | wc -l) line(s))"
git log -1 --format='   trunk last changed it: %h %ci %s' trunk -- tools/test_workflow/ndtwin-lab | cut -c1-160
T="$(mktemp -d "${TMPDIR:-/tmp}/ndtovs-e1420df2-XXXXXX")"; trap 'rm -rf "$T"' EXIT
git archive e1420df2 tests/shell tools/test_workflow | tar -x -C "$T"
echo "== test_ndt_helper_apps_window.sh on the e1420df2 tree (green in ndt_lab_suite.ndtovs-e1420df2.log before 19:34)"
out="$(timeout 600 bash "$T/tests/shell/test_ndt_helper_apps_window.sh" 2>&1)"; echo "rc=$?"
grep -A2 'FAILED' <<<"$out" | head -6; grep 'Ran [0-9]' <<<"$out" | tail -1
echo "== the same suite at HEAD"
out="$(timeout 600 bash tests/shell/test_ndt_helper_apps_window.sh 2>&1)"; echo "rc=$?"
grep -A2 'FAILED' <<<"$out" | head -6; grep 'Ran [0-9]' <<<"$out" | tail -1
