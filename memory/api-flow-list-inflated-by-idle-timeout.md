---
name: api-flow-list-inflated-by-idle-timeout
description: 🔴 get_detected_flow_data 列出的流有 92% 已經結束（FLOW_IDLE_TIMEOUT 15 s 的尾巴）。churn 下膨脹 13.3×，倍率≈1+15×新流速率/平均併發。有 repo 外消費者：Energy-Saving-App 整包餵進省電模擬
metadata: 
  node_type: memory
  type: project
  originSessionId: 5ee7b174-e2c9-421a-a4e1-a469a24dc633
  modified: 2026-08-29T03:08:57.978Z
---

**工單 W，2026-08-27 深夜由 `8/27 mainDev` 在工單 M 的 pre-flight 中意外發現。**
正本在 repo：預註冊 `59d58fb`、`doc/KNOWN-ISSUES.md` B 類、原始讀出 `8c9e841`
（`doc/audit/2026-08-27_1khz-path-recompute/preflight_*`）。**這裡只記 repo 裡沒有的部分。**

## 事實

API 的流清單（`getFlowInfoJson` / `get_detected_flow_data`）**在流結束後仍會列它 15 秒**
（`FLOW_IDLE_TIMEOUT`，`include/ndt_core/collection/FlowLinkUsageCollector.hpp:34`）。

```
churn 工作點：mean expected_alive 4.7  vs  mean api_flows 63.0  ⇒ 13.3×  ⇒ 92% 已結束
最低 api_flows/expected_alive = 2.25，從來沒有低於 1 ⇒ 膨脹出現在每一個樣本裡
```

🔑 **mainDev 把它寫成公式而不是一個數字，這才是它可用的形式：**

> **倍率 ≈ `1 + 15 × 新流速率 / 平均併發`** ⇒ 長流下趨近 1，churn 下發散。

⇒ **13.3× 只是一個工作點的讀數；公式是一個模型，任何人都能用別的工作點否證它。**

## 🔴 它有 repo 外的消費者（`no-in-repo-callers-is-not-dead-code` 再一次成立）

repo 內只有稽核工具與契約測試在讀 ⇒ **看起來像沒人在用**。真正的生產消費者在另一個 repo：

| 消費者 | 做什麼 |
|---|---|
| 🔴 `~/Energy-Saving-App/src/app/energy_saving_app.cpp:741` | `get_detected_flow_data()` → **整包餵進 `json2sim["flowDataList"]`** |
| `tools/twin_audit/twin_audit.py:91` | 稽核 |
| `tools/contract_test/*` | fixture |

⚠️ **「餵進去」不等於「據以決策」——這個區分要保住，不要放棄。**
未答的三問：① `flowDataList` 有沒有進到影響輸出的計算？② 逐流用還是只取聚合？
③ 🔴 **有沒有任何地方把「流的數量」當負載指標**（那是最壞情況，13× 直接變 13× 的負載高估）。
⚠️ 那個 repo 有**未 push** 的修改（見 [[energy-saving-app-power-bug-fix]]）⇒ **只讀不動。**

## 🔴 08-13 那條線索：**已對帳，確認「不同源」**（`6b6ba52`，mainDev）

`tools/twin_audit/twin_audit.py` 檔頭記著 **2026-08-13 OVS 過夜輪**：
「`get_detected_flow_data` 回報一條流正在流動，而實際沒有」。**我期待它同源。它不是。**

> `purgeIdleFlows` 在**最後一個樣本之後 15 秒**清除（`FLUC:2238-2248`，而 `endTime` 每次樣本抵達都更新）
> ⇒ **W 的機制有 15 秒硬上界。而觀察值是 291 秒，19 倍。**

🔑 **結案的方式值得記**：不是「症狀像所以同源」，也不是「資料不足」，
**是碼強制的上界對上一個超過它 19 倍的量測**——一個**數量級的矛盾**，不是一個統計判斷。
⇒ **W 沒有變成「兩週前就撞過」。兩者共有的是後果不是成因；修 W 不會修掉 08-13 那個。**

## 🔴 但對帳換來一個更好的東西：**一個具名、可測的新候選（獨立工單）**

`FLUC:2242`：`if (now <= info.endTime) continue;` —— **而 `now` 來自系統時鐘，不是 steady clock。**

⇒ **時鐘倒退（NTP 校時／VM suspend／手動改）會讓那條流每一輪都被跳過
⇒ 產生沒有上界的殭屍紀錄** ⇒ **正是 291 秒那個形狀。**

**與 15 秒尾巴是兩個缺陷，只是症狀重疊。** 記在 `ad682cc` 的 `NEXT.md`，待開工單。
🔑 **一次「確認不同源」的對帳，比一次「確認同源」產出更多**——
因為它逼出了「那另一個成因是什麼」，而那一問有答案。

