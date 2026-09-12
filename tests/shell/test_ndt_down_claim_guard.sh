#!/usr/bin/env bash
#
# `ndt down` refuses over somebody else's live claim -- driven offline, from a claim FILE.
#
# [Co-developed with claude code -- Adam]
#
# WHAT THIS IS, AND WHY IT IS NOT A LIVE CELL. The hunt's live grid carries a cell called
# `intruder_down_is_refused_by_the_claim_before_the_marker` (12-4). It cannot run in the night
# grid: the only honest way to measure it live is to bring a lab up under one owner and run a
# teardown as another, and a cell that tears the lab down when the guard is BROKEN is a cell
# that destroys the round it is part of. CELLS-2-SUMMARY §7-3 offered three ways out; Adam took
# (c): drive the guard branch offline, where it costs nothing and therefore runs every night.
#
# 🔴 FROM A CLAIM FILE, not from a stubbed foreign_claim(). tests/shell/test_ndt_up_down_robust.sh
# already drives this branch with `foreign_claim() { echo other-owner; }`, which tests what
# cmd_down does with an answer -- not whether the file on disk produces that answer. The two
# halves have failed separately in this repo: ROLE-4 T1 measured two owners both getting rc 0
# from `ndt claim` in the same second, and ROLE-4 T2 measured a refusal whose retry line pasted
# a description with parentheses into a command line. So everything below writes the five fields
# `claim_write` documents into $REPO/.test_run/lab.claim and lets the real foreign_claim,
# claim_field and measuring_declared read them.
#
# 🔴 WHAT MUST NOT HAPPEN is half the subject. A refusal that has already stopped the kernel is
# not a refusal, so every case asserts the machine was not touched: no `sudo` call recorded, no
# stack.sh invocation, and no teardown marker left behind (H3 -- an in-flight marker written by
# a command that refused would block the NEXT teardown too).
#
# Offline, and it stays offline in the branches that PROCEED: `sudo` and `sleep` are shell
# functions, $STACK and $LAB are fixture scripts, and every reading that would describe this
# machine is answered from the fixture. Nothing here reaches the lab, a port, or root -- which
# is what lets the expired-claim and --force controls run at all.
#
# Run:  bash tests/shell/test_ndt_down_claim_guard.sh
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="$HERE/../../tools/test_workflow/ndt"
[[ -r "$NDT" ]] || { echo "  FAILED   no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 1; }

PASS=0; FAIL=0
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}
has()   { grep -qF -- "$2" <<<"$3" && { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; } \
          || { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             no match for: [%s]\n' "$1" "$2"; }; }
hasnt() { grep -qF -- "$2" <<<"$3" && { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             unexpected: [%s]\n' "$1" "$2"; } \
          || { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-down-claim-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT INT TERM
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs" "$FIX/tools/test_workflow" "$FIX/etc"
echo '{"switches":[]}' > "$FIX/manifest.json"
printf 'helper\n' > "$FIX/installed-ndtwin-lab"

# A recording fake stack.sh. Its log file is the evidence for "nothing was torn down": the
# refusal cases must leave it empty and the proceeding controls must not.
cat > "$FIX/stack.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STACK_LOG"
echo "stopped kernel"
echo "stopped ryu"
exit 0
FAKE
chmod +x "$FIX/stack.sh"

# --- the seam ------------------------------------------------------------------------------
# `ndt` returns early when sourced, so this defines its functions without dispatching on argv;
# then every reading that would describe THIS machine is replaced. foreign_claim, claim_field,
# measuring_declared, mark_teardown_start and cmd_down itself are left REAL -- they are the
# subject.
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
sudo() { printf "sudo %s\n" "$*" >> "'"$FIX"'/sudo.log"; return 0; }
sleep() { :; }
bmv2_count() { echo 0; }
mn_count() { echo 0; }
fabric_host_count() { echo 0; }
topo_session() { return 1; }
in_flight() { :; }
guard_no_live_ovs() { return 0; }
check_up_target() { UP_TARGET_PROBLEMS=(); return 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
git_lines() { :; }
ovs_bridge_count() { echo 0; }
ovs_daemon_running() { return 1; }
netem_count() { echo 0; }
port_open() { return 1; }
ndt_port_open() { return 1; }
ndt_port_listener_pids() { return 0; }
http_get_graph() { :; }
curl() { return 1; }
wait_reaped() { return 0; }
app_probe() { APP_STATE=not-running; APP_LIVE_PIDS=(); }
'

drive() {   # drive <shell-code> -> its output plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

# write_claim <owner> <expires-epoch> <note> <measuring> -- the five fields claim_write documents.
write_claim() {
    printf 'owner=%s\nexpires=%s\nnote=%s\nexclusive_cpu=%s\nmeasuring=%s\n' \
        "$1" "$2" "$3" no "$4" > "$FIX/.test_run/lab.claim"
}
reset_fix() { rm -f "$FIX/sudo.log" "$FIX/stack.log" "$FIX/.test_run/lab.claim" \
                    "$FIX/.test_run/down.inflight" "$FIX/.test_run/"*.inflight; : > "$FIX/sudo.log"; : > "$FIX/stack.log"; }
# `grep -c .` exits 1 when the count is 0, so `|| echo 0` appends a SECOND zero rather than
# supplying a missing one -- the first draft of this helper reported `sudo=0\n0 stack=0\n0` and
# every "nothing was touched" check was red for a reason that had nothing to do with ndt.
count_lines() {
    local n; n="$(grep -c . "$1" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}
touched() {   # "sudo=<n> stack=<n>" -- how much of the machine the command reached
    printf 'sudo=%s stack=%s' "$(count_lines "$FIX/sudo.log")" "$(count_lines "$FIX/stack.log")"
}
markers() { find "$FIX/.test_run" -maxdepth 1 -name '*inflight*' -o -maxdepth 1 -name '*teardown*' 2>/dev/null | wc -l | tr -d ' '; }

THEM=other-session
US=overnight-0905
FUTURE=$(( $(date +%s) + 1800 ))
PAST=$(( $(date +%s) - 60 ))

# =============================================================================================
section "1. an intruder's 'ndt down' is refused by the claim, and the lab is not touched"
# =============================================================================================
reset_fix
write_claim "$THEM" "$FUTURE" "ROLE-4 T2/T3: reader running" ""
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "🔴 somebody else's live claim -> rc 5"            "5" "$(rc_of "$OUT")"
has   "  and it says it is refusing"                     "refusing to tear down: the lab is claimed by" "$OUT"
has   "  and names the holder"                           "$THEM" "$OUT"
has   "  and says what it would have destroyed"          "their kernel's pid is in the shared .test_run/pids/, so this would kill it." "$OUT"
has   "  and names the override"                         "ndt down --force" "$OUT"
check "🔴 NOTHING on the machine was reached"            "sudo=0 stack=0" "$(touched)"
check "  and no in-flight teardown marker was left"      "0" "$(markers)"
hasnt "  the teardown never started"                     "[1/3] kernel + proxy/Ryu" "$OUT"

# 🔴 ROLE-4 T2, 01:56:53 verbatim: the retry line used to be `NDT_OWNER=$held ndt down`, and
# $held is a DESCRIPTION -- "other-session (until 02:36:24, reader running)". Pasted, bash reads
# `(until ...)` as a subshell and the command dies on a syntax error. The bare owner goes on the
# command line; the description goes on a line of its own where it cannot get into it.
has   "  the retry line carries the BARE owner"          "NDT_OWNER=$THEM ndt down" "$OUT"
hasnt "  🔴 and not the parenthesised description"       "NDT_OWNER=$THEM (until" "$OUT"

# =============================================================================================
section "2. an owner who wrote measuring= is told what the teardown would have killed"
# =============================================================================================
# ROLE-4 T2: the claim said `measuring=ROLE-4 reader nsr, do not tear down` and the refusal never
# mentioned it -- the one sentence the holder wrote FOR this moment was the one not shown at it.
reset_fix
write_claim "$THEM" "$FUTURE" "night round" "ROLE-4 reader nsr, do not tear down"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "  still rc 5"                                     "5" "$(rc_of "$OUT")"
has   "  🔴 and the declaration is quoted"               "measuring=ROLE-4 reader nsr, do not tear down" "$OUT"
has   "  with what it is"                                "they DECLARED what is running" "$OUT"
check "  and nothing was touched"                        "sudo=0 stack=0" "$(touched)"

# =============================================================================================
section "3. 🔴 the controls -- a guard that refuses everything guards nothing"
# =============================================================================================
# An EXPIRED claim is stale, not a holder. Without this cell the guard could be "refuse whenever
# lab.claim exists", which would make the file impossible to leave behind.
reset_fix
write_claim "$THEM" "$PAST" "finished at 01:00" ""
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "an EXPIRED claim is not a refusal"                "0" "$(( $(rc_of "$OUT") == 5 ? 1 : 0 ))"
has   "  the teardown ran"                               "[1/3] kernel + proxy/Ryu" "$OUT"
hasnt "  and it never claimed to be refusing"            "refusing to tear down: the lab is claimed by" "$OUT"

# Our OWN claim is not foreign. NDT_OWNER has to be set on every command, so this is the common
# case, and a guard that refused here would make the claim unusable by the session holding it.
reset_fix
write_claim "$US" "$FUTURE" "our own round" ""
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "our own live claim is not a refusal"              "0" "$(( $(rc_of "$OUT") == 5 ? 1 : 0 ))"
has   "  the teardown ran"                               "[1/3] kernel + proxy/Ryu" "$OUT"

# With NDT_OWNER unset, an unnamed caller cannot prove the claim is its own -- so it is foreign.
reset_fix
write_claim "$US" "$FUTURE" "our own round" ""
OUT="$(drive 'unset NDT_OWNER; cmd_down')"
check "🔴 an unnamed caller is refused over any claim"   "5" "$(rc_of "$OUT")"
check "  and touched nothing"                            "sudo=0 stack=0" "$(touched)"

# --force is the one override, and it says that it used it.
reset_fix
write_claim "$THEM" "$FUTURE" "night round" "ROLE-4 reader nsr"
OUT="$(NDT_OWNER="$US" drive 'cmd_down --force')"
check "--force tears down over a foreign claim"          "0" "$(( $(rc_of "$OUT") == 5 ? 1 : 0 ))"
has   "  and warns that it is doing exactly that"        "--force: tearing down over a declared measurement" "$OUT"
has   "  the teardown ran"                               "[1/3] kernel + proxy/Ryu" "$OUT"

# 🔴 --deep is NOT an override. A guard that any second flag turns off is not a guard, and --deep
# is what an operator reaches for when a teardown did not reach clean -- i.e. exactly when a
# declared measurement is most likely to still be running.
reset_fix
write_claim "$THEM" "$FUTURE" "night round" ""
OUT="$(NDT_OWNER="$US" drive 'cmd_down --deep')"
check "🔴 --deep does not open the guard"                "5" "$(rc_of "$OUT")"
check "  and touched nothing"                            "sudo=0 stack=0" "$(touched)"

# =============================================================================================
section "4. the same guard on a claim this tool did not write"
# =============================================================================================
# `ndt`'s own header says any script may write .test_run/lab.claim directly, so the reader must
# not depend on field order or on trailing fields being present.
reset_fix
printf 'expires=%s\nowner=%s\n' "$FUTURE" "$THEM" > "$FIX/.test_run/lab.claim"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "a hand-written claim still refuses"               "5" "$(rc_of "$OUT")"
has   "  and names the holder"                           "$THEM" "$OUT"
check "  and touched nothing"                            "sudo=0 stack=0" "$(touched)"

# A malformed expiry is stale, not a holder: `ndt` treats an unparseable date as expired rather
# than as "forever", which is the direction that cannot wedge the lab.
reset_fix
printf 'owner=%s\nexpires=%s\n' "$THEM" "not-a-number" > "$FIX/.test_run/lab.claim"
OUT="$(NDT_OWNER="$US" drive 'cmd_down')"
check "a malformed expiry is not a refusal"              "0" "$(( $(rc_of "$OUT") == 5 ? 1 : 0 ))"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
