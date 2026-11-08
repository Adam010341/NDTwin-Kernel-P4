#!/usr/bin/env bash
# Sourced by the mutation gates that run unittest suites: a gate refuses to start when a test in its
# baseline was skipped, instead of scoring that test's mutations as survivors.
#
# [Co-developed with claude code -- Adam]
#
# A gate reads "the named test stayed green" as "the tests ran and did not notice". A SKIPPED test
# did not run at all, so it can neither notice nor fail to, and a gate that does not look at skips
# says the first when the second happened: every mutation only that test catches is reported
# SURVIVED (exit 1, read as a test gap), and a gate whose mutations happen to be caught elsewhere
# exits 0 with its controls "green" on a suite that did not all run. The usual causes are the
# compiled P4 program (p4_proxy/p4_src/build/, gitignored, so absent in a fresh clone or worktree),
# whose tests skip with "not built", and an interpreter without a dependency a test guards on.
#
# Usage, right after the gate has decided that its baseline is green:
#
#     source "<this directory>/lib_gate_skips.sh"
#     gate_baseline_skips [<allowed test id ERE>...] <<<"$baseline_transcript" || exit 2
#
# The transcript is the output of one or more `python -m unittest ... -v` runs, concatenated. Every
# skipped test is listed with the reason unittest printed. A skip whose whole test id matches one of
# the EREs (each is anchored here, at both ends) is one the gate expects -- say why where it is
# passed -- and is listed as such; any other skip makes the function print what could not run and
# return 1, and the gate exits 2, "refused", which is what a gate already answers when its baseline
# cannot vouch for its tests. The first line it prints, always, is "checked N run(s), K skip(s)";
# the declared skips, then any refusal, follow it.
#
# It fails closed. It refuses when it recognises no run at all ("Ran N tests in" -- an empty or
# misrouted transcript would otherwise read as "nothing skipped"), when a run ran 0 tests, when the
# runs and the summary lines ("OK ..." / "FAILED ...") do not pair up, and when the skips it can name
# do not add up to the summaries' "(skipped=N)" totals. A transcript needs -v: the names come from
# the per-test lines, which unittest prints only then. Colour codes are ignored.
#
# A skip goes to a test only when its line says which, or when it is on the line that started that
# test or on the very next one (a docstring, or output the test printed before its result). Further
# away it is "(unnamed)", and so is a skip right after a line that already ended in a result (output
# with "ok" glued to it). That refuses some skips it could have named -- a test that printed two lines
# and then skipped -- and never declares one by guessing.
#
# Test ids are module.Class.method on every Python 3 (3.10 prints "name (module.Class)", 3.11 and
# later "name (module.Class.name)"). A setUpClass or setUpModule that skips is "<path>.setUpClass" /
# "<module>.setUpModule"; on 3.10 those print no name at all and are listed as "(unnamed)", as is
# any skip whose test this cannot tell -- a name it is not sure of is never given to a skip.

