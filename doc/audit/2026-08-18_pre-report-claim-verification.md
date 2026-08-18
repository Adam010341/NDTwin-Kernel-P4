# 報告前的宣稱查核：簡報說的事現在還成立嗎

**2026-08-18。**兩件事：**①** 逐條查核簡報要宣稱的東西（Task 2）；
**②** 確認哪些 baseline 缺陷在**實驗室現在跑的 main**（`8b61cdc`）上還活著（Task 3）。

**一句話**：簡報的量測數字全部站得住，**但兩個測試鷹架的期望已經過期**，
而且實驗室現有 main 的 **52/56 個原始檔與 baseline 逐位元組相同**——
除了 `FlowLinkUsageCollector` 家族，所有既有缺陷原封不動還在那裡。

[Co-developed with claude code -- Adam]

---

## §1 實驗室現有 main（`8b61cdc`）：哪些缺陷還活著

### 1a. 決定性的事實：只差一個 commit

```
git log --oneline 28b8b13..8b61cdc   →   8b61cdc "Add sharding"   （就這一個）
git diff --name-only 28b8b13 8b61cdc →   5 個檔案
```

| 變動的檔案 |
|---|
| `include/common_types/SFlowType.hpp` |
| `include/ndt_core/collection/FlowLinkUsageCollector.hpp` |
| `src/ndt_core/collection/FlowLinkUsageCollector.cpp` |
| `src/utils/Logger.cpp` |
| `setting/StaticNetworkTopology_ipAlias4_10_HPE_Switches_smapled_by_p4.json` |

**其餘 52 個 `src/`＋`include/` 檔案與 baseline 逐位元組相同。**

所以「這條缺陷在實驗室現在的碼上還在嗎」對絕大多數條目**不需要跑起來驗**——
檔案一模一樣。需要個別確認的只有 `FlowLinkUsageCollector` 家族那幾條。

### 1b. `FlowLinkUsageCollector` 那幾條，逐條查了

| 缺陷 | `28b8b13` | `8b61cdc`（實驗室現況） | 判定 |
|---|---|---|---|
| 閒置 100% CPU（`POLL_TIMEOUT_MS = 0` 忙轉） | `= 0` | **`= 0`** | 🔴 **還活著** |
| elephant flag 的清除 `else` 被註解掉 | 註解掉 | **仍註解掉** | 🔴 **還活著** |
| sFlow parser 缺邊界檢查 | 無守衛 | **無守衛** | 🔴 **還活著** |
| `handlePacket` 無鎖 `find()` 競態 | 有 | 分片改寫**順手修掉** | ✅ 對方已修 |
| packet rate 用 bytes 算 | 有 | **已修**（一個 token） | ✅ 對方已修 |
| `getTopKFlowInfoJson` 遞迴 `shared_lock` | 有 | 分片副作用**已修** | ✅ 對方已修 |

（前三項用 `git show 8b61cdc:<path>` 直接比對確認，不是從敘述推論。
後三項出自既有的 `doc/audit/2026-08-12_overnight-review/U-upstream-8b61cdc-analysis.md`。）

### 1c. 編譯器自己找到的：實驗室現有 main 在 2026 的工具鏈上編不過

`28b8b13` 和 `8b61cdc` 都設了自己的 `-Werror`（CMakeLists:53），在 **gcc 13.3** 上：

| tree | 結果 | `-Werror=unused-result` | `-Werror=maybe-uninitialized` |
|---|---|---|---|
| `28b8b13` baseline | **編不過** | 8 | 4 |
| `8b61cdc` 實驗室現況 | **編不過** | 9 | **35** |

拿掉 `-Werror` 一個字之後 baseline 建得起來（`exit=0`，產出 `ndtwin_kernel`）——
所以**在原始碼上實跑重現是可行的**，這是 M1 的前提。

**`unused-result`（8→9）是真缺陷、不是誤報**：`system()` 的回傳值被丟掉，例如
baseline `ApplicationManager.cpp:132` 的 `system("sudo exportfs -ra");`。
我們這邊已經修成 `describeCommandFailure(std::system(...))`。

**`maybe-uninitialized`（4→35）也是真的，但嚴重度低**——查過了，不是 `-O3` 誤報：

