#!/usr/bin/env bash
# make_hbwrap.sh <dir> -- the drop check's two binaries as the gates run them (the orchestrator's
# 09-28 conditions, ENFORCED here, not only logged -- round-5 ruling on M-4):
#   <dir>/simple_switch          stands in for NDT_HB_CHECK_BMV2 (the stock throwaway switch)
#   <dir>/simple_switch_grpc     stands in for NDT_HB_CHECK_FABRIC_BMV2 (the fabric's, --version only)
# Each call appends one line to $NOLAB_LOG. A call that meets every condition is
#   <epoch> ALLOWED-LAUNCH <which> pid=<pid> start=<starttime> uid=<uid> argv0=<a0> cwd=<cwd> args=<args>
#   <epoch> ALLOWED-PROBE  <which> pid=... (only `--version`)
# and is exec'd (same pid) through a symlink named as the tool executed it (the fabric's: always
# ndt-hbdrop-bmv2), so the comm is the one the tool chose.
# Anything else is   <epoch> REFUSED-LAUNCH <which> why=<reason> ... -- NOT exec'd, exit 97.
# Conditions: euid not 0; argv[0] ndt-hbdrop-bmv2; a switch: --use-files, every -i `N@pN`
# (pcaps relative to its cwd), --thrift-port in 29400-29499, --device-id >= 900000,
# --notifications-addr exactly ipc://notif.ipc (relative), --log-file relative, cwd a directory
# named ndt-hbdrop-*, no argument naming simple_switch*; a probe: exactly `--version` (it opens no
# socket and writes no file). [Co-developed with claude code -- Adam]
set -eu
D="$1"; mkdir -p "$D"
for which in simple_switch simple_switch_grpc; do
    case "$which" in
        simple_switch)      real=/usr/local/bin/simple_switch; lib="" ;;
        simple_switch_grpc) real=/usr/local/bmv2-fast/bin/simple_switch_grpc; lib=/usr/local/bmv2-fast/lib ;;
    esac
    cat > "$D/$which" <<EOF
#!/usr/bin/env bash
which=$which real=$real lib=$lib
EOF
    cat >> "$D/$which" <<'EOF'
a0="${NDT_HB_CHECK_ARGV0:-?}"
read -r -a st < "/proc/$$/stat"; start="${st[21]}"
head="pid=$$ start=$start uid=$EUID argv0=$a0 cwd=$PWD"
refuse() { printf '%s REFUSED-LAUNCH %s why=%s %s args=%s\n' "$(date +%s.%N)" "$which" "$1" "$head" "$*" >> "$NOLAB_LOG"; echo "hbwrap: refused: $1" >&2; exit 97; }
(( EUID != 0 )) || refuse "euid-0"
[[ "$a0" == ndt-hbdrop-bmv2 ]] || refuse "argv0-$a0"
for x in "$@"; do [[ "${x##*/}" == simple_switch* ]] && refuse "an-argument-names-simple_switch"; done
if [[ "$#" == 1 && "$1" == --version ]]; then
    kind=ALLOWED-PROBE
else
    [[ "$which" == simple_switch ]] || refuse "the-fabric-binary-only-answers---version"
    [[ "${PWD##*/}" == ndt-hbdrop-* && "${PWD##*/}" != ndt-hbdrop-ver-* ]] || refuse "cwd-not-its-own"
    args=("$@"); n=${#args[@]}; thrift=""; dev=""; notif=""; logf=""; files=0; ifs=0
    for (( i = 0; i < n; i++ )); do
        case "${args[i]}" in
            --use-files) files=1; i=$((i+1)) ;;
            -i) i=$((i+1)); [[ "${args[i]}" =~ ^([0-9]+)@p([0-9]+)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]] || refuse "interface-${args[i]}"; ifs=$((ifs+1)) ;;
            --thrift-port) i=$((i+1)); thrift="${args[i]}" ;;
            --device-id) i=$((i+1)); dev="${args[i]}" ;;
            --notifications-addr) i=$((i+1)); notif="${args[i]}" ;;
            --log-file) i=$((i+1)); logf="${args[i]}" ;;
        esac
    done
    (( files == 1 && ifs > 0 )) || refuse "not-use-files"
    [[ "$thrift" =~ ^[0-9]+$ ]] && (( thrift >= 29400 && thrift <= 29499 )) || refuse "thrift-port-$thrift"
    [[ "$dev" =~ ^[0-9]+$ ]] && (( dev >= 900000 )) || refuse "device-id-$dev"
    [[ "$notif" == ipc://notif.ipc ]] || refuse "notifications-addr-${notif:-default}"
    [[ -n "$logf" && "$logf" != /* ]] || refuse "log-file-$logf"
    kind=ALLOWED-LAUNCH
fi
# the name the tool executed us by is the comm the real binary gets (the stock one mirrors the tool;
# the fabric's always runs as ndt-hbdrop-bmv2: comm simple_switch_g is what ndt's bmv2_count counts)
name="${0##*/}"; [[ "$which" == simple_switch_grpc ]] && name=ndt-hbdrop-bmv2
printf '%s %s %s %s exe=%s args=%s\n' "$(date +%s.%N)" "$kind" "$which" "$head" "$name" "$*" >> "$NOLAB_LOG"
# the link lives under TMPDIR, one directory per binary, never in the caller's cwd (an old tool runs its
# --version probe from wherever it was started -- the worktree root, in red first)
R="${TMPDIR:-/tmp}/hbwrap-real-$EUID/$which"; mkdir -p "$R" && ln -sfn "$real" "$R/$name"
[[ -n "$lib" ]] && export LD_LIBRARY_PATH="$lib"
exec -a "$a0" "$R/$name" "$@"
EOF
    chmod +x "$D/$which"
done
