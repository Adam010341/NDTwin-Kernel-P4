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
    # The operator account on the lab laptop has NO blanket sudo -- `sudo -n true` asks for a
    # password there for everyone, Adam included -- only the two grants below. `sudo -n -l <cmd>`
    # answers 0 exactly when that command runs without a prompt, so ask about what is used.
    if sudo -n -l /usr/local/sbin/ndtwin-lab >/dev/null 2>&1 \
       && sudo -n -l /usr/bin/mnexec >/dev/null 2>&1; then
        note "root is reachable for exactly what this needs: sudoers grants ndtwin-lab and mnexec without a prompt"
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

# --- the telemetry knob (TICKET-P3 §2.1) --------------------------------------------------------
#
# [Co-developed with claude code -- Adam]
# 🔴 THE SAME SNAPSHOT-AND-RESTORE AS THE HOST KNOB, AND FOR THE OPPOSITE REASON. `ndt release`
# REFUSES while host_count_override differs, so a step that forgot that one finds out at once.
# NOTHING refuses over p4_proxy/mininet/telemetry_override: `ndt down` does not clear it (§2.1 --
# it is a standing choice about the NEXT fabric, not a description of this one) and `ndt release`
# does not read it. So a step that moved it and walked away decides the next bring-up's telemetry
# source with nothing on any screen saying so, and the only protection is this pair.
#
# 🔴 BYTES, NOT THE WORD, for the same reason as the host knob: the file may carry a comment the
# operator wrote, and rewriting it to a bare word is not a restore.
TEL_KNOB="$REPO/p4_proxy/mininet/telemetry_override"
TEL_ENTRY_COPY=""
snapshot_telemetry_knob() {
    TEL_ENTRY_COPY="$RUN/00_telemetry_override.entry"
    if [[ -e "$TEL_KNOB" ]]; then
        cp -p "$TEL_KNOB" "$TEL_ENTRY_COPY"
        note "telemetry_override snapshot taken ($(tr -d '\n' < "$TEL_KNOB" | head -c 40))"
    else
        TEL_ENTRY_COPY="(absent)"
        note "telemetry_override does not exist; it will be removed again at the end"
    fi
}
restore_telemetry_knob() {
    [[ -n "$TEL_ENTRY_COPY" ]] || return 0
    if [[ "$TEL_ENTRY_COPY" == "(absent)" ]]; then
        [[ -e "$TEL_KNOB" ]] && note "telemetry_override removed (this step created it)"
        rm -f "$TEL_KNOB"; return 0
    fi
    cmp -s "$TEL_ENTRY_COPY" "$TEL_KNOB" 2>/dev/null && return 0
    cp -p "$TEL_ENTRY_COPY" "$TEL_KNOB" || { bad "could NOT put telemetry_override back -- the bytes are in $TEL_ENTRY_COPY"; return 1; }
    cmp -s "$TEL_ENTRY_COPY" "$TEL_KNOB" || { bad "put telemetry_override back and it did NOT take"; return 1; }
    note "telemetry_override put back to what this step found"
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
    # 🔴 `set +e` FIRST, BEFORE ANYTHING ELSE (TICKET-P3 §9 ruling 19②, found by the first live
    # run). This file runs under `set -euo pipefail`, and this function is the EXIT trap -- so a
    # teardown step that exits non-zero killed the trap itself, half way through. Live 02 ended
    # at `== teardown` and live 03 at "stopping the exercise controller": no `ndt down rc=` line,
    # no `ndt release`, and NO VERDICT LINE, while the README promises the last line is PASS or
    # FAIL. A teardown is the one place where every step must run precisely BECAUSE an earlier
    # one failed; `-e` inverts that, and it silently took the release with it -- leaving the lab
    # claimed by a finished run.
    #
    # 🔴 THE rc IS NOT DISCARDED, it is folded in: `ndt down` exiting non-zero becomes a `fail`
    # with its rc below, so the verdict still reports it -- it just no longer prevents the
    # verdict from being printed at all.
    set +e
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
        "$NDT" down > "$RUN/90_down.txt" 2>&1
        local down_rc=$?
        note "ndt down rc=$down_rc -> $(basename "$RUN")/90_down.txt"
        tail -3 "$RUN/90_down.txt" | sed 's/^/     /'
        # 🔴 FOLDED INTO THE VERDICT, NOT INTO AN ABORT (§9 ruling 19②). Before `set +e` this
        # rc ended the trap; now it is reported and the teardown carries on to the release.
        (( down_rc == 0 )) || fail "'ndt down' exited $down_rc -- see $(basename "$RUN")/90_down.txt"
        if [[ -e "$APP_KNOB" ]]; then
            sed 's/^/       /' "$APP_KNOB" >&2
            # 🔴 A FAILURE, not a warning. This file decides which fabric the next `ndt up p4`,
            # the next hand-run p4_testbed_topo.py and the next proxy build. A step that left it
            # behind has left the checkout pointing at an exercise nobody asked for, and a step
            # that reported PASS while doing so would be the green light this whole feature is
            # meant to remove.
            fail "p4_proxy/mininet/app_package_override SURVIVED the teardown (printed above) -- the next 'ndt up p4' and the next proxy read it; remove it by hand"
        else
            note "app_package_override is gone, as 'ndt down' should leave it"
        fi
    fi
    restore_knob || true
    # TICKET-P3 §2.1: beside the host knob, in the same place, for the reason
    # restore_telemetry_knob's own note gives -- nothing downstream refuses over this one.
    restore_telemetry_knob || true
    if (( CLAIMED )); then
        # 🔴 `fail`, NOT `bad` -- THE ROUND MUST NOT PRINT PASS WITH THE LAB STILL CLAIMED.
        # `bad` only prints; the verdict stays whatever it was, so a round whose release did not
        # take could end `PASS`, and the next person to want the lab finds it held by a step
        # that reported success. (The same shape worker E's judge found today.)
        "$NDT" release 2>&1 | sed 's/^/   /' \
            || fail "'ndt release' did not take -- THE LAB IS STILL CLAIMED; run it by hand"
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
    snapshot_telemetry_knob
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

# model_switch_dpids <package-dir> -- the dpids the package's model declares, one per line,
# ascending. The sibling of model_hosts, and for the same reason: the fabric's shape is a fact
# about the package, and a script that types it out is a script that agrees with itself.
model_switch_dpids() {
    "$PY" -c "
import json,sys
t=json.load(open(sys.argv[1]))
for d in sorted(int(n['dpid']) for n in t['nodes'] if n.get('vertex_type')==0): print(d)" \
        "$1/ndtwin/topology.json" 2>/dev/null
}

# --- TICKET-P2-F: the twin's liveness, against what the exercise's controller actually loaded --
#
# 🔴 WHY THIS IS THE ASSERTABLE PROPERTY AND "N up" IS NOT. Under `mode: external` NDTwin loads
# no pipeline; the switches have no program until the exercise's own controller pushes one, and
# the twin's liveness policy (p4LivenessFor) calls a bmv2 with no program Down. Measured
# 2026-09-18: `ndt up` printed `3 switches, 3 up` and `ndt status` one second later read
# `0 up, 3 enabled` -- the green was a read landing between a background retry and the 1 Hz
# pingWorker that undoes it. What IS stable, and what goal (3) is actually about, is the
# correspondence: the switches the twin calls up should be exactly the switches the controller
# loaded a program onto, and the rest should be down. Both of this exercise's controllers load
# s1 and s2 and leave s3 alone, so the expectation is not a constant this file wrote down -- it
# is parsed out of the controller's own log.

# controller_program_set <log> -- the dpids the controller says it loaded a program onto,
# sorted, comma-joined. Empty when it says none.
#
# 🔴 `sN` -> dpid N is the package's own rule, the one tools/p4_exercise/preflight.py asserts as
# "every sN has dpid N". The digits are taken to the end of the token, so `s10` is 10 and not 1.
controller_program_set() {
    [[ -r "$1" ]] || return 0
    "$PY" -c "
import re, sys
seen = set()
for line in open(sys.argv[1], errors='replace'):
    m = re.search(r'Installed P4 Program using SetForwardingPipelineConfig on s([0-9]+)\b', line)
    if m:
        seen.add(int(m.group(1)))
print(','.join(str(d) for d in sorted(seen)))" "$1" 2>/dev/null
}

# kernel_up_set -- the dpids the kernel graph currently says are up, sorted, comma-joined.
# Empty when none is up; empty ALSO when the graph cannot be read, so callers that need to tell
# those apart use the rc (1 = unreadable).
kernel_up_set() {
    local body
    body="$(curl -s --max-time 5 "$KERNEL_URL/ndt/get_graph_data" 2>/dev/null)" || return 1
    printf '%s' "$body" | "$PY" -c "
import json, sys
d = json.load(sys.stdin)
sw = [n for n in d.get('nodes', []) if n.get('vertex_type') == 0]
if not sw:
    raise SystemExit(1)
print(','.join(str(n['dpid']) for n in sorted(sw, key=lambda n: int(n['dpid'])) if n.get('is_up')))" 2>/dev/null
}

# kernel_liveness_rows -- "<dpid> <is_up> <is_enabled>" per switch, for the raw captures.
kernel_liveness_rows() {
    curl -s --max-time 5 "$KERNEL_URL/ndt/get_graph_data" 2>/dev/null | "$PY" -c "
import json, sys
d = json.load(sys.stdin)
for n in sorted((n for n in d.get('nodes', []) if n.get('vertex_type') == 0),
                key=lambda n: int(n['dpid'])):
    print(n['dpid'], bool(n.get('is_up')), bool(n.get('is_enabled')))" 2>/dev/null
}

# await_kernel_up_set <expected> <timeout-s> <outfile> -- wait until the kernel's up-set is
# EXACTLY <expected> (a sorted comma-joined dpid list). rc 0 when it is, 1 on timeout or refusal.
#
# 🔴 AN EMPTY EXPECTED SET IS REFUSED OUTRIGHT, and that is the control this check needs. The
# expectation comes out of the controller's own log; if the log named no switch, then "the twin
# agrees with the controller" is an equality between two empty sets, which is true of a dead
# fabric, a broken parser and a controller that never started alike. It would be the greenest
# possible way to check nothing.
#
# 🔴 "Exactly" and not "at least": the switches OUTSIDE the set have to be down. s3 never gets a
# program in this exercise, so a twin that called it up would be reporting liveness it has no
# evidence for -- which is the shape of the defect this whole check replaces.
await_kernel_up_set() {
    local expected="$1" timeout="${2:-20}" out="$3"
    if [[ -z "$expected" ]]; then
        bad "await_kernel_up_set: the expected set is EMPTY -- the controller log named no switch it loaded a program onto, and an equality between two empty sets proves nothing"
        printf 'REFUSED: empty expected set\n' > "$out"
        return 1
    fi
    local i got="" last="<unreadable>"
    for (( i = 0; i < timeout; i++ )); do
        if got="$(kernel_up_set)"; then
            last="${got:-<none>}"
            if [[ "$got" == "$expected" ]]; then
                { printf 'expected (from the controller log): %s\n' "$expected"
                  printf 'kernel up set:                      %s\n' "$got"
                  printf 'reached after:                      %ds\n' "$i"
                  printf '\ndpid is_up is_enabled\n'
                  kernel_liveness_rows; } > "$out"
                note "kernel up set == $expected after ${i}s   ($(basename "$out"))"
                return 0
            fi
        fi
        sleep 1
    done
    { printf 'expected (from the controller log): %s\n' "$expected"
      printf 'kernel up set (last read):          %s\n' "$last"
      printf 'gave up after:                      %ds\n' "$timeout"
      printf '\ndpid is_up is_enabled\n'
      kernel_liveness_rows; } > "$out"
    bad "the kernel's up set never became '$expected' within ${timeout}s (last: $last) -- see $(basename "$out")"
    return 1
}

# assert_probe_ok_follows_set <switch_state.json> <package-dir> <dpid set> <label> -- the
# proxy's side of the same fact await_kernel_up_set checks on the kernel's: every switch the
# controller loaded a program onto now ANSWERS its liveness probe, and every other switch the
# model declares still does not. rc 1 (and a named `fail` per disagreement) when they disagree.
#
# 🔴 THE UNIVERSE COMES OUT OF THE MODEL, not out of this file. The first draft wrote
# `for d in (1, 2, 3)`, which is true of exercises/p4runtime's pod-topo today and of nothing
# else -- and it made "s3 is computed, not typed" a half-truth: the set was computed and the
# thing it was subtracted from was typed. A four-switch package would have had its fourth switch
# silently unchecked, which is the quietest kind of green there is.
#
# 🔴 AN EMPTY EXPECTED SET IS REFUSED, the same control await_kernel_up_set has and for the same
# reason: with nothing declared programmed, "every switch outside the set is unprogrammed" is a
# sentence about the whole fabric that a dead fabric satisfies perfectly.
assert_probe_ok_follows_set() {
    local ss="$1" pkg="$2" want="$3" label="$4" rc=0 d pok universe
    universe="$(model_switch_dpids "$pkg")"
    if [[ -z "$universe" ]]; then
        fail "$label: could not read the switch dpids the package's model declares, so there is no universe to check the probes against"
        return 1
    fi
    if [[ -z "$want" ]]; then
        fail "$label: the expected set is EMPTY -- 'every switch outside the set is unprogrammed' is then a sentence about the whole fabric, which a dead one satisfies too"
        return 1
    fi
    while read -r d; do
        [[ -n "$d" ]] || continue
        pok="$(jqp "$ss" "((d.get('switches') or {}).get('$d') or {}).get('probe_ok')")"
        if [[ ",$want," == *",$d,"* ]]; then
            note "$label: switch $d probe_ok $pok   (the controller loaded a program onto it)"
            [[ "$pok" == True ]] || { fail "$label: switch $d got a program from the controller and its probe_ok is '$pok', want True"; rc=1; }
        else
            note "$label: switch $d probe_ok $pok   (no controller ever loaded a program onto it)"
            [[ "$pok" == False ]] || { fail "$label: switch $d never got a program and its probe_ok is '$pok', want False"; rc=1; }
        fi
    done <<<"$universe"
    return $rc
}

# run_app_pipeline_kind <package-dir> -- `ndt`'s own answer to "whose program is on these
# switches", out of the same subshell and the same function `ndt up` uses (TICKET-P2-D §3.5).
#
# 🔴 `ndt`'s, not this script's. app_pipeline_kind answers through Package.pipeline_is_ndtwin --
# the real loader, comparing RESOLVED paths -- and a live script that decided for itself whether
# package.json's `pipeline` field looked foreign would be a second answer to the question it is
# here to check, agreeing with the first by construction.
run_app_pipeline_kind() {
    ( set +e
      source "$NDT" >/dev/null 2>&1
      app_pipeline_kind "$1" )
}

# run_verify_p4 <topology-file> <want-paths> [mode] [pipeline-kind] -- `ndt`'s own [3/3], run
# again on its own.
#
# 🔴 `verify_p4` IS A FUNCTION, NOT A VERB. `ndt`'s dispatch is up / down / clean / status /
# check / claim / release / apps / ntg and nothing else, so `ndt verify_p4 ...` prints the usage
# block and exits 2 -- which a step that treated a non-zero rc as "the fabric failed" would then
# report as a broken lab. It is reached the way tests/shell/test_ndt_*.sh reach it: `ndt`
# returns early when sourced, so a subshell has the function and none of its argv handling.
run_verify_p4() {
    ( set +e
      source "$NDT" >/dev/null 2>&1
      verify_p4 "$1" "$2" "${3:-}" "${4:-}" )
}

# pingall_via_ndt <package-dir> -- every ordered host pair, through `ndt`'s OWN dataplane_ok.
#
# 🔴 THIS IS NOT THE LOSS MEASUREMENT, and the two must not be confused. `ndt`'s dataplane_ok is
# `ping -c 2 -W 2` and its exit 0 means AT LEAST ONE of those two replies arrived -- so rc 0 is
# "this pair is not completely dead", never "0% loss". Acceptance (2) is `pingall` 0% loss and
# (3) is 3/3; citing a two-packet exit code as evidence for either would be a claim this
# instrument cannot make. What this function IS: `ndt`'s own check, run so that the step
# exercises the same predicate `ndt up` ends on -- including its separation of the permission
# question from the forwarding one (`mnexec -a <pid> true` first), which is why a missing sudo
# grant here cannot be reported as "the fabric is not forwarding" (ndt:4012). The loss number
# comes from ping_loss / pingall_loss below.
#
# Sourced in a SUBSHELL: `ndt` defines two hundred names and a $REPO of its own.
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
            1) bad=$((bad+1)); echo "NOT-FORWARDING $s -> $d (${ip[$d]})" ;;
            *) untested=$((untested+1)); echo "UNTESTED $s -> $d: ${NDT_DATAPLANE_WHY:-unrecorded}" ;;
          esac
        done
      done
      echo "NDT_DATAPLANE_OK alive=$ok dead=$bad untested=$untested (rc 0 here means >=1 of 2 replies, NOT 0% loss)"
    )
}

