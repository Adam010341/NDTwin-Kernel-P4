#!/usr/bin/env bash
# make_shims_live.sh <dir> -- the nolab shims (make_shims.sh), but with a sudo that ANSWERS the
# read-only lab probes as a LIVE lab would. [Co-developed with claude code -- Adam]
# The orchestrator's round (a), 09-27: what does a suite go on to do when the probe says the lab
# is up? Every call is still recorded ("<suite> <pass> sudo <argv>" in $NOLAB_LOG), NOTHING reaches
# root -- the answers are printed by this shim:
#   sudo -n <lab helper> status      rc 0: a config line, energy / sim / topo sessions, "bmv2: 10  mininet: 4"
#   sudo -n <lab helper> topo-out N  rc 0: a mininet> prompt
#   sudo -n ovs-vsctl list-br        rc 0: s1 s2 s3 s4        (also ovs-vsctl list-br without sudo)
#   sudo -n mnexec -a 1 true         rc 0
#   sudo -n -l <anything>            rc 0: the command's path, as sudoers prints a granted one
#   anything else through sudo       recorded, REFUSED (rc 1) -- these are the ones to look at
# ps: with NOLAB_FAKE_FABRIC=1 the Mininet host shells h1..h4 (make_shims.sh), and with
# NOLAB_FAKE_BMV2=1 also ten simple_switch_grpc rows (pids above pid_max) in comm / args listings.
set -eu
D="$1"
bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/make_shims.sh" "$D" > /dev/null
LOGLINE='printf "%s %s %s %s\n" "${NOLAB_SUITE:--}" "${NOLAB_PASS:--}" "$(basename "$0")" "$*" >> "${NOLAB_LOG:-/dev/null}"'
cat > "$D/sudo" <<EOF
#!/bin/bash
$LOGLINE
a=("\$@"); [[ "\${a[0]:-}" == -n ]] && a=("\${a[@]:1}")
[[ "\${a[0]:-}" == -l ]] && { printf '%s\n' "\${a[*]:1}"; exit 0; }
case "\${a[0]:-}" in */ndtwin-lab|ndtwin-lab) h=lab ;; */ovs-vsctl|ovs-vsctl) h=ovs ;; */mnexec|mnexec) h=mnexec ;; *) h="" ;; esac
case "\$h \${a[*]:1}" in
    "lab status")
        printf 'config: /etc/ndtwin-lab.conf (KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel)\n'
        printf '%s: 1 windows (created Sun Sep 27 05:00:00 2026)\n' energy sim topo
        printf 'bmv2: 10  mininet: 4\n'; exit 0 ;;
    "lab topo-out"*) printf 'mininet> \n'; exit 0 ;;
    "ovs list-br") printf 's1\ns2\ns3\ns4\n'; exit 0 ;;
    "mnexec -a 1 true") exit 0 ;;
esac
echo "sudo: refused by the nolab shim (a verb that is not a read-only probe)" >&2
exit 1
EOF
cat > "$D/ovs-vsctl" <<EOF
#!/bin/bash
$LOGLINE
[[ "\$*" == list-br ]] && { printf 's1\ns2\ns3\ns4\n'; exit 0; }
echo "ovs-vsctl: refused by the nolab shim" >&2
exit 1
EOF
cat > "$D/ps" <<'EOF'
#!/bin/bash
spec=""; prev=""
for a in "$@"; do
    [[ "$prev" == -o || "$prev" == -eo || "$prev" == -axo || "$prev" == -Ao ]] && spec="$spec,$a"
    [[ "$a" == -o?* ]] && spec="$spec,${a#-o}"
    prev="$a"
done
rows() {   # the fake rows for this listing: Mininet hosts and/or bmv2 switches
    local cols c line h n kind off
    IFS=, read -r -a cols <<<"${spec#,}"
    for kind in host bmv2; do
        [[ $kind == host && "${NOLAB_FAKE_FABRIC:-}" != 1 ]] && continue
        [[ $kind == bmv2 && "${NOLAB_FAKE_BMV2:-}" != 1 ]] && continue
        n=4; off=0; [[ $kind == bmv2 ]] && { n=10; off=20; }
        for h in $(seq 1 $n); do
            line=""
            for c in "${cols[@]}"; do
                case "${c%%=*}" in
                    pid|ppid|pgid|sid) line+="$(( 4194390 + h + off )) " ;;
                    comm) [[ $kind == host ]] && line+="bash " || line+="simple_switch_g " ;;
                    args|cmd|command) [[ $kind == host ]] && line+="bash --norc -is mininet:h$h " \
                        || line+="/usr/local/bin/simple_switch_grpc --device-id $h -i 1@s$h-eth1 --no-p4 " ;;
                    etimes) line+="100 " ;;
                    user) line+="root " ;;
                    *) line+="- " ;;
                esac
            done
            printf '%s\n' "${line% }"
        done
    done
}
# fake rows only in a machine-wide listing that names processes by their command: never for a
# `-p <pid>` / `--pid` / `-q` question about one process (the first version answered
# `ps -o pgid= -p $$` with fake rows too, and test_apps_stop_kills_the_group went red on it)
[[ " $* " == *" -p "* || " $* " == *" --pid"* || " $* " == *" -q "* ]] && exec /usr/bin/ps "$@"
[[ "$spec" == *args* || "$spec" == *cmd* || "$spec" == *command* || "$spec" == *comm* ]] || exec /usr/bin/ps "$@"
hl=1; IFS=, read -r -a _c <<<"${spec#,}"; for c in "${_c[@]}"; do [[ "$c" == *=* ]] || hl=0; done
if (( hl )); then rows; exec /usr/bin/ps "$@"; fi
real="$(/usr/bin/ps "$@")"; rc=$?
printf '%s\n' "$real" | head -1; rows; printf '%s\n' "$real" | tail -n +2
exit $rc
EOF
chmod +x "$D"/*
echo "live-answering shims in $D"
