#!/usr/bin/env bash
# redfirst_stub.sh <worktree> <nolab2 dir> -- fix/probe-suites-stub-0927, red first. Each of the six
# suites runs at 8746c1bc (a copy beside the real file) and at HEAD, each under three external
# shim sets: R (refusing, what CI and the gates see), L (a sudo answering as a live lab with
# bmv2 + OVS + hosts), L2 (live OVS + hosts, no bmv2). Nothing reaches root in any of them.
#   base: under L2 test_ndt_sample_rate_reads_both_bounds goes RED (a live OVS changes its verdict)
#   HEAD: every suite green under R, L and L2, with the SAME checks, ok for ok, in all three; one
#         check more than at base (the closing check); and the external shims see NO sudo at all --
#         the suite's own stub answers every one.
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; NL="$2"; bad=0
SUITES=(test_apps_stop_kills_the_group.sh test_cell_gate_suspect_wiring.sh test_lab_handoff.sh
        test_ndt_app_orphans.sh test_ndt_honesty.sh test_ndt_sample_rate_reads_both_bounds.sh)
T=$(mktemp -d "${TMPDIR:-/tmp}/stub-red-XXXXXX"); COPIES=()
trap 'rm -f "${COPIES[@]}"; rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
cd "$WT" || exit 2
lab_hosts() { /usr/bin/ps -eo args= 2>/dev/null | /usr/bin/grep -cE '(^| )mininet:[A-Za-z0-9_-]+$'; }
[[ "$(lab_hosts)" == 0 ]] || { echo "REFUSE: a real fabric is up"; exit 2; }
bash "$NL/make_shims.sh" "$T/sh_R" >/dev/null
bash "$NL/make_shims_live.sh" "$T/sh_L" >/dev/null; cp -r "$T/sh_L" "$T/sh_L2"
echo "HEAD $(git rev-parse HEAD); base 8746c1bc"
run() {   # run <file> <R|L|L2> <label>
    env -u SELFTEST_PROBE_SUDO PATH="$T/sh_$2:$PATH" NOLAB_LOG="$T/$3.$2.calls" NOLAB_SUITE="$3" NOLAB_PASS="$2" \
        NOLAB_FAKE_FABRIC=$([[ $2 == L* ]] && echo 1 || echo 0) NOLAB_FAKE_BMV2=$([[ $2 == L ]] && echo 1 || echo 0) \
        timeout 900 bash "$1" < /dev/null > "$T/$3.$2.out" 2>&1
    echo $? > "$T/$3.$2.rc"; touch "$T/$3.$2.calls"
}
checks() { /usr/bin/grep -E '^ *(ok|FAILED) ' "$1" | sed -E 's/[0-9]{5,}/N/g; s/ +/ /g'; }
for s in "${SUITES[@]}"; do
    echo; echo "== $s"
    b="tests/shell/.redfirst-stub-base-$s"; git show "8746c1bc:tests/shell/$s" > "$b"; COPIES+=("$WT/$b")
    for p in R L L2; do run "$b" "$p" "base-$s"; run "tests/shell/$s" "$p" "head-$s"; done
    for p in R L L2; do
        printf '    %-3s base rc %s, %-3s red, %-28s | head rc %s, %-3s red, %s\n' "$p" \
            "$(cat "$T/base-$s.$p.rc")" "$(checks "$T/base-$s.$p.out" | /usr/bin/grep -c '^ *FAILED')" "$(tail -1 "$T/base-$s.$p.out" | cut -c1-28)" \
            "$(cat "$T/head-$s.$p.rc")" "$(checks "$T/head-$s.$p.out" | /usr/bin/grep -c '^ *FAILED')" "$(tail -1 "$T/head-$s.$p.out" | cut -c1-40)"
    done
    if [[ "$s" == test_ndt_sample_rate_reads_both_bounds.sh ]]; then
        [[ "$(cat "$T/base-$s.L2.rc")" != 0 && "$(checks "$T/base-$s.L2.out" | /usr/bin/grep -c '^ *FAILED')" -ge 1 ]] \
            && ok "base under L2 (a live OVS): RED -- the verdict depended on the lab" || nok "base under L2 was not red"
    fi
    for p in R L L2; do
        [[ "$(cat "$T/head-$s.$p.rc")" == 0 && "$(checks "$T/head-$s.$p.out" | /usr/bin/grep -c '^ *FAILED')" == 0 ]] \
            || nok "head under $p is not green"
    done
    if cmp -s <(checks "$T/head-$s.R.out") <(checks "$T/head-$s.L.out") && cmp -s <(checks "$T/head-$s.R.out") <(checks "$T/head-$s.L2.out"); then
        ok "head: green under R, L and L2, the same $(checks "$T/head-$s.R.out" | wc -l) checks, ok for ok"
    else
        nok "head: the checks differ between R, L and L2"; diff <(checks "$T/head-$s.R.out") <(checks "$T/head-$s.L2.out") | head -6 | sed 's/^/      /'
    fi
    nb="$(checks "$T/base-$s.R.out" | wc -l)"; nh="$(checks "$T/head-$s.R.out" | wc -l)"
    [[ "$nh" == $((nb + 1)) ]] && ok "  $nh checks = base's $nb + the closing check" || nok "  head has $nh checks, base $nb"
    /usr/bin/grep -E '^ *ok ' "$T/head-$s.R.out" | /usr/bin/grep -qF "every sudo went to this suite's stub" \
        && ok "  the closing check is ok" || nok "  the closing check is not ok"
    ext="$(cat "$T/head-$s.L.calls" "$T/head-$s.L2.calls" | /usr/bin/grep -cE ' (sudo|ovs-vsctl|mnexec) ')"
    [[ "$ext" == 0 ]] && ok "  under L and L2 the external (answering) shims got no sudo/ovs call at all -- the suite's stub took every one" \
        || nok "  $ext call(s) reached the external shims past the suite's stub"
done
[[ "$(lab_hosts)" == 0 ]] || nok "a real fabric appeared"
rm -f "${COPIES[@]}"; [[ -z "$(ls "$WT"/tests/shell/.redfirst-stub-* 2>/dev/null)" ]] && ok "the base copies are gone" || nok "copies left"
echo "STUB-RED-FIRST: $([[ $bad == 0 ]] && echo 'sample_rate red on a live OVS at base; all six identical under R/L/L2 at HEAD' || echo BROKEN)"
exit $bad