# ping_loss <hN> <dst-ip> <count> <raw-file> -- "<loss%> <received>/<transmitted>" for a ping
# run INSIDE that host's namespace, or "UNTESTED <why>" with rc 2.
#
# 🔴 THE LOSS NUMBER COMES FROM PING'S OWN SUMMARY LINE, parsed here, and from nothing else.
# The namespace is found with `ndt`'s host_pid and entered with the same `sudo -n mnexec -a`
# seam dataplane_ok uses -- the form this machine's sudoers allows, and the reader that needs
# no pgrep. The permission question is asked FIRST and separately (`mnexec -a <pid> true`), so
# a missing grant comes back as UNTESTED and can never be rendered as packet loss.
#
# -c 5, not -c 2: a two-packet sample cannot distinguish 0% from 50%, and both acceptance
# conditions are about a rate.
ping_loss() {
    local h="$1" dst="$2" n="${3:-5}" raw="$4" pid out loss recv trans
    pid="$( set +e; source "$NDT" >/dev/null 2>&1; host_pid "$h" )"
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        printf '### %s -> %s: no namespace\n\n' "$h" "$dst" >> "$raw"
        echo "UNTESTED no namespace for $h"; return 2
    fi
    if ! sudo -n mnexec -a "$pid" true >/dev/null 2>&1; then
        printf '### %s -> %s: mnexec could not enter the namespace (pid %s)\n\n' "$h" "$dst" "$pid" >> "$raw"
        echo "UNTESTED mnexec could not enter $h's namespace (pid $pid) -- sudo, not the data plane"; return 2
    fi
    out="$(sudo -n mnexec -a "$pid" ping -c "$n" -W 2 "$dst" 2>&1)"
    printf '### %s -> %s  (pid %s, ping -c %s -W 2)\n%s\n\n' "$h" "$dst" "$pid" "$n" "$out" >> "$raw"
    loss="$(/usr/bin/grep -oE '[0-9]+(\.[0-9]+)?%[[:space:]]+packet loss' <<<"$out" | head -1 | cut -d'%' -f1)"
    trans="$(/usr/bin/grep -oE '[0-9]+ packets transmitted' <<<"$out" | head -1 | cut -d' ' -f1)"
    recv="$(/usr/bin/grep -oE '[0-9]+ received' <<<"$out" | head -1 | cut -d' ' -f1)"
    # 🔴 No summary line is UNTESTED, never 0%. `ping` prints one whatever happens, so its
    # absence means the command did not run -- and an unparsed reading rendered as a good one
    # is the failure mode every check in this suite is written against.
    if [[ -z "$loss" ]]; then
        echo "UNTESTED ping printed no '% packet loss' summary for $h -> $dst"; return 2
    fi
    printf '%s %s/%s\n' "$loss" "${recv:-?}" "${trans:-?}"
    return 0
}

