#!/usr/bin/env bash
#
# `ndt up` refuses over somebody else's lab on BOTH planes, `--force` is written down, and a
# stale pidfile is marked by `status`, removed by `down`, and is not something to tear down.
#
# [Co-developed with claude code -- Adam]
#
# TICKET-ndt-ovs-claim (doc/audit/2026-09-25_ndt-ovs-claim/), Adam's ruling 2026-09-25:
#
#   1. up_p4 has refused over a foreign claim (and over a measurement in flight) with rc 5 since
#      09-12. up_ovs had NEITHER check. Measured by the ndt serve round, 2026-09-24 22:49:45-46
#      (feat/ndt-serve-0924, doc/audit/2026-09-24_ndt-serve/REPORT.md section 2): a foreign owner
#      claimed the lab, `ndt up 4` built an OVS fabric under that claim in 8.5 s and exited 0,
#      and `ndt help` said "5 ... the lab is claimed by somebody else" of both planes. The ruling:
#      OVS refuses exactly as P4 does, through the SAME code, and nothing is half-built.
#   2. an explicit override, the same flag on both planes, and every use of it recorded -- who,
#      when, whose claim.
#   3. a pidfile whose pid is gone (and whose process group, if recorded, is empty) is STALE:
#      `status` marks it, `down` removes it, and an already-down lab answers 3 with one of them
#      in .test_run/pids/. The measured case: `.test_run/pids/app_viz.pid`, written 09-14, naming
#      a pid long gone, which made "down an already-down lab" answer 0 instead of 3; the
#      orchestrator had to delete it by hand.
#
# 🔴 FROM A CLAIM FILE, not from a stubbed foreign_claim() -- for the reason
# tests/shell/test_ndt_down_claim_guard.sh gives: the file on disk producing the answer and the
# command acting on the answer have failed separately in this repo (ROLE-4 T1, T2). in_flight is
# the one reading answered by the fixture (FX_BUSY): it reads the process table.
#
# 🔴 WHAT MUST NOT HAPPEN is half of every refusal cell: no sudo, no stack.sh, no up.target, no
# temp file or fifo left in TMPDIR, the app knob untouched, the claim byte-identical, and no
# override recorded. The proceeding controls read the SAME instruments non-zero, so "nothing was
# touched" cannot be a sentence the harness always says.
#
# Offline, fixture-driven, the seam test_ndt_up_down_robust.sh uses: `ndt` is sourced, REPO/LAB/
# STACK point into a temp dir, `sudo` and `sleep` are shell functions, stack.sh is a recording
# fake. The only real processes are this suite's own `sleep` fixtures, spawned by it and killed by
# pid when it ends. No lab, no root, no port.
#
# Run:  bash tests/shell/test_ndt_ovs_claim.sh
# Env:  NDT_UNDER_TEST=<path>   (tests/shell/mutate_ndt_ovs_claim.sh points it at a copy)
# Exit: 0 every check passed, 1 some check failed, 2 the harness could not start
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

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-ovs-claim-XXXXXX")"
FIXTURES="$FIX/fixture.pids"
: > "$FIXTURES"
# Every process this suite starts is a `sleep` it spawned, recorded here, and killed BY PID --
# never by name, never by pattern. Checked against /proc/<pid>/comm first, so a recycled number
# is left alone.
reap_fixtures() {
    local pid
    [[ -f "$FIXTURES" ]] || return 0
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || continue
        kill -KILL "$pid" 2>/dev/null
    done < "$FIXTURES"
    return 0
}
cleanup() { reap_fixtures; [[ -n "${FIX:-}" && -d "$FIX" ]] && rm -rf "$FIX"; return 0; }
trap cleanup EXIT INT TERM
export FIX
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs" "$FIX/setting" "$FIX/p4_proxy/mininet" \
         "$FIX/p4_proxy/venv/bin" "$FIX/p4_proxy/p4_src/build" "$FIX/build/bin" \
         "$FIX/tools/test_workflow" "$FIX/tmp" "$FIX/etc"

# --- fixtures -------------------------------------------------------------------------------
: > "$FIX/build/bin/ndtwin_kernel";            chmod +x "$FIX/build/bin/ndtwin_kernel"
: > "$FIX/p4_proxy/venv/bin/python";           chmod +x "$FIX/p4_proxy/venv/bin/python"
echo '{}' > "$FIX/p4_proxy/p4_src/build/ndtwin_switch.json"
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
mk_topo StaticNetworkTopologyMininet_10Switches_128Hosts.json 128 40
printf 'helper v2\n' > "$FIX/installed-ndtwin-lab"
printf 'helper v2\n' > "$FIX/tools/test_workflow/ndtwin-lab"

# The recording fake stack.sh, playing the FIFO protocol up_ovs depends on (print "[2/3]", block
# on stdin), so the proceeding controls run the real bring-up sequencing.
cat > "$FIX/stack.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/stack.log"
case "$1 ${2:-}" in
    "up ovs")
        echo "[1/3] control plane (Ryu)"
        echo "[2/3] data plane (Mininet, needs sudo)"
        read -r _ || true
        echo "converged"
        exit 0 ;;
    "up p4")
        echo "[1/3] data plane"; echo "started"; exit 0 ;;
    "down"*)
        echo "stopped kernel"; echo "stopped ryu"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$FIX/stack.sh"

KNOB="$FIX/p4_proxy/mininet/app_package_override"
reset_fix() {
    rm -f "$FIX/sudo.log" "$FIX/stack.log" "$FIX/bmv2.seq" "$FIX/mn.seq" \
          "$FIX/.test_run/up.target" "$FIX/.test_run/lab.claim" "$FIX/.test_run/lab.claim.prev" \
          "$FIX/.test_run/down.inflight"
    rm -rf "$FIX/.test_run/lab.claim.overrides" "$FIX/.test_run/apps"
    rm -f "$FIX/.test_run/pids/"* "$FIX/tmp/"*
    echo 4 > "$FIX/p4_proxy/mininet/host_count_override"
    echo '{"switches":[]}' > "$FIX/manifest.json"
    # A knob an OVS bring-up clears on its way up -- so a refusal that left it gone had
    # already started acting (up_ovs's app_knob_clear sits after record_up_target).
    printf '%s\n' "$FIX/some-app-package" > "$KNOB"
    : > "$FIX/sudo.log"; : > "$FIX/stack.log"
}

