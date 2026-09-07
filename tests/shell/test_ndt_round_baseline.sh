#!/usr/bin/env bash
#
# Does `ndt status` notice that the P4 host knob has not been put back?
#
# [Co-developed with claude code -- Adam]
#
# 09-05 R7 finding I-3 (rounds/03-R7-reconciler.md), decided 09-07 (grill §4D round 10).
# `p4_proxy/mininet/host_count_override` was working tree 4 / HEAD 128 that night -- the
# LAB-RULES red line, because restoring it means WRITING 4, and `git checkout --` gives 128.
# R4 wrote 128 into it for a 128-host round, and BOTH restoration instruments went blind at
# once, because both derived their answer from git dirtiness:
#
#     git status --porcelain | wc -l          22  ->  21     (the machine LEFT its baseline
#                                                             and the number went DOWN)
#     ndt status:
#       code  68c1dde4  +22 file(s) with uncommitted changes
#                       1 of them can change behaviour:
#                       p4_proxy/mininet/host_count_override      <- this block DISAPPEARED
#
# Groups 8-12 are the 09-07 follow-up, after the row was watched working on a live fabric
# (rounds/08-round2.md:146, arm lw16 step D, 04:36, OVS 4): it printed
#     knob baseline  8 -- this round started at 128 (at 04:36:41): NOT RESTORED
# in red, and `ndt status --check` returned 0. Adam's decisions of that morning (grill §4E
# round 3): E-9, that sentence is a --check problem and the rc goes red on it; E-11, `ndt
# release` retires .test_run/round.baseline to .prev, so a round that has ended stops being
# compared against. Both are about what the COMMAND does with this row's answer, so those
# groups drive cmd_status/cmd_release whole rather than calling one row.
#
# Groups 13-16 are the correction Adam made that evening (18:1x, R3-NDT §7-1 and §7-2), once
# E-9 was read against the standard P4 round: `ndt up p4 4` writes this knob through, so a
# round claimed at 128 was NOT RESTORED from its own second command onward and every `--check`
# in it exited 1. E-9b splits the row three ways -- back at the start, holding what `ndt up p4`
# wrote (a warning), or holding something nobody announced (still red, still a problem) -- and
# E-11b moves the deadline to `ndt release`, which now refuses while the knob is not back and
# takes `--force` as the signature for releasing anyway.
#
# The value was still printed in the configuration section. What vanished was the WARNING, at
# the moment the knob held the value that changes the most behaviour. Two guards, one flawed
# signal: not redundant, blind together. (MEMORY: "the clean version is the one you have to go
# back and check".)
#
# 🔴 THREE DIRECTIONS, because "warn about the knob" has wrong answers that look like fixes:
#   * warn whenever the value is not 4 -- group 3 is the 128-host round that is SUPPOSED to be
#     running at 128, and it must be able to say "this is what this round started with";
#   * warn only when git calls the file dirty -- group 1 is the finding itself, and the file is
#     CLEAN there;
#   * count the dirty files instead of naming them -- group 5: the count moves the wrong way,
#     and no count can express "this path left the set".
#
# Offline: a throwaway git repository in a temp dir. No lab, no kernel, no sudo, no network.
#
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_ndt_round_baseline.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; exit 2; }
for sib in ports.sh sudo_surface.sh; do
    [[ -r "$(dirname "$NDT")/$sib" ]] || { echo "ndt needs $sib beside it; not at $(dirname "$NDT")/$sib"; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "this suite needs git"; exit 2; }

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: [$2]  actual: [$3]"; }
has()   { grep -qF -- "$2" <<<"$3" && t_ok "$1" || t_bad "$1" "no match for '$2'"; }
hasnt() { grep -qF -- "$2" <<<"$3" && t_bad "$1" "unexpected '$2' in the output" || t_ok "$1"; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-round-base-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# --- the 09-05 machine, in miniature ------------------------------------------------------
# HEAD carries 128 (that is what is committed on trunk), the working tree carries 4 (that is
# what the night was actually running). Reproducing that pairing is the whole point: it is the
# state in which "restore" and "match HEAD" are OPPOSITE instructions.
git -C "$FIX" init -q 2>/dev/null || { echo "git init failed"; exit 2; }
git -C "$FIX" config user.email fixture@example.invalid
git -C "$FIX" config user.name  fixture
mkdir -p "$FIX/p4_proxy/mininet" "$FIX/.test_run" "$FIX/src"
KNOB="$FIX/p4_proxy/mininet/host_count_override"
printf '128\n' > "$KNOB"
printf 'baseline\n' > "$FIX/src/Thing.cpp"
printf 'readme\n'   > "$FIX/README.md"
# As the real repo does (.gitignore:21). It matters here: the round baseline lives under
# .test_run/, and an untracked baseline file would add a line to `git status --porcelain` --
# the very count these cases are about. The three below are group 8's `--check` fixtures, for
# the same reason: they describe the machine, not the working tree, and a file this suite
# invented must not show up in the set difference the suite is measuring.
printf '.test_run/\ngraph.json\nentries.json\nsetting/\n' > "$FIX/.gitignore"
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" commit -qm "fixture: HEAD carries 128, as trunk does" >/dev/null 2>&1

knob()  { printf '%s\n' "$1" > "$KNOB"; }
dirty_count() { git -C "$FIX" status --porcelain | wc -l | tr -d ' '; }
no_baseline() { rm -f "$FIX/.test_run/round.baseline"; }

STUBS='
REPO="'"$FIX"'"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
'
drive() {   # drive <shell-code> -> output + RC=
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

# ==========================================================================================
section "1. 🔴 the finding: the knob at 128 with git calling the file CLEAN"
# The night's baseline is 4, so the round baseline says 4. R4 writes 128 for a 128-host round
# and stops there. git now agrees with HEAD, so nothing git-shaped can see it.
knob 4
BEFORE="$(dirty_count)"
OUT="$(drive 'record_round_baseline')"
knob 128
AFTER="$(dirty_count)"
check "🔴 the porcelain count moved the WRONG way (22->21 on 09-05)" "yes" \
      "$( (( AFTER < BEFORE )) && echo yes || echo no)"
check "  and git itself calls the knob clean"          "" \
      "$(git -C "$FIX" status --porcelain -- p4_proxy/mininet/host_count_override)"

OUT="$(drive 'git_lines')"
has   "🔴 the alarm fires anyway"                       "NOT RESTORED" "$OUT"
has   "  naming the value it should be"                 "this round started at 4" "$OUT"
has   "  and the value it is"                           "knob baseline  128" "$OUT"
has   "🔴 and saying the thing that made this invisible" "git calls this file CLEAN (it matches HEAD) -- that is NOT 'restored'" "$OUT"
has   "  it hands over the restore command"             "echo 4 > p4_proxy/mininet/host_count_override" "$OUT"
has   "🔴 and warns against the one that gives 128"     "NOT 'git checkout --'" "$OUT"

section "2. 🔴 a clean tree does not stop the check"
# The old git_lines returned early on a clean tree. That is exactly the state the knob's most
# dangerous value produces, so the early return WAS the bug.
git -C "$FIX" stash -q -u >/dev/null 2>&1 || true
git -C "$FIX" checkout -q -- . 2>/dev/null
knob 128
check "the tree really is clean now"                    "0" "$(dirty_count)"
OUT="$(drive 'git_lines')"
has   "the code row still says clean tree"              "(clean tree)" "$OUT"
has   "🔴 and the knob is still checked"                "NOT RESTORED" "$OUT"

section "3. 🔴 the other direction: a 128-host round that is MEANT to be at 128"
# Without this the change is satisfied by "always warn when != 4", and a warning that is on
# during every legitimate P4-128 round is a warning nobody reads.
knob 128
OUT="$(drive 'record_round_baseline; knob_row')"
has   "it says the value matches what the round started with" "128 == the value this round started with" "$OUT"
hasnt "  and does not shout"                            "NOT RESTORED" "$OUT"

section "4. no baseline: the unconditional fallback Adam named"
no_baseline
knob 128
OUT="$(drive 'knob_row')"
has   "🔴 128 with no baseline is still printed"        "128 != 4, and no round baseline exists" "$OUT"
has   "  saying what it decides"                        "builds 128 hosts" "$OUT"
knob 4
OUT="$(drive 'knob_row')"
has   "  and 4 with no baseline is quiet but explicit"  "4 (the default; no round baseline recorded" "$OUT"
hasnt "  nothing red about it"                          "NOT RESTORED" "$OUT"

section "5. 🔴 the restoration check compares the SET, not the count"
no_baseline
knob 4                                   # the night's real working-tree value: dirty vs HEAD
printf 'edited\n' > "$FIX/src/Thing.cpp"
OUT="$(drive 'record_round_baseline')"
has   "the baseline records the paths, sorted"          "recorded this round's starting point" "$OUT"
BASE_FILE="$FIX/.test_run/round.baseline"
has   "  the knob's value is in it"                     "host_count=4" "$(cat "$BASE_FILE")"
has   "  and both dirty paths"                          "dirty=p4_proxy/mininet/host_count_override" "$(cat "$BASE_FILE")"
has   "  including the other one"                       "dirty=src/Thing.cpp" "$(cat "$BASE_FILE")"

BEFORE="$(dirty_count)"
knob 128                                  # leaves the dirty set by MATCHING HEAD
AFTER="$(dirty_count)"
check "🔴 the count says the tree got cleaner"          "yes" "$( (( AFTER < BEFORE )) && echo yes || echo no)"
OUT="$(drive 'tree_vs_round_row')"
has   "🔴 the set difference names the path that LEFT"  "- p4_proxy/mininet/host_count_override" "$OUT"
has   "  and says what leaving the set means"           "now matches HEAD -- which is not the same as restored" "$OUT"
has   "  counted in both directions"                    "1 file(s) LEFT the uncommitted set" "$OUT"

printf 'new\n' > "$FIX/src/Added.cpp"
OUT="$(drive 'tree_vs_round_row')"
has   "🔴 a path that JOINED the set is named too"      "+ src/Added.cpp" "$OUT"
rm -f "$FIX/src/Added.cpp"

section "6. 🔴 no baseline is said, not assumed"
no_baseline
OUT="$(drive 'tree_vs_round_row')"
has   "it says there is nothing to compare against"     "nothing here can say what this round changed" "$OUT"
hasnt "  and never reports a match"                     "same set of uncommitted files" "$OUT"

section "7. the wiring: 'ndt claim' is what records a round"
no_baseline
knob 4
OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
NDT_OWNER=fixture-owner
cmd_claim 5 'a round'
echo \"RC=\$?\"" 2>&1)"
check "claim succeeds"                                  "0" "$(rc_of "$OUT")"
check "🔴 and it wrote the baseline"                    "yes" \
      "$( [[ -f "$BASE_FILE" ]] && echo yes || echo no)"
has   "  with the owner in it"                          "by=fixture-owner" "$(cat "$BASE_FILE" 2>/dev/null)"
has   "  and the knob's value at that moment"           "host_count=4" "$(cat "$BASE_FILE" 2>/dev/null)"

# 🔴 git_lines has to CALL both rows, or the whole file is a set of functions nobody runs.
OUT="$(drive 'git_lines')"
has   "git_lines runs the knob check"                   "knob baseline" "$OUT"
has   "  and the set comparison"                        "tree vs round" "$OUT"

# ==========================================================================================
# Groups 8 and 9 drive the whole of cmd_status / cmd_release rather than one row, because the
# two things decided on 09-07 are both about what the SURROUNDING command does with the row's
# answer. Everything that would describe this machine is stubbed; git_lines, knob_row,
# tree_vs_round_row, check_up_target and the exit code all run for real.
# [Co-developed with claude code -- Adam]

mkdir -p "$FIX/setting"
python3 - "$FIX/setting/OVS4.json" <<'PY'
import json, sys
nodes  = [{"vertex_type": 0, "id": i} for i in range(10)]
nodes += [{"vertex_type": 1, "id": 1000 + i} for i in range(4)]
json.dump({"nodes": nodes,
           "edges": [{"src": i % 10, "dst": (i + 1) % 10} for i in range(40)]},
          open(sys.argv[1], "w"))
PY
python3 - "$FIX/graph.json" <<'PY'
import json, sys
n  = [{"vertex_type": 0, "is_up": True, "is_enabled": True, "admin_disabled": False, "id": i}
      for i in range(10)]
n += [{"vertex_type": 1, "id": 1000 + i} for i in range(4)]
e  = [{"is_up": True, "admin_disabled": False, "src": i % 10, "dst": (i + 1) % 10}
      for i in range(40)]
json.dump({"nodes": n, "edges": e}, open(sys.argv[1], "w"))
PY
# One rule, 9000 s old, outside every app window: the residue row must answer "none" so that
# the only thing that can turn --check red in this group is the knob.
python3 - "$FIX/entries.json" <<'PY'
import json, sys
row = {"actions": ["OUTPUT:1"], "byte_count": 0, "cookie": 0, "duration_sec": 9000,
       "duration_nsec": 91000000, "flags": 0, "hard_timeout": 0, "idle_timeout": 0,
       "length": 96, "match": {"in_port": 1}, "packet_count": 0, "priority": 10,
       "table_id": 0}
json.dump([{"dpid": 1, "flows": {"1": [row]}}], open(sys.argv[1], "w"))
PY
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs"
: > "$FIX/.test_run/pids/app_energy.pid"
touch -d "@$(( $(date +%s) - 600 ))" "$FIX/.test_run/pids/app_energy.pid"

# The `ndt up` record --check compares against. Written to match the fixture exactly, so a
# green run here means "nothing else was wrong", and a red one names the knob and only the knob.
write_up_target() {
    printf 'plane=ovs\nhosts=4\ntopology=setting/OVS4.json\ntopology_sha256=%s\nmodel_hosts=4\nmodel_edges=40\nat=%s\nby=fixture\nbuilder=up_ovs\n' \
        "$(sha256sum "$FIX/setting/OVS4.json" | cut -d' ' -f1)" "$(date +%s)" \
        > "$FIX/.test_run/up.target"
}
write_up_target

CHECK_STUBS='
MANIFEST="$REPO/manifest.json"
claim_line() { echo none; }
in_flight() { :; }
foreign_claim() { :; }
sample_rate() { echo 256; }
rate_source() { echo "fixture"; }
bmv2_binary() { echo "fixture-bmv2"; }
stale_pipeline() { return 1; }
source_ahead_of_build() { return 1; }
bmv2_count() { echo 0; }
mn_count() { echo 14; }
fabric_host_count() { echo 4; }
ovs_bridge_count() { echo 10; }
ovs_daemon_running() { return 0; }
topo_session() { return 0; }
live_dataplane_kind() { echo ovs; }
port_open() { [[ "$1" == 8000 ]]; }
http_get_graph() { cat "$REPO/graph.json"; }
http_get_flow_entries() { cat "$REPO/entries.json"; }
lock_probe() { echo free; }
netem_count() { echo 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
app_probe() { APP_STATE=not-running; }
lab_version_verdict() { echo "same fixture-sha fixture-sha"; }
'
run_check() {   # -> the whole report plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$CHECK_STUBS
cmd_status --check
echo \"RC=\$?\"" 2>&1
}
KNOB_PROBLEM="- the P4 host knob is NOT RESTORED"

section "8. 🔴 E-9: '--check' EXITS 1 on NOT RESTORED (on 09-07 it printed red and exited 0)"
# rounds/08-round2.md:146, live arm lw16 step D, 04:36 on a 4-host OVS fabric: claim recorded
# 128, the operator wrote 8, and --check printed
#     knob baseline  8 -- this round started at 128 (at 04:36:41): NOT RESTORED
# in red -- and returned 0. Red text with a green exit code is a report, not a gate, and the
# end of a round is exactly where "have I put the knob back" has to bite.
# Adam's decision 09-07 (grill §4E round 3, E-9).
git -C "$FIX" stash -q -u >/dev/null 2>&1 || true
git -C "$FIX" checkout -q -- . 2>/dev/null
knob 128
OUT="$(drive 'record_round_baseline')"       # the round starts at 128
knob 8                                        # ...and is left at 8
OUT="$(run_check)"
has   "the row still prints in red"                     "NOT RESTORED" "$OUT"
has   "🔴 and it is listed as a problem"                "$KNOB_PROBLEM" "$OUT"
has   "  the problem line carries both values"          "is 8, this round started at 128" "$OUT"
has   "  and how to put it back"                        "write 128 back" "$OUT"
has   "🔴 and warns against the one that gives HEAD"    "not 'git checkout --'" "$OUT"
check "🔴 --check exits 1 (it exited 0 over this at 04:36)" "1" "$(rc_of "$OUT")"
hasnt "  and does not also say ok"                      "check: ok" "$OUT"

section "9. 🔴 the other direction: putting the knob back makes --check green again"
# Without this the change is satisfied by a --check that is red whenever a baseline exists.
knob 128
OUT="$(run_check)"
has   "the row says the value matches"                  "128 == the value this round started with" "$OUT"
hasnt "🔴 the problem is gone"                          "$KNOB_PROBLEM" "$OUT"
check "🔴 and rc is back to 0"                          "0" "$(rc_of "$OUT")"
has   "  check: ok"                                     "check: ok" "$OUT"

section "10. 🔴 scope: a changed SET is not a problem, only a changed VALUE is"
# Adam's ruling names one sentence. Committing during a round moves files in and out of the
# uncommitted set for entirely good reasons, so tree_vs_round_row stays out of the verdict --
# a gate that fires on every commit is a gate nobody reads. (The row still prints.)
printf 'edited during the round\n' > "$FIX/src/Thing.cpp"
OUT="$(run_check)"
has   "the set difference is reported"                  "joined it" "$OUT"
hasnt "🔴 but a file that joined the set is NOT a problem" "$KNOB_PROBLEM" "$OUT"
check "🔴 and --check is still green"                   "0" "$(rc_of "$OUT")"
git -C "$FIX" checkout -q -- src/Thing.cpp 2>/dev/null

# ...and the two no-baseline outcomes, which Adam did not rule on: printed, never a verdict.
# `!= 4 with no baseline` cannot tell a forgotten restore from a deliberate 128-host round
# that never claimed, so folding it in would make --check red on every such round.
no_baseline
knob 128
OUT="$(run_check)"
has   "no baseline: the row still says 128 != 4"        "128 != 4, and no round baseline exists" "$OUT"
hasnt "🔴 but it is not a problem"                      "$KNOB_PROBLEM" "$OUT"
check "🔴 and --check stays green"                      "0" "$(rc_of "$OUT")"

section "11. no up.target: rc 3 COULD NOT CHECK, and the knob problem is still shown"
# --check without an `ndt up` record returns 3 and prints its problem list under "everything
# else this report could still check". The knob answer does not depend on the lab at all, so
# it must survive into that list -- otherwise the one instrument that still works goes quiet
# in exactly the state (a checkout with no baseline) where a round is most likely to be over.
knob 128
OUT="$(drive 'record_round_baseline')"
knob 8
rm -f "$FIX/.test_run/up.target"
OUT="$(run_check)"
check "rc 3, not 1: nothing was compared against a target" "3" "$(rc_of "$OUT")"
has   "  it says so"                                    "COULD NOT CHECK" "$OUT"
has   "🔴 and the knob problem is still listed"         "$KNOB_PROBLEM" "$OUT"
write_up_target

section "12. 🔴 E-11: 'ndt release' retires the round baseline to .prev"
# R2-NDT left `.test_run/round.baseline` behind on purpose -- nothing deleted it, so a round
# that ended kept being compared against. Adam's decision 09-07 (grill §4E round 3, E-11):
# rename it, on the lab.handoff precedent. Renamed and not deleted, because the knob value and
# the dirty set a round started from cannot be reconstructed from `git status` afterwards.
rm -f "$BASE_FILE" "$BASE_FILE.prev"
knob 4
OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
NDT_OWNER=fixture-owner
cmd_claim 5 'a round'
echo \"RC=\$?\"" 2>&1)"
check "claim wrote a baseline"                          "yes" \
      "$( [[ -f "$BASE_FILE" ]] && echo yes || echo no)"
BEFORE_SUM="$(sha256sum "$BASE_FILE" | cut -d' ' -f1)"
OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
NDT_OWNER=fixture-owner
cmd_release
echo \"RC=\$?\"" 2>&1)"
check "release succeeds"                                "0" "$(rc_of "$OUT")"
check "🔴 the round baseline is gone"                   "no" \
      "$( [[ -f "$BASE_FILE" ]] && echo yes || echo no)"
