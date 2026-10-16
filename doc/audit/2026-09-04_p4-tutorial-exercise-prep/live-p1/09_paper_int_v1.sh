#!/usr/bin/env bash
#
# Live ⑨ -- a published paper app on NDTwin: niloysh/int-v1 (MIT), `ndt up p4 --app`.
#
# [Co-developed with claude code -- Adam]
#
# WRITTEN OFFLINE, NEVER RUN BY ITS AUTHOR (no lab, no sudo). Adam's 10-08 ruling: live runs happen
# in the shared main checkout after the branch is merged into trunk. The offline half -- the
# package's pipeline loads on a throwaway simple_switch_grpc, every entry goes in and reads back,
# and int-v1's INT frame comes out byte for byte -- is doc/audit/2026-10-16_p4-paper-apps/
# offline_int_v1.py; this step is the part only a fabric can show.
#
# THE APP. int-v1 @84a3ebe8 (github.com/niloysh/int-v1, MIT, local clone /home/adam/paper-apps/int-v1):
# an INT v1.0 source on bmv2. linear-topo is h1-s1-s3-s2-h2 plus h3 on s3; s1-s3-runtime.json carry
# the ipv4_lpm routes (P4Runtime) and runtime_cmds/s1.sh adds, through the bmv2 CLI, the one INT
# source: s1's ingress port 1, flows 10.0.1.0/24 -> 10.0.2.0/24, any L4 port, hop_metadata_len 8,
# remaining_hop_cnt 4, both instruction masks 0xF. The package is built with
# `convert.py --thrift-commands s1=runtime_cmds/s1.sh`, which translates those two CLI lines into
# P4Runtime entries in s1's runtime file (tools/p4_exercise/thrift_cli.py says how: the ternary
# value masked, the zero-mask L4 keys omitted, CLI priority 0 -> P4Runtime 1).
#
# MEASURED OFFLINE ALREADY (2026-10-16, stock 1.15.3-f0b7d201 and bmv2-fast, offline_int_v1.py, 12/12
# verdicts each): the pipeline push is accepted; all 6 of s1's entries are accepted and the 5
# non-default ones read back; bmv2 holds the translated INT entries exactly as it holds the app's
# CLI-written ones (the CLI masks 10.0.1.1 to 10.0.1.0 itself); frames out are byte-identical between
# the two; the INT frame is int_source.p4's byte for byte; CLI priority 1 beats 2 and the translation
# keeps that. And one thing to NOT do on the fabric: a bmv2 CLI write makes every later P4Runtime read
# of that switch fail (INTERNAL "Table state out-of-sync with target", both builds) -- so int-v1's own
# runtime_cmd.sh must never be run against an NDTwin fabric; the proxy's flow-stats poll is such a read.
#
# WHAT EACH CELL SAYS, AND WHAT IT DOES NOT:
#
#   A1  bring-up. `ndt up p4 --app` exits 0; switch_state: mode ndtwin, three switches, every
#       switch on the app's own program (pipeline.ndtwin False), and per switch
#       table_entries.applied == recorded with failed == 0 -- i.e. s1's six (four routes + the
#       two translated) and s2's, s3's four each went in through the proxy's writer.
#   A2  int-v1's own check, with a verdict. h2 sniffs UDP dport 8002 (receive.py's filter); h1
#       sends ten send.py-shaped frames to h2 and h3 sends ten. Every h1 frame that arrives must
#       carry the INT source's header exactly (paper_int_v1_hostside.py: DSCP 0x17, +12 bytes,
#       shim 1/3, hop_ml 8, rhc 4, masks f/f, ttl 61 = three hops); every h3 frame must carry
#       none (ttl 62, the s3-s2 path, which has no INT source). At most one of each ten may be
#       lost; a wrong header may not. h3's ten are the CONTROL: without them "the header is there"
#       is also what a fabric that INT-stamps everything would show.
#   A3  the app's side effect, predicted from its code and confirmed offline (the ICMP frame f5 of
#       offline_int_v1.py): the source entry's L4 keys are don't-care, so h1 <-> h2 PINGS GET AN
#       INT SHIM STRAIGHT AFTER IPv4 and are not answered. Expected ping matrix: h1->h2 and
#       h2->h1 100% loss, the other four ordered pairs 0%. This is int-v1's behaviour, not a
#       twin defect, and it is asserted both ways: a fabric where h1<->h2 pings succeeded would
#       be one where the INT source is NOT installed.
#   G1  the twin. live-p1/_common.sh's link_usage_round, h1 -> h2 iperf (s1, s3, s2 carry it):
#       primary on-path > 0, off-path under the floor -- the same program-independent cell 05
#       and 06 run. h2 drops the datagrams (s1 grows udp.length_ by 12 and leaves the checksum),
#       which does not matter to it: G1 reads switch tx bytes and the twin, not iperf's server.
#   R   raw only, NOT asserted: the twin's flow view (/ndt/get_detected_flow_data) during G1, to
#       see whether the h1->h2 flow is identified with its 5-tuple through the INT shim (10-01's
#       reading says yes: the shim is after L4, intake-0926/parser-autoderive/REPORT-int-v1.md).
#
#   It does NOT show: transit or sink INT (int-v1 @84a3ebe8 has neither -- no metadata header is
#   ever set valid, egress is empty); that the twin understands INT (it does not parse it); any
#   reroute (no roles are declared, so NDTwin writes no routes into the app's ipv4_lpm).
#
# Run (main checkout, after the merge):
#       NDT_OWNER=<you> bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/09_paper_int_v1.sh
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
# 🔴 NOTHING HERE USES pkill/pgrep. The sniffer exits on its own timeout; the iperf server is
# link_usage_round's, stopped by its pid; the fabric is torn down by `ndt down` in finish().
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

