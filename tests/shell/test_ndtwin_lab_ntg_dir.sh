#!/usr/bin/env bash
#
# Where the P4 bridge finds NTG, and how that answer reaches it.
#
# [Co-developed with claude code -- Adam]
#
# The defect (2026-10-26, fresh VM, NTG cloned under /home/ndt, NTG_PY set in
# /etc/ndtwin-lab.conf): `ndt up p4 4` returned rc 1 after 185.4 s with "fabric did not come up:
# 0/10 switches", and topo.log held one line:
#
#     Error: NTG repo not found at /home/adam/Network-Traffic-Generator (override with the
#     NTG_DIR env var)
#
# ntg_bmv2_topo.py read NTG_DIR from its environment with a default under one person's home, and
# its environment is root's tmux pane: `sudo` resets the caller's, and `topo-start` passed
# nothing. So the hint in the message could not be followed through `ndt up`, and the config file
# had no key for it. The fix follows G-7 rather than the hint: NTG_DIR is a key of the root-only
# config file, and `topo-start` hands its value to the bridge explicitly.
#
# 🔑 EXERCISED, NOT GREPPED. p4_topo_start is called with $TMUX replaced by a recorder (the one
#    stub; the loader, the parser, the refusal and the launch are the real ones), and section 3
#    then RUNS the recorded command under an empty environment with a probe in place of the
#    interpreter, so what is asserted is the value the bridge would see, not the spelling of the
#    argv. Section 5 executes the dispatch's own `topo-start` branch for the same reason
#    test_ndt_ovs_topo_script.sh does: a function can be right while the verb root reaches does
#    not call it.
#
# Run:  bash tests/shell/test_ndtwin_lab_ntg_dir.sh
#       NDTWIN_LAB_UNDER_TEST=<copy> NDT_UNDER_TEST=<copy> bash tests/shell/test_ndtwin_lab_ntg_dir.sh   (gate)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LAB="${NDTWIN_LAB_UNDER_TEST:-$REPO/tools/test_workflow/ndtwin-lab}"
NDT="${NDT_UNDER_TEST:-$REPO/tools/test_workflow/ndt}"
BRIDGE_PY="$REPO/p4_proxy/mininet/ntg_bmv2_topo.py"
[[ -r "$LAB" ]] || { echo "no ndtwin-lab at $LAB"; echo "Ran 1 checks, 1 failed"; exit 2; }
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 2; }

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }
summary() { printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"; }

TMPROOT="$(mktemp -d /tmp/ndt-ntgdir-XXXXXX)"
cleanup_all() { [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-ntgdir-* ]] && rm -rf "$TMPROOT"; return 0; }
trap cleanup_all EXIT INT TERM

# --- section 0: what an exported NTG_DIR does to the helper ---------------------------------
#
# Asked in a fresh shell BEFORE this one sources the helper, because sourcing is where the answer
# is decided. The environment must not get a vote (the KERNEL_DIR comment at the top of
# ndtwin-lab, FINDING-01): whatever the caller exported, the helper's NTG_DIR is the default or
# the config file's.
echo "the caller's environment does not choose NTG_DIR"
env_said="$(NTG_DIR=/nonexistent/NDT-TEST-FIXTURE/from-the-environment \
    bash -c 'source "$1" >/dev/null 2>&1; set +e; printf "%s|%s|%s" "${NTG_DIR:-<unset>}" "${LAB_DEFAULT_NTG_DIR:-<unset>}" "${LAB_CONF_SOURCE:-<unset>}"' _ "$LAB")"
env_ntg="$(cut -d'|' -f1 <<<"$env_said")"
env_default="$(cut -d'|' -f2 <<<"$env_said")"
env_source="$(cut -d'|' -f3 <<<"$env_said")"
# On a machine whose real /etc/ndtwin-lab.conf was accepted, that file may set NTG_DIR, and then
# the helper's value is the file's, not the default. Only the half that holds everywhere is
# asserted there; the default is pinned wherever no config file is in force.
if [[ "$env_source" == /etc/ndtwin-lab.conf ]]; then
    echo "  note     /etc/ndtwin-lab.conf is in force here; only 'not the exported value' is asserted"
else
    check "🔴 an exported NTG_DIR is replaced by the helper's own value" \
          "$env_default" "$env_ntg"
fi
check "  and that value is not the exported one" no \
      "$(has from-the-environment "$env_ntg")"

# Sourced, not executed: ndtwin-lab returns before its root guard and before its dispatch.
# shellcheck source=/dev/null
source "$LAB" || { echo "  FAILED   could not source $LAB"; summary; exit 1; }
set +e

# --- section 1: the config file has a key for it -------------------------------------------
echo "NTG_DIR is a key of the install-time config file"

# A kernel tree that passes the parser's own post-condition, and an NTG checkout.
FAKETREE="$TMPROOT/kernel"; mkdir -p "$FAKETREE/p4_proxy/mininet"
: > "$FAKETREE/p4_proxy/mininet/ntg_bmv2_topo.py"
FAKENTG="$TMPROOT/ntg checkout"; mkdir -p "$FAKENTG"; : > "$FAKENTG/network_traffic_generator.py"

