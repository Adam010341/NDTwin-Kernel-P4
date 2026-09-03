#!/usr/bin/env bash
#
# Tests for sflow_state / verify_sflow in tools/test_workflow/ndt -- the half of the fix for
# finding #4 that makes "nothing is sampling" visible.
#
# [Co-developed with claude code -- Adam]
#
# The defect: `ndt up ovs4` brought up ten bridges with `sflow=[]` on every one and printed
# `up. ready`. Every structural check above it was correct -- ten switches up and enabled, the
# kernel's graph matching the model file, h1 forwarding to h2 -- while the thing the operator
# was about to measure reported nothing. `/ndt/get_average_link_usage` answered
# `{"avg_link_usage":0.0,"status":"success"}` under 3000 packets of real traffic.
#
# 🔴 Both directions are tested, for the reason the sudo-surface tests give: an implementation
# that calls every fabric broken satisfies every "it must go red" case below and makes `ndt up
# ovs` impossible to complete. The cases marked "control" are the ones such an implementation
# fails, and the case marked "refused" is the one an implementation that folds a permission
# error into "not configured" fails -- that would send the operator to the topology script for
# a problem that is in sudoers.
#
# 🔴 And it is not enough to check that sflow is CONFIGURED. A record whose agent interface
# carries the wrong address (or none) produces datagrams the kernel parses, matches against no
# edge, and drops -- output identical to no datagrams at all. So the agent address is compared
# against the address the kernel's own model file declares for that switch, and there are cases
# for each way that can be wrong.
#
# No lab contact, no real sudo, no ovs-vsctl. Fakes on PATH answer with recorded OVS output;
# nothing here starts a topology, binds a port or touches a claim -- another session may be
# measuring.
#
# Run:  bash tests/shell/test_ovs4_sflow_verify.sh
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate sets it)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="${NDT_UNDER_TEST:-$REPO/tools/test_workflow/ndt}"
MODEL="$REPO/setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json"

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n    %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: $2 / actual: $3"; }
has()   { grep -q -- "$2" <<<"$3" && t_ok "$1" || t_bad "$1" "no match for '$2' in: $3"; }
hasnt() { grep -q -- "$2" <<<"$3" && t_bad "$1" "unexpected '$2' in: $3" || t_ok "$1"; }

BIN="$(mktemp -d "${TMPDIR:-/tmp}/ndt-sflow-fakes-XXXXXX")"
trap 'rm -rf "$BIN"' EXIT

# --- the fakes -------------------------------------------------------------------------------
# `sudo` refuses whatever FAKE_SUDO_DENY names, with sudo's own measured wording, and otherwise
# runs it -- so the code under test sees a real exit status and a real stderr.
cat >"$BIN/sudo" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == "-n" ]] && shift
base="${1##*/}"
case " ${FAKE_SUDO_DENY:-} " in
    *" $base "*) echo "sudo: a password is required" >&2; exit 1 ;;
esac
exec "$@"
FAKE

# ovs-vsctl answers the two queries sflow_state makes, from FAKE_BRIDGE_ROWS / FAKE_SFLOW_ROWS,
# in the CSV shape real ovs-vsctl produces for --format=csv --no-headings --data=bare.
#
# FAKE_FAIL_QUERY fails exactly ONE of the two. That distinction is load-bearing: with both
# failing together, dropping the guard on the first query is invisible because the guard on the
# second one produces the same verdict -- the mutation gate found that survivor.
cat >"$BIN/ovs-vsctl" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${FAKE_OVSDB_DOWN:-}" ]]; then
    echo "ovs-vsctl: unix:/var/run/openvswitch/db.sock: database connection failed" >&2
    exit 1
fi
for a in "$@"; do
    case "$a" in
        --columns=*)
            if [[ -n "${FAKE_FAIL_QUERY:-}" && "$a" == "--columns=${FAKE_FAIL_QUERY}" ]]; then
                echo "ovs-vsctl: unix:/var/run/openvswitch/db.sock: database connection failed" >&2
                exit 1
            fi ;;
    esac
    case "$a" in
        --columns=name,sflow)          printf '%s\n' "${FAKE_BRIDGE_ROWS:-}"; exit 0 ;;
        --columns=_uuid,agent,targets) printf '%s\n' "${FAKE_SFLOW_ROWS:-}";  exit 0 ;;
    esac
