#!/usr/bin/env bash
#
# The three topology launches of ndtwin-lab (topo-start, ovs-topo-start, ovs-topo-4host) start their
# interpreter with PYTHONDONTWRITEBYTECODE=1.
#
# [Co-developed with claude code -- Adam]
#
# The defect (seen live 2026-11-05): the helper starts the P4 bridge as root, the bridge imports
# this checkout's modules and NTG's from trees owned by the user, and Python wrote root-owned
# __pycache__/*.pyc into them -- after which the user's `rm -rf` of the NTG checkout failed.
#
# The variable has to be on the launch command itself. sudo resets the caller's environment and
# root's tmux server keeps whatever environment it started with, so neither would carry it.
#
# 🔑 EXERCISED, NOT GREPPED. As in test_ndtwin_lab_ntg_dir.sh, the launch functions are called
#    with $TMUX replaced by a recorder, and the recorded command is then RUN under `env -i` with
#    a probe standing in for the interpreter, so what is asserted is the variable the interpreter
#    would find in its environment -- from an environment that carries nothing, which is the
#    pane's. The three verbs' own `case` branches are executed the same way (existence is not
#    wiring). The last section is a cheap net for a FOURTH launch, and says so: it reads the
#    file's text and is not the evidence for the three above.
#
# CONTROLS: this process unsets PYTHONDONTWRITEBYTECODE (and the checks run the command under
# `env -i` regardless), and a probe run with nothing set must say so -- a probe that printed "1"
# whatever it was given would pass every mutant.
#
# Run:  bash tests/shell/test_ndtwin_lab_no_bytecode.sh
#       NDTWIN_LAB_UNDER_TEST=<copy> bash tests/shell/test_ndtwin_lab_no_bytecode.sh   (gate)
set -uo pipefail
unset PYTHONDONTWRITEBYTECODE PYTHONPYCACHEPREFIX

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LAB="${NDTWIN_LAB_UNDER_TEST:-$REPO/tools/test_workflow/ndtwin-lab}"
[[ -r "$LAB" ]] || { echo "no ndtwin-lab at $LAB"; echo "Ran 1 checks, 1 failed"; exit 2; }

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
summary() { printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"; }

TMPROOT="$(mktemp -d /tmp/ndt-nobytecode-XXXXXX)"
cleanup_all() { [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-nobytecode-* ]] && rm -rf "$TMPROOT"; return 0; }
trap cleanup_all EXIT INT TERM

# Sourced, not executed: the helper returns before its root guard and its dispatch.
# shellcheck source=/dev/null
source "$LAB" || { echo "  FAILED   could not source $LAB"; summary; exit 1; }
set +e
unset PYTHONDONTWRITEBYTECODE PYTHONPYCACHEPREFIX

# --- fixtures: a kernel tree the helper accepts, an NTG checkout, the recorder, the probe ----
FAKENTG="$TMPROOT/ntg checkout"; mkdir -p "$FAKENTG"; : > "$FAKENTG/network_traffic_generator.py"
ALT="$TMPROOT/alt-tree"; mkdir -p "$ALT/p4_proxy/mininet" "$ALT/tools/test_workflow"
: > "$ALT/p4_proxy/mininet/ntg_bmv2_topo.py"; : > "$ALT/testbed_topo.py"
: > "$ALT/tools/test_workflow/ovs_4host_topo.py"

REC="$TMPROOT/rec-tmux"
REC_LOG="$TMPROOT/tmux.argv"
cat > "$REC" <<'REC_EOF'
#!/bin/bash
printf '%s\0' "$@" >> "$REC_LOG"
printf '\036' >> "$REC_LOG"
REC_EOF
chmod 755 "$REC"
export REC_LOG
rec_reset() { : > "$REC_LOG"; }
rec_calls() { tr -cd '\036' < "$REC_LOG" | wc -c; }
rec_argv()  { tr '\0' '\n' < "$REC_LOG" | tr -d '\036'; }
# rec_command -- the command tmux would run: every argv element after `-c <dir>`.
rec_command() { rec_argv | grep -v '^$' | awk 'seen {print} prev == "-c" {seen=1} {prev=$0}'; }
TMUX="$REC"

# The probe takes the interpreter's place: prints the variable it finds, and the first argument.
PROBE="$TMPROOT/probe-python"
printf '#!/bin/bash\nprintf "%%s" "${PYTHONDONTWRITEBYTECODE-<unset>}"\n' > "$PROBE"; chmod 755 "$PROBE"

