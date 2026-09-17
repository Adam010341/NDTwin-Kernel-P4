#!/usr/bin/env bash
#
# Shared preamble for the three P1 live acceptance steps. Sourced, never run.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 ONE COPY, and the ticket lists four files rather than five. Three copies of sixty lines of
# claim handling, root checks and teardown traps is the shape this repo keeps recording as a
# defect -- up_p4 and up_ovs's two copies of the H4 unpacking, with one of them wrong for a day
# (tests/shell/test_ndt_up_down_robust.sh section 11). The deviation is written up in
# P1-C-SUMMARY.
#
# What every step gets from here:
#   * a refusal when root is not available and when the lab is not free -- BEFORE anything is
#     started, and before the claim is taken;
#   * a claim of its own, and an EXIT trap that tears the lab down, puts the P4 host knob back
#     and releases, in that order. `ndt release` refuses while the knob differs from what the
#     round started at (E-11b), so the restore is not optional and is not --force;
#   * a run directory under runs/<UTC>_<step>/ that every capture is written into;
#   * one verdict line, PASS or FAIL <reason>.
#
# 🔴 NOTHING HERE USES pkill/pgrep. The only process this suite starts by hand is the exercise
# controller in step 03, and it is stopped by the pid `setsid` reported.

# --- where things are ------------------------------------------------------------------------
LIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$LIVE_DIR/../../../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
PY="$REPO/p4_proxy/venv/bin/python"
KNOB="$REPO/p4_proxy/mininet/host_count_override"
APP_KNOB="$REPO/p4_proxy/mininet/app_package_override"
PKG_ROOT="$REPO/.test_run/packages"
PROXY_URL="http://localhost:8081"
KERNEL_URL="http://localhost:8000"
: "${NDT_OWNER:=live-p1}"
export NDT_OWNER
: "${CLAIM_MINUTES:=45}"

STEP=""
RUN=""
VERDICT_RC=0
VERDICT_WHY=""
KNOB_ENTRY_COPY=""
CLAIMED=0
CTRL_PID=""

# --- output ----------------------------------------------------------------------------------
say()  { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
bad()  { printf '   !! %s\n' "$*" >&2; }
# fail <reason> -- record the first reason and keep going only where that is safe. Every caller
# that must stop says so itself; this never exits on its own, because a step that stopped in the
# middle still has a lab to tear down and a claim to give back.
fail() { VERDICT_RC=1; [[ -z "$VERDICT_WHY" ]] && VERDICT_WHY="$*"; bad "$*"; }
die()  { bad "$*"; exit 2; }

# --- refusals, before anything is touched -----------------------------------------------------
#
# 🔴 ROOT IS REQUIRED BUT EUID 0 IS NOT. `ndt` is designed to be run as the operator with
# passwordless grants for ndtwin-lab and mnexec (tools/test_workflow/sudo_surface.sh); running
# the whole script as root works too, but it leaves root-owned files in .test_run/ and in this
# directory's runs/, which then break the operator's next unprivileged `ndt`. So what is
# required is that root is REACHABLE without a prompt, and either way of having it is accepted.
require_root() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        note "running as root (uid 0)"
        bad  "note: files written under runs/ and .test_run/ will be root-owned."
        bad  "      'sudo chown -R $(logname 2>/dev/null || echo "$SUDO_USER") ...' afterwards, or"
        bad  "      run this WITHOUT sudo -- the grants below are all this needs."
        return 0
    fi
    if sudo -n true 2>/dev/null; then
        note "root is available without a prompt (sudo -n)"
        return 0
    fi
    die "refusing: this needs root and cannot ask for it. Either grant the sudoers lines
       tools/test_workflow/sudo_surface.sh prints (ndtwin-lab and mnexec), or run this under
       sudo. A step that cannot reach root would report a data plane that never forwarded."
}

# require_free_lab -- `ndt status` first, then read the two fields that say somebody else is
# using it. Both, not one: `measuring=` is the only channel a session has for "you cannot see
# what I am running from the process table" (ROLE-4 T2d), and a claim can be held with nothing
# declared.
require_free_lab() {
    say "lab state before this step"
    "$NDT" status > "$RUN/00_status_before.txt" 2>&1 || true
    sed -n '/^lab/,/^$/p' "$RUN/00_status_before.txt" | sed 's/^/   /'
    local claim="$REPO/.test_run/lab.claim" owner expires measuring now
    now="$(date +%s)"
    if [[ -f "$claim" ]]; then
        owner="$(sed -n 's/^owner=//p' "$claim" | head -1)"
        expires="$(sed -n 's/^expires=//p' "$claim" | head -1)"
        measuring="$(sed -n 's/^measuring=//p' "$claim" | head -1)"
        if [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > now )) && [[ "$owner" != "$NDT_OWNER" ]]; then
            die "refusing: the lab is claimed by '$owner' until $(date -d "@$expires" '+%H:%M:%S').
       ${measuring:+They declared: measuring=$measuring
       }Wait for it, or take the lab over deliberately -- not from this script."
        fi
        if [[ -n "$measuring" ]] && [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > now )); then
            die "refusing: the live claim DECLARES a measurement in progress:
         measuring=$measuring
       Bringing a fabric up under it loses that run, and nothing else here would say so."
        fi
    fi
    note "lab is free"
}

