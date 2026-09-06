# FIX — the seven `ip[0]` sites (FINDINGS #88, W14)

日期：2026-09-06。分支 `fix/w14-index-zero-guards`（base：trunk `1536ff17`）。
worktree `scratch/overnight-2026-09-05/wt-w2`（沿用 W2 的樹）。**沒有 push、沒有 merge、沒有碰 lab。**

[Co-developed with claude code -- Adam]

---

## 1. 這張單修的是什麼

W2（#88）補了十六處無守衛的 `ip.front()`，它自己的 grep 又找到**七處**沒補：寫成 `ip[0]`、
散在另外三個子系統。W2 的 §6 把它們留下來，理由是「沒看過紅不算修完」。這張單補上那七處，
外加它們的紅。

`operator[]` **不是比較溫和的 `front()`**。libstdc++ 兩支都定義成 `*(_M_start + n)`，
而 default-construct 的 `std::vector` 的 `_M_start == nullptr` ⇒ 對空的 `ip` 取 `ip[0]`
是把 reference 綁到 null pointer 再讀穿它。跟 #88 的差別只有拼法。

### 1.1 七處，以及它們在 trunk `1536ff17` 上的行號

W2-SUMMARY §2.2 的行號對 base `f0687b34`；下表是**在 trunk 上重新定位**的結果。
七處全部成立，**沒有一處漂移**（W2 之後這三個檔在這些區段沒有被動過）。

| # | 檔案:行（trunk `1536ff17`） | 函式 | 型別 | 可達性 |
|---|---|---|---|---|
| 1 | `IntentTranslator.cpp:212` | `getSwitchIpByName` | SWITCH | 走不到（見 §3） |
| 2 | `IntentTranslator.cpp:657` | `performTask` / `GET_NETWORK_TOPOLOGY`，`switches[]` | SWITCH | 走不到 |
| 3 | **`IntentTranslator.cpp:665`** | `performTask` / `GET_NETWORK_TOPOLOGY`，`hosts[]` | **HOST** | **走得到** |
| 4 | **`IntentTranslator.cpp:702`** | `performTask` / `GET_ALL_HOSTS` | **HOST** | **走得到** |
| 5 | **`LLMAgent.cpp:243`** | `getCurrentTopology` | **HOST** | **走得到** |
| 6 | **`FlowLinkUsageCollector.cpp:2986`** | `getPathBetweenHostsJson`，src | **HOST** | **走得到** |
| 7 | **`FlowLinkUsageCollector.cpp:2987`** | `getPathBetweenHostsJson`，dst | **HOST** | **走得到** |

W2 標成「有守衛、不是缺陷」的兩處我複驗成立，沒有動：
`IntentTranslator.cpp:738`（`hostProp.ip.empty()` 早退，:733）、
以及 W2 自己補過的 `TopologyAndFlowMonitor.cpp:3565/3580/3802`、
`DeviceConfigurationAndPowerManager.cpp:1235/2277/2395`。

---

## 2. 走不到 vs 走得到：這一次是**實測**，不是讀碼推的

W2 §6.2 把 C 組的可達性標 🔵（讀碼推的），並記了一條反向證據：
`validateStaticTopologyJson` 對 `dpid == 0` 的 edge 端點會要求「這個位址要有節點持有」，
所以「host 空 ip ＋ 該 host 被 edge 以位址指名」的檔案**會在載入時被拒**。

那條反向證據是對的，而且**不涵蓋整個問題**。把載入路徑兩道門逐字讀完之後：

```
TopologyAndFlowMonitor.cpp:219   （validateStaticTopologyJson，第一道，在第一個 add_vertex 之前）
    if (vertexType == VertexType::SWITCH && addresses.empty()) → throw

TopologyAndFlowMonitor.cpp:759   （loadStaticTopologyFromFile，backstop）
    if (vp.vertexType == VertexType::SWITCH && vp.ip.empty())  → throw
```

**兩道門都只看 SWITCH。** 而 `:744` 的註解自己寫著「`at("ip")` throws on a missing key
but accepts an empty array」——所以一份宣告 `"ip": []` 的 **HOST** 節點兩道門都過，
一路走到 `boost::add_vertex`。

W2 的反向證據管的是 **edge 的 `src_ip`／`dst_ip`**：拿掉一個「有 edge 指名它」的 host 的位址
會被拒，因為那條 edge 的位址不再被任何節點持有。它不管**沒有 edge 指名的 host**。

### 2.0 只有一個寫者，所以只有一條路

把 host vertex 的兩個候選寫者都讀完：

