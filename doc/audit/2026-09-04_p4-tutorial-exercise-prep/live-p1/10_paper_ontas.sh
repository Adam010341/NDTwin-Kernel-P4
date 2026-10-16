#!/usr/bin/env bash
#
# Live ⑩ -- a published paper app on NDTwin: Princeton-Cabernet ONTAS (bmv2, Apache-2.0), `ndt up p4 --app`.
#
# [Co-developed with claude code -- Adam]
#
# WRITTEN OFFLINE, NEVER RUN BY ITS AUTHOR (no lab, no sudo). Live runs happen in the shared main
# checkout after the branch is merged (Adam's 10-08 ruling). The offline half -- the package's
# pipeline loads on a throwaway simple_switch_grpc, every entry goes in and reads back, and every
# crafted frame and a replayed slice of smallFlows.pcap come out exactly as a hand model of
# p4anony.p4 says -- is doc/audit/2026-10-16_p4-paper-apps/offline_ontas.py.
#
# THE APP. github.com/Princeton-Cabernet/p4-projects @e5c7cca1, ONTAS/bmv2_p4_16 (Apache-2.0; the
# local blob-less sparse clone /home/adam/paper-apps/p4-projects, downloaded with Adam's permission).
# 🔴 DOWNLOADED, UNTRUSTED: nothing of it is executed -- not its Makefile, not a script. This step
# COPIES the checked-out files (no git command that could fetch a missing blob from the remote),
# checks every copy's blob id against `git ls-tree` of that commit, compiles p4anony.p4 with this
# machine's p4c, reads s1-runtime.json and topology.json as data and the pcap as data.
#
# ONTAS anonymises on line rate at s1: the id half of each MAC becomes crc32(id) mod 24, and an IPv4
# address in 72.14.213.0/24 keeps its /24 and gets crc16(last octet) mod 8 -- which for these inputs
# is the octet's parity, so the anonymised last octet is 0 or 1 (ontas_model.py says how, and why
# "mod 24" and "mod 8": the program passes those literals as hash maxima).
# It forwards port 1 -> port 2 only. Its topology.json is the 2018-19 tutorials format (hosts a
# list, links without ports); convert.py derives h1 10.0.1.1 / port 1 and h2 10.0.1.2 / port 2 by
# that harness's rules and says so.
#
# WHAT EACH CELL SAYS, AND WHAT IT DOES NOT:
#
#   C0  the program is the one tested offline (P4INFO_SHA / JSON_SHA below).
#   A1  bring-up, the checks 02_app_basic.sh makes for a foreign pipeline: `ndt up p4 --app`
#       exits 0; switch_state mode ndtwin, this package, exactly switch 1, on the app's program
#       (pipeline.ndtwin False, the tested p4info sha, per-switch skipped clone_session +
#       sflow_telemetry), heartbeat watchdog running with fabric skips lldp_discovery +
#       install_initial_routes, 16 entries recorded == applied, 0 failed; the kernel graph has
#       1 switch and 2 hosts; `ndt up` printed the entries line and "destination paths NOT
#       CHECKED"; `ndt status` says the sample rate is n/a; app_pipeline_kind is foreign:1.
#   A2  the app's own check, with a verdict. h2 sniffs; h1 sends the seven crafted frames (the
#       live twins of offline g1-g7) and then REPLAY_N frames of smallFlows.pcap; every one must
#       arrive at h2 exactly as ontas_model.py computes it (paper_ontas_hostside.py verdict).
#   A3  the other direction, the CONTROL: h1 sniffs while h2 sends the same frames -- forward_tb
#       has no port-2 entry, so none may arrive, neither as sent nor rewritten. And the ping
#       matrix this implies: h1->h2 and h2->h1 100% loss (h2's replies never come back).
#   G1  the twin: link_usage_round h1 -> h2 (primary on-path > 0, off-path under the floor),
#       after the step sets a static ARP entry for h2 in h1 ITSELF. Without one h1 cannot send to
#       h2 at all: its ARP request reaches h2 with ONTAS's rewritten MACs and h2's answer, in on
#       port 2, is dropped (forward_tb has no port-2 entry). This is the step's own setup, not
#       the app's: the 2018-19 harness set a static ARP entry only for a phony gateway, not for h2.
#
#   It does NOT show: that the twin understands the anonymisation (it does not parse it); any
#   reverse path (the app has none); the Tofino version of ONTAS (not this code).
#
# Run (main checkout, after the merge):
#       NDT_OWNER=<you> bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/10_paper_ontas.sh
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
# Test: tests/shell/test_live_p1_10.sh sources this file with LIVE10_LIB_ONLY=1 and drives A1/A3.
# 🔴 NOTHING HERE USES pkill/pgrep. Host-side scripts run under `timeout` and exit on their own.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

