#!/usr/bin/env bash
# The embedded programs no self-test executes (embedded_cover.py's NOT rows), each run once here
# on a small input through the REAL text: the functions are sourced from the tree (or, for 07's
# two top-level blocks, the program text is cut out of the file), and the output is checked.
# Read-only against the machine (/proc/net/dev is read). [Co-developed with claude code -- Adam]
set -u
WT="$1"; T=$(mktemp -d "${TMPDIR:-/tmp}/rtcheck-XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
LIVE="$WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1"
chk() { if [[ "$2" == "$3" ]]; then echo "  ok    $1  ($2)"; else echo "  BAD   $1: got '$2', want '$3'"; bad=1; fi; }
echo "HEAD $(git -C "$WT" rev-parse HEAD)"
# _common.sh's functions, sourced as test_live_p1_common.sh sources them
out="$( cd "$WT" && bash -c '
set -u
source "$1/_common.sh" >/dev/null 2>&1
T="$2"
printf "{\"b\": 1, \"a\": [2]}" > "$T/in.json"
get_json "file://$T/in.json" "$T/got.json" >/dev/null 2>&1; echo "get_json rc $? $(tr -d " \n" < "$T/got.json")"
netdev_tx "$T/netdev.txt"; echo "netdev_tx rc $? lines $(wc -l < "$T/netdev.txt") bad $(grep -cvE "^s[0-9]+-eth[0-9]+ [0-9]+$" "$T/netdev.txt")"
printf "s1-eth1 P 50000\ns1-eth2 M 900\ns3-eth1 P 40000\ns4-eth2 M 20\n" > "$T/onpath.txt"
echo "minor=$(/usr/bin/awk '"'"'$2=="M"{printf "%s ", $1}'"'"' "$T/onpath.txt")"
echo "nP=$(/usr/bin/awk '"'"'$2=="P"{n++} END{print n+0}'"'"' "$T/onpath.txt") nM=$(/usr/bin/awk '"'"'$2=="M"{n++} END{print n+0}'"'"' "$T/onpath.txt")"
printf "{\"complete\": true, \"request_id\": \"r-7\"}" > "$T/d.json"
echo "complete=$(jqp "$T/d.json" "d.get('"'"'complete'"'"')") rid=$(jqp "$T/d.json" "d.get('"'"'request_id'"'"') or '"'"''"'"'")"
' _ "$LIVE" "$T" 2>&1 )"
chk "_common get_json (315): file:// JSON re-written sorted" "$(sed -n 's/^get_json //p' <<<"$out")" 'rc 0 {"a":[2],"b":1}'
chk "_common netdev_tx (701): every line 'sN-ethP <bytes>'" "$(sed -n 's/^netdev_tx rc \([0-9]*\) lines [0-9]* bad \([0-9]*\)/rc \1 bad \2/p' <<<"$out")" "rc 0 bad 0"
chk "_common minor list (1160)" "$(sed -n 's/^minor=//p' <<<"$out")" "s1-eth2 s4-eth2 "
chk "_common P/M counts (1168, 1169)" "$(sed -n 's/^\(nP=.*\)/\1/p' <<<"$out")" "nP=2 nM=2"
chk "07 jqp complete / request_id (496, 506)" "$(sed -n 's/^\(complete=.*\)/\1/p' <<<"$out")" "complete=True rid=r-7"
# the awk and jqp texts above are typed here; each must be, character for character, the file's
for pair in "_common.sh|/usr/bin/awk '\$2==\"M\"{printf \"%s \", \$1}'" \
            "_common.sh|/usr/bin/awk '\$2==\"P\"{n++} END{print n+0}'" \
            "_common.sh|/usr/bin/awk '\$2==\"M\"{n++} END{print n+0}'" \
            "07_roles_basic.sh|jqp \"\$out\" \"d.get('complete')\"" \
            "07_roles_basic.sh|jqp \"\$2.json\" \"d.get('request_id') or ''\""; do
    f="${pair%%|*}"; txt="${pair#*|}"
    /usr/bin/grep -qF -- "$txt" "$LIVE/$f" && echo "  ok    the text run above is $f's: $txt" \
        || { echo "  BAD   $f does not hold: $txt"; bad=1; }
done
# 07's ENTRY_TABLES block (549): cut out of the file, run on a two-switch package
prog="$(awk '/^ENTRY_TABLES="\$\("\$PY" -c "$/ {on=1; next} on && /" "\$PKG_ROLES"\)"$/ {sub(/" "\$PKG_ROLES"\)"$/, ""); print; exit} on {print}' "$LIVE/07_roles_basic.sh")"
mkdir -p "$T/pkg"
printf '{"switches": {"s1": {"entries": "s1.json"}, "s2": {"entries": "s2.json"}}}' > "$T/pkg/package.json"
printf '{"table_entries": [{"table": "MyIngress.ipv4_lpm", "default_action": true}]}' > "$T/pkg/s1.json"
printf '{"table_entries": [{"table": "MyIngress.ipv4_lpm", "default_action": true}]}' > "$T/pkg/s2.json"
chk "07 ENTRY_TABLES (549)" "$("$WT/p4_proxy/venv/bin/python" -c "$prog" "$T/pkg" 2>&1)" "[('MyIngress.ipv4_lpm', True)]"
# the spike's consts (200): the proxy's own constants, imported
chk "spike consts (200)" "$(cd "$WT" && env -u NDTWIN_P4_BEACON_S "$WT/p4_proxy/venv/bin/python" -c 'import sys; sys.path.insert(0, sys.argv[1])
from proxy_agent import topology_manager as t
print(t.LLDP_BEACON_INTERVAL_S, t.LINK_BEACON_TIMEOUT_S, t.LINK_WATCHDOG_INTERVAL_S)' "$WT/p4_proxy" 2>/dev/null | tail -1)" "5 15 5"
echo "RUNTIME-CHECK: $([[ $bad == 0 ]] && echo 'every never-executed program ran and answered as written' || echo BROKEN)"
exit $bad
