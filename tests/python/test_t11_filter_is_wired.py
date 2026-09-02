"""
T-11-A wiring guard: the phantom filter must stay CONNECTED, not merely present.

[Co-developed with claude code -- Adam]

## Why this file exists

`91e7743` ("Serve only the flow entries that were actually programmed") fixed KNOWN-ISSUES
B-1 by filtering unconfirmed rows out of the flow-table view. It shipped
`tests/test_PendingEntryFilter.cpp`, eight gtest cases, and those are good tests -- but they
include exactly two headers:

    #include "ndt_core/routing_management/DispatchOutcomeLog.hpp"
    #include "ndt_core/routing_management/PendingEntryFilter.hpp"

They call the pure function `stripUnprogrammedEntries()` directly. They never construct
`DeviceConfigurationAndPowerManager`, never call `getOpenFlowTables()`, and never go near
`HttpSession`. So they verify that the RULE is written correctly and say nothing about
whether the rule RUNS.

The fix has three wiring points. Cut any of them and all eight gtest cases stay green:

    W1  DeviceConfigurationAndPowerManager::getOpenFlowTables() calls the filter.
        Cut it -> the phantom returns in full, to all three cache consumers.

    W2  main.cpp injects the confirmation predicate.
        Cut it -> the predicate is empty. That default withholds every tokened row
        (deliberately conservative), so the failure is a view that under-reports for one
        poll interval rather than a phantom -- still wrong, and still silent.

    W3  HttpSession stamps the token onto the rows it hands the cache.
        Cut it -> rows arrive untokened, the filter reads them as polled-from-the-switch
        entries and must not touch them, and the phantom returns in full.

The only thing that ever exercised the wiring was the live acceptance
(`doc/audit/2026-08-31_live-acceptance-batch/`), which needs a fabric and therefore cannot
run in CI. This file is the CI-runnable half.

## Why this file parses instead of grepping -- and how it learned to

The first version of this guard matched substrings against the raw file. The coordinator
killed it with one mutation the original battery had not tried:

    sed -i '1975s|^|//MUTANT |' .../DeviceConfigurationAndPowerManager.cpp

Commenting the call out left the guard GREEN, because `"stripUnprogrammedEntries(" in text`
cannot tell a statement from a comment. That is exactly the hole this file was written to
report in the gtests, reproduced inside the instrument that reports it -- and commenting a
line out is the *realistic* way wiring dies, because it is what someone does when they
disable something "temporarily".

So the source is now preprocessed before anything is matched:

  * `//` line comments, `/* */` block comments, string literals, char literals and raw
    string literals are blanked (length- and newline-preserving, so offsets and line numbers
    still line up with the file on disk);
  * `#if 0 ... #endif` regions are blanked, honouring nesting and `#else`/`#elif`;
  * the filter call must sit at the top level of the function body -- brace depth 1 -- which
    is what kills `if (false) { ... }` and any other conditional smuggled around it.

`SourcePreprocessorTest` below tests the preprocessor itself against the hazards actually
present in these files: `"http://"` inside a string (a `//` that is not a comment),
`R"({"error":"..."})"` raw strings carrying unbalanced-looking braces, and escaped quotes.
A guard whose instrument is untested is not a guard; this project has paid for that before.

## What this file is NOT

It reads source text, not semantics. It proves the call is written and reachable, not that
it computes the right thing. Three things it deliberately cannot see, all of them covered by
`tests/test_PendingEntryFilter.cpp`:

  * a predicate that always answers true (gtest T4's territory);
  * `stripUnprogrammedEntries` reimplemented as a no-op;
  * the filter being correct but the confirmation index being wrong.

Treat this as a tripwire against silent disconnection during a refactor, not as evidence the
filter works -- that evidence is the gtest suite plus the live batch. The two layers are
complementary on purpose: this one guards the joints, that one guards the rule.

Related: memory `existence-is-not-wiring`.

## Standard library only

Everything in tests/python runs under plain `python3` and may depend on nothing outside the
standard library; l1_unit_tests.sh enforces that.
"""

from __future__ import annotations

import os
import re
import unittest


# --------------------------------------------------------------------------------------
# Source preprocessing
# --------------------------------------------------------------------------------------


