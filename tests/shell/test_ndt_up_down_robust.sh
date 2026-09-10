#!/usr/bin/env bash
#
# Do `ndt up` and `ndt down` tell the truth, and do they clean up after themselves?
#
# [Co-developed with claude code -- Adam]
#
# Four findings from the 09-02/09-03 night rounds, all of them about the same two commands:
#
# #3  A failed `ndt up ovs4` does not roll back. Measured 2026-09-02 23:36-23:39
#     (doc/audit/2026-09-03_night-rounds/round1-ovs/02_): a sibling session's kernel took :8000
#     four seconds before the bring-up started; `ndt up` built Ryu (:8080/:6653/:6633) and a
#     15-process / 36-veth data plane, and only THEN did stack.sh's [3/3] refuse. `ndt up`
#     returned failure and left all of it running, with no kernel. Three minutes later the same
#     processes were still there. Two defects in one: the refusal ran after the machine had been
#     changed, and nothing undid what had been done.
#
# #21 `up_p4` sweeps an orphan bmv2 with `sudo -n "$LAB" cleanup >/dev/null 2>&1` and throws the
#     rc away, then builds on top of whatever survived. The orphan holds :3005x, the new fabric
#     cannot bind, and the operator sees an error that reads like a P4 pipeline problem.
#     `cmd_down`'s sweep has the same shape through a pipeline. Until G-9 this was invisible
#     rather than wrong -- every kill in the old cleanup was `|| true`, so it could not fail.
#
# #49 `ndt down`'s own verify is not synchronised with the sweep it verifies: it printed
#     "XX bmv2 switches: 5 still running" and "not clean", and `ps -eo comm=` counted 0 twenty
#     seconds later (round3-restart-concurrency/SUMMARY.md:167, 15_). The fabric was gone; the
#     verdict was taken before the machine had finished agreeing with it.
#
# #83 `ndt:55` hard-codes LAB=/usr/local/sbin/ndtwin-lab, a root-owned COPY. The copy on this
#     machine is the 08-30 one (sha256 288b71cb...); tools/test_workflow/ndtwin-lab has moved
#     five commits since. So `ndt up`/`ndt down` run code that is not in this tree, and nothing
#     -- status, preflight, or any gate -- compares the two files or says a word.
#
# 🔴 THE DIRECTION THAT MATTERS. Each of these has an "obvious fix" that is worse than the
# defect, and every group below carries the case that catches it:
#   * refuse whenever a needed port is held  -> refuses every reuse of a running stack, and
#     every live P4 fabric (bmv2's :3005x is root-owned, so we cannot see its pid at all).
#   * roll back on any non-zero exit         -> destroys a stack that came up and merely failed
#     VERIFICATION, which is the state an operator most needs to look at.
#   * roll back everything you can find      -> tears down a fabric this run REUSED and did not
#     start, i.e. someone else's lab.
#   * wait until the machine looks clean     -> turns a real leftover into a green teardown,
#     which is #49 with the sign flipped and strictly worse than the false negative.
#
# Offline and fixture-driven, like tests/shell/test_ndt_status_check_baseline.sh: `ndt` is
# sourced through its own source seam, REPO/LAB/STACK are redirected into a temp dir, `sudo` and
# `sleep` are shell functions in this shell (a function shadows the command, so no production
# seam is needed for either), and stack.sh is a recording fake. No lab, no root, no port, no
# network. What is NOT stubbed is the point: preflight, the port table, the ownership test, the
# rollback, the bounded wait and the sha comparison all run for real.
#
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_ndt_up_down_robust.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; exit 2; }
# ndt sources two tables from beside itself and exits 2 when either is missing; sourced with
# output discarded that would kill this suite with no message at all.
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

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-updown-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
export FIX
mkdir -p "$FIX/.test_run/pids" "$FIX/setting" "$FIX/p4_proxy/mininet" \
         "$FIX/p4_proxy/venv/bin" "$FIX/p4_proxy/p4_src/build" "$FIX/build/bin" "$FIX/tools/test_workflow"

# --- fixtures ---------------------------------------------------------------------------
# What preflight insists exists before it will let a bring-up start.
: > "$FIX/build/bin/ndtwin_kernel";            chmod +x "$FIX/build/bin/ndtwin_kernel"
: > "$FIX/p4_proxy/venv/bin/python";           chmod +x "$FIX/p4_proxy/venv/bin/python"
echo '{}' > "$FIX/p4_proxy/p4_src/build/ndtwin_switch.json"
echo 4 > "$FIX/p4_proxy/mininet/host_count_override"
echo '{"switches":[]}' > "$FIX/manifest.json"

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

