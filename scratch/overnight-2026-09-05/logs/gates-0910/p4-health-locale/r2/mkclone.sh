#!/usr/bin/env bash
# mkclone.sh <clone dir> <commit> : (re)build a throwaway clone of the worktree at <commit>, with the venv and build
# symlinks inside it only. Refuses while any process still has its cwd, or a path in its command line, under
# <clone dir> (a suite that outlived a stopped driver), so a clone is rebuilt only after its old children are gone.
# [Co-developed with claude code -- Adam]
C="$1"; SHA="$2"
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-locale
users() {
    local p cwd
    for p in /proc/[0-9]*; do
        cwd="$(readlink "$p/cwd" 2>/dev/null)" || continue
        if [[ "$cwd" == "$C" || "$cwd" == "$C/"* ]] || tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -qF -- "$C/"; then
            [[ "${p#/proc/}" == "$$" || "${p#/proc/}" == "$BASHPID" ]] || echo "${p#/proc/}"
        fi
    done
}
left="$(users)"
if [[ -n "$left" ]]; then
    echo "REFUSED: processes still use $C:"; ps -o pid,pgid,sid,cmd -p "$(echo $left | tr ' ' ',')"; exit 2
fi
rm -rf "$C"
git clone -q --no-hardlinks "$W" "$C" && git -C "$C" checkout -q "$SHA" || exit 2
ln -s /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv "$C/p4_proxy/venv"
ln -s /home/adam/Desktop/NDTwin-Kernel/build "$C/build"
echo "clone $C at $(git -C "$C" rev-parse HEAD)"
