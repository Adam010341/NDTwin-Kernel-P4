"""Exercise the SIGUSR2 greenlet dump the way a wedged Ryu would experience it:
eventlet monkeypatched, several greenlets PARKED (one blocked on a full bounded queue,
which is the exact shape the hypothesis predicts), main thread idle in the hub."""
import eventlet
eventlet.monkey_patch()
import os, sys, signal, time
sys.path.insert(0, "/home/adam/Desktop/NDTwin-Kernel")

os.environ["NDTWIN_RYU_GREENLET_DUMP"] = "/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/d2e2d151-039a-43b5-b79f-ef14684eabaa/scratchpad/gdump.txt"

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
print("DUMPS DONE")
