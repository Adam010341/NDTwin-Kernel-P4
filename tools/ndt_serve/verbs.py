"""The whitelist: which `ndt` command lines this service may run, and what their exit codes mean.

[Co-developed with claude code -- Adam]

Everything here is a pure function from a request to an argv list, or from an rc to a sentence.
Nothing here runs anything. The server calls these, and only an argv list that came out of one of
them ever reaches `ndt` -- there is no other path from an HTTP request to a command line, and
there is no shell anywhere on that path (TICKET section 3.3).

🔴 This module does NOT reimplement `ndt`. It decides which of `ndt`'s own verbs a request may
name and checks that each argument is one of a fixed set of values; what the verb then does,
whether the lab is claimed, whether a teardown is in flight -- every guard -- is `ndt`'s, and the
rc it answers with is passed through unchanged (section 3.4).

The rc tables below are ANNOTATION ONLY: the `rc` field of every answer is the integer `ndt`
exited with, whatever this table says about it. An rc the table does not know is reported as
`unknown`, never folded into a neighbour.

Where each table comes from is RC_SOURCE, below, and it is not one place (judge 09-24, finding 5):
`up`, `down` and `status --check` are in `ndt help`; plain `status`, `claim`, `release` and the
three `apps` verbs are NOT -- they were read from ndt's code, and RC_SOURCE names the lines.
tests/python/test_ndt_serve.py RcProvenance holds both kinds to the real ndt of this tree: a
help phrase that is no longer printed, or a cited line that no longer says what it is cited
for, turns it red.
"""
import os
import re

# The OVS plane builds only two sizes and each is a different ndt verb (`ndt help`: "OVS builds
# only 128 or 4 -- each is a different ndtwin-lab verb, not a parameter").
#
# P4 accepts any multiple of 4 (host_count_buildable), but the service offers only the two sizes
# that have been measured on this laptop. A wider enum is a decision for Adam (REPORT section 6),
# not something the first cut should widen on its own.
UP_HOSTS = {
    "ovs": (None, 4, 128),
    "p4": (None, 4, 128),
}

MAX_CLAIM_MINUTES = 240
MAX_NOTE_CHARS = 200

# A claim note is written by `ndt` into .test_run/lab.claim as a `note=<text>` line. A newline in
# it would be a second line of that file -- `owner=` included -- so control characters are
# refused here, before anything runs, and not left for the file format to absorb.
_NOTE_OK = re.compile(r"^[^\x00-\x1f\x7f]*$")
APP_NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")


class Refused(Exception):
    """The request names something outside the whitelist. HTTP 400; nothing runs."""


def _no_extra_keys(body, allowed):
    extra = sorted(set(body) - set(allowed))
    if extra:
        raise Refused("unknown field(s): %s (allowed: %s)" % (", ".join(extra), ", ".join(sorted(allowed)) or "none"))


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def argv_up(body, app_roots):
    """POST /api/v1/up  {"plane": "ovs"|"p4", "hosts": 4|128, "app": "<dir>"}"""
    _no_extra_keys(body, ("plane", "hosts", "app"))
    plane = body.get("plane")
    if not isinstance(plane, str) or plane not in UP_HOSTS:
        raise Refused("plane must be one of: %s" % ", ".join(sorted(UP_HOSTS)))
    hosts = body.get("hosts")
    app = body.get("app")
    if hosts is not None and not _is_int(hosts):
        raise Refused("hosts must be an integer")
    if hosts not in UP_HOSTS[plane]:   # an int or None by here, so the lookup cannot raise
        raise Refused("hosts on %s must be one of: %s" % (
            plane, ", ".join(str(h) for h in UP_HOSTS[plane] if h is not None)))
    if app is not None:
        if plane != "p4":
            raise Refused("app is a P4 field: ndt refuses --app on the OVS plane (ndt help, 'up')")
        if hosts is not None:
            raise Refused("app and hosts are exclusive: an app package sizes the fabric (ndt help, 'up')")
        return ["up", "p4", "--app", app_dir(app, app_roots)]
    if plane == "ovs":
        return ["up", "4"] if hosts == 4 else ["up", "ovs"]
    return ["up", "p4"] if hosts is None else ["up", "p4", str(hosts)]


def app_dir(raw, app_roots):
    """The realpath of an app package, if it lies under one of the allowed roots.

    realpath, not abspath: a symlink inside a root that points outside it is outside it. The
    resolved path -- not the string the client sent -- is what goes into the argv.
    """
    if not isinstance(raw, str) or not raw or "\x00" in raw:
        raise Refused("app must be a non-empty path")
    if not os.path.isabs(raw):
        raise Refused("app must be an absolute path")
    real = os.path.realpath(raw)
    for root in app_roots:
        root_real = os.path.realpath(root)
        if os.path.commonpath([root_real, real]) == root_real and real != root_real:
            if not os.path.isdir(real):
                raise Refused("app is not a directory: %s" % real)
            return real
    raise Refused("app must resolve to a directory under %s (it resolves to %s)" % (
        " or ".join(os.path.realpath(r) for r in app_roots) or "<no --app-root configured>", real))


