#!/usr/bin/env bash
#
# The mutation gate's own refusals, and the script that adds its shards up (Cut 2 round 5, #6).
#
# [Co-developed with claude code -- Adam]
#
# tests/shell/mutate_p4_health.sh refuses, BEFORE its baseline, a MUT_SHARD with k >= n or with n larger than
# the table, a malformed one, and any run in which no mutation is selected (an ONLY_LABEL_PREFIX that matches
# nothing): such a run measured nothing and used to end rc=0. Every shard log says it is not the gate by
# itself. tests/shell/sum_p4_health_gate_shards.sh reads the n shard logs and prints the one line
#   GATE: N mutations, S survived, shards k/n ok
# only if they share one commit, tree and subject sha, every baseline, control and after-check is green, every
# rc is 0 and the counts add up to the table; anything else exits non-zero.
#
# The scripts under test are $P4_HEALTH_GATE_UNDER_TEST's (the mutation gate points it at a mutated copy);
# the default is this directory's. The gate script is only ever run into its refusals or, with PYTHON=/bin/true,
# up to its baseline (which then finds no suite and stops): nothing here runs a real baseline.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${P4_HEALTH_GATE_UNDER_TEST:-$HERE}"
GATE="$DIR/mutate_p4_health.sh"
SUM="$DIR/sum_p4_health_gate_shards.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4h-gatescripts-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CHECKS=0; FAILED=0
check() {  # check <name> <condition...>
    local name="$1"; shift
    CHECKS=$((CHECKS + 1))
    if "$@"; then echo "  ok    $name"; else echo "  FAIL  $name"; FAILED=$((FAILED + 1)); fi
}

# --- the gate script's refusals -----------------------------------------------------------------------
gate() {  # gate <out file> <VAR=value>... -- run the gate script; its output goes to <out>, its rc is printed
    local out="$1"; shift
    env "$@" PYTHON=/bin/true timeout 60 bash "$GATE" > "$out" 2>&1
    echo $?
}
refused_before_baseline() {  # refused_before_baseline <name> <message fragment> <VAR=value>...
    local name="$1" frag="$2" out="$WORK/$1.out" rc; shift 2
    rc="$(gate "$out" "$@")"
    [[ "$rc" -eq 2 ]] && grep -q "REFUSED" "$out" && grep -qF -- "$frag" "$out" && ! grep -q "BASELINE" "$out"
}
echo "--- the gate script refuses what cannot be the gate, before its baseline"
check "MUT_SHARD with k equal to n is refused" \
    refused_before_baseline kn "k must be below n" MUT_SHARD=4/4
check "MUT_SHARD with k above n is refused" \
    refused_before_baseline kgtn "k must be below n" MUT_SHARD=5/4
check "MUT_SHARD with n larger than the table is refused (a shard that would run nothing)" \
    refused_before_baseline ntoobig "larger than the" MUT_SHARD=400/500
check "MUT_SHARD with n just above the table size is refused too" \
    refused_before_baseline nplus1 "larger than the" MUT_SHARD=0/100000
check "a malformed MUT_SHARD is refused (not k/n)" \
    refused_before_baseline malformed "is not k/n" MUT_SHARD=abc
check "MUT_SHARD with n of zero is refused" \
    refused_before_baseline nzero "is not k/n" MUT_SHARD=0/0
check "MUT_SHARD with a leading zero is refused" \
    refused_before_baseline leadzero "is not k/n" MUT_SHARD=01/4
check "MUT_SHARD with a negative k is refused" \
    refused_before_baseline negative "is not k/n" MUT_SHARD=-1/4
check "an ONLY_LABEL_PREFIX that matches nothing is refused (no mutation is selected)" \
    refused_before_baseline noprefix "no mutation is selected" ONLY_LABEL_PREFIX=NO-SUCH-LABEL-
check "a shard and a prefix that together select nothing are refused" \
    refused_before_baseline both "no mutation is selected" MUT_SHARD=1/2 ONLY_LABEL_PREFIX=NO-SUCH-LABEL-