# pingall_loss <package-dir> <count> <raw-file> -- ping_loss over EVERY ORDERED PAIR the model
# names. Prints one line per pair that is not clean, then a verdict line the caller parses.
pingall_loss() {
    local pkg="$1" n="${2:-5}" raw="$3"
    local -A ip
    local k a s d r pairs=0 zero=0 lossy=0 untested=0
    while read -r k a; do ip["$k"]="$a"; done < <(model_hosts "$pkg")
    for s in $(printf '%s\n' "${!ip[@]}" | sort -V); do
      for d in $(printf '%s\n' "${!ip[@]}" | sort -V); do
        [[ "$s" == "$d" ]] && continue
        pairs=$((pairs+1))
        r="$(ping_loss "$s" "${ip[$d]}" "$n" "$raw")"
        case "$r" in
            UNTESTED*) untested=$((untested+1)); echo "$s -> $d (${ip[$d]}): $r" ;;
            "0 "*)     zero=$((zero+1)) ;;
            *)         lossy=$((lossy+1)); echo "$s -> $d (${ip[$d]}): ${r%% *}% packet loss, ${r#* } received" ;;
        esac
      done
    done
    echo "PINGALL_LOSS pairs=$pairs zero_loss=$zero lossy=$lossy untested=$untested"
}

