#!/usr/bin/env python3
"""Citations of `doc/KNOWN-ISSUES.md` must name an ENTRY CODE, not a line number.

[Co-developed with claude code -- Adam]

## The defect this file exists to stop

`doc/KNOWN-ISSUES.md` is a single 3,483-line append-and-insert document. Entries are added in
the middle of it -- six branches did so on the night of 09-05 alone -- and every insertion
shifts every line below it. A citation of the form `KNOWN-ISSUES.md:<n>` is therefore correct
for exactly as long as nobody edits the file above line n, which for this file means days.

This is not a hypothetical. On `1a284f75`, BEFORE this fix, the repo held 62 such citations and
this scanner could not trust 58 of them -- including four that were already wrong on the day
they were written:

    doc/audit/2026-09-02_fix-design-campaign/findings/IPERF3-CONFLICT.md  cited :1614
    doc/audit/2026-09-03_fix-flow-visibility-units/FIX-FLOW-VISIBILITY-UNITS.md  cited :1429, :1475
    doc/2026-08-29_bmv2-performance-study.md and
    doc/audit/2026-08-28_flow-count-capacity/FINDINGS.md                  cited :1679

An entry CODE (`A-1`, `B-2d`, `C-4b`, `G-13`) is stable under insertion: it survives every edit
that does not renumber the entry itself. Adam's ruling (DECISIONS.md, 09-07 21:0x, item 3) is
that citations use the code. This file is the gate that keeps them that way.

## What it checks

Every text file under `doc/ tests/ tools/ src/ include/ p4_proxy/` plus the repo's root-level
`*.md` is read, and each citation of the shape

    KNOWN-ISSUES.md:<n>        KNOWN-ISSUES.md:<n>-<m>        KNOWN-ISSUES:<n>

is resolved against `doc/KNOWN-ISSUES.md` AS IT IS IN THE SAME TREE. For each one:

  * the nearest entry code on the SAME LINE is the code the citation claims (if the line
    carries none, the enclosing paragraph is searched -- a citation whose code sits one line
    above is sloppy, not wrong);
  * line n (and m) must fall inside that code's section.

A citation with no code anywhere near it, or one whose line lands in a DIFFERENT entry, is a
violation and the message says 改成條目代號.

🔴 It does NOT enforce that a citation carries a line number, and it must not: the whole point
of the ruling is that `KNOWN-ISSUES B-11` alone is the correct citation, and a bare code is
invisible to this scanner by construction. What the scanner guards is the other direction --
if you DO write a line number, it has to be true, and it has to say which entry it means.

## What it deliberately does not read

  * `*.log`, `*.diff`, `*.patch` -- verbatim records of bytes somebody else produced. They
    cannot be corrected without falsifying them, so checking them would be a permanent red
    that the only available fix makes worse. (`*.log` is Adam's exclusion; the other two are
    the same category and are called out in FIX-KIREF.md §5 as a widening of it.)
  * `scratch/`, `.git/`, `build*/`, `venv/`, `node_modules/`, `__pycache__/` -- not the repo's
    documentation, and `p4_proxy/venv` is a symlink into another checkout entirely.

🔴 THIS FILE EXEMPTS NOTHING, ITSELF INCLUDED. `tests/python/` and `tests/shell/` are inside
the scanned tree, so this file and its mutation gate are scanned like everything else. That is
why neither of them ever contains the literal citation shape: the fixtures below build it with
`%d`, and the gate builds it in shell with `"$KI:1679"`. An instrument that has to be excluded
from its own scan is an instrument whose scope nobody can check.

## Entry shapes it can resolve

The ruling names `### <code>` headings, which is where 48 of the codes live. Three shapes exist
in the file and all three are read, because "could not resolve" must never read as "fine":

    ### B-11 ...        span = that line to the line before the next `### `
    ## B-x. ...         span = that line to the line before the next `## `
    | **F-9** | ...     a table row: span = that one line

A code that appears in NONE of them (there are none today, but F-codes are one renumbering away
from it) is reported as UNRESOLVABLE-CODE, not silently passed.

## Seams

`KIREF_REPO_UNDER_TEST` replaces the tree that `TheRepositoryAsItStands` scans. The mutation
gate `tests/shell/mutate_known_issues_references.sh` uses it to point a COPY of this file at a
COPY of the tree; neither the tree nor this file is ever written by the gate.

Stdlib only. No kernel, no build, no fabric, no lab, no network: it reads files and counts
lines. Runtime on `1a284f75` is about a second.

Run:  p4_proxy/venv/bin/python -m unittest discover -s tests/python \
          -p test_known_issues_references.py
      python3 tests/python/test_known_issues_references.py -v
"""
import os
import re
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_REPO = os.path.dirname(os.path.dirname(HERE))
REPO = os.environ.get("KIREF_REPO_UNDER_TEST", DEFAULT_REPO)