check "the built-in default is the value the bridge used to carry" \
      "$(grep -o 'os.environ.get("NTG_DIR", "[^"]*")' "$BRIDGE_PY" | sed 's/.*, "\(.*\)")/\1/')" \
      "${LAB_DEFAULT_NTG_DIR:-<no LAB_DEFAULT_NTG_DIR>}"

good="$TMPROOT/good.conf"
printf 'KERNEL_DIR=%s\nNTG_PY=/usr/bin/python3\nNTG_DIR=%s\n' "$FAKETREE" "$FAKENTG" > "$good"
parsed="$( lab_config_parse "$good" >/dev/null 2>&1; echo "rc=$?|${NTG_DIR-}|${LAB_CONF_ERROR-}" )"
check "🔴 a config with an NTG_DIR line is adopted"  "rc=0" "${parsed%%|*}"
check "  and NTG_DIR is the value it names"          "$FAKENTG" "$(cut -d'|' -f2 <<<"$parsed")"

bad="$TMPROOT/unknown.conf"
printf 'KERNEL_DIR=%s\nNTG_DIRS=/tmp\n' "$FAKETREE" > "$bad"
unk="$( lab_config_parse "$bad" >/dev/null 2>&1; printf '%s' "$LAB_CONF_ERROR" )"
check "an unknown key is still refused"              yes "$(has "unknown key 'NTG_DIRS'" "$unk")"
check "  and the refusal lists NTG_DIR among the known keys" yes "$(has "NTG_DIR)" "$unk")"

rel="$TMPROOT/relative.conf"
printf 'KERNEL_DIR=%s\nNTG_DIR=Network-Traffic-Generator\n' "$FAKETREE" > "$rel"
relrc="$( lab_config_parse "$rel" >/dev/null 2>&1; echo $? )"
check "a relative NTG_DIR is refused like any other path" 1 "$relrc"

# A refused file puts every key back, NTG_DIR included: a half-applied config matches nothing
# anybody wrote down. This file is the test user's, so the trust check refuses it.
after="$( NTG_DIR=/nonexistent/NDT-TEST-FIXTURE/half-applied
          lab_config_load "$good" >/dev/null 2>&1
          printf '%s' "$NTG_DIR" )"
check "🔴 a refused config file leaves NTG_DIR at the default" "${LAB_DEFAULT_NTG_DIR:-<no LAB_DEFAULT_NTG_DIR>}" "$after"

# --- section 2: the recorder ---------------------------------------------------------------
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
rec_arg_after() {
    local flag="$1" prev="" line
    while IFS= read -r line; do
        [[ "$prev" == "$flag" ]] && { printf '%s' "$line"; return 0; }
        prev="$line"
    done < <(rec_argv)
    return 1
}
# rec_command -- the command tmux would run: every argv element after `-c <dir>`.
rec_command() { rec_argv | grep -v '^$' | awk 'seen {print} prev == "-c" {seen=1} {prev=$0}'; }
TMUX="$REC"

KERNEL_DIR="$REPO"
BRIDGE="$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py"
NTG_DIR="$FAKENTG"

echo "what topo-start hands root"
check "ndtwin-lab defines p4_topo_start" defined \
      "$(declare -F p4_topo_start >/dev/null && echo defined || echo 'not defined -- the launch is inline in the root-only dispatch')"
if ! declare -F p4_topo_start >/dev/null; then
    echo "  ... sections 2-4 need p4_topo_start and cannot run"
    p4_topo_start() { return 99; }
fi

rec_reset
out="$( p4_topo_start 2>&1 )"; rc=$?
check "the launch succeeds"                         0 "$rc"
check "it launched exactly once"                    1 "$(rec_calls)"
check "it is still the 'topo' session"              topo "$(rec_arg_after -s)"
check "tmux's working directory is the bridge's"    "$KERNEL_DIR/p4_proxy/mininet" "$(rec_arg_after -c)"
check "the bridge is the last argument"             "$BRIDGE" "$(rec_command | tail -1)"
check "  handed to NTG_PY"                          "$NTG_PY" "$(rec_command | tail -2 | head -1)"
check "🔴 the command carries NTG_DIR=<the configured value>" yes \
      "$(rec_command | grep -qxF "NTG_DIR=$FAKENTG" && echo yes || echo no)"
check "it says which tree it started"               yes "$(has "topo session started from $KERNEL_DIR" "$out")"

