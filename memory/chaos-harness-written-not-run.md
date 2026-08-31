---
name: chaos-harness-written-not-run
description: 🏁 08-29 chaos harness 首次 live 跑完（null round ＋ 四個 G1 對照）：偽陽性地板＝0（安靜與有流量各一輪），但**十三個缺陷全在 harness 自己身上**，G1 仍只有 1/7（只有 INV-06 真的燒紅），--full 照設計拒絕。正本＝doc/audit/2026-08-28_chaos-harness/05_first-live-run.md
metadata: 
  node_type: memory
  type: project
  originSessionId: c6089ab0-73c9-45fb-9a1f-6926ea449a77
  modified: 2026-08-30T13:11:30.174Z
---

⚠️ **檔名已經過時但沒有改**（原本是「寫好了但一次沒跑」）。檔名是位址，改名會斷 MEMORY.md
與 [[ndtwin-current-state]] 的引用；內容才是真的。**它已經跑過了。**

08-29 由 `開機手冊` 執行，`8/29 auditor` 派工。commit `efd2fe1`（工作分支）＋ `a8bec55`（audit-raw）。

## 結果：地板是 0，但**十三個**缺陷全是 harness 自己的（首報寫九，之後又長出四個）

| | 值 |
|---|---|
| 偽陽性地板（安靜） | **0** |
| 偽陽性地板（**有流量**＝注入輪真正的條件） | **0** |
| 有吐出判決的不變量 | **7/8** |
| **G1 對照真的讓不變量變紅** | **1/7**（只有 INV-06） |

⇒ **`--full` 仍然拒絕，那道拒絕留著。** 除了 INV-06，其他七個的 PASS 都還不算證據。

## 🔑 三個可重用的判準（比 0 這個數字重要）

### 1. 第一輪的違規是**捏造的**，而它長得跟真發現一模一樣

`switch_flags` 用 `dpid` 當 key，而**128 台 host 全都 `dpid: 0`** ⇒ 塌成一格、最後一個
（`h128`, `is_up=true`）被當成第 11 台交換機。INV-01 於是報：

> 「graph 說 11 台 up，只有 10 個 bmv2 行程——分身正在替死掉的交換機背書（A-1 形態）」

**三條規則同時破**：①儀器產出自己要找的形狀；②誤差是**常數** ⇒ 該不變量在 null 輪與注入輪
給一樣的答案＝**零解析度**；③127 台 host 靜靜消失，而證據欄印著自信的 `"total": 11`
——**無聲丟失長得像覆蓋率**。修法：照 `vertex_type` 過濾，並且**抓不到判別欄位就 raise**
（`.get("vertex_type", 0)` 會在欄位改名那天無聲地把 bug 種回來，而且往樂觀方向）。

### 2. 🔴 **只有那個具破壞性的對照，一行都沒碰過系統，而它自己的 G2 說成功了**

`_c01_apply` 兩個獨立致命錯：發 **GET** 打只收 POST 的路由（`HttpSession.cpp:177`）、
帶 **`dpid`** 打讀 `ip` 的 handler（`:653`）。

**為什麼整個 build 都沒人發現**＝A-1 的簽章是「成功而且快得可疑」，**而沒配到路由的請求也很快**。
`_c01_verify` 量到 0.0069 s 就報「fast path reached」。
⇒ **儀器的失效模式與它要找的缺陷逐字相同**（[[instrument-must-not-mimic-its-own-finding]] 第八式）。
我做的 pre-state 快照、restore path、`setsid`、順序——全部正確，全部圍著一個沒有作用的動作。

### 3. 🔴 **G1 驗的是對照、不是不變量，然後印「FIRED」**

舊 `gate_g1_controls` 只呼叫 `ctl.verify()`（＝G2「缺陷有沒有重現」），
**整個閘門沒有呼叫過任何一個 invariant 函式**。判準問句：「**把不變量整個刪掉，這個閘門會變紅嗎？**」
答案是不會。⇒ [[verify-the-purpose-not-the-mechanism]] 在一個函式的距離上重演。
**舊碼在這一輪會印出 2 個 FIRED，兩個都是瞎的。**

## 我自己犯的兩個——都是「檢查站錯位置」不是「檢查寫錯」

- **基線取在注入之後**：第一輪就被抓到（G1-06 的 before 已經是 FAIL，因為 apply 先跑了）。
  **對照背了自己造成的失敗** ⇒ [[controls-decide-what-you-learn]]。
- **G2 的 verify 把它剛確認的缺陷修好了**（`_c06_verify` 尾巴 `release_lock`）⇒ 不變量接著看到
  健康系統，被判成 BLIND。**G2 只能觀察，不能修復；修復屬於 undo，排在不變量之後。**
  兩個都修好之後 **INV-06 才第一次真的燒紅**。

