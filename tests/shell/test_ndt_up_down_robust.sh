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
        # A1: what a teardown SAYS is a fixture too, not two hard-coded lines. `out.stack_down`
        # is how section 12 replays stack.sh cmd_down's real prose -- report_exit's two halves,
        # sweep_orphan_exits' registry line, the port table's consequence/remedy pair and the
        # crash sentence with its names line -- through ndt's own filter.
        if [[ -f "$FIX/out.stack_down" ]]; then cat "$FIX/out.stack_down"
        else echo "stopped kernel"; echo "stopped ryu"; fi
        exit "$(rc_of stack_down)" ;;
esac
exit 0
FAKE
chmod +x "$FIX/stack.sh"

# The scripted exit statuses and the reading sequences, reset between groups.
reset_fix() {
    rm -f "$FIX/rc."* "$FIX/out."* "$FIX/sudo.log" "$FIX/stack.log" \
          "$FIX/stack_ovs_dies_early" "$FIX/stack_ovs_no_prompt" \
          "$FIX/topo_p4.seen" "$FIX/topo_ovs.seen" \
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
section "8. H4: a model of a DIFFERENT network is refused before anything is built"
# ==========================================================================================
# Measured live by ROLE-2, 2026-09-11 01:20 (ROLE-2-CYCLES-REPORT §4, cycle-07):
# `NDT_TOPO=setting/StaticNetworkTopologyP4_10Switches_128Hosts.json ndt up p4 4` was not
# refused. It printed `hosts 4` and the 128-host model on adjacent lines, built the 4-host
# fabric, wrote `hosts=4` and `model_hosts=128` into the same up.target, and hung in [2/3] for
# over 300 s with :8000 never opening -- the kernel was never started at all, and the proxy's
# log said `switch-entered was never acknowledged for [1..10] after 30 retries`.
#
# The escape hatch checked only that the file existed (`[[ -f "$NDT_TOPO" ]]`). Two guards now:
# topo_for_hosts, which is where the hatch is, and record_up_target, which is the one place
# every plane and every model path passes through and the function that was writing both
# numbers side by side without comparing them.
reset_fix
mk_topo StaticNetworkTopologyP4_10Switches_128Hosts.json 128 288
T128="$FIX/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
T4="$FIX/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json"

OUT="$(NDT_TOPO="$T128" drive 'topo_for_hosts 4 p4; echo "TRC=$? REFUSAL=[$TOPO_REFUSAL]"')"
has   "  🔴 rc 3 -- a real file, for the wrong network"    "TRC=3" "$OUT"
has   "  and the reason names both counts"                 "4 host(s) asked for on the p4 plane, 128 declared" "$OUT"
has   "  and the file"                                     "$T128" "$OUT"
hasnt "  🔴 and the model path is NOT printed for a caller to use" "REFUSAL=[]" "$OUT"

# 🔴 The whole bring-up, from the argv ROLE-2 typed. The refusal is above the claim check, the
# in-flight check and preflight, so nothing on the machine has been read yet, let alone changed.
reset_fix
OUT="$(NDT_TOPO="$T128" drive 'up_p4 4')"
check "  🔴 'ndt up p4 4' with a 128-host NDT_TOPO is refused" "5" "$(rc_of_out "$OUT")"
has   "  and says what it is refusing"                     "refusing to build" "$OUT"
has   "  naming a model of a different network"            "names a model of a different network" "$OUT"
# The numbers reach the OPERATOR, not only TOPO_REFUSAL. They travel out of a command
# substitution to get here, and F8 is what happens when a fix forgets that: `topo="$(...)"`
# left the reason empty in up_p4's shell and this line printed its fallback, naming nothing.
has   "  🔴 and the refusal names both counts, not a fallback" \
      "4 host(s) asked for on the p4 plane, 128 declared" "$OUT"
has   "  and where the fabric's number comes from"         "host_count_override" "$OUT"
has   "  and how to make the two agree"                    "ndt up p4 <n>" "$OUT"
check "  🔴 and NOTHING was built: no topo-start, no cleanup" "" "$(cat "$FIX/sudo.log")"
check "  🔴 and no baseline was written"                   "absent" \
      "$([[ -f "$FIX/.test_run/up.target" ]] && echo present || echo absent)"

# record_up_target is the second guard, and the general one: it refuses the same pair even when
# it is handed to it directly, which is the shape any later escape hatch would arrive in.
reset_fix
OUT="$(drive "record_up_target p4 4 '$T128'")"
check "  🔴 record_up_target refuses hosts=4 against model_hosts=128" "5" "$(rc_of_out "$OUT")"
has   "  and says they are different networks"             "different networks" "$OUT"
has   "  quoting the two fields it would have written"     "hosts=4, model_hosts=128" "$OUT"
check "  🔴 and writes no file"                            "absent" \
      "$([[ -f "$FIX/.test_run/up.target" ]] && echo present || echo absent)"

# 🔴 THE CONTROLS. "Refuse whenever NDT_TOPO is set" would satisfy every check above and remove
# the escape hatch the manual documents (doc/2026-08-17_testing-manual.md:832).
reset_fix
OUT="$(NDT_TOPO="$T4" drive 'topo_for_hosts 4 p4; echo "TRC=$?"')"
has   "  🔴 a MATCHING NDT_TOPO is still honoured"         "TRC=0" "$OUT"
has   "  and its path is what comes back"                  "$T4" "$OUT"
OUT="$(drive 'topo_for_hosts 4 p4; echo "TRC=$?"')"
has   "  🔴 and with no NDT_TOPO the glob still answers"   "TRC=0" "$OUT"
has   "  with the 4-host model"                            "StaticNetworkTopologyP4_10Switches_4Hosts.json" "$OUT"
# The glob branch answers "no such model" with rc 0 and an EMPTY line, and both callers test
# the string. Left exactly as it was -- what must not happen is that answer becoming rc 3, which
# would send an operator looking for an NDT_TOPO they never set.
OUT="$(drive 'topo_for_hosts 7 p4; echo "TRC=$?"')"
has   "  a size no model has is rc 0 with nothing, as before" "TRC=0" "$OUT"
hasnt "  🔴 and never rc 3 -- there is no NDT_TOPO to blame"  "TRC=3" "$OUT"
hasnt "  and no model is named"                            "StaticNetworkTopology" "$OUT"
OUT="$(NDT_TOPO="$FIX/setting/does-not-exist.json" drive 'topo_for_hosts 4 p4; echo "TRC=$?"')"
has   "  a missing NDT_TOPO file is still rc 1, not 3"     "TRC=1" "$OUT"
reset_fix
OUT="$(drive "record_up_target p4 4 '$T4'")"
check "  🔴 and a matching pair is still recorded"         "0" "$(rc_of_out "$OUT")"
check "  the baseline is there"                            "present" \
      "$([[ -f "$FIX/.test_run/up.target" ]] && echo present || echo absent)"

# 🔴 A model whose hosts cannot be counted is WARNED about and then built: NDT_TOPO exists for
# models that do not follow the conventions, and "I could not count them" is not evidence of a
# mismatch. What it must not do is look like a comparison that passed (E-7).
reset_fix
printf 'not json at all\n' > "$FIX/setting/unreadable.json"
OUT="$(NDT_TOPO="$FIX/setting/unreadable.json" drive 'topo_for_hosts 4 p4; echo "TRC=$?"')"
has   "  an uncountable model is not refused"              "TRC=0" "$OUT"
has   "  🔴 but the missing comparison is said out loud"   "was NOT compared against it" "$OUT"
# 🔴 warn() writes to STDOUT (ndt:102) and this function's stdout IS the model path, so a
# warning printed the ordinary way becomes part of the filename. This is that cell.
OUT="$(NDT_TOPO="$FIX/setting/unreadable.json" bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
topo_for_hosts 4 p4" 2>/dev/null)"
check "  🔴 and the warning does not land in the model path" "$FIX/setting/unreadable.json" "$OUT"

# ==========================================================================================
section "9. H3: a bring-up that overlaps a teardown is refused, on BOTH planes"
# ==========================================================================================
# Measured live by ROLE-2, 2026-09-11 (ROLE-2-CYCLES-REPORT §4, cycle-13): a second `ndt up p4`
# 13 s after a backgrounded `ndt down` printed `ok already up: 10 switches, 4 hosts, reusing`,
# then PASSED `ok model matches fabric` with the fabric mid-SIGTERM, and the teardown went on to
# name that run's own kernel and proxy as residue and advise `ndt down --deep`. On OVS the same
# overlap was refused one second in, by mn_count. The difference is not care: bmv2 is root-owned
# and its ports look identical coming up and going down, so on P4 there was nothing to read. The
# teardown now records that it is running, and preflight refuses on the record.
reset_fix
DM="$FIX/.test_run/down.inflight"

# A live teardown: this test's own shell is the pid, so it is certainly alive.
printf 'pid=%s\nat=2026-09-11T01:26:11+0800\nby=role-2\n' "$$" > "$DM"
OUT="$(drive 'preflight p4')"
check "  🔴 P4 preflight refuses while a teardown runs"  "5" "$(rc_of_out "$OUT")"
has   "  and says what it is refusing"                   "an 'ndt down' from this checkout is still running" "$OUT"
has   "  naming the pid that is doing it"                "pid $$" "$OUT"
has   "  and when it started"                            "2026-09-11T01:26:11+0800" "$OUT"
has   "  🔴 and what the overlap actually does"          "REUSES the fabric" "$OUT"
has   "  quoting what [1/3] said on 09-11"               "already up: 10 switches, reusing" "$OUT"
has   "  and the remedy"                                 "wait for it to finish" "$OUT"
OUT="$(drive 'preflight ovs')"
check "  and OVS preflight refuses too"                  "5" "$(rc_of_out "$OUT")"
# The whole bring-up, not just the predicate: nothing may be built.
reset_fix; printf 'pid=%s\nat=2026-09-11T01:26:11+0800\n' "$$" > "$DM"
OUT="$(drive 'up_p4 4')"
check "  🔴 'ndt up p4 4' is refused"                    "5" "$(rc_of_out "$OUT")"
check "  🔴 and no topo-start ran"                       "absent" \
      "$(grep -qF topo-start "$FIX/sudo.log" && echo present || echo absent)"

# 🔴 THE STALE MARKER, which is the failure this must not create: a `down` that was killed
# leaves the file behind, and a marker that outlived its process must not make the lab
# unstartable. Pid 2 is init's kthreadd on Linux, so instead of guessing a dead pid the fixture
# uses one that certainly is not an `ndt down`: a pid that has exited. `$!` of a finished
# background job is the cheapest one that is certainly gone.
reset_fix
(exit 0) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
printf 'pid=%s\nat=2026-09-10T23:59:31+0800\n' "$DEADPID" > "$DM"
OUT="$(drive 'preflight p4')"
check "  🔴 a marker whose pid is gone does NOT refuse"  "0" "$(rc_of_out "$OUT")"
has   "  it says it removed it"                          "removing a stale teardown marker" "$OUT"
has   "  naming the pid and when"                        "2026-09-10T23:59:31+0800" "$OUT"
check "  🔴 and the file is gone, so it cannot block again" "absent" \
      "$([[ -f "$DM" ]] && echo present || echo absent)"
# A marker with no pid field at all -- a truncated write -- is stale, not a refusal.
reset_fix; printf 'at=2026-09-10T23:59:31+0800\n' > "$DM"
OUT="$(drive 'preflight p4')"
check "  a marker with no pid is stale too"              "0" "$(rc_of_out "$OUT")"

# 🔴 THE CONTROLS. "Refuse when the marker file exists" and "always refuse" both satisfy the
# cells above; so would a guard wired to nothing.
reset_fix
OUT="$(drive 'preflight p4')"
check "  🔴 no marker: preflight passes, as before"      "0" "$(rc_of_out "$OUT")"
hasnt "  and says nothing about a teardown"              "still running" "$OUT"
OUT="$(drive 'preflight ovs')"
check "  and so does OVS"                                "0" "$(rc_of_out "$OUT")"

# The teardown is what writes it, and the teardown is what takes it away. `cmd_down` is driven
# with a fake stack and helper, as in group 4.
reset_fix
OUT="$(drive 'cmd_down; echo "MARKER=$([[ -f "$(down_marker)" ]] && echo present || echo absent)"')"
has   "  🔴 'ndt down' removes its own marker when it finishes" "MARKER=absent" "$OUT"
check "  and left none on disk"                          "absent" \
      "$([[ -f "$DM" ]] && echo present || echo absent)"
# 🔴 And it is written while the teardown is RUNNING, not merely created and deleted: the marker
# is read from inside the teardown, at the moment cmd_clean runs.
reset_fix
OUT="$(drive 'cmd_clean() { teardown_in_flight >/dev/null && echo "MARKER-LIVE-DURING-DOWN"; return 0; }
cmd_down')"
has   "  🔴 and it is present DURING the teardown, not just around it" "MARKER-LIVE-DURING-DOWN" "$OUT"
# A `down` that REFUSES never claims to be tearing down.
reset_fix
OUT="$(drive 'foreign_claim() { echo other-owner; }; cmd_down; echo "MARKER=$([[ -f "$(down_marker)" ]] && echo present || echo absent)"')"
has   "  🔴 a refused 'ndt down' writes no marker"       "MARKER=absent" "$OUT"

# ==========================================================================================
section "10. F1: 'ndt up p4' asks for the P4 plane's rate, not for whatever plane is live"
# ==========================================================================================
# F-OFFLINE-1 §1.14. `up_p4` read `rate="$(sample_rate)"` with NO argument, so sample_rate asked
# live_dataplane_kind -- and on a machine where an OVS fabric had been left up that answers
# `ovs`, so the number came out of OVSDB and was printed under the label "(compiled into
# ndtwin_switch.json)". The worst form is not a wrong fraction: it is
# `NO sFlow record on any bridge -- this fabric samples NOTHING` printed as the compiled P4
# pipeline's rate, with the reuse refusal below it asserting that ten bmv2 switches are not
# running it. up_p4 is BUILDING the P4 plane; the plane is not something to look up here.
#
# 🔴 The ARGUMENT is what is observed, not the number. This suite's STUBS answer
# `sample_rate() { echo 256; }`, so an assertion on "1/256" passes whether the call site names
# the plane or not -- it would be a test of the stub. The stub here reports what it was asked.
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
OUT="$(drive 'sample_rate() { echo "ASKED[${1:-NOTHING}]"; }
live_dataplane_kind() { echo ovs; }
up_p4')"
has   "  🔴 the plane is passed, not looked up"          "ASKED[p4]" "$OUT"
hasnt "  🔴 and it is not asked with no argument"        "ASKED[NOTHING]" "$OUT"

# Then the consequence, with a fixture that answers by plane the way sample_rate does: ask for
# p4 and you get the compiled rate; ask for anything else and you get OVS's answer. No
# production logic is copied -- the mapping is the fixture.
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
OUT="$(drive 'sample_rate() { case "${1:-}" in p4) echo 256 ;; *) echo OVS-NOSFLOW ;; esac; }
live_dataplane_kind() { echo ovs; }
up_p4')"
has   "  so the line under the P4 label is the P4 rate" "sample rate  1/256     (compiled into ndtwin_switch.json)" "$OUT"
hasnt "  🔴 and OVS's 'samples NOTHING' never appears there" "samples NOTHING" "$OUT"

# 🔴 The reuse refusal quotes the same $rate, so it inherited the same defect. bmv2 already up,
# so up_p4 takes the reuse path.
reset_fix; echo "10" > "$FIX/bmv2.seq"
OUT="$(drive 'sample_rate() { case "${1:-}" in p4) echo 256 ;; *) echo OVS-NOSFLOW ;; esac; }
live_dataplane_kind() { echo ovs; }
up_p4')"
hasnt "  🔴 nor in the reuse refusal"                    "samples NOTHING" "$OUT"

# ==========================================================================================
section "11. H4 REGRESSION: the tab-packed reading left a newline in the middle of the path"
# ==========================================================================================
# 🔴 Introduced by H4's own fix (76b5d434, on trunk) and proved live and offline by ROLE-6 on
# 2026-09-11 (ROLE-6-SUCCESSOR2-REPORT §1). H4 replaced `topo="$(topo_for_hosts ...)"` with a
# packed reading that carries three answers out of one subshell:
#
#     both="$(topo_for_hosts "$hosts" p4; printf '\t%s\t%s' "$?" "$TOPO_REFUSAL")"
#     topo="${both%%$'\t'*}"
#
# A command substitution strips TRAILING newlines, and topo_for_hosts' newline is no longer
# trailing -- the tab and the rc follow it. So `topo` came out as "<path>\n": every `[[ -f
# "$topo" ]]` false, sha256sum and topo_model_counts silent failures, `topology_sha256=
# unavailable` and an empty `model_hosts=` written into up.target, and the kernel started with a
# --topology argument it could not open. Live result on both planes: `Cannot open topology file`
# / `No port has been opened`, `ndt up p4 4` and `ndt up ovs 4` ending rc 1 after ~318 s with
# `rollback INCOMPLETE`. Two sites, ndt:1948 (p4) and ndt:2287 (ovs).
#
# 🔴 WHY THE 171 CELLS ABOVE DID NOT CATCH IT, which is the part worth keeping. Section 8 tests
# topo_for_hosts DIRECTLY -- its stdout, its rc, its refusal string -- and it was never wrong.
# The one cell that drives the whole bring-up (`up_p4 4` with a 128-host NDT_TOPO) takes the
# rc-3 branch, where `topo` is printed in no message and opened by nothing. So the SPLIT had no
# cell at all: every reader of the packed string was tested except the one that reads the field
# the rest of the bring-up depends on. Existence is not wiring, one level down -- the value
# crossed the boundary and nothing read it back.
#
# Asserted through the RECORD rather than by re-splitting the string here: a test that repeats
# the production expression proves the expression agrees with itself. up.target is where the
# resolved path lands, it is written by the function every plane passes through, and its
# topology_sha256 is a reading OF THE FILE -- so it is 64 hex characters when the path names a
# file and "unavailable" when it does not.
reset_fix
OUT="$(drive 'up_p4 4')"
UT="$FIX/.test_run/up.target"
utf() { sed -n "s/^$1=//p" "$UT" 2>/dev/null | head -1; }
check "  the p4 bring-up wrote a target record"            "present" \
      "$([[ -f "$UT" ]] && echo present || echo absent)"
# read_whole <file> -- the file's content INCLUDING a trailing newline. `$(cat f)` and
# `$(< f)` both strip trailing newlines, so either of them would repair the defect on the way
# to the assertion and report green over it.
# read_whole <file> -> RAW: the file's bytes INCLUDING a trailing newline, in the variable RAW.
# 🔴 NOT `printf '%s' "$v"` out of a function called in `$(...)`: a command substitution strips
# trailing newlines from its own output, so the first draft of this helper deleted the very byte
# section 11 exists to detect and reported green over M38. Measured 2026-09-11 03:2x -- the gate
# caught it, the suite did not. The value is therefore assigned, never substituted.
read_whole() { RAW=""; IFS= read -rd '' RAW < "$1" 2>/dev/null || true; }
check "  the record is the nine lines record_up_target writes" "9" "$(wc -l < "$UT")"
check "  with no empty line in it"                         "0" \
      "$(grep -c '^$' "$UT" 2>/dev/null)"
check "🔴 and the line after the path is the sha, not a blank" "topology_sha256" \
      "$(grep -A1 '^topology=' "$UT" | tail -1 | cut -d= -f1)"
check "🔴 topology_sha256 is a reading of that file, not 'unavailable'" "64" \
      "$(utf topology_sha256 | tr -d '\n' | grep -oE '^[0-9a-f]{64}$' | wc -c | awk '{print $1-1}')"
check "  and the model's hosts were counted"               "4" "$(utf model_hosts)"
has   "  the bring-up printed the model on the topology line" "topology     setting/StaticNetworkTopologyP4_10Switches_4Hosts.json" "$OUT"

# The OVS site is a SEPARATE copy of the same two lines (ndt:2287). One plane fixed is not both
# -- the same shape as M9/M10 in mutate_ndt_honesty.sh.
reset_fix
OUT="$(drive 'up_ovs 4')"
check "  the ovs bring-up wrote a target record"           "present" \
      "$([[ -f "$UT" ]] && echo present || echo absent)"
check "  and the record is nine lines on this plane as well" "9" "$(wc -l < "$UT")"
check "🔴 with a real sha, on the OVS plane as well"       "64" \
      "$(utf topology_sha256 | tr -d '\n' | grep -oE '^[0-9a-f]{64}$' | wc -c | awk '{print $1-1}')"
check "  and its hosts counted"                            "4" "$(utf model_hosts)"

# 🔴 [[ -f ]] on the value itself, taken at the production call that receives it: up_p4 ends
# with `verify_p4 "$topo"` (ndt:2065). The stub records its $1 with no newline of its own, so the
# file's byte count IS the value's length -- every line-based reading (`sed -n 's/^topology=//p'`,
# `$(cat f)`, `$(< f)`) strips a trailing newline and would repair the defect on the way to the
# assertion. That is why the obvious `-f "$FIX/$(utf topology)"` cell has NO discriminating power
# here and is not in this block.
# The bmv2 sequence section 2 uses: no orphan on the reading that looks for one, ten switches
# on every reading after, which is what carries up_p4 past [1/3] and as far as verify_p4.
reset_fix; echo "0 10" > "$FIX/bmv2.seq"
T4P="$FIX/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json"
drive 'verify_p4() { printf "%s" "$1" > "'"$FIX"'/verify.seen"; return 0; }
up_p4 4' >/dev/null 2>&1
read_whole "$FIX/verify.seen"
check "🔴 the path verify_p4 is handed passes [[ -f ]]"    "yes" \
      "$([[ -n "$RAW" && -f "$RAW" ]] && echo yes || echo no)"
check "🔴 and it is the model path byte for byte"          "$(printf '%s' "$T4P" | wc -c)" \
      "$(wc -c < "$FIX/verify.seen" 2>/dev/null || echo missing)"

# 🔴 The three answers H4 packed into one call must still arrive. A fix that strips the newline
# by dropping the packing would take the refusal text with it, which is F8 all over again.
reset_fix
mk_topo StaticNetworkTopologyP4_10Switches_128Hosts.json 128 288
OUT="$(NDT_TOPO="$FIX/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json" drive 'up_p4 4')"
check "  the rc-3 refusal still fires"                     "5" "$(rc_of_out "$OUT")"
has   "  and still carries the reason out of the subshell" "4 host(s) asked for on the p4 plane, 128 declared" "$OUT"

# ==========================================================================================
section '12. A1-a: what stack.sh down said reaches the operator, instead of being filtered'
# FIX-NDT-4 section 7-1, Adam's ruling 2026-09-12 ("both"). ndt down piped stack.sh's teardown
# output through `grep -E 'stopped|still|held'`. Measured at the text layer on 09-12 (the real
# messages through the real regex, logs/gates-0910/red-A1a-textlayer.ndt5-0912-r1.log): six of
# the eight lines that matter were dropped, and the one that got through --
# "teardown itself worked, but something crashed rather than stopped:" -- had its own next
# line, the NAMES, eaten. Every message below is copied from tools/test_workflow/stack.sh.
STACK_DOWN_REAL="Shutting down (reverse order)
  stopped kernel
  🔴 ryu did not stop cleanly: killed by SIGABRT
     evidence: $FIX/.test_run/pids/ryu.exit, and the tail of $FIX/.test_run/logs/ryu.log
  ryu exit status 7 (exited)
  cleared ryu's stale registry files (pid gone): ryu.pid ryu.child.pid
  -> the next bring-up cannot bind :8000
  find and stop it, or the next 'up' will report on it:
  teardown itself worked, but something crashed rather than stopped:
    ryu(134)
Mininet was started manually; clean it up with:  sudo mn -c"

reset_fix; out_for stack_down "$STACK_DOWN_REAL"
OUT="$(drive 'cmd_down')"
has  "🔴 the crash half of B-5 arrives"                 "ryu did not stop cleanly" "$OUT"
has  "  and the evidence it names arrives with it"      "evidence:" "$OUT"
has  "🔴 a plain non-zero ending arrives (#19)"         "ryu exit status 7" "$OUT"
has  "🔴 the stale registry files it cleared are named" "cleared ryu's stale registry files" "$OUT"
has  "  the port table's consequence line"              "the next bring-up cannot bind :8000" "$OUT"
has  "  and the remedy printed under it"                "find and stop it" "$OUT"
has  "🔴 the crash sentence keeps its subject"          "ryu(134)" "$OUT"
has  "  the ordinary 'stopped <name>' lines still show" "stopped kernel" "$OUT"

# 🔴 The control against "just delete the filter". Two lines are dropped on purpose, because
# `ndt down` answers both better itself: its own [1/3] banner, and `sudo mn -c` -- which is
# wrong advice inside `ndt down`, whose step [3/3] runs the sweep.
hasnt "🔴 stack.sh's own banner is not repeated"        "Shutting down (reverse order)" "$OUT"
hasnt "🔴 nor the 'sudo mn -c' advice ndt down obsoletes" "sudo mn -c" "$OUT"

# 🔴 The direction an allowlist cannot hold: the filter must not decide what a FUTURE message
# from stack.sh is worth. This is the cell that goes red if anyone re-narrows it to a list of
# words, which is how the defect was written in the first place.
reset_fix; out_for stack_down "  a sentence stack.sh learned to print after this filter was written"
OUT="$(drive 'cmd_down')"
has  "🔴 a message this filter has never seen is not dropped" \
     "learned to print after this filter" "$OUT"

# One filter, both call sites. The rollback path (ndt's rollback_up, `stack` stage) had the
# same grep, and a bring-up that rolls back is the other moment the crash half matters.
reset_fix; out_for stack_down "  🔴 kernel did not stop cleanly: killed by SIGKILL"
OUT="$(drive 'UP_STARTED=(stack); rollback_up "verification failed"')"
has  "🔴 the rollback path prints it too"               "kernel did not stop cleanly" "$OUT"

# ==========================================================================================
section '13. A1-b: a stack.sh teardown that failed makes ndt down non-zero'
# The other half of FIX-NDT-4 section 7-1. `out=$(... stack.sh down ...)` threw the exit status
# away here while the rollback path a thousand lines up kept it, so B-5's two channels -- the
# message and the rc -- were both shut at the one command an operator runs to finish a round.
reset_fix; rc_for stack_down 1
out_for stack_down "  🔴 kernel did not stop cleanly: killed by SIGKILL
     evidence: $FIX/.test_run/pids/kernel.exit, and the tail of $FIX/.test_run/logs/kernel.log
  teardown itself worked, but something crashed rather than stopped:
    kernel(137)"
OUT="$(drive 'cmd_down')"
check "🔴 'ndt down' is red when its stack.sh half was red" "1" "$(rc_of_out "$OUT")"
has   "  and names which half"                             "stack.sh down exited 1" "$OUT"
has   "  with the component that crashed"                  "kernel(137)" "$OUT"

# 🔴 The control against the obvious wrong fix, an early return. A teardown whose first step
# failed is the teardown that most needs the other three to run: the topology session, the
# sweep, and the assertion are what decide whether the machine is usable at all.
SUDO="$(cat "$FIX/sudo.log")"
has   "🔴 the topology session is still stopped"           "topo-stop" "$SUDO"
has   "  the sweep still runs"                             "cleanup" "$SUDO"
has   "  and the machine is still verified"                "verify clean" "$OUT"

# ...including the baseline removal, which is what makes the NEXT `status --check` honest.
reset_fix; rc_for stack_down 1; printf 'x\n' > "$FIX/.test_run/up.target"
OUT="$(drive 'cmd_down')"
check "🔴 and the up-target baseline is still cleared"     "absent" \
      "$([[ -f "$FIX/.test_run/up.target" ]] && echo present || echo absent)"

# The other direction: a teardown whose stack.sh half was clean must not go red, or every
# round ends in a false alarm and the rc stops meaning anything.
reset_fix; rc_for stack_down 0
OUT="$(drive 'cmd_down')"
check "🔴 a clean stack.sh half is still green"            "0" "$(rc_of_out "$OUT")"
hasnt "  with nothing said about it"                       "stack.sh down exited" "$OUT"

# ==========================================================================================
section '14. ROLE-12: the teardown marker has an OWNER'
# ==========================================================================================
# Measured live by ROLE-12, 2026-09-12 02:07:18-02:07:32 (hunt-0911/logs/ROLE-12/c2b-*, marker
# sampled every 0.2 s). The H3 marker had no owner: mark_teardown_start wrote `pid=$$`
# unconditionally and mark_teardown_end was an unconditional `rm -f`.
#
#   02:07:18.107  D1 writes the marker, pid=2455882.          15 samples say so.
#   02:07:22.115  D2 (a second `ndt down`, same owner) OVERWRITES it with its own pid, while
#                 D1 is still alive. 55 samples say so -- so for 11 s every bring-up that was
#                 refused printed the pid of the teardown that was NOT the one it collided with.
#   02:07:32.687  D1 finishes first and `rm -f`s the marker. The marker was D2's, and D2 is
#                 still running.
#   02:07:32.691  `ndt up p4 4` -- NOT refused, rc 0, reached [3/3] with `data plane forwards`.
#
# i.e. H3's guard is switched off by an overlap, which is the one thing it exists for. Two
# rules, one missing word: a marker held by a LIVE process is not yours to overwrite, and a
# marker that does not name your pid is not yours to remove.
reset_fix; rm -f "$DM"

# A live teardown that is not this one: the test's own shell, which is certainly alive.
printf 'pid=%s\nat=2026-09-12T02:07:18+0800\nby=role-12-D1\n' "$$" > "$DM"
OUT="$(drive 'cmd_down')"
check "🔴 a second 'ndt down' is refused while one is still running" "5" "$(rc_of_out "$OUT")"
has   "  naming what it is refusing on"       "an 'ndt down' from this checkout is still running" "$OUT"
has   "  with the pid that is doing it"       "pid $$" "$OUT"
has   "  and when that one started"           "2026-09-12T02:07:18+0800" "$OUT"
has   "  and the remedy"                      "wait for it to finish" "$OUT"
check "🔴 and the first teardown's marker is untouched" "$$" "$(sed -n 's/^pid=//p' "$DM")"
# The refusal is decided before the machine is touched, like every other one in cmd_down.
check "  🔴 so no stack.sh teardown ran"      "absent" \
      "$(grep -qF down "$FIX/stack.log" && echo present || echo absent)"
check "  and no sweep ran"                    "absent" \
      "$(grep -qF cleanup "$FIX/sudo.log" && echo present || echo absent)"

# 🔴 The consequence the 02:07:22 sample is about: a bring-up during the overlap must name the
# teardown that is really running, not the one that arrived second and overwrote the record.
OUT="$(drive 'preflight p4')"
has   "🔴 a bring-up refused during the overlap names the FIRST teardown" "pid $$" "$OUT"
has   "  and its start time, not the second one's" "2026-09-12T02:07:18+0800" "$OUT"

# 🔴 THE FAILURE THIS MUST NOT CREATE, again: a `down` that was killed leaves the file behind,
# and a marker that outlived its process must not make the lab permanently un-teardownable
# either. Same rule as the bring-up guard, and it has to say whose marker it took.
reset_fix; rm -f "$DM"
(exit 0) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
printf 'pid=%s\nat=2026-09-11T23:59:31+0800\nby=killed-round\n' "$DEADPID" > "$DM"
OUT="$(drive 'cmd_down')"
check "🔴 a marker whose pid is gone does NOT refuse the teardown" "0" "$(rc_of_out "$OUT")"
has   "  and it says whose marker it took over"  "taking over the teardown marker left by pid $DEADPID" "$OUT"
has   "  naming when that one was recorded"      "2026-09-11T23:59:31+0800" "$OUT"
check "  and the marker is gone when it finishes" "absent" \
      "$([[ -f "$DM" ]] && echo present || echo absent)"

# 🔴 mark_teardown_end is asserted DIRECTLY, because the refusal above means a second `down`
# never reaches it -- and the second line of a guard is exactly the one that must not depend on
# the first line holding. It was this `rm -f` that removed the marker of a LIVE teardown.
reset_fix; rm -f "$DM"
printf 'pid=%s\nat=2026-09-12T02:07:18+0800\nby=role-12-D1\n' "$$" > "$DM"
OUT="$(drive 'mark_teardown_end')"
check "🔴 mark_teardown_end does not remove a marker that is not its own" "present" \
      "$([[ -f "$DM" ]] && echo present || echo absent)"
has   "  and says why it left it"             "leaving the teardown marker in place" "$OUT"
has   "  naming the pid recorded in it"       "pid $$" "$OUT"
# ...and the control: it does remove the one it wrote, or one teardown makes the lab unstartable.
reset_fix; rm -f "$DM"
OUT="$(drive 'mark_teardown_start >/dev/null; mark_teardown_end
echo "MARKER=$([[ -f "$(down_marker)" ]] && echo present || echo absent)"')"
has   "  🔴 and it does remove the one it wrote" "MARKER=absent" "$OUT"

# The no-marker control: nothing about ownership may change an ordinary teardown.
reset_fix; rm -f "$DM"
OUT="$(drive 'cmd_down')"
check "🔴 with no marker at all, the teardown runs as before" "0" "$(rc_of_out "$OUT")"
hasnt "  and says nothing about another teardown" "is still running" "$OUT"
hasnt "  nor about taking one over"               "taking over the teardown marker" "$OUT"

# ==========================================================================================
section '15. ROLE-12: the rc of a teardown is its ENDING, not a reading from the middle of it'
# ==========================================================================================
# Measured by ROLE-12, 2026-09-12: SEVEN out of seven `ndt down`s over a live P4 fabric exited
# 1, including one with no concurrency at all (c6-03-down-p4-solo.log, rc captured in the
# foreground). Two live OVS teardowns and one already-down lab: rc 0, and not one of these
# lines. The shape is the order of the steps, not the plane: `stack.sh down` is step [1/3] and
# the bmv2 sweep is [3/3], so on a live P4 fabric the port assertion necessarily runs while the
# fabric is still there and necessarily names the 20 ports (:30051-30060, :9091-9100) of the
# fabric THIS teardown is about to remove -- and the same log then prints
# `ok ports closed: ...30051-30060/9091-9100...` four steps later.
#
# 🔴 The fix that would be worse: "P4 does not check ports". That swaps a reading for an
# assumption, and an orphan on :30051 is exactly what the reading is for. So the ports are
# RE-READ after `verify clean` and the rc follows the SECOND reading.
STACK_DOWN_LIVE_P4="  -> an orphan holding one makes the next fabric fail to bind
  :30051 is still listening, held by a process this user cannot see (probably root-owned)
    This script did not start it. The next 'up' would find the port open and
    measure the wrong process, so this is reported rather than ignored.
  :9091 is still listening, held by a process this user cannot see (probably root-owned)
    This script did not start it. The next 'up' would find the port open and
    measure the wrong process, so this is reported rather than ignored.
  find and stop it, or the next 'up' will report on it:
    ss -ltnp   # tcp rows;  ss -lunp   # the udp one (:6343) -- see ports.sh"

reset_fix; rm -f "$DM"; rc_for stack_down 1; out_for stack_down "$STACK_DOWN_LIVE_P4"
OUT="$(drive 'cmd_down')"
check "🔴 ports [1/3] found open and [3/3] closed are not a failed teardown" "0" "$(rc_of_out "$OUT")"
has   "  what [1/3] said is still printed in full" ":30051 is still listening" "$OUT"
has   "  and the status it produced is still named" "stack.sh down exited 1" "$OUT"
has   "  🔴 with the verdict on those ports deferred" "taken AFTER 'verify clean'" "$OUT"
has   "  🔴 then re-read, by number, and reported closed" "were closed by [3/3]: 9091 30051" "$OUT"
has   "  and 'verify clean' really ran"            "ports closed" "$OUT"

# 🔴 THE OTHER DIRECTION, isolated from the assertion's own rc. `cmd_clean` would go red about
# a held port by itself, so a reader that merely inherited clean_rc would pass this cell while
# doing nothing. Here the assertion is stubbed GREEN and the ports are still held: only a
# second reading of the ports themselves can tell those two apart.
reset_fix; rm -f "$DM"; rc_for stack_down 1; out_for stack_down "$STACK_DOWN_LIVE_P4"
OUT="$(drive 'FX_HELD="30051: 9091:"
cmd_clean() { ok "ports closed: the fixture asserts nothing survived"; return 0; }
cmd_down')"
check "🔴 a port STILL held after [3/3] keeps the teardown red" "1" "$(rc_of_out "$OUT")"
has   "  naming which ones"                       "STILL held after [3/3]: 9091 30051" "$OUT"
# ...and the control for that stub: with the ports closed the same drive is green, so the cell
# above is about the ports and not about the stub.
reset_fix; rm -f "$DM"; rc_for stack_down 1; out_for stack_down "$STACK_DOWN_LIVE_P4"
OUT="$(drive 'cmd_clean() { ok "ports closed: the fixture asserts nothing survived"; return 0; }
cmd_down')"
check "  and green when they are not"             "0" "$(rc_of_out "$OUT")"

# 🔴 A fatal ending in the same breath is NOT deferrable. It is delivered once, out of a .exit
# record report_exit then removes, so an rc that swallowed it would lose it for good.
reset_fix; rm -f "$DM"; rc_for stack_down 1
out_for stack_down "  🔴 kernel did not stop cleanly: killed by SIGKILL
  :30051 is still listening, held by a process this user cannot see (probably root-owned)
  find and stop it, or the next 'up' will report on it:"
OUT="$(drive 'cmd_down')"
check "🔴 a fatal ending alongside the ports keeps the teardown red" "1" "$(rc_of_out "$OUT")"
has   "  and is still reported as the ending it is" "ENDING FROM AN EARLIER ROUND" "$OUT"

# ...and so is a port held by a process this stack STARTED: that is stop_one failing, and no
# sweep of the data plane addresses it.
#
# 🔴 MIXED ON PURPOSE, and the gate is why: with :8000 alone there is no port to defer, so the
# cell passed whether or not the exclusion existed and M46 survived. The state that separates
# them is the real one -- a live P4 fabric's twenty foreign ports AND one the teardown could
# not stop -- where forgiving the first half would forgive the whole status.
reset_fix; rm -f "$DM"; rc_for stack_down 1
out_for stack_down "  :30051 is still listening, held by a process this user cannot see (probably root-owned)
  :8000 is still held by a process this script started (ndtwin_kernel pid 4242) -- stop_one did
    not manage to stop it
  find and stop it, or the next 'up' will report on it:"
OUT="$(drive 'cmd_down')"
check "🔴 a port this stack STARTED still holds keeps the teardown red" "1" "$(rc_of_out "$OUT")"
hasnt "  and nothing is deferred out of that status"  "taken AFTER 'verify clean'" "$OUT"

# 🔴 Pinned to a RETURN SITE, not to a vocabulary: `still listening` with no advice block under
# it did not come from the branch that returns on ports, so nothing is deferred.
reset_fix; rm -f "$DM"; rc_for stack_down 1
out_for stack_down "  :30051 is still listening, held by a process this user cannot see (probably root-owned)"
OUT="$(drive 'cmd_down')"
check "🔴 ports named outside that branch defer nothing"  "1" "$(rc_of_out "$OUT")"

# ...and a non-zero this reader cannot account for at all stays exactly what it was.
reset_fix; rm -f "$DM"; rc_for stack_down 1
out_for stack_down "  the teardown failed for a reason invented after this reader was written"
OUT="$(drive 'cmd_down')"
check "🔴 an unaccounted-for non-zero is still red"       "1" "$(rc_of_out "$OUT")"

# The OVS / already-down control: a clean stack half defers nothing and says nothing.
reset_fix; rm -f "$DM"; rc_for stack_down 0
OUT="$(drive 'cmd_down')"
check "🔴 a clean stack.sh half is still green"           "0" "$(rc_of_out "$OUT")"
hasnt "  and nothing is deferred"                         "taken AFTER 'verify clean'" "$OUT"

# 🔴 Against the CODE, from this tree and never from a mutant copy: the four sentences this
# reader is pinned to are the ones stack.sh really prints, each exactly once. A text-only
# assertion here would keep passing after stack.sh had been reworded, and the fix would then be
# silently back to "every live P4 teardown is red".
STACK_REAL="$HERE/../../tools/test_workflow/stack.sh"
check "  the return-site line is stack.sh's own, and unique" "1" \
      "$(grep -cF "find and stop it, or the next 'up' will report on it:" "$STACK_REAL")"
check "  so is the foreign-holder line"                   "1" \
      "$(grep -cF 'is still listening, held by' "$STACK_REAL")"
check "  and the one for a holder this stack started"     "1" \
      "$(grep -cF 'is still held by a process this script started' "$STACK_REAL")"
check "  and report_exit's fatal-ending line"             "1" \
      "$(grep -cF 'did not stop cleanly:' "$STACK_REAL")"

# ==========================================================================================
section "16. ROLE-12 cell 3: 'ndt clean' refuses while a teardown is in flight"
# ==========================================================================================
# 02:08:24.569 on 2026-09-12, with the marker present and D1 alive and tearing down ten P4
# switches: `ndt clean` was NOT refused. It exited 1, printed `not clean`, and listed the
# operator's own fabric -- the one being destroyed -- as residue: 10 bmv2, 14 host/switch
# processes, the topo session, the manifest, `ndtwin_kernel pid 2460143 holding :8000`,
# `python pid 2459746 holding :8081`, :6343 and the twenty bmv2 ports. Last line:
# `this stack did not start it; to kill it too:  ndt down --deep`.
#
# That is the sentence H3's own refusal quotes as the thing that would have killed the
# operator's processes, arriving through a different door: H3's guard lives in `preflight`, and
# `preflight` is walked by `ndt up` and by nothing else.
reset_fix; rm -f "$DM"
printf 'pid=%s\nat=2026-09-12T02:08:17+0800\nby=role-12-D1\n' "$$" > "$DM"
# 🔴 The two held ports are the fixture half that makes the two `hasnt` cells below mean
# something: without residue there is no `--deep` line to suppress, and the cells would pass
# against a product with no guard at all. 2460143/2459746 are ROLE-12's own numbers.
OUT="$(drive 'FX_BMV2=10 FX_MN=14 FX_TOPO_SESSION=1 FX_HELD="8000:2460143 8081:2459746" cmd_clean')"
check "🔴 'ndt clean' is refused while a teardown is running" "5" "$(rc_of_out "$OUT")"
has   "  naming what it is refusing on"   "an 'ndt down' from this checkout is still running" "$OUT"
has   "  with the pid to wait for"        "pid $$" "$OUT"
has   "  and when that teardown started"  "2026-09-12T02:08:17+0800" "$OUT"
has   "  and the remedy"                  "wait for it" "$OUT"
# 🔴 The needle is cmd_clean's ADVICE LINE, not the words `ndt down --deep`. The refusal names
# that verb while explaining what it would have done, and a bare `--deep` needle matches the
# refusal's own prose -- ROLE-12's cell 5 lost an hour to exactly this shape, a grep that found
# the message it was asserting about quoted inside the message it was asserting on.
hasnt "🔴 and it does NOT advise --deep over that teardown's own fabric" \
      "to kill it too:  ndt down --deep" "$OUT"
hasnt "  nor call the fabric being destroyed residue"  "bmv2 switches: 10 still running" "$OUT"
has   "  it says what that advice would have killed"   "would kill the operator's" "$OUT"

# 🔴 THE CONTROLS. "Refuse whenever the marker file exists" and "always refuse" both satisfy
# every cell above, and the first of them would refuse the last step of every teardown.
reset_fix; rm -f "$DM"
OUT="$(drive 'FX_BMV2=10 cmd_clean')"
check "🔴 with no teardown in flight it judges as before" "1" "$(rc_of_out "$OUT")"
has   "  naming what survived"            "bmv2 switches: 10 still running" "$OUT"
hasnt "  and refuses nothing"             "refusing to judge" "$OUT"

reset_fix; rm -f "$DM"
(exit 0) & DEADPID2=$!; wait "$DEADPID2" 2>/dev/null
printf 'pid=%s\nat=2026-09-11T23:59:31+0800\n' "$DEADPID2" > "$DM"
OUT="$(drive 'FX_BMV2=10 cmd_clean')"
check "🔴 a marker whose pid is gone does not refuse the assertion" "1" "$(rc_of_out "$OUT")"
has   "  it judged the machine instead"   "bmv2 switches: 10 still running" "$OUT"
has   "  and said it removed the stale marker" "removing a stale teardown marker" "$OUT"

# 🔴 The one this must not break: `ndt down`'s own `verify clean` runs under the marker this
# very process wrote. A guard that read the FILE rather than its owner would turn the last step
# of every round into a refusal.
reset_fix; rm -f "$DM"
OUT="$(drive 'cmd_down')"
check "🔴 'ndt down' is not refused by its own marker at verify clean" "0" "$(rc_of_out "$OUT")"
hasnt "  it did not refuse itself"        "refusing to judge" "$OUT"
has   "  and its verify clean really ran" "ports closed" "$OUT"

# ==========================================================================================
section "17. ROLE-11 F5: 'ndt clean' does not call this stack's own fabric somebody else's"
# ==========================================================================================
# Measured 2026-09-12 02:25:14 (ROLE-11 F5, hunt-0911/logs/ROLE-11/18-clean-live.log), thirty
# seconds after the reader had brought that fabric up himself with `ndt up p4 4`, following the
# manual's own instruction to verify it with `ndt clean`. Seventy-four XX lines, closing on
# `this stack did not start it; to kill it too:  ndt down --deep` -- and the first two entries
# of the list that line was summarising were `ndtwin_kernel pid 2511227 holding :8000` and
# `python pid 2510886 holding :8081`, while the same round's `ndt status` pidfiles row read
# `kernel.child.pid=2511227 alive, p4_proxy.child.pid=2510886 alive`.
#
# The manual's fold-out says to use --deep only when the machine is certainly yours. The tool
# had just told him it was not. It was the only line in that round that would have broken
# something if followed.
#
# 🔴 The population is DERIVED -- from .test_run/pids/ and from the switch manifest -- and not
# a hand-written list of ports, because a hand-written list is the shape ports.sh exists to
# replace.
reset_fix; rm -f "$DM"
ledger kernel 2511227
ledger p4_proxy 2510886
OUT="$(drive 'FX_HELD="8000:2511227 8081:2510886"; cmd_clean')"
check "  it is still not clean"                 "1" "$(rc_of_out "$OUT")"
has   "  and the residue is still listed by port and holder" "holding :8000" "$OUT"
hasnt "🔴 a pid in .test_run/pids/ is not 'this stack did not start it'" \
      "to kill it too:  ndt down --deep" "$OUT"
has   "🔴 it says the fabric this stack started is still up" \
      "the fabric this stack started is still up" "$OUT"
has   "  naming the pid it read out of the registry"  "pid 2511227" "$OUT"
has   "  and the verb that takes it down"             "Take it down with:  ndt down" "$OUT"

# 🔴 bmv2's twenty ports are root-owned, so this user cannot see their pids BY CONSTRUCTION
# (ports.sh's own note) and the pidfile test cannot answer for them. The switch manifest this
# stack wrote is the record that can, and it was present in that very log:
# `switch manifest still present: /tmp/ndtwin_p4_switches.json`.
reset_fix; rm -f "$DM"
OUT="$(drive 'FX_HELD="30051: 9091:"; cmd_clean')"
check "  it is not clean"                       "1" "$(rc_of_out "$OUT")"
hasnt "🔴 a bmv2 port under this stack's own manifest is not a stranger either" \
      "to kill it too:  ndt down --deep" "$OUT"
has   "  and it names the record that answered" "the switch manifest this stack wrote" "$OUT"

# 🔴 THE CONTROL, and it is the whole point: a holder that really is NOT this stack's still gets
# the old sentence and the --deep remedy. "Never say it" would be the same defect with the sign
# flipped -- ports.sh's table exists because a stray :8000 makes the next round measure the
# wrong kernel.
reset_fix; rm -f "$DM"
OUT="$(drive 'FX_HELD="8000:999111"; cmd_clean')"
check "  it is not clean"                       "1" "$(rc_of_out "$OUT")"
has   "🔴 a holder that is NOT in the registry still gets the old sentence" \
      "to kill it too:  ndt down --deep" "$OUT"
hasnt "  and is not claimed as this stack's"    "the fabric this stack started is still up" "$OUT"

# ...and the manifest is the RECORD, not the plane: a bmv2 port with no manifest is a stranger.
reset_fix; rm -f "$DM"; rm -f "$FIX/manifest.json"
OUT="$(drive 'FX_HELD="30051:"; cmd_clean')"
has   "🔴 with no manifest, a bmv2 port is a stranger again" \
      "to kill it too:  ndt down --deep" "$OUT"

# Both kinds in one report: two ports, two different sentences, neither swallowing the other.
reset_fix; rm -f "$DM"; ledger kernel 2511227
OUT="$(drive 'FX_HELD="8000:2511227 8080:999111"; cmd_clean')"
has   "  this stack's own port is named as its own" "the fabric this stack started is still up" "$OUT"
has   "  and the stranger still gets --deep"        "to kill it too:  ndt down --deep" "$OUT"
has   "  which names the port it is about"          "held by nothing this stack registered: :8080" "$OUT"

# ==========================================================================================
section "18. ROLE-9: a REFUSED 'ndt up p4 <n>' leaves the P4 host knob exactly as it found it"
# ==========================================================================================
# Measured by ROLE-9 on 2026-09-12, twice and in both directions (cell 4b at 04:14:52 and cell
# 4c at 04:17:57; hunt-0911/logs/ROLE-9/c4b-up.log, c4c-up.log). `ndt up p4 <n>` wrote <n> into
# p4_proxy/mininet/host_count_override BEFORE the H4 topology check, was refused 0.1 s later
# having started nothing at all (`[1/3]` zero times, bmv2 0 -> 0), and never put the file back.
# 4b verbatim, knob 4 on the way in:
#
#     !!  host_count_override: 4 -> 128 (persistent; affects every later run)
#     XX  refusing to build: NDT_TOPO names a model of a different network: 128 host(s) asked
#     XX    the fabric is built from p4_proxy/mininet/host_count_override (128), and the
#
# 🔴 THE THIRD LINE IS THE FINDING. The refusal told the operator the fabric is built from a
# knob reading 128 -- a value this refused command had written 0.1 s earlier. The operator's
# tree said 4. A refusal that quotes a state only the refusal itself created cannot be acted
# on, and on this machine that file is somebody else's uncommitted change: `ndt status` is the
# only thing that noticed, and it only speaks at `ndt release`.
#
# 🔴 BYTES, not the number. host_count_in skips comment lines and leading whitespace, so a
# file can read 4 and not be the four bytes `4\n` -- which makes "write 4 back" a rewrite and
# not a restore. Every cell below compares the file with od, and the first one gives it a
# comment line that only a byte-for-byte restore can keep.
#
# 🔴 THE DIRECTION THAT WOULD BE WORSE: checking the knob's CURRENT value instead of the count
# on the command line. `NDT_TOPO=<4-host model> ndt up p4 128` with the knob at 4 would then
# compare 4 against a 4-host model, agree, and build -- the H4 defect back, reached by way of
# its own fix. The last cell of this section is that control.
KNOBF="$FIX/p4_proxy/mininet/host_count_override"
knob_hex()  { od -An -tx1 -v < "$KNOBF" 2>/dev/null | tr -d ' \n'; }
knob_put()  { printf '%s' "$1" > "$KNOBF"; }

# -- 4b, verbatim: knob 4, `ndt up p4 128`, NDT_TOPO naming a 4-host model.
reset_fix; rm -f "$DM"
knob_put '# Adam: 4 for tonight. NOT committed -- see LAB-RULES hard rule 5.
4
'
KNOB_BEFORE="$(knob_hex)"
OUT="$(NDT_TOPO="$T4" drive 'up_p4 128')"
check "🔴 the H4 refusal is still a refusal"               "5" "$(rc_of_out "$OUT")"
check "🔴 and the knob is byte-for-byte what this run found it" \
      "$KNOB_BEFORE" "$(knob_hex)"
check "  including the comment a value-only restore would have dropped" "2" \
      "$(wc -l < "$KNOBF")"
check "🔴 and nothing was built"                           "" "$(cat "$FIX/sudo.log")"
has   "  the refusal names the value the operator arrived with" \
      "UNCHANGED at 4" "$OUT"
hasnt "🔴 and no write was announced, because none happened" \
      "host_count_override: 4 -> 128" "$OUT"
# The count on the command line is still what was refused: this is not "the knob wins".
has   "  while the size this run asked for is still named" "128 host(s) asked for on the p4 plane" "$OUT"

# -- 4c, the mirror: knob 128, `ndt up p4 4`, NDT_TOPO naming the 128-host model.
reset_fix; rm -f "$DM"
knob_put '128
'
KNOB_BEFORE="$(knob_hex)"
OUT="$(NDT_TOPO="$T128" drive 'up_p4 4')"
check "🔴 the mirror direction is refused as well"         "5" "$(rc_of_out "$OUT")"
check "🔴 and its knob is untouched too"                   "$KNOB_BEFORE" "$(knob_hex)"
has   "  quoting ITS entry value, not the 4 it was asked for" "UNCHANGED at 128" "$OUT"

# -- the other refusal decided from the same reading: no model of that size exists at all.
reset_fix; rm -f "$DM"
knob_put '4
'
KNOB_BEFORE="$(knob_hex)"
OUT="$(drive 'up_p4 12')"
check "  a size no model has is still refused"             "1" "$(rc_of_out "$OUT")"
has   "  by the message that names the deriver"            "no P4 topology model in setting/ has 12 hosts" "$OUT"
check "🔴 and that refusal leaves the knob alone as well"  "$KNOB_BEFORE" "$(knob_hex)"

# -- a claim somebody else holds. This refusal is three checks further down than H4, so it is
# the one that says whether the knob write really moved BELOW all of them and not just below
# the topology test.
reset_fix; rm -f "$DM"
knob_put '4
'
KNOB_BEFORE="$(knob_hex)"
OUT="$(drive 'foreign_claim() { echo "someone-else -- 40m left"; }
up_p4 128')"
check "  a foreign claim still refuses the bring-up"       "5" "$(rc_of_out "$OUT")"
check "🔴 and the knob is still the operator's"            "$KNOB_BEFORE" "$(knob_hex)"

# -- and preflight, which is the last refusal before the machine changes.
reset_fix; rm -f "$DM"
knob_put '4
'
KNOB_BEFORE="$(knob_hex)"
OUT="$(FX_LAB_KERNEL_DIR="$FIX/other-tree" drive 'up_p4 128')"
check "  a lab that acts in another tree still refuses"    "1" "$(rc_of_out "$OUT")"
check "🔴 and that refusal moved nothing either"           "$KNOB_BEFORE" "$(knob_hex)"

# -- 🔴 A BRING-UP THAT DID CHANGE THE MACHINE AND WAS TAKEN BACK DOWN. rollback_up says "the
# machine is back to what it was before this 'ndt up'", and the knob is part of the machine:
# it is the one file `ndt up p4 <n>` writes that outlives the run.
#
# 🔴 The knob here carries a COMMENT, and that is the whole reason this cell is the one with
# an annotated file: this is the only path in the section where the knob is really written and
# really put back, so it is the only place where "write $KNOB_ENTRY back" and "restore the
# bytes" can be told apart. host_count_in reads 4 out of both.
reset_fix; rm -f "$DM"; echo "0 10" > "$FIX/bmv2.seq"
knob_put '# Adam: 4 for tonight, not committed
4
'
KNOB_BEFORE="$(knob_hex)"
rc_for topo-start 1
OUT="$(drive 'up_p4 128')"
check "  a bring-up whose fabric never started is red"     "1" "$(rc_of_out "$OUT")"
has   "  and it rolled back"                               "rollback" "$OUT"
check "🔴 and the rollback put the knob back too"          "$KNOB_BEFORE" "$(knob_hex)"
check "  bytes, so the comment survived the round trip"    "2" "$(wc -l < "$KNOBF")"
has   "  and the put-back is announced, not silent"        "host_count_override put back to 4" "$OUT"

# -- 🔴 THE WRITE STILL HAPPENS. Everything above is satisfied by an `ndt up p4 <n>` that never
# writes the knob at all -- and then the fabric is built at whatever the last round left, which
# is the defect E-9 is about. This is the success path, and the knob has to carry the count.
reset_fix; rm -f "$DM"; echo "0 10" > "$FIX/bmv2.seq"
mk_topo StaticNetworkTopologyP4_10Switches_8Hosts.json 8 56
knob_put '4
'
OUT="$(drive 'up_p4 8')"
check "🔴 a bring-up that was NOT refused is green"        "0" "$(rc_of_out "$OUT")"
check "🔴 and the knob carries the count it was given"     "8" "$(cat "$KNOBF")"
has   "  and the write is still announced as persistent"   "host_count_override: 4 -> 8 (persistent" "$OUT"
has   "  the fabric really was built"                      "topo-start" "$(cat "$FIX/sudo.log")"

# -- ...and a bring-up whose VERIFY failed keeps it: the fabric is up at that size, and a knob
# that no longer described it would send the next `ndt up p4` to a different network. This is
# the one non-zero path that must NOT put the knob back.
reset_fix; rm -f "$DM"; echo "0 10" > "$FIX/bmv2.seq"
knob_put '4
'
OUT="$(drive 'FX_VERIFY_RC=1
up_p4 8')"
check "  a bring-up that came up and failed verify is red" "1" "$(rc_of_out "$OUT")"
check "🔴 and the knob still describes the fabric that IS up" "8" "$(cat "$KNOBF")"
hasnt "  nothing was rolled back"                          "rollback" "$OUT"

# -- 🔴 THE CONTROL for the whole section: the refusal is still decided from the COUNT ON THE
# COMMAND LINE. Knob 4, `ndt up p4 128`, NDT_TOPO naming the 128-host model: the model and the
# request agree, so this must be built -- a fix that compared NDT_TOPO against the knob's
# current value would refuse it and put H4's own defect back the other way round.
reset_fix; rm -f "$DM"; echo "0 10" > "$FIX/bmv2.seq"
knob_put '4
'
OUT="$(NDT_TOPO="$T128" drive 'up_p4 128')"
check "🔴 a model that matches the COUNT ASKED FOR is still built" "0" "$(rc_of_out "$OUT")"
hasnt "  and is not refused as another network"            "a model of a different network" "$OUT"
check "  the knob was written to the size that was built"  "128" "$(cat "$KNOBF")"

# ==========================================================================================
section "19. ROLE-9 / ROLE-11 F6: the claim note carries the verdict 'verify clean' reached"
# ==========================================================================================
# ROLE-9, 2026-09-12 04:16:03, .test_run/lab.claim verbatim after the tenth round's teardown:
#
#     note=down at 2026-09-12 04:16:03 did NOT verify clean; claim kept -- read 'running'
#          below, not this note
#
# and in the same teardown's log, four steps above it, `verify clean`'s five lines were all
# `ok` and the last word was `clean`. The note took `$down_rc`, and on a live P4 fabric that rc
# was 1 for a reading taken in the MIDDLE of the teardown (G-43). ROLE-11 F6 saw the same pair.
#
# 🔴 THE HALF THAT SURVIVED G-43'S FIX. `ndt down`'s rc has three sources and only some of them
# are about residue: a component that ended on a FATAL SIGNAL is reported once out of a .exit
# record and can be LAST ROUND'S ending (00-COMMON, 09-12). That is a true non-zero over a
# machine `verify clean` found spotless -- and the note said "did NOT verify clean" about it.
# The note is a sentence about the MACHINE, so it follows what was verified; the rc is the
# command's, and stays what it was.
#
# 🔴 AND IT IS NOT THE RC RENAMED. Two teardowns with the same rc get different sentences
# (cells 2 and 3 below, both rc 1) and two with different rcs get the same one (cells 1 and 2,
# rc 0 and rc 1). A note copied from the rc cannot do both.
#
# 🔴 THE NOTE OUTLIVES THE ROUND. ROLE-9's own baseline carried the 02:26 version of this
# sentence from the session before it, and the note's own tail -- "read 'running' below, not
# this note" -- is the tool admitting the sentence is not to be trusted. That is why this is
# pinned on the FILE and not on the screen.
NOTE_OWNER=ndt7-owner
IN_USE="in use: ndt up p4 4 at 2026-09-12 04:07:04 by $NOTE_OWNER"
mk_claim_note() {   # <note>
    printf 'owner=%s\nexpires=%s\nnote=%s\nexclusive_cpu=\nmeasuring=\n' \
        "$NOTE_OWNER" "$(( $(date +%s) + 3600 ))" "$1" > "$FIX/.test_run/lab.claim"
}
cnote() { sed -n 's/^note=//p' "$FIX/.test_run/lab.claim" 2>/dev/null | head -1; }

# -- 1. the live-P4 shape G-43 fixed: rc 0, everything verified.
reset_fix; rm -f "$DM"; rc_for stack_down 1; out_for stack_down "$STACK_DOWN_LIVE_P4"
mk_claim_note "$IN_USE"
OUT="$(NDT_OWNER="$NOTE_OWNER" drive 'cmd_down')"
check "  a live-P4 teardown that ended clean is green" "0" "$(rc_of_out "$OUT")"
has   "  and 'verify clean' really ran"                "ports closed" "$OUT"
has   "🔴 the note says the machine was verified clean" "verified clean" "$(cnote)"
hasnt "🔴 and does not say the opposite"               "did NOT verify clean" "$(cnote)"
has   "  the claim is still kept, not released"        "claim kept" "$(cnote)"
hasnt "  and the 'in use' sentence is gone"            "in use" "$(cnote)"

# -- 2. 🔴 THE FINDING. rc 1 from an ending that happened in an EARLIER round, over a machine
# `verify clean` found spotless. This is the pair ROLE-11 F6 read off the screen and the claim.
reset_fix; rm -f "$DM"; rc_for stack_down 1
out_for stack_down "  🔴 kernel did not stop cleanly: killed by SIGKILL"
mk_claim_note "$IN_USE"
OUT="$(NDT_OWNER="$NOTE_OWNER" drive 'cmd_down')"
check "  the teardown is red for that ending"          "1" "$(rc_of_out "$OUT")"
has   "  and says whose ending it is"                  "ENDING FROM AN EARLIER ROUND" "$OUT"
has   "🔴 the note STILL says the machine verified clean" "verified clean" "$(cnote)"
hasnt "🔴 a clean machine is not written down as unverified" "did NOT verify clean" "$(cnote)"
has   "  while the non-zero it did end on is not hidden" "exits 1" "$(cnote)"

# -- 3. residue really found: the other sentence, and which half found it.
reset_fix; rm -f "$DM"
mk_claim_note "$IN_USE"
OUT="$(NDT_OWNER="$NOTE_OWNER" drive 'cmd_clean() { err "bmv2 switches: 10 still running"; return 1; }
cmd_down')"
check "  a teardown that left residue is red"          "1" "$(rc_of_out "$OUT")"
has   "🔴 and its note says it did not verify clean"   "did NOT verify clean" "$(cnote)"
has   "  naming the half that could not verify"        "the residue check" "$(cnote)"
has   "  with the sentence that says not to act on it" "read 'running' below, not this note" "$(cnote)"

# -- 4. the sweep is the other half, and it is NOT the residue check: cleanup sweeps patterns
# cmd_clean does not look at, so a reader told "the residue check" would look in the wrong place.
reset_fix; rm -f "$DM"; rc_for cleanup 1; out_for cleanup "STILL RUNNING bmv2 pid 4242"
mk_claim_note "$IN_USE"
OUT="$(NDT_OWNER="$NOTE_OWNER" drive 'cmd_down')"
check "  a sweep that did not finish is red"           "1" "$(rc_of_out "$OUT")"
has   "🔴 and the note names the sweep"                "the [3/3] sweep" "$(cnote)"
hasnt "  not the half that was green"                  "the residue check" "$(cnote)"

# -- 5. and the deferred ports, re-read after [3/3] and still held: a third half, named.
reset_fix; rm -f "$DM"; rc_for stack_down 1; out_for stack_down "$STACK_DOWN_LIVE_P4"
mk_claim_note "$IN_USE"
OUT="$(NDT_OWNER="$NOTE_OWNER" drive 'FX_HELD="30051: 9091:"
cmd_clean() { ok "ports closed: the fixture asserts nothing survived"; return 0; }
cmd_down')"
check "  ports still held after the sweep are red"     "1" "$(rc_of_out "$OUT")"
has   "🔴 and the note names the port re-reading"      "port(s) still held" "$(cnote)"

# -- 6. the control that keeps the note a description and not a lease: a claim that is not ours
# is still not narrated, and no claim is still not invented.
reset_fix; rm -f "$DM"
printf 'owner=%s\nexpires=%s\nnote=%s\nexclusive_cpu=\nmeasuring=\n' \
    somebody-else "$(( $(date +%s) + 3600 ))" "$IN_USE" > "$FIX/.test_run/lab.claim"
OUT="$(NDT_OWNER="$NOTE_OWNER" drive 'cmd_down')"
check "  a teardown over somebody else's claim is green" "0" "$(rc_of_out "$OUT")"
check "🔴 and their note is untouched"                 "$IN_USE" "$(cnote)"
has   "  while saying out loud that it was not updated" "the claim note was NOT updated" "$OUT"
reset_fix; rm -f "$DM" "$FIX/.test_run/lab.claim"
OUT="$(NDT_OWNER="$NOTE_OWNER" drive 'cmd_down')"
check "  with no claim at all the teardown is green"   "0" "$(rc_of_out "$OUT")"
check "🔴 and no claim file is invented to narrate"    "gone" \
      "$( [[ -f "$FIX/.test_run/lab.claim" ]] && echo present || echo gone )"

# ==========================================================================================
section "20. FIX-NDT-8: a REFUSED 'ndt up' exits 5; a DIRTY READING still exits 1"
# ==========================================================================================
# Adam, 2026-09-12 (form 1 Q1, form 5 Q15b): one vocabulary across up, down and clean.
#   rc 1  something was MEASURED and it was dirty -- alive, held, would not stop
#   rc 3  nothing was measured, because there was nothing to measure
#   rc 5  a guard REFUSED; this command did not act at all
# rc 0 is left for "measured, and clean". The three tables in `ndt help` say the same thing,
# and tests/shell/test_ndt_honesty.sh section 5I reads them.
#
# 🔴 THE DIRECTION THAT MATTERS, and every control below is one of its corners: "make every
# non-zero refusal 5" is not the change. A bring-up that refused because it FOUND something --
# a stray on :8000, a live Mininet, a fabric older than the pipeline -- measured the machine and
# is still rc 1. The distinction is between "I looked and it is dirty" and "I declined to look".
#
# 🔴 The knob is put back to 4 here, and reset_fix deliberately does not do it: section 18
# drives the ROLE-9 rewrites and leaves whatever its last case wrote. Without this line the reuse
# branch below compares a 128-host knob against a 4-host fabric, takes the REBUILD path instead,
# and the cell that is meant to be about stale_pipeline passes for a reason that has nothing to
# do with it -- measured here 2026-09-12 12:2x: rc 0, with no refusal printed at all.
echo 4 > "$FIX/p4_proxy/mininet/host_count_override"
reset_fix
OUT="$(drive 'foreign_claim() { echo "somebody-else (until 03:00)"; }
up_p4')"
check "🔴 a lab claimed by somebody else refuses with rc 5" "5" "$(rc_of_out "$OUT")"
has   "  and the sentence an operator reads is unchanged" "the lab is claimed by somebody-else" "$OUT"
check "  🔴 and nothing was built"                        ""  "$(cat "$FIX/sudo.log")"

reset_fix
OUT="$(drive 'in_flight() { echo "iperf3 -c 10.0.0.33 -t 200"; }
up_p4')"
check "🔴 a measurement in flight refuses with rc 5"      "5" "$(rc_of_out "$OUT")"
has   "  naming what is running"                          "iperf3 -c 10.0.0.33 -t 200" "$OUT"

# H4 on the OVS side. Section 8 pins the P4 one; one plane changed is not both -- up_p4 and
# up_ovs carry two copies of this refusal, and they have drifted before (the stray-newline
# regression in section 11 was in both).
reset_fix
OUT="$(NDT_TOPO="$T128" drive 'up_ovs 4')"
check "🔴 H4 refuses with 5 on the OVS side too"          "5" "$(rc_of_out "$OUT")"
has   "  and still says the size is the verb there"       "the size is the VERB" "$OUT"

# 🔴 The WIRING, and the trap it is about: up_ovs does housekeeping between the refusal and its
# own `return`, and `rm -f "$fifo" "$out"; return $?` returns the rc of `rm`. Both planes, both
# guards, and the control that a preflight which failed for an ordinary reason is NOT promoted.
reset_fix
OUT="$(drive 'preflight() { return 5; }
up_p4')"
check "🔴 up_p4 carries preflight's refusal code out"     "5" "$(rc_of_out "$OUT")"
OUT="$(drive 'preflight() { return 1; }
up_p4')"
check "🔴 and a preflight that failed for any other reason is still 1" "1" "$(rc_of_out "$OUT")"
reset_fix
OUT="$(drive 'preflight() { return 5; }
up_ovs 4')"
check "🔴 up_ovs carries it out too, past its own rm -f"  "5" "$(rc_of_out "$OUT")"
OUT="$(drive 'preflight() { return 1; }
up_ovs 4')"
check "  and 1 stays 1 on that path as well"             "1" "$(rc_of_out "$OUT")"
reset_fix
OUT="$(drive 'record_up_target() { return 5; }
up_p4')"
check "🔴 record_up_target's refusal reaches up_p4's caller" "5" "$(rc_of_out "$OUT")"
reset_fix
OUT="$(drive 'record_up_target() { return 5; }
up_ovs 4')"
check "  and up_ovs's"                                    "5" "$(rc_of_out "$OUT")"

# 🔴 PRECEDENCE, decided here and written into the help: preflight folds several checks into one
# answer, and a teardown in flight can coincide with a port this bring-up would also refuse on.
# The refusal wins, because the actionable sentence is "wait for that teardown" -- and the port
# it would otherwise send the operator hunting is very likely one that teardown is releasing.
reset_fix; rm -f "$DM"
printf 'pid=%s\nat=2026-09-12T11:00:00+0800\nby=fix-ndt-8\n' "$$" > "$DM"
OUT="$(FX_HELD="8000:992261" drive 'preflight p4')"
check "🔴 a refusal and a dirty reading together: the refusal wins" "5" "$(rc_of_out "$OUT")"
has   "  and the dirty reading is still PRINTED, not hidden" "not part of this checkout" "$OUT"
has   "  while the remedy is the teardown, not the port"     "wait for it to finish" "$OUT"
rm -f "$DM"

# 🔴 THE CONTROLS. Each of these is a bring-up that refused because it MEASURED something.
reset_fix
OUT="$(FX_HELD="8000:992261" drive 'preflight ovs')"
check "🔴 a stray holding :8000 is a dirty reading, still 1" "1" "$(rc_of_out "$OUT")"
reset_fix
OUT="$(FX_MN=14 drive 'up_ovs 4')"
check "🔴 a live Mininet is a dirty reading, still 1"      "1" "$(rc_of_out "$OUT")"
has   "  naming the wedge it would trigger"                "wedge trigger" "$OUT"
reset_fix
OUT="$(drive 'stale_pipeline() { return 0; }
FX_BMV2=10 FX_TOPO_SESSION=1 up_p4')"
check "🔴 a fabric older than the pipeline is a dirty reading, still 1" "1" "$(rc_of_out "$OUT")"
has   "  naming what those switches are NOT running"       "are NOT running" "$OUT"
reset_fix
OUT="$(drive 'up_p4 abc')"
check "  a usage error is still 2, not 5"                  "2" "$(rc_of_out "$OUT")"
OUT="$(drive 'up_ovs 16')"
check "  and so is a size the OVS plane cannot build"      "2" "$(rc_of_out "$OUT")"
reset_fix; rm -f "$DM"
OUT="$(drive 'preflight p4')"
check "  🔴 and with nothing wrong at all, preflight is still 0" "0" "$(rc_of_out "$OUT")"

# ==========================================================================================
section "21. FIX-NDT-8: 'ndt clean' answers 3 when there was nothing to judge, 5 when refused"
# ==========================================================================================
# Adam, 2026-09-12 (form 1 Q1): "沒量" 不是 "乾淨". `ndt clean` on a machine where no fabric was
# ever started walked five assertions over an empty process table, found nothing, printed
# `clean` and exited 0 -- byte-identical, to any script, to a teardown that removed ten bmv2
# switches and proved them gone. The manual sends a first-time reader to this command to VERIFY
# a lab; the answer it gave on a machine with no lab at all was the answer it gives on a lab
# that was torn down correctly.
#
# 🔴 The verdict LINE is asserted with grep -x, not with a substring. `clean` occurs inside
# `not clean` and inside every sentence about being clean, and this whole group is about which
# of two words that line is.
reset_fix; rm -f "$DM" "$FIX/manifest.json"
OUT="$(drive 'cmd_clean')"
check "🔴 an empty machine is rc 3, not rc 0"        "3" "$(rc_of_out "$OUT")"
check "🔴 and the verdict line is NOT 'clean'"       "0" "$(grep -cx 'clean' <<<"$OUT")"
check "  it says it judged nothing"                  "1" "$(grep -cx 'nothing to judge' <<<"$OUT")"
has   "  naming the three populations it found empty" "no port in ports.sh" "$OUT"
has   "  and that 3 is not a clean bill"             "is not the same statement" "$OUT"

# 🔴 THE SEAM, and the pair that gives it discriminating power: the SAME empty machine, read
# once as an assertion in its own right and once as the last step of a teardown that had
# something to remove. `ndt down`'s verify clean is about the fabric it just took out -- the
# subject was established before it acted -- so "nothing here" is its RESULT.
reset_fix; rm -f "$DM" "$FIX/manifest.json"
OUT="$(drive 'cmd_clean "the fabric this teardown was asked to remove"')"
check "🔴 with a subject supplied by the caller, the same machine is 0" "0" "$(rc_of_out "$OUT")"
check "  and the verdict line is 'clean'"            "1" "$(grep -cx 'clean' <<<"$OUT")"

# A registry entry is a subject on its own: .test_run/pids/ is what `ndt down` acts on, so a
# machine that has one has something for this command to be about.
# [Co-developed with claude code -- Adam]
# 🔴 A LIVE entry: the pid is this suite's own shell. It was 992261 until 2026-09-25 -- a number
# nothing on this machine holds, i.e. a STALE entry, which Adam's ruling that day (TICKET-ndt-
# ovs-claim section 2 item 3) says is NOT something to judge. The stale half of this cell lives in
# tests/shell/test_ndt_ovs_claim.sh section 10; what this one pins is unchanged.
reset_fix; rm -f "$DM" "$FIX/manifest.json"; ledger kernel "$$"
OUT="$(drive 'cmd_clean')"
check "🔴 a pidfile in the registry is a subject: rc 0" "0" "$(rc_of_out "$OUT")"
check "  and the verdict line is 'clean'"            "1" "$(grep -cx 'clean' <<<"$OUT")"

# 🔴 THE CONTROLS. "Answer 3 when nothing is running" would swallow every stray this command
# exists to find -- the empty registry is exactly the state a stray nobody started leaves.
reset_fix; rm -f "$DM"
OUT="$(FX_BMV2=10 drive 'cmd_clean')"
check "🔴 ten switches still running is 1, not 3"    "1" "$(rc_of_out "$OUT")"
check "  and the verdict line is 'not clean'"        "1" "$(grep -cx 'not clean' <<<"$OUT")"
reset_fix; rm -f "$DM" "$FIX/manifest.json"
OUT="$(FX_HELD="8000:992261" drive 'cmd_clean')"
check "🔴 a stray holding :8000 with an EMPTY registry is 1, not 3" "1" "$(rc_of_out "$OUT")"
has   "  and it is still named as a stranger"        "this stack did not start it" "$OUT"

# The refusal, and its precedence: an empty machine plus somebody else's teardown is 5. A
# command that refused did not measure the machine at all, so it cannot report 3 about it.
reset_fix; rm -f "$DM" "$FIX/manifest.json"
printf 'pid=%s\nat=2026-09-12T12:00:00+0800\nby=fix-ndt-8\n' "$$" > "$DM"
OUT="$(drive 'cmd_clean')"
check "🔴 a refusal outranks 'nothing to judge'"     "5" "$(rc_of_out "$OUT")"
has   "  and says what it is refusing on"            "an 'ndt down' from this checkout is still running" "$OUT"
check "  and judged nothing"                         "0" "$(grep -cx 'nothing to judge' <<<"$OUT")"
rm -f "$DM"

# 🔴 The one this must not break, again: a teardown that HAD something to remove still ends on
# `clean` and still exits 0. reset_fix leaves the manifest in place, which is that subject.
reset_fix; rm -f "$DM"
OUT="$(drive 'cmd_down')"
check "🔴 the teardown's own verify clean still ends on 'clean'" "1" "$(grep -cx 'clean' <<<"$OUT")"
check "  and the teardown is still rc 0"             "0" "$(rc_of_out "$OUT")"

# ==========================================================================================
section "22. FIX-NDT-8: 'ndt down' answers 3 when there was nothing to tear down, 5 when refused"
# ==========================================================================================
# Adam, 2026-09-12 (form 1 Q1). The third table of the same three words. `ndt down` on a lab
# that was already down printed its four steps, verified an empty machine and exited 0 --
# indistinguishable, to the caller, from a teardown that removed a fabric and proved it gone.
# ROLE-12 recorded exactly that pair on 09-12 ("two live OVS teardowns and one already-down
# lab: rc 0") and had no way to tell the third one from the other two except by reading the log.
reset_fix; rm -f "$DM" "$FIX/manifest.json"
OUT="$(drive 'cmd_down')"
check "🔴 tearing down an already-down lab is rc 3, not rc 0" "3" "$(rc_of_out "$OUT")"
check "  and the verdict line says what it measured" "1" \
      "$(grep -cx 'nothing was up to tear down' <<<"$OUT")"
has   "  naming the three populations it found empty" "no registry entry" "$OUT"
# 🔴 The direction this must not go: 3 is a verdict, not a shortcut. Every step still runs --
# they are idempotent, and a teardown that skipped them on an empty reading would be the
# reading deciding whether to act.
SUDO="$(cat "$FIX/sudo.log")"
has   "  🔴 the topo session was still stopped"       "topo-stop" "$SUDO"
has   "  🔴 and the sweep still ran"                  "cleanup" "$SUDO"
has   "  and stack.sh was still asked to go down"     "down" "$(cat "$FIX/stack.log")"

# 🔴 THE NOTE, which outlives the round: a teardown that had nothing to tear down must not
# write "verified clean" into .test_run/lab.claim. That sentence is read by the next session.
reset_fix; rm -f "$DM" "$FIX/manifest.json"
mk_claim_note "$IN_USE"
OUT="$(NDT_OWNER="$NOTE_OWNER" drive 'cmd_down')"
check "🔴 the note does not claim a clean machine was verified" "0" \
      "$(grep -cF 'verified clean' <<<"$(cnote)")"
has   "  it says there was nothing up"                "nothing was up to tear down" "$(cnote)"
has   "  the claim is still kept"                     "claim kept" "$(cnote)"
hasnt "  and the 'in use' sentence is still taken back" "in use" "$(cnote)"

# 🔴 CONTROLS. A teardown that HAD a subject is unchanged in every respect.
reset_fix; rm -f "$DM"
OUT="$(drive 'cmd_down')"
check "🔴 a teardown with something to remove is still rc 0" "0" "$(rc_of_out "$OUT")"
check "  and still ends on 'clean'"                   "1" "$(grep -cx 'clean' <<<"$OUT")"
has   "  🔴 it names what it was about"               "this teardown is about:" "$OUT"
has   "  naming the manifest the sweep is going to remove" "the switch manifest" "$OUT"
# 🔴 And the ordering that makes that work: the manifest is gone by the time anything else
# looks, because `cleanup` removes it. A subject read after the sweep is always empty.
reset_fix; rm -f "$DM"
mk_claim_note "$IN_USE"
OUT="$(NDT_OWNER="$NOTE_OWNER" drive 'cmd_down')"
has   "🔴 a subject the sweep removes still counts as one" "verified clean" "$(cnote)"

# A dirty reading outranks "nothing was measured": an empty lab whose stack.sh half reports
# last round's fatal ending is rc 1, and that 1 is the one A1-b connected.
reset_fix; rm -f "$DM" "$FIX/manifest.json"; rc_for stack_down 1
OUT="$(drive 'cmd_down')"
check "🔴 an empty lab with a non-zero stack.sh half is 1, not 3" "1" "$(rc_of_out "$OUT")"
check "  and the verdict line is not the empty one"   "0" \
      "$(grep -cx 'nothing was up to tear down' <<<"$OUT")"

# The three refusals, all 5 now. Each is decided before the machine is touched, which is why
# each one also has to leave the sweep unrun.
reset_fix; rm -f "$DM"
OUT="$(drive 'foreign_claim() { echo "somebody-else (until 03:00)"; }
cmd_down')"
check "🔴 a foreign claim refuses the teardown with 5" "5" "$(rc_of_out "$OUT")"
has   "  and --force is still the way past it"        "ndt down --force" "$OUT"
check "  🔴 and nothing was swept"                    "absent" \
      "$(grep -qF cleanup "$FIX/sudo.log" && echo present || echo absent)"
reset_fix; rm -f "$DM"
OUT="$(drive 'measuring_declared() { echo "ROLE-4 reader nsr, do not tear down"; }
cmd_down')"
check "🔴 a DECLARED measurement refuses with 5"      "5" "$(rc_of_out "$OUT")"
has   "  quoting the declaration it is protecting"    "ROLE-4 reader nsr" "$OUT"
reset_fix; rm -f "$DM"
OUT="$(drive 'in_flight() { echo "iperf3 -c 10.0.0.33 -t 200"; }
cmd_down')"
check "🔴 a measurement in flight refuses with 5"     "5" "$(rc_of_out "$OUT")"
has   "  naming what is running"                      "iperf3 -c 10.0.0.33 -t 200" "$OUT"

# 🔴 The overrides and the usage code are untouched: --force is the one way past all three, and
# a wrong flag is still a wrong flag.
reset_fix; rm -f "$DM"
OUT="$(drive 'foreign_claim() { echo "somebody-else"; }
cmd_down --force')"
check "  --force still tears down over a foreign claim" "0" "$(rc_of_out "$OUT")"
OUT="$(drive 'cmd_down --nope')"
check "  an unknown option is still 2, not 5"        "2" "$(rc_of_out "$OUT")"

# ==========================================================================================
section "23. FIX-NDT-8 / Adam Q3: [3/3] says it ran the Mininet sweep for you"
# ==========================================================================================
# FIX-NDT-5 stopped `ndt down` repeating stack.sh's advice to run the Mininet sweep by hand --
# inside a teardown that advice is wrong, because [3/3] has already done it. What was left is a
# teardown that runs the sweep and never says so: an operator following the manual, which does
# carry that hand-typed command, has no way to tell that it is redundant here. Adam, 2026-09-12
# (form 1 Q3): the step says it itself.
reset_fix; rm -f "$DM"
OUT="$(drive 'cmd_down')"
has   "🔴 [3/3] says it ran the Mininet sweep"    "this step ran the Mininet sweep (mn -c) for you" "$OUT"
has   "  naming the verb that does it"            "'ndtwin-lab cleanup'" "$OUT"
has   "  and why the [1/3] advice is filtered"    "already acted on" "$OUT"

# 🔴 THE CONTROL, and it is the whole reason this is delicate: the sentence stack.sh prints at
# [1/3] is still suppressed. Saying "I did the sweep" is not a licence to let the advice that
# tells the operator to do it by hand back into the same output.
reset_fix; rm -f "$DM"
out_for stack_down "Mininet was started manually (not by this script); run: sudo mn -c"
OUT="$(drive 'cmd_down')"
hasnt "🔴 stack.sh's hand-typed advice is still filtered out" "Mininet was started manually" "$OUT"
has   "  while [3/3] still says what it did"      "this step ran the Mininet sweep" "$OUT"

# It is said whatever the sweep's own exit status was: "I ran it" and "it finished" are two
# statements, and the second one already has its own line and its own rc.
reset_fix; rm -f "$DM"; rc_for cleanup 1
OUT="$(drive 'cmd_down')"
has   "  it is said even when the sweep did not finish" "this step ran the Mininet sweep" "$OUT"
check "  which is still a failed teardown"        "1" "$(rc_of_out "$OUT")"
has   "  and the failure still has its own line"  "the sweep did not finish" "$OUT"

# ==========================================================================================
section "24. FIX-NDT-8 / Adam 11:23: the OVS bring-up prints the way IN, like the P4 one"
# ==========================================================================================
# `ndt up p4` ended on `proxy :8081  kernel :8000  Mininet CLI: sudo tmux -L ndtwinlab attach -t
# topo`; `ndt up ovs` ended on nothing of the kind, so an operator who had just built a 128-host
# OVS fabric was not told how to get into it -- on the plane that IS the default. Adam asked for
# it at 11:23 on 2026-09-12.
#
# 🔴 One function for both planes, and that is the point: two copies of a command an operator
# pastes drift, and this file already has the evidence (up_p4 and up_ovs carry two copies of the
# H4 unpacking, and section 11 exists because one of them was wrong).
reset_fix
OUT="$(drive 'lab_entry_points ovs')"
has   "🔴 the OVS line carries the Mininet CLI command" \
      "Mininet CLI: sudo tmux -L ndtwinlab attach -t topo" "$OUT"
has   "  with the kernel's port"                       "kernel :8000" "$OUT"
has   "  and Ryu's, which is the OVS plane's control plane" "Ryu :8080" "$OUT"
hasnt "  🔴 and NOT a proxy, which the OVS plane does not have" ":8081" "$OUT"
OUT="$(drive 'lab_entry_points p4')"
has   "  the P4 line is unchanged, whole"              \
      "proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo" "$OUT"

# 🔴 THE CROSS-FILE CELL, and the one with real discriminating power: the command printed here
# is the command ndtwin-lab itself hands out at each of its three launch verbs. A session name
# or socket typed twice is a paste that stops working the day one of them moves.
# 🔴 The REPO's helper, not the one beside the ndt under test: the mutation gate points
# NDT_UNDER_TEST at a copy carrying only ports.sh / sudo_surface.sh / components.env, so
# `dirname "$NDT"` there has no ndtwin-lab at all and this cell went red for every mutant --
# measured 2026-09-12 13:1x, `mutate_ndt_up_down_robust` refused with `baseline is RED`.
LABFILE="$HERE/../../tools/test_workflow/ndtwin-lab"
ATTACH="$(drive 'lab_attach_cmd' | head -1)"
check "🔴 that command is what ndtwin-lab itself prints, at all three launch verbs" "3" \
      "$(grep -cF "(attach: $ATTACH)" "$LABFILE")"

# The wiring: both planes call it, and only from the branch that says the lab is ready.
check "  up_ovs calls it"                              "1" "$(grep -c 'lab_entry_points ovs' "$NDT")"
check "  and up_p4 calls it"                           "1" "$(grep -c 'lab_entry_points p4' "$NDT")"
check "  🔴 and each call sits under 'up. ready'"      "2" \
      "$(grep -A1 'say "up\. \${G}ready\${N}"' "$NDT" | grep -c lab_entry_points)"

# ==========================================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
