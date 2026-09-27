#!/usr/bin/env bash
# redfirst_r3.sh <worktree> <snapshot dir> -- round 3 (fix/hb-followups-r3-0927) red first, with
# redfirst_lib.sh's green / exactly_red (every unexpected output kept, a line after SELF-TEST PASS
# told apart). [Co-developed with claude code -- Adam]
#   R-N1  the HB W gate at c0cef392 (its leak check, the whole-p4_proxy link still in ltree) refuses
#         before any mutation, naming the knob; ltree at c0cef392 vs HEAD, built and checked here
#   R-N2  07 at a435d24e (the new cell, the env-read poll): exactly that cell red; HEAD clean
set -u
WT="$1"; SNAP="$2"; bad=0
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$HERE/redfirst_lib.sh"
R1=c0cef392; R2=a435d24e
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
T=$(mktemp -d "${TMPDIR:-/tmp}/r3-red-XXXXXX"); COPY="$WT/tests/shell/.redfirst-r3-mutate_p4_heartbeat_w.sh"
trap 'rm -rf "$T"; rm -f "$COPY"' EXIT
export KEEP="${KEEP:-$T/kept-not-saved}"
echo "HEAD $(git -C "$WT" rev-parse HEAD); R-N1 red-first $(git -C "$WT" rev-parse $R1); R-N2 red-first $(git -C "$WT" rev-parse $R2)"
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }

echo "== R-N1: the 08 mutant tree"
git -C "$WT" show "$R1:tests/shell/mutate_p4_heartbeat_w.sh" > "$COPY"
( cd "$WT" && timeout 300 bash "$COPY" > "$T/gate_r1.out" 2>&1; echo $? > "$T/gate_r1.rc" )
sed -n '/REFUSE/,$p' "$T/gate_r1.out" | head -8 | sed 's/^/    /'
[[ "$(cat "$T/gate_r1.rc")" == 2 ]] && ok "the gate at $R1 refuses (rc 2)" || nok "the gate at $R1: rc $(cat "$T/gate_r1.rc")"
/usr/bin/grep -qF "REFUSE: 08's mutant tree reaches out of itself" "$T/gate_r1.out" \
    && ok "  before any mutation, and says why" || nok "  no leak refusal in its output"
/usr/bin/grep -qF "p4_proxy/mininet/host_count_override resolves to $WT/p4_proxy/mininet/host_count_override" "$T/gate_r1.out" \
    && ok "  naming it: the tree's host_count_override IS the checkout's ($WT/p4_proxy/mininet/host_count_override)" \
    || nok "  the knob line is not there"
/usr/bin/grep -c 'caught\|SURVIVED' "$T/gate_r1.out" | { read -r n; [[ "$n" == 0 ]] && ok "  and no mutation ran ($n)" || nok "  $n mutation line(s) before the refusal"; }
for rev in "$R1" HEAD; do
    fn="$(git -C "$WT" show "$rev:tests/shell/mutate_p4_heartbeat_w.sh" | sed -n '/^ltree() {/,/^}/p; /^ltree_leaks() {/,/^}/p')"
    leaks="$( REPO="$WT"; LIVE_DIR_REL="$LIVE"; LIVE08="$WT/$LIVE/08_heartbeat.sh"; eval "$fn"
              ltree "$T/tree_$rev"; ltree_leaks "$T/tree_$rev" )"
    echo "    ltree at $rev -> leaks: [$(paste -sd';' <<<"$leaks")]"
    if [[ "$rev" == HEAD ]]; then [[ -z "$leaks" ]] && ok "ltree at HEAD: no way out but the two read-only links" || nok "ltree at HEAD leaks"
    else [[ "$leaks" == *"host_count_override resolves to $WT/"* ]] && ok "ltree at $R1: the knobs are the checkout's" || nok "ltree at $R1 does not show the leak"; fi
done
[[ ! -e "$T/tree_HEAD/p4_proxy/mininet" && -e "$T/tree_HEAD/p4_proxy/proxy_agent/topology_manager.py" && -x "$T/tree_HEAD/p4_proxy/venv/bin/python" ]] \
    && ok "  (HEAD's tree: no p4_proxy/mininet; proxy_agent and the venv's python are there)" || nok "  HEAD's tree is not the expected shape"

echo "== R-N2: 07's live L1 poll"
at07() {   # at07 <rev> <dir>
    mkdir -p "$2/tmp" "$2/p4_proxy"
    git -C "$WT" archive "$1" "$LIVE" | tar -x -C "$2"
    ln -s "$(readlink -f "$WT/p4_proxy/venv")" "$2/p4_proxy/venv"
    ( cd "$2" && TMPDIR="$2/tmp" SELFTEST_HB_RUN="$SNAP/run" SELFTEST_HB_PKGS="$SNAP/pkgs" \
        timeout 600 bash "$LIVE/07_roles_basic.sh" --self-test > "$2/out.txt" 2>&1 )
}
at07 "$R2" "$T/r07"
exactly_red "07 at $R2" "$T/r07/out.txt" "an inherited L1_POLL_S does not shorten the live poll"
at07 HEAD "$T/h07"
green "07 at HEAD" "$T/h07/out.txt"
/usr/bin/grep -qF "an inherited L1_POLL_S=2 does not shorten the live poll" <(/usr/bin/grep '^  ok ' "$T/h07/out.txt") \
    && ok "07 at HEAD runs the new cell: $(/usr/bin/grep -oF 'still polling at 6.5 s (judged 0 polls '"$(sed -n 's/.*judged 0 polls \([0-9]*\).*/\1/p' "$T/h07/out.txt" | head -1)"')' "$T/h07/out.txt" | head -1)" \
    || nok "07 at HEAD has no ok line for the new cell"
echo "R3-RED-FIRST: $([[ $bad == 0 ]] && echo 'red at each red-first tree, clean at HEAD' || echo BROKEN)"
exit $bad
