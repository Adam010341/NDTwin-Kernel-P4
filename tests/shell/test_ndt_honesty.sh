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
      "$(grep -c 'for line in verdict_lines(twin_bps, truth_bps, shape):' "$NDT")"
check "🔴 and the window shape really reaches it"          "1" \
      "$(grep -c 'shape = window_shape(subs)' "$NDT")"
check "  and the lines it returns exist nowhere else"      "1" \
      "$(grep -c 'double-count band; accuracy is NOT' "$NDT")"

section "4F. 🔴 #17: a ratio over the band is not self-evidently a stack of clone replicas"
# ROLE-5, 2026-09-11 (ROLE-5-TRAFFIC-REPORT.md section 5 L2; logs/ROLE-5/18-posctrl-L2-live.log).
# ONE `tc netem loss 100%` on s1-eth2, injected two seconds into the eight-second window, with
# the injection asserted twice (the qdisc read back, and the interface moved 0.48 MB in the next
# 2s against 85 MB/2s before) -- and the tripwire printed, verbatim:
#
#     twin  (integrated)   438.5 Mbit/s
#     /proc/net/dev        273.7 Mbit/s
#     ratio                1.60   DOUBLE-COUNTING -- clone replicas stacked
#     check rc=0
#
# There were no clone replicas. The twin publishes its last sampled rate, the ground truth
# collapsed under it, and the tripwire read a LAG as a STACK -- with the mechanism written into
# the verdict string. The same round's L3 control installed one rule fifty times (all HTTP 200,
# accepted_by_switch=1) and the ratio did not move at all, so "install the same rule twice" is
# not this tripwire's positive control either.
#
# Fed here with ROLE-5's own numbers, through the same extraction 4E uses.
VL2="$(python3 - "$NDT" <<'VLPY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"# --- BEGIN verdict_lines.*?\n(.*?)# --- END verdict_lines ---", s, re.S)
if not m:
    print("EXTRACT-FAILED"); sys.exit(0)
ns = {}
exec(m.group(1), ns)
# ROLE-5 L2, the link failure: 3 of 8 sub-windows hot, ground truth fell 1346 -> 82 Mbit/s
print("== LAG ==")
for line in ns["verdict_lines"](438.5e6, 273.7e6,
                                {"hot": 3, "subs": 8, "truth_lo": 82.0, "truth_hi": 1346.1}):
    print(line)
# the shape the tripwire was built for: a constant factor over a steady ground truth
print("== STACK ==")
for line in ns["verdict_lines"](2.0e6, 1.0e6,
                                {"hot": 8, "subs": 8, "truth_lo": 1300.0, "truth_hi": 1346.1}):
    print(line)
print("== NO SHAPE ==")
for line in ns["verdict_lines"](2.0e6, 1.0e6):
    print(line)
print("== OK ==")
for line in ns["verdict_lines"](1.0e6, 1.0e6,
                                {"hot": 0, "subs": 8, "truth_lo": 1300.0, "truth_hi": 1346.1}):
    print(line)
VLPY
)"
hasnt "verdict_lines still extracts and runs"             "EXTRACT-FAILED" "$VL2"
LAGBLK="$(sed -n '/^== LAG ==/,/^== STACK ==/p' <<<"$VL2")"
STKBLK="$(sed -n '/^== STACK ==/,/^== NO SHAPE ==/p' <<<"$VL2")"
NOSHAPE="$(sed -n '/^== NO SHAPE ==/,/^== OK ==/p' <<<"$VL2")"
OKBLK="$(sed -n '/^== OK ==/,$p' <<<"$VL2")"
has   "🔴 ROLE-5's 1.60 is still over the band"          "1.60   DOUBLE-COUNTING" "$LAGBLK"
hasnt "🔴 but it does NOT name clone replicas as the finding" \
      "DOUBLE-COUNTING -- clone replicas stacked" "$LAGBLK"
