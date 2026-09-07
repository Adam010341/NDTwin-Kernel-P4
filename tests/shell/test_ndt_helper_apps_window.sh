#!/usr/bin/env bash
#
# 3-51: the two apps the LAB HELPER starts had no window, ever -- and the check that was
# supposed to notice looked in the wrong tree.
#
# [Co-developed with claude code -- Adam]
#
# Measured live 2026-09-07, lw16pw (P4 4 hosts, 1/1, rounds/08-round2.md:174-200):
#
#     ndt apps start sim     ok sim started (tmux: sim, pid(s) 1169930 1169932)
#     ndt apps stop sim      sim: no pidfile and no live process -- no window, so no rule
#                            can be dated -- tally all zeros
#     ndt apps orphans       rc 0, "(no app had a datable window in this run)"
#     ndt status --check     residue none -- ... (asked, not assumed)
#
# Nothing was asked. Four separate things had to be true at once for that to print:
#
#   1. `app_start` for energy|sim goes through `sudo ndtwin-lab <name>-start`, which starts the
#      program as root inside tmux, and NEVER wrote .test_run/pids/app_<name>.pid. The other
#      three apps get one from app_spawn.
#   2. `app_started_at` read only that pidfile. A live process it could have asked `ps -o
#      etimes=` was not consulted, so a sim that had been up for twelve seconds had no window.
#   3. the discriminator that keeps a never-started app from being reported as "could not
#      check" reads a LOG -- and it read $REPO's, while the helper writes sim's to
#      $KERNEL_DIR/.test_run/logs/app_sim.log with KERNEL_DIR defaulting to the main checkout
#      (ndtwin-lab:98,301). In a worktree that file is always absent, so the answer was always
#      "no sign it ever ran here". The 04:42 log is in the main checkout to this day.
#   4. energy has no disk log at all -- the helper gives it no `script -f` -- so for energy the
#      question has no channel on any machine, and "no sign it ever ran here" was a claim
#      nobody had checked.
#
# Adam's ruling (DECISIONS.md, grill §4E round 2, E-8): fix the counter, not the helper --
# `ndt` writes the pidfile, falls back to the live process, and resolves the helper's KERNEL_DIR
# READ-ONLY by the helper's own rule. /usr/local/sbin/ndtwin-lab, sudoers and
# tools/test_workflow/ndtwin-lab are not touched by this branch.
#
# 🔴 THE SUITE MUST NOT DEPEND ON THE MACHINE IT RUNS ON, in both directions:
#   * LAB_CONF is redirected into a temp dir, so nothing reads /etc and no fixture needs root;
#   * where a case is about the helper's real default it is compared against the helper's own
#     SOURCE TEXT, not against a string copied into this file -- a copy that drifts silently is
#     the defect this whole area is about;
#   * fixtures are `( exec -a "/nonexistent/NDT-TEST-FIXTURE/..." sleep N )&`, so /proc is a
#     real witness and a leaked one cannot be mistaken for an app;
#   * `sudo` and `lab_session` are replaced by shell functions: nothing here reaches the real
#     ndtwin-lab, asks for root, or touches a claimed lab.
#
# Run:  bash tests/shell/test_ndt_helper_apps_window.sh
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; exit 2; }
for sib in ports.sh sudo_surface.sh; do
    [[ -r "$(dirname "$NDT")/$sib" ]] || { echo "ndt needs $sib beside it; not at $(dirname "$NDT")/$sib"; exit 2; }