| 候選寫者 | 會不會造出空 ip 的 HOST |
|---|---|
| `loadStaticTopologyFromFile`（`:696-786`） | **會**。兩道門只看 SWITCH（上面）。 |
| `updateHosts`（Ryu `/v1.0/topology/hosts`，`:1552-1760`） | **不會**，而且是兩重的：<br>① `:1568` `if (!host.contains("ipv4") \|\| host["ipv4"].empty()) continue;`<br>② **整支函式一次 `add_vertex` 都沒有**——它只更新既有頂點。 |

⇒ **靜態拓樸檔是唯一的路。** 這件事有兩個後果，兩個都要寫下來：

* 本單的可達性論證是**完整的**，不是「找到一條路」而已——沒有第二條要排除。
* **門 3b 一旦補上，這條唯一的路就關了**（見 §2.1.1）。那時本單的七處守衛變成第二層防禦，
  而 W15 工單自己就是這樣裁的（「3b 是檔案層拒絕，W2 是執行層不炸，兩層都要留」）。
  🔴 **但它們不會變成死碼**：`updateHosts` 的兩重保護裡，`:1568` 那一句是**一個 `if`**，
  而「整支函式沒有 `add_vertex`」是**沒有人寫下來的性質**。這個 finding 的整段歷史就是
  「不變量由別的子系統裡的一個 `if` 維持」出事的歷史。

### 2.1 這條路線寫成了測試

`tests/test_AddresslessNodeReplies.cpp` 的 `AddresslessHostLoadTest` 三支：

1. `TheShippedTopologyLoads` — 未改動的 `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`
   載得起來（前提；不成立的話下面兩支什麼都證不了）。
2. `AHostDeclaringAnEmptyIpArrayIsAcceptedAndReachesTheGraph` — 同一份檔案**加一個** `"ip": []`
   的 host 節點（沒有 edge 指名它），**載入不 throw**，而且那個 vertex 進了圖。
3. `TheSameEditOnASwitchIsRefused` — **同一個編輯**做在 SWITCH 上**被拒**，訊息含
   `empty "ip" array`，而且 `num_vertices == 0`（#61 的「拒絕不留半張圖」）。

第 3 支是控制組：它讓第 2 支不是「我寫 JSON 的方式造成的假象」。
**兩者的不對稱就是整個可達性論證。**

⚠️ 這三支是**載入器**的性質，不是本次守衛的性質。如果哪天載入器長出 host 側的位址檢查，
第 2 支會紅——那是**正確的訊號**（可達性前提變了，這份文件要改寫），不是壞掉的測試。
測試裡逐字寫了這句。

### 2.1.1 🔴 這個「哪天」已經排進今晚了

`scratch/overnight-2026-09-05/fix/TICKETS-0906/W3-3b-and-W15-validator.md`（worktree `wt-val`、
分支 `fix/w3-door3b-host-empty-ip`）的裁決逐字是「**W3 門 3b 也擋 host `ip:[]`**」，
而它引的 R0b live 觀測就是「(a) host `ip:[]` **收下**（W2 之後不炸、但不該收）」。

⇒ **兩條分支一旦相遇，本單的第 2 支測試會紅。** 這是預期內的，不是衝突，但**必須有人動手**：

* 正確的處理是把那一案**翻面**——斷言 throw、訊息指名該 host、`num_vertices == 0`，
  形狀照本檔第 3 支 `TheSameEditOnASwitchIsRefused`，並回來改本節。
* **不要刪掉那一案。** 兩層都要留（W15 工單自己也這樣寫：「3b 是檔案層拒絕，W2 是執行層不炸」），
  而這一案是「當時是哪一層在扛」的紀錄。
* 這段話同時寫在測試檔那一行的失敗訊息裡，撞到紅的人不用先找到這份文件。

本單的**七處守衛不受影響**：門 3b 關的是檔案這條路，`updateHosts`（Ryu 那條）是另一個
host vertex 的寫者，而「每個節點都有位址」這個不變量會再一次變成**另一個子系統裡的一個 `if`**。

### 2.2 那兩處 SWITCH 為什麼還是改了

改的是一致性，不是因為找到路。理由跟 W2 給的一樣，而且更強：
**同一個檔案裡七個一模一樣的運算式，補六個留一個**，正是這個 finding 的起點。
關掉 SWITCH 那條路的東西是**另一個子系統裡的一個 `if`**，五週前還不存在。

---

## 3. 修法：三種形狀，因為問的不是同一個問題

W2 的 helper 直接沿用，**沒有發明第二種寫法**（`include/utils/Utils.hpp`，W2 `b78c35f8` 新增）：

