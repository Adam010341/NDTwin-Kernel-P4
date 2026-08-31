---
name: single-flow-precision-gap
description: ✅ proxy 側已接通並 live 驗證（08-24，P2-5）：5-tuple 規則裝得上、priority 讀回 101、壓過 LPM 但不擴大它、counter 真實。TE 仍只送 ipv4_dst ⇒ 措辭上限「P4 側已通、端到端待 TE」
metadata: 
  node_type: memory
  type: project
  originSessionId: 56cc1a30-fc20-4847-97f3-176033806b7e
  modified: 2026-08-22T03:55:28.190Z
---

2026-08-19 順著 Adam 問「為什麼 bmv2 不支援 5-tuple 下發」查出來的。答案跟問題的預設相反：
**bmv2 和 P4 pipeline 完全支援，斷點在控制路徑，而且不只斷一處。**

## ✅ 2026-08-24 更新：proxy 這一層已經接通了（P2-5 完成）

commits `29f8456`→`e5931fa`（分五步：翻譯層、P4Runtime ternary 寫入、install/delete/modify 路由決策、
counter 回讀、live 證明）。**live 驗證在真 bmv2 上四項全過**
（`doc/audit/2026-08-24_five-tuple-live/REPORT.md`）：

| 宣稱 | 證據 |
|---|---|
| 規則裝得上、四個 match 欄位都在 | `prio=101 match={nw_dst,nw_proto,tp_dst,dl_type} -> OUTPUT:2` |
| **priority 不再被丟掉** | 讀回 **101**＝OpenFlow 100 經 +1 位移（原始 bug 是「讀回 0」） |
| **壓過 LPM 但不擴大它** | 同目的地的 LPM 條目仍在、仍走自己的 port，各自帶流量：規則 pkts=3（＝h1 tx delta 3）、LPM pkts=2 |
| 刪得掉且刪對條目 | 表回到 4 條 baseline |

🔑 **順手抓到並修好一個自己的 bug**：counter 一開始全讀 0——`read_table_entries` 從來沒有
**請求** counter_data（P4Runtime 要在 request 裡帶一個 present 的 counter_data 才會回）。
單元測試抓不到，因為它們**餵給 renderer 一個 counters dict 再斷言它活著**＝測了 switch 以下、
沒測 switch 以上。**「測試自己提供了它要驗證傳輸的那份資料」就看不見來源根本沒送**。

⚠️ 仍然成立的限制：**TE app 自己還是只送 `ipv4_dst`**（跨 repo，本輪明令不動）。
所以措辭上限維持「**P4 側已通、端到端待 TE**」，不能宣稱 per-flow TE 已經端到端。

## 三層狀態（下表的 proxy 列已過時，見上）

| 層 | 狀態 |
|---|---|
| bmv2 | 支援 |
| **P4 pipeline** | **有** `table flow_5tuple`（ternary，key = ingress_port + src/dst IP + protocol + L4 src/dst port），而且**已接進 pipeline 且排在 LPM 之前**：`if (!flow_5tuple.apply().hit) { ipv4_lpm.apply(); }`（`p4_proxy/p4_src/ndtwin_switch.p4:307`, ~369）。Phase 4 就做好了 |
| **proxy 寫入路徑** | **未接**。`HONOURED_MATCH_FIELDS = frozenset({"nw_dst", "ipv4_dst"})`（`topology_manager.py:97`），`route_flow` 只寫 `ipv4_lpm` |
| **TE app 自己** | **也沒送 5-tuple**。實際 payload 是 `{"eth_type": 2048, "ipv4_dst": ...}`，而且程式碼上面掛著 `# TODO: Change to match 5-tuple in HPE`（`Traffic-engineering-App.py:331`） |

## 為什麼 proxy 的「拒絕」是修法不是缺陷