check "🔴 and kept as .prev, not deleted"               "yes" \
      "$( [[ -f "$BASE_FILE.prev" ]] && echo yes || echo no)"
check "  byte-identical to what claim wrote"            "$BEFORE_SUM" \
      "$(sha256sum "$BASE_FILE.prev" 2>/dev/null | cut -d' ' -f1)"
has   "  and release says where it went"                "round.baseline.prev" "$OUT"
# The correct reading afterwards: the round is over, so there is nothing to compare against.
OUT="$(drive 'tree_vs_round_row')"
has   "🔴 status is back to 'no baseline'"              "nothing here can say what this round changed" "$OUT"

# --force takes the same path, and a foreign claim is the case it exists for.
printf 'owner=someone else\nexpires=%s\nnote=busy\n' "$(( $(date +%s) + 3600 ))" \
    > "$FIX/.test_run/lab.claim"
rm -f "$BASE_FILE.prev"
OUT="$(drive 'record_round_baseline')"
OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
NDT_OWNER=fixture-owner
cmd_release --force
echo \"RC=\$?\"" 2>&1)"
check "release --force succeeds"                        "0" "$(rc_of "$OUT")"
check "🔴 --force retires the baseline too"             "yes" \
      "$( [[ ! -f "$BASE_FILE" && -f "$BASE_FILE.prev" ]] && echo yes || echo no)"

