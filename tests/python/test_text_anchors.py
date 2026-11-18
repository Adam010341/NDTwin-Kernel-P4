#!/usr/bin/env python3
"""Every anchor a tool reads must name exactly one place in the code, by text.

[Co-developed with claude code -- Adam]

A line number is wrong as soon as anyone edits the file above it. `tools/test_workflow/ndt` is
over 12,000 lines and almost every change to it moved the numbers other files held, so each
change had to re-number them and every branch carrying one had to be redone. A tool-read anchor
is therefore a TEXT anchor: a run of whole lines, compared with surrounding whitespace stripped,
that must occur in exactly one place in its file. Lines inserted or removed elsewhere do not move
it; a change to the code it names breaks it, and this check says so.

The anchors checked here, and the files they name:

  * tools/ndt_serve/verbs.py RC_SOURCE, its "code" rows -> tools/test_workflow/ndt.
    Each row is (rc, needle, function, snippet). This file checks that the snippet occurs exactly
    once and that the needle is on exactly one of its lines. That the line is in the named
    function and the rc set matches the table is tests/python/test_ndt_serve.py RcProvenance.

A new kind of tool-read anchor is added to `tool_read_anchors()` below, so this one check
keeps covering all of them.

NDT_SERVE_UNDER_TEST and NDT_UNDER_TEST point the check at another copy of the service and of
ndt, the same seams tests/python/test_ndt_serve.py has.

Run:  python3 tests/python/test_text_anchors.py -v
"""
import importlib.util
import os
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SERVE_DIR = os.environ.get("NDT_SERVE_UNDER_TEST") or os.path.join(REPO, "tools", "ndt_serve")
NDT = os.environ.get("NDT_UNDER_TEST") or os.path.join(REPO, "tools", "test_workflow", "ndt")


def locate(lines, snippet):
    """The 1-based line numbers where `snippet` (a sequence of lines) starts in `lines`, each line
    compared with surrounding whitespace stripped. An empty snippet locates nowhere."""
    want = [s.strip() for s in snippet]
    if not want or not all(want[0:1]):
        return []
    have = [s.strip() for s in lines]
    k = len(want)
    return [i + 1 for i in range(len(have) - k + 1) if have[i] == want[0] and have[i:i + k] == want]


def resolve(lines, snippet, needle):
    """(line, problem) for one anchor. line is the 1-based line of `lines` that holds `needle`
    inside the one place `snippet` matches; problem is None when it resolves, else what is wrong."""
    starts = locate(lines, snippet)
    if len(starts) != 1:
        return None, "matches %d places, not 1" % len(starts)
    hits = [j for j, s in enumerate(snippet) if needle in s]
    if len(hits) != 1:
        return None, "the needle %r is on %d of its lines, not 1" % (needle, len(hits))
    return starts[0] + hits[0], None


def _load_verbs(serve_dir):
    spec = importlib.util.spec_from_file_location("verbs_under_test", os.path.join(serve_dir, "verbs.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def tool_read_anchors(serve_dir=SERVE_DIR, ndt=NDT):
    """Every tool-read anchor in the tree: (label, path of the file it names, snippet, needle)."""
    verbs = _load_verbs(serve_dir)
    out = []
    for kind, src in verbs.RC_SOURCE.items():
        for row in src.get("code", ()):
            rc, needle, func, snippet = row
            out.append(("verbs.RC_SOURCE[%r] rc %d (%s)" % (kind, rc, func), ndt, snippet, needle))
    return out


def _read_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines()


class EveryToolReadAnchor(unittest.TestCase):

    def test_every_tool_read_anchor_resolves_to_exactly_one_place(self):
        """Every anchor is checked and every broken one is named, not only the first. A check
        that found no anchors at all would prove nothing, so that is a failure too."""
        anchors = tool_read_anchors()
        self.assertGreater(len(anchors), 0, "no tool-read anchors were found")
        cache, bad = {}, []
        for label, path, snippet, needle in anchors:
            if path not in cache:
                cache[path] = _read_lines(path)
            _line, problem = resolve(cache[path], snippet, needle)
            if problem:
                bad.append("%s: %s in %s: %r" % (label, problem, os.path.relpath(path, REPO), snippet))
        self.assertEqual(bad, [])

    def test_no_rc_source_row_carries_a_line_number(self):
        """A row is (rc, needle, function, snippet): an int rc, two strings and a tuple of strings.
        A row that grows a line number back fails here."""
        verbs = _load_verbs(SERVE_DIR)
        bad = []
        for kind, src in verbs.RC_SOURCE.items():
            for row in src.get("code", ()):
                ok = (isinstance(row, tuple) and len(row) == 4 and isinstance(row[0], int)
                      and isinstance(row[1], str) and isinstance(row[2], str) and isinstance(row[3], tuple)
                      and len(row[3]) > 0 and all(isinstance(s, str) for s in row[3]))
                if not ok:
                    bad.append("%s: %r" % (kind, row))
        self.assertEqual(bad, [])


class TheRuleItself(unittest.TestCase):
    """The rule on small texts, so a resolver that always said yes cannot pass unnoticed."""

    TEXT = ["f() {", "    if x; then", "        return 1", "    fi", "    return 0", "}",
            "g() {", "    if x; then", "        return 1", "    fi", "}"]

    def test_a_snippet_that_matches_nowhere_does_not_resolve(self):
        self.assertEqual(resolve(self.TEXT, ("return 7",), "return 7"), (None, "matches 0 places, not 1"))

    def test_a_snippet_that_matches_twice_does_not_resolve(self):
        self.assertEqual(resolve(self.TEXT, ("if x; then", "return 1"), "return 1"),
                         (None, "matches 2 places, not 1"))

    def test_a_snippet_that_matches_once_resolves_to_its_needle_line(self):
        self.assertEqual(resolve(self.TEXT, ("return 1", "fi", "return 0"), "return 0"), (5, None))

    def test_the_needle_must_be_on_exactly_one_line_of_the_snippet(self):
        self.assertEqual(resolve(self.TEXT, ("return 1", "fi", "return 0"), "return")[1],
                         "the needle 'return' is on 2 of its lines, not 1")
        self.assertEqual(resolve(self.TEXT, ("return 1", "fi", "return 0"), "exit")[1],
                         "the needle 'exit' is on 0 of its lines, not 1")

    def test_indentation_does_not_matter_but_every_other_character_does(self):
        self.assertEqual(locate(self.TEXT, ("  return 1  ", "fi", "return 0")), [3])
        self.assertEqual(locate(self.TEXT, ("return 1", "fi;", "return 0")), [])

    def test_an_empty_snippet_resolves_nowhere(self):
        self.assertEqual(locate(self.TEXT, ()), [])
        self.assertEqual(locate(self.TEXT, ("",)), [])

    def test_lines_inserted_above_move_the_line_but_not_the_anchor(self):
        """The real anchors against the real ndt with 50 blank lines put in front of it: every one
        still resolves, to the same text 50 lines further down."""
        lines = _read_lines(NDT)
        shifted = [""] * 50 + lines
        for label, path, snippet, needle in tool_read_anchors():
            if path != NDT:
                continue
            before, p1 = resolve(lines, snippet, needle)
            after, p2 = resolve(shifted, snippet, needle)
            self.assertEqual((p1, p2), (None, None), label)
            self.assertEqual(after, before + 50, label)
            self.assertEqual(shifted[after - 1], lines[before - 1], label)


if __name__ == "__main__":
    unittest.main(verbosity=2)