# --- TICKET-P3 §2.7: the generic cell -- link usage follows the iperf path ---------------------
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WHY THIS CELL IS PROGRAM-INDEPENDENT, AND WHY THAT IS THE POINT. Every other acceptance
# this suite carries is a claim about one exercise's program: source_routing's ttl, firewall's
# blocked direction, link_monitor's port field. This one is a claim about NDTwin: while a flow
# crosses the fabric, the twin's `link_bandwidth_usage_bps` must be non-zero on the interfaces
# that carried it and zero on the inter-switch interfaces that did not -- whatever program the
# switches are running. It is the assertable half of TICKET-P3 §2.2's "record the link bytes
# BEFORE you ask what the flow was".
#
# 🔴 GROUND TRUTH IS /proc/net/dev AND THE TWIN IS THE SUBJECT. The on-path set is not written
# down here and is not derived from the topology: it is measured, as the tx_bytes delta on each
# `sN-ethP` across the same window, and it is the only thing the assertion is allowed to be
# about. A path this file typed out would be this file agreeing with itself, and would be wrong
# the first time an exercise's own control plane routed a flow the other way round the pod.
#
# 🔴 THE KEY IS `ndt check`'s KEY, not a second spelling of it. `s<src_dpid>-eth<src_interface>`
# is how cmd_check already joins the twin's edges to /proc/net/dev (ndt:6168-6170), and two
# readers of one join is how the same fabric gets two answers.
#
# 🔴 WHAT THE NUMBERS ARE FOR. The integral is a bit-count over the NOMINAL window (each sample
# weighted by 1/HZ), not over the measured wall clock, and it is used for exactly one thing:
# telling zero from non-zero. A curl that took longer than its slot stretches the real window
# without moving that verdict. The measured span is printed beside it so the reader can see
# both, and no rate is ever quoted from this cell -- `ndt check` is the instrument for rates.