reaches_baseline() {  # reaches_baseline <name> <VAR=value>...  -- goes past the validation, stops at the stub python
    local name="$1" out="$WORK/$1.out" rc; shift
    rc="$(gate "$out" "$@")"
    [[ "$rc" -eq 2 ]] && grep -q "a suite did not run at baseline" "$out" && ! grep -q "MUT_SHARD" "$out"
}
echo "--- the control: a shard that fits goes on to its baseline"
check "MUT_SHARD=0/4 is not refused by the validation" reaches_baseline ok04 MUT_SHARD=0/4
check "MUT_SHARD=3/4 is not refused by the validation" reaches_baseline ok34 MUT_SHARD=3/4
check "a prefix that selects mutations is not refused" reaches_baseline okprefix ONLY_LABEL_PREFIX=M1.
check "no shard and no prefix (the whole gate) is not refused" reaches_baseline okall

says_not_the_gate() {  # says_not_the_gate <name> <k/n>
    local name="$1" out="$WORK/$1.out"; gate "$out" "MUT_SHARD=$2" > /dev/null
    grep -q "^NOT THE GATE BY ITSELF: shard $2" "$out"
}
echo "--- every shard says it is not the gate by itself"
check "a shard log opens with NOT THE GATE BY ITSELF: shard k/n" says_not_the_gate says 2/4
no_banner_for_the_whole_gate() {
    gate "$WORK/whole.out" > /dev/null; ! grep -q "NOT THE GATE BY ITSELF" "$WORK/whole.out"
}
check "the whole gate does not" no_banner_for_the_whole_gate

# --- the shard-sum script ------------------------------------------------------------------------------
SHA=1111111111111111111111111111111111111111
TREE=2222222222222222222222222222222222222222
SUBJ=3333333333333333
mklog() {  # mklog <file> <k> <n> <labels> <mutations> [name=value]...   -- a shard log as the gate script writes it
    local file="$1" k="$2" n="$3" labels="$4" m="$5" i; shift 5
    local sha="$SHA" head="$SHA" tree="$TREE" subj="$SUBJ" survived=0 rc=0 baseline=1 control=1 ident=1 after=1 \
        partial=0 banner=1 last="rc=0" extra=""
    local kv; for kv in "$@"; do
        case "$kv" in
            sha=*) sha="${kv#sha=}";; head=*) head="${kv#head=}";; tree=*) tree="${kv#tree=}";;
            subj=*) subj="${kv#subj=}";; survived=*) survived="${kv#survived=}";; rc=*) rc="${kv#rc=}";;
            baseline=*) baseline="${kv#baseline=}";; control=*) control="${kv#control=}";;
            ident=*) ident="${kv#ident=}";; after=*) after="${kv#after=}";; partial=*) partial="${kv#partial=}";;
            banner=*) banner="${kv#banner=}";; last=*) last="${kv#last=}";; extra=*) extra="${kv#extra=}";;
        esac
    done
    {
        echo "commit $sha"
        echo "gate       : tests/shell/mutate_p4_health.sh"
        echo "cwd        : /x"
        echo "interpreter: /x/python3.8 (3.8.20)"
        echo "subject    : /x/tools/p4_health"
        echo "HEAD       : $head (commit)"
        echo "tree       : $tree (git tree of tools/p4_health at HEAD)$extra"
        echo "subject sha: $subj"
        echo
        [[ "$banner" -eq 1 ]] && { echo "NOT THE GATE BY ITSELF: shard $k/$n ($m of $labels mutations; the gate is the sum of all $n shards)"; echo; }
        echo "=== BASELINE: every suite green against the real files ==="
        [[ "$baseline" -eq 1 ]] && echo "  ok       baseline green"
        for ((i = 0; i < m; i++)); do
            echo; echo "=== M$i. a mutation ==="; echo "  anchor occurrences: 1"; echo "  ✅ caught by test_x"
        done
        [[ "$survived" -gt 0 ]] && { echo "  🔴 SURVIVED -- every suite stayed green"; }
        echo; echo "=== NEGATIVE CONTROL: comment-only edit must stay GREEN ==="; echo "  anchor occurrences: 1"
        [[ "$control" -eq 1 ]] && echo "  ✅ green: the suites do not react to a comment"
        echo; echo "--- was the original written? ---"
        [[ "$ident" -eq 1 ]] && echo "  byte-identical  tools/p4_health  0123456789abcdef"
        [[ "$after" -eq 1 ]] && echo "  suites green against the real files"
        echo
        echo "$m mutations, $survived survived"
        echo "SHARD $k/$n of $labels mutations in the table"
        [[ "$banner" -eq 1 ]] && echo "NOT THE GATE BY ITSELF: shard $k/$n"
        [[ "$partial" -eq 1 ]] && echo "PARTIAL RUN: only labels starting X -- this is not the gate"
        echo "$last"
    } > "$file"
    : "$rc"
}
good_set() {  # good_set <dir> <n> <labels> -- n consistent shard logs
    local d="$1" n="$2" labels="$3" k m
    mkdir -p "$d"
    for ((k = 0; k < n; k++)); do
        m=$(( k < labels ? (labels - k + n - 1) / n : 0 ))
        mklog "$d/s$k.log" "$k" "$n" "$labels" "$m"
    done
}
sum() { bash "$SUM" "$@"; }
sum_rc() { sum "$@" > "$WORK/sum.out" 2>&1; echo $?; }

