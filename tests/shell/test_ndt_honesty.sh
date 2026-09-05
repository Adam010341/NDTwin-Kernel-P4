#!/usr/bin/env bash
#
# Does `ndt` describe the lab it is actually looking at?
#
# [Co-developed with claude code -- Adam]
#
# The subjects are the places where a reading that was NOT TAKEN used to be rendered as a
# statement of fact. Each group names the 09-05 night-round finding it pins.
#
# I-1 (W12), measured 3/3 on 2026-09-05 (15:46:18, 16:20:04, 17:34:09), each time within
# minutes of an OVS fabric being torn down in this very checkout:
#
#     up target
#       record         none -- no 'ndt up' has run in this checkout  (.test_run/up.target)
#     configuration
#       hosts          4   (p4_proxy/mininet/host_count_override -- P4 only; no 'ndt up' recorded here)
#       topology       setting/StaticNetworkTopologyP4_10Switches_4Hosts.json   (the P4 model ...)
#
# The checkout had run `ndt up` at least seven times that evening and every one of them was
# OVS. Both sentences are about HISTORY, and `down` had only removed a record about NOW. The
# second one also changed the PLANE: R0's script grepped the first `setting/*.json` out of
# `ndt status` and carried the P4 model into an OVS round (R0 instrument error #3).
#
# 🔴 THREE DIRECTIONS, because "print something else" has obvious wrong answers:
#   * an implementation that always says "cleared by 'ndt down'" invents a teardown that may
#     never have happened -- group 1C is the case where there is no kernel.exit to say so;
#   * one that hard-codes the plane passes 1B and fails 1D;
#   * one that answers "unknown" to everything passes 1A-1D and fails 1E, where a record IS
#     present and the old, correct output must be unchanged.
# rc 3 and "COULD NOT CHECK" are asserted as UNCHANGED throughout: they were the honest part
# of the old behaviour, and a fix that traded them away would be a different regression.
#
# Offline and fixture-driven. REPO is redirected into a temp dir, so the record, the exit file,
# the models and the knob are all files this suite wrote; every process and privilege probe is
# stubbed. No lab, no sudo, no port, no network -- the lab was in use the night this was
# written and none of it may be touched.
#
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_ndt_honesty.sh
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

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-honesty-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs" "$FIX/setting" "$FIX/p4_proxy/mininet"

# --- fixtures ------------------------------------------------------------------------------
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
mk_topo StaticNetworkTopologyOVS_10Switches_4Hosts.json  4 40
mk_topo StaticNetworkTopologyP4_10Switches_4Hosts.json   4 40
OVS4="setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json"

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

knob() { printf '%s\n' "$1" > "$FIX/p4_proxy/mininet/host_count_override"; }

# The exit record supervise.sh leaves behind, verbatim in its field order and with a real
# kernel command line -- the `--topology` argument is the whole point, since it is the only
# thing in this file that names a plane.
kexit() {   # <plane> [at]
    local plane="$1" at="${2:-2026-09-05T15:45:07+08:00}" model
    case "$plane" in
        ovs)  model="$FIX/setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json" ;;
        p4)   model="$FIX/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json" ;;
        none) model="" ;;
    esac
    { echo "status=0"
      echo "signal=none"
      echo "child_pid=12345"
      echo "supervisor_pid=12344"
      echo "at=$at"
      if [[ -n "$model" ]]; then
          echo "command=bash -c cd '$FIX/build' && exec ./bin/ndtwin_kernel --mode mininet --topology '$model' --no-ai"
      else
          echo "command=bash -c cd '$FIX/build' && exec ./bin/ndtwin_kernel --mode physical --no-ai"
      fi
      echo "reason=stopped on request"
    } > "$FIX/.test_run/pids/kernel.exit"
}
no_kexit() { rm -f "$FIX/.test_run/pids/kernel.exit"; }

record() {    # <plane> <hosts> <topology-relative-path>
    local plane="$1" h="$2" topo="$3" sum counts
    counts="$(python3 -c '
import json,sys; t=json.load(open(sys.argv[1]))
print(sum(1 for n in t["nodes"] if n.get("vertex_type")==1), len(t["edges"]))' "$FIX/$topo")"
    sum="$(sha256sum "$FIX/$topo" | cut -d' ' -f1)"
    printf 'plane=%s\nhosts=%s\ntopology=%s\ntopology_sha256=%s\nmodel_hosts=%s\nmodel_edges=%s\nat=%s\nby=%s\nbuilder=up_%s\n' \
        "$plane" "$h" "$topo" "$sum" "${counts%% *}" "${counts##* }" "$(date +%s)" "fixture" "$plane" \
        > "$FIX/.test_run/up.target"
}
no_record() { rm -f "$FIX/.test_run/up.target"; }