# The two helper copies #83 is about. Distinct contents, so their sha256s differ the way the
# installed 08-30 copy differs from this tree's.
mk_helpers() {   # <installed-content> <repo-content>;  "-" means "do not create the file"
    rm -f "$FIX/installed-ndtwin-lab" "$FIX/tools/test_workflow/ndtwin-lab"
    [[ "$1" == - ]] || printf '%s\n' "$1" > "$FIX/installed-ndtwin-lab"
    [[ "$2" == - ]] || printf '%s\n' "$2" > "$FIX/tools/test_workflow/ndtwin-lab"
}
mk_helpers "helper v2" "helper v2"

# A recording fake stack.sh. It plays the FIFO protocol `up_ovs` depends on (print the "[2/3]"
# banner, then block on stdin) so the real bring-up sequencing runs; every invocation is
# recorded and every exit status is scripted from a file.
cat > "$FIX/stack.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/stack.log"
rc_of() { cat "$FIX/rc.$1" 2>/dev/null || echo 0; }
case "$1 ${2:-}" in
    "up ovs")
        echo "[1/3] control plane (Ryu)"
        [[ -f "$FIX/stack_ovs_dies_early" ]] && exit 9
        echo "[2/3] data plane (Mininet, needs sudo)"
        [[ -f "$FIX/stack_ovs_no_prompt" ]] && { sleep 0.05; exit 9; }
        read -r _ || true
        echo "converged"
        exit "$(rc_of stack_up)" ;;
    "up p4")
        echo "[1/3] data plane"; echo "started"; exit "$(rc_of stack_up)" ;;
    "down"*)
        echo "stopped kernel"; echo "stopped ryu"; exit "$(rc_of stack_down)" ;;
esac
exit 0
FAKE
chmod +x "$FIX/stack.sh"

# The scripted exit statuses and the reading sequences, reset between groups.
reset_fix() {
    rm -f "$FIX/rc."* "$FIX/out."* "$FIX/sudo.log" "$FIX/stack.log" \
          "$FIX/stack_ovs_dies_early" "$FIX/stack_ovs_no_prompt" \
          "$FIX/bmv2.seq" "$FIX/mn.seq" "$FIX/.test_run/up.target"
    echo '{"switches":[]}' > "$FIX/manifest.json"
    rm -f "$FIX/.test_run/pids/"*
    : > "$FIX/sudo.log"; : > "$FIX/stack.log"
}
rc_for()  { printf '%s\n' "$2" > "$FIX/rc.$1"; }       # rc_for <verb|stack_up|stack_down> <rc>
out_for() { printf '%s\n' "$2" > "$FIX/out.$1"; }      # what the fake $LAB prints for <verb>

