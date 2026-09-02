"""Source guard for the shell-command-construction family: doc/KNOWN-ISSUES.md B-2b and B-4.

[Co-developed with claude code -- Adam]

## What these tests are, and what they are emphatically not

They read C++ source text. They do **not** run the kernel, do not build it, and prove nothing
about its behaviour. A green run here means "no shell-execution site in the kernel is reached by a
request-controlled string, as classified below", not "the injection is fixed" -- the behavioural
evidence for that lives in tests/test_ExecArgv.cpp and tests/test_RoutingStrategies.cpp, which need
a compiler.

That narrowness is the point rather than an apology. The defect is a *textual pattern* that was
reintroduced independently at three call sites, and whose population KNOWN-ISSUES twice failed to
recount: the entry claims 14 southbound call sites, a later audit could only find 11, and neither
number can be reproduced today. A test that counts is worth having precisely because two careful
humans could not.

## An unclassified site is a failing site

SHELL_SITES below is the whole population, with a verdict for each. `_verdict_for` returns REQUEST
for anything it does not recognise, so a newly added shell-out fails
`test_no_shell_site_is_reached_by_a_request_controlled_string` until someone writes down what
reaches it. Presuming danger is the only safe default for a table a human maintains by hand.

## Why the key is the source line and not the line number

Line numbers move whenever anything above them changes, which would make this file churn for
unrelated edits and train people to update it without reading. The stripped source line moves only
when someone edits that statement -- which is exactly when the classification needs rechecking.
Counts are carried because seven sites in one file share the line
`std::string snmp_result = utils::execCommand(cmd);`, and losing track of how many there are is
how the 14/11 disagreement started.

## The enumeration missed a category once; that is why popen( is in the pattern

The first pass of this sweep grepped for `utils::execCommand`, `std::system` and
`executeSystemCommand`, and reported the population as complete. It was not: `OVSPowerStrategy`
and `SSHHelper` call **`popen` directly**, bypassing every named helper, and neither appeared. See
MEMORY [[grep-gives-incomplete-answers]] -- an enumeration is only as complete as the widest
spelling you thought of, and "I grepped for it" is not evidence that a category does not exist.
"""

from __future__ import annotations

import collections
import os
import re
import unittest

# --- the population -----------------------------------------------------------------------------

#: Anything that hands a string to /bin/sh. `popen(`/`std::system(`/`executeSystemCommand(` are
#: required to be followed by an identifier or a quote so that prose ("popen() failed") and
#: declarations do not match.
SHELL_CALL = re.compile(
    r'(?:\bpopen\s*\(\s*[A-Za-z_"]'
    r'|\bstd::system\s*\(\s*[A-Za-z_"]'
    r'|\butils::execCommand\s*\('
    r'|\bexecuteSystemCommand\s*\(\s*[A-Za-z_"])'
)

#: The two power strategies' virtual seam. Its *declaration* is not a call site; its body is
#: listed below in its own right.
SEAM_DECLARATION = re.compile(r"\bexecuteSystemCommand\s*\(\s*const\s+std::string")

# Verdicts.
#   CONSTANT  - the command is a compile-time literal; nothing is interpolated.
#   CONFIG    - interpolates AppConfig values or the static topology file read from disk.
#   NUMERIC   - interpolates text re-rendered from an integer (utils::ipToString on a uint32,
#               std::to_string on a dpid), which cannot contain a shell metacharacter whatever
#               the integer's origin.
#   SEAM      - receives an already-built string; classified through its callers, listed here so
#               the count of real /bin/sh entry points stays honest.
#   REQUEST   - a string that can carry arbitrary bytes from an HTTP request. Must be empty.
CONSTANT, CONFIG, NUMERIC, SEAM, REQUEST = "CONSTANT", "CONFIG", "NUMERIC", "SEAM", "REQUEST"

