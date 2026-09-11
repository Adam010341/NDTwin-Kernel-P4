#!/usr/bin/env python3
"""Do the entries in warning_allowlist.txt still describe messages this tree can emit?

[Co-developed with claude code -- Adam]

The allowlist's own header says what it is for -- "make NEW warnings fail the build" -- and
its maintenance note says `check_logs.py` reports entries that never matched "so stale lines
get pruned". Nothing prunes them, and nothing fails when one rots: a never-matched entry is
printed at the end of a log check as UNUSED, in a run whose verdict is PASS, which is the
shape of every green check this project has had to stop trusting.

Two things rot differently, and this file separates them, because FIX-CONTRACT-1 SUMMARY
section 6 and section 7-2 recorded two entries with the same symptom and different
consequences:

  * a PERMISSION (WARNING/ERROR) for a message no source emits any more is pure noise. It
    cannot cause a false green -- there is nothing left to match it -- and deleting it is
    safe. `warning_allowlist.txt:133`, `P4 BMv2 Power ON from Kernel is currently a stub`,
    was that: zero hits for `currently a stub` and for `P4 BMv2 Power` across src/, include/
    and p4_proxy/, first noted stale in
    doc/audit/2026-08-30_live-full-stack-round/harness/90_restore.sh:29 on 08-30 and
    unregistered until 09-11.

  * a FORBID whose regex cannot match the message it names is a LIGHT THAT NEVER COMES ON,
    and deleting it deletes the intent with it. `:169` is
    `FORBID | Cannot open OpenflowCapacity\\.json`; the kernel prints
    `Cannot open 2026-01-02_OpenflowCapacity.json` (HttpSession.cpp, handleGetOpenflowCapacity),
    so `re.search` never matches -- the `2026-01-02_` sits between the two halves of the
    pattern. FIX-CONTRACT-1 section 7-2 left it for Adam, and this file keeps the darkness
    VISIBLE rather than tidy: every dark FORBID has to be registered, with its reason, in
    DARK_FORBID below, and the assertion runs in BOTH directions so the registry cannot rot
    into an excuse either.

🔴 WHAT THIS FILE CANNOT DO. It matches a rule's regex against the STRING LITERALS in this
tree's sources, so:
  * a message assembled from two literals, or one whose `{}` placeholder falls inside the
    pattern, will not be found. That is why only the FORBID rules and the "Known gaps with an
    owner" section are scanned -- the sections whose entries are single fixed sentences.
  * a message emitted by a LIBRARY is invisible by construction (spdlog throws "logger with
    name ... already exists"), which is one of the two registered entries below and is
    registered for that reason and not as a defect.
Every other section is out of scope here and says so, rather than being scanned badly.

Interpreter: plain python3, no third-party imports (`p4_proxy/venv/bin/python3` works too;
this suite was run under both on 2026-09-11).

Run:  python3 -m unittest discover -s tests/python -p test_warning_allowlist_entries.py -v
"""

from __future__ import annotations

import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOWLIST = os.path.join(REPO_ROOT, "tools", "contract_test", "warning_allowlist.txt")

#: The separator the allowlist documents: a pipe with whitespace around it.
FIELD_SEP = re.compile(r"\s+\|\s+")

#: Where a kernel message can come from. tools/ is included because check_logs.py is also
#: pointed at the proxy's logs by run_layers.sh.
SOURCE_DIRS = ("src", "include", "p4_proxy/proxy_agent", "p4_proxy/mininet", "tools")
SOURCE_EXTS = ("cpp", "hpp", "h", "cc", "py")

#: A C++ or python string literal of at least four characters, escapes included.
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.){4,400})"')

#: The section whose own header calls each of its lines "a promise to remove it".
KNOWN_GAPS_HEADER = "# Known gaps with an owner"