#: The document every citation this file reads is a citation OF.
KI_NAME = "KNOWN-ISSUES.md"
KI_REL = os.path.join("doc", KI_NAME)

#: Where a citation may live. Root-level `*.md` (NEXT.md, RATIONALE.md) is added separately
#: because the repo root also holds build trees, scratch and the venv symlink.
SCAN_DIRS = ("doc", "tests", "tools", "src", "include", "p4_proxy")

#: Suffixes that are text at all. A file with any other suffix is not read -- `.tar.gz`,
#: `.jsonl.gz`, `.pdf`, `.png` under doc/audit/ are all in the scanned tree.
#: 🔴 `.log`, `.diff` and `.patch` are IN this set on purpose. They are text; what keeps them
#: out is the next set, and the mutation gate's M6 relies on that being the only thing that
#: does. A rule enforced twice is a rule whose real enforcement point nobody can find.
TEXT_SUFFIXES = frozenset((
    ".md", ".py", ".sh", ".cpp", ".hpp", ".cc", ".c", ".h", ".txt", ".tsv", ".csv",
    ".json", ".p4", ".yml", ".yaml", ".cmake", ".cfg", ".ini", ".toml", ".rst",
    ".log", ".diff", ".patch",
))

#: Verbatim records: someone else's bytes, quoted exactly. Correcting a citation inside one
#: would make the record a lie, so they are not read. See the module docstring.
VERBATIM_SUFFIXES = frozenset((".log", ".diff", ".patch"))

#: Directory names never descended into. `venv` is the symlink into the main checkout.
SKIP_DIR_NAMES = frozenset((
    ".git", "scratch", "venv", ".venv", "node_modules", "__pycache__", ".mypy_cache",
    ".pytest_cache", ".claude",
))

#: Directory name prefixes never descended into: build/, build-fuzz/, build-telemetry/...
SKIP_DIR_PREFIXES = ("build",)

#: An entry code as the ruling defines it: one uppercase letter, a hyphen, digits, and an
#: optional lowercase suffix (`A-4c`, `B-2d`). `\b` on both sides so `UTF-8` is not `F-8` and
#: `RFC-2119` is not `C-2119`.
CODE_RE = re.compile(r"\b([A-Z]-\d+[a-z]?)\b")

#: A citation by line number. `.md` is OPTIONAL -- the repo spells it both ways (20 of the 62
#: sites on `1a284f75` dropped the suffix), and a scanner that reads only the longer spelling
#: documents its own bypass. Widening of the ticket's regex; FIX-KIREF.md §5.
#: 🔴 No literal example here, on purpose: this file is inside the scanned tree, and the first
#: run of this scanner reported THIS comment as a finding about itself. `<N>` below stands for
#: the digits.
#:
#: 🔴 B12 (2026-09-11). This used to be `... ?: ?(\d+)` -- one colon, spelled one way, with
#: at most one space each side, and the document name hyphenated one way.
#: hunt-0911/F-B0-B12-REPORT.md §3.1 rows (5)b..(5)e put four re-spellings of ONE citation through
#: it and got `violations=0` out of every one: the name with an UNDERSCORE, a GitHub blob anchor
#: `#L<N>`, the English word `line <N>`, and extra spaces around the colon. A citation is a claim
#: about a line of that document whatever punctuation carries it, and the claim is what rots.
#:
#: The Chinese form is in for the same reason: this repo's documents are written in Chinese, and
#: doc/audit/2026-09-02_fix-design-campaign/findings/NDT-HARNESS.md:52 has been citing two line
#: numbers as `第<N>／<N>行` since 09-02. They went stale exactly the way the other 62 did -- the
#: lines it names are now inside an entry about netem scanning.
#:
#: 🔴 `行<N>` -- the marker BEFORE the number -- is deliberately NOT a line citation, and the
#: lookahead is what keeps them apart. §L of the document numbers its ROWS `| **02** |`,
#: `| **05** |`, and doc/audit/2026-09-02_fix-design-campaign/LEDGER.md:69's `行 02/05` means those
#: rows: a correct entry citation. Reading it as "lines 2 and 5" would report a citation that is
#: right, and the only way to get the tree green again would be to delete something true.
_KI_DOC = r"KNOWN[-_]ISSUES(?:\.md)?"
#: What may join the two numbers of a range, or two line numbers cited together.
_KI_JOIN = r"[-–—]|\#?L|／|/|、"
_KI_LINE_SEP = (
    r"[ \t]*[:：][ \t]*"                      # a colon, ASCII or fullwidth, any spacing
    r"|\#L"                                       # a GitHub blob anchor
    r"|[ \t]*,?[ \t]*[Ll]ines?[ \t]*"            # the English word
    # the Chinese form. The lookahead requires the marker AFTER the digits, which is what
    # separates a line citation from a row label -- see the note above.
    r"|[ \t]*第?[ \t]*(?=\d+(?:[ \t]*(?:" + _KI_JOIN + r")[ \t]*\d+)*[ \t]*行)"
)
CITATION_RE = re.compile(_KI_DOC + r"(?:" + _KI_LINE_SEP + r")(\d+)"
                         r"(?:[ \t]*(?:" + _KI_JOIN + r")[ \t]*(\d+))?")