def no_fields(body):
    """A POST whose body must be {} -- it names everything it does in its path."""
    _no_extra_keys(body, ())
    return []


def cell_run_body(body):
    """POST /cells/<name>/run or /guided  {} or {"confirm_shared_state_write": true}"""
    _no_extra_keys(body, ("confirm_shared_state_write",))
    c = body.get("confirm_shared_state_write", False)
    if not isinstance(c, bool):
        raise Refused("confirm_shared_state_write must be true or false")
    return c


def argv_down(body):
    """POST /api/v1/down  {} -- never --deep, never --force (TICKET section 5)."""
    _no_extra_keys(body, ())
    return ["down"]


def argv_claim(body):
    """POST /api/v1/claim  {"minutes": 1..240, "note": "<text>"}"""
    _no_extra_keys(body, ("minutes", "note"))
    minutes = body.get("minutes", 30)
    if not _is_int(minutes) or not 1 <= minutes <= MAX_CLAIM_MINUTES:
        raise Refused("minutes must be an integer from 1 to %d" % MAX_CLAIM_MINUTES)
    note = body.get("note", "")
    if not isinstance(note, str):
        raise Refused("note must be a string")
    if len(note) > MAX_NOTE_CHARS:
        raise Refused("note is longer than %d characters" % MAX_NOTE_CHARS)
    if not _NOTE_OK.match(note):
        raise Refused("note must not contain control characters (it becomes one line of .test_run/lab.claim)")
    return ["claim", str(minutes)] + ([note] if note else [])


def argv_release(body):
    """POST /api/v1/release  {} -- never --force."""
    _no_extra_keys(body, ())
    return ["release"]


def argv_app(name, action, body, known_apps):
    """POST /api/v1/apps/<name>/start|stop  {}"""
    _no_extra_keys(body, ())
    if not isinstance(name, str) or not APP_NAME_RE.match(name) or name not in known_apps:
        raise Refused("unknown app %r (ndt knows: %s)" % (name, " ".join(known_apps)))
    if action == "start":
        return ["apps", name]
    if action == "stop":
        return ["apps", "stop", name]
    raise Refused("unknown app action %r" % action)


def argv_status(check):
    return ["status", "--check"] if check else ["status"]


ARGV_APPS_STATUS = ["apps", "status"]

# --- what the exit codes mean -----------------------------------------------------------------
#
# One table per verb, because the same integer means different things to different verbs:
# `apps stop` answers 2 for "nothing was running", which is `up`'s usage error. A single table
# would have to lie to one of them.
#
# rc_class is a short machine word for a GUI to colour by. 🔴 `refused` (a guard said no and
# nothing was built) and `dirty` (it looked and did not like what it found) are different words
# on purpose -- ndt help: "1 AND 5 ARE DIFFERENT QUESTIONS". There is no `ok: false` field that
# would put them back together.
RC_TABLE = {
    "up": {
        0: ("ok", "the fabric came up and verified"),
        1: ("dirty", "something was MEASURED and it was dirty (a held port, a Mininet already "
                     "running, a stale fabric, a bring-up that could not finish or verify)"),
        2: ("usage", "usage error"),
        5: ("refused", "a GUARD REFUSED and nothing was built (claimed by somebody else, a "
                       "measurement in flight, a teardown still running, or a model of another network)"),
    },
    "down": {
        0: ("ok", "the teardown finished and the machine verified clean"),
        1: ("dirty", "a step failed, the sweep did not finish, or something is still running"),
        2: ("usage", "usage error"),
        3: ("nothing", "there was nothing to tear down -- this is NOT 'this round ended clean'"),
        5: ("refused", "a GUARD REFUSED and nothing was torn down"),
    },
    # 🔴 Two tables, because plain `ndt status` judges nothing: it prints the report and returns
    # 0 whatever the report says (cmd_status's last line). Only --check answers 0/1/3. The live
    # run of 09-24 22:01 had one table for both, and printed "all compared fields match" beside a
    # plain status of a lab with no baseline, where nothing had been compared at all.
    "status": {
        0: ("report", "the report was printed; plain 'ndt status' judges nothing and answers 0 "
                      "whatever it found -- read the report, or ask for a verdict with ?check=1"),
    },
    "status.check": {
        0: ("ok", "all compared fields match what the last 'ndt up' asked for"),
        # 🔴 ndt help says "1 one of them does not", but cmd_status answers 1 whenever its
        # problems[] is not empty (ndt:7070-7072) -- a claim held by somebody else (6698), a
        # measurement process in flight (6784, in_flight's process scan -- a measuring= the claim
        # only DECLARES, 6760-6762, is not a problem), a netem qdisc (6930), a refused sudo grant
        # (6943) are all problems. A GUI that printed "a field does not match" would name the wrong
        # cause.
        1: ("dirty", "ndt reported at least one problem -- a compared field that does not match, a claim "
                     "held by somebody else, a measurement in progress, a netem qdisc, a refused sudo "
                     "grant, and more; the output names each one"),
        3: ("nothing", "nothing was compared: there is no baseline right now -- NOT 'checked and matched'"),
    },
    "claim": {
        0: ("ok", "the claim is yours"),
        1: ("refused", "the lab is claimed by somebody else, or another writer beat this claim"),
        2: ("usage", "usage error (or NDT_OWNER missing)"),
    },
    "release": {
        0: ("ok", "released, or there was no claim to release"),
        1: ("refused", "the claim is somebody else's, or the P4 host knob moved during the round"),
    },
    "apps.start": {
        0: ("ok", "started, or it was already running"),
        1: ("failed", "it could not be started (the output says why)"),
    },
    "apps.stop": {
        0: ("ok", "it was running, and it is not now"),
        1: ("failed", "it could not be stopped, or its pidfile was poisoned"),
        2: ("nothing", "there was nothing to stop -- this is NOT a usage error for this verb"),
    },
    # run_cells.sh --cell <name>: 0 is PASS *or SKIP* -- the job view reads the CELL: line the
    # cell's own judge printed to say which, and SKIP is not a pass.
    "cells.run": {
        0: ("see-verdict", "the cell PASSED or was SKIPPED -- read cell_verdict; SKIP is not a pass"),
        1: ("fail", "the cell FAILED: its judge printed CELL: FAIL"),
        2: ("harness", "the harness could not run the cell, or the RESTORE after it failed -- "
                       "the lab is NOT restored; read the output"),
    },
    "apps.status": {
        0: ("ok", "the table was printed"),
    },
}