# 🔴 The early return is NOT a round ending. `ndt release` with no claim held is a no-op, and
# a no-op must not retire somebody else's still-live baseline -- releasing a claim you never
# took says nothing about whose round is running.
rm -f "$FIX/.test_run/lab.claim" "$BASE_FILE.prev"
OUT="$(drive 'record_round_baseline')"
OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
NDT_OWNER=fixture-owner
cmd_release
echo \"RC=\$?\"" 2>&1)"
has   "release with no claim says so"                   "no claim to release" "$OUT"
check "🔴 and leaves the baseline where it is"          "yes" \
      "$( [[ -f "$BASE_FILE" && ! -f "$BASE_FILE.prev" ]] && echo yes || echo no)"

# ==========================================================================================
# Groups 13-16: E-9b and E-11b, Adam's decisions of 09-07 18:1x (R3-NDT §7-1 and §7-2), which
# are about what happens BETWEEN the two things above. E-9 made "the knob is not what the round
# started with" a --check problem; the next reading of the standard P4 round showed what that
# costs, because `ndt up p4 4` writes the knob through set_host_count:
#
#     ndt claim ...        round.baseline: host_count=128
#     ndt up p4 4          the knob is now 4 -- written by ndt, on purpose
#     ndt status --check   rc 1, "NOT RESTORED", for the whole rest of the round
#
# arm_up.sh:45 records that rc on every P4 arm. A gate that is red from the first command to
# the last is the shape E-9 was itself decided against. So: the round baseline also records
# what `ndt up p4` wrote (up_wrote=), knob_row has three answers instead of two, and the
# deadline that used to fire on every status call now fires once, in `ndt release`.
# [Co-developed with claude code -- Adam]

