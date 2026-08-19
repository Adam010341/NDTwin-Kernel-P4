#!/usr/bin/env bash
#
# faults.sh -- L5: inject one named fault, prove what it did, and put everything back.
#
# [Co-developed with claude code -- Adam]
#
# Why this exists. The 2026-08-12 static + live review found the same shape three times:
# a real bug was fixed and no fault TYPE was left behind to catch the next one of its kind
# (unidirectional link loss, mastership collision, killing the controller). Fault types
# live in faults.txt, one per line, in the same "field | field | reason" shape the rest of
# this repo's catalogues use -- so adding a fault type is adding a line, not editing code.
#
# The three rules every round obeys, each bought with a real incident:
#
#  1. qdisc before and after, and the diff must be empty. `tc qdisc add dev X root netem`
#     does not stack a layer, it silently REPLACES TCLink's htb; `del root` then restores
#     the kernel default, not htb. The customary "netem residue = 0" check cannot see that,
#     and the NOPASSWD grants cannot put htb back. So the round is void unless
#     qdisc_snapshot.sh says the tree came back identical -- an injection tool that
#     corrupts the experiment silently is worse than no injection tool.
#     (doc/2026-07-29_environment_gotchas.md, 2026-08-13 OVS round.)
#
#  2. The verdict comes from tools/twin_audit/criteria.py -- the same three-channel quorum
#     the twin lie detector uses, not a second opinion written here. One source of truth
#     for "are packets moving", used by the tool that accuses the twin and by the tool that
#     breaks the network.
#
#  3. Revert always runs, including when the mid-round check fails or the operator
#     interrupts. A fault left in place poisons every later round on that machine.
#
# Usage:
#   faults.sh list
#   faults.sh run L-2 --pair 10.0.0.1,10.0.0.2 --iface s1-eth1
#   faults.sh run L-3 --pair 10.0.0.1,10.0.0.2 --iface s1-eth1 --peer-iface s5-eth1
#   faults.sh run N-4 --pair 10.0.0.1,10.0.0.2 --pid 12345
#   faults.sh run-all --pair 10.0.0.1,10.0.0.2 --iface s1-eth1 --peer-iface s5-eth1 --pid N
#
# Exit: 0 all rounds behaved as the catalogue says, 1 a round failed or was voided,
#       2 usage error (same meaning as qdisc_snapshot.sh and stack.sh).
#
# Seams. Every function that touches the world is overridable, and the binaries behind them
# are environment variables, so the tests drive the real round logic with nothing running:
#
#   FAULTS_TC          tc command                (default: sudo -n tc)
#                      READ THIS BEFORE THE FIRST LIVE ROUND. Measured with `sudo -n -l` on
#                      2026-08-13, the NOPASSWD grant for tc was only:
#                        tc qdisc add dev s*-eth* root netem * | del dev s*-eth* root | show
#                      i.e. sudo permitted ONLY the `root netem` form -- the one that silently
#                      replaces TCLink's htb -- and NOT the safe `parent H:D` form this
#                      script computes, so on a shaped interface plain `sudo -n tc` could not
#                      do the right thing at all and this script refused rather than fall back
#                      to the destructive form.
#                      *** RESOLVED 2026-08-15: Adam added the two parent rules, and
#                      `sudo -n -l` on 2026-08-17 confirms all four grants are live:
#                        tc qdisc add dev s*-eth* root netem * | del dev s*-eth* root | show
#                        tc qdisc add dev s*-eth* parent * netem * | del dev s*-eth* parent *
#                      The default FAULTS_TC is therefore correct on this machine now, and the
#                      safe form is the one that gets used on a shaped interface. Keep the
#                      escape below for any machine whose sudoers is still the 08-13 shape:
#                        FAULTS_TC="sudo -n mnexec -a $(pgrep -f '[t]estbed_topo.py'|head -1) tc"
#                      (mnexec runs as root, so tc under it needs no tc-specific grant --
#                      the same escape doc/2026-07-29_environment_gotchas.md uses for ovs-ofctl.)
#   FAULTS_KILL        signal command            (default: sudo -n kill)
#                      Same trap as FAULTS_TC, found on this script's first live round
#                      (2026-08-16): this machine's sudoers has no NOPASSWD for bare
#                      `kill`, so the default answers "a password is required" and the
#                      injection silently degrades to "not-injected". Use the same escape:
#                        FAULTS_KILL="sudo -n mnexec -a 1 kill"
#   FAULTS_CRITERIA    verdict command           (default: python3 <root>/tools/twin_audit/criteria.py)
#                      criteria.py reads PATHS_URL from the environment (default is Ryu's
#                      :8080). On a P4 stack export PATHS_URL=http://localhost:8081 or the
#                      paths channel reports unknown all round and the quorum quietly runs
#                      on two channels -- also learned on the first live round.
#   FAULTS_QDISC       qdisc snapshot tool       (default: <here>/qdisc_snapshot.sh)
#   FAULTS_CATALOGUE   catalogue file            (default: <here>/faults.txt)
#   FAULTS_SETTLE_S    seconds to wait after injecting and after reverting (default: 5)
#
# Overridable functions: run_tc, run_signal, settle, check_pair, qdisc_save, qdisc_diff,
# show_qdisc. Source this file and replace any of them (see tests/shell/test_faults.sh).
#
# Sourcing defines the functions without running anything -- that is the tests' seam.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

