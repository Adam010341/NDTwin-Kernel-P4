# E-21 — 四個 link 端點納入 L2 契約

分支 `fix/e21-link-endpoints-in-contract`，base＝`fix/w8b-withdrawal-needs-observed-failure`@`8a3f71d1`。
**未併、未推。不動 C++**——本輪一行 kernel 碼都沒改，加的全是斷言。

[Co-developed with claude code -- Adam]

> 🔴 **「跑過」與「讀過未執行」分開寫**：每一節都標了是哪一種。
> **本單沒有對活 kernel 跑過契約**（單子明寫 live 由 orchestrator 用 `wt-integrate` 的
> `2be98d5297459249` 做）。下面所有 🟢 都是離線跑的（python，不需要 kernel、不需要建置）。

---

## 1. 裁決與問題

`DECISIONS.md`「grill §4E」第六輪：

> **E-21 四個 link 端點納入契約：開單納入**（含 `declaration_retained` 形狀與 dpid-0 的 400）。

問題出自 R2-W8b 的 §7-5：

> `declaration_retained` 目前沒有任何 consumer，手冊寫了、契約沒列
> （四個 link 端點本來就不在 `ENDPOINTS` 裡，沒有 response schema 可掛）。

精確講，缺的東西比「沒有 consumer」更難看一點：

- `/ndt/link_failure_detected` 與 `/ndt/link_recovery_detected` **從 kernel 有這兩條路以來就沒有契約**
  （`components.py` 有登記路由，`spec.py` 零命中——同 F-13「登記而無形狀斷言」的形狀）；
- `/ndt/inject_link_failure`／`/ndt/inject_link_recovery` 是 B-6 修法加的，一樣沒有；
- 於是 **`declaration_retained` 這個欄位在整個 repo 裡沒有任何 schema 指名過**。
  它是 wire 上唯一說得出「這顆 kernel 刻意讓你的 link 保持 down」的東西——
  **狀態碼兩種結果都是 200**，而且那是刻意的（`HttpSession.cpp:728-733`：Ryu 的 `on_link_add`
  對任何 4xx 會記 `"NDT REJECTED this notification … the kernel's view is now stale"`，
  在這裡那句話是假的，而且每次控制面重啟會對每條被拒的 link 各印一次）。
  ⇒ **狀態列不帶資訊，body 就是全部的訊號，而沒有人在檢查那個 body。**

---

## 2. 改了什麼

### 2.1 `tools/contract_test/spec.py`

**新的 schema**（放在 `DOWN_REASONS` 後面的「the four link endpoints」區塊）：

| 名稱 | 是什麼 | 對應 |
|---|---|---|
| `LINK_REQUEST` | 四個端點共用的 request body（四個鍵，`strict=True`） | 手冊 §1；§2／§2b／§2c 都寫「identical to §1」 |
| `HOST_EDGE_PAYLOAD` | dpid 0 的 host 邊 payload（四扇門用） | W8-7 |
| `NO_SUCH_LINK_PAYLOAD` | 兩個都非 0、拓樸沒有的 dpid（404 用） | — |
| `NO_LINK_CHOSEN_PAYLOAD` | 拓樸沒有 switch↔switch 邊時的退路，四個端點都會拒 | — |
| `TC_ATTEMPT` | `tc` 陣列的一格 | `NetemLinkFault.hpp` 的 `cutInterface`／`restoreInterface` |
| `TC_REPORT` | `OneOf(List(TC_ATTEMPT), Str(allowed=("skipped (not MININET)",)))` | 手冊 §2b 的兩種形狀 |
| `LINK_FAILURE_REPORTED` | §1 成功；`down_reason`／`until` **optional** | `HttpSession.cpp:558` |
| `LINK_RECOVERY_REPORTED` | §2 成功，兩種結果；`declaration_retained: Bool()` optional | `HttpSession.cpp:736-745` |
| `LINK_FAILURE_INJECTED` | §2b 成功；四個欄位全 **required**，`until` 釘死 | `HttpSession.cpp:831-846` |
| `LINK_RECOVERY_INJECTED` | §2c 成功 | `HttpSession.cpp:920-935` |

**為什麼 §1 的兩個鍵是 optional 而 §2b 的是 required**——這是本檔案一貫的規矩，不是隨手：
trunk 的 §1 回 `{"status": "link failure processed"}` 一個鍵（手冊 §1 明寫），
**結構檢查不能因為版本舊就紅**；而 §2b 這條路 **trunk 上根本回 404**，沒有「舊 kernel 的回應」
會被誤殺。少掉的那兩個鍵改由不變量回報。

**四個新的不變量**：

