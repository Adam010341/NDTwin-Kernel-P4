# agy-review 積壓盤點與第一輪裁決（2026-08-17）

Adam 問「還有幾份沒審」，答案比預期難算，而且我第一次算錯了。這份文件把**帳**算清楚，
並記錄本輪實際裁決過的部分——**本輪只覆蓋一小片，其餘明列為未審**，好讓下一輪從這裡接。

[Co-developed with claude code -- Adam]

## 1. 帳（328 份，逐段對齊）

| 範圍 | 份數 | 狀態 | 紀錄在哪 |
|---|---|---|---|
| 0001–0056 | 56 | ❌ 未審 | 查無任何 triage 紀錄 |
| 0057–0106 | 50 | ✅ 已審 | `doc/2026-07-29_HANDOFF.md` §2d（2026-08-03） |
| 0107–0127 | 21 | ✅ 已審 | `doc/2026-07-29_HANDOFF.md` §2e（2026-08-07） |
| 0128–0156 | 29 | ❌ 未審 | — |
| 0157–0196、0198–0201 | 44 | ✅ 已審 | `2026-07-29_codebase-review/ADJUDICATION_agy-reviews_0157-0201.md`（2026-08-11，47 個 HIGH） |
| 0197 | 1 | ❌ 未審 | 上述檔案中零命中（可能無 HIGH，也可能漏掉；嚴謹算未審） |
| 0202–0328 | 127 | ❌ 未審（本輪處理其中一小片） | 本檔 |

**已審 115／未審 213。** 自最後一輪（0157–0201）以來的真積壓是 **0202–0328 共 127 份**。

⚠️ **三輪的標準不完全相同**：0157–0201 那輪與 §2e 是逐條裁決 **HIGH 級**；§2d 是從 50 份
抽出 497 條「發現」再篩（原文：絕大多數是章節標題、`Nothing to report` 與文件細節）。
**任何場合都不要把這三輪說成「全部審完」。**

### 兩個算錯的教訓

1. 我第一次回報「未審 201」，少算了 0157–0201 那一輪。**根因是我自己把證據截斷了**：
   `git grep ... | head -10` 的前十行被 HANDOFF 與兩份 runbook 的行級命中吃光，
   ADJUDICATION 檔排在第五個檔案卻沒進畫面。`| head -N` 可以用來讀輸出，**不能用來數**。
2. 8/16 mainDev 更正為「未審 212」，但它的表把 0157–0201 整段算成 45 已審，
   同時又說 0197 該當未審——兩者不能並存。取嚴格解則是 **115／213**。

## 2. 0202–0328 的機械盤點

| 類別 | 份數 |
|---|---|
| 新格式（有 `VERDICT:` 行）且有 HIGH/MEDIUM | 91 |
| 新格式且 `0 HIGH, 0 MEDIUM` | 34 |
| 舊格式（無 `VERDICT:` 行，逐類敘述體） | 2 |

新格式那 91 份合計 **98 個 HIGH、113 個 MEDIUM**。
0001–0056 與 0128–0156 共 85 份**全是舊格式**——那是「每類都要回答，包含
`Nothing to report`」的舊 prompt 產物，訊噪比極差（見 `tools/git-hooks/README.md`：
整個語料 313 句「沒事」、83 句稱讚、332 個 nitpick 對 74 個真發現）。

⚠️ **抽取器本身是不可信的**：HIGH 條目在這批裡有**三種**排版
（`HIGH: 標題`＋後續段落／`**HIGH**` 標頭加項目／`- **HIGH**: 內文`），
我寫的解析器第一版只認得一種、第二版仍漏 24 份。**下一輪不要相信任何一次性抽取的計數，
以 `VERDICT:` 行宣告的數字為準，逐檔開啟。**

## 3. 本輪實際裁決的（逐條對照**現行**程式碼，不是相信 review 的說法）

### 🔴 仍然成立 — 需要裁決

**F1. `TopologyAndFlowMonitor` 的欄位型別守衛缺一半（0226 兩條 HIGH）**