```cpp
uint16_t srcPort, dstPort, icmpType, icmpCode;     // 四個都沒初始化
if (protocol != 1) { srcPort = …; dstPort = …; }   // icmpType/icmpCode 仍未初始化
else               { icmpType = …; icmpCode = …; } // srcPort/dstPort 仍未初始化
…
SPDLOG_LOGGER_TRACE(…, icmpType, icmpCode, …);     // 非 ICMP 路徑上讀未初始化值
```

`FlowKey` 的組成（`key = {srcIp, dstIp, srcPort, dstPort, protocol}`）**有正確用
`protocol != 1` 守住**，所以流量鍵是對的；壞的只有那行 log。
但它踩到本 repo 已經記載過的陷阱：**spdlog 就算 level 關閉也會先求值參數**——
和 `Classifier` 那個 crash 同一個機制——所以這個 UB 在 TESTBED 模式下**每個非 ICMP
flow sample 都會執行一次，與 log 等級無關**。

**分片改寫把 4 個變成 35 個。**這是可以交回去的具體東西。

### 1d. ⚠️ 一個必須講清楚的界線

**`intelligent_router.py` 不在 `28b8b13`，也不在 `8b61cdc`。**兩個 tree 都沒有它。
它是隨 Adam 的 `6f32bca` 進 repo 的。

所以那兩條 Ryu 缺陷（`034da18` 單向鏈路、`2c81b26` 路由重算）——
**repo 回答不了「實驗室現在跑的還有沒有這個問題」**，因為那支程式不在他們的 repo 裡。
簡報上照舊註明「既有 Ryu 控制程式的缺陷」是對的，但**不可以說「他們的 main 現在還有」**。

---

## §2 簡報宣稱查核（Task 2）

環境：P4／4 台拓撲、bmv2-fast、kernel `build/bin/ndtwin_kernel`（建於 08-17 15:06）。

| 簡報宣稱 | 查核方式 | 結果 |
|---|---|---|
| C++ 基準線 585 / 79 | 重跑 | 🟡 **588 / 80**（`b62bafe` 加了 3 條）。說明書已更新 |
| Page 28「L4 differential PASS、14 個被接受的差異」 | 讀 allowlist | 🔴 **無法重驗，且數字對不上**（見下）|
| Page 29 failover 對照表 | — | ✅ 已於今日改寫（23 次控制實驗）|
| Page 30 吞吐（stock ~40 / fast 431 Mbps） | 確認 fast build 仍安裝 | ✅ 仍是量測時的組態 |
| L2 API 契約 | 對活 stack 跑 | 🟡 **1 條過期期望**（見下）|
| L3 元件契約 ＋ log allowlist | 對活 stack 跑 | 🔴 **抓到 1 個真缺陷 ＋ 1 條過期樣式** |

### 2a. 🔴 Page 28 的「14 個被接受的差異」重驗不了，而且數字對不上

**重驗不了**：`.test_run/baseline/` 是**空的**（08-15 之後沒有 capture）。
L4 比對需要 OVS 與 P4 兩邊各 capture 一次，也就是要換一次 stack。

**數字對不上**：`baseline_diff_allowlist.txt` 的非註解行數是

| | 行數 |
|---|---|
| `dac192b`（簡報引用的 commit） | **19** |
| HEAD | **18** |

簡報寫 **14**。⚠️ **我不主張簡報錯了**——很可能它數的是「被接受的差異」這個
*發現* 數，不是 allowlist 的*行*數（一行樣式可以涵蓋多個差異）。
**動筆前必須重數，並把口徑寫出來**（數的是行還是發現）。這正是 A2b 那條規矩存在的理由。

### 2b. 🟡 L2：`install_flow_entry__missing_fields` 的期望已經過期

契約套件對 body `{"dpid": 1}` 期望 `[400, 422]`（`spec.py:556`），實測回 **200**。

**這不是回歸，是修好之後的正確行為。**原本的 400 是假的——
`ad49347` 之前，回應先被寫成 200，然後快取層的 `.at("priority")` 對缺鍵丟例外，
例外逃到外層 handler 把 200 **蓋成 400**，而規則已經派送出去了
（見 `doc/audit/2026-08-17_install-rejected-but-applied.md`）。

我今天實測走了一遍完整路徑：

