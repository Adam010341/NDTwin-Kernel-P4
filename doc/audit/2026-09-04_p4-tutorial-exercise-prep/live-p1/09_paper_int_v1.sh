#!/usr/bin/env bash
#
# Live ⑨ -- a published paper app on NDTwin: niloysh/int-v1 (MIT), `ndt up p4 --app`.
#
# [Co-developed with claude code -- Adam]
#
# WRITTEN OFFLINE, NEVER RUN BY ITS AUTHOR (no lab, no sudo). Live runs happen in the shared main
# checkout after the branch is merged into trunk. The offline half -- the package's pipeline
# loads on a throwaway simple_switch_grpc, every entry goes in and reads back, and int-v1's INT
# frame comes out byte for byte -- is checked separately; this step is the part only a fabric can
# show.
#
# THE APP. int-v1 @84a3ebe8 (github.com/niloysh/int-v1, MIT, local clone $HOME/paper-apps/int-v1):
# an INT v1.0 source on bmv2. linear-topo is h1-s1-s3-s2-h2 plus h3 on s3; s1-s3-runtime.json carry
# the ipv4_lpm routes (P4Runtime) and runtime_cmds/s1.sh adds, through the bmv2 CLI, the one INT
# source: s1's ingress port 1, flows 10.0.1.0/24 -> 10.0.2.0/24, any L4 port, hop_metadata_len 8,
# remaining_hop_cnt 4, both instruction masks 0xF. The package is built with
# `convert.py --thrift-commands s1=runtime_cmds/s1.sh`, which translates those two CLI lines into
# P4Runtime entries in s1's runtime file (tools/p4_exercise/thrift_cli.py says how: the ternary
# value masked, the zero-mask L4 keys omitted, CLI priority 0 -> P4Runtime 2^31-1, which bmv2
# holds as 0, the CLI's own number).
#
# MEASURED OFFLINE ALREADY (offline_int_v1.py, on both bmv2 builds; the run, its commit and its
# numbers are in the round's hand-back, not here): the pipeline push is accepted; every s1 entry is
# accepted and the all-tables Read returns exactly what was written; bmv2's own table_dump holds
# the translated INT entries as it holds the app's CLI-written ones, Priority included (the CLI
# masks 10.0.1.1 to 10.0.1.0 itself); frames out are byte-identical between the two; the INT frame
# is int_source.p4's byte for byte; the ICMP echo request AND reply h1->h2 get the shim after IPv4.
# And one thing NOT to do on the fabric: any bmv2 P4Runtime Read that covers a table the bmv2 CLI
# wrote into fails (INTERNAL "Table state out-of-sync with target"; doc/KNOWN-ISSUES.md B-18 has
# the measured table), so int-v1's own runtime_cmd.sh must never be run against an NDTwin fabric:
# the proxy's flow-stats poll is an all-tables Read.
#
# WHAT EACH CELL SAYS, AND WHAT IT DOES NOT:
#
#   C0  the program is the one tested offline: the compile's p4info sha256 and int.json sha256
#       must be P4INFO_SHA / JSON_SHA below. (Pre-flight recompiles int.p4 by its absolute path
#       and gets another int.json sha, 277665a3...: the json then carries that path 42 times, and
#       with it removed the bytes are the same -- observed in the 2026-10-16 offline run.)
#   A1  bring-up, the same checks 02_app_basic.sh makes for a foreign pipeline: `ndt up p4 --app`
#       exits 0; switch_state: mode ndtwin, package == this package, switches exactly 1,2,3, each
#       on the app's program (pipeline.ndtwin False, p4info_sha256 the tested one, per-switch
#       skipped == clone_session + sflow_telemetry), heartbeat watchdog running with the fabric
#       skips lldp_discovery + install_initial_routes, and per switch table_entries.applied ==
#       recorded, failed 0, recorded 6/4/4 (s1: three routes, the default action and the two
#       translated entries); the kernel graph has 3 switches and 3 hosts; `ndt up` printed the
#       entries line switch_state implies and "destination paths NOT CHECKED"; `ndt status`
#       says the sample rate is n/a; app_pipeline_kind is exactly foreign:1,2,3.
#   A2  int-v1's own check, with a verdict. h2 sniffs UDP dport 8002 (receive.py's filter); h1
#       sends ten send.py-shaped frames to h2 and h3 sends ten. Every h1 frame that arrives must
#       carry the INT source's header as the code builds it (paper_int_v1_hostside.py: DSCP
#       0x17, +12 bytes, shim 1/3, hop_ml 8, rhc 4, masks f/f, ttl 61 = three hops); every h3
#       frame must carry none (ttl 62, the s3-s2 path, which has no INT source). At most one of
#       each ten may be lost; a wrong header may not. h3's ten are the CONTROL: without them
#       "the header is there" is also what a fabric that INT-stamps everything would show.
#   A3  the app's side effect, measured offline (f5, f6 of offline_int_v1.py): the source
#       entry's L4 keys are don't-care, so ICMP from h1 to h2 -- a request, or the reply to
#       h2's request -- gets an INT shim straight after IPv4, and h2 answers neither. Expected
#       ping matrix: h1->h2 and h2->h1 100% loss, the other four ordered pairs 0%. Asserted both
#       ways: a fabric where h1<->h2 pings succeeded is one where the INT source is NOT installed.
#   G1  the twin. live-p1/_common.sh's link_usage_round, h1 -> h2 iperf (s1, s3, s2 carry it):
#       primary on-path > 0, off-path under the floor -- the same program-independent cell 05
#       and 06 run. h2 drops the datagrams (s1 grows udp.length_ by 12 and leaves the checksum),
#       which does not matter to it: G1 reads switch tx bytes and the twin, not iperf's server.
#   R   raw only, NOT asserted: the twin's flow view (/ndt/get_detected_flow_data) during G1.
#
#   It does NOT show: transit or sink INT (int-v1 @84a3ebe8 has neither); that the twin
#   understands INT (it does not parse it); any reroute (no roles are declared).
#
# Run (main checkout, after the merge):
#       NDT_OWNER=<you> bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/09_paper_int_v1.sh
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
# Test: tests/shell/test_live_p1_09.sh sources this file with LIVE09_LIB_ONLY=1 (functions only,
#       nothing started) and drives A1 and A3 against good and bad inputs.
# 🔴 NOTHING HERE USES pkill/pgrep. The sniffer and senders run under `timeout` and exit on their
# own; the iperf server is link_usage_round's, stopped by its pid; `ndt down` runs in finish().
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
#: What the offline check ran on 2026-10-16.
P4INFO_SHA="7aeaf18009ab6f4f2ef2954671c41d3bd0feafca94e0fe678bd1f45b2d17ca8b"
JSON_SHA="2c4dba92b8581200a93ac848086c2f15919edac07b9e7299b73d308c09a60d02"
FABRIC_SKIPS_HB="['install_initial_routes', 'lldp_discovery']"               # sorted, as 02
SWITCH_SKIPS="[\"('clone_session', 'sflow_telemetry')\"]"                     # per switch, as 02
WANT_KIND="foreign:1,2,3"
WANT_RECORDED="{'1': 6, '2': 4, '3': 4}"
#: Every ordered pair, and the loss int-v1's own source entry implies (A3).
A3_PAIRS="h1:h2:100 h2:h1:100 h1:h3:0 h3:h1:0 h2:h3:0 h3:h2:0"
declare -A HIP=([h1]=10.0.1.1 [h2]=10.0.2.2 [h3]=10.0.3.3)