done
# The helper is the AUTHORITY for group 1 and is read, never run and never written.
HELPER="$HERE/../../tools/test_workflow/ndtwin-lab"
[[ -r "$HELPER" ]] || { echo "no ndtwin-lab at $HELPER"; exit 2; }

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: [$2]  actual: [$3]"; }
has()   { grep -qF -- "$2" <<<"$3" && t_ok "$1" || t_bad "$1" "no match for '$2'"; }
hasnt() { grep -qF -- "$2" <<<"$3" && t_bad "$1" "unexpected '$2' in the output" || t_ok "$1"; }
section() { printf '\n%s\n' "$1"; }
note()  { printf '  note     %s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-helper-window-XXXXXX")"
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs" "$FIX/conf"
# The tree a config file could point at: it must contain the bridge script, because the helper
# refuses a KERNEL_DIR that does not (ndtwin-lab lab_config_parse) and a copy that accepted one
# the helper rejects would point `ndt` at a tree root is not running in.
mkdir -p "$FIX/othertree/p4_proxy/mininet" "$FIX/othertree/.test_run/logs"
: > "$FIX/othertree/p4_proxy/mininet/ntg_bmv2_topo.py"

FIXTURE_TTL=120
FIXTURE_REG="$FIX/fixtures"
: > "$FIXTURE_REG"
reap_fixtures() {
    local pid left=0
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || continue
        kill -KILL "$pid" 2>/dev/null
    done < "$FIXTURE_REG"
    sleep 0.3
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] && left=$((left + 1))
    done < "$FIXTURE_REG"
    echo "$left"
}
# Group 10's parent is a bash script, not a `sleep`, so reap_fixtures cannot see it -- and it
# leads a process group of its own. Killed BY THE GROUP, and only after /proc confirms the
# process is this suite's fixture: a group id is a pid like any other and the number could have
# been recycled into a stranger. Never by name: no pkill, no pgrep.
reap_two_layer() {
    local left=0
    [[ "${TWO_PARENT:-}" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
    if [[ "$(tr '\0' ' ' 2>/dev/null < "/proc/$TWO_PARENT/cmdline")" == *"$FIX/twolayer"* ]]; then
        kill -KILL -"$TWO_PARENT" 2>/dev/null || kill -KILL "$TWO_PARENT" 2>/dev/null
        sleep 0.3
    fi
    [[ -d "/proc/$TWO_PARENT" ]] && left=$((left + 1))
    [[ "${TWO_CHILD:-}" =~ ^[0-9]+$ && -d "/proc/${TWO_CHILD:-x}" ]] && left=$((left + 1))
    echo "$left"
}
cleanup() {
    [[ -f "$FIXTURE_REG" ]] && reap_fixtures >/dev/null
    declare -F reap_two_layer >/dev/null && reap_two_layer >/dev/null
    rm -rf "$FIX"
    return 0
}
trap cleanup EXIT INT TERM

# Same construction as tests/shell/test_ndt_apps_liveness.sh: the pid really is the process
# wearing that argv, so /proc is the witness and nothing about identity is stubbed.
spawn_fixture() {
    local want="$1" pid i
    local -a argv=()
    ( exec -a "$want" sleep "$FIXTURE_TTL" ) >/dev/null 2>&1 </dev/null &
    pid=$!
    echo "$pid" >> "$FIXTURE_REG"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        argv=()
        mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null
        [[ "${argv[0]:-}" == "$want" ]] && { echo "$pid"; return 0; }
        sleep 0.1
    done
    echo "  FAILED   fixture never took argv0=$want (pid $pid)" >&2
    exit 1
}
# Only sim gets a process fixture: every energy case below is about a channel that does not
# exist (its log) or a start that fails, and a fixture nothing reads would be scenery.
SIM_ARGV="/nonexistent/NDT-TEST-FIXTURE/simulation_platform_manager"

# --- the seam --------------------------------------------------------------------------------
# Everything that would describe THIS machine is an FX_ variable or a temp path. lab_kernel_dir,
# app_evidence_log, app_started_at, app_start, app_stop and residue_report all run for real.
#
# 🔴 LAB_CONF is redirected rather than lab_kernel_dir stubbed: the resolution rule IS the
# subject of group 1, and a stub would test the stub.
STUBS='
REPO="'"$FIX"'"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
LAB_CONF="${FX_CONF:-'"$FIX"'/conf/none.conf}"
LAB_DEFAULT_KERNEL_DIR="${FX_DEFAULT_KERNEL_DIR:-$LAB_DEFAULT_KERNEL_DIR}"
port_open() { [[ "${FX_KERNEL_UP:-1}" == 1 ]]; }
http_get_flow_entries() { [[ "${FX_NO_TABLE:-0}" == 1 ]] || cat "$REPO/entries.json"; }
live_dataplane_kind() { echo "${FX_PLANE:-ovs}"; }
lock_probe() { echo free; }
app_ps_snapshot() { printf "%s\n" "${FX_PS:-}"; }
lab_session() { [[ " ${FX_SESSIONS:-} " == *" $1 "* ]]; }
# The :9000 channel, answered by a variable. The real one asks ports.sh what is listening on
# this machine, and group 10 must not go red because somebody left a sim up. The channels this
# suite is ABOUT -- the /proc group walk and the log-fd scan -- are left real.
app_port_pids() { printf "%s\n" "${FX_PORT_PIDS:-}"; }
sudo() {
    local a sub="" seen=0
    for a in "$@"; do
        [[ "$a" == -* ]] && continue
        if (( seen == 0 )); then seen=1; continue; fi
        sub="$a"; break
    done
    echo "$sub" >> "$REPO/sudo_calls"
    case "$sub" in
        *-start) (( ${FX_LAB_START_RC:-0} != 0 )) && return "${FX_LAB_START_RC:-0}"
                 FX_SESSIONS="${FX_SESSIONS:-} ${sub%-start}"
                 FX_PS="${FX_START_PS:-${FX_PS:-}}" ;;
        # FX_KILL_GROUP: `<name>-stop` kills a tmux SESSION, which takes the process group in
        # that pane with it. Modelled by really signalling the group, because app_wait_stopped
        # verifies through the real /proc afterwards -- a stub that only edited FX_PS would
        # leave the fixture alive and the verification would (correctly) refuse to call it
        # stopped.
        *-stop)  FX_SESSIONS=""; FX_PS="${FX_STOP_PS:-}"
                 [[ -n "${FX_KILL_GROUP:-}" ]] && kill -KILL -"$FX_KILL_GROUP" 2>/dev/null
                 return 0 ;;
    esac
    return 0
}
'
inner() {   # inner <shell code> -- run it with ndt sourced and the seam in place
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

# The flow table residue_report reads: the app's own pri-96 rule at <age>, plus a baseline entry
# old enough to be outside every window. duration_nsec is non-zero on purpose -- W16-3 reads
# duration 0/0 as the P4 proxy's synthetic signature and would call the whole table UNKNOWN.
mk_entries() {   # <app-rule-age-seconds>
    python3 - "$FIX/entries.json" "$1" <<'PY'
import json, sys
p, age = sys.argv[1], int(sys.argv[2])
def row(dur, pri, acts):
    return {"actions": acts, "byte_count": 0, "cookie": 0, "duration_sec": dur,
            "duration_nsec": 91000000, "flags": 0, "hard_timeout": 0, "idle_timeout": 0,
            "length": 96, "match": {"in_port": 1}, "packet_count": 0,
            "priority": pri, "table_id": 0}
json.dump([{"dpid": 1, "flows": {"1": [row(9000, 10, ["OUTPUT:1"])]}},
           {"dpid": 2, "flows": {"2": [row(age, 96, ["OUTPUT:2"])]}}], open(p, "w"))
PY
}
mk_entries 300

# ==============================================================================================
section "1. the helper's KERNEL_DIR, resolved read-only -- and pinned to the helper's own source"
# 🔴 Compared against the helper's SOURCE, never against a string written out here. `ndt` now
# carries a copy of somebody else's rule; the failure mode of a copy is that it drifts while
# both sides keep working on their own, and this is the only thing that can see that happen.
HELPER_DEFAULT="$(sed -n 's/^LAB_DEFAULT_KERNEL_DIR=//p' "$HELPER" | head -1)"
HELPER_CONF="$(sed -n 's/^LAB_CONF=//p' "$HELPER" | head -1)"
NDT_DEFAULT="$(sed -n 's/^LAB_DEFAULT_KERNEL_DIR=//p' "$NDT" | head -1)"
NDT_CONF="$(sed -n 's/^LAB_CONF=//p' "$NDT" | head -1)"
check "🔴 ndt's default KERNEL_DIR is the helper's default"  "$HELPER_DEFAULT" "$NDT_DEFAULT"
check "🔴 ndt's config path is the helper's config path"     "$HELPER_CONF"    "$NDT_CONF"
check "  and neither is empty"                               "yes" \
      "$(if [[ -n "$HELPER_DEFAULT" && -n "$HELPER_CONF" ]]; then echo yes; else echo no; fi)"
# sim's log path is the helper's too, and this is the line that was read from the wrong tree.
check "🔴 the helper writes sim's log under its own KERNEL_DIR" \
      'SIM_LOG=$KERNEL_DIR/.test_run/logs/app_sim.log' \
      "$(grep -m1 '^SIM_LOG=' "$HELPER")"
# What actually runs as root is the INSTALLED copy. Compared when it can be read; said, not
# skipped silently, when it cannot -- "could not check" is not "checked and fine".
if [[ -r /usr/local/sbin/ndtwin-lab ]]; then
    check "🔴 the installed helper is the copy this suite read" \
          "$(sha256sum "$HELPER" | cut -d' ' -f1)" \
          "$(sha256sum /usr/local/sbin/ndtwin-lab | cut -d' ' -f1)"
else
    note "/usr/local/sbin/ndtwin-lab is not readable here -- the installed copy was NOT compared"
fi

check "no config file at all -> the built-in default" "$NDT_DEFAULT" "$(inner 'lab_kernel_dir')"
has   "  and it says so"  "built-in default" "$(inner 'lab_kernel_dir >/dev/null; echo "$LAB_KERNEL_DIR_SOURCE"')"

# 🔴 A config OWNED BY US is refused -- the direction that matters. There is no fixture for the
# accepted path off a root shell (no non-root-writable directory is root-owned), which is why
# ndt splits the trust gate from the parser exactly as the helper does: each half is drivable.
printf 'KERNEL_DIR=%s\n' "$FIX/othertree" > "$FIX/conf/mine.conf"
chmod 644 "$FIX/conf/mine.conf"
check "🔴 a config this user owns is REFUSED (it is not root's)" "$NDT_DEFAULT" \
      "$(FX_CONF="$FIX/conf/mine.conf" inner 'lab_kernel_dir')"
has   "  and the refusal is named, not silent" "was REFUSED" \
      "$(FX_CONF="$FIX/conf/mine.conf" inner 'lab_kernel_dir >/dev/null; echo "$LAB_KERNEL_DIR_SOURCE"')"
check "  lab_conf_trusted says no to it"        "1" \
      "$(inner "lab_conf_trusted '$FIX/conf/mine.conf'; echo RC=\$?" | sed -n 's/^RC=//p')"
ln -sf "$FIX/conf/mine.conf" "$FIX/conf/link.conf"
check "🔴 a symlink is refused rather than followed" "1" \
      "$(inner "lab_conf_trusted '$FIX/conf/link.conf'; echo RC=\$?" | sed -n 's/^RC=//p')"
check "  a missing file is refused"             "1" \
      "$(inner "lab_conf_trusted '$FIX/conf/nothing.conf'; echo RC=\$?" | sed -n 's/^RC=//p')"
# The control for the whole group: root's own /etc IS trusted, so a refuse-everything
# implementation -- which would satisfy every case above -- fails here.
check "🔴 control: a real root-owned, non-writable path IS trusted" "0" \
      "$(inner "lab_conf_path_trusted /etc; echo RC=\$?" | sed -n 's/^RC=//p')"

section "2. the parser: what a TRUSTED file would set, and what it refuses to set"
# Driven directly, because the trust gate above cannot be satisfied without root. This is the
# helper's own reason for splitting the two, kept.
check "a well-formed KERNEL_DIR is adopted" "$FIX/othertree" \
      "$(inner "lab_conf_kernel_dir '$FIX/conf/mine.conf'")"
printf 'KERNEL_DIR=%s\nNTG_PY=/usr/bin/python3\n' "$FIX/othertree" > "$FIX/conf/two.conf"
check "  other known keys do not disturb it"  "$FIX/othertree" \
      "$(inner "lab_conf_kernel_dir '$FIX/conf/two.conf'")"
printf 'KERNEL_DIR=%s\nWHAT=1\n' "$FIX/othertree" > "$FIX/conf/badkey.conf"
check "🔴 an unknown key sets NOTHING (the helper refuses the whole file)" "" \
      "$(inner "lab_conf_kernel_dir '$FIX/conf/badkey.conf'")"
printf 'KERNEL_DIR=relative/path\n' > "$FIX/conf/rel.conf"
check "🔴 a relative KERNEL_DIR sets nothing"  "" \
      "$(inner "lab_conf_kernel_dir '$FIX/conf/rel.conf'")"
printf 'KERNEL_DIR=%s/../othertree\n' "$FIX" > "$FIX/conf/dots.conf"
check "🔴 a path containing '..' sets nothing" "" \
      "$(inner "lab_conf_kernel_dir '$FIX/conf/dots.conf'")"
printf 'KERNEL_DIR=%s/nosuchtree\n' "$FIX" > "$FIX/conf/gone.conf"
check "🔴 a KERNEL_DIR that is not a directory sets nothing" "" \
      "$(inner "lab_conf_kernel_dir '$FIX/conf/gone.conf'")"
mkdir -p "$FIX/emptytree"
printf 'KERNEL_DIR=%s/emptytree\n' "$FIX" > "$FIX/conf/nobridge.conf"
check "🔴 a tree with no ntg_bmv2_topo.py sets nothing (the helper checks this too)" "" \
      "$(inner "lab_conf_kernel_dir '$FIX/conf/nobridge.conf'")"

section "3. app_evidence_log: which log answers 'did it ever run HERE'"
check "te's log is the one WE write"      "$FIX/.test_run/logs/app_te.log" \
      "$(inner 'app_evidence_log te')"
check "nsr's too"                         "$FIX/.test_run/logs/app_nsr.log" \
      "$(inner 'app_evidence_log nsr')"
# 🔴 The defect itself: sim's evidence is in the HELPER's tree, and $REPO is not it.
check "🔴 sim's log is the helper's, not ours" "$NDT_DEFAULT/.test_run/logs/app_sim.log" \
      "$(inner 'app_evidence_log sim')"
check "🔴 and it is NOT under this checkout" "no" \
      "$(case "$(inner 'app_evidence_log sim')" in "$FIX"*) echo yes ;; *) echo no ;; esac)"
check "  it follows a config file that moves the tree" "$FIX/othertree/.test_run/logs/app_sim.log" \
      "$(FX_DEFAULT_KERNEL_DIR="$FIX/othertree" inner 'app_evidence_log sim')"
check "🔴 energy has NO log channel at all -> rc 1" "1" \
      "$(inner 'app_evidence_log energy >/dev/null; echo RC=$?' | sed -n 's/^RC=//p')"
check "  and prints nothing to be mistaken for a path" "" "$(inner 'app_evidence_log energy')"

section "4. app_start writes the pidfile it just verified (E-8 point 1)"
SIMFIX="$(spawn_fixture "$SIM_ARGV")"
rm -f "$FIX/.test_run/pids/app_sim.pid" "$FIX/sudo_calls"
OUT="$(FX_START_PS="$SIMFIX $SIM_ARGV" inner 'app_start sim; echo "RC=$?"')"
check "start of a helper app that comes up -> rc 0" "0" "$(rc_of "$OUT")"
has   "  and it asked the lab to start it"          "sim-start" "$(cat "$FIX/sudo_calls" 2>/dev/null)"
check "🔴 the pidfile now exists"                   "yes" \
      "$(if [[ -f "$FIX/.test_run/pids/app_sim.pid" ]]; then echo yes; else echo no; fi)"
check "🔴 and it names the pid the scan verified"   "$SIMFIX" \
      "$(cat "$FIX/.test_run/pids/app_sim.pid" 2>/dev/null)"
check "🔴 which app_pidfile_pid accepts"            "$SIMFIX" \
      "$(FX_PS="$SIMFIX $SIM_ARGV" inner 'app_pidfile_pid sim')"
# 🔴 The other direction: a start that could NOT be verified must leave no pidfile, or the file
# becomes the C26 defect in a new place -- a record of a program that was never there.
rm -f "$FIX/.test_run/pids/app_sim.pid"
OUT="$(FX_START_PS="" inner 'app_start sim; echo "RC=$?"')"
check "🔴 a start nothing came up for -> rc 1"      "1" "$(rc_of "$OUT")"
check "🔴 and writes NO pidfile"                    "no" \
      "$(if [[ -f "$FIX/.test_run/pids/app_sim.pid" ]]; then echo yes; else echo no; fi)"
OUT="$(FX_LAB_START_RC=3 inner 'app_start energy; echo "RC=$?"')"
check "a lab that refuses the request -> rc 1"      "1" "$(rc_of "$OUT")"
check "  and no pidfile for it either"              "no" \
      "$(if [[ -f "$FIX/.test_run/pids/app_energy.pid" ]]; then echo yes; else echo no; fi)"

section "5. app_started_at falls back to the live process (E-8 point 2)"
rm -f "$FIX/.test_run/pids/app_sim.pid"
STARTED="$(FX_PS="$SIMFIX $SIM_ARGV" inner 'app_started_at sim')"
check "🔴 a live process with no pidfile still has a window" "yes" \
      "$(if [[ "$STARTED" =~ ^[0-9]+$ ]]; then echo yes; else echo no; fi)"
check "  and the window starts when the process did (within 30s of now)" "yes" \
      "$(if [[ "$STARTED" =~ ^[0-9]+$ ]] && (( $(date +%s) - STARTED < 30 )); then echo yes; else echo no; fi)"
check "🔴 nothing running and no pidfile -> still no window, not a made-up one" "1" \
      "$(FX_PS="" inner 'app_started_at sim >/dev/null; echo RC=$?' | sed -n 's/^RC=//p')"
# 🔴 sim matches TWICE on a logging run (the `script` wrapper and the binary it execs). The
# window must open at the OLDER one: a window that starts too late reports "no flow entry
# arrived during that window", which is a clean answer arrived at by looking at the wrong hour.
OLDFIX="$SIMFIX"
sleep 4
NEWFIX="$(spawn_fixture "$SIM_ARGV")"
# 🔴 The younger pid is listed FIRST, so "take the first one" and "take the oldest" differ here.
# Compared against the YOUNGER-ONLY answer with a >= 2s margin rather than against the older-only
# answer for equality: `ps -o etimes=` is whole seconds and each call re-reads the clock, so two
# correct answers taken a fraction of a second apart can differ by 1. A margin the 4s gap clears
# and a wrong answer (0s) cannot is the same assertion without the coin flip.
TWO="$(FX_PS="$NEWFIX $SIM_ARGV
$OLDFIX $SIM_ARGV" inner 'app_started_at sim')"
NEWONLY="$(FX_PS="$NEWFIX $SIM_ARGV" inner 'app_started_at sim')"
check "🔴 with two live pids the window opens at the OLDER one" "yes" \
      "$(if [[ "$TWO" =~ ^[0-9]+$ && "$NEWONLY" =~ ^[0-9]+$ ]] && (( NEWONLY - TWO >= 2 )); \
         then echo yes; else echo "no (both=$TWO younger-only=$NEWONLY)"; fi)"
kill -KILL "$NEWFIX" 2>/dev/null

section "6. the sentence that was printed about a running app (E-8 point 4)"
rm -f "$FIX/.test_run/pids"/app_*.pid
# A live process whose start time cannot be read: ps is answered, the etimes read is not.
OUT="$(FX_PS="$SIMFIX $SIM_ARGV" inner '
ps() { case " $* " in *" etimes= "*) return 1 ;; *) command ps "$@" ;; esac; }
residue_report sim')"
hasnt "🔴 it does NOT say 'no pidfile and no live process' about a running app" \
      "no pidfile and no live process" "$OUT"