```
POST /ndt/install_flow_entry  {"dpid": 1}
  → HTTP 200 {"accepted":1,"status":"queued"}
  → [warning] install flow entry failed: P4 proxy agent reported an error in a 200 response
  → [error]   dispatched install failed for dpid 1 (priority 0)
  → 交換機表：UNCHANGED
```

**原本的缺陷（回 400 卻真的裝上規則）確實沒有了。**現在是誠實地說「已排隊」，
然後真的被拒絕，而失敗寫在 log 裡。

⚠️ **但契約要怎麼寫是設計決定，我沒有動它。**把期望直接改成 `[200]` 等於把
「只有 dpid、沒有 match 沒有 actions 的 body 也接受」寫成契約。
audit 文件自己點出的缺口正是這個：**佇列式端點只驗「誠實地說已排隊」，
沒有任何檢查看得到派送結果**。合理的第三條路是同步驗 body 形狀、
形狀不可能成立就 400，well-formed 的才 200-queued。

✅ **2026-08-18 已裁決並實作（Adam）**——見 §5。契約期望 `[400, 422]` 因此**不需要改**：它現在又是對的了，實測 `install_flow_entry__missing_fields` PASS [400]。

### 2c. 🔴 log 檢查抓到一個真的：NFS 清理的權限死結（已修一半）

```
[WARNING] Found stale application folder from a previous run: /srv/nfs/sim/1
[ERROR] Failed during cleanup for '/srv/nfs/sim/1': cannot remove all:
        Permission denied [/srv/nfs/sim/1/energy_saving_simulator/1.0/case4/input]
```

磁碟上的真相：

```
/srv/nfs/sim/1                             drwxrwxrwx adam:adam       ← kernel 的 chmod 只到這層
/srv/nfs/sim/1/energy_saving_simulator     drwxr-xr-x nobody:nogroup  ← 模擬器自己建的
.../1.0/case4                              drwxr-xr-x nobody:nogroup
```

`remove_all` 需要**每一層父目錄的寫權限**。`openUpAppDirPermissions` 只 chmod
**最上層**（header 註明：它取代了需要 root 的 `chownRecursive`），
所以 client 自己建的子目錄永遠刪不掉 → `cleanupStaleEntries` 永遠失敗 →
app 目錄永遠被重用。

**這是 `b62bafe` 那條修復的前提，現在有 live 證據而不只是推論。**
修復處理了「重用被當成失敗」那半（權限不再被跳過）。
**還沒處理的**：`cleanupStaleEntries` 對一個**預期發生、且沒有 root 就修不了**的狀況
記 **ERROR**。把「squashed client 擁有這些子目錄」與真正的失敗分開，
是同一個形狀往上一層——**建議下一步就做這個**。

### 2d. 🟡 log allowlist 有一條樣式已經過期

allowlist:127 是 `^refusing flow batch: [0-9]+ dpid\(s\) are not switches`，
實際訊息已經變成
`refusing flow batch: none of its 1 entries names a switch in the loaded topology (1 distinct unknown dpid(s))`。
**訊息文字改了、樣式沒跟著改**，所以它同時出現在「未匹配的問題行」和「未使用的 allowlist 條目」兩份清單裡。
純鷹架腐爛，不影響產品。

✅ **已修**（同一輪）。順帶發現第二條同型的：allowlist:124 `^Bad entry in request:` 的理由寫著它守的是 `install_flow_entry__missing_fields`，而那條測試現在被形狀檢查先攔下來——樣式仍可達（欄位**型別**錯的 well-shaped entry，例如 `"priority": "high"`），但理由已就地更正。

### 2e. 一條是我自己的操作錯誤，不是缺陷

`get_detected_flow_data` FAIL——我加了 `--traffic` 但當下根本沒有流量在跑
（stack 從昨天起就閒置）。**旗標用錯，不是系統問題。**記在這裡是因為
「把自己的操作錯誤誤判成缺陷」是這個專案反覆出現的風險。

---

## §3 待辦（依建議順序）