FAULTS_TC="${FAULTS_TC:-sudo -n tc}"
FAULTS_KILL="${FAULTS_KILL:-sudo -n kill}"
FAULTS_CRITERIA="${FAULTS_CRITERIA:-python3 $ROOT/tools/twin_audit/criteria.py}"
FAULTS_TWIN_AUDIT="${FAULTS_TWIN_AUDIT:-python3 $ROOT/tools/twin_audit/twin_audit.py}"
FAULTS_QDISC="${FAULTS_QDISC:-$HERE/qdisc_snapshot.sh}"
FAULTS_CATALOGUE="${FAULTS_CATALOGUE:-$HERE/faults.txt}"
# 75, not 5. The catalogue's own L-2 entry records the recovery times measured over 23 live runs
# on 2026-08-17 (9467ea0): P4/4-host 13.7 s, OVS/4-host 15.7 s, OVS/128-host 50.1 s (max observed
# 53.7 s). Every one of those exceeds a 5 s settle, so the shipped default could not pass on any
# topology on this machine -- and its failure message says a 'still' reading is a regression, which
# sent the reader looking for a bug in the data plane instead of at this line. Confirmed on both
# fabrics 2026-08-18: L-2 at the 5 s default FAILED (OVS during=still, P4 during=disputed) and
# PASSED unchanged at a longer settle, same fault, same interface, qdisc verified identical.
# The value has to clear the slowest documented recovery, which is the 128-host OVS cell.
# Override downward for small topologies where the wait dominates the round.
# [Co-developed with claude code -- Adam]
FAULTS_SETTLE_S="${FAULTS_SETTLE_S:-75}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; D=''; N=''
fi

say()  { echo "$*"; }
warn() { echo "${Y}$*${N}"; }
err()  { echo "${R}$*${N}" >&2; }

# --- the world ---------------------------------------------------------------------
# The only functions that touch anything outside this script. Tests replace them.

run_tc()     { ${FAULTS_TC} "$@"; }
run_signal() { ${FAULTS_KILL} "-$1" "$2"; }
show_qdisc() { ${FAULTS_TC} qdisc show dev "$1" 2>/dev/null; }
settle()     { sleep "$1"; }
qdisc_save() { "$FAULTS_QDISC" save "$1"; }
qdisc_diff() { "$FAULTS_QDISC" diff "$1"; }