## ✅ Energy-Saving-App 的三問：已讀（`d38d209`），但**分支歸屬整個相反**（`6bcd4fc` 撤回）

- **逐流消費**（`strings` 有 `flow ip:{}->{} … oldband/newband/diff`），不是只取聚合 ⇒ 死流會逐條進去。**這半仍成立。**

🔴🔴 **08-28：這個事實在一天內被講成三種互相矛盾的版本，而三個人各對一部分。**
**爭執的從來不是行為，是「baseline」指哪一個 commit。**

| 「baseline」可能指 | `hopsCounter == 0` 時 | 誰查的 |
|---|---|---|
| **`28b8b13`**（fork point） | `continue`，**不清除 ⇒ 保留舊值** | `無狀態tester` |
| **`origin/main`**（今天的公開版，領先 fork point 只有 2 個 commit） | **明文清除** | `mainDev` |
| ✅ **`3367d0e9`**（實驗的 base 臂**實際跑的 binary**） | **清除**——建置自 `aabe605` 之後 | **後來由 mainDev 用字串簽名＋實測行為定案，見檔尾** |

改變 upstream 行為的是 `8b61cdc "Add sharding"`（標題完全看不出來）。
本分支：`31b357a` 引入保留、`aabe605` 於 08-20 修掉 ⇒ **本分支今天清除。**

⇒ **「公開版本現在就有幻影負載」對 `origin/main` 是假的、對 fork point 是真的。**
⇒ **而實驗真正要問的那個 commit（`3367d0e9`），三個人都沒查。**

🔑 **可轉移的那一條，比這個事實本身重要：**
> **凡是宣稱「baseline 如何」，都必須指名 commit。不指名的版本一律作廢，不管它說什麼。**
> 見 [[benchmark-must-name-the-binary-it-measured]]——**同一條規則，從 binary 推廣到原始碼宣稱。**

📌 **我在這裡犯的錯特別值得記**：我讀了 `28b8b13`，發現與 `mainDev` 的說法衝突，
就發了一則「急件」指控他錯，還特地寫「**我自己去讀了原始碼**」當作權威來源。
**我讀了正確的原始碼，回答了錯誤的問題。** 我沒有問的是：
**「我讀的這個 commit，是不是他講的那個 commit？」**
⇒ **「我親自驗證過」只在你驗證的對象與對方講的是同一個時才成立。**

🔑 **誤讀的機制值得記**：證據是 `FLUC:1896-1910` 的註解，它**真的**記著那個量測
（20.3 Mbps／10496 pps，逐位相同，iperf3 結束後 5 秒與 10 秒）——**數字是真的、行號是對的**。
但它的**最後一句**寫著「Introduced on this branch by the divide-by-zero guard (31b357a6),
so it is ours to fix.」⇒ **讀了量測，停在歸屬之前。**

🔴 **而我自己的錯更難看：決定性的事實本來就在這個檔案裡，我把符號讀反了。**
本檔原本就寫著「guard `31b357a` **不是 `origin/main` 的祖先**」。
我把它讀成「**baseline 少了保護**」，但那個 guard 是**造成缺陷的原因**，不是保護
⇒ 正確的推論是「**baseline 少了那個缺陷**」，剛好相反。
**同一個祖先關係，兩個相反的結論，差別只在你以為 guard 是因還是果。**

⇒ 連帶作廢：**我由此推出的「死流帶著非零速率搶進 top-k」的機制不成立**——兩邊都歸零。

> 🔴 **但「死流不會出現在前 K 名」這個推論也是錯的，08-28 實測否證了它——見檔尾。**
> 我當時寫「死流會沉到最後」，**那是從機制推的，沒有量。實際上它們占住前 10 名的 4–6 格。**
> ⚠️ **一個機制被否證，不代表它的結論被否證**——我把兩件事一起丟掉了。

🔑 兩句要記的：
> **把兩個缺陷相乘之前，先確認兩個都還活著。**（`開機手冊`）
> **預註冊防的是事後改判準，它防不了一個寫下來時就是錯的前提。**（`mainDev`）

⚠️ 仍**未**回答的：那些數值有沒有**驅動關機決策**。mainDev 的 handoff 原本寫「unread」，讀完後已更正。
🔑 他順手記下的形狀值得留：**交接檔會腐爛，而它腐爛的方式是「當時為真的句子」。**

## 🔴 兩個明確**不**宣稱（mainDev 寫的，保留）