#: A `### ` / `## ` heading. The negative lookahead matters: without it `^## ` also matches
#: `### A-1` (with the third `#` swallowed into the title) and every level-3 heading would be
#: indexed twice, once with a span that runs to the next level-2 heading.
H3_RE = re.compile(r"^### (?!#)(.*)$")
H2_RE = re.compile(r"^## (?!#)(.*)$")

#: The first cell of a table row, and what has to be left of it for the row to BE an entry.
#: §C's rows are `| 🏁 **F-14** | ...` and §D's is `| **F-4**<br>（＝subagent 那套編號） | ...`,
#: so the status marker and the `<br>` gloss are stripped before the cell is compared. A row
#: whose first cell is prose (`| 代號 | 說明 |`) is not an entry, and neither is one inside a
#: blockquote (`> | `F-1` | ...`) -- that table is the OTHER campaign's numbering, and reading
#: it as an entry index would make citations of the wrong F-1 look resolved.
FIRST_CELL_RE = re.compile(r"^\|([^|]*)(?:\||$)")
CELL_IS_CODE_RE = re.compile(r"(?:\W|\s)*([A-Z]-\d+[a-z]?)(?:\s*[（(\[【].*)?")

NO_CODE = "NO-CODE"
WRONG_ENTRY = "WRONG-ENTRY"
UNRESOLVABLE_CODE = "UNRESOLVABLE-CODE"
OUT_OF_RANGE = "OUT-OF-RANGE"

#: The sentence the ruling asks for. Kept in one place so the gate can mutate it and the tests
#: can assert on it without two spellings drifting apart.
FIX_ADVICE = "改成條目代號"


class Violation(object):
    """One citation that cannot be trusted, and everything needed to fix it in one line."""

    def __init__(self, path, line, raw, claimed, kind, actual):
        self.path = path          # repo-relative path of the FILE THAT CITES
        self.line = line          # 1-based line in that file
        self.raw = raw            # the citation exactly as written
        self.claimed = claimed    # entry code the citing line claims, or None
        self.kind = kind
        self.actual = actual      # entry the cited line really falls in, or a note

    def __str__(self):
        return "%s:%d  %-28s claims %-8s %-18s %s -- %s" % (
            self.path, self.line, self.raw, self.claimed or "(none)", self.kind,
            self.actual, FIX_ADVICE)

    __repr__ = __str__


# --- reading doc/KNOWN-ISSUES.md ----------------------------------------------------------

def parse_entries(text):
    """code -> [(first_line, last_line), ...], 1-based and inclusive.

    A code can own more than one span: `F-4` is a row in the §C table and another in the §D
    table, and a citation that lands in either of them is citing F-4.
    """
    lines = text.splitlines()
    spans = {}

    def add(code, start, end):
        spans.setdefault(code, []).append((start, end))

    def heading_spans(pattern):
        found = []
        for i, line in enumerate(lines, 1):
            m = pattern.match(line)
            if m:
                found.append((i, m.group(1)))
        for idx, (start, title) in enumerate(found):
            end = found[idx + 1][0] - 1 if idx + 1 < len(found) else len(lines)
            m = CODE_RE.search(title)
            if m:
                add(m.group(1), start, end)

    heading_spans(H3_RE)
    heading_spans(H2_RE)
    for i, line in enumerate(lines, 1):
        code = row_code(line)
        if code:
            add(code, i, i)
    return spans


def row_code(line):
    """The entry code a markdown table row declares, or None if the row is not an entry."""
    m = FIRST_CELL_RE.match(line)
    if not m:
        return None
    cell = m.group(1).split("<br>")[0].replace("*", "").strip()
    m2 = CELL_IS_CODE_RE.fullmatch(cell)
    return m2.group(1) if m2 else None


def entry_of(spans, n):
    """Which code owns line n? The narrowest span wins, so a table row inside a `##`
    section is reported rather than the section that encloses it."""
    best, best_width = None, None
    for code, ranges in spans.items():
        for start, end in ranges:
            if start <= n <= end:
                width = end - start
                if best_width is None or width < best_width:
                    best, best_width = code, width
    return best


# --- reading the citing files -------------------------------------------------------------

def paragraph_bounds(lines, idx):
    """The contiguous run of non-blank lines containing lines[idx] (0-based, inclusive)."""
    start = idx
    while start > 0 and lines[start - 1].strip():
        start -= 1
    end = idx
    while end + 1 < len(lines) and lines[end + 1].strip():
        end += 1
    return start, end


