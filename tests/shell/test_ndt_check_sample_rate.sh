#!/usr/bin/env bash
#
# Which plane's sampling rate do `ndt status` and `ndt check` report, and what does that rate
# mean for the numbers underneath it?
#
# [Co-developed with claude code -- Adam]
#
# TWO findings, both measured 2026-09-06 (rounds/06-X-experiments.md), both decided by Adam on
# 09-06 (grill §4D round 9, D-2: "要，一起印").
#
# X-2 -- `ndt status` read the WRONG PLANE. sample_rate() decoded the rng bound out of
# p4_proxy/p4_src/build/ndtwin_switch.json, a bmv2 compile artefact, and printed it on every
# plane. On OVS the rate lives in OVSDB's `sflow` table (testbed_topo.py:160, sampling=256) and
# has nothing to do with that file. Verbatim, logs/x1-22-status-blind-to-ovs-rate.log, after
# setting all ten sflow records to 64:
#
#     ovs now: 64
#     --- ndt status says: ---
#       sample rate    1/256
#
# The two numbers had agreed by coincidence since the fabric was built, so nobody noticed.
#
# X-1 -- and that rate is the thing that decides every bandwidth number. Against a ground
# truth stable to <=0.4%, the twin's ratio tracked the sampling rate monotonically over 19
# runs, every one of them LOW, with zero telemetry loss in all three cells:
#
#     1/64    mean ratio 0.977   (6 runs)      under-reports  2.3%
#     1/256   mean ratio 0.902   (9 runs)      under-reports  9.8%
#     1/1024  mean ratio 0.753   (4 runs)      under-reports 24.8%
#
# `ndt check` printed `ok` for all of them, because the ok band is 0.5-1.5 -- it is a
# double-count tripwire and Adam kept the band. What it now also prints is what the ratio is
# EXPECTED to be at the rate in force, so `ok` cannot be read as "accurate".
#
# 🔴 THREE DIRECTIONS:
#   * a reader that always answers from OVSDB fails group 2 (the P4 plane, where the compiled
#     pipeline IS the answer) and group 3 (no fabric at all);
#   * a reader that reports the first of ten sflow records fails group 4 -- ten records that
#     disagree are a fabric with no single rate, and picking one hides exactly that;
#   * an expected-shortfall table that interpolates fails group 6: the curve saturates, so a
#     number between the measured points is a claim nobody made.
#
# Offline: no fabric, no sudo, no kernel. ovs-vsctl is answered by a stub and the compiled
# JSON is a fixture.
#
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_ndt_check_sample_rate.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; exit 2; }
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

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-rate-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/p4_proxy/p4_src/build" "$FIX/p4_proxy/mininet" "$FIX/.test_run" "$FIX/setting"
printf '4\n' > "$FIX/p4_proxy/mininet/host_count_override"

# The compiled pipeline, exactly as p4c emits the primitive. 256 here THROUGHOUT, so that any
# case below which answers 256 on the OVS plane is answering out of the wrong file -- which is
# X-2, and is the only way these cases can tell the two sources apart.
cat > "$FIX/p4_proxy/p4_src/build/ndtwin_switch.json" <<'JSON'
{"actions":[{"name":"sample","primitives":[{"op":"modify_field_rng_uniform","parameters":[{"type":"field","value":["scalars","metadata.sample_rand"]},{"type":"hexstr","value":"0x0000"},{"type":"hexstr","value":"0x00ff"}]}]}]}
JSON