has   "🔴 it says the app is running and names the pid"  "running as pid(s) $SIMFIX" "$OUT"
has   "  and that this is not 'left nothing'"            "NOT 'this app left nothing'" "$OUT"
# The control: with nothing running the old sentence is still the right one.
OUT="$(FX_PS="" inner 'residue_report sim')"
has   "control: with nothing running it still says so"   "no pidfile and no live process" "$OUT"

section "7. energy: 'cannot be asked' must not look like 'never ran' (E-8 point 3/5)"
rm -f "$FIX/.test_run/pids"/app_*.pid
OUT="$(FX_PS="" inner 'residue_report energy; echo "V=$RESIDUE_UNKNOWABLE B=$RESIDUE_BLIND"')"
has   "🔴 it says the question cannot be asked"          "CANNOT BE ASKED" "$OUT"
has   "  and why: the helper keeps no log for it"        "keeps no log for energy" "$OUT"
hasnt "🔴 and never says 'no sign it ever ran here'"     "no sign it ever ran here" "$OUT"
has   "  counted as unknowable, not as blind"            "V=1 B=0" "$OUT"
check "🔴 and it is NOT red (nobody can act on it) -- rc 0" "0" \
      "$(rc_of "$(FX_PS="" inner 'residue_report energy >/dev/null; residue_verdict; echo "RC=$?"')")"