def claimed_code(lines, idx, col):
    """The entry code this citation claims: nearest on its own line, else in its paragraph.

    Same line first, by character distance from the citation. The paragraph fallback exists
    because a citation whose code sits in the sentence above it is sloppy, not wrong, and a
    scanner that called it a violation would spend its credibility on formatting.
    """
    same = [(abs(m.start() - col), m.group(1)) for m in CODE_RE.finditer(lines[idx])]
    if same:
        return min(same)[1]
    start, end = paragraph_bounds(lines, idx)
    near = []
    for j in range(start, end + 1):
        if j == idx:
            continue
        for m in CODE_RE.finditer(lines[j]):
            near.append((abs(j - idx), abs(m.start() - col), m.group(1)))
    return min(near)[2] if near else None


def check_text(rel_path, text, spans, ki_lines):
    """Every violation in one file's text."""
    out = []
    lines = text.splitlines()
    for idx, line in enumerate(lines):
        for m in CITATION_RE.finditer(line):
            n = int(m.group(1))
            m2 = int(m.group(2)) if m.group(2) else None
            code = claimed_code(lines, idx, m.start())
            raw = m.group(0)
            if code is None:
                out.append(Violation(rel_path, idx + 1, raw, None, NO_CODE,
                                     "line %d is in %s" % (n, entry_of(spans, n) or "no entry")))
                continue
            if code not in spans:
                out.append(Violation(rel_path, idx + 1, raw, code, UNRESOLVABLE_CODE,
                                     "%s has no heading or table row in %s" % (code, KI_NAME)))
                continue
            bad = [x for x in (n, m2) if x is not None and x > ki_lines]
            if bad:
                out.append(Violation(rel_path, idx + 1, raw, code, OUT_OF_RANGE,
                                     "%s has %d lines" % (KI_NAME, ki_lines)))
                continue
            for want in (n, m2):
                if want is None:
                    continue
                if not any(s <= want <= e for s, e in spans[code]):
                    out.append(Violation(
                        rel_path, idx + 1, raw, code, WRONG_ENTRY,
                        "line %d is in %s" % (want, entry_of(spans, want) or "no entry")))
                    break
    return out


def is_text_file(name):
    suffix = os.path.splitext(name)[1].lower()
    if suffix in VERBATIM_SUFFIXES:
        return False
    return suffix in TEXT_SUFFIXES


