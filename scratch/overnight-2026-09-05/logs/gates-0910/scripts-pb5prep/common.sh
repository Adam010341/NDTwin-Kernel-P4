# Worker pb5prep (2026-09-26): shared settings for the offline verification of branch
# fix/p4proxy-protobuf5-0926. Sourced, not run.
# [Co-developed with claude code -- Adam]
#
# Every log is <name>.pb5prep-<sha8>.log in logs/gates-0910; its FIRST line is "# HEAD <full sha>"
# plus what ran, its LAST line is "rc=<n>" (the real exit status of what the log is about). A log
# that exists is never overwritten.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-pb5-merge-prep-0926
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
S=$L/scripts-pb5prep
GUARD=$WT/tools/build_guard/guarded_build.sh
W=$WT/scratch/pb5prep                 # every venv this worker makes lives here (gitignored scratch/)
MAIN_REPO=/home/adam/Desktop/NDTwin-Kernel
MAINPY=$MAIN_REPO/p4_proxy/venv/bin/python      # READ-ONLY: only ever run with PYTHONDONTWRITEBYTECODE=1
TRUNK=580767a83dea12e42755687d174af891b69deb97
FULL=$(git -C "$WT" rev-parse HEAD)
SHA=${FULL:0:8}
export PIP_NO_INPUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1
mkdir -p "$W"

tree_clean() { [[ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ]]; }
tree_clean || { echo "REFUSE: tracked changes in $WT"; exit 2; }

# new_log <name> <what> -- create the log with its first line; echo its path.
new_log() {
    local f="$L/$1.pb5prep-$SHA.log"
    if [[ -e "$f" ]]; then echo "REFUSE: $f exists" >&2; return 2; fi
    printf '# HEAD %s  %s\n# %s  worktree %s\n' "$FULL" "$2" "$(date -u +%FT%TZ)" "$WT" > "$f"
    echo "$f"
}

# pyid <python> -- one line naming a venv: prefix, version, protobuf + backend. -B: no .pyc.
pyid() {
    PYTHONDONTWRITEBYTECODE=1 "$1" -B -c 'import sys
try:
    import google.protobuf as p; from google.protobuf.internal import api_implementation as a
    pb = p.__version__ + " backend=" + a.Type()
except Exception as e:
    pb = "protobuf n/a (%s)" % type(e).__name__
print("venv", sys.prefix, "python", sys.version.split()[0], "protobuf", pb)'
}

# main venv fingerprint, the method the 09-26 live trial used (fingerprint_pre.log):
#   find <venv> -type f -printf '%P %s %T@\n' | sort | sha256sum
main_fp() { find "$MAIN_REPO/p4_proxy/venv" -type f -printf '%P %s %T@\n' | sort | sha256sum | cut -c1-64; }