* `utils::firstAddressOf(const std::vector<uint32_t>&) -> std::optional<std::string>`
* `utils::firstAddressRaw(const std::vector<uint32_t>&) -> std::optional<uint32_t>`

🔴 **`firstAddressRaw` 在 W2 交付時是死碼**（W2 §7 第 3 題「要留還是刪？」）。
本單的第 6／7 處是它的**第一個呼叫端**——那兩處只要 raw uint32 當 map key，不需要字串化。
⇒ 這個問題的答案現在是「留」，而且有理由。

### 3.1 `optional` 直接當回傳值（第 1 處）

`getSwitchIpByName` 的回傳型別**本來就是** `optional<std::string>`，所以誠實的答案不需要新形狀：
拓樸沒有位址的交換機，就是這支函式叫不出名字的交換機。多一行 WARN，回 `nullopt`。

### 3.2 JSON `null`，不是 `"0.0.0.0"`，也不是把節點丟掉（第 2、3、4 處）

三處都在「列出網路裡有什麼」的回覆裡。決策與理由：

| 選項 | 為什麼不選 |
|---|---|
| `"0.0.0.0"` | 這個檔案已經被燒過兩次（`FIX-CPU-REPORT-NO-IP.md` §5）。捏一個看起來像量測的值，沒有任何呼叫端分得出來。 |
| 跳過該節點 | `GET_ALL_HOSTS` 問的是「有哪些 host」。因為少一個欄位就把節點從答案裡拿掉，是**回答了另一個問題**。 |
| **`null`** | ✅ 節點還在、`ip` 這個 key 還在（索引 `["ip"]` 的讀者仍找得到），而 `null` 是唯一沒有消費者會拿去撥的值。 |

🔴 `GET_NETWORK_TOPOLOGY` 的 SWITCH 與 HOST 兩個分支**共用一次計算**（`ipJson`），
是刻意的：這個缺陷的形狀就是「一個分支補了、旁邊那個沒補」。

### 3.3 散文，不是位址（第 5 處）

`LLMAgent::getCurrentTopology` 產的是 **system prompt**——LLM 接著會據以提出 flow rule。
在這裡捏 `h3(0.0.0.0)` 比在 JSON 裡捏更糟：那是餵給一個**工作就是拿它去動作**的元件的假事實。
替代值是 `h3(no IP address on record)`，非數字、不可能被讀成位址。

### 3.4 拒絕，而且說出是哪一台（第 6、7 處）

`getPathBetweenHostsJson` 已經有一個「host 找不到」的拒絕形狀（物件，帶 `missing_hosts` 陣列）。
本單照同一個形狀加 `hosts_without_address`。

為什麼不是回「找不到路徑」：一條 path 的 key 是 `(srcIp, dstIp)`，**沒有位址的 host 不可能是
那個 key 的任一端**。回「無路徑」會把一個**拓樸紀錄的性質**報成一個**網路的性質**。

---

## 4. 測試：七支 death test，因為普通紅線在這裡不存在

缺陷是 null 解參考。在普通 build 上，未修的碼**不會產生紅線**——它把整個 binary 帶走，
中途死掉，任何測試都沒有 `[  FAILED  ]`，還沒跑的 suite 也全部沒有結果。那不是證據。

W2 的閘門親自證過這件事：它的 M2 變異在 2026-09-04 被判 **SURVIVED**，
就是因為 fault 落在 in-process 測試裡、gtest 來不及給裁決（W2-SUMMARY §4.2）。

⇒ 七處**每一處一支 death test**，斷言 `ExitedWithCode(0)`：子行程做那件事然後乾淨退出。
未修的碼上子行程 SIGSEGV，父行程印出一行有名字的紅。
**containment 就是重點**：它把「這次跑掛了」變成「這一支測試失敗了」。

七支全部宣告在檔案裡所有 in-process 測試之前（gtest 依宣告順序跑同一個 suite）。

in-process 那些測試斷言的是**守衛之後回答了什麼**，那是另外一半：
一個用 `"0.0.0.0"` 換掉崩潰、或把節點從清單裡拿掉的守衛，是**把缺陷搬走**，不是修好。

---

## 5. 閘門

`tests/shell/mutate_index_zero_guards.sh`，形狀抄 `mutate_first_address_of.sh`。

🔴 **只有一個 build 目錄，而這是跟母閘門的差別。** 母閘門需要 asan round，是因為它的 M1–M3
把 UB 還原進**普通 in-process 測試**裡。本單用 containment 取代 sanitizer：把 `ip[0]` 還原回去
之後**子行程**死掉，父行程印出

