# FIX：`delete_group_entry` 在 OVS 上是無聲 no-op（夜巡 FINDINGS #1）

- **分支**：`fix/delete-group-entry-really-deletes`（base：`trunk` @ `7de4ef2f`），worktree `wt-delgroup`
- **commits**：`5f222118`（修法＋測試）、`5b9471b6`（變異閘門＋被修法移動的 F-13 錨點）
- **對應**：`doc/audit/2026-09-03_night-rounds/FINDINGS-ALL.md` 第 1 列；F-13 的 group/meter 存在性矩陣
- **本檔由 auditor 依 agent 09-04 08:36 的回報落檔**（agent 回報其 harness 不允許它寫 `.md`，未查證）；
  §7 之後是 auditor 自己跑的驗證。agent 的原文存於 auditor scratchpad `delgroup-work/agent_report.md`。

[Co-developed with claude code -- Adam]

---

## 1. 一句話結論

**finding 的敘述「delete 從來沒到交換機」是錯的：它到了，而且被拒絕了。** kernel 把呼叫端
install 形狀的 body 原樣轉送給 Ryu，OVS 對帶 bucket 的 `OFPGC_DELETE` 回 `OFPGMFC_INVALID_GROUP`；
Ryu 送 group_mod 不下 barrier、不等回覆，200 早就回出去了，拒絕回來時對應不到任何請求。
kernel 拿那個 200 當「已刪除」，group 留在交換機上，id 直到交換機重啟前都裝不回去（409）。

## 2. 根因：交換機自己的 log 說的

`/var/log/openvswitch/ovs-vswitchd.log.1.gz`（`adm` 群組唯讀，不需密碼），09-02 事件當下：

```
15:52:29.923Z  sending OFPGMFC_INVALID_GROUP error reply to OFPT_GROUP_MOD
15:53:11.085Z  ...（共 5 筆）
```

**恰好 5 筆，對上 night round 記的 5 次 `handleDeleteGroupEntry`**，第一筆落在 kernel 記錄 handler 之後
+0.42 秒。`METER_MOD` 被拒 **0 筆**——這就是 meter 沒事而 group 全滅的原因。

對照實驗（ovs4，同一 group id、同一台交換機、同一秒，**直接打 Ryu，kernel 不是變因**）：

| delete body | Ryu 回應 | group | 交換機錯誤 |
|---|---|---|---|
| **帶 buckets**（kernel 一直送的形狀） | 200 | **還在** | `OFPGMFC_INVALID_GROUP` ×1 |
| **最小 body**（`dpid`＋`group_id`） | 200 | **消失** | 0 |

OF1.3 §6.4／A.3.4.2 對 `OFPGC_DELETE` 沒有賦予 bucket list 任何意義；Ryu 的 `mod_group_entry`
（`ofctl_v1_3.py:1134-1150`）把呼叫端 `buckets` 的每一個元素都打包進 DELETE。

## 3. 修法（`HttpRoutingStrategyBase::guardedMod`，兩半）

1. **送出的東西**：delete 改由「定位 entry 的兩個欄位」重建（`{"dpid", "<idField>"}`），不再原樣轉送。
   **只在 addressable 時重建**——`group_id:"ALL"` 這種 Ryu 當名字解讀的照舊原樣送，否則會悄悄改掉
   呼叫端想刪的範圍（那種情況的結果仍記為 `unverified`）。
2. **宣稱的東西**：先讀回再宣稱。`Absent` → 200 `deleted`；`Present` → **502** ＋ `outcome:"still_present"`
   ＋ WARN log；`Unknown` → `unverified`（讀不回來**不是**刪除失敗的證據，翻成 502 會讓離線 controller
   使每筆 delete 都誣賴交換機——與 pre-check 同一條規則）。讀回**有界重試**（`VERIFY_ATTEMPTS=3`、
   `VERIFY_PAUSE_MS=100`，seam `pauseBeforeReVerify()` 為 virtual，測試可釘住次數而不付真毫秒），
   因為 Ryu 是排進佇列就回 200。