# resolve_pid <ip> -- the Mininet host PID that owns an IP, empty if unknown.
#
# [Co-developed with claude code -- Adam]
# Without this every probe ran in the root namespace: ping could not reach 10.0.0.2 at all
# and the counter read the host's own NIC (rx in the millions, growing from unrelated
# background traffic). The round then read "ping still, counters moving" and refused to
# inject on the grounds that the baseline was broken -- a self-inflicted refusal that looked
# exactly like a real finding. Found on the harness's first live run, 2026-08-13.
# twin_audit owns the IP -> host -> PID map; this asks it rather than re-deriving it.
resolve_pid() {
    ${FAULTS_TWIN_AUDIT} hosts 2>/dev/null \
        | awk -v ip="$1" '$1 == ip { sub(/^pid=/, "", $3); print $3; exit }'
}

# check_pair -- ask criteria.py whether packets move between PAIR_SRC and PAIR_DST.
# Echoes one of: moving still inconclusive disputed error. Never fails the caller;
# the verdict is the return value, in text, because the round logic branches on it.
check_pair() {
    local out rc src_pid dst_pid
    src_pid="$(resolve_pid "$PAIR_SRC")"
    dst_pid="$(resolve_pid "$PAIR_DST")"
    if [[ -z "$src_pid" || -z "$dst_pid" ]]; then
        err "cannot resolve host PIDs for $PAIR_SRC / $PAIR_DST -- is Mininet running?"
        err "  every probe would run in the root namespace and measure the wrong machine."
        echo error
        return
    fi
    out="$(${FAULTS_CRITERIA} check --src-ip "$PAIR_SRC" --dst-ip "$PAIR_DST" \
           --src-pid "$src_pid" --dst-pid "$dst_pid" 2>&1)"
    rc=$?
    echo "$out" >&2
    case "$rc" in
        0) echo moving ;;
        1) echo still ;;
        3) echo inconclusive ;;
        4) echo disputed ;;
        *) echo error ;;
    esac
}

# --- the catalogue -------------------------------------------------------------------
# Data, not code: faults.txt is parsed here and nowhere else.

# catalogue_ids -- every ID in file order.
catalogue_ids() {
    grep -vE '^[[:space:]]*(#|$)' "$FAULTS_CATALOGUE" 2>/dev/null \
        | awk -F' \\| ' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "") print $1}'
}

# catalogue_field <ID> <2|3> -- the spec or the reason for one entry.
catalogue_field() {
    local want="$1" field="$2"
    grep -vE '^[[:space:]]*(#|$)' "$FAULTS_CATALOGUE" 2>/dev/null \
        | awk -F' \\| ' -v want="$want" -v f="$field" '
            { gsub(/^[ \t]+|[ \t]+$/, "", $1)
              if ($1 == want) { gsub(/^[ \t]+|[ \t]+$/, "", $f); print $f; exit } }'
}

# spec_action <spec> -- the mechanism, i.e. the first word.
spec_action() { awk '{print $1}' <<<"$1"; }

# spec_value <spec> <key> [default] -- one key=value parameter.
spec_value() {
    local spec="$1" key="$2" default="${3:-}" value
    value="$(tr ' ' '\n' <<<"$spec" | grep -E "^${key}=" | head -1 | cut -d= -f2-)"
    [[ -n "$value" ]] && echo "$value" || echo "$default"
}

cmd_list() {
    local id
    for id in $(catalogue_ids); do
        printf '%-6s %s\n' "$id" "$(catalogue_field "$id" 2)"
        printf '       %s%s%s\n' "$D" "$(catalogue_field "$id" 3)" "$N"
    done
}

# --- where netem may be attached -----------------------------------------------------

