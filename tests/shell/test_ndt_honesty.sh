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
# 09-07: `cmd_status --check` now runs a residue scan (W16-2). Answered from the fixture so
# this suite never reaches :8000 -- with these unstubbed the result would depend on whether a
# kernel happens to be listening on the machine the suite is run from, which is the kind of
# hidden input that makes a green run mean nothing. Both answer "nothing there", so the exit
# codes below stay about the up-target baseline, which is what this suite is for.
http_get_flow_entries() { echo "[]"; }
lock_probe() { echo free; }
netem_count() { echo 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
# 🔴 F9 (F-OFFLINE-1 §1.13, measured 2026-09-11). WITHOUT this line every `--check` group in
# this file read a file in the MAIN checkout: app_evidence_log sim is
# `$(lab_kernel_dir)/.test_run/logs/app_sim.log` (ndt:3938) and lab_kernel_dir’s built-in
# default is LAB_DEFAULT_KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel (ndt:940, ndtwin-lab:98) --
# a 148717-byte root-owned log on this machine (uid 0, mtime 2026-09-10 16:48). Non-empty means
# "the app ran here and its window is LOST", so every group scored a RESIDUE_BLIND and the
# residue row said NOT CHECKED rather than "none". It stayed GREEN only because Adam’s E-7
# ruling makes residue rc 5 not red -- the suite’s exit codes were being held up by a ruling
# about a different question, and a `sudo truncate` of that file would have changed what this
# suite prints. 3-51 added exactly this stub to test_apps_residue.sh:126 and
# test_ndt_status_residue_row.sh:142 and did not reach the other two suites.
lab_kernel_dir() { echo "$REPO"; }
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
# _f9 <shell-code> -- the STUBS shell, for the F9 group at the bottom. Same seam as the runner
# above; separate only because the runner appends its own command.
_f9() {
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1" 2>&1
}


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

# HANDOFF is redirected as well as CLAIM: cmd_claim renames the handoff note aside, and with the
# real path still in scope that rename would land in the checkout this suite is testing.
lib() { bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
CLAIM=\"\$REPO/.test_run/lab.claim\"
HANDOFF=\"\$REPO/.test_run/lab.handoff\"
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

# ==========================================================================================
# R4-2 (2026-09-05, 100% reproducible on 128 hosts): `ndt check` prints "run this while traffic
# is flowing" when idle, and refuses with rc 1 as soon as traffic exists, because it treated any
# iperf3 CLIENT as a measurement in flight. The only configuration that produced a meaningful
# ratio was the one the tool itself labelled "accept the contamination".
#
# R4-5, the same evening: against a ground truth stable to 0.27%, the ratio ranged 0.85-0.97 --
# 12/12 low, a 13% spread -- and printed `ok` every time, because the band is 0.5-1.5.
#
# 🔴 THE DIRECTION THAT MATTERS: a `check` that never refuses passes 4B and fails 4A, and it
# would put back the hazard the guard exists for -- a sampling-rate poll-off cell silently
# refilled by this 4 Hz poll. And in_flight must NOT be weakened: 4D asserts `ndt status` still
# renders the observed processes, because that row is what caught I-4.
#
# python3 is stubbed throughout this group. The real block opens :8000 and polls it at 4 Hz for
# eight seconds; running that from a test would perturb whatever is on the machine, which is the
# exact hazard the group is about.

CHECK_STUBS='
REPO="'"$FIX"'"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
port_open() { [[ "$1" == 8000 ]]; }
python3() { cat >/dev/null; echo "PYTHON-WOULD-RUN"; }
'
IPERF_LINES='in_flight() { echo "iperf3 -c 10.0.0.33 -p 5511 -t 200 -P 4 -i 0"; echo "iperf3 -c 10.0.0.34 -p 5512 -t 200 -P 4 -i 0"; }'
NO_IPERF='in_flight() { :; }'
FX_INFLIGHT="$NO_IPERF"
run_ndt_check() {   # [--force]
    bash -c "source '$NDT' >/dev/null 2>&1
$CHECK_STUBS
$FX_INFLIGHT
cmd_check ${1:-}
echo \"RC=\$?\"" 2>&1
}

export NDT_OWNER=fixture-owner

section "4A. R4-2: it refuses on a DECLARED measurement -- the guard still guards"
printf 'owner=fixture-owner\nexpires=%s\nnote=n\nexclusive_cpu=no\nmeasuring=%s\n' \
    "$(( $(date +%s) + 3600 ))" "sampling matrix, poll-off cell 3/8" > "$(claim_file)"
FX_INFLIGHT="$IPERF_LINES"
OUT="$(run_ndt_check)"
check "a declared measurement is refused, rc 1"          "1" "$(rc_of "$OUT")"
has   "  and the declaration is quoted back"             "sampling matrix, poll-off cell 3/8" "$OUT"
has   "  named as a declaration, not as a guess"         "declared in .test_run/lab.claim (measuring=), not guessed from the process table." "$OUT"
hasnt "🔴 it stopped before sampling anything"           "PYTHON-WOULD-RUN" "$OUT"
OUT="$(run_ndt_check --force)"
has   "  --force still gets past it"                     "PYTHON-WOULD-RUN" "$OUT"

section "4B. 🔴 R4-2 itself: traffic alone no longer refuses -- traffic is the precondition"
printf 'owner=fixture-owner\nexpires=%s\nnote=n\nexclusive_cpu=no\nmeasuring=\n' \
    "$(( $(date +%s) + 3600 ))" > "$(claim_file)"
OUT="$(run_ndt_check)"
check "🔴 iperf3 clients with nothing declared: rc 0"    "0" "$(rc_of "$OUT")"
has   "🔴 and it actually samples"                       "PYTHON-WOULD-RUN" "$OUT"
hasnt "  nothing is refused"                             "refusing" "$OUT"
has   "  the traffic is still shown, as the precondition" "iperf3 -c 10.0.0.33" "$OUT"
has   "  and it says how to make it a protected measurement" "NDT_MEASURING=" "$OUT"

section "4C. the declaration is written by 'ndt claim', and expires with it"
no_claim
OUT="$(lib 'NDT_OWNER=fixture-owner NDT_MEASURING="matrix cell 3/8" cmd_claim 30 "a note" >/dev/null 2>&1; cat "$CLAIM"')"
has   "NDT_MEASURING lands in the claim file"            "measuring=matrix cell 3/8" "$OUT"
has   "  beside the note it was given"                   "note=a note" "$OUT"
OUT="$(lib 'NDT_OWNER=fixture-owner cmd_claim 30 "a note" >/dev/null 2>&1; cat "$CLAIM"')"
has   "  and is empty when nothing was declared"         "measuring=" "$OUT"
check "🔴 an expired claim declares nothing"             "" \
      "$(printf 'owner=fixture-owner\nexpires=1\nnote=n\nexclusive_cpu=no\nmeasuring=still here\n' > "$(claim_file)"; lib 'measuring_declared')"
check "  and a live one declares what it says"           "still here" \
      "$(printf 'owner=fixture-owner\nexpires=%s\nnote=n\nexclusive_cpu=no\nmeasuring=still here\n' "$(( $(date +%s) + 3600 ))" > "$(claim_file)"; lib 'measuring_declared')"
check "🔴 rewriting the note does not drop the declaration" "still here" \
      "$(lib 'set_claim_note "down at now; claim kept" >/dev/null; measuring_declared')"

section "4D. 🔴 in_flight is not weakened: 'ndt status' still renders the process table"
mk_graph 4 40
knob 4
record ovs 4 "$OVS4"
kexit ovs
printf 'owner=fixture-owner\nexpires=%s\nnote=n\nexclusive_cpu=no\nmeasuring=%s\n' \
    "$(( $(date +%s) + 3600 ))" "sampling matrix, poll-off cell 3/8" > "$(claim_file)"
STATUS_OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
CLAIM=\"\$REPO/.test_run/lab.claim\"
claim_line() { echo \"yours -- 60m left\"; }
$IPERF_LINES
cmd_status" 2>&1)"
has   "the declared measurement gets its own row"        "declared" "$STATUS_OUT"
has   "  naming what it is"                              "sampling matrix, poll-off cell 3/8" "$STATUS_OUT"
has   "🔴 and the OBSERVED processes are still printed"  "measuring" "$STATUS_OUT"
has   "🔴 with the process line I-4 was caught by"       "iperf3 -c 10.0.0.33" "$STATUS_OUT"
printf 'owner=fixture-owner\nexpires=%s\nnote=n\nexclusive_cpu=no\nmeasuring=\n' \
    "$(( $(date +%s) + 3600 ))" > "$(claim_file)"
STATUS_OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
CLAIM=\"\$REPO/.test_run/lab.claim\"
claim_line() { echo \"yours -- 60m left\"; }
$IPERF_LINES
cmd_status" 2>&1)"
has   "🔴 undeclared traffic is still reported by status" "iperf3 -c 10.0.0.33" "$STATUS_OUT"
hasnt "  and no empty 'declared' row is printed"         "declared       " "$STATUS_OUT"

section "4E. R4-5: the verdict says how big the gap is, and what 'ok' does not mean"
# verdict_lines is pure and is extracted verbatim from ndt's embedded python block. The rest of
# that block needs a kernel, a fabric and traffic; this function needs none of them.
VL="$(python3 - "$NDT" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"# --- BEGIN verdict_lines.*?\n(.*?)# --- END verdict_lines ---", s, re.S)
if not m:
    print("EXTRACT-FAILED"); sys.exit(0)
ns = {}
exec(m.group(1), ns)
for tw, tr in ((3240.1e6, 3829.7e6), (2.0e6, 1.0e6), (0.6e6, 1.0e6)):
    for line in ns["verdict_lines"](tw, tr):
        print(line)
PY
)"
hasnt "verdict_lines was found and ran"                  "EXTRACT-FAILED" "$VL"
has   "R4-5's own numbers: the ratio is printed as a value" "ratio=0.846" "$VL"
has   "  with both sides of it"                          "(twin 3240.1 / ground truth 3829.7 Mbit/s)" "$VL"
has   "🔴 and the size of the gap in words"              "twin under-reports by 15%" "$VL"
has   "🔴 saying what ok does not mean"                  "accuracy is NOT" "$VL"
has   "🔴 the band did not move: 0.85 is still ok"       "0.85   ok" "$VL"
has   "  and 0.6 is still ok too"                        "0.60   ok" "$VL"
has   "  the +/-50% band is named"                       "within the +/-50% double-count band" "$VL"
has   "🔴 a doubling is still called out"                "DOUBLE-COUNTING" "$VL"
has   "  and named as outside the band"                  "OUTSIDE the +/-50% double-count band" "$VL"
has   "  over-reporting is not called under-reporting"   "twin over-reports by 100%" "$VL"

# 🔴 WIRING, and it is a TEXT check, not a driven one -- naming that rather than hiding it.
# The call site sits inside a block that needs a live kernel on :8000, a fabric and real traffic;
# this suite refuses to run it (see the python3 stub above). What is asserted here is that the
# pure function is the only thing producing those lines. The live path is on the "needs live
# verification" list, not on this one.
check "verdict_lines is called exactly once from the block" "1" \
      "$(grep -c 'for line in verdict_lines(twin_bps, truth_bps):' "$NDT")"
check "  and the lines it returns exist nowhere else"      "1" \
      "$(grep -c 'double-count band; accuracy is NOT' "$NDT")"

no_claim
unset NDT_OWNER FX_INFLIGHT

# ==========================================================================================
section "1G. F10: the DEFAULT round's model is a Mininet_* file, and it reads as ovs"
# ==========================================================================================
# F-OFFLINE-1 §1.15, with a positive control. `ndt up` with no arguments is `up_ovs 128`
# (resolve_up_target), setting/ has no OVS 128-host model -- OVS has 4/8/16/32/64 -- and
# topo_for_hosts's OVS glob includes StaticNetworkTopologyMininet_*.json, so the model the
# DEFAULT round loads is setting/StaticNetworkTopologyMininet_10Switches.json, which declares
# 128 hosts. last_kernel_plane matched only OVS_* and P4_*, so after `ndt up; ndt down` the
# most common round on this machine could not be classified: `--check` printed `names no model
# this script can classify`, byte-identical to a physical-mode run, while the same report's
# `rate source` row said OVS.
MINI="$FIX/setting/StaticNetworkTopologyMininet_10Switches.json"
mk_topo StaticNetworkTopologyMininet_10Switches.json 128 288
_lkp() {   # <topology argument> -> "<plane> rc=<n>"
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
kernel_exit_field() { [[ \"\$1\" == command ]] && echo \"bash -c cd build && exec ./bin/ndtwin_kernel --mode mininet --topology '$1' --no-ai\"; }
out=\"\$(last_kernel_plane)\"; echo \"[\$out] rc=\$?\"" 2>&1
}
check "  🔴 a Mininet_* model reads as ovs"              "[ovs] rc=0" "$(_lkp "$MINI")"
# The positive control from the report: an OVS_* model was already classified, so this cell
# cannot pass merely because everything answers ovs.
check "  the OVS_* control still reads as ovs"          "[ovs] rc=0" \
      "$(_lkp "$FIX/setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json")"
check "  🔴 and P4 is NOT swallowed by the new pattern" "[p4] rc=0" \
      "$(_lkp "$FIX/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json")"
# 🔴 The direction this must not go: a command naming no model at all is still unclassifiable.
# That is 1F's property and the reason the whole block exists -- "I could not tell" and "it was
# ovs" are different answers.
check "  🔴 a physical-mode command is still rc 1"      "[] rc=1" "$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
kernel_exit_field() { [[ \"\$1\" == command ]] && echo 'bash -c cd build && exec ./bin/ndtwin_kernel --mode physical --no-ai'; }
out=\"\$(last_kernel_plane)\"; echo \"[\$out] rc=\$?\"" 2>&1)"
check "  and no record at all is still rc 1"            "[] rc=1" "$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
kernel_exit_field() { :; }
out=\"\$(last_kernel_plane)\"; echo \"[\$out] rc=\$?\"" 2>&1)"

# ==========================================================================================
# 5. `ndt help` -- the prose is an output too, and nothing was reading it
# ==========================================================================================
# 🔴 F-OFFLINE-1 §1.12 / §1.24, measured 2026-09-11: two claims that the code had already
# stopped making, and one of them the code's own comment calls false, were still being printed
# by `ndt help` -- with no test anywhere in the tree looking at that output. `grep -rn` over
# tests/ found the sentences only in four 09-02 manual-test transcripts. A suite that drives
# `--check` until every row is honest and never reads the paragraph that tells an operator what
# `--check`'s exit codes mean is checking half the statement.
#
# The dispatch is executed, not sourced: help lives in the `*)` arm of the case block at the
# bottom of the file (ndt:6075), below the source seam. It is the one command that touches
# nothing -- a heredoc and `exit 2` -- so it is safe to run here, where the lab must not be.
run_help() { bash "$NDT" help 2>&1; }
HELP="$(run_help)"

section "5A. F12: help no longer claims what check_up_target deliberately stopped claiming"
check "  ndt help runs offline and exits 2"              "2" \
      "$(bash "$NDT" help >/dev/null 2>&1; echo $?)"
has   "  and it is the help"                             "usage: ndt <command>" "$HELP"
# check_up_target:2974-2977 removed this sentence from the OUTPUT and says why in its own
# comment: "is a statement about history and is false after every ordinary up->down". The help
# went on printing it, in capitals, as the definition of rc 3.
hasnt "  🔴 the sentence W12 removed from the output is gone from the help too" \
      "has run in THIS checkout" "$HELP"
check "  🔴 and from the file in that spelling -- the help was its last home" "0" \
      "$(grep -c 'has run in THIS checkout' "$NDT")"
has   "  rc 3 is explained by the baseline, not by history" "no baseline RIGHT NOW" "$HELP"
has   "  and it names 'absent' as one cause"             "is absent" "$HELP"
has   "  🔴 and 'unreadable' as the other -- rc 3 has two return sites" "or unreadable" "$HELP"
has   "  and says an ordinary up->down clears it"        "ordinary up->down clears it" "$HELP"
has   "  3 is still never 'checked and matched'"          'never "checked and matched"' "$HELP"
has   "  and it says what 3 is NOT"                      "it is NOT \"no 'ndt up'" "$HELP"
# The claim the corrected sentence makes about the report has to be true of the report. 1A
# above drives exactly this: with a kernel.exit present, the record row names the last run.
has   "  and points at the file the report reads instead" ".test_run/pids/kernel.exit" "$HELP"

section "5B. B10: help scopes the host_count_override claim to what the code enforces"
# The 09-05 round (R3-3) recorded this sentence as REFUTED. It was not: read literally it only
# ever claimed that FORGETTING an environment variable cannot cause the mistake, and R3-3's own
# note says what it did -- "設一個環境變數就做到了". What was false is the impression the
# sentence leaves, so what changes is its SCOPE, and the help now carries both halves.
hasnt "  🔴 the blanket 'cannot be made' claim is gone"  "mistake cannot be made by forgetting an" "$HELP"
has   "  the claim that survives is scoped to P4"        "On P4, 'ndt up' derives" "$HELP"
has   "  and to the failure mode it really covers"       "because an environment variable was forgotten" "$HELP"
has   "  🔴 the two-checkout form is named as refused"   "refused before anything is built" "$HELP"
has   "  and by what"                                    "acts in ONE tree" "$HELP"
has   "  🔴 and what the knob does NOT prevent is said"  "does NOT make the" "$HELP"
has   "  with the 09-05 counter-example"                 "setting it built exactly that pair (R3-3)" "$HELP"
has   "  and 'ndt up p4 N' named as the other writer"    "p4 N' rewrites it" "$HELP"
has   "  OVS is excluded, because it has no such knob"   "OVS has no such knob" "$HELP"
# 🔴 WIRING, a text check and named as one: the refusal the help now points at is a real
# function called before up_p4/up_ovs build anything (ndt:1457). Its behaviour belongs to
# tests/shell/test_ndt_up_down_robust.sh; what is asserted here is only that the help is not
# pointing at a mechanism nobody calls -- which is what F8 turned out to be, one file over.
check "  the refusal the help points at is called from 'ndt up'" "1" \
      "$(grep -c 'guard_lab_acts_in_this_tree || bad=1' "$NDT")"


section "5C. F2/F4: the help's two rc tables stop saying things the code does not do"
# F-OFFLINE-1 §1.16. Both sentences were true of a state the tool is rarely in and false of the
# state a round ENDS in, and neither had a test.
#
# F2: `residue FOUND is a problem (rc 1)`. cmd_status --check folds residue and knob problems
# into `problems` (ndt:3313-3316, :3153) but returns 3 when there is no up.target (ndt:2991),
# printing them under "everything else this report could still check". `ndt down` clears the
# baseline (clear_up_target), so utrc==3 is exactly the end-of-round state -- when a rule is
# most likely to be on the wire with no process left to attribute it to.
has   "  🔴 rc 1 is scoped to 'while there is a baseline'" "it is rc 1 ONLY while there is a" "$HELP"
has   "  and says what happens without one"              "the whole report is rc 3" "$HELP"
has   "  naming where they are printed instead"          "everything else this" "$HELP"
has   "  and that 'ndt down' puts you there"             "clears the baseline" "$HELP"
has   "  with what to read instead"                      "Read the residue ROW, not the" "$HELP"
#
# F4: the `apps orphans` table calls itself disjoint. The PROCESS answer wins whenever it is
# non-zero (cmd_apps orphans: `if (( orc != 0 )); then ... return "$orc"`), and rc 2 is the
# ordinary answer here because /proc/<pid>/fd of a root process cannot be read and every app the
# lab helper starts is root -- so the documented rc 4 is unreachable in the state it describes.
has   "  🔴 the rc table says it is not disjoint"        "THE CODES ARE NOT DISJOINT IN PRACTICE" "$HELP"
has   "  naming which answer wins"                       "PROCESS answer" "$HELP"
has   "  and why 2 is the ordinary answer here"          "cannot be read and every app the" "$HELP"
has   "  🔴 and that 4 can be true and unreachable"      "true and unreachable at the same time" "$HELP"
has   "  with the sentence the tool prints when it is"   "residue rc" "$HELP"
has   "  and the reader to use instead"                  "orphans_verdict.sh" "$HELP"
# 🔴 The claims are checked against the code, not just against themselves: both sentences
# describe control flow, and a text-only assertion would go on passing if the flow changed.
check "  the no-baseline branch still returns 3" "1" \
      "$(grep -c 'there is no baseline, so --check did NOT check' "$NDT")"
check "  and the process answer still wins in cmd_apps orphans" "1" \
      "$(grep -c 'if (( orc != 0 )); then' "$NDT")"

# ==========================================================================================
section "F9. this suite reads its OWN tree, and not the main checkout"
# ==========================================================================================
# F-OFFLINE-1 §1.13. Two of the four `--check` suites had no lab_kernel_dir stub, so
# app_evidence_log answered with a path in /home/adam/Desktop/NDTwin-Kernel -- a 148717-byte
# root-owned file this suite cannot write, cannot trim and does not own. Asserted on the PATH
# rather than on what the path happened to contain: "the residue row said none" would depend on
# whether somebody had truncated that file, which is the hidden input the stub removes.
check "  lab_kernel_dir answers the fixture tree"        "$FIX" "$(_f9 'lab_kernel_dir')"
check "  🔴 sim's evidence log is inside the fixture"    "$FIX/.test_run/logs/app_sim.log" \
      "$(_f9 'app_evidence_log sim')"
check "  and so is an ordinary app's log"                "$FIX/.test_run/logs/app_nsr.log" \
      "$(_f9 'app_logfile nsr')"
hasnt "  🔴 and no reading of it names the main checkout" "/home/adam/Desktop/NDTwin-Kernel/.test_run" \
      "$(_f9 'app_evidence_log sim; echo; app_logfile nsr; echo; lab_kernel_dir')"
# energy has no channel at all, and that has to stay a different answer from "a path".
check "  energy still has no evidence log (rc 1)"        "1" \
      "$(_f9 'app_evidence_log energy >/dev/null 2>&1; echo $?')"

# ==========================================================================================
# 6. T1: the claim is a check-then-write, and two sessions could both win it
# ==========================================================================================
# 🔴 ROLE-4, measured 2026-09-11 01:53:36 and 01:54:21 (hunt-0911/logs/ROLE-4/03-t1-race-sweep.log
# off=0.00s, 04-t1-race-offset0-reps.log rep1). Two owners firing `ndt claim` in the same second
# BOTH got rc 0 and both were told "ok lab claimed by <themselves>"; the file kept only the last
# writer. 2 of 16 same-second pairs; every pair offset by 50 ms or more refused correctly, so this
# is a window and not a missing check. The loser had no channel at all -- its own rc 0 was not
# evidence, and only a later `ndt status` disagreed with it.
#
# 🔴 THREE DIRECTIONS. A lock alone leaves 6F false for the writer this tool's own header
# invites ("any script may write .test_run/lab.claim"): that writer takes no lock, so the write
# is also read back. A refusal that says the same thing either way (6D) sends the loser of a
# millisecond race to "wait for it to lapse" about a claim one second old. And an overwrite that
# keeps no copy (6B) is R7 I-2 -- lab.claim was the one state file with no .prev, so a claim that
# changed hands mid-round left no trace in any interface.

cprev() { sed -n "s/^$1=//p" "$(claim_file).prev" 2>/dev/null | head -1; }

# claim_run <extra-stubs> <call> -- the claim harness with room for one more stub. Same seam as
# lib() above; separate because these cases are about what cmd_claim READS, and the reading is
# what the stub replaces.
claim_run() {
    bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
CLAIM=\"\$REPO/.test_run/lab.claim\"
HANDOFF=\"\$REPO/.test_run/lab.handoff\"
$1
$2
echo \"RC=\$?\"" 2>&1
}

rm -f "$(claim_file).prev" "$(claim_file).lock"

section "6A. a free lab: the claim is taken, and the five fields are in the documented order"
no_claim
rm -f "$(claim_file).prev"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner NDT_MEASURING="cell 3/8" cmd_claim 5 "T1 A"')"
check "claim on a free lab succeeds"                     "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "  and the file says we hold it"                   "fixture-owner" "$(cf owner)"
check "  the header's field order, in the header's order" "owner expires note exclusive_cpu measuring" \
      "$(sed 's/=.*//' "$(claim_file)" | tr '\n' ' ' | sed 's/ $//')"
check "  nothing was kept aside -- there was nothing to keep" "gone" \
      "$( [[ -f "$(claim_file).prev" ]] && echo present || echo gone )"

section "6B. 🔴 R7 I-2: the claim an overwrite replaces is kept as .prev"
mk_claim old-owner -60 "the round that ended"
OLD_EXP="$(cf expires)"
rm -f "$(claim_file).prev"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner cmd_claim 5 "T1 B"')"
check "an expired claim is claimable"                    "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "🔴 and the claim it replaced is still readable"   "old-owner" "$(cprev owner)"
check "  with the expires nothing else can reconstruct"  "$OLD_EXP" "$(cprev expires)"
check "  and its note"                                   "the round that ended" "$(cprev note)"

section "6C. 🔴 the loser of the race: free before the lock, held inside it"
# The window ROLE-4 measured, made deterministic. foreign_claim answers "free" the first time
# and "taken" the second; the two readings are the subject -- one before the lock, one inside it.
no_claim
rm -f "$FIX/fc.n"
RACE_STUB='
foreign_claim() {
    local n=0; [[ -f "'"$FIX"'/fc.n" ]] && n="$(cat "'"$FIX"'/fc.n")"
    echo $(( n + 1 )) > "'"$FIX"'/fc.n"
    (( n == 0 )) && return 0
    echo "other-session (until 03:00:00, their round)"
}'
OUT="$(claim_run "$RACE_STUB" 'NDT_OWNER=fixture-owner cmd_claim 5 "T1 C"')"
check "🔴 the loser is refused"                          "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
has   "  told it was beaten, not that the lab was busy"  "beaten to it" "$OUT"
has   "  and who took it"                                "other-session" "$OUT"
check "🔴 and it did not write over them"                "gone" \
      "$( [[ -f "$(claim_file)" ]] && echo present || echo gone )"
check "  the reading was taken twice, not once"          "2" "$(cat "$FIX/fc.n" 2>/dev/null)"

section "6D. the ordinary refusal keeps the ordinary sentence"
mk_claim someone-else 3600 "their round"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner cmd_claim 5 "T1 D"')"
check "a live foreign claim refuses"                     "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
has   "  and says it is already claimed"                 "already claimed by someone-else" "$OUT"
hasnt "🔴 not 'beaten to it' -- that points the reader at the wrong minute" "beaten to it" "$OUT"

section "6E. 🔴 the lock is real: nothing is written while another writer holds it"
no_claim
rm -f "$FIX/lock.taken"
( flock -x 9 && : > "$FIX/lock.taken" && sleep 5 ) 9>>"$(claim_file).lock" &
LOCK_HOLDER=$!
for _ in $(seq 1 100); do [[ -f "$FIX/lock.taken" ]] && break; sleep 0.05; done
OUT="$(claim_run '' 'NDT_CLAIM_LOCK_WAIT=1 NDT_OWNER=fixture-owner cmd_claim 5 "T1 E"')"
check "🔴 it gives up rather than writing"               "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "  and wrote nothing"                              "gone" \
      "$( [[ -f "$(claim_file)" ]] && echo present || echo gone )"
has   "  naming what it waited for"                      "lab.claim.lock" "$OUT"
kill "$LOCK_HOLDER" 2>/dev/null; wait "$LOCK_HOLDER" 2>/dev/null

section "6F. 🔴 the readback: the lock only reaches sessions that use this tool"
no_claim
OUT="$(claim_run 'claim_readback_owner() { echo direct-writer; }' \
      'NDT_OWNER=fixture-owner cmd_claim 5 "T1 F"')"
check "a claim that is not ours after the write is refused" "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
has   "  and says whose it is now"                       "direct-writer" "$OUT"
hasnt "🔴 and does not report success"                   "lab claimed by fixture-owner" "$OUT"

section "6G. three real claims in one instant: exactly one is told it won"
# The end-to-end shape of ROLE-4's sweep, with no stub in it. It is 2/16 red before the lock and
# deterministic after it, so it is the confirmation and 6C/6E/6F are the discriminating cells.
no_claim
rm -f "$FIX"/race.*
for i in 1 2 3; do
    ( claim_run '' "NDT_OWNER=racer-$i cmd_claim 5 'T1 G'" > "$FIX/race.$i" 2>&1 ) &
done
wait
check "🔴 exactly one of the three is told it holds the lab" "1" \
      "$(grep -lF "lab claimed by racer-" "$FIX"/race.* 2>/dev/null | wc -l)"
WINNER="$(cf owner)"
check "  and that one is the owner the file names"       "1" \
      "$(grep -cF "lab claimed by $WINNER" "$FIX/race.${WINNER#racer-}" 2>/dev/null)"

# ==========================================================================================
# 7. T2 / T2d: measuring= was a declaration nothing enforced, and the refusal printed a
#    command that could not be pasted
# ==========================================================================================
# 🔴 T2d, measured 2026-09-11 01:57:27-01:57:54 (logs/ROLE-4/10-t3-down-by-owner.log). The claim
# said `measuring=ROLE-4 reader nsr, do not tear down`. The owner's own `ndt down` tore the
# fabric out, printed `clean`, exited 0, killed the declared reader, and never mentioned the
# field -- which then OUTLIVED the teardown that had killed the thing it described. cmd_down read
# foreign_claim and in_flight (iperf3 client, matrix.sh, measure.sh, cpu_probe.py) and nothing
# else, so the one channel a session has for "you cannot see what I am measuring" was read by
# `ndt check` alone.
#
# 🔴 T2, measured 01:56:53 (08-t2-foreign-down.log). The refusal was right and its rescue line
# could not be used:
#     NDT_OWNER=overnight-0905 (until 02:36:24, ROLE-4 T2/T3: reader running) ndt down
# `$held` is a DESCRIPTION, and bash reads `(until ...)` as a subshell. The same message never
# quoted the measuring= the claim declared, so the operator being refused could not see why.
#
# 🔴 THE DIRECTION THAT MATTERS: --force is the override and --deep is not one. A guard that
# any second flag turns off protects nothing, and `--deep` is the flag an operator reaches for
# when a teardown did not reach clean -- i.e. exactly when a declared measurement is most likely
# to still be running.

mk_claim_m() {  # <owner> <seconds-from-now> <note> <measuring>
    printf 'owner=%s\nexpires=%s\nnote=%s\nexclusive_cpu=no\nmeasuring=%s\n' \
        "$1" "$(( $(date +%s) + $2 ))" "$3" "$4" > "$(claim_file)"
}

# down_run [args] -- cmd_down against the fixture with the CLAIM READING REAL. The 2E runner
# above stubs foreign_claim out, which is right for the note and wrong here: who holds the lab
# and what they declared are what these cases are about.
#
# 🔴 Two things in here are load-bearing and were both wrong in the first draft of this block,
# each producing a rc 1 that looked like the refusal under test:
#   * NDT_OWNER is SET. Without it every claim is foreign (the safe default), so 7A's refusal
#     came from the foreign-claim guard and the declaration was never reached -- a green cell
#     over an unexercised branch.
#   * sudo returns 0. The real cmd_down reads the sweep's rc (FINDING #21), so a sudo stub that
#     refuses makes down_rc 1 on every path and "the teardown runs" can never be observed.
down_run() {
    bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
CLAIM=\"\$REPO/.test_run/lab.claim\"
STACK='$FIX/no-such-stack.sh'; LAB='$FIX/no-such-lab'
export NDT_OWNER=fixture-owner
sudo() { return 0; }
in_flight() { :; }
app_probe() { APP_STATE=not-running; }
cmd_clean() { return 0; }
wait_reaped() { return 0; }
clear_up_target() { :; }
mark_teardown_start() { :; }
mark_teardown_end() { :; }
deep_sweep() { echo 'the deep sweep ran'; }
cmd_down $1
echo \"RC=\$?\"" 2>&1
}

section "7A. 🔴 T2d: the owner's own teardown honours the declaration"
mk_claim_m fixture-owner 3600 "T2d round" "ROLE-4 reader nsr, do not tear down"
OUT="$(down_run '')"
check "a declared measurement refuses the teardown"      "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
has   "  and the refusal reads the declaration back"     "ROLE-4 reader nsr, do not tear down" "$OUT"
has   "  naming the field it came from"                  "measuring=" "$OUT"
hasnt "🔴 and the teardown never started"                "[1/3]" "$OUT"
check "  the declaration is still there to be read"      "ROLE-4 reader nsr, do not tear down" "$(cf measuring)"

section "7B. 🔴 --deep is not an override; --force is"
OUT="$(down_run '--deep')"
check "🔴 --deep does not override a declaration"        "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
hasnt "  and no deep sweep ran"                          "the deep sweep ran" "$OUT"
mk_claim_m fixture-owner 3600 "T2d round" "ROLE-4 reader nsr, do not tear down"
OUT="$(down_run '--force')"
check "--force tears down anyway"                        "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
has   "  and says what it went through"                  "declared" "$OUT"

section "7C. an empty declaration declares nothing, and an expired claim declares nothing"
mk_claim_m fixture-owner 3600 "control" ""
OUT="$(down_run '')"
check "🔴 nothing declared: the teardown runs"           "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
hasnt "  and no declaration is discussed"                "measuring=" "$OUT"
mk_claim_m fixture-owner -60 "expired" "a run that is over"
OUT="$(down_run '')"
check "🔴 an expired claim holds nothing, so it declares nothing" "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"

section "7D. 🔴 T2: the rescue command the refusal prints has to parse"
mk_claim_m other-session 3600 "their round" "their matrix, cell 3/8"
OUT="$(down_run '')"
check "a foreign claim refuses the teardown"             "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
RESCUE="$(grep -F 'NDT_OWNER=' <<<"$OUT" | head -1 | sed 's/^[[:space:]]*XX[[:space:]]*//;s/^[[:space:]]*//')"
check "🔴 that line parses as shell -- it is printed to be pasted" "0" \
      "$(bash -n -c "$RESCUE" 2>/dev/null; echo $?)"
check "  it is the command and only the command"         "NDT_OWNER=other-session ndt down" "$RESCUE"
check "🔴 no NDT_OWNER= line carries the description"    "0" \
      "$(grep -F 'NDT_OWNER=' <<<"$OUT" | grep -cF '(until')"
has   "  which is printed on its own line instead"       "until " "$OUT"
has   "🔴 and the foreign refusal quotes the declaration" "their matrix, cell 3/8" "$OUT"

# 🔴 The direction a smaller fix would miss: deleting the "(until ...)" from that line leaves it
# unpasteable for any owner name with a space in it, and owner is free text by design.
mk_claim_m 'weird (owner) name' 3600 "their round" ""
OUT="$(down_run '')"
RESCUE="$(grep -F 'NDT_OWNER=' <<<"$OUT" | head -1 | sed 's/^[[:space:]]*XX[[:space:]]*//;s/^[[:space:]]*//')"
check "🔴 an owner name with spaces and parens still parses" "0" \
      "$(bash -n -c "$RESCUE" 2>/dev/null; echo $?)"


# --- done ---------------------------------------------------------------------------------
printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
