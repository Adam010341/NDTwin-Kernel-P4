# Shared by the shims. Sourced, never executed -- hence no shebang and mode 644.
# [Co-developed with claude code -- Adam]

# The file every build-guard shims directory ships (see guard_is_shim_dir). Its content is
# irrelevant; its presence is the identity.
GUARD_SHIM_MARKER=".ndtwin-build-guard-shims"

# guard_is_shim_dir <dir>  -- true if <dir> is a build-guard shims directory, from ANY checkout.
#
# Identified by what is IN the directory, never by its path: a shim can know its own path and
# nothing about where another checkout's guard lives. Two guards from two checkouts, one nested
# in the other, put two shim dirs on PATH (`<clone>/shims:<main>/shims:...`); each shim removed
# only its own, found the other checkout's shim as the "real" tool, and the two exec'd each
# other without end (2026-10-25: a baseline build hung for 58 minutes; `cmake --version` alone
# reproduces it).
# Skipping every shims directory makes that impossible, whatever the order or the number -- once
# every guard on PATH carries this check. A guard from before it still strips only its own
# directory; ours skips that guard's shims (see below), but the old one cannot be taught.
#
# A directory is a shims dir if it holds the marker file, or -- for a clone from before the
# marker existed -- a regular file `_resolve.sh` that defines guard_real_tool(). Merely being
# called `_resolve.sh` is not enough: a real-tool directory with an unrelated file of that name
# must stay on the walk.
guard_is_shim_dir() {
    [[ -n "${1:-}" ]] || return 1
    [[ -e "$1/$GUARD_SHIM_MARKER" ]] && return 0
    [[ -f "$1/_resolve.sh" && "$(< "$1/_resolve.sh")" == *'guard_real_tool()'* ]]
}

# guard_shim_dirs_on_path  -- the PATH entries guard_real_tool skips, ':'-joined.
guard_shim_dirs_on_path() {
    local part canon out="" saved_glob OLD_IFS="$IFS"
    case "$-" in *f*) saved_glob=on ;; *) saved_glob=off ;; esac
    set -f; IFS=:
    for part in $PATH; do
        [[ -z "$part" ]] && continue
        canon="$(CDPATH= cd -P -- "$part" 2>/dev/null && pwd -P)" || canon="$part"
        guard_is_shim_dir "$canon" && out+="${out:+:}$part"
    done
    IFS="$OLD_IFS"
    [[ "$saved_glob" == off ]] && set +f
    printf '%s' "$out"
}

# guard_no_real_tool <tool>  -- the one loud message for "nothing but shims on PATH". Callers exit 127.
guard_no_real_tool() {
    echo "build_guard: no real $1 on PATH outside the build-guard shim directories" \
         "(every shims dir is skipped, including other checkouts'); refusing to run." \
         "skipped shims dirs: [$(guard_shim_dirs_on_path)] PATH=$PATH" >&2
}

# guard_refused <candidate> <its dir>  -- says which candidate was refused, before the shim exits 127.
guard_refused() {
    echo "build_guard: refusing $1: it resolves into a build-guard shims dir ($2)" >&2
}

# guard_real_tool <shim_dir> <tool>  -- prints the real tool's path, or nothing.
#
# Finds the real tool by taking every shims directory out of PATH -- this shim's own and any
# other checkout's -- and asking again.
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
    canon_shim="$(CDPATH= cd -P -- "$shim_dir" 2>/dev/null && pwd -P)" || canon_shim="$shim_dir"

    # `for part in $PATH` needs word splitting on ':' but must NOT glob: a PATH entry
    # containing a '*' would otherwise be replaced by matching filenames.
    case "$-" in *f*) saved_glob=on ;; *) saved_glob=off ;; esac
    set -f
    local OLD_IFS="$IFS"; IFS=:
    for part in $PATH; do
        [[ -z "$part" ]] && continue
        canon="$(CDPATH= cd -P -- "$part" 2>/dev/null && pwd -P)" || canon="$part"
        [[ "$canon" == "$canon_shim" ]] && continue
        guard_is_shim_dir "$canon" && continue
        rebuilt+=("$part")
    done
    IFS="$OLD_IFS"
    [[ "$saved_glob" == off ]] && set +f

    local stripped found found_dir
    stripped="$(IFS=:; printf '%s' "${rebuilt[*]}")"
    # `type -P`, not `command -v`: with an exported shell function called like the tool,
    # `command -v` answers with the bare name, and `exec <bare name>` goes back through PATH to the
    # shim. `type -P` looks at files only.
    found="$(PATH="$stripped" type -P "$tool" 2>/dev/null)"
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
    found_dir="$(CDPATH= cd -P -- "$(dirname "$(readlink -f "$found" 2>/dev/null || echo "$found")")" 2>/dev/null && pwd -P)" || found_dir=""
    [[ "$found_dir" == "$canon_shim" ]] && { guard_refused "$found" "$found_dir"; return 0; }
    guard_is_shim_dir "$found_dir" && { guard_refused "$found" "$found_dir"; return 0; }

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