KERNEL_DIR="$ALT"
BRIDGE="$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py"
NTG_DIR="$FAKENTG"
NTG_PY="$PROBE"

# saw -- run what the recorder holds under an EMPTY environment; print what the interpreter saw.
saw() {
    local -a cmd
    mapfile -t cmd < <(rec_command)
    (( ${#cmd[@]} > 0 )) || { printf '<nothing was launched>'; return 0; }
    env -i "${cmd[@]}" 2>/dev/null
}

echo "the probe can tell"
check "🔴 an interpreter started with nothing set sees nothing" "<unset>" "$(env -i "$PROBE")"

echo "topo-start: the P4 bridge"
rec_reset; ( p4_topo_start ) >/dev/null 2>&1
check "it launched exactly once"                              1 "$(rec_calls)"
check "🔴 the bridge's interpreter is started with PYTHONDONTWRITEBYTECODE=1" "1" "$(saw)"

echo "ovs-topo-start: the 128-host OVS topology"
rec_reset; ( ovs_topo_start ) >/dev/null 2>&1
check "it launched exactly once"                              1 "$(rec_calls)"
check "🔴 the OVS topology's interpreter is started with PYTHONDONTWRITEBYTECODE=1" "1" "$(saw)"

# --- the verbs root reaches, executed ---------------------------------------------------------
echo "the verbs are wired to what was tested"
NOBIN="$TMPROOT/nobin"; mkdir -p "$NOBIN"
branch_body() {   # <verb> -- the lines of that case branch, without its label and its ;;
    awk -v v="    $1)" '$0 == v {inb=1; next} inb && $0 == "        ;;" {exit} inb {print}' "$LAB"
}
for verb in topo-start ovs-topo-start ovs-topo-4host; do
    body="$(branch_body "$verb")"
    check "the $verb branch was found" yes "$([[ $(grep -c . <<<"$body") -ge 2 ]] && echo yes || echo no)"
    rec_reset
    (
        PATH="$NOBIN"
        session_running() { return 1; }
        eval "$body"
    ) >/dev/null 2>&1
    check "  and launched exactly once" 1 "$(rec_calls)"
    case "$verb" in
        topo-start)      label="🔴 the topo-start branch starts the bridge with PYTHONDONTWRITEBYTECODE=1" ;;
        ovs-topo-start)  label="🔴 the ovs-topo-start branch starts the topology with PYTHONDONTWRITEBYTECODE=1" ;;
        ovs-topo-4host)  label="🔴 the ovs-topo-4host branch starts the topology with PYTHONDONTWRITEBYTECODE=1" ;;
    esac
    check "$label" "1" "$(saw)"
done

# --- a net for another launch through $NTG_PY ---------------------------------------------------
#
# Text, not behaviour, and narrow: it reads the lines that start "$NTG_PY" and "$HB_PYTHON" and
# nothing else, so a launch through any other interpreter is NOT seen here. Two launches are left
# without the variable on purpose, with their reasons:
#   * the heartbeat ("$HB_PYTHON" -I): root's own /usr/bin/python3, the program in /run/ndtwin-lab or on stdin,
#     standard-library imports only, and -I (which implies -E, so the variable would be ignored)
#     keeps the working directory, the script directory and the user's site off the path -- no
#     user tree to write into. This section only keeps each such launch on -I;
#   * `mn -c` (cleanup): system Mininet from root-owned dist-packages.
# A new launch through $NTG_PY that lacks the variable fails here and gets its own case above.
echo "no \$NTG_PY launch without the variable (text net)"
launches="$(grep -n '"\$NTG_PY"' "$LAB" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v 'printf' )"
n_launch="$(grep -c . <<<"$launches")"
check "the helper starts \$NTG_PY from 3 places" 3 "$n_launch"
bare="$(grep -v 'PYTHONDONTWRITEBYTECODE=1 "\$NTG_PY"' <<<"$launches")"
check "🔴 every one of them has PYTHONDONTWRITEBYTECODE=1 directly before the interpreter" "" "$bare"
hb_lines="$(grep -n '"\$HB_PYTHON"' "$LAB" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v '==\|HB_PYTHON=' )"
check "the heartbeat interpreter is started from 3 places" 3 "$(grep -c . <<<"$hb_lines")"
hb_bare="$(grep -v '"\$HB_PYTHON" -I ' <<<"$hb_lines")"
check "  and every one of them is isolated (-I)" "" "$hb_bare"

summary
[[ $FAIL -eq 0 ]]
