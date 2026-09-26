#!/usr/bin/env bash
# Worker pb5prep, phase 6: per-test-id verdict diffs, <A> vs <B>, for the three suites.
#   phase6_verdictdiff.sh <label A> <label B>
# Reads the TSVs phase3_suites.sh wrote at this HEAD. A missing TSV is RED, never "0 lines"
# (REQ's compare_verbose v1 printed 0 for a suite that never loaded). The WHOLE diff is saved.
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
A="${1:?}"; B="${2:?}"; fail=0
for suite in p4_proxy_suite p4_exercise_suite p4_exercise_suite_emptyhome; do
    ta="$L/${suite}_verdicts_$A.pb5prep-$SHA.tsv"; tb="$L/${suite}_verdicts_$B.pb5prep-$SHA.tsv"
    f=$(new_log "${suite}_verdictdiff_${A}_vs_${B}" "per-test-id verdicts, $A vs $B") || exit 2
    {
      if [[ ! -s "$ta" || ! -s "$tb" ]]; then echo "RED: missing verdict file ($ta: $( [[ -s $ta ]] && echo ok || echo MISSING); $tb: $( [[ -s $tb ]] && echo ok || echo MISSING))"; echo "rc=1"
      else
        echo "# $A: $(wc -l < "$ta") ids, $(cut -f2 "$ta" | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
        echo "# $B: $(wc -l < "$tb") ids, $(cut -f2 "$tb" | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
        echo "# non-ok verdicts in $A:"; grep -v $'\tok$' "$ta" | sed 's/^/#   /'
        diff "$ta" "$tb"; d=$?
        n=$(diff "$ta" "$tb" | grep -c '^[<>]')
        echo "# diff lines (<,>): $n"
        echo "rc=$d"
      fi; } >> "$f" 2>&1
    tail -2 "$f" | tr '\n' ' '; echo " <- ${suite} $A vs $B"
    [[ "$(tail -1 "$f")" == "rc=0" ]] || fail=1
done
exit $fail