claim_round() {     # -> output + RC=   (a round starts; the knob's value is recorded)
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
NDT_OWNER=fixture-owner
cmd_claim 5 'a round'
echo \"RC=\$?\"" 2>&1
}
release_round() {   # $1 = '' or --force
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
NDT_OWNER=fixture-owner
cmd_release ${1:-}
echo \"RC=\$?\"" 2>&1
}
claim_exists() { [[ -f "$FIX/.test_run/lab.claim" ]] && echo yes || echo no; }

section "13. 🔴 E-9b: 'ndt up p4 <n>' leaves a note saying ndt itself moved the knob"
rm -f "$BASE_FILE" "$BASE_FILE.prev" "$FIX/.test_run/lab.claim"
knob 128
printf 'edited before the round\n' > "$FIX/src/Thing.cpp"   # so the baseline has a dirty set
OUT="$(drive 'record_round_baseline')"
OUT="$(drive 'set_host_count 4')"
check "set_host_count succeeds"                         "0" "$(rc_of "$OUT")"
check "  and the knob really moved"                     "4" "$(cat "$KNOB")"
has   "🔴 the baseline records that ndt wrote it"       "up_wrote=4" "$(cat "$BASE_FILE")"
has   "  and when"                                      "up_wrote_at=" "$(cat "$BASE_FILE")"
has   "🔴 the round's own starting value is untouched"  "host_count=128" "$(cat "$BASE_FILE")"
has   "  and so is the dirty set it recorded"           "dirty=src/Thing.cpp" "$(cat "$BASE_FILE")"
git -C "$FIX" checkout -q -- src/Thing.cpp 2>/dev/null
# 🔴 Rewritten, never appended: round_baseline_field takes `head -1`, so a second up_wrote=
# line would let a value ndt has since overwritten go on excusing the knob.
OUT="$(drive 'set_host_count 8')"
check "🔴 a second 'ndt up' leaves ONE up_wrote line"   "1" "$(grep -c '^up_wrote=' "$BASE_FILE")"
check "  and one timestamp"                             "1" "$(grep -c '^up_wrote_at=' "$BASE_FILE")"
has   "  carrying the newest value"                     "up_wrote=8" "$(cat "$BASE_FILE")"
hasnt "  and not the one it replaced"                   "up_wrote=4" "$(cat "$BASE_FILE")"