# 🔴 ...and it is not invisible either: E-7's rule is that "could not check" must not look like
# "checked and clean". This is the row `ndt status --check` prints.
# 🔴 FX_DEFAULT_KERNEL_DIR is set here and not left at the built-in one: status_residue_row
# reports on ALL FIVE apps, and with the real default sim's evidence log is the main checkout's
# -- a file this suite must never depend on the contents of.
ROW="$(FX_DEFAULT_KERNEL_DIR="$FIX/othertree" FX_PS="" inner 'status_residue_row')"
has   "🔴 the --check row says an app could not be asked" "could not be asked whether they ran here" "$ROW"
has   "  and names it"                                    "energy" "$ROW"
has   "  while still reporting the clean part as clean"   "asked, not assumed" "$ROW"

section "8. sim: the window comes from the HELPER's tree, not from ours"
rm -f "$FIX/.test_run/pids"/app_*.pid
mkdir -p "$FIX/othertree/.test_run/logs"
: > "$FIX/othertree/.test_run/logs/app_sim.log"
: > "$FIX/.test_run/logs/app_sim.log"
# Our own tree's copy is non-empty; the helper's is empty. The answer must come from the
# helper's -- this is the exact inversion that printed "no sign it ever ran here" at 04:42.
echo "ours, and irrelevant" > "$FIX/.test_run/logs/app_sim.log"
OUT="$(FX_DEFAULT_KERNEL_DIR="$FIX/othertree" FX_PS="" inner 'residue_report sim')"
has   "🔴 an empty log in the HELPER's tree reads as 'never ran here'" \
      "no sign it ever ran here" "$OUT"