# gate_skips_parse -- stdin: transcript. stdout: one "S<TAB><id><TAB><reason>" line per skip, then
# "T<TAB><summaries' skipped total><TAB><runs><TAB><summaries><TAB><runs of 0 tests>".
gate_skips_parse() {
    awk '
        # The id of the first "name (dotted.path)" in s, or "" if there is none.
        function id_in(s,   t, name, p, last) {
            if (!match(s, /[A-Za-z_][A-Za-z0-9_]* \([A-Za-z_][A-Za-z0-9_.]*\)/)) return ""
            t = substr(s, RSTART, RLENGTH)
            name = substr(t, 1, index(t, " ") - 1)
            p = substr(t, index(t, "(") + 1)
            p = substr(p, 1, length(p) - 1)
            last = p
            while (index(last, ".") > 0) last = substr(last, index(last, ".") + 1)
            # 3.11+: the path already ends in the name. A test name with printed output glued in
            # front of it still ends in that last component.
            if (index(p, ".") > 0 && name == last) return p
            if (index(p, ".") > 0 && last ~ /^test/ && length(name) > length(last) \
                && substr(name, length(name) - length(last) + 1) == last) return p
            return p "." name
        }
        # cur is the test whose result has not been printed yet; it counts only while pending, and
        # only on its start line (start) or the next one.
        BEGIN { cur = "(unnamed)"; pending = 0; start = -1 }
        {
            line = $0
            gsub(/\033\[[0-9;]*m/, "", line)
            if (line ~ /^Ran [0-9]+ tests? in /) runs++
            if (line ~ /^Ran 0 tests in /) empty++
            if (line ~ /^(OK|FAILED)( \(|$)/) {
                sums++
                if (line ~ /skipped=[0-9]+/) total += substr(line, index(line, "skipped=") + 8) + 0
            }
            # A test starts: "name (dotted.path)" at the start of a line, alone or before " ... ".
            if (line ~ /^[A-Za-z_][A-Za-z0-9_]* \([A-Za-z_][A-Za-z0-9_.]*\)( \.\.\. |$)/) {
                cur = id_in(line)
                pending = 1
                start = NR
            }
            near = pending && NR <= start + 1
            # Where a skip status starts on this line: right after the first " ... ", or glued to
            # output the test printed after it.
            at = 0
            if ((k = index(line, " ... ")) > 0 && match(substr(line, k + 5), /skipped ["\047]/))
                at = k + 4 + RSTART
            if (at > 0) {
                # The test this line belongs to: the one still waiting for its result (the line may
                # be its docstring or a subTest), else the one this line names, else nobody.
                id = near ? cur : id_in(substr(line, 1, at - 1))
                if (id == "") id = "(unnamed)"
                printf "S\t%s\t%s\n", id, substr(line, at + 8)
                pending = 0
            } else if (line ~ /^skipped ["\047]/) {
                # Bare: a setUpClass/module skip on 3.10 (no name printed), or the result of the
                # test whose " ... " line some printed output broke.
                printf "S\t%s\t%s\n", (near ? cur : "(unnamed)"), substr(line, 9)
                pending = 0
            } else if (line ~ /(ok|FAIL|ERROR|expected failure|unexpected success)$/) {
                # A result: after " ... ", on its own line, or glued to the end of what the test
                # printed. Whatever skip comes next does not belong to this test.
                pending = 0
            }
        }
        END { printf "T\t%d\t%d\t%d\t%d\n", total, runs, sums, empty }
    '
}

# gate_baseline_skips [<allowed id ERE>...] -- stdin: transcript. Prints what it checked and the
# skips; returns 1 (after saying why) when any skip is not allowed, or when it cannot vouch for the
# transcript at all.
gate_baseline_skips() {
    local parsed tline total runs sums empty found=0 bad=0 id reason allowed re tag r
    parsed="$(gate_skips_parse)"
    tline="$(grep $'^T\t' <<<"$parsed")"
    IFS=$'\t' read -r tag total runs sums empty <<<"$tline"
    local -a refused=() named=() declared=()
    while IFS=$'\t' read -r tag id reason; do
        [[ "$tag" == S ]] || continue
        found=$((found + 1))
        named+=("$id"$'\t'"$reason")
        allowed=0
        for re in "$@"; do
            [[ "$id" =~ ^($re)$ ]] && { allowed=1; break; }
        done
        if [[ "$allowed" == 1 ]]; then
            declared+=("$id"$'\t'"$reason")
        else
            refused+=("$id"$'\t'"$reason")
            bad=$((bad + 1))
        fi
    done <<<"$parsed"
    echo "  checked ${runs:-0} run(s), $found skip(s)"
    for r in "${declared[@]}"; do
        printf '  skipped in the baseline, expected by this gate: %s\n      %s\n' "${r%%$'\t'*}" "${r#*$'\t'}"
    done
    if [[ "${runs:-0}" -eq 0 ]]; then
        echo "REFUSE: no unittest run was recognised in the baseline's transcript (no \"Ran N tests in\""
        echo "        line) -- it is empty, or its output went somewhere else -- so it cannot say what ran."
        return 1
    fi
    if [[ "${empty:-0}" -ne 0 ]]; then
        echo "REFUSE: $empty of the baseline's runs ran 0 tests -- a run that ran nothing vouches for nothing."
        return 1
    fi
    if [[ "$runs" -ne "${sums:-0}" ]]; then
        echo "REFUSE: the baseline's transcript has $runs run(s) but ${sums:-0} summary line(s) (OK/FAILED);"
        echo "        a run without its summary (or one that ended in NO TESTS RAN) cannot say what it skipped."
        return 1
    fi
    if [[ "$found" -ne "${total:-0}" ]]; then
        echo "REFUSE: the baseline's summaries count ${total:-0} skipped test(s) and $found could be"
        echo "        named -- what did not run cannot be said, so neither can what a survivor means."
        if [[ "$found" -gt 0 ]]; then
            echo "        The ones it could name:"
            for r in "${named[@]}"; do printf '    %s\n        %s\n' "${r%%$'\t'*}" "${r#*$'\t'}"; done
        fi
        return 1
    fi
    [[ "$bad" -eq 0 ]] && return 0
    echo "REFUSE: $bad test(s) in the baseline were SKIPPED -- they did not run, so a mutation only"
    echo "        they can catch would be scored a survivor, and the gate's green would cover tests"
    echo "        that never ran. Nothing was mutated. What did not run, and unittest's reason:"
    for r in "${refused[@]}"; do
        printf '    %s\n        %s\n' "${r%%$'\t'*}" "${r#*$'\t'}"
    done
    # A reason may name either cause, or both (the protobufs AND the compiled p4info): say each.
    if printf '%s\n' "${refused[@]}" | grep -qiE 'not built|compiled'; then
        echo "        If the P4 program is not compiled here (p4_proxy/p4_src/build/ is generated and"
        echo "        not in git): tools/test_workflow/l0_build_check.sh p4 builds it."
    fi
    if printf '%s\n' "${refused[@]}" | grep -qiE 'protobuf|not importable|not available in this interpreter|not installed'; then
        echo "        If this interpreter lacks what a reason names: set PROXY_PY= to one that has the"
        echo "        proxy's dependencies (p4_proxy/venv)."
    fi
    return 1
}
