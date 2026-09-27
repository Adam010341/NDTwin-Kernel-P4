#!/usr/bin/env bash
# redfirst_stalefix.sh <worktree> <keep dir> -- fix/stale-suites-0927's fix round (the opus judge's B1,
# N1-N5 on d2a9d641), red first at d2a9d641, every output KEPT under <keep dir>. [Co-developed with claude code -- Adam]
#   B1  group C of d2a9d641 and of HEAD on one corpus and its mutants: the judge's four counterexamples
#       (M1 on test_faults_topo_pid.sh:442 and test_ndtwin_lab_config.sh:293, test_ndt_down_stops_only_ours.sh
#       :245 deleted, test_mutate_gate_dead_mutant.sh:299 broken) -- only the target suite's C line is
#       read -- and M0, the whole corpus unmutated
#   N4  three $(( )) the renderer cannot evaluate (09, empty, **) in test_faults.sh's summary: what
#       d2a9d641's group C says, and HEAD's ("instrument failed")
#   N1  NDT_SAMPLING_RAW_DIR exported, then round.env sourced: plot_figures.RAW at d2a9d641, and at HEAD
#   N2  a tree WITH the real raw t008_poll (read from audit-raw into a temp dir) and the suite's
#       override broken: d2a9d641's suite stays green, HEAD's is red on case 1b; unbroken, HEAD green
#   N3  the fixture's first row now, and the real trace's sha256 in audit-raw and in the main checkout
set -u
WT="$1"; K="$2"; bad=0; BASE=d2a9d641; cd "$WT" || exit 2; mkdir -p "$K"
T=$(mktemp -d "${TMPDIR:-/tmp}/stalefix-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
echo "HEAD $(git rev-parse HEAD); base $(git rev-parse $BASE)"

echo "== B1: the four counterexamples, group C at $BASE and at HEAD"
mkc() {   # mkc <dir> [python mutation of one corpus file: <rel> <expr>] -- a corpus: HEAD's tests/shell and tools/test_workflow
    rm -rf "$1"; mkdir -p "$1"; git archive HEAD tests/shell tools/test_workflow | tar -x -C "$1"
    git show "$BASE:tests/shell/test_l1_shell_scoring.sh" > "$1/tests/shell/.base-l1.sh"
    cp tests/shell/test_l1_shell_scoring.sh "$1/tests/shell/.head-l1.sh"
    [[ $# -lt 3 ]] && return 0
    python3 - "$1/$2" "$3" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read(); b = s
ns = {"s": s}; exec(expr, ns); s = ns["s"]
assert s != b, "the mutation did not change " + p
open(p, "w").write(s)
PY
}
cl() {   # cl <corpus> <base|head> <target suite> <tag> -> "ok|FAILED<TAB>actual"
    ( cd "$1" && timeout 600 bash "tests/shell/.$2-l1.sh" < /dev/null > "$K/b1_$4_$2.out" 2>&1 )
    awk -v w="  FAILED   C  $3 prints" -v o="  ok       C  $3 prints" -v o2="  ok       C  $3's" -v w2="  FAILED   C  $3's" '
        index($0, w) == 1 || index($0, w2) == 1 {f = 1; next}
        index($0, o) == 1 || index($0, o2) == 1 {print "ok"; exit}
        f && /^ +actual:/ {sub(/^ +actual: +/, ""); print "FAILED\t" $0; exit}' "$K/b1_$4_$2.out"
}
declare -A E
row() {   # row <tag> <target> <rel> <expr> <expected at HEAD: ok|red:<text>>
    local tag="$1" tg="$2" rel="$3" expr="$4" want="$5" b h
    mkc "$T/c-$tag" "$rel" "$expr" || { nok "$tag: the mutation did not apply"; return; }
    b="$(cl "$T/c-$tag" base "$tg" "$tag")"; h="$(cl "$T/c-$tag" head "$tg" "$tag")"
    echo "    $tag ($tg):  $BASE ${b%%$'\t'*}   HEAD ${h%%$'\t'*}  -- ${h#*$'\t'}"
    [[ "$b" == ok ]] && ok "  at $BASE it SURVIVES (group C green on $tg)" || nok "  at $BASE: $b"
    case "$want" in
        ok)    [[ "$h" == ok ]] && ok "  at HEAD it still survives -- the KNOWN LIMITATION, recorded" || nok "  at HEAD: $h" ;;
        red:*) [[ "$h" == FAILED*"${want#red:}"* ]] && ok "  at HEAD KILLED, by: ${want#red:}" || nok "  at HEAD: $h" ;;
    esac
}
row M5-topo_pid test_faults_topo_pid.sh tests/shell/test_faults_topo_pid.sh \
    's = s.replace("echo \"Ran $((PASS+FAIL)) checks, all passed${SKIP:+ ($SKIP skipped)}\"", "echo \"everything is fine\"")' \
    "red:exit <non-zero> after it on the same line"
row M1-lab_config test_ndtwin_lab_config.sh tests/shell/test_ndtwin_lab_config.sh \
    's = s.replace("\necho \"Ran $((PASS+FAIL)) checks, all passed\"", "\necho \"everything is fine\"")' \
    "red:exit <non-zero> after it on the same line"
row M6-down_stops test_ndt_down_stops_only_ours.sh tests/shell/test_ndt_down_stops_only_ours.sh \
    's = s.replace("printf \x27\\n\x27\necho \"Ran $((PASS+FAIL)) checks, $FAIL failed\"\n", "printf \x27\\n\x27\n")' \
    "red:exit <non-zero> after it on the same line"
row dead_mutant test_mutate_gate_dead_mutant.sh tests/shell/test_mutate_gate_dead_mutant.sh \
    'i = s.rindex("echo \"Ran $((PASS+FAIL)) checks, $FAIL failed\""); s = s[:i] + "echo \"everything is fine\"" + s[i + len("echo \"Ran $((PASS+FAIL)) checks, $FAIL failed\""):]' \
    ok
echo "  -- M0, the corpus unmutated:"
mkc "$T/c-M0"
for v in base head; do
    ( cd "$T/c-M0" && timeout 600 bash "tests/shell/.$v-l1.sh" < /dev/null > "$K/b1_M0_$v.out" 2>&1 ); r=$?
    echo "    $v: rc $r, $(tail -1 "$K/b1_M0_$v.out"); group C ok $(/usr/bin/grep -cE '^  ok +C  ' "$K/b1_M0_$v.out"), red $(/usr/bin/grep -cE '^  FAILED +C  ' "$K/b1_M0_$v.out")"
    [[ $v == head ]] && { [[ $r == 0 && "$(/usr/bin/grep -cE '^  ok +C  ' "$K/b1_M0_$v.out")" == "$(ls "$T/c-M0"/tests/shell/test_*.sh | wc -l)" ]] \
        && ok "HEAD's group C green on every suite of the corpus ($(ls "$T/c-M0"/tests/shell/test_*.sh | wc -l))" || nok "HEAD's group C on the unmutated corpus: rc $r"; }
done

echo "== N4: a \$(( )) the renderer cannot evaluate"
for adv in 'PASS + 09' ' ' 'PASS**PASS**PASS'; do
    tag="adv-$(tr -c 'A-Za-z0-9' '_' <<<"$adv")"
    mkc "$T/c-$tag" tests/shell/test_faults.sh "s = s.replace('echo \"Ran \$((PASS + FAIL)) checks, all passed\"', 'echo \"Ran \$(($adv)) checks, all passed\"')"
    b="$(cl "$T/c-$tag" base test_faults.sh "$tag")"; h="$(cl "$T/c-$tag" head test_faults.sh "$tag")"
    echo "    \$(($adv)):  $BASE: ${b//$'\t'/ -- }"
    echo "    \$(($adv)):  HEAD: ${h//$'\t'/ -- }"
    [[ "$h" == FAILED*"instrument failed"* ]] && ok "  HEAD: red as an instrument failure" || nok "  HEAD: $h"
    [[ "$b" != *"instrument"* ]] && ok "  $BASE: not an instrument failure (read as: ${b:-nothing})" || nok "  $BASE: $b"
done

echo "== N1: an inherited NDT_SAMPLING_RAW_DIR, then round.env"
for rev in "$BASE" HEAD; do
    d="$T/n1-$rev"; mkdir -p "$d"; git archive "$rev" doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env doc/audit/2026-08-20_sampling-rate-and-cpu/plot_figures.py | tar -x -C "$d"
    raw="$( export NDT_SAMPLING_RAW_DIR="$T/somewhere-else"
            . "$d/doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env" >/dev/null 2>&1
            cd "$d/doc/audit/2026-08-20_sampling-rate-and-cpu" && PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" -c 'import plot_figures; print(plot_figures.RAW)' 2>&1 )"
    echo "    $rev: plot_figures.RAW = $raw"
    if [[ "$rev" == "$BASE" ]]; then [[ "$raw" == "$T/somewhere-else" ]] && ok "  at $BASE the round would read the inherited directory" || nok "  at $BASE: $raw"
    else [[ "$raw" == "$d/doc/audit/2026-08-20_sampling-rate-and-cpu/raw" ]] && ok "  at HEAD round.env clears it: the round's own raw/" || nok "  at HEAD: $raw"; fi
done

echo "== N2: a tree that HAS the real raw, and a broken override"
mkdir -p "$T/real"
for f in t008_poll_twin.jsonl t008_poll_client.json; do git show "audit-raw:doc/audit/2026-08-20_sampling-rate-and-cpu/raw/$f" > "$T/real/$f"; done
for rev in "$BASE" HEAD; do
    d="$T/n2-$rev"; mkdir -p "$d"
    git archive "$rev" tests/shell doc/audit/2026-08-31_sampling-ceiling-after-merge doc/audit/2026-08-20_sampling-rate-and-cpu doc/audit/2026-08-25_sampling-rounds | tar -x -C "$d"
    mkdir -p "$d/doc/audit/2026-08-20_sampling-rate-and-cpu/raw"; cp "$T/real"/* "$d/doc/audit/2026-08-20_sampling-rate-and-cpu/raw/"
    s="$d/tests/shell/test_gate_exit_code_not_tee.sh"
    for arm in broken intact; do
        [[ $arm == broken ]] && { python3 - "$s" "$s.broken" <<'PY'
import sys
s = open(sys.argv[1]).read(); a = 'export NDT_SAMPLING_RAW_DIR="$T/raw"'
assert s.count(a) == 1
open(sys.argv[2], "w").write(s.replace(a, 'export NDT_SAMPLING_RAW_DIR_BROKEN="$T/raw"'))
PY
        run="$s.broken"; } || run="$s"
        ( cd "$d" && timeout 300 bash "$run" < /dev/null > "$K/n2_${rev}_$arm.out" 2>&1 ); r=$?
        echo "    $rev, override $arm: rc $r, $(tail -1 "$K/n2_${rev}_$arm.out" | sed 's/^ *//')$(/usr/bin/grep -A2 'case 1b' "$K/n2_${rev}_$arm.out" | sed -n 's/^ *actual: */ -- 1b read: /p')"
        case "$rev,$arm" in
            "$BASE",broken) [[ $r == 0 ]] && ok "  at $BASE, override broken, the real trace read: still GREEN -- vacuous" || nok "  at $BASE broken: rc $r" ;;
            HEAD,broken)    [[ $r != 0 ]] && /usr/bin/grep -q '^  FAILED   case 1b ' "$K/n2_${rev}_$arm.out" \
                                && ok "  at HEAD, override broken: red on case 1b" || nok "  at HEAD broken: rc $r" ;;
            HEAD,intact)    [[ $r == 0 ]] && ok "  at HEAD, override intact, real raw present: green, the fixture read" || nok "  at HEAD intact: rc $r" ;;
        esac
    done