def iter_files(root):
    """Every file in scope, repo-relative, in a stable order."""
    for name in sorted(os.listdir(root)):
        if name.endswith(".md") and os.path.isfile(os.path.join(root, name)):
            yield name
    for top in SCAN_DIRS:
        base = os.path.join(root, top)
        if not os.path.isdir(base) or os.path.islink(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(
                d for d in dirnames
                if d not in SKIP_DIR_NAMES
                and not d.startswith(SKIP_DIR_PREFIXES)
                and not os.path.islink(os.path.join(dirpath, d)))
            for name in sorted(filenames):
                if is_text_file(name):
                    yield os.path.relpath(os.path.join(dirpath, name), root)


def scan_tree(root):
    """(violations, stats) for a whole tree. Raises if the document itself is missing --
    a scan that could not read what it compares against is not a clean scan."""
    ki_path = os.path.join(root, KI_REL)
    if not os.path.isfile(ki_path):
        raise IOError("%s is not in %s -- nothing to check citations against" % (KI_REL, root))
    with open(ki_path, encoding="utf-8", errors="replace") as fh:
        ki_text = fh.read()
    spans = parse_entries(ki_text)
    ki_lines = len(ki_text.splitlines())

    violations, scanned, citations = [], 0, 0
    for rel in iter_files(root):
        path = os.path.join(root, rel)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        scanned += 1
        # 🔴 A fast path is still a rule. This used to test for the hyphenated name, so the
        # underscore spelling B12 row (5)b found was skipped BEFORE CITATION_RE ever saw it --
        # a second spelling test, hidden behind an optimisation, and the widened regex alone
        # would not have fixed it. The prefix both spellings share is the only safe filter.
        if "KNOWN" not in text:
            continue
        citations += len(CITATION_RE.findall(text))
        violations.extend(check_text(rel, text, spans, ki_lines))
    return violations, {"files": scanned, "citations": citations,
                        "codes": len(spans), "ki_lines": ki_lines}


def report(violations):
    return "\n".join(["  " + str(v) for v in violations])


# --- fixtures -----------------------------------------------------------------------------
#
# A three-entry stand-in for doc/KNOWN-ISSUES.md. Written out rather than sliced from the real
# document so the line numbers the tests assert on stay put when the real one is edited -- which
# is the very thing this file is about.

FAKE_KI = "\n".join([
    "# NDTwin — 已知未修缺陷",      # 1
    "",                              # 2
    "## A. 正常操作就會發作",        # 3
    "",                              # 4
    "### A-1 🔴 第一條",             # 5
    "",                              # 6
    "A-1 的內容。",                  # 7
    "",                              # 8
    "### A-4c 🔴 第二條",            # 9
    "",                              # 10
    "A-4c 的內容。",                 # 11
    "第二行。",                      # 12
    "",                              # 13
    "## F. 環境限制",                # 14
    "",                              # 15
    "| 代號 | 說明 |",               # 16
    "|---|---|",                     # 17
    "| **F-9** | 量化到取樣粒度 |",  # 18
    "| 🏁 **F-13（群組計數）** | 記號＋註 |",  # 19
    "> | `F-1` | 另一套編號 |",      # 20
    "",                              # 21
    "### G-9 🔴 第三條",             # 22
    "",                              # 23
    "G-9 的內容。",                  # 24
    "",                              # 25
]) + "\n"


def cite(n, m=None, with_md=True):
    """Build a citation. Never written as a literal anywhere in this repo's tests, because
    tests/ is inside the scanned tree and a literal here would be a finding about itself."""
    return "%s%s:%d%s" % ("KNOWN-ISSUES", ".md" if with_md else "", n,
                          "-%d" % m if m else "")


SPELLINGS = ("underscore", "blob-anchor", "the-word-line", "roomy-colon",
             "fullwidth-colon", "chinese")


def cite_as(spelling, n, m=None):
    """The same citation of line `n`, in one of the spellings B12 found this scanner blind to.

    Assembled out of pieces for the reason cite() gives: tests/ is inside the scanned tree, so
    a literal citation written here would be a finding this file produces about itself.
    """
    doc = "KNOWN" + ("_" if spelling == "underscore" else "-") + "ISSUES" + ".md"
    span = "" if m is None else "-%d" % m
    if spelling == "underscore":
        return "%s:%d%s" % (doc, n, span)
    if spelling == "blob-anchor":
        return "%s#L%d%s" % (doc, n, "#L%d" % m if m else "")
    if spelling == "the-word-line":
        return "%s line %d%s" % (doc, n, span)
    if spelling == "roomy-colon":
        return "%s  :  %d%s" % (doc, n, span)
    if spelling == "fullwidth-colon":
        return "%s\uff1a%d%s" % (doc, n, span)
    if spelling == "chinese":
        inner = "%d" % n if m is None else "%d\uff0f%d" % (n, m)
        return "KNOWN" + "-" + "ISSUES \u7b2c %s \u884c" % inner
    if spelling == "chinese-row":
        inner = "%02d" % n if m is None else "%02d/%02d" % (n, m)
        return "KNOWN" + "-" + "ISSUES \u884c %s" % inner
    raise AssertionError("no such spelling: %r" % (spelling,))


class TreeFixture(object):
    """A throwaway tree with doc/KNOWN-ISSUES.md and whatever citing files a test needs."""

    def __init__(self, testcase, files):
        self.root = tempfile.mkdtemp(prefix="kiref-")
        testcase.addCleanup(self._cleanup)
        self.write(KI_REL, FAKE_KI)
        for rel, body in files.items():
            self.write(rel, body)

    def write(self, rel, body):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)

    def scan(self):
        return scan_tree(self.root)[0]

    def _cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


# --- the entry index ----------------------------------------------------------------------

class TheEntryIndex(unittest.TestCase):
    """Resolving a code to the lines it owns. Everything else is built on this."""

    def setUp(self):
        self.spans = parse_entries(FAKE_KI)

    def test_a_hash3_heading_owns_up_to_the_next_hash3(self):
        self.assertEqual([(5, 8)], self.spans.get("A-1"))
        self.assertEqual([(9, 21)], self.spans.get("A-4c"),
                         "A-4c runs to the line before the next `### `, crossing the `## F.` "
                         "heading -- that is the ruling's rule, not an accident")

    # .get(), not [] : a missing code must read as a FAILURE with the reason attached, not as a
    # KeyError. A gate that greps for "FAIL:" scores an ERROR as a survivor, so an assertion
    # that crashes instead of failing is an assertion the gate cannot see.
    def test_a_table_row_is_an_entry_too(self):
        self.assertEqual([(18, 18)], self.spans.get("F-9"),
                         "F-9 has no `### ` heading anywhere in the real document either; a "
                         "scanner that could not see it would call every F citation unresolvable")

    def test_a_status_marker_and_a_gloss_do_not_hide_the_row(self):
        self.assertEqual([(19, 19)], self.spans.get("F-13"),
                         "every row of the real §C table is `| 🏁 **F-n** | ...`, and §D's F-5 "
                         "row carries a parenthesised gloss after the code")

    def test_a_blockquoted_table_is_not_an_entry_index(self):
        self.assertNotIn("F-1", self.spans,
                         "the blockquoted table is the OTHER campaign's numbering; indexing it "
                         "would resolve citations of a different F-1")

    def test_the_narrowest_owner_wins(self):
        self.assertEqual("F-9", entry_of(self.spans, 18))
        self.assertEqual("A-4c", entry_of(self.spans, 16))

    def test_the_real_document_parses_into_entries(self):
        with open(os.path.join(REPO, KI_REL), encoding="utf-8") as fh:
            spans = parse_entries(fh.read())
        self.assertGreaterEqual(len(spans), 40,
                                "only %d codes resolved out of the real %s -- the parser has "
                                "gone blind and every citation would read as fine"
                                % (len(spans), KI_NAME))
        for code in ("A-1", "B-2d", "C-4b", "G-9"):
            self.assertIn(code, spans)