APP_SRC="${INT_V1_SRC:-/home/adam/paper-apps/int-v1}"
APP_COMMIT="84a3ebe84c0d38fb44ac8bd7ef9fba01b82f7548"
STAGE="$REPO/.test_run/paper-src/int-v1"
PKG="$PKG_ROOT/int-v1"
P4C="${P4C:-/usr/local/bin/p4c-bm2-ss}"
CTRL_PY="${CTRL_PY:-/home/adam/p4dev-python-venv/bin/python}"
HOSTSIDE="$HERE/paper_int_v1_hostside.py"

start_step 09_paper_int_v1

# --- 0. the app, at its commit, staged and compiled BEFORE the lab is touched --------------------
say "staging int-v1 @$APP_COMMIT from $APP_SRC"
[[ -d "$APP_SRC/.git" ]] || die "no int-v1 clone at $APP_SRC (set INT_V1_SRC=); this step does not download it"
[[ -x "$P4C" ]]          || die "no p4c-bm2-ss at $P4C"
[[ -x "$CTRL_PY" ]]      || die "no scapy interpreter at $CTRL_PY (set CTRL_PY=)"
git -C "$APP_SRC" cat-file -e "$APP_COMMIT^{commit}" 2>/dev/null \
    || die "$APP_SRC does not have commit $APP_COMMIT"
rm -rf "$STAGE" && mkdir -p "$STAGE"
# `git archive` of the commit, not a copy of the working tree: the package is then about one
# named version of the app whatever the clone's checkout holds.
git -C "$APP_SRC" archive "$APP_COMMIT" | tar -x -C "$STAGE"
note "staged $(find "$STAGE" -type f | wc -l) file(s) -> $STAGE"
mkdir -p "$STAGE/build"
# The app's own recipe (its utils/Makefile:6 and :45), which names the p4info `.p4.p4info.txt`.
( cd "$STAGE" && "$P4C" --p4v 16 --p4runtime-files build/int.p4.p4info.txt -o build/int.json int.p4 ) \
    > "$RUN/09_compile.txt" 2>&1 || { sed 's/^/   /' "$RUN/09_compile.txt"; die "p4c failed -- see $(basename "$RUN")/09_compile.txt"; }
"$P4C" --version >> "$RUN/09_compile.txt" 2>&1 || true
for f in "$STAGE/build/int.json" "$STAGE/build/int.p4.p4info.txt"; do
    [[ -s "$f" ]] || die "p4c reported success and $f is not there"
    note "$(sha256sum "$f" | cut -c1-16)  $f"
done

say "converting -> $PKG  (--p4 int.p4, --thrift-commands s1=runtime_cmds/s1.sh)"
rm -rf "$PKG"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$STAGE" --topology linear-topo/topology.json \
      --p4 int.p4 --thrift-commands s1=runtime_cmds/s1.sh --out "$PKG" \
      > "$RUN/10_convert.txt" 2>&1 || { sed 's/^/   /' "$RUN/10_convert.txt"; die "convert.py failed -- see $(basename "$RUN")/10_convert.txt"; }
