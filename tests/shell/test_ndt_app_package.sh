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
mkpkg() {   # mkpkg <dir> <mode> <n-hosts> <n-switches> [<pipeline stem for s1>]
    local d="$1" mode="$2" nh="$3" ns="$4" pipe="${5:-}"
    mkdir -p "$d/ndtwin"
    [[ -n "$pipe" ]] && { mkdir -p "$d/build"; : > "$d/build/$pipe.p4.p4info.txtpb"; echo '{}' > "$d/build/$pipe.json"; }
    python3 - "$d" "$mode" "$nh" "$ns" "$pipe" <<'PY'
import json, os, sys
d, mode, nh, ns = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
pipe = sys.argv[5] if len(sys.argv) > 5 else ""
nodes, edges, hosts = [], [], {}
for i in range(1, ns + 1):
    nodes.append({"device_name": "s%d" % i, "bridge_name": "s%d" % i, "dpid": i,
                  "vertex_type": 0, "device_layer": 2, "ip": ["192.168.123.%d" % (10 + i)],
                  "mac": 0, "ecmp_groups": []})
for i in range(1, nh + 1):
    ip = "10.0.%d.%d" % (i, i)
    nodes.append({"device_name": "h%d" % i, "dpid": 0, "vertex_type": 1,
                  "device_layer": 3, "ip": [ip], "mac": i})
    # 🔴 topo_from_json.mac_str(i, "hN")'s own answer, not a second formula:
    # app_package.load refuses a package whose hosts.hN.mac differs from the model's
    # (static ARP written from one and resolved against the other drops every frame for
    # that host), so a fixture with a prettier MAC is a fixture no reader of this package
    # can load -- which section 14 would then read as "unreadable" for a package that is
    # fine.
    hosts["h%d" % i] = {"ip": ip, "prefix_len": 24,
                        "mac": ":".join("%02x" % ((i >> sh) & 0xFF)
                                        for sh in (40, 32, 24, 16, 8, 0)),
                        "commands": []}
    sw = (i - 1) % ns + 1
    edges.append({"src_dpid": 0, "src_interface": 1, "dst_dpid": sw, "dst_interface": 1})
    edges.append({"src_dpid": sw, "src_interface": 1, "dst_dpid": 0, "dst_interface": 1})
json.dump({"nodes": nodes, "edges": edges, "links": []},
          open(os.path.join(d, "ndtwin", "topology.json"), "w"), indent=2, sort_keys=True)
json.dump({"format": 1, "name": os.path.basename(d), "topology": "ndtwin/topology.json",
           "hosts": hosts,
           "switches": {str(i): {"name": "s%d" % i,
                                 "pipeline": ({"p4info": "build/%s.p4.p4info.txtpb" % pipe,
                                               "bmv2_json": "build/%s.json" % pipe}
                                              if (pipe and i == 1) else None),
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
# TICKET-P2 §5.5: a package that puts somebody else's program on s1 and leaves s2-s4 on
# NDTwin's. exercises/firewall is the shipped shape of exactly this.
PKG_FOREIGN="$FIX/packages/foreign"; mkpkg "$PKG_FOREIGN" ndtwin 4 4 firewall
# A package directory whose manifest cannot be read at all. `unreadable` is its own answer and
# is NOT `ndtwin`: rendering an unparsable package as the default pipeline is the silent
# substitution this feature exists to remove.
PKG_UNREADABLE="$FIX/packages/unreadable"; mkdir -p "$PKG_UNREADABLE"
printf 'this is not json\n' > "$PKG_UNREADABLE/package.json"

# 🔴 THE REAL LOADER, over the fixture's paths. app_pipeline_kind answers with
# Package.pipeline_is_ndtwin (TICKET-P2 §2.1) and imports it from $REPO/p4_proxy/mininet --
# which under these stubs is $FIX -- so the three modules that answer the question are
# symlinked in. A stand-in for them would be this suite deciding the answer it is checking.
for m in app_package.py topo_from_json.py grpc_ports.py; do
    ln -sf "$REAL_REPO/p4_proxy/mininet/$m" "$FIX/p4_proxy/mininet/$m"
done

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
verify_p4() { echo "VERIFY_P4 topo=$1 want_paths=$2 mode=${3:-<none>} pipe=${4:-<none>}"; return 0; }
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

# 🔴 verify_p4_graph's DENOMINATOR, driven for real with the kernel's answer stubbed.
# Live, 2026-09-18: a four-switch package came up correctly -- 4 switches, 4 up, 16 edges, all
# four with entries recorded -- and this printed `kernel: 4 switches, 4 up (want 10/10)` and
# `is_enabled=4/10`, reporting a healthy fabric as two faults. The want came off the global
# SWITCHES, which is the literal 10. It comes off the model this function is handed now.
GRAPH='
curl() { printf %s "$GRAPH_JSON"; }
fabric_host_count() { echo "$GRAPH_HOSTS"; }
'
mkgraph() {   # mkgraph <switches> <hosts>
    python3 - "$1" "$2" <<'PY'
import json, sys
ns, nh = int(sys.argv[1]), int(sys.argv[2])
nodes = [{"vertex_type": 0, "is_up": True, "is_enabled": True} for _ in range(ns)]
nodes += [{"vertex_type": 1} for _ in range(nh)]
print(json.dumps({"nodes": nodes, "edges": [{} for _ in range(ns * 4)]}))
PY
}
G4="$(mkgraph 4 4)"
OUT="$(drive_v "$GRAPH"$'\n'"GRAPH_JSON=$(q "$G4"); GRAPH_HOSTS=4; verify_p4_graph '$PKG_OK/ndtwin/topology.json'")"
check "🔴 a 4-switch package makes the want 4, not 10"    "0" "$(rc_of "$OUT")"
has   "  and says so positively"                          "kernel: 4 switches, 4 up" "$OUT"
hasnt "🔴 the literal ten is gone"                        "want 10/10" "$OUT"
hasnt "  and so is is_enabled=4/10"                       "is_enabled=4/10" "$OUT"
# The control that keeps the cell above from passing on any denominator at all.
G3="$(mkgraph 3 4)"
OUT="$(drive_v "$GRAPH"$'\n'"GRAPH_JSON=$(q "$G3"); GRAPH_HOSTS=4; verify_p4_graph '$PKG_OK/ndtwin/topology.json'")"
check "🔴 three switches under a 4-switch model still fails" "1" "$(rc_of "$OUT")"
has   "  naming the model's number as the want"           "want 4/4" "$OUT"
# Baseline: the 10-switch models still want ten.
G10="$(mkgraph 10 4)"
OUT="$(drive_v "$GRAPH"$'\n'"GRAPH_JSON=$(q "$G10"); GRAPH_HOSTS=4; verify_p4_graph '$BASE4'")"
check "🔴 the baseline model still wants ten"             "0" "$(rc_of "$OUT")"
has   "  and says ten"                                    "kernel: 10 switches, 10 up" "$OUT"
OUT="$(drive_v "$GRAPH"$'\n'"GRAPH_JSON=$(q "$G4"); GRAPH_HOSTS=4; verify_p4_graph '$BASE4'")"
check "🔴 four switches under the baseline model fails"   "1" "$(rc_of "$OUT")"
has   "  naming ten as the want"                          "want 10/10" "$OUT"
# Unobtainable is RED, not green -- same rule as the host count beside it.
OUT="$(drive_v "$GRAPH"$'\n'"GRAPH_JSON=$(q "$G4"); GRAPH_HOSTS=4; verify_p4_graph '$FIX/no-such-model.json'")"
check "🔴 an uncountable model is a failure, not a pass"  "1" "$(rc_of "$OUT")"
has   "  and says the check did not run"                  "kernel: UNCHECKED" "$OUT"

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

# =============================================================================================
section "14. 🔴 a package pipeline has no sampling rate here, and the rate rows say so"
# =============================================================================================
# TICKET-P2 §5.5 / PLAN-0917 §3.1. `sample rate` is decoded from
# p4_proxy/p4_src/build/ndtwin_switch.json, and a switch running the package's own program
# never loaded that file. Printing 1/256 beside it is X-2 with a different plane in it: for
# months `status` said `1/256` on an OVS fabric out of the same artefact, and the two numbers
# had only ever agreed by coincidence (D-2 / X-2, 2026-09-06). So the row reads
# `n/a (package pipeline)`, the source row says which dpids and why, and `stale_pipeline` --
# a comparison of the manifest's mtime with THAT file's -- is not judged at all.
#
# 🔴 app_pipeline_kind's answer comes from Package.pipeline_is_ndtwin, the real loader,
# symlinked in above. A second copy of "is this switch on NDTwin's pipeline" living in `ndt`
# would be two answers to one question.

pipe_kind() {   # pipe_kind [dir] -- app_pipeline_kind's one word, without the driver's RC line
    drive "app_pipeline_kind ${1:-}" | /usr/bin/grep -v '^RC=' | tail -1
}

reset_fix
check "🔴 no package: there is no pipeline question to answer" "none" "$(pipe_kind)"
check "  a package whose switches are all null is ndtwin"      "ndtwin" "$(pipe_kind "$PKG_OK")"
check "🔴 one switch on somebody else's program names the dpid" "foreign:1" \
      "$(pipe_kind "$PKG_FOREIGN")"
check "🔴 a package that will not load is 'unreadable', NOT 'ndtwin'" "unreadable" \
      "$(pipe_kind "$PKG_UNREADABLE")"
check "  a directory that is not there is unreadable too"      "unreadable" \
      "$(pipe_kind "$FIX/packages/gone")"

# Through the knob, which is how cmd_status asks it.
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
check "  a foreign-pipeline package comes up and writes the knob" "$PKG_FOREIGN" "$(knob_state)"
check "🔴 and the pipeline question is then answered off the knob" "foreign:1" "$(pipe_kind)"

# --- the two rows themselves ------------------------------------------------------------------
STALE='stale_pipeline() { return 0; }'
reset_fix
OUT="$(drive "$STALE"$'\n'"status_rate_rows 256 p4 none")"
has   "  a baseline fabric still prints the rate"              "sample rate    1/256" "$OUT"
has   "  and where it came from"                               "P4: p4_proxy/p4_src/build/ndtwin_switch.json" "$OUT"
has   "  and the stale warning when it is stale"               "the running switches predate it" "$OUT"

OUT="$(drive "$STALE"$'\n'"status_rate_rows 256 p4 foreign:1")"
has   "🔴 a package pipeline has no rate here"                 "sample rate    n/a (package pipeline)" "$OUT"
hasnt "🔴 and the built json's number is NOT printed for it"   "1/256" "$OUT"
has   "  the source row names the dpid"                        "foreign pipeline on dpid 1" "$OUT"
has   "  and which file is not what those switches loaded"     "ndtwin_switch.json is NOT what those switches loaded" "$OUT"
hasnt "🔴 stale_pipeline is not judged under a package pipeline" "the running switches predate it" "$OUT"

OUT="$(drive "$STALE"$'\n'"status_rate_rows 256 p4 foreign:2,3")"
has   "  two foreign switches are both named"                  "foreign pipeline on dpid 2,3" "$OUT"

# The predicate the row and the --check problem BOTH read, driven on its own: one answer, so a
# yellow row over a green exit code cannot happen.
OUT="$(drive "$STALE"$'\n'"status_pipeline_is_stale p4 ndtwin")"
check "  an ndtwin package on a stale build IS stale"          "0" "$(rc_of "$OUT")"
OUT="$(drive "$STALE"$'\n'"status_pipeline_is_stale p4 foreign:1")"
check "🔴 a foreign pipeline is never stale"                   "1" "$(rc_of "$OUT")"
OUT="$(drive "$STALE"$'\n'"status_pipeline_is_stale ovs none")"
check "  and the OVS plane is not judged by it either (as before)" "1" "$(rc_of "$OUT")"
OUT="$(drive 'stale_pipeline() { return 1; }'$'\n'"status_pipeline_is_stale p4 none")"
check "  a build older than the fabric is not stale"           "1" "$(rc_of "$OUT")"

# The rate's OWN --check problems, through the same seam: a foreign pipeline raises none of
# them, because each is about ndtwin_switch.json or about an OVS fabric.
probs() { drive "status_rate_problems $1 $2" | /usr/bin/grep -v '^RC=' ; }
has   "  a dead rng is still a problem on the baseline"        "samples nothing" "$(probs 'DISABLED:lo=1' none)"
has   "  and so is an OVS fabric with no sflow record"         "no sFlow record" "$(probs OVS-NOSFLOW none)"
check "🔴 a foreign pipeline raises none of the rate problems" "" "$(probs 'DISABLED:lo=1' foreign:1)"
check "  not even the OVS ones"                                "" "$(probs OVS-NOSFLOW foreign:2,3)"
check "  a healthy rate raises nothing either (the control)"   "" "$(probs 256 none)"

# =============================================================================================
section "15. 🔴 the whole of 'ndt status --check' over a foreign package pipeline"
# =============================================================================================
# Section 14 drives the three new functions one at a time, and that is not enough on its own:
# each of them could be right while `cmd_status` called none of them. This drives the WHOLE
# report with a foreign package knob in place and `stale_pipeline` returning true, and asserts
# the two halves that have to agree --
#   * the printed row says `n/a (package pipeline)` and NOT the built json's rate, and
#   * `--check`'s problem list carries neither the stale-pipeline problem nor any of the four
#     the rate itself raises.
# -- because those are the two halves one mutation at a time can pull apart: with the row's
# early return gone the rate comes back, and with the predicate's exemption gone the problem
# comes back UNDER a row that still says n/a. Each of those is its own mutation in
# mutate_ndt_app_package.sh (M19, M20, M23), and each must be able to redden THIS cell alone.
#
# The stub set is tests/shell/test_ndt_check_sample_rate.sh:171-204's, plus what a package
# fabric needs: the knob is real (cmd_status reads it through app_knob_state) and so is the
# package it names.
STATUS_STUBS="$STUBS"'
claim_line() { echo none; }
claim_prev_row() { :; }
lab_version_report() { :; }
lab_version_problem() { :; }
up_target_field() { :; }
last_kernel_plane() { :; }
kernel_exit_field() { :; }
host_count() { echo 4; }
topo_for_hosts() { echo setting/StaticNetworkTopologyP4_10Switches_4Hosts.json; }
live_dataplane_kind() { echo p4; }
# 🔴 A RATE TOKEN THAT HAS SOMETHING TO SAY. With 256 here the rate raises no --check
# problem at all, and "a foreign pipeline raises none of them" is then true of every possible
# implementation -- a vacuous cell, which is exactly what M23 in mutate_ndt_app_package.sh
# caught when it SURVIVED against the first draft of this section. DISABLED:lo=1 is the
# compiled pipeline that samples nothing (RESTORE-SWEEP 2026-09-02): a problem on a baseline
# fabric, and not one under a package pipeline. rate_label stays stubbed, so the printed row
# is unaffected either way.
# (No apostrophes in this block: it lives inside a single-quoted stub set.)
sample_rate() { echo "DISABLED:lo=1"; }
rate_label() { echo "1/256"; }
stale_pipeline() { return 0; }
source_ahead_of_build() { return 1; }
ovs_bridge_count() { echo 0; }
ovs_daemon_running() { return 1; }
lock_probe() { echo free; }
netem_count() { echo 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
ndt_port_residue() { :; }
http_get_graph() { :; }
http_get_flow_entries() { echo "[]"; }
verify_p4_graph() { :; }
# 🔴 check_up_target, not a value: with no up.target recorded `--check` exits 3 ("could not
# check"), which outranks every verdict below it -- so a cell that left it unstubbed would read
# 3 whatever cmd_status decided about the rate. Stubbed to "compared, and it matched", which is
# the state this cell is about.
check_up_target() { return 0; }
UP_TARGET_PROBLEMS=()
'
run_status() {   # run_status [<cmd_status args>] [<extra stubs appended after STATUS_STUBS>]
    bash -c "source '$NDT' >/dev/null 2>&1
$STATUS_STUBS
${2:-}
cmd_status ${1:-}
echo \"RC=\$?\"" 2>&1
}

reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"    # writes the knob, as a real round does
check "  the foreign package is the knob cmd_status will read" "$PKG_FOREIGN" "$(knob_state)"
OUT="$(run_status --check)"
has   "🔴 the whole report says the rate is n/a"          "sample rate    n/a (package pipeline)" "$OUT"
hasnt "🔴 and never prints the built json's number"       "sample rate    1/256" "$OUT"
has   "  the source row names the dpid and the file"      "foreign pipeline on dpid 1" "$OUT"
hasnt "🔴 --check does not raise the stale-pipeline problem" "the fabric predates the current build" "$OUT"
hasnt "  nor any problem about the compiled rate"         "the compiled pipeline samples nothing" "$OUT"
check "  and --check exits 0 over a healthy package fabric" "0" "$(rc_of "$OUT")"

# The control: the SAME report with an ndtwin-pipeline package prints the rate and DOES raise
# the stale problem. Without it, "no rate, no problems" is a sentence this harness would say
# whatever cmd_status did.
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
OUT="$(run_status --check)"
has   "  an ndtwin-pipeline package still prints the rate" "sample rate    1/256" "$OUT"
hasnt "  and does not claim a package pipeline"           "n/a (package pipeline)" "$OUT"
has   "🔴 and the stale build IS a problem there"         "the fabric predates the current build" "$OUT"
# The other half of M23's evidence: the rate's OWN problem is raised here and suppressed above,
# so "none of them under a foreign pipeline" is a difference this pair can actually see.
has   "🔴 and so is the compiled pipeline that samples nothing" "the compiled pipeline samples nothing" "$OUT"
check "  so --check exits 1 on it"                        "1" "$(rc_of "$OUT")"

# =============================================================================================
section "16. 🔴 verify_p4 under a package pipeline -- paths NOT CHECKED, entries the gate"
# =============================================================================================
# TICKET-P2-D. The hole this section closes was found LIVE and could not be found here, because
# §0-2 forbids a worker `ndt up` and `curl` in this file is a stub: on 2026-09-18
# `ndt up p4 --app <exercises/basic>` waited the whole CONVERGE_WAIT for twelve destination
# paths, read four, and ended `up, but not verified` over a fabric whose twelve ordered pairs
# all pinged at 0% loss. Four was the DESIGNED answer -- the proxy skips lldp_discovery on a
# foreign pipeline (proxy_agent/main.py FOREIGN_PIPELINE_FABRIC_SKIPS), so its graph has no
# inter-switch links and the only pairs it can path are the ones sharing a switch.
#
# 🔴 THE THREE SEGMENTS ARE THREE DIFFERENT VERDICTS, and that is the whole design:
#   * the path count is NOT CHECKED -- but only once the proxy has SAID it skipped discovery.
#     "I stopped counting because a package named its own pipeline" would print the same
#     sentence over a proxy that really was discovering links and had found four of twelve,
#     which is the fault the count exists to catch wearing this message as a disguise;
#   * the table entries are the GATE, because applying the package's own rules is the one thing
#     NDTwin is responsible for on this fabric;
#   * forwarding is a READING. A skeleton is meant not to forward and source_routing's own
#     solution does not answer a plain ping, so a gate here hands drive_exercise.py an ERROR
#     where it needs a red arm and a green one.

# mkss <file> <control-plane spec> <per-switch spec>... -- a switch_state fixture.
#   control-plane spec:  NOCP            no control_plane object at all
#                        NULL            control_plane present, skipped: null (startup unfinished)
#                        <empty>         skipped: []
#                        a,b,c           skipped: [a, b, c]
#   per-switch spec:     <rec>:<app>:<fail>   or   NOENTRIES (no table_entries block)
mkss() {
    local f="$1" cp="$2"; shift 2
    python3 - "$f" "$cp" "$@" <<'PY'
import json, sys
f, cp = sys.argv[1], sys.argv[2]
d = {"status": "success", "switches": {}}
if cp != "NOCP":
    d["control_plane"] = {"mode": "ndtwin", "package": "/pkg",
                          "skipped": None if cp == "NULL" else ([] if cp == "" else cp.split(","))}
for i, spec in enumerate(sys.argv[3:], start=1):
    s = {"pipeline": {"ndtwin": False, "p4info": "/pkg/build/basic.p4.p4info.txtpb",
                      "p4info_sha256": "9213871cee36bd93",
                      "skipped": ["clone_session", "sflow_telemetry"]}}
    if spec != "NOENTRIES":
        rec, app, fail = (int(x) for x in spec.split(":"))
        s["table_entries"] = {"recorded": rec, "applied": app, "failed": fail,
                              "api_writes": 0, "journaled": False}
    d["switches"][str(i)] = s
json.dump(d, open(f, "w"), indent=1)
PY
}
SKIPS3=install_initial_routes,link_watchdog,lldp_discovery
SS_GOOD="$FIX/ss_good.json"    ; mkss "$SS_GOOD"    "$SKIPS3" 5:5:0 5:5:0 5:5:0 5:5:0
SS_NOLLDP="$FIX/ss_nolldp.json"; mkss "$SS_NOLLDP"  ""        5:5:0 5:5:0 5:5:0 5:5:0
SS_NOCP="$FIX/ss_nocp.json"    ; mkss "$SS_NOCP"    NOCP      5:5:0 5:5:0 5:5:0 5:5:0
SS_NULL="$FIX/ss_null.json"    ; mkss "$SS_NULL"    NULL      5:5:0 5:5:0 5:5:0 5:5:0
SS_FAILED="$FIX/ss_failed.json"; mkss "$SS_FAILED"  "$SKIPS3" 5:5:0 5:4:1 5:5:0 5:5:0
SS_SHORT="$FIX/ss_short.json"  ; mkss "$SS_SHORT"   "$SKIPS3" 5:5:0 5:5:0 5:3:0 5:5:0
SS_EMPTY="$FIX/ss_empty.json"  ; mkss "$SS_EMPTY"   "$SKIPS3" 0:0:0 0:0:0
SS_MIXED="$FIX/ss_mixed.json"  ; mkss "$SS_MIXED"   "$SKIPS3" 5:5:0 3:3:0
# 🔴 The one shape only the `failed` half can catch: every recorded entry is applied AND the
# proxy still reports refusals. Without it `failed != 0` and `applied != recorded` cover for
# each other -- deleting either leaves the other printing the same sentence about the same
# switch, which is what this fixture was added for after that mutation survived.
SS_FAILONLY="$FIX/ss_failonly.json"; mkss "$SS_FAILONLY" "$SKIPS3" 5:5:0 5:5:2
SS_NOTE="$FIX/ss_noentries.json"; mkss "$SS_NOTE"   "$SKIPS3" 5:5:0 NOENTRIES
SS_JUNK="$FIX/ss_junk.json"    ; printf 'not json at all\n' > "$SS_JUNK"

# 🔴 `verify_dataplane_reading` and `verify_p4_package_entries` are left REAL -- they are the
# subject. What is stubbed is the machine: the endpoint (one `curl`, answering the fixture the
# cell points at), the kernel graph, the ping's own exit code, and `verify_dataplane`, whose
# presence in the output is how a cell proves the READING path was NOT taken.
FSTUB='
verify_p4_graph() { echo "GRAPH CHECKED $1"; return 0; }
# 🔴 The stub honours DP_RC too, so "a package fabric is not failed for a silent data
# plane" is a claim about the RC and not only about the wording: with the stub always
# returning 0, a mutation that routed the foreign branch back through verify_dataplane
# would keep the bring-up green and only the sentences would change.
verify_dataplane() { echo "PINGED $1 -> $2"; [[ "${DP_RC:-0}" == 1 ]] && return 1; return 0; }
dataplane_ok() { NDT_DATAPLANE_WHY=""; return ${DP_RC:-0}; }
ndt_sudo_explain() { echo "SUDO EXPLAIN $1"; }
lab_entry_points() { echo "ENTRY POINTS $1"; }
json_len() { echo "${PATHS_ANSWER:-4}"; }
curl() { cat "$SS_FILE"; }
sleep() { :; }
'
vp4() {   # vp4 <switch_state file> <mode> <pipe> [<extra shell before the call>]
    drive_v "$FSTUB"$'\n'"SS_FILE=$(q "$1"); ${4:-:}
verify_p4 '$PKG_OK/ndtwin/topology.json' 12 '$2' '$3'"
}

# --- §3.2-1: the path count, and the proxy's own word for why ---------------------------------
OUT="$(vp4 "$SS_GOOD" ndtwin foreign:1,2,3,4)"
check "🔴 a package pipeline ends ready, not 'never settled'" "0" "$(rc_of "$OUT")"
has   "🔴 and NAMES the path count as not checked"        "proxy: destination paths NOT CHECKED" "$OUT"
has   "  naming the dpids the package's program is on"    "runs on dpid" "$OUT"
has   "  and quoting what the proxy said it skipped"      "control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery" "$OUT"
hasnt "🔴 it does NOT count paths and call four of twelve a failure" "never settled" "$OUT"
hasnt "  nor report a stable count it never took"         "destination paths (stable)" "$OUT"
has   "  the verdict word is the same one"                "up. ready" "$OUT"
has   "  with the entry points under it"                  "ENTRY POINTS p4" "$OUT"
has   "🔴 and the caveat says what NDTwin did not do"     "package pipeline: NDTwin discovered no links" "$OUT"
hasnt "🔴 and it is NOT the external plane's EMPTY paragraph" "this fabric is up and EMPTY" "$OUT"

# 🔴 THE CONTROL WITHOUT WHICH "NOT CHECKED" IS A SENTENCE THIS BRANCH ALWAYS SAYS. A proxy that
# did not skip discovery gets the check it deserves, in red -- an expectation the proxy does not
# confirm is a fault, not a quieter success.
OUT="$(vp4 "$SS_NOLLDP" ndtwin foreign:1,2,3,4)"
check "🔴 a proxy that did NOT skip discovery is red"     "1" "$(rc_of "$OUT")"
has   "  and says the expectation was not confirmed"      "this script expected the proxy to skip discovery for a package pipeline" "$OUT"
has   "  quoting the list that does not name it"          "which does not name lldp_discovery" "$OUT"
has   "  under the unverified verdict"                    "but not verified" "$OUT"
OUT="$(vp4 "$SS_NOCP" ndtwin foreign:1,2,3,4)"
check "🔴 an endpoint with no control_plane is red too"   "1" "$(rc_of "$OUT")"
has   "  and says the proxy gave no skipped list"         "gave no control_plane.skipped" "$OUT"
OUT="$(vp4 "$SS_NULL" ndtwin foreign:1,2,3,4)"
check "🔴 'skipped: null' is NOT 'nothing was skipped'"   "1" "$(rc_of "$OUT")"
OUT="$(vp4 "$SS_JUNK" ndtwin foreign:1,2,3,4)"
check "🔴 an unreadable switch_state is red, not quiet"   "1" "$(rc_of "$OUT")"

# --- §3.2-2: the entries are the gate ---------------------------------------------------------
OUT="$(vp4 "$SS_GOOD" ndtwin foreign:1,2,3,4)"
has   "🔴 the entries the proxy applied are reported"     "table entries: 5/5 applied on 4 switch(es), 0 failed" "$OUT"
OUT="$(vp4 "$SS_FAILED" ndtwin foreign:1,2,3,4)"
check "🔴 one refused entry fails the bring-up"           "1" "$(rc_of "$OUT")"
has   "  naming how many, of how many, on which dpid"     "the proxy could not apply 1 of 5 on dpid 2" "$OUT"
hasnt "🔴 and not the counts-disagree sentence, which is a different fault" "neither written nor refused" "$OUT"
OUT="$(vp4 "$SS_FAILONLY" ndtwin foreign:1,2)"
check "🔴 refusals are red even when the counts add up"   "1" "$(rc_of "$OUT")"
has   "  naming the refused count and the dpid"           "could not apply 2 of 5 on dpid 2" "$OUT"
OUT="$(vp4 "$SS_SHORT" ndtwin foreign:1,2,3,4)"
check "🔴 applied < recorded with 0 failed is red too"    "1" "$(rc_of "$OUT")"
has   "  and says the counts themselves disagree"         "neither written nor refused" "$OUT"
OUT="$(vp4 "$SS_NOTE" ndtwin foreign:1,2,3,4)"
check "🔴 a switch that reports no table_entries is red"  "1" "$(rc_of "$OUT")"
has   "  because an unchecked gate is not a passed one"   "an unchecked gate is a failure, not a pass" "$OUT"
OUT="$(vp4 "$SS_EMPTY" ndtwin foreign:1,2)"
check "  a package with no entries at all is NOT red"     "0" "$(rc_of "$OUT")"
has   "  but is told that nothing will forward"           "the package carries no entries" "$OUT"
OUT="$(vp4 "$SS_MIXED" ndtwin foreign:1,2)"
check "  switches carrying different counts still pass"   "0" "$(rc_of "$OUT")"
has   "🔴 and the totals say so in a different word"      "8/8 applied across 2 switch(es)" "$OUT"

# --- §3.2-3: forwarding is a reading, not a verdict -------------------------------------------
OUT="$(vp4 "$SS_GOOD" ndtwin foreign:1,2,3,4 'DP_RC=1')"
check "🔴 a silent data plane does NOT fail a package fabric" "0" "$(rc_of "$OUT")"
has   "  it is reported as a reading"                     "a READING, not a verdict" "$OUT"
has   "  naming the program it is a reading of"           "9213871cee36bd93" "$OUT"
has   "  and saying who judges it"                        "The exercise's driver judges it." "$OUT"
hasnt "🔴 and NOT as a verdict about NDTwin's routing"    "fabric is up but not forwarding" "$OUT"
has   "  the verdict is still ready"                      "up. ready" "$OUT"
# 🔴 THE CONTROL. The same dead ping on NDTwin's own pipeline is still a failure -- this is the
# one verdict TICKET-P2-D changes, and it changes it for exactly one fabric.
# 🔴 The two reporters side by side over ONE dead ping, with nothing stubbed but the ping itself:
# same input, same instrument, two verdicts, and the difference is whose program is running.
DPSTUB='dataplane_ok() { NDT_DATAPLANE_WHY=""; return 1; }'
OUT="$(drive_v "$DPSTUB"$'\n'"verify_dataplane_reading h1 10.0.2.2 'sha'")"
has   "  the reading function itself warns rather than errs" "a READING, not a verdict" "$OUT"
check "  and returns 0 whatever the ping did"             "0" "$(rc_of "$OUT")"
OUT="$(drive_v "$DPSTUB"$'\n'"verify_dataplane h1 10.0.2.2 'the hint'")"
has   "🔴 while verify_dataplane still calls it a fault"  "fabric is up but not forwarding" "$OUT"
check "  and still returns 1"                             "1" "$(rc_of "$OUT")"
OUT="$(vp4 "$SS_GOOD" ndtwin foreign:1,2,3,4 'DP_RC=2')"
has   "  an unanswerable ping is still NOT tested"        "forwarding NOT tested" "$OUT"
check "  and does not fail the bring-up either"           "0" "$(rc_of "$OUT")"

# --- §3.1: every other kind takes today's path, to the byte -----------------------------------
# 🔴 The discriminator: `PINGED` comes from the STUBBED verify_dataplane, so its presence proves
# the old branch ran and its absence proves the reading branch did.
for kind in '' none ndtwin unreadable; do
    OUT="$(vp4 "$SS_GOOD" ndtwin "$kind" 'PATHS_ANSWER=12')"
    has   "  pipeline kind '${kind:-<empty>}' still counts paths" "12/12 destination paths (stable)" "$OUT"
    has   "  and still pings through verify_dataplane"    "PINGED h1 -> 10.0.2.2" "$OUT"
    hasnt "  and says nothing about a package pipeline"   "package pipeline: NDTwin discovered no links" "$OUT"
done
OUT="$(vp4 "$SS_GOOD" external foreign:1,2,3,4)"
check "🔴 external outranks foreign, and is unchanged"    "0" "$(rc_of "$OUT")"
has   "  the external sentence, not the package one"     "this package declares an external control" "$OUT"
has   "  and the EMPTY caveat"                            "this fabric is up and EMPTY" "$OUT"
hasnt "  no entries gate on a plane nothing was pushed to" "table entries:" "$OUT"

# --- §3.1: up_p4 is what hands verify_p4 the answer -------------------------------------------
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
has   "🔴 up_p4 passes the package's pipeline kind on"    "mode=ndtwin pipe=foreign:1" "$OUT"
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
has   "  an all-NDTwin package passes 'ndtwin'"           "mode=ndtwin pipe=ndtwin" "$OUT"
reset_fix
OUT="$(drive "up_p4 4")"
has   "🔴 and a baseline round passes no kind at all"     "mode=<none> pipe=<none>" "$OUT"

# --- §3.3: 'ndt status' does not want paths it knows nobody installed -------------------------
# The same rule as the sampling rate two sections up, on the other number this report gets out of
# a package fabric. `hosts * (hosts - 1)` is what NDTwin's own control plane installs after LLDP;
# on this fabric there was no LLDP, so the shortfall is about something never attempted.
PROXY_STUBS='
port_open() { [[ "$1" == 8081 ]]; }
curl() { echo "{}"; }
json_len() { echo 4; }
'
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
OUT="$(run_status --check "$PROXY_STUBS")"
has   "🔴 a package fabric is told none were expected"    "4 destination paths reported; none expected" "$OUT"
has   "  naming the dpid and the step the proxy skipped"  "the package's program on dpid 1, proxy skipped lldp_discovery" "$OUT"
hasnt "🔴 and the shortfall is NOT a --check problem"     "proxy reports 4 destination paths, want" "$OUT"
check "  so --check still exits 0"                        "0" "$(rc_of "$OUT")"
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_OK"); up_p4")"
OUT="$(run_status --check "$PROXY_STUBS")"
has   "  an NDTwin-pipeline package still wants twelve"   "4 destination paths (want 12 for 4 hosts)" "$OUT"
has   "🔴 and the shortfall IS a problem there"           "proxy reports 4 destination paths, want 12" "$OUT"
check "  so --check exits 1 on it"                        "1" "$(rc_of "$OUT")"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