#: An interface that moved less than this across the window did not carry the flow. 10 kB, not
#: "> 0 bytes": LLDP, ARP and the proxy's own probes keep every link faintly busy, and a
#: threshold of zero would put every interface in the fabric on the path.
: "${LINK_USAGE_ONPATH_BYTES:=10000}"
#: The FLOOR an off-path edge has to stay under. Not zero, and the reason is measured rather
#: than defensive (TICKET-P3 §9 ruling 9, R4):
#:
#:   * after worker A's kernel merge the collector banks a sample's frame length BEFORE it asks
#:     what the flow was (§2.2), so ARP, LLDP and IPv6 neighbour discovery all count toward
#:     link usage where they used to be dropped at the `etherType != 0x0800` test;
#:   * on an NDTwin-pipeline fabric the proxy sends an LLDP beacon along every switch-switch
#:     link, and the pipeline samples 1 in 256. One beacon drawn in an eight-second window is
#:     ordinary, and at 1/256 it is banked as 256 x its frame length -- tens of kilobits on an
#:     edge that carried no flow.
#:
#: So "exactly 0 off the path" would have gone red on a fabric doing exactly what it is
#: supposed to do, and it would have done so at random. The floor is the larger of an absolute
#: 5 kbit and 2% of the SMALLEST on-path integral: absolute, so a quiet window still has a
#: bound; relative, so the bound cannot be a fixed number that an 8-second 2 Mbit/s flow
#: (~16 Mbit on-path) dwarfs -- 2% of that is 320 kbit, which is two orders of magnitude above
#: a sampled beacon and two orders below the flow. Every edge's raw integral is printed either
#: way, so a reader can see the margin rather than take the verdict's word for it.
: "${LINK_USAGE_NOISE_BITS:=5000}"
: "${LINK_USAGE_OFFPATH_FRACTION:=0.02}"
#: The twin refreshes usage once a second; sample above that. Same rate as cmd_check.
: "${LINK_USAGE_HZ:=4}"
#: `iperf -u -b 2M -t 8`, TICKET-P3 §2.7 verbatim.
: "${LINK_USAGE_SECONDS:=8}"
: "${LINK_USAGE_RATE:=2M}"

# netdev_tx <out> -- "<iface> <tx_bytes>" for every sN-ethP, from /proc/net/dev. The switches
# are in the ROOT namespace (Mininet's addSwitch defaults to inNamespace=False), so this file
# is where their veth ends are counted and no mnexec is needed.
netdev_tx() {
    "$PY" -c '
import re, sys
out = open(sys.argv[1], "w")
iface = re.compile(r"^s\d+-eth\d+$")
for line in open("/proc/net/dev"):
    if ":" not in line:
        continue
    name, rest = line.split(":", 1)
    name = name.strip()
    if iface.match(name):
        out.write("%s %d\n" % (name, int(rest.split()[8])))
' "$1"
}

# 🔴 An interface that appears in only one of the two readings is NOT on the path and is not
# silently zero either: it is skipped and named on stderr, because "the interface went away
# mid-window" and "it moved no bytes" are different facts and only one of them is a reading.
#: The share of the LARGEST switch-interface delta below which an interface that still passed
#: the absolute byte threshold is called MINOR rather than primary (TICKET-P3 §9 ruling 20①).
: "${LINK_USAGE_PRIMARY_FRACTION:=0.05}"
#: What the sampler can see, used only to print an expected sample count beside a MINOR row.
: "${LINK_USAGE_MTU_BYTES:=1500}"
: "${LINK_USAGE_SAMPLE_RATE:=256}"

# onpath_ifaces <before> <after> [threshold-bytes] -- "<iface> <class> <delta>" per interface
# that moved at least the threshold, sorted. THE MEASUREMENT, not a list this file knows.
#
# 🔴 THREE CLASSES, BECAUSE "CARRIED THE FLOW" AND "THE SAMPLER COULD SEE IT" ARE DIFFERENT
# FACTS (§9 ruling 20①, from the first live run). qos/solution's real deltas were s1-eth3
# 2,162,160 B and s2-eth1 2,162,160 B -- the flow -- plus s1-eth4 15,120 B and s3-eth1
# 15,120 B: TEN datagrams down a side branch. The old rule called all four on-path because all
# four passed 10 kB, and then required a non-zero twin integral on each. But at 1 sample in 256
# the EXPECTED number of samples for ten packets is 0.04 -- so the twin correctly integrated
# zero there, and the cell went red on a twin that was right.
#
#   PRIMARY  delta >= max(<threshold>, 5% of the largest switch-interface delta)
#            -- big enough that a 1/256 sampler must have seen it. Integral MUST be > 0.
#   MINOR    <threshold> <= delta < that 5%
#            -- real traffic the sampler may or may not have caught. ASSERTED ON NEITHER SIDE,
#               and printed with its expected sample count so a reader can see why.
#   (below the threshold it is not listed at all: that is the off-path floor's business.)
#
# 🔴 An interface that appears in only one of the two readings is NOT on the path and is not
# silently zero either: it is skipped and named on stderr, because "the interface went away
# mid-window" and "it moved no bytes" are different facts and only one of them is a reading.
onpath_ifaces() {
    "$PY" -c '
import sys
thresh = int(sys.argv[3]); frac = float(sys.argv[4])
def read(p):
    d = {}
    for line in open(p):
        parts = line.split()
        if len(parts) == 2:
            d[parts[0]] = int(parts[1])
    return d
b, a = read(sys.argv[1]), read(sys.argv[2])
for k in sorted(set(b) ^ set(a)):
    sys.stderr.write("   onpath_ifaces: %s is in only one of the two readings -- skipped\n" % k)
deltas = {k: a[k] - b[k] for k in sorted(set(b) & set(a))}
# 🔴 THE REFERENCE IS THE LARGEST SWITCH-INTERFACE DELTA, not the largest of anything: a host
# interface carrying the same flow is the same bytes counted at the other end, and taking a
# max over both populations would not change the answer here but would make the rule depend on
# which side of a link the biggest number happened to be on.
sw = [d for k, d in deltas.items() if k.startswith("s")]
biggest = max(sw) if sw else 0
primary_at = max(thresh, biggest * frac)
for k, d in sorted(deltas.items()):
    # strictly greater, as before: an interface that moved EXACTLY the threshold is out.
    if d <= thresh:
        continue
    print("%s %s %d" % (k, "P" if d >= primary_at else "M", d))
' "$1" "$2" "${3:-$LINK_USAGE_ONPATH_BYTES}" "$LINK_USAGE_PRIMARY_FRACTION"
}