# Where each table's codes come from. "help": the phrase `ndt help` prints for each rc (compared
# whitespace-normalised). "code": (line, rc, text that line must contain, the function that line
# lies in) in tools/test_workflow/ndt -- trunk cafd518a's line numbers (segment W of
# TICKET-P4-heartbeat added 124 lines to ndt above cmd_status; the 11 rows below it moved by that
# much, each located by its old line's text in the same function): the `serve)` dispatch lies
# below every anchor. 🔴 The function is half the anchor (intake judge 09-26, finding 3): `return
# 1` is on 187 lines of this tree's ndt, and 09-24's apps.start line 8315 was one of them --
# proc_checkout's, 8439 since segment W. [Co-developed with claude code -- Adam]
RC_SOURCE = {
    "up": {"help": {0: "exit 0 the fabric came up and verified",
                    1: "1 something was MEASURED and it was dirty",
                    2: "2 is a usage error",
                    5: "5 a GUARD REFUSED and nothing was built"}},
    "down": {"help": {0: "exit 0 the teardown finished and the machine verified clean",
                      1: "1 any of: stack.sh's half exited non-zero",
                      2: "2 is a usage error",
                      3: "3 THERE WAS NOTHING TO TEAR DOWN",
                      5: "5 A GUARD REFUSED and nothing was torn down"}},
    "status.check": {"help": {0: "exit 0 all compared fields match",
                              1: "1 one of them does not (the message names it)",
                              3: "3 nothing was compared, because there is no baseline RIGHT NOW"},
                     "code": [(7063, 3, "return 3", "cmd_status"), (7068, 0, "return 0", "cmd_status"),
                              (7072, 1, "return 1", "cmd_status")]},
    "status": {"code": [(7074, 0, "return 0", "cmd_status")]},
    "claim": {"code": [(753, 2, "return 2", "cmd_claim"), (762, 2, "return 2", "cmd_claim"),
                       (787, 1, "return 1", "claim_take"), (860, 1, "return 1", "claim_take"),
                       (862, 0, 'ok "lab claimed by', "claim_take")]},
    "release": {"code": [(866, 0, "return 0", "cmd_release"), (871, 1, "return 1", "cmd_release"),
                         (899, 1, "return 1", "cmd_release")]},
    "apps.start": {"code": [(8895, 0, "return 0", "app_start"), (8899, 1, "return 1", "app_start"),
                            (8972, 1, "return 1", "app_start")]},
    "apps.stop": {"code": [(10413, 1, "return 1", "cmd_apps"), (10416, 2, "return 2", "cmd_apps"),
                           (10419, 0, "return 0", "cmd_apps")]},
    "apps.status": {"code": [(10346, 0, "return 0", "cmd_apps")]},
}


def meaning(kind, rc):
    """(rc_class, sentence) for `ndt <kind>` having exited with rc."""
    if rc is None:
        return ("unknown", "no exit code was recorded")
    if rc < 0:
        return ("signal", "ndt was killed by signal %d; the lab may be half-built or half-torn-down: "
                          "read the output and run status" % -rc)
    row = RC_TABLE.get(kind, {}).get(rc)
    if row is None:
        return ("unknown", "rc %d is not in this service's table for '%s'; read the output" % (rc, kind))
    return row
