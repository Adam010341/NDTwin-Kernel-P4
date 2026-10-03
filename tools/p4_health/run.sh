#!/usr/bin/env bash
# Run the P4 health check detached from the terminal, at low priority, logging to its run dir.
# [Co-developed with claude code -- Adam]
#   tools/p4_health/run.sh s0 [extra probe.py args]      -> .test_run/p4_health/<UTC>_p4_health/probe.log (ignored; copy to audit-raw)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PY="${P4_PROXY_PY:-$REPO/p4_proxy/venv/bin/python}"
[[ -x "$PY" ]] || { echo "no interpreter at $PY (set P4_PROXY_PY)" >&2; exit 2; }
[[ "$(id -u)" -ne 0 ]] || { echo "refusing to run as root" >&2; exit 2; }
cmd="${1:-}"; shift || true
RUN="${P4_HEALTH_RUN_DIR:-$REPO/.test_run/p4_health/$(date -u +%Y-%m-%dT%H%M%SZ)_p4_health}"
mkdir -p "$RUN"
setsid nice -n 10 "$PY" "$HERE/probe.py" "$cmd" --run-dir "$RUN" "$@" >"$RUN/probe.log" 2>&1 < /dev/null
rc=$?
echo "rc=$rc  $RUN/probe.log"
exit "$rc"