# onpath_primary <onpath-file> -- just the PRIMARY interface names, one per line.
#
# 🔴 THIS IS THE ONE LIST THAT IS ASSERTED ON, and it has a name so that a caller asking "which
# interfaces did this round actually check?" gets the answer from the same place the assertion
# uses, rather than re-deriving the class rule. `link_usage_round` prints it; the suite reads it.
onpath_primary() { /usr/bin/awk '$2 == "P" {print $1}' "$1"; }

# twin_usage_integral <out> <seconds> [hz] -- poll /ndt/get_graph_data and integrate each
# edge's reported rate over the window. Writes "<key> <bits> <switch|host>" per edge, sorted,
# and a trailing "# samples=<n> span=<s>" comment. rc 1 when the graph never answered.
#
# 🔴 EVERY EDGE, INCLUDING HOST-FACING ONES. cmd_check deliberately compares inter-switch edges
# only, because it is computing a ratio and the two populations have to match. This cell is not
# a ratio: the switch->host edge is where TICKET-P3 §2.2's egress-only sample lands, so leaving
# it out would leave out the half of the mechanism this round is here to see. The kind travels
# with the key so the assertion can hold the two to different standards.
twin_usage_integral() {
    local out="$1" secs="${2:-$LINK_USAGE_SECONDS}" hz="${3:-$LINK_USAGE_HZ}"
    local n=$(( secs * hz )) i t0 t1 tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/twin-usage-XXXXXX")"
    t0="$(date +%s)"
    for (( i = 0; i < n; i++ )); do
        curl -s --max-time 5 "$KERNEL_URL/ndt/get_graph_data" >> "$tmp" 2>/dev/null
        printf '\n\036\n' >> "$tmp"
        sleep "$(awk "BEGIN{print 1/$hz}")"
    done
    t1="$(date +%s)"
    "$PY" -c '
import json, sys
src, out, hz, span = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
dt = 1.0 / hz
bits, kind, n = {}, {}, 0
for blob in open(src, errors="replace").read().split("\036"):
    blob = blob.strip()
    if not blob:
        continue
    try:
        g = json.loads(blob)
    except Exception:
        continue
    sw = {node["dpid"] for node in g.get("nodes", []) if node.get("vertex_type") == 0}
    if not sw:
        continue
    n += 1
    for e in g.get("edges", []):
        try:
            key = "s%s-eth%s" % (e["src_dpid"], e["src_interface"])
            v = float(e.get("link_bandwidth_usage_bps") or 0.0)
        except Exception:
            continue
        if e["src_dpid"] not in sw:
            continue                      # host->switch direction: no sN-ethP carries it
        bits[key] = bits.get(key, 0.0) + v * dt
        kind[key] = "switch" if e.get("dst_dpid") in sw else "host"
fh = open(out, "w")
for key in sorted(bits):
    fh.write("%s %.3f %s\n" % (key, bits[key], kind[key]))
fh.write("# samples=%d span=%ss\n" % (n, span))
sys.exit(0 if n else 1)
' "$tmp" "$out" "$hz" "$(( t1 - t0 ))"
    local rc=$?
    rm -f "$tmp"
    (( rc == 0 )) || bad "twin_usage_integral: /ndt/get_graph_data never answered with a switch in it -- there is no twin reading for this window"
    return $rc
}

# assert_link_usage_follows_path <onpath-file> <integral-file> <label> -- THE CELL.
#   * every interface that carried the flow has a twin edge, and that edge integrated > 0;
#   * every inter-switch edge that did NOT carry it integrated to exactly 0;
#   * every host-facing edge that did not carry it stayed under LINK_USAGE_NOISE_BITS.
# rc 0 when all three hold. Each disagreement is a named `fail`.
#
# 🔴 AN EMPTY ON-PATH SET IS REFUSED. With nothing measured as on-path the first clause is
# vacuous and the second is "every edge is zero", which a fabric that moved no packet at all
# satisfies perfectly -- and that fabric is exactly what a broken iperf, a missing sudo grant
# and a dead switch all look like. Same control await_kernel_up_set and
# assert_probe_ok_follows_set carry, for the same reason.
#
# 🔴 AN ON-PATH INTERFACE WITH NO TWIN EDGE IS RED, not skipped. "The twin does not model this
# link" is the most important thing this cell can find, and skipping it would report the gap as
# a clean run.
# link_usage_floor <onpath-file> <integral-file> -- the documented off-path bound for this
# window: max(LINK_USAGE_NOISE_BITS, LINK_USAGE_OFFPATH_FRACTION x the SMALLEST on-path
# integral). Printed by the assertion so the number is in the raw beside the readings it judged.
link_usage_floor() {
    local onpath="$1" integral="$2"
    "$PY" -c '
import sys
floor_abs = float(sys.argv[3]); frac = float(sys.argv[4])
want = set()
for line in open(sys.argv[1]):
    parts = line.split()
    # PRIMARY ONLY: the floor is a fraction of what the flow actually deposited, and the
    # integral of a MINOR row is expected to be 0 -- including one would drive the floor to 0.
    # (No apostrophes in here: this block is inside a single-quoted shell string.)
    if len(parts) >= 2 and parts[1] == "P":
        want.add(parts[0])
vals = []
for line in open(sys.argv[2]):
    parts = line.split()
    if len(parts) == 3 and parts[0] in want:
        try:
            vals.append(float(parts[1]))
        except ValueError:
            pass
print("%.3f" % max(floor_abs, frac * min(vals)) if vals else "%.3f" % floor_abs)
' "$onpath" "$integral" "$LINK_USAGE_NOISE_BITS" "$LINK_USAGE_OFFPATH_FRACTION"
}