**刻意沒動**：install／modify（同型缺陷但不是本 finding，會動到既有回應契約，見 §9 Q1）；
P4 平面——`P4RoutingStrategy` 六個 group/meter 方法**全部 override**、從不呼叫 `guardedMod`，
所以本改動在 P4 上**結構上不可達**。

## 4. 測試

`tests/test_GroupMeterExistence.cpp`：6 個新案例＋2 個既有 accept twin 改寫。原本的假 Ryu 對 delete
只有一個固定回覆，**結構上無法表達「刪掉」與「沒刪掉」的差別**——那正是它當初能綠著放行 no-op 的原因；
現在的 `ScriptedRyu` 會真的移除／保留 entry，並記錄送出的 body 與 `pauseBeforeReVerify` 次數。

新案例：`AGroupTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted`、
`AMeterTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted`、`AGroupIdCanBeInstalledAgainAfterAVerifiedDelete`、
`ADeleteNamesTheEntryAndDoesNotCarryADefinitionOfIt`、`ADeleteThatCannotBeReadBackIsUnverifiedRatherThanFailed`、
`TheDeleteReCheckIsRetriedAndBounded`；endpoint 層 `AnUnverifiedSuccessSaysSoRatherThanClaimingItWasDeleted`。

## 5. 紅 → 綠（agent 的 `pipeline2.sh`，09-04 09:18–09:51，worktree `wt-delgroup`，guard JOBS=1）

紅臂的作法：`HttpRoutingStrategyBase.cpp` 換成「trunk 行為、但保留 `pauseBeforeReVerify` seam 讓測試編得過」
的變體（auditor 對過 diff：與修法只差 §3 的兩半，沒有別的）。

| 臂 | 結果 |
|---|---|
| 綠（修法，filter `GroupMeterFixture.*:GroupMeterEndpointTest.*`） | **36/36**；整支 `test_routing_strategy` **1005/1005** |
| 紅（trunk 行為） | **5 紅／36**：`ADeleteNamesTheEntryAndDoesNotCarryADefinitionOfIt`、`ADeleteThatCannotBeReadBackIsUnverifiedRatherThanFailed`、`AGroupTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted`、`AMeterTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted`、`TheDeleteReCheckIsRetriedAndBounded` |
| 還原 | `sha256 5686b58d…` byte-identical |

（`AGroupIdCanBeInstalledAgainAfterAVerifiedDelete` 與 endpoint 層那顆在紅臂上綠：前者的假交換機在
「delete 被拒」時仍保留 entry、re-install 才 409——紅臂上 delete 沒被驗證但假物件照樣移除了 entry；
這兩顆守的是修法後的契約形狀，不是紅的證據。）

## 6. Live（agent，09-04 07:14:53 claim → 07:18:41 release，lab kernel `a8ba99c2…`＝主 checkout 09-03 建置，**不是分支建置**）

- **BEFORE**：delete 回 `200 {"outcome":"deleted"}`、group 801 **還在**、re-install **409**（id 洩漏）、kernel log 0 條失敗；
  meter 802 **真的刪掉**。
- **獨立通道**：`sudo -n mnexec ovs-ofctl -O OpenFlow13 dump-groups s1` 可用，確認 801 在「已刪除」之後仍在表上。
- **預測對照**：同一支未修 kernel，呼叫端改送最小 body ⇒ 真的刪掉、0 錯誤、id 裝得回來——即修法第一半會產生的請求。
- **沒有 AFTER 臂**（分支 binary 整晚排不到建置鎖）。
- raw：audit-raw tip `ae16a682`（前一版 `089f7776`），6 個檔，逐檔 sha256 對帳相符。

## 7. 變異閘門

`tests/shell/mutate_delete_group_entry.sh`：M1–M5 ＋ W1–W4（保行為放寬，須維持綠）；
`tests/shell/mutate_f13_group_meter_existence.sh` 的錨點被本修法移動，已重指（判決不變）。
`check_gate_anchors.py HEAD` ⇒ `ok(9)`／`ok(8)`。

