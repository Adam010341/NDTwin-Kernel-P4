#!/usr/bin/env bash
#
# oldcode_selftest.sh -- can the spike's --self-test tell each fix from the code it replaced?
#
# [Co-developed with claude code -- Adam]
#
# Judge R4-4 (round-4 verdict): the round-4 evidence of discrimination came from a tool that lived
# only in a session scratchpad; the logs kept its effect, not its method. This is that tool, in the
# repo, extended to the round-5 fixes.
#
# For each REVERT below: a copy of S_heartbeat_spike.sh and a copy of hb_watch.py are written
# BESIDE the real ones (same directory, so SPIKE_DIR / LIVE_P1 / REPO resolve exactly as for the
# real script; the spike copy's WATCH points at the hb_watch copy), with that one fix put back to
# its old form -- every edit is asserted to apply exactly as many times as it is written for, and
# the diff is printed. Then the COPY's own --self-test runs: its `declare -f` drivers carry the
# copy's functions, so the new checks run against the old code. A revert passes only if
#   * the self-test exits non-zero, and
#   * its red lines are exactly the ones written for that fix: every expected line red exactly
#     once, no other line red, and each expected line carries the reason given for it.
# The CONTROL (the same copying, no revert) must exit 0 with no red line: the copying itself
# changes nothing a check can see.
#
#   bash doc/audit/2026-09-25_p4-heartbeat/spike/oldcode_selftest.sh           # every revert
#   bash doc/audit/2026-09-25_p4-heartbeat/spike/oldcode_selftest.sh R4-2 r3   # just these
#   bash doc/audit/2026-09-25_p4-heartbeat/spike/oldcode_selftest.sh --list
#
# Touches no lab: what runs is the spike's --self-test, with SELFTEST_PROBE_SUDO and FAULTS_TC
# removed from its environment (the opt-in sudo probe stays off). The copies are removed on exit.
# Exit 0: every requested revert discriminates (and the control is clean); 1 otherwise; 2 usage,
# or an edit that does not apply (the tool no longer matches the spike -- not a pass).
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="oldcode-$$"
trap 'rm -f "$D"/."$TAG"-*' EXIT INT TERM
/usr/bin/python3 -I - "$D" "$TAG" "$@" <<'PY'
import difflib
import os
import re
import subprocess
import sys

D, TAG, ARGS = sys.argv[1], sys.argv[2], sys.argv[3:]
SPIKE, WATCH = os.path.join(D, "S_heartbeat_spike.sh"), os.path.join(D, "hb_watch.py")

