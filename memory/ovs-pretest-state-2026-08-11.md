---
name: ovs-pretest-state-2026-08-11
description: "Status of Adam's 3-part pre-Phase-7 plan (my OVS pass, his manual pass, deepseek-agent traffic test) as of 2026-08-11"
metadata: 
  node_type: memory
  type: project
  originSessionId: 354194c4-0718-4137-b4b9-524e1ee1af6d
  modified: 2026-08-11T05:00:26.549Z
---

Before starting Phase 7 (power management), Adam's plan was three parts: I run the OVS runbook once, he runs it manually once himself, and deepseek-agent generates traffic via Mininet and checks the API for anomalies.

**Done as of 2026-08-11** (branch `fix/flow-rate-divide-by-zero`, commits `5639e65`..`2bec2a5`, pushed to `p4` remote):
- Full `doc/2026-08-10_ovs_manual_test_runbook.md` §1–§7 pass, first real run (previously written from source with the P4 stack running, never executed). Filled every TO BE MEASURED, corrected 5 wrong predictions (host/edge learning, flow count for `iperf -u`, IP encoding, `pgrep` anchoring, wrong link chosen for the failover test).
- Rate-accuracy ladder (5j i.e. §5i): twin's estimate is accurate to ±2% at 25-50 Mbit/s, but a single low-rate read can be off by 4x — it's a computable sampling-floor artifact (sampling_rate × packet_size × 8), not noise.
- 200 Mbit/s aggregate load + break-under-load: clean, only the rerouted flow lost packets (2.7%), everything else 0%.
- deepseek-agent third-party cross-check (network block from earlier in the session cleared; see [[reproducible-is-not-mechanism]]): found one genuinely new, more severe issue — at very low packet rates (5 pkt/s ICMP), a flow's *existence* in `get_detected_flow_data` and in `get_num_of_flows_passing_a_switch` flickers, not just its rate reading. Documented as runbook §5j. Matters directly for Phase 7 if it ever uses flow presence as an idle signal.

**Still outstanding**: Adam's own manual pass through the runbook has not happened yet. Don't treat OVS as fully re-validated until that's done — my pass and the agent's are both automated/scripted and share blind spots neither would catch (see [[reproducible-is-not-mechanism]] for a case where two independent automated re-runs agreed on a wrong theory).

**How to apply**: if a future session asks "is OVS ready for Phase 7 to build on," the answer is "mostly, pending Adam's manual pass" — not an unqualified yes.

**2026-08-18 更新：Adam 的手動輪次仍然沒發生**（他改成叫我跑、再交給 subagent），
所以上面那句「pending Adam's manual pass」**依然成立，不要當成已完成**。

但這條記憶的核心主張拿到了實測校正。當天跑了**兩輪互相獨立的自動化掃描**
（我四輪 + 一個全新、未被告知任何發現的 Claude subagent 一輪）：8 條 vs 18 條，
**重疊只有一條**。

所以原文「both automated/scripted and **share** blind spots」要修正為：
**它們不是共享盲點，是各有各的盲點。** 兩輪自動化不會收斂到同一組答案，
而這代表「跑過 N 輪 = 找完了」在任何 N 都不成立。人工輪次的價值仍在
（第三種盲點），但理由不是「自動化都看不到同一塊」。

詳見 [[live-round-2026-08-18-two-passes]]。