#: (path, stripped source line) -> (occurrences, verdict, what reaches the shell)
SHELL_SITES = {
    ("include/utils/SSHHelper.hpp", 'FILE* pipe = popen(command.c_str(), "r");'): (
        1, NUMERIC,
        "getPowerReportViaSsh(ip, username): ip is utils::ipToString(uint32) at both callers "
        "(DeviceConfigurationAndPowerManager.cpp:1309/1728), username is the literal \"admin\". "
        "Cannot migrate as-is: the command is a shell pipeline, "
        "`(echo ...; sleep 1; echo ...) | ssh ...`, so removing the shell means feeding ssh's "
        "stdin instead -- a redesign, not a substitution.",
    ),
    ("include/utils/Utils.hpp", 'FILE* pipe = popen(cmd.c_str(), "r");'): (
        1, SEAM,
        "utils::execCommand itself. This is the /bin/sh the whole family goes through.",
    ),
    ("src/ndt_core/application_management/ApplicationManager.cpp",
     'if (const auto why = describeCommandFailure(std::system("sudo exportfs -ra")); !why.empty())'): (
        2, CONSTANT, "String literal, no interpolation.",
    ),
    ("src/ndt_core/application_management/ApplicationManager.cpp",
     'int ret = std::system("exportfs -ra && systemctl reload nfs-server");'): (
        1, CONSTANT,
        "String literal. The `&&` is shell syntax the caller genuinely wants, and it is safe "
        "because both sides are literals.",
    ),
    ("src/ndt_core/collection/FlowLinkUsageCollector.cpp",
     'FILE* pipe = popen("sudo ovs-vsctl list interface", "r");'): (
        1, CONSTANT, "String literal, no interpolation.",
    ),
    ("src/ndt_core/collection/FlowLinkUsageCollector.cpp",
     "const std::string output = utils::execCommand(cmd);"): (
        1, CONFIG,
        "controlPlaneHostAndPort() returns AppConfig::P4_PROXY_IP_AND_PORT or "
        "AppConfig::RYU_IP_AND_PORT (FlowLinkUsageCollector.cpp:216/218).",
    ),
    ("src/ndt_core/collection/TopologyAndFlowMonitor.cpp",
     "return utils::execCommand(buildTopologyFetchCommand(url));"): (
        1, CONFIG,
        "url is 'http://' + AppConfig::{RYU,P4_PROXY}_IP_AND_PORT + a literal path; the timeouts "
        "are std::to_string of constexpr ints.",
    ),
    ("src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp",
     'FILE* fp = popen("sudo ovs-vsctl list-br 2>/dev/null", "r");'): (
        1, CONSTANT, "String literal, no interpolation.",
    ),
    ("src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp",
     "response = utils::execCommand(cmd);"): (
        1, CONFIG, "buildSwitchStateCommand(AppConfig::P4_PROXY_IP_AND_PORT).",
    ),
    ("src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp",
     "std::string output = utils::execCommand(cmd);"): (
        1, NUMERIC,
        "pingSwitch(ip, timeout): the sole caller passes utils::ipToString(uint32) "
        "(DeviceConfigurationAndPowerManager.cpp:691); the timeout is std::to_string(int).",
    ),
    ("src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp",
     "std::string raw = utils::execCommand(cmd);"): (
        1, CONFIG,
        "buildFlowStatsCommand(ip_and_port, dpid): ip_and_port is an AppConfig constant, dpid is "
        "a uint64_t.",
    ),
    ("src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp",
     "std::string raw = utils::execCommand(cmd.str());"): (
        1, CONFIG,
        "The relay status GET. GW_IP is AppConfig; si.plugIp comes from the static topology JSON "
        "file; si.plugIdx is an int. The request's own ip= parameter is a lookup key only "
        "(DeviceConfigurationAndPowerManager.cpp:210) and never enters the command.",
    ),
    ("src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp",
     "std::string snmp_result = utils::execCommand(cmd);"): (
        7, NUMERIC,
        "snmpget/snmpwalk with a hardcoded community string and OID; the only variable is "
        "ip_str = utils::ipToString(vp.ip.front()).",
    ),
    ("src/ndt_core/power_management/OVSPowerStrategy.cpp",
     'FILE* fp = popen(cmd.c_str(), "r");'): (
        1, CONFIG,
        "executeListPorts: 'sudo ovs-vsctl list-ports ' + bridge name, which is "
        "bridgeNameForMininet from the static topology file. Note this bypasses the class's own "
        "executeSystemCommand seam, which is a testing hole the file already complains about "
        "elsewhere -- separate from this family.",
    ),
    ("src/ndt_core/power_management/OVSPowerStrategy.cpp",
     "const int rc = std::system(cmd.c_str());"): (
        1, SEAM, "OVSPowerStrategy::executeSystemCommand. Classified through its two callers.",
    ),
    ("src/ndt_core/power_management/OVSPowerStrategy.cpp", "if (!executeSystemCommand(cmd))"): (
        2, CONFIG,
        "swName is bridgeNameForMininet (static topology file), dpid is rendered as 16 hex "
        "digits, and port comes from this machine's own `ovs-vsctl list-ports` output. No HTTP "
        "endpoint writes bridgeNameForMininet: modify_device_name sets deviceName, a different "
        "field, and it is not in VertexProperties' from_json.",
    ),
    ("src/ndt_core/power_management/P4PowerStrategy.cpp",
     "const int rc = std::system(cmd.c_str());"): (
        1, SEAM, "P4PowerStrategy::executeSystemCommand. Classified through its three callers.",
    ),
    ("src/ndt_core/power_management/P4PowerStrategy.cpp",
     'if (!executeSystemCommand("curl -sS --fail-with-body -X POST --max-time 30 http://" +'): (
        1, CONFIG, "AppConfig::P4_PROXY_IP_AND_PORT plus std::to_string(dpid).",
    ),
    ("src/ndt_core/power_management/P4PowerStrategy.cpp",
     'if (!executeSystemCommand(std::string("sudo -n ") + kPowerHelper + " off " + swName))'): (
        1, CONFIG, "kPowerHelper is constexpr; swName is bridgeNameForMininet. Runs under sudo.",
    ),
    ("src/ndt_core/power_management/P4PowerStrategy.cpp",
     'if (!executeSystemCommand(std::string("sudo -n ") + kPowerHelper + " on " + swName))'): (
        1, CONFIG, "kPowerHelper is constexpr; swName is bridgeNameForMininet. Runs under sudo.",
    ),
}


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
    """True for a `//` line, a doc-comment continuation, or a preprocessor line.

    [Co-developed with claude code -- Adam]
    Not cosmetic. Without it these tests fail on the comments that explain the very defect they
    guard against -- which happened on the first run of this file, since the fix's comment quotes
    the construction it removed. A guard that forbids *describing* the bug pushes the next author
    to delete the explanation, which is the opposite of what is wanted. Deliberately naive: this
    does not track /* */ blocks or string literals, so it can only ever under-suppress, never hide
    a real hit on a code line.
    """
    return line.lstrip().startswith(("//", "*", "/*", "#"))