| # | 事項 | 誰 |
|---|---|---|
| 1 | `cleanupStaleEntries` 分辨「squashed client 的子目錄」與真失敗（§2c） | 可直接做 |
| 2 | ~~`install_flow_entry` 缺欄位要 400 還是 200-queued~~ ✅ **已裁決並實作**（第三條路：形狀同步驗回 400、語意留佇列）。**派送結果查不到**這個缺口列入「已知未完成」，見 §5 | 完成 |
| 3 | ~~更新 allowlist:127 的樣式~~ ✅ **已修**，連同 allowlist:124 過期的理由 | 完成 |
| 4 | L4 differential 重跑一輪（需換 stack 到 OVS 再換回來）＋ 重數「14」的口徑（§2a） | 需要換環境 |
| 5 | 決定要不要把 §1 的結果交給學長姐、以什麼形式 | **Adam 裁決** |

## §4 重現

```bash
# §1a/1b 的比對（不需要建置）
git diff --name-only 28b8b13 8b61cdc
git show 8b61cdc:src/ndt_core/collection/FlowLinkUsageCollector.cpp | grep -oE 'POLL_TIMEOUT_MS[^;]*'

# §1c 的建置（M1 的前提）
git worktree add /tmp/baseline 28b8b13 --detach
cmake -S /tmp/baseline -B /tmp/baseline/build -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/baseline/build -j4          # 失敗；錯誤即證據
sed -i 's/-Werror -pthread/-pthread/' /tmp/baseline/CMakeLists.txt
cmake --build /tmp/baseline/build -j4          # exit=0，產出 bin/ndtwin_kernel

# §2 的契約查核（需要活的 stack）
NO_COLOR=1 bash tools/test_workflow/run_layers.sh api p4    # 不要加 --traffic 除非真的在灌
```


---

## §5 列入「已知未完成」：佇列式端點查不到派送結果

**2026-08-18 裁決（Adam）**：`install_flow_entry` 走第三條路——**形狀與語意分開**。

| | 誰判斷 | 何時 | 回什麼 |
|---|---|---|---|
| **形狀**：這個 body 有沒有可能變成一條規則 | HTTP 執行緒，`describeFlowEntryShapeProblem` | **同步** | 不成立 → **400**，並指名哪一筆的哪個欄位 |
| **語意**：交換機接不接受這條規則 | FlowDispatcher → proxy → bmv2 | 非同步 | 只寫 kernel log |

實測（活的 P4 stack，kernel 重建後）：

```
{"dpid": 1}                                       → 400  missing "actions" -- send "actions": [] if a drop rule is what you meant
{"dpid":1,"priority":1,"match":{…},"actions":[…]} → 200  queued
{"dpid":1,"priority":0,"actions":[]}              → 200  queued   ← 明確的 drop rule 必須留著能用
{"dpid":9999,"actions":[]}                        → 404  unknown dpid   ← 既有路徑沒被遮蔽
```

**全批拒絕而不是部分套用，這一點跟下方 unknown-dpid 的分區刻意相反**：不認識的 dpid 是*資料*
狀況（拓撲變了），會零星打到一個原本正確的批次，而兩個寫 flow 的應用都丟棄回應，所以整批拒絕
只會默默丟掉它們的好條目。畸形條目相反，是*呼叫端*的缺陷，不會零星發生——要嘛從不觸發，
要嘛它送的每一批都一樣錯。套用其餘的等於藏 bug，不是容忍競態。

### 還沒解決的，就是列進未完成的那條

**200 之後，「規則到底有沒有裝上去」沒有任何 API 問得到。**

這不是這次修法造成的，是佇列式端點的結構性缺口——audit 文件自己早就寫著：

> 佇列式端點只驗「誠實地說已排隊」，沒有任何檢查看得到派送結果

**它有多真實**：契約套件 L2 曾經全綠，而同一時間 kernel log 寫著
`dispatched install failed for dpid 1 (priority 0)`。**綠燈和失敗同時存在**，
而且沒有任何一層看得到那個矛盾——當初就是追這條矛盾才追出整個缺陷的。

**補法**（新功能，不是修 bug）：查詢端點（`/ndt/get_flow_job_status?job_id=…`）、
或讓 200 回一個可查的 job id、或至少讓契約套件在 dispatch 之後對交換機表對帳。

**為什麼現在不做**：三個都是新的 API 表面，會動到七個外圍元件的契約。報告前不動。
**已列入簡報 Page 35「誠實列出未完成」。**