# --- the seam ---------------------------------------------------------------------------
# `ndt` is sourced (it returns at its own source seam), then every reading that would describe
# THIS machine is answered by a fixture. LAB and STACK are assigned HERE, in the test's own
# shell, after sourcing -- `ndt` itself must keep hard-coding LAB, and ndtwin-lab's header says
# why (a root-owned NOPASSWD target must not let the caller choose what root runs).
STUBS='
REPO="'"$FIX"'"
HERE="'"$FIX"'/tools/test_workflow"
LAB="'"$FIX"'/installed-ndtwin-lab"
STACK="'"$FIX"'/stack.sh"
MANIFEST="'"$FIX"'/manifest.json"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
# The two readings lab_kernel_dir() is built on, both redirected into the fixture so the tree
# comparison in preflight is answered here and never by this machine (#R5: /etc/ndtwin-lab.conf
# and a built-in constant naming the main checkout). lab_kernel_dir itself is NOT stubbed -- it
# is half of what section 6 is about. By default the lab acts in THIS fixture tree, which is
# the state every other section assumes; FX_LAB_KERNEL_DIR is how section 6 moves it away.
LAB_CONF="'"$FIX"'/etc/ndtwin-lab.conf"
LAB_DEFAULT_KERNEL_DIR="${FX_LAB_KERNEL_DIR:-'"$FIX"'}"
# `sudo` and `sleep` are shell functions here, which shadow the commands for every caller in
# this shell -- including the ones inside ndt. No production seam, and no root.
sudo() {
    local a args=()
    for a in "$@"; do [[ "$a" == -n ]] && continue; args+=("$a"); done
    local prog="${args[0]:-}" verb="${args[1]:-none}"
    printf "%s %s\n" "${prog##*/}" "${args[*]:1}" >> "'"$FIX"'/sudo.log"
    # The real cleanup removes the manifest before it decides its own exit status, so the
    # fixture does too -- otherwise every teardown assertion here is red about a file the
    # sweep would have taken with it.
    [[ "$verb" == cleanup ]] && rm -f "'"$FIX"'/manifest.json"
    # ...and a topology start writes it back, immediately after the switches come up. The wait
    # loop in up_p4 requires both, so a fixture that removed it and never restored it would fail
    # every bring-up for a reason that has nothing to do with the case under test.
    [[ "$verb" == topo-start ]] && echo '{"switches":[]}' > "'"$FIX"'/manifest.json"
    [[ -f "'"$FIX"'/out.$verb" ]] && cat "'"$FIX"'/out.$verb"
    [[ -f "'"$FIX"'/rc.$verb" ]] && return "$(cat "'"$FIX"'/rc.$verb")"
    return 0
}
sleep() { :; }
# Counters. A SEQUENCE file answers successive readings with successive values and then repeats
# the last one, which is the whole of finding #49: the sweep has signalled the processes, the
# table has not caught up yet, and the next reading is different from this one. It is also how a
# fabric can be an orphan on one reading and a live fabric on the next, which is the #21 branch.
seq_read() {   # seq_read <file> <default>
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
foreign_claim() { :; }
in_flight() { :; }
guard_no_live_ovs() { return "${FX_GUARD_RC:-0}"; }
bmv2_binary() { echo fixture-bmv2; }
sample_rate() { echo 256; }
stale_pipeline() { return 1; }
source_ahead_of_build() { return 1; }
verify_p4() { return "${FX_VERIFY_RC:-0}"; }
app_probe() { APP_STATE=not-running; }
# The up-target comparison is the neighbour suite\x27s subject (test_ndt_status_check_baseline.sh),
# not this one\x27s. Neutralised so a --check exit code here is about the helper comparison.
check_up_target() { UP_TARGET_PROBLEMS=(); return "${FX_UT_RC:-0}"; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
claim_line() { echo none; }
git_lines() { :; }
ovs_bridge_count() { echo "${FX_BRIDGES:-0}"; }
ovs_daemon_running() { [[ "${FX_BRIDGES:-0}" -gt 0 ]]; }
netem_count() { echo 0; }
port_open() { return 1; }
http_get_graph() { :; }
curl() { return 1; }
# Which ports are held, and by whom. ndt_port_listener_pids is the ONE reading the ownership
# test is built on, so it is the one the fixture controls: FX_HELD is "port:pid" pairs, and a
# pair with an empty pid is a listener whose owner this user cannot see (root-owned bmv2).
ndt_port_open() {
    local p="$1" e
    for e in ${FX_HELD:-}; do [[ "${e%%:*}" == "$p" ]] && return 0; done
    return 1
}
ndt_port_listener_pids() {
    local p="$1" e
    for e in ${FX_HELD:-}; do [[ "${e%%:*}" == "$p" ]] && { [[ -n "${e#*:}" ]] && echo "${e#*:}"; return 0; }; done
    return 0
}
'
# The pgid reading the ownership rule needs. `ndt` already has proc_pgid (it reads /proc/<pid>/stat
# rather than forking ps -- trap note 2), so that is the function the fixture answers, and a pid
# can be given a process group here without a process existing.
STUBS="$STUBS"'
proc_pgid() { local m; for m in ${FX_PGID:-}; do [[ "${m%%:*}" == "$1" ]] && { echo "${m#*:}"; return 0; }; done; return 1; }
'

drive() {   # drive <shell-code>  -> its output plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of_out() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
ledger() { printf '%s\n' "$2" > "$FIX/.test_run/pids/$1.pid"; }   # ledger <component> <pid>

# ==========================================================================================
section "1. #3(a): the cheap refusals are decided BEFORE the machine is touched"
# The measured collision, verbatim: :8000 held by a kernel this checkout did not start. On
# 09-02 that was discovered by stack.sh's [3/3], after Ryu and a 15-process fabric existed.
reset_fix
OUT="$(FX_HELD="8000:992261" drive 'preflight ovs')"
check "🔴 a foreign holder of :8000 refuses the bring-up"  "1"  "$(rc_of_out "$OUT")"
has   "  and names the port"                               ":8000" "$OUT"
has   "  and says it is not this checkout's"               "not part of this checkout" "$OUT"
has   "  and carries the row's consequence"                "the next 'up' measures the stray kernel" "$OUT"
has   "  and names where the late refusal used to happen"  "stack.sh would refuse at its [3/3]" "$OUT"
has   "  and says what to do about it"                     "ndt down" "$OUT"

# The reuse path, which is the reason the check was advisory-only before: our own running stack
# holds :8000, and refusing it would make `ndt up` on a live stack impossible.
reset_fix; ledger kernel 992261
OUT="$(FX_HELD="8000:992261" drive 'preflight ovs')"
check "🔴 :8000 held by OUR OWN kernel is not a refusal"   "0"  "$(rc_of_out "$OUT")"
hasnt "  and is not reported as foreign"                   "not part of this checkout" "$OUT"
has   "  it is still named, as residue"                    "residue" "$OUT"

# Same, one level less direct: the listener is a child of the recorded process group leader.
# start_bg setsids, so this is the ownership rule stack.sh's port_owner_verdict already uses.
reset_fix; ledger kernel 992261
OUT="$(FX_HELD="8000:992999" FX_PGID="992999:992261" drive 'preflight ovs')"
check "a listener in our recorded process group is ours"   "0"  "$(rc_of_out "$OUT")"

# 🔴 The control that stops "refuse whenever a needed port is held" from passing this group.
# bmv2 runs as root under ndtwin-lab, so `ss` shows us no pid for :30051 at all. Refusing on
# that would refuse every live P4 fabric -- the reuse path, again.
reset_fix
OUT="$(FX_HELD="30051:" drive 'preflight p4')"
check "🔴 a holder we cannot see is NOT refused"           "0"  "$(rc_of_out "$OUT")"
has   "  it is reported as unowned-as-far-as-we-can-tell"  "cannot see" "$OUT"
hasnt "  and never as foreign"                             "not part of this checkout" "$OUT"

# The plane column has to be honoured, or `ndt up ovs` starts refusing on P4-only leftovers.
reset_fix
OUT="$(FX_HELD="8081:777" drive 'preflight ovs')"
check "a P4-only port does not block an OVS bring-up"      "0"  "$(rc_of_out "$OUT")"
OUT="$(FX_HELD="8081:777" drive 'preflight p4')"
check "  and does block a P4 one"                          "1"  "$(rc_of_out "$OUT")"

# 🔴 The other direction: not simply always red.
reset_fix
OUT="$(drive 'preflight ovs')"
check "nothing held: preflight passes"                     "0"  "$(rc_of_out "$OUT")"
hasnt "  and says nothing about foreign holders"           "not part of this checkout" "$OUT"

section "2. #3(b): a bring-up that fails after changing the machine takes it back down"
# up_ovs, the measured shape: Ryu started, the fabric built, then the kernel step failed.
reset_fix; rc_for stack_up 1; echo "0 14 0" > "$FIX/mn.seq"
OUT="$(drive 'up_ovs 4')"
check "a failed 'ndt up ovs4' exits non-zero"              "1"  "$(rc_of_out "$OUT")"
has   "  and rolls back"                                   "rollback" "$OUT"
has   "  naming what it had started"                       "this bring-up started" "$OUT"
has   "  stops what stack.sh started (Ryu)"                "stopped ryu" "$OUT"
SUDO="$(cat "$FIX/sudo.log")"; STACKLOG="$(cat "$FIX/stack.log")"
has   "  stops the topo session"                           "topo-stop" "$SUDO"
has   "  sweeps the data plane"                            "cleanup" "$SUDO"
has   "  and takes the control plane down through stack.sh" "down" "$STACKLOG"
has   "🔴 keeps .test_run/up.target on purpose"            "kept .test_run/up.target" "$OUT"
check "  the record really is still there"                 "yes" "$( [[ -f "$FIX/.test_run/up.target" ]] && echo yes || echo no )"

# 🔴 The control against "roll back on any non-zero exit". A stack that came UP and then failed
# its verification is the state an operator most needs to look at; tearing it down destroys the
# evidence and is not what #3 asks for.
# The sequence is "0 10": no orphan on the reading that looks for one, ten switches on every
# reading after -- a bring-up that builds its own fabric, gets a stack, and then fails [3/3].
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
OUT="$(FX_VERIFY_RC=1 drive 'up_p4')"
check "a bring-up that came up but did not verify is red"  "1"  "$(rc_of_out "$OUT")"
hasnt "🔴 and is NOT rolled back"                          "rollback" "$OUT"
SUDO="$(cat "$FIX/sudo.log")"
hasnt "  nothing is swept"                                 "cleanup" "$SUDO"

# 🔴 The control against "tear down everything you can find". This run REUSED a fabric it did
# not start; rolling that back is tearing down someone else's lab.
reset_fix; rc_for stack_up 1
OUT="$(FX_TOPO_SESSION=1 FX_BMV2=10 FX_FABRIC_HOSTS=4 drive 'up_p4')"
check "a bring-up that reused a fabric still exits non-zero" "1" "$(rc_of_out "$OUT")"
has   "  and rolls back what it did start"                 "rollback" "$OUT"
SUDO="$(cat "$FIX/sudo.log")"
hasnt "🔴 but does NOT sweep the fabric it reused"         "cleanup" "$SUDO"
hasnt "  and does not stop its topo session"               "topo-stop" "$SUDO"

# Nothing started yet: a refusal before the first machine-changing step must not announce a
# rollback it did not need to do.
reset_fix
OUT="$(FX_HELD="8000:992261" drive 'up_ovs 4')"
check "a preflight refusal exits non-zero"                 "1"  "$(rc_of_out "$OUT")"
hasnt "  and does not claim to have rolled anything back"  "rollback" "$OUT"
SUDO="$(cat "$FIX/sudo.log")"
check "  the machine was not touched at all"               ""   "$SUDO"

# up_ovs's other reachable failure: stack.sh exits before the Mininet prompt. Ryu may already be
# up, so this is after the first machine-changing step.
reset_fix; touch "$FIX/stack_ovs_dies_early"
OUT="$(drive 'up_ovs 4')"
check "stack.sh exiting early is red"                      "1"  "$(rc_of_out "$OUT")"
has   "  and rolls back"                                   "rollback" "$OUT"
STACKLOG="$(cat "$FIX/stack.log")"
has   "  through stack.sh down"                            "down" "$STACKLOG"

# The fabric verb itself failing, in up_ovs: the tmux session may exist even so.
reset_fix; rc_for ovs-topo-4host 1
OUT="$(drive 'up_ovs 4')"
check "a failed ovs-topo-4host is red"                     "1"  "$(rc_of_out "$OUT")"
has   "  and rolls back"                                   "rollback" "$OUT"
SUDO="$(cat "$FIX/sudo.log")"
has   "  including the topo session it may have created"   "topo-stop" "$SUDO"

# A rollback that could not finish must say so rather than report a tidy machine.
reset_fix; rc_for stack_up 1; rc_for cleanup 1; out_for cleanup "  STILL RUNNING  simple_switch_grpc pid 4242"
echo "0 14 0" > "$FIX/mn.seq"
OUT="$(FX_BMV2=5 drive 'up_ovs 4')"
has   "an incomplete rollback says so"                     "rollback INCOMPLETE" "$OUT"
has   "  and names the survivor cleanup reported"          "STILL RUNNING" "$OUT"
hasnt "  and never claims the machine is back as it was"   "the machine is back to what it was" "$OUT"

section "3. #21: cleanup's exit status is read, not thrown away"
# up_p4 with an orphan bmv2 and no topo session -- the exact branch, ndt:803 on trunk.
# 🔴 The sequence is "3 10": three orphans on the reading that finds them, ten switches on every
# reading after -- i.e. a bring-up that would otherwise have gone all the way to green. Without
# it this case is red on trunk for the wrong reason (a fabric that never came up), and a red for
# the wrong reason proves nothing about the sweep.
reset_fix; rc_for cleanup 1; out_for cleanup "  STILL RUNNING  simple_switch_grpc pid 4242 (TERM and KILL both refused)"
echo "3 10" > "$FIX/bmv2.seq"
OUT="$(drive 'up_p4')"
check "🔴 a failed orphan sweep refuses the bring-up"      "1"  "$(rc_of_out "$OUT")"
has   "  and names the survivor"                           "STILL RUNNING" "$OUT"
has   "  and says why building on it misleads"             "looks like a P4 problem" "$OUT"
SUDO="$(cat "$FIX/sudo.log")"
hasnt "🔴 and no fabric is started on top of it"           "topo-start" "$SUDO"

# The other direction: a sweep that succeeds must not block anything.
reset_fix; rc_for cleanup 0
echo "3 10" > "$FIX/bmv2.seq"
OUT="$(drive 'up_p4')"
check "🔴 a successful orphan sweep is not turned into a refusal" "0" "$(rc_of_out "$OUT")"
SUDO="$(cat "$FIX/sudo.log")"
has   "  and the bring-up proceeds"                        "topo-start" "$SUDO"

# cmd_down's sweep: same shape, through a pipeline.
reset_fix; rc_for cleanup 1; out_for cleanup "  STILL RUNNING  ntg_bmv2_topo pid 99"
OUT="$(drive 'cmd_down')"
check "🔴 'ndt down' is red when its sweep did not finish" "1"  "$(rc_of_out "$OUT")"
has   "  and names what survived"                          "STILL RUNNING" "$OUT"
has   "  saying the sweep itself failed"                   "cleanup exited 1" "$OUT"

reset_fix
OUT="$(drive 'cmd_down')"
check "🔴 and a clean teardown is still green"             "0"  "$(rc_of_out "$OUT")"
hasnt "  with no complaint about the sweep"                "cleanup exited" "$OUT"

section "4. #49: the teardown verify waits for the sweep it is verifying"
# The measured case: five bmv2 still in the table at the instant of the assertion, gone shortly
# after. Trunk asserts immediately and reports "5 still running / not clean".
reset_fix; echo "5 5 5 0" > "$FIX/bmv2.seq"
OUT="$(drive 'cmd_down')"
check "🔴 processes reaped just after the sweep are not a failure" "0" "$(rc_of_out "$OUT")"
has   "  and the wait is reported, not hidden"             "waited" "$OUT"
hasnt "  no false 'still running'"                         "bmv2 switches: 5 still running" "$OUT"
has   "  the assertion still ran"                          "bmv2 switches: 0" "$OUT"

# 🔴 The control against "wait until it looks clean". A process that never goes away must still
# be red, and the wait must be bounded.
reset_fix; echo "5" > "$FIX/bmv2.seq"
OUT="$(drive 'cmd_down')"
check "🔴 a process that never leaves is still RED"        "1"  "$(rc_of_out "$OUT")"
has   "  and the bound is stated"                          "not waiting further" "$OUT"
has   "  and the assertion reports what is there"          "still running" "$OUT"

# Nothing to wait for: no wait, and no line about one.
reset_fix
OUT="$(drive 'cmd_down')"
hasnt "a clean machine is not made to wait"                "waited" "$OUT"

# `ndt clean` on its own stays an instantaneous assertion -- it is the teardown ASSERTION, and
# a caller running it to ask "is the machine clean right now" must not be given a wait.
reset_fix; echo "5 0" > "$FIX/bmv2.seq"; rm -f "$FIX/manifest.json"
OUT="$(drive 'cmd_clean')"
check "🔴 'ndt clean' alone does not wait"                 "1"  "$(rc_of_out "$OUT")"
has   "  it answers about this instant"                    "bmv2 switches: 5 still running" "$OUT"

section "5. #83: the installed helper is compared with this tree's, and named"
reset_fix; mk_helpers "helper 08-30" "helper trunk"
OUT="$(drive 'lab_version_report')"
check "a differing helper is reported"                     "1"  "$(rc_of_out "$OUT")"
has   "  naming the installed path"                        "/installed-ndtwin-lab" "$OUT"
has   "  naming the repo path"                             "tools/test_workflow/ndtwin-lab" "$OUT"
has   "  with both sha256 prefixes"                        "$(sha256sum "$FIX/installed-ndtwin-lab" | cut -c1-8)" "$OUT"
has   "  and the other one"                                "$(sha256sum "$FIX/tools/test_workflow/ndtwin-lab" | cut -c1-8)" "$OUT"
has   "  it says which copy actually runs"                 "run the INSTALLED copy" "$OUT"
has   "  and gives the install command verbatim"           "sudo install -o root -g root -m 755 tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab" "$OUT"

reset_fix; mk_helpers "helper same" "helper same"
OUT="$(drive 'lab_version_report')"
check "🔴 matching copies are green and quiet"             "0"  "$(rc_of_out "$OUT")"
hasnt "  no install advice when nothing needs installing"  "sudo install" "$OUT"

reset_fix; mk_helpers - "helper trunk"
OUT="$(drive 'lab_version_report')"
check "a missing installed helper is a problem"            "1"  "$(rc_of_out "$OUT")"
has   "  and is named as missing, not as a mismatch"       "is not installed" "$OUT"

reset_fix; mk_helpers "helper 08-30" -
OUT="$(drive 'lab_version_report')"
check "🔴 'could not compare' is not green"                "2"  "$(rc_of_out "$OUT")"
has   "  and says which side it could not read"            "could not compare" "$OUT"

# The three places the answer has to show up.
reset_fix; mk_helpers "helper 08-30" "helper trunk"
OUT="$(drive 'cmd_status')"
has   "'ndt status' prints it in the lab section"          "helper" "$OUT"
has   "  with the install command"                         "sudo install -o root -g root -m 755" "$OUT"

OUT="$(drive 'cmd_status --check')"
check "🔴 'ndt status --check' counts it as a problem"     "1"  "$(rc_of_out "$OUT")"
has   "  and lists it among the problems"                  "- the installed" "$OUT"
has   "  naming the path a reader can act on"              "tools/test_workflow/ndtwin-lab" "$OUT"

# 🔴 The other direction, on the same fixture: it is not simply always a problem.
reset_fix; mk_helpers "helper same" "helper same"
OUT="$(drive 'cmd_status --check')"
check "🔴 and matching copies leave --check green"         "0"  "$(rc_of_out "$OUT")"
hasnt "  with nothing in the problem list about it"        "- the installed" "$OUT"

reset_fix; mk_helpers "helper 08-30" "helper trunk"
OUT="$(drive 'preflight ovs')"
check "🔴 preflight WARNS and does not refuse"             "0"  "$(rc_of_out "$OUT")"
has   "  the operator is told before the run"              "helper" "$OUT"
has   "  and told what to do"                              "sudo install -o root -g root -m 755" "$OUT"

section "6. R5: 'ndt up' from a tree the lab does not act in is refused, and says why"
# The measured shape (R5-P4-128-SUMMARY §2-§3, 2026-09-10): `ndt up p4 128` from a worktree
# built a 4-host fabric out of the MAIN checkout -- ndtwin-lab's KERNEL_DIR is a built-in
# constant -- under a 128-host kernel and proxy from the worktree. One `up`, two trees, two
# host counts; every structural check green; the only thing said about it was one line at
# [3/3] naming a host count and neither tree.
#
# The fixture is the two trees, with the two host counts of that night: this checkout says 4,
# the tree the lab acts in says 128.
mkdir -p "$FIX/other-tree/p4_proxy/mininet"
echo 128 > "$FIX/other-tree/p4_proxy/mininet/host_count_override"
ln -sfn "$FIX" "$FIX/self-link"

reset_fix; echo 4 > "$FIX/p4_proxy/mininet/host_count_override"
OUT="$(FX_LAB_KERNEL_DIR="$FIX/other-tree" drive 'up_p4')"
check "🔴 'ndt up p4' from a tree the lab does not act in is refused" "1" "$(rc_of_out "$OUT")"
has   "  this checkout's path, with ITS host count"        "$FIX  (host_count_override 4)" "$OUT"
has   "  the lab's tree, with ITS host count"              "$FIX/other-tree  (host_count_override 128)" "$OUT"
has   "  and where that second path came from"             "built-in default" "$OUT"
has   "🔴 the sentence that says which half comes from where, and both ways out" \
      "fabric would come from $FIX/other-tree, kernel/proxy from $FIX; run ndt from $FIX/other-tree or point the lab at $FIX" "$OUT"
has   "  and how root would move the lab's tree"           "sudo install -o root -g root -m 644 /dev/stdin $FIX/etc/ndtwin-lab.conf" "$OUT"
SUDO="$(cat "$FIX/sudo.log")"; STACKLOG="$(cat "$FIX/stack.log")"
check "🔴 nothing on the machine was touched"              ""   "$SUDO"
check "  no fabric was started"                            ""   "$STACKLOG"
check "  and no up.target was recorded"                    "no" "$( [[ -f "$FIX/.test_run/up.target" ]] && echo yes || echo no )"
hasnt "  it is a refusal, not a rollback"                  "rollback" "$OUT"

# The OVS plane goes through the same helper: ovs-topo-start and ovs-topo-4host derive their
# topology from the same KERNEL_DIR (ndtwin-lab's ovs_topo_script), so the refusal cannot be
# P4-only. Ryu is the first thing up_ovs starts, and it must not be started here.
reset_fix
OUT="$(FX_LAB_KERNEL_DIR="$FIX/other-tree" drive 'up_ovs 4')"
check "🔴 'ndt up ovs4' is refused for the same reason"    "1"  "$(rc_of_out "$OUT")"
has   "  naming the lab's tree"                            "$FIX/other-tree" "$OUT"
# 🔴 The two numbers are host_count_override, which is the P4 plane's knob and nothing else's:
# `ndt status` printed it on the OVS plane for weeks (D-2 / X-2) and it was read as an answer
# about OVS. On this plane the size is the verb, so the message has to say so itself.
has   "🔴 and says that knob is the P4 plane's, not what OVS builds" \
      "that knob is the P4 plane's" "$OUT"
STACKLOG="$(cat "$FIX/stack.log")"
check "  and Ryu is never started"                         ""   "$STACKLOG"

# Callable on its own, the way guard_no_live_ovs is: the whole decision, including "they are
# the same tree", is one function a test can ask directly.
reset_fix
OUT="$(FX_LAB_KERNEL_DIR="$FIX/other-tree" drive 'guard_lab_acts_in_this_tree')"
check "the guard answers on its own"                       "1"  "$(rc_of_out "$OUT")"

# 🔴 The other direction. Without these three the guard could refuse everything and every
# case above would still pass -- which is the N* widening this suite exists to catch.
reset_fix
OUT="$(drive 'guard_lab_acts_in_this_tree')"
check "🔴 the same tree is not a refusal"                  "0"  "$(rc_of_out "$OUT")"
hasnt "  and says nothing"                                 "does not act in this checkout" "$OUT"

reset_fix; echo "0 10" > "$FIX/bmv2.seq"
OUT="$(drive 'up_p4')"
check "🔴 and 'ndt up p4' still comes up in that tree"     "0"  "$(rc_of_out "$OUT")"
SUDO="$(cat "$FIX/sudo.log")"
has   "  the fabric really was built"                      "topo-start" "$SUDO"

# 🔴 It compares TREES, not strings: the same tree named through a symlink, and the same tree
# with a trailing slash, are the same tree. A string comparison passes every case above and
# then refuses every correctly-configured run on a machine where /etc/ndtwin-lab.conf writes
# the path in any other form -- which is how a guard against a silent wrong answer becomes a
# bring-up that cannot be made to work at all.
reset_fix
OUT="$(FX_LAB_KERNEL_DIR="$FIX/self-link" drive 'guard_lab_acts_in_this_tree')"
check "🔴 the same tree through a symlink is not a refusal" "0" "$(rc_of_out "$OUT")"
reset_fix
OUT="$(FX_LAB_KERNEL_DIR="$FIX/" drive 'guard_lab_acts_in_this_tree')"
check "🔴 the same tree with a trailing slash is not a refusal" "0" "$(rc_of_out "$OUT")"

section "7. R5: topo-start's output is printed, not discarded"
# ndtwin-lab prints "topo session started from <KERNEL_DIR>" on purpose -- its comment there
# says FINDING-01 ran two trees for a whole round with no line of output that could have
# caught it. `ndt` then sent that line to /dev/null (ndt:1673 on trunk), so on 09-10 the same
# two-tree run produced nothing on screen naming either tree. The guard above only fires when
# the trees DIFFER; this line is what names the tree when they do not.
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
out_for topo-start "topo session started from $FIX (attach: sudo tmux -L ndtwinlab attach -t topo)"
OUT="$(drive 'up_p4')"
check "a bring-up that starts a fabric is still green"     "0"  "$(rc_of_out "$OUT")"
has   "🔴 and the helper's 'which tree' line reaches the operator" \
      "topo session started from $FIX" "$OUT"

# The failure path keeps it too: what the helper said is the only evidence of why it refused.
reset_fix; rc_for topo-start 1; out_for topo-start "topo session already running (topo-stop first)"
echo "0 10" > "$FIX/bmv2.seq"
OUT="$(drive 'up_p4')"
check "a failed topo-start is still red"                   "1"  "$(rc_of_out "$OUT")"
has   "  and what the helper said is not swallowed"        "topo session already running" "$OUT"
has   "  alongside ndt's own line"                         "topo-start failed" "$OUT"

# ==========================================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