# name -> (what it puts back, [(file, new text, old text, count)], [(red-line text, reason text)])
# The red-line text is matched inside a line that carries the red mark; the reason must be in
# that same line. An empty reason asks for nothing beyond the line itself.
REVERTS = {
    "control": ("nothing -- the copying alone", [], []),
    "r3": ("round 4's two set -e fixes (judge R3-1: bare watch_hit; the round-4 audit: bare return)", [
        ("spike", '    [[ "$v" == OK* ]] || return 0\n', '    [[ "$v" == OK* ]] || return\n', 1),
        ("spike", 'watch_hit "$dir" "$stopf" || true; return 0; fi', 'watch_hit "$dir" "$stopf"; return 0; fi', 2),
    ], [
        ("a clean window under set -e: rc 1", ""),
        ("a detection part that fails its first check ended the run under set -e: rc 1", ""),
        # added in round 5: the census arm's clean window is the same bare watch_hit, at its call site
        ("a census arm with the new daemon's report: died", ""),
    ]),
    "R4-1": ("the whole R4-1 fix: census's old session block, wait_session's old call, hb_watch's old `session`", [
        ("watch", '        print(session_of(load(argv[2]), int(argv[3])))\n',
                  '        print(load(argv[2]).get("session") or "")\n', 1),
        ("spike", 's="$(/usr/bin/python3 -I "$WATCH" session "$1" "$3" 2>/dev/null)" || s=""',
                  's="$(/usr/bin/python3 -I "$WATCH" session "$1" 2>/dev/null)" || s=""', 1),
        ("spike", '''        # The daemon THIS start started (judge R4-1): its pid from start's own answer, and the
        # session only from a running report of that pid. "already running" names no pid here.
        hb_pid="$(/usr/bin/python3 -I "$WATCH" started-pid "$dir/11_hb_start.txt" 2>/dev/null)" || hb_pid=""
        session=""
        if [[ -n "$hb_pid" ]]; then
            session="$(wait_session "$HB_REPORT" 20 "$hb_pid")" || session=""
        fi
        if [[ -z "$session" ]]; then
            printf '%s\\t%s\\tyes\\tno session in 5 s\\t-\\n' "$ex" "$which" >> "$RUN/40_census.tsv"
            if [[ -n "$hb_pid" ]]; then
                fail "census $ex/$which: the heartbeat started (pid $hb_pid) but no running report of that pid carries a session after 5 s"
            else
                fail "census $ex/$which: 'heartbeat start' answered 0 without saying it started a daemon -- see 11_hb_start.txt"
            fi
''', '''        if ! session="$(wait_session "$HB_REPORT" 20)"; then
            printf '%s\\t%s\\tyes\\tno session in 5 s\\t-\\n' "$ex" "$which" >> "$RUN/40_census.tsv"
            fail "census $ex/$which: the heartbeat started but its report carries no session after 5 s"
''', 1),
    ], [
        ("the previous arm's final 'stopped' report was taken for the new session", "a1a1a1a1a1a1a1a1"),
        ("a 'stopped' report of the pid start named was taken for a session", "b2b2b2b2b2b2b2b2"),
        ("a 'running' report of another pid was taken for the new session", "c3c3c3c3c3c3c3c3"),
        ("an arm whose report is still the previous arm's 'stopped' one", "sniff h1 a1a1a1a1a1a1a1a1"),
        ("an arm whose start answered 'already running'", "sniff h1 d4d4d4d4d4d4d4d4"),
    ]),
    "R4-1/status": ("half of R4-1: session_of without its `status == running` clause", [
        ("watch", '    if doc.get("status") != "running":\n        return ""\n', '', 1),
    ], [
        ("session: a stopped report is none, even of that pid", "False"),
        ("a 'stopped' report of the pid start named was taken for a session", "b2b2b2b2b2b2b2b2"),
    ]),
    "R4-1/pid": ("the other half of R4-1: session_of without its pid clause", [
        ("watch", '    if doc.get("pid") != pid:\n        return ""\n', '', 1),
    ], [
        ("session: a running report of another pid is none", "False"),
        ("a 'running' report of another pid was taken for the new session", "c3c3c3c3c3c3c3c3"),
    ]),
    "R4-2": ("R4-2: `cut_link || break` -- a half-done cut left to the EXIT trap", [
        ("spike", 'cut_link || { restore_link || fail "cycle $i: could not remove the netem a half-done cut left on $CUT_A"; break; }',
                  'cut_link || break', 1),
    ], [
        ("a half-done cut: rc 0", "teardown said: cannot locate the netem"),
    ]),
    "R4-3": ("R4-3: the census table through a bare `column | sed` under pipefail", [
        ("spike", '    show_census "$RUN/40_census.tsv"\n',
                  r'''    column -t -s $'\t' "$RUN/40_census.tsv" | sed 's/^/   /'
''', 1),
    ], [
        ("the census table without 'column' ended the run: rc 127", "column: command not found"),
    ]),
    "R4-3/d-i": ("judge (d)(i): hb_watch all-heard / others-up with a bare load()", [
        ("watch", '''        try:
            print(all_heard(load(argv[2]), float(argv[3])))
        except (OSError, ValueError, KeyError) as exc:
            print(f"BAD the report could not be read: {exc!r}")
''', '''        print(all_heard(load(argv[2]), float(argv[3])))
''', 1),
        ("watch", '''        try:
            print(others_up(load(argv[2]), parse_dirs(argv[3]), time.monotonic(), float(argv[4])))
        except (OSError, ValueError, KeyError) as exc:
            print(f"BAD the report could not be read: {exc!r}")
''', '''        print(others_up(load(argv[2]), parse_dirs(argv[3]), time.monotonic(), float(argv[4])))
''', 1),
    ], [
        ("all-heard on a report that cannot be read: BAD, rc 0", "raised FileNotFoundError"),
        ("others-up on a report that cannot be read: BAD, rc 0", "raised FileNotFoundError"),
    ]),
    # Every detect scenario that gets past the first check reads QDISC_TOOL, so both of them go red
    # when the driver lacks it -- by construction, and for that one reason.
    "R4-5": ("R4-5: the detect driver without QDISC_TOOL", [
        ("spike", '''        printf 'QDISC_TOOL=%q\\n' "$st_tmp/fake_qdisc_tool"\n''', '', 1),
    ], [
        ("a detection cycle that goes as designed: rc 1", "QDISC_TOOL: unbound variable"),
        ("a half-done cut: rc 1", "QDISC_TOOL: unbound variable"),
    ]),
}
RED = "\U0001f534"

