# Ticket — `/ndt/acquire_lock`: three defects, one of them live

Opened 2026-08-29 by `開機手冊`, on `8/29 auditor`'s ruling. All three are in
`src/ndt_core/http/HttpSession.cpp::handleAcquireLock`. Written as three items because they have
three different fixes and three different blast radii.

**Provenance note.** This ticket exists because a finding I published was wrong. I reported
*"`lockName` does not namespace — every name maps to one global `routing_lock`"*. That was a
misdiagnosis of my own harness's bug (it sent `lockName`; the handler reads `type`). The
auditor read the code and corrected me. The three defects below are what is actually there.

---

## L-1 🔴 A malformed body still acquires the lock

```cpp
try {
    auto jsonBody = json::parse(m_req.body());
    lockType = jsonBody.value("type", LockManager::DEFAULT_LOCK_TYPE_STR);
    ttl      = jsonBody.value("ttl",  LockManager::DEFAULT_TTL_SECONDS);
}
catch (...) {
    // Keep default values if JSON parsing fails      <-- :1928-1931
}
bool success = m_lockManager->acquireLock(lockType, ttl);   // <-- reached anyway
```

The `catch` swallows the parse failure and execution falls straight through to `acquireLock`
with the defaults. **Verified live**, judging on state rather than the response:

```
0. baseline routing_lock free?  -> True
1. POST body "{this is not json"
   response                     -> {'status': 'locked', 'ttl': 5, 'type': 'routing_lock'}
2. second client can acquire?   -> False       <- the malformed request really holds it
```

⇒ **An unparseable request takes the lock that real routing operations take.** This is
`rejected-requests-can-still-act`, eighth instance in this codebase, and it is exactly what
`01`'s **H5 (malformed lock body)** was written to probe — the probe was right, the harness
just never got there.

**Fix:** a body that fails to parse is a 400. Defaults are for *absent* fields, not for
*unreadable* ones — the two are different requests and only one of them is well-formed.

## L-2 A missing `type` is silently substituted

`:1925` — `jsonBody.value("type", DEFAULT_LOCK_TYPE_STR)` — and
`LockManager.hpp:27` sets that default to **`routing_lock`**.

Only three lock types exist (`routing_lock`, `graph_lock`, `power_lock`) and **all three are
real**; there is no scratch lock. So a caller who omits `type`, or who sends the field under
some other name, does not get a harmless default — they get the busiest real lock in the
system, and nothing in the response distinguishes "the lock you asked for" from "the lock we
picked for you".

This is how the harness spent its whole life holding `routing_lock` while believing it held
something private.

**Fix:** either require `type` explicitly, or echo loudly enough that a substitution is visible.
The response *does* carry `"type"` — which is exactly the field I failed to read, so echoing
alone is evidently not sufficient.

## L-3 The error string conflates two causes, and reports the substituted value

`:1946` — `"System busy or invalid lock type: " + lockType`.

Two distinct conditions (**busy** vs **invalid type**) share one message, and the value printed
is the *post-substitution* `lockType`, not what the caller sent. So a client that sent an
unreadable or absent type and lost a race is told:

```
System busy or invalid lock type: routing_lock
```

`routing_lock` is perfectly valid. It was merely busy. And it is not what they asked for.
`instrument-must-not-mimic-its-own-finding`: the diagnostic points at the wrong thing in both
of its halves.

**Fix:** separate the two conditions, and report the caller's input alongside whatever was
substituted.

---

## Scope note

`isValidType` / `stringToLockType` (`LockManager.hpp:38-43`, `:65-68`) are **correct** — an
unknown name returns `Unknown` and the acquire is refused. The bug is not in the lock manager;
it is in the HTTP layer deciding what to hand it. Verified from both directions: sending
`{"type":"power_lock"}` now returns `power_lock`, where every earlier call returned
`routing_lock` regardless of what was asked for.

[Co-developed with claude code -- Adam]
