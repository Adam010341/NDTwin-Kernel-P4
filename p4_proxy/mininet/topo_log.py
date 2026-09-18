#!/usr/bin/env python3
"""Where the topology bridge's output goes once the pane that held it is gone.

[Co-developed with claude code -- Adam]

Why this exists. `ndtwin-lab topo-start` launches ntg_bmv2_topo.py inside a root-owned tmux
pane, and that pane is the ONLY place its stdout and stderr have ever existed. When the script
dies -- which is exactly the interesting case -- tmux reaps the session, the pane goes with it,
and `ndtwin-lab topo-out` answers "no topo session". The 2026-09-18 live round is the whole
argument: `ndt up p4 --app` reported `fabric did not come up: 0/4 switches, manifest missing`,
the bridge had already exited on a KeyError, and the traceback that named the line existed
nowhere on the machine. The failure was reproducible only by re-running it by hand.

Two properties this module has to hold at once, and they pull against each other:

  * EVERY byte, including the bytes this process does not write itself. `os.system('sudo mn
    -c')`, Mininet's own logger (which binds sys.stderr at import and keeps that object), and
    anything a child prints all go to file descriptors 1 and 2, not to `sys.stdout`. So the
    tee is at the FD level -- `os.dup2` onto a pipe with a pump thread -- and not a
    `sys.stdout` wrapper, which would have caught only this file's own `print`s.
  * The pane keeps working, INCLUDING NTG's interactive prompt. That is not a preference:
    NTG's `command_line()` reaches `PromptSession.prompt_async`, and prompt_toolkit's
    `create_output` (output/defaults.py, "Stdout is not a TTY? Render as plain text.") returns
    a `PlainTextOutput` when `sys.stdout.isatty()` is false. A prompt rendered as plain text
    into a pipe is not a prompt anybody can use, and `ndtwin-lab topo-cmd` types into it.

So the tee is STOPPED for the stretch where NTG owns the terminal and STARTED again for
teardown: bring-up, the part that fails, is captured; the interactive session is left on the
real tty it needs. `record_traceback` writes to the file directly and works in either state,
because the crash this module exists for can happen in either.

stdin is never touched. prompt_toolkit's `Vt100Input` REQUIRES a tty there (it raises
`io.UnsupportedOperation` otherwise), and nothing here has any reason to go near it.

The rotation is stack.sh's `rotate_log`, in Python and deliberately to the letter: stamped
rather than numbered (a `.prev` means something different an hour later, so a path written down
in a report stops being true), `NDT_LOG_KEEP` with the same default of 5 and the same floor of
1, and pruning only the stamped generations this scheme creates -- a pre-existing `.prev` is
left alone, because deleting a file this scheme did not write is not its decision.
"""
from __future__ import annotations

import glob
import os
import sys
import threading
import time
import traceback

_HERE = os.path.dirname(os.path.abspath(__file__))

#: The tests' override, and only the tests'. The bridge is launched through `tmux` under a fixed
#: root environment where no operator-set variable arrives -- the same reason
#: `host_count_override` and `app_package_override` are files -- so production always takes the
#: derived path below. `ndt`'s `topo_log_tail` reads the same variable name.
LOG_ENV = "NDT_TOPO_LOG"

#: Beside stack.sh's p4_proxy.log / kernel.log / ryu.log, under the same $RUN_DIR/logs.
LOG_RELPATH = os.path.join(".test_run", "logs", "topo.log")

#: stack.sh's rotate_log default and its override, repeated here rather than re-chosen.
KEEP_ENV = "NDT_LOG_KEEP"
DEFAULT_KEEP = 5


def default_path(kernel_dir=None, env=None):
    """The topology log for this checkout.

    Derived from THIS FILE's location rather than from a variable: the bridge is started as
    `$NTG_PY $KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py` under a root environment that
    carries nothing an operator set, so the file's own path is the only thing that can name the
    tree it belongs to -- and naming the wrong tree is FINDING-01.
    """
    env = os.environ if env is None else env
    override = env.get(LOG_ENV)
    if override:
        return override
    if kernel_dir is None:
        kernel_dir = os.path.normpath(os.path.join(_HERE, "..", ".."))
    return os.path.join(kernel_dir, LOG_RELPATH)


def keep_depth(env=None):
    """How many rotated generations survive. stack.sh's rule, including the floor of one."""
    env = os.environ if env is None else env
    raw = str(env.get(KEEP_ENV, "")).strip()
    if raw.isdigit() and int(raw) >= 1:
        return int(raw)
    return DEFAULT_KEEP