# netem_attach_point <dev> -- echo the tc argument that adds netem WITHOUT destroying the
# interface's shaping, or "unsafe" if it cannot be determined.
#
# The whole reason this function exists: on a TCLink interface the root qdisc is htb and
# `tc qdisc add dev X root netem` REPLACES it -- bandwidth shaping silently gone, and
# `del root` restores the kernel default rather than htb. So the attach point is read from
# the live tree every time rather than assumed: under htb, netem hangs off the default
# class (`parent <handle>:<default>`); on an unshaped interface `root` is correct and is
# why the P4 runbook's root-netem recipe is valid there.
netem_attach_point() {
    local dev="$1" tree line kind handle default
    tree="$(show_qdisc "$dev")"
    [[ -z "$tree" ]] && { echo unsafe; return 1; }

    if grep -qE '^qdisc netem ' <<<"$tree"; then
        # Residue from an earlier round: stacking onto it would make the revert ambiguous.
        echo unsafe
        return 1
    fi

    line="$(grep -E ' root ' <<<"$tree" | head -1)"
    [[ -z "$line" ]] && { echo unsafe; return 1; }
    kind="$(awk '{print $2}' <<<"$line")"
    handle="$(awk '{print $3}' <<<"$line")"

    if [[ "$kind" == "htb" ]]; then
        default="$(grep -oE 'default [0-9a-fx]+' <<<"$line" | head -1 | awk '{print $2}')"
        [[ -z "$default" ]] && { echo unsafe; return 1; }
        echo "parent ${handle}${default}"
        return 0
    fi
    echo root
}

# --- mechanism: link_loss ------------------------------------------------------------

inject_link_loss() {
    local spec="$1" loss direction dev where
    loss="$(spec_value "$spec" loss)"
    direction="$(spec_value "$spec" direction one)"
    [[ -n "$loss" ]] || { err "catalogue entry has no loss="; return 2; }
    [[ -n "$OPT_IFACE" ]] || { err "link_loss needs --iface"; return 2; }
    if [[ "$direction" == "both" && -z "$OPT_PEER_IFACE" ]]; then
        err "direction=both needs --peer-iface as well as --iface"
        return 2
    fi

    INJECTED_IFACES=()
    local targets=("$OPT_IFACE")
    [[ "$direction" == "both" ]] && targets+=("$OPT_PEER_IFACE")

    for dev in "${targets[@]}"; do
        where="$(netem_attach_point "$dev")"
        if [[ "$where" == "unsafe" ]]; then
            err "refusing to touch $dev: cannot find a safe netem attach point."
            err "Either the qdisc tree is unreadable, or netem is already present from an"
            err "earlier round. Attaching at root here would replace TCLink's htb and the"
            err "shaping cannot be restored (doc/2026-07-29_environment_gotchas.md)."
            return 1
        fi
        # shellcheck disable=SC2086 -- $where is deliberately two words ("parent 5:1").
        if ! run_tc qdisc add dev "$dev" $where netem loss "$loss"; then
            err "tc failed on $dev (attach point: $where)"
            if [[ "$where" != "root" ]]; then
                # Measured 2026-08-13: the NOPASSWD grant for tc is
                #   /usr/sbin/tc qdisc {add dev s*-eth* root netem *, del dev s*-eth* root, show ...}
                # i.e. sudo permits ONLY the `root netem` form -- the one that silently
                # replaces TCLink's htb -- and NOT the safe `parent H:D` form this script
                # computes. So on a shaped interface plain `sudo -n tc` cannot do the right
                # thing at all. mnexec runs as uid 0, so tc under it needs no tc-specific
                # grant; that is the same escape doc/2026-07-29_environment_gotchas.md uses for
                # ovs-ofctl, which is not in sudoers either.
                err "The NOPASSWD grant for tc covers only the 'root netem' form, which is"
                err "exactly the form that destroys TCLink's htb. Run tc as uid 0 instead:"
                err "  FAULTS_TC=\"sudo -n mnexec -a \$(pgrep -f '[t]estbed_topo.py' | head -1) tc\""
            fi
            return 1
        fi
        INJECTED_IFACES+=("$dev")
        say "  injected ${loss} loss on ${dev} (${where})"
    done
    return 0
}