if ARGS == ["--list"]:
    for name, (what, _, want) in REVERTS.items():
        print(f"{name:12s} {what}  -> {len(want)} red line(s)")
    sys.exit(0)
names = ARGS or list(REVERTS)
unknown = [n for n in names if n not in REVERTS]
if unknown:
    print(f"unknown revert(s): {' '.join(unknown)} (--list)", file=sys.stderr)
    sys.exit(2)
if "control" not in names:
    names = ["control"] + names          # every answer is read against a clean control

originals = {"spike": open(SPIKE).read(), "watch": open(WATCH).read()}
env = {k: v for k, v in os.environ.items() if k not in ("SELFTEST_PROBE_SUDO", "FAULTS_TC")}
rows, all_ok = [], True
for n, name in enumerate(names):
    what, edits, want = REVERTS[name]
    text = dict(originals)
    for f, new, old, count in edits:
        found = text[f].count(new)
        if found != count:
            print(f"### {name}: the edit on {f} applies {found} time(s), written for {count} -- the tool "
                  f"no longer matches the spike; nothing was run\n    looked for: {new[:120]!r}")
            sys.exit(2)
        text[f] = text[f].replace(new, old)
    stem = os.path.join(D, f".{TAG}-{n}")
    watch_copy, spike_copy = stem + "-hb_watch.py", stem + "-spike.sh"
    repoint = 'WATCH="$SPIKE_DIR/hb_watch.py"\n'
    if text["spike"].count(repoint) != 1:
        print(f"### the spike no longer sets WATCH as {repoint!r}; nothing was run")
        sys.exit(2)
    text["spike"] = text["spike"].replace(repoint, f'WATCH="$SPIKE_DIR/{os.path.basename(watch_copy)}"\n')
    try:
        with open(watch_copy, "w") as fh:
            fh.write(text["watch"])
        with open(spike_copy, "w") as fh:
            fh.write(text["spike"])
        print(f"\n### {name}: {what}")
        print("### the copies differ from this checkout's files exactly by:")
        for f, path in (("watch", WATCH), ("spike", SPIKE)):
            sys.stdout.writelines(difflib.unified_diff(originals[f].splitlines(True), text[f].splitlines(True),
                                                       path, os.path.basename(spike_copy if f == "spike" else watch_copy), n=0))
        p = subprocess.run(["bash", spike_copy, "--self-test"], env=env, capture_output=True, text=True)
    finally:
        for path in (watch_copy, spike_copy):
            try:
                os.remove(path)
            except OSError:
                pass
    out = p.stdout + p.stderr
    reds = [l.rstrip() for l in out.splitlines() if RED in l]
    print("### its --self-test (SELFTEST_PROBE_SUDO and FAULTS_TC unset): rc", p.returncode)
    for l in reds:
        print(l)
    for l in out.splitlines():
        if re.search(r"SELF-TEST (PASS|FAIL)", l):
            print(l)
    problems = []
    matched = set()
    for text_, reason in want:
        hits = [i for i, l in enumerate(reds) if text_ in l]
        if len(hits) != 1:
            problems.append(f"expected red once, got {len(hits)}: {text_!r}")
            continue
        matched.add(hits[0])
        if reason and reason not in reds[hits[0]]:
            problems.append(f"red, but not for its reason ({reason!r} missing): {text_!r}")
    for i, l in enumerate(reds):
        if i not in matched:
            problems.append(f"red that no expectation names: {l.strip()[:160]!r}")
    if name == "control":
        if p.returncode != 0:
            problems.append(f"the control's self-test exited {p.returncode}")
    elif p.returncode == 0:
        problems.append("the self-test exited 0 with the old code in place")
    ok = not problems
    all_ok &= ok
    for pr in problems:
        print("### PROBLEM:", pr)
    print(f"### {name}: {'DISCRIMINATES' if name != 'control' and ok else 'CLEAN' if ok else 'UNEXPECTED'}")
    rows.append((name, p.returncode, len(reds), len(want), "ok" if ok else "UNEXPECTED"))

print("\n### per revert: the copy's self-test rc, red lines, red lines written for it, verdict")
print(f"    {'revert':12s} {'rc':>3s} {'red':>4s} {'want':>5s}  verdict")
for name, rc, nred, nwant, v in rows:
    print(f"    {name:12s} {rc:3d} {nred:4d} {nwant:5d}  {v}")
print("OLD CODE IS RED IN EXACTLY ITS OWN CHECKS, EVERY REVERT" if all_ok else "UNEXPECTED -- see PROBLEM lines")
sys.exit(0 if all_ok else 1)
PY
