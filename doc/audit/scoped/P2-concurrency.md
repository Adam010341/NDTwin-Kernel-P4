# P2 — new concurrency and lifecycle code

Scope: `be3c242..576dd2a` only. Worktree `/tmp/audit-576dd2a`.

[Co-developed with claude code -- Adam]

---

### The route-reinstall debounce drops every topology change that arrives while a reinstall is running

- **File:line** — `intelligent_router.py:108` (`_schedule_route_reinstall`) and
  `intelligent_router.py:125` (`_route_reinstall_worker`), `2c81b26`
- **Severity** — **high**. Inside a window equal to the duration of `install_all_pair_paths`, this
  is the *same* defect `2c81b26` was written to fix: a link fails, the graph is updated, and no
  rule is ever recomputed. Silent — the log says "route reinstall done" and means the previous
  change.
- **Confidence** — verified (by simulation of the exact scheduler; see below)
- **How I checked** — `reinstall_worker_running` is set before `hub.spawn` and cleared only in the
  worker's `finally`, so it stays `True` for the whole of `install_all_pair_paths`. But the worker
  leaves its quiet-period loop *before* that call:

  ```python
  while True:
      seen = self.topology_change_seq
      hub.sleep(reinstall_quiet_period)
      if self.topology_change_seq == seen:
          break                                    # <- stops watching seq here
  ...
  self.install_all_pair_paths(self._active_net())  # <- ~60s; seq changes here are unobserved
  ```

  A change during that call increments `topology_change_seq`, hits
  `if self.reinstall_worker_running: return`, and is never acted on.

  I copied both methods verbatim into a deterministic cooperative scheduler
  (`scratchpad/probe_debounce.py`, hub.sleep and install\_all\_pair\_paths replaced by simulated
  time — Ryu's hub is cooperative, so a single-threaded event loop is faithful):

  ```
  === paired events from one operator action (install takes 60s) ===
    t=   0.0  scheduled: link 1->5 down (seq=1)
    t=   0.1  scheduled: link 5->1 down (seq=2)   -> worker already running, returning
    t=   6.0    -> install_all_pair_paths STARTS
    t=  66.0    -> install_all_pair_paths ENDS
    LAST EVENT (t=0.05) COVERED BY A LATER RECOMPUTE: True        # the intended case works

  === second link fails during the recompute (install takes 60s) ===
    t=   6.0    -> install_all_pair_paths STARTS
    t=  10.0  scheduled: link 2->6 down (seq=3)   -> worker already running, returning
    t=  10.1  scheduled: link 6->2 down (seq=4)   -> worker already running, returning
    t=  66.0    -> install_all_pair_paths ENDS
    events scheduled : 4
    recomputes run   : 1
    LAST EVENT (t=10.05) COVERED BY A LATER RECOMPUTE: False      # <- lost
  ```

  60 s is not a worst case picked to make the point: the file's own comment says the walk covers
  "16256 of them on the 128-host topology", and `doc/HANDOFF.md` §1g records the startup install as
  taking about that long.
- **Failure scenario** — `link s1 s5 down`, then `link s2 s6 down` eight seconds later (a switch
  rebooting, a cable pulled from a shelf, or simply an operator testing two failures in a row).
  The first pair triggers a recompute at t≈6 s. The second pair arrives at t≈8 s, during it. The
  graph loses both edges (`remove_edge` runs synchronously in the handler), so Ryu's view is
  correct, but the flow rules covering the second link are never recomputed for the life of the
  process. Traffic across s2↔s6 black-holes indefinitely, and the twin will report the edge down
  while ingress counters keep rising — the exact "black-hole flow" shape §1g's third row calls a
  twin capability that does not exist yet.
- **Suggested fix** — capture the sequence number at the moment the recompute starts and re-check
  it in the `finally`; if it moved, loop back into the quiet period rather than exiting:

  ```python
  while True:
      while True:
          seen = self.topology_change_seq
          hub.sleep(reinstall_quiet_period)
          if self.topology_change_seq == seen:
              break
      ...
      started_at_seq = self.topology_change_seq
      self.install_all_pair_paths(self._active_net())
      if self.topology_change_seq == started_at_seq:
          break                       # nothing arrived while we worked
  ```

  with `reinstall_worker_running = False` still in the outer `finally`. That keeps the single-worker
  guarantee and makes "a change arrived while I was working" mean "go round again" instead of
  "discard".

---

### In static-topology mode the initial install and a reinstall can run concurrently, and the loser's routes win

- **File:line** — `intelligent_router.py:356-357` (static path) vs `intelligent_router.py:284-285`
  (dynamic path); the reinstall worker's guard is at `intelligent_router.py:135`. `2c81b26`
- **Severity** — medium. Nondeterministic final routing state and a nondeterministic
  `all_destination_paths` served to the kernel.
- **Confidence** — probable (verified by reading; I have no Ryu here to run it)
- **How I checked** — the two startup paths set the completion flag in opposite orders:

  ```python
  # static (intelligent_router.py:356), the mode the manual documents
  self.install_initial_openflow_entries_completed = True
  self.install_all_pair_paths(self.static_net)

  # dynamic (intelligent_router.py:284)
  self.install_all_pair_paths(self.dynamic_net)
  self.install_initial_openflow_entries_completed = True
  ```

  The worker's guard is `if not self.install_initial_openflow_entries_completed: return`, whose
  comment says "the initial install has not run yet and will cover the current graph when it does."
  In the dynamic ordering that is true. In the static ordering the flag is `True` for the whole
  ~60 s of the initial walk, so a link event during it passes the guard and calls
  `install_all_pair_paths` a second time, concurrently. `hub` is cooperative, so the two greenlets
  interleave at every socket send rather than corrupting memory — but each has its own local
  `all_destination_paths` list, assigned to `self.all_destination_paths` at
  `intelligent_router.py:595` when it finishes, and each issues `OFPFC_ADD` for the same
  (switch, ipv4\_dst) with the same priority. Per the brief's stated OpenFlow 1.3 semantics, an
  identical match+priority `OFPFC_ADD` overwrites, so **whichever walk finishes last wins**, and
  the one that started first is the one using the pre-failure graph.
- **Failure scenario** — a link fails ~55 s after Ryu starts, while the initial install is still
  running. The reinstall greenlet wakes 3 s later, sees the flag `True`, and starts a second walk
  from the post-failure graph. The initial walk (pre-failure graph) finishes after it and reinstates
  rules pointing at the dead link, and overwrites `self.all_destination_paths` with the stale list —
  which the kernel then pulls through `/ryu_server/all_destination_paths` into `setAllPaths`, so
  `get_path_switch_count` answers from the stale topology too. Nothing logs a conflict.
- **Suggested fix** — set `install_initial_openflow_entries_completed = True` *after* the call in
  the static path, matching the dynamic one. That closes this window and is a one-line move. If
  concurrent walks are ever wanted deliberately, the guard needs to be a real lock
  (`hub.Semaphore`) around `install_all_pair_paths` rather than a bool set at spawn time.

---

### `on_link_delete` now depends on a `requests.post` with no timeout before it touches the graph

- **File:line** — `intelligent_router.py:701` (the POST) and `:706-715` (the new work after it),
  `2c81b26`
- **Severity** — low-to-medium. A pre-existing unbounded call now gates new, important work.
- **Confidence** — probable
- **How I checked** — `requests.post(api_url, json=data, headers=headers)` has no `timeout=`, so it
  blocks until the peer responds or the socket errors. Before this diff the handler ended there,
  so a hang cost only a notification. The edge removal and `_schedule_route_reinstall` were added
  *below* it, so they now inherit the same fate. A refused connection returns immediately
  (`ECONNREFUSED` on loopback), which is the common case — but `doc/HANDOFF.md` §1j documents a
  wedged kernel holding `:8000` biting three times. A process that accepts the connection and does
  not answer produces an indefinite block, not an exception, so the `except` clause does not help.
- **Failure scenario** — a hung kernel still listening on `:8000`. `link s1 s5 down` fires the
  handler, `requests.post` blocks, and the edge is never removed from the routing graph and no
  reinstall is ever scheduled — i.e. the pre-`2c81b26` behaviour, silently, with the greenlet
  parked.
- **Suggested fix** — `timeout=(2, 5)` on both notification POSTs, or move the graph mutation and
  `_schedule_route_reinstall(...)` above the notification. The second is better on its own merits:
  the local graph is this app's own state and should not be conditional on a remote call at all.

---

### `refreshDestinationPathsPeriodically` deep-copies the whole path map once a minute to ask whether it is empty

- **File:line** — `src/ndt_core/collection/FlowLinkUsageCollector.cpp:429`, `0596dd1`
- **Severity** — low
- **Confidence** — verified (by reading; the cost is arithmetic, not a hypothesis)
- **How I checked** — `const bool haveAny = !getAllPaths().empty();`, and `getAllPaths()` returns
  `m_allPathMap` **by value** under `m_allPathMapMutex` (`FlowLinkUsageCollector.cpp:1990`). On the
  128-host topology that map holds one `sflow::Path` per ordered host pair — the Ryu app's own
  comment says 16256 — each a vector of hops. The copy is allocated, then immediately destroyed.
  It runs every 5 s while the map is empty and every 60 s afterwards, and it holds the shared lock
  for the duration, which blocks `setAllPaths` (a writer) for as long as the copy takes.
- **Failure scenario** — not a correctness bug; a periodic allocation spike and a writer stall
  proportional to the topology size. Mentioned because this loop is new in the range and because
  the last CPU-burn investigation (`doc/HANDOFF.md` §1) turned on exactly this kind of loop cost
  being invisible in the code.
- **Suggested fix** — add a tiny `bool hasAnyPaths() const` that takes the shared lock and returns
  `!m_allPathMap.empty()`. Three lines, and it removes the only reason this loop touches the map.

---

### `FlowDispatcher::stop()` called concurrently: the second caller returns before the workers stop

- **File:line** — `src/ndt_core/routing_management/FlowDispatcher.cpp:31`, `d5f5bfa`
- **Severity** — low (I could not find a caller that does this today)
- **Confidence** — verified as a property of the code; **not** shown to be reachable
- **How I checked** — `stop()` swaps `workers_` into a local under the lock and joins outside it.
  Two concurrent callers therefore split the set: the first takes all the threads and joins them,
  the second takes an empty map and returns immediately, while the workers are still running. The
  only callers today are the explicit `stop()` in tests and `~FlowDispatcher`, and `~Controller`
  runs once — so I am recording the shape, not claiming a live bug. `StopIsIdempotentBecauseThe
  DestructorCallsItToo` covers the *sequential* double-stop, which is the reachable one.
- **Suggested fix** — none needed unless a second call site appears; if one does, a `std::once_flag`
  or a `m_stopping` guard held across the join is the fix. Worth a line in the header saying stop()
  is idempotent but not concurrent-safe, since the current comment says only "Safe to call multiple
  times".

---

### `enqueue()` drops jobs silently while `HttpSession` still answers 200

- **File:line** — `src/ndt_core/routing_management/FlowDispatcher.cpp:52` and `:71` (the new
  `if (!running_) return;`), against `src/ndt_core/http/HttpSession.cpp:980`, `d5f5bfa`
- **Severity** — low, because I checked and it is not reachable outside shutdown
- **Confidence** — verified
- **How I checked** — the guard is the right fix for the unowned-thread fault, but it returns
  `void` with no log and no counter, and `processFlowBatch` reports `accepted = jobs.size()` and
  200 regardless. Before this diff a pre-`start()` enqueue was actually *delivered* (the worker's
  predicate `!running_ || !queues_[dpid].empty()` is satisfied by a non-empty queue, and the
  `break` only fires when the queue is empty), so this is a behaviour change. It is not reachable
  for the pre-start case: `Controller`'s constructor calls `dispatcher_.start()`
  (`Controller.cpp:70`) before any `HttpSession` exists. The post-stop case is reachable only
  during `~Controller`, i.e. process shutdown.
- **Suggested fix** — a one-line `SPDLOG_LOGGER_WARN` naming the dropped count would make the
  shutdown case observable and cost nothing. Not urgent.

---

## Checked and found sound

- **The two-mutex `scoped_lock` in `setAllPaths` cannot deadlock.** I enumerated every use of both
  mutexes (`grep -n "m_allPathMapMutex\|m_switchCountMapMutex"`): `setAllPaths` at
  `FlowLinkUsageCollector.cpp:1946` is the **only** site that takes both, so there is no second
  ordering to conflict with. Nor is there a cycle with the other locks in the class: no code path
  that holds `m_allPathMapMutex` or `m_switchCountMapMutex` acquires the graph mutex or
  `m_flowInfoTableMutex` while holding it — `setAllPaths`' body is two map assignments and a
  `SPDLOG_TRACE`, `getAllPaths`/`printAllPathMap`/`setAllPath` do nothing but touch the map. The
  `pathKnown` lambda at `:1428` is explicitly scoped so the graph-taking body below it runs
  unlocked, and its comment says exactly that. The unlocked `m_allPathMap.size()` in the DEBUG line
  at `:1981` is inside the `scoped_lock`'s scope.
- **`FlowDispatcher::stop()` drains rather than discards.** After `running_ = false`, a worker whose
  queue is non-empty does not `break` — it sends the remaining burst first and exits on the next
  pass. So queued jobs are delivered, not dropped, and `stop()` blocks until they are.
- **`enqueue` before `start()` is not reachable in production** — `Controller`'s constructor starts
  the dispatcher, and it is the only owner (`Controller.hpp:51`).
- **The `OpResult` chain is wired correctly and both directions are covered.** `Controller`'s sender
  assigns and inspects all three results; `OpResult::ok` defaults to `false`
  (`OpResult.hpp:22`), so a future unhandled `FlowOp` would log a failure rather than pass silently.
  Mutant M6 (`if (!result.ok)` → `if (false)`) is caught by two tests. I looked specifically for the
  reverse error — a success reported as a failure — and did not find one: the only `SPDLOG_ERROR`
  is inside `if (!result.ok)`, and `ASuccessfulDispatchReportsNothing` pins it.
- **`getFlowsArrayForDpid`'s new `json*` return does not dangle.** The pointer is taken *after*
  `m_cachedOpenFlowTables.push_back`, and each of `installOne`/`modifyOne`/`deleteOne` re-obtains it
  per entry, so a reallocation in a later iteration cannot invalidate an earlier pointer. The
  `nullptr` path is also unreachable in practice now, because `processFlowBatch` rejects unknown
  dpids with 404 before calling `updateOpenFlowTables` — `HttpSession.cpp:983` is its only caller.
