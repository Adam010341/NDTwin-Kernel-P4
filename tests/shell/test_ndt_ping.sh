#!/usr/bin/env bash
#
# `ndt ping`: background pings between Mininet hosts, and an honest report of their loss.
#
# [Co-developed with claude code -- Adam]
#
# The command's one hard rule is that a loss figure comes only from ping's own summary line. sudo
# refusing the helper and ping getting no reply BOTH exit 1, so a report that read the exit code
# would turn a missing grant into "100% packet loss" -- a specific claim about the network, made
# from a permission error. Section P4 is that table, one fake answer per row; (c) and (d) are the
# pair that tells the two exit-1 cases apart.
#
#   P1 arguments and bounds          P2 names resolved only from the recorded model
#   P3 the guards, and that a refusal starts and writes nothing
#   P4 the report table              P5 the exact sudo call, and no mnexec
#   P6 start returns at once; wait waits, and gives up      P7 where the files go
#
# Runs the real ndt, copied into a scratch tree of its own (ndt writes under the tree it sits in, so
# the checkout's .test_run is never touched). A fake `sudo` first on PATH answers `ndtwin-lab status`
# and `ndtwin-lab host-ping` the way the real ones do, records every call, and exits on INT/TERM.
# The start cells source ndt (NDT_LIB_ONLY=1) and replace only in_flight, which reads the machine's
# process table: a measurement another session is running must not decide a test. The dispatch is
# exercised through the executable. No lab, no root, no real ping.
#
# Run:  bash tests/shell/test_ndt_ping.sh
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points it at a mutated copy)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT_SRC="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
SRCDIR="$(dirname "$NDT_SRC")"
for f in "$NDT_SRC" "$SRCDIR/ports.sh" "$SRCDIR/sudo_surface.sh" "$SRCDIR/components.env"; do
    [[ -r "$f" ]] || { echo "missing $f"; exit 2; }
done
command -v setsid >/dev/null || { echo "setsid is required"; exit 2; }

