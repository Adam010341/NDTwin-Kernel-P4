#!/usr/bin/env bash
#
# What does `ndt status --check` compare the running lab against?
#
# [Co-developed with claude code -- Adam]
#
# FINDING #8, measured 2026-09-02 23:41-23:42 on a healthy 4-host OVS fabric
# (doc/audit/2026-09-03_night-rounds/round1-ovs/05_, 07_):
#
#     configuration
#       hosts          128                                                    <- fabric has 4
#       topology       setting/StaticNetworkTopologyP4_10Switches_128Hosts.json  <- fabric is OVS
#     network health
#       model          MISMATCH: graph has 4 hosts / 40 edges, file says 128 288
#     check: 1 problem(s)
#       - the kernel graph does not match the topology file
#     CHECK_RC=1
#
# Both numbers came from p4_proxy/mininet/host_count_override, a P4-ONLY knob that
# `ndt up ovs4` never writes. That is the false red. The second half of the finding is worse
# and is the reason this suite exists at all: setting the knob "correctly" does not fix it,
# because the comparison was (hosts, edges) and BOTH 4-host models are (4, 40) --
#
#     StaticNetworkTopologyP4_10Switches_4Hosts.json    4 hosts  40 edges
#     StaticNetworkTopologyOVS_10Switches_4Hosts.json   4 hosts  40 edges
#
# -- so the check went GREEN while comparing an OVS fabric against a P4 model file. A check
# that cannot tell the two data planes apart has zero discriminating power on either.
#
# Adam's decision, 2026-09-03 (QUESTIONS-FOR-ADAM N12 (a)): the baseline is the TARGET OF THE
# LAST `ndt up`, recorded by `up` in .test_run/up.target and compared by `--check`.
#
# 🔴 THREE DIRECTIONS, because "compare more things" has two obvious wrong answers:
#   * a check that is always GREEN passes group 1 and fails groups 2, 3, 5;
#   * a check that is always RED fails groups 1 and 6 (the P4 arm, which must still pass);
#   * a check that answers "could not check" to everything fails groups 1, 2 and 6.
# Group 3 pins the third state separately: with no record, --check must say so in its own
# words and with its own exit code, and must NEVER print the mismatch sentence or "ok".
# "Could not check" is not "checked and matched".
#
# Offline and fixture-driven. REPO is redirected into a temp dir, so setting/, the host-count
# override, the record and the kernel's graph are all files this suite wrote; every process
# and privilege probe is stubbed. No lab, no sudo, no port, no network.
#
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_ndt_status_check_baseline.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; exit 2; }
# ndt sources two tables from beside itself and exits 2 when either is missing; sourced with
# output discarded that would kill this suite with no message at all.
for sib in ports.sh sudo_surface.sh; do
    [[ -r "$(dirname "$NDT")/$sib" ]] || { echo "ndt needs $sib beside it; not at $(dirname "$NDT")/$sib"; exit 2; }
