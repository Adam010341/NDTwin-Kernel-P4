#!/usr/bin/env bash
#
# Tests for L-9: `make_topology.py --stdout` must produce a JSON document on stdout.
#
# [Co-developed with claude code -- Adam]
#
# The flag's documented use is a redirect -- the script's own usage block says
# `tools/make_topology.py --hosts 16 --stdout` -- and it could not work: the round-trip report
# and the per-size progress lines went to the same stdout as the JSON, so the redirect produced a
# file whose first line is "round-trip against the shipped models:". Observed 2026-09-02,
# doc/audit/2026-09-02_live-round/raw/B6_make_topology.log: `JSONDecodeError: Expecting value:
# line 1 column 1`, and the same bytes with the report stripped by hand parsed to nodes 22,
# edges 56.
#
# 🔴 Three directions, because two of the three obvious wrong fixes pass a one-case test:
#   case 2 -- stdout parses. A build that printed NOTHING to stdout would fail this too.
#   case 4 -- the report is still emitted, on stderr. Deleting the report also makes case 2 pass,
#            and it would take the round-trip refusal ("REFUSING TO GENERATE") down with it.
#   case 5 -- WITHOUT --stdout nothing moves. The report IS the output there, and sending it to
#            stderr unconditionally would silently empty every existing invocation's stdout.
#
# No lab, no fabric, no writes to setting/: only --stdout and --check are exercised, neither of
# which writes a file, and the mutation gate runs its copies against a temp tree whose `setting`
# holds symlinks to the two shipped models.
#
# Run:  bash tests/shell/test_make_topology_stdout_is_json.sh
# Env:  MAKE_TOPOLOGY_UNDER_TEST=<path>  test another copy (the mutation gate uses it)
#       PY=<interpreter>                 default: the repo's test_env venv, else python3

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOOL="${MAKE_TOPOLOGY_UNDER_TEST:-$REPO/tools/make_topology.py}"
PY="${PY:-$REPO/test_env/bin/python}"
[[ -x "$PY" ]] || PY=python3

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_bad "$1" "expected: [$2]  actual: [$3]"; fi; }

T="$(mktemp -d /tmp/make-topo-stdout-XXXXXX)"
cleanup() { [[ -n "${T:-}" && "$T" == /tmp/make-topo-stdout-* ]] && rm -rf "$T"; }
trap cleanup EXIT

REPORT_LINE='round-trip against the shipped models:'

"$PY" "$TOOL" --hosts 8 --stdout >"$T/out.json" 2>"$T/out.err"
RC=$?

# --- 1. injection check: the run must actually have done the work ------------------------------
# If --hosts 8 --stdout had failed outright, or emitted nothing anywhere, every "stdout is clean"
# assertion below would pass on an empty file and mean nothing.
if [[ "$RC" -eq 0 && -s "$T/out.json" && -s "$T/out.err" ]]; then
    t_ok "injection check: the run exited 0 and wrote to BOTH streams (rc=$RC, $(wc -c <"$T/out.json") B out, $(wc -c <"$T/out.err") B err)"
else
    t_bad "injection check: the run exited 0 and wrote to BOTH streams" \
          "rc=$RC  stdout=$(wc -c <"$T/out.json") B  stderr=$(wc -c <"$T/out.err") B"
fi

# --- 2. stdout is a JSON document, and it is the right one -------------------------------------
parsed="$("$PY" - "$T/out.json" <<'PY' 2>&1
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("UNPARSEABLE %s" % e.__class__.__name__); raise SystemExit
print("nodes %d edges %d" % (len(d["nodes"]), len(d["edges"])))
PY
)"
check "case 2  --stdout writes a parseable model to stdout (8 hosts: 10 switches + 8 hosts, 48 edges)" \
      "nodes 18 edges 48" "$parsed"

# --- 3. and nothing else is on stdout ----------------------------------------------------------
check "case 3  the round-trip report is NOT on stdout" "0" \
      "$(grep -c "$REPORT_LINE" "$T/out.json")"

# --- 4. the report is not lost: it goes to stderr ----------------------------------------------
check "case 4  the round-trip report IS on stderr (not deleted -- it carries the refusal too)" \
      "1" "$(grep -c "$REPORT_LINE" "$T/out.err")"

# --- 5. without --stdout nothing moves ---------------------------------------------------------
# --check is the invocation whose entire output is the report. If the report moved to stderr
# unconditionally, this command's stdout would silently become empty.
"$PY" "$TOOL" --check >"$T/check.out" 2>"$T/check.err"
check "case 5  without --stdout the report still goes to stdout (--check unchanged)" \
      "1 0" "$(grep -c "$REPORT_LINE" "$T/check.out") $(grep -c "$REPORT_LINE" "$T/check.err")"

echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