## 🔴 INV-07 在健康系統上、只要有流量就 FAIL

實測（不是推論）：跑著 iperf3 時 null 輪報「2 條流在停止後 16 秒仍有非零速率＝殭屍條目」，
**而流量根本沒停**。`quiet_s` 這個前提**寫在參數名字裡、沒有任何地方強制**。
致命處：`--full` **需要**流量（否則 INV-04/05 沒有解析度）⇒ **每一個注入輪都會發火**，
而且**假陽性與處理效應完全對齊**。已修成量網卡、忙就回 SKIPPED。

## 系統面的觀察（不是 chaos 發現，但會影響判讀）

- 🏁 **08-30 三個缺陷全部修掉了（`4ee086f`；手術前身＝`dff87f9`，批次 push 的 rebase 改了 sha、patch-id 相同），本節保留為病歷。**
  解析移進 `LockManager::parseRequest()`，**回傳決定、不取任何東西**；目標不再有預設值
  （`ttl` 仍可預設——時長不會讓請求作用在它沒指名的東西上）。三個拒絕變成 **400** 且各自
  說明是哪一種錯、**引用呼叫端送的值而不是伺服器替換後的值**；busy 維持 **423**（423 是重試、
  400 是別重試，舊碼用一句話混掉兩者）。
  **Mutation gate**：pre-fix 邏輯逐字放回 ⇒ **三個拒絕測試全紅、三個放行測試維持綠**。
  **兩支都 live 驗過**：畸形／缺 type／未知 type 全 400 且**之後 routing_lock 仍是空的**（判在狀態）；
  兩個 sibling app 送的 body 仍 200；第二 client 423；routing 被持有時 `power_lock` 仍可取。
  🔑 auditor 先掃過 `components.env` 七個 repo 確認**只有兩個呼叫端且都明送 `type`**
  （`Energy-Saving-App/src/app/http.cpp:425`、`Traffic-Engineering-App:71`），所以拿掉隱式預設
  **不會弄壞任何現有呼叫端**——這是「改跨 repo 契約前先數呼叫端」的正面案例。
  紅→綠的證據正本＝`doc/audit/2026-08-28_chaos-harness/07_fix-evidence.md`。

- 🔴 **原始的三個缺陷（⚠️ 機制已更正，08-29 auditor 讀碼）。**
  ❌ **原本記成「`lockName` 不分名字空間、任何名字都對到同一把鎖」——那是誤診。**
  `LockManager.hpp:38-43` 的 `stringToLockType` 對未知名字回 `Unknown`，`:65-68` **明確拒絕**
  ⇒ 送 `{"type":"alpha"}` **是會被擋下來的**。當初看到的現象是 harness 把欄位叫 `lockName`，
  而 handler 讀的是 **`type`** ⇒ **名字根本沒被讀到**（＝harness 自己的第十個缺陷）。
  真正的三條，全在 `src/ndt_core/http/HttpSession.cpp`：
  1. 🔴 **`:1928` 的 `catch (...)` 只留一句註解就往下走** ⇒ **畸形 JSON body 照樣取得 `routing_lock`**。
     ✅ **08-29 我 live 驗過，而且判在狀態不是回應**（不是只讀碼）：
     送 `"{this is not json"` → `{'status':'locked','ttl':5,'type':'routing_lock'}`，
     **接著第二個 client 拿不到** ⇒ 它是真的握著。
     ＝[[rejected-requests-can-still-act]] 的第八個實例，也正是 `01` 表裡 H5 要打的地方。
  2. **`:1925` 缺 `type` 欄位靜默替換成 `routing_lock`** ⇒ 以為自己拿私有鎖的人，
     拿走的是 routing 真正在用的那一把（**後果敘述照舊成立**）。
  3. **`:1946` 錯誤字串把「busy」與「invalid type」混成一句**，且回報**替換後**的值而非呼叫端送的東西
     ⇒ 會看到 `invalid lock type: routing_lock`（它有效，只是 busy）。

  🏁 **08-30 Adam 裁「修」，且修法已排除破壞契約的風險。** 我掃過 `components.env` 列的
  **全部七個** sibling repo：只有**兩個**呼叫這個端點，而且**都明確送了 `type`** ⇒
  修掉「缺 `type` 靜默替換」**不會弄壞任何現有呼叫端**。
  - `Energy-Saving-App/src/app/http.cpp:425` → `{{"ttl", 300}, {"type", "routing_lock"}}`
  - `Traffic-Engineering-App/Traffic-engineering-App.py:71` → `{"ttl": ttl, "type": "routing_lock"}`

  🔑 **驗收要兩支都跑**：畸形 body **被拒**（新行為）**且**正常 body **仍拿得到鎖**（舊行為沒壞）
  ——放行路徑正是上面兩個 app 的生產路徑（[[smoke-the-accept-path-not-just-refusals]]）。
  📌 它和 [[install-manual-clean-room-test]] 的 **P-1 是同一個問題的兩層**：
  P-1 ＝兩個元件搶著寫同一批交換機，而這把鎖就是本來該仲裁它的機制。

  ✅ **我自己複驗過才接受**（`stringToLockType` `:38-43`、`DEFAULT_LOCK_TYPE_STR` `:27`、
  三個 handler 都讀 `type`），**並從反方向再確認一次**：改送 `{"type":"power_lock"}` 之後
  回應變成 `{"type":"power_lock"}`——而在此之前**不管送什麼，回應永遠是 `routing_lock`**。
  🔑 **破綻一直印在我自己的輸出裡**：我送 `alpha`，回應說 `routing_lock`。
  我讀了我以為會在那裡的欄位，不是實際在那裡的欄位（[[verify-against-known-good-output]] 第五式）。