1. **不宣稱這是 bug。** 15 秒保留可能是刻意的；**缺陷在端點沒有表達出這件事**。
   ~~若 `doc/2026-01-02_ndt_api.md` §4 有揭露 ⇒ 降級成「文件被忽略」。~~
   ✅ **08-28 查完了（`07408c6`，正本 `doc/audit/2026-08-27_flow-table-idle-tail/03_spec-disclosure-check.md`）：
   沒有揭露 ⇒ 不降級，措辭維持。** 但二分法漏了一支，而真相落在那一支：

   🔴 **文件不是沒說，是說了相反的話。** §4 第 358 行：
   `Returns detailed information about all **active** flows`。
   全檔搜 `idle|timeout|expire|stale|ended|retain|TTL` 命中 24 條，**沒有一條在 §4**
   （全屬 `is_up` 陳舊規則、OpenFlow 自己的 timeout 欄位、鎖 TTL、manifest 陳舊、`DEC_NW_TTL` 動作名）。
   ⇒ 不是「規格沉默、實作自由發揮」，是**規格做了宣稱而實作牴觸它**——高一個等級。

   🔑 **可轉移的**：**對一份文件做二分預註冊，天生就少一支。**
   「揭露／沉默」漏掉「**主張相反**」，而那一支的強度最高。**這類判準要三支起跳。**（審查員收下）

   📌 兩個附帶：`spec.FLOW_RECORD`（`tools/contract_test/spec.py:92-105`）**12 個必要欄位、無 optional、
   沒有任何欄位能表達「已死」**；`latest_sampled_time` 是唯一沾邊的，但要用它得先知道
   `FLOW_IDLE_TIMEOUT = 15000 ms`——**而那正是文件沒給的**。
   ✅ **修法契約相容**：`Obj` 的 `strict` 預設 **False**（`tools/contract_test/schema.py:129-138`，
   docstring 明寫加欄位不算破壞消費端）⇒ 加一個存活性欄位不必先改契約。
2. **不宣稱 13.3× 是普遍值**（見上面的公式）。

## 為什麼它是這樣被找到的

工單 M 的驗收指標 6-2（「`path` 非空的流佔比」）被這個尾巴**稀釋約 13 倍**——
分母裡塞滿已結束、且早就有路徑的流。
⚠️ **正確措辭是「damped 13×」不是「盲」**：`mean 0.9635 / min 0.677 / 39 個樣本裡 16 個 < 0.99`
⇒ **訊號在，只是被淹沒。** 兩者導向同一個決定（換指標），但**寫報告時不是同一句話**。

🔑 **可轉移的那一條**：**一個比值的靈敏度，可能由分子分母以外的第三個參數決定**
（這裡是 `FLOW_IDLE_TIMEOUT`，一個與被測變項完全無關的常數）。
**檢查寫入點、檢查母體，都看不到它。** 要看到它必須問：
**「分母裡有多少東西是與被測變項無關的？」超過一半就換指標。**
比 [[ratio-sides-must-share-a-population]] 深一層——兩邊同母體也擋不住。

相關：[[replace-vs-add-bug-shape]]（這是它的**時間版**：舊資料不是被覆蓋，是被留到超時）、
[[instrument-must-not-mimic-its-own-finding]]、[[cross-repo-component-ecosystem]]

## 🔴🔴 08-28 實測結案：**三個假說全錯，真相比兩個都糟**

兩臂各 170 次輪詢、churn 120 s ＋ 停流後尾巴 40 s（`W_base` 3367d0e9 ↔ `W_branch` a40e04ce）：

| | base | branch |
|---|---|---|
| 有流量時列出筆數（median） | 33 | 34 |
| 其中已結束 | 27 | 27 |
| **死流且排序鍵非零** | **0** | **0** |
| **前 10 名裡的死流（median）** | **4 / 10** | **2 / 10** |

1. 🔴 **我的「死流帶陳舊非零速率**搶進**前 K」：否證**（3040 次觀察全 0）
2. 🔴 **mainDev 的「兩臂相同 ⇒ 與分支無關 ⇒ 那就是結論」：也錯**——預設了「相同＝沒事」
3. ✅ **真相是第三個**：

> **死流的排序鍵是 0，卻照樣占住前 10 名——因為同時活著的流不到 10 條。**
> **不是「贏過」活流，是「填滿」活流下面的空位。**
> 消費端讀「前 10 名」拿到 **約 4 條真流 ＋ 約 6 具零速率屍體**。

🔑 **這比兩個原始假說都糟**：**就算每個速率欄位都正確歸零，前 10 名裡仍有 6 具屍體。**
成因是 **零存活性過濾 ＋ `min(k, size)`**，兩個分支都有，**修速率欄位修不掉它**。

