"""Exercise the SIGUSR2 greenlet dump the way a wedged Ryu would experience it:
eventlet monkeypatched, several greenlets PARKED (one blocked on a full bounded queue,
which is the exact shape the hypothesis predicts), main thread idle in the hub."""
import eventlet
eventlet.monkey_patch()
import os, sys, signal, time
sys.path.insert(0, "/home/adam/Desktop/NDTwin-Kernel")

# Was hardcoded to a scratchpad path belonging to the session that wrote this file. That session
# is gone; the directory goes with it, so the dump would land nowhere and the smoke would "pass"
# by writing to a path nobody reads. Use a temp file owned by this run instead, and print it.
# [Co-developed with claude code -- Adam]
import tempfile
_dump_fd, _dump_path = tempfile.mkstemp(prefix="ndtwin_gdump_smoke_", suffix=".txt")
os.close(_dump_fd)
os.environ["NDTWIN_RYU_GREENLET_DUMP"] = _dump_path

# Import only the dump machinery, not the whole Ryu app.
import importlib.util, types
src = open("/home/adam/Desktop/NDTwin-Kernel/intelligent_router.py").read()
start = src.index("GREENLET_DUMP_PATH = os.environ.get")
end = src.rindex("_install_greenlet_dump_handler()") + len("_install_greenlet_dump_handler()")
mod = types.ModuleType("gdump"); mod.__dict__["os"] = os
exec(compile(src[start:end], "intelligent_router.py", "exec"), mod.__dict__)

from eventlet.queue import Queue
q = Queue(2)

def blocked_putter():
    q.put("a"); q.put("b")
    q.put("c")          # blocks forever: this is the predicted shape
def sleeper():
    eventlet.sleep(300)

eventlet.spawn(blocked_putter)
eventlet.spawn(sleeper)
eventlet.sleep(0.3)     # let both park

os.kill(os.getpid(), signal.SIGUSR2)
eventlet.sleep(0.3)
os.kill(os.getpid(), signal.SIGUSR2)   # second dump, to diff like the py-spy pair
eventlet.sleep(0.3)
# "DUMPS DONE" used to print unconditionally -- which is how a dump path pointing at a deleted
# session's scratchpad survived here unnoticed. A smoke test that cannot fail is not a test.
_n = os.path.getsize(_dump_path)
if _n == 0:
    print(f"FAIL: SIGUSR2 handler wrote nothing to {_dump_path}")
    sys.exit(1)
with open(_dump_path) as _fh:
    _txt = _fh.read()
_dumps = _txt.count("greenlet dump  pid=")
_parked = _txt.count("state=parked")
if _dumps != 2:
    print(f"FAIL: expected 2 dumps, found {_dumps} in {_dump_path}")
    sys.exit(1)
# The whole point of this tool is capturing PARKED greenlet stacks -- that is what py-spy
# structurally cannot see. Reporting the parked count without asserting on it means the parked
# detection could break completely and this smoke would still print a green line. Found by the
# post-commit shadow review, which is right that a number you print but never check is decoration.
# This script parks several greenlets on purpose (one blocked on a full bounded queue), so zero
# is never correct here.
if _parked < 1:
    print(f"FAIL: {_parked} parked frames -- the dump captured no parked greenlet, "
          f"which is the one thing this tool exists to do. See {_dump_path}")
    sys.exit(1)
print(f"DUMPS DONE: {_dumps} dumps, {_parked} parked frames, {_n} bytes -> {_dump_path}")
os.unlink(_dump_path)   # shadow review: mkstemp files were never cleaned up