| 不變量 | 說什麼 |
|---|---|
| `inv_declared_failure_says_who_can_withdraw_it` | §1 的 200 要說得出「宣告是黏的」與「誰能撤」；缺 ⇒ 報（不是 pass、也不是 TOOL-PRECONDITION，因為它讀的就是受測回應本身，沒有第二來源可言） |
| `inv_recovery_withdrew_the_declaration` | §2 面對**自己 sibling 報過**的斷 ⇒ 不准拒。抓的是 W8b 閘門「方向 2」那一半：一條什麼都拒的規則一樣是綠的 |
| `inv_recovery_was_declined_and_said_so` | §2 面對**注入** ⇒ 必須拒，而且 body 要說得出來、要指到 §2c。**E-21 點名的形狀** |
| `inv_tc_half_is_reported_per_interface` | §2b／§2c 的 `tc`：兩端各一格、`ok:false` 要說原因、`ok:true` 要說跑了什麼 tc；skipped／refused ⇒ `ACCOUNTED-FOR` 不是紅 |

**十七筆 `ENDPOINTS`**，放在表的**最後**：

```
error  [400]  link_failure_detected__host_edge_dpid_zero
error  [400]  link_recovery_detected__host_edge_dpid_zero
error  [400]  inject_link_failure__host_edge_dpid_zero
error  [400]  inject_link_recovery__host_edge_dpid_zero
error  [404]  link_failure_detected__unknown_edge
error  [404]  link_recovery_detected__unknown_edge
error  [404]  inject_link_failure__unknown_edge
error  [404]  inject_link_recovery__unknown_edge
error  [400]  link_failure_detected__malformed_json
error  [400]  link_recovery_detected__malformed_json
error  [400]  link_recovery_detected__missing_fields
mutate [200]  link_failure_detected                              步驟 1
mutate [200]  link_recovery_detected                             步驟 2
mutate [200]  inject_link_failure                                步驟 3
mutate [200]  link_recovery_detected__declined_after_injection    步驟 4  ← E-21
mutate [200]  inject_link_recovery                               步驟 5
mutate [200]  inject_link_recovery_cleanup                       步驟 6
```

### 2.2 序列本身就是檢查（同 lock 序列）

| 步 | 端點 | 邊上的狀態 | 為什麼要有這一步 |
|---|---|---|---|
| 1 | `link_failure_detected` | `declaredDown=1, failureReported=1` | 記下「控制面說它看到斷了」 |
| 2 | `link_recovery_detected` | 兩個都清掉、邊抬起 | **花掉**那個 report ⇒ 撤回成功 |
| 3 | `inject_link_failure` | `declaredDown=1, failureReported=0` ＋ 兩端 netem | 造出「有宣告、沒 report」——**唯一**產得出 `declaration_retained` 的狀態 |
| 4 | `link_recovery_detected`（再一次） | 不變，邊仍 down | **必須被拒**，而且 body 要說 |
| 5 | `inject_link_recovery` | 清掉、邊抬起、netem 拆掉 | 唯一的無條件撤回 |
| 6 | `inject_link_recovery`（再一次） | 不變 | 冪等（`noop`, `ok:true`）＋ **第二道還原** |

狀態轉移逐條對過 `TopologyAndFlowMonitor.cpp:3090-3180`
（`setEdgeDownByDeclaration`／`setEdgeDownByReportedFailure`／`applyReportedLinkRecovery`／
`clearEdgeDeclaredDown`），🟢 **讀過未執行**（對活 kernel 的跑由 orchestrator 做）。

**為什麼排在整張表的最後**：`endpoints_by_category` 保留宣告順序，所以跑到這裡時所有唯讀檢查
都已經讀完一座沒有人動過的 fabric。步驟 3 之後那條 link 在 MININET 下是真的斷的，
中間只隔一個 HTTP 往返（步驟 4）；任何在那個窗口裡讀圖的檢查讀到的會是**這套測試自己弄壞的網路**。

**為什麼還要第六步**：runner 的主迴圈**不會因為前一個檢查失敗就跳過後面的**
（`run_contract_test.py:477-521`），所以步驟 4 判紅也不會讓 fabric 卡在斷線狀態；第六步是
第二道保險，同時把手冊 §2c 講的冪等性變成看得到的斷言。

### 2.3 那條 link 從哪裡來

`switch_to_switch_link(topology_path)`：讀拓樸檔，取
`(src_dpid, src_interface, dst_dpid, dst_interface)` **最小**的那條**兩端都是交換機**的邊。
在三個 shipped 拓樸上都是 `1:1 -> 5:1`（🟢 跑過），也就是 lw8b／lw8b2／lw8b3 用的同一條。

- **min()，理由同 `Context.a_dpid`**：兩次跑要打同一條，不然「s1:1 -> s5:1」報告兩次不是同一件事。
- **兩端都必須是交換機**：host 端 dpid 是 0，四個端點都拒，而且 host 邊本來就會被 host poll 抬回去。
- **拓樸裡沒有 switch↔switch 邊 ⇒ 回 `None`**，呼叫端改送一個四個端點都會拒的 payload。
  **不猜**：猜一條 link 等於在一條沒有人選過的邊上注入故障。
