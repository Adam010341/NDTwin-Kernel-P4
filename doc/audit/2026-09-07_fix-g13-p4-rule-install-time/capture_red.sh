#!/usr/bin/env bash
# Re-applies five of the gate's mutations one at a time and prints the VERBATIM unittest output
# for the case that goes red, so the summary can quote it rather than paraphrase the gate's
# one-line verdict. Read-only against the repo: every mutant is a copy under $BK.
set -uo pipefail
REPO="/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-g13"
PY="$REPO/p4_proxy/venv/bin/python"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-red-XXXXXX")
trap 'rm -rf "$BK"' EXIT
MODULES="tests.test_rule_install_times tests.test_ryu_flow_stats"

apply() {  # $1 label  $2 file (relative to p4_proxy)  $3 old  $4 new
    local d="$BK/$1"; mkdir -p "$d"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$d/"
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    python3 - "$d/$2" "$3" "$4" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits)" % s.count(a)
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

show() {  # $1 label  $2 mutant dir  $3 case name
    echo "=============================================================="
    echo "### $1"
    echo "=============================================================="
    ( cd "$2" && PYTHONPATH="$2" PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest $MODULES 2>&1 ) \
        | awk -v c="$3" '
            /^(FAIL|ERROR): / {p = index($0, c" (") > 0}
            p {print}
            /^Ran |^FAILED|^OK/ {print}
          '
    echo
}

d=$(apply m1 proxy_agent/p4_client.py \
'            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Added route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")' \
'            print(f"[{self.device_id}] Added route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")')
show "M1 -- an accepted route install is not recorded at all" "$d" test_an_accepted_route_install_is_dated

d=$(apply m2 proxy_agent/ryu_flow_stats.py \
'        "duration_sec": duration_sec,
        "duration_nsec": duration_nsec,' \
'        "duration_sec": 0,
        "duration_nsec": 0,')
show "M2 -- the renderer emits 0/0 again (the line as it stood)" "$d" test_a_rule_this_proxy_installed_reports_how_long_ago

d=$(apply m3 proxy_agent/rule_install_times.py \
'        if installed_at is None:
            return None
        return max(0.0, self._monotonic() - installed_at)' \
'        if installed_at is None:
            return max(0.0, self._monotonic())
        return max(0.0, self._monotonic() - installed_at)')
show "M3 -- a rule nobody recorded is given an age anyway (widening)" "$d" test_a_rule_with_no_record_stays_zero_which_is_what_unknown_looks_like

d=$(apply m4 proxy_agent/rule_install_times.py \
'    return (str(dpid), str(table), int(priority or 0), normalise_match(match))' \
'    return (str(dpid), str(table), int(priority or 0))')
show "M4 -- the key drops the match, so one table is one rule" "$d" test_two_rules_in_one_table_at_one_priority_do_not_share_an_age

d=$(apply m5 proxy_agent/api_routes.py \
'        return ryu_flow_stats.render_flow_stats(dpid, client.read_table_entries(),
                                                install_times=client.rule_install_times)' \
'        return ryu_flow_stats.render_flow_stats(dpid, client.read_table_entries())')
show "M5 -- the endpoint stops passing the record (finding #71 again)" "$d" test_a_rule_the_client_installed_comes_back_with_its_age

d=$(apply n1 proxy_agent/p4_client.py \
'            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Added route:' \
'            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            print(f"[{self.device_id}] Added route:')
show "N1 (control) -- the stamp is written before the switch accepted anything" "$d" test_a_refused_route_install_is_not_dated

d=$(apply n2 proxy_agent/rule_install_times.py \
'            if key not in self._at:
                self._at[key] = self._monotonic()' \
'            self._at[key] = self._monotonic()')
show "N2 (control) -- a second write of the same entry restarts the clock" "$d" test_an_idempotent_rewrite_does_not_restart_the_clock

d=$(apply n3 proxy_agent/p4_client.py \
'            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Modified route:' \
'            self._forget_route(dst_ip, prefix_len)
            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Modified route:')
show "N3 (control) -- a reroute restarts the clock (the design Adam ruled out 2026-09-08)" "$d" test_an_app_rerouting_a_destination_does_not_make_the_rule_look_new
