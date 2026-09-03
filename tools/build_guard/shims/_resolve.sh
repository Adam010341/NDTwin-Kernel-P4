# Shared by the shims. Sourced, never executed -- hence no shebang and mode 644.
# [Co-developed with claude code -- Adam]

# guard_real_tool <shim_dir> <tool>  -- prints the real tool's path, or nothing.
#
# Finds the real tool by taking the shim's own directory out of PATH and asking again.
# Hardcoding /usr/bin/<tool> would be an assumption: this laptop has conda on PATH, and a
# conda- or pip-installed cmake is an ordinary thing to have. Resolving instead of assuming
# also makes the shim testable -- a test can put a fake tool on PATH and read what the shim
# forwards to it.
#
# The shim's directory is passed in rather than derived from BASH_SOURCE, because inside a
# function BASH_SOURCE[1] means "whoever called me", which stops being the shim the moment
# anything wraps the call.
guard_real_tool() {
    # `pwd -P`, not `pwd`: bash's pwd is LOGICAL, so `cd <symlink-to-shimdir> && pwd` prints the
    # symlink's own path and the comparison below misses. That miss is not a wrong answer -- it
    # leaves the shim dir in PATH, `command -v` finds the shim, and the shim execs itself.
    local shim_dir="$1" tool="$2" canon_shim part canon rebuilt=() saved_glob
    canon_shim="$(cd "$shim_dir" 2>/dev/null && pwd -P)" || canon_shim="$shim_dir"

    # `for part in $PATH` needs word splitting on ':' but must NOT glob: a PATH entry
    # containing a '*' would otherwise be replaced by matching filenames.
    case "$-" in *f*) saved_glob=on ;; *) saved_glob=off ;; esac
    set -f
    local OLD_IFS="$IFS"; IFS=:
    for part in $PATH; do
        [[ -z "$part" ]] && continue
        canon="$(cd "$part" 2>/dev/null && pwd -P)" || canon="$part"
        [[ "$canon" == "$canon_shim" ]] && continue
        rebuilt+=("$part")
    done
    IFS="$OLD_IFS"
    [[ "$saved_glob" == off ]] && set +f

    local stripped found found_dir
    stripped="$(IFS=:; printf '%s' "${rebuilt[*]}")"
    found="$(PATH="$stripped" command -v "$tool" 2>/dev/null)"
    [[ -n "$found" ]] || return 0

    # If the answer is the shim itself, the shim would exec the shim: one process spinning
    # forever, which every caller without a timeout of its own -- that is every gate script in
    # tests/shell -- reads as "still building". Refusing here turns that into rc 127 and a
    # sentence. Nothing legitimate is rejected: the real tool is never inside the shim dir.
    #
    # `readlink -f` first, because stripping the shim DIRECTORY out of PATH does not catch a
    # POINTER into it: a $SOMEWHERE/cmake that is a symlink to $SHIM/cmake resolves through a
    # directory that was never stripped. Comparing the link's target is what makes this check
    # reachable, and therefore what makes it testable.
    found_dir="$(cd "$(dirname "$(readlink -f "$found" 2>/dev/null || echo "$found")")" 2>/dev/null && pwd -P)" || found_dir=""
    [[ "$found_dir" == "$canon_shim" ]] && return 0

    printf '%s' "$found"
}

# guard_jobs -- the job count every shim forces.
guard_jobs() {
    local j="${SHIM_JOBS:-2}"
    # A caller exporting SHIM_JOBS=0, or a typo, must not silently become "unlimited": -j0 is
    # exactly the state this guard exists to prevent, and make reads it as no limit at all.
    [[ "$j" =~ ^[1-9][0-9]*$ ]] || j=2
    printf '%s' "$j"
}
