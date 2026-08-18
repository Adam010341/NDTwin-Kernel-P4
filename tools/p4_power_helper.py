#!/usr/bin/env python3
"""
ndtwin-p4-power -- start or stop exactly one bmv2 switch, as root, from the manifest.

[Co-developed with claude code -- Adam]

This is the privileged half of P4PowerStrategy (Phase 7, doc/2026-08-11_phase7_power_mechanism_design.md).
The kernel runs as an unprivileged user and simple_switch_grpc runs as root, so the kill and the
relaunch both need root; rather than putting `kill` into NOPASSWD -- which would let the invoking
user kill any root process on the machine -- this script is the one thing sudoers allows, and it
refuses everything except managing one named bmv2 switch.

Install (one-time, as root -- the sudoers line must point at a root-owned copy, never at the
repo checkout, because NOPASSWD on a user-writable file is root for whoever can edit it):

    sudo cp tools/p4_power_helper.py /usr/local/sbin/ndtwin-p4-power
    sudo chown root:root /usr/local/sbin/ndtwin-p4-power
    sudo chmod 755 /usr/local/sbin/ndtwin-p4-power
    # visudo:
    # adam ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-p4-power

Hard rules, which the tests assert and reviewers should hold this file to:

  * Processes are only ever addressed by PID taken from the manifest, and the PID must still
    look like the process the manifest described (comm + gRPC port in cmdline) before it is
    signalled. Never by name: the original implementation's `pkill -f simple_switch_grpc`
    would have killed all ten switches, because Mininet nodes share the root PID namespace.
    No `pkill`, no `killall`, no name matching -- in any code path.
  * SIGTERM only. bmv2 exits cleanly on TERM; a process that ignores it has something else
    wrong, and that is reported as a failure rather than silenced with SIGKILL.
  * The launch never goes through a shell. The manifest's argv is split with shlex and passed
    to the OS as a list, so shell metacharacters in it are inert.
  * The twin-facing caller gets an honest answer: "off" exits 0 only once the process is gone,
    "on" exits 0 only once the gRPC port is accepting connections.
"""

import json
import os
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

MANIFEST_PATH = "/tmp/ndtwin_p4_switches.json"
EXPECTED_NAME = "simple_switch_grpc"
#: /proc/<pid>/comm is capped at 15 characters (TASK_COMM_LEN - 1), so the full binary name
#: can never appear there -- comparing against it would refuse every real switch. The manual
#: test runbook documents the same trap for `pgrep -x`. comm gets the truncation; the
#: untruncated name is checked against /proc/<pid>/cmdline, which is not capped.
EXPECTED_COMM = EXPECTED_NAME[:15]

#: How long "off" waits for the process to disappear after SIGTERM.
TERM_WAIT_S = 10.0
#: How long "on" waits for the gRPC port to accept connections. bmv2 loads its config and
#: binds within a couple of seconds on this machine; 15 covers a loaded box.
PORT_WAIT_S = 15.0
POLL_INTERVAL_S = 0.2


def fail(msg):
    print(f"ndtwin-p4-power: {msg}", file=sys.stderr)
    sys.exit(1)


def manifest_path():
    """
    The manifest location. Overridable via environment for the unprivileged tests only:
    when running as root the override is ignored, so a caller cannot point the privileged
    run at a manifest they control. (sudo's env_reset strips the variable anyway; this makes
    the guarantee not depend on sudo configuration.)
    """
    if os.geteuid() != 0:
        return os.environ.get("NDTWIN_P4_MANIFEST", MANIFEST_PATH)
    return MANIFEST_PATH