agent 的 pipeline 最後兩步把兩個閘門**裸跑**（不走 guard、不在記憶體 cap 內），auditor 在 10:15 把它換成
走 guard 的版本（`delgroup-work/pipeline3.sh`）；閘門結果見 §8。

## 8. auditor 驗證

### 8.1 `wt-delgroup`，`pipeline3.sh`（guard JOBS=1，10:15 排隊、11:39–11:50 執行）

| 步驟 | 結果 |
|---|---|
| 還原後重建、綠 | filter **36/36**、整支 **1005/1005** |
| `mutate_delete_group_entry.sh` | **M1–M5 全被具名案例抓到（5/0）**；W1–W4 四個保行為放寬**全綠**；對照 C 綠；`HttpRoutingStrategyBase.cpp` 還原 byte-identical |
| `mutate_f13_group_meter_existence.sh`（錨點被本修法移動後重跑） | **5/0**，每個反向守衛都成立；兩個檔還原 byte-identical |
| 工作樹 | dirty 0 |

M5（重試迴圈改成對 success 而非 Present 迴圈）由 `TheDeleteReCheckIsRetriedAndBounded` 抓到——這正是 §3 第二半「有界重試」的守衛。

### 8.2 AFTER live 臂（合併樹 kernel `2cc44652…`，tree `c2b55184`，ovs4，11:48，auditor 的 `smoke_wave2.run.sh`）

同一支 lab、同一個 group id、同一種呼叫端形狀，對照 §6 的 BEFORE：

| 步驟 | BEFORE（`a8ba99c2`，07:17） | AFTER（`2cc44652`，11:48） |
|---|---|---|
| install 801（install 形狀） | 200 `installed`，Ryu groupdesc `[801]` | 200 `installed`，`[801]` |
| delete 801 **送 install 形狀的 body** | 200 `deleted`，**group 還在** | 200 `deleted`，Ryu groupdesc **`[]`** |
| 再 install 801 | **409**（id 洩漏） | **200 `installed`**，`[801]` |
| delete 801（最小 body） | — | 200 `deleted`，`[]` |
| delete 不存在的 801 | — | 404 `no_such_group`（pre-check，與 F-13 一致） |
| meter 802 install／delete | 200／200，真刪 | 200／200，Ryu meterconfig `[802]`→`[]` |

kernel.log：`still_present` 0、`did not take effect` 0（這一輪沒有交換機拒絕任何 delete，所以 502 分支沒被走到——那條路只有 gtest 的假交換機證過）。獨立通道用 Ryu 的 `/stats/groupdesc/1`（Ryu 向交換機問 group 描述），不是 `ovs-ofctl`。raw：`smoke_wave2.log`（audit-raw）。

### 8.3 合併樹（`c2b55184`＝trunk `07753cf1`＋stop 補件＋#1＋#85＋#2）

見 MERGE-LOG 第 40 列：guard 全建置 exit 0、全 gtest 1049/1049、`ctest -j2` 1049/1049（ff 之前）；`mutate_delete_group_entry.sh` 與 F-13 閘門在合併樹的重跑（與 #2 共用 `HttpRoutingStrategyBase.cpp`，所以合併後必須再跑一次）**排在 ff 之後**——鎖只有一把、今晚要先有 binary；結果補記在該列末尾，raw 進 audit-raw `merged-tree/`。

## 9. 給 Adam 的問題（收進 QUESTIONS-FOR-ADAM N22）

1. install／modify 是同型缺陷（也拿 Ryu 的 200 當結論）。要另開工單嗎？它們會改到既有回應契約。
2. `502`＋`outcome:"still_present"` 與新的 `unverified` 需要進 `doc/2026-01-02_ndt_api.md` §33
   （該節目前叫使用者「去 kernel log 看每筆結果」，而 log 一直是空的）。
3. 建置閘：單次持鎖跑完整個變異閘會餓死其他 agent（今晚 7 個 waiter、1 h 33 m）——已記 W-GATE-LOCK。