revert_link_loss() {
    local dev rc=0 where
    for dev in "${INJECTED_IFACES[@]:-}"; do
        [[ -z "$dev" ]] && continue
        # Delete exactly what was added. `del dev X root` would take out htb along with the
        # netem on a shaped interface, which is the damage this whole file exists to avoid.
        where="$(netem_delete_point "$dev")"
        if [[ "$where" == "unsafe" ]]; then
            err "cannot locate the netem to remove on $dev -- leaving it alone; the round"
            err "is void and the qdisc diff will say so."
            rc=1
            continue
        fi
        if [[ "$where" == "root" ]]; then
            # [Co-developed with claude code -- Adam]
            # No trailing `netem` here. The NOPASSWD grant is the exact argument list
            # `qdisc del dev s*-eth* root`, and sudo matches it literally -- one extra token
            # and the revert dies with "a password is required", leaving the fault in place
            # and voiding the round on the qdisc diff. Measured 2026-08-13, on the harness's
            # first live run: the injection was permitted, the revert was not.
            run_tc qdisc del dev "$dev" root || rc=1
        else
            # shellcheck disable=SC2086
            run_tc qdisc del dev "$dev" $where netem || rc=1
        fi
    done
    INJECTED_IFACES=()
    return $rc
}

# netem_delete_point <dev> -- echo the tc argument identifying the netem we added.
netem_delete_point() {
    local dev="$1" tree line parent
    tree="$(show_qdisc "$dev")"
    line="$(grep -E '^qdisc netem ' <<<"$tree" | head -1)"
    [[ -z "$line" ]] && { echo unsafe; return 1; }
    if grep -qE ' root ' <<<"$line"; then
        echo root
        return 0
    fi
    parent="$(grep -oE 'parent [0-9a-fx]+:[0-9a-fx]*' <<<"$line" | head -1 | awk '{print $2}')"
    [[ -z "$parent" ]] && { echo unsafe; return 1; }
    echo "parent $parent"
}

# --- mechanism: proc_signal ----------------------------------------------------------

inject_proc_signal() {
    local spec="$1" signal
    signal="$(spec_value "$spec" signal)"
    [[ -n "$signal" ]] || { err "catalogue entry has no signal="; return 2; }
    [[ -n "$OPT_PID" ]] || { err "proc_signal needs --pid"; return 2; }
    # A PID, never a pattern. Mininet nodes share a PID namespace, so `pkill -f
    # simple_switch_grpc` takes out all ten switches -- a documented past bug here
    # (doc/2026-07-27_p4_bmv2_support_plan.md item 6). pkill is a forbidden word on this path.
    if ! run_signal "$signal" "$OPT_PID"; then
        err "could not send SIG${signal} to $OPT_PID"
        return 1
    fi
    SIGNALLED_PID="$OPT_PID"
    say "  sent SIG${signal} to pid ${OPT_PID}"
    return 0
}

revert_proc_signal() {
    local spec="$1" restore
    restore="$(spec_value "$spec" restore)"
    [[ -z "${SIGNALLED_PID:-}" ]] && return 0
    if [[ -z "$restore" || "$restore" == "none" ]]; then
        warn "  catalogue says this fault has no restore signal; the process stays as it is"
        SIGNALLED_PID=""
        return 0
    fi
    run_signal "$restore" "$SIGNALLED_PID"
    local rc=$?
    say "  sent SIG${restore} to pid ${SIGNALLED_PID}"
    SIGNALLED_PID=""
    return $rc
}

# --- one round -----------------------------------------------------------------------

# verdict_ok <expected> <actual>
verdict_ok() {
    [[ "$1" == "any" ]] && return 0
    [[ "$1" == "$2" ]]
}