```
[  FAILED  ] AddresslessNodeTest.<name>
```

——普通 build 上一行有名字的普通紅線。這比「sanitizer 說了話而且 rc 非零」是**更強**的證據，
而且不用第二棵 build tree。

🔴 **GROUP 1 跑比較窄的 filter**，理由不是省時間：M4（「src 那一端的 subscript 回來了」）之下，
death test 是被關住的，但 in-process 的 `APathQueryToAnAddresslessHostIsRefusedAndSaysWhich`
會在**測試行程裡**出錯。gtest 寫到被重導的 stdout ⇒ block buffered ⇒ 崩潰可能把**已經印出來的**
紅線丟掉，而評分器就會讀到一次沒有裁決的跑、把變異判成 SURVIVED——
那是**對測試說謊**，不是對碼說謊。把 GROUP 1 限縮到 death test，父行程就完全不碰無位址節點。
`stdbuf -oL` 是這條的第二層保險。

閘門另外有一條 baseline 斷言：`--gtest_list_tests` 必須數到**七支** death test。
少一支就代表有一處沒有被關住的紅線，而閘門不會告訴你——所以它自己先拒絕。

### 5.1 逐字結果

**`16 mutations, 0 survived, 0 invalid` → PASS，第一次跑就過。** 逐字在同目錄的
`RED-GREEN.md`，raw 在 `raw/W14-04-gate.log`（05:45:03–06:55:21）。

* M1–M7＝七處站點**各一個紅**（工單只要求五處走得到的各一個）。
* M8–M13＝守衛在、答案說謊的那一半（捏 `0.0.0.0` 兩處、丟掉節點、拒絕不說是哪一台、
  兩種 over-guard）——**sanitizer 永遠看不到這一組。**
* C1–C3 全綠 ⇒ 那 13 個 `caught` 不是「harness 對任何編輯都報紅」。

🔴 **第一次就 PASS 不是運氣，是先做了 preflight。** 母閘門第一次是 FAIL，兩個問題都在閘門
自己（M5 碰不到缺陷、M7 anchor 逐行撞兩次）。本單在跑之前先用一支腳本把 16 條 anchor 的
**逐行唯一性**（`assert_unique` 用 `grep -c -F`，是**行**導向）與**多行 anchor 的整體出現次數**
全部核過一遍，才送進排隊 —— 那一輪要跑 70 分鐘，失敗的代價不是重寫而是重排。

### 5.2 紅長什麼樣（節錄；全文在 RED-GREEN.md §1）

```text
Death test: networkTopologyThenExitZero()
    Result: died but not with expected exit code:
            Terminated by signal 11 (core dumped)
[  FAILED  ] AddresslessNodeTest.TheTopologyReplyOverAnAddresslessHostDoesNotKillTheProcess
```

**signal 11 落在子行程裡，父行程活著把紅線印出來。** 這一行就是整份設計的理由。

---

## 6. 沒做的

1. **`TopologyAndFlowMonitor.cpp:1729` 沒修。** 見 SUMMARY §5：這是本單 grep 新冒出來的第八處
   （`(*m_graph)[*vertexOpt2].ip[0]`，SWITCH，`updateHosts` 裡），不在工單的七處內，
   也沒有測試。照 W2 的規矩：**沒有證據的守衛不算修好。**

   > 🔴 **2026-09-07 更新（W18 加註）：這一處已經修了。** 分支 `fix/w18-eighth-index-zero`
   > （base＝本分支 `e62c8d6f`）補上守衛、一支必死測試（`tests/test_AddresslessAttachmentSwitch.cpp`）
   > 與一個閘門（`tests/shell/mutate_attachment_switch_index_zero.sh`），文件在
   > `doc/audit/2026-09-07_fix-attachment-switch-index-zero/`。
   > ⇒ **這一族的正確總數是 24 處（W2 記 16、後來記 23，兩次都少算），現在 24 處全部有守衛。**
   > W2-SUMMARY §2.2 的「23 處」也已就地加註更正。
2. **API 手冊沒動。** 這三個回覆都不是 HTTP endpoint——`GET_NETWORK_TOPOLOGY`／`GET_ALL_HOSTS`／
   `getPathBetweenHostsJson` 只從 `IntentTranslator::performTask` 走得到（LLM 面向），
   `doc/2026-01-02_ndt_api.md` 沒有它們的條目。
3. **`answer_agent_prompt.txt` 沒動。** 它只描述**請求**形狀，不描述回覆形狀。