`topology_manager.py:20-29` 記著：以前 proxy **會接受** 5-tuple 規則，然後默默裝成一條
「目的位址 → port N」的 LPM 規則並回 200。**實測驗證過**：規則生效、流量改走新 port，
**但套用到所有送往該目的地的流量，而且 priority 讀回 0 不是 100**。
一條瞄準單一流的 TE 規則，靜靜變成整個目的地的規則。

原則寫在同一段：「P4 真的無法 honour 某個語意時，proxy 回明確錯誤讓 kernel 記錄——
絕不靜默成功」。註解自己標了下一步：wiring `route_flow` → `flow_5tuple` 是 Phase 3 work。

## 🔑 對報告的意義

**「per-flow TE」目前不能宣稱，而且原因不在 P4。** 就算 proxy 明天接上 5-tuple，
TE 還是只送目的位址——所以 **OVS 上也一樣**，這不是 P4 專有的限制。
TE 的註解寫 `Migrate, install specific flow rule`、`Only migrate one flow per iteration`，
但它裝的規則影響往該目的地的所有流量。

**⚠️ 2026-08-22 裁定更新（取代下一行的 08-19 裁定）：Adam 改令 8/27 前做 proxy 側**——
工單已發 mainDev v2（P2 位、犧牲順序第一讓）：`route_flow` 接上 `flow_5tuple`（含刪改、
per-table counter 回讀、測試＋突變、live 證明一條 5-tuple 規則真的蓋過 LPM）；
**TE repo 仍不動**（跨 repo 規則），措辭上限＝「P4 側已通、端到端待 TE」。
08-22 fresh 驗證：`flow_5tuple` 表在 `ndtwin_switch.p4:307` 如本檔所述；proxy 的大聲拒絕
已有測試釘住（`p4_proxy/tests/test_unsupported_match.py:44`「silently narrowed is now named」）。

**2026-08-19 Adam 裁定：報告後再修。** 安全，因為三層一致——沒有消費端今天需要它，
而且現況是誠實回 400 而不是靜默降級。建議措辭見 phase-2 討論。

⚠️ 別跟 [[replace-vs-add-bug-shape]] 第 32-39 行那條混淆：那條講的是
TE 的 `priority`/`idle_timeout` 被 P4 `route_flow` 忽略、以及 `ipv4_lpm` 每個目的地只有一筆，
已經裁定「不要再歸進那族」。**本條講的是 TE 送出去的 match 欄位本身**，是不同的斷點。

TE 是別人的 repo（[[cross-repo-component-ecosystem]]）——只測不改。

相關：[[phase2-round-2026-08-19]]、[[ntg-bmv2-support-pending-feature]]。

## 🏁 08-30 更正：`install_flow_entry` 的 priority 不是「被丟掉」，是那張表沒有這一欄

正本 `doc/audit/2026-08-30_live-traffic-round/FINDING-07_*.md`（`ec515ce`）。兩個錨點我親自複讀：
- `p4_proxy/p4_src/ndtwin_switch.p4:329-345`＝`flow_5tuple` 六欄**全 ternary**、
  `default_action = NoAction(); // fall through to ipv4_lpm`；
  `:350-352`＝`ipv4_lpm` 只有 `hdr.ipv4.dstAddr: lpm`。**P4 的 LPM 表沒有 priority**，
  同 dst 家族的次序＝prefix length。
- `p4_proxy/proxy_agent/api_routes.py:204-214`（`add_flow_entry` docstring）明寫
  「priority … **is still ignored for the destination-only path**」。

⇒ dst-only 的規則全走 `ipv4_lpm`，回讀到的 `priority: 0` **不是被丟棄的 915，是欄位不存在的預設值**。
🔴 **「兩條規則 match 同一包無定義次序」已撤回**——次序是確定性的、**沒有封包被轉錯**。
剩下的是**API 契約缺陷**：端點收下 priority、把規則送到用不到它的表、回 success 卻不說。
🔑 這正是第一版自己標成「另一種修法完全不同」的那一支——**把互斥的兩支都寫進 not-established，
   後來證明是省下整輪的關鍵**（否則會照「轉發壞掉」去修）。