# --- what counts as a violation -----------------------------------------------------------

class WhatIsAViolation(unittest.TestCase):
    """The four verdicts, each on a tree built for it."""

    def test_a_correct_reference_is_not_a_violation(self):
        """🔴 THE CONTROL. Everything above is about firing; this is the only case that says
        the scanner can still hold its fire. A widening that reports a correct citation would
        satisfy every other test in this file and turn the gate into a ban on line numbers,
        which is not what was ruled."""
        t = TreeFixture(self, {"doc/x.md": "見 KNOWN-ISSUES A-4c（`doc/%s`）。\n" % cite(11)})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_a_correct_range_is_not_a_violation(self):
        t = TreeFixture(self, {"doc/x.md": "A-4c（`%s`）\n" % cite(11, 12)})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_a_line_in_another_entry_is_reported(self):
        t = TreeFixture(self, {"doc/x.md": "見 KNOWN-ISSUES A-1（`doc/%s`）。\n" % cite(11)})
        v = t.scan()
        self.assertEqual(1, len(v), report(v))
        self.assertEqual(WRONG_ENTRY, v[0].kind)
        self.assertEqual("A-1", v[0].claimed)
        self.assertIn("A-4c", v[0].actual, "the report must name where line 11 really is")

    def test_the_far_end_of_a_range_is_checked_too(self):
        t = TreeFixture(self, {"doc/x.md": "A-1（`%s`）\n" % cite(7, 11)})
        v = t.scan()
        self.assertEqual(1, len(v), report(v))
        self.assertEqual(WRONG_ENTRY, v[0].kind,
                         "line 7 is inside A-1; line 11 is not, and a range is only as good "
                         "as its far end")

    def test_a_citation_with_no_code_is_reported_and_says_what_to_do(self):
        t = TreeFixture(self, {"doc/x.md": "細節見 `doc/%s`。\n" % cite(11)})
        v = t.scan()
        self.assertEqual(1, len(v), report(v))
        self.assertEqual(NO_CODE, v[0].kind)
        self.assertIn(FIX_ADVICE, str(v[0]))
        self.assertIn("A-4c", v[0].actual)

    def test_a_code_with_no_entry_at_all_is_not_silently_accepted(self):
        t = TreeFixture(self, {"doc/x.md": "見 KNOWN-ISSUES Z-3（`%s`）\n" % cite(11)})
        v = t.scan()
        self.assertEqual(1, len(v), report(v))
        self.assertEqual(UNRESOLVABLE_CODE, v[0].kind)

    def test_a_line_past_the_end_of_the_document_is_its_own_verdict(self):
        t = TreeFixture(self, {"doc/x.md": "A-1（`%s`）\n" % cite(9999)})
        v = t.scan()
        self.assertEqual(1, len(v), report(v))
        self.assertEqual(OUT_OF_RANGE, v[0].kind)

    def test_the_code_may_sit_one_line_above(self):
        t = TreeFixture(self, {"doc/x.md":
                               "KNOWN-ISSUES A-4c 講的是第二條，\n細節在 `%s`。\n" % cite(11)})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_a_code_in_a_different_paragraph_does_not_count(self):
        t = TreeFixture(self, {"doc/x.md":
                               "KNOWN-ISSUES A-4c 是另一段。\n\n細節在 `%s`。\n" % cite(11)})
        v = t.scan()
        self.assertEqual(1, len(v), report(v))
        self.assertEqual(NO_CODE, v[0].kind)

    def test_the_nearest_code_on_the_line_is_the_one_claimed(self):
        t = TreeFixture(self, {"doc/x.md":
                               "A-1 與 A-4c 兩條都相關，這裡引 A-4c `%s`。\n" % cite(11)})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_the_md_less_spelling_is_read_too(self):
        t = TreeFixture(self, {"doc/x.md": "A-1（`%s`）\n" % cite(11, with_md=False)})
        v = t.scan()
        self.assertEqual(1, len(v), report(v))
        self.assertEqual(WRONG_ENTRY, v[0].kind,
                         "20 of the 62 sites on 1a284f75 wrote it without `.md`; a scanner "
                         "blind to that spelling ships its own bypass")