#: FORBID patterns that provably match no literal in this tree, with the reason each one is
#: still here. Registered rather than deleted, in both directions: a pattern that starts
#: matching has to come OUT of this table, or the next dark one hides behind it.
DARK_FORBID = {
    r"logger with name .* already exists": (
        "spdlog throws it (spdlog::spdlog_ex from the registry), so no literal of ours can "
        "carry it. Structurally invisible to a source scan, not stale: Logger::init being "
        "called twice is still the thing this line exists to fail on."),
    r"Cannot open OpenflowCapacity\.json": (
        "🔴 KNOWN DARK, awaiting Adam (FIX-CONTRACT-1 SUMMARY section 7-2, registered as G-y "
        "in its section 6). The kernel prints 'Cannot open 2026-01-02_OpenflowCapacity.json' "
        "and this pattern requires the two halves to be adjacent, so re.search returns None "
        "and the light has never come on. The one-line fix is 'Cannot open "
        ".*OpenflowCapacity\\.json'. It was NOT applied here because it changes what a log "
        "gate says about a run with the capacity file missing, and because the message is "
        "logged at ERROR level -- measured 2026-09-11: check_logs.py already fails such a log "
        "with rc 1 through the unallowlisted-error path, and passes it with rc 0 if the same "
        "message is ever demoted to info, which is exactly the case FORBID exists for. "
        "IF YOU JUST FIXED THE REGEX: delete this entry, and this test goes green again."),
}


def allowlist_lines():
    with open(ALLOWLIST, encoding="utf-8") as fh:
        return fh.read().split("\n")


def rules(kinds=None, section=None):
    """[(lineno, kind, pattern, reason)] -- parsed the way check_logs.py parses them.

    `section` limits the result to the rules belonging to the `# ====`-fenced block whose
    header contains that text.

    🔴 The block boundary is the `# ====` fence, NOT "the next comment line", and it is not
    "until the first rule is found either". A first draft used the second rule and a section
    with NO rules in it swallowed every rule after it -- which is what an emptied section is,
    and emptying one is exactly what this file exists around. Measured 2026-09-11: it reported
    the two WHEN-POWERED-OFF rules as stale known gaps.
    """
    out, current = [], None
    for lineno, raw in enumerate(allowlist_lines(), 1):
        line = raw.strip()
        if line.startswith("# ==="):
            # A fence: either opening a new block (the title comes next) or closing one.
            current = "" if current is None else None
            continue
        if line.startswith("#"):
            if current == "":
                current = line          # the first comment after a fence is the title
            continue
        if not line:
            continue
        if section is not None and (current is None or section not in current):
            continue
        parts = [p.strip() for p in FIELD_SEP.split(line)]
        if len(parts) < 3:
            continue
        kind, pattern, reason = parts[0].upper(), parts[1], " | ".join(parts[2:])
        if kinds is None or kind in kinds:
            out.append((lineno, kind, pattern, reason))
    return out


def source_literals():
    """[(path, literal)] for every string literal in this tree's sources."""
    found = []
    for root in SOURCE_DIRS:
        base = os.path.join(REPO_ROOT, root)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in ("venv", "build", "__pycache__")]
            for name in filenames:
                if name.rsplit(".", 1)[-1] not in SOURCE_EXTS:
                    continue
                path = os.path.join(dirpath, name)
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    continue
                for m in LITERAL.finditer(text):
                    found.append((os.path.relpath(path, REPO_ROOT), m.group(1)))
    return found


class AllowlistIsReadable(unittest.TestCase):
    """The control: if the parse breaks, every assertion below is vacuous."""

    def test_the_file_parses_into_rules(self):
        self.assertGreater(len(rules()), 20, "the allowlist parsed into almost nothing")

    def test_the_known_gaps_section_still_exists(self):
        """🔴 Without this, deleting the section header would make its test vacuous."""
        self.assertTrue(any(KNOWN_GAPS_HEADER in l for l in allowlist_lines()),
                        "the 'Known gaps with an owner' section header is gone -- the check "
                        "below now scans nothing, which is not the same as passing")

    def test_the_source_scan_finds_something(self):
        lits = source_literals()
        self.assertGreater(len(lits), 1000,
                           "the source scan found almost no literals; every 'no match' below "
                           "would be an artefact of that")


class KnownGapsStillHaveACallSite(unittest.TestCase):
    """Each line in that section is "a promise to remove it" -- so the message must exist.

    A permission for a message nothing emits cannot cause a false green, and that is exactly
    why nothing catches it: it is noise in a 200-line file that a reader has to judge. 09-11
    deleted the one entry that had rotted; this keeps the next one from lasting six weeks.
    """

    def test_every_known_gap_entry_matches_a_literal_in_the_sources(self):
        lits = source_literals()
        stale = []
        for lineno, kind, pattern, _reason in rules(section=KNOWN_GAPS_HEADER):
            rx = re.compile(pattern)
            if not any(rx.search(lit) for _p, lit in lits):
                stale.append("%s:%d  %s | %s" % (os.path.basename(ALLOWLIST), lineno,
                                                 kind, pattern))
        self.assertEqual([], stale,
                         "allowlist entries in 'Known gaps with an owner' whose message no "
                         "source in this tree emits:\n  " + "\n  ".join(stale))


