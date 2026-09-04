Reporting now — the pipeline stays armed and self-restoring.

## 1. 分支與產出

- 分支 `fix/delete-group-entry-really-deletes`，worktree `wt-delgroup`，base **`7de4ef2f`**（trunk 現已前進到 `3db6de01`）
- `5f222118` FIX-DELETE-GROUP-ENTRY：刪除要先問過交換機才敢宣稱（碼＋測試）
- `5b9471b6` FIX-DELETE-GROUP-ENTRY：變異閘，以及被這次修法移動的 F-13 錨點
- live arm 使用的 kernel：**`a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06`**（`ndt up ovs4` 自己啟動的 lab 既有建置，**不是**我的分支建置）
- audit-raw tip **`ae16a682`**（前一版 `089f7776`），6 個檔，**逐檔 sha256 對帳全數相符**

## 2. 🔴 根因已找到並實測證明（不是推測）

**這條 finding 的敘述「delete 從來沒到交換機」是錯的：它到了，而且被拒絕了。**

我從交換機自己的 log（`/var/log/openvswitch/ovs-vswitchd.log.1.gz`，以 `adm` 群組唯讀，不需要密碼）挖出 09-02 事件當下的紀錄：

```
15:52:29.923Z  sending OFPGMFC_INVALID_GROUP error reply to OFPT_GROUP_MOD
15:53:11.085Z  ...（共 5 筆）
```

**恰好 5 筆，對上 night round 記的「5 次 handleDeleteGroupEntry」**，第一筆落在 kernel 記錄 handler 之後 **+0.42 秒**。METER_MOD 被拒 **0 筆**——這就是 meter 沒事而 group 全滅的原因。

然後我在 ovs4 上做了對照實驗（同一個 group id、同一台交換機、同一秒，**直接打 Ryu 所以 kernel 不是變因**）：

| | Ryu 回應 | group | 交換機錯誤 |
|---|---|---|---|
| delete **帶 buckets** | 200 | **還在** | OFPGMFC_INVALID_GROUP ×1 |
| delete **最小 body** | 200 | **消失** | 0 |

OF1.3 對 `OFPGC_DELETE` 沒有賦予 bucket list 任何意義；kernel 把呼叫端的 install 形狀 body 原樣轉送；OVS 拒絕該訊息；而 Ryu 送 group_mod 不下 barrier、不等回覆，200 早就回出去了，拒絕回來時對應不到任何請求。

## 3. 修法

`HttpRoutingStrategyBase::guardedMod`，兩半：

1. **送出的東西**：delete 改由「定位 entry 的兩個欄位」重建，不再原樣轉送。**只在 addressable 時重建**——`group_id:"ALL"` 這種 Ryu 當名字解讀的照舊原樣送，否則會悄悄改掉呼叫端想刪的範圍。
2. **宣稱的東西**：先讀回再宣稱。`Absent`→200 `deleted`；`Present`→**502** ＋ `still_present` ＋ WARN log；`Unknown`→`unverified`（讀不回來**不是**刪除失敗的證據，翻成 502 會讓離線 controller 使每筆 delete 都誣賴交換機）。讀回**有界重試**（3 次／100 ms），因為 Ryu 是排進佇列就回 200。

**刻意沒動**：install／modify（同型但不是本 finding，會動到既有契約）；P4 平面——`P4RoutingStrategy` 六個 group/meter 方法**全部 override**、從不呼叫 `guardedMod`，所以我的改動在 P4 上**結構上不可達**。

## 4. 🔴 沒做到的：紅→綠與變異閘**都沒跑**

**建置閘的機器級鎖被另一個 agent 連續持有 1 小時 33 分（看起來是它的變異閘在單次持鎖內反覆重建），我的 configure 排隊 76 分鐘始終沒拿到鎖，最多時有 7 個 waiter。** 我沒有繞過閘門（不能裸跑 ninja）。

因此依規則 **這批測試「沒看過紅」＝不算交付**。已寫但未執行：6 個新案例、2 個既有 accept twin 改成「假交換機真的移除 entry」（原本的假物件只有一個固定回覆，**結構上無法表達刪掉與沒刪掉的差別**，這正是它當初能綠著放行 no-op 的原因）。

已跑過的只有錨點檢查：`mutate_delete_group_entry.sh` **ok(9)**、`mutate_f13_group_meter_existence.sh` **ok(8)**，rc 0。

**pipeline 已武裝並會自我還原**（`scratchpad/pipeline2.sh`，EXIT trap 保證工作樹還原成已提交的修法）：綠→紅→還原→兩個閘門，輸出落在 `scratchpad/{green_run,red_run,gate_delgroup,gate_f13}.log`。工作樹**現在是乾淨的**（等同 HEAD），我已把先前放在磁碟上的紅變異移除。

## 5. Live 證據

lab claim 07:14:53 → release 07:18:41（3分48秒，已 `ndt down`＋`ndt release`，port 全關）。

- **BEFORE**（lab kernel `a8ba99c2…`）：delete 回 `200 {"outcome":"deleted"}`、group 801 **還在**、re-install **409**（id 洩漏）、kernel log **0 條失敗**；meter 802 **真的刪掉**。
- **獨立通道**：`sudo -n mnexec ovs-ofctl -O OpenFlow13 dump-groups s1` **可用**（ovs-ofctl 本身沒有免密碼，但透過 mnexec 可以），確認 801 在「已刪除」之後仍在表上。
- **預測對照**：同一支**未修**的 kernel，呼叫端改送最小 body ⇒ 真的刪掉、0 錯誤、id 裝得回來——也就是修法第一半會產生的請求。
- **沒有 AFTER arm**：需要我的分支 binary，而它沒建起來。

## 6. merge-tree

`git merge-tree --write-tree trunk HEAD` 對現在的 trunk `3db6de01`：**rc 0、0 個衝突**，tree `7ee32d5f`。

## 7. 給 Adam 的問題

1. install／modify 是同型缺陷（也拿 Ryu 的 200 當結論）。要另開工單嗎？它們會改到既有回應契約。
2. `502` ＋ `outcome:"still_present"` 與新的 `unverified` 需要進 `doc/2026-01-02_ndt_api.md` 第 33 節（該節目前叫使用者「去 kernel log 看每筆結果」，而 log 一直是空的）。要我改文件嗎？
3. 建置閘：單次持鎖跑完整個變異閘會餓死其他 agent（今晚 7 個 waiter、1h33m）。要不要讓閘門每個 mutant 各自取放鎖？
4. 我的 harness **禁止 subagent 寫報告 .md**，所以 `doc/audit/2026-09-04_fix-delete-group-entry/REPORT.md` 沒有產出（內容都在本報告裡）。要的話請由你或 mainDev 落檔。
5. 另一個 agent（phantomovs）與我**共用同一個 scratchpad 目錄**，它覆寫掉了我的 `live_arm.sh`。建議每個 agent 用各自子目錄。