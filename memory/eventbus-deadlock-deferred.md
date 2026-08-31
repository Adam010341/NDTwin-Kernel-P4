---
name: eventbus-deadlock-deferred
description: "RESOLVED — EventBus::emit()'s lock-upgrade deadlock was fixed in 1a7875b exactly as designed; the bus still has zero production subscribers"
metadata: 
  node_type: memory
  type: project
  originSessionId: 354194c4-0718-4137-b4b9-524e1ee1af6d
  modified: 2026-08-11T11:35:59.087Z
---

**Status as of 2026-08-11: fixed. This memory is kept because the *shape* is worth remembering, not because there is anything left to do.**

`EventBus::emit()` used to hold a `std::shared_lock` while synchronously invoking each handler, so a handler calling `registerHandler()` (wants `unique_lock`) was a guaranteed same-thread self-deadlock, and a nested `emit()` was a real risk under writer contention. Deliberately deferred in July 2026 because the bus had zero subscribers, making the deadlock unreachable.

Commit `1a7875b` ("Phase 6 prerequisite: make EventBus::emit() safe to re-enter") applied **exactly the fix that was agreed back then**: copy the handler vector for the event type under the `shared_lock`, release it, then invoke from the copy. `include/event_system/EventBus.hpp` now reads that way. `tests/test_EventBus.cpp` covers it, including the nested-`registerHandler` case that was the guaranteed deadlock and a concurrent emit/register case.

**Still true, and still worth knowing**: `registerHandler()` is called only from `tests/test_EventBus.cpp` — there are **no production subscribers**. The whole pub/sub system is constructed and threaded through `TopologyAndFlowMonitor`, `HttpSession`, `FlowLinkUsageCollector`, `FlowRoutingManager` and `ControllerAndOtherEventHandler`, and `emit()` is called for `LinkFailureDetected` in `HttpSession::handleLinkFailure`, but nothing listens. So those `emit()` calls are still no-ops in production.

**How to apply**: do not re-report the deadlock — it is fixed and tested. Do note, when reading code that emits events, that emitting currently reaches nobody: see [[existence-is-not-wiring]], of which this is the largest live example in the repo. If a future phase adds the first real subscriber, that is when `emit()`'s behaviour starts mattering.

**The archiving lesson**: this memory sat stale for an unknown period. I only caught it because I grepped `registerHandler` for an unrelated reason and saw a test comment saying "before the fix". A memory asserting "X is deferred / not yet done" decays silently — the world moves and nothing tells the memory. Re-verify deferral memories against the code before relying on them.