class TheSpellingOfTheCitationIsNotThePoint(unittest.TestCase):
    """B12: the same claim about the same line, written the ways this tree actually writes it.

    🔴 Every case below came back `violations=0` on trunk c81dabbb -- see
    logs/gates-0910/b12-test_known_issues_references.BEFORE.log, which runs this class against
    the old one-colon regex. Not one of them differs from
    WhatIsAViolation.test_a_line_in_another_entry_is_reported in what it CLAIMS; they differ in
    the punctuation that carries the claim. A citation rots because the document moved under it,
    and the document does not know which separator was used.
    """

    def test_each_spelling_of_a_wrong_line_is_reported(self):
        for spelling in SPELLINGS:
            with self.subTest(spelling=spelling):
                t = TreeFixture(self, {"doc/x.md": "\u898b KNOWN-ISSUES A-1\uff08`%s`\uff09\u3002\n"
                                                   % cite_as(spelling, 11)})
                v = t.scan()
                self.assertEqual(1, len(v), report(v))
                self.assertEqual(WRONG_ENTRY, v[0].kind)
                self.assertEqual("A-1", v[0].claimed)
                self.assertIn("A-4c", v[0].actual)

    def test_two_line_numbers_cited_together_are_both_checked(self):
        """NDT-HARNESS.md:52's shape: two lines joined by a fullwidth solidus. The near end is
        inside the entry claimed and the far end is not, so a scanner that read only the first
        number would call this correct."""
        t = TreeFixture(self, {"doc/x.md": "A-1\uff08`%s`\uff09\n" % cite_as("chinese", 7, 11)})
        v = t.scan()
        self.assertEqual(1, len(v), report(v))
        self.assertEqual(WRONG_ENTRY, v[0].kind)

    def test_a_citation_with_no_code_is_reported_in_every_spelling_too(self):
        for spelling in SPELLINGS:
            with self.subTest(spelling=spelling):
                t = TreeFixture(self, {"doc/x.md": "\u7d30\u7bc0\u898b `%s`\u3002\n"
                                                   % cite_as(spelling, 11)})
                v = t.scan()
                self.assertEqual(1, len(v), report(v))
                self.assertEqual(NO_CODE, v[0].kind)
                self.assertIn(FIX_ADVICE, str(v[0]))


class TheWideningStillHoldsItsFire(unittest.TestCase):
    """🔴 The other direction, one control per spelling admitted above.

    A scanner that reported a CORRECT citation would satisfy every case in the class above and
    turn the ruling into a ban on line numbers, which is not what was ruled -- and the only way
    to get the tree green again would be to delete something true.
    """

    def test_a_correct_citation_in_each_spelling_is_left_alone(self):
        for spelling in SPELLINGS:
            with self.subTest(spelling=spelling):
                t = TreeFixture(self, {"doc/x.md": "\u898b KNOWN-ISSUES A-4c\uff08`%s`\uff09\u3002\n"
                                                   % cite_as(spelling, 11)})
                self.assertEqual([], t.scan(), report(t.scan()))

    def test_a_row_label_is_not_a_line_number(self):
        """🔴 The case that pays for the Chinese spelling. §L of the document numbers its ROWS
        `| **02** |` and `| **05** |`, and
        doc/audit/2026-09-02_fix-design-campaign/LEDGER.md:69 cites them as `行 02/05` -- the
        marker BEFORE the number, which in this repo means the row and not the line. Reading it
        as "lines 2 and 5" reports a correct entry citation as a violation."""
        t = TreeFixture(self, {"doc/x.md": "NDT-HARNESS\uff1a%s \u5df2\u904e\u671f\u3002\n"
                                           % cite_as("chinese-row", 2, 5)})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_a_bare_entry_code_is_still_invisible(self):
        """The ruling's whole point: `KNOWN-ISSUES B-11` with no line number is the CORRECT
        citation, and this scanner must have nothing to say about it."""
        t = TreeFixture(self, {"doc/x.md": "\u898b KNOWN-ISSUES A-4c\u3002\n"})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_another_document_with_a_line_number_is_not_this_document(self):
        t = TreeFixture(self, {"doc/x.md": "\u898b `OTHER-ISSUES.md:11`\u3002\n"})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_a_chapter_number_is_not_a_line_number(self):
        """`\u7b2c N \u7ae0` is a chapter, `\u7b2c N \u884c` is a line. The lookahead reads the marker that
        follows the digits, so the two do not collapse into each other."""
        t = TreeFixture(self, {"doc/x.md":
                               "\u898b KNOWN" + "-" + "ISSUES \u7b2c 11 \u7ae0\u3002\n"})
        self.assertEqual([], t.scan(), report(t.scan()))


# --- which files are read -----------------------------------------------------------------