sed -n '/CLI commands/,/files/p' "$RUN/10_convert.txt" | sed 's/^/   /'
/usr/bin/grep -q 's1: 2 entries from runtime_cmds/s1.sh' "$RUN/10_convert.txt" \
    || die "convert.py did not report s1's two translated CLI entries -- see 10_convert.txt"
KIND="$(run_app_pipeline_kind "$PKG")"
note "pipeline kind: $KIND"
[[ "$KIND" == foreign:* ]] || die "refusing: $PKG is '$KIND', not the app's own pipeline"

say "pre-flight"
set +e
"$PY" "$REPO/tools/p4_exercise/preflight.py" "$PKG" > "$RUN/11_preflight.txt" 2>&1
PF_RC=$?
set -e
tail -1 "$RUN/11_preflight.txt" | sed 's/^/   /'
(( PF_RC != 0 )) && { sed 's/^/   /' "$RUN/11_preflight.txt"; die "pre-flight FAILED (rc $PF_RC); nothing was started"; }

# 🔴 THE CLAIM IS TAKEN HERE, after compile, convert and pre-flight -- none of them touches the lab.
take_claim "live-p1/09: paper app int-v1 (INT source) on the twin"

# --- A1. bring-up --------------------------------------------------------------------------------
say "ndt up p4 --app $PKG"
set +e
"$NDT" up p4 --app "$PKG" > "$RUN/20_up.txt" 2>&1
UP_RC=$?
set -e
note "rc=$UP_RC -> $(basename "$RUN")/20_up.txt"
tail -8 "$RUN/20_up.txt" | sed 's/^/     /'
(( UP_RC != 0 )) && { fail "A1: 'ndt up p4 --app' exited $UP_RC (see 20_up.txt)"; exit 1; }

SS="$RUN/30_switch_state.json"
get_json "$PROXY_URL/p4/switch_state" "$SS" || fail "A1: no switch_state"
"$NDT" status > "$RUN/31_status.txt" 2>&1 || true
sed -n '/^ *telemetry/,/^ *link shaping/p' "$RUN/31_status.txt" | sed 's/^/   /'
if [[ -s "$SS" ]]; then
    A1="$(jqp "$SS" "
(lambda sw: [
  'mode=%s' % (d.get('control_plane') or {}).get('mode'),
  'switches=%d' % len(sw),
] + ['s%s ndtwin=%s recorded=%s applied=%s failed=%s' % (k, (v.get('pipeline') or {}).get('ndtwin'),
      (v.get('table_entries') or {}).get('recorded'), (v.get('table_entries') or {}).get('applied'),
      (v.get('table_entries') or {}).get('failed')) for k, v in sorted(sw.items())])(
  d.get('switches') if isinstance(d.get('switches'), dict) else {})")"
    note "A1 switch_state: $A1"
    A1_OK="$(jqp "$SS" "
(lambda sw: (d.get('control_plane') or {}).get('mode') == 'ndtwin' and sorted(sw) == ['1', '2', '3']
  and all((v.get('pipeline') or {}).get('ndtwin') is False for v in sw.values())
  and all((v.get('table_entries') or {}).get('failed') == 0 for v in sw.values())
  and all((v.get('table_entries') or {}).get('applied') == (v.get('table_entries') or {}).get('recorded')
          for v in sw.values())
  and (sw.get('1', {}).get('table_entries') or {}).get('recorded') == 6)(
  d.get('switches') if isinstance(d.get('switches'), dict) else {})")"
    [[ "$A1_OK" == True ]] || fail "A1: switch_state is not three switches on the app's program with every entry applied (s1: 6) -- $A1"
fi

# --- A2. int-v1's check, with a verdict ------------------------------------------------------------
say "A2: h2 sniffs; h1 sends 10 (INT expected), h3 sends 10 (control, no INT)"
hpid() { ( set +e; source "$NDT" >/dev/null 2>&1; host_pid "$1" ); }
P1="$(hpid h1)"; P2="$(hpid h2)"; P3="$(hpid h3)"
if [[ ! "$P1" =~ ^[0-9]+$ || ! "$P2" =~ ^[0-9]+$ || ! "$P3" =~ ^[0-9]+$ ]]; then
    fail "A2: NOT RUN -- no namespace for h1/h2/h3 ($P1/$P2/$P3); a namespace answer, not a reading about the app"
