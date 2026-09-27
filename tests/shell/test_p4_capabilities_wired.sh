#!/usr/bin/env bash
#
# The one wire of the capabilities feature no unit test can reach: pingWorker -> pollP4SwitchState
# -> fetchP4SwitchState, in DeviceConfigurationAndPowerManager.cpp.
#
# [Co-developed with claude code -- Adam]
#
# pollP4SwitchState() is where the 1 Hz GET /p4/switch_state answer is both recorded as each
# switch's `capabilities` (for /ndt/get_graph_data, doc/2026-01-02_ndt_api.md section 3) and handed
# on to the bmv2 liveness verdicts. tests/test_P4Capabilities.cpp drives it directly, but nothing
# offline can drive pingWorker -- it needs start(), which shells out -- so the call from the loop is
# checked here, statically.
#
# 🔴 THE REGRESSION THIS EXISTS FOR is not "the call was deleted" (that does not compile:
# pingWorker reads the payload further down) but "the old direct fetch came back": a conflict
# resolved against a branch that still has
#
#     std::optional<json> p4SwitchState;
#     if (m_mode == utils::DeploymentMode::MININET && dataPlaneIsBmv2())
#     {
#         p4SwitchState = fetchP4SwitchState();
#     }
#
# compiles, keeps liveness working, and silently stops every node from carrying `capabilities`.
# No offline test and no live liveness check would notice. Hence three checks:
#
#   1. fetchP4SwitchState is called from exactly one place in src/ and include/, and that place
#      is inside pollP4SwitchState's body;
#   2. pingWorker calls pollP4SwitchState();
#   3. what pingWorker hands the liveness verdicts (p4VerdictFor) is the value that call returned.
#
# Comments and string literals are stripped before anything is counted, so a comment naming a
# function is neither a call nor a missing call. Function bodies are found by brace matching on
# the stripped text.
#
# Usage:  bash tests/shell/test_p4_capabilities_wired.sh
#         P4CAPS_WIRING_ROOT=<a copy of the tree> bash tests/shell/test_p4_capabilities_wired.sh
#         (the root is overridable so tests/shell/mutate_p4_capabilities_wired.sh can point this
#         at a mutated copy without writing the real tree)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${P4CAPS_WIRING_ROOT:-$(cd "$HERE/../.." && pwd)}"

python3 - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
DCPM = os.path.join(root, "src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp")
CLS = "DeviceConfigurationAndPowerManager"

passed = failed = 0


def ok(name):
    global passed
    passed += 1
    print(f"  ok       {name}")


def bad(name, why):
    global failed
    failed += 1
    print(f"  FAILED   {name}\n    {why}")


def strip(text):
    """Blank out comments and string/char literals, keeping every other character in place."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j])); i = j
        elif text.startswith('R"', i) and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            m = re.match(r'R"([^()\\ ]{0,16})\(', text[i:])
            if not m:
                out.append(c); i += 1; continue
            close = ")" + m.group(1) + '"'
            j = text.find(close, i + m.end())
            j = n if j < 0 else j + len(close)
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j])); i = j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i)); i = j
        else:
            out.append(c); i += 1
    return "".join(out)


def body(stripped, name):
    """(start, end) of CLS::name's definition body in the stripped text, or None."""
    for m in re.finditer(rf"\b{CLS}::{name}\s*\(", stripped):
        k = m.end()
        depth = 1
        while k < len(stripped) and depth:
            depth += {"(": 1, ")": -1}.get(stripped[k], 0)
            k += 1
        rest = stripped[k:]
        brace = rest.find("{")
        semi = rest.find(";")
        if brace < 0 or (0 <= semi < brace):
            continue                      # a declaration or a call, not the definition
        start = k + brace
        depth, e = 0, start
        while e < len(stripped):
            depth += {"{": 1, "}": -1}.get(stripped[e], 0)
            e += 1
            if depth == 0:
                return start, e
    return None


if not os.path.isfile(DCPM):
    print(f"  FAILED   the source file exists\n    {DCPM} not found")
    print("0 passed, 1 failed")
    sys.exit(1)

sources = {}
for sub in ("src", "include"):
    for d, _dirs, files in os.walk(os.path.join(root, sub)):
        for f in files:
            if f.endswith((".cpp", ".hpp", ".h", ".cc")):
                p = os.path.join(d, f)
                with open(p, encoding="utf-8", errors="replace") as fh:
                    sources[p] = strip(fh.read())

dcpm = sources[DCPM]
poll = body(dcpm, "pollP4SwitchState")
ping = body(dcpm, "pingWorker")

# --- 1 ---------------------------------------------------------------------------------------
name = "fetchP4SwitchState is called from exactly one place, inside pollP4SwitchState"
calls = []
for p, s in sources.items():
    for m in re.finditer(r"\bfetchP4SwitchState\s*\(", s):
        before = s[max(0, m.start() - 80):m.start()]
        if re.search(rf"{CLS}::\s*$", before):
            continue                                  # the out-of-line definition
        if re.search(r"std::optional\s*<\s*json\s*>\s*$", before):
            continue                                  # the declaration in the header
        line = s.count("\n", 0, m.start()) + 1
        calls.append((p, m.start(), line))
where = ", ".join(f"{os.path.relpath(p, root)}:{ln}" for p, _o, ln in calls) or "nowhere"
if poll is None:
    bad(name, "pollP4SwitchState's definition was not found in " + os.path.relpath(DCPM, root))
elif len(calls) != 1:
    bad(name, f"{len(calls)} call site(s): {where}")
elif not (calls[0][0] == DCPM and poll[0] <= calls[0][1] < poll[1]):
    bad(name, f"the one call is at {where}, outside pollP4SwitchState")
else:
    ok(name)

# --- 2 ---------------------------------------------------------------------------------------
name = "pingWorker takes its bmv2 evidence from pollP4SwitchState()"
ping_text = dcpm[ping[0]:ping[1]] if ping else ""
assign = re.search(r"\b(\w+)\s*=\s*pollP4SwitchState\s*\(\s*\)", ping_text)
if ping is None:
    bad(name, "pingWorker's definition was not found")
elif not re.search(r"\bpollP4SwitchState\s*\(\s*\)", ping_text):
    bad(name, "pingWorker does not call pollP4SwitchState() (comments do not count)")
else:
    ok(name)

# --- 3 ---------------------------------------------------------------------------------------
name = "the liveness verdicts read the answer pollP4SwitchState() returned"


def last_argument(text, open_paren):
    """The last top-level argument of the call whose '(' is at open_paren."""
    depth, k, start = 0, open_paren, open_paren + 1
    while k < len(text):
        ch = text[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return text[start:k].strip()
        elif ch == "," and depth == 1:
            start = k + 1
        k += 1
    return ""


verdicts = [last_argument(ping_text, m.end() - 1)
            for m in re.finditer(r"\bp4VerdictFor\s*\(", ping_text)]
if not assign:
    bad(name, "no variable in pingWorker is assigned from pollP4SwitchState()")
elif not verdicts:
    bad(name, "pingWorker no longer calls p4VerdictFor")
elif any(v != assign.group(1) for v in verdicts):
    bad(name, f"p4VerdictFor is given {verdicts}, not `{assign.group(1)}`")
else:
    ok(name)

print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