has   "  and the report says which file it read"          "$FIX/othertree/.test_run/logs/app_sim.log" "$OUT"
echo "the helper wrote this" > "$FIX/othertree/.test_run/logs/app_sim.log"
: > "$FIX/.test_run/logs/app_sim.log"
OUT="$(FX_DEFAULT_KERNEL_DIR="$FIX/othertree" FX_PS="" inner 'residue_report sim; echo "B=$RESIDUE_BLIND"')"
has   "🔴 a non-empty log in the helper's tree means it RAN here" "the window is LOST" "$OUT"
has   "  counted as blind"                                "B=1" "$OUT"
check "🔴 and that is rc 5 -- not checked, not clean"     "5" \
      "$(rc_of "$(FX_DEFAULT_KERNEL_DIR="$FIX/othertree" FX_PS="" inner \
          'residue_report sim >/dev/null; residue_verdict; echo "RC=$?"')")"
rm -f "$FIX/.test_run/logs/app_sim.log" "$FIX/othertree/.test_run/logs/app_sim.log"

section "9. 'apps stop sim' reports on a window it can still see"
# 🔴 lw16pw's headline: `ndt apps stop sim` verified the app was gone and then printed
# "no window, so no rule can be dated" about the app it had just stopped. The stop deletes the
# record; the window has to be read before it does.
SIMFIX2="$(spawn_fixture "$SIM_ARGV")"
rm -f "$FIX/.test_run/pids"/app_*.pid
echo "$SIMFIX2" > "$FIX/.test_run/pids/app_sim.pid"
# The window here is the fixture's own age, which is seconds. The rule has to be inside it, so
# it is a genuine just-installed one: duration_sec 0 with a non-zero nsec, which W16-3 dates
# rather than calling synthetic.
mk_entries 0
OUT="$(FX_PS="$SIMFIX2 $SIM_ARGV" FX_SESSIONS="sim" FX_STOP_PS="" inner 'cmd_apps stop sim; echo "RC=$?"')"
check "the app really was stopped -> rc 0"               "0" "$(rc_of "$OUT")"
has   "🔴 and the residue report has a window for it"    "sim    window" "$OUT"
hasnt "🔴 not 'no window, so no rule can be dated'"      "no window, so no rule can be dated" "$OUT"
has   "  so the rules in that window were listed"        "pri=96" "$OUT"
check "🔴 and the pidfile is gone afterwards, so the window closes" "no" \
      "$(if [[ -f "$FIX/.test_run/pids/app_sim.pid" ]]; then echo yes; else echo no; fi)"