done
exit 1
FAKE

# `ip -4 -o addr show [dev X]`, from FAKE_ADDRS ("iface ip" pairs, one per line). Faked rather
# than stubbed so the parsing in iface_ipv4/local_ipv4s is exercised too.
cat >"$BIN/ip" <<'FAKE'
#!/usr/bin/env bash
dev=""
for (( i=1; i<=$#; i++ )); do
    [[ "${!i}" == "dev" ]] && { j=$((i+1)); dev="${!j}"; }
done
n=0
while read -r iface addr; do
    [[ -z "$iface" ]] && continue
    [[ -n "$dev" && "$iface" != "$dev" ]] && continue
    n=$((n+1))
    echo "$n: $iface    inet $addr/24 brd 10.255.255.255 scope global $iface"
done <<<"${FAKE_ADDRS:-}"
exit 0
FAKE

chmod +x "$BIN"/sudo "$BIN"/ovs-vsctl "$BIN"/ip
PATH="$BIN:$PATH"; export PATH

# --- fixtures --------------------------------------------------------------------------------
# %08d, not '0000000$1': with $1=10 that is nine characters in the first group, which is not a
# uuid and which sflow_state's pattern correctly refuses to match. The fixture was wrong, not
# the code -- and only the control cases showed it, which is what the controls are for.
uuid() { printf '%08d-0000-0000-0000-000000000000\n' "$1"; }

# A healthy fabric: ten bridges, one record each, agents carrying the addresses the model file
# declares, target on the collector.
healthy_bridges() { local i; for i in $(seq 1 10); do echo "s$i,$(uuid "$i")"; done; }
healthy_records() { local i; for i in $(seq 1 10); do echo "$(uuid "$i"),s$i-eth1,127.0.0.1:6343"; done; }
healthy_addrs()   { local i; echo "lo 127.0.0.1"; for i in $(seq 1 10); do echo "s$i-eth1 192.168.123.$((10+i))"; done; }

# Each case runs in its own subshell with ndt sourced as a library, so nothing leaks between
# cases and no case can be masked by an earlier one having already returned.
in_ndt() { NDT_LIB_ONLY=1 bash -c "source '$NDT' >/dev/null 2>&1; $1" 2>&1; }

state() {   # state <bridge-rows> <sflow-rows> <addrs> [extra env assignments]
    FAKE_BRIDGE_ROWS="$1" FAKE_SFLOW_ROWS="$2" FAKE_ADDRS="$3" \
    in_ndt "${4:-} sflow_state '$MODEL'; echo rc=\$?; printf '%s\n' \"\${NDT_SFLOW_PROBLEMS[@]}\"; echo summary=\$NDT_SFLOW_SUMMARY; echo why=\$NDT_SFLOW_WHY"
}

verify() {  # verify <bridge-rows> <sflow-rows> <addrs> [extra env assignments]
    FAKE_BRIDGE_ROWS="$1" FAKE_SFLOW_ROWS="$2" FAKE_ADDRS="$3" \
    in_ndt "${4:-} verify_sflow '$MODEL'; echo rc=\$?"
}

echo "the defect: bridges that sample nothing"

# The measured state on 2026-09-02: ten bridges, `sflow=[]` on all of them, and a green
# bring-up. This is the case the whole change exists for.
out="$(state "$(for i in $(seq 1 10); do echo "s$i,"; done)" "" "$(healthy_addrs)")"
has "the fabric from finding #4 is red"                       "rc=1"                  "$out"
has "  ... and names a bridge that samples nothing"           "s1: no sFlow record"   "$out"
has "  ... and says what the operator will see instead"       "reads zero"            "$out"
has "  ... and counts how many are sampling"                  "summary=0/10"          "$out"

out="$(verify "$(for i in $(seq 1 10); do echo "s$i,"; done)" "" "$(healthy_addrs)")"
has "verify_sflow fails the bring-up"                         "rc=1"                  "$out"
has "  ... and says the API will answer 0.0 with success"     "0.0"                   "$out"

# One bridge short. The nine-of-ten shape: a loop that stops early, or a switch added later.
b="$(healthy_bridges | sed 's/^s7,.*/s7,/')"
out="$(state "$b" "$(healthy_records | grep -v '^00000007')" "$(healthy_addrs)")"
has "one bridge not sampling is red"                          "rc=1"                  "$out"
has "  ... and it is named"                                   "s7: no sFlow record"   "$out"
hasnt "  ... and the other nine are not blamed"               "s6: no sFlow"          "$out"

echo
echo "configured, but reporting something the kernel cannot use"

# 🔴 The agent address is what the kernel matches a sample to an edge by. Wrong address =
# datagrams that parse, match nothing, and read exactly like no datagrams.
a="$(healthy_addrs | sed 's|^s4-eth1 .*|s4-eth1 10.9.9.9|')"
out="$(state "$(healthy_bridges)" "$(healthy_records)" "$a")"
has "an agent address the model does not declare is red"      "rc=1"                     "$out"
has "  ... and both addresses are printed"                    "10.9.9.9"                 "$out"
has "  ... and the model's is printed too"                    "192.168.123.14"           "$out"

# No address at all: OVS falls back to the route source address, identical for all ten.
a="$(healthy_addrs | grep -v '^s2-eth1 ')"
out="$(state "$(healthy_bridges)" "$(healthy_records)" "$a")"
has "an agent interface with no IPv4 is red"                  "rc=1"                     "$out"
has "  ... and says why one address for ten switches is bad"  "no IPv4 address"          "$out"

# A record with an empty agent column: same fallback, reached a different way.
r="$(healthy_records | sed 's|^\(00000003-[^,]*\),[^,]*,|\1,,|')"
out="$(state "$(healthy_bridges)" "$r" "$(healthy_addrs)")"
has "a record naming no agent interface is red"               "rc=1"                     "$out"
has "  ... and says the kernel will match no edge"            "no agent interface"       "$out"

# The port the datagrams are sent to. A typo here is silent: OVS accepts it, the switch samples
# happily, and nothing ever arrives.
r="$(healthy_records | sed 's|127.0.0.1:6343|127.0.0.1:6344|')"
out="$(state "$(healthy_bridges)" "$r" "$(healthy_addrs)")"
has "a target on the wrong port is red"                       "rc=1"                     "$out"
has "  ... and names the port the collector is on"            ":6343"                    "$out"

# An address that is not on this machine.
r="$(healthy_records | sed 's|127.0.0.1:6343|10.4.4.4:6343|')"
out="$(state "$(healthy_bridges)" "$r" "$(healthy_addrs)")"
has "a target that is not a local address is red"             "rc=1"                     "$out"
has "  ... and says nothing will arrive"                      "not an address on this machine" "$out"

echo
echo "the loosening shapes -- configured MORE than once, or onto nothing"

# Two records referenced by one bridge. A checker asking only "is the column non-empty" signs
# this off, and so does one asking "is there at least one record per bridge".
b="$(healthy_bridges | sed "s|^s5,.*|s5,\"[$(uuid 5),$(uuid 9)]\"|")"
out="$(state "$b" "$(healthy_records)" "$(healthy_addrs)")"
has "a bridge referencing two records is red"                 "rc=1"                     "$out"
has "  ... and says a bridge samples to one"                  "s5: 2 sFlow records"      "$out"

# A record nothing points at -- what a second `create sflow` leaves behind, and what `set
# bridge s11 sflow=@sflow` leaves when s11 does not exist. Invisible to any per-bridge check.
r="$(healthy_records; echo "$(uuid 99),s99-eth1,127.0.0.1:6343")"
out="$(state "$(healthy_bridges)" "$r" "$(healthy_addrs)")"
has "an sFlow record no bridge references is red"             "rc=1"                     "$out"
has "  ... and says it is a configuration that ran twice"     "ran twice"                "$out"

echo
echo "refused: a permission error is not a verdict about telemetry"

# 🔴 The whole point of the third state. Folded into "not configured", this sends the operator
# to the topology script for a problem that is in sudoers.
out="$(state "$(healthy_bridges)" "$(healthy_records)" "$(healthy_addrs)" "export FAKE_SUDO_DENY=ovs-vsctl;")"
has "a refused ovs-vsctl returns 2, not 1"                    "rc=2"                     "$out"
has "  ... and says it was sudo"                              "why=sudo refused ovs-vsctl" "$out"
hasnt "  ... and accuses no bridge"                           "no sFlow record"          "$out"

out="$(verify "$(healthy_bridges)" "$(healthy_records)" "$(healthy_addrs)" "export FAKE_SUDO_DENY=ovs-vsctl;")"
has "verify_sflow reports NOT tested"                         "NOT tested"               "$out"
has "  ... and prints the sudoers line that fixes it"         "NOPASSWD"                 "$out"
hasnt "  ... and does not claim the fabric is fine"           "ok       sFlow"           "$out"
# 🔴 control, and the reason this is a warn and not an err: failing the bring-up on a machine
# whose sudoers the manual actually teaches would make `ndt up ovs4` impossible to run there.
# A grant that is missing is a thing to say, not a thing to stop on. (verify_dataplane makes
# exactly this distinction for mnexec, and for exactly this reason.)
has "control: a refusal does not fail the bring-up"           "rc=0"                     "$out"

# ovsdb down is not sudo, and must not be reported as sudo.
out="$(state "$(healthy_bridges)" "$(healthy_records)" "$(healthy_addrs)" "export FAKE_OVSDB_DOWN=1;")"
has "ovsdb down also returns 2"                               "rc=2"                     "$out"
has "  ... and the reason is ovs-vsctl's, not sudo's"         "database connection failed" "$out"

# An answer with no bridges in it is not ten healthy bridges.
out="$(state "" "" "$(healthy_addrs)")"
has "an empty bridge list is 'could not tell', not a pass"    "rc=2"                     "$out"

# 🔴 Each query is guarded on its own. Both failing together hides a missing guard on either
# one: the survivor sees the OTHER guard produce the same verdict and reports nothing. So each
# is failed alone, and what is asserted is the REASON, which is the half that differs.
out="$(state "$(healthy_bridges)" "$(healthy_records)" "$(healthy_addrs)" "export FAKE_FAIL_QUERY=name,sflow;")"
has "a failed bridge query is 'could not tell'"               "rc=2"                     "$out"
has "  ... reported with the reason ovs-vsctl gave"           "database connection failed" "$out"
hasnt "  ... and not as an empty fabric"                      "listed no bridges"        "$out"

out="$(state "$(healthy_bridges)" "$(healthy_records)" "$(healthy_addrs)" "export FAKE_FAIL_QUERY=_uuid,agent,targets;")"
has "a failed record query is 'could not tell'"               "rc=2"                     "$out"
has "  ... reported with the reason ovs-vsctl gave, too"      "database connection failed" "$out"
hasnt "  ... and not as ten bridges sampling nothing"         "no sFlow record"          "$out"

echo
echo "control: a correctly sampling fabric must NOT be red"
# Without these, an implementation that fails every fabric passes every case above and makes
# `ndt up ovs4` impossible to complete.

out="$(state "$(healthy_bridges)" "$(healthy_records)" "$(healthy_addrs)")"
has "control: the healthy fabric passes"                      "rc=0"                     "$out"
has "control: and says how many bridges are sampling"         "summary=10/10"            "$out"

out="$(verify "$(healthy_bridges)" "$(healthy_records)" "$(healthy_addrs)")"
has "control: verify_sflow returns 0"                         "rc=0"                     "$out"
has "control: and reports ok"                                 "ok"                       "$out"

# The other reference topology targets 192.168.123.1 (aliased onto lo), not 127.0.0.1. The
# check must accept any address this machine actually holds, or `ndt up ovs` goes red on a
# fabric that is sampling correctly.
r="$(healthy_records | sed 's|127.0.0.1:6343|192.168.123.1:6343|')"
a="$(healthy_addrs; echo "lo 192.168.123.1")"
out="$(state "$(healthy_bridges)" "$r" "$a")"
has "control: the 128-host topology's collector alias passes" "rc=0"                     "$out"

echo
echo "wiring: existence is not wiring"
# A verify_sflow nobody calls leaves the bring-up exactly as green as it was. Read off the
# PARSED function rather than the file text, and asserted beside the check it belongs with: a
# bring-up that verifies forwarding and not telemetry is the state this change started from.
out="$(in_ndt "declare -f up_ovs")"
has "up_ovs calls verify_sflow"                               "verify_sflow"     "$out"
has "  ... beside the forwarding check it belongs with"       "verify_dataplane" "$out"
out="$(in_ndt "declare -f verify_sflow")"
has "verify_sflow takes its verdict from sflow_state"         "sflow_state"      "$out"

echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
