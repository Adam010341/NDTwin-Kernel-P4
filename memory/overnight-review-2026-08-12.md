---
name: overnight-review-2026-08-12
description: "2026-08-12/13 所有實測紀錄的位置索引：兩輪 live＋複驗輪＋5 靜態 agent＋研究報告＋測試總歸檔；18 個 commit（034da18..3794ac1）"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 8633678c-0827-493c-8d55-882f82ee6c9f
  modified: 2026-08-27T14:01:41.563Z
---

**入口：`doc/audit/2026-08-12_overnight-review/INDEX.md`** ——
發現彙整、修復表、給 Adam 的早晨清單、live 複驗清單都在裡面，先讀它。

同資料夾的分檔（都是邊做邊寫的一手紀錄）：

- `A-live-runbook.md`（718 行）— P4/bmv2 全輪：failover 16.63s 自癒 hitless、
  949fcba/32afeb9 live 驗證、**readopt 清表缺陷的發現與 s6 對照組**
- `C-live-ovs-runbook.md`（1057 行）— OVS/Ryu 全輪：**單向斷鏈 P0 的完整實驗**（Phase 3D）、
  52.42s failover 對照、htb 被 root netem 替換的發現、電源輪 sFlow 遺失 P1
- `B1-commit-review.md` — 16 commits 全審零 P0/P1；Python 385→517 帳目溯源
- `B2-doc-rot.md` — 文件腐爛掃描；port 佈局證實（kernel 8000/proxy 8081/Ryu 8080）
- `B3-test-mutation.md` — 7/7 mutant；LiveSwitchTest 逃逸事故的第一手申報
- `B4-runbook-vs-code.md` — runbook §6h 三個 P0 的定位；乾淨面清單（不用重查的項目）
- `S-slide-review.md` — slide template 的 69-commit 差距、A2 裁定表 +9 條建議
- `RESEARCH-PROMPT-advanced-testing.md` — 進階測試研究 session 的 prompt（**已跑完**，報告見下）
- `W2-live-reverify.md` — **2026-08-13 下午的複驗輪**：readopt gate 成立、P4 側單向故障
  12.5s 自癒、bmv2 非 primary 清表**坐實**、L5 首次實戰、**`/p4/switch_state` 的 P1**（§6.2）
- `DRAFT-message-to-patty.md` — 給 patty 的信草稿（中英各一版）＋合併紅線
- `T-w2-tools.md` — twin 測謊器與 L5 harness 的實作報告（含 11 項「需 live 確認」清單）

**同層目錄的另外兩份**（不在 Overnight 資料夾底下）：
- `~/Documents/NDTwin documentation/TESTING-INVENTORY.md` — **Adam 指定的測試總歸檔**，
  報告時回答「你做了哪些測試」用；一頁摘要可直接當投影片
- `doc/audit/2026-08-13_advanced-testing-research/REPORT.md` —
  684 行：故障模型目錄、bmv2 天花板、11 個外部工具的取捨理由

修復輪 7 commit（`034da18..d2a609a`）＋下午的測試基礎建設 11 commit（`d2a609a..3794ac1`），皆已 push `p4`：Ryu 單向黑洞、LiveSwitchTest 硬 gate、
readopt mastership/routes 雙防護、curl helper 捆綁旗標、文件批次、wedge 防呆＋qdisc 快照工具。

相關：[[ndtwin-current-state]]（當前狀態）、[[live-runs-find-what-tests-cannot]]、
[[ryu-flow-stats-wedge]]、[[destructive-shell-traps]]。