`updateHosts`：`if (!host.contains("ipv4") || host["ipv4"].empty())` 之後直接 `vecIpStr[0]`。
`ipv4` 若是**基本型別**（例如 `"ipv4": 1234`），`empty()` 對數字回 false，
`vecIpStr[0]` 直接丟 `json::type_error.305`。
`updateLinks`：`if (!link.contains("src") || ...)` 之後 `link["src"].value("dpid", "")`。
`src` 若是基本型別，`.value()` 對非物件丟 `json::type_error.306`。

**兩個函式的 `try` 都在 `for` 迴圈外面**（已確認），所以例外逃到函式層 catch
→ **該筆之後的所有 entry 全部被丟掉**，正是這兩個 commit 在註解裡宣稱已經關掉的
「一筆壞資料costs整份 reply」缺陷。已關掉的是**元素**型別（`[1234]` 有 `is_string()` 擋），
沒關掉的是**欄位**型別。缺的是 `is_array()` 與 `is_object()` 各一。

*可達性*：資料來自 Ryu 的 `/v1.0/topology/{links,hosts}`，正常不會送出這種形狀，
所以這是**強健性**缺陷而非現行故障。但它與已修的那半是同一族，且註解已宣稱修好。

**F2. 電源端點把 `OpResult` 丟掉，換成硬編的 500（0209、0217、0233 三份各自獨立指出）**

`P4PowerStrategy` 構造帶 502 與具體訊息的 `OpResult`（含 2abf1e3 特地寫的
「先 power off 再 power on」復原指引），但 `setSwitchPowerState` 的簽章是 `bool`，
handler 看到 false 就回 `500 {"error":"Failed to change switch power state"}`。
**那句指引沒有任何 API 消費者看得到**；操作者看到通用 500，最可能的反應正是盲目重試，
也就是該 commit 想避免的那條路。

*註*：同檔的其他端點已經有 `respondToOpResult()` 這個正確形狀可以照抄，
所以修法在本 repo 內已有先例。

### ✅ 已被後續 commit 修掉（review 當時是對的）

| review | 宣稱 | 現況 |
|---|---|---|
| 0225 | `SFlowType.hpp` 的守衛「literally `if (false)`」，heap-buffer-overflow 仍在 | **已修**：現為 `if (!nodeJson.is_array() \|\| nodeJson.size() < 2)` |
| 0214 | `updateLinks` 端點缺失時是 `return;` 不是 `continue;`，整份 reply 被丟 | **已修**：現為 `continue;` |
| 0208 | readopt 的 `curl -f` 會吞掉 proxy 的錯誤 body | **已修**：現為 `--fail-with-body`，註解日期 2026-08-12 就是為此 |

### ⚪ 仍然成立，但**早已裁決為刻意不修**

| review | 宣稱 | 裁決 |
|---|---|---|
| 0227 | `reverseEdgeFailures()` 的 `endPass()` 從未被呼叫，失敗只累積不輸出 | 已在「刻意不修」清單（endPass/0116）。現況確認：只有 `:1391`／`:1442` 兩處 `record()`，全檔無 `endPass()` |

### ❓ 需要更深查證，本輪不下結論

| review | 宣稱 |
|---|---|
| 0207 | `p4_power_helper.py` 的 manifest 在 load 與 save 之間隔著最長 15 秒的操作，並發指令會互相覆蓋；且 `cmd_on` 逾時時未先記錄 pid → 產生 helper 永遠殺不掉的孤兒 |
| 0211 | readopt 的部分失敗（clone session 失敗／零路由）被 200 吞掉，kernel 只看 curl 的 exit code | 與 §0k「completion handle 結案」的結論可能衝突（該結論說 kernel 自 Phase 2 就會解析 error body），**必須對照現行碼重判，不要沿用任一方** |

## 4. 覆蓋率誠實聲明

**本輪逐條驗證過的只有上表列出的 9 條**（來自 8 份 review），全部取自 0202–0328。
**98 個 HIGH 裡的其餘 ~89 條、113 個 MEDIUM、以及 0001–0056／0128–0156 的 85 份舊格式，
本輪完全沒有審。** 前一輪（0157–0201，47 個 HIGH）動用四個平行 subagent 才做完，
規模可以照此外推。

**下一輪的接手點**：0202–0328 新格式、`VERDICT:` 行宣告有 HIGH 的 91 份，逐檔開啟，
每條對照現行程式碼判 still-open／already-fixed／deliberate／misjudged。
本檔第 3 節的四分類就是輸出格式。