APP_SRC="${ONTAS_SRC:-/home/adam/paper-apps/p4-projects}"
APP_COMMIT="e5c7cca1e4c537f52196c9e7201b41cf0812d798"
APP_PATH="ONTAS/bmv2_p4_16"
STAGE="$REPO/.test_run/paper-src/ontas"
PKG="$PKG_ROOT/ontas"
P4C="${P4C:-/usr/local/bin/p4c-bm2-ss}"
CTRL_PY="${CTRL_PY:-/home/adam/p4dev-python-venv/bin/python}"
HOSTSIDE="$HERE/paper_ontas_hostside.py"
MODEL_DIR="$REPO/doc/audit/2026-10-16_p4-paper-apps"
REPLAY_N=60
#: Files of $APP_PATH at $APP_COMMIT, utils/ excluded (b_02_stage_provenance.log: 11).
WANT_FILES=11
#: What the offline check ran (2026-10-16, gates-0910/p4-paper-apps/b_01_p4c_ontas.log).
P4INFO_SHA="517074c9175dc3c9ac13595e827de9a81b985daf7655f995dc10373f58f28ec4"
JSON_SHA="bb74da905adb7683e6949b723c7fdb30204a0e2403aea2f81b3027e369fb63f0"
FABRIC_SKIPS_HB="['install_initial_routes', 'lldp_discovery']"
SWITCH_SKIPS="[\"('clone_session', 'sflow_telemetry')\"]"
WANT_KIND="foreign:1"
WANT_RECORDED="{'1': 16}"
A3_PAIRS="h1:h2:100 h2:h1:100"
declare -A HIP=([h1]=10.0.1.1 [h2]=10.0.1.2)

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
if sorted(sw) != sorted(want_rec):
    problems.append("switches are %s, want exactly %s" % (sorted(sw), sorted(want_rec)))
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
print("BAD " + problems[0] if problems else "OK mode ndtwin, package, s1 on the tested program, "
      "%s entries applied" % (sw.get("1", {}).get("table_entries") or {}).get("applied"))
A1
}

# a3_matrix <raw file> -- both directions must be dead (the app forwards port 1 -> 2 only).
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