def rotate(path, keep=None, env=None, now=None):
    """Move `path` aside under its own start time and prune to `keep` generations.

    Returns the name the old log was moved to, or None when there was nothing to move. An
    EMPTY file is not rotated, which is stack.sh's `[[ -s "$log" ]]` -- a run that wrote
    nothing must not push a real generation off the end.
    """
    keep = keep_depth(env) if keep is None else keep
    try:
        if os.path.getsize(path) == 0:
            return None
    except OSError:
        return None

    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(now))
    target = "%s.%s" % (path, stamp)
    n = 0
    while os.path.exists(target):
        n += 1
        target = "%s.%s-%d" % (path, stamp, n)
    os.replace(path, target)

    # Descending by name IS descending by era, because the suffix is the era -- which is why
    # the stamp is there and why this does not consult mtime, a thing a grep or an editor can
    # move. Only `path.<digits>...` is considered: a hand-made `.prev` is not ours to delete.
    generations = sorted(glob.glob(path + ".[0-9]*"), reverse=True)
    for old in generations[keep:]:
        try:
            os.remove(old)
        except OSError:
            pass
    return target


class Tee:
    """stdout and stderr to the pane AND to a file, with the file surviving the pane.

    [Co-developed with claude code -- Adam]
    `start()` swaps file descriptors 1 and 2 onto a pipe and pumps that pipe to the real
    terminal and to the log. `stop()` puts the original descriptors back and leaves the log
    open, which is what lets the NTG prompt have the tty it requires while `record_traceback`
    still has somewhere to write.

    Nothing here raises at the caller: a topology that refuses to come up because its LOG could
    not be opened would be a diagnostic aid that costs more than the defect it reports. Failures
    to open or to write are reported once, on the terminal, and the bring-up goes on.
    """

    def __init__(self, path, keep=None, env=None, report=None):
        self.path = path
        self._keep = keep
        self._env = env
        self._report = report or (lambda msg: print(msg, file=sys.stderr))
        self._fh = None
        self._saved = {}
        self._reader = None
        self._read_fd = None
        #: The pump thread's own copy of the terminal, which it closes itself. Kept here so a
        #: test can assert it is NOT one of `_saved`'s -- see `start`.
        self._terminal_fd = None
        self.active = False
        self.rotated_to = None

    # --- the file ---------------------------------------------------------------------------

    def open(self):
        """Rotate and open the log. Returns True when there is a file to write to.

        Separate from `start()` because the two can fail independently, and because the
        traceback path needs the file even when the descriptor swap was refused.
        """
        if self._fh is not None:
            return True
        try:
            directory = os.path.dirname(self.path)
            if directory:
                os.makedirs(directory, exist_ok=True)
            self.rotated_to = rotate(self.path, keep=self._keep, env=self._env)
            # Binary and unbuffered: bmv2 and Mininet both emit bytes this process has no
            # business decoding (BMv2Switch.failure_reason already documents the non-UTF-8
            # case), and a buffered log is empty in precisely the crash it exists for.
            self._fh = open(self.path, "ab", buffering=0)
        except OSError as exc:
            self._report("WARNING: could not open the topology log %s: %s" % (self.path, exc))
            self._fh = None
            return False
        return True

    def _to_file(self, text):
        if self._fh is None:
            return False
        try:
            self._fh.write(text.encode("utf-8", "replace"))
            return True
        except (OSError, ValueError):
            return False

    # --- the descriptors --------------------------------------------------------------------

    def start(self):
        """Send fds 1 and 2 through the pump. Idempotent; never raises."""
        if self.active:
            return True
        if not self.open():
            return False
        try:
            sys.stdout.flush()
            sys.stderr.flush()
        except (OSError, ValueError):
            pass
        try:
            read_fd, write_fd = os.pipe()
        except OSError as exc:
            self._report("WARNING: could not tee this run's output to %s: %s"
                         % (self.path, exc))
            return False
        terminal_fd = None
        try:
            self._saved = {1: os.dup(1), 2: os.dup(2)}
            # 🔴 THE PUMP GETS ITS OWN DESCRIPTOR, not a share of `_saved`. Two reasons, and
            # the second one is a data-corruption bug rather than a cosmetic one: the pump is a
            # thread that is still draining while `stop()` returns, so (a) whatever it has left
            # to write must still have somewhere to go, and (b) a descriptor NUMBER that
            # `stop()` has closed is a number the process will hand to the next `open()` -- and
            # this thread would then be writing the topology log into somebody else's file.
            # The pump closes this copy itself, when it has finished.
            terminal_fd = os.dup(1)
            os.dup2(write_fd, 1)
            os.dup2(write_fd, 2)
        except OSError as exc:
            for fd in [read_fd, write_fd, terminal_fd] + list(self._saved.values()):
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            self._report("WARNING: could not tee this run's output to %s: %s"
                         % (self.path, exc))
            self._saved = {}
            return False
        # fds 1 and 2 are now the only write ends, which is what makes `stop()` produce the EOF
        # the pump waits for.
        os.close(write_fd)
        self._read_fd = read_fd
        self._terminal_fd = terminal_fd
        self._reader = threading.Thread(target=self._pump, args=(read_fd, terminal_fd),
                                        daemon=True, name="topo-log-tee")
        self._reader.start()
        self.active = True
        return True

    def _pump(self, read_fd, terminal_fd):
        """Every byte to the terminal first, then to the log. Never lets either kill the other."""
        try:
            while True:
                chunk = os.read(read_fd, 65536)
                if not chunk:
                    break
                try:
                    os.write(terminal_fd, chunk)
                except OSError:
                    pass
                if self._fh is not None:
                    try:
                        self._fh.write(chunk)
                    except (OSError, ValueError):
                        pass
        except OSError:
            pass
        finally:
            for fd in (read_fd, terminal_fd):
                try:
                    os.close(fd)
                except OSError:
                    pass

    def stop(self, join_timeout=5.0):
        """Give the real terminal back. The log stays open. Idempotent; never raises."""
        if not self.active:
            return
        try:
            sys.stdout.flush()
            sys.stderr.flush()
        except (OSError, ValueError):
            pass
        # Put the real descriptors back FIRST: dup2 closes the pipe write end that fd 1 and fd 2
        # currently are, and with the last write end gone the pump reads EOF and drains.
        for fd, saved in sorted(self._saved.items()):
            try:
                os.dup2(saved, fd)
            except OSError:
                pass
        self.active = False
        if self._reader is not None:
            # Bounded, because the pump ends on EOF and EOF needs every copy of the write end
            # to be gone. This process owns them all -- Mininet gives its node shells their own
            # pipes and bmv2 is launched with `> /tmp/sN_bmv2.log 2>&1` -- but a wait that
            # cannot end is not a thing to put in a teardown path on the strength of that.
            #
            # 🔴 AND IT IS BEFORE THE CLOSES BELOW, which is not tidiness. The pump still has
            # whatever was in the pipe when the swap happened -- measured under a real pty on
            # 2026-09-18, the last line printed before the hand-over was in the log and NOT on
            # the terminal, because the descriptor it was going to had already been closed.
            self._reader.join(timeout=join_timeout)
            self._reader = None
        for saved in self._saved.values():
            try:
                os.close(saved)
            except OSError:
                pass
        self._saved = {}
        self._read_fd = None
        self._terminal_fd = None

    def close(self):
        self.stop()
        if self._fh is not None:
            try:
                self._fh.close()
            except OSError:
                pass
            self._fh = None

    # --- the crash --------------------------------------------------------------------------

    def record_traceback(self, banner=None, text=None):
        """Put an uncaught exception in the log, whichever state the tee is in.

        The pane may be about to disappear with the process, so the file is what has to have
        it. Written through stderr while the tee is up (one copy reaches both destinations) and
        to both by hand while it is down -- writing to both in both states would double it in
        the file, and a doubled traceback reads like two failures.
        """
        if text is None:
            text = traceback.format_exc()
        if banner is None:
            banner = ("\n[ntg_bmv2_topo] uncaught exception -- the fabric may be half built "
                      "and the pane is about to go:\n")
        if self.active:
            try:
                sys.stderr.write(banner + text)
                sys.stderr.flush()
            except (OSError, ValueError):
                self._to_file(banner + text)
            return
        self.open()
        self._to_file(banner + text)
        try:
            sys.stderr.write(banner + text)
            sys.stderr.flush()
        except (OSError, ValueError):
            pass

    def note(self, line):
        """One line into both destinations, whichever state the tee is in."""
        if self.active:
            print(line)
            try:
                sys.stdout.flush()
            except (OSError, ValueError):
                pass
            return
        self._to_file(line + "\n")
        print(line)


# [Co-developed with claude code -- Adam]