- 🔴 **這個更正的下游後果比更正本身大：`--null` 不是唯讀的，而且沒有任何地方講。**
  INV-06 要測互斥就**必須真的持有一把鎖**，而透過上面那個 bug，它每一輪（**包含 null 輪**）
  都在拿**分身真正的 routing 鎖**約 7 秒；`_c06_apply` 還把它續約到 ttl=30。
  ⚠️ **只有三種鎖、三種都是真的 ⇒ 沒有 scratch 鎖可用**，所以這件事修不掉，
  能修的是「沒人講」：現在一律明送 `type`、選 `power_lock` 當減害、
  且每一個 INV-06 finding 都帶 `side_effect` 欄位指名它拿走的是哪一把真鎖。

- 🔴 **修好它當場又弄壞 G1-06——而這是第二課**：我加了「拿不到鎖 ⇒ SKIPPED」的保護
  （避免把忙碌的鄰居誤判成缺陷），結果**它正好吞掉陽性對照**——對照的全部效果就是
  「留下一把不該被持有的鎖」。不變量從一小時前的 **FIRED 退回 BLIND**。
  🔑 **判準必須為「它本來要抓的那個情況」保留一支**（[[controls-decide-what-you-learn]]）。
  缺的是**脈絡**不是邏輯 ⇒ 由呼叫端補：G1 在 after 那次傳 `expect_free=True`，
  因為它自己的 baseline 幾秒前才證明那把鎖是空的。改完 **G1-06 重新 FIRED、地板仍是 0**。
- **INV-04 在 c=2 時容差是 ±138.6%**（196/√c 是對的）⇒ 兩條流時它幾乎不可能 fail。PASS 不能重讀。
- **INV-03 是空對空過的**（兩邊都 0 條規則）。
- **單一 iperf3 就把 CPU busy fraction 從 0.045 拉到 0.33–0.39** ⇒ 繼承來的 0.15 門檻
  **在任何 chaos 之前就被普通流量越過**。校準要從這個數字起跳，不是從 0.15。

## 下一步順序（`STATUS.md` 檔尾有同一份）

1. **G1-07 重新配對**（B-3 是 historical logging，INV-07 是 flow table 新鮮度＝**兩個子系統**，
   再怎麼跑都不會紅）。2. 用新加的 `traffic.sh` 實作 G1-04（它已經打得出 1.1 Gbit/s 超過宣告的 1 Gbps
   ＝就是 clamp 條件）。3. G1-01 要跑得先設計**對著真的關掉的交換機測過**的 restore
   ——現在的 undo 只見過健康的那顆。4. INV-02/03/05 的對照。5. CPU 門檻校準。

📌 **工單已開**：`doc/audit/2026-08-28_chaos-harness/06_ticket_acquire-lock.md`（L-1/L-2/L-3 分開寫），
commit `6adb688`。**六顆 commit 全推上去了**（`fix/flow-rate-divide-by-zero` ＋ `audit-raw`，
兩個 remote 都用 `ls-remote` 驗過同一個 sha）。

相關：[[benchmark-must-name-the-binary-it-measured]]（H-11＝沒有產出指認得出 binary）、
[[new-tools-are-the-first-thing-under-test]]、[[live-runs-find-what-tests-cannot]]、
[[injections-must-assert-their-own-success]]、[[failures-that-report-success]]、
[[mutation-gate-for-tests]]、[[lab-claim-handoff-protocol]]
