---
name: bmv2-unknown-status-vocabulary
description: bmv2 把幾乎所有寫入異常都回 UNKNOWN+空 details——照 P4Runtime 規格寫的分支是死碼;消歧手法=改查『目標狀態成立了沒』;已四例
metadata: 
  node_type: memory
  type: project
  originSessionId: 3878c1c3-5bc1-4b38-b7ea-a95f52dd8e1d
  modified: 2026-08-28T11:07:09.389Z
---

**bmv2 的錯誤狀態字彙與 P4Runtime 規格不符：它把語意不同的失敗一律回
`UNKNOWN` 帶空 `details()`。** 照規格狀態碼寫的處理分支對真 bmv2 是死碼，而
mock 單元測試會照規格餵狀態碼，所以這類死碼**全綠地活著**，只有 live 才會揭穿。

已實錘四例：
1. duplicate INSERT → UNKNOWN（不是 ALREADY_EXISTS）——C9/insert fallback 的由來。
2. **delete 不存在的 entry → UNKNOWN（不是 NOT_FOUND）**——2026-08-16 寫入路徑
   live 輪抓到，`delete_ipv4_route` 的冪等分支從未執行過（`459acbb` 修）。
3. C8 的 election-id 重複 → 也是靠 details 文字（`Election id already exists`）
   而非狀態碼區分。
4. **pipeline commit 後的 clone-session DELETE → UNKNOWN 空 details**（raw client
   實錄，2026-08-16）——對帳輪記的「NOT_FOUND」是推論非觀察（swallow 沒 log 碼），
   [[investigation-briefs-separate-observation-from-inference]] 重演。

**Why:** 狀態碼無法消歧時，唯一可靠的判準是「呼叫者要的目標狀態成立了沒」：
insert 的歧義用「改成 MODIFY 再試」解、delete 的歧義用「讀回表確認不存在」解
（`_ipv4_route_present`，讀回值要 pad——bmv2 canonicalize 會剝前導零 byte）。

**How to apply:** 對 bmv2 寫任何錯誤處理分支時，先問「這個狀態碼 bmv2 真的會發
嗎」，答案要 live 證據不是規格引文；規格碼分支可以留（對規格相容 target 有效）
但**必須**再補 UNKNOWN 的目標狀態消歧。相關：[[live-runs-find-what-tests-cannot]]、
[[smoke-the-accept-path-not-just-refusals]]。
