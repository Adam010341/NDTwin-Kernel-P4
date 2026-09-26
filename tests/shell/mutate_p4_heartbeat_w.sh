#!/usr/bin/env bash
#
# Mutation gate for TICKET-P4-heartbeat segment W: the proxy's half (the report reader, the
# evidence through the reserved entry, the freeze, detect-only, capabilities / reroute / heartbeat
# on switch_state, the 409), ndt's half (start, stop, status), and 08_heartbeat.sh's self-test.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 EVERY NEW TEST HAS TO HAVE BEEN SEEN RED (the ticket's section 2, CLAUDE.md's mutation gate).
#   * proxy: every test in NEW_CLASSES / NEW_TESTS -- enumerated from the unmutated copy by the
#     unittest loader, not typed -- must go red under some mutation, and a check against the base
#     (TICKET_BASE) makes NEW_CLASSES name every TestCase class added since;
#   * ndt: every check of tests/shell/test_ndt_heartbeat.sh must go red under some mutation,
#     EXCEPT the named CONTROLS below -- checks that prove a cell reached the branch it is about
#     (an rc of a bring-up or teardown that has nothing to do with the heartbeat). Each is listed
#     with that reason; one that is not a control and never went red fails the gate by name;
#   * 08_heartbeat.sh: every named mutation's self-test case must go red.
# Each mutation also names the ONE test (or check, or self-test case) that must go red for it.
#
# 🔴 EVERY MUTANT IS A COPY. p4_proxy/ (proxy_agent, tests, mininet, p4_src) and tools/p4_exercise
# are copied under a temp dir laid out like the repo; ndt is copied beside its siblings; 08 is
# copied with _common.sh, faults.sh and census_prepare.py; the root helper, which this ticket
# does NOT change, is only ever COPIED (for section 7's pins). Every source is re-hashed at the end.
#
# Usage:  tests/shell/mutate_p4_heartbeat_w.sh           PROXY_PY=/path/to/python to choose one
# Exit:   0 every mutation caught, every control green, every new test seen red;
#         1 otherwise; 2 refused (no interpreter, or a baseline was red); 3 a source changed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HBMOD="$REPO/p4_proxy/proxy_agent/link_heartbeat.py"
TOPOMGR="$REPO/p4_proxy/proxy_agent/topology_manager.py"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
ROUTES="$REPO/p4_proxy/proxy_agent/api_routes.py"
NDT="$REPO/tools/test_workflow/ndt"
HELPER="$REPO/tools/test_workflow/ndtwin-lab"
LIVE_DIR_REL="doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1"
LIVE08="$REPO/$LIVE_DIR_REL/08_heartbeat.sh"
NDT_TEST="$HERE/test_ndt_heartbeat.sh"
SOURCES=("$HBMOD" "$TOPOMGR" "$MAIN" "$ROUTES" "$NDT" "$HELPER" "$LIVE08" "$NDT_TEST")
#: The ticket's base (segment W's worktree was cut from it).
TICKET_BASE=580767a8

MODULES="tests.test_link_heartbeat tests.test_heartbeat_watchdog tests.test_heartbeat_fabric \
tests.test_flowentry_read_only tests.test_link_state_entry tests.test_route_binding \
tests.test_link_watchdog tests.test_declared_links tests.test_switch_state tests.test_startup"

NEW_CLASSES="tests.test_link_heartbeat:* tests.test_heartbeat_watchdog:* \
tests.test_heartbeat_fabric:* tests.test_flowentry_read_only:*"
#: Two first-cut tests the ticket changed on purpose (6e246f2d), asserted as they are now.
NEW_TESTS="tests.test_route_binding.AWriteWithNoBindingIs501OnTheRenamedFixtureTest.test_an_external_control_plane_refuses_first_as_it_always_did
tests.test_link_state_entry.TheEntryIsNotWiredInThisCutTest.test_its_one_caller_is_the_watchdog_pass_ingesting_the_heartbeat"

#: test_ndt_heartbeat.sh checks that are CONTROLS: each proves its cell reached the branch it is
#: about, and goes red only when code with nothing to do with the heartbeat breaks.
NDT_CONTROLS="🔴 the bring-up succeeds
  a reused fabric: rc 0
  (it did take the reuse branch)
  a package on NDTwin's pipeline comes up
  (the pipeline kind was read as ndtwin)
  the baseline fabric comes up
  an external package comes up
  (the pipeline kind was read as foreign)
  the teardown succeeds
  and the teardown still went on to the topology
  a proxy that never came up: rc 1
  the replacement comes up"

MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc; from p4.config.v1 import p4info_pb2' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || { echo "REFUSE: no interpreter with fastapi/networkx/grpc/p4runtime. Set PROXY_PY=." >&2; exit 2; }
echo "interpreter: $PY"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-hbw-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
RED_LOG="$BK/ever_red.txt"; : > "$RED_LOG"
NDT_RED_LOG="$BK/ndt_ever_red.txt"; : > "$NDT_RED_LOG"
declare -A BASE_SHA
for f in "${SOURCES[@]}"; do BASE_SHA["$f"]=$(sha256sum "$f" | cut -d' ' -f1); done
SURVIVORS=0
MUTATIONS=0

# === the proxy ====================================================================================
lay_out() {   # $1 = a directory to become a repo-shaped copy
    local d="$1"
    mkdir -p "$d/p4_proxy/p4_src" "$d/tools/test_workflow" "$d/home" "$d/tmp"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$d/p4_proxy/"
    cp "$REPO/p4_proxy/p4_src/"*.p4 "$d/p4_proxy/p4_src/"
    cp -rL "$REPO/p4_proxy/p4_src/build" "$d/p4_proxy/p4_src/" 2>/dev/null
    cp -r "$REPO/tools/p4_exercise" "$d/tools/"
    cp "$HELPER" "$d/tools/test_workflow/ndtwin-lab"
    ln -s "$REPO/setting" "$d/setting"
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
}

run_against() {
    ( cd "$1/p4_proxy" && HOME="$1/home" TMPDIR="$1/tmp" PYTHONPATH="$1/p4_proxy" \
        PYTHONDONTWRITEBYTECODE=1 timeout 300 "$PY" -m unittest $MODULES -v 2>&1 )
}

red_ids() { sed -n -E 's/^(FAIL|ERROR): ([^ ]+) \(([^)]*)\).*/\3/p' | sort -u; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test that must go red
    local out rc reds
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    reds=$(red_ids <<<"$out")
    printf '%s\n' "$reds" >> "$RED_LOG"
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS+1)); printf '  🔴 HUNG   %-70s\n' "$1"
    elif [[ "$rc" -ne 0 ]] && /usr/bin/grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-70s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (%s stayed green)\n' "$1" "$3"
        /usr/bin/grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | head -5 | sed 's/^/             /'
    fi
    rm -rf "$2"
}

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate. The anchor must
# occur exactly once, so a mutation cannot land somewhere other than where it says.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    lay_out "$d"
    python3 - "$d/${file#"$REPO/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert a != b, "identity mutation: %s" % a[:70]
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "proxy baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; lay_out "$base"
base_out=$(run_against "$base")
if ! /usr/bin/grep -qE '^OK' <<<"$base_out"; then
    /usr/bin/grep -E '^(Ran |OK|FAILED|FAIL:|ERROR:)' <<<"$base_out" | head -20
    echo "  proxy baseline is RED -- mutations prove nothing on a red baseline"; exit 2
fi
/usr/bin/grep -E '^(Ran |OK)' <<<"$base_out" | sed 's/^/  /'
NEW_IDS="$BK/new_ids.txt"
( cd "$base/p4_proxy" && PYTHONPATH="$base/p4_proxy" HOME="$base/home" TMPDIR="$base/tmp" \
    PYTHONDONTWRITEBYTECODE=1 "$PY" - $NEW_CLASSES > "$NEW_IDS.raw" <<'PY'
import importlib, sys, unittest
loader = unittest.TestLoader()
for spec in sys.argv[1:]:
    module_name, cls = spec.split(":")
    module = importlib.import_module(module_name)
    classes = ([getattr(module, n) for n in dir(module)
                if isinstance(getattr(module, n), type)
                and issubclass(getattr(module, n), unittest.TestCase)
                and getattr(module, n).__module__ == module.__name__]
               if cls == "*" else [getattr(module, cls)])
    for c in classes:
        for name in loader.getTestCaseNames(c):
            print(f"ID {module_name}.{c.__name__}.{name}")
PY
) || { echo "REFUSE: could not enumerate the new tests"; exit 2; }
{ sed -n 's/^ID //p' "$NEW_IDS.raw"; printf '%s\n' "$NEW_TESTS"; } | sort -u > "$NEW_IDS"
echo "  new proxy tests to be seen red: $(wc -l < "$NEW_IDS")"
# [Co-developed with claude code -- Adam]
# 🔴 THE SCAN READS THIS SEGMENT'S OWN HEAD, NOT THE WORKING TREE. Read from the working tree,
# "every class added since TICKET_BASE" is also every class any LATER ticket adds, so this gate
# would go red on trunk the first time somebody else adds a proxy test -- which is exactly what
# the first cut's mutate_roles_binding.sh does at this segment's head (its NEW_CLASSES check,
# pinned to 6291db35, lists the 18 classes added here and counts them as its survivor).
# CLASSES_AT is the last commit of this segment that added a test class. A later round of this
# ticket that adds one moves it, or runs with CLASSES_AT=worktree while it is uncommitted. It
# must be an ancestor of HEAD: a history that lost it (a squash-merge) is refused, not scanned
# as "no classes, none missing".
CLASSES_AT="${CLASSES_AT:-d57531d9cf53b65ffaa8d904a7f7ff3689093860}"
if [[ "$CLASSES_AT" != worktree ]] && ! git -C "$REPO" merge-base --is-ancestor "$CLASSES_AT" HEAD 2>/dev/null; then
    echo "REFUSE: CLASSES_AT $CLASSES_AT is not an ancestor of HEAD -- which classes this segment added cannot be read"
    exit 2