has   "🔴 it names the twin lagging the truth as a cause" "lagging" "$LAGBLK"
has   "  and stacking as the other one"                   "clone replicas" "$LAGBLK"
has   "🔴 with the evidence that separates them"          "3 of the 8 sub-windows" "$LAGBLK"
has   "  the ground truth range inside the window"        "1346" "$LAGBLK"
has   "  and where that reading came from"                "ROLE-5" "$LAGBLK"
# The other direction: the shape the tripwire was built for must still be CALLED that. A verdict
# that only ever says "two things could have done this" is not a tripwire.
has   "🔴 a constant factor over a steady truth IS the stack shape" "every" "$STKBLK"
has   "  and it says so"                                  "clone replicas" "$STKBLK"
hasnt "  and does not call the lag the leading cause"     "the leading cause is" "$STKBLK"
has   "  while still saying what the lag would have looked like" \
      "produces some hot sub-windows and not all of them" "$STKBLK"
# And with no sub-window evidence at all, neither cause is named as the finding.
has   "🔴 no shape: the two causes are printed side by side" "lagging" "$NOSHAPE"
has   "  saying the window could not tell them apart"     "cannot" "$NOSHAPE"
# The band itself did not move, and a healthy ratio says nothing about either cause.
has   "control: 1.00 is still ok"                         "1.00   ok" "$OKBLK"
hasnt "  and prints no cause discussion"                  "lagging" "$OKBLK"

