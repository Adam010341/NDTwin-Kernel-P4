#!/usr/bin/env bash
# Round 4 helpers. [Co-developed with claude code -- Adam]
# host_pid: the same substring convention ndt:1183 uses. Never pgrep -f.
r4_host_pid() {
    local tag="mininet:$1" pid args
    while read -r pid args; do
        [[ "${args##* }" == "$tag" ]] && { echo "$pid"; return 0; }
    done < <(ps -eo pid=,args= 2>/dev/null)
    return 1
}
r4_in() { local h="$1"; shift; local p; p=$(r4_host_pid "$h") || return 2; sudo -n mnexec -a "$p" "$@"; }
