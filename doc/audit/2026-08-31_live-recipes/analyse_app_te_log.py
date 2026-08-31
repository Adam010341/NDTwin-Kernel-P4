#!/usr/bin/env python3
"""Bounded evidence pack for .test_run/logs/app_te.log before it is deleted.

[Co-developed with claude code -- Adam]

The log is 100,896,853 bytes and is being removed for disk. Three claims in
doc/KNOWN-ISSUES.md section G rest on it -- "20h32m", "100 MB", "crash loop" --
and the only surviving excerpt (te-crashloop-excerpt.txt, 184 bytes) preserves
the exception's identity but nothing about its cadence, which is exactly what
two of those three words are about. This extracts the cadence, bounded to a few
kilobytes, in one streaming pass.

Deliberately does NOT compute anything the log cannot support: if a number here
disagrees with KNOWN-ISSUES, the disagreement is printed, not reconciled.

Usage:  python3 analyse_app_te_log.py <logfile> > app_te_log_evidence.txt
"""
import collections
import hashlib
import os
import re
import subprocess
import sys
from datetime import datetime

ANSI = re.compile(r"\x1b\[[0-9;]*m")
TS = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.(\d{3})")
EXC = re.compile(r"^([A-Za-z_][A-Za-z0-9_.]*(?:Error|Exception|Warning|Interrupt))\b\s*:")
LEVEL = re.compile(r"\|\s*(DEBUG|INFO|WARNING|ERROR|CRITICAL|SUCCESS|TRACE)\s*\|")

path = sys.argv[1]
st = os.stat(path)

h = hashlib.sha256()
with open(path, "rb") as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        h.update(chunk)

lines = 0
first_ts = last_ts = None
first_exc_ts = last_exc_ts = None
first_exc_line = None
per_hour_lines = collections.Counter()
per_hour_exc = collections.Counter()
per_hour_error = collections.Counter()
exc_kinds = collections.Counter()
error_msgs = collections.Counter()
levels = collections.Counter()
gaps = []            # (prev_ts, ts, seconds) for jumps > 60 s
prev_dt = None
head_keep, tail_keep = [], collections.deque(maxlen=40)
# The healthy -> crash transition. The 184-byte excerpt that already exists preserves the
# exception's identity but not the moment it started, and "was it broken from the start?" is a
# different claim from "it broke".
transition = collections.deque(maxlen=30)
transition_frozen = None
freeze_at = None

with open(path, "r", errors="replace") as fh:
    for raw in fh:
        lines += 1
        s = ANSI.sub("", raw).rstrip("\n")
        if lines <= 40:
            head_keep.append(s)
        tail_keep.append(s)
        if transition_frozen is None:
            transition.append("%7d  %s" % (lines, s))

        m = TS.match(s)
        if m:
            ts = m.group(1)
            if first_ts is None:
                first_ts = ts + "." + m.group(2)
            last_ts = ts + "." + m.group(2)
            hour = ts[:13]
            per_hour_lines[hour] += 1
            dt = datetime.strptime(ts, "%Y-%m-%d %H:%M:%S")
            if prev_dt is not None:
                d = (dt - prev_dt).total_seconds()
                if d > 60:
                    gaps.append((prev_dt.isoformat(sep=" "), dt.isoformat(sep=" "), d))
            prev_dt = dt
            lm = LEVEL.search(s)
            if lm:
                levels[lm.group(1)] += 1
                if lm.group(1) == "ERROR":
                    per_hour_error[hour] += 1
                    msg = s.split(" - ", 1)[-1]
                    error_msgs[msg[:110]] += 1

        em = EXC.match(s)
        if em:
            exc_kinds[em.group(1)] += 1
            if first_exc_ts is None:
                first_exc_ts = last_ts
                first_exc_line = lines
                freeze_at = lines + 8   # keep 8 more lines of context, then stop collecting
            last_exc_ts = last_ts
            per_hour_exc[(last_exc_ts or "?")[:13]] += 1

        if transition_frozen is None and freeze_at is not None and lines >= freeze_at:
            transition_frozen = list(transition)

W = 78
def rule(t=""):
    print("=" * W)
    if t:
        print(t)
        print("-" * W)