- **快取在路徑上**，不只是為了快：同一輪 `--allow-mutations` 裡 `modify_device_name` 會把
  `setting/*.json` 整個重寫一遍，六步必須全部指同一條。

⚠️ **這個函式讀檔，而 `Context` 也讀同一個檔。** 本來該住在 `Context`（`run_contract_test.py`），
但單子把可改檔案限定在 `spec.py`／`test_contract_spec.py`／閘門／文件，所以留在 `spec.py`。
見 §7-4。

### 2.4 `tools/contract_test/selftest_fixtures.py`

八筆新 fixture ＋ 十四筆新 `INVARIANT_CASES`。fixture **全部是手冊裡印出來的那段 body**，
手冊沒印的地方（§2c 的 `tc` 內容）照 `NetemLinkFault.hpp` 的建構逐欄抄，並在註解裡講明是哪一種。
`--self-test` 66 → **88 checks**（🟢 跑過）。

### 2.5 `tests/python/test_contract_spec.py`

+36 格（141 → **177**，🟢 跑過）。新增 `LinkEndpointContractTest`，還有兩處既有檢查跟著擴：

- `test_nothing_that_changes_state_is_categorised_as_a_read` 的 `writes` 清單補四個 link 端點
  ——這是表裡**最重的寫入**（兩個會把 link 宣告成 down 到有人撤為止、兩個會對真的介面掛 netem），
  分類寫錯的代價是一座 fabric。
- 檔頭加 `NDT_CONTRACT_DIR` 覆寫（形狀與理由同 `tests/python/test_l3_dispatch_drift.py`），
  讓閘門可以對**複本**評分而一個位元組都不寫進工作樹。

### 2.6 文件

- `tools/contract_test/README.md`：涵蓋率那行改成 🟢 **實跑貼上**的 45／37／8（原本 45／33／12），
  並寫明這四筆描述的是分支不是 trunk。
- `doc/2026-08-17_testing-manual.md`：既有的 09-06 那段不動，**後面加一段更正**（同檔既有慣例）。
- `doc/KNOWN-ISSUES.md` B-6 第二輪：加一則 🆕，並明寫 **B-6 狀態不變**（A-1）。
- `doc/2026-01-02_ndt_api.md`：**一個字都沒改**（單子明寫「§2／§2b 對不上的字 ⇒ 列 §7 不改」）。

---

## 3. 閘門（🟢 跑過）

`tests/shell/mutate_contract_link_endpoints.sh` — **15 變異、0 存活；4 對照、0 誤殺**。
逐字在 `RED-GREEN.md`。

形狀取自 `tests/shell/mutate_l3_dispatch_drift.sh`：**每個變異都寫進 `tools/contract_test` 的一份複本**，
lane 用 `NDT_CONTRACT_DIR` 指過去，真的檔案從頭到尾沒有被寫過（結尾用 sha256 對過）。
anchor 的唯一性仍然是對**真的檔案**數的，所以改寫措辭會在這裡與 `check_gate_anchors.py` 兩邊報缺 anchor，
而不是靜靜地變成一個什麼都沒改、然後把綠燈記成「抓到了」的 no-op。

兩條 lane 都真的跑（一條從不執行的 lane 什麼也不證明）：

| lane | 跑什麼 | 守什麼 |
|---|---|---|
| `spec` | `tests/python/test_contract_spec.py` | 端點表與 schema |
| `selftest` | `run_contract_test.py --self-test` | schema／不變量 對 手冊範例 |

不需要建置、不需要 kernel。

---

## 4. 沒做的

1. **沒有對活 kernel 跑契約。** lab 不是我的。orchestrator 的最小配方見 §7-1。
2. **沒有動 C++。** 手冊與碼對不上的地方全部只列在 §7。
3. **沒有動 `run_contract_test.py`／`schema.py`／`components.py`。** 前兩者見 §7-4／§7-5；
   `components.py` 早就登記了這四條路由（`--check-drift` 🟢 跑過：45 endpoints in sync）。
4. **沒有為新條目預先加 `baseline_diff_allowlist.txt`。** L4 的 baseline 通常不帶
   `--allow-mutations`，兩邊都帶的時候 `tc` 的 qdisc 字串會逐機不同——但那還沒有發生過，
   而那個檔自己說「登記了沒用到的項目會被報成 stale」。等真的看到再寫。
5. **`declaration_retained` 仍然沒有 consumer。** 七個 app 一個都沒讀它；契約是第一個讀的東西。
   跨 repo 只讀的規矩仍然成立。