def blank_comments_and_literals(source: str) -> str:
    """Blank comments and literals, preserving length and newlines.

    Every character that is not live code becomes a space, except newlines, which are kept
    so that line numbers and character offsets still match the file on disk. Handles raw
    strings (`R"delim(...)delim"`), ordinary strings with backslash escapes, and char
    literals -- all three occur in the files this guard reads, and a stripper that mishandles
    any of them corrupts the very text the assertions run on.
    """
    chars = list(source)
    n = len(source)

    def blank(start: int, end: int) -> None:
        for k in range(max(start, 0), min(end, n)):
            if chars[k] != "\n":
                chars[k] = " "

    i = 0
    while i < n:
        c = source[i]

        # Raw string: R"delim( ... )delim" -- may contain //, /*, quotes and braces.
        if c == "R" and i + 1 < n and source[i + 1] == '"':
            paren = source.find("(", i + 2)
            delimiter = source[i + 2 : paren] if paren != -1 else None
            if paren != -1 and "\n" not in delimiter and len(delimiter) <= 16:
                closing = ")" + delimiter + '"'
                end = source.find(closing, paren + 1)
                if end != -1:
                    blank(i + 2, end + len(closing) - 1)
                    i = end + len(closing)
                    continue

        # Ordinary string or char literal.
        if c == '"' or c == "'":
            j = i + 1
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j] == c or source[j] == "\n":
                    break
                j += 1
            blank(i + 1, j)
            i = j + 1
            continue

        if c == "/" and i + 1 < n and source[i + 1] == "/":
            end = source.find("\n", i)
            end = n if end == -1 else end
            blank(i, end)
            i = end
            continue

        if c == "/" and i + 1 < n and source[i + 1] == "*":
            end = source.find("*/", i + 2)
            end = n if end == -1 else end + 2
            blank(i, end)
            i = end
            continue

        i += 1

    return "".join(chars)


_IF_OPEN = re.compile(r"^#\s*(if|ifdef|ifndef)\b")
_IF_ZERO = re.compile(r"^#\s*if\s+0\s*$")
_IF_ELSE = re.compile(r"^#\s*(else|elif)\b")
_IF_END = re.compile(r"^#\s*endif\b")


def blank_if_zero(source: str) -> str:
    """Blank `#if 0 ... #endif` regions, preserving line count and length.

    Nesting is tracked so an inner `#if`/`#endif` pair cannot end the disabled region early,
    and `#else`/`#elif` at the outermost disabled level re-enables, because that branch is
    the one the compiler keeps.
    """
    out = []
    nesting = 0  # 0 == not skipping
    for line in source.split("\n"):
        stripped = line.strip()
        if nesting:
            if _IF_OPEN.match(stripped):
                nesting += 1
            elif _IF_END.match(stripped):
                nesting -= 1
            elif _IF_ELSE.match(stripped) and nesting == 1:
                nesting = 0
            out.append(" " * len(line))
            continue
        if _IF_ZERO.match(stripped):
            nesting = 1
            out.append(" " * len(line))
            continue
        out.append(line)
    return "\n".join(out)


def preprocess(source: str) -> str:
    """Everything a match should not see, removed. Comments first: a commented-out
    `#if 0` must not start a disabled region."""
    return blank_if_zero(blank_comments_and_literals(source))


# --------------------------------------------------------------------------------------
# Locating the code under guard
# --------------------------------------------------------------------------------------


def _repo_root() -> str:
    """Walk up from this file until the directory holding src/main.cpp is found."""
    here = os.path.dirname(os.path.abspath(__file__))
    while True:
        if os.path.isfile(os.path.join(here, "src", "main.cpp")):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            raise AssertionError("repo root not found: no ancestor contains src/main.cpp")
        here = parent


ROOT = _repo_root()

DEVICE_MANAGER = os.path.join(
    ROOT, "src", "ndt_core", "power_management", "DeviceConfigurationAndPowerManager.cpp"
)
MAIN_CPP = os.path.join(ROOT, "src", "main.cpp")
HTTP_SESSION = os.path.join(ROOT, "src", "ndt_core", "http", "HttpSession.cpp")

GET_TABLES = "DeviceConfigurationAndPowerManager::getOpenFlowTables()"


def code_of(path: str) -> str:
    """The file with comments, literals and `#if 0` regions blanked."""
    with open(path, encoding="utf-8") as fh:
        return preprocess(fh.read())


def function_body(code: str, signature: str, path: str) -> str:
    """Return the text of the function whose definition line is `signature`.

    `code` must already be preprocessed, so a mention of the signature inside a comment
    cannot be mistaken for the definition. This repo puts both the opening and the closing
    brace of a free-standing definition in column 0, so the body runs from the signature to
    the next line that is exactly "}".
    """
    start = code.find(signature)
    if start == -1:
        raise AssertionError(
            "{}: definition {!r} not found in live code. If it was renamed, this guard "
            "must be updated deliberately -- do not delete it.".format(path, signature)
        )
    end = code.find("\n}\n", start)
    if end == -1:
        raise AssertionError("{}: could not find the end of {!r}".format(path, signature))
    return code[start:end]