class WhichFilesAreRead(unittest.TestCase):
    """Coverage is half the instrument: a rule nobody applies to `.cpp` does not cover `.cpp`."""

    BAD = "// F-9 -- doc/%s\n"

    def test_a_cpp_comment_is_scanned(self):
        t = TreeFixture(self, {"tests/test_Thing.cpp": self.BAD % cite(11)})
        v = t.scan()
        self.assertEqual(1, len(v), report(v))
        self.assertEqual("tests/test_Thing.cpp", v[0].path)

    def test_a_python_comment_is_scanned(self):
        t = TreeFixture(self, {"tests/python/test_thing.py": "# F-9 (doc/%s)\n" % cite(11)})
        self.assertEqual(1, len(t.scan()), report(t.scan()))

    def test_a_shell_script_is_scanned(self):
        t = TreeFixture(self, {"tools/thing.sh": "# F-9 doc/%s\n" % cite(11)})
        self.assertEqual(1, len(t.scan()), report(t.scan()))

    def test_a_header_is_scanned(self):
        t = TreeFixture(self, {"include/Thing.hpp": self.BAD % cite(11)})
        self.assertEqual(1, len(t.scan()), report(t.scan()))

    def test_a_root_level_markdown_file_is_scanned(self):
        t = TreeFixture(self, {"NEXT.md": "F-9 `doc/%s`\n" % cite(11)})
        self.assertEqual(1, len(t.scan()), report(t.scan()))

    def test_a_log_is_a_verbatim_record_and_is_not_read(self):
        t = TreeFixture(self, {"doc/audit/round.log": self.BAD % cite(11)})
        self.assertEqual([], t.scan(),
                         "a log is somebody else's bytes; correcting a citation inside one "
                         "would falsify the record")

    def test_a_diff_and_a_patch_are_not_read_either(self):
        t = TreeFixture(self, {"doc/a.diff": self.BAD % cite(11),
                               "doc/b.patch": self.BAD % cite(11)})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_scratch_is_not_read(self):
        t = TreeFixture(self, {"doc/scratch/notes.md": "F-9 `%s`\n" % cite(11)})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_a_build_tree_is_not_read(self):
        t = TreeFixture(self, {"tools/build-fuzz/copy.md": "F-9 `%s`\n" % cite(11)})
        self.assertEqual([], t.scan(), report(t.scan()))

    def test_a_binary_suffix_is_not_read(self):
        t = TreeFixture(self, {"doc/audit/raw.jsonl": "F-9 `%s`\n" % cite(11)})
        self.assertEqual([], t.scan(), report(t.scan()))


# --- the repository as it stands ----------------------------------------------------------

class TheRepositoryAsItStands(unittest.TestCase):
    """The standing gate. Everything above proves the scanner works; this is what it says."""

    def test_every_line_number_citation_names_the_entry_it_lands_in(self):
        violations, _ = scan_tree(REPO)
        # assertEqual(0, len(...)) rather than assertEqual([], ...): the list form prints
        # unittest's own truncated sequence diff and hides the report, and the report IS the
        # deliverable -- one line per citation, with the file, the code it claims and the entry
        # its line really lands in.
        self.assertEqual(
            0, len(violations),
            "%d citation(s) of %s cannot be trusted. %s -- 見 doc/audit/"
            "2026-09-07_fix-known-issues-references/FIX-KIREF.md：\n%s"
            % (len(violations), KI_NAME, FIX_ADVICE, report(violations)))

    def test_the_scan_actually_read_the_repository(self):
        """A green scan of nothing is the failure mode this whole family of gates exists to
        catch. Floors, not exact counts, so ordinary growth does not turn it red."""
        _, stats = scan_tree(REPO)
        self.assertGreaterEqual(stats["files"], 800,
                                "only %d file(s) read -- the walk is not reaching the tree"
                                % stats["files"])
        self.assertGreaterEqual(stats["codes"], 40,
                                "only %d entry code(s) resolved out of %s"
                                % (stats["codes"], KI_NAME))
        self.assertGreaterEqual(stats["ki_lines"], 2000,
                                "%s is %d lines -- that is not the document"
                                % (KI_NAME, stats["ki_lines"]))

    def test_this_file_and_its_gate_are_inside_the_scanned_tree(self):
        """No self-exemption. If either ever stops being scanned, the reason it contains no
        literal citation stops being a discipline and becomes an accident."""
        scanned = set(iter_files(REPO))
        for rel in (os.path.join("tests", "python", "test_known_issues_references.py"),
                    os.path.join("tests", "shell", "mutate_known_issues_references.sh")):
            # Not assertIn: its failure message prints the whole 1,000-entry set and buries
            # the one name that matters.
            self.assertTrue(rel in scanned, "%s is not in the scanned set" % rel)


if __name__ == "__main__":
    unittest.main(verbosity=2)