# The other direction: a window that is still open on a LATER run must not be invented from a
# stop that already happened.
OUT="$(FX_PS="" inner 'residue_report sim')"
has   "  a later run has no window for it again"         "no window, so no rule can be dated" "$OUT"

section "10. the shape lw351 found: a helper app is TWO processes, and it is tracked"
# 🔴 Measured live 2026-09-07 (lw351, 1/1) on the branch that added the pidfile. With sim
# genuinely running and its pidfile naming a live pid, `apps orphans` answered rc 1:
#
#     sim: children with no pidfile and no signature
#         pid 3729217  (process group 3729217)
#         script -qfa .../app_sim.log -c ./simulation_platform_manager
#
# ...about the pid that was IN the pidfile, and `apps stop sim` then said
# `ok sim stopped (was: not-running)` about a sim whose own log shows it taking SIGINT a second
# later. Three verbs, three different answers about one app.
#
# 🔴 GROUPS 1-10 COULD NOT HAVE CAUGHT THIS, and the reason is the fixture: they spawn ONE
# process wearing the app's argv. `sudo ndtwin-lab sim-start` runs `script -qfa <log> -c
# ./simulation_platform_manager`, so there are TWO -- a group-leader wrapper whose argv carries
# the signature as a later element, and the program it execs -- and it is the WRAPPER the
# pidfile names. The survivor channels walk the process group; the group has members; nothing
# compared them against what the probe had already accounted for. So this group builds the two
# layers for real: a setsid'd leader (pgid == pid, as the wrapper is) and a child in its group.
TWO_PARENT=""
TWO_CHILD=""
cat > "$FIX/twolayer" <<'FIXTURE'
#!/usr/bin/env bash
# NDT-TEST-FIXTURE. $1 = the argv the child wears, $2 = ttl, $3 = where to record the child pid,
# $4 = the app log to hold open for writing.
#
# The parent OWN argv carries $1 as a later element, which is what makes it the wrapper shape:
# pid_is_app compares argv ELEMENTS, so both layers answer to the signature.
#
# fd 9 is opened for append BEFORE the fork, so both layers hold a writable fd on the app log --
# the channel that found the 09-02 viz JVMs, and the only one left when the pidfile is gone.
#
# 🔴 `wait`, not another `sleep`: `wait` is a builtin, so this stays exactly TWO processes. A
# trailing `sleep` forks a THIRD -- one with no signature, in the same group, holding the same
# log fd -- which the verb under test correctly reports as unaccounted for, and the case would
# then be measuring the fixture instead of the code.
exec 9>>"$4"
( exec -a "$1" sleep "$2" ) &
echo "$!" > "$3"
wait
FIXTURE
chmod +x "$FIX/twolayer"
spawn_two_layer() {
    local i
    setsid "$FIX/twolayer" "$SIM_ARGV" "$FIXTURE_TTL" "$FIX/twolayer_child" \
           "$FIX/.test_run/logs/app_sim.log" >/dev/null 2>&1 &
    TWO_PARENT=$!
    # Off the jobs table, for the reason test_ndt_apps_liveness.sh gives: killing it later would
    # otherwise print bash's own "Killed" line into the middle of a gate's output. Nothing about
    # the process changes -- it is reaped by pid and by group, never by jobspec.
    disown "$TWO_PARENT" 2>/dev/null || true
    echo "$TWO_PARENT" >> "$FIXTURE_REG"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        TWO_CHILD="$(cat "$FIX/twolayer_child" 2>/dev/null)"
        [[ "$TWO_CHILD" =~ ^[0-9]+$ && -d "/proc/$TWO_CHILD" ]] && break
        sleep 0.2
    done
    echo "$TWO_CHILD" >> "$FIXTURE_REG"
}
rm -f "$FIX/twolayer_child" "$FIX/.test_run/pids"/app_*.pid
spawn_two_layer
TWO_PS="$TWO_PARENT $(tr '\0' ' ' < "/proc/$TWO_PARENT/cmdline" 2>/dev/null)
$TWO_CHILD $SIM_ARGV"
check "the fixture really is two processes"              "yes" \
      "$(if [[ -d "/proc/$TWO_PARENT" && -d "/proc/$TWO_CHILD" && "$TWO_PARENT" != "$TWO_CHILD" ]]; \
         then echo yes; else echo no; fi)"