# --- the seam -------------------------------------------------------------------------------
# foreign_claim, claim_field, measuring_declared, up_ovs, up_p4, preflight, cmd_down, cmd_clean
# and the pidfile predicates are left REAL -- they are the subject.
STUBS='
REPO="'"$FIX"'"
HERE="'"$FIX"'/tools/test_workflow"
LAB="'"$FIX"'/installed-ndtwin-lab"
STACK="'"$FIX"'/stack.sh"
MANIFEST="'"$FIX"'/manifest.json"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
LAB_CONF="'"$FIX"'/etc/ndtwin-lab.conf"
LAB_DEFAULT_KERNEL_DIR="'"$FIX"'"
# [Co-developed with claude code -- Adam] TICKET-P4-heartbeat segment W: the heartbeat pidfile and
# report are fixture paths (never present), so a heartbeat running on this machine cannot add a
# `heartbeat stop` to a teardown cell or a row to a status cell.
HB_PIDFILE="'"$FIX"'/run/heartbeat.pid"; HB_REPORT="'"$FIX"'/run/heartbeat.json"
export TMPDIR="'"$FIX"'/tmp"
sudo() {
    local a args=()
    for a in "$@"; do [[ "$a" == -n ]] && continue; args+=("$a"); done
    local verb="${args[1]:-none}"
    printf "%s %s\n" "${args[0]##*/}" "${args[*]:1}" >> "'"$FIX"'/sudo.log"
    [[ "$verb" == cleanup ]] && rm -f "'"$FIX"'/manifest.json"
    [[ "$verb" == topo-start ]] && echo "{\"switches\":[]}" > "'"$FIX"'/manifest.json"
    return 0
}
sleep() { :; }
seq_read() {
    local f="$1" v rest
    [[ -f "$f" ]] || { echo "$2"; return 0; }
    read -r v rest < "$f"
    [[ -n "${rest// /}" ]] && printf "%s\n" "$rest" > "$f"
    echo "${v:-$2}"
}
bmv2_count() { seq_read "'"$FIX"'/bmv2.seq" "${FX_BMV2:-0}"; }
mn_count()   { seq_read "'"$FIX"'/mn.seq"   "${FX_MN:-0}"; }
fabric_host_count() { echo "${FX_FABRIC_HOSTS:-4}"; }
topo_session() { [[ -n "${FX_TOPO_SESSION:-}" ]]; }
in_flight() { [[ -n "${FX_BUSY:-}" ]] && printf "%s\n" "$FX_BUSY"; return 0; }
guard_no_live_ovs() { return 0; }
bmv2_binary() { echo fixture-bmv2; }
sample_rate() { echo 256; }
stale_pipeline() { return 1; }
source_ahead_of_build() { return 1; }
verify_p4() { return "${FX_VERIFY_RC:-0}"; }
app_probe() { APP_STATE=not-running; APP_LIVE_PIDS=(); }
check_up_target() { UP_TARGET_PROBLEMS=(); return 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
git_lines() { :; }
ovs_bridge_count() { echo "${FX_BRIDGES:-0}"; }
ovs_daemon_running() { [[ "${FX_BRIDGES:-0}" -gt 0 ]]; }
netem_count() { echo 0; }
port_open() { return 1; }
http_get_graph() { :; }
curl() { return 1; }
wait_reaped() { return 0; }
ndt_port_open() { return 1; }
ndt_port_listener_pids() { return 0; }
'

drive() {   # drive <shell-code> -> its output plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

count_lines() { local n; n="$(grep -c . "$1" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
# How much of the machine and of the checkout a bring-up reached. Every refusal wants all of it
# at zero; the proceeding controls read the same instrument and must see it move.
touched() {
    printf 'sudo=%s stack=%s target=%s tmp=%s knob=%s' \
        "$(count_lines "$FIX/sudo.log")" "$(count_lines "$FIX/stack.log")" \
        "$([[ -e "$FIX/.test_run/up.target" ]] && echo 1 || echo 0)" \
        "$(find "$FIX/tmp" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" \
        "$([[ -e "$KNOB" ]] && echo kept || echo cleared)"
}
UNTOUCHED='sudo=0 stack=0 target=0 tmp=0 knob=kept'
# [Co-developed with claude code -- Adam] judge's note 10 (round 2): every column of touched() has
# to be seen reading non-zero somewhere, or "nothing was touched" is a sentence it cannot help
# saying. The bring-up cells below move sudo/stack/target/knob; tmp= is moved here, by hand,
# because a finished bring-up removes its own fifo and temp file.
# ($$ in the name: $FIX is already mktemp'd, but tests/shell/check_test_tmpdirs.py reads the
# spelling "/tmp/<name>" and cannot know that, and a per-process marker costs nothing.)
: > "$FIX/tmp/instrument-probe.$$"
[[ "$(touched)" == *"tmp=1"* ]] || { echo "  FAILED   touched() cannot read a file in TMPDIR"; echo "Ran 1 checks, 1 failed"; exit 1; }
rm -f "$FIX/tmp/instrument-probe.$$"
OVR="$FIX/.test_run/lab.claim.overrides"
overrides() { count_lines "$OVR"; }
ovr_field() {   # <key> -- that field of the LAST override line (tab-separated key=value)
    [[ -f "$OVR" ]] || return 0
    tail -n 1 "$OVR" | tr '\t' '\n' | sed -n "s/^$1=//p" | head -1
}
claim_sum() { sha256sum "$FIX/.test_run/lab.claim" 2>/dev/null | cut -d' ' -f1; }

write_claim() {   # <owner> <expires-epoch> <note> <measuring>
    printf 'owner=%s\nexpires=%s\nnote=%s\nexclusive_cpu=%s\nmeasuring=%s\n' \
        "$1" "$2" "$3" no "$4" > "$FIX/.test_run/lab.claim"
}
THEM=other-session
US=ovs-claim-worker
FUTURE=$(( $(date +%s) + 1800 ))
PAST=$(( $(date +%s) - 60 ))

# A pid that certainly does not exist, and whose number is no process group's either: allocate
# one, let it exit, and ask /proc. (The shape test_ndt_status_check_baseline.sh's dead_pid uses.)
dead_pid() {
    local p
    ( exit 0 ) & p=$!
    wait "$p" 2>/dev/null
    [[ -d "/proc/$p" ]] && { echo 0; return 1; }
    echo "$p"
}
# spawn <argv0> [setsid] -- a `sleep` wearing that argv0, in $FIX; echo its pid. With `setsid`
# it leads a process group of its own, which is how a live group is planted.
spawn() {
    local want="$1" how="${2:-}" pid i
    local -a argv=()
    if [[ "$how" == setsid ]]; then
        ( cd "$FIX" && exec setsid bash -c 'exec -a "$0" sleep 120' "$want" ) >/dev/null 2>&1 </dev/null &
    else
        ( cd "$FIX" && exec -a "$want" sleep 120 ) >/dev/null 2>&1 </dev/null &
    fi
    pid=$!
    echo "$pid" >> "$FIXTURES"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        argv=()
        mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null
        [[ "${argv[0]:-}" == "$want" ]] && { echo "$pid"; return 0; }
        command sleep 0.1
    done
    echo "  FAILED   fixture never took argv0=$want (pid $pid)" >&2
    echo "Ran $((PASS + FAIL + 1)) checks, $((FAIL + 1)) failed"
    exit 1
}
kill_fixture() {
    local pid="$1" i
    [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || return 0
    kill -KILL "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do [[ -e "/proc/$pid" ]] || return 0; command sleep 0.1; done
}
pidf() { printf '%s\n' "$2" > "$FIX/.test_run/pids/$1"; }   # pidf <file-name> <contents>
present() { [[ -e "$FIX/.test_run/pids/$1" ]] && echo present || echo absent; }

# =============================================================================================
section "1. 🔴 'ndt up ovs' under somebody else's claim: rc 5, and nothing is half-built"
# =============================================================================================
reset_fix
write_claim "$THEM" "$FUTURE" "ROLE-x reader running" ""
BEFORE="$(claim_sum)"
OUT="$(NDT_OWNER="$US" drive 'up_ovs 4')"
check "🔴 a foreign claim refuses the OVS bring-up with 5"   "5" "$(rc_of "$OUT")"
has   "  it says it is refusing to build"                    "refusing to build: the lab is claimed by $THEM" "$OUT"
check "🔴 NOTHING was reached: no sudo, no stack.sh, no target, no temp, knob kept" \
      "$UNTOUCHED" "$(touched)"
check "  the claim file is byte-identical"                   "$BEFORE" "$(claim_sum)"
check "  and no override was recorded -- none was asked for" "0" "$(overrides)"
hasnt "  the bring-up banner never printed"                  "[1/4] control plane (Ryu)" "$OUT"
has   "  the retry line carries the BARE owner"              "NDT_OWNER=$THEM ndt up ovs 4" "$OUT"
hasnt "  🔴 and not the parenthesised description"           "NDT_OWNER=$THEM (until" "$OUT"
has   "  and names the override, with where it is recorded"  "ndt up ovs 4 --force" "$OUT"
has   "  saying where the override would be written"         ".test_run/lab.claim.overrides" "$OUT"

# The holder's own declaration is quoted -- the one sentence they wrote for this moment.
reset_fix
write_claim "$THEM" "$FUTURE" "night round" "sampling matrix, cell 3/8"
OUT="$(NDT_OWNER="$US" drive 'up_ovs 4')"
check "  a foreign claim with measuring= is still 5"         "5" "$(rc_of "$OUT")"
has   "  and quotes the declaration"                         "measuring=sampling matrix, cell 3/8" "$OUT"

# The 128-host plane is the same function, and the default plane.
reset_fix
write_claim "$THEM" "$FUTURE" "night round" ""
OUT="$(NDT_OWNER="$US" drive 'up_ovs 128')"
check "  'ndt up' (OVS 128) is refused the same way"         "5" "$(rc_of "$OUT")"
check "  and reached nothing"                                "$UNTOUCHED" "$(touched)"

# An unnamed caller cannot prove any claim is its own, so every claim is foreign to it.
reset_fix
write_claim "$US" "$FUTURE" "our own round" ""
OUT="$(drive 'unset NDT_OWNER; up_ovs 4')"
check "🔴 NDT_OWNER unset: any live claim refuses"           "5" "$(rc_of "$OUT")"
check "  and reached nothing"                                "$UNTOUCHED" "$(touched)"

# =============================================================================================
section "2. 🔴 'ndt up ovs' with a measurement in flight: rc 5, P4's semantics"
# =============================================================================================
reset_fix
OUT="$(NDT_OWNER="$US" FX_BUSY="iperf3 -c 10.0.0.2 -t 200 -P 4" drive 'up_ovs 4')"
check "🔴 a measurement in flight refuses the OVS bring-up" "5" "$(rc_of "$OUT")"
has   "  it says a measurement is running"                   "a measurement is running" "$OUT"
has   "  naming what is running"                             "iperf3 -c 10.0.0.2 -t 200 -P 4" "$OUT"
check "  and reached nothing"                                "$UNTOUCHED" "$(touched)"
has   "  and names the override"                             "ndt up ovs 4 --force" "$OUT"

# =============================================================================================
section "3. 🔴 the controls -- a guard that refuses everything guards nothing"
# =============================================================================================
# Our OWN claim: NDT_OWNER is set on every command, so this is the common case.
reset_fix; echo "0 14" > "$FIX/mn.seq"
write_claim "$US" "$FUTURE" "our own round" ""
OUT="$(NDT_OWNER="$US" drive 'up_ovs 4')"
check "our own live claim is not a refusal"                  "no" "$([[ "$(rc_of "$OUT")" == 5 ]] && echo yes || echo no)"
has   "  the bring-up ran"                                   "[1/4] control plane (Ryu)" "$OUT"
# 🔴 THE INSTRUMENT'S OWN CONTROL. Every refusal cell above rests on touched() reading all
# zeros; this is the same instrument reading a bring-up that ran, and it must move.
has   "🔴 stack.sh WAS invoked -- the instrument can read non-zero" "up ovs" "$(cat "$FIX/stack.log")"
has   "  and the fabric verb WAS run"                        "ovs-topo-4host" "$(cat "$FIX/sudo.log")"
check "  and the knob WAS cleared -- that column can move too" "cleared" "$([[ -e "$KNOB" ]] && echo kept || echo cleared)"
check "  and up.target WAS written"                          "present" "$([[ -e "$FIX/.test_run/up.target" ]] && echo present || echo absent)"
check "  and no override is recorded for a bring-up that needed none" "0" "$(overrides)"

# An EXPIRED claim is stale, not a holder.
reset_fix; echo "0 14" > "$FIX/mn.seq"
write_claim "$THEM" "$PAST" "finished at 01:00" ""
OUT="$(NDT_OWNER="$US" drive 'up_ovs 4')"
check "an EXPIRED claim is not a refusal"                    "no" "$([[ "$(rc_of "$OUT")" == 5 ]] && echo yes || echo no)"
has   "  the bring-up ran"                                   "up ovs" "$(cat "$FIX/stack.log")"

# No claim at all, nothing running.
reset_fix; echo "0 14" > "$FIX/mn.seq"
OUT="$(drive 'unset NDT_OWNER; up_ovs 4')"
check "no claim and nothing running is not a refusal"        "no" "$([[ "$(rc_of "$OUT")" == 5 ]] && echo yes || echo no)"
has   "  the bring-up ran"                                   "up ovs" "$(cat "$FIX/stack.log")"

# =============================================================================================
section "4. 🔴 --force builds, and every use of it is written down"
# =============================================================================================
reset_fix; echo "0 14" > "$FIX/mn.seq"
write_claim "$THEM" "$FUTURE" "ROLE-x reader running" "reader nsr"
OUT="$(NDT_OWNER="$US" drive 'NDT_UP_FORCE=1; up_ovs 4')"
check "--force is not refused"                               "no" "$([[ "$(rc_of "$OUT")" == 5 ]] && echo yes || echo no)"
has   "  the fabric was built"                               "ovs-topo-4host" "$(cat "$FIX/sudo.log")"
has   "  it says out loud it is building over the claim"     "--force: building over the claim of $THEM" "$OUT"
check "🔴 exactly one override is recorded"                  "1" "$(overrides)"
check "  who: the NDT_OWNER that forced it"                  "$US" "$(ovr_field by)"
check "  🔴 whose claim was overridden"                      "$THEM" "$(ovr_field over)"
check "  that claim's expiry, as it was"                     "$FUTURE" "$(ovr_field claim_expires)"
check "  what that claim declared"                           "reader nsr" "$(ovr_field measuring)"
check "  when: a timestamp with a date and an offset"        "yes" \
      "$([[ "$(ovr_field at)" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$ ]] && echo yes || echo no)"
has   "  and the command it forced"                          "up ovs 4 --force" "$(ovr_field command)"
check "  which login ran it"                                 "$(id -un)" "$(ovr_field user)"

# A second override APPENDS: this file is history, and the first line is still the first line.
FIRST="$(head -n 1 "$OVR" 2>/dev/null)"
reset_keep_ovr() { local keep; keep="$(cat "$OVR" 2>/dev/null)"; reset_fix; [[ -n "$keep" ]] && printf '%s\n' "$keep" > "$OVR"; }
reset_keep_ovr; echo "0 14" > "$FIX/mn.seq"
OUT="$(NDT_OWNER="$US" FX_BUSY="matrix.sh cell 4" drive 'NDT_UP_FORCE=1; up_ovs 4')"
check "🔴 --force over a measurement in flight is recorded too, and APPENDED" "2" "$(overrides)"
check "  the first record is untouched"                      "$FIRST" "$(head -n 1 "$OVR" 2>/dev/null)"
check "  with no claim to name, 'over' says so"              "none" "$(ovr_field over)"
has   "  and it names what was running"                      "matrix.sh cell 4" "$(ovr_field running)"

# --force with nothing to override is not an override, and writes nothing.
reset_fix; echo "0 14" > "$FIX/mn.seq"
OUT="$(NDT_OWNER="$US" drive 'NDT_UP_FORCE=1; up_ovs 4')"
check "--force over nothing records nothing"                 "0" "$(overrides)"
has   "  and the bring-up still ran"                         "up ovs" "$(cat "$FIX/stack.log")"

# 🔴 An override that cannot be recorded is not taken. The record's path is a directory here, so
# the append fails -- and the bring-up must not happen behind it.
reset_fix
write_claim "$THEM" "$FUTURE" "night round" ""
mkdir -p "$OVR"
OUT="$(NDT_OWNER="$US" drive 'NDT_UP_FORCE=1; up_ovs 4')"
check "🔴 --force whose record cannot be written is refused" "5" "$(rc_of "$OUT")"
has   "  and says why"                                       "could not be recorded" "$OUT"
check "  and reached nothing"                                "$UNTOUCHED" "$(touched)"
rm -rf "$OVR"

# =============================================================================================
section "5. 🔴 P4 goes through the SAME guard, with the same flag and the same record"
# =============================================================================================
reset_fix
write_claim "$THEM" "$FUTURE" "night round" ""
OUT="$(NDT_OWNER="$US" drive 'up_p4 4')"
check "🔴 a foreign claim still refuses the P4 bring-up with 5" "5" "$(rc_of "$OUT")"
has   "  with the same sentence as OVS"                      "refusing to build: the lab is claimed by $THEM" "$OUT"
check "  and reached nothing"                                "$UNTOUCHED" "$(touched)"
has   "  and names the same override"                        "ndt up p4 4 --force" "$OUT"
reset_fix
OUT="$(NDT_OWNER="$US" FX_BUSY="measure.sh run 2" drive 'up_p4 4')"
check "  a measurement in flight still refuses P4 with 5"    "5" "$(rc_of "$OUT")"
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
write_claim "$THEM" "$FUTURE" "night round" ""
OUT="$(NDT_OWNER="$US" drive 'NDT_UP_FORCE=1; up_p4 4')"
check "--force builds P4 over a foreign claim"               "no" "$([[ "$(rc_of "$OUT")" == 5 ]] && echo yes || echo no)"
has   "  the fabric was started"                             "topo-start" "$(cat "$FIX/sudo.log")"
check "  and the override is recorded"                       "1" "$(overrides)"
check "  naming whose claim"                                 "$THEM" "$(ovr_field over)"
has   "  and the P4 command"                                 "up p4 4 --force" "$(ovr_field command)"

# 🔴 ONE guard, not two copies: neither bring-up reads the claim itself any more. The behaviour
# above is the proof that both are guarded; this is the proof that they are guarded by the one
# function the ticket asks for, so the next change to it cannot fix one plane and not the other.
OUT="$(drive 'declare -f up_ovs; declare -f up_p4')"
check "🔴 neither bring-up calls foreign_claim itself"       "0" "$(grep -c 'foreign_claim' <<<"$OUT")"
check "  and each calls the shared guard exactly once"       "2" "$(grep -c 'guard_up_lab_free ' <<<"$OUT")"

# =============================================================================================
section "6. the flag is argv, parsed once for both planes, and an exported variable is not it"
# =============================================================================================
OUT="$(drive 'up_take_app_flag ovs 4 --force; echo "force=[$NDT_UP_FORCE] argv=[${NDT_UP_ARGV[*]}] words=[$NDT_UP_WORDS]"')"
has   "--force is taken off argv and sets the flag"          "force=[1] argv=[ovs 4]" "$OUT"
has   "  and the words to retry with do not carry it"        "words=[ovs 4]" "$OUT"
OUT="$(drive 'up_take_app_flag --force p4 4; echo "force=[$NDT_UP_FORCE] argv=[${NDT_UP_ARGV[*]}]"')"
has   "  in any position"                                    "force=[1] argv=[p4 4]" "$OUT"
OUT="$(NDT_UP_FORCE=1 drive 'up_take_app_flag ovs 4; echo "force=[$NDT_UP_FORCE]"')"
has   "🔴 an exported NDT_UP_FORCE without the flag forces nothing" "force=[]" "$OUT"
# ...and not even when a bring-up is reached without the dispatch: loading ndt resets it.
reset_fix
write_claim "$THEM" "$FUTURE" "night round" ""
OUT="$(NDT_OWNER="$US" NDT_UP_FORCE=1 drive 'up_ovs 4')"
check "🔴 an exported NDT_UP_FORCE=1 does not open the guard" "5" "$(rc_of "$OUT")"
check "  and nothing was recorded or reached"                "0 $UNTOUCHED" "$(overrides) $(touched)"

# =============================================================================================
section "7. 'ndt help' tells the truth about it"
# =============================================================================================
HELP="$(bash "$NDT" help 2>&1)"
has   "the up block names the override"                      "ndt up <any of the above> --force" "$HELP"
has   "  and where it is recorded"                           ".test_run/lab.claim.overrides" "$HELP"
has   "  rc 5 still names a foreign claim among its causes"  "the lab is claimed by somebody else" "$HELP"
has   "  and says it is BOTH planes now"                     "on BOTH planes" "$HELP"
has   "the down block says a stale entry is not a subject"   "STALE" "$HELP"

# The status row for the record, so the override is found by the next reader and not only by
# someone who knows to cat a file (R7 I-2 condition 2: kept evidence no interface mentions).
reset_fix
write_claim "$THEM" "$FUTURE" "night round" ""
printf 'at=2026-09-25T03:00:00+0800\tby=%s\tuser=u\tpid=1\tcommand=ndt up ovs 4 --force\tover=%s\tclaim_expires=%s\tclaim_note=n\tmeasuring=\trunning=\n' \
    "$US" "$THEM" "$FUTURE" > "$OVR"
OUT="$(NDT_OWNER="$US" drive 'cmd_status')"
has   "🔴 'ndt status' shows the last override"              "--force" "$(grep -A1 -E '^  override ' <<<"$OUT")"
has   "  naming who forced past whom"                        "$US over $THEM" "$OUT"

# =============================================================================================
section "8. 🔴 a stale pidfile: 'ndt status' marks it"
# =============================================================================================
reset_fix
DEAD="$(dead_pid)"
pidf app_viz.pid "$DEAD"
OUT="$(drive 'app_pidfile_stale_row')"
has   "🔴 a dead app pidfile is marked STALE"                "STALE" "$OUT"
has   "  naming the file"                                    ".test_run/pids/app_viz.pid" "$OUT"
has   "  and the pid that is gone"                           "pid $DEAD gone" "$OUT"
has   "  and what removes it"                                "'ndt down' removes it" "$OUT"
OUT="$(drive 'cmd_status')"
has   "🔴 and 'ndt status' itself prints that row (existence is not wiring)" "STALE -- .test_run/pids/app_viz.pid" "$OUT"

# The stack's own files were already marked (R7 I-3); still are.
reset_fix
DEAD="$(dead_pid)"
pidf kernel.pid "$DEAD"
OUT="$(drive 'stack_pidfile_row')"
has   "a dead stack pidfile is still marked stale"          "kernel.pid: stale pidfile (pid $DEAD gone" "$OUT"

# The controls, one per way "the file exists" differs from "the process is gone".
reset_fix
LIVE_VIZ="$(spawn "$FIX/network_traffic_visualizer.sh")"
pidf app_viz.pid "$LIVE_VIZ"
OUT="$(drive 'app_pidfile_stale_row')"
hasnt "🔴 a pidfile naming a LIVE viz is not stale"          "STALE" "$OUT"
kill_fixture "$LIVE_VIZ"

# pid gone, but the process group the app was started in still has a member: the FINDINGS #6/#48
# shape (viz's launcher dead, its JVMs running on). NOT stale.
reset_fix
GROUP="$(spawn "java-child-of-viz" setsid)"
DEAD="$(dead_pid)"
pidf app_viz.pid "$DEAD"; pidf app_viz.pgid "$GROUP"
OUT="$(drive 'app_pidfile_stale_row')"
hasnt "🔴 pid gone but its process group alive: NOT stale"   "STALE -- " "$OUT"
has   "  and it says the group is still there"               "process group $GROUP still has live member(s)" "$OUT"
kill_fixture "$GROUP"

# pid alive, but it is not viz any more -- a recycled number. Identity is pid + argv.
reset_fix
STRANGER="$(spawn "some-unrelated-program")"
pidf app_viz.pid "$STRANGER"
OUT="$(drive 'app_pidfile_stale_row')"
has   "🔴 a pid alive as somebody else is STALE (pid + argv, not the number)" "STALE" "$OUT"
has   "  and it says the number was recycled"                "recycled" "$OUT"
kill_fixture "$STRANGER"

# =============================================================================================
section "9. 🔴 a stale pidfile: 'ndt down' removes it, and a down lab still answers 3"
# =============================================================================================
reset_fix; rm -f "$FIX/manifest.json"
DEAD="$(dead_pid)"
pidf app_viz.pid "$DEAD"
touch -d '@1789365600' "$FIX/.test_run/pids/app_viz.pid"      # 2026-09-14 14:00 +0800, like the real one
pidf app_viz.pgid "$DEAD"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 an already-down lab with a stale pidfile is rc 3, not 0" "3" "$(rc_of "$OUT")"
check "  and the verdict line says what it measured"          "1" "$(grep -cx 'nothing was up to tear down' <<<"$OUT")"
check "🔴 the stale pidfile is GONE"                         "absent" "$(present app_viz.pid)"
check "  and its .pgid with it"                              "absent" "$(present app_viz.pgid)"
has   "  it says it removed it, and why"                     "removed stale .test_run/pids/app_viz.pid -- pid $DEAD gone" "$OUT"
# 🔴 The window is kept before the file goes: app_started_at dates a dead app by this file's
# mtime, and it is the only record of when viz ran (G-12, RESIDUE-1).
check "🔴 the app's window was written down before the file went" "1789365600" \
      "$(sed -n 's/^start=//p' "$FIX/.test_run/apps/viz.window" 2>/dev/null)"
# [Co-developed with claude code -- Adam]
# 🔴 AND ITS RIGHT END (judge's F3, round 2). No app log here, so app_window_seal closes the window
# at the pidfile's own mtime -- zero-length. Written as `now` instead, it would reopen RESIDUE-1's
# twelve-hour window over every rule installed since.
check "🔴 the window's right end is the sealed one, not now" "1789365600" \
      "$(sed -n 's/^end=//p' "$FIX/.test_run/apps/viz.window" 2>/dev/null)"
# Down twice: the second is an already-down lab with nothing stale left.
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 down again: rc 3"                                  "3" "$(rc_of "$OUT")"
hasnt "  and nothing left to remove"                         "removed stale" "$OUT"

# The stack's own leftovers the same way: a dead kernel.pid the fake stack.sh never removes.
reset_fix; rm -f "$FIX/manifest.json"
DEAD="$(dead_pid)"
pidf kernel.pid "$DEAD"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "  a dead kernel.pid on a down lab: rc 3"              "3" "$(rc_of "$OUT")"
check "  and it is removed"                                  "absent" "$(present kernel.pid)"

# 🔴 THE CONTROLS: the sweep removes only what is provably stale.
reset_fix; rm -f "$FIX/manifest.json"
LIVE_VIZ="$(spawn "$FIX/network_traffic_visualizer.sh")"
pidf app_viz.pid "$LIVE_VIZ"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 a LIVE pidfile is kept"                            "present" "$(present app_viz.pid)"
check "  and is a subject: rc 0, not 3"                      "0" "$(rc_of "$OUT")"
kill_fixture "$LIVE_VIZ"

reset_fix; rm -f "$FIX/manifest.json"
GROUP="$(spawn "java-child-of-viz" setsid)"
DEAD="$(dead_pid)"
pidf app_viz.pid "$DEAD"; pidf app_viz.pgid "$GROUP"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 pid gone, group alive: the pidfile is KEPT"        "present" "$(present app_viz.pid)"
check "  and it is still a subject: not 3"                   "no" "$([[ "$(rc_of "$OUT")" == 3 ]] && echo yes || echo no)"
kill_fixture "$GROUP"

reset_fix; rm -f "$FIX/manifest.json"
printf 'not-a-pid\n' > "$FIX/.test_run/pids/app_viz.pid"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "  an UNUSABLE pidfile is not called stale and not removed by the sweep" "present" "$(present app_viz.pid)"

# A refused teardown touches nothing, stale files included.
reset_fix; rm -f "$FIX/manifest.json"
DEAD="$(dead_pid)"
pidf app_viz.pid "$DEAD"
write_claim "$THEM" "$FUTURE" "night round" ""
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "  under a foreign claim 'down' is still 5"            "5" "$(rc_of "$OUT")"
check "  and leaves even the stale file where it is"         "present" "$(present app_viz.pid)"

# =============================================================================================
section "10. 'ndt clean' reads the registry the same way"
# =============================================================================================
reset_fix; rm -f "$FIX/manifest.json"
DEAD="$(dead_pid)"
pidf app_viz.pid "$DEAD"
OUT="$(drive 'cmd_clean')"
check "🔴 only a stale entry: nothing to judge, rc 3"        "3" "$(rc_of "$OUT")"
has   "  and it does not pretend the registry is empty"      "STALE" "$OUT"
check "  clean does not remove it -- it is an assertion"     "present" "$(present app_viz.pid)"
reset_fix; rm -f "$FIX/manifest.json"
pidf kernel.pid "$$"
OUT="$(drive 'cmd_clean')"
check "  a LIVE registry entry is still a subject: rc 0"     "0" "$(rc_of "$OUT")"

# =============================================================================================
section "11. 🔴 F1: a zero-length window moved into a record by 'down' still says NO extent"
# =============================================================================================
# [Co-developed with claude code -- Adam]
# Judge's F1 on 6b7fce83 (orchestrator round 2, 09-25). energy has no log channel on any machine,
# so a dead energy pidfile's window is [mtime, mtime]. While the pidfile exists the report says
# G-12's "NO extent ... NOT 'this app left nothing'"; once `down` moves that window into
# .test_run/apps/energy.window the report reads it from the record -- and until round 2 that path
# printed the window and `no flow entry arrived during that window` with no caveat at all.
RESIDUE_STUBS='
port_open() { return 0; }
http_get_flow_entries() { cat "$REPO/entries.json"; }
live_dataplane_kind() { echo ovs; }
lock_probe() { echo free; }
app_scan_pids() { :; }
lab_kernel_dir() { echo "$REPO"; }
'
printf '%s\n' '[{"dpid": 1, "flows": {"1": [{"actions": ["OUTPUT:1"], "byte_count": 0, "cookie": 0, "duration_sec": 9000, "duration_nsec": 91000000, "flags": 0, "hard_timeout": 0, "idle_timeout": 0, "length": 96, "match": {"in_port": 1}, "packet_count": 0, "priority": 10, "table_id": 0}]}}]' > "$FIX/entries.json"
reset_fix; rm -f "$FIX/manifest.json"
DEAD="$(dead_pid)"
pidf app_energy.pid "$DEAD"
touch -d '@1789365600' "$FIX/.test_run/pids/app_energy.pid"
OUT="$(drive "$RESIDUE_STUBS"'
residue_report energy')"
has   "control: over the pidfile itself the report says NO extent" "has NO extent" "$OUT"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "  down on that lab: rc 3"                             "3" "$(rc_of "$OUT")"
check "  the energy pidfile is gone"                         "absent" "$(present app_energy.pid)"
check "  and its window is on record, zero wide"             "1789365600 1789365600" \
      "$(sed -n 's/^start=//p' "$FIX/.test_run/apps/energy.window" 2>/dev/null) $(sed -n 's/^end=//p' "$FIX/.test_run/apps/energy.window" 2>/dev/null)"
OUT="$(drive "$RESIDUE_STUBS"'
residue_report energy')"
has   "  the report now reads it from the record"            "energy.window" "$OUT"
has   "🔴 F1: and still says the window has NO extent"       "has NO extent" "$OUT"
has   "  and that it is NOT 'this app left nothing'"         "NOT 'this app left nothing'" "$OUT"

# =============================================================================================
section "12. 🔴 F2/F8: a recycled number that leads its own group is STALE (start time), not 'group'"
# =============================================================================================
# [Co-developed with claude code -- Adam]
# Judge's F2 on 6b7fce83. POSIX does not reuse a number still in use as a process-group id, so
# when an app pidfile's number is alive as a stranger the app's own group is gone -- and if the
# stranger leads a group (a shell job, a daemon, anything setsid'd) the group question found its
# own member and called the record "NOT stale". The real shape: a setsid-spawned stranger, the
# .pgid naming it, the pidfile written BEFORE the stranger started.
reset_fix; rm -f "$FIX/manifest.json"
STR="$(spawn "stranger-group-leader" setsid)"
pidf app_viz.pid "$STR"; pidf app_viz.pgid "$STR"
touch -d "@$(( $(date +%s) - 600 ))" "$FIX/.test_run/pids/app_viz.pid"
OUT="$(drive 'app_pidfile_stale_row')"
has   "🔴 recycled into a group leader: STALE"               "STALE -- .test_run/pids/app_viz.pid" "$OUT"
has   "  and it says the process started after the file"     "after this file was written" "$OUT"
hasnt "  and never 'NOT stale'"                              "NOT stale" "$OUT"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 down removes it and a down lab answers 3"          "3 absent" "$(rc_of "$OUT") $(present app_viz.pid)"
check "  and the stranger was not signalled"                 "alive" "$([[ -d /proc/$STR ]] && echo alive || echo gone)"
# The control: the same stranger, and a pidfile written AFTER it started -- this is no longer
# "a number recycled after the file", and the group it leads is still live: NOT stale.
reset_fix; rm -f "$FIX/manifest.json"
pidf app_viz.pid "$STR"; pidf app_viz.pgid "$STR"
OUT="$(drive 'app_pidfile_stale_row')"
hasnt "🔴 control: started BEFORE the file was written -> not stale" "STALE -- " "$OUT"
has   "  it is the live-group case"                          "is NOT stale" "$OUT"
kill_fixture "$STR"

# F8: the stack's own files take the same test. They carry no argv to compare, so a live number
# was always LIVE; one whose process started after the file was written is somebody else's.
reset_fix; rm -f "$FIX/manifest.json"
DAEMON="$(spawn "some-daemon")"
pidf kernel.pid "$DAEMON"
touch -d "@$(( $(date +%s) - 600 ))" "$FIX/.test_run/pids/kernel.pid"
OUT="$(drive 'stack_pidfile_row')"
has   "🔴 F8: a stack pidfile recycled into a stranger is stale" "kernel.pid: stale pidfile (pid $DAEMON is alive, but that process started" "$OUT"
hasnt "  and is not printed as alive"                        "kernel.pid=$DAEMON alive" "$OUT"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "  down: not a subject (rc 3), and removed"            "3 absent" "$(rc_of "$OUT") $(present kernel.pid)"
# [Co-developed with claude code -- Adam] judge r2 #3: the real stack.sh's stop_one printed, a few
# lines up, that it was keeping this file; the removal has to say why that was not a contradiction.
has   "  🔴 and says why stack.sh kept it"                   "stack.sh kept it above because the number is somebody else's" "$OUT"
reset_fix; rm -f "$FIX/manifest.json"
pidf kernel.pid "$DAEMON"
OUT="$(drive 'stack_pidfile_row')"
has   "  control: written after it started -> alive, as before" "kernel.pid=$DAEMON alive" "$OUT"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "  and down keeps it and counts it (rc 0)"             "0 present" "$(rc_of "$OUT") $(present kernel.pid)"
kill_fixture "$DAEMON"

# =============================================================================================
section "13. 🔴 F3/F4: the window's right end is the app's log when there is one; no window, no removal"
# =============================================================================================
reset_fix; rm -f "$FIX/manifest.json"
DEAD="$(dead_pid)"
pidf app_viz.pid "$DEAD"
touch -d '@1789365600' "$FIX/.test_run/pids/app_viz.pid"
printf 'viz wrote this\n' > "$FIX/.test_run/logs/app_viz.log"
touch -d '@1789366100' "$FIX/.test_run/logs/app_viz.log"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 a log newer than the pidfile closes the window at the log's mtime" "1789365600 1789366100" \
      "$(sed -n 's/^start=//p' "$FIX/.test_run/apps/viz.window" 2>/dev/null) $(sed -n 's/^end=//p' "$FIX/.test_run/apps/viz.window" 2>/dev/null)"
rm -f "$FIX/.test_run/logs/app_viz.log"

# F4: the record cannot be written (its directory is a plain file) -> the pidfile is KEPT, down is
# 1, and the claim note names it.
reset_fix; rm -f "$FIX/manifest.json"
write_claim "$US" "$FUTURE" "our own round" ""
DEAD="$(dead_pid)"
pidf app_viz.pid "$DEAD"
: > "$FIX/.test_run/apps"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 F4: no window written -> the stale pidfile is KEPT" "present" "$(present app_viz.pid)"
check "  and down is 1, not 3"                               "1" "$(rc_of "$OUT")"
has   "  it says why it kept it"                             "kept stale .test_run/pids/app_viz.pid" "$OUT"
# [Co-developed with claude code -- Adam] judge r2 #4: rc 1 repeats on every `down` until the cause
# is removed (run_cells.sh stops the grid on it), so the error says what to fix.
has   "  🔴 and how to recover"                              "then run 'ndt down' again" "$OUT"
has   "  and the claim note names it"                        "app_viz.pid kept" "$(sed -n 's/^note=//p' "$FIX/.test_run/lab.claim")"
rm -f "$FIX/.test_run/apps"

# =============================================================================================
section "14. what 'down' may NOT delete: a symlink, and a group that is this shell's own"
# =============================================================================================
reset_fix; rm -f "$FIX/manifest.json"
DEAD="$(dead_pid)"
printf '%s\n' "$DEAD" > "$FIX/elsewhere.pid"
ln -s "$FIX/elsewhere.pid" "$FIX/.test_run/pids/app_viz.pid"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 a symlinked pidfile is never removed"              "yes" "$([[ -L "$FIX/.test_run/pids/app_viz.pid" ]] && echo yes || echo no)"
check "  nor what it points at"                              "present" "$([[ -e "$FIX/elsewhere.pid" ]] && echo present || echo absent)"
rm -f "$FIX/.test_run/pids/app_viz.pid" "$FIX/elsewhere.pid"
# This suite's own process group: the driven ndt is in it, so app_group_pids refuses to answer
# (rc 2) and nothing may be proved dead.
MYPG="$(awk '{ sub(/.*\) /, ""); print $3 }' "/proc/$$/stat")"
reset_fix; rm -f "$FIX/manifest.json"
DEAD="$(dead_pid)"
pidf app_viz.pid "$DEAD"; pidf app_viz.pgid "$MYPG"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 a pidfile whose group is this shell's own is never removed" "present" "$(present app_viz.pid)"

# =============================================================================================
section "15. the guard's edges: our own claim's measuring=, the dispatch, the record's shape"
# =============================================================================================
# Our OWN claim declaring a measurement has never refused a bring-up (P4's semantics, kept).
reset_fix; echo "0 14" > "$FIX/mn.seq"
write_claim "$US" "$FUTURE" "our own round" "sampling matrix, cell 2/8"
OUT="$(NDT_OWNER="$US" drive 'up_ovs 4')"
check "🔴 our own claim with measuring= does not refuse 'up'" "no" "$([[ "$(rc_of "$OUT")" == 5 ]] && echo yes || echo no)"
has   "  the bring-up ran"                                   "up ovs" "$(cat "$FIX/stack.log")"

# The dispatch itself -- the `case` block at the end of ndt, run as written -- so NDT_UP_WORDS is
# asserted the way an operator meets it: the retry line spells the command they typed.
DISPATCH="$(sed -n '/^case "\${1:-}" in$/,$p' "$NDT")"
[[ -n "$DISPATCH" ]] || { echo "  FAILED   no dispatch block in $NDT"; FAIL=$((FAIL+1)); }
reset_fix
write_claim "$THEM" "$FUTURE" "night round" ""
OUT="$(NDT_OWNER="$US" drive 'set -- up 4
'"$DISPATCH")"
check "🔴 dispatch: 'ndt up 4' under a foreign claim is 5"   "5" "$(rc_of "$OUT")"
has   "  its retry line is the command as typed"             "NDT_OWNER=$THEM ndt up 4" "$OUT"
has   "  and its override line too"                          "    ndt up 4 --force" "$OUT"
reset_fix; echo "0 14" > "$FIX/mn.seq"
write_claim "$THEM" "$FUTURE" "night round" ""
OUT="$(NDT_OWNER="$US" drive 'set -- up 4 --force
'"$DISPATCH")"
check "🔴 dispatch: 'ndt up 4 --force' builds"              "no" "$([[ "$(rc_of "$OUT")" == 5 ]] && echo yes || echo no)"
has   "  the fabric verb ran"                                "ovs-topo-4host" "$(cat "$FIX/sudo.log")"
check "  and the record carries the command as typed"        "ndt up 4 --force" "$(ovr_field command)"

# The read-back: the append "succeeds" into /dev/null and the line is not there afterwards.
reset_fix
write_claim "$THEM" "$FUTURE" "night round" ""
ln -s /dev/null "$OVR"
OUT="$(NDT_OWNER="$US" drive 'NDT_UP_FORCE=1; up_ovs 4')"
check "🔴 a record that does not read back is refused"      "5" "$(rc_of "$OUT")"
check "  and reached nothing"                                "$UNTOUCHED" "$(touched)"
rm -f "$OVR"

# TAB and newline inside a value must not add a field or a line: ten fields, one line.
reset_fix; echo "0 14" > "$FIX/mn.seq"
printf 'owner=%s\nexpires=%s\nnote=%s\nexclusive_cpu=no\nmeasuring=%s\n' \
    "$THEM" "$FUTURE" $'a\tnote\twith tabs' $'x\ty' > "$FIX/.test_run/lab.claim"
OUT="$(NDT_OWNER=$'us\twith a tab' FX_BUSY=$'iperf3 -c 10.0.0.2\tx\nmatrix.sh 2' drive 'NDT_UP_FORCE=1; up_ovs 4')"
check "🔴 one override is one line"                          "1" "$(overrides)"
check "  of exactly ten tab-separated fields"                "10" "$(awk -F'\t' '{print NF}' "$OVR" 2>/dev/null | head -1)"
check "  the tab in the note became a space"                 "a note with tabs" "$(ovr_field claim_note)"
check "  and the second process is counted, not a new line"  "iperf3 -c 10.0.0.2 x (+1 more)" "$(ovr_field running)"

# =============================================================================================
section "16. 'ndt help' says what the record means and every place the rules changed"
# =============================================================================================
HELP="$(bash "$NDT" help 2>&1)"
FLAT="$(tr -s ' \n' '  ' <<<"$HELP")"
has   "a --force with nothing to go past writes nothing"     "A --force with nothing to go past writes nothing" "$FLAT"
has   "🔴 F6: the line means '--force was used', not 'it came up'" 'THE LINE MEANS "--force WAS USED", NOT "IT CAME UP"' "$FLAT"
has   "down's rc 1 names the stale-entry failures"           "STALE registry entry could not be removed, or an app's window could not be written" "$FLAT"
has   "identity is stated per kind of file"                  "for the stack's own files, which carry no argv to compare, the pid alone" "$FLAT"
has   "clean's 3 says 'live'"                                "nothing in .test_run/pids/ naming a live process" "$FLAT"
# [Co-developed with claude code -- Adam] judge r2 #1: the new --check rc 1, in the status section,
# with its qualifier; and the manual saying the same, and saying what the code does about a
# recycled number (judge r2 #5: stale BEFORE the group is asked).
has   "🔴 status: a recycled stack pidfile is a --check problem, rc 1 only with a baseline" \
      "(a recycled number) is stale too, and a --check problem: rc 1 while a baseline exists; with none the answer is still 3" "$FLAT"
MANUAL="$HERE/../../doc/2026-08-17_testing-manual.md"
has   "🔴 the manual says the same about --check"            "有 baseline（\`.test_run/up.target\`）時 rc 1，沒有時照舊 3" "$(cat "$MANUAL" 2>/dev/null)"
has   "🔴 the manual: a recycled number is stale without asking the group" "**直接**判 stale，不問 group" "$(cat "$MANUAL" 2>/dev/null)"

# =============================================================================================
section "17. 🔴 a recycled stack number is a --check problem: rc 1 with a baseline, 3 without"
# =============================================================================================
# [Co-developed with claude code -- Adam]
# Judge's #1 on e1420df2 (orchestrator round 3). F8 made a kernel.pid whose live pid started after
# the file was written a `stale pidfile` in the pidfiles row, and that row feeds --check's problem
# list -- so `status --check` went from 0 to 1 on such a lab. That is only true while a baseline
# exists: with no .test_run/up.target the report is 3 whatever the problem list says. The baseline
# comparison itself is test_ndt_status_check_baseline.sh's subject, so here check_up_target
# answers only "is there a baseline" (0) or "none" (3), from the file, and everything else in
# cmd_status runs for real.
CHECK_STUB='check_up_target() { UP_TARGET_PROBLEMS=(); [[ -f "$REPO/.test_run/up.target" ]] || return 3; return 0; }'
DAEMON="$(spawn "some-daemon")"
reset_fix; rm -f "$KNOB"
printf 'plane=ovs\n' > "$FIX/.test_run/up.target"
pidf kernel.pid "$DAEMON"
touch -d "@$(( $(date +%s) - 600 ))" "$FIX/.test_run/pids/kernel.pid"
OUT="$(drive "$CHECK_STUB"'
cmd_status --check')"
check "🔴 with a baseline, a recycled kernel.pid makes --check rc 1" "1" "$(rc_of "$OUT")"
has   "  and it is named in the problem list"                "- .test_run/pids/kernel.pid: stale pidfile (pid $DAEMON is alive, but that process started" "$OUT"
# The control: the same live process, its pidfile written after it started -- the ordinary state.
reset_fix; rm -f "$KNOB"
printf 'plane=ovs\n' > "$FIX/.test_run/up.target"
pidf kernel.pid "$DAEMON"
OUT="$(drive "$CHECK_STUB"'
cmd_status --check')"
check "🔴 control: the same pid written after it started leaves --check at 0" "0" "$(rc_of "$OUT")"
# No baseline: 3, whatever the problem list holds -- the qualifier.
reset_fix; rm -f "$KNOB"
pidf kernel.pid "$DAEMON"
touch -d "@$(( $(date +%s) - 600 ))" "$FIX/.test_run/pids/kernel.pid"
OUT="$(drive "$CHECK_STUB"'
cmd_status --check')"
check "🔴 without a baseline the answer is still 3"          "3" "$(rc_of "$OUT")"
has   "  the recycled pidfile is still listed, under 'everything else'" "kernel.pid: stale pidfile (pid $DAEMON is alive" "$OUT"
kill_fixture "$DAEMON"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