# verify_stage <clone> <commit> <path> <stage> <want> -- every staged file against the commit's
# tree: "OK <n> files" or "BAD <why>". 🔴 GIT_NO_LAZY_FETCH=1 on every git command against the
# clone: it is blob-less, and a git command that needs a blob it lacks would otherwise fetch it
# from the remote (round 2 did exactly that once, through `git archive`). `cat-file -e` and
# `ls-tree` need only commit and tree objects; `hash-object` hashes the local copy. A clone that
# is not a git checkout, lacks the commit, or lists fewer files than expected is a refusal: a
# loop over an empty listing would otherwise report "every file matches" about no file.
verify_stage() {
    local src="$1" commit="$2" path="$3" stage="$4" want="$5"
    local n=0 badn=0 listing mode type id p f got
    if ! GIT_NO_LAZY_FETCH=1 git -C "$src" cat-file -e "$commit^{commit}" 2>/dev/null; then
        echo "BAD $src is not a git checkout that has commit $commit"; return 0
    fi
    listing="$(GIT_NO_LAZY_FETCH=1 git -C "$src" ls-tree -r "$commit" "$path" 2>/dev/null)" \
        || { echo "BAD git ls-tree failed on $src"; return 0; }
    while read -r mode type id p; do
        [[ -z "$p" || "$p" == "$path/utils/"* ]] && continue
        n=$((n+1))
        f="$stage/${p#"$path"/}"
        got="$(git hash-object "$f" 2>/dev/null || echo missing)"
        [[ "$got" == "$id" ]] || badn=$((badn+1))
    done <<<"$listing"
    if (( n == 0 )); then echo "BAD 0 comparisons: $commit lists nothing under $path"
    elif (( n < want )); then echo "BAD only $n comparison(s), want $want"
    elif (( badn > 0 )); then echo "BAD $badn of $n staged file(s) differ from the commit's blobs"
    else echo "OK $n files, each the commit's blob"; fi
}

in_host() {   # in_host <pid> <timeout s> <stdout> <stderr> <args...>
    local pid="$1" secs="$2" out="$3" err="$4"
    shift 4
    ( cd / && timeout -k 5 "$secs" sudo -n mnexec -a "$pid" "$CTRL_PY" -I "$HOSTSIDE" "$@" ) \
        > "$out" 2> "$err"
}

# sniff_and_send <sniffer pid> <sender pid> <tag> -- capture in one host while the other sends
# the frame file; sets CAP to the capture. A sniffer that never says READY is a NOT RUN.
sniff_and_send() {
    local spid="$1" tpid="$2" tag="$3" sniff
    CAP="$RUN/${tag}_capture.json"
    in_host "$spid" 60 "$CAP" "$RUN/${tag}_sniff.err" sniff 25 &
    sniff=$!
    for _ in $(seq 1 40); do
        /usr/bin/grep -q '^READY' "$RUN/${tag}_sniff.err" 2>/dev/null && break
        kill -0 "$sniff" 2>/dev/null || break
        sleep 0.5
    done
    if ! /usr/bin/grep -q '^READY' "$RUN/${tag}_sniff.err" 2>/dev/null; then
        wait "$sniff" 2>/dev/null || true
        return 3
    fi
    in_host "$tpid" 40 "$RUN/${tag}_send.txt" "$RUN/${tag}_send.err" send "$FRAMES" || {
        wait "$sniff" 2>/dev/null || true; return 4; }
    wait "$sniff" || return 5
    return 0
}

