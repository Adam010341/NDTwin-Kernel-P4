"""The `ps` oracle: a fabric bmv2's own argv, found by its Thrift port.

[Co-developed with claude code -- Adam]

P1 (`--cpu-port 510`) and Q2 (`--priority-queues`) read the argv the switch was started with.
The process is found by the exact `--thrift-port 909N` pair in its argv -- never by name (no
`pgrep -f`), and the throwaway switches S0 runs carry ports outside 9091-9100, so they cannot be
mistaken for a fabric one.
"""
from __future__ import annotations


def ps_lines(runner):
    res = runner.run(["ps", "-eo", "pid=,args="], timeout=10)
    return res.stdout.splitlines() if res.rc == 0 else None


def bmv2_argv(lines, thrift_port):
    """The argv tokens of the one process whose argv has `--thrift-port <port>`; None when there
    is not exactly one."""
    if lines is None:
        return None
    hits = []
    for line in lines:
        parts = line.split()
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        argv = parts[1:]
        for i, tok in enumerate(argv[:-1]):
            if tok == "--thrift-port" and argv[i + 1] == str(thrift_port):
                hits.append(argv)
                break
    return hits[0] if len(hits) == 1 else None


def has_flag(argv, flag, value=None):
    if argv is None:
        return None
    for i, tok in enumerate(argv):
        if tok == flag and (value is None or (i + 1 < len(argv) and argv[i + 1] == str(value))):
            return True
        if value is not None and tok == "%s=%s" % (flag, value):
            return True
    return False
