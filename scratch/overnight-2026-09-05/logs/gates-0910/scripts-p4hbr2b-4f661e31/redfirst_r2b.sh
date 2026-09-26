#!/usr/bin/env bash
# Round 2b (fix/hb-followups-r2-0927) red first, each from a git archive of its commit:
#   08 at 7403eb79 (the tests, not the fix): SELF-TEST FAIL with exactly the five N2-1 cases red;
#   07 at 691d46da (the tests, not the fix): SELF-TEST FAIL with exactly the seven N3-1/N3-2 cases red;
#   the ndt serve lock-probe citation test against 3f8c2abf's tools/ndt_serve: red on README:60;
# and every one of them green at HEAD. SNAP is the read-only snapshot of 08's real switch_states
# (checked against the sha256 of the originals before anything runs).
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; SNAP="$2"; SNAPSUM="$3"; bad=0
R08=7403eb79; R07=691d46da; BASE=3f8c2abf
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
T=$(mktemp -d "${TMPDIR:-/tmp}/r2b-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
echo "HEAD $(git -C "$WT" rev-parse HEAD)"
echo "08 red-first $(git -C "$WT" rev-parse $R08); 07 red-first $(git -C "$WT" rev-parse $R07); ndt serve base $(git -C "$WT" rev-parse $BASE)"
( cd "$SNAP" && sha256sum -c --quiet "$SNAPSUM" ) && echo "  ok    the snapshot of 08's real captures matches its recorded sha256" \
    || { echo "  BAD   the snapshot does not match $SNAPSUM"; bad=1; }
at() {   # at <rev> <dir> <script>
    mkdir -p "$2/tmp"
    git -C "$WT" archive "$1" "$LIVE" tools/test_workflow/faults.sh tools/test_workflow/qdisc_snapshot.sh \
        doc/audit/2026-09-25_p4-heartbeat/spike/census_prepare.py | tar -x -C "$2"
    ln -s "$(readlink -f "$WT/p4_proxy")" "$2/p4_proxy"   # unchanged on this branch; consts imports it
    ( cd "$2" && TMPDIR="$2/tmp" SELFTEST_HB_RUN="$SNAP/run" SELFTEST_HB_PKGS="$SNAP/pkgs" \
        timeout 900 bash "$LIVE/$3" --self-test > "$2/out.txt" 2>&1; echo $? > "$2/rc" )
}
exactly_red() {   # exactly_red <label> <out> <expected red case>... -- those red, each once, nothing else
    local label="$1" out="$2" n want got; shift 2
    got="$(/usr/bin/grep -c '^  🔴 ' "$out")"
    /usr/bin/grep '^  🔴 ' "$out" | cut -c1-190 | sed 's/^/    /'
    [[ "$got" == "$#" ]] && echo "  ok    $label: $got red line(s), as many as expected" \
        || { echo "  BAD   $label: $got red line(s), $# expected"; bad=1; }
    for want in "$@"; do
        n="$(/usr/bin/grep '^  🔴 ' "$out" | /usr/bin/grep -cF -- "$want")"
        [[ "$n" == 1 ]] && echo "  ok    $label: red once -- $want" || { echo "  BAD   $label: '$want' red $n time(s)"; bad=1; }
    done
    [[ "$(tail -1 "$out")" == "SELF-TEST FAIL" ]] && echo "  ok    $label: SELF-TEST FAIL" \
        || { echo "  BAD   $label: last line '$(tail -1 "$out")'"; bad=1; }
}
green() {   # green <label> <out>
    [[ "$(tail -1 "$2")" == "SELF-TEST PASS" && "$(/usr/bin/grep -c '^  🔴 ' "$2")" == 0 ]] \
        && echo "  ok    $1: SELF-TEST PASS ($(/usr/bin/grep -c '^  ok ' "$2") ok, 0 red)" \
        || { echo "  BAD   $1: not a clean PASS"; bad=1; }
}

echo "== 08"
at "$R08" "$T/r08" 08_heartbeat.sh
exactly_red "08 at $R08" "$T/r08/out.txt" \
    "H5 sampler killed after a good start" \
    "H5 sampler with a warning on its stderr" \
    "H5 01 with no sample in its window" \
    "H5 a sampler that stopped reading for 500 s mid-06" \
    "H5 01 where the sampler stopped half-way"
at HEAD "$T/h08" 08_heartbeat.sh
green "08 at HEAD" "$T/h08/out.txt"
for c in "H5 sampler killed after a good start" "H5 sampler with a warning on its stderr" \
         "sampler_alive: a live pid that is not the sampler" "consts: the proxy's beacon interval"; do
    /usr/bin/grep -qF -- "$c" <(/usr/bin/grep '^  ok ' "$T/h08/out.txt") && echo "  ok    08 at HEAD runs: $c" \
        || { echo "  BAD   08 at HEAD has no ok line for: $c"; bad=1; }
done

echo "== 07"
at "$R07" "$T/r07" 07_roles_basic.sh
exactly_red "07 at $R07" "$T/r07/out.txt" \
    "L1 a direction never heard yet (the startup grace)" \
    "L1 every direction in the startup grace" \
    "L6/L1 on switch_state (roles), heard at once" \
    "state_until through the startup grace" \
    "never heard within the poll" \
    "no switch_state at all" \
    "L6/L1 on switch_state (unbound)"
echo "  --    of those, $(/usr/bin/grep '^  🔴 ' "$T/r07/out.txt" | /usr/bin/grep -c 'command not found') red because the live path's L6/L1 code was not yet a function the self-test could call (their discrimination is L7-24..L7-27's)"
at HEAD "$T/h07" 07_roles_basic.sh
green "07 at HEAD" "$T/h07/out.txt"
n="$(/usr/bin/grep -c '^  ok .*L1 on the real 08 capture' "$T/h07/out.txt")"
[[ "$n" == 4 ]] && echo "  ok    07 at HEAD judged all four real captures (22, 61 BAD; 35, 67 OK)" \
    || { echo "  BAD   07 at HEAD: $n real-capture ok lines, 4 expected"; bad=1; }

echo "== ndt serve lock-probe citations"
mkdir -p "$T/ns"; git -C "$WT" archive "$BASE" tools/ndt_serve | tar -x -C "$T/ns"
out="$(cd "$WT" && NDT_SERVE_UNDER_TEST="$T/ns/tools/ndt_serve" timeout 300 python3 tests/python/test_ndt_serve.py \
        RcProvenance.test_lock_probe_citations_are_lock_probe 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && /usr/bin/grep -q "README.md:60 cites ndt:9292-9307" <<<"$out" \
    && echo "  ok    on $BASE's tools/ndt_serve: red, README.md:60 cites ndt:9292-9307" \
    || { echo "  BAD   on $BASE's tools/ndt_serve: rc $rc, not the README's stale range"; bad=1; }
out="$(cd "$WT" && timeout 300 python3 tests/python/test_ndt_serve.py RcProvenance.test_lock_probe_citations_are_lock_probe 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && echo "  ok    at HEAD: green" || { echo "  BAD   at HEAD: rc $rc"; bad=1; }

echo "R2B-RED-FIRST: $([[ $bad == 0 ]] && echo 'red at each red-first tree, green at HEAD' || echo BROKEN)"
exit $bad