PASS=0; FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: %s\n             actual:   %s\n' "$1" "$2" "$3"; fi
}
has()   { if grep -qF -- "$1" <<<"$2"; then echo yes; else echo no; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ndt-ping-XXXXXX")"
cleanup() {
    local p
    # Only the fakes this suite started and recorded, and only while /proc says they are still sleep.
    for p in $(cat "$T"/fake/*.hangpid 2>/dev/null); do
        [[ "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" == "sleep "* ]] && kill -TERM "$p" 2>/dev/null
    done
    rm -rf "$T"
}
trap cleanup EXIT

TREE="$T/repo"; NDT="$TREE/tools/test_workflow/ndt"
mkdir -p "$TREE/tools/test_workflow" "$TREE/setting" "$TREE/.test_run"
cp "$NDT_SRC" "$SRCDIR/ports.sh" "$SRCDIR/sudo_surface.sh" "$SRCDIR/components.env" "$TREE/tools/test_workflow/"
chmod +x "$NDT"

# The tutorials' basic pod topology, as a kernel model: four hosts, one switch to keep it a graph.
cat > "$TREE/setting/model.json" <<'JSON'
{"nodes": [
 {"vertex_type": 1, "device_name": "h1", "ip": ["10.0.1.1"]},
 {"vertex_type": 1, "device_name": "h2", "ip": ["10.0.2.2"]},
 {"vertex_type": 1, "device_name": "h3", "ip": ["10.0.3.3"]},
 {"vertex_type": 1, "device_name": "h4", "ip": ["10.0.4.4/24"]},
 {"vertex_type": 0, "device_name": "s1", "ip": ["192.168.0.1"]}],
 "edges": []}
JSON
record() { printf 'plane=p4\nhosts=4\ntopology=setting/model.json\nat=%s\nby=t\n' "${1:-1700000000}" > "$TREE/.test_run/up.target"; }
norecord() { rm -f "$TREE/.test_run/up.target"; }

# --- the fake sudo --------------------------------------------------------------------------------
FAKE="$T/fake"; mkdir -p "$FAKE/bin"
SUDO_LOG="$FAKE/sudo.log"
cat > "$FAKE/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
trap 'exit 143' TERM; trap 'exit 130' INT
printf '%s\n' "$*" >> "$FAKE_DIR/sudo.log"
[[ "${1:-}" == -n ]] && shift
[[ "${1:-}" == /usr/local/sbin/ndtwin-lab ]] || { echo "sudo: a password is required" >&2; exit 1; }
case "${2:-}" in
  status)
    case "${FAKE_TOPO:-up}" in
      up)      printf 'config: built-in defaults\ntopo: 1 windows (created now)\nbmv2: 4  mininet: 4\n' ;;
      down)    printf 'config: built-in defaults\nno lab sessions\nbmv2: 0  mininet: 0\n' ;;
      refused) echo "sudo: a password is required" >&2; exit 1 ;;
    esac ;;
  host-ping)
    src="$3" ip="$4" count="$5"
    mode="clean"; [[ -f "$FAKE_DIR/mode.$src-$ip" ]] && mode="$(cat "$FAKE_DIR/mode.$src-$ip")"
    case "$mode" in
      clean)   sleep "${FAKE_SECS:-0}"
               printf '\n--- %s ping statistics ---\n%s packets transmitted, %s received, 0%% packet loss, time 5ms\n' "$ip" "$count" "$count"; exit 0 ;;
      loss)    printf '\n--- %s ping statistics ---\n3000 packets transmitted, 2431 received, 18.97%% packet loss, time 60000ms\n' "$ip"; exit 1 ;;
      total)   printf '\n--- %s ping statistics ---\n%s packets transmitted, 0 received, 100%% packet loss, time 60000ms\n' "$ip" "$count"; exit 1 ;;
      refused) echo "sudo: a password is required" >&2; exit 1 ;;
      oldhelper) echo "ndtwin-lab: usage: ndtwin-lab {topo-start|ovs-topo-start|ovs-topo-4host|topo-cmd <text>|topo-out [n]|topo-stop|cleanup|energy-start|energy-stop|energy-out [n]|sim-start|sim-stop|sim-out [n]|heartbeat {start|stop|status}|status|config}" >&2; exit 1 ;;
      nohost)  echo "ndtwin-lab host-ping: no Mininet host $src: no process's last argument is its tag (is a topology running, and does it have $src?)" >&2; exit 65 ;;
      early)   printf '\n--- %s ping statistics ---\n2400 packets transmitted, 2400 received, 0%% packet loss, time 48000ms\n' "$ip"; exit 0 ;;
      zero)    echo "ping: connect: Network is unreachable" >&2
               printf '\n--- %s ping statistics ---\n0 packets transmitted, 0 received\n' "$ip"; exit 2 ;;
      nopct)   printf '\n--- %s ping statistics ---\n%s packets transmitted, %s received, time 5ms\n' "$ip" "$count" "$count"; exit 0 ;;
      unreach) echo "ping: connect: Network is unreachable" >&2; exit 2 ;;
      decoyunreach) echo "ndtwin-lab host-ping: refusing pid 5151 for Mininet host $src: its uids (real, effective, saved, fs) are '1000 1000 1000 1000', not all 0" >&2
               echo "ping: connect: Network is unreachable" >&2; exit 2 ;;
      twolines) echo "ndtwin-lab host-ping: refusing pid 5151 for Mininet host $src: its uids (real, effective, saved, fs) are '1000 1000 1000 1000', not all 0" >&2
               echo "ndtwin-lab host-ping: no process carrying Mininet host $src's tag passed the identity check (rejected pids 5151 5252)" >&2; exit 66 ;;
      killed)  kill -TERM $$; sleep 1 ;;
      hang)    echo $$ >> "$FAKE_DIR/$src.hangpid"; exec sleep "${FAKE_HANG:-30}" ;;
    esac ;;
  *) echo "ndtwin-lab: usage: ..." >&2; exit 1 ;;
esac
SUDO
chmod +x "$FAKE/bin/sudo"
export FAKE_DIR="$FAKE" PATH="$FAKE/bin:$PATH"
mode() { echo "$2" > "$FAKE/mode.$1"; }
nomodes() { rm -f "$FAKE"/mode.*; }
calls() { grep -c 'host-ping' "$SUDO_LOG" 2>/dev/null || true; }

# lib <fn...> -- run in the scratch tree with ndt sourced; in_flight answers FAKE_IN_FLIGHT.
lib() {
    ( cd "$TREE" || exit 99
      # shellcheck source=/dev/null
      NDT_LIB_ONLY=1 source "$NDT" >/dev/null 2>&1
      in_flight() { [[ -n "${FAKE_IN_FLIGHT:-}" ]] && printf '%s\n' "$FAKE_IN_FLIGHT"; return 0; }
      NO_COLOR=1 "$@" )
}
fresh() { : > "$SUDO_LOG"; rm -rf "$TREE/.test_run/ping" "$TREE/.test_run/lab.claim" "$TREE/.test_run/lab.claim.overrides" "$TREE/.test_run/down.inflight"; nomodes; unset FAKE_TOPO FAKE_IN_FLIGHT FAKE_SECS; }
lastdir() { local s; s="$(cat "$TREE/.test_run/ping/last" 2>/dev/null)" && echo "$TREE/.test_run/ping/$s"; }
# start_wait <args> -- start, then wait for every .rc (the fakes answer at once), up to 10 s.
settle() { local d i; d="$(lastdir)"; for i in $(seq 1 100); do
    [[ -n "$d" ]] && (( $(ls "$d"/*.plan 2>/dev/null | wc -l) == $(ls "$d"/*.rc 2>/dev/null | wc -l) )) && return 0; sleep 0.1; done; }

echo "P1 arguments and bounds"
fresh; record
for bad in "h1" "h1:" ":h3" "h1:h3:h4" "h1:h3," ",h1:h3" "h1:h3,,h4:h1" "h1;id:h3" "h1:10.0.3.256" \
           "h1:h3 --for 601s" "h1:h3 --for 0" "h1:h3 --for 1h" "h1:h3 --interval 0.001" "h1:h3 --interval 11" \
           "h1:h3 --interval" "h1:h3 --bogus" "--wait"; do
    # shellcheck disable=SC2086
    out="$(lib cmd_ping $bad 2>&1)"; rc=$?
    check "'ndt ping $bad' -> 2, nothing started or written" "2 0 no" "$rc $(calls) $([[ -e $TREE/.test_run/ping ]] && echo yes || echo no)"
done
pairs33="$(for i in $(seq 1 33); do printf 'h1:h3,'; done)"; pairs33="${pairs33%,}"
lib cmd_ping "$pairs33" >/dev/null 2>&1; rc=$?
check "33 streams -> 2" "2" "$rc"
got="$(cd "$TREE" && NDT_LIB_ONLY=1 bash -c 'source "$1" >/dev/null 2>&1; ping_parse_args h1:h3,h3:h1 h4:10.0.1.1 --for 2m --interval=0.02; echo "${#PING_SRC[@]} ${PING_SRC[*]} ${PING_DST[*]} $PING_FOR_S $PING_COUNT"' _ "$NDT" 2>&1)"
check "pairs by comma and as words; --for 2m; --interval=0.02 -> 6000 pings" "3 h1 h3 h4 h3 h1 10.0.1.1 120 6000" "$got"
got="$(cd "$TREE" && NDT_LIB_ONLY=1 bash -c 'source "$1" >/dev/null 2>&1; ping_parse_args h1:h3; echo "$PING_FOR_S $PING_INTERVAL $PING_COUNT"' _ "$NDT" 2>&1)"
check "defaults: 60 s at 0.2 s -> 300 pings" "60 0.2 300" "$got"
got="$(cd "$TREE" && NDT_LIB_ONLY=1 bash -c 'source "$1" >/dev/null 2>&1; ping_parse_args h1:h3 --for 600 --interval 0.01; echo "$PING_COUNT"' _ "$NDT" 2>&1)"
check "the largest run: 600 s at 0.01 s -> 60000, the helper's own limit" "60000" "$got"
# The count is rounded to the nearest ping, which can pass the helper's 600 s by half an interval:
# it is clamped to the whole pings that fit.
for row in "600 7 85" "10m 0.9 666" "600 0.013 46153" "600 0.01 60000" "599 7 85" "60 0.02 3000"; do
    read -r f i want <<<"$row"
    got="$(cd "$TREE" && NDT_LIB_ONLY=1 bash -c 'source "$1" >/dev/null 2>&1; ping_parse_args h1:h3 --for "$2" --interval "$3"; echo "$PING_COUNT"' _ "$NDT" "$f" "$i" 2>&1)"
    check "--for $f --interval $i -> $want pings, never more than 600 s of them" "$want" "$got"
done
# One rule, two places: what ndt computes is run through the helper's OWN duration check (hp_duration_ok,
# with the helper's own interval and count validators), across --for 595-600 and a spread of intervals,
# so the two cannot drift apart again.
HELPER="$SRCDIR/ndtwin-lab"
if [[ -r "$HELPER" ]]; then
    ROWS="$(cd "$TREE" && NDT_LIB_ONLY=1 bash -c '
        source "$1" >/dev/null 2>&1
        for f in 595 596 597 598 599 600; do
            for i in 0.01 0.011 0.013 0.017 0.07 0.1 0.2 0.3 0.33 0.9 1 1.5 2.5 7 9.99 10; do
                ping_parse_args h1:h3 --for "$f" --interval "$i" >/dev/null 2>&1 || { echo "$f $i PARSE-REFUSED"; continue; }
                echo "$f $i $PING_COUNT"
            done
        done' _ "$NDT" 2>&1)"
    HELPER_SAYS="$(NDTWIN_LAB_SOURCED=1 HELPER="$HELPER" ROWS="$ROWS" bash -c '
        source "$HELPER" >/dev/null 2>&1; set +e
        n=0; bad=""
        while read -r f i c; do
            n=$((n+1))
            ms="$(hp_interval_ms "$i")" && hp_valid_count "$c" && hp_duration_ok "$c" "$ms" || bad+="$f/$i/$c "
        done <<<"$ROWS"
        echo "$n ${bad:-ok}"' 2>&1)"
    check "every count ndt computes for --for 595-600 (96 combinations) is accepted by the helper's own checks" "96 ok" "$HELPER_SAYS"
    check "control: the helper's check does refuse what the old rounding gave (86 pings at 7 s)" "no" \
          "$(NDTWIN_LAB_SOURCED=1 HELPER="$HELPER" bash -c 'source "$HELPER" >/dev/null 2>&1; set +e; hp_duration_ok 86 7000 && echo yes || echo no')"
else
    check "the helper is beside the ndt under test (the duration cross-check needs it)" "yes" "no"
fi
out="$("$NDT" ping 2>&1)"; rc=$?
check "through the executable: bare 'ndt ping' -> 2 with its usage" "2 yes" "$rc $(has 'usage: ndt ping <src>:<dst>' "$out")"
out="$("$NDT" ping wait extra 2>&1)"; rc=$?
check "'ndt ping wait extra' -> 2" "2" "$rc"

echo "P2 names come from the recorded model, never a guess"
fresh; record
lib cmd_ping h1:h3,h4:h1 --for 1 --interval 1 >/dev/null 2>&1; rc=$?; settle
check "with a record: h3 -> 10.0.3.3, h1 -> 10.0.1.1 (and h4 from a model entry with a prefix length)" \
      "0 -n /usr/local/sbin/ndtwin-lab host-ping h1 10.0.3.3 1 1|-n /usr/local/sbin/ndtwin-lab host-ping h4 10.0.1.1 1 1" \
      "$rc $(grep host-ping "$SUDO_LOG" | sort | paste -sd'|')"
fresh; record
out="$(lib cmd_ping h1:h9 2>&1)"; rc=$?
check "an unknown destination name -> 2, named, nothing started" "2 yes 0" "$rc $(has 'h9 is not a host of setting/model.json' "$out") $(calls)"
out="$(lib cmd_ping h9:h3 2>&1)"; rc=$?
check "an unknown source name -> 2, named" "2 yes" "$rc $(has 'h9 is not a host of' "$out")"
fresh; norecord
out="$(lib cmd_ping h1:h3 2>&1)"; rc=$?
check "🔴 no record: a name is refused (2), with the address form to use, and nothing is called" "2 yes 0" \
      "$rc $(has "no 'ndt up' record in this checkout" "$out") $(grep -c . "$SUDO_LOG")"
lib cmd_ping h1:10.0.3.3 --for 1 --interval 1 >/dev/null 2>&1; rc=$?; settle
check "no record: an address is used as given" "0 -n /usr/local/sbin/ndtwin-lab host-ping h1 10.0.3.3 1 1" "$rc $(grep host-ping "$SUDO_LOG")"
fresh; printf 'plane=p4\ntopology=setting/gone.json\nat=1\n' > "$TREE/.test_run/up.target"
out="$(lib cmd_ping h1:h3 2>&1)"; rc=$?
check "a record whose model is gone: 2, and it says so" "2 yes" "$rc $(has 'cannot be read: give the address' "$out")"
record

echo "P3 the guards: a refusal starts nothing and writes nothing"
fresh; record
printf 'owner=alice\nexpires=%s\nnote=lldp run\nmeasuring=lldp timing\n' "$(( $(date +%s) + 3600 ))" > "$TREE/.test_run/lab.claim"
out="$(NDT_OWNER=bob lib cmd_ping h1:h3 2>&1)"; rc=$?
check "somebody else's claim -> 5, no sudo call at all, no run dir" "5 0 no" "$rc $(grep -c . "$SUDO_LOG") $([[ -e $TREE/.test_run/ping ]] && echo yes || echo no)"
check "  and it names the holder and what they declared" "yes yes" "$(has 'claimed by alice' "$out") $(has 'measuring=lldp timing' "$out")"
NDT_OWNER=alice lib cmd_ping h1:h3 --for 1 --interval 1 >/dev/null 2>&1; rc=$?; settle
check "control: the same claim, our own -> starts (0)" "0 1" "$rc $(calls)"
fresh; record
printf 'owner=alice\nexpires=%s\n' "$(( $(date +%s) + 3600 ))" > "$TREE/.test_run/lab.claim"
out="$(NDT_OWNER=bob lib cmd_ping h1:h3 --for 1 --interval 1 --force 2>&1)"; rc=$?; settle
check "--force over the claim: starts, and writes ONE overrides line naming the command" "0 1 1 yes" \
      "$rc $(calls) $(grep -c . "$TREE/.test_run/lab.claim.overrides" 2>/dev/null) $(has 'command=ndt ping h1:h3 --for 1 --interval 1 --force' "$(cat "$TREE/.test_run/lab.claim.overrides" 2>/dev/null)")"
fresh; record
printf 'owner=alice\nexpires=%s\n' "$(( $(date +%s) + 3600 ))" > "$TREE/.test_run/lab.claim"
FAKE_TOPO=down NDT_OWNER=bob lib cmd_ping h1:h3 --force >/dev/null 2>&1; rc=$?
check "--force with no topology: 3, and no override is recorded for a run that did not start" "3 0 no" \
      "$rc $(calls) $([[ -s $TREE/.test_run/lab.claim.overrides ]] && echo yes || echo no)"
fresh; record
out="$(FAKE_IN_FLIGHT='/bin/bash ./matrix.sh cell 3' lib cmd_ping h1:h3 2>&1)"; rc=$?
check "a measurement in flight -> 5, no sudo call, no run dir" "5 0 no" "$rc $(grep -c . "$SUDO_LOG") $([[ -e $TREE/.test_run/ping ]] && echo yes || echo no)"
check "  and it quotes what is running" "yes" "$(has 'matrix.sh cell 3' "$out")"
fresh; record
printf 'pid=%s\nat=now\n' "$$" > "$TREE/.test_run/down.inflight"
out="$(lib cmd_ping h1:h3 --force 2>&1)"; rc=$?
check "an 'ndt down' in flight -> 5 even with --force, no sudo call" "5 0" "$rc $(grep -c . "$SUDO_LOG")"
check "  and it says why" "yes" "$(has "an 'ndt down' from this checkout is still running" "$out")"
fresh; record
out="$(FAKE_TOPO=down lib cmd_ping h1:h3 2>&1)"; rc=$?
check "no topo session -> 3, no host-ping call, no run dir" "3 0 no" "$rc $(calls) $([[ -e $TREE/.test_run/ping ]] && echo yes || echo no)"
out="$(FAKE_TOPO=refused lib cmd_ping h1:h3 2>&1)"; rc=$?
check "the topo session cannot be read (status refused) -> 5, no host-ping call" "5 0" "$rc $(calls)"

echo "P4 the report: a loss figure only from ping's own summary"
# report_for <mode> -- one stream h1 -> h3 answered by the fake in that mode; prints rc and output.
report_for() {
    fresh; record; [[ -n "$1" ]] && mode h1-10.0.3.3 "$1"
    lib cmd_ping h1:h3 --for 60 --interval 0.02 >/dev/null 2>&1
    settle
    REP="$(lib cmd_ping report 2>&1)"; REP_RC=$?
}
report_for ""
check "(a) 0% lost -> rc 0, ping's own numbers" "0 yes" "$REP_RC $(has '3000 sent  3000 received  0% packet loss' "$REP")"
report_for loss
check "(b) loss -> rc 1, ping's own figure" "1 yes" "$REP_RC $(has '3000 sent  2431 received  18.97% packet loss' "$REP")"
report_for refused
check "🔴 (c) sudo refused (rc 1, no summary) -> NOT MEASURED, rc 4" "4 yes" "$REP_RC $(has 'NOT MEASURED -- sudo refused /usr/local/sbin/ndtwin-lab host-ping' "$REP")"
check "  (c) with the grant line, once" "1" "$(grep -c 'grant it:' <<<"$REP")"
check "🔴 (c) the output says neither 0% nor 100%" "no no" "$(has '0%' "$REP") $(has '100%' "$REP")"
report_for total
check "🔴 (d) ping rc 1 WITH a 100% summary -> measured: rc 1, 100% loss" "1 yes" "$REP_RC $(has '3000 sent  0 received  100% packet loss' "$REP")"
fresh; record
lib cmd_ping h1:h3 --for 60 --interval 0.02 >/dev/null 2>&1; settle
d="$(lastdir)"; b="$(ls "$d"/1.*.plan 2>/dev/null)"; b="${b%.plan}"
# Only inside this suite's run directory: an ndt that started nothing leaves b empty, and the edits
# below must then touch nothing (they once wrote ./.pid into the cwd of a run against an old ndt).
if [[ -n "$d" && "$b" == "$TREE/.test_run/ping/"* && -f "$b.plan" ]]; then
    rm -f "$b.rc" "$b.out"; echo 999999 > "$b.pid"; sed -i 's/^ends=.*/ends=1/' "$b.plan"
fi
REP="$(lib cmd_ping report 2>&1)"; REP_RC=$?
check "(e) no .rc, its process gone, past its end -> killed, NOT MEASURED, rc 4" "4 yes" "$REP_RC $(has 'NOT MEASURED -- no summary: the stream was killed before it ended' "$REP")"
report_for oldhelper
check "(f) an older helper's usage line -> 'no host-ping verb', with both shas" "4 yes" "$REP_RC $(has 'the installed helper has no host-ping verb (installed' "$REP")"
report_for nohost
check "(g) the helper's own refusal is passed through" "4 yes" "$REP_RC $(has 'NOT MEASURED -- ndtwin-lab host-ping: no Mininet host h1' "$REP")"
report_for early
check "(h) fewer sent than planned is flagged, and still measured (rc 0)" "0 yes" "$REP_RC $(has '(ended early: 2400 of 3000 sent)' "$REP")"
report_for zero
check "(h2) a summary with 0 transmitted -> NOT MEASURED with ping's message" "4 yes" "$REP_RC $(has 'NOT MEASURED -- ping sent nothing: ping: connect: Network is unreachable' "$REP")"
report_for killed
check "(h3) killed by a signal (TERM) -> NOT MEASURED, killed, rc 4" "4 yes" "$REP_RC $(has 'the stream was killed (signal 15)' "$REP")"
# The two rows no earlier cell reached. An unreachable destination is the realistic one: ping prints
# one line and exits 2 with no statistics at all; and a summary can arrive without its loss figure.
report_for nopct
check "(k) a summary 'N transmitted, M received' with no '% packet loss' -> NOT MEASURED, rc 4" "4 yes" \
      "$REP_RC $(has "NOT MEASURED -- ping's summary has no loss figure: 3000 packets transmitted, 3000 received" "$REP")"
check "🔴 (k) the output says neither 0% nor 100%" "no no" "$(has '0%' "$REP") $(has '100%' "$REP")"
report_for unreach
check "(l) exit 2 with only 'ping: connect: Network is unreachable' on stderr -> NOT MEASURED, rc 4" "4 yes" \
      "$REP_RC $(has 'NOT MEASURED -- no summary (exit 2): ping: connect: Network is unreachable' "$REP")"
check "🔴 (l) the output says neither 0% nor 100%" "no no" "$(has '0%' "$REP") $(has '100%' "$REP")"
# A rejected decoy makes the helper print its own refusal line even when the call goes on; that line is
# not the reason a LATER failure happened. The helper's line is used only for its own refusals (64-67),
# and then the last one is the verdict.
report_for decoyunreach
check "(o) a rejected decoy, then ping unreachable (exit 2) -> the reason is ping's, not the decoy's" "4 yes no" \
      "$REP_RC $(has 'NOT MEASURED -- no summary (exit 2): ping: connect: Network is unreachable' "$REP") $(has 'refusing pid' "$REP")"
report_for twolines
check "(p) the helper refuses (66) after naming a decoy -> the reason is its LAST line" "4 yes no" \
      "$REP_RC $(has "NOT MEASURED -- ndtwin-lab host-ping: no process carrying Mininet host h1's tag passed the identity check" "$REP") $(has 'refusing pid' "$REP")"
fresh; record; mode h1-10.0.3.3 hang
lib cmd_ping h1:h3 --for 60 --interval 0.02 >/dev/null 2>&1; sleep 0.5
REP="$(lib cmd_ping report 2>&1)"; REP_RC=$?
check "(i) a stream still running -> RUNNING with its end, rc 4" "4 yes" "$REP_RC $(has 'RUNNING -- ends by' "$REP")"
fresh; record; mode h1-10.0.3.3 loss; mode h3-10.0.1.1 refused
lib cmd_ping h1:h3,h3:h1 --for 60 --interval 0.02 >/dev/null 2>&1; settle
REP="$(lib cmd_ping report 2>&1)"; REP_RC=$?
check "🔴 (j) a loss and a sudo refusal -> rc 1 (1 outranks 4), each on its own line" "1 yes yes" \
      "$REP_RC $(has '1   h1 -> h3 (10.0.3.3)   3000 sent  2431 received  18.97% packet loss' "$REP") $(has '2   h3 -> h1 (10.0.1.1)   NOT MEASURED -- sudo refused' "$REP")"
# A run whose own files are damaged must not read as green: the report goes through the streams the
# run file says it started, and one with nothing to show is NOT MEASURED too.
fresh; record
lib cmd_ping h1:h3,h3:h1 --for 1 --interval 1 >/dev/null 2>&1; settle
d="$(lastdir)"
[[ "$d" == "$TREE/.test_run/ping/"* ]] && rm -f "$d"/2.*.plan
REP="$(lib cmd_ping report 2>&1)"; REP_RC=$?
check "(m) a stream the run started, with its plan file missing -> NOT MEASURED, rc 4, and the other still reported" "4 yes yes" \
      "$REP_RC $(has 'NOT MEASURED -- stream 2 has no plan file' "$REP") $(has '1 sent  1 received  0% packet loss' "$REP")"
fresh; record
lib cmd_ping h1:h3 --for 1 --interval 1 >/dev/null 2>&1; settle
d="$(lastdir)"
[[ "$d" == "$TREE/.test_run/ping/"* ]] && sed -i '/^streams=/d' "$d/run"
REP="$(lib cmd_ping report 2>&1)"; REP_RC=$?
check "(n) a run file without streams= -> NOT MEASURED, rc 4, no stream line, not green" "4 yes no" \
      "$REP_RC $(has 'NOT MEASURED -- the run file does not say how many streams were started (streams=missing)' "$REP") $(has 'packet loss' "$REP")"
[[ "$d" == "$TREE/.test_run/ping/"* ]] && printf 'streams=0\n' >> "$d/run"
REP="$(lib cmd_ping report 2>&1)"; REP_RC=$?
check "(n2) streams=0 -> NOT MEASURED too (rc 4)" "4 yes" "$REP_RC $(has 'does not say how many streams were started (streams=0)' "$REP")"
fresh; record 1700000000
lib cmd_ping h1:h3 --for 1 --interval 1 >/dev/null 2>&1; settle; record 1700000999
REP="$(lib cmd_ping report 2>&1)"
check "a fabric rebuilt during the run is said, under the numbers" "yes" "$(has 'the fabric was taken down or rebuilt during this run' "$REP")"
fresh
REP="$("$NDT" ping report 2>&1)"; REP_RC=$?
check "no run recorded -> 3 (through the executable)" "3 yes" "$REP_RC $(has "no 'ndt ping' run is recorded" "$REP")"

echo "P5 the sudo call"
fresh; record
lib cmd_ping h1:h3 --for 60 --interval 0.02 >/dev/null 2>&1; settle
check "exactly one helper verb, with exactly four arguments" "-n /usr/local/sbin/ndtwin-lab host-ping h1 10.0.3.3 3000 0.02" "$(grep host-ping "$SUDO_LOG")"
check "no mnexec call, and nothing but status and host-ping" "0 0" "$(grep -c mnexec "$SUDO_LOG") $(grep -vcE 'ndtwin-lab (status$|host-ping )' "$SUDO_LOG")"

echo "P6 start returns at once; wait waits, and gives up"
fresh; record
t0=$(date +%s%N)
FAKE_SECS=3 lib cmd_ping h1:h3 --for 1 --interval 1 >/dev/null 2>&1; rc=$?
t1=$(date +%s%N)
check "start returns while a 3 s stream runs (under 2 s), rc 0" "0 yes" "$rc $( (( (t1 - t0) / 1000000 < 2000 )) && echo yes || echo no)"
REP="$(lib cmd_ping wait 2>&1)"; rc=$?
t2=$(date +%s%N)
check "wait returns after the stream ended, with its line (rc 0)" "0 yes yes" "$rc $( (( (t2 - t0) / 1000000 >= 2900 )) && echo yes || echo no) $(has '1 sent  1 received  0% packet loss' "$REP")"
fresh; record; mode h1-10.0.3.3 hang
t0=$(date +%s)
REP="$(NDT_PING_GRACE=1 FAKE_HANG=30 lib cmd_ping h1:h3 --for 1 --interval 1 --wait 2>&1)"; rc=$?
t1=$(date +%s)
check "--wait on a stream that never ends: gives up at its deadline (1 s + 5) + grace 1, rc 4, RUNNING" "4 yes yes" \
      "$rc $( (( t1 - t0 >= 6 && t1 - t0 <= 12 )) && echo yes || echo no) $(has 'RUNNING' "$REP")"

echo "P7 where the files go"
fresh; record
before="$(cd "$TREE" && find . -path ./.test_run/ping -prune -o -print | sort)"
lib cmd_ping h1:h3,h3:h1 --for 1 --interval 1 >/dev/null 2>&1; settle
after="$(cd "$TREE" && find . -path ./.test_run/ping -prune -o -print | sort)"
check "nothing written outside .test_run/ping/" "$before" "$after"
d="$(lastdir)"
check "the run is one directory under .test_run/ping/" "yes" "$([[ -d "$d" && "$(dirname "$d")" == "$TREE/.test_run/ping" ]] && echo yes || echo no)"
check "every file in it is this user's" "" "$(find "$TREE/.test_run/ping" ! -user "$(id -u)" -print)"
check "each stream has its plan, output, errors and exit code" "2 2 2 2" \
      "$(ls "$d"/*.plan | wc -l) $(ls "$d"/*.out | wc -l) $(ls "$d"/*.err | wc -l) $(ls "$d"/*.rc | wc -l)"
check "nothing is registered in .test_run/pids/ ('ndt down' and 'ndt clean' are unchanged)" "no" \
      "$([[ -e "$TREE/.test_run/pids" ]] && echo yes || echo no)"

echo "P8 the usage text"
out="$("$NDT" help 2>&1)"
check "'ndt help' lists ping with its exit codes" "yes yes" "$(has 'ping <src>:<dst>[,<src>:<dst>...]' "$out") $(has '1 outranks 4' "$out")"
check "'ndt help' says what sudo covers: the helper, its status and host-ping verbs -- not host-ping alone" "yes no" \
      "$(has 'helper (its status and host-ping verbs' "$out") $(has "sudo: only 'ndtwin-lab host-ping'" "$out")"
check "'ndt help' names the run directory as <UTC stamp>.<pid>, as ndt makes it" "yes" "$(has '.test_run/ping/<UTC stamp>.<pid>/' "$out")"

echo "D1 every 'ndt ping' command the docs show parses"
# The docs are read from the tree the ndt under test sits in, so a mutation gate can hand this a
# doc with a typo next to its ndt.
DOCROOT="$(cd "$SRCDIR/../.." && pwd)"
for doc in examples/p4_energy_saving/README.md doc/2026-11-05_user-guide.md doc/2026-10-31_p4-app-guide.md; do
    lines="$(grep -oE 'ndt ping [^`#|]*' "$DOCROOT/$doc" 2>/dev/null | sed -E 's/[[:space:]]+$//' \
             | grep -vxE 'ndt ping (wait|report)')"
    check "$doc shows at least one 'ndt ping' that starts pings" "yes" "$([[ -n "$lines" ]] && echo yes || echo no)"
    while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        # shellcheck disable=SC2086 -- the doc's words, split as a shell would split them
        rc="$(cd "$TREE" && NDT_LIB_ONLY=1 bash -c 'source "$1" >/dev/null 2>&1; shift; ping_parse_args "$@" >/dev/null 2>&1; echo $?' _ "$NDT" ${l#ndt ping })"
        check "  parses: $l" "0" "$rc"
    done <<<"$lines"
done
# The run directory is <UTC stamp>.<pid> (two runs in one second must not collide), and the guide says so.
check "the user guide names the run directory as <UTC stamp>.<pid>, not a bare <stamp>" "1 0" \
      "$(grep -c '\.test_run/ping/<UTC stamp>\.<pid>/' "$DOCROOT/doc/2026-11-05_user-guide.md") $(grep -c '\.test_run/ping/<stamp>/' "$DOCROOT/doc/2026-11-05_user-guide.md")"

echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
