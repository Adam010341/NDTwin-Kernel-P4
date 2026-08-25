# Known-good-input check for the qsize/balance instrumentation.
# Build exactly what app_manager.py:160-161 builds, drive it into the BLOCKED state on purpose,
# and assert the two numbers the dump prints actually say "blocked".
from ryu.lib import hub

q = hub.Queue(4)                      # app_manager uses Queue(128)
sem = hub.BoundedSemaphore(q.maxsize)

def emit(i):
    sem.acquire()                     # app_manager._send_event
    q.put((i, None))

print("empty     :", q.qsize(), "/", q.maxsize, " balance =", getattr(sem, "balance", "MISSING"))

for i in range(4):                    # fill it exactly
    hub.spawn(emit, i)
hub.sleep(0.2)
print("full      :", q.qsize(), "/", q.maxsize, " balance =", getattr(sem, "balance", "MISSING"))

for i in range(3):                    # three more emitters must now BLOCK
    hub.spawn(emit, 100 + i)
hub.sleep(0.2)
bal = getattr(sem, "balance", None)
print("3 blocked :", q.qsize(), "/", q.maxsize, " balance =", bal)

assert q.qsize() == q.maxsize, "queue should be full"
assert isinstance(bal, int) and bal == -3, f"balance should be -3 (3 blocked emitters), got {bal!r}"

q.get(); sem.release()                # drain one -> one emitter proceeds
hub.sleep(0.2)
print("after 1 drain:", q.qsize(), "/", q.maxsize, " balance =", sem.balance)
assert sem.balance == -2, f"expected -2, got {sem.balance}"
print("\nPASS: qsize hits maxsize and balance counts blocked emitters exactly")