done

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: [$2]  actual: [$3]"; }
has()   { grep -qF -- "$2" <<<"$3" && t_ok "$1" || t_bad "$1" "no match for '$2'"; }
hasnt() { grep -qF -- "$2" <<<"$3" && t_bad "$1" "unexpected '$2' in the output" || t_ok "$1"; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-checkbase-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/.test_run" "$FIX/setting" "$FIX/p4_proxy/mininet"

# --- fixtures ---------------------------------------------------------------------------
# Topology models with the counts that make the finding what it is: the two 4-host models are
# indistinguishable on (hosts, edges), and the 128-host P4 model is the one the knob selects.
mk_topo() {   # <file> <hosts> <edges>
    python3 - "$FIX/setting/$1" "$2" "$3" <<'PY'
import json, sys
p, h, e = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
nodes = [{"vertex_type": 0, "id": i} for i in range(10)]
nodes += [{"vertex_type": 1, "id": 1000 + i} for i in range(h)]
edges = [{"src": i % 10, "dst": (i + 1) % 10} for i in range(e)]
json.dump({"nodes": nodes, "edges": edges}, open(p, "w"))
PY
}
mk_topo StaticNetworkTopologyOVS_10Switches_4Hosts.json    4   40
mk_topo StaticNetworkTopologyP4_10Switches_4Hosts.json     4   40
mk_topo StaticNetworkTopologyP4_10Switches_128Hosts.json   128 288
OVS4="setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json"
P4_4="setting/StaticNetworkTopologyP4_10Switches_4Hosts.json"

# The kernel's answer on :8000, as graph_summary parses it.
mk_graph() {  # <hosts> <edges>
    python3 - "$FIX/graph.json" "$1" "$2" <<'PY'
import json, sys
p, h, e = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
sw = [{"vertex_type": 0, "is_up": True, "is_enabled": True, "admin_disabled": False, "id": i}
      for i in range(10)]
sw += [{"vertex_type": 1, "id": 1000 + i} for i in range(h)]
ed = [{"is_up": True, "admin_disabled": False, "src": i % 10, "dst": (i + 1) % 10} for i in range(e)]
json.dump({"nodes": sw, "edges": ed}, open(p, "w"))
PY
}
no_graph() { rm -f "$FIX/graph.json"; }

knob() { printf '%s\n' "$1" > "$FIX/p4_proxy/mininet/host_count_override"; }

# The record, written by hand in the format `ndt` documents beside up_target_file(). Written
# rather than produced by record_up_target on purpose: these cases must describe the BEHAVIOUR
# of --check, not depend on the writer they are also testing (group 7 tests the writer).
record() {    # <plane> <hosts> <topology-relative-path> [sha-override]
    local plane="$1" h="$2" topo="$3" sum="${4:-}" counts
    counts="$(python3 -c '
import json,sys; t=json.load(open(sys.argv[1]))
print(sum(1 for n in t["nodes"] if n.get("vertex_type")==1), len(t["edges"]))' "$FIX/$topo")"
    [[ -n "$sum" ]] || sum="$(sha256sum "$FIX/$topo" | cut -d' ' -f1)"
    printf 'plane=%s\nhosts=%s\ntopology=%s\ntopology_sha256=%s\nmodel_hosts=%s\nmodel_edges=%s\nat=%s\nby=%s\nbuilder=up_%s\n' \
        "$plane" "$h" "$topo" "$sum" "${counts%% *}" "${counts##* }" "$(date +%s)" "fixture" "$plane" \
        > "$FIX/.test_run/up.target"
}
no_record() { rm -f "$FIX/.test_run/up.target"; }

# --- the seam ---------------------------------------------------------------------------
# ndt is sourced (it returns at its own source seam), REPO is redirected at the fixture, and
# every reading that would otherwise describe THIS machine is answered by an FX_ variable.
# What is NOT stubbed is the whole point: host_count, topo_for_hosts, graph_summary, the
# up-target reader and the comparison itself all run for real, against fixture files.
STUBS='
REPO="'"$FIX"'"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
MANIFEST="$REPO/manifest.json"
claim_line() { echo none; }
git_lines() { :; }
in_flight() { :; }
foreign_claim() { :; }
sample_rate() { echo 256; }
bmv2_binary() { echo "fixture-bmv2"; }
stale_pipeline() { return 1; }
source_ahead_of_build() { return 1; }
bmv2_count() { echo "${FX_BMV2:-0}"; }
mn_count() { echo "${FX_MN:-14}"; }
fabric_host_count() { echo "${FX_FABRIC_HOSTS:-0}"; }
ovs_bridge_count() { [[ -n "${FX_OVS_CANNOT_TELL:-}" ]] && return 2; echo "${FX_BRIDGES:-0}"; }
ovs_daemon_running() { [[ "${FX_BRIDGES:-0}" -gt 0 ]]; }
topo_session() { [[ -n "${FX_TOPO_SESSION:-1}" ]]; }
port_open() { case "$1" in 8000) [[ -s "$REPO/graph.json" ]] ;; *) return 1 ;; esac; }
http_get_graph() { [[ -s "$REPO/graph.json" ]] && cat "$REPO/graph.json"; }
netem_count() { echo 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
app_probe() { APP_STATE=not-running; }
# Finding #83 added a second thing `--check` compares: the installed /usr/local/sbin/ndtwin-lab
# against tools/test_workflow/ndtwin-lab. On this machine those really do differ, so without
# this stub every "exits 0" case below would be red about the helper -- a true statement, and
# not the one this suite is making. Pinned to "same" so an exit code here is about the up-target
# baseline, which is what group 1-8 are for. tests/shell/test_ndt_up_down_robust.sh is where the
# helper comparison itself is tested, in both directions. [Co-developed with claude code -- Adam]
lab_version_verdict() { echo "same fixture-sha fixture-sha"; }
'
run_check() {   # -> the whole report plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
cmd_status --check
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
# A healthy 4-host OVS fabric: ten bridges, no bmv2, four host namespaces, kernel graph 4/40.
healthy_ovs4() {
    export FX_BMV2=0 FX_BRIDGES=10 FX_FABRIC_HOSTS=4 FX_MN=14
    unset FX_OVS_CANNOT_TELL
    mk_graph 4 40
}

# ==========================================================================================
section "1. the ovs4 false red: a healthy 4-host OVS fabric is GREEN"
# The measured case, verbatim: the knob says 128 because nothing on the OVS path writes it.
knob 128
record ovs 4 "$OVS4"
healthy_ovs4
OUT="$(run_check)"
check "a healthy ovs4 exits 0"                          "0"    "$(rc_of "$OUT")"
has   "and says so"                                     "check: ok" "$OUT"
hasnt "🔴 no false red about the topology file"         "the kernel graph does not match the topology file" "$OUT"
hasnt "🔴 and the P4 128-host model is not the baseline" "StaticNetworkTopologyP4_10Switches_128Hosts.json" "$OUT"
has   "it names the fabric it was asked for"            "ovs, 4 hosts" "$OUT"
has   "and the model file that goes with it"            "$OVS4" "$OUT"
has   "configuration reports 4 hosts, not the knob's 128" "hosts          4" "$OUT"
has   "the P4 knob is still shown, named for what it is" "p4 host knob" "$OUT"
has   "it prints what it compared: the data plane"      "dataplane" "$OUT"
has   "  the fabric-side host count"                    "fabric hosts" "$OUT"
has   "  the kernel graph"                              "graph hosts" "$OUT"
# The row, not the words: trunk's single failure sentence also contains "topology file", so a
# looser assertion here was green against the code this suite exists to fail.
has   "  and the identity of the model file"            "topology file  sha256" "$OUT"

section "2. zero discriminating power: a P4 fabric where ovs4 was asked for is RED"
# The knob is set "correctly" here (4), which is what made the old check GREEN: it compared
# the kernel graph (4, 40) against the P4 4-host model (4, 40) and matched -- while the plane
# underneath was the wrong one. Everything except the data plane agrees, deliberately.
knob 4
record ovs 4 "$OVS4"
export FX_BMV2=10 FX_BRIDGES=0 FX_FABRIC_HOSTS=4
unset FX_OVS_CANNOT_TELL
mk_graph 4 40
OUT="$(run_check)"
check "🔴 a P4 fabric under an ovs4 record is not ok"   "1"    "$(rc_of "$OUT")"
hasnt "  and it is NOT reported as checked-and-matched" "check: ok" "$OUT"
has   "the mismatch names the field: dataplane"         "dataplane: the lab has 'p4', the last 'ndt up' asked for 'ovs'" "$OUT"
has   "  and shows it in the comparison"                "MISMATCH" "$OUT"
hasnt "  host count is NOT what differs (it agrees)"    "graph hosts: the lab has" "$OUT"

section "3. no record: 'could not check' has its own words and its own exit code"
knob 128
no_record
healthy_ovs4
OUT="$(run_check)"
check "🔴 no baseline exits 3, not 0 and not 1"         "3"    "$(rc_of "$OUT")"
has   "  and says it could not check"                   "COULD NOT CHECK" "$OUT"
hasnt "  never the mismatch sentence"                   "the kernel graph does not match the topology file" "$OUT"
hasnt "  never 'ok'"                                    "check: ok" "$OUT"
has   "  it says where the record would be"             ".test_run/up.target" "$OUT"
has   "  and that .test_run is per checkout (#79)"      "per checkout" "$OUT"

# The direction that matters most, and the one the old code got exactly wrong: with the knob
# agreeing with the graph by coincidence, the old check printed "check: ok" and exited 0 --
# a pass produced with no baseline at all.
knob 4
no_record
export FX_BMV2=10 FX_BRIDGES=0 FX_FABRIC_HOSTS=4
mk_graph 4 40
OUT="$(run_check)"
check "🔴 a coincidence must not be reported as a pass" "3"    "$(rc_of "$OUT")"
hasnt "  'could not check' is never 'checked and matched'" "check: ok" "$OUT"

section "4. a mismatch names the field that differs"
knob 4
record ovs 4 "$OVS4"
export FX_BMV2=0 FX_BRIDGES=10 FX_FABRIC_HOSTS=4
mk_graph 128 288
OUT="$(run_check)"
check "a 128-host graph under a 4-host record is red"   "1"    "$(rc_of "$OUT")"
has   "  and the field is named"                        "graph hosts: the lab has '128', the last 'ndt up' asked for '4'" "$OUT"

mk_graph 4 31
OUT="$(run_check)"
check "a link-count dip in the kernel graph is red"     "1"    "$(rc_of "$OUT")"
has   "  and the field is named"                        "graph edges: the lab has '31'" "$OUT"

mk_graph 4 40
export FX_FABRIC_HOSTS=128
OUT="$(run_check)"
check "a 128-host FABRIC under a 4-host record is red"  "1"    "$(rc_of "$OUT")"
has   "  and the field is named"                        "fabric hosts: the lab has '128'" "$OUT"

section "5. a reading that could not be taken is RED, never green"
export FX_FABRIC_HOSTS=0
OUT="$(run_check)"
check "no host namespaces at all is red"                "1"    "$(rc_of "$OUT")"
has   "  named as not compared, not as agreement"       "fabric hosts: could not be compared" "$OUT"

export FX_FABRIC_HOSTS=4 FX_BMV2=0 FX_BRIDGES=0 FX_OVS_CANNOT_TELL=1
OUT="$(run_check)"
check "🔴 a refused ovs-vsctl is not 'no OVS here'"     "1"    "$(rc_of "$OUT")"
has   "  it is reported as an unanswered question"      "dataplane: could not be compared" "$OUT"
hasnt "  and is not reported as a match"                "check: ok" "$OUT"
unset FX_OVS_CANNOT_TELL

export FX_BRIDGES=10
no_graph
OUT="$(run_check)"
check "a kernel that answers nothing is red"            "1"    "$(rc_of "$OUT")"
has   "  named as the kernel graph, not as a mismatch"  "kernel graph: could not be compared" "$OUT"

healthy_ovs4
cp "$FIX/$OVS4" "$FIX/$OVS4.bak"
python3 -c "
import json,sys
p=sys.argv[1]; t=json.load(open(p)); t['edges'].append({'src':0,'dst':9}); json.dump(t,open(p,'w'))" "$FIX/$OVS4"
OUT="$(run_check)"
check "the model file edited under a running kernel is red" "1" "$(rc_of "$OUT")"
has   "  and it says the file changed, naming it"       "topology file: $OVS4 has been edited since the ndt up that loaded it" "$OUT"
mv -f "$FIX/$OVS4.bak" "$FIX/$OVS4"

section "6. 🔴 the other direction: it is not simply always red"
# Every check in groups 2-5 would pass for an implementation that reports a problem whatever
# it is given. These are the cases that must stay green -- including the P4 plane, which the
# fix must not break while making the OVS plane work.
knob 4
record p4 4 "$P4_4"
export FX_BMV2=10 FX_BRIDGES=0 FX_FABRIC_HOSTS=4
mk_graph 4 40
OUT="$(run_check)"
check "a healthy P4 fabric under a p4 record is ok"     "0"    "$(rc_of "$OUT")"
has   "  and it says what it compared"                  "check: ok" "$OUT"
has   "  naming the plane it was asked for"             "p4, 4 hosts" "$OUT"

knob 128
record ovs 4 "$OVS4"
healthy_ovs4
OUT="$(run_check)"
check "and the ovs4 case is still ok after all of that" "0"    "$(rc_of "$OUT")"

section "7. the record itself: written by 'up', read by '--check', dropped by 'down'"
# The writer, through the same source seam. Group 1-6 never call it, so a writer that wrote
# nothing at all would pass everything above.
lib() { bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
$1" 2>&1; }
rm -f "$FIX/.test_run/up.target"
OUT="$(lib "record_up_target ovs 4 \"\$REPO/$OVS4\" >/dev/null; cat \"\$REPO/.test_run/up.target\"")"
has   "record_up_target writes the plane"               "plane=ovs" "$OUT"
has   "  the host count"                                "hosts=4" "$OUT"
has   "  the topology path, relative to the repo"       "topology=$OVS4" "$OUT"
has   "  the counts that file declares"                 "model_edges=40" "$OUT"
check "  and the file's sha256 as it was at 'up' time"  "$(sha256sum "$FIX/$OVS4" | cut -d' ' -f1)" \
      "$(sed -n 's/^topology_sha256=//p' <<<"$OUT")"
OUT="$(lib "up_target_field plane; up_target_field hosts")"
check "up_target_field reads them back"                 "ovs
4" "$OUT"
OUT="$(lib "clear_up_target >/dev/null; [[ -f \"\$REPO/.test_run/up.target\" ]] && echo present || echo gone")"
check "clear_up_target removes it ('down' calls it)"    "gone" "$OUT"

# The predicate the whole discrimination rests on.
OUT="$(lib "bmv2_count() { echo 10; }; ovs_bridge_count() { echo 0; }; live_dataplane_kind")"
check "live_dataplane_kind: bmv2 running is p4"         "p4"  "$OUT"
OUT="$(lib "bmv2_count() { echo 0; }; ovs_bridge_count() { echo 10; }; live_dataplane_kind")"
check "  bridges and no bmv2 is ovs"                    "ovs" "$OUT"
OUT="$(lib "bmv2_count() { echo 0; }; ovs_bridge_count() { echo 0; }; live_dataplane_kind")"
check "  neither is 'none'"                             "none" "$OUT"
OUT="$(lib "bmv2_count() { echo 0; }; ovs_bridge_count() { return 2; }; live_dataplane_kind")"
check "🔴 a refused ovs-vsctl is 'unknown', not 'none'" "unknown" "$OUT"

section "8. the wiring: 'up' really writes it and 'down' really drops it"
# 🔴 EXISTENCE IS NOT WIRING. Everything above would pass with record_up_target defined and
# never called -- and then `--check` would answer "could not check" forever, which is exactly
# the shape of failure this project keeps finding (a mechanism that exists beside the path
# that needed it). So the two builders and the teardown are driven for real, far enough to
# reach the call and no further: STACK points at nothing, so the step after the record fails
# immediately and no lab is touched.
up_run() {   # <the up call> -- returns the record's contents, or NONE
    bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
STACK='$FIX/no-such-stack.sh'
LAB='$FIX/no-such-lab'
sudo() { return 1; }
preflight() { return 0; }
foreign_claim() { :; }
in_flight() { :; }
mn_count() { echo 0; }
bmv2_count() { echo 10; }
fabric_host_count() { echo 4; }
topo_session() { return 0; }
stale_pipeline() { return 1; }
guard_no_live_ovs() { return 0; }
sample_rate() { echo 256; }
verify_sflow() { return 0; }
$1 >/dev/null 2>&1
cat \"\$REPO/.test_run/up.target\" 2>/dev/null || echo NONE" 2>/dev/null
}
knob 4
rm -f "$FIX/.test_run/up.target"
OUT="$(up_run 'up_ovs 4')"
has   "'ndt up ovs4' records its target"                "plane=ovs" "$OUT"
has   "  with the host count it was asked for"          "hosts=4" "$OUT"
has   "  and the OVS model, not the P4 one"             "topology=$OVS4" "$OUT"

rm -f "$FIX/.test_run/up.target"
OUT="$(up_run 'up_p4')"
has   "'ndt up p4' records its target too"              "plane=p4" "$OUT"
has   "  with the P4 model"                             "topology=$P4_4" "$OUT"

# And `down` drops it, so an idle machine answers "could not check" rather than going red
# about a fabric nobody asked for.
record ovs 4 "$OVS4"
OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
STACK='$FIX/no-such-stack.sh'; LAB='$FIX/no-such-lab'
sudo() { return 1; }; foreign_claim() { :; }; in_flight() { :; }
app_probe() { APP_STATE=not-running; }
cmd_clean() { return 0; }
cmd_down >/dev/null 2>&1
[[ -f \"\$REPO/.test_run/up.target\" ]] && echo still-there || echo gone" 2>/dev/null)"
check "'ndt down' drops the record"                     "gone" "$OUT"

section "9. 🔴 the nickname overlay is named and NOT compared (W10)"
# [Co-developed with claude code -- Adam]
#
# Measured live on OVS, 2026-09-05: one POST /ndt/modify_nickname, a two-line diff on
# setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json, and `ndt status --check` rc=1 saying
# "the topology file has been edited since the ndt up that loaded it". Two controls in the same
# run showed that was this check WORKING and not failing -- renaming and renaming back left the
# file byte-identical and the check green, and a writer with nothing to do with nicknames earned
# the identical sentence. So an operator naming a switch made the one question worth asking
# ("is my environment still what I brought up?") answer red, about something they had not done.
#
# Adam's decision, 2026-09-05 18:1x (W10): the names go to an overlay outside setting/, `--check`
# does not look at it, and the kernel lays it back on at startup. These cases are the "--check
# does not look at it" half. The kernel half is tests/test_NicknameOverlay.cpp.
knob 128
record ovs 4 "$OVS4"
healthy_ovs4
OVERLAY="$FIX/.test_run/nickname_overlay/$(basename "${OVS4%.json}").names.json"
mkdir -p "$(dirname "$OVERLAY")"

# Before anything is written: the row exists and names the file it looked for.
#
# 🔴 It must NOT say "none set". Measured live 2026-09-06 07:15: this row said
# `none set through the API` three times on an OVS fabric where a nickname HAD been set and
# had survived a down/up -- the kernel writes from its own cwd (stack.sh starts it in build/)
# and this row read the checkout root. The kernel's anchor is fixed; the wording is fixed too,
# because they are two different faults and only one of them was a path.
OUT="$(run_check)"
has   "the report names the overlay even when absent"   "device names" "$OUT"
has   "  it says the FILE is missing, not that no name is set" "no overlay file at .test_run/nickname_overlay/" "$OUT"
hasnt "🔴 it never claims none are set"                 "none set through the API" "$OUT"
has   "  and says so out loud"                          "not a claim that none are set" "$OUT"

# The overlay the kernel would have written for two renamed switches.
cat > "$OVERLAY" <<'JSON'
{
  "version": 1,
  "topology": "setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json",
  "switches": {"1": {"nickname": "core-a"}, "2": {"nickname": "core-b"}},
  "hosts": {}
}
JSON
OUT="$(run_check)"
check "🔴 renaming two switches leaves --check GREEN"   "0"    "$(rc_of "$OUT")"
has   "  the topology row is still ok"                  "topology file  sha256" "$OUT"
hasnt "  and NOT 'CHANGED SINCE up'"                    "CHANGED SINCE up" "$OUT"
hasnt "  nor the sentence that misled the operator"     "has been edited since the ndt up that loaded it" "$OUT"
has   "  the overlay is counted, not hidden"            "2 set through the API" "$OUT"
has   "  and the row says it was left out on purpose"   "not compared -- the model file is the baseline" "$OUT"
has   "  and names the file the count came from"        ".test_run/nickname_overlay/StaticNetworkTopologyOVS_10Switches_4Hosts.names.json" "$OUT"
hasnt "  the 'missing' wording is gone once it exists"  "no overlay file at" "$OUT"

# 🔴 The other direction, in this group and not only in group 5: a `--check` that had simply
# stopped hashing the model file would satisfy every assertion above. The model file edited
# under a running kernel must still be red WHILE an overlay exists.
cp "$FIX/$OVS4" "$FIX/$OVS4.bak"
python3 -c "
import json,sys
p=sys.argv[1]; t=json.load(open(p)); t['edges'].append({'src':0,'dst':9}); json.dump(t,open(p,'w'))" "$FIX/$OVS4"
OUT="$(run_check)"
check "🔴 an overlay does not blind the model-file check" "1"  "$(rc_of "$OUT")"
has   "  the edit is still named"                       "topology file: $OVS4 has been edited since the ndt up that loaded it" "$OUT"
mv -f "$FIX/$OVS4.bak" "$FIX/$OVS4"

# And an unreadable overlay is a "?" in a row nobody grades, not a red check: the overlay is
# cosmetic and must never be able to fail the environment.
printf '%s' '{ not json' > "$OVERLAY"
OUT="$(run_check)"
check "an unparseable overlay does not turn --check red" "0"   "$(rc_of "$OUT")"
has   "  and the row admits it could not count"         "? set through the API" "$OUT"
rm -f "$OVERLAY"

# 🔴 The path this suite writes to is the one the KERNEL derives, and the two are computed in
# different languages in different files. tests/test_NicknameOverlay.cpp asserts the C++ side
# against the same literal; if either drifts, one of the two suites goes red. Stated here so
# the next reader knows the fixture path above is load-bearing and not decorative.
has   "the row's path is the one the kernel writes"     "nickname_overlay/StaticNetworkTopologyOVS_10Switches_4Hosts.names.json" "$(run_check)"

# --- done ---------------------------------------------------------------------------------
printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