class ForbidRulesAreEitherLiveOrRegisteredAsDark(unittest.TestCase):
    """A FORBID that cannot match its own message is a light that never comes on.

    🔴 BOTH DIRECTIONS, the way tests/shell/check_process_by_name.py registers its sites: a
    dark pattern must be in DARK_FORBID with a reason, and a pattern in DARK_FORBID that has
    started matching must be taken out. Otherwise the registry becomes the place dark rules
    go to be forgotten.
    """

    def setUp(self):
        self.lits = source_literals()
        self.forbids = rules(kinds=("FORBID",))

    def matches(self, pattern):
        rx = re.compile(pattern)
        return [(p, lit) for p, lit in self.lits if rx.search(lit)]

    def test_there_are_forbid_rules_to_check(self):
        self.assertGreaterEqual(len(self.forbids), 5)

    def test_every_dark_forbid_is_registered_with_a_reason(self):
        unregistered = []
        for lineno, _kind, pattern, _reason in self.forbids:
            if self.matches(pattern):
                continue
            if pattern not in DARK_FORBID:
                unregistered.append("%s:%d  FORBID | %s" % (
                    os.path.basename(ALLOWLIST), lineno, pattern))
        self.assertEqual([], unregistered,
                         "FORBID patterns that match no message this tree emits, and are not "
                         "registered as dark in DARK_FORBID:\n  " + "\n  ".join(unregistered))

    def test_a_registered_dark_forbid_that_now_matches_must_be_deregistered(self):
        fixed = []
        for _lineno, _kind, pattern, _reason in self.forbids:
            if pattern in DARK_FORBID and self.matches(pattern):
                where = self.matches(pattern)[0]
                fixed.append("%s  (now matches %s :: %s)" % (pattern, where[0], where[1][:60]))
        self.assertEqual([], fixed,
                         "these FORBID patterns are registered as dark but now match a real "
                         "message -- take them out of DARK_FORBID:\n  " + "\n  ".join(fixed))

    def test_the_registry_names_no_pattern_the_allowlist_has_dropped(self):
        """A registered reason for a rule nobody ships is a claim about nothing."""
        present = {p for _l, _k, p, _r in self.forbids}
        orphans = sorted(set(DARK_FORBID) - present)
        self.assertEqual([], orphans,
                         "DARK_FORBID registers patterns that are no longer in the "
                         "allowlist:\n  " + "\n  ".join(orphans))

    def test_the_capacity_forbid_is_dark_for_the_reason_recorded(self):
        """The measurement behind G-y, pinned so the next reader does not have to redo it.

        This asserts the STATE, not that the state is right: the kernel's own literal and the
        shipped pattern, and that one does not match the other. When Adam rules and the regex
        is widened, this case and the DARK_FORBID entry go together.
        """
        pattern = r"Cannot open OpenflowCapacity\.json"
        self.assertIn(pattern, {p for _l, _k, p, _r in self.forbids},
                      "the capacity FORBID is gone from the allowlist -- if that was "
                      "deliberate, this case and its DARK_FORBID entry go with it")
        kernel_literal = [lit for p, lit in self.lits
                          if "OpenflowCapacity.json" in lit and lit.startswith("Cannot open")]
        self.assertTrue(kernel_literal,
                        "no 'Cannot open ...OpenflowCapacity.json' literal in the sources any "
                        "more; re-read FIX-CONTRACT-1 section 7-2 before changing the rule")
        self.assertFalse(re.search(pattern, kernel_literal[0]),
                         "the FORBID now matches the kernel's message: the G-y fix has been "
                         "applied, so delete this case and the DARK_FORBID entry")
        self.assertIn("2026-01-02_", kernel_literal[0],
                      "the message changed shape; the reason recorded in DARK_FORBID is about "
                      "the date prefix and needs re-reading")


if __name__ == "__main__":
    unittest.main()
