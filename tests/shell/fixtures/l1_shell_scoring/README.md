# Fixtures for `tests/shell/test_l1_shell_scoring.sh`, group R

[Co-developed with claude code -- Adam]

Each `rNN_*.sh` here is a minimal suite TEXT: group C's reader (`render_prints` + `corpus_verdict`)
reads it exactly as it reads a suite in `tests/shell/`, and group R asserts the verdict. None of
them is ever run -- they live outside the `tests/shell/test_*.sh` glob on purpose, so neither the
L1 lane nor group C's corpus loop picks them up.

Why they exist (2026-09-27, the opus judge's NOTEs A, B, F, G, H and I on `1d5180ce`): group C's
rules were only ever checked against the corpus as it happened to be, so a reading the corpus did
not exercise could be wrong in either direction without anything going red. Each fixture pins one
reading; `tests/shell/mutate_l1_shell_scoring.sh` breaks each reading and must see its fixture's
check go red.

| fixture | the reading | verdict |
|---|---|---|
| r01 | a function's summary whose every call is `summary; exit 1` (A) | failure path (`call`) |
| r02 | r01 plus a bare `summary` call | nonzero |
| r03 | a function that `exit 1`s later in its own body (A) | failure path (`body`) |
| r04 | `echo ...; (( FAIL )) && exit 1` (B) | nonzero |
| r05 | `echo ...; [[ $FAIL -eq 0 ]] && exit 0; exit 1` (B) | nonzero |
| r06 | `echo ... \|\| exit 1` | nonzero |
| r07 | `then echo ... && exit 1; fi` | failure path (`2a`) |
| r08 | `summary(){ echo ...; }` -- no space before `{` (F) | nonzero |
| r09 | prints behind case patterns (F) | nonzero |
| r10 | a summary written to a file (G) | zero |
| r11 | a summary written to stderr (G) | nonzero |
| r12 | `echo ... \| tee -a "$LOG"; exit 1` (G) | failure path (`2a`) |
| r13 | `{ echo ...; }; exit 1` (H) | failure path (`2a`) |
| r14 | `then echo ...; else exit 1; fi` | nonzero |
| r15 | `case ... in 0) echo ... ;; *) exit 1 ;; esac` | nonzero |
| r16 | `echo ...; if (( FAIL )); then exit 1; fi` | nonzero |

The first line of each is a comment and the line numbers in group R's expected verdicts count it:
edit a fixture and its check's expected line moves with it.
