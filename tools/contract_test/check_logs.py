#!/usr/bin/env python3
"""
Check an NDTwin kernel log against warning_allowlist.txt.

Replaces "scroll the log and see if anything looks bad" with a pass/fail gate:

  * any error/critical line fails, unless explicitly allowlisted
  * any warning line fails unless allowlisted -- so a NEW warning cannot hide among
    the ones you already accepted
  * FORBID patterns fail at any level, for messages whose severity is worse than the
    level they are logged at
  * WHEN-POWERED-OFF patterns are permitted only for the switches --powered-off names,
    and are undecidable (not failed) when nothing was declared. See WHEN_POWERED_OFF below
  * allowlist entries that never matched are reported, so the file does not rot

Usage
-----
  ./check_logs.py kernel.log
  ./check_logs.py kernel.log --allowlist my_allowlist.txt
  ./check_logs.py kernel.log --powered-off 5,7,9   # the Energy-Saving-App turned these off
  ./check_logs.py kernel.log --powered-off none    # assert that nothing is off
  ./check_logs.py kernel.log --suggest-allowlist     # bootstrap on an existing log
  cat kernel.log | ./check_logs.py -

Exit code
---------
  0  the log is clean
  1  crashes, or problem lines -- a claim about the system
  2  usage error (allowlist missing)
  3  TOOL-PRECONDITION-FAILED -- this run could not establish what it needed before
     judging, so it makes no claim about the log. Distinct from 1 on purpose: a tool
     must never be able to fail in a way that looks like the system failing
     (KNOWN-ISSUES A-8). [Co-developed with claude code -- Adam]

Log format comes from Logger::init in src/utils/Logger.cpp:
  [2026-07-27 10:00:00.123] [info] [File.cpp:123 func] message
with ANSI colour around file/line/function, which is stripped before matching.

[Co-developed with claude code -- Adam]
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import Counter, OrderedDict

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# [timestamp] [level] [file:line func] message
LINE = re.compile(
    r"^\[(?P<ts>[^\]]+)\]\s*"
    r"\[(?P<level>trace|debug|info|warning|error|critical)\]\s*"
    r"(?:\[(?P<where>[^\]]*)\]\s*)?"
    r"(?P<msg>.*)$",
    re.IGNORECASE,
)

FAIL_LEVELS = {"error", "critical"}
WARN_LEVELS = {"warning"}

# Crash and abort messages are written by the runtime, not by spdlog, so they never match
# the log format above and were being discarded by --ignore-unparsed -- putting the single
# most important signal in the checker's blind spot. These always fail, on any line,
# parsed or not, and cannot be allowlisted.
CRASH_PATTERNS = [
    (re.compile(r"terminate called after throwing", re.I),
     "unhandled exception reached std::terminate"),
    (re.compile(r"terminate called recursively", re.I), "recursive terminate"),
    # [Co-developed with claude code -- Adam]
    # KNOWN-ISSUES B-5. The third wording, and the one the kernel actually printed: std::terminate
    # with no exception in flight, which in practice means a joinable std::thread was destroyed.
    # It was missing here, so the abort the kernel raised on every Ctrl-C shutdown would have
    # passed this gate even on the runs whose logs did capture it. The catch-all below covers a
    # fourth wording; both are ordered after the specific ones so the reported reason stays the
    # most precise one that matches.
    (re.compile(r"terminate called without an active exception", re.I),
     "std::terminate with no exception in flight -- a joinable std::thread was destroyed, "
     "or a rethrow with nothing to rethrow"),
    (re.compile(r"terminate called", re.I), "std::terminate (unrecognised wording)"),
    (re.compile(r"\bSegmentation fault\b", re.I), "segfault"),
    (re.compile(r"\bcore dumped\b", re.I), "process dumped core"),
    (re.compile(r"\bSIG(SEGV|ABRT|FPE|BUS|ILL)\b"), "fatal signal"),
    (re.compile(r"Floating point exception", re.I),
     "SIGFPE -- likely an integer division by zero"),
    (re.compile(r"\bAssertion\b.*\bfailed\b", re.I), "assertion failure"),
    (re.compile(r"std::bad_alloc"), "allocation failure"),
    (re.compile(r"(AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer|"
                r"ThreadSanitizer)", re.I), "sanitizer report"),
    # [Co-developed with claude code -- Adam]
    # Widened from `free(): invalid`, which missed "free(): double free detected in tcache 2" --
    # the single most common heap message there is. glibc prints "<allocator>(): ..." only when
    # it is aborting, so the function name plus the colon is the whole signal.
    (re.compile(r"double free or corruption"
                r"|(free|malloc|realloc|munmap_chunk|malloc_consolidate)\(\): "
                r"|corrupted (size vs\. prev_size|double-linked list)", re.I),
     "heap corruption"),
    # FORTIFY_SOURCE and the stack protector. Neither says "terminate", "abort" or "SIG"; they
    # print a banner and die, so nothing else in this table would have caught them.
    (re.compile(r"\*{3} (stack smashing detected|buffer overflow detected"
                r"|%n in writable segment detected)", re.I),
     "FORTIFY/stack-protector abort"),
    (re.compile(r"Fatal glibc error", re.I), "glibc fatal error"),
    # The shell's own job-control notice for a child that died of a signal. It is how a SIGKILL
    # appears at all -- a killed process prints nothing itself -- and on this machine
    # systemd-oomd is a routine source of exactly that.
    #
    # Anchored on a pid (3+ digits) precisely so the words alone stay harmless: "Killed" and
    # "Aborted" are ordinary English and appear in ordinary log prose, and a crash detector that
    # cannot be trusted is worse than one with a known gap.
    (re.compile(r"\b\d{3,} +(Killed|Aborted)\b"),
     "a child was killed by a signal (the shell's job-control notice)"),
    (re.compile(r"\bBus error\b|\bIllegal instruction\b|\bTrace/breakpoint trap\b"),
     "fatal signal reported by the shell"),
    (re.compile(r"pure virtual method called", re.I), "pure virtual call"),
    (re.compile(r"what\(\):\s*\S", re.I), "uncaught exception detail"),
]


def scan_for_crash(text: str):
    for pattern, why in CRASH_PATTERNS:
        if pattern.search(text):
            return why
    return None

RESET, RED, GREEN, YELLOW, DIM = "\033[0m", "\033[31m", "\033[32m", "\033[33m", "\033[2m"


def colour(enabled):
    if enabled:
        return (lambda c, s: f"{c}{s}{RESET}")
    return (lambda c, s: s)


#: A rule kind whose permission is conditional on a fact the operator must state.
#: [Co-developed with claude code -- Adam] -- KNOWN-ISSUES A-8.
#:
#: The kernel emits "... reported a read failure for switch N -- keeping the previous table"
#: (DeviceConfigurationAndPowerManager.cpp:1134) *because it is handling a powered-off switch
#: correctly*. It is unlistable as a plain WARNING: the identical line is also what a wedged
#: control plane produces, which is the 2026-08-07 defect the warning was added to expose
#: (all ten switches reporting zero rules while s1 held 130). Allowlisting it outright would
#: turn this checker into the thing that hides that defect.
#:
#: So the permission is scoped to the switches the run declares powered off, via
#: --powered-off. Same line, three answers:
#:   dpid declared off  -> EXPECTED, not a violation
#:   dpid not declared  -> still a violation, in full
#:   nothing declared   -> TOOL-PRECONDITION-FAILED, exit 3. The checker will not guess.
WHEN_POWERED_OFF = "WHEN-POWERED-OFF"

#: Exit code for "this checker could not establish what it needed before judging".
#: Distinct from 1 so a tool failure can never be read as a system failure.
EXIT_PRECONDITION = 3


class Rule:
    def __init__(self, kind, pattern, reason, lineno):
        self.kind = kind          # WARNING | ERROR | FORBID | WHEN-POWERED-OFF
        self.pattern_src = pattern
        self.regex = re.compile(pattern)
        self.reason = reason
        self.lineno = lineno
        self.hits = 0


# Field separator: a pipe surrounded by whitespace. Splitting on a bare "|" would break
# every regex that uses alternation, so inside a pattern write it without spaces --
# (int|float) is a regex, " | " is a separator.
FIELD_SEP = re.compile(r"\s+\|\s+")


def load_allowlist(path) -> list[Rule]:
    rules = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in FIELD_SEP.split(line)]
            if len(parts) < 3:
                raise SystemExit(
                    f"{path}:{lineno}: expected 'LEVEL | regex | reason'"
                    f" (fields separated by a pipe with spaces around it), got: {line}")
            kind, pattern, reason = parts[0].upper(), parts[1], " | ".join(parts[2:])
            if kind not in ("WARNING", "ERROR", "FORBID", WHEN_POWERED_OFF):
                raise SystemExit(
                    f"{path}:{lineno}: unknown level {kind!r}"
                    f" (expected WARNING, ERROR, FORBID or {WHEN_POWERED_OFF})")
            try:
                rule = Rule(kind, pattern, reason, lineno)
            except re.error as exc:
                raise SystemExit(f"{path}:{lineno}: invalid regex {pattern!r}: {exc}")
            if kind == WHEN_POWERED_OFF and "dpid" not in rule.regex.groupindex:
                raise SystemExit(
                    f"{path}:{lineno}: a {WHEN_POWERED_OFF} pattern must capture the switch "
                    f"it is about in a group named 'dpid', e.g. "
                    f"'for switch (?P<dpid>\\d+)'. Without it the rule would excuse the "
                    f"message for every switch, which is the blanket permission this kind "
                    f"exists to avoid.")
            rules.append(rule)
    return rules


def parse_log(stream):
    """Yields (lineno, level, message). Non-matching lines are reported as level None."""
    for lineno, raw in enumerate(stream, 1):
        clean = ANSI.sub("", raw.rstrip("\n"))
        if not clean.strip():
            continue
        m = LINE.match(clean)
        if m:
            yield lineno, m.group("level").lower(), m.group("msg").strip(), clean
        else:
            yield lineno, None, clean.strip(), clean


def parse_powered_off(raw):
    """
    Turn --powered-off into (set_of_dpids, was_declared). Pure; no I/O.

    'none' is a real declaration -- "I assert nothing is powered off" -- and is not the same
    as omitting the flag, which declares nothing. That distinction is the whole point: with
    'none' a read-failure warning is a genuine violation again, which is how the 2026-08-07
    wedged-controller detection survives this change. [Co-developed with claude code -- Adam]
    """
    if raw is None:
        return frozenset(), False
    text = raw.strip()
    if text.lower() in ("none", ""):
        return frozenset(), True
    dpids = set()
    for token in text.split(","):
        token = token.strip()
        if not token:
            continue
        if not token.lstrip("-").isdigit():
            raise SystemExit(f"--powered-off: {token!r} is not a dpid "
                             f"(expected digits, a comma-separated list, or 'none')")
        dpids.add(int(token))
    return frozenset(dpids), True


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Check a kernel log against the allowlist")
    ap.add_argument("logfile", help="log file, or - for stdin")
    ap.add_argument("--allowlist", default=os.path.join(here, "warning_allowlist.txt"))
    ap.add_argument("--suggest-allowlist", action="store_true",
                    help="print allowlist lines for everything currently unmatched, "
                         "for review before adoption")
    ap.add_argument("--max-report", type=int, default=15,
                    help="max example lines per distinct message (default: %(default)s)")
    ap.add_argument("--ignore-unparsed", action="store_true",
                    help="do not warn about lines that do not match the log format "
                         "(crash detection still scans them)")
    ap.add_argument("--to-line", type=int, metavar="N",
                    help="only check the first N lines. Used to exclude errors that the "
                         "L2 error-path checks provoke on purpose, which would otherwise "
                         "make this check permanently red")
    ap.add_argument("--from-line", type=int, default=0, metavar="N",
                    help="skip the first N lines (e.g. a previous run in the same file)")
    # [Co-developed with claude code -- Adam] -- A-8. See WHEN_POWERED_OFF above.
    ap.add_argument("--powered-off", metavar="DPIDS",
                    help="comma-separated dpids the Energy-Saving-App (or an operator) has "
                         "deliberately powered down, or the literal 'none' to assert that "
                         "nothing is off. Scopes every WHEN-POWERED-OFF rule to exactly "
                         "these switches. Omit it and any line matching such a rule is "
                         "reported as TOOL-PRECONDITION-FAILED rather than judged")
    args = ap.parse_args()

    powered_off, powered_off_declared = parse_powered_off(args.powered_off)

    use_colour = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
    c = colour(use_colour)

    if not os.path.exists(args.allowlist):
        print(c(RED, f"allowlist not found: {args.allowlist}"))
        return 2
    rules = load_allowlist(args.allowlist)

    # Explicit encoding: logs are UTF-8, but the default follows the system locale,
    # which turns a stray byte into a crash on a differently-configured machine.
    stream = (sys.stdin if args.logfile == "-"
              else open(args.logfile, encoding="utf-8", errors="replace"))
    try:
        entries = list(parse_log(stream))
    finally:
        if stream is not sys.stdin:
            stream.close()

    # Crashes are scanned over the WHOLE file, never the window. Filtering first (as an
    # earlier version did) meant a crash during the excluded region -- exactly when the L2
    # error paths are provoking the kernel -- was silently skipped, contradicting the
    # documented guarantee that crash detection ignores the window.
    all_entries = entries
    total_lines = len(all_entries)

    windowed_entries = all_entries
    if args.from_line:
        windowed_entries = [e for e in windowed_entries if e[0] > args.from_line]
    # `is not None`, not truthiness: --to-line 0 is a meaningful request (check nothing but
    # crashes, e.g. when the log was empty before the tests ran) and 0 is falsy.
    if args.to_line is not None:
        windowed_entries = [e for e in windowed_entries if e[0] <= args.to_line]
    windowed = bool(args.from_line) or args.to_line is not None

    warn_rules = [r for r in rules if r.kind == "WARNING"]
    error_rules = [r for r in rules if r.kind == "ERROR"]
    forbid_rules = [r for r in rules if r.kind == "FORBID"]
    conditional_rules = [r for r in rules if r.kind == WHEN_POWERED_OFF]

    violations = OrderedDict()   # message -> dict(level, lines[], why)
    crashes = OrderedDict()
    level_counts = Counter()
    unparsed = []
    # [Co-developed with claude code -- Adam] -- A-8.
    expected = OrderedDict()      # lines explained by a declared power-down
    undecidable = OrderedDict()   # lines a WHEN-POWERED-OFF rule matched with no declaration
    seen_off_dpids = set()        # dpids a conditional rule actually named in this log

    def record(msg, level, lineno, why):
        key = (level, why, msg)
        violations.setdefault(key, []).append(lineno)

    def classify_conditional(msg):
        """
        (rule, dpid) for the first WHEN-POWERED-OFF rule that matches, else None.

        A rule whose 'dpid' group did not capture digits is treated as no match: the rule
        claimed it could identify the switch and could not, so it may not grant permission.
        """
        for rule in conditional_rules:
            m = rule.regex.search(msg)
            if not m:
                continue
            captured = m.groupdict().get("dpid")
            if captured is None or not str(captured).strip().lstrip("-").isdigit():
                continue
            return rule, int(captured)
        return None

    # Crash scan: every line of the file, parsed or not, window or not. Never allowlistable
    # and unaffected by --ignore-unparsed.
    for lineno, _level, _msg, full in all_entries:
        crash_why = scan_for_crash(full)
        if crash_why:
            crashes.setdefault((crash_why, full.strip()[:160]), []).append(lineno)

    # Rule validation: only the requested window.
    for lineno, level, msg, full in windowed_entries:
        if level is None:
            unparsed.append((lineno, msg))
            continue
        level_counts[level] += 1

        # FORBID wins at every level.
        hit_forbid = next((r for r in forbid_rules if r.regex.search(msg)), None)
        if hit_forbid:
            hit_forbid.hits += 1
            record(msg, level, lineno, f"forbidden pattern: {hit_forbid.reason}")
            continue

        # [Co-developed with claude code -- Adam] -- A-8. After FORBID (a forbidden message
        # is never excused by a power-down) and before the level rules, so that the scoped
        # permission is checked before the blanket one.
        conditional = classify_conditional(msg)
        if conditional is not None:
            rule, dpid = conditional
            seen_off_dpids.add(dpid)
            if not powered_off_declared:
                undecidable.setdefault((rule.lineno, dpid, msg), []).append(lineno)
                continue
            if dpid in powered_off:
                rule.hits += 1
                expected.setdefault((dpid, msg), []).append(lineno)
                continue
            # Declared power state says this switch is ON, so the message is unexplained
            # and falls through to the ordinary level rules -- i.e. it stays red.

        if level in FAIL_LEVELS:
            allowed = next((r for r in error_rules if r.regex.search(msg)), None)
            if allowed:
                allowed.hits += 1
            else:
                record(msg, level, lineno, f"{level} level is never allowed by default")
            continue

        if level in WARN_LEVELS:
            allowed = next((r for r in warn_rules if r.regex.search(msg)), None)
            if allowed:
                allowed.hits += 1
            else:
                record(msg, level, lineno, "warning is not in the allowlist")

    # --- suggest mode: emit paste-ready lines, do not judge ------------------
    if args.suggest_allowlist:
        if undecidable:
            # [Co-developed with claude code -- Adam] -- A-8. Without this, suggest mode
            # would print "nothing unmatched" over lines it deliberately did not judge,
            # which is the silent-zero shape this whole change exists to remove.
            print("# NOT SUGGESTED -- matched a WHEN-POWERED-OFF rule with no --powered-off")
            print("# declaration, so this run cannot tell whether they are expected:")
            for (_rule_lineno, dpid, msg), lines in undecidable.items():
                print(f"#   [dpid {dpid}] {msg}   ({len(lines)}x, e.g. line {lines[0]})")
            print()
        if not violations:
            print("# nothing unmatched -- the allowlist already covers this log")
            return EXIT_PRECONDITION if undecidable else 0

        # A FORBID hit is by definition something to fix, so we refuse to emit an
        # allowlist line for it -- doing so would silence the mechanism.
        forbidden = [(msg, lines) for (level, why, msg), lines in violations.items()
                     if why.startswith("forbidden pattern")]
        suggestable = [(level, msg, lines) for (level, why, msg), lines in violations.items()
                       if not why.startswith("forbidden pattern")]

        if forbidden:
            print("# NOT SUGGESTED -- these matched FORBID rules and must be fixed,")
            print("# not permitted. Allowlisting them would defeat the purpose:")
            for msg, lines in forbidden:
                print(f"#   {msg}   ({len(lines)}x, e.g. line {lines[0]})")
            print()

        if not suggestable:
            print("# nothing else to suggest")
            return 0

        print("# Suggested allowlist additions. REVIEW EACH ONE before pasting:")
        print("# an acceptable warning needs a reason; a real problem needs a fix.\n")
        seen = set()
        for level, msg, lines in suggestable:
            pattern = re.escape(msg)
            # Generalise spdlog-formatted values so one rule covers many instances.
            pattern = re.sub(r"\d+", r"\\d+", pattern)
            if pattern in seen:
                continue
            seen.add(pattern)
            kind = "ERROR" if level in FAIL_LEVELS else "WARNING"
            print(f"{kind} | {pattern} | TODO reason ({len(lines)} occurrence(s), "
                  f"e.g. line {lines[0]})")
        return 0

    # --- report --------------------------------------------------------------
    total = sum(level_counts.values())
    print(f"Log check: {args.logfile}")
    print(f"  parsed   : {total} log lines "
          f"({', '.join(f'{k}={v}' for k, v in sorted(level_counts.items())) or 'none'})")
    if windowed:
        lo = args.from_line + 1
        # `is not None` again: --to-line 0 must display as an empty window, not the whole file.
        hi = args.to_line if args.to_line is not None else total_lines
        print(f"  {c(YELLOW, 'window')}   : lines {lo}-{hi} of {total_lines} "
              f"{c(DIM, '(the rest is deliberately excluded)')}")
    print(f"  allowlist: {len(rules)} rule(s) "
          f"({len(warn_rules)} warning, {len(error_rules)} error, {len(forbid_rules)} forbid, "
          f"{len(conditional_rules)} when-powered-off)")
    if powered_off_declared:
        print(f"  powered off: {sorted(powered_off) if powered_off else 'nothing (declared)'}")
    else:
        print(f"  powered off: {c(DIM, 'not declared (--powered-off)')}")

    if unparsed and not args.ignore_unparsed:
        print(f"\n  {c(YELLOW, 'note')}: {len(unparsed)} line(s) did not match the expected "
              f"log format (stdout from a subprocess?), first at line {unparsed[0][0]}")

    if crashes:
        print(f"\n{c(RED, 'CRASHES / ABORTS')}  "
              f"{c(DIM, '(never allowlistable)')}")
        for (why, sample), lines in crashes.items():
            print(f"\n  [{c(RED, why.upper())}] line(s): {', '.join(map(str, lines[:10]))}")
            print(f"      {sample}")

    if violations:
        print(f"\n{c(RED, 'PROBLEMS')}")
        for (level, why, msg), lines in violations.items():
            shown = ", ".join(map(str, lines[:args.max_report]))
            more = f" (+{len(lines) - args.max_report} more)" if len(lines) > args.max_report else ""
            tag = c(RED, level.upper())
            print(f"\n  [{tag}] {msg}")
            print(f"      {c(DIM, why)}")
            print(f"      {len(lines)} occurrence(s) at line(s): {shown}{more}")

    # [Co-developed with claude code -- Adam] -- A-8.
    if expected:
        print(f"\n{c(YELLOW, 'EXPECTED (explained by a declared power-down)')}")
        for (dpid, msg), lines in expected.items():
            print(f"\n  [dpid {dpid}] {msg}")
            print(f"      {len(lines)} occurrence(s) at line(s): "
                  f"{', '.join(map(str, lines[:args.max_report]))}")

    # The declaration and the log disagreeing is itself worth saying: a switch declared off
    # that produced no such line may mean the power-down did not take effect.
    declared_but_silent = sorted(powered_off - seen_off_dpids) if powered_off_declared else []
    if declared_but_silent:
        print(f"\n  {c(YELLOW, 'note')}: dpid(s) declared powered off produced no matching "
              f"log line: {declared_but_silent}")

    if undecidable:
        print(f"\n{c(YELLOW, 'TOOL-PRECONDITION-FAILED')}")
        print(c(DIM, "  These lines are either the correct handling of a deliberately"))
        print(c(DIM, "  powered-off switch or a control plane that has stopped reading its"))
        print(c(DIM, "  switches. This run was not told which, so it does not say."))
        for (rule_lineno, dpid, msg), lines in undecidable.items():
            print(f"\n  [dpid {dpid}] {msg}")
            print(f"      {c(DIM, f'{os.path.basename(args.allowlist)}:{rule_lineno}')}"
                  f"  {len(lines)} occurrence(s) at line(s): "
                  f"{', '.join(map(str, lines[:args.max_report]))}")
        print(c(DIM, "\n  Re-run with --powered-off <dpids>, or --powered-off none to assert"))
        print(c(DIM, "  that nothing is off (which makes these lines a failure again)."))

    # FORBID rules are excluded: one that never fires means the system is healthy,
    # which is exactly what we want. Only unused *permissions* are cruft.
    # WHEN-POWERED-OFF rules are excluded for the same reason: an unfired one means no
    # switch was powered off during this run, not that the rule has rotted.
    stale = [r for r in rules if r.hits == 0 and r.kind not in ("FORBID", WHEN_POWERED_OFF)]
    if stale:
        print(f"\n{c(YELLOW, 'UNUSED ALLOWLIST ENTRIES')} "
              f"(nothing matched them in this log)")
        print(c(DIM, "  Expected for warnings that only appear in the other data plane or"))
        print(c(DIM, "  only during startup. Prune anything that is permanently unused."))
        for r in stale:
            print(f"  {os.path.basename(args.allowlist)}:{r.lineno}  "
                  f"{r.kind} | {r.pattern_src}")

    print(f"\n{'=' * 70}")
    if crashes:
        n = sum(len(v) for v in crashes.values())
        print(c(RED, f"FAIL: {n} crash/abort line(s) — the process died or nearly did"))
        return 1
    if violations:
        n = sum(len(v) for v in violations.values())
        print(c(RED, f"FAIL: {n} problem line(s) across "
                     f"{len(violations)} distinct message(s)"))
        print(c(DIM, "to accept one deliberately, add it to "
                     f"{os.path.basename(args.allowlist)} with a reason"))
        return 1
    if undecidable:
        # [Co-developed with claude code -- Adam] -- A-8: not FAIL, and not exit 1. This run
        # makes no claim about the log.
        n = sum(len(v) for v in undecidable.values())
        print(c(YELLOW, f"TOOL-PRECONDITION-FAILED: {n} line(s) could not be judged without "
                        f"knowing which switches are powered off"))
        return EXIT_PRECONDITION

    if expected:
        print(c(GREEN, f"PASS: no crashes, no unexpected warnings or errors "
                       f"({sum(len(v) for v in expected.values())} line(s) explained by the "
                       f"declared power-down)"))
        return 0
    print(c(GREEN, "PASS: no crashes, and no unexpected warnings or errors"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