check "  in one process group led by the parent"         "$TWO_PARENT $TWO_PARENT" \
      "$(awk '{print $5}' "/proc/$TWO_PARENT/stat" 2>/dev/null) $(awk '{print $5}' "/proc/$TWO_CHILD/stat" 2>/dev/null)"
check "  and BOTH answer to the app's signature"         "yes yes" \
      "$(FX_PS="$TWO_PS" inner "yn() { if \"\$@\"; then echo yes; else echo no; fi; }
         echo \"\$(yn pid_is_app $TWO_PARENT sim) \$(yn pid_is_app $TWO_CHILD sim)\"" | tail -1)"

# The pidfile app_start writes names the WRAPPER -- APP_LIVE_PIDS[0], lowest pid first.
echo "$TWO_PARENT" > "$FIX/.test_run/pids/app_sim.pid"
check "app_probe calls a two-layer sim running"          "running" \
      "$(FX_PS="$TWO_PS" FX_SESSIONS="sim" inner 'app_probe sim; echo "$APP_STATE"' | tail -1)"
# 🔴 The channel has to FIRE, or the case below proves nothing: a dedup that is never asked to
# subtract anything passes on an empty list.
check "🔴 the group channel really finds the wrapper"    "yes" \
      "$(FX_PS="$TWO_PS" FX_SESSIONS="sim" inner \
          'app_survivors sim; printf "%s\n" "${APP_SURVIVORS[@]}"' | grep -q "^$TWO_PARENT " && echo yes || echo no)"

