"""Regenerate p4runtime's _pb2 / _pb2_grpc modules for the protobuf this venv has.

Worker REQ (TICKET-p4proxy-requirements), route C of the protobuf upgrade. p4runtime 1.5.0 (the
newest on PyPI) ships pre-3.19 generated code that protobuf >= 4.21 refuses on its default (upb)
backend. The .proto sources are not in the wheel -- but every old _pb2 embeds its complete
FileDescriptorProto (`serialized_pb`), so no download is needed: this reads those descriptors,
writes them as a FileDescriptorSet, and runs grpc_tools.protoc --descriptor_set_in over it.

MUST be run with PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python (the only way the OLD modules
import on protobuf 5), and ONLY on a venv this worker owns -- it overwrites files in its
site-packages/p4/.

  PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python <venv>/bin/python regen_p4runtime_pb2.py <workdir>

Prints the old and new sha256 of every file it replaces, and asserts that each regenerated
module's FileDescriptorProto is byte-for-byte the one it replaced (checked in a fresh
interpreter on the default backend by the caller -- see the log).

[Co-developed with claude code -- Adam]
"""
import hashlib
import importlib
import os
import shutil
import subprocess
import sys

from google.protobuf import descriptor_pb2

assert os.environ.get("PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION") == "python", "see docstring"
work = os.path.abspath(sys.argv[1])
os.makedirs(work, exist_ok=True)

P4_FILES = ["p4/config/v1/p4types.proto", "p4/config/v1/p4info.proto",
            "p4/v1/p4data.proto", "p4/v1/p4runtime.proto"]
# Dependencies protoc must be able to resolve, in dependency order. Not regenerated: they belong
# to protobuf and googleapis-common-protos, whose own modules are current.
DEP_MODULES = ["google.protobuf.any_pb2", "google.rpc.status_pb2"]


def module_of(proto):
    return proto[:-len(".proto")].replace("/", ".") + "_pb2"


fds = descriptor_pb2.FileDescriptorSet()
old = {}
for mod in DEP_MODULES + [module_of(p) for p in P4_FILES]:
    m = importlib.import_module(mod)
    fdp = descriptor_pb2.FileDescriptorProto.FromString(m.DESCRIPTOR.serialized_pb)
    fds.file.append(fdp)
    old[fdp.name] = m.DESCRIPTOR.serialized_pb
    print(f"descriptor {fdp.name:32s} from {m.__file__}")
set_path = os.path.join(work, "p4runtime.fds")
with open(set_path, "wb") as f:
    f.write(fds.SerializeToString())
with open(os.path.join(work, "old_serialized.bin"), "wb") as f:
    for name in P4_FILES:
        f.write(name.encode() + b"\0" + old[name].hex().encode() + b"\n")

out = os.path.join(work, "gen")
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
cmd = [sys.executable, "-m", "grpc_tools.protoc", f"--descriptor_set_in={set_path}",
       f"--python_out={out}", f"--grpc_python_out={out}"] + P4_FILES
print("$", " ".join(cmd))
subprocess.run(cmd, check=True)

import p4  # noqa: E402  -- the installed package whose files are replaced
site_p4 = os.path.dirname(p4.__file__)
for proto in P4_FILES:
    for suffix in ("_pb2.py", "_pb2_grpc.py"):
        rel = proto[:-len(".proto")][len("p4/"):] + suffix
        src, dst = os.path.join(out, "p4", rel), os.path.join(site_p4, rel)
        if not os.path.exists(src):
            print(f"not generated (protoc writes _grpc only for services): {rel}")
            continue
        h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()[:16]  # noqa: E731
        before = h(dst) if os.path.exists(dst) else "<absent>"
        shutil.copyfile(src, dst)
        print(f"replaced {rel:32s} {before} -> {h(dst)}")
for root, dirs, _ in os.walk(site_p4):
    for d in dirs:
        if d == "__pycache__":
            shutil.rmtree(os.path.join(root, d))
print("done")
