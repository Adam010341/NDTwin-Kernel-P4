---
name: reproducible-is-not-mechanism
description: "A third-party agent's cross-endpoint finding reproduced 10/10 and was still wrong about why — verify the mechanism, not just the symptom"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 354194c4-0718-4137-b4b9-524e1ee1af6d
  modified: 2026-08-27T14:46:11.438Z
---

When a second agent (or my own script) reports a cross-endpoint contradiction and it reproduces cleanly across repeated samples, that only proves the symptom is real — it does not validate the inference about *why*. Reproducibility rules out transient noise, nothing more.

Concrete case (NDTwin-Kernel, 2026-08-11): deepseek-agent found `get_num_of_flows_passing_a_switch` disagreeing with `get_detected_flow_data` on 6 of 10 switches, and inferred "this endpoint excludes ICMP flows." The pattern fit that theory with unsettling precision — 10/10 switches matched a "count UDP only" recomputation. I re-ran it myself and got the identical 10/10 fit. Two independent reproductions of the same wrong theory.

It broke only when I stopped comparing aggregate endpoint output and read the underlying data structure directly (`edge.flow_set` on individual edges via `get_graph_data`) — the same ICMP flow was present on one hop of its path and absent on the next. No protocol filter produces that; a per-edge independent sampling process does. At 5 pkt/s with 1/256 sFlow sampling, the expected interval between samples per switch is 256/5 = 51.2s, so a ~50s observation window landing mostly empty is exactly what the math predicts — confirmed by watching two edges flicker in real time. The sibling finding is written into `doc/2026-08-10_ovs_manual_test_runbook.md` §5j.

**Why the 10/10 fit was misleading**: both "protocol exclusion" and "sampling floor at low rate" predict the same observable pattern when the only traffic below the floor happens to be the one ICMP flow in the test. The theories only diverge once you check a case that separates them — reading membership at the edge level, or varying the rate.

**How to apply**: when a finding (mine, another agent's, a subagent's) claims a mechanism, find the one measurement that would look different under a competing explanation before writing it up as confirmed. Preference order: read the primitive data structure the aggregate is built from, not just the aggregate; if there's a numeric relationship implied (sampling rate, timeout, threshold), compute what it predicts and check against a fresh measurement designed to test that specific number. Don't stop at "I reproduced it twice" — that defeats coincidence, not a wrong theory that predicts the same coincidence.

Related: [[investigation-briefs-separate-observation-from-inference]] (my own inference mislabeled as fact), [[test-independence-is-the-spec-not-the-model]] (a different agent encoding the same bug into its own verification), [[cited-line-numbers-are-not-evidence]] (a different flavor of "looked right, wasn't").

**2026-08-15 深夜:目前最典型的一例(clone cap 撤回案)。** 兩個 20 秒窗口各得 16 顆
clone、完美可重現 → 建立「取樣硬頂 ~0.8/s」整套理論、跨 session 仲裁、寫進報告。全錯:
`egress_port_counter[255]` 根本不數 clone(P4 egress 的 clone 分支在 count() 前 return,
**註解明寫**)——我量的是 LLDP punt 節奏(5s beacon)。翻案靠**三層獨立通道對同一事件**
(wire tcpdump 19.5/s+kernel 量子 5-7/s vs counter 0.44/s;離群層=誤認層),不是更多次
重複。升級版教訓:**先讀「增量發生的那一行」,再信任一個 counter 在數什麼**。
全程:`doc/2026-08-15_bmv2-performance-report.md` 撤回節,commit `0590e00`。