ORPH="$(FX_PS="$TWO_PS" FX_SESSIONS="sim" inner 'apps_orphans; echo "RC=$?"')"
check "🔴 a tracked, running sim is NOT an orphan -- rc 0" "0" "$(rc_of "$ORPH")"
hasnt "🔴 and it is not called 'children with no pidfile'" "sim: children with no pidfile" "$ORPH"
hasnt "  nor is the pidfile's own pid listed as untracked" "pid $TWO_PARENT  (process group" "$ORPH"
has   "  the verb still answers about processes"          "no untracked app processes" "$ORPH"

# 🔴 The control, and it is FINDING #48 itself: same two processes, but the launcher's record is
# gone and the argv scan cannot see them. Nothing then accounts for them, and every one must
# still come out. A dedup that swallowed this would have traded one silent verb for another.
rm -f "$FIX/.test_run/pids/app_sim.pid"
ORPH="$(FX_PS="" FX_SESSIONS="" inner 'apps_orphans; echo "RC=$?"')"
check "🔴 control: untracked children still exit 1"      "1" "$(rc_of "$ORPH")"
has   "  and are still called that"                      "sim: children with no pidfile and no signature" "$ORPH"
has   "  naming the pid the group channel found"         "pid $TWO_PARENT" "$ORPH"

# 🔴 And the third verb. `apps stop` printed `(was: not-running)` about this app while it was
# running, because app_wait_stopped re-probes and overwrites APP_STATE before the message.
echo "$TWO_PARENT" > "$FIX/.test_run/pids/app_sim.pid"
STOP="$(FX_PS="$TWO_PS" FX_SESSIONS="sim" FX_STOP_PS="" FX_KILL_GROUP="$TWO_PARENT" \
        inner 'app_stop sim; echo "RC=$?"')"
check "stopping a running two-layer sim -> rc 0"         "0" "$(rc_of "$STOP")"
has   "🔴 it says what the app WAS: running"             "sim stopped (was: running)" "$STOP"
hasnt "🔴 not 'was: not-running' about an app it stopped" "was: not-running" "$STOP"
check "  and both layers are gone"                       "no" \
      "$(if [[ -d "/proc/$TWO_PARENT" || -d "/proc/$TWO_CHILD" ]]; then echo yes; else echo no; fi)"

section "11. this suite reaps its own fixtures"
check "no fixture survives this run"                     "0" "$(reap_fixtures)"
check "  and neither layer of the two-layer one does"    "0" "$(reap_two_layer)"

# --- done -------------------------------------------------------------------------------------
echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
