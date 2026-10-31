#!/usr/bin/env bash
#
# The P4 app guide quotes the `up. ready` line's NTG labels; this holds the guide to ndt.
#
# [Co-developed with claude code -- Adam]
#
# doc/2026-10-31_p4-app-guide.md tells a newcomer what the words before the attach command mean
# and shows the line NTG as shipped produces. Those words are ndt's (ntg_pane), and a guide that
# quotes a label ndt no longer prints sends the reader looking for a line that is not there. So
# every label is produced HERE, by sourcing ndt and asking ntg_pane on a fixture NTG checkout in
# each state, and then looked up in the guide -- not typed out twice.
#
# Touches no lab and no real NTG checkout: ndt's LAB_CONF and default NTG_DIR are redirected into
# a temp dir. It lives with the guide and needs the ndt that prints these labels, so it lands
# together with or after that ndt; with an ndt that prints other words it fails, as it should.
#
# Run:  bash tests/shell/test_p4_guide_ntg_labels.sh
# Env:  NDT_UNDER_TEST=<path>  GUIDE_UNDER_TEST=<path>
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="${NDT_UNDER_TEST:-$REPO/tools/test_workflow/ndt}"
GUIDE="${GUIDE_UNDER_TEST:-$REPO/doc/2026-10-31_p4-app-guide.md}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 2; }
[[ -r "$GUIDE" ]] || { echo "no guide at $GUIDE"; echo "Ran 1 checks, 1 failed"; exit 2; }

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
in_guide() {   # <what> <text> -- the text occurs in the guide, verbatim (an empty text never does)
    if [[ -n "$2" ]] && grep -qF -- "$2" "$GUIDE"; then echo "  ok       $1"; PASS=$((PASS+1))
    else echo "  FAILED   $1"; echo "             not in the guide: $2"; FAIL=$((FAIL+1)); fi
}

FIX="$(mktemp -d /tmp/ndt-guidelabels-XXXXXX)"
trap '[[ "$FIX" == /tmp/ndt-guidelabels-* ]] && rm -rf "${FIX:?}"' EXIT INT TERM

mk_ntg() {   # <dir> <mode> <host_file> [extra hosts-file text]
    mkdir -p "$1/setting"; : > "$1/network_traffic_generator.py"
    printf -- '---\ninventory:\n  plugin: SimpleInventory\n  options:\n    host_file: "%s"\n' "$3" > "$1/NTG.yaml"
    printf -- '---\nMininet_Testbed:\n  data:\n    mode: "%s"\n%s' "$2" "${4:-}" > "$1/setting/Mininet.yaml"
    printf -- '---\nHardware_Testbed:\n  data:\n    log_level: "DEBUG"\n' > "$1/setting/Hardware.yaml"
}
pane() {   # <ntg_dir> <fresh|reused> -- what lab_entry_points p4 prints
    bash -c "source '$NDT' >/dev/null 2>&1
set +e
LAB_CONF='$FIX/none.conf'
LAB_DEFAULT_KERNEL_DIR='$FIX/kernel'
LAB_DEFAULT_NTG_DIR='$1'
lab_version_problem() { :; }
lab_entry_points p4 $2" 2>&1
}
label() { sed -n '1s/^ *proxy :8081   kernel :8000   \(.*\): sudo tmux .*/\1/p' <<<"$1"; }
mkdir -p "$FIX/kernel/p4_proxy/mininet"; : > "$FIX/kernel/p4_proxy/mininet/ntg_bmv2_topo.py"

section() { printf '\n%s\n' "$1"; }

section "1. the ready line NTG as shipped produces is the one the guide shows"
mk_ntg "$FIX/shipped" custom_command ./setting/Hardware.yaml
out="$(pane "$FIX/shipped" fresh)"
check "  (ndt printed two lines)" "2" "$(grep -c . <<<"$out")"
in_guide "🔴 the guide shows the attach line verbatim" "$(sed -n 1p <<<"$out")"
in_guide "🔴 and the hint line under it, verbatim"     "$(sed -n 2p <<<"$out")"

section "2. every label ndt prints is one the guide explains"
mk_ntg "$FIX/cli" cli ./setting/Mininet.yaml
mk_ntg "$FIX/hw" custom_command ./setting/Hardware.yaml; rm -f "$FIX/hw/setting/Mininet.yaml"
mk_ntg "$FIX/both" custom_command ./setting/Mininet.yaml $'Hardware_Testbed:\n  data: {}\n'
mk_ntg "$FIX/prompt" prompt ./setting/Mininet.yaml
for c in cli:fresh shipped:fresh hw:fresh both:fresh prompt:fresh cli:reused; do
    l="$(label "$(pane "$FIX/${c%%:*}" "${c#*:}")")"
    check "  (${c}: ndt printed a label)" "yes" "$([[ -n "$l" ]] && echo yes || echo no)"
    in_guide "🔴 ${c}: \`$l\` is explained in the guide" "\`$l\`"
done
# The control: the lookup is not vacuous -- a label ndt does not print is not in the guide.
check "  control: a made-up label is not found" "no" \
      "$(grep -qF '`NTG mode surely known`' "$GUIDE" && echo yes || echo no)"

printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
(( FAIL == 0 ))