---

## 5. 對帳

| 舊結論 | 現在 |
|---|---|
| R2-W8b §6：「四個 link 端點仍然沒有 contract、仍然沒有 consumer，數字不變（45 中的 33）」 | **前半推翻**：45 中的 **37**。後半仍然成立——沒有 consumer |
| R3-W8b §6：「四個 link 端點仍然不在 `ENDPOINTS` 裡（那是 E-21 另開的單）」 | **這張單做完了** |
| `doc/2026-08-17_testing-manual.md:685`「45／33／12」 | 已加更正段落：45／37／8 |
| R2-W8b §7-5「要不要納入 contract？」 | E-21 裁「納入」，已納入 |

---

## 6. 這是 `spec.py` 的第四邊

`spec.py`／`test_contract_spec.py` 這一輪之前已經被三邊各改過。合併時要對的是**行段**，不是檔案：

| 邊 | 動到 `spec.py` 的哪裡 |
|---|---|
| W8（`fix/w8-declared-link-failure-sticky`） | `DOWN_REASONS` 加 `declared` ＋ `GRAPH_NODE`／`GRAPH_EDGE` 的 `down_reason` optional 欄 |
| W10（`52224425`） | — |
| R2-PY（`0c00c7d2`） | — |
| **本單（第四邊）** | 見下表 |

（W10／R2-PY 動到的是同一批檔案的其他區段，逐行對照寫在 SUMMARY §6。）

**本單動到的 `spec.py` 行段**（皆為**新增**，未刪除任何既有行）：

| 行段（本分支 tip 上的行號） | 內容 |
|---|---|
| `19-20` | `import functools` / `import json` |
| `240-347` | 「the four link endpoints」schema 區塊（`LINK_REQUEST` … `LINK_RECOVERY_INJECTED`），插在 `DOWN_REASONS` 與 `FLOW_KEY`（`349`）之間 |
| `1047-1200` | 四個新不變量，插在 `inv_power_state_values`（`1202`）之前 |
| `1223-1268` | `switch_to_switch_link()`／`link_endpoint_body()`，插在 `# --- endpoint table ---`（`1270`）之前 |
| `1798-1963` | 十七筆 `ENDPOINTS`，接在 `intent_translator_text__incomplete_body` 之後、收尾的 `]`（`1964`）之前 |

`selftest_fixtures.py`：`116-192`（八筆 fixture 常數，插在 `FIXTURES = {`（`194`）之前）、
`277-296`（`FIXTURES` 尾巴）、`537-596`（`INVARIANT_CASES` 尾巴）。
`test_contract_spec.py`：`40`／`43`（`import json`／`import tempfile`）、`46-54`（`NDT_CONTRACT_DIR`）、
`990-999`（`writes` 清單補四筆）、`1341-1689`（`LinkEndpointContractTest` 與它的常數）。

### 🔴 與 R2-PY（`fix/contract-per-node-identity`, `0c00c7d2`）**必定衝突**的四處

實測（`git merge-tree`，🟢 跑過，結果在 SUMMARY §6）：`spec.py` 自己**乾淨**——它的兩段插在
`DISPATCH_STATUS` 與 `inv_graph_matches_topology` 之後，跟本單的三段互不相鄰。會撞的是另外三個檔：

| 檔 | 撞在哪 | 為什麼 |
|---|---|---|
| `tests/python/test_contract_spec.py` 檔頭 | 兩邊都加 `import json`／`import tempfile`，並且**都把 `sys.path.insert` 換成環境變數覆寫** | 但**變數名不同**：本單用 `NDT_CONTRACT_DIR`（跟 trunk 上已有的 `tests/python/test_l3_dispatch_drift.py` 同名），R2-PY 用 `NDT_CONTRACT_TOOLS`。見 §7-2 |
| `tests/python/test_contract_spec.py` 檔尾 | 兩邊都在 `PowerStateReadingCarriesBothFieldsTest` 之後 append 一整個大 class | 純 append，兩段都留即可 |
| `tools/contract_test/selftest_fixtures.py` 檔尾 | 兩邊都往 `INVARIANT_CASES` 尾巴 append | 純 append，兩段都留即可 |
| `tools/contract_test/README.md` | 兩邊都改涵蓋率那一行 | 兩邊的數字都是各自分支上算的；**併完要重算一次**（〈重算涵蓋率〉那段） |

與 W10（`fix/w10-nickname-overlay`）**不衝突**：它動的是 `modify_nickname`／`modify_device_name`
兩筆的 note 與 `test_the_device_rename_writes_back_the_name_it_found` 的註解，
與本單的 `writes` 清單相隔 35 行以上。

---

## 7. 要 Adam 裁的

見 `scratch/overnight-2026-09-05/fix/R3-E21-SUMMARY.md` §7。