if [[ "${LIVE10_LIB_ONLY:-}" == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi

start_step 10_paper_ontas

# --- 0. the app, copied and checked, compiled BEFORE the lab is touched -------------------------
say "staging ONTAS @$APP_COMMIT from $APP_SRC/$APP_PATH (copies of the checked-out files)"
[[ -d "$APP_SRC/$APP_PATH/src" ]] || die "no ONTAS checkout at $APP_SRC/$APP_PATH (set ONTAS_SRC=); this step does not download it"
[[ -x "$P4C" ]]     || die "no p4c-bm2-ss at $P4C"
[[ -x "$CTRL_PY" ]] || die "no scapy interpreter at $CTRL_PY (set CTRL_PY=)"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -r "$APP_SRC/$APP_PATH/src" "$APP_SRC/$APP_PATH/LICENSE" "$APP_SRC/$APP_PATH/README.md" \
      "$APP_SRC/$APP_PATH/smallFlows.pcap" "$STAGE/"
V="$(verify_stage "$APP_SRC" "$APP_COMMIT" "$APP_PATH" "$STAGE" "$WANT_FILES")"
note "staging: $V"
[[ "$V" == OK* ]] || die "the staged copy is not ONTAS @$APP_COMMIT (${V#BAD }); nothing was started"
mkdir -p "$STAGE/src/build"
( cd "$STAGE/src" && "$P4C" --p4v 16 --p4runtime-files build/p4anony.p4.p4info.txt -o build/p4anony.json p4anony.p4 ) \
    > "$RUN/09_compile.txt" 2>&1 || { sed 's/^/   /' "$RUN/09_compile.txt"; die "p4c failed -- see $(basename "$RUN")/09_compile.txt"; }
"$P4C" --version >> "$RUN/09_compile.txt" 2>&1 || true
V="$(c0_check "$STAGE/src/build/p4anony.p4.p4info.txt" "$STAGE/src/build/p4anony.json")"
note "C0: $V"
[[ "$V" == OK* ]] || die "C0: ${V#BAD }; nothing was started"

say "converting -> $PKG"
rm -rf "$PKG"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$STAGE/src" --topology topology.json --p4 p4anony.p4 \
      --name ontas --out "$PKG" > "$RUN/10_convert.txt" 2>&1 \
    || { sed 's/^/   /' "$RUN/10_convert.txt"; die "convert.py failed -- see $(basename "$RUN")/10_convert.txt"; }
sed -n '/topology      :/,/pipelines/p' "$RUN/10_convert.txt" | sed 's/^/   /'
/usr/bin/grep -q 'h2 10.0.1.2/24 00:00:00:00:01:02' "$RUN/10_convert.txt" \
    || die "convert.py did not derive h2 10.0.1.2 from the 2018-19 topology -- see 10_convert.txt"
KIND="$(run_app_pipeline_kind "$PKG")"
[[ "$KIND" == "$WANT_KIND" ]] || die "refusing: $PKG is '$KIND', want $WANT_KIND"

say "pre-flight"
set +e
"$PY" "$REPO/tools/p4_exercise/preflight.py" "$PKG" > "$RUN/11_preflight.txt" 2>&1
PF_RC=$?
set -e
tail -1 "$RUN/11_preflight.txt" | sed 's/^/   /'
(( PF_RC != 0 )) && { sed 's/^/   /' "$RUN/11_preflight.txt"; die "pre-flight FAILED (rc $PF_RC); nothing was started"; }

FRAMES="$RUN/12_frames.hex"
( cd / && "$CTRL_PY" -I "$HOSTSIDE" frames "$MODEL_DIR" "$STAGE/smallFlows.pcap" "$REPLAY_N" "$FRAMES" ) \
    > "$RUN/12_frames.txt" 2>&1 || die "could not build the frames (12_frames.txt)"
sed 's/^/   /' "$RUN/12_frames.txt"

take_claim "live-p1/10: paper app ONTAS (anonymisation) on the twin"

# --- A1. bring-up ----------------------------------------------------------------------------------
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
    V="$(a1_verdict "$SS" "$PKG")"; note "A1 switch_state: $V"
    [[ "$V" == OK* ]] || fail "A1: ${V#BAD }"
    V="$(heartbeat_skips_verdict "$SS" "$FABRIC_SKIPS_HB")"
    [[ "$V" == OK* ]] || fail "A1: ${V#BAD }"
    SW_SKIPPED="$(jqp "$SS" "sorted({repr(tuple(sorted((s.get('pipeline') or {}).get('skipped') or []))) for s in (d.get('switches') or {}).values()})")"
    [[ "$SW_SKIPPED" == "$SWITCH_SKIPS" ]] || fail "A1: per-switch pipeline.skipped is $SW_SKIPPED, want $SWITCH_SKIPS"
    EXPECT_ENTRIES="$(jqp "$SS" "(lambda v: 'table entries: %d/%d applied on %d switch(es), 0 failed' % (v[0][0], v[0][1], len(v)))([((s.get('table_entries') or {}).get('applied'), (s.get('table_entries') or {}).get('recorded')) for s in (d.get('switches') or {}).values()])")"
    /usr/bin/grep -qF "$EXPECT_ENTRIES" "$RUN/20_up.txt" \
        || fail "A1: 'ndt up' did not print the entries line switch_state implies: [$EXPECT_ENTRIES]"
fi
/usr/bin/grep -qF 'destination paths NOT CHECKED' "$RUN/20_up.txt" \
    || fail "A1: 'ndt up' did not say the destination-path count was NOT CHECKED"
/usr/bin/grep -qF 'n/a (package pipeline)' "$RUN/31_status.txt" \
    || fail "A1: 'ndt status' printed a sampling rate for a fabric running the package's own pipeline"
G="$RUN/32_get_graph_data.json"
if [[ -s "$G" ]]; then
    G_SW="$(jqp "$G" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==0])")"
    G_H="$(jqp "$G" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==1])")"
    [[ "$G_SW" == 1 && "$G_H" == 2 ]] || fail "A1: the kernel graph has $G_SW switches and $G_H hosts, want 1 and 2"