# a1_verdict <switch_state.json> <package dir> -- "OK ..." or "BAD <first problem>", one line.
a1_verdict() {
    "$PY" - "$1" "$2" "$P4INFO_SHA" "$WANT_RECORDED" <<'A1' 2>/dev/null || echo "BAD the A1 verdict could not run on $1"
import ast, json, sys
path, pkg, sha, want_rec = sys.argv[1], sys.argv[2], sys.argv[3][:16], ast.literal_eval(sys.argv[4])
try:
    d = json.load(open(path))
except (OSError, ValueError) as exc:
    print("BAD switch_state unreadable: %s" % exc); sys.exit(0)
cp = d.get("control_plane") or {}
sw = d.get("switches") if isinstance(d.get("switches"), dict) else {}
problems = []
if cp.get("mode") != "ndtwin":
    problems.append("control_plane.mode is %r, want 'ndtwin'" % cp.get("mode"))
if cp.get("package") != pkg:
    problems.append("control_plane.package is %r, want %s" % (cp.get("package"), pkg))
if sorted(sw) != ["1", "2", "3"]:
    problems.append("switches are %s, want exactly ['1', '2', '3']" % sorted(sw))
for k in sorted(sw):
    v, te = sw[k], (sw[k].get("table_entries") or {})
    pipe = v.get("pipeline") or {}
    if pipe.get("ndtwin") is not False:
        problems.append("s%s pipeline.ndtwin is %r, want False" % (k, pipe.get("ndtwin")))
    if pipe.get("p4info_sha256") != sha:
        problems.append("s%s p4info_sha256 is %r, want %s (the offline-tested p4info)"
                        % (k, pipe.get("p4info_sha256"), sha))
    if te.get("failed") != 0 or te.get("applied") != te.get("recorded"):
        problems.append("s%s table_entries %s: want applied == recorded and failed 0" % (k, te))
    if te.get("recorded") != want_rec.get(k):
        problems.append("s%s table_entries.recorded is %r, want %r" % (k, te.get("recorded"),
                                                                       want_rec.get(k)))
print("BAD " + problems[0] if problems else "OK mode ndtwin, package, s1-s3 on the tested "
      "program, entries %s all applied" % {k: (sw[k].get("table_entries") or {}).get("applied")
                                            for k in sorted(sw)})
A1
}