# --- the seam ------------------------------------------------------------------------------
# ndt is sourced (it returns at its own source seam), REPO is redirected at the fixture, and
# every reading that would otherwise describe THIS machine is answered by an FX_ variable.
# kernel_exit_file, last_kernel_plane, check_up_target and the configuration block all run for
# real, against fixture files -- they are the subject.
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
fabric_host_count() { echo "${FX_FABRIC_HOSTS:-4}"; }
ovs_bridge_count() { echo "${FX_BRIDGES:-10}"; }
ovs_daemon_running() { [[ "${FX_BRIDGES:-10}" -gt 0 ]]; }
topo_session() { return 0; }
port_open() { case "$1" in 8000) [[ -s "$REPO/graph.json" ]] ;; *) return 1 ;; esac; }
http_get_graph() { [[ -s "$REPO/graph.json" ]] && cat "$REPO/graph.json"; }
netem_count() { echo 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
app_probe() { APP_STATE=not-running; }
lab_version_verdict() { echo "same fixture-sha fixture-sha"; }
'
run_status() {   # [--check] -> the whole report plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
cmd_status ${1:-}
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

mk_graph 4 40
knob 4

# ==========================================================================================
section "1A. I-1: after a 'down', --check says what was cleared -- not that nothing ever ran"
no_record
kexit ovs
OUT="$(run_status --check)"
has   "🔴 the record line names the clearing, and when"  "the last 'ndt up' record was cleared by 'ndt down' at 2026-09-05T15:45:07+08:00" "$OUT"
has   "  and where the history is"                       "history is in .test_run/pids/*.exit" "$OUT"
hasnt "🔴 the sentence that was false is gone"           "no 'ndt up' has run in this checkout" "$OUT"
has   "  the run it names is reported as history, not as a baseline" "NOT a baseline, just what ran" "$OUT"
# The honest half of the old behaviour, asserted as unchanged.
check "rc is still 3 -- not 0 and not 1"                 "3" "$(rc_of "$OUT")"
has   "  COULD NOT CHECK is still said"                  "COULD NOT CHECK" "$OUT"
hasnt "  and it is still never 'ok'"                     "check: ok" "$OUT"
has   "  finding #79's per-checkout note is still there" "per checkout" "$OUT"
has   "  it still says where the record would be"        ".test_run/up.target" "$OUT"

section "1B. I-1: and the plane does not change to P4"
OUT="$(run_status)"
has   "🔴 topology says unknown and names the plane that ran" "unknown (no up.target); last kernel.exit ran ovs" "$OUT"
hasnt "🔴 no P4 model file is printed -- that path was the carrier" "StaticNetworkTopologyP4" "$OUT"
hasnt "  and the host count is not presented as the fabric's" "hosts          4   (p4_proxy" "$OUT"
has   "  the P4 knob is still shown, named for what it decides" "p4 host knob" "$OUT"
has   "  and the hosts row says it does not know"        "hosts          unknown (no up.target)" "$OUT"

section "1C. 🔴 the other direction: with no kernel.exit it must not invent a teardown"
no_kexit
OUT="$(run_status --check)"
hasnt "🔴 no 'cleared by ndt down' without a record of one" "cleared by 'ndt down'" "$OUT"
has   "  it says the checkout cannot tell"               "there is no .test_run/pids/kernel.exit to say what ran before" "$OUT"
check "  rc is still 3"                                  "3" "$(rc_of "$OUT")"
OUT="$(run_status)"
has   "  and the topology row says the same"             "no kernel.exit either -- this checkout cannot say what ran" "$OUT"
hasnt "  it does not name a plane it was never told"     "last kernel.exit ran" "$OUT"

section "1D. 🔴 the plane is read, not assumed: a P4 exit record reads back as p4"
kexit p4
OUT="$(run_status)"
has   "'last kernel.exit ran p4' after a P4 run"         "last kernel.exit ran p4" "$OUT"
hasnt "  and not ovs"                                    "last kernel.exit ran ovs" "$OUT"
OUT="$(run_status --check)"
has   "  --check names the same plane"                   "that run was p4" "$OUT"

section "1E. 🔴 it does not answer 'unknown' to everything -- 1A-1D would pass if it did"
kexit ovs
record ovs 4 "$OVS4"
OUT="$(run_status)"
has   "with a record, hosts is what 'up' asked for"      "hosts          4   (what the last 'ndt up' asked for: ovs)" "$OUT"
has   "  and topology is the model that was loaded"      "topology       $OVS4" "$OUT"
hasnt "  nothing says 'no up.target'"                    "no up.target" "$OUT"
OUT="$(run_status --check)"
check "  and --check checks: rc 0, not 3"                "0" "$(rc_of "$OUT")"
has   "  it reports a real comparison"                   "check: ok" "$OUT"
hasnt "  and says nothing about a clearing"              "cleared by 'ndt down'" "$OUT"

section "1F. an exit record naming no model is not turned into a plane"
no_record
kexit none
OUT="$(run_status)"
has   "it says the command names no model it can classify" "names no model this script can classify" "$OUT"
hasnt "  rather than picking one"                        "last kernel.exit ran" "$OUT"

# ==========================================================================================
# I-4 (W13), measured 2026-09-05 17:21:57 -- one `ndt status`, two rows apart:
#
#     note       arm r4p4 finished 17:17; lab free, night claim kept
#     measuring  iperf3 -c 10.0.0.33 -p 5511 -t 200 -P 4 -i 0    + 7 more process(es)
#
# 16 iperf3 processes over a 128-host fabric with ten bridges up, while the note said the
# machine was free. The note's only writers were the arm_*.sh wrappers around `ndt`, so any
# `ndt up` that did not go through one of them left the previous wrapper's sentence standing.
#
# 🔴 THREE DIRECTIONS. A writer that rewrites the whole claim passes every "the note is right"
# case and fails 2A/2C (it is I-2 residue #1: correcting a sentence silently extended a lease by
# three hours). A writer that never refuses passes 2A and fails 2B. A note written only where
# it is defined and never called passes everything except 2C/2D/2E, which drive `up` and `down`
# for real -- existence is not wiring.

lib() { bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
CLAIM=\"\$REPO/.test_run/lab.claim\"
$1" 2>&1; }

claim_file() { echo "$FIX/.test_run/lab.claim"; }
mk_claim() {  # <owner> <seconds-from-now> <note>
    printf 'owner=%s\nexpires=%s\nnote=%s\nexclusive_cpu=yes\n' \
        "$1" "$(( $(date +%s) + $2 ))" "$3" > "$(claim_file)"
}
no_claim() { rm -f "$(claim_file)"; }
cf() { sed -n "s/^$1=//p" "$(claim_file)" | head -1; }

# The wiring harness, the same shape group 8 of test_ndt_status_check_baseline.sh uses: the two
# builders are driven far enough to reach the call and no further -- STACK points at nothing, so
# the step after it fails immediately and no lab is touched.
up_run() {   # <the up call> -- runs it against the fixture; the claim file is the observation
    bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
CLAIM=\"\$REPO/.test_run/lab.claim\"
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
$1 >/dev/null 2>&1" >/dev/null 2>&1
}

I4_NOTE="arm r4p4 finished 17:17; lab free, night claim kept"
export NDT_OWNER=fixture-owner

section "2A. I-4: the note can be corrected without moving the lease"
mk_claim fixture-owner 3600 "$I4_NOTE"
EXP_BEFORE="$(cf expires)"
OUT="$(lib 'set_claim_note "hello there"; echo "RC=$?"')"
check "set_claim_note succeeds on our own live claim"    "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "  the note is the new one"                        "hello there" "$(cf note)"
check "🔴 expires is byte-identical -- not pushed out"   "$EXP_BEFORE" "$(cf expires)"
check "  owner is untouched"                             "fixture-owner" "$(cf owner)"
check "  and so is exclusive_cpu"                        "yes" "$(cf exclusive_cpu)"

section "2B. 🔴 a session that does not hold the lab must not narrate it"
mk_claim someone-else 3600 "$I4_NOTE"
OUT="$(lib 'set_claim_note "not mine"; echo "RC=$?"')"
check "someone else's claim is refused"                  "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "  and the note is unchanged"                      "$I4_NOTE" "$(cf note)"
mk_claim fixture-owner -60 "$I4_NOTE"
OUT="$(lib 'set_claim_note "expired"; echo "RC=$?"')"
check "an expired claim is refused"                      "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "  and the note is unchanged"                      "$I4_NOTE" "$(cf note)"
no_claim
OUT="$(lib 'set_claim_note "no claim"; echo "RC=$?"')"
check "no claim at all is refused"                       "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "  and no claim file is invented"                  "gone" "$( [[ -f "$(claim_file)" ]] && echo present || echo gone )"

section "2C. 🔴 the wiring: 'ndt up ovs4' really rewrites the note"
knob 4
no_record
mk_claim fixture-owner 3600 "$I4_NOTE"
EXP_BEFORE="$(cf expires)"
up_run 'up_ovs 4'
has   "the note says the lab is in use"                  "in use: ndt up ovs 4" "$(cf note)"
has   "  and names who is using it"                      "by fixture-owner" "$(cf note)"
hasnt "🔴 the 'lab free' sentence is gone"               "lab free" "$(cf note)"
check "🔴 and the lease did not move"                    "$EXP_BEFORE" "$(cf expires)"

section "2D. and 'ndt up p4' does too -- one builder wired is not both"
no_record
mk_claim fixture-owner 3600 "$I4_NOTE"
up_run 'up_p4'
has   "the note names the P4 target"                     "in use: ndt up p4 4" "$(cf note)"
hasnt "  and not the OVS one"                            "ndt up ovs" "$(cf note)"

section "2E. 🔴 and 'ndt down' takes it back -- a stale 'in use' is the same defect, flipped"
mk_claim fixture-owner 3600 "in use: ndt up ovs 4 at 2026-09-05 17:21:11 by fixture-owner"
EXP_BEFORE="$(cf expires)"
OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
CLAIM=\"\$REPO/.test_run/lab.claim\"
STACK='$FIX/no-such-stack.sh'; LAB='$FIX/no-such-lab'
sudo() { return 1; }; foreign_claim() { :; }; in_flight() { :; }
app_probe() { APP_STATE=not-running; }
cmd_clean() { return 0; }
cmd_down >/dev/null 2>&1" 2>&1)"
has   "the note says the lab came down"                  "down at " "$(cf note)"
has   "  and that the claim was kept, not released"      "claim kept" "$(cf note)"
hasnt "🔴 it no longer says the lab is in use"           "in use" "$(cf note)"
check "  the lease still did not move"                   "$EXP_BEFORE" "$(cf expires)"

# 🔴 The direction that matters most on a teardown: "down" and "down, and something survived"
# are different statements, and the second is the one a reader must not act on as the first.
mk_claim fixture-owner 3600 "in use: ndt up ovs 4 at 2026-09-05 17:21:11 by fixture-owner"
bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
CLAIM=\"\$REPO/.test_run/lab.claim\"
STACK='$FIX/no-such-stack.sh'; LAB='$FIX/no-such-lab'
sudo() { return 1; }; foreign_claim() { :; }; in_flight() { :; }
app_probe() { APP_STATE=not-running; }
cmd_clean() { return 1; }
cmd_down >/dev/null 2>&1" >/dev/null 2>&1
has   "🔴 a teardown that did not verify says so"        "did NOT verify clean" "$(cf note)"

no_claim
unset NDT_OWNER

# ==========================================================================================
section "3G. O-4: teardown asserts, and asserting is not deleting"
# The other half of the kernel.log question. Bounding the generations belongs to stack.sh's
# rotate_log, at the moment a new one replaces an old one; `ndt clean` and `ndt down --deep`
# must leave them alone. This is the state of the code before this change as well as after --
# the point of pinning it is that "it happens not to delete them" and "it must not delete them"
# are different facts, and only the second one survives someone tidying up.
mkdir -p "$FIX/.test_run/logs"
: > "$FIX/.test_run/logs/kernel.log"
for s in 20260905-153726 20260905-154246 20260905-155230; do
    printf 'era %s\n' "$s" > "$FIX/.test_run/logs/kernel.log.$s"
done
printf 'old scheme\n' > "$FIX/.test_run/logs/kernel.log.prev"
CLEAN_OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
MANIFEST=\"\$REPO/manifest.json\"
bmv2_count() { echo 0; }
mn_count() { echo 0; }
topo_session() { return 1; }
ndt_port_residue() { return 0; }
ndt_port_label() { echo none; }
cmd_clean
echo \"RC=\$?\"" 2>&1)"
check "the assertion itself still passes on a clean machine" "0" "$(sed -n 's/^RC=//p' <<<"$CLEAN_OUT" | tail -1)"
check "🔴 every rotated generation is still there"       "3" \
      "$(ls -1 "$FIX/.test_run/logs/kernel.log".[0-9]* 2>/dev/null | wc -l)"
check "🔴 and so is the live log"                        "present" \
      "$( [[ -e "$FIX/.test_run/logs/kernel.log" ]] && echo present || echo gone )"
check "🔴 and a .prev from the old scheme"               "old scheme" \
      "$(cat "$FIX/.test_run/logs/kernel.log.prev" 2>/dev/null)"

# --- done ---------------------------------------------------------------------------------
printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
