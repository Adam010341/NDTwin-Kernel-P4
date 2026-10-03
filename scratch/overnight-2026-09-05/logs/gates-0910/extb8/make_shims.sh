#!/usr/bin/env bash
# make_shims.sh <dir> -- the "nolab" PATH shims for sweeping shell suites for lab contact.
# [Co-developed with claude code -- Adam]
# Every shim appends "<suite> <pass> <cmd> <argv>" to $NOLAB_LOG. The ones that could reach a lab
# REFUSE (rc 1, curl rc 7): sudo, mnexec, iperf, iperf3, ping, and the changing forms of tc, ip and
# ovs-*; curl refuses the lab's endpoints (kernel :8000, proxy :8081, controller REST :8080) and
# passes everything else; the read-only forms of tc / ip / ovs go to the real binary.
# ps: the real process table, plus -- when NOLAB_FAKE_FABRIC=1 -- four FAKE Mininet host shells
# (pids 4194391-4194394 -- ABOVE pid_max 4194304, so no real process can have them, and a
# kill aimed at one hits nothing -- argv ending mininet:h1..h4, the convention host_pid matches). No process
# carries that string in its argv: the lines are printed by bash builtins inside this shim.
set -eu
D="$1"; mkdir -p "$D"
LOGLINE='printf "%s %s %s %s\n" "${NOLAB_SUITE:--}" "${NOLAB_PASS:--}" "$(basename "$0")" "$*" >> "${NOLAB_LOG:-/dev/null}"'
for c in sudo mnexec iperf iperf3 ping; do
    cat > "$D/$c" <<EOF
#!/bin/bash
$LOGLINE
echo "$c: refused by the nolab shim (a lab command)" >&2
exit 1
EOF
done
# and no C++ build from a swept suite (this worker never builds C++; the laptop's oomd)
for c in cmake ninja make gcc g++ c++ cc clang clang++; do
    cat > "$D/$c" <<EOF
#!/bin/bash
$LOGLINE
echo "$c: refused by the nolab shim (no C++ build here)" >&2
exit 1
EOF
done
cat > "$D/curl" <<EOF
#!/bin/bash
$LOGLINE
for a in "\$@"; do
    case "\$a" in
        *localhost:8000*|*localhost:8081*|*localhost:8080*|*127.0.0.1:8000*|*127.0.0.1:8081*|*127.0.0.1:8080*|*\[::1\]:80[08][01]*)
            echo "curl: refused by the nolab shim (a lab endpoint): \$a" >&2; exit 7 ;;
    esac
done
exec /usr/bin/curl "\$@"
EOF
for c in tc ip ovs-vsctl ovs-ofctl; do
    real="$(PATH=/usr/sbin:/usr/bin:/sbin:/bin type -P "$c" || echo /nonexistent/$c)"
    cat > "$D/$c" <<EOF
#!/bin/bash
$LOGLINE
case " \$* " in
    *" show "*|*" list "*|*" -o link"*|*" link show"*|*" addr show"*|*" -V "*|*" --version "*|*" get "*|*" find "*|*" dump-flows "*|*" dump-ports "*)
        case " \$* " in *" netns "*|*" exec "*) ;; *) exec "$real" "\$@" ;; esac ;;
esac
echo "$c: refused by the nolab shim (a changing or namespace form)" >&2
exit 1
EOF
done
cat > "$D/ps" <<'EOF'
#!/bin/bash
/usr/bin/ps "$@"; rc=$?
if [[ "${NOLAB_FAKE_FABRIC:-}" == 1 ]]; then
    spec=""; prev=""
    for a in "$@"; do
        [[ "$prev" == -o || "$prev" == -eo || "$prev" == -axo || "$prev" == -Ao ]] && spec="$spec,$a"
        [[ "$a" == -o* && "$a" != -o ]] && spec="$spec,${a#-o}"
        prev="$a"
    done
    if [[ "$spec" == *args* || "$spec" == *cmd* || "$spec" == *command* ]]; then
        for h in 1 2 3 4; do
            line=""
            IFS=, read -r -a cols <<<"${spec#,}"
            for c in "${cols[@]}"; do
                case "${c%%=*}" in
                    pid) line+="$((4194390 + h)) " ;;
                    ppid|pgid|sid) line+="$((4194390 + h)) " ;;   # never 1: a `kill -- -1` would reach everything
                    comm) line+="bash " ;;
                    args|cmd|command) line+="bash --norc -is mininet:h$h " ;;
                    etimes) line+="100 " ;;
                    user) line+="root " ;;
                    *) line+="- " ;;
                esac
            done
            printf '%s\n' "${line% }"
        done
    fi
fi
exit $rc
EOF
chmod +x "$D"/*
echo "shims in $D: $(ls "$D" | tr '\n' ' ')"