# 🔴 No round claimed: nothing to excuse, so nothing is written. Inventing the file here would
# manufacture a round `ndt claim` never started.
no_baseline
knob 128
OUT="$(drive 'set_host_count 4')"
check "with no round claimed set_host_count still succeeds" "0" "$(rc_of "$OUT")"
check "🔴 and it writes no baseline file"               "no" \
      "$( [[ -f "$BASE_FILE" ]] && echo yes || echo no)"
check "  (the knob still moved)"                        "4" "$(cat "$KNOB")"

section "14. 🔴 E-9b: what 'ndt up p4' wrote is a WARNING; a hand edit is still a problem"
rm -f "$BASE_FILE" "$BASE_FILE.prev"
knob 128
OUT="$(drive 'record_round_baseline')"     # the round starts at 128
OUT="$(drive 'set_host_count 4')"          # ...and `ndt up p4 4` writes 4 through
OUT="$(run_check)"
has   "🔴 the row names who wrote it"                   "written by 'ndt up p4 4'" "$OUT"
has   "  and what the round started at"                 "the round started at 128" "$OUT"
has   "  with the deadline attached"                    "write 128 back before 'ndt release'" "$OUT"
has   "  and how to do it"                              "echo 128 > p4_proxy/mininet/host_count_override" "$OUT"
has   "  saying release will enforce it"                "'ndt release' refuses while these differ" "$OUT"
hasnt "🔴 it is NOT called NOT RESTORED"                "NOT RESTORED" "$OUT"
hasnt "🔴 and NOT a --check problem"                    "$KNOB_PROBLEM" "$OUT"
check "🔴 --check is green (rc 1 for the whole round before E-9b)" "0" "$(rc_of "$OUT")"

