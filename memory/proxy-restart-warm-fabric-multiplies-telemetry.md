---
name: proxy-restart-warm-fabric-multiplies-telemetry
description: "clone replica 疊加:raw client 已重現(排除我方)、settle pair 修復已 live 驗證收斂單 replica;「proxy 重啟必連 fabric」降級為防禦縱深;上游材料 upstream-grade 但 Adam 2026-08-17 裁決不投遞、只歸檔"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9cd25052-2251-4b8f-90db-9e0894747e1e
  modified: 2026-08-17T05:19:02.772Z
---

**現象(2026-08-16 對帳輪實測)**:proxy 對 warm fabric 重啟一次,twin 的**所有**
rate/link-usage 均勻 ×2(22 條活躍邊 twin/veth 全落 1.96-2.39);再重啟一次變 ×3。

**機制(2026-08-16 下午已由第三方 raw client 完整重現,我方 proxy 排除)**:
pipeline commit(`SetForwardingPipelineConfig` VERIFY_AND_COMMIT)清空 P4Runtime
server 的 clone-session 簿記,但 target PRE 的 mgroup(mgid=0x8000+250=33018)存活
→ 新 INSERT「成功」並 append 一個 port-255 replica。對照組證明**觸發點是 commit
不是重啟**:不重推時 duplicate INSERT 被正常拒(UNKNOWN 空 details——
[[bmv2-unknown-status-vocabulary]];⚠️ 舊記載「DELETE 回 NOT_FOUND」是推論,
raw 實錄=UNKNOWN)。

**⭐ 修復(`79e4f69`,重現輪 phase E 的發現)**:簿記**持有** session 時的 DELETE
會銷毀整個 mgroup 含全部孤兒 replica → `write_clone_session` 註冊成功後加
**settle pair(DELETE+INSERT)**,任何路徑收斂到單 replica。live 驗證:probe 疊到
2 → plain `stack.sh up p4` → 1 node、10/10 安裝、0 settle 失敗。

**How to apply**:
- 「proxy 重啟必須連 fabric 重啟」**降級為防禦縱深**(順帶清表狀態,仍是好習慣),
  不再是遙測正確性的必要條件。
- 驗法不變:thrift `mirroring_get 250`+`mc_dump` 數 node(配方 requirements.txt);
  veth 對帳看 twin/veth ≈ 整數倍。
- 上游材料**已 upstream-grade**(五相 raw 重現在
  `p4_proxy/reference/clone_stack_probe.py`,報告
  `doc/audit/2026-08-16_clone-stacking-raw-repro.md`);🚫 **Adam 2026-08-17 裁決
  =不投遞、只歸檔**(取代 08-16 的「單獨投 p4lang」)。issue 稿
  `doc/2026-08-16_p4lang-clone-stacking-issue-draft.md` 與報告、probe docstring、
  投遞包 README 四處都標了同一條裁決;p4lang 上不存在對應 issue(gh 查證)。
  **別再把它當待辦**——我方曝險由 settle pair 關閉。

相關:[[ntg-bmv2-support-pending-feature]]、[[third-party-repro-catches-false-upstream-report]]
