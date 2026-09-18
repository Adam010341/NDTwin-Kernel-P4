#!/usr/bin/env bash
#
# `ndt up p4 --app <dir>` and the app-package knob's whole life, driven OFFLINE.
#
# [Co-developed with claude code -- Adam]
#
# WHAT THIS IS. p4_proxy/mininet/app_package_override decides which fabric the next `ndt up
# p4`, the next hand-run p4_testbed_topo.py and the next proxy build. `ndt` is its only writer
# (TICKET-P1 §1), so every one of its states -- written, cleared, refused, and the
# present-but-empty one that makes the proxy refuse to start -- is reachable only through this
# command, and none of them can be measured on the night grid: they all need a lab.
#
# So the file is driven the way tests/shell/test_ndt_down_claim_guard.sh drives the teardown
# guard: `ndt` returns early when sourced, the functions are then called directly, and every
# reading that would describe THIS machine is answered from a fixture. Nothing here reaches
# root, a port, Mininet or the real lab.
#
# 🔴 WHAT MUST NOT HAPPEN IS HALF THE SUBJECT, twice over:
#   * a REFUSED bring-up must not have moved the knob. `ndt up p4 --app <bad package>` that
#     wrote the file on its way to saying no is the ROLE-9 defect (a refusal quoting a state
#     only the refusal had created) with a different file in it, so every refusal cell asserts
#     the knob is byte-identical to what it was AND that stack.sh and sudo were never reached.
#   * a knob must never be left PRESENT AND EMPTY. app_package.read_knob refuses that state
#     outright (P1-A §4-3) -- it is a half-finished write, not a default -- so the write path
#     is asserted to leave a directive line, and the clear path to leave no file.
#
# 🔴 THE CONTROL that keeps the two above from being sentences the harness always says: the
# proceeding cell asserts the numbers POSITIVELY (`sudo=<n> stack=1`), so a mis-spelled log
# path could not make every "nothing was touched" cell pass over a guard somebody deleted.
#
# Run:  bash tests/shell/test_ndt_app_package.sh
# Env:  NDT_UNDER_TEST=<path>   (tests/shell/mutate_ndt_app_package.sh points it at a copy)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
REAL_REPO="$(cd "$HERE/../.." && pwd)"
[[ -r "$NDT" ]] || { echo "  FAILED   no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 1; }

PASS=0; FAIL=0
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}
has()   { /usr/bin/grep -qF -- "$2" <<<"$3" && { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; } \
          || { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             no match for: [%s]\n' "$1" "$2"; }; }
hasnt() { /usr/bin/grep -qF -- "$2" <<<"$3" && { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             unexpected: [%s]\n' "$1" "$2"; } \
          || { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-app-pkg-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT INT TERM
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs" "$FIX/tools/test_workflow" \
         "$FIX/p4_proxy/mininet" "$FIX/setting" "$FIX/etc"
echo '{"switches":[{"dpid":1}]}' > "$FIX/manifest.json"
# The real 4-host model, so the NO-package cells reach the same code the package cells do:
# without it topo_for_hosts's glob branch finds nothing in an empty setting/ and `up_p4 4`
# refuses one screen above the knob, which is the line those cells are about.
cp "$REAL_REPO/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json" "$FIX/setting/" 2>/dev/null
printf 'helper\n' > "$FIX/installed-ndtwin-lab"
KNOB="$FIX/p4_proxy/mininet/app_package_override"

# --- two package fixtures ---------------------------------------------------------------
#
# 🔴 SHAPED LIKE THE REAL ONES AND NOT COPIES OF THEM. The converter's output lives outside
# version control (.test_run/packages/, TICKET-P1C §0), so a test that read it would be green
# or absent depending on whether somebody had run convert.py that day. What `ndt` reads out of
# a package is exactly three things -- ndtwin/topology.json's host and switch counts, its host
# addresses, and package.json's control_plane.mode -- so those are what these carry, at the
# two shapes that matter: FOUR hosts on FOUR switches under NDTwin's own control plane, and
# THREE hosts on THREE switches under an external one. Three is not a multiple of four, which
# is the number host_count_buildable refuses and the reason exercises/p4runtime needs the
# package layout to be exempt from it.
mkpkg() {   # mkpkg <dir> <mode> <n-hosts> <n-switches>
    local d="$1" mode="$2" nh="$3" ns="$4"
    mkdir -p "$d/ndtwin"
    python3 - "$d" "$mode" "$nh" "$ns" <<'PY'
import json, os, sys
d, mode, nh, ns = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
nodes, edges, hosts = [], [], {}
for i in range(1, ns + 1):
    nodes.append({"device_name": "s%d" % i, "bridge_name": "s%d" % i, "dpid": i,
                  "vertex_type": 0, "device_layer": 2, "ip": ["192.168.123.%d" % (10 + i)],
                  "mac": 0, "ecmp_groups": []})
for i in range(1, nh + 1):
    ip = "10.0.%d.%d" % (i, i)
    nodes.append({"device_name": "h%d" % i, "dpid": 0, "vertex_type": 1,
                  "device_layer": 3, "ip": [ip], "mac": i})
    hosts["h%d" % i] = {"ip": ip, "prefix_len": 24,
                        "mac": "08:00:00:00:%02d:%02d" % (i, i * 11), "commands": []}
    sw = (i - 1) % ns + 1
    edges.append({"src_dpid": 0, "src_interface": 1, "dst_dpid": sw, "dst_interface": 1})
    edges.append({"src_dpid": sw, "src_interface": 1, "dst_dpid": 0, "dst_interface": 1})
json.dump({"nodes": nodes, "edges": edges, "links": []},
          open(os.path.join(d, "ndtwin", "topology.json"), "w"), indent=2, sort_keys=True)
json.dump({"format": 1, "name": os.path.basename(d), "topology": "ndtwin/topology.json",
           "hosts": hosts, "switches": {str(i): {"name": "s%d" % i, "pipeline": None,
                                                 "entries": None} for i in range(1, ns + 1)},
           "control_plane": {"mode": mode, "election_id": [0, 65535],
                             "grpc_base": 30050, "device_id": "dpid"},
           "bmv2": {"cpu_port": 255}, "links": []},
          open(os.path.join(d, "package.json"), "w"), indent=2, sort_keys=True)
PY
}
PKG_OK="$FIX/packages/four"        ; mkpkg "$PKG_OK" ndtwin   4 4
PKG_EXT="$FIX/packages/three-ext"  ; mkpkg "$PKG_EXT" external 3 3
PKG_BAD="$FIX/packages/redflag"    ; mkpkg "$PKG_BAD" ndtwin   4 4

# A recording fake stack.sh. Its log is the evidence for "nothing was built". `2/3` is what
# up_ovs waits for on its stdout before it will go on; $STACK_FAIL switches it to the failing
# half, which is what section 12 drives.
cat > "$FIX/stack.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STACK_LOG"
printf 'TOPO_P4=%s\n' "${TOPO_P4:-}" >> "$STACK_LOG"
if [[ -e "$STACK_FAIL" ]]; then
    echo "  proxy did not open :8081; see .test_run/logs/p4_proxy.log"
    exit 1
fi
echo "[2/3] data plane (Mininet, needs sudo)"
echo "started p4_proxy"
echo "started kernel"
exit 0
FAKE
chmod +x "$FIX/stack.sh"
export STACK_FAIL="$FIX/stack-must-fail"

# The OVS-plane model up_ovs's topo_for_hosts globs for. Same shape as the P4 one -- what that
# reader counts is hosts -- but under the OVS family name, because mixing the two families is
# the mistake topo_for_hosts exists to prevent.
cp "$REAL_REPO/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json" \
   "$FIX/setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json" 2>/dev/null

# --- the pre-flight stand-in --------------------------------------------------------------
#
# tools/p4_exercise/preflight.py needs protobuf, which only the proxy's venv has; a suite that
# required it would be a suite that skips on any machine without the venv built, and a skipped
# gate cell is a survivor. So `ndt` is pointed at a stand-in through the two seams it already
# has (P4_PROXY_PY, NDT_APP_PREFLIGHT) and the stand-in's verdict is switched by a file.
# Section 9 asserts separately that the DEFAULTS behind those seams are the real interpreter
# and the real tool, which is the only part of this a stand-in cannot say.
cat > "$FIX/fakepy" <<'FAKE'
#!/usr/bin/env bash
exec bash "$@"
FAKE
chmod +x "$FIX/fakepy"
cat > "$FIX/preflight.sh" <<'FAKE'
#!/usr/bin/env bash
echo "pre-flight: $1"
if [[ -e "$PREFLIGHT_FAIL" ]]; then
    echo "  FAIL  entries match p4info         16 problem(s); first: s1 entry 1 is TERNARY"
    echo "FAIL -- 1 check(s) failed; do NOT bring this package up"
    exit 1
fi
echo "  PASS  format                       1"
echo "PASS -- every check passed"
exit 0
FAKE
chmod +x "$FIX/preflight.sh"
export PREFLIGHT_FAIL="$FIX/preflight-must-fail"

# --- the seam -------------------------------------------------------------------------------
# Everything that would describe THIS machine is replaced. The app knob readers and writers,
# set_host_count, up_p4's --app block, verify_p4, cmd_down's and cmd_clean's clear, the status
# row and up_take_app_flag are left REAL -- they are the subject.
STUBS='
REPO="'"$FIX"'"
HERE="'"$FIX"'/tools/test_workflow"
LAB="'"$FIX"'/installed-ndtwin-lab"
STACK="'"$FIX"'/stack.sh"
MANIFEST="'"$FIX"'/manifest.json"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
LAB_CONF="'"$FIX"'/etc/ndtwin-lab.conf"
LAB_DEFAULT_KERNEL_DIR="'"$FIX"'"
export STACK_LOG="'"$FIX"'/stack.log"
export P4_PROXY_PY="'"$FIX"'/fakepy"
export NDT_APP_PREFLIGHT="'"$FIX"'/preflight.sh"
export NDT_PROXY_LOG="'"$FIX"'/.test_run/logs/p4_proxy.log"
export NDT_TOPO_LOG="'"$FIX"'/.test_run/logs/topo.log"
sudo() {
    printf "sudo %s\n" "$*" >> "'"$FIX"'/sudo.log"
    case "$*" in *topo-start*) echo 99 > "'"$FIX"'/bmv2_count" ;; esac
    return 0
}
sleep() { :; }
bmv2_count() { cat "'"$FIX"'/bmv2_count" 2>/dev/null || echo 0; }
mn_count() { echo 0; }
fabric_host_count() { echo 0; }
topo_session() { return 1; }
foreign_claim() { :; }
in_flight() { :; }
guard_no_live_ovs() { return 0; }
stale_pipeline() { return 1; }
preflight() { return 0; }
claim_note_up() { :; }
bmv2_binary() { echo "simple_switch_grpc (stub)"; }
sample_rate() { echo 256; }
rate_label() { echo "1/256"; }
wait_reaped() { return 0; }
app_probe() { APP_STATE=not-running; APP_LIVE_PIDS=(); }
mark_teardown_start() { return 0; }
mark_teardown_end() { return 0; }
lab_subject() { :; }
stack_down_deferrable_ports() { :; }
ndt_port_residue() { :; }
teardown_in_flight() { return 1; }
curl() { return 1; }
git_lines() { :; }
port_open() { return 1; }
'

# verify_p4 is stubbed for every `up_p4` cell -- what those measure is what reaches it -- and
# left REAL for section 10, which is about the function itself. Two stub sets rather than one
# with an `unset -f`, because unsetting a function does not bring the original back.
STUBS_V="$STUBS"
STUBS="$STUBS"'
verify_p4() { echo "VERIFY_P4 topo=$1 want_paths=$2 mode=${3:-<none>}"; return 0; }
'

_drive() {   # _drive <stub-set> <shell-code> -> its output plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$1
$2
echo \"RC=\$?\"" 2>&1
}
# 🔴 EVERY variable a cell wants `ndt` to see goes INSIDE the driven code, never in front of
# `drive`. `ndt` initialises NDT_APP_DIR="" at source time (it has to, under set -u), so a
# value exported from out here would be wiped by the source and every --app cell would have
# silently measured the no-package branch -- which is exactly what the first draft of this file
# did: 43 red cells, none of them about `ndt`.
drive()   { _drive "$STUBS"   "$1"; }
drive_v() { _drive "$STUBS_V" "$1"; }
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
q() { printf '%q' "$1"; }

reset_fix() {
    rm -f "$FIX/sudo.log" "$FIX/stack.log" "$FIX/bmv2_count" "$PREFLIGHT_FAIL" "$STACK_FAIL" \
          "$KNOB" "$FIX/.test_run/up.target" "$FIX/.test_run/host_count_override.pre-up" \
          "$FIX/.test_run/logs/p4_proxy.log" "$FIX/.test_run/logs/topo.log"
    : > "$FIX/sudo.log"; : > "$FIX/stack.log"
    printf '4\n' > "$FIX/p4_proxy/mininet/host_count_override"
}
count_lines() {
    local n; n="$(/usr/bin/grep -c . "$1" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}
# 🔴 `grep -c .` exits 1 when the count is 0, so `|| echo 0` appends a SECOND zero rather
# than supplying a missing one. count_lines is the shape that does not; this counts stack.sh
# invocations through the same reader. (The note is tests/shell/test_ndt_down_claim_guard.sh's,
# and this file reproduced the bug before reading it.)
stack_ups() {
    local n; n="$(/usr/bin/grep -c '^up p4' "$FIX/stack.log" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}
touched() { printf 'sudo=%s stack=%s' "$(count_lines "$FIX/sudo.log")" "$(stack_ups)"; }
knob_state() {   # absent | empty | <the directory it names>
    [[ -e "$KNOB" ]] || { echo absent; return; }
    local line
    while read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        printf '%s' "$line"; return
    done < "$KNOB"
    echo empty
}

# =============================================================================================
section "1. --app writes the knob, and writes it the way the proxy's reader demands"
# =============================================================================================
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
check "🔴 a package that passes pre-flight comes up"      "0" "$(rc_of "$OUT")"
check "🔴 and the knob names it"                          "$PKG_OK" "$(knob_state)"
has   "  the write is announced"                          "app package set: $PKG_OK" "$OUT"
has   "  the pre-flight table is printed"                 "PASS -- every check passed" "$OUT"
has   "  the banner names the package and its mode"       "app package  $PKG_OK (mode ndtwin, 4 switch(es))" "$OUT"
# 🔴 ABSOLUTE, and the knob's reader refuses anything else: the proxy is started from p4_proxy/
# and the topology script from anywhere, so a relative line would name two directories.
check "🔴 the line is absolute"                           "1" \
      "$(/usr/bin/grep -c '^/' <<<"$(knob_state)")"
has   "  and it carries the note saying who wrote it"     "# written by ndt up p4 --app at" "$(cat "$KNOB")"
check "  the note is a comment, so the reader skips it"   "2" "$(/usr/bin/grep -c . "$KNOB")"

# The model decides the size. Not the command line, and not the value the knob happened to
# hold: `hosts` is what record_up_target writes and what every check downstream compares to.
check "🔴 host_count_override became the MODEL's host count" "4" \
      "$(sed -n '1p' "$FIX/p4_proxy/mininet/host_count_override")"
has   "  the kernel is handed the package's model"        "TOPO_P4=$PKG_OK/ndtwin/topology.json" "$(cat "$FIX/stack.log")"
has   "  and so is verify_p4"                             "VERIFY_P4 topo=$PKG_OK/ndtwin/topology.json" "$OUT"
has   "  which is told the control-plane mode"            "mode=ndtwin" "$OUT"
# 🔴 THE INSTRUMENT'S OWN CONTROL. Every refusal cell below rests on touched() reading
# `sudo=0 stack=0`, and a touched() that could only ever say that -- a mis-spelled log path, a
# counter that lost its input -- would make all of them pass over a guard somebody had deleted.
# The numbers are what a bring-up that really ran reaches: one `sudo -n $LAB topo-start`, one
# `stack.sh up p4`.
check "🔴 and the machine WAS reached -- the instrument can read non-zero" "sudo=1 stack=1" "$(touched)"

# =============================================================================================
section "2. 🔴 three hosts: the layout rule a package replaces"
# =============================================================================================
# exercises/p4runtime is three hosts on three switches. host_count_buildable refuses 3 -- and
# it is right to, for ntg_bmv2_topo.py's four-way splitter, which is the layout a package does
# not use. A package names every host and the port it hangs off.
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_EXT"); up_p4")"
check "🔴 a three-host package is built, not refused"     "0" "$(rc_of "$OUT")"
check "  and the knob names it"                           "$PKG_EXT" "$(knob_state)"
check "🔴 host_count_override is 3, which the splitter rule forbids" "3" \
      "$(sed -n '1p' "$FIX/p4_proxy/mininet/host_count_override")"
has   "  the switch count came from the model too"        "(mode external, 3 switch(es))" "$OUT"
has   "  and the mode reached verify_p4"                  "mode=external" "$OUT"
# The control for that exemption: the splitter path still refuses 3, or the rule would have
# been deleted rather than scoped.
printf '4\n' > "$FIX/p4_proxy/mininet/host_count_override"
OUT="$(drive 'set_host_count 3')"
check "🔴 the SPLITTER path still refuses 3"              "1" "$(rc_of "$OUT")"
has   "  naming the rule"                                 "host count must be a multiple of 4" "$OUT"
printf '4\n' > "$FIX/p4_proxy/mininet/host_count_override"
OUT="$(drive 'set_host_count 3 package')"
check "  and the package path takes it"                   "0" "$(rc_of "$OUT")"

# =============================================================================================
section "3. 🔴 a pre-flight FAIL refuses, and moves nothing"
# =============================================================================================
reset_fix
: > "$PREFLIGHT_FAIL"
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_BAD"); up_p4")"
check "🔴 rc 5 -- a GUARD REFUSED and nothing was built"  "5" "$(rc_of "$OUT")"
has   "  it says so"                                      "refusing to build: the app package did not pass pre-flight" "$OUT"
has   "🔴 and the table is printed VERBATIM"              "FAIL  entries match p4info         16 problem(s); first: s1 entry 1 is TERNARY" "$OUT"
has   "  with the tool's own verdict line"                "FAIL -- 1 check(s) failed; do NOT bring this package up" "$OUT"
check "🔴 the knob was NOT written"                       "absent" "$(knob_state)"
has   "  and the refusal SAYS the knob is unchanged"      "is UNCHANGED at absent" "$OUT"
check "🔴 host_count_override was not moved either"       "4" \
      "$(sed -n '1p' "$FIX/p4_proxy/mininet/host_count_override")"
check "🔴 NOTHING on the machine was reached"             "sudo=0 stack=0" "$(touched)"
check "  and no up.target was recorded"                   "0" \
      "$([[ -e "$FIX/.test_run/up.target" ]] && echo 1 || echo 0)"
rm -f "$PREFLIGHT_FAIL"

# A directory that is not a package at all: refused before pre-flight is even reached, because
# the model file is what the kernel is handed and what the fabric is built from.
reset_fix
mkdir -p "$FIX/packages/empty-dir"
OUT="$(drive "NDT_APP_DIR=$(q "$FIX/packages/empty-dir"); up_p4")"
check "a directory with no ndtwin/topology.json is refused" "5" "$(rc_of "$OUT")"
has   "  saying which file is missing"                    "carries no ndtwin/topology.json" "$OUT"
check "  and wrote nothing"                               "absent" "$(knob_state)"

# =============================================================================================
section "4. 🔴 the knob's other end -- every command that ends a run clears it"
# =============================================================================================
# A knob that outlives its fabric is read by the next `ndt up p4`, the next hand-run
# p4_testbed_topo.py and the next proxy. Leaving one is how a baseline round silently builds
# somebody's exercise while every banner says baseline.
plant_knob() { printf '# written by ndt up p4 --app at 2026-09-17T00:00:00Z\n%s\n' "$PKG_OK" > "$KNOB"; }

reset_fix; plant_knob
OUT="$(drive 'up_p4 4')"
check "🔴 'ndt up p4 4' with no --app clears it"          "absent" "$(knob_state)"
has   "  and names what it removed"                       "app package cleared: $PKG_OK" "$OUT"
has   "  the banner says the fabric is the baseline one"  "app package  none (baseline fabric)" "$OUT"

reset_fix; plant_knob
OUT="$(NDT_OWNER=t drive 'cmd_down')"
check "🔴 'ndt down' clears it"                           "absent" "$(knob_state)"
has   "  and names what it removed"                       "app package cleared: $PKG_OK" "$OUT"

reset_fix; plant_knob
OUT="$(NDT_OWNER=t drive 'cmd_clean')"
check "🔴 'ndt clean' clears it"                          "absent" "$(knob_state)"
has   "  and names what it removed"                       "app package cleared: $PKG_OK" "$OUT"

# 🔴 THE OVS PLANE TOO, through the real up_ovs. The knob is P4-only in the sense that only P4
# readers act on it -- which is exactly why an OVS round is where a stale one survives
# unnoticed, and the next `ndt up p4 4` in this checkout then builds somebody's exercise under
# a banner reading `app package  none`. up_ovs is driven for real and is expected to fail later
# on (the stubbed fabric has no hosts); what this cell is about is the file, and up_ovs's own
# rollback cannot be what removed it -- APP_KNOB_WRITTEN is empty on this plane.
reset_fix; plant_knob
OUT="$(drive 'up_ovs 4')"
check "🔴 'ndt up ovs 4' clears it as well"               "absent" "$(knob_state)"
has   "  and names what it removed"                       "app package cleared: $PKG_OK" "$OUT"
has   "  saying it is this plane that does not use one"   "this 'ndt up ovs' does not use one" "$OUT"

# 🔴 The rollback. A bring-up that wrote the knob and then failed must not leave it: the
# fabric it describes has just been taken back down.
reset_fix
OUT="$(drive "app_knob_write $(q "$PKG_OK") >/dev/null; rollback_up 'test'")"
check "🔴 a rolled-back bring-up clears the knob it wrote" "absent" "$(knob_state)"
has   "  saying why"                                      "app package cleared: $PKG_OK -- this bring-up was rolled back" "$OUT"
# The control: a rollback must not remove a knob this run never wrote. APP_KNOB_WRITTEN is
# what tells the two apart, and without it "clear on rollback" would be "clear whatever is
# there", which would undo another session's state from a command that failed.
reset_fix; plant_knob
OUT="$(drive 'rollback_up "test"')"
check "🔴 but NOT one this run did not write"             "$PKG_OK" "$(knob_state)"

# =============================================================================================
section "5. 🔴 never a knob that is present and empty"
# =============================================================================================
# app_package.read_knob refuses a file with no directive line outright: it is a half-finished
# write, not a default, and a proxy that answered "baseline" to it would silently run the wrong
# fabric. So the write is a rename over a complete file and the clear removes the file.
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
check "after a write the knob names a package"            "$PKG_OK" "$(knob_state)"
check "  and no temp file is left beside it"              "0" \
      "$(find "$FIX/p4_proxy/mininet" -name 'app_package_override.ndt.*' | wc -l | tr -d ' ')"
reset_fix
printf '# a comment and nothing else\n' > "$KNOB"
check "the harness can read the empty state at all"       "empty" "$(knob_state)"
OUT="$(drive 'app_knob_state')"
has   "  and so can ndt"                                  "empty" "$OUT"
OUT="$(NDT_OWNER=t drive 'cmd_down')"
check "🔴 'ndt down' removes an empty knob too"           "absent" "$(knob_state)"
has   "  saying what that state was"                      "the knob existed but named none" "$OUT"

# =============================================================================================
section "6. 🔴 --app is a P4 flag, and the flag parser is its own subject"
# =============================================================================================
OUT="$(drive 'up_take_app_flag p4 --app "'"$PKG_OK"'"; echo "DIR=$NDT_APP_DIR"; echo "LEFT=${NDT_UP_ARGV[*]}"')"
has   "--app <dir> is lifted out of argv"                 "DIR=$PKG_OK" "$OUT"
has   "  and the plane is left behind for resolve_up_target" "LEFT=p4" "$OUT"
OUT="$(drive 'up_take_app_flag p4 --app="'"$PKG_OK"'"; echo "DIR=$NDT_APP_DIR"')"
has   "--app=<dir> means the same thing"                  "DIR=$PKG_OK" "$OUT"
OUT="$(cd / && drive 'up_take_app_flag p4 --app tmp; echo "DIR=$NDT_APP_DIR"')"
has   "🔴 a relative path is made absolute here"          "DIR=/tmp" "$OUT"
OUT="$(drive 'up_take_app_flag p4 --app')"
check "--app with no value is a usage error"              "2" "$(rc_of "$OUT")"
has   "  and says what it wanted"                         "ndt up --app needs a package directory" "$OUT"
OUT="$(drive 'up_take_app_flag p4 --app /no/such/dir')"
check "--app naming no directory is a usage error"        "2" "$(rc_of "$OUT")"
# 🔴 AN EMPTY VALUE IS NOT "NO PACKAGE". `--app=` and `--app ""` both leave NDT_APP_DIR empty,
# and an emptiness test alone reads that as the baseline branch -- so the command would build
# the baseline fabric AND clear p4_proxy/mininet/app_package_override, under an argv that says
# --app. `seen` is tracked apart from the value for exactly this.
OUT="$(drive 'up_take_app_flag p4 --app=')"
check "🔴 --app= with an empty value is a usage error"    "2" "$(rc_of "$OUT")"
has   "  and says why an empty value is not the default"  "an empty value is not 'no package'" "$OUT"
OUT="$(drive 'up_take_app_flag p4 --app ""')"
check "🔴 so is --app with an empty argument"             "2" "$(rc_of "$OUT")"
# The control for it: a knob already there must be untouched by that refusal, because the
# refusal happens in the parser, above everything that writes.
reset_fix; plant_knob
OVSOUT2="$(cd "$FIX" && NDT_OWNER=t bash "$NDT" up p4 --app= 2>&1)"; OVSRC2=$?
check "  the real dispatch refuses it too"                "2" "$OVSRC2"
check "🔴 and the knob that was there is untouched"       "$PKG_OK" "$(knob_state)"
OUT="$(drive 'up_take_app_flag ovs; echo "DIR=[$NDT_APP_DIR]"; echo "LEFT=${NDT_UP_ARGV[*]}"')"
has   "  and argv without the flag is left alone"         "DIR=[]" "$OUT"
has   "  every word of it"                                "LEFT=ovs" "$OUT"

# 🔴 THE PLANE CHECK, through the real dispatch. An accepted-and-ignored --app would build a
# 128-host OVS fabric while the operator believed they were running an exercise.
OVSOUT="$(cd "$FIX" && NDT_OWNER=t bash "$NDT" up ovs --app "$PKG_OK" 2>&1)"; OVSRC=$?
check "🔴 --app on the OVS plane is refused"              "2" "$OVSRC"
has   "  saying it is a P4 flag"                          "--app is a P4 flag" "$OVSOUT"
has   "  and what to type instead"                        "ndt up p4 --app $PKG_OK" "$OVSOUT"
hasnt "  and no OVS bring-up started"                     "[1/4] control plane (Ryu)" "$OVSOUT"

# A package SIZES the fabric, so a host count beside it is two answers to one question.
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); up_p4 4")"
check "🔴 --app with a host count is a usage error"       "2" "$(rc_of "$OUT")"
has   "  saying why"                                      "takes no host count: the package's model declares its hosts" "$OUT"
check "  and nothing was written"                         "absent" "$(knob_state)"

# =============================================================================================
section "7. 🔴 one model, not two -- NDT_TOPO and the package"
# =============================================================================================
# A package naming one model while an override names another is the 2026-08-21 defect in a new
# costume: one of them builds the fabric, the other is handed to the kernel, and every topology
# view reads correct either way.
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); NDT_TOPO=$(q "$PKG_EXT/ndtwin/topology.json"); up_p4")"
check "🔴 NDT_TOPO naming another model is refused"       "5" "$(rc_of "$OUT")"
has   "  naming both files"                               "NDT_TOPO=$PKG_EXT/ndtwin/topology.json and the app package's model are two different files" "$OUT"
check "  and nothing was written"                         "absent" "$(knob_state)"
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); NDTWIN_P4_TOPO_FILE=$(q "$PKG_EXT/ndtwin/topology.json"); up_p4")"
check "🔴 so is NDTWIN_P4_TOPO_FILE -- the proxy's own override" "5" "$(rc_of "$OUT")"
# The control: pointing it AT the package is not a disagreement, or the variable would be
# unusable with a package at all.
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); NDT_TOPO=$(q "$PKG_OK/ndtwin/topology.json"); up_p4")"
check "  NDT_TOPO pointed at the package is fine"         "0" "$(rc_of "$OUT")"