def load_manifest(path):
    """
    Read the manifest, refusing one that unprivileged users could have influenced.

    The security load-bearing part: this script executes the manifest's argv as root, so the
    manifest must be trustworthy. /tmp is sticky -- anyone can create the *name* first, and a
    root `open(path, "w")` truncates in place without changing the owner, which is why
    write_manifest() in p4_testbed_topo.py replaces the inode instead of rewriting it. Here we
    verify what that guarantees: the file is owned by root and writable only by root. The check
    is skipped when running unprivileged (tests use fixture manifests owned by the test user;
    an unprivileged run cannot damage anything the invoker could not already damage).

    O_NOFOLLOW + fstat on the same fd, so the thing checked is the thing read.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as e:
        fail(f"cannot open manifest {path}: {e}")
    try:
        st = os.fstat(fd)
        if os.geteuid() == 0:
            if st.st_uid != 0:
                fail(f"manifest {path} is not owned by root (uid {st.st_uid}); refusing to "
                     f"act on it -- see load_manifest() for why this matters")
            if st.st_mode & 0o022:
                fail(f"manifest {path} is writable by group/other "
                     f"(mode {oct(st.st_mode & 0o777)}); refusing to act on it")
        with os.fdopen(fd, "r") as fh:
            fd = None  # fdopen owns it now
            data = json.load(fh)
    except (OSError, ValueError) as e:
        fail(f"cannot read manifest {path}: {e}")
    finally:
        if fd is not None:
            os.close(fd)
    if not isinstance(data, dict):
        fail(f"manifest {path} is not a JSON object")
    return data


def save_manifest(path, manifest):
    """Atomic replace, same reasoning as write_manifest() in p4_testbed_topo.py: a new inode
    owned by whoever runs this (root in real use), never a truncate-in-place of an inode
    somebody else may own."""
    dirname = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=dirname, prefix=".ndtwin_p4_switches.")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(manifest, fh, indent=2)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        fail(f"cannot update manifest {path}: {e}")


def proc_comm(pid):
    try:
        with open(f"/proc/{pid}/comm") as fh:
            return fh.read().strip()
    except OSError:
        return None


def proc_cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            return fh.read().decode("utf-8", "replace").split("\0")
    except OSError:
        return None


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # It exists but we may not signal it -- only possible unprivileged.
        return True


def port_listening(port, timeout=0.3):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


def get_entry(manifest, name):
    entry = manifest.get(name)
    if not isinstance(entry, dict):
        fail(f"switch '{name}' is not in the manifest (has the topology script run, and did "
             f"the switch come up? write_manifest() only lists verified-live switches)")
    return entry


def verify_is_our_switch(pid, entry, name):
    """
    The PID-reuse defence: between the manifest being written and this run, the process may
    have exited and the PID been handed to something else. Both checks must pass before the
    PID is believed: comm says what the binary calls itself, and the gRPC port in the cmdline
    ties it to *this* switch rather than any bmv2.
    """
    comm = proc_comm(pid)
    if comm != EXPECTED_COMM:
        fail(f"pid {pid} (manifest entry '{name}') is '{comm}', not {EXPECTED_COMM}; the "
             f"manifest is stale and the PID has been reused -- refusing to signal it")
    cmdline = proc_cmdline(pid) or []
    base = os.path.basename(cmdline[0]) if cmdline and cmdline[0] else ""
    if base != EXPECTED_NAME:
        # comm is truncated, so "simple_switch_g" also matches e.g. "simple_switch_gui";
        # cmdline is not truncated and settles it.
        fail(f"pid {pid} has comm '{comm}' but its cmdline names '{base}', not "
             f"{EXPECTED_NAME}; refusing to signal it")
    port_token = str(entry.get("grpc_port"))
    if not any(port_token in arg for arg in cmdline):
        fail(f"pid {pid} is a {EXPECTED_NAME} but its cmdline does not mention gRPC port "
             f"{port_token}; it is some other switch -- refusing to signal it")


def cmd_off(name):
    path = manifest_path()
    manifest = load_manifest(path)
    entry = get_entry(manifest, name)

    pid = entry.get("pid")
    if pid is None:
        # Idempotent by design: the strategy's guard is the twin's is_up flag, and the two can
        # disagree after a crash. "Already stopped" is a true answer, not an error.
        print(json.dumps({"status": "already-stopped", "name": name}))
        return
    if not isinstance(pid, int) or pid < 2:
        fail(f"manifest entry '{name}' has an unusable pid ({pid!r})")

    if not pid_alive(pid):
        entry["pid"] = None
        save_manifest(path, manifest)
        print(json.dumps({"status": "already-stopped", "name": name,
                          "detail": f"pid {pid} no longer exists; manifest updated"}))
        return

    verify_is_our_switch(pid, entry, name)

    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as e:
        fail(f"could not signal pid {pid}: {e}")

    deadline = time.monotonic() + TERM_WAIT_S
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            entry["pid"] = None
            save_manifest(path, manifest)
            print(json.dumps({"status": "stopped", "name": name, "pid": pid}))
            return
        time.sleep(POLL_INTERVAL_S)

    fail(f"pid {pid} is still running {TERM_WAIT_S}s after SIGTERM; not escalating to "
         f"SIGKILL -- bmv2 exits cleanly on TERM, so a switch that will not is evidence of "
         f"a different problem that should be looked at, not silenced")


def cmd_on(name):
    path = manifest_path()
    manifest = load_manifest(path)
    entry = get_entry(manifest, name)

    for field in ("argv", "log_file", "grpc_port"):
        if not entry.get(field):
            fail(f"manifest entry '{name}' has no {field}; cannot relaunch")

    pid = entry.get("pid")
    if isinstance(pid, int) and pid >= 2 and pid_alive(pid) and proc_comm(pid) == EXPECTED_COMM:
        fail(f"'{name}' already appears to be running (pid {pid}); refusing to start a second "
             f"instance")

    grpc_port = int(entry["grpc_port"])
    if port_listening(grpc_port):
        # Whatever holds the port, launching another bmv2 against it would die of
        # "Address already in use" -- and, worse, the failure would be blamed on the new
        # process while the stale listener kept answering probes.
        fail(f"something is already listening on gRPC port {grpc_port}; refusing to launch "
             f"a second listener behind it")

    args = shlex.split(entry["argv"])
    # An env-prefixed argv ("LD_LIBRARY_PATH=... /path/simple_switch_grpc ...") is what a
    # topology running under a bmv2 binary override records. Drop the assignments and keep the
    # command: this launch has no shell, so a "VAR=value" argv[0] would be looked up as a
    # program name and fail. The values are not applied from here -- see the derivation below
    # for why they do not need to be. [Co-developed with claude code -- Adam]
    while args and "=" in args[0] and not args[0].startswith("/"):
        args = args[1:]

    # EXPECTED_NAME, not EXPECTED_COMM: argv comes from the manifest, not from the kernel's
    # truncated comm, so the full name is what a legitimate entry carries.
    if not args or os.path.basename(args[0]) != EXPECTED_NAME:
        fail(f"manifest argv for '{name}' does not start with {EXPECTED_NAME} "
             f"({args[:1]!r}); refusing to execute it")

    # [Co-developed with claude code -- Adam]
    # Give the binary its own libraries, derived here rather than taken from the manifest.
    #
    # A fast bmv2 build lives at <prefix>/bin/simple_switch_grpc with its libraries at
    # <prefix>/lib. Launched with neither the env prefix nor this, the loader falls back to the
    # ldconfig cache and the fast binary silently runs against the *stock* libraries -- a switch
    # that is neither build, and a measurement that reports one while running the other.
    #
    # Until now the topology's env-prefixed argv was left to fail the basename check above, on
    # the reasoning that a loud refusal beats that silent mixing (p4_testbed_topo.bmv2_launch_head
    # says so). Both were true and the third option was missed: derive the path instead of
    # choosing between wrong and refused. The cost of the refusal was not small -- the
    # Energy-Saving App exists to power switches off *and back on*, so under an override it could
    # only ever shut the fabric down.
    #
    # Derived, not read from the manifest, because that adds nothing to what this script already
    # trusts. It is the same `dirname(binary)/../lib` rule resolve_bmv2_launcher applies on the
    # topology side, so the two cannot drift; and load_manifest has already established the
    # manifest is root-owned and not group/other-writable, which is the actual boundary here --
    # the basename check is a staleness guard, not a security one (it admits any
    # .../simple_switch_grpc). Anyone who could inject a library path could already choose the
    # binary.
    launch_env = os.environ
    lib_dir = os.path.normpath(os.path.join(os.path.dirname(args[0]), "..", "lib"))
    if os.path.dirname(args[0]) and os.path.isdir(lib_dir):
        launch_env = {**os.environ, "LD_LIBRARY_PATH": lib_dir}

    # O_NOFOLLOW: the log lives in /tmp, where a symlink planted at the recorded name would
    # otherwise turn a root append into a write to wherever the attacker pointed it.
    # Append rather than truncate -- the pre-power-off log is evidence worth keeping.
    try:
        log_fd = os.open(entry["log_file"],
                         os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o644)
    except OSError as e:
        fail(f"cannot open log file {entry['log_file']}: {e}")

    try:
        proc = subprocess.Popen(args, stdout=log_fd, stderr=log_fd,
                                start_new_session=True, close_fds=True, env=launch_env)
    except OSError as e:
        fail(f"could not launch {args[0]}: {e}")
    finally:
        os.close(log_fd)

    # [Co-developed with claude code -- Adam]
    # The pid is recorded here, immediately, rather than on the success path below. It used to
    # be written only inside the port-open branch, which meant the timeout path -- the one that
    # deliberately leaves the process running -- returned without ever recording it. The
    # manifest still said null, and the "off" that this function's own failure message
    # recommends reads that null, prints {"status": "already-stopped"} and exits 0 while the
    # bmv2 the helper just created keeps running and keeps the gRPC port. The helper had made a
    # process it could no longer address, and every later "off" reported success while lying.
    #
    # Recording early is safe in the direction that matters: a pid that is written and then
    # dies is handled ("off" re-verifies against /proc and clears it, "on" sees a dead pid and
    # proceeds). A pid that is never written is unreachable forever.
    entry["pid"] = proc.pid
    save_manifest(path, manifest)

    # The port opening is what "on" means. The process merely existing is not enough -- bmv2
    # runs briefly before its gRPC server binds, and reports a bind failure by exiting.
    deadline = time.monotonic() + PORT_WAIT_S
    while time.monotonic() < deadline:
        rc = proc.poll()
        if rc is not None:
            # Gone, so the pid recorded above is stale: clear it rather than leave the next
            # "on" to work out that the manifest names a corpse.
            entry["pid"] = None
            save_manifest(path, manifest)
            fail(f"{EXPECTED_NAME} for '{name}' exited with status {rc} before opening port "
                 f"{grpc_port}; see {entry['log_file']}")
        if port_listening(grpc_port):
            print(json.dumps({"status": "started", "name": name, "pid": proc.pid}))
            return
        time.sleep(POLL_INTERVAL_S)

    fail(f"{EXPECTED_NAME} for '{name}' (pid {proc.pid}) did not open port {grpc_port} "
         f"within {PORT_WAIT_S}s; it was left running -- killing it here would race its "
         f"startup. Its pid is recorded in the manifest, so 'off' will stop it once you "
         f"have decided")


def main(argv):
    if len(argv) != 3 or argv[1] not in ("on", "off"):
        print("usage: ndtwin-p4-power {on|off} <switch-name>", file=sys.stderr)
        return 2
    name = argv[2]
    if not name.replace("-", "").replace("_", "").isalnum():
        fail(f"switch name {name!r} contains characters that no Mininet node name has")
    if argv[1] == "off":
        cmd_off(name)
    else:
        cmd_on(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