def brace_depth_at(body: str, index: int) -> int:
    """Brace depth of `body[index]`, counting the function's own body as depth 1."""
    opening = body.find("{")
    if opening == -1 or opening > index:
        raise AssertionError("no opening brace before the statement being measured")
    depth = 1
    for ch in body[opening + 1 : index]:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
    return depth


# --------------------------------------------------------------------------------------
# The instrument's own tests
# --------------------------------------------------------------------------------------


class SourcePreprocessorTest(unittest.TestCase):
    """The preprocessor is load-bearing; an untested one would let the guard lie quietly.

    Each case here is a hazard that actually occurs in the three files this guard reads.
    """

    def test_a_double_slash_inside_a_string_is_not_a_comment(self):
        # DeviceConfigurationAndPowerManager.cpp:838 and friends build curl command lines.
        code = preprocess('auto url = "http://host:8000/relay"; keepThis();')
        self.assertIn("keepThis();", code)

    def test_an_escaped_quote_does_not_end_a_string(self):
        # DeviceConfigurationAndPowerManager.cpp:225 contains "\"http://".
        code = preprocess('auto s = "a\\"b//c"; keepThis();')
        self.assertIn("keepThis();", code)

    def test_a_raw_string_is_blanked_including_its_braces(self):
        # HttpSession.cpp:415 etc: R"({"error":"..."})" -- braces that must not be counted.
        code = preprocess('res.body() = R"({"error":"x"})"; keepThis();')
        self.assertIn("keepThis();", code)
        self.assertNotIn("error", code)
        self.assertEqual(code.count("{"), 0)
        self.assertEqual(code.count("}"), 0)

    def test_a_regex_raw_string_survives_backslashes(self):
        # DeviceConfigurationAndPowerManager.cpp:955: R"(INTEGER:\s*(\d+))"
        code = preprocess('static const std::regex re(R"(INTEGER:\\s*(\\d+))"); keepThis();')
        self.assertIn("keepThis();", code)
        self.assertNotIn("INTEGER", code)

    def test_line_comments_are_removed(self):
        self.assertNotIn("gone", preprocess("live(); // gone\n"))

    def test_block_comments_are_removed_across_lines(self):
        self.assertNotIn("gone", preprocess("live();\n/* gone\n still gone */\nalso();\n"))

    def test_if_zero_regions_are_removed(self):
        self.assertNotIn("gone", preprocess("live();\n#if 0\ngone();\n#endif\nalso();\n"))

    def test_nested_if_inside_if_zero_does_not_end_it_early(self):
        source = "#if 0\ngone();\n#ifdef X\nalsogone();\n#endif\nstillgone();\n#endif\nlive();\n"
        code = preprocess(source)
        self.assertNotIn("gone", code)
        self.assertIn("live();", code)

    def test_else_inside_if_zero_re_enables(self):
        # The #else branch is what the compiler keeps, so it must survive.
        code = preprocess("#if 0\ngone();\n#else\nkept();\n#endif\n")
        self.assertNotIn("gone", code)
        self.assertIn("kept();", code)

    def test_offsets_and_line_count_are_preserved(self):
        source = 'a(); // x\n/* y */\nb();\n'
        code = preprocess(source)
        self.assertEqual(len(code), len(source))
        self.assertEqual(code.count("\n"), source.count("\n"))


# --------------------------------------------------------------------------------------
# W1 -- the read path
# --------------------------------------------------------------------------------------