else
    CAP="$RUN/40_h2_capture.json"
    sudo -n mnexec -a "$P2" "$CTRL_PY" "$HOSTSIDE" sniff 12 "$CAP" > "$RUN/40_sniff.txt" 2>&1 &
    SNIFF=$!
    sleep 3
    sudo -n mnexec -a "$P1" "$CTRL_PY" "$HOSTSIDE" send 10.0.2.2 08:00:00:00:02:22 10 h1int \
        > "$RUN/41_send_h1.txt" 2>&1 || fail "A2: the sender in h1 failed (41_send_h1.txt)"
    sudo -n mnexec -a "$P3" "$CTRL_PY" "$HOSTSIDE" send 10.0.2.2 08:00:00:00:02:22 10 h3ctl \
        > "$RUN/42_send_h3.txt" 2>&1 || fail "A2: the sender in h3 failed (42_send_h3.txt)"
    # The sniffer stops on its own 12 s timeout; it is waited for, never killed.
    wait "$SNIFF" || fail "A2: the sniffer in h2 exited non-zero (40_sniff.txt)"
    sed 's/^/   /' "$RUN/40_sniff.txt"
    "$CTRL_PY" "$HOSTSIDE" verdict "$CAP" h1int int 10 61 > "$RUN/43_verdict_h1.txt" 2>&1 \
        || fail "A2: h1's frames did not arrive at h2 with int-v1's INT header ($(tail -1 "$RUN/43_verdict_h1.txt"))"
    "$CTRL_PY" "$HOSTSIDE" verdict "$CAP" h3ctl plain 10 62 > "$RUN/44_verdict_h3.txt" 2>&1 \
        || fail "A2 control: h3's frames did not arrive plain ($(tail -1 "$RUN/44_verdict_h3.txt"))"
    tail -1 "$RUN/43_verdict_h1.txt" | sed 's/^/   /'
    tail -1 "$RUN/44_verdict_h3.txt" | sed 's/^/   /'
fi

# --- A3. the ping matrix int-v1's source entry implies --------------------------------------------
say "A3: ping matrix (h1<->h2 expected dead: the INT shim lands after IPv4 on ICMP)"
PRAW="$RUN/50_ping_matrix.txt"
: > "$PRAW"
declare -A HIP=([h1]=10.0.1.1 [h2]=10.0.2.2 [h3]=10.0.3.3)
for pair in h1:h2:100 h2:h1:100 h1:h3:0 h3:h1:0 h2:h3:0 h3:h2:0; do
    IFS=: read -r s d want <<<"$pair"
    set +e
    got="$(ping_loss "$s" "${HIP[$d]}" 5 "$PRAW")"
    prc=$?
    set -e
    note "$s -> $d: $got (want ${want}% loss)"
    if (( prc != 0 )); then
        fail "A3: NOT RUN for $s -> $d: $got"
    elif [[ "${got%% *}" != "$want" ]]; then
        fail "A3: $s -> $d lost ${got%% *}%, want ${want}% -- see 50_ping_matrix.txt"
    fi
done

# --- G1. the twin's link utilisation follows the h1 -> h2 path ----------------------------------
say "G1: link usage follows the iperf path (h1 -> h2)"
G1DIR="$RUN/60_link_usage"
mkdir -p "$G1DIR"
# R: the twin's flow view during the window, raw only. Started before, read after.
( sleep 6; get_json "$KERNEL_URL/ndt/get_detected_flow_data" "$G1DIR/R_detected_flow_data.json" || true ) &
FLOWS=$!
set +e
link_usage_round "$PKG" "int-v1" "$G1DIR" follows h2
G1_RC=$?
set -e
wait "$FLOWS" 2>/dev/null || true
case "$G1_RC" in
    0) note "G1 PASS" ;;
    "$LINK_USAGE_WINDOW_RC") fail "G1: NOT RUN -- the window this path needs is longer than the caller will wait" ;;
    2) fail "G1: NOT RUN -- no namespace for the two hosts; a permission answer, not a reading about link usage" ;;
    *) fail "G1: the twin's link usage did not follow the h1 -> h2 path" ;;
esac
[[ -s "$G1DIR/R_detected_flow_data.json" ]] && note "R: the twin's flow view during G1 -> 60_link_usage/R_detected_flow_data.json (raw, not asserted)"

# finish() (the EXIT trap from start_step) tears down: ndt down, the two knobs, ndt release.
exit 0
