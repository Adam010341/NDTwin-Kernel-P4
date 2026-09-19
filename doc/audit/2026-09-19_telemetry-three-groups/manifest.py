#!/usr/bin/env python3
"""Reading /tmp/ndtwin_p4_switches.json -- the switch manifest `ndt up p4` writes.

[Co-developed with claude code -- Adam]

🔴 THIS FILE EXISTS BECAUSE THE SHAPE WAS ASSUMED AND THE ASSUMPTION WAS WRONG. The manifest's
`argv` is ONE STRING, not a list of tokens:

    "argv": "LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib /usr/local/bmv2-fast/bin/simple_switch_grpc
             -i 3@s1-eth3 ... --thrift-port 9091 --device-id 1 ..."

run_group_arm.sh iterated it looking for a token whose basename starts with `simple_switch`, and
iterating a string yields CHARACTERS -- so no token ever matched, and every arm of the campaign
was marked `invalid=no simple_switch binary in ... -- this arm cannot name what it measured`.
The first real round died on it after measuring a ceiling of 30 kpps that then could not be
used. (Ruling 27; the real manifest is kept verbatim at
scratch/overnight-2026-09-05/logs/orchestrator-0919/evidence-ndtwin_p4_switches-argv-is-a-string.json
and copied into tests/fixtures/ndtwin_p4_switches.real.json.)

It is a module rather than another heredoc inside the arm script so that it can be TESTED. The
offline stub had a list-shaped `argv`, which is exactly why the suite was green while the real
thing could never work: a fixture that agrees with the code's assumption proves nothing about
the world. Pure stdlib, so it runs under p4_proxy/venv/bin/python.
"""
import json
import os
import shlex
import sys


def argv_tokens(argv):
    """The argv of one switch as a LIST OF TOKENS, whichever way the manifest spelled it.

    A string is split the way a shell would (shlex), because that is what it is: a command line,
    complete with the `LD_LIBRARY_PATH=...` prefix assignment. A list is already tokens and is
    returned as it stands -- the point is to accept the shape that exists, not to guess one.
    """
    if argv is None:
        return []
    if isinstance(argv, str):
        try:
            return shlex.split(argv)
        except ValueError:
            return argv.split()
    return [str(token) for token in argv]


def looks_like_the_binary(token, previous):
    """Is `token` the switch binary, given the token before it?

    Basename, not substring -- but basename alone is not enough, and this test caught that:
    `--log-file /tmp/simple_switch.log` has a basename starting with `simple_switch` too. The
    real manifest writes `--log-file /tmp/s1_bmv2.log`, so it would not have bitten today; it
    would have bitten the first time somebody named a log after the binary. Two more rules:

      * a token that FOLLOWS an option (`--log-file`, `-i`, ...) is that option's VALUE, never
        the command being run;
      * the binary has no dot in its basename (`simple_switch`, `simple_switch_grpc`), while
        the things named after it are files and do (`.log`).
    """
    base = os.path.basename(token)
    if not base.startswith("simple_switch"):
        return False
    if previous is not None and previous.startswith("-"):
        return False
    return "." not in base


def switch_binary(manifest):
    """The simple_switch* binary the fabric is actually running, or None."""
    for _name, entry in sorted((manifest or {}).items()):
        tokens = argv_tokens((entry or {}).get("argv"))
        for index, token in enumerate(tokens):
            if looks_like_the_binary(token, tokens[index - 1] if index else None):
                return token
    return None


def switch_rows(manifest):
    """[(pid, label)] for every switch that has a pid -- label is device_id, else the name."""
    rows = []
    for name, entry in sorted((manifest or {}).items()):
        pid = (entry or {}).get("pid")
        if not pid:
            continue
        device = (entry or {}).get("device_id")
        rows.append((int(pid), name if device is None else str(device)))
    return rows


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


if __name__ == "__main__":
    # `manifest.py binary <path>` / `manifest.py rows <path>` -- what run_group_arm.sh calls.
    if len(sys.argv) != 3:
        print("usage: manifest.py {binary|rows} <manifest path>", file=sys.stderr)
        sys.exit(2)
    what, path = sys.argv[1], sys.argv[2]
    data = load(path)
    if what == "binary":
        found = switch_binary(data)
        if found:
            print(found)
    elif what == "rows":
        for pid, label in switch_rows(data):
            print("%s %s" % (pid, label))
    else:
        print("usage: manifest.py {binary|rows} <manifest path>", file=sys.stderr)
        sys.exit(2)