assert_link_usage_follows_path() {
    local onpath="$1" integral="$2" label="$3" rc=0 key bits kind floor
    if [[ ! -s "$onpath" ]]; then
        fail "$label: the on-path interface set is EMPTY -- nothing measurably carried the flow, so 'usage follows the path' is a sentence about a fabric that moved no packets"
        return 1
    fi
    if [[ ! -s "$integral" ]]; then
        fail "$label: there is no twin integral for this window"
        return 1
    fi
    # 🔴 PRIMARY IS ASSERTED, MINOR IS PRINTED (§9 ruling 20①). A MINOR interface carried real
    # bytes -- too few for a 1/256 sampler to be expected to catch any of them -- so neither
    # "the twin saw it" nor "the twin did not" is a finding, and asserting either way would
    # make a correct twin red at random. What IS owed to the reader is the number and what the
    # sampler could have been expected to do with it.
    local cls delta expect_n
    while read -r key cls delta; do
        [[ -n "$key" ]] || continue
        read -r _ bits kind < <(/usr/bin/grep -m1 "^$key " "$integral"; printf ' \n')
        if [[ -z "$kind" ]]; then
            if [[ "$cls" == P ]]; then
                fail "$label: $key carried the flow and the twin has NO edge for it -- the link is not modelled, which is a gap this cell exists to find"
                rc=1
            else
                note "$label: minor    $key  ${delta} B moved, and the twin has no edge for it (not asserted)"
            fi
            continue
        fi
        if [[ "$cls" != P ]]; then
            expect_n="$(awk "BEGIN{printf \"%.3f\", $delta / ($LINK_USAGE_MTU_BYTES * $LINK_USAGE_SAMPLE_RATE)}")"
            note "$label: minor    $key  ${delta} B moved, twin $bits bit  ($kind); expected samples = ${delta} / (${LINK_USAGE_MTU_BYTES} x ${LINK_USAGE_SAMPLE_RATE}) = $expect_n -- NOT asserted"
            continue
        fi
        if [[ "$(awk "BEGIN{print ($bits > 0) ? 1 : 0}")" == 1 ]]; then
            note "$label: on-path  $key  $bits bit  ($kind)  [primary, ${delta} B]"
        else
            fail "$label: $key carried the flow ($delta B, primary) and the twin integrated $bits bit over the window"
            rc=1
        fi
    done < "$onpath"
    floor="$(link_usage_floor "$onpath" "$integral")"
    note "$label: off-path floor $floor bit   = max(${LINK_USAGE_NOISE_BITS}, ${LINK_USAGE_OFFPATH_FRACTION} x the smallest PRIMARY on-path integral)"
    while read -r key bits kind; do
        [[ "$key" == \#* || -z "$key" ]] && continue
        # 🔴 MINOR ROWS ARE NOT OFF-PATH EITHER. They moved real bytes; holding them to the
        # off-path floor would be asserting the opposite of what the class means.
        /usr/bin/awk -v k="$key" '$1 == k {found=1} END{exit !found}' "$onpath" && continue
        # 🔴 EVERY OFF-PATH EDGE'S RAW INTEGRAL IS RECORDED, judged or not (§9 ruling 9, R4).
        # The verdict is a comparison against a floor, and a floor only means something beside
        # the numbers it was applied to -- otherwise "under the bound" and "exactly zero" read
        # the same in the raw, and the margin is the whole question.
        note "$label: off-path $key  $bits bit  ($kind)"
        if [[ "$(awk "BEGIN{print ($bits >= $floor) ? 1 : 0}")" == 1 ]]; then
            if [[ "$kind" == switch ]]; then
                fail "$label: $key is an inter-switch link that did NOT carry the flow and the twin integrated $bits bit on it, at or over the $floor bit floor"
            else
                fail "$label: $key is a host-facing link off the path and the twin integrated $bits bit, at or over the $floor bit floor"
            fi
            rc=1
        fi
    done < "$integral"
    (( rc == 0 )) && note "$label: link usage follows the iperf path (off-path under $floor bit)"
    return $rc
}

# assert_link_usage_absent <onpath-file> <integral-file> <label> -- THE POSITIVE CONTROL.
# The same window with the telemetry source set to `none`: every interface that carried the
# flow must integrate to EXACTLY zero in the twin. Without this the cell above has no
# discriminating power -- a twin that reported a constant non-zero on every edge would pass it.
assert_link_usage_absent() {
    local onpath="$1" integral="$2" label="$3" rc=0 key bits kind cls delta
    if [[ ! -s "$onpath" ]]; then
        fail "$label (control): the on-path interface set is EMPTY -- with no traffic measured, 'the twin reports nothing' is true of any twin at all"
        return 1
    fi
    # 🔴 THE CONTROL JUDGES PRIMARIES ONLY, like the assertion it controls (§9 ruling 20①). A
    # MINOR row is expected to read 0 with sampling ON, so "0 with sampling off" says nothing.
    while read -r key cls delta; do
        [[ -n "$key" ]] || continue
        [[ "$cls" == P ]] || continue
        read -r _ bits kind < <(/usr/bin/grep -m1 "^$key " "$integral" 2>/dev/null; printf ' \n')
        if [[ -z "$kind" ]]; then
            note "$label (control): $key has no twin edge at all"
            continue
        fi
        if [[ "$(awk "BEGIN{print ($bits != 0) ? 1 : 0}")" == 1 ]]; then
            fail "$label (control): telemetry is off and the twin still integrated $bits bit on $key, which carried the flow -- the cell above has no discriminating power"
            rc=1
        else
            note "$label (control): $key carried the flow and the twin reports 0 bit, as it must with no sampling"
        fi
    done < "$onpath"
    (( rc == 0 )) && note "$label (control): with telemetry off the twin reports nothing on the path"
    return $rc
}

# link_usage_round <package-dir> <label> <out-dir> [expect] [dst-host] -- the measurement, once.
# `expect` is `follows` (the cell) or `absent` (the positive control).
#
# 🔴 ONE IMPLEMENTATION, TWO CALLERS. live-p1/05 runs it three times and drive_exercise.py's
# ndtwin arm runs it once at the end of every exercise that HAS a path (TICKET-P3 §2.7). A
# driver with its own copy of this rule would be a second instrument, and "the same cell on 13
# exercises" would be a comparison of thirteen runs of one script against three of another.
#
# 🔴 h1 -> the LAST host the package's model declares, so the flow crosses the fabric rather
# than staying on one switch. Which hosts those are is read from the model, never typed.
#
# 🔴 <dst-host> OVERRIDES THAT LAST HOST, AND TWO EXERCISES NEED IT. "The last host" is a
# property of the MODEL, and for two packages it is a host the exercise deliberately cannot
# reach: exercises/multicast's sig-topo group replicates ports 1,2,3 and leaving h4 out is the
# student's own TODO (README:122), and exercises/p4runtime's controller wires the h1<->h2
# tunnel and never touches s3. Measuring to those would produce an EMPTY on-path set, which
# this cell refuses -- correctly, and about the wrong thing. The destination is a PARAMETER of
# the measurement; the PATH is still measured and never typed.
link_usage_round() {
    local pkg="$1" label="$2" dir="$3" expect="${4:-follows}" want_dst="${5:-}"
    local src dst dst_ip pid_s pid_c rc=0
    mkdir -p "$dir"
    src="$(model_hosts "$pkg" | head -1 | cut -d' ' -f1)"
    if [[ -n "$want_dst" ]]; then
        read -r dst dst_ip < <(model_hosts "$pkg" | /usr/bin/grep -m1 "^$want_dst ")
        if [[ -z "$dst_ip" ]]; then
            fail "$label: the package model declares no host '$want_dst' to run a flow to"
            return 1
        fi
    else
        read -r dst dst_ip < <(model_hosts "$pkg" | tail -1)
    fi
    if [[ -z "$src" || -z "$dst" || -z "$dst_ip" || "$src" == "$dst" ]]; then
        fail "$label: the package model does not name two hosts to run a flow between (src='$src' dst='$dst')"
        return 1
    fi
    # 🔴 WHICH TWO HOSTS, SAID BEFORE ANYTHING IS ASKED ABOUT THEM. The pair is a decision --
    # the model's first host and either its last or the one the caller named -- and the
    # refusals below are about whether those namespaces exist. Printing the decision after
    # the refusal would leave a reader of a red run guessing which hosts it meant.
    note "$label: $src -> $dst ($dst_ip), iperf -u -b $LINK_USAGE_RATE -t $LINK_USAGE_SECONDS"
    pid_s="$( set +e; source "$NDT" >/dev/null 2>&1; host_pid "$dst" )"
    pid_c="$( set +e; source "$NDT" >/dev/null 2>&1; host_pid "$src" )"
    if [[ ! "$pid_s" =~ ^[0-9]+$ || ! "$pid_c" =~ ^[0-9]+$ ]]; then
        fail "$label: no namespace for $src ($pid_c) or $dst ($pid_s) -- this is a permission/namespace answer, never a reading about link usage"
        return 2
    fi
    netdev_tx "$dir/netdev.before"
    sudo -n mnexec -a "$pid_s" iperf -s -u > "$dir/iperf_server.txt" 2>&1 &
    local srv=$!
    sleep 1
    sudo -n mnexec -a "$pid_c" iperf -c "$dst_ip" -u -b "$LINK_USAGE_RATE" -t "$LINK_USAGE_SECONDS" \
        > "$dir/iperf_client.txt" 2>&1 &
    local cli=$!
    twin_usage_integral "$dir/twin_integral.txt" "$LINK_USAGE_SECONDS" "$LINK_USAGE_HZ" || rc=1
    wait "$cli" 2>/dev/null || true
    netdev_tx "$dir/netdev.after"
    # 🔴 The server is stopped by the pid this function started, never by name (CLAUDE.md).
    kill "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true
    onpath_ifaces "$dir/netdev.before" "$dir/netdev.after" > "$dir/onpath.txt" 2>"$dir/onpath.err"
    [[ -s "$dir/onpath.err" ]] && sed 's/^/   /' "$dir/onpath.err"
    # 🔴 THE TWO CLASSES ARE NAMED SEPARATELY (§9 ruling 20①). One list mixing P and M would
    # read as "these all carried the flow and were all checked", and only the P rows were.
    note "$label: primary=$(onpath_primary "$dir/onpath.txt" | tr '\n' ' ')  minor=$(/usr/bin/awk '$2=="M"{printf "%s ", $1}' "$dir/onpath.txt")"
    if [[ "$expect" == absent ]]; then
        assert_link_usage_absent "$dir/onpath.txt" "$dir/twin_integral.txt" "$label" || rc=1
    else
        assert_link_usage_follows_path "$dir/onpath.txt" "$dir/twin_integral.txt" "$label" || rc=1
    fi
    printf 'LINK_USAGE %s expect=%s primary=%s minor=%s rc=%s\n' \
        "$label" "$expect" \
        "$(/usr/bin/awk '$2=="P"{n++} END{print n+0}' "$dir/onpath.txt" 2>/dev/null || echo 0)" \
        "$(/usr/bin/awk '$2=="M"{n++} END{print n+0}' "$dir/onpath.txt" 2>/dev/null || echo 0)" "$rc"
    return $rc
}