run_round() {
    local id="$1"
    local spec action expect snapshot
    spec="$(catalogue_field "$id" 2)"
    if [[ -z "$spec" ]]; then
        err "no such fault id in $FAULTS_CATALOGUE: $id"
        return 2
    fi
    action="$(spec_action "$spec")"
    expect="$(spec_value "$spec" expect any)"

    case "$action" in
        link_loss|proc_signal) ;;
        *) err "unknown mechanism '$action' for $id -- a new mechanism needs code, not just"
           err "a catalogue line."; return 2 ;;
    esac

    say "=== $id ($spec) ==="

    snapshot="$(mktemp)"
    if ! qdisc_save "$snapshot"; then
        err "could not snapshot the qdisc tree; refusing to inject anything"
        rm -f "$snapshot"
        return 1
    fi

    local before during after rc=0
    before="$(check_pair)"
    if [[ "$before" != "moving" ]]; then
        err "baseline is '$before', not 'moving' -- nothing was injected."
        err "A fault round on a network that is already broken proves nothing."
        rm -f "$snapshot"
        return 1
    fi
    say "  before: $before"

    # From here on the revert must happen no matter what.
    INJECTED_IFACES=()
    SIGNALLED_PID=""
    if "inject_$action" "$spec"; then
        settle "$FAULTS_SETTLE_S"
        during="$(check_pair)"
        say "  during: $during (catalogue expects $expect)"
        verdict_ok "$expect" "$during" || rc=1
    else
        err "injection failed"
        during="not-injected"
        rc=1
    fi

    "revert_$action" "$spec" || rc=1
    settle "$FAULTS_SETTLE_S"
    after="$(check_pair)"
    say "  after:  $after"
    if [[ "$after" != "moving" ]]; then
        err "the network did not come back (after=$after) -- the fault or its revert left"
        err "damage behind."
        rc=1
    fi

    # The qdisc discipline is checked last and overrides everything: a round that changed
    # the shaping tree measured something other than the fault it thought it injected.
    if ! qdisc_diff "$snapshot"; then
        err "ROUND VOID: the qdisc tree did not come back identical. Whatever this round"
        err "measured, it also changed the experiment. Discard the result."
        rc=1
    fi
    rm -f "$snapshot"

    if [[ $rc -eq 0 ]]; then
        say "${G}PASS${N} $id: before=$before during=$during after=$after, qdisc clean"
    else
        err "FAIL $id: before=$before during=$during after=$after"
    fi
    return $rc
}

# --- driver ---------------------------------------------------------------------------

OPT_IFACE=""
OPT_PEER_IFACE=""
OPT_PID=""
PAIR_SRC=""
PAIR_DST=""

parse_opts() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pair)
                PAIR_SRC="${2%%,*}"; PAIR_DST="${2##*,}"
                if [[ -z "$PAIR_SRC" || -z "$PAIR_DST" || "$PAIR_SRC" == "$2" ]]; then
                    err "--pair wants SRC_IP,DST_IP"; return 2
                fi
                shift 2 ;;
            --iface)      OPT_IFACE="$2"; shift 2 ;;
            --peer-iface) OPT_PEER_IFACE="$2"; shift 2 ;;
            --pid)        OPT_PID="$2"; shift 2 ;;
            *) err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ -n "$PAIR_SRC" && -n "$PAIR_DST" ]] || { err "--pair SRC_IP,DST_IP is required"; return 2; }
    return 0
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        list)
            cmd_list ;;
        run)
            local id="${1:-}"
            [[ -n "$id" ]] || { err "usage: $0 run <ID> --pair SRC,DST [...]"; return 2; }
            shift
            parse_opts "$@" || return 2
            run_round "$id" ;;
        run-all)
            parse_opts "$@" || return 2
            local id failed=0
            for id in $(catalogue_ids); do
                run_round "$id" || failed=1
                echo
            done
            return $failed ;;
        *)
            err "usage: $0 {list|run <ID>|run-all} [--pair SRC,DST] [--iface DEV]"
            err "          [--peer-iface DEV] [--pid PID]"
            return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

main "$@"
