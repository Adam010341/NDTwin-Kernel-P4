#!/usr/bin/env python3
"""Generate the bash script that rehearses requirements.txt's "UPGRADING AN EXISTING VENV" text.

  gen_rehearsal.py <requirements file> forward  <V> <PARK> <vars out> <script out>
  gen_rehearsal.py <requirements file> rollback <vars in>      <script out>

Worker pb5prep (2026-09-26). Every command the procedure writes after `#   $ ` is run VERBATIM, in
order, in one bash shell, each echoed first and followed by its exit status. The only change to
the procedure's text: in block 1's first command, `V=p4_proxy/venv; PARK=$HOME;` becomes
`V=<V>; PARK=<PARK>;` (the rehearsal must not touch the real venv, nor park anything in
$HOME). Lines this generator adds that are not in the procedure are marked [rehearsal] -- probes that make a step's effect visible (the l1 probe before and after
regen, the regen tool with grpcio-tools gone, ...), never a replacement for a step.

forward:  blocks 1, 2 (probe inserted after `pip install -r`), 3; then V and OLD are saved.
rollback: V, PARK and OLD restored from the saved file (the procedure: "In a new shell, first set
          V, PARK and OLD ... and fp() as in 1"), fp() defined by block 1's own second command; the ROLLBACK block;
          then [rehearsal] the in-place forward repair the header's parenthesis describes (pip
          install -r, probe red, regen, probe green); then the ROLLBACK IN PLACE block with the
          regen tool probed right after grpcio-tools is uninstalled (a refusal path, rc 2) and
          again at the end (the protobuf-3.x no-op path).
[Co-developed with claude code -- Adam]
"""
import re
import shlex
import sys


def blocks(path):
    lines = open(path).read().splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith("# UPGRADING AN EXISTING VENV"))
    cur, out = None, {}
    for l in lines[start:]:
        m = re.match(r"^# ([0-9])\. ", l)
        if m:
            cur = m.group(1)
        elif l.startswith("# ROLLBACK IN PLACE"):
            cur = "rollback_inplace"
        elif l.startswith("# ROLLBACK,"):
            cur = "rollback"
        m = re.match(r"^#   \$ (.*)$", l)
        if m:
            out.setdefault(cur, []).append(m.group(1))
    return out


def run(cmd):
    return f"printf '%s\\n' {shlex.quote('$ ' + cmd)}\n{cmd}\necho \"[rc=$?]\"\n"


def probe(label, code, want):
    return (f"echo {shlex.quote('[rehearsal] ' + label)}\n"
            f"\"$V/bin/python\" -c {shlex.quote(code)} 2>&1 | grep -E 'Error|^[0-9]' | tail -3\n"
            f"echo \"[rehearsal probe rc=${{PIPESTATUS[0]}}] (want {want})\"\n")


IMPORT = "import p4.v1.p4runtime_pb2"
IDENT = ("import google.protobuf as g, p4.v1.p4runtime_pb2; "
         "from google.protobuf.internal import api_implementation as a; print(g.__version__, a.Type())")

req, mode = sys.argv[1], sys.argv[2]
b = blocks(req)
# The procedure's shape, asserted: a line-wrap that starts a comment line with "# 1. " once turned
# the ROLLBACK block's commands into block 1's (caught at generation, fixed in the file). Any
# change to how many commands a block has must be a deliberate edit here too.
SHAPE = {"1": 3, "2": 3, "3": 6, "rollback": 2, "rollback_inplace": 4}
got = {k: len(v) for k, v in b.items()}
if got != SHAPE:
    sys.exit(f"procedure shape changed: {got} != {SHAPE}")
s = ["set -u", 'cd /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-pb5-merge-prep-0926 || exit 2', ""]
if mode == "forward":
    V, PARK, vars_out, out = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
    first = b["1"][0]
    head = "V=p4_proxy/venv; PARK=$HOME;"
    if not first.startswith(head):
        sys.exit(f"block 1 no longer starts with {head!r}: {first!r}")
    s.append("echo '### block 1 (the ONLY edit: %s -> V=%s; PARK=%s;)'" % (head, V, PARK))
    s.append(run(first.replace(head, f"V={V}; PARK={PARK};", 1)))
    for c in b["1"][1:]:
        s.append(run(c))
    s.append("echo '### block 2'")
    for c in b["2"]:
        s.append(run(c))
        if "install -r" in c:
            s.append(probe("l1 probe after pip install -r, before regen", IMPORT, "nonzero"))
    s.append(probe("l1 probe after regen", IMPORT, "0"))
    s.append("echo '### block 3'")
    for c in b["3"]:
        s.append(run(c))
    s.append(f'printf "V=%q\\nPARK=%q\\nOLD=%q\\n" "$V" "$PARK" "$OLD" > {shlex.quote(vars_out)}')
    s.append(f"echo '[rehearsal] saved V and OLD to {vars_out}'; cat {shlex.quote(vars_out)}")
elif mode == "rollback":
    vars_in, out = sys.argv[3], sys.argv[4]
    s.append(f"echo '[rehearsal] a new shell: V, PARK and OLD from {vars_in}, fp() from block 1'")
    s.append(f"source {shlex.quote(vars_in)}; echo \"V=$V PARK=$PARK OLD=$OLD\"")
    fp = [c for c in b["1"] if c.startswith("fp()")]
    if len(fp) != 1:
        sys.exit("block 1 must define fp() exactly once")
    s.append(run(fp[0]))
    s.append("echo '### ROLLBACK'")
    for c in b["rollback"]:
        s.append(run(c))
    s.append(probe("identity after ROLLBACK", IDENT, "0, prints 3.20.3 python"))
    s.append("echo '[rehearsal] the restored venv is at its first path again; its pip names it:'; "
             "\"$V/bin/pip\" --version")
    s.append("echo '### [rehearsal] in-place upgrade without regen, then the repair the header names'")
    s.append(run('"$V/bin/pip" install -r p4_proxy/requirements.txt'))
    s.append(probe("l1 probe after an in-place pip install -r", IMPORT, "nonzero (TypeError)"))
    s.append(run('"$V/bin/python" p4_proxy/regen_p4runtime_pb2.py'))
    s.append(probe("identity after the repair", IDENT, "0, prints 5.29.6 upb"))
    s.append("echo '### ROLLBACK IN PLACE'")
    for c in b["rollback_inplace"]:
        s.append(run(c))
        if "uninstall -y grpcio-tools" in c:
            s.append("echo '[rehearsal] regen tool with protobuf 5 and no grpcio-tools (refusal path, want rc 2):'")
            s.append('"$V/bin/python" p4_proxy/regen_p4runtime_pb2.py; echo "[rehearsal rc=$?] (want 2)"')
    s.append("echo '[rehearsal] regen tool on protobuf 3.x (no-op path, want rc 0):'")
    s.append('"$V/bin/python" p4_proxy/regen_p4runtime_pb2.py; echo "[rehearsal rc=$?] (want 0)"')
    s.append('echo "[rehearsal] pip check:"; "$V/bin/python" -m pip check; echo "[rehearsal rc=$?]"')
    s.append('echo "[rehearsal] freeze now vs the old venv\'s freeze from block 1:"; '
             'diff <(PYTHONDONTWRITEBYTECODE=1 "$V/bin/python" -m pip freeze --all) "$OLD.freeze"; '
             'echo "[rehearsal diff rc=$?]"')
else:
    sys.exit(f"mode {mode!r}")
open(out, "w").write("\n".join(s) + "\n")
print(f"wrote {out}")