class FilterIsWiredIntoTheReadPath(unittest.TestCase):
    """W1: the one common read exit applies the filter."""

    def setUp(self):
        self.body = function_body(code_of(DEVICE_MANAGER), GET_TABLES, DEVICE_MANAGER)

    def test_get_openflow_tables_calls_the_filter(self):
        self.assertIn(
            "stripUnprogrammedEntries(",
            self.body,
            msg=(
                "getOpenFlowTables() no longer calls stripUnprogrammedEntries() in live code "
                "(the body shown above is the file with comments, literals and #if 0 regions "
                "blanked -- so a commented-out call reads as absent, which is the point). "
                "This is the single read exit shared by "
                "/ndt/get_switch_openflow_table_entries, LLMAgent::getCurrentFlowEntries() "
                "and IntentTranslator -- without this call every one of them serves "
                "KNOWN-ISSUES B-1's phantom again. The eight cases in "
                "tests/test_PendingEntryFilter.cpp cannot see this: they call the filter "
                "directly and stay green."
            ),
        )

    def test_the_filter_call_is_not_nested_in_a_conditional(self):
        """`if (false) { strip(...); }` compiles, reads as wired, and does nothing."""
        index = self.body.find("stripUnprogrammedEntries(")
        self.assertNotEqual(index, -1, msg="no live call to stripUnprogrammedEntries()")
        depth = brace_depth_at(self.body, index)
        self.assertEqual(
            depth,
            1,
            msg=(
                "stripUnprogrammedEntries() is called at brace depth {} instead of 1, so it "
                "sits inside a nested block rather than at the top level of "
                "getOpenFlowTables(). A call wrapped in `if (false) {{ ... }}` -- or behind "
                "any other condition -- is present in the source and absent at run time, "
                "which is the failure this assertion exists to catch. The filter is "
                "unconditional by design: making it conditional is a change that must be "
                "argued for, not one that should slip past a wiring guard.".format(depth)
            ),
        )

    def test_the_filter_is_applied_to_the_copy_that_is_returned(self):
        """Filtering a different object than the one returned would be a silent no-op."""
        match = re.search(r"stripUnprogrammedEntries\(\s*([A-Za-z_][A-Za-z0-9_]*)", self.body)
        self.assertIsNotNone(
            match, msg="stripUnprogrammedEntries() is not called with a named variable"
        )
        filtered = match.group(1)
        self.assertRegex(
            self.body,
            r"return\s+" + re.escape(filtered) + r"\s*;",
            msg=(
                "getOpenFlowTables() filters {0!r} but does not return it. Filtering an object "
                "that is then discarded restores the phantom while looking, in a diff, exactly "
                "like a working filter.".format(filtered)
            ),
        )


# --------------------------------------------------------------------------------------
# W2 -- the confirmation predicate
# --------------------------------------------------------------------------------------


class ConfirmationPredicateIsInjected(unittest.TestCase):
    """W2: the predicate that answers 'was this token programmed?' is actually supplied."""

    def test_main_wires_the_programmed_predicate(self):
        # assertTrue on a boolean, not assertIn on the file: assertIn renders the whole
        # haystack into the failure message, which for a 500-line source file buries the
        # explanation under the thing it is explaining.
        self.assertTrue(
            "setProgrammedPredicate(" in code_of(MAIN_CPP),
            msg=(
                "src/main.cpp no longer calls setProgrammedPredicate() in live code. The "
                "predicate then stays empty, and PendingEntryFilter's documented default "
                "withholds EVERY tokened row -- so the flow-table view silently under-reports "
                "for up to one poll interval. That default is the safe direction on purpose, "
                "which is precisely why a dropped wire here is invisible without this "
                "assertion."
            ),
        )


# --------------------------------------------------------------------------------------
# W3 -- the token reaching the cache
# --------------------------------------------------------------------------------------


class TokensReachTheCache(unittest.TestCase):
    """W3: rows written optimistically carry the token the filter keys on."""

    def test_http_session_stamps_a_token_on_the_cached_rows(self):
        self.assertTrue(
            "kPendingTokenField" in code_of(HTTP_SESSION),
            msg=(
                "HttpSession.cpp no longer stamps kPendingTokenField in live code. Untokened "
                "rows are treated by the filter as entries polled from a real switch -- which "
                "it must not hide -- so the optimistic row is served again and B-1's phantom "
                "is back."
            ),
        )

    def test_the_cache_is_handed_the_annotated_batch_not_the_raw_body(self):
        """The pre-fix line was `updateOpenFlowTables(j)` -- the raw request body."""
        calls = re.findall(
            r"updateOpenFlowTables\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", code_of(HTTP_SESSION)
        )
        self.assertTrue(
            calls, msg="no live call to updateOpenFlowTables() found in HttpSession.cpp"
        )
        for argument in calls:
            self.assertNotEqual(
                argument,
                "j",
                msg=(
                    "HttpSession passes the raw request body `j` to updateOpenFlowTables(). "
                    "That is the pre-T-11 line: the untokened rows it writes are "
                    "indistinguishable to the filter from rows polled off a real switch, so "
                    "they are served as table entries. Hand it the tokened copy instead."
                ),
            )


if __name__ == "__main__":
    unittest.main()