echo "--- the shard-sum script"
good_set "$WORK/good" 4 10
check "four good shards of ten: the one GATE line, rc 0" \
    bash -c 'out="$(bash "$1" "$2"/s*.log 2>&1)"; rc=$?; [ "$rc" -eq 0 ] && [ "$out" == "GATE: 10 mutations, 0 survived, shards 4/4 ok" ]' _ "$SUM" "$WORK/good"
good_set "$WORK/good1" 1 7
check "a single shard of the whole table (1/1) is the gate" \
    bash -c 'out="$(bash "$1" "$2"/s0.log 2>&1)"; rc=$?; [ "$rc" -eq 0 ] && [ "$out" == "GATE: 7 mutations, 0 survived, shards 1/1 ok" ]' _ "$SUM" "$WORK/good1"
check "the order of the logs on the command line does not matter" \
    bash -c 'out="$(bash "$1" "$2"/s3.log "$2"/s1.log "$2"/s0.log "$2"/s2.log 2>&1)"; [ "$out" == "GATE: 10 mutations, 0 survived, shards 4/4 ok" ]' _ "$SUM" "$WORK/good"

# each defect: a good set of four with ONE shard (s2) changed; the script must say no, say why, and print no GATE line
refuses() {  # refuses <name> <reason fragment> <mklog option>...  -- s2 is made with the options
    local name="$1" frag="$2" d="$WORK/bad-$1"; shift 2
    good_set "$d" 4 10
    mklog "$d/s2.log" 2 4 10 2 "$@"
    refused_set "$d" "$frag" "$d"/s*.log
}
refused_set() {  # refused_set <name dir> <reason fragment> <logs>...
    local frag="$2"; shift 2
    local out rc
    out="$(bash "$SUM" "$@" 2>&1)"; rc=$?
    [[ "$rc" -ne 0 ]] && ! grep -q "^GATE:" <<<"$out" && grep -q "^NOT THE GATE:" <<<"$out" && grep -qF -- "$frag" <<<"$out"
}
echo "--- ... and it refuses each of these, with a reason"
check "a shard of another commit (first line and HEAD line)" refuses othercommit "commits differ" sha=4444444444444444444444444444444444444444 head=4444444444444444444444444444444444444444
check "a shard whose first line is not the commit HEAD says" refuses firstline "first line" sha=4444444444444444444444444444444444444444
check "a shard of another tools/p4_health tree" refuses othertree "trees differ" tree=5555555555555555555555555555555555555555
check "a shard of another subject sha" refuses othersubj "subject shas differ" subj=6666666666666666
check "a shard of a tree with uncommitted changes" refuses uncommitted "UNCOMMITTED" "extra= +UNCOMMITTED changes in the subject or its suites"
check "a shard whose baseline is not green" refuses nobaseline "baseline" baseline=0
check "a shard whose negative control is not green" refuses nocontrol "negative control" control=0
check "a shard that does not say the original is byte-identical" refuses noident "byte-identical" ident=0
check "a shard whose after-check is not green" refuses noafter "suites green against the real files" after=0
check "a shard that survived a mutation, even with rc 0 written" refuses survivor "survived" survived=1
check "a shard that ended rc=1" refuses rc1 "rc=1" last=rc=1
check "a shard that ended rc=2" refuses rc2 "rc=2" last=rc=2
check "a shard whose log does not end in an rc line" refuses norc "does not end in rc=" last="82 mutations, 0 survived"
check "a partial run" refuses partial "PARTIAL" partial=1
check "a shard without the not-the-gate banner (not a log of this script)" refuses nobanner "NOT THE GATE BY ITSELF" banner=0
refuses_count() {  # s2 reports 3 mutations where its share is 2
    local d="$WORK/bad-count"; good_set "$d" 4 10; mklog "$d/s2.log" 2 4 10 3
    refused_set "$d" "add up" "$d"/s*.log
}
check "a shard that ran more mutations than its share (the counts no longer add up)" refuses_count
refuses_labels() {  # s2 thinks the table has 11 mutations
    local d="$WORK/bad-labels"; good_set "$d" 4 10; mklog "$d/s2.log" 2 4 11 3
    refused_set "$d" "size of the table" "$d"/s*.log
}
check "shards that disagree on the size of the table" refuses_labels
refuses_missing() {
    local d="$WORK/bad-missing"; good_set "$d" 4 10; rm "$d/s3.log"
    refused_set "$d" "shards 0..3" "$d"/s*.log
}
check "three shards of four" refuses_missing
refuses_dup() {
    local d="$WORK/bad-dup"; good_set "$d" 4 10; cp "$d/s1.log" "$d/s1b.log"; rm "$d/s3.log"
    refused_set "$d" "more than once" "$d"/s0.log "$d"/s1.log "$d"/s1b.log "$d"/s2.log
}
check "the same shard twice in place of another" refuses_dup
refuses_mixed_n() {
    local d="$WORK/bad-n"; good_set "$d" 4 10; mklog "$d/s3.log" 3 5 10 2
    refused_set "$d" "different n" "$d"/s*.log
}
check "shards of different n" refuses_mixed_n
refuses_zero() {  # an empty shard (a k beyond the table) is a result of nothing
    local d="$WORK/bad-zero"; good_set "$d" 12 10
    refused_set "$d" "larger than the table" "$d"/s*.log
}
check "n larger than the table (two shards would have run nothing)" refuses_zero
refuses_refused_log() {  # a log of a run the gate script refused: no mutations section at all
    local d="$WORK/bad-refused"; good_set "$d" 4 10
    printf 'commit %s\nREFUSED: baseline is red: x\nrc=2\n' "$SHA" > "$d/s2.log"
    refused_set "$d" "REFUSED" "$d"/s*.log
}
check "a log of a refused run" refuses_refused_log
no_logs() { out="$(bash "$SUM" 2>&1)"; rc=$?; [[ "$rc" -ne 0 ]] && grep -q "^NOT THE GATE:" <<<"$out"; }
check "no logs at all is refused, with a reason" no_logs
missing_log() { out="$(bash "$SUM" /no/such/log 2>&1)"; rc=$?; [[ "$rc" -ne 0 ]] && grep -q "^NOT THE GATE:" <<<"$out"; }
check "a log that does not exist is refused, with a reason" missing_log

echo
echo "Ran $CHECKS checks, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