def _matching_lines(pattern: re.Pattern[str], only: str | None = None) -> list[str]:
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
                    hits.append("{}:{}: {}".format(os.path.relpath(path, root), number, text.strip()))
    return hits


def _discovered_shell_sites() -> dict[tuple[str, str], int]:
    """(relative path, stripped line) -> how many times it appears."""
    root = _repo_root()
    found: collections.Counter[tuple[str, str]] = collections.Counter()
    for path in _cpp_sources():
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for text in handle:
                if _is_comment(text) or SEAM_DECLARATION.search(text):
                    continue
                if SHELL_CALL.search(text):
                    found[(os.path.relpath(path, root), text.strip())] += 1
    return dict(found)


def _verdict_for(site: tuple[str, str]) -> str:
    """REQUEST for anything unclassified: an unrecognised shell-out is guilty until described."""
    entry = SHELL_SITES.get(site)
    return entry[1] if entry else REQUEST


class ShellSitePopulationTest(unittest.TestCase):
    def test_no_shell_site_is_reached_by_a_request_controlled_string(self):
        """The invariant the B-2b/B-4 sweep exists to establish.

        WHICH LINE MAKES THIS RED: any shell-out carrying a request string. Before the sweep, the
        two that did were
        `interpretRelayResponse(utils::execCommand(buildRelayPowerCommand(GW_IP, si, action)));`
        in DeviceConfigurationAndPowerManager::setPowerStateTestbed -- `action` is the `action`
        query parameter of POST /ndt/set_switches_power_state -- and the two snmpget commands in
        getSingleSwitchCpuReport built from its `deviceIdentifier` parameter. Restore either and
        this fails, because neither line is in SHELL_SITES and unknown means REQUEST.
        """
        offenders = sorted(
            "{}: {}".format(path, line)
            for (path, line) in _discovered_shell_sites()
            if _verdict_for((path, line)) == REQUEST
        )
        self.assertEqual(
            [],
            offenders,
            "a shell-execution site is either reached by a request-controlled string or has not "
            "been classified. Every entry below must be migrated to utils::execArgv, or added to "
            "SHELL_SITES with the provenance of what reaches it:\n" + "\n".join(offenders),
        )

    def test_the_site_inventory_matches_the_classification(self):
        """Counts too, not just presence.

        Seven sites in one file share a single source line, so presence alone would let an eighth
        appear unnoticed -- and an uncountable population is exactly what KNOWN-ISSUES records as
        having defeated two previous audits.
        """
        discovered = _discovered_shell_sites()

        wrong_count = [
            "{}: {}  (classified {}, found {})".format(path, line, SHELL_SITES[key][0], count)
            for key in SHELL_SITES
            if (count := discovered.get(key, 0)) != SHELL_SITES[key][0]
            for (path, line) in [key]
        ]
        self.assertEqual(
            [],
            wrong_count,
            "the number of shell-execution sites changed. Re-read them and update SHELL_SITES "
            "with the provenance of each:\n" + "\n".join(wrong_count),
        )


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

    def test_the_argv_executor_exists_and_does_not_use_a_shell(self):
        """Guards the replacement itself.

        A test suite that only forbids the old pattern is satisfied by deleting the code. This
        pins that the thing callers were pointed at is present and is what it claims: execvp with
        an argument vector, and no popen/system anywhere in it.
        """
        root = _repo_root()
        with open(os.path.join(root, "include", "utils", "Utils.hpp"), encoding="utf-8") as handle:
            source = handle.read()

        # Not assertIn: on failure unittest would print the whole 900-line header as the message.
        self.assertTrue("execArgv" in source, "the shell-free executor is gone from Utils.hpp")

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

    def test_the_sudo_nfs_commands_are_argument_vectors(self):
        """ApplicationManager escaped for the wrong layer, which is worse than not escaping.

        buildExportsPurgeCommand BRE-escaped `.*[]^$\\/` -- correct for sed's address syntax -- and
        then wrapped the result in `'...'` inside a string passed to std::system. `'` is not a BRE
        metacharacter, so it was not escaped, and it did not need to be for sed; it needed to be
        for the shell, which nothing had considered. Both commands run under sudo.

        WHICH LINE MAKES THIS RED: restore
        `return "sudo sed -i '/^" + escaped + " /d' " + exportsFile;` (and the std::string return
        type) in ApplicationManager::buildExportsPurgeCommand.
        """
        hits = _matching_lines(
            re.compile(r'"sudo (?:sed|exportfs)'),
            only=os.path.join("src", "ndt_core", "application_management", "ApplicationManager.cpp"),
        )
        interpolating = [hit for hit in hits if "+" in hit]
        self.assertEqual(
            [],
            interpolating,
            "a sudo command is being built by string concatenation again; return a "
            "std::vector<std::string> for utils::execArgv instead:\n" + "\n".join(interpolating),
        )