fi

# --- A2 / A3. the anonymiser, both directions -----------------------------------------------------
P1="$(hpid h1)"; P2="$(hpid h2)"
if [[ ! "$P1" =~ ^[0-9]+$ || ! "$P2" =~ ^[0-9]+$ ]]; then
    fail "A2: NOT RUN -- no namespace for h1/h2 (${P1:-none}/${P2:-none})"
else
    say "A2: h1 sends 7 crafted + $REPLAY_N replayed frames; h2 must see each as the model computes"
    if sniff_and_send "$P2" "$P1" 40_a2; then
        ( cd / && "$CTRL_PY" -I "$HOSTSIDE" verdict "$MODEL_DIR" "$CAP" "$FRAMES" ) > "$RUN/43_verdict.txt" 2>&1 \
            || fail "A2: $(tail -1 "$RUN/43_verdict.txt")"
        tail -1 "$RUN/43_verdict.txt" | sed 's/^/   /'
    else
        fail "A2: NOT RUN -- the sniffer or the sender in the hosts did not run (rc $?; 40_a2_*)"
    fi
    say "A3: h2 sends the same frames; h1 must see none of them (forward_tb: port 1 only)"
    if sniff_and_send "$P1" "$P2" 45_a3; then
        ( cd / && "$CTRL_PY" -I "$HOSTSIDE" none-arrived "$MODEL_DIR" "$CAP" "$FRAMES" ) > "$RUN/47_verdict.txt" 2>&1 \
            || fail "A3: $(tail -1 "$RUN/47_verdict.txt")"
        tail -1 "$RUN/47_verdict.txt" | sed 's/^/   /'
    else
        fail "A3: NOT RUN -- the sniffer or the sender in the hosts did not run (rc $?; 45_a3_*)"
    fi
fi
say "A3: ping matrix (both directions expected dead)"
a3_matrix "$RUN/50_ping_matrix.txt"

# --- G1. the twin's link utilisation follows h1 -> h2 -------------------------------------------
say "G1: link usage follows the iperf path (h1 -> h2)"
if [[ "$P1" =~ ^[0-9]+$ ]]; then
    sudo -n mnexec -a "$P1" arp -s 10.0.1.2 00:00:00:00:01:02 > "$RUN/59_static_arp.txt" 2>&1 \
        || fail "G1: could not set h1's static ARP entry for h2 (59_static_arp.txt)"
fi
G1DIR="$RUN/60_link_usage"
mkdir -p "$G1DIR"
set +e
link_usage_round "$PKG" "ontas" "$G1DIR" follows h2
G1_RC=$?
set -e
case "$G1_RC" in
    0) note "G1 PASS" ;;
    "$LINK_USAGE_WINDOW_RC") fail "G1: NOT RUN -- the window this path needs is longer than the caller will wait" ;;
    2) fail "G1: NOT RUN -- no namespace for the two hosts" ;;
    *) fail "G1: the twin's link usage did not follow the h1 -> h2 path" ;;
esac

exit 0