# --- the knob, and giving the lab back ---------------------------------------------------------
#
# 🔴 BYTES, NOT THE NUMBER. host_count_in skips comments and leading whitespace, so the file can
# read 4 without being the two bytes `4\n`; "write $cur back" would rewrite a hand-annotated file
# into a bare number and call it a restore. Same reasoning as `ndt`'s own knob_snapshot.
snapshot_knob() {
    KNOB_ENTRY_COPY="$RUN/00_host_count_override.entry"
    if [[ -e "$KNOB" ]]; then
        cp -p "$KNOB" "$KNOB_ENTRY_COPY"
        note "host_count_override snapshot taken ($(tr -d '\n' < "$KNOB" | head -c 40))"
    else
        KNOB_ENTRY_COPY="(absent)"
        note "host_count_override does not exist; it will be removed again at the end"
    fi
}
restore_knob() {
    [[ -n "$KNOB_ENTRY_COPY" ]] || return 0
    if [[ "$KNOB_ENTRY_COPY" == "(absent)" ]]; then
        rm -f "$KNOB"; note "host_count_override removed (this step created it)"; return 0
    fi
    cmp -s "$KNOB_ENTRY_COPY" "$KNOB" 2>/dev/null && return 0
    cp -p "$KNOB_ENTRY_COPY" "$KNOB" || { bad "could NOT put host_count_override back -- the bytes are in $KNOB_ENTRY_COPY"; return 1; }
    cmp -s "$KNOB_ENTRY_COPY" "$KNOB" || { bad "put host_count_override back and it did NOT take"; return 1; }
    note "host_count_override put back to what this step found"
}

take_claim() {   # take_claim <note>
    say "claiming the lab"
    if ! "$NDT" claim "$CLAIM_MINUTES" "$1" 2>&1 | sed 's/^/   /'; then
        die "refusing: 'ndt claim' would not take. Nothing was started."
    fi
    CLAIMED=1
}

# finish -- the EXIT trap. Order matters and is not the obvious one:
#   1. the controller this step started, by the pid setsid reported (never pkill);
#   2. `ndt down`, which is also what removes p4_proxy/mininet/app_package_override -- it is
#      cleared by `verify clean`, the last step of that command;
#   3. the P4 host knob, put back to the bytes this step found;
#   4. the claim -- last, because `ndt release` refuses while the knob is still moved (E-11b),
#      and a --force here would be this script signing for a state it created.
finish() {
    local rc=$?
    trap - EXIT INT TERM
    say "teardown"
    if [[ -n "$CTRL_PID" ]] && kill -0 "$CTRL_PID" 2>/dev/null; then
        note "stopping the exercise controller (pid $CTRL_PID)"
        kill "$CTRL_PID" 2>/dev/null || true
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$CTRL_PID" 2>/dev/null || break; sleep 1; done
        kill -0 "$CTRL_PID" 2>/dev/null && bad "controller pid $CTRL_PID is still alive after TERM"
    fi
    # 🔴 GATED ON THE CLAIM, and the claim is taken AFTER every refusal. A step that refused --
    # no root, a lab somebody else holds, a package that will not pre-flight -- has started
    # nothing, and a teardown on that path would be this script destroying a lab it was just
    # told to keep its hands off. The same flag gates the release, for the same reason.
    if (( CLAIMED )) && [[ -n "$RUN" ]]; then
        "$NDT" down > "$RUN/90_down.txt" 2>&1; note "ndt down rc=$? -> $(basename "$RUN")/90_down.txt"
        tail -3 "$RUN/90_down.txt" | sed 's/^/     /'
        if [[ -e "$APP_KNOB" ]]; then
            bad "🔴 p4_proxy/mininet/app_package_override SURVIVED the teardown:"
            sed 's/^/       /' "$APP_KNOB" >&2
            bad "   the next 'ndt up p4' and the next proxy read it. Remove it by hand."
        else
            note "app_package_override is gone, as 'ndt down' should leave it"
        fi
    fi
    restore_knob || true
    if (( CLAIMED )); then
        "$NDT" release 2>&1 | sed 's/^/   /' || bad "'ndt release' did not take -- run it by hand"
    fi
    printf '\n'
    # 🔴 A REFUSAL KEEPS ITS OWN CODE. `die` exits 2 and 2 means "nothing was started" -- the
    # same vocabulary `ndt` uses, and the distinction the README tells Adam to read. Flattening
    # it into the 1 that means "this ran and something was wrong" would hide the one case where
    # there is nothing to look at on the machine.
    if (( rc == 2 )) && (( VERDICT_RC == 0 )); then
        rmdir "$RUN" 2>/dev/null || true      # empty: the refusal captured nothing
        printf 'REFUSED %s -- nothing was started\n' "$STEP"
        exit 2
    fi
    if (( rc != 0 )) && (( VERDICT_RC == 0 )); then VERDICT_RC=1; VERDICT_WHY="the script exited $rc before its own verdict"; fi
    # The raw path first and the verdict LAST, because the README tells Adam what the last line
    # should read and a path underneath it would be the last line instead.
    printf 'raw: %s\n' "${RUN:-<none>}"
    if (( VERDICT_RC == 0 )); then
        printf 'PASS %s\n' "$STEP"
    else
        printf 'FAIL %s -- %s\n' "$STEP" "$VERDICT_WHY"
    fi
    exit "$VERDICT_RC"
}

