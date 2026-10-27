#!/usr/bin/env bash
#
# Who makes .test_run/logs, and does `ndt up` notice when it cannot write there?
#
# [Co-developed with claude code -- Adam]
#
# The defect (2026-10-26, fresh VM, a checkout with no .test_run/logs yet): `ndt up p4 4` runs
# `sudo ndtwin-lab topo-start`, and the bridge -- root -- was the first thing to need the
# directory, so its log made it root:root 755 (p4_proxy/mininet/topo_log.py). stack.sh, running
# as the user, then could not create p4_proxy.log there:
#
#     stack.sh: line 588: .../.test_run/logs/p4_proxy.log: Permission denied
#
# and the proxy never started. A run that removed only logs/ and changed nothing else
# reproduced it. `.test_run` itself was the user's (made by `ndt claim`).
#
# The fake below is what makes that reproducible without root: the `topo-start` stub does what
# the bridge's log did -- if logs/ is missing it creates it in a state this user cannot write
# (mode 555 stands in for "root-owned") -- and the fake stack.sh does what stack.sh does, which is
# to create p4_proxy.log there and fail when it cannot. Everything between them is the real `ndt`.
#
# Same seam as tests/shell/test_ndt_up_down_robust.sh: `ndt` is sourced, REPO/LAB/STACK point
# into a temp dir, `sudo` and `sleep` are shell functions. No root, no lab, no port.
#
# Run:  bash tests/shell/test_ndt_run_logs_dir.sh
#       NDT_UNDER_TEST=<copy> bash tests/shell/test_ndt_run_logs_dir.sh   (gate)
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 2; }
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

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-runlogs-XXXXXX")"
# The 555 directories are this suite's own; give write back before removing them.
trap 'chmod -R u+w "$FIX" 2>/dev/null; rm -rf "$FIX"' EXIT
export FIX
mkdir -p "$FIX/.test_run/pids" "$FIX/setting" "$FIX/p4_proxy/mininet" \
         "$FIX/p4_proxy/venv/bin" "$FIX/p4_proxy/p4_src/build" "$FIX/build/bin" "$FIX/tools/test_workflow"
: > "$FIX/build/bin/ndtwin_kernel";            chmod +x "$FIX/build/bin/ndtwin_kernel"
: > "$FIX/p4_proxy/venv/bin/python";           chmod +x "$FIX/p4_proxy/venv/bin/python"
echo '{}' > "$FIX/p4_proxy/p4_src/build/ndtwin_switch.json"
echo 4 > "$FIX/p4_proxy/mininet/host_count_override"
echo '{"switches":[]}' > "$FIX/manifest.json"
printf 'helper\n' > "$FIX/installed-ndtwin-lab"; cp "$FIX/installed-ndtwin-lab" "$FIX/tools/test_workflow/ndtwin-lab"

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

# The fake stack.sh does the one thing this suite is about: it writes its component logs under
# .test_run/logs as the calling user, exactly as stack.sh's start_bg does, and fails like it.
cat > "$FIX/stack.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/stack.log"
logs="$FIX/.test_run/logs"
case "$1 ${2:-}" in
    "up p4")
        echo "[1/3] data plane"
        mkdir -p "$logs"
        if ! : > "$logs/p4_proxy.log"; then
            echo "proxy did not open :8081; see $logs/p4_proxy.log"; exit 1
        fi
        echo "started"; exit 0 ;;
    "up ovs")
        echo "[1/3] control plane (Ryu)"
        mkdir -p "$logs"
        : > "$logs/ryu.log" || { echo "Ryu did not open :8080"; exit 1; }
        echo "[2/3] data plane (Mininet, needs sudo)"
        read -r _ || true
        echo "converged"; exit 0 ;;
    "down"*) echo "stopped kernel"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$FIX/stack.sh"

reset_fix() {
    chmod -R u+w "$FIX/.test_run" 2>/dev/null
    rm -rf "$FIX/.test_run/logs" "$FIX/.test_run/up.target" "$FIX/sudo.log" "$FIX/stack.log" "$FIX/logs.at_topo_start"
    rm -f "$FIX/.test_run/pids/"*
    echo 4 > "$FIX/p4_proxy/mininet/host_count_override"
    echo '{"switches":[]}' > "$FIX/manifest.json"
    : > "$FIX/sudo.log"; : > "$FIX/stack.log"
}