# --- the seam ------------------------------------------------------------------------------
# ndt_sudo_capture is the one call ovs_sample_rate makes. FX_SFLOW is what `ovs-vsctl --bare
# --columns=sampling list sflow` prints (one line per record); FX_SUDO_RC non-zero is a refusal.
STUBS='
REPO="'"$FIX"'"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
ndt_sudo_capture() {
    [[ "${FX_SUDO_RC:-0}" == 0 ]] || return "${FX_SUDO_RC}"
    printf "%s" "${FX_SFLOW-}"
}
'
drive() {   # drive <shell-code> -> output + RC=
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
val()   { sed '/^RC=/d' <<<"$1"; }

ten() { local i out=""; for i in $(seq 10); do out+="$1
"; done; printf '%s' "$out"; }

# ==========================================================================================
section "1. 🔴 X-2: on the OVS plane the rate comes from OVSDB, not from the bmv2 artefact"
OUT="$(FX_SFLOW="$(ten 64)" drive 'sample_rate ovs')"
check "ten sflow records all saying 64 -> 64"           "64"  "$(val "$OUT")"
hasnt "🔴 and NOT 256, which is what the compiled json says" "256" "$(val "$OUT")"
OUT="$(FX_SFLOW="$(ten 1024)" drive 'sample_rate ovs')"
check "  a swept fabric reads back the swept value"     "1024" "$(val "$OUT")"
OUT="$(drive 'rate_source ovs')"
has   "  and the source is named on every run"          "ovs-vsctl --columns=sampling list sflow" "$(val "$OUT")"

section "2. 🔴 the other direction: on P4 the compiled pipeline IS the answer"
OUT="$(FX_SFLOW="$(ten 64)" drive 'sample_rate p4')"
check "the P4 plane still reads the built json"         "256" "$(val "$OUT")"
OUT="$(drive 'rate_source p4')"
has   "  named as the build artefact it is"             "p4_proxy/p4_src/build/ndtwin_switch.json" "$(val "$OUT")"

section "3. no fabric: the artefact is all there is, and the row says so"
OUT="$(drive 'sample_rate none')"
check "it still answers"                                "256" "$(val "$OUT")"
OUT="$(drive 'rate_source none')"
has   "🔴 but says it is not a reading of anything running" "no fabric running -- this is the COMPILED P4 pipeline, not a reading" "$(val "$OUT")"

section "4. 🔴 ten records that disagree are not a rate"
OUT="$(FX_SFLOW="$(printf '64\n64\n64\n64\n64\n256\n256\n256\n256\n256\n')" drive 'sample_rate ovs')"
check "an interrupted sweep is reported as DISAGREE"    "OVS-DISAGREE:64,256" "$(val "$OUT")"
OUT="$(drive 'rate_label OVS-DISAGREE:64,256')"
has   "  the label names every value it saw"            "sFlow records DISAGREE (64,256)" "$(val "$OUT")"
has   "  and says what that means"                      "no single sampling rate" "$(val "$OUT")"
hasnt "🔴 and it is never printed as a fraction"        "1/OVS" "$(val "$OUT")"

section "5. 🔴 'nothing is sampling' and 'could not ask' are not rates either"
OUT="$(FX_SFLOW="" drive 'sample_rate ovs')"
check "no sflow record at all"                          "OVS-NOSFLOW" "$(val "$OUT")"
OUT="$(drive 'rate_label OVS-NOSFLOW')"
has   "  said in words"                                 "this fabric samples NOTHING" "$(val "$OUT")"
OUT="$(FX_SUDO_RC=1 FX_SFLOW="$(ten 64)" drive 'sample_rate ovs')"
has   "a refused ovs-vsctl is UNREADABLE"               "UNREADABLE:" "$(val "$OUT")"
hasnt "🔴 and never a number"                           "64" "$(val "$OUT")"
OUT="$(drive 'rate_label UNREADABLE:sudo -n ovs-vsctl would not answer')"
has   "  and never 'the default'"                       "NOT a rate, and not 'the default'" "$(val "$OUT")"

section "6. 🔴 X-1: what the ratio is EXPECTED to be at this rate, measured, never interpolated"
OUT="$(drive 'expected_shortfall 64')"
check "1/64"    "0.977 2.3 6"   "$(val "$OUT")"
OUT="$(drive 'expected_shortfall 256')"
check "1/256"   "0.902 9.8 9"   "$(val "$OUT")"
OUT="$(drive 'expected_shortfall 1024')"
check "1/1024"  "0.753 24.8 4"  "$(val "$OUT")"
OUT="$(drive 'expected_shortfall 512; echo "rc=$?"')"
check "🔴 a rate X1 did not measure has NO reference"   "1" "$(sed -n 's/^rc=//p' <<<"$OUT" | head -1)"

OUT="$(drive 'check_rate_lines 1024 ovs')"
has   "check prints the rate"                           "sample rate          1/1024" "$(val "$OUT")"
has   "  and where it came from"                        "OVS: ovs-vsctl" "$(val "$OUT")"
has   "🔴 and the shortfall to expect at it"            "under-reports by ~24.8%" "$(val "$OUT")"
has   "  with the whole measured curve beside it"       "1/64 -> 0.977, 1/256 -> 0.902, 1/1024 -> 0.753" "$(val "$OUT")"
has   "🔴 and says the expected reading is not a healthy one" "is the EXPECTED reading" "$(val "$OUT")"
OUT="$(drive 'check_rate_lines 512 ovs')"
has   "🔴 an unmeasured rate says so instead of guessing" "no reference measurement for this rate" "$(val "$OUT")"
has   "  and says which three were measured"            "X1 measured 1/64, 1/256 and 1/1024 only" "$(val "$OUT")"
hasnt "  and invents no number"                         "under-reports by" "$(val "$OUT")"
OUT="$(drive 'check_rate_lines DISABLED:lo=1 p4')"
has   "a dead pipeline keeps its own words here too"    "SAMPLING DISABLED" "$(val "$OUT")"

section "7. the wiring: 'ndt check' asks, and 'ndt status' prints the source"
CHECK_SRC="$(sed -n '/^cmd_check() {/,/^}/p' "$NDT")"
has   "cmd_check reads the plane"                       'cplane="$(live_dataplane_kind)"' "$CHECK_SRC"
has   "  and the rate of THAT plane"                    'crate="$(sample_rate "$cplane")"' "$CHECK_SRC"
has   "  and prints both"                               'check_rate_lines "$crate" "$cplane"' "$CHECK_SRC"

STATUS_STUBS='
REPO="'"$FIX"'"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
MANIFEST="$REPO/manifest.json"
ndt_sudo_capture() { [[ "${FX_SUDO_RC:-0}" == 0 ]] || return "${FX_SUDO_RC}"; printf "%s" "${FX_SFLOW-}"; }
claim_line() { echo none; }
git_lines() { :; }
in_flight() { :; }
foreign_claim() { :; }
bmv2_binary() { echo fixture-bmv2; }
stale_pipeline() { return 1; }
source_ahead_of_build() { return 1; }
bmv2_count() { echo 0; }
mn_count() { echo 14; }
fabric_host_count() { echo 4; }
ovs_bridge_count() { echo 10; }
ovs_daemon_running() { return 0; }
topo_session() { return 0; }
port_open() { return 1; }
http_get_graph() { :; }
http_get_flow_entries() { echo "[]"; }
lock_probe() { echo free; }
netem_count() { echo 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
app_probe() { APP_STATE=not-running; }
lab_version_verdict() { echo "same fixture-sha fixture-sha"; }
'
run_status() {
    bash -c "source '$NDT' >/dev/null 2>&1
$STATUS_STUBS
cmd_status ${1:-}
echo \"RC=\$?\"" 2>&1
}
OUT="$(FX_SFLOW="$(ten 64)" run_status)"
has   "🔴 ndt status on an OVS fabric prints 1/64"      "sample rate    1/64" "$OUT"
hasnt "🔴 and not the 1/256 of X-2"                     "sample rate    1/256" "$OUT"
has   "  with a source row beside it"                   "rate source    OVS: ovs-vsctl" "$OUT"

OUT="$(FX_SFLOW="" run_status --check)"
has   "🔴 a fabric with no sflow record is a --check problem" "- no sFlow record exists on any OVS bridge" "$OUT"
OUT="$(FX_SFLOW="$(printf '64\n256\n')" run_status --check)"
has   "🔴 so is a fabric whose records disagree"        "- the OVS sflow records disagree" "$OUT"
OUT="$(FX_SUDO_RC=1 run_status --check)"
has   "🔴 so is a rate that could not be read"          "- the sampling rate could not be read" "$OUT"

# --- done ---------------------------------------------------------------------------------
# 🔴 `echo`, not printf: tests/shell/test_l1_shell_scoring.sh group C reads the LAST
# `echo "..."` out of every suite's SOURCE and requires it to render a count the scorer in
# tools/ can read. A summary printed with printf is invisible to it.
echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
