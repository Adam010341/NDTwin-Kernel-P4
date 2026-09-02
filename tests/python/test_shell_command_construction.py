"""
Source guard for the shell-command-construction family: doc/KNOWN-ISSUES.md B-2b and B-4.

[Co-developed with claude code -- Adam]

## What these tests are, and what they are emphatically not

They read C++ source text. They do **not** run the kernel, do not build it, and prove nothing
about its behaviour. A green run here means "the construction that produced B-2b and B-4 is not
present in the tree", not "the injection is fixed" -- the behavioural evidence for that lives in
tests/test_RoutingStrategies.cpp, which needs a compiler.

That narrowness is the point rather than an apology. The defect is a *textual pattern* that was
reintroduced independently at three call sites, and whose population KNOWN-ISSUES twice failed to
recount: the entry claims 14 southbound call sites, a later audit could only find 11, and neither
number can be reproduced today. A test that counts is worth having precisely because two careful
humans could not.

## Why a ratchet and not an exact count

test_execCommand_call_sites_do_not_grow asserts an upper bound. Adding a call site fails; removing
one passes and the bound is then lowered by hand in the same commit that removes it. An exact-count
assertion would fail on progress, which teaches people to edit the number without reading it.
"""

from __future__ import annotations

import os
import re
import unittest


def _repo_root() -> str:
    """Walk up from this file to the directory holding src/ndt_core. Keeps the file movable."""
    here = os.path.dirname(os.path.abspath(__file__))
    while True:
        if os.path.isdir(os.path.join(here, "src", "ndt_core")):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            raise AssertionError("could not locate the repo root from " + __file__)
        here = parent


def _cpp_sources() -> list[str]:
    root = _repo_root()
    found = []
    for base in ("src", "include"):
        for dirpath, _dirnames, filenames in os.walk(os.path.join(root, base)):
            for name in filenames:
                if name.endswith((".cpp", ".hpp", ".h")):
                    found.append(os.path.join(dirpath, name))
    return sorted(found)


def _is_comment(line: str) -> bool:
    """True for a `//` line.

    [Co-developed with claude code -- Adam]
    Not cosmetic. Without it these tests fail on the comments that explain the very defect they
    guard against -- which happened on the first run of this file, since the fix's comment quotes
    the construction it removed. A guard that forbids *describing* the bug pushes the next author
    to delete the explanation, which is the opposite of what is wanted. Deliberately naive: this
    does not track /* */ blocks or string literals, so it can only ever under-suppress, never hide
    a real hit on a code line.
    """
    return line.lstrip().startswith(("//", "*", "/*"))


def _matching_lines(pattern: "re.Pattern[str]", only: str | None = None) -> list[str]:
    """Every non-comment `path:line: text` whose text matches, as a reviewer wants to read it."""
    root = _repo_root()
    paths = _cpp_sources() if only is None else [os.path.join(root, only)]
    hits = []
    for path in paths:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for number, text in enumerate(handle, start=1):
                if _is_comment(text):
                    continue
                if pattern.search(text):
                    rel = os.path.relpath(path, root)
                    hits.append("{}:{}: {}".format(rel, number, text.strip()))
    return hits


class ShellCommandConstructionTest(unittest.TestCase):
    def test_no_source_builds_a_curl_body_inside_single_quotes(self):
        """The exact construction of B-2b and B-4.

        All three sites spelled it the same way -- `<< "-d '" << body << "'"` -- because each was
        copied from the last. json::dump() escapes what JSON requires and `'` is not a JSON
        metacharacter, so the quote arrived at /bin/sh intact, ended the quoting, and made the rest
        of the body a command. The northbound API binds 0.0.0.0:8000 with no authentication, so
        this was reachable command execution rather than a formatting problem.

        The replacement is an argument vector: no command line is built, so there is no quoting to
        get wrong. If this assertion ever fails again, the fix is execArgv() in utils/Utils.hpp --
        NOT adding escaping, which both KNOWN-ISSUES entries warn against by name.
        """
        hits = _matching_lines(re.compile(r"-d\s+'"))
        self.assertEqual(
            [],
            hits,
            "a request body is being interpolated into a shell command line again "
            "(doc/KNOWN-ISSUES.md B-2b/B-4); use utils::execArgv, not escaping:\n"
            + "\n".join(hits),
        )

    def test_execCommand_call_sites_do_not_grow(self):
        """Every remaining utils::execCommand() call is a shell-injection surface.

        popen() runs `/bin/sh -c`, so every value interpolated into its argument is shell code.
        The 16 that remain all interpolate configuration rather than request fields, which is why
        they are a ratchet and not a failure -- but a *new* one is how this family grew to three
        sites in the first place, and a new one on a request path would be another B-2b.

        Lower the bound when you migrate one. Never raise it.
        """
        hits = _matching_lines(re.compile(r"utils::execCommand\("))
        self.assertLessEqual(
            len(hits),
            16,
            "a new utils::execCommand() call site appeared. It runs /bin/sh -c, so anything "
            "interpolated into its argument is executable. Use utils::execArgv:\n"
            + "\n".join(hits),
        )

    def test_the_argv_executor_exists_and_does_not_use_a_shell(self):
        """Guards the replacement itself.

        A test suite that only forbids the old pattern is satisfied by deleting the code. This
        pins that the thing callers were pointed at is present and is what it claims: execvp with
        an argument vector, and no popen/system anywhere in it.
        """
        root = _repo_root()
        with open(os.path.join(root, "include", "utils", "Utils.hpp"), encoding="utf-8") as handle:
            source = handle.read()

        self.assertIn("execArgv", source, "the shell-free executor is gone")

        start = source.index("execArgv(const std::vector<std::string>& argv)\n{")
        end = source.index("\n}", start)
        body = source[start:end]

        self.assertIn("::execvp(", body, "execArgv must exec the program directly")
        for shell_call in ("popen(", "system(", "sh -c"):
            self.assertNotIn(
                shell_call,
                body,
                "execArgv reintroduced a shell via " + shell_call,
            )


class HandBuiltJsonTest(unittest.TestCase):
    def test_the_simulation_case_reply_is_not_built_by_concatenation(self):
        """The second, unlisted half of B-4.

        HttpSession::handleReceivedSimulationCase built its reply as
        `std::string("{\\"status\\":\\"") + resp + "\\"}"`, where `resp` was another process's
        output. A quote or newline in that output made this kernel's own response malformed JSON --
        the same defect as the shell interpolation four lines above it, pointed the other way.

        Scoped to this one construction rather than all 23 hand-built JSON strings in the tree
        (IntentTranslator.cpp has 22 more): a test asserting a property the tree does not have
        cannot be committed green, and pretending the other 22 are covered would be worse than
        leaving them listed in the fix design.
        """
        hits = _matching_lines(
            re.compile(r'"\{\\"status\\":\\""'),
            only=os.path.join("src", "ndt_core", "http", "HttpSession.cpp"),
        )
        self.assertEqual(
            [],
            hits,
            "a JSON response is being built by string concatenation from another process's "
            "output; use nlohmann::json:\n" + "\n".join(hits),
        )


if __name__ == "__main__":
    unittest.main()