📌 **我要記的形狀**：我和 mainDev 都在爭「**哪些東西排在前面**」，
而真正的問題是「**前面根本沒那麼多東西**」。
**兩個假說共用「母體夠大」這個預設，於是誰都沒去數活流有幾條**——
**兩邊的爭論碰不到它們共有的那個前提。**

⚠️ **不宣稱** 4/10 對 2/10 的差是 M 造成的：每邊只有一個臂，兩顆 binary 在這條路徑上無機制差異。

## 📌 binary 身分：**用行為定，不用 commit 定**

`3367d0e9` 追不到 commit（內嵌 40-hex 不是 git 物件、doc 只記 sha256）。
`mainDev` 改用**字串簽名**：查 `aabe605` 引入的字串在不在，
並用 `f5e3556` 的 `rate divisor check` 當**負控制**（在 base 缺席、另兩顆存在）
⇒ **證明這個測試分得出東西**；沒有負控制的話「三顆都有」和「grep 壞了」長得一樣。
再用**實測行為**（dead-AND-nonzero = 0）獨立對帳。

⇒ **規則細化**：宣稱 baseline 必須指名 commit；**commit 查不到時，
指名「你依賴的那個行為」並直接量它，是合法替代。**（見 [[benchmark-must-name-the-binary-it-measured]]）

## 🆕 08-29：同一個端點的三件事，實測（正本 `doc/audit/2026-08-28_manual-verification-coverage/GENERATING-TRAFFIC.md`）

📌 行號更正：`FLOW_IDLE_TIMEOUT` 在 **`FlowLinkUsageCollector.hpp:35`**（本檔上面寫 :34）。
今天親自開檔讀的；purge 迴圈 `FLUC:2230-2280` 每秒掃一次 ⇒ 實際清除落在 15–16 s。

**① 端點回傳的 IP 是裸 uint32，而同一個檔的鄰居用 `ipToString`。**
`FLUC:2300` 寫 `j["src_ip"] = flowKey.srcIP;` 直接塞整數；`:2726` 和 `HttpSession.cpp:1732`
用 `utils::ipToString`，而**下面二十行的 `purgeIdleFlows` 自己 log 的時候也用 dotted quad**。
⇒ 同一個 struct、同一個檔、兩種序列化慣例。`16777226` ＝ `10.0.0.1`（小端）。

🔴 **這件事讓我燒掉一整輪**：比對器搜字串 `"10.0.0.2"`，450 秒全報 0 命中，
**而端點從頭到尾都是對的**。因為每個 response body 都存了下來才救得回來——
只存判準的布林值就會寫出一份 FAIL 的假報告。
⇒ **要比對這個端點，先解碼再比，不要拿 dotted quad 去 grep。**

**② 15 秒尾巴 end-to-end 實測確認**（本檔以前只有 churn 工作點的統計）：
單一 iperf3 h2→h1，記錄 **t+5 s 出現**（兩個方向都在，1.197 Gbps ＋ 25.1 Mbps ACK 流）、
**t+312 s 還在、t+317 s 消失**，client 約 t+302 s 結束 ⇒ **與 15 s 常數吻合**。

**③ `path[].node` 是超載欄位**：host 用 uint32 IP、switch 用 dpid（`1`），**同一個 key、兩個命名空間、沒有型別標記**。
消費端只能靠數值大小猜，那是啟發式不是規則。130 筆全部 3 hop、兩條互為鏡像。

## 🔴 08-29：**同一個常數，第二份文件出問題，而且方向相反**

本檔上面記了 `ndt_api.md` §4 的形狀：**規格宣稱 active，實作牴觸它**。
使用者手冊的 Generating Traffic 段是**另一種**壞法：

> "The API returns a JSON response containing the currently detected flow records
> (**or an empty list if no flows have been captured yet**)."

**空陣列滿足這句話 ⇒ 偵測完全死掉也會過。** 再加上手冊叫讀者**前景**跑 `iperf3 -t 300`
（卡住 prompt 五分鐘）**然後**才換終端機 curl ⇒ 15 s 早就到了。
實測掃「client 結束→curl」的間隔：**5 s 兩筆、20 s 與 30 s 都是零**（每格都斷言 client 真的傳了 GB 級資料）。
⇒ **壞掉時會過，正常時看不到東西。** 已修：`~/NDTwin-Website` `f17d2c5`（**本機未推**）。

🔑 **兩份文件、同一個常數、兩種相反的失效**：一份**主張相反**（強度最高），
一份**兩支都叫通過**（根本沒有紅燈）。⇒ 查一個未揭露的常數時，
**不要只問「文件有沒有說」，要問「文件的驗收句有沒有一支會失敗」**。
見 [[verify-the-purpose-not-the-mechanism]]。