# The 04:36 case, unchanged: a third value nobody announced.
knob 8
OUT="$(run_check)"
has   "🔴 a hand edit is still NOT RESTORED"            "NOT RESTORED" "$OUT"
has   "  naming the value ndt did write"                "'ndt up p4' wrote 4 this round" "$OUT"
has   "🔴 and still a problem"                          "$KNOB_PROBLEM" "$OUT"
check "🔴 rc 1 (a hand edit after 'ndt up')"            "1" "$(rc_of "$OUT")"

# A baseline with no up_wrote at all -- groups 8-11's state, which must not have moved.
rm -f "$BASE_FILE"
knob 128
OUT="$(drive 'record_round_baseline')"
knob 8
check "a fresh baseline carries no up_wrote field"      "0" "$(grep -c '^up_wrote=' "$BASE_FILE")"
OUT="$(run_check)"
has   "🔴 no note means NOT RESTORED, exactly as before" "NOT RESTORED" "$OUT"
has   "🔴 and it is a problem"                          "$KNOB_PROBLEM" "$OUT"
check "🔴 rc 1 (nothing excuses this value)"            "1" "$(rc_of "$OUT")"

section "15. 🔴 E-11b: 'ndt release' refuses while the knob is not back"
# The other half of E-9b. One line into cmd_release the baseline becomes .prev, after which
# nothing in this script can say what the knob started at -- so this is the last moment the
# question can be asked, and E-9b moved the answer here on purpose.
rm -f "$BASE_FILE" "$BASE_FILE.prev" "$FIX/.test_run/lab.claim"
knob 128
OUT="$(claim_round)"
check "claim succeeds"                                  "0" "$(rc_of "$OUT")"
knob 8
OUT="$(release_round)"
check "🔴 release refuses"                              "1" "$(rc_of "$OUT")"
has   "  saying what the knob is now"                   "the P4 host knob is 8" "$OUT"
has   "  and what the round started at"                 "this round started at 128" "$OUT"
has   "🔴 and how to put it back"                       "echo 128 > p4_proxy/mininet/host_count_override" "$OUT"
has   "  warning off the command that gives HEAD"       "NOT 'git checkout --'" "$OUT"
has   "  and naming the override"                       "ndt release --force" "$OUT"
check "🔴 the claim is NOT released"                    "yes" "$(claim_exists)"
check "🔴 and the baseline is NOT retired"              "yes" \
      "$( [[ -f "$BASE_FILE" && ! -f "$BASE_FILE.prev" ]] && echo yes || echo no)"