done

echo "== N3: the fixture's first row, and the real trace's sha256"
echo "    fixture row 1: $(head -1 tests/shell/fixtures/gate_exit_code_not_tee/t008_poll_twin.jsonl)"
echo "    real row 1:    $(head -1 "$T/real/t008_poll_twin.jsonl")"
ra="$(sha256sum "$T/real/t008_poll_twin.jsonl" | cut -d' ' -f1)"
mc=/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu/raw/t008_poll_twin.jsonl
rm_="$( [[ -r "$mc" ]] && sha256sum "$mc" | cut -d' ' -f1 || echo absent )"
echo "    sha256 audit-raw:      $ra"
echo "    sha256 main checkout:  $rm_  ($mc, read only)"
[[ "$ra" == "$rm_" ]] && ok "the main checkout's t008_poll_twin.jsonl is audit-raw's, byte for byte" || nok "they differ"
[[ "$(head -1 tests/shell/fixtures/gate_exit_code_not_tee/t008_poll_twin.jsonl)" != *1787658157.534* ]] && ok "no row of the fixture is the real trace's first" || nok "the first row is still the real one's"
echo "STALEFIX-RED-FIRST: $([[ $bad == 0 ]] && echo "B1, N1, N2, N4 red at $BASE, green at HEAD; the SELFTEST_INNER shape recorded as a limitation" || echo BROKEN)"
exit $bad
