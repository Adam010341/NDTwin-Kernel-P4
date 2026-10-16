#!/usr/bin/env bash
#
# live-p1/09_paper_int_v1.sh's two verdicts and its host lookup, driven OFFLINE against stubs.
#
# [Co-developed with claude code -- Adam]
#
# 09 has never been run (it needs the lab), so the only evidence that its verdicts can say no is
# this file. It sources 09 with LIVE09_LIB_ONLY=1 -- functions defined, nothing started: no
# claim, no `ndt`, no sudo -- in a subshell, and drives:
#
#   A1  a1_verdict over a switch_state that is right, and over seven that are wrong in one field
#       each (mode, package, the dpid set, pipeline.ndtwin, the p4info sha, a failed entry, s1's
#       recorded count). Each wrong one must read BAD and name what is wrong.
#   A3  a3_matrix with ping_loss stubbed from a table: the matrix int-v1 implies is green; h1->h2
#       answering (the INT source not installed) is red; an untested pair is red, never green.
#   m1  hpid against an `ndt` whose host_pid fails: an empty answer and rc 0, so the A2 NOT RUN
#       branch is reachable under `set -e` instead of the script dying in an assignment.
#
# Run:  bash tests/shell/test_live_p1_09.sh
# Env:  LIVE09_UNDER_TEST=<path> to drive a copy (it must sit beside a _common.sh)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$HERE/../.." && pwd)"
LIVE="$REAL_REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1"
S09="${LIVE09_UNDER_TEST:-$LIVE/09_paper_int_v1.sh}"
[[ -r "$S09" ]] || { echo "  FAILED   no 09 at $S09"; echo "Ran 1 checks, 1 failed"; exit 1; }

PASS=0; FAIL=0
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}
has() { /usr/bin/grep -qF -- "$2" <<<"$3" && { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; } \
        || { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             no match for: [%s] in [%s]\n' "$1" "$2" "$3"; }; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-09-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
PKGDIR="$FIX/packages/int-v1"
SHA="7aeaf18009ab6f4f"

# lib <commands> -- run <commands> in a subshell that has sourced 09 in function-only mode.
lib() {
    ( LIVE09_LIB_ONLY=1
      # shellcheck disable=SC1090
      source "$S09" >/dev/null 2>&1 || exit 97
      set +e
      # a1_verdict uses only the standard library; a worktree has no p4_proxy/venv of its own.
      [[ -x "$PY" ]] || PY=python3
      eval "$1" )
}

# --- A1 --------------------------------------------------------------------------------------------
printf '\nA1: a1_verdict\n'
state() {   # state <file> <python edits applied to d>
    "${PY:-python3}" - "$1" "$PKGDIR" "$SHA" "$2" <<'ST'
import json, sys
path, pkg, sha, edit = sys.argv[1:5]
sw = lambda rec: {"pipeline": {"ndtwin": False, "p4info_sha256": sha,
                               "skipped": ["clone_session", "sflow_telemetry"]},
                  "table_entries": {"recorded": rec, "applied": rec, "failed": 0}}
d = {"control_plane": {"mode": "ndtwin", "package": pkg, "skipped": []},
     "switches": {"1": sw(6), "2": sw(4), "3": sw(4)}}
exec(edit)
json.dump(d, open(path, "w"))
ST
}
state "$FIX/good.json" "pass"
OUT="$(lib "a1_verdict '$FIX/good.json' '$PKGDIR'")"
has "the right switch_state reads OK" "OK mode ndtwin" "$OUT"

while IFS='|' read -r name edit needle; do
    state "$FIX/bad.json" "$edit"
    OUT="$(lib "a1_verdict '$FIX/bad.json' '$PKGDIR'")"
    has "🔴 $name reads BAD" "BAD" "$OUT"
    has "   and names it" "$needle" "$OUT"
done <<'CASES'
another control-plane mode|d['control_plane']['mode'] = 'external'|control_plane.mode
another package|d['control_plane']['package'] = '/elsewhere'|control_plane.package
a switch missing|del d['switches']['3']|want exactly
s2 on NDTwin's pipeline|d['switches']['2']['pipeline']['ndtwin'] = True|s2 pipeline.ndtwin
an untested p4info|d['switches']['1']['pipeline']['p4info_sha256'] = '0000000000000000'|s1 p4info_sha256
a refused entry|d['switches']['3']['table_entries'].update(applied=3, failed=1)|s3 table_entries
s1 without the translated entries|d['switches']['1']['table_entries'].update(recorded=4, applied=4)|s1 table_entries.recorded
CASES

# --- A3 --------------------------------------------------------------------------------------------
printf '\nA3: a3_matrix\n'
# ping_loss_table <pair:loss:rc ...> -- a ping_loss stub answering from that table.
a3() {   # a3 <table> -> "VERDICT_RC=<n> WHY=<first reason>"
    lib "ping_loss() { local k=\"\$1:\$2\" e; for e in $1; do IFS=: read -r s d l r <<<\"\$e\";
           if [[ \"\$s:\${HIP[\$d]}\" == \"\$k\" ]]; then echo \"\$l 5/5\"; return \"\$r\"; fi; done;
           echo 'UNTESTED no stub row'; return 2; }
         VERDICT_RC=0; VERDICT_WHY=''; a3_matrix '$FIX/raw.txt' >/dev/null 2>&1
         echo \"VERDICT_RC=\$VERDICT_RC WHY=\$VERDICT_WHY\""
}
GOOD="h1:h2:100:0 h2:h1:100:0 h1:h3:0:0 h3:h1:0:0 h2:h3:0:0 h3:h2:0:0"
check "the matrix int-v1 implies is green" "VERDICT_RC=0 WHY=" "$(a3 "$GOOD")"
OUT="$(a3 "${GOOD/h1:h2:100:0/h1:h2:0:0}")"
has "🔴 h1->h2 answering (no INT source) is red" "VERDICT_RC=1" "$OUT"
has "   and says which pair" "h1 -> h2 lost 0%, want 100%" "$OUT"
OUT="$(a3 "${GOOD/h3:h2:0:0/h3:h2:20:0}")"
has "🔴 loss on a pair that should be clean is red" "h3 -> h2 lost 20%, want 0%" "$OUT"
OUT="$(a3 "${GOOD/h2:h1:100:0/h2:h1:100:2}")"
has "🔴 an untested pair is red, not green" "A3: NOT RUN for h2 -> h1" "$OUT"

# --- m1 --------------------------------------------------------------------------------------------
printf '\nm1: hpid under set -e\n'
cat > "$FIX/ndt" <<'NDT'
host_pid() { return 1; }
return 0 2>/dev/null || exit 0
NDT
OUT="$(lib "NDT='$FIX/ndt'; set -e; P=\"\$(hpid h1)\"; echo \"rc=\$? P=[\$P]\"")"
check "a missing host is an empty answer, not an exit" "rc=0 P=[]" "$OUT"

printf '\nRan %d checks, %d failed\n' "$((PASS + FAIL))" "$FAIL"
(( FAIL == 0 ))