# --- section 3: the value reaches the program, under an environment that carries nothing ------
#
# The recorded command is run for real with the interpreter swapped for a probe, under `env -i`:
# that is the pane's situation (sudo reset the caller's environment, and root's tmux server has
# no NTG_DIR in its own). A launch that relied on inheriting it prints nothing here.
echo "🔴 the bridge's environment has NTG_DIR in it"
PROBE="$TMPROOT/probe-python"
printf '#!/bin/bash\nprintf "%%s" "${NTG_DIR-<unset>}"\n' > "$PROBE"; chmod 755 "$PROBE"
rec_reset
( NTG_PY="$PROBE"; p4_topo_start ) >/dev/null 2>&1
mapfile -t CMD < <(rec_command)
seen="<nothing was launched>"
(( ${#CMD[@]} > 0 )) && seen="$(env -i "${CMD[@]}" 2>/dev/null)"
check "🔴 the program started in the pane sees the configured NTG_DIR" "$FAKENTG" "$seen"

# --- section 4: an NTG_DIR that is not NTG is refused, not started ---------------------------
echo "🔴 an NTG_DIR that is not an NTG checkout refuses instead of starting a dying pane"
rec_reset
miss_err="$( ( NTG_DIR=/nonexistent/NDT-TEST-FIXTURE/Network-Traffic-Generator; p4_topo_start ) 2>&1 >/dev/null )"
miss_rc="$( ( NTG_DIR=/nonexistent/NDT-TEST-FIXTURE/Network-Traffic-Generator; p4_topo_start ) >/dev/null 2>&1; echo $? )"
check "rc is non-zero"                              1 "$([[ "$miss_rc" -ne 0 ]] && echo 1 || echo 0)"
check "  and nothing was launched"                  0 "$(rec_calls)"
check "  and the message names the path"            yes "$(has /nonexistent/NDT-TEST-FIXTURE/Network-Traffic-Generator "$miss_err")"
check "  and names the config key"                  yes "$(has "NTG_DIR=" "$miss_err")"
check "  and names the config file"                 yes "$(has /etc/ndtwin-lab.conf "$miss_err")"

NOTNTG="$TMPROOT/not-ntg"; mkdir -p "$NOTNTG"
rec_reset
( NTG_DIR="$NOTNTG"; p4_topo_start ) >/dev/null 2>&1; dir_rc=$?
check "a directory without network_traffic_generator.py is refused too" 1 "$([[ "$dir_rc" -ne 0 ]] && echo 1 || echo 0)"
check "  and nothing was launched"                  0 "$(rec_calls)"

# --- section 5: the verbs are wired to what was tested -------------------------------------
echo "the verbs are wired to what was tested"
NOBIN="$TMPROOT/nobin"; mkdir -p "$NOBIN"
branch_body() {   # <verb> -- the lines of that case branch, without its label and its ;;
    awk -v v="    $1)" '$0 == v {inb=1; next} inb && $0 == "        ;;" {exit} inb {print}' "$LAB"
}
start_body="$(branch_body topo-start)"
check "the topo-start branch was found"             yes "$([[ $(grep -c . <<<"$start_body") -ge 2 ]] && echo yes || echo no)"
rec_reset
(
    PATH="$NOBIN"
    session_running() { return 1; }
    eval "$start_body"
) >/dev/null 2>&1
check "🔴 the topo-start branch hands the bridge NTG_DIR" yes \
      "$(rec_command | grep -qxF "NTG_DIR=$FAKENTG" && echo yes || echo no)"
check "  and launches the bridge"                   "$BRIDGE" "$(rec_command | tail -1)"

config_body="$(branch_body config)"
cfg="$( PATH="$NOBIN"; eval "$config_body" 2>&1 )"
check "\`config\` prints NTG_DIR"                   yes "$(has "NTG_DIR:    $FAKENTG" "$cfg")"
cfg_bad="$( PATH="$NOBIN"; NTG_DIR="$NOTNTG"; eval "$config_body" 2>&1 )"
check "  and says when topo-start would refuse it"  yes "$(has "topo-start will refuse" "$cfg_bad")"

# --- section 6: ndt reads the same file the same way ---------------------------------------
#
# ndt keeps a read-only copy of the helper's parser (lab_conf_kernel_dir) to know which tree the
# helper acts in. A key the helper accepts and ndt does not is a config the two read differently:
# ndt would fall back to the built-in tree and refuse `ndt up` with "does not act in this
# checkout" on the very machine the config was written for.
echo "ndt's copy of the parser accepts the same file"
ndt_says="$( cd "$REPO" && bash -c 'source "$1" >/dev/null 2>&1; set +e; lab_conf_kernel_dir "$2"; echo "|rc=$?"' _ "$NDT" "$good" 2>/dev/null )"
check "🔴 ndt reads KERNEL_DIR out of a config that has NTG_DIR in it" "$FAKETREE|rc=0" "$ndt_says"
ndt_unk="$( cd "$REPO" && bash -c 'source "$1" >/dev/null 2>&1; set +e; lab_conf_kernel_dir "$2" >/dev/null; echo "rc=$?"' _ "$NDT" "$bad" 2>/dev/null )"
check "  and still refuses an unknown key, as the helper does" "rc=1" "$ndt_unk"

summary
[[ $FAIL -eq 0 ]]
