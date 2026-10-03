#!/usr/bin/env bash
# rehearse.sh <old|new> <A|B|C|C0|D> -- steps 0, 2 and 6 of the README's procedure, as extracted verbatim, against a
# throwaway clone of the main checkout. Prints what the procedure said and the state it left. [Co-developed with claude code -- Adam]
set -u
VER="$1"; CASE="$2"; H="$(cd "$(dirname "$0")" && pwd)"
MAIN=/home/adam/Desktop/NDTwin-Kernel
B=5311f3f60add32e9b92b2bf964db68a38419ae2a
BWT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927
avail=$(df --output=avail -BM / | tail -1 | tr -dc 0-9); (( avail >= 2048 )) || { echo "DISK: $avail MB < 2048 -- not run"; exit 97; }
W="$(mktemp -d "$H/clone-XXXX")"; M="$W/main"
git clone -q "$MAIN" "$M" || exit 2
gi=(-c user.name=rehearsal -c user.email=r@example.invalid -c commit.gpgsign=false)
git -C "$M" config user.name rehearsal; git -C "$M" config user.email r@example.invalid; git -C "$M" config commit.gpgsign false
[[ "$(git -C "$M" symbolic-ref --short HEAD)" == trunk ]] || { echo "clone is not on trunk"; exit 2; }
BFILE=tools/test_workflow/ndt
git -C "$M" diff --name-only HEAD "$B" | grep -qx "$BFILE" || { echo "$BFILE is not a file B changes"; exit 2; }
echo "== $VER case $CASE: clone at $(git -C "$M" rev-parse --short HEAD), B $B"
event() {   # event <where> -- the case's interference
    case "$CASE:$1" in
        A:after2)  echo "# rec: tools/test_workflow/ndt edited after the merge" >> "$M/$BFILE"; echo "   [event] uncommitted edit to $BFILE (B changes it)" ;;
        B:after0)  echo "x" > "$M/someone_else.txt"; git -C "$M" add someone_else.txt; git "${gi[@]}" -C "$M" commit -q -m "someone else's commit"
                   OTHER=$(git -C "$M" rev-parse HEAD); echo "$OTHER" > "$W/other"; echo "   [event] someone commits to trunk: $OTHER" ;;
        C:after2)  echo "staged" >> "$M/README.md"; git -C "$M" add README.md; echo "   [event] someone stages README.md (a file B does not change)" ;;
        C0:after0) echo "staged" >> "$M/README.md"; git -C "$M" add README.md; echo "   [event] someone stages README.md before the merge" ;;
    esac
}
if [[ "$VER" == old ]]; then
    # the old text assumes one shell that keeps its variables (the agent's calls do not: case D)
    export M B_SHA="$B"
    ( source "$H/old/step0.sh"; event after0; source "$H/old/step2.sh"; event after2
      if [[ "$CASE" == D ]]; then echo "   [event] a fresh shell for step 6: T_MERGE recovered, C_HEAD not"
          ( C_HEAD=""; source "$H/old/step6.sh" )
      else source "$H/old/step6.sh"; fi ) 2>&1 | sed 's/^/   | /'
else
    V="$W/vars"; printf 'M=%s\nB_WT=%s\nB_SHA=%s\nLP=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1\n' "$M" "$BWT" "$B" > "$V"; printf 'C1=%s\nC2=%s\n' "$W/c1-not-run" "$W/c2-not-run" >> "$V"   # step 1 (the 06 runs) is not rehearsed
    for k in 0 2 6; do sed "s#^V=/home/adam/Desktop/NDTwin-Kernel/scratch/live-extb/vars;#V=$V;#" "$H/new/step$k.sh" > "$W/step$k.sh"; done
    { bash "$W/step0.sh" 2>&1 | grep -v '^[a-zA-Z0-9_./-]*$' ; event after0; bash "$W/step2.sh"; event after2
      if [[ "$CASE" == D ]]; then echo "   [event] the vars file lost its C_HEAD line"; sed -i '/^C_HEAD=/d' "$V"; fi
      bash "$W/step6.sh"; echo "   (step 6 rc $?)"; } 2>&1 | sed 's/^/   | /'
fi
T=$(git -C "$M" rev-parse HEAD)
echo "   state: HEAD $(git -C "$M" log --oneline -1 | cut -c1-60); parents $(git -C "$M" rev-list --parents -n1 HEAD | wc -w | awk '{print $1-1}')"
echo "   B merged into trunk: $(git -C "$M" merge-base --is-ancestor "$B" HEAD && echo YES || echo no)"
[[ -s "$W/other" ]] && echo "   someone's commit on trunk: $(git -C "$M" merge-base --is-ancestor "$(cat "$W/other")" HEAD && echo kept || echo DROPPED)"
echo "   index: $(git -C "$M" diff --cached --name-only | tr '\n' ' ')|  worktree edits: $(git -C "$M" diff --name-only | tr '\n' ' ')"
if [[ ( "$CASE" == A || "$CASE" == C ) && "$VER" == new ]]; then
    echo "   -- the owner moves the edit off (git stash), then step 6 again:"
    git -C "$M" stash -q && bash "$W/step6.sh" 2>&1 | sed 's/^/   | /'
fi
rm -rf "${W:?}"