fi
# scan_classes <NEW_CLASSES> -- every module:class added between TICKET_BASE and CLASSES_AT that
# the given list does not cover, one per line.
scan_classes() {
    "$PY" - "$REPO" "$TICKET_BASE" "$CLASSES_AT" "$1" <<'PY'
import ast, glob, os, subprocess, sys
repo, base, at, listed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
wild = {s.split(":")[0] for s in listed if s.endswith(":*")}
def classes(src):
    return {n.name for n in ast.parse(src).body if isinstance(n, ast.ClassDef)
            and any(isinstance(f, ast.FunctionDef) and f.name.startswith("test") for f in n.body)}
def show(rev, rel):
    r = subprocess.run(["git", "-C", repo, "show", f"{rev}:{rel}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None
if at == "worktree":
    rels = sorted(os.path.relpath(p, repo) for p in glob.glob(f"{repo}/p4_proxy/tests/test_*.py"))
    read = lambda rel: open(f"{repo}/{rel}").read()
else:
    names = subprocess.run(["git", "-C", repo, "ls-tree", "--name-only", at, "p4_proxy/tests/"],
                           capture_output=True, text=True, check=True).stdout.split()
    rels = sorted(r for r in names if os.path.basename(r).startswith("test_") and r.endswith(".py"))
    read = lambda rel: show(at, rel)
if not rels:
    sys.exit("no test modules at " + at)
for rel in rels:
    module = "tests." + os.path.basename(rel)[:-3]
    then_src = show(base, rel)
    then = classes(then_src) if then_src is not None else set()
    for cls in sorted(classes(read(rel)) - then):
        if module not in wild:
            print(f"{module}:{cls}")
PY
}
missing=$(scan_classes "$NEW_CLASSES") \
    || { echo "REFUSE: could not compare the test classes with $TICKET_BASE"; exit 2; }
# The scan's own control: with one module left off the list it must name that module's classes. A
# scan that read nothing (a wrong pin, an empty listing) would otherwise pass as "none missing".
probe=$(scan_classes "${NEW_CLASSES/tests.test_flowentry_read_only:\*/}") \
    || { echo "REFUSE: the class scan's control could not run"; exit 2; }
if ! /usr/bin/grep -qx 'tests.test_flowentry_read_only:ARefusedWriteIsA409Test' <<<"$probe"; then
    echo "REFUSE: the class scan cannot see an omission (its control named: ${probe:-nothing})"
    exit 2
fi
if [[ -n "$missing" ]]; then
    echo "  🔴 NEW_CLASSES omits class(es) added between $TICKET_BASE and ${CLASSES_AT:0:8}:"
    sed 's/^/       /' <<<"$missing"
    SURVIVORS=$((SURVIVORS+1))
else
    echo "  NEW_CLASSES names every TestCase class added between $TICKET_BASE and ${CLASSES_AT:0:8}" \
         "(the scan's control, one module left off, named its classes)"
fi
rm -rf "$base"
echo

echo "the report: trusted, alive, this fabric, this period"
m=$(mutant p01 "$HBMOD" \
    '    if st.st_uid != owner_uid:' \
    '    if False:')
report "P01: the owner is not checked (file or directory)" "$m" \
       "test_a_report_owned_by_somebody_else_is_not_evidence"
m=$(mutant p02 "$HBMOD" \
    '    if st.st_mode & 0o022:' \
    '    if False:')
report "P02: group/other-writable is not checked" "$m" "test_an_other_writable_report_is_not_evidence"
m=$(mutant p03 "$HBMOD" \
    '        _check_owner_and_mode(path, st, owner_uid)' \
    '        pass')
report "P03: only the directory is checked, not the report itself" "$m" \
       "test_a_group_writable_report_is_not_evidence"
m=$(mutant p04 "$HBMOD" \
    '    _check_owner_and_mode(directory, dst, owner_uid)' \
    '    pass')
report "P04: the directory is not checked" "$m" "test_a_directory_somebody_else_can_write_is_not_trusted"
m=$(mutant p05 "$HBMOD" \
    'os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC' \
    'os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC')
report "P05: a symlink is followed" "$m" "test_a_symlink_is_not_followed"
m=$(mutant p06 "$HBMOD" \
    '        if not stat.S_ISREG(st.st_mode):' \
    '        if False:')
report "P06: a FIFO (anything not regular) is read" "$m" "test_a_fifo_is_refused_without_blocking"
m=$(mutant p07 "$HBMOD" \
    '            if total > MAX_REPORT_BYTES:' \
    '            if False:')
report "P07: no size cap" "$m" "test_a_report_larger_than_any_heartbeat_writes_is_refused"
m=$(mutant p08 "$HBMOD" \
    '    if status != "running":' \
    '    if False:')
report "P08: a stopped report is evidence" "$m" "test_a_stopped_heartbeat_is_not_running"
m=$(mutant p09 "$HBMOD" \
    '    if age > ALIVE_PERIODS * period or age < -CLOCK_SLACK_S:' \
    '    if age < -CLOCK_SLACK_S:')
report "P09: a report nobody rewrote is alive" "$m" "test_written_longer_ago_than_two_periods_is_stale"
m=$(mutant p09b "$HBMOD" \
    '    if age > ALIVE_PERIODS * period or age < -CLOCK_SLACK_S:' \
    '    if age > ALIVE_PERIODS * period:')
report "P09b: a report from another clock (the future) is alive" "$m" \
       "test_written_in_the_future_is_not_this_clock"
m=$(mutant p09c "$HBMOD" \
    'ALIVE_PERIODS = 2' \
    'ALIVE_PERIODS = 1')
report "P09c: one period of lag is already stale" "$m" "test_written_two_periods_ago_is_still_alive"
m=$(mutant p10 "$HBMOD" \
    '    if float(period) != float(period_expected):' \
    '    if False:')
report "P10: another period is judged with this proxy's timeout" "$m" \
       "test_another_period_is_a_mismatch_the_timeout_would_be_wrong_for"
m=$(mutant p11 "$HBMOD" \
    '    if not declared or missing:' \
    '    if not declared:')
report "P11: a report missing a declared direction is usable" "$m" \
       "test_a_declared_direction_the_report_does_not_carry_is_a_fabric_mismatch"
m=$(mutant p11b "$HBMOD" \
    '    if not declared or missing:' \
    '    if missing:')
report "P11b: nothing declared is usable" "$m" "test_no_declared_direction_at_all_is_not_usable"
m=$(mutant p12 "$HBMOD" \
    'heard={link: reported[link] for link in declared}' \
    'heard=dict(reported)')
report "P12: an undeclared direction is entered as evidence" "$m" \
       "test_a_direction_the_package_does_not_declare_is_disclosed_and_ignored"
m=$(mutant p13 "$HBMOD" \
    '    if not isinstance(doc, dict) or doc.get("format") != REPORT_FORMAT \
            or doc.get("source") != REPORT_SOURCE:' \
    '    if not isinstance(doc, dict):')
report "P13: format and source are not checked" "$m" "test_something_else_s_json_is_unreadable"
m=$(mutant p14 "$HBMOD" \
    '    if not all(isinstance(v, int) and not isinstance(v, bool) for v in link):' \
    '    if False:')
report "P14: a non-integer endpoint is accepted" "$m" "test_a_malformed_direction_is_unreadable"
m=$(mutant p15 "$HBMOD" \
    '                self._session, self._epoch = reading.session, reading.started_mono' \
    '                self._session, self._epoch = reading.session, (self._epoch if self._epoch is not None else reading.started_mono)')
report "P15: a new session keeps the old epoch" "$m" \
       "test_a_new_session_after_a_stop_counts_from_its_own_start"
m=$(mutant p15b "$HBMOD" \
    '                self._session, self._epoch = reading.session, reading.started_mono' \
    '                self._session, self._epoch = reading.session, reading.written_mono')
report "P15b: a new session counts from its report, not its start" "$m" \
       "test_a_new_session_counts_from_the_daemons_own_start"
m=$(mutant p16 "$HBMOD" \
    '                self._epoch = reading.written_mono' \
    '                pass')
report "P16: a gap in the same session does not restart the epoch" "$m" \
       "test_a_gap_in_the_same_session_restarts_the_epoch_at_the_report_that_ended_it"
m=$(mutant p17 "$HBMOD" \
    '            if last is not None and last >= epoch:' \
    '            if last is not None:')
report "P17: heard before the epoch counts as heard" "$m" "test_heard_before_the_epoch_is_not_heard"
m=$(mutant p18 "$HBMOD" \
    '                self._was_usable = False
                return reading, None' \
    '                self._was_usable = False
                return reading, []')
report "P18: an unusable report is empty evidence, not none" "$m" \
       "test_an_unusable_report_is_no_evidence_at_all"
m=$(mutant p18b "$HBMOD" \
    '                self._was_usable = False
                return reading, None' \
    '                self._was_usable = False
                return reading, [(link, False, self._clock()) for link in self.declared]')
report "P18b: no report reads as every direction silent (the network-wide false alarm)" "$m" \
       "test_a_heartbeat_that_never_ran_judges_nothing"
m=$(mutant p19 "$HBMOD" \
    '    period = _number(doc.get("period_s"))' \
    '    period = _number(doc.get("period"))')
report "P19: the period is read from the wrong key" "$m" \
       "test_a_well_formed_report_of_this_fabric_is_usable"
m=$(mutant p20 "$HBMOD" \
    '    except FileNotFoundError:
        return Reading(False, REASON_NOT_RUNNING,' \
    '    except FileNotFoundError:
        return Reading(False, REASON_UNREADABLE,')
report "P20: no report reads as unreadable, not as not running" "$m" \
       "test_no_report_at_all_is_a_heartbeat_that_is_not_running"
m=$(mutant p21 "$HBMOD" \
    '    try:
        doc = json.loads(raw)
    except ValueError as exc:
        return Reading(False, REASON_UNREADABLE, f"{path} does not parse: {exc}")' \
    '    doc = json.loads(raw)')
report "P21: a report that does not parse raises" "$m" \
       "test_a_report_that_does_not_parse_is_unreadable_not_a_crash"
m=$(mutant p22 "$HBMOD" \
    '    side = doc.get("side_effects") if isinstance(doc.get("side_effects"), dict) else None' \
    '    side = None')
report "P22: the side-effect counters are dropped" "$m" \
       "test_the_side_effect_counters_travel_with_the_reading"
m=$(mutant p23 "$HBMOD" \
    'REPORT_PATH = "/run/ndtwin-lab/heartbeat.json"' \
    'REPORT_PATH = "/run/ndtwin-lab/hb.json"')
report "P23: the proxy reads a file the helper does not write" "$m" \
       "test_the_report_path_is_the_one_the_root_helper_writes"
m=$(mutant p24 "$HBMOD" \
    'REPORT_OWNER_UID = 0' \
    'REPORT_OWNER_UID = 1000')
report "P24: the report may be owned by a user" "$m" \
       "test_the_owner_is_the_uid_the_helper_expects_of_its_daemon"

echo "the evidence, the one rule, the freeze"
m=$(mutant t01 "$TOPOMGR" \
    '        elif heard:
            entry["seen"] = True
            entry["at"] = max(entry["at"], at)' \
    '        elif heard:
            entry["seen"] = True
            entry["at"] = max(entry["at"], self._clock())')
report "T01: heard evidence is dated now, not when it was heard" "$m" \
       "test_a_heard_report_enters_the_time_it_was_heard_not_now"
m=$(mutant t02 "$TOPOMGR" \
    '        elif heard:
            entry["seen"] = True
            entry["at"] = max(entry["at"], at)' \
    '        elif heard:
            entry["seen"] = True
            entry["at"] = at')
report "T02: evidence can move backwards" "$m" "test_evidence_only_moves_forward"
m=$(mutant t03 "$TOPOMGR" \
    '        elif not entry["down"]:
            entry["at"] = max(entry["at"], at)' \
    '        else:
            entry["at"] = max(entry["at"], at)')
report "T03: silence revives a direction believed down" "$m" \
       "test_a_not_heard_report_on_a_down_direction_moves_nothing"
m=$(mutant t04 "$TOPOMGR" \
    '                                                "seen": heard}' \
    '                                                "seen": True}')
report "T04: a never-heard direction gets no startup grace" "$m" \
       "test_a_not_heard_report_on_a_new_direction_gives_it_the_startup_grace"
m=$(mutant t05 "$TOPOMGR" \
    '        entry["source"] = source' \
    '        pass')
report "T05: the evidence's source is not recorded" "$m" "test_the_source_is_recorded_on_the_evidence"
m=$(mutant t06 "$TOPOMGR" \
    '            elif at is not None:
                self._enter_evidence(' \
    '            if at is not None:
                self._enter_evidence(')
report "T06: timed evidence is entered with no watchdog running" "$m" \
       "test_without_a_watchdog_it_is_recorded_only_whatever_the_time"
m=$(mutant t07 "$TOPOMGR" \
    '            judge_at = self._ingest_link_evidence()' \
    '            judge_at = None')
report "T07: the pass never reads the heartbeat" "$m" \
       "test_a_tenth_past_the_beacon_timeout_both_directions_go_down_and_the_kernel_is_told"
m=$(mutant t08 "$TOPOMGR" \
    '                return _NOTHING_TO_JUDGE
            return self._evidence_judged_at' \
    '                return _NOTHING_TO_JUDGE
            return None')
report "T08: a dead heartbeat is judged at the clock (no freeze)" "$m" \
       "test_a_stale_report_freezes_every_link_where_it_was"
m=$(mutant t08b "$TOPOMGR" \
    '                return _NOTHING_TO_JUDGE
            return self._evidence_judged_at' \
    '                return None
            return self._evidence_judged_at')
report "T08b: evidence never usable yet is judged at the clock" "$m" \
       "test_evidence_attached_anew_judges_nothing_until_it_is_usable"
m=$(mutant t09 "$TOPOMGR" \
    '            self.report_external_link_state(*link, up=heard, source="heartbeat", at=at)' \
    '            self.report_external_link_state(*link, up=heard, source="heartbeat", at=at - 1.0)')
report "T09: the evidence is dated a second early (a stricter second rule)" "$m" \
       "test_a_cable_silent_for_exactly_the_beacon_timeout_is_still_up"
m=$(mutant t10 "$TOPOMGR" \
    '            self.report_external_link_state(*link, up=heard, source="heartbeat", at=at)' \
    '            self.report_external_link_state(*link, up=heard, source="heartbeat", at=min(x[2] for x in items))')
report "T10: one silent cable ages every direction" "$m" "test_the_other_six_directions_stay_up"
m=$(mutant t11 "$TOPOMGR" \
    '            self.report_external_link_state(*link, up=heard, source="heartbeat", at=at)' \
    '            with self._liveness_lock:
                self._enter_evidence(link, heard, at, "heartbeat")')
report "T11: the evidence bypasses the reserved entry" "$m" \
       "test_its_one_caller_is_the_watchdog_pass_ingesting_the_heartbeat"
m=$(mutant t12 "$TOPOMGR" \
    '            if self.routes_to_attached_hosts_only:
                print("[TopologyManager] link transition reported to the kernel and NOT rerouted: "' \
    '            if False:
                print("[TopologyManager] link transition reported to the kernel and NOT rerouted: "')
report "T12: a fabric that skips its routes is rerouted anyway" "$m" \
       "test_a_fabric_that_skips_its_routes_detects_and_does_not_reroute"
m=$(mutant t13 "$TOPOMGR" \
    '            if self.routes_to_attached_hosts_only:
                print("[TopologyManager] link transition reported to the kernel and NOT rerouted: "' \
    '            if True:
                print("[TopologyManager] link transition reported to the kernel and NOT rerouted: "')
report "T13: no fabric is ever rerouted" "$m" "test_an_owned_fabric_reroutes_on_the_transition"
m=$(mutant t14 "$TOPOMGR" \
    '                    **({"source": e["source"]} if "source" in e else {}),' \
    '                    **({}),')
report "T14: link_liveness hides the heartbeat as the source" "$m" \
       "test_link_liveness_names_the_heartbeat_as_the_source"
m=$(mutant t15 "$TOPOMGR" \
    '                    **({"source": e["source"]} if "source" in e else {}),' \
    '                    **({"source": e.get("source", "lldp")}),')
report "T15: an LLDP entry grows a source key" "$m" \
       "test_a_beacon_that_stops_still_times_out_on_the_proxys_clock"
m=$(mutant t16 "$TOPOMGR" \
    '        self.start_link_watchdog(seed_expected=False)' \
    '        self.start_link_watchdog(seed_expected=True)')
report "T16: the heartbeat watchdog seeds from the topology file" "$m" \
       "test_it_watches_the_declared_links_and_runs_the_one_watchdog_thread"
m=$(mutant t17 "$TOPOMGR" \
    '        evidence.poll()
        self.start_link_watchdog(seed_expected=False)' \
    '        self.start_link_watchdog(seed_expected=False)')
report "T17: nothing is read until the first pass" "$m" \
       "test_it_reads_the_report_once_at_once_so_the_state_is_known_before_the_first_pass"
m=$(mutant t18 "$TOPOMGR" \
    'period_s=LLDP_BEACON_INTERVAL_S, clock=self._clock,' \
    'period_s=5, clock=self._clock,')
report "T18: the evidence's period is a literal 5" "$m" \
       "test_the_topology_manager_reads_its_period_from_the_lldp_constant"
m=$(mutant t19 "$TOPOMGR" \
    '            self._last_packet_in[device_id] = now
            if lldp_info:' \
    '            self._last_packet_in[device_id] = now
            for _l, _e in self._link_beacons.items():
                if _l[2] == device_id and _l[3] == ingress_port:
                    _e["at"] = now
            if lldp_info:')
report "T19: a packet-in refreshes the link it arrived on" "$m" \
       "test_punted_heartbeat_frames_do_not_keep_a_cut_link_alive"
m=$(mutant t21 "$TOPOMGR" \
    '        self._record_watchdog_pass(pass_start, len(result["down"]), len(result["up"]))' \
    '        pass')
report "T21: no pass is recorded" "$m" "test_every_pass_is_recorded_with_its_times_and_its_transitions"
m=$(mutant t22 "$TOPOMGR" \
    '        self._watchdog_passes = collections.deque(maxlen=WATCHDOG_PASS_LOG)' \
    '        self._watchdog_passes = collections.deque()')
report "T22: the pass log grows without bound" "$m" "test_the_log_is_bounded"
m=$(mutant t23 "$TOPOMGR" \
    '            if judge_at is _NOTHING_TO_JUDGE:
                result = {"down": [], "up": [], "unacked": []}' \
    '            if judge_at is _NOTHING_TO_JUDGE:
                return {"down": [], "up": [], "unacked": []}')
report "T23: a pass with nothing to judge is not on record" "$m" "test_a_frozen_pass_is_recorded_too"
m=$(mutant t20 "$TOPOMGR" \
    '        #: TICKET-P4-heartbeat segment W -- see the class attributes of the same names.
        #: [Co-developed with claude code -- Adam]
        self._link_evidence = None' \
    '        #: TICKET-P4-heartbeat segment W -- see the class attributes of the same names.
        #: [Co-developed with claude code -- Adam]
        self._link_evidence = link_heartbeat.HeartbeatEvidence((), period_s=5)')
report "T20: every manager gets heartbeat evidence attached" "$m" "test_no_evidence_is_attached_by_default"

echo "which fabric, reroute, and what switch_state says"
m=$(mutant m01 "$MAIN" \
    '    if _fabric.get("declared_links"):
        _fabric["routes_blocked"] = _routes_blocked_word(clients, foreign)' \
    '    if True:
        _fabric["routes_blocked"] = _routes_blocked_word(clients, foreign)')
report "M01: NDTwin's own pipeline starts the heartbeat watchdog" "$m" \
       "test_an_all_ndtwin_fabric_does_not_start_it"
m=$(mutant m01b "$MAIN" \
    '    if _fabric.get("declared_links"):
        _fabric["routes_blocked"] = _routes_blocked_word(clients, foreign)' \
    '    if _fabric.get("declared_links") or read_only:
        _fabric["routes_blocked"] = _routes_blocked_word(clients, foreign)')
report "M01b: an external control plane starts it" "$m" "test_an_external_fabric_does_not_start_it"
m=$(mutant m02 "$MAIN" \
    '        started, error = _start_heartbeat_watchdog(topo)' \
    '        started, error = False, "mutant"')
report "M02: a foreign fabric never starts it" "$m" "test_a_foreign_fabric_starts_it_on_the_helpers_report"
m=$(mutant m03 "$MAIN" \
    '    if _fabric.get("declared_links"):
        _fabric["routes_blocked"] = _routes_blocked_word(clients, foreign)' \
    '    if _fabric.get("declared_links") and routes_owned:
        _fabric["routes_blocked"] = _routes_blocked_word(clients, foreign)')
report "M03: only an owned fabric starts it (no detection without reroute)" "$m" \
       "test_an_unbound_foreign_fabric_starts_it_too_detection_is_not_rerouting"
m=$(mutant m04 "$MAIN" \
    '        started, error = _start_heartbeat_watchdog(topo)' \
    '        started, error = _start_heartbeat_watchdog(topo)
        topo.start_link_watchdog(seed_expected=True)')
report "M04: the LLDP beacon watchdog is started beside it" "$m" \
       "test_the_lldp_watchdog_stays_off_and_stays_named_skipped"
m=$(mutant m05 "$MAIN" \
    '        _heartbeat["evidence"] = start(path=HEARTBEAT_REPORT_PATH, owner_uid=HEARTBEAT_REPORT_UID)' \
    '        _heartbeat["evidence"] = start()')
report "M05: the watchdog is not pointed at the helper's report" "$m" \
       "test_a_foreign_fabric_starts_it_on_the_helpers_report"
m=$(mutant m06 "$MAIN" \
    'HEARTBEAT_REPORT_UID = link_heartbeat.REPORT_OWNER_UID' \
    'HEARTBEAT_REPORT_UID = 1000')
report "M06: the report may be a user's" "$m" "test_a_foreign_fabric_starts_it_on_the_helpers_report"
m=$(mutant m07 "$MAIN" \
    '    if start is None:
        return False, ("AttributeError: this topology has no start_heartbeat_watchdog, so no "' \
    '    if start is None and False:
        return False, ("AttributeError: this topology has no start_heartbeat_watchdog, so no "')
report "M07: a topology without the entry is called anyway" "$m" \
       "test_a_topology_without_the_entry_does_not_stop_startup_and_says_so"
m=$(mutant m08 "$MAIN" \
    '        _heartbeat["evidence"] = start(path=HEARTBEAT_REPORT_PATH, owner_uid=HEARTBEAT_REPORT_UID)
    except Exception as e:  # noqa: BLE001 -- disclosed below, never fatal' \
    '        _heartbeat["evidence"] = start(path=HEARTBEAT_REPORT_PATH, owner_uid=HEARTBEAT_REPORT_UID)
    except ImportError as e:  # mutant: an OSError now stops startup')
report "M08: an entry that raises stops startup" "$m" "test_an_entry_that_raises_does_not_stop_startup"
m=$(mutant m09 "$MAIN" \
    '        if blocked is not None:' \
    '        if False:')
report "M09: an unbound fabric says reroute true" "$m" \
       "test_unbound_detects_by_heartbeat_and_does_not_reroute_and_says_why"
m=$(mutant m10 "$MAIN" \
    '        if reading is None or not reading.usable:' \
    '        if reading is None:')
report "M10: a stopped heartbeat still reroutes" "$m" \
       "test_owned_without_a_running_heartbeat_does_not_reroute_and_is_declared"
m=$(mutant m11 "$MAIN" \
    '        if not _fabric.get("heartbeat_watchdog"):' \
    '        if False:')
report "M11: a watchdog that never started is not the reason" "$m" \
       "test_owned_without_the_watchdog_does_not_reroute"
m=$(mutant m12 "$MAIN" \
    '    if route_binding.REASON_UNBOUND in words:' \
    '    if False:')
report "M12: unbound is named owned_by_package" "$m" "test_one_unbound_switch_is_enough"
m=$(mutant m13 "$MAIN" \
    '        elif binding.owner != route_binding.OWNER_NDTWIN:' \
    '        elif False:')
report "M13: a package-owned table does not block the reroute" "$m" \
       "test_a_package_owned_table_says_owned_by_package"
m=$(mutant m14 "$MAIN" \
    '            "link_discovery": "heartbeat" if usable else "declared"}' \
    '            "link_discovery": "declared"}')
report "M14: link_discovery never says heartbeat" "$m" \
       "test_owned_and_usable_reroutes_and_discovers_by_heartbeat"
m=$(mutant m15 "$MAIN" \
    '        for caps in out.values():
            caps.update(live)' \
    '        for caps in out.values():
            pass')
report "M15: capabilities never follow the heartbeat" "$m" \
       "test_owned_and_usable_reroutes_and_discovers_by_heartbeat"
m=$(mutant m16 "$MAIN" \
    '    return {"reroute": bool(available),' \
    '    return {"reroute": bool(available), "reroute_reason": _reason,')
report "M16: the capabilities grow a sixth key" "$m" "test_the_capabilities_keep_their_five_keys"
m=$(mutant m17 "$MAIN" \
    '    return evidence.last() if evidence is not None else None' \
    '    return _heartbeat.setdefault("frozen", evidence.last() if evidence is not None else None)')
report "M17: the answer is the one startup saw" "$m" "test_the_answer_follows_the_heartbeat_after_startup"
m=$(mutant m18 "$MAIN" \
    '        return (False, REROUTE_EXTERNAL,' \
    '        return (False, REROUTE_NO_LLDP_WATCHDOG,')
report "M18: external is not named as the reason" "$m" \
       "test_an_external_fabric_says_external_control_plane"
m=$(mutant m19 "$MAIN" \
    '    _fabric.update(external=read_only, heartbeat_watchdog=None, heartbeat_error=None,' \
    '    _fabric.update(external=False, heartbeat_watchdog=None, heartbeat_error=None,')
report "M19: startup forgets the fabric is external" "$m" \
       "test_an_external_fabric_says_external_control_plane"
m=$(mutant m20 "$MAIN" \
    '        return (True, None, "LLDP and its link watchdog run on this fabric")' \
    '        return (False, REROUTE_NO_LLDP_WATCHDOG, "LLDP and its link watchdog run on this fabric")')
report "M20: an all-NDTwin fabric stops rerouting" "$m" "test_an_all_ndtwin_fabric_is_what_it_was"
m=$(mutant m21 "$MAIN" \
    '        "frames_reached_hosts": (None if side is None
                                 else bool(side.get("forwarded_to_hosts", 0))),' \
    '        "frames_reached_hosts": False,')
report "M21: a frame at a host is never named" "$m" "test_a_frame_that_reached_a_host_is_named"
m=$(mutant m22 "$MAIN" \
    '        "census": HEARTBEAT_CENSUS,' \
    '        "census": {},')
report "M22: segment S's census is not served" "$m" \
       "test_the_block_carries_the_live_counters_and_segment_s_census"
m=$(mutant m23 "$MAIN" \
    '    if not _fabric.get("declared_links") or _fabric.get("heartbeat_watchdog") is None:
        return None
    reading = _heartbeat_reading()
    side =' \
    '    if False:
        return None
    reading = _heartbeat_reading()
    side =')
report "M23: a fabric with no heartbeat serves a heartbeat block" "$m" \
       "test_an_all_ndtwin_fabric_does_not_start_it"
m=$(mutant m24 "$MAIN" \
    '        "state": ("usable" if reading is not None and reading.usable' \
    '        "state": ("usable" if reading is not None')
report "M24: a stopped heartbeat is reported usable" "$m" "test_a_stopped_heartbeat_is_reported_as_what_it_is"
m=$(mutant m25 "$MAIN" \
    'api_routes.inject_heartbeat_reports(reroute_report, heartbeat_report)' \
    'api_routes.inject_heartbeat_reports(None, None)')
report "M25: main never injects the two reports" "$m" "test_main_injects_both"

m=$(mutant m26 "$MAIN" \
    '        "watchdog_passes": _heartbeat_passes(),' \
    '        "watchdog_passes": [],')
report "M26: the passes are not served" "$m" "test_the_watchdogs_passes_are_served"
m=$(mutant m27 "$MAIN" \
    '    _heartbeat["passes"] = getattr(topo, "watchdog_passes", None)' \
    '    _heartbeat["passes"] = None')
report "M27: the passes are not read from the topology" "$m" "test_the_watchdogs_passes_are_served"

echo "the endpoint and ruling 5(a)"
m=$(mutant a01 "$ROUTES" \
    '    if reroute_report is not None:
        state["reroute"] = reroute_report()' \
    '    if False:
        state["reroute"] = reroute_report()')
report "A01: switch_state never carries reroute" "$m" "test_both_blocks_reach_the_endpoint_at_the_top_level"
m=$(mutant a02 "$ROUTES" \
    '    if heartbeat_report is not None:
        state["heartbeat"] = heartbeat_report()' \
    '    if True:
        state["heartbeat"] = heartbeat_report() if heartbeat_report else None')
report "A02: an uninjected reporter still adds a key" "$m" "test_an_uninjected_reporter_adds_no_key"
m=$(mutant a03 "$ROUTES" \
    '        raise _route_write_unsupported(err, dpid)
    except ControlPlaneReadOnly as err:
        # TICKET-P4-heartbeat ruling 5(a). [Co-developed with claude code -- Adam]
        raise _read_only_conflict(err, dpid)

    if not success:
        return {"status": "error", "message": "Failed to add route"}' \
    '        raise _route_write_unsupported(err, dpid)

    if not success:
        return {"status": "error", "message": "Failed to add route"}')
report "A03: add on an external control plane is 500 again" "$m" "test_add_is_409"
m=$(mutant a04 "$ROUTES" \
    '        raise _route_write_unsupported(err, dpid)
    except ControlPlaneReadOnly as err:
        # TICKET-P4-heartbeat ruling 5(a). [Co-developed with claude code -- Adam]
        raise _read_only_conflict(err, dpid)
    if success:' \
    '        raise _route_write_unsupported(err, dpid)
    if success:')
report "A04: delete on an external control plane is 500 again" "$m" "test_delete_is_409"
m=$(mutant a05 "$ROUTES" \
    '        raise _route_write_unsupported(err, dpid)
    except ControlPlaneReadOnly as err:
        # TICKET-P4-heartbeat ruling 5(a). [Co-developed with claude code -- Adam]
        raise _read_only_conflict(err, dpid)
    if not success:
        raise HTTPException(status_code=400, detail="Failed to modify flow entry in P4 switch")' \
    '        raise _route_write_unsupported(err, dpid)
    if not success:
        raise HTTPException(status_code=400, detail="Failed to modify flow entry in P4 switch")')
report "A05: modify on an external control plane is 500 again" "$m" "test_modify_is_409"
m=$(mutant a06 "$ROUTES" \
    '        detail={"error": "external control plane", "dpid": dpid, "message": str(err)})' \
    '        detail={"error": "read only", "dpid": dpid, "message": str(err)})')
report "A06: the 409 body is not /p4/table_entry's" "$m" "test_the_body_is_the_table_entry_endpoints_own"
m=$(mutant a07 "$ROUTES" \
    '@router.post("/stats/flowentry/delete_strict")' \
    '@router.post("/stats/flowentry/delete_strict_x")')
report "A07: delete_strict is not the delete handler" "$m" "test_both_delete_routes_are_that_handler"

# === ndt ===========================================================================================
echo
echo "ndt"
ndt_run() {   # ndt_run <ndt copy> [helper copy] -> the suite's output
    ( TMPDIR="$BK/tmp" NDT_UNDER_TEST="$1" HELPER_UNDER_TEST="${2:-$HELPER}" timeout 600 bash "$NDT_TEST" 2>&1 )
}
mkdir -p "$BK/tmp"
nmutant() {   # $1 = label, $2 = file to mutate (ndt or the helper), $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" "$d/"
    [[ -r "$REPO/tools/test_workflow/components.env" ]] && cp "$REPO/tools/test_workflow/components.env" "$d/"
    cp "$HELPER" "$d/ndtwin-lab"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert a != b, "identity mutation: %s" % a[:70]
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}
nreport() {   # $1 = mutation name, $2 = mutant dir, $3 = the check that must go red
    local out
    MUTATIONS=$((MUTATIONS+1))
    out=$(ndt_run "$2/ndt" "$2/ndtwin-lab")
    sed -n 's/^  FAILED   //p' <<<"$out" >> "$NDT_RED_LOG"
    if /usr/bin/grep -qxF -- "  FAILED   $3" <<<"$out"; then
        printf '  caught   %-70s (check "%s" went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (check "%s" stayed green)\n' "$1" "$3"
        /usr/bin/grep -E 'FAILED|^Ran ' <<<"$out" | head -4 | sed 's/^/             /'
    fi
    rm -rf "$2"
}
nbase="$BK/nbase"; mkdir -p "$nbase"
cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" "$nbase/"
[[ -r "$REPO/tools/test_workflow/components.env" ]] && cp "$REPO/tools/test_workflow/components.env" "$nbase/"
nbase_out=$(ndt_run "$nbase/ndt")
if [[ "$(tail -1 <<<"$nbase_out")" != *", 0 failed" ]]; then
    tail -3 <<<"$nbase_out"; echo "  ndt baseline is RED"; exit 2
fi
echo "  ndt baseline: $(tail -1 <<<"$nbase_out")"
NDT_CHECKS="$BK/ndt_checks.txt"
sed -n 's/^  ok       //p' <<<"$nbase_out" | sort -u > "$NDT_CHECKS"
rm -rf "$nbase"

m=$(nmutant n01 "$NDT" \
    '    heartbeat_up_step "$app_pipe" "$app_mode"' \
    '    :')
nreport "N01: ndt up never starts the heartbeat" "$m" "🔴 exactly one 'heartbeat start'"
m=$(nmutant n02 "$NDT" \
    '    [[ "$1" == foreign:* && "$2" != external ]]' \
    '    true')
nreport "N02: every bring-up starts it (NDTwin's pipeline too)" "$m" "🔴 and never asks for a heartbeat (it has LLDP)"
m=$(nmutant n03 "$NDT" \
    '    [[ "$1" == foreign:* && "$2" != external ]]' \
    '    [[ "$1" == foreign:* ]]')
nreport "N03: an external control plane gets one" "$m" "🔴 and does not start one: the proxy reads only there"
m=$(nmutant n04 "$NDT" \
    '    heartbeat_up_step "$app_pipe" "$app_mode"' \
    '    heartbeat_up_step "$app_pipe" "$app_mode"; [[ -e "$HB_PIDFILE" ]] || { rollback_up "the heartbeat did not start"; return 1; }')
nreport "N04: a heartbeat that does not start fails the bring-up" "$m" "🔴 rc 0 -- the fabric IS up"
m=$(nmutant n05 "$NDT" \
    '        3) info "heartbeat: nothing to watch -- this fabric has no inter-switch link (rc 3)" ;;' \
    '        9) info "heartbeat: nothing to watch -- this fabric has no inter-switch link (rc 3)" ;;')
nreport "N05: rc 3 is warned about as a failure" "$m" "🔴 and not as a failure"
m=$(nmutant n06 "$NDT" \
    '    heartbeat_up_step "$app_pipe" "$app_mode"

    # -- 2 + 3. proxy and kernel, via stack.sh --
    say "[2/3] proxy + kernel"
    info "stack.sh prompt is answered immediately: the fabric is already up"
    # CONVERGE_WAIT is an upper bound, not a sleep. 128 hosts means 16256 destination paths.
    local out rc
    up_started stack
    out="$(printf '"'"'\n'"'"' \
           | TOPO_P4="$topo" CONVERGE_WAIT="${CONVERGE_WAIT:-300}" NO_COLOR=1 \
             bash "$STACK" up p4 2>&1)"
    rc=$?' \
    '    # -- 2 + 3. proxy and kernel, via stack.sh --
    say "[2/3] proxy + kernel"
    info "stack.sh prompt is answered immediately: the fabric is already up"
    # CONVERGE_WAIT is an upper bound, not a sleep. 128 hosts means 16256 destination paths.
    local out rc
    up_started stack
    out="$(printf '"'"'\n'"'"' \
           | TOPO_P4="$topo" CONVERGE_WAIT="${CONVERGE_WAIT:-300}" NO_COLOR=1 \
             bash "$STACK" up p4 2>&1)"
    rc=$?
    heartbeat_up_step "$app_pipe" "$app_mode"')
nreport "N06: the heartbeat starts after the proxy" "$m" "🔴 before stack.sh starts the proxy"
m=$(nmutant n07 "$NDT" \
    '    heartbeat_stop_step "before the topology it watches is taken down" || {' \
    '    true || {')
nreport "N07: ndt down never stops the heartbeat" "$m" "🔴 one 'heartbeat stop'"
m=$(nmutant n08 "$NDT" \
    '    heartbeat_stop_step "before the topology it watches is taken down" || {
        down_rc=1
        not_verified "the heartbeat daemon (its stop failed; sudo ndtwin-lab heartbeat status says whether it runs)"
    }

    say "[2/3] topology session"
    sudo -n "$LAB" topo-stop 2>&1 | sed '"'"'s/^/      /'"'"'' \
    '    say "[2/3] topology session"
    sudo -n "$LAB" topo-stop 2>&1 | sed '"'"'s/^/      /'"'"'
    heartbeat_stop_step "before the topology it watches is taken down" || {
        down_rc=1
        not_verified "the heartbeat daemon (its stop failed; sudo ndtwin-lab heartbeat status says whether it runs)"
    }')
nreport "N08: ndt down stops it after the topology" "$m" "🔴 before topo-stop"
m=$(nmutant n09 "$NDT" \
    '    heartbeat_stop_step "before the topology it watches is taken down" || {
        down_rc=1' \
    '    heartbeat_stop_step "before the topology it watches is taken down" || {
        true')
nreport "N09: a stop that failed is not a failed teardown" "$m" "🔴 a stop that failed: rc 1"
m=$(nmutant n09b "$NDT" \
    '        not_verified "the heartbeat daemon (its stop failed; sudo ndtwin-lab heartbeat status says whether it runs)"' \
    '        true')
nreport "N09b: the claim note does not say what was not verified" "$m" "🔴 and the claim note says what was not verified"
m=$(nmutant n10 "$NDT" \
    '    [[ -e "$HB_PIDFILE" || -L "$HB_PIDFILE" ]] || return 0' \
    '    true')
nreport "N10: the helper is asked to stop whatever the pidfile says" "$m" "🔴 no pidfile: the helper is not asked at all"
m=$(nmutant n11 "$NDT" \
    'heartbeat_stop_step "before the running topology is replaced" || true; sudo -n "$LAB" topo-stop' \
    'sudo -n "$LAB" topo-stop')
nreport "N11: replacing a topology leaves its heartbeat running" "$m" \
        "🔴 the old heartbeat was stopped before the old topology"
m=$(nmutant n12 "$NDT" \
    '        0) ok "heartbeat running on the inter-switch veths:' \
    '        0) heartbeat_stop_step "mutant"; ok "heartbeat running on the inter-switch veths:')
nreport "N12: the bring-up stops the heartbeat it just started" "$m" "  nothing was stopped on the way up"
m=$(nmutant n13 "$NDT" \
    '            heartbeat)
                heartbeat_stop_step "this bring-up is being rolled back" || rc=1
                ;;' \
    '            heartbeat)
                ;;')
nreport "N13: a rollback leaves the heartbeat running" "$m" "🔴 the rollback stopped the heartbeat"
m=$(nmutant n14 "$NDT" \
    '    up_started heartbeat
    out="$(sudo -n "$LAB" heartbeat start 2>&1)"; rc=$?' \
    '    UP_STARTED=(heartbeat ${UP_STARTED[@]+"${UP_STARTED[@]}"})
    out="$(sudo -n "$LAB" heartbeat start 2>&1)"; rc=$?')
nreport "N14: a rollback stops the heartbeat after the fabric" "$m" "🔴 before it stopped the topology"
m=$(nmutant n15 "$NDT" \
    '    # [Co-developed with claude code -- Adam] TICKET-P4-heartbeat segment W.
    heartbeat_row' \
    '    :')
nreport "N15: ndt status has no heartbeat row" "$m" "🔴 cmd_status prints the heartbeat row"
m=$(nmutant n16 "$NDT" \
    'if status == "running" and period > 0 and age <= 2 * period:' \
    'if status == "running":')
nreport "N16: a report nobody rewrote reads running" "$m" "🔴 a running report nobody rewrote reads STALE"
m=$(nmutant n17 "$NDT" \
    'if hosts:
    out +=' \
    'if False:
    out +=')
nreport "N17: a frame at a host is not named" "$m" "🔴 a frame that reached a host is named"
m=$(nmutant n18 "$NDT" \
    'if not os.path.exists(path):
    print(f"none -- no report at {path} (no heartbeat has run since boot)")' \
    'if False:
    print(f"none -- no report at {path} (no heartbeat has run since boot)")')
nreport "N18: no report reads as unreadable" "$m" "  no report at all"
m=$(nmutant n19 "$NDT" \
    'heartbeat_row() {
    local line' \
    'heartbeat_row() {
    local line
    sudo -n "$LAB" heartbeat status > /dev/null 2>&1')
nreport "N19: the row asks sudo" "$m" "🔴 reading it needs no sudo"
m=$(nmutant n20 "$NDT" \
    '    out = (f"running (pid {d.get('"'"'pid'"'"')}, session {d.get('"'"'session'"'"')}) -- {n} direction(s), "' \
    '    out = (f"running (session {d.get('"'"'session'"'"')}) -- {n} direction(s), "')
nreport "N20: the running row loses its pid" "$m" "🔴 a fresh running report reads running, with its pid"
m=$(nmutant n21 "$NDT" \
    '    n = len(d.get("directions") or [])' \
    '    n = 0')
nreport "N21: the running row miscounts its directions" "$m" "  and its directions"
m=$(nmutant n22 "$NDT" \
    '    out = f"{status} ({d.get('"'"'stop_reason'"'"')}), {age:.0f} s ago"' \
    '    out = f"{status}, {age:.0f} s ago"')
nreport "N22: a stopped row loses why" "$m" "  a stopped report reads stopped, with why"
m=$(nmutant n23 "$NDT" \
    '    print(f"report unreadable ({type(exc).__name__}: {exc})")' \
    '    print("none")')
nreport "N23: an unreadable report is not said" "$m" "  an unreadable report says so"
m=$(nmutant n24 "$NDT" \
    'HB_PIDFILE=/run/ndtwin-lab/heartbeat.pid' \
    'HB_PIDFILE=/run/ndtwin-lab/heartbeat.pidfile')
nreport "N24: ndt's pidfile is not the helper's" "$m" "🔴 ndt's pidfile is the helper's HB_PIDFILE"
m=$(nmutant n25 "$NDT" \
    'HB_REPORT=/run/ndtwin-lab/heartbeat.json' \
    'HB_REPORT=/run/ndtwin-lab/report.json')
nreport "N25: ndt reads a report the helper does not write" "$m" "🔴 ndt's report is the file the helper's daemon writes"
m=$(nmutant n26 "$HELPER" \
    '("heartbeat.pid", "heartbeat.lock", "heartbeat.json")' \
    '("hb.pid", "heartbeat.lock", "heartbeat.json")')
nreport "N26: (a helper COPY) spells its pidfile otherwise" "$m" "  (which the helper spells that way)"
m=$(nmutant n27 "$HELPER" \
    '("heartbeat.pid", "heartbeat.lock", "heartbeat.json")' \
    '("heartbeat.pid", "heartbeat.lock", "hb.json")')
nreport "N27: (a helper COPY) names its report otherwise" "$m" "  (which the helper names that way)"
m=$(nmutant n28 "$NDT" \
    '    [[ -n "$out" ]] && printf '"'"'%s\n'"'"' "$out" | sed '"'"'s/^/      /'"'"'
    case "$rc" in' \
    '    case "$rc" in')
nreport "N28: the helper's start answer is not printed" "$m" "  the helper's answer is printed"
m=$(nmutant n29 "$NDT" \
    '        0) ok "heartbeat running on the inter-switch veths:' \
    '        0) ok "started:')
nreport "N29: ndt does not say what the heartbeat is for" "$m" "  and ndt says what it is for"
m=$(nmutant n30 "$NDT" \
    '        *) warn "heartbeat did NOT start (rc $rc): a cut link on this fabric will not be detected."' \
    '        *) info "heartbeat: rc $rc"')
nreport "N30: a heartbeat that did not start is not said" "$m" "🔴 and it says detection is off"
m=$(nmutant n31 "$NDT" \
    '    out="$(sudo -n "$LAB" heartbeat start 2>&1)"; rc=$?' \
    '    out="$(sudo -n "$LAB" heartbeat start 2>/dev/null)"; rc=$?')
nreport "N31: the helper's reason for refusing is dropped" "$m" "  with the helper's reason"
m=$(nmutant n32 "$NDT" \
    '    out="$(sudo -n "$LAB" heartbeat stop 2>&1)"; rc=$?
    [[ -n "$out" ]] && printf '"'"'%s\n'"'"' "$out" | sed '"'"'s/^/      /'"'"'' \
    '    out="$(sudo -n "$LAB" heartbeat stop 2>&1)"; rc=$?')
nreport "N32: the helper's stop answer is not printed" "$m" "  the helper's stop answer is printed"
m=$(nmutant n33 "$NDT" \
    '        err "heartbeat stop exited $rc -- the heartbeat daemon may still be running (its own line is above)"' \
    '        :')
nreport "N33: a failed stop is not said" "$m" "  it says so"
m=$(nmutant n34 "$NDT" \
    '    heartbeat_up_step "$app_pipe" "$app_mode"' \
    '    heartbeat_up_step "$app_pipe" "$app_mode"; rollback_up "mutant" > /dev/null 2>&1')
nreport "N34: a successful bring-up is rolled back after its heartbeat" "$m" "  and no rollback happened"
m=$(nmutant n35 "$NDT" \
    '        3) info "heartbeat: nothing to watch -- this fabric has no inter-switch link (rc 3)" ;;' \
    '        3) info "heartbeat: rc 3" ;;')
nreport "N35: rc 3 is not said as what it is" "$m" "  said as what it is, in ndt's own words"
m=$(nmutant n36 "$NDT" \
    '    say "[2/3] topology session"
    sudo -n "$LAB" topo-stop 2>&1 | sed '"'"'s/^/      /'"'"'' \
    '    say "[2/3] topology session"
    sudo -n "$LAB" topo-stop 2>&1 | sed '"'"'s/^/      /'"'"'
    sudo -n "$LAB" cleanup > /dev/null 2>&1')
nreport "N36: (control of the counter) the teardown asks sudo once more" "$m" \
        "  and the teardown's own two sudo calls are the only ones"
m=$(nmutant n37 "$NDT" \
    '            stack)
                info "stopping what stack.sh started (kernel, proxy, Ryu)"' \
    '            heartbeat_x)
                info "stopping what stack.sh started (kernel, proxy, Ryu)"')
nreport "N37: a rollback does not stop the stack first" "$m" "  and after the stack"
m=$(nmutant n38 "$NDT" \
    '|| true; sudo -n "$LAB" topo-stop >/dev/null 2>&1; }' \
    '|| true; sudo -n "$LAB" topo-stop >/dev/null 2>&1; heartbeat_up_step "$app_pipe" "$app_mode"; }')
nreport "N38: the heartbeat starts before the new fabric is up" "$m" "  and a new one started after the new topology"
# --- every ndt check, seen red ---------------------------------------------------------------------
never=$(sort -u "$NDT_RED_LOG" | comm -23 "$NDT_CHECKS" - | /usr/bin/grep -vxF -f <(printf '%s\n' "$NDT_CONTROLS") || true)
controls_red=$(sort -u "$NDT_RED_LOG" | /usr/bin/grep -xF -f <(printf '%s\n' "$NDT_CONTROLS") || true)
if [[ -n "$never" ]]; then
    SURVIVORS=$((SURVIVORS+1))
    echo "🔴 ndt checks NEVER SEEN RED ($(/usr/bin/grep -c . <<<"$never")), none of them a named control:"
    sed 's/^/     /' <<<"$never"
else
    echo "every ndt check seen red except the $(/usr/bin/grep -c . <<<"$NDT_CONTROLS") named controls ($(wc -l < "$NDT_CHECKS") checks)"
fi
[[ -n "$controls_red" ]] && echo "  (controls that went red anyway: $(paste -sd';' <<<"$controls_red"))"

# === 08_heartbeat.sh --self-test ===================================================================
echo
echo "08_heartbeat.sh --self-test"
lmutant() {   # $1 = label, $2 = file (08), $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"
    mkdir -p "$d/$LIVE_DIR_REL" "$d/tools/test_workflow" "$d/doc/audit/2026-09-25_p4-heartbeat/spike" "$d/tmp"
    cp "$REPO/$LIVE_DIR_REL/_common.sh" "$LIVE08" "$d/$LIVE_DIR_REL/"
    cp "$REPO/tools/test_workflow/faults.sh" "$REPO/tools/test_workflow/qdisc_snapshot.sh" "$d/tools/test_workflow/"
    cp "$REPO/doc/audit/2026-09-25_p4-heartbeat/spike/census_prepare.py" "$d/doc/audit/2026-09-25_p4-heartbeat/spike/"
    python3 - "$d/$LIVE_DIR_REL/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert a != b, "identity mutation: %s" % a[:70]
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}
lrun() { ( cd "$1" && TMPDIR="$1/tmp" timeout 300 bash "$LIVE_DIR_REL/08_heartbeat.sh" --self-test 2>&1 ); }
lreport() {   # $1 = mutation name, $2 = mutant dir, $3 = the self-test case that must go red
    local out
    MUTATIONS=$((MUTATIONS+1))
    out=$(lrun "$2")
    if /usr/bin/grep -qF "🔴    $3" <<<"$out" && /usr/bin/grep -q '^SELF-TEST FAIL' <<<"$out"; then
        printf '  caught   %-70s (self-test case "%s" went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (self-test case "%s" stayed green)\n' "$1" "$3"
        /usr/bin/grep -E '🔴|SELF-TEST' <<<"$out" | head -4 | sed 's/^/             /'
    fi
    rm -rf "$2"
}
lb="$BK/lbase"
mkdir -p "$lb/$LIVE_DIR_REL" "$lb/tools/test_workflow" "$lb/doc/audit/2026-09-25_p4-heartbeat/spike" "$lb/tmp"
cp "$REPO/$LIVE_DIR_REL/_common.sh" "$LIVE08" "$lb/$LIVE_DIR_REL/"
cp "$REPO/tools/test_workflow/faults.sh" "$REPO/tools/test_workflow/qdisc_snapshot.sh" "$lb/tools/test_workflow/"
cp "$REPO/doc/audit/2026-09-25_p4-heartbeat/spike/census_prepare.py" "$lb/doc/audit/2026-09-25_p4-heartbeat/spike/"
if [[ "$(lrun "$lb" | tail -1)" == "SELF-TEST PASS" ]]; then
    echo "  08 self-test baseline: SELF-TEST PASS"
else
    echo "  08 self-test baseline is RED -- its mutations would prove nothing"; exit 2
fi
rm -rf "$lb"

m=$(lmutant l01 "$LIVE08" \
    '       if (s.get("capabilities") or {}).get("reroute") is not want' \
    '       if False')
lreport "L01: caps accepts any reroute" "$m" "H1 one switch says reroute false"
m=$(lmutant l02 "$LIVE08" \
    '    got = (r.get("available"), r.get("reason"))' \
    '    got = want')
lreport "L02: reroute accepts any answer" "$m" "H1 unavailable is not available"
m=$(lmutant l03 "$LIVE08" \
    '    if h.get("state") == want:' \
    '    if True:')
lreport "L03: hb_state accepts any state" "$m" "H1 a stopped heartbeat is not usable"
m=$(lmutant l04 "$LIVE08" \
    '    n = side.get("forwarded_to_hosts", 0) or 0' \
    '    n = 0')
lreport "L04: ruling 4 is never a STOP" "$m" "ruling 4: the daemon counted one (report)"
m=$(lmutant l05 "$LIVE08" \
    '    if f is not None and r is not None and f[1] is False and r[1] is False:' \
    '    if f is not None and r is not None and (f[1] is False or r[1] is False):')
lreport "L05: one direction down counts as the cut" "$m" "H1 only one direction down"
m=$(lmutant l06 "$LIVE08" \
    '    if f == (True, True) and r == (True, True):' \
    '    if f == (True, True) or r == (True, True):')
lreport "L06: one direction back up counts as recovered" "$m" "H1 only one direction back up"
m=$(lmutant l07 "$LIVE08" \
    '        if into:' \
    '        if False:')
lreport "L07: a route still into the cut is not a failure" "$m" "H1 s3 still routes into the cut"
m=$(lmutant l08 "$LIVE08" \
    '        if set(pre) - set(post):' \
    '        if False:')
lreport "L08: a lost destination is not a failure" "$m" "H1 a destination lost its route"
m=$(lmutant l09 "$LIVE08" \
    '    if not used:
        return f"BAD before the cut no route used' \
    '    if False:
        return f"BAD before the cut no route used')
lreport "L09: a cut nothing routed over passes" "$m" "H1 a cut nothing routed over proves nothing"
m=$(lmutant l10 "$LIVE08" \
    '        if ap in pa.values() or bp in pb.values():' \
    '        if True:')
lreport "L10: pick_cut takes the first cable whether used or not" "$m" "  pick_cut on unused s1-s3 chose"
m=$(lmutant l11 "$LIVE08" \
    '    if s <= float(bound):' \
    '    if s <= float(bound) + 1.0:')
lreport "L11: the 20 s bound has a second of slack" "$m" "H1 over 20 s"
m=$(lmutant l12 "$LIVE08" \
    '    bad = [l for l in lines if "  OK " not in l]' \
    '    bad = []')
lreport "L12: H2 does not see the cut go down" "$m" "H2 went down once"
m=$(lmutant l13 "$LIVE08" \
    '    if c == "501" and d.get("outcome") == "unsupported_on_p4" and d.get("reason") == "unbound":' \
    '    if c == "501":')
lreport "L13: any 501 is the unbound refusal" "$m" "H3 501 for another reason"
m=$(lmutant l14 "$LIVE08" \
    '    if c == "409" and d.get("error") == "external control plane":' \
    '    if c in ("409", "500"):')
lreport "L14: the old 500 passes H4" "$m" "H4 the 500 of before"
m=$(lmutant l15 "$LIVE08" \
    '    diff = [f"{k[0]}/{k[1]}: {a.get(k)} vs {b[k]}" for k in sorted(b) if a.get(k) != b[k]]' \
    '    diff = [f"{k[0]}/{k[1]}" for k in sorted(b) if k not in a]')
lreport "L15: H5 compares arms by presence only" "$m" "H5 one arm differs"
m=$(lmutant l16 "$LIVE08" \
    '        if arm not in want and new:' \
    '        if False:')
lreport "L16: H5 misses a heartbeat on an arm that should have none" "$m" "H5 an arm that should have none had one"
m=$(lmutant l17 "$LIVE08" \
    '    leak = [s for s in ss if s["hosts"] not in ("0", "", "None")]' \
    '    leak = []')
lreport "L17: H5 never STOPs for ruling 4" "$m" "H5 ruling 4 in a sample"
m=$(lmutant l18 "$LIVE08" \
    '        if [[ "$TEARDOWN_DOWN_RC" != 0 && "$TEARDOWN_DOWN_RC" != 3 ]]; then
            keep_claim' \
    '        if false; then
            keep_claim')
lreport "L18: a refused down is released anyway (segment S round 7)" "$m" \
        "🔴 a refused down ended"
m=$(lmutant l19 "$LIVE08" \
    '    env -u NDT_MEASURING "$REAL_NDT" down > "$1" 2>&1 && rc=0 || rc=$?' \
    '    "$REAL_NDT" down > "$1" 2>&1 && rc=0 || rc=$?')
lreport "L19: a phase's down runs under the caller's measuring=" "$m" \
        "🔴 nd_down:"
m=$(lmutant l20 "$LIVE08" \
    'if [[ "${1:-}" != "--self-test" && -z "${NDT_OWNER:-}" ]]; then' \
    'if false; then')
lreport "L20: no NDT_OWNER is not refused" "$m" "🔴 no NDT_OWNER:"
m=$(lmutant l21 "$LIVE08" \
    ': "${CLAIM_MINUTES:=120}"' \
    ': "${CLAIM_MINUTES_08:=120}"')
lreport "L21: the claim's minutes are _common.sh's 45" "$m" \
        "🔴 CLAIM_MINUTES after the prelude"
m=$(lmutant l22 "$LIVE08" \
    '# 🔴 This script never declares a measurement; see the header.
unset NDT_MEASURING' \
    '# 🔴 This script never declares a measurement; see the header.
:')
lreport "L22: a caller's NDT_MEASURING survives the prelude" "$m" "  NDT_MEASURING after the prelude"
m=$(lmutant l23 "$LIVE08" \
    '        if (( rc == 3 && FABRIC_UP == 0 )); then
            echo "08: '"'"'ndt down'"'"' answered 3 (nothing was up) -- this run had already taken its own fabric down"' \
    '        if false; then
            echo "08: '"'"'ndt down'"'"' answered 3 (nothing was up) -- this run had already taken its own fabric down"')
lreport "L23: a run that took its own fabric down fails on finish's rc 3" "$m" \
        "a run already down ended"
m=$(lmutant l24 "$LIVE08" \
    'k = max(1, math.ceil((now + 0.3 - last - phi) / p))' \
    'k = 1')
lreport "L24: the cut is planned for a round already past" "$m" "  too close gave"
m=$(lmutant l25 "$LIVE08" \
    '    if (( $1 <= H1_WORST )); then echo "$PHI_WORST"; return; fi' \
    '    :')
lreport "L25: no cycle is cut at the worst phase" "$m" "phase_for gave"
m=$(lmutant l26 "$LIVE08" \
    'if len(ts) == 2 and all(isinstance(t, (int, float)) for t in ts):
    print(f"{max(ts):.3f}")' \
    'if len(ts) == 2 and all(isinstance(t, (int, float)) for t in ts):
    print(f"{min(ts):.3f}")')
lreport "L26: the cut's phase is measured from the EARLIER direction" "$m" "report_last gave"

m=$(lmutant l27 "$LIVE08" \
    '    if worst == "1" and phi > 1.0:' \
    '    if False:')
lreport "L27: a worst-phase cycle that missed its phase counts" "$m" "cycle: a worst-phase cut that landed before the round"
m=$(lmutant l28 "$LIVE08" \
    '    rep = [p for p in passes if (p.get("down") or 0) > 0 and p.get("start_mono", 0) >= l]' \
    '    rep = passes or [{"start_mono": 0.0}]')
lreport "L28: any pass is taken as the one that reported" "$m" "cycle: no reporting pass served"

# --- a control that must stay green ----------------------------------------------------------------
m=$(mutant c1 "$HBMOD" \
    '#: The daemon'"'"'s report is a few KiB; anything past this is not one.' \
    '# MUTANT: a comment, and nothing else.
#: The daemon'"'"'s report is a few KiB; anything past this is not one.')
out=$(run_against "$m"); rc=$?
if [[ "$rc" -eq 0 ]]; then echo "  green    C1 (control): a comment-only edit in link_heartbeat.py"
else SURVIVORS=$((SURVIVORS+1)); echo "  🔴 RED   C1 (control): a comment-only edit went red -- these suites detect change, not behaviour"; fi
rm -rf "$m"

# --- every new proxy test, seen red ------------------------------------------------------------------
echo
never=$(sort -u "$RED_LOG" | comm -23 "$NEW_IDS" -)
total=$(wc -l < "$NEW_IDS")
if [[ -n "$never" ]]; then
    SURVIVORS=$((SURVIVORS+1))
    echo "🔴 NEVER SEEN RED: $(/usr/bin/grep -c . <<<"$never") of $total new proxy test(s):"
    sed 's/^/     /' <<<"$never"
else
    echo "every new proxy test seen red: $total of $total"
fi

echo
for f in "${SOURCES[@]}"; do
    [[ "$(sha256sum "$f" | cut -d' ' -f1)" == "${BASE_SHA[$f]}" ]] \
        || { echo "🔴 baseline CHANGED -- ${f#"$REPO/"} was written during the gate"; exit 3; }
done
echo "baseline byte-identical: yes (${#SOURCES[@]} sources, the root helper among them)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