STUBS='
REPO="'"$FIX"'"
HERE="'"$FIX"'/tools/test_workflow"
LAB="'"$FIX"'/installed-ndtwin-lab"
STACK="'"$FIX"'/stack.sh"
MANIFEST="'"$FIX"'/manifest.json"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
LAB_CONF="'"$FIX"'/etc/ndtwin-lab.conf"
LAB_DEFAULT_KERNEL_DIR="'"$FIX"'"
HB_PIDFILE="'"$FIX"'/run/heartbeat.pid"; HB_REPORT="'"$FIX"'/run/heartbeat.json"
sudo() {
    local a args=()
    for a in "$@"; do [[ "$a" == -n ]] && continue; args+=("$a"); done
    local verb="${args[1]:-none}"
    printf "%s\n" "${args[*]:1}" >> "'"$FIX"'/sudo.log"
    if [[ "$verb" == topo-start ]]; then
        local d="'"$FIX"'/.test_run/logs"
        # What the directory looked like at the moment root was handed the bridge.
        if [[ -d "$d" ]]; then
            printf "exists owner=%s writable=%s\n" "$(stat -c %u "$d")" \
                "$([[ -w "$d" ]] && echo yes || echo no)" > "'"$FIX"'/logs.at_topo_start"
        else
            echo missing > "'"$FIX"'/logs.at_topo_start"
            # The bridge as root: os.makedirs, then topo.log, in a directory the user cannot
            # write afterwards. 555 is that directory as this user sees it.
            mkdir -p "$d"; : > "$d/topo.log"; chmod 555 "$d"
        fi
        echo "{\"switches\":[]}" > "'"$FIX"'/manifest.json"
    fi
    [[ "$verb" == cleanup ]] && rm -f "'"$FIX"'/manifest.json"
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
bmv2_count() { seq_read "'"$FIX"'/bmv2.seq" 10; }
mn_count()   { echo "${FX_MN:-0}"; }
fabric_host_count() { echo 4; }
topo_session() { return 1; }
foreign_claim() { :; }
in_flight() { :; }
guard_no_live_ovs() { return 0; }
bmv2_binary() { echo fixture-bmv2; }
sample_rate() { echo 256; }
stale_pipeline() { return 1; }
source_ahead_of_build() { return 1; }
verify_p4() { return 0; }
verify_ovs() { return 0; }
app_probe() { APP_STATE=not-running; }
check_up_target() { UP_TARGET_PROBLEMS=(); return 0; }
ndt_sudo_report() { return 0; }
claim_line() { echo none; }
git_lines() { :; }
ovs_bridge_count() { echo 0; }
ovs_daemon_running() { return 1; }
netem_count() { echo 0; }
port_open() { return 1; }
http_get_graph() { :; }
curl() { return 1; }
ndt_port_open() { return 1; }
ndt_port_listener_pids() { return 0; }
'

drive() {   # drive <shell-code>  -> its output plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of_out() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

# ==========================================================================================
section "1. a checkout with no .test_run/logs: the user makes it, before root is asked to"
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
OUT="$(drive 'up_p4 4')"
check "🔴 logs/ existed when topo-start was called, writable by this user" \
      "exists owner=$(id -u) writable=yes" "$(cat "$FIX/logs.at_topo_start" 2>/dev/null || echo 'topo-start was never called')"
check "🔴 so the proxy's log could be written and the bring-up finished" "0" "$(rc_of_out "$OUT")"
hasnt "  and stack.sh did not fail on its log"             "proxy did not open" "$OUT"
check "  and p4_proxy.log is there"                       yes \
      "$([[ -f "$FIX/.test_run/logs/p4_proxy.log" ]] && echo yes || echo no)"
hasnt "  and nothing was refused"                         "refusing to build" "$OUT"

# ==========================================================================================
section "2. a logs/ this user cannot write (left by an older run) is refused before anything is built"
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
mkdir -p "$FIX/.test_run/logs"; : > "$FIX/.test_run/logs/topo.log"; chmod 555 "$FIX/.test_run/logs"
OUT="$(drive 'up_p4 4')"
check "🔴 ndt up p4 refuses"                               "1" "$(rc_of_out "$OUT")"
has   "  and names the directory"                         "$FIX/.test_run/logs is not writable" "$OUT"
has   "  and says what to do without root"                "mv $FIX/.test_run/logs $FIX/.test_run/logs.root-owned." "$OUT"
check "  and the target is stamped, so it cannot land inside an earlier one" "1" \
      "$(grep -cE "mv [^ ]+/logs [^ ]+/logs\.root-owned\.[0-9]{8}T[0-9]{6}Z$" <<<"$OUT")"
check "🔴 topo-start was never called"                     "0" "$(grep -c topo-start "$FIX/sudo.log")"
check "  and stack.sh was never called"                   "0" "$(grep -c . "$FIX/stack.log")"
check "  and the host knob is untouched"                  "4" "$(cat "$FIX/p4_proxy/mininet/host_count_override")"

# A logs/ that cannot even be created (.test_run itself is not writable): refused, and the
# move-it-aside hint is not offered, because there is nothing to move and nowhere to move it.
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
chmod 555 "$FIX/.test_run"
OUT="$(drive 'up_p4 4')"
chmod 755 "$FIX/.test_run"
check "  a logs/ that cannot be created is refused too"    "1" "$(rc_of_out "$OUT")"
has   "    and says it could not be created"              "does not exist and could not be created" "$OUT"
hasnt "    and offers no mv for a directory that is not there" "mv $FIX" "$OUT"
check "    and topo-start was never called"               "0" "$(grep -c topo-start "$FIX/sudo.log")"

# The same directory blocks the OVS plane in the same way: stack.sh writes ryu.log there.
reset_fix
mkdir -p "$FIX/.test_run/logs"; chmod 555 "$FIX/.test_run/logs"
OUT="$(drive 'up_ovs 4')"
check "  ndt up ovs refuses on it too"                    "1" "$(rc_of_out "$OUT")"
has   "    with the same sentence"                        "$FIX/.test_run/logs is not writable" "$OUT"
check "    and stack.sh was never called"                 "0" "$(grep -c . "$FIX/stack.log")"

# ==========================================================================================
section "3. an existing, writable logs/ is left alone (the ordinary case)"
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
mkdir -p "$FIX/.test_run/logs"; echo "an older proxy log" > "$FIX/.test_run/logs/kernel.log"
OUT="$(drive 'up_p4 4')"
check "the bring-up finishes"                             "0" "$(rc_of_out "$OUT")"
check "  and an existing log in it is not disturbed"      "an older proxy log" "$(cat "$FIX/.test_run/logs/kernel.log")"

printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
[[ $FAIL -eq 0 ]]