# start_step <name> -- make the run directory, arm the trap, and do the two refusals.
start_step() {
    STEP="$1"
    RUN="$LIVE_DIR/runs/$(date -u '+%Y-%m-%dT%H%M%SZ')_$STEP"
    mkdir -p "$RUN" || die "could not create $RUN"
    trap finish EXIT INT TERM
    printf '== %s\n   repo: %s\n   raw : %s\n   owner: %s\n' "$STEP" "$REPO" "$RUN" "$NDT_OWNER"
    [[ -x "$NDT" ]] || die "no ndt at $NDT"
    [[ -x "$PY" ]]  || die "no proxy venv interpreter at $PY -- python3 -m venv p4_proxy/venv && p4_proxy/venv/bin/pip install -r p4_proxy/requirements.txt"
    require_root
    require_free_lab
    snapshot_knob
}

# --- captures ---------------------------------------------------------------------------------
# get_json <url> <file> -- save the body, pretty-printed when it parses. rc 1 when there is no
# usable answer, and the file then holds whatever did arrive: an endpoint that answered HTML or
# nothing is a reading, and deleting it would be deleting the reading.
get_json() {
    local url="$1" out="$2"
    curl -s --max-time 10 "$url" > "$out.raw" 2>"$out.curl.err" || true
    if "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
json.dump(d, open(sys.argv[2],'w'), indent=2, sort_keys=True)
open(sys.argv[2],'a').write('\n')" "$out.raw" "$out" 2>/dev/null; then
        rm -f "$out.raw" "$out.curl.err"
        return 0
    fi
    bad "no usable JSON from $url (kept as $(basename "$out").raw)"
    return 1
}

# jqp <file> <python-expr over d> -- one value out of a saved capture, printed.
jqp() { "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))" "$1" "$2" 2>/dev/null; }

# model_hosts <package-dir> -- '<name> <ip>' per host, sorted by the number in the name.
model_hosts() {
    "$PY" -c "
import json,sys
t=json.load(open(sys.argv[1]))
hs=[n for n in t['nodes'] if n.get('vertex_type')==1]
hs.sort(key=lambda n:(int(n['device_name'][1:]) if n['device_name'][1:].isdigit() else 0))
for n in hs: print(n['device_name'], (n.get('ip') or [''])[0])" "$1/ndtwin/topology.json"
}

# run_verify_p4 <topology-file> <want-paths> [mode] -- `ndt`'s own [3/3], run again on its own.
#
# 🔴 `verify_p4` IS A FUNCTION, NOT A VERB. `ndt`'s dispatch is up / down / clean / status /
# check / claim / release / apps / ntg and nothing else, so `ndt verify_p4 ...` prints the usage
# block and exits 2 -- which a step that treated a non-zero rc as "the fabric failed" would then
# report as a broken lab. It is reached the way tests/shell/test_ndt_*.sh reach it: `ndt`
# returns early when sourced, so a subshell has the function and none of its argv handling.
run_verify_p4() {
    ( set +e
      source "$NDT" >/dev/null 2>&1
      verify_p4 "$1" "$2" "${3:-}" )
}

# pingall_via_ndt <package-dir> -- every ordered host pair, through `ndt`'s OWN dataplane_ok.
#
# 🔴 `ndt`'s helper and not a hand-rolled one. dataplane_ok asks the permission question
# separately from the forwarding question -- `mnexec -a <pid> true` first -- so a missing sudo
# grant cannot be reported as "the fabric is not forwarding", which is the exact manufactured
# claim ndt:4012 records. It also finds the namespace by host_pid, which is the reader that does
# not need pgrep. Sourced in a SUBSHELL: `ndt` defines two hundred names and a $REPO of its own.
pingall_via_ndt() {
    local pkg="$1"
    ( set +e
      source "$NDT" >/dev/null 2>&1
      declare -A ip
      while read -r n a; do ip["$n"]="$a"; done < <(model_hosts "$pkg")
      local ok=0 bad=0 untested=0 s d
      for s in "${!ip[@]}"; do
        for d in "${!ip[@]}"; do
          [[ "$s" == "$d" ]] && continue
          dataplane_ok "$s" "${ip[$d]}"
          case $? in
            0) ok=$((ok+1)) ;;
            1) bad=$((bad+1)); echo "LOSS $s -> $d (${ip[$d]})" ;;
            *) untested=$((untested+1)); echo "UNTESTED $s -> $d: ${NDT_DATAPLANE_WHY:-unrecorded}" ;;
          esac
        done
      done
      echo "PINGALL ok=$ok loss=$bad untested=$untested"
    )
}