# a3_matrix <raw file> -- ping every ordered pair (ping_loss, 5 each) and `fail` each pair whose
# loss is not the one A3_PAIRS names. An untested pair is a failure too: it is not a passed one.
a3_matrix() {
    local raw="$1" pair s d want got prc
    : > "$raw"
    for pair in $A3_PAIRS; do
        IFS=: read -r s d want <<<"$pair"
        got="$(ping_loss "$s" "${HIP[$d]}" 5 "$raw")" && prc=0 || prc=$?
        note "$s -> $d: $got (want ${want}% loss)"
        if (( prc != 0 )); then
            fail "A3: NOT RUN for $s -> $d: $got"
        elif [[ "${got%% *}" != "$want" ]]; then
            fail "A3: $s -> $d lost ${got%% *}%, want ${want}% -- see $(basename "$raw")"
        fi
    done
}

# hpid <host> -- the host's namespace pid, or nothing (rc 1). Never aborts the caller under -e.
hpid() { ( set +e; source "$NDT" >/dev/null 2>&1; host_pid "$1" ) || true; }

# c0_check <p4info> <json> -- "OK" when both are the program the offline check ran, else "BAD ...".
c0_check() {
    local info json
    info="$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)"
    json="$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)"
    if [[ "$info" == "$P4INFO_SHA" && "$json" == "$JSON_SHA" ]]; then
        echo "OK p4info $info, json $json (the offline-tested program)"
    else
        echo "BAD the compile is not the program the offline check ran: p4info ${info:-unreadable} (want $P4INFO_SHA), json ${json:-unreadable} (want $JSON_SHA)"
    fi
}

# in_host <pid> <timeout s> <stdout> <stderr> <args...> -- the p4dev Python, isolated (-I), from
# a directory outside the repo, as root in that namespace, under an outer timeout. The two files
# are created by THIS shell, so they are not root's.
in_host() {
    local pid="$1" secs="$2" out="$3" err="$4"
    shift 4
    ( cd / && timeout -k 5 "$secs" sudo -n mnexec -a "$pid" "$CTRL_PY" -I "$HOSTSIDE" "$@" ) \
        > "$out" 2> "$err"
}

if [[ "${LIVE09_LIB_ONLY:-}" == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi

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
# The app's own recipe (its utils/Makefile:6 and :45), by the RELATIVE path, as the offline run
# compiled it -- that is what makes JSON_SHA reproducible.
( cd "$STAGE" && "$P4C" --p4v 16 --p4runtime-files build/int.p4.p4info.txt -o build/int.json int.p4 ) \
    > "$RUN/09_compile.txt" 2>&1 || { sed 's/^/   /' "$RUN/09_compile.txt"; die "p4c failed -- see $(basename "$RUN")/09_compile.txt"; }
"$P4C" --version >> "$RUN/09_compile.txt" 2>&1 || true
V="$(c0_check "$STAGE/build/int.p4.p4info.txt" "$STAGE/build/int.json")"
note "C0: $V"
[[ "$V" == OK* ]] || die "C0: ${V#BAD } -- a different p4c or a different source; nothing was started"

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
[[ "$KIND" == "$WANT_KIND" ]] || die "refusing: $PKG is '$KIND', want $WANT_KIND"

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
get_json "$KERNEL_URL/ndt/get_graph_data" "$RUN/32_get_graph_data.json" || fail "A1: no get_graph_data"
if [[ -s "$SS" ]]; then
    V="$(a1_verdict "$SS" "$PKG")"
    note "A1 switch_state: $V"
    [[ "$V" == OK* ]] || fail "A1: ${V#BAD }"
    V="$(heartbeat_skips_verdict "$SS" "$FABRIC_SKIPS_HB")"
    [[ "$V" == OK* ]] || fail "A1: ${V#BAD }"
    SW_SKIPPED="$(jqp "$SS" "sorted({repr(tuple(sorted((s.get('pipeline') or {}).get('skipped') or []))) for s in (d.get('switches') or {}).values()})")"
    [[ "$SW_SKIPPED" == "$SWITCH_SKIPS" ]] || fail "A1: per-switch pipeline.skipped is $SW_SKIPPED, want $SWITCH_SKIPS"
    EXPECT_ENTRIES="$(jqp "$SS" "(lambda v: 'table entries: %d/%d applied across %d switch(es) (they do not all carry the same count), 0 failed' % (sum(a for a, r in v), sum(r for a, r in v), len(v)))([((s.get('table_entries') or {}).get('applied'), (s.get('table_entries') or {}).get('recorded')) for s in (d.get('switches') or {}).values()])")"
    /usr/bin/grep -qF "$EXPECT_ENTRIES" "$RUN/20_up.txt" \
        || fail "A1: 'ndt up' did not print the entries line switch_state implies: [$EXPECT_ENTRIES]"
fi
/usr/bin/grep -qF 'destination paths NOT CHECKED' "$RUN/20_up.txt" \
    || fail "A1: 'ndt up' did not say the destination-path count was NOT CHECKED (no LLDP on a foreign pipeline)"
/usr/bin/grep -qF 'n/a (package pipeline)' "$RUN/31_status.txt" \
    || fail "A1: 'ndt status' printed a sampling rate for a fabric running the package's own pipeline"
G="$RUN/32_get_graph_data.json"
if [[ -s "$G" ]]; then
    G_SW="$(jqp "$G" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==0])")"
    G_H="$(jqp "$G" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==1])")"
    note "kernel graph: $G_SW switches, $G_H hosts"
    [[ "$G_SW" == 3 && "$G_H" == 3 ]] || fail "A1: the kernel graph has $G_SW switches and $G_H hosts, the package's model declares 3 and 3"
