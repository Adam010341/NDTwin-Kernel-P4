"""The one door every subprocess of the probe goes through.

[Co-developed with claude code -- Adam]

sudo, mnexec, tc, ndt, simple_switch_CLI, ps, ip, ethtool: every one of them is run through a
`Runner` the caller hands in (design 4.1), so a test that injects a `RecordingRunner` has seen
every command the reading layer and the lifecycle would have run -- and the hermetic test proves
it with fail-loud stubs first on PATH and a refusal of every other spawn.

The exceptions are outside the reading layer and the lifecycle, and none of them touches the
lab: probe.py's `git` identity calls, the throwaway switch's own long-lived child (throwaway.py,
stopped by its pid), and the two offline helpers capture_thrift_fixtures.py and vs_trial.py.
"""
from __future__ import annotations

import os
import subprocess


class Result(object):
    """What one command did. `rc` is None when it could not be started at all."""

    def __init__(self, argv, rc, stdout="", stderr="", error=None):
        self.argv = list(argv)
        self.rc = rc
        self.stdout = stdout or ""
        self.stderr = stderr or ""
        self.error = error

    @property
    def ok(self):
        return self.rc == 0

    def __repr__(self):
        return "Result(argv=%r, rc=%r)" % (self.argv, self.rc)


class Runner(object):
    """Runs argv lists (never a shell string), with a timeout, and never raises for a failure."""

    def run(self, argv, env=None, timeout=120, cwd=None, input_text=None):
        full_env = None
        if env is not None:
            full_env = dict(os.environ)
            full_env.update(env)
        try:
            proc = subprocess.run(list(argv), env=full_env, cwd=cwd, input=input_text,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  universal_newlines=True, timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            return Result(argv, None, exc.stdout or "", exc.stderr or "", error="timeout")
        except OSError as exc:
            return Result(argv, None, "", "", error="%s: %s" % (type(exc).__name__, exc))
        return Result(argv, proc.returncode, proc.stdout, proc.stderr)


class RecordingRunner(Runner):
    """A Runner for tests: records argv, answers from canned replies, runs nothing.

    `replies` is a list of (matcher, reply). A matcher is a tuple that must equal the start of
    argv, or a callable taking argv. A reply is a Result-like tuple (rc, stdout[, stderr]) or a
    callable (argv, env, input_text) -> such a tuple. An argv nothing matches answers rc 127 --
    a test that forgot to can a command sees the command fail, never succeed.
    """

    def __init__(self, replies=None):
        self.replies = list(replies or [])
        self.calls = []

    def add(self, matcher, reply):
        self.replies.append((matcher, reply))
        return self

    def run(self, argv, env=None, timeout=120, cwd=None, input_text=None):
        argv = list(argv)
        self.calls.append({"argv": argv, "env": dict(env or {}), "input": input_text})
        for matcher, reply in self.replies:
            hit = matcher(argv) if callable(matcher) else tuple(argv[:len(matcher)]) == tuple(matcher)
            if not hit:
                continue
            out = reply(argv, env, input_text) if callable(reply) else reply
            rc, stdout = out[0], out[1]
            stderr = out[2] if len(out) > 2 else ""
            return Result(argv, rc, stdout, stderr)
        return Result(argv, 127, "", "RecordingRunner: no canned reply for %r" % (argv,))

    def argvs(self):
        return [c["argv"] for c in self.calls]