OUT="$(release_round --force)"
check "🔴 --force releases anyway"                      "0" "$(rc_of "$OUT")"
has   "🔴 in red, saying what it left behind"           "released with the knob left at 8 (round started at 128)" "$OUT"
check "  the claim is gone"                             "no" "$(claim_exists)"
check "  and the baseline was still retired to .prev"   "yes" \
      "$( [[ ! -f "$BASE_FILE" && -f "$BASE_FILE.prev" ]] && echo yes || echo no)"

# The knob back where it started: the release path of groups 11-12, untouched.
rm -f "$BASE_FILE" "$BASE_FILE.prev"
knob 4
OUT="$(claim_round)"
OUT="$(release_round)"
check "🔴 with the knob back at the start, release just works" "0" "$(rc_of "$OUT")"
has   "  and says so"                                   "lab released" "$OUT"
check "  retiring the baseline as E-11 says"            "yes" \
      "$( [[ ! -f "$BASE_FILE" && -f "$BASE_FILE.prev" ]] && echo yes || echo no)"

section "16. 🔴 E-11b: 'ndt up p4' buys time, not a release"
# up_wrote excuses the value DURING the round and is exactly what makes it unacceptable at the
# end: the next round's `ndt up p4` reads this file and nothing else does.
rm -f "$BASE_FILE" "$BASE_FILE.prev"
knob 128
OUT="$(claim_round)"
OUT="$(drive 'set_host_count 4')"
has   "the note is there"                               "up_wrote=4" "$(cat "$BASE_FILE")"
OUT="$(run_check)"
check "  --check is green during the round"             "0" "$(rc_of "$OUT")"
OUT="$(release_round)"
check "🔴 but release still refuses"                    "1" "$(rc_of "$OUT")"
has   "  naming the value to write back"                "echo 128 > p4_proxy/mininet/host_count_override" "$OUT"
check "🔴 and the claim is still held"                  "yes" "$(claim_exists)"
knob 128
OUT="$(release_round)"
check "  writing 128 back releases cleanly"             "0" "$(rc_of "$OUT")"
check "  and the claim is gone"                         "no" "$(claim_exists)"

# --- done ---------------------------------------------------------------------------------
# 🔴 `echo`, not printf: tests/shell/test_l1_shell_scoring.sh group C reads the LAST
# `echo "..."` out of every suite's SOURCE and requires it to render a count the scorer in
# tools/ can read. A summary printed with printf is invisible to it.
echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