section "4G. 🔴 #17: the verdict reaches the exit code"
# ROLE-5-TRAFFIC-REPORT.md section 6, S1 附帶 2: `cmd_check` ended on `info`, so it exited 0
# whatever it printed -- measured live at 02:22:24 with `DOUBLE-COUNTING` on the screen and
# `check rc=0` in the same log. "It did not go red" was not observable to any script, and this
# command's output is a screen of prose no driver can read.
#
# 🔴 The python block is the thing that decides, and it needs a kernel, a fabric and traffic;
# what is driven here is the PROPAGATION, with the block replaced by a stub that exits with the
# code the real one would. Named as a seam rather than presented as a live reading -- the live
# path is on the "needs live verification" list.
check_run() {   # <rc the block exits with> -> output + RC=
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
port_open() { [[ \"\$1\" == 8000 ]]; }
in_flight() { :; }
measuring_declared() { :; }
sample_rate() { echo 256; }
rate_source() { echo 'fixture'; }
python3() { return $1; }
cmd_check
echo \"RC=\$?\"" 2>&1
}
OUT="$(check_run 4)"
check "🔴 a DOUBLE-COUNTING verdict reaches the caller as rc 4" "4" "$(rc_of "$OUT")"
has   "  and the rc says where to read the finding"      "read the ratio block above" "$OUT"
has   "  while the rate context still prints under it"   "sample rate" "$OUT"
hasnt "🔴 it is not reported as the check failing to run" "nothing to check" "$OUT"
check "  an ok verdict is still rc 0"                    "0" "$(rc_of "$(check_run 0)")"
check "  and 'could not read the twin' is rc 1"          "1" "$(rc_of "$(check_run 1)")"
# The source half of the same statement: the block exits 4 on the verdict it printed. A text
# check, said out loud, because the condition lives inside a python heredoc that needs the lab.
check "🔴 the block exits 4 when the ratio is over the band" "1" \
      "$(grep -c 'sys.exit(4)' "$NDT")"

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

section "5D. A1-b: 'down' has an rc table, and it names the red that comes from an earlier round"
# 🔴 The teardown gained an exit code it did not have (`stack.sh down` non-zero is now `ndt down`
# non-zero, Adam's ruling 2026-09-12), and one of the three things behind it is read from a
# `.exit` record ON DISK. So the first `ndt down` after a round in which something was SIGKILLed
# -- systemd-oomd does that on this laptop -- exits 1 for an ending that already happened. An
# operator who is not told that reads it as "this teardown failed" and goes looking for a fabric
# that is gone; the one after it is green again, which makes it look intermittent as well.
has   "  🔴 down has an rc table at all"                 "exit 0 the teardown finished" "$HELP"
has   "  naming the stack half as one cause of 1"        "stack.sh's half exited non-zero" "$HELP"
has   "  🔴 and that rc 1 can be an ENDING FROM AN EARLIER ROUND" "ENDING FROM AN EARLIER ROUND" "$HELP"
has   "  naming the signals that produce it"             "SIGKILL" "$HELP"
has   "  and the file it is read out of"                 ".test_run/pids/<name>.exit" "$HELP"
has   "  🔴 and that it is delivered once, so the next down is green" "delivered once" "$HELP"
has   "  with the two statements kept apart"             "are not the same statement" "$HELP"
# 🔴 Checked against the code, not against itself: a text-only assertion would go on passing if
# the rc stopped being carried.
check "  the rc the table describes is really carried"   "1" \
      "$(grep -c 'the kernel/proxy/Ryu half did not end cleanly' "$NDT")"

section "5E. A7: the help says what 'ndt check' rc 0 is worth when there was no traffic"
# G-33's second zero-discrimination, Adam's ruling 2026-09-12 (A7): the rc STAYS 0 -- 3 would
# make every `ndt check` on an idle lab non-zero -- and the help has to carry what that 0 is
# worth. Under 1 Mbit/s of ground truth the command prints no ratio and no verdict at all and
# exits 0, which is byte-identical, to a script, to "inside the band". A rule-frequency study
# with no iperf3 running collects that answer for twenty minutes.
has   "  🔴 rc 0 is named as 'nothing was compared'"     "rc 0 ALSO MEANS" "$HELP"
has   "  with the floor that triggers it"                "under 1 Mbit/s of ground truth" "$HELP"
has   "  🔴 and that it is not the fabric being healthy" "NOT the fabric being healthy" "$HELP"
has   "  it says what to read instead of the code"       "read the ratio block" "$HELP"
has   "  and that 0 is a ruling, not an oversight"       "kept at 0 deliberately" "$HELP"
has   "  attributed, so it can be revisited"             "G-33" "$HELP"
# 🔴 Against the code: the branch the sentence describes, and the fact that it does not exit.
check "  the floor the help names is the floor the code uses" "1" \
      "$(grep -c '^if truth_bps < 1e6:' "$NDT")"
check "  🔴 and that branch still reaches no sys.exit"   "1" \
      "$(grep -c 'sys.exit(4)' "$NDT")"

section "5F. ROLE-12: the 'down' rc table says a port held at [1/3] is not by itself a failure"
# The other side of the rc A1-b connected. ROLE-12 measured it 7 times out of 7 on 2026-09-12:
# every `ndt down` over a LIVE P4 fabric exits 1 because stack.sh's port assertion runs in step
# [1/3], before the bmv2 sweep in [3/3], and therefore names the twenty ports of the fabric this
# very teardown is about to remove -- while the same log prints `ok ports closed: ...` four
# steps later. An operator told only "exit 1" reads that as a teardown that failed. The rc now
# follows a re-read taken after the sweep, and the table has to say so, or the next reader
# reconciles a 0 against seven nights of 1s with nothing to explain the change.
has   "  🔴 the table names the ordering that produces it" "[1/3] runs before" "$HELP"
has   "  and that it is the live fabric accusing itself"   "the fabric this teardown is about to remove" "$HELP"
has   "  with the measurement behind it"                   "7 of 7" "$HELP"
has   "  🔴 and that those ports are RE-READ after the sweep" "re-read after 'verify clean'" "$HELP"
has   "  naming both outcomes of that second reading"      "still held -> rc 1" "$HELP"
has   "  🔴 and that the other two halves are unchanged"   "are red whatever the sweep does" "$HELP"
has   "  attributed, so it can be revisited"               "ROLE-12" "$HELP"
# 🔴 Against the code. A text-only cell here would go on passing after the re-read had been
# deleted, which is the exact state the table would then be lying about.
check "  the re-read the table describes is really taken"  "1" \
      "$(grep -c "were closed by \[3/3\]" "$NDT")"
check "  🔴 and it is pinned to stack.sh's return site, not to a word list" "1" \
      "$(grep -c '^STACK_DOWN_RETURNED_ON_PORTS=' "$NDT")"

section "5G. ROLE-12 cell 3: the help says 'clean' refuses while a teardown is running"
# `ndt clean` is the command the manual tells a first-time reader to run to verify a lab, and
# on 2026-09-12 02:08:24 it answered a live teardown by listing that teardown's own fabric as
# residue and advising `ndt down --deep`. The refusal is new behaviour on a documented command,
# so the documented rc table is where it has to appear -- a guard nobody is told about is read
# as a malfunction the first time it fires.
has   "  🔴 the refusal is documented at all"        "it REFUSES while an 'ndt down'" "$HELP"
has   "  and that it is rc 1, not a quiet skip"      "that refusal is also rc 1" "$HELP"
has   "  naming what it would otherwise have listed" "middle of killing" "$HELP"
has   "  🔴 and whose processes the old advice would have taken" "the operator's own" "$HELP"
has   "  with the pid to wait for named in the block" "names the pid to wait for" "$HELP"
has   "  and a stale marker not refusing"            "removed and does not" "$HELP"
has   "  attributed, so it can be revisited"         "ROLE-12 cell 3" "$HELP"
# 🔴 Against the code: the refusal is in cmd_clean, it goes through the one shared opening the
# bring-up refusal uses, and it is scoped to somebody ELSE's teardown -- `ndt down` calls
# cmd_clean as its own verify step, under its own marker.
check "  the refusal the help describes is in cmd_clean" "1" \
      "$(grep -c 'teardown_in_flight_refusal "judge this lab"' "$NDT")"
check "  🔴 and it is scoped to another process's marker" "1" \
      "$(grep -c 'if tif="$(teardown_in_flight)" && \[\[ "${tif%% \*}" != "$\$" \]\]; then' "$NDT")"

section "5H. ROLE-11 F7 / FIX-DOC-1: the help's --deep line quotes ports.sh's table, not three ports"
# The help said `--deep also kills whatever still holds :8000/:8080/:8081`. deep_sweep has read
# ports.sh's table since the table existed -- nine rules, 27 ports once the two per-device
# ranges are expanded -- so the sentence understated by 24 the set of processes that verb can
# kill, in the one place an operator is told what --deep does before running it. The manual was
# corrected on 09-12 (FIX-DOC-1 F7, commit c395da50); this is the copy inside the tool.
#
# 🔴 The number is GENERATED from the table, not typed next to it. A number typed here is the
# same artefact one edit later: ROLE-11 counted 25 by hand on the machine and the table says 27.
hasnt "  🔴 --deep no longer names three ports"       ":8000/:8080/:8081" "$HELP"
has   "  it names the table instead"                  "ANY port in ports.sh's table" "$HELP"
has   "  🔴 with the size read out of the table"      "9 rule(s), 27 port(s)" "$HELP"
has   "  and the specs themselves, ranges and all"    "30051-30060/9091-9100" "$HELP"
has   "  saying what it used to claim"                "used to name only the three ports" "$HELP"
has   "  attributed"                                  "ROLE-11 F7" "$HELP"
# 🔴 Against the code, and this is the cell that matters: the two numbers above are printed by
# a function reading NDT_PORT_TABLE. Typing `27` back into the prose passes every cell above
# and puts the defect back the day somebody adds a row.
check "  the size in the help is computed, not typed" "1" \
      "$(grep -c 'ndt_port_table_size all' "$NDT")"
check "  and so is the list of specs"                 "1" \
      "$(grep -c 'the ports --deep sweeps, from the table' "$NDT")"

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

section "6H. 🔴 'ndt release' keeps the claim it removed, as .prev"
# FIX-NDT-3 SUMMARY section 7-3. `ndt claim` keeps one generation (6B above); `release` DELETED,
# and the two neighbours it was modelled on -- lab.handoff and round.baseline -- both rename. The
# objection recorded there is that `.prev` could make a reader think somebody still holds the
# lab; it cannot, because `ndt status` reads the LIVE claim for that question and answers "none"
# after a release. What `.prev` answers is a different question -- who held it, and until when --
# which is asked after the fact more often than during.
rm -f "$(claim_file).prev"
mk_claim fixture-owner 3600 "the round that is ending"
OLD_EXP="$(cf expires)"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner cmd_release')"
check "release succeeds"                                 "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "  the live claim is gone"                         "gone" \
      "$( [[ -f "$(claim_file)" ]] && echo present || echo gone )"
check "🔴 and it was kept, not deleted"                  "fixture-owner" "$(cprev owner)"
check "  with the expires nothing else can reconstruct"  "$OLD_EXP" "$(cprev expires)"
check "  and its note"                                   "the round that is ending" "$(cprev note)"
has   "  and release says where it went"                 "lab.claim.prev" "$OUT"
# --force takes the same path: it is the override for whose claim it is, not for keeping a copy.
rm -f "$(claim_file).prev"
mk_claim someone-else 3600 "their round"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner cmd_release --force')"
check "release --force succeeds"                         "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "🔴 and keeps the claim it overrode"               "someone-else" "$(cprev owner)"
# 🔴 The other direction: with no claim held there is nothing to keep, and a no-op must not
# manufacture a `.prev` -- a reader would see a handover that never happened. Same reasoning as
# the round-baseline case in test_ndt_round_baseline.sh group 12: releasing a claim you never
# took says nothing about whose round is running.
no_claim
rm -f "$(claim_file).prev"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner cmd_release')"
has   "release with no claim says so"                    "no claim to release" "$OUT"
check "🔴 and writes no .prev"                           "gone" \
      "$( [[ -f "$(claim_file).prev" ]] && echo present || echo gone )"
no_claim
rm -f "$(claim_file).prev"

section "6I. 🔴 R7 I-2 condition 2: 'ndt status' says the claim changed hands"
# R7's own acceptance of the I-2 fix (R7-reconciler.md section 3b, 04:29:25): condition 1 PASSED
# -- `.prev` really is the claim that was replaced, checked field by field against R7's own
# independent 118-point sampling record -- and CONDITION 2 FAILED. R7 grepped the WHOLE of
# `ndt status` for prev|changed hands|took|handover|previous|was held: 0 hits. So the evidence
# was being kept and no interface mentioned it; a session arriving at 04:29 still could not see
# that the claim had been rewritten two minutes earlier without knowing to cat a file.
#
# 🔴 The row is printed whether or not a claim is live, because the person who needs it is the
# one who arrives AFTER the change. claim_line is stubbed to `none` in run_status, so nothing
# below can be coming from the live-claim row.
rm -f "$(claim_file).prev"
mk_claim first-owner 3600 "the round that ended"
OUT="$(claim_run '' 'NDT_OWNER=second-owner cmd_claim 5 "the next round"')"
check "a new owner claims an expired-or-free lab"        "RC=1" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
# A LIVE foreign claim is refused (6D), so the handover this row is about is the one that
# happens through the file: the previous claim expires or is released, and the next owner takes
# it. Written here in the two steps the machine really takes.
mk_claim first-owner -60 "the round that ended"
OLD_EXP="$(cf expires)"
OUT="$(claim_run '' 'NDT_OWNER=second-owner cmd_claim 5 "the next round"')"
check "  once it has lapsed, the next owner takes it"    "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "  and the replaced claim is kept"                 "first-owner" "$(cprev owner)"
OUT="$(run_status)"
has   "🔴 status discloses the claim that was replaced"  "prev claim" "$OUT"
has   "  naming who held it"                             "first-owner" "$OUT"
has   "  and the file a reader can check for themselves" "lab.claim.prev" "$OUT"
has   "🔴 and that it CHANGED HANDS, with both names"    "changed hands: first-owner -> second-owner" "$OUT"
has   "  and when, from the record's own timestamp"      "prev claim" "$OUT"
# 🔴 The other direction, and it is what stops this row from being noise: the SAME owner
# re-claiming is a rewrite, not a handover. R7's I-2 residue #1 is a note corrected by
# re-claiming, which moved `expires` three hours out -- that is worth disclosing as a rewrite
# and calling it a handover would teach the reader to skip the row.
rm -f "$(claim_file).prev"
mk_claim same-owner -60 "a round"
OUT="$(claim_run '' 'NDT_OWNER=same-owner cmd_claim 5 "same owner again"')"
OUT="$(run_status)"
has   "the same owner re-claiming is still disclosed"    "prev claim" "$OUT"
hasnt "🔴 but it is NOT called changed hands"            "changed hands" "$OUT"
has   "  it is called a rewrite by the same owner"       "same owner" "$OUT"
# With no .prev at all there is no row: a machine nobody has claimed twice has nothing to say.
no_claim
rm -f "$(claim_file).prev"
OUT="$(run_status)"
hasnt "no .prev -> no handover row at all"               "prev claim" "$OUT"

section "6J. 🔴 one writer for the claim file, so the field order cannot be a function of who wrote"
# R7's 附帶發現 (section 3b): `lab.claim` and `lab.claim.prev` carried the five fields in
# DIFFERENT orders -- owner/expires/note/exclusive_cpu/measuring against
# owner/expires/exclusive_cpu/measuring/note -- because they came from two different writers.
# Harmless that night (R7 compared field by field), and it makes `diff lab.claim lab.claim.prev`
# or a hash comparison report a change forever, for two files that mean the same thing.
#
# claim_rewrite fixed the order for the note path (8C). This is the other writer: claim_take's
# own printf. There is now ONE, and the assertion is on the SOURCE -- a text check, said out
# loud, because two printfs that agree today are exactly what R7 found and what drifts next.
check "🔴 exactly one place writes the five fields"      "1" \
      "$(grep -c "printf 'owner=%s" "$NDT")"
# ...and both paths still produce the documented order, driven rather than read.
no_claim
rm -f "$(claim_file).prev"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner NDT_MEASURING="cell 3/8" cmd_claim 5 "a note"')"
check "claim writes the header's order"                  "owner expires note exclusive_cpu measuring" \
      "$(sed 's/=.*//' "$(claim_file)" | tr '\n' ' ' | sed 's/ $//')"
claim_run '' 'NDT_OWNER=fixture-owner set_claim_note "corrected"' >/dev/null 2>&1
check "  and a note rewrite keeps it"                    "owner expires note exclusive_cpu measuring" \
      "$(sed 's/=.*//' "$(claim_file)" | tr '\n' ' ' | sed 's/ $//')"
check "  the declaration survived both"                  "cell 3/8" "$(cf measuring)"
# 🔴 And the copy kept for the next reader is BYTE-IDENTICAL, which is the check R7 could not
# make that night: with two writers, comparing the files was guaranteed to report a difference.
# The same owner re-claiming, because a LIVE foreign claim is refused (6D) and this check is
# about the copy, not about who may take the lab.
BEFORE_SUM="$(sha256sum "$(claim_file)" | cut -d' ' -f1)"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner cmd_claim 5 "a second window"')"
check "  the re-claim succeeded"                         "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "🔴 .prev is byte-identical to the claim it replaced" "$BEFORE_SUM" \
      "$(sha256sum "$(claim_file).prev" 2>/dev/null | cut -d' ' -f1)"
no_claim
rm -f "$(claim_file).prev"

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
#   * 🔴 STACK exists and succeeds (A1-b, 2026-09-12). cmd_down now reads `stack.sh down`'s exit
#     status too, and a STACK that is not there is bash's 127 -- a true red, because the first
#     step of the teardown did not run. Four cells here went red on that and every one of them
#     is about the CLAIM, not about the stack; a fixture that cannot reach "the teardown runs"
#     proves nothing about the declaration guard. That the failed stack half IS red is asserted
#     where it belongs: tests/shell/test_ndt_up_down_robust.sh section 13.
printf '#!/usr/bin/env bash\necho "  stopped kernel"\nexit 0\n' > "$FIX/stack-ok.sh"
chmod +x "$FIX/stack-ok.sh"
down_run() {
    bash -c "source '$NDT' >/dev/null 2>&1
REPO='$FIX'
CLAIM=\"\$REPO/.test_run/lab.claim\"
STACK='$FIX/stack-ok.sh'; LAB='$FIX/no-such-lab'
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

# ==========================================================================================
# 8. T5: the note that failed silently, the declaration that outlived its teardown, and the
#    field that moved to the end of the file
# ==========================================================================================
# 🔴 T5, measured 2026-09-11 01:55:07 against 01:59:53 (logs/ROLE-4/06-up-ovs4.log,
# 17-claim-timeline.txt). The same `ndt up ovs 4`, twice: run by the owner it rewrote the note
# to "in use: ..."; run with NDT_OWNER UNSET it changed nothing and said nothing, because
# set_claim_note returns 1 for a claim that is not yours and claim_note_up threw that away
# (`return 0`, no warn). So the note went on describing the previous round while a fabric was
# being built -- I-4 again, in the two arms where the note matters most.

section "8A. 🔴 an 'ndt up' that could not write the note says so"
mk_claim fixture-owner 3600 "$I4_NOTE"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner claim_note_up "ovs 4"')"
hasnt "our own live claim: written, and nothing is warned" "NOT updated" "$OUT"
mk_claim other-session 3600 "$I4_NOTE"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner claim_note_up "ovs 4"')"
has   "🔴 a live claim we do not hold: warned, not swallowed" "NOT updated" "$OUT"
has   "  quoting the sentence that is still standing"    "$I4_NOTE" "$OUT"
has   "  and naming who holds the lab"                   "other-session" "$OUT"
check "  the note itself is unchanged"                   "$I4_NOTE" "$(cf note)"
OUT="$(claim_run '' 'unset NDT_OWNER; claim_note_up "ovs 4"')"
has   "🔴 NDT_OWNER unset -- the 01:55 arm -- is warned too" "NOT updated" "$OUT"
no_claim
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner claim_note_up "ovs 4"')"
hasnt "🔴 no claim at all: silent, there is nothing to narrate" "NOT updated" "$OUT"
mk_claim fixture-owner -60 "$I4_NOTE"
OUT="$(claim_run '' 'NDT_OWNER=fixture-owner claim_note_up "ovs 4"')"
hasnt "  and an expired claim holds nothing, so it says nothing" "NOT updated" "$OUT"

section "8B. 🔴 the teardown clears the declaration it tore down"
mk_claim_m fixture-owner 3600 "in use: ndt up ovs 4" "ROLE-4 reader nsr"
OUT="$(down_run '--force')"
check "the forced teardown succeeds"                     "RC=0" "$(grep -o 'RC=[0-9]*' <<<"$OUT")"
check "🔴 measuring= is empty afterwards"                "" "$(cf measuring)"
has   "  and the note records that this down cleared it" "cleared measuring" "$(cf note)"
has   "  while still saying the lab came down"           "down at " "$(cf note)"
has   "  and that the claim was kept"                    "claim kept" "$(cf note)"

section "8C. 🔴 the field order is fixed, whoever writes"
mk_claim_m fixture-owner 3600 "first note" "a run"
claim_run '' 'NDT_OWNER=fixture-owner set_claim_note "second note"' >/dev/null 2>&1
check "the note was rewritten"                           "second note" "$(cf note)"
check "🔴 and note did not migrate to the last line"     "owner expires note exclusive_cpu measuring" \
      "$(sed 's/=.*//' "$(claim_file)" | tr '\n' ' ' | sed 's/ $//')"
check "  the declaration survived the rewrite"           "a run" "$(cf measuring)"
check "  and so did exclusive_cpu"                       "no" "$(cf exclusive_cpu)"
# 🔴 A rewrite that knows only five fields DROPS what another script wrote -- and this tool's
# own header invites that writer ("any script may write the file directly").
printf 'x_extra=kept by another writer\n' >> "$(claim_file)"
claim_run '' 'NDT_OWNER=fixture-owner set_claim_note "third note"' >/dev/null 2>&1
check "  a field another script wrote is carried through" "kept by another writer" "$(cf x_extra)"

no_claim
rm -f "$(claim_file).prev" "$(claim_file).lock" "$FIX/fc.n" "$FIX"/race.*

# ==========================================================================================
# 9. T3 / T4: two sentences that describe the tool wrongly
# ==========================================================================================

section "9A. T3: 'these survive ndt down' was disproved by the same round's ndt down"
# ROLE-4 01:56:27-01:57:54. Two `ndt apps nsr` in the same second left two processes and two
# pidfiles naming different ones; `ndt status` printed "these survive 'ndt down'", and the
# `ndt down` in that SAME round printed "nsr is running untracked (pid 2666802 2666801) --
# stopping it by pid" and killed both (`ps` counted 0 afterwards, 10-t3-down-by-owner.log).
# cmd_down's [0/3] gate is app_probe, not app_running, so an untracked app is precisely the one
# it does stop -- and that was a deliberate change (G-6).
status_untracked() {
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
app_probe() { APP_STATE=pidfile-lost-but-alive; APP_LIVE_PIDS=(2666802 2666801); }
cmd_status
echo \"RC=\$?\"" 2>&1
}
OUT="$(status_untracked)"
has   "the untracked row is still printed"               "no pidfile names them" "$OUT"
hasnt "🔴 the sentence that round's teardown disproved is gone" "these survive 'ndt down'" "$OUT"
has   "🔴 and it says what a teardown really does to them" "'ndt down' does stop these" "$OUT"
has   "  with the reason it can"                         "scans" "$OUT"
has   "  and why to stop them now anyway"                "keep polling" "$OUT"
# 🔴 The sentence is checked against the code, not only against itself: a text-only assertion
# would go on passing if cmd_down went back to the pidfile.
check "  cmd_down still stops an untracked app by pid"   "1" \
      "$(grep -c 'warn "\$a is running untracked' "$NDT")"

section "9B. T4: the help says what a claim does NOT cover"
# 🔴 NOT FIXED, and now said rather than implied. ROLE-4 T4, measured 02:01:16-02:02:45
# (14-t4-expiry.log, 14b-write-loop.log): a loop calling install_flow_entry and
# delete_flow_entry every 2 s got http 200 through its own claim's expiry (claim_left=-1s) and
# through another owner taking the claim (owner=intruder-0911, claim_left=-3s), and stopped only
# when that owner's `ndt down` SIGTERMed the kernel. The only signal that writer ever received
# was curl printing 000. Whether the northbound API should read the claim is Adam's decision;
# what the help must not do is leave a reader believing it already does.
has   "  the help scopes the claim to this tool's own verbs" "claim only blocks the 'ndt'" "$HELP"
has   "  and names the API as outside it"                "not the northbound API" "$HELP"
has   "🔴 and says expiry and loss are silent"           "no signal" "$HELP"
# The manual carries the same fact. Asserted here rather than nowhere; note that the mutation
# gate copies only ndt, so this cell is not mutation-protected and the SUMMARY says so.
MANUAL="$HERE/../../doc/2026-08-17_testing-manual.md"
check "  the manual is readable from here"               "yes" \
      "$( [[ -r "$MANUAL" ]] && echo yes || echo no )"
has   "🔴 and the manual's claim section says it too"    "ROLE-4 T4" "$(cat "$MANUAL" 2>/dev/null)"

# --- done ---------------------------------------------------------------------------------
printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