fi

# --- A2. int-v1's check, with a verdict ------------------------------------------------------------
say "A2: h2 sniffs; h1 sends 10 (INT expected), h3 sends 10 (control, no INT)"
P1="$(hpid h1)"; P2="$(hpid h2)"; P3="$(hpid h3)"
if [[ ! "$P1" =~ ^[0-9]+$ || ! "$P2" =~ ^[0-9]+$ || ! "$P3" =~ ^[0-9]+$ ]]; then
    fail "A2: NOT RUN -- no namespace for h1/h2/h3 (${P1:-none}/${P2:-none}/${P3:-none}); a namespace answer, not a reading about the app"
else
    CAP="$RUN/40_h2_capture.json"
    in_host "$P2" 40 "$CAP" "$RUN/40_sniff.err" sniff 15 &
    SNIFF=$!
    # Readiness, not a sleep: the sniffer prints READY on stderr once scapy is capturing.
    for _ in $(seq 1 40); do
        /usr/bin/grep -q '^READY' "$RUN/40_sniff.err" 2>/dev/null && break
        kill -0 "$SNIFF" 2>/dev/null || break
        sleep 0.5
    done
    if ! /usr/bin/grep -q '^READY' "$RUN/40_sniff.err" 2>/dev/null; then
        fail "A2: NOT RUN -- the sniffer in h2 never said READY (40_sniff.err)"
    else
        in_host "$P1" 30 "$RUN/41_send_h1.txt" "$RUN/41_send_h1.err" send 10.0.2.2 08:00:00:00:02:22 10 h1int \
            || fail "A2: the sender in h1 failed or timed out (41_send_h1.*)"
        in_host "$P3" 30 "$RUN/42_send_h3.txt" "$RUN/42_send_h3.err" send 10.0.2.2 08:00:00:00:02:22 10 h3ctl \
            || fail "A2: the sender in h3 failed or timed out (42_send_h3.*)"
    fi
    # The sniffer stops on its own 15 s; the outer timeout is 40 s. Waited for, never killed.
    wait "$SNIFF" || fail "A2: the sniffer in h2 exited non-zero or timed out (40_sniff.err)"
    sed 's/^/   /' "$RUN/40_sniff.err"
    "$CTRL_PY" -I "$HOSTSIDE" verdict "$CAP" h1int int 10 61 > "$RUN/43_verdict_h1.txt" 2>&1 \
        || fail "A2: h1's frames did not arrive at h2 with int-v1's INT header ($(tail -1 "$RUN/43_verdict_h1.txt"))"
    "$CTRL_PY" -I "$HOSTSIDE" verdict "$CAP" h3ctl plain 10 62 > "$RUN/44_verdict_h3.txt" 2>&1 \
        || fail "A2 control: h3's frames did not arrive plain ($(tail -1 "$RUN/44_verdict_h3.txt"))"
    tail -1 "$RUN/43_verdict_h1.txt" | sed 's/^/   /'
    tail -1 "$RUN/44_verdict_h3.txt" | sed 's/^/   /'
fi

# --- A3. the ping matrix int-v1's source entry implies --------------------------------------------
say "A3: ping matrix (h1<->h2 expected dead: the INT shim lands after IPv4 on ICMP)"
a3_matrix "$RUN/50_ping_matrix.txt"

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
