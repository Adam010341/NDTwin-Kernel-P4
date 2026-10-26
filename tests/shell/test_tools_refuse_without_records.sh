#!/usr/bin/env bash
#
# Kept lab tools whose real runs read a record that is not part of the public tree must refuse
# safely without it.
#
# [Co-developed with claude code -- Adam]
#
# Some files under doc/audit are records even though a kept tool reads them on a real run: a
# round's registration (PREREG.md, read for its EVIDENCE-BASIS sentinel and its force-matrix
# transcript) and a raw-log index (external_survey_34.tsv, the frozen list of rounds the survey
# compares). They stay out of the public tree. This suite checks what a clone without them does:
#
#   * run_f5.sh arm and run_e.sh ladder, as dry runs, refuse at the registration check;
#   * external_survey.py with no manifest argument refuses as unreadable (rc 2);
#
# and, as controls, that the same runs get past the registration check when they are given a
# registration-shaped file, so each refusal above is the registration check and not something
# earlier. Everything runs in a temp copy of doc/audit with the records removed, with sudo, curl,
# ndt, mnexec, tc, ip, iperf3, ping, nc and ssh replaced by stubs that record and fail; the suite
# also checks that no stub was called.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
E_REL=doc/audit/2026-08-31_sampling-ceiling-after-merge
F_REL=doc/audit/2026-08-31_f5-fine-grid-round
SV_REL=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
PY="${PY:-python3}"

PASS=0
FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"; PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"; echo "           expected: [$expected]"; echo "           actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}
has() {   # has <what> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then echo "  ok       $1"; PASS=$((PASS + 1))
    else echo "  FAILED   $1"; echo "           missing: [$2]"; printf '%s\n' "$3" | tail -5 | sed 's/^/           | /'; FAIL=$((FAIL + 1)); fi
}
lacks() {   # lacks <what> <needle> <haystack>
    if [[ "$3" != *"$2"* ]]; then echo "  ok       $1"; PASS=$((PASS + 1))
    else echo "  FAILED   $1"; echo "           present: [$2]"; FAIL=$((FAIL + 1)); fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/refuse-without-records-XXXXXX")"
trap 'rm -rf "$T"' EXIT
# The tracked doc/audit tree (a checkout-shaped copy: round.env finds KERNEL_DIR=$T/tree from its own
# path), then the records removed, as in a public clone.
mkdir -p "$T/tree"
(cd "$REPO" && git ls-files -z -- doc/audit | tar --null -T - -cf -) | tar -xf - -C "$T/tree"
rm -f "$T/tree/$E_REL/PREREG.md" "$T/tree/$F_REL/PREREG.md" "$T/tree/$SV_REL/external_survey_34.tsv"
check "the copy has the three tools and none of the three records" "yes no no no" \
      "$( [[ -f "$T/tree/$F_REL/run_f5.sh" && -f "$T/tree/$E_REL/run_e.sh" && -f "$T/tree/$SV_REL/external_survey.py" ]] && echo yes || echo no) \
$( [[ -e "$T/tree/$E_REL/PREREG.md" ]] && echo yes || echo no) $( [[ -e "$T/tree/$F_REL/PREREG.md" ]] && echo yes || echo no) \
$( [[ -e "$T/tree/$SV_REL/external_survey_34.tsv" ]] && echo yes || echo no)"

STUB="$T/stub"; mkdir -p "$STUB"
for c in sudo curl ndt mnexec tc ip iperf3 ping nc ssh; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/stub.log"\nexit 97\n' "$c" "$T" > "$STUB/$c"; chmod +x "$STUB/$c"
done
: > "$T/stub.log"
# A dry run in an operator-shaped environment: nothing inherited but PATH (stubs first), HOME and the
# temp dir; the round's own round.env supplies KERNEL_DIR, ROUND and NDT_OWNER.
dry() {   # dry <round rel> <NAME=value>... -- <script and args>
    local rel="$1"; shift
    local envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
    (cd "$T/tree/$rel" && env -i PATH="$STUB:$PATH" HOME="$HOME" TMPDIR="$T" LANG=C.UTF-8 DRY_RUN=1 \
        "${envs[@]}" timeout 120 bash "$@" 2>&1)
}
printf 'EVIDENCE-BASIS: COMPLETE\n' > "$T/registration_complete.txt"

echo "F5: run_f5.sh arm, dry, in a tree without its registration"
out="$(dry "$F_REL" F5_HARNESS_SUBRUN=1 -- ./run_f5.sh arm)"
has   "🔴 refused at the EVIDENCE-BASIS check"          "REFUSE: the registration reports EVIDENCE-BASIS: <absent>" "$out"
lacks "  and nothing ran past it"                       "complete ->" "$out"
out="$(dry "$F_REL" -- ./run_f5.sh arm)"
has   "🔴 without the sub-run flag: refused at the transcript check" "the force transcript embedded in the registration is out of date" "$out"
out="$(dry "$F_REL" F5_HARNESS_SUBRUN=1 PREREG_FILE="$T/tree/$F_REL/selftest_registration.txt" -- ./run_f5.sh arm)"
lacks "  control: given a registration-shaped file, the EVIDENCE-BASIS check passes" "EVIDENCE-BASIS:" "$out"
has   "  control: and the dry arm runs to its end"      "complete ->" "$out"

echo "E: run_e.sh ladder, dry, in a tree without its registration"
out="$(dry "$E_REL" LADDER=16 REPS=1 -- ./run_e.sh ladder)"
has   "🔴 refused at the EVIDENCE-BASIS check"          "REFUSE: the registration reports EVIDENCE-BASIS: <absent>" "$out"
out="$(dry "$E_REL" LADDER=16 REPS=1 PREREG_FILE="$T/registration_complete.txt" -- ./run_e.sh ladder)"
lacks "  control: given a registration that says COMPLETE, the EVIDENCE-BASIS check passes" "EVIDENCE-BASIS:" "$out"
has   "  control: and the dry ladder runs to its end"   "=== ladder complete ->" "$out"

echo "external_survey.py without its manifest"
mkdir -p "$T/prep/runs"
out="$(cd "$T" && "$PY" "$T/tree/$SV_REL/external_survey.py" "$T/prep" 2>&1; echo "RC=$?")"
check "🔴 refused as unreadable: rc 2" "RC=2" "$(grep -o 'RC=[0-9]*' <<<"$out")"
has   "  naming the manifest it could not read"         "external_survey_34.tsv" "$out"

check "🔴 no stubbed lab, network or sudo command was called" "" "$(cat "$T/stub.log")"

echo
if [ "$FAIL" -gt 0 ]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