# =============================================================================================
section "8. 🔴 'ndt status' names the file, and --check goes red on every broken state"
# =============================================================================================
reset_fix
OUT="$(drive 'app_package_row; echo "PROB=${#STATUS_APP_PROBLEMS[@]}"')"
has   "no knob reads as none"                             "app package    none   (p4_proxy/mininet/app_package_override absent" "$OUT"
has   "  and is not a problem"                            "PROB=0" "$OUT"

printf '# written by ndt\n%s\n' "$PKG_OK" > "$KNOB"
OUT="$(drive 'app_package_row; echo "PROB=${#STATUS_APP_PROBLEMS[@]}"')"
has   "a package reads as itself, with its mode"          "app package    $PKG_OK (mode ndtwin)" "$OUT"
has   "  naming the file that decides the next run"       "it decides the next 'ndt up p4' and the next proxy" "$OUT"
has   "  and a good package is not a problem"             "PROB=0" "$OUT"

printf '%s\n' "$FIX/packages/gone" > "$KNOB"
OUT="$(drive 'app_package_row; echo "PROB=${#STATUS_APP_PROBLEMS[@]}"')"
has   "🔴 a knob naming a directory that is gone says so" "THE DIRECTORY IS NOT THERE" "$OUT"
has   "  and --check has a problem to exit 1 on"          "PROB=1" "$OUT"

printf '# nothing but a comment\n' > "$KNOB"
OUT="$(drive 'app_package_row; echo "PROB=${#STATUS_APP_PROBLEMS[@]}"')"
has   "🔴 an empty knob says the proxy refuses to start"  "the proxy REFUSES to start on that file" "$OUT"
has   "  and is a problem"                                "PROB=1" "$OUT"

mkdir -p "$FIX/packages/nomanifest"
printf '%s\n' "$FIX/packages/nomanifest" > "$KNOB"
OUT="$(drive 'app_package_row; echo "PROB=${#STATUS_APP_PROBLEMS[@]}"')"
has   "🔴 a directory with no readable package.json says so" "package.json UNREADABLE" "$OUT"
has   "  and is a problem"                                "PROB=1" "$OUT"
hasnt "  🔴 and is NOT rendered as the default mode"      "mode ndtwin" "$OUT"
rm -f "$KNOB"

# =============================================================================================
section "9. 🔴 the two defaults a stand-in cannot test"
# =============================================================================================
# Sections 1-8 drive pre-flight through a stand-in, which is the only way this file can run on
# a machine with no venv. What that cannot say is whether the DEFAULTS behind the two seams
# still name the real interpreter and the real tool -- so those are read from the repo here.
# The interpreter is the SFLOW_PORT situation exactly: a constant `ndt` keeps because it does
# not source components.env, and a copy that agrees today and drifts next.
CE_PY="$(cd "$REAL_REPO/tools/test_workflow" && KERNEL_DIR="$REAL_REPO" bash -c '. ./components.env; echo "$P4_PROXY_PY"')"
NDT_PY="$(cd "$REAL_REPO" && REPO="$REAL_REPO" bash -c "source '$NDT' >/dev/null 2>&1; REPO='$REAL_REPO'; unset P4_PROXY_PY; p4_proxy_py")"
check "🔴 ndt's interpreter is components.env's P4_PROXY_PY" "$CE_PY" "$NDT_PY"
NDT_TOOL="$(cd "$REAL_REPO" && bash -c "source '$NDT' >/dev/null 2>&1; REPO='$REAL_REPO'; unset NDT_APP_PREFLIGHT; echo \"\${NDT_APP_PREFLIGHT:-\$REPO/tools/p4_exercise/preflight.py}\"")"
check "🔴 and the tool it runs is the repo's pre-flight"  "1" \
      "$([[ -r "$NDT_TOOL" ]] && echo 1 || echo 0)"

# =============================================================================================
section "10. 🔴 the model decides the ping, and an external plane says what it did NOT check"
# =============================================================================================
# `h1 10.0.0.2` was a literal here. For both baseline models it is what the model says; for
# exercises/basic's pod-topo it is an address no host in that fabric holds, and the ping would
# fail for that reason under a message claiming the fabric is not forwarding.
BASE4="$REAL_REPO/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json"
BASE128="$REAL_REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
OUT="$(drive "topo_model_ping_pair '$BASE4'")"
has   "🔴 the 4-host model still gives the old literal"   "h1 10.0.0.2" "$OUT"
OUT="$(drive "topo_model_ping_pair '$BASE128'")"
has   "🔴 and so does the 128-host model"                 "h1 10.0.0.2" "$OUT"
OUT="$(drive "topo_model_ping_pair '$PKG_OK/ndtwin/topology.json'")"
has   "  a package gives ITS second host's address"       "h1 10.0.2.2" "$OUT"
OUT="$(drive "topo_model_switches '$PKG_EXT/ndtwin/topology.json'")"
has   "  and the switch count comes off the model"        "3" "$OUT"

# verify_p4 under each mode. The proxy-side checks are driven through the real function with
# the graph half stubbed, so what is measured here is which checks it runs and what it says
# about the ones it does not.
VSTUB='
verify_p4_graph() { echo "GRAPH CHECKED $1"; return 0; }
verify_dataplane() { echo "PINGED $1 -> $2"; return 0; }
json_len() { echo 12; }
curl() { echo "{}"; }
'
OUT="$(drive_v "$VSTUB"$'\n'"verify_p4 '$PKG_OK/ndtwin/topology.json' 12 ndtwin")"
has   "ndtwin mode pings the pair the model names"        "PINGED h1 -> 10.0.2.2" "$OUT"
has   "  and checks the graph"                            "GRAPH CHECKED" "$OUT"
has   "  and ends ready"                                  "up. ready" "$OUT"
OUT="$(drive_v "$VSTUB"$'\n'"verify_p4 '$PKG_EXT/ndtwin/topology.json' 6 external")"
check "🔴 external mode still ends green"                 "0" "$(rc_of "$OUT")"
has   "🔴 and NAMES the path count as not checked"        "proxy: destination paths NOT CHECKED" "$OUT"
has   "🔴 and forwarding as not tested"                   "data plane: forwarding NOT TESTED for the same reason" "$OUT"
has   "  saying what would have to run first"            "run_external_controller.py" "$OUT"
has   "🔴 and that the fabric is EMPTY, under an unchanged verdict word" "this fabric is up and EMPTY" "$OUT"
hasnt "🔴 it does NOT ping and call the silence a pass"   "PINGED" "$OUT"
has   "  but the graph, model and fabric ARE checked"     "GRAPH CHECKED" "$OUT"

# =============================================================================================
section "11. 🔴 the proxy's own last words when it will not start"
# =============================================================================================
# P1-A §4-11 makes proxy_agent/main.py raise AT IMPORT when a package will not load. stack.sh
# can only ever report `proxy did not open :8081`, which under a package is true of every
# possible cause; the traceback naming the field is in the log.
printf 'line one\nAppPackageError: hosts h3 is not in the model\n' > "$FIX/.test_run/logs/p4_proxy.log"
OUT="$(drive 'proxy_log_tail 2')"
has   "the proxy log's tail is printed"                   "AppPackageError: hosts h3 is not in the model" "$OUT"
rm -f "$FIX/.test_run/logs/p4_proxy.log"
OUT="$(drive 'proxy_log_tail 2')"
has   "  and its absence is said, not skipped"            "the proxy never got far enough to write one" "$OUT"

# =============================================================================================
section "12. 🔴 when stack.sh cannot bring the proxy up"
# =============================================================================================
# P1-A §4-11 makes proxy_agent/main.py raise AT IMPORT when a package will not load, and
# stack.sh can then only say `proxy did not open :8081` -- true of every possible cause. The
# traceback naming the field is in the proxy's log, and until this change nothing printed it.
# The other half of the same path: the knob THIS run wrote must not outlive the rollback.
reset_fix
: > "$STACK_FAIL"
printf 'Traceback (most recent call last):\n  ...\nAppPackageError: hosts h3 is not in the model\n' \
    > "$FIX/.test_run/logs/p4_proxy.log"
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
check "🔴 a stack.sh that exits 1 fails the bring-up"     "1" "$(rc_of "$OUT")"
has   "  and says so"                                     "stack.sh up p4 exited 1" "$OUT"
has   "🔴 the PROXY's own last words are printed"         "AppPackageError: hosts h3 is not in the model" "$OUT"
has   "  named as the proxy's log"                        "the last 10 line(s) of .test_run/logs/p4_proxy.log" "$OUT"
has   "  and the bring-up was rolled back"                "rollback" "$OUT"
check "🔴 the knob THIS run wrote does not outlive it"    "absent" "$(knob_state)"
has   "  saying why it went"                              "app package cleared: $PKG_OK -- this bring-up was rolled back" "$OUT"
# The control: with no proxy log there is no traceback to print, and the absence is SAID.
reset_fix
: > "$STACK_FAIL"
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
has   "  with no proxy log, the absence is reported"      "the proxy never got far enough to write one" "$OUT"
rm -f "$STACK_FAIL"

# =============================================================================================
section "13. 🔴 when the FABRIC never comes up, the bridge's own last words"
# =============================================================================================
# TICKET-P1D. The 2026-09-18 live round is the whole argument: `ndt up p4 --app` printed
# `fabric did not come up: 0/4 switches, manifest missing` and `look at the pane`, and by then
# there was no pane -- ntg_bmv2_topo.py had died of a KeyError and tmux reaps the session when
# the process goes, so `ndtwin-lab topo-out` answers "no topo session". The bridge now tees its
# output to .test_run/logs/topo.log and this branch prints the tail of it.
#
# 🔴 BEFORE the rollback, not after: rollback_up runs `ndtwin-lab cleanup`, and a cause printed
# underneath a screen of recovery is a cause nobody reads. The ordering has its own cell.
reset_fix
TOPO_LOG="$FIX/.test_run/logs/topo.log"
printf 'Traceback (most recent call last):\n  File "ntg_bmv2_topo.py", line 139, in main\n    switches = [net.get(f"s{i}") for i in range(1, 11)]\nKeyError: %s\n' "'s5'" > "$TOPO_LOG"
OUT="$(drive "bmv2_count() { echo 0; }; NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
check "🔴 a fabric that never came up fails the bring-up" "1" "$(rc_of "$OUT")"
has   "  and says how far it got"                         "fabric did not come up: 0/4 switches" "$OUT"
has   "🔴 the BRIDGE's own last words are printed"        "KeyError: 's5'" "$OUT"
has   "  named as the topology log"                       "the last 30 line(s) of .test_run/logs/topo.log" "$OUT"
has   "  the pane is still offered for the live case"     "sudo -n $FIX/installed-ndtwin-lab topo-out 40" "$OUT"
has   "  and the bring-up was rolled back"                "rollback" "$OUT"
check "🔴 the knob THIS run wrote does not outlive it"    "absent" "$(knob_state)"
# 🔴 THE ORDER. Read as line numbers rather than asserted as prose, because "it was printed"
# and "it was printed where somebody sees it" are the two halves of this whole ticket.
tail_at="$(/usr/bin/grep -n 'the last 30 line(s) of' <<<"$OUT" | head -1 | cut -d: -f1)"
roll_at="$(/usr/bin/grep -n 'this bring-up started' <<<"$OUT" | head -1 | cut -d: -f1)"
check "🔴 the cause is printed ABOVE the rollback"        "yes" \
      "$( [[ -n "$tail_at" && -n "$roll_at" && "$tail_at" -lt "$roll_at" ]] && echo yes || echo no )"

# The control: with no topology log there is no traceback to print, and the absence is SAID --
# an empty tail must not read the same as a clean bring-up.
reset_fix
OUT="$(drive "bmv2_count() { echo 0; }; NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
has   "  with no topology log, the absence is reported"   "the bridge never got far enough to write one" "$OUT"
hasnt "  and no tail is invented"                         "the last 30 line(s)" "$OUT"

# And the baseline plane reaches it too: the bridge is what `ndt up p4` starts with or without
# a package, so the diagnosis must not be a --app-only feature.
reset_fix
printf 'Error: no P4 topology model in setting/ has 4 hosts\n' > "$TOPO_LOG"
OUT="$(drive 'bmv2_count() { echo 0; }; up_p4 4')"
has   "🔴 the same tail on a bring-up with NO package"    "no P4 topology model in setting/ has 4 hosts" "$OUT"
rm -f "$TOPO_LOG"

# The OTHER way the fabric step fails: `ndtwin-lab topo-start` itself refuses (a topo session is
# already up, the config is untrusted, ...). The bridge may then never have run, so the log is
# quite possibly the previous round's -- printed anyway, because the other likely cause is a
# bridge that died before tmux could report it, and LABELLED, because a stale traceback read as
# this run's is a wrong diagnosis rather than a missing one.
reset_fix
printf 'KeyError: %s\n' "'s5'" > "$TOPO_LOG"
SUDO_FAIL='sudo() { printf "sudo %s\n" "$*" >> "'"$FIX"'/sudo.log"; case "$*" in *topo-start*) return 1 ;; esac; return 0; }'
OUT="$(drive "$SUDO_FAIL"$'\n'"NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
check "🔴 a topo-start that refuses fails the bring-up"   "1" "$(rc_of "$OUT")"
has   "  and says so"                                     "topo-start failed" "$OUT"
has   "🔴 the topology log is printed here too"           "KeyError: 's5'" "$OUT"
has   "🔴 labelled as possibly the PREVIOUS round's"      "topo.log may be the PREVIOUS round's" "$OUT"
has   "  and the bring-up was rolled back"                "rollback" "$OUT"
rm -f "$TOPO_LOG"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
