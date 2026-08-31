---
name: replace-vs-add-bug-shape
description: "Recurring NDTwin bug shape, seven instances: something that should replace a snapshot is implemented so it can only add. Ask every ingest when its old data disappears"
metadata:
  node_type: project
  type: project
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-27T14:04:54.167Z
---

**One question finds all seven: "when does the old data disappear?"** A snapshot that should replace state is written so it can only add to it, and the symptom is always the twin answering from something that no longer exists.

Seven instances found in this repo:

1. `TopologyAndFlowMonitor::run()` took the topology once at startup — 88 ms from entry to exit — and never re-read it. The whole graph was whatever Ryu knew in that instant. Fixed by periodic polling (`71d27c1`).
2. `Classifier::updateFromQueriedTables` skipped an empty flow array, so rules that had disappeared from a switch were never swept (`820c2a2`).
3. `setAllPaths` filled two maps with `operator[]` and never cleared them, so `get_path_switch_count` kept answering from a route a link failure had removed (`eb9c860`).
4. `Answer::from_json` appends to `tasks` without clearing it — **not yet fixed**, found by the C++ test pass.
5. **A two-sided variant, and the first one I shipped myself.** The P4 proxy's link watchdog reported a failure, the kernel set the edge down, and `updateLinks` on the next topology poll set it straight back up — because `updateLinks` has *no* path that sets `isUp`/`isEnabled` false and the proxy had no `remove_edge`. Neither half can remove anything; together they can never take a link down. Fixed by withholding the link from the reply (`down_link_endpoints`) — the reply has no way to *say* "down", so silence is the only available contradiction. It had a second half I missed at first: `render_destination_paths` still computed over the full graph, so the same pass that reported the failure handed the kernel paths across it, and `m_switchCountMap` is filled from there rather than from the poll.
6. `disableSwitchAndEdges` (the Intent Translator's `DisableSwitch`) clears only `isEnabled`, and `updateSwitches`/`updateLinks` set `isUp = true; isEnabled = true;` unconditionally for everything the poll reports — so an operator's disable is undone on the next poll, silently. Nothing in `VertexProperties`/`EdgeProperties` can record administrative intent, so the poll has nothing to respect. **The poll interval is 5 s for the process's first 90 s, then 30 s forever** (`TopologyAndFlowMonitor.cpp:1793-1795`) — not 1 s; the 1 s at :1798 is a sleep slice so `stop()` need not wait out a whole interval, and I misread it as the interval in three documents before checking. **Not fixed:** the fix is a design decision that changes `/ndt/get_graph_data` semantics, i.e. a contract with 7 downstream apps. See `doc/audit/2026-08-10_tfm-spec-unknown-adjudication.md`.

7. **`intelligent_router.py` 的路由安裝：完全沒有任何刪除路徑**（零 `OFPFC_DELETE`／`del_flow`），
   而 `add_flow` 不設 `idle_timeout`／`hard_timeout` → 規則永久，只會被同 match+priority 覆蓋。
   **安裝走訪沒走到的 switch，舊規則無限期留著。** 兩條路徑，原本記錄的那條反而比較難達成：
   (A) BFS 走不到——實測本拓撲 20 條無向鏈路、最小度數 3，**斷 1 或 2 條永遠不分割**，
   要 3 條同時斷、且只有 4 種組合；(B) **switch 掉線重連完全不會重算**——
   `_schedule_route_reinstall` 只在鏈路 up/down 呼叫，重連處理器只 POST 通知 kernel。
   電源開關會連帶產生鏈路事件而順帶蓋掉 (B)，**沒被蓋到的是「資料面正常但控制連線斷掉」**。
   **未修**，而且修法不明顯安全：單向故障時資料面可能仍然能從 BFS 已經不信任的那個 port 正常轉發，
   刪掉規則會把「還能走的單向路徑」變成 table miss。（2026-08-13 查證，`cfbbf24`）

**Not an eighth instance (2026-08-17):** TE's `priority`/`idle_timeout` being ignored by the P4
`route_flow` was filed under this family and then reviewed properly. It is a different shape.
`ipv4_lpm` holds **one entry per destination**, so a TE migration *replaces* the destination's
only entry rather than accumulating alongside it — and `install_initial_routes` rewrites every
(switch, host) entry on any link transition, so the migration is *clobbered by an unrelated
event* rather than outliving its welcome. Also, no producer asks for ageing at all: TE's live
path sends no `idle_timeout` key and its disabled path sends 0, which the kernel omits. Full
correction in `doc/2026-08-16_src-ip-endianness-review.md`. Do not re-file it here.

**The inverse family now has its own memory:** [[rejected-requests-can-still-act]] — a write that
happens while the API reports it was rejected. Same question asked from the other end.

**Why:** the shape is invisible at the call site. Each of these is correct the first time it runs, and every one of them ran exactly once for most of the project's life — the defect only appears on the *second* call, which is why adding a refresh loop is what exposed it.

**How to apply:** treat it as a class, not four incidents. When reviewing any code that ingests external state, ask what removes the previous version. Note the answer is **not** uniformly "apply the empty snapshot": `Classifier` should (an empty array arriving with a dpid is a definite statement about that switch) while `setAllPaths` should not (an empty path list before the control plane converges is transient, and an HTTP push calls it unconditionally). And an empty snapshot that arrives *slowly* may be a timeout rather than a fact — see [[ryu-flow-stats-wedge]].