class HandBuiltJsonTest(unittest.TestCase):
    def test_the_simulation_case_reply_is_not_built_by_concatenation(self):
        """The second, unlisted half of B-4.

        HttpSession::handleReceivedSimulationCase built its reply as
        `std::string("{\\"status\\":\\"") + resp + "\\"}"`, where `resp` was another process's
        output. A quote or newline in that output made this kernel's own response malformed JSON --
        the same defect as the shell interpolation four lines above it, pointed the other way.
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

    def test_intent_replies_are_not_built_by_concatenation(self):
        """The same mistake pointed at JSON instead of at a shell.

        Twenty-two replies in IntentTranslator::performTask pasted a device name, host id or form
        type into a JSON literal. Device names arrive from an LLM, which is fed the text of
        POST /ndt/intent_translator/text, so a name containing a quote could add keys to this
        kernel's own reply. The file's own comment named the affected cases and left them.

        The eight remaining `return "{\\"error\\": ...}"` literals in that function interpolate
        nothing and are deliberately untouched, which is why this looks for concatenation rather
        than for hand-written JSON.

        WHICH LINE MAKES THIS RED: restore any of them, e.g. the DISABLE_SWITCH
        `return "{\\"error\\": \\"Switch not found\\", \\"device\\": \\"" + disableTask->deviceName
        + "\\"}";`
        """
        hits = _matching_lines(
            re.compile(r'"\{\\".*\+'),
            only=os.path.join("src", "ndt_core", "intent_translator", "IntentTranslator.cpp"),
        )
        self.assertEqual(
            [],
            hits,
            "an intent reply is being built by string concatenation; use nlohmann::json:\n"
            + "\n".join(hits),
        )


if __name__ == "__main__":
    unittest.main()