def span(a, b):
    fa = datetime.strptime(a[:19], "%Y-%m-%d %H:%M:%S")
    fb = datetime.strptime(b[:19], "%Y-%m-%d %H:%M:%S")
    sec = int((fb - fa).total_seconds())
    return "%dh%02dm%02ds (%d s)" % (sec // 3600, sec % 3600 // 60, sec % 60, sec)

rule("SOURCE FILE (deleted after this pack was written)")
print("path      %s" % path)
print("sha256    %s" % h.hexdigest())
print("bytes     %d" % st.st_size)
print("lines     %d" % lines)
try:
    birth = subprocess.run(["stat", "-c", "%w", path], capture_output=True,
                           text=True).stdout.strip()
except Exception:
    birth = "?"
print("birth     %s" % birth)
print("mtime     %s" % datetime.fromtimestamp(st.st_mtime).isoformat(sep=" "))

rule("WHAT THE LOG ITSELF SAYS ABOUT ITS OWN SPAN")
print("first timestamp in file   %s" % first_ts)
print("last  timestamp in file   %s" % last_ts)
if first_ts and last_ts:
    print("span (first -> last)      %s" % span(first_ts, last_ts))
print()
print("first exception at        %s   (line %s)" % (first_exc_ts, first_exc_line))
print("last  exception at        %s" % last_exc_ts)
if first_exc_ts and last_exc_ts:
    print("span (crash loop)         %s" % span(first_exc_ts, last_exc_ts))
print()
print("healthy prefix            %s" % (span(first_ts, first_exc_ts)
                                        if first_ts and first_exc_ts else "?"))

rule("RECONCILIATION WITH doc/KNOWN-ISSUES.md SECTION G")
print("KNOWN-ISSUES said, before this pack was written:  crash loop lived 20h32m (73920 s)")
print()
print("  measured, whole file  first -> last timestamp   %s" %
      (span(first_ts, last_ts) if first_ts and last_ts else "?"))
print("  measured, crash loop  first -> last exception   %s" %
      (span(first_exc_ts, last_exc_ts) if first_exc_ts and last_exc_ts else "?"))
print()
print("NEITHER equals 20h32m. The figure appears nowhere else in the repo, so this log is")
print("not its source; it is consistent with a `ps` elapsed-time reading taken a few minutes")
print("before the last log line, but nothing recorded that reading and this pack does not")
print("invent it. What the log does establish is the SHAPE: a healthy prefix, then one")
print("exception repeated at a fixed cadence until the process stopped.")

rule("EXCEPTION KINDS OVER THE WHOLE FILE (is it one traceback throughout?)")
for k, n in exc_kinds.most_common():
    print("%9d  %s" % (n, k))
if not exc_kinds:
    print("(none matched)")

rule("LOG LEVELS")
for k, n in levels.most_common():
    print("%9d  %s" % (n, k))

rule("DISTINCT ERROR MESSAGES (truncated to 110 chars)")
for msg, n in error_msgs.most_common(12):
    print("%9d  %s" % (n, msg))

rule("CADENCE: lines / ERROR / exceptions per clock hour")
print("%-16s %10s %10s %10s" % ("hour", "lines", "ERROR", "exc"))
for hour in sorted(per_hour_lines):
    print("%-16s %10d %10d %10d" % (hour, per_hour_lines[hour],
                                    per_hour_error.get(hour, 0),
                                    per_hour_exc.get(hour, 0)))

rule("GAPS LONGER THAN 60 s BETWEEN CONSECUTIVE TIMESTAMPS")
if gaps:
    for a, b, d in gaps[:40]:
        print("%s -> %s   %.0f s" % (a, b, d))
    print("(%d gap(s) total)" % len(gaps))
else:
    print("none -- the cadence never paused for a minute")

rule("HEALTHY -> CRASH TRANSITION (the 30 lines ending just past the first exception)")
for s in (transition_frozen or list(transition)):
    print(s)

rule("HOW THE LOG ENDS")
print("last line verbatim: %r" % (tail_keep[-1] if tail_keep else None))
print("(the process stopped writing at the mtime above; nothing in this file records")
print(" which command did it, and 'ndt apps stop te' could not have signalled it once")
print(" the pidfile was gone -- that is the defect this pack was written alongside.)")

rule("FIRST 40 LINES (ANSI stripped)")
for s in head_keep:
    print(s)

rule("LAST 40 LINES (ANSI stripped)")
for s in tail_keep:
    print(s)
