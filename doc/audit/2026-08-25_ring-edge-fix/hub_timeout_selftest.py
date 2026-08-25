# Does hub.Timeout actually interrupt the exact primitive the ring parks in?
# The wedge parks in app_manager.py:279 `req.reply_q.get()` on a hub.Queue that nobody will
# ever put to. Assert the interrupt on THAT, not on a sleep.
from ryu.lib import hub
import time

# 1. the parking spot itself: an empty Queue nobody feeds
q = hub.Queue()
t0 = time.time()
try:
    with hub.Timeout(1.0):
        q.get()                      # would block forever
    raise AssertionError("Timeout did not fire")
except hub.Timeout:
    dt = time.time() - t0
    assert 0.9 < dt < 1.6, f"fired at {dt:.2f}s, expected ~1.0"
    print(f"PASS reply_q.get() interrupted at {dt:.2f}s")

# 2. the semaphore-acquire spot (app_manager.py:302), where a full queue blocks the emitter
sem = hub.BoundedSemaphore(1); sem.acquire()
t0 = time.time()
try:
    with hub.Timeout(1.0):
        sem.acquire()                # would block forever
    raise AssertionError("Timeout did not fire")
except hub.Timeout:
    dt = time.time() - t0
    assert 0.9 < dt < 1.6, f"fired at {dt:.2f}s"
    print(f"PASS _events_sem.acquire() interrupted at {dt:.2f}s")

# 3. the accept path must still work -- a timeout that also breaks the success case is worse
q2 = hub.Queue()
hub.spawn(lambda: q2.put("answer"))
with hub.Timeout(2.0):
    got = q2.get()
assert got == "answer", got
print("PASS the non-timeout path still returns the value")

# 4. min(budget, per-call) is what actually bounds it
t0 = time.time()
try:
    with hub.Timeout(min(0.3, 5.0)):
        hub.Queue().get()
except hub.Timeout:
    dt = time.time() - t0
    assert dt < 0.8, f"budget clamp did not apply: {dt:.2f}s"
    print(f"PASS remaining-budget clamp bounds the call at {dt:.2f}s")

print("\nALL PASS")
