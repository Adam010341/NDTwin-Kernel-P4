# FIX — finding #17 的第四例（與掃出來的第五例）：chaos harness 對只收 POST 的路由發 GET

分支 `fix/chaos-invariants-method`，base `eeda3cba`（當時的 trunk 頭），commit `84997c45`。
**純離線完成**：沒有 lab、沒有 claim、沒有 `ndt`、沒有 Mininet／bmv2／OVS、沒有編 C++、
沒有起任何 server。測試用 `probes._curl` 這個 seam 換掉真正的 curl——那個 seam 是 `probes.py`
自己的 docstring 指定的（"Replaced by the self-tests, so every status-handling branch below can
be watched go both ways without a kernel"）。

[Co-developed with claude code -- Adam]

---

## 1. 一句話

INV-01 的延遲檢查**從來沒有量到過一次 power-on**——它對只收 POST 的路由發 GET，404 被寬鬆包裝器
吃成 `None`，只剩下碼錶還在動，而「沒有路由的請求」也很快 ⇒ 每一輪都回報同一句
「A-1 early return」；現在它發正確的 POST＋`ip=`，**而且非 2xx 一律 SKIPPED、措辭裡不准出現
「A-1」或「early return」**，因為用指控自己的字寫成的否認，讀起來就是那句指控。

---

## 2. 前後對照

### 2.1 缺陷的兩半（都查證過源碼，不是猜的）

| | 舊碼 | 源碼怎麼寫的 | 後果 |
|---|---|---|---|
| 方法 | `GET` | `HttpSession.cpp:189`：`method == http::verb::post && target.starts_with("/ndt/set_switches_power_state")` ⇒ **只註冊 POST** | GET 掉出整條 if/else-if 鏈 ⇒ 404 |
| 參數 | `dpid=` | `handleSetSwitchesPowerState`（`HttpSession.cpp:866-867`）讀 `utils::queryParam(target,"ip")` 與 `"action"`，**完全不讀 `dpid`** | 就算改成 POST 也是 400 `Missing or invalid ip/action` |

兩個獨立、各自致命。而它還能生出結論，是因為第三個成分：`api_get_timed` 是**寬鬆**的
（`api_get` 把 `NotAnswered` 吃成 `None`），body 沒人看，只剩碼錶。

```
舊：doc/audit/2026-08-28_chaos-harness/harness/invariants.py:84
    _, dt = probes.api_get_timed(f"/ndt/set_switches_power_state?dpid={dpid}&action=on")
    if dt < 0.1:  →  FAIL "…nothing was attempted (A-1 early return)"

新：invariants.py:126（行號會漂）
    _, dt = probes.api_post_checked_timed(f"/ndt/set_switches_power_state?ip={ip}&action=on", {})
    except probes.HarnessBug   →  SKIPPED "this check did not run: …"
    except probes.NotAnswered  →  SKIPPED "the kernel refused this power-on rather than
                                           performing it (…), 沒有量到 duration"
    dt < 0.1 且真的是 2xx      →  FAIL（保留鑑別力，見 §3 的 N3）
```

🔑 **這是恆為真的判定**：不管 A-1 在不在、不管交換機是不是活的、在任何 fabric 上、
甚至沒有 fabric 的時候，它都回同一句。而它的形狀正好是 INV-01 自己要抓的東西
（「快得可疑的成功」），`instrument-must-not-mimic-its-own-finding`。

**對帳（不是我第一個發現的，兩份既有文件已各自記過同一個機制）**：
KNOWN-ISSUES A-4f 記「`invariants.py:78-90 inv01_powercycle_latency`
**其實構不到電源碼**」；`doc/audit/2026-09-02_fix-design-campaign/findings/A-4f.md:410`
在檢查另一件事時獨立判定「它送 **GET** 且帶 `dpid=`，兩者都不成立 ⇒ 請求從沒到過電源碼」。
兩份都停在「診斷」，沒有修，也沒有把它連到 `actions.py:_c01_undo` 的第五例。
**本工單推翻的不是那兩份的結論，而是「它只是沒效果」這個讀法**——它不是沒效果，
它每一輪都在產出一句對 NDTwin 的假指控。

### 2.2 第五例（finding 沒寫、掃出來的）

`actions.py:176`（舊）`_c01_undo` 的復原分支：

```python
probes.api_get("/ndt/set_switches_power_state?dpid=1&action=on")   # 回傳值直接丟掉
```

同一個家族、同樣兩半都錯、同樣走寬鬆包裝器、而且**回傳值連讀都沒讀**。它比檢查裡那個更貴：
這是 `_c01` 的**還原路徑**，而 `P4PowerStrategy.cpp:100-114` 記錄 off-then-on 不會把 P4 交換機救回來
⇒ 它靜靜失敗的結果，是把 fabric 留在「被認證為 up、但一個封包都轉不動」的狀態，
也就是這個 harness 存在的理由本身，之後每一輪量的都是這堆殘骸。

現在改成 `api_post_checked` ＋ `ip={S1_MGMT_IP}`；`_c01_undo` 不能拋（它是 cleanup 路徑，
拋出去會把 fabric 卡在半修好），所以它在既有的 readopt 進度旁邊**印出來**。

### 2.3 結構性的一半：`probes.assert_route`

只修被指到的那一行，會把形狀留給下一條搬家的路由（`_c07_apply` 就是為了這個教訓重寫的）。
所以守衛放在 chokepoint：`_request` 送出 curl **之前**呼叫 `assert_route`。

- **表不是抄的。** 讀 `tools/contract_test/components.py` 的 `scan_kernel_dispatch()`，
  直接 parse `src/ndt_core/http/HttpSession.cpp` 的 if/else-if 鏈（三種拼法都認得，
  第三種 `utils::pathIs(` 是 09-03 為 L-5 加的）。**在這裡再抄一份 = 多一個會爛的東西**，
  而爛掉的路由表的失效模式，正好是「拒絕 kernel 明明有服務的路由」。
- **讀源碼不讀 `KERNEL_ENDPOINTS`**，因為後者是手抄的、而且**現在就是舊的**（見 §6）。
- **`HarnessBug` 刻意不是 `NotAnswered` 的子類。** 這是整條 finding 的核心：
  「系統沒給出可推理的答案」（寬鬆包裝器可以吃掉，某些呼叫者真的容忍）與
  「這個 harness 問錯問題」（沒有任何容忍的讀法）本來是同一個值。現在前者仍然變 `None`，
  後者穿過所有寬鬆路徑。
- **在送出之前，不是之後。** 錯方法的請求對真 kernel 是一次真的往返、~0.007 s 回 404，
  而「快得可疑」正是呼叫端下一步要秤的東西 ⇒ 送出去本身就在製造證據。
- **範圍講清楚**：只管 kernel。`base=PROXY` 是 Ryu，這個 repo 不擁有它的 dispatch 表 ⇒ 不檢查，
  這個洞是真的，記在 §6 而不是假裝有蓋到。

### 2.4 完整的 HTTP 呼叫對照表（34 個呼叫點，0 個不符）

**怎麼證明它完整**（grep 在這個 harness 裡剛好四種漏法全都存在）：

1. **chokepoint 論證**：`probes.py` 裡每一個請求都經過 `_request` → `_curl`。
   所以「所有 HTTP 呼叫」＝「公開包裝器的呼叫點」∪「繞過 chokepoint 的 raw subprocess」。
2. **AST 走訪，不是 grep**：走每個 harness `.py` 的 `ast.walk`，抓每個 `ast.Call`。
   f-string、閉包、comprehension、巢狀函式 ast 全都看得到。
   模組層級的 `NAME = "literal"` 會被解析回來——`HISTORICAL_LOGGING` 是必要的那個案例：
   actions.py 刻意只把那條路由拼一次、在三個呼叫點內插，**grep `"/ndt/"` 三個都找不到**。
   包裝函式（`graph_data`／`flow_data`／三個 lock helper，共 16 個呼叫點）路徑根本不在呼叫點上，
   靠 `FIXED_PATH` 對回去。raw curl 的 argv 一個包裝器名字都沒提。
3. **反向檢查**：全 harness 沒有任何 `requests`／`urllib`／`http.client`／`socket`／`httpx`／
   `aiohttp` 的 import（`test_no_alternate_http_client_exists` 每次跑都驗）；
   `chaos.py` 與 `antioracle.py` **零** HTTP 呼叫（只用 `probes.run`／`bmv2_process_count`／
   `bmv2_provenance`）。
4. 🔴 **這張表本身是可執行的**：`tests/python/test_chaos_invariants_method.py` 的
   `TheWholeHarnessConforms` 每次跑都重新推導這份清單再逐條比對。
   明天多一個第六例，會在這裡紅，不需要有人記得 #17。

修完之後的狀態（`git rev-parse HEAD` = `84997c45`；行號是修後的）：

| file:line | 呼叫 | M | 路由 | base | 判定 |
|---|---|---|---|---|---|
| actions.py:112 | `api_post` | POST | `/ndt/set_switches_power_state?ip=…&action=off` | KERNEL | 符合 |
| actions.py:122 | `api_post_timed` | POST | `…?ip=…&action=on` | KERNEL | 符合 |
| actions.py:134 | `graph_data` | GET | `/ndt/get_graph_data` | KERNEL | 符合 |
| actions.py:139 | `api_post_timed` | POST | `…?ip=…&action=on` | KERNEL | 符合 |
| **actions.py:195** | **`api_post_checked`** | **POST** | **`…?ip=…&action=on`** | KERNEL | **🔧 第五例，本次修** |
| actions.py:201 | `api_post` | POST | `/p4/readopt/1` | **PROXY** | 範圍外（§6） |
| actions.py:234 | `flow_data` | GET | `/ndt/get_detected_flow_data` | KERNEL | 符合 |
| actions.py:248 | `acquire_lock` | POST | `/ndt/acquire_lock` | KERNEL | 符合 |
| actions.py:250 | `renew_lock` | POST | `/ndt/renew_lock` | KERNEL | 符合 |
| actions.py:267 | `acquire_lock` | POST | `/ndt/acquire_lock` | KERNEL | 符合 |
| actions.py:291 | `release_lock` | POST | `/ndt/release_lock` | KERNEL | 符合 |
| actions.py:326 | `api_post_checked` | POST | `/ndt/historical_logging?state=enable` | KERNEL | 符合（變數 `HISTORICAL_LOGGING`） |
| actions.py:369 | `api_post_checked` | POST | `/ndt/historical_logging?state=enable` | KERNEL | 符合（同上） |
| actions.py:400 | `api_post_checked` | POST | `/ndt/historical_logging?state=disable` | KERNEL | 符合（同上） |
| **actions.py:458** | **raw curl** | POST | `/ndt/acquire_lock` | KERNEL | **繞過 chokepoint，本次加自己的 `assert_route`** |
| actions.py:473 | `acquire_lock` | POST | `/ndt/acquire_lock` | KERNEL | 符合 |
| actions.py:475 | `release_lock` | POST | `/ndt/release_lock` | KERNEL | 符合 |
| actions.py:485 | `api_post` | POST | `/ndt/inform_all_destination_paths` | KERNEL | 符合 |
| actions.py:507 | `api_get_checked` | GET | `/ndt/get_all_destination_paths` | KERNEL | **未註冊，已在允許清單**（第三例，`efd2fe10` 已改成拒絕） |
| invariants.py:53 | `graph_data` | GET | `/ndt/get_graph_data` | KERNEL | 符合 |
| **invariants.py:126** | **`api_post_checked_timed`** | **POST** | **`…?ip={ip}&action=on`** | KERNEL | **🔧 第四例＝本工單主體** |
| invariants.py:160 | `graph_data` | GET | `/ndt/get_graph_data` | KERNEL | 符合 |
| invariants.py:195 | `graph_data` | GET | `/ndt/get_graph_data` | KERNEL | 符合 |
| invariants.py:205 | `api_get` | GET | `/ndt/get_switch_openflow_table_entries?dpid=…` | KERNEL | 符合 |
| invariants.py:206 | `api_get` | GET | `/stats/flow/{dpid}` | **PROXY** | 範圍外（§6） |
| invariants.py:257 | `flow_data` | GET | `/ndt/get_detected_flow_data` | KERNEL | 符合 |
| invariants.py:298 | `flow_data` | GET | `/ndt/get_detected_flow_data` | KERNEL | 符合 |
| invariants.py:347 | `acquire_lock` | POST | `/ndt/acquire_lock` | KERNEL | 符合 |
| invariants.py:375 | `acquire_lock` | POST | `/ndt/acquire_lock` | KERNEL | 符合 |
| invariants.py:379 | `release_lock` | POST | `/ndt/release_lock` | KERNEL | 符合 |
| invariants.py:387 | `acquire_lock` | POST | `/ndt/acquire_lock` | KERNEL | 符合 |
| invariants.py:390 | `release_lock` | POST | `/ndt/release_lock` | KERNEL | 符合 |
| invariants.py:445 | `flow_data` | GET | `/ndt/get_detected_flow_data` | KERNEL | 符合 |
| invariants.py:480 | `flow_data` | GET | `/ndt/get_detected_flow_data` | KERNEL | 符合 |

**合計 34｜符合 30｜不符 0｜允許清單 1｜proxy 2｜raw curl 1**

**修之前跑同一份掃描的結果是「不符 2」**：`invariants.py:84`（第四例）與 `actions.py:176`（第五例）。
`actions.py:469`（第三例）已經在 `efd2fe10` 改成拒絕，掃描把它列進允許清單而不是不符——
允許清單只免除掃描，**不免除拒絕**：那個呼叫仍然必須 catch 住並回報 NOT-ANSWERED，
`_h23_verify` 的 catch 這次跟著加了 `HarnessBug`（守衛現在在送出前就攔下它，是不同的例外型別，
只 catch `NotAnswered` 會變成 traceback）。允許清單另有兩條反向測試：
條目對應不到活的呼叫點就紅（放行了沒人要的東西），條目指到 kernel **真的有註冊**的路由也紅
（那是要修的方法缺陷，不是可以容忍的缺口）。

`probes.py` 自己的 8 個內部呼叫點（4 個委派包裝器＋4 個固定路徑 reader）不在表內：
那是 chokepoint 的實作，路徑是參數；固定路徑的那些在呼叫端用 `FIXED_PATH` 對回去了。

---

## 3. 閘門證據

🔴 **沒看過紅不算交付。** `tests/shell/mutate_chaos_invariants_method.sh`，
**11 mutations, 0 survived**，兩個方向。

```
baseline (must be green before any mutation):
  OK
  caught   M1: back to GET at a POST-only route (the finding)             (test_it_posts_with_ip_not_gets_with_dpid went red)
  caught   M2: back to dpid= at an ip-keyed handler                       (test_it_posts_with_ip_not_gets_with_dpid went red)
  caught   M3: the guard stops comparing the verb                         (test_get_at_a_post_only_route_is_refused went red)
  caught   M4: the guard stops checking that the route exists             (test_an_unregistered_route_is_refused went red)
  caught   M5: HarnessBug becomes a NotAnswered, so the lenient wrappers absorb it (test_harness_bug_is_not_a_notanswered went red)
  caught   M6: the refusal is written up in the finding's own vocabulary  (test_a_refusal_is_never_reported_as_an_early_return went red)
  caught   M7: a non-2xx is scored as the defect again                    (test_a_refusal_is_never_reported_as_an_early_return went red)
  caught   M8: the FIFTH instance returns to _c01_undo's recovery path    (test_every_kernel_call_uses_a_registered_method went red)
  caught   N1 (control): the guard refuses everything it cannot verify    (test_the_proxy_is_out_of_scope_and_passes went red)
  caught   N2 (control): every non-2xx refused, incl. a legitimate 404 for a missing flow (test_a_legitimate_404_still_comes_back_as_none went red)
  caught   N3 (control): INV-01 becomes a constant SKIPPED and can never fire (test_a_genuine_fast_success_is_still_a_finding went red)

baseline byte-identical: yes (probes.py, invariants.py, actions.py)
mutation gate: 11 mutations, 0 survived
```

**N 那一組是重點。** 「任何非乾淨 200 都拒絕」可以通過 M1–M8 全部，同時把 INV-01 變成恆為
SKIPPED，並且弄壞 INV-03 與 B-3 對照組——那兩個是**刻意**容忍非 200 的。
恆為 SKIPPED 比這次移掉的恆為 FAIL 更糟：它什麼都測不到，而且讀起來很謹慎。
這個 harness 做過一模一樣的交換——08-29 加在 INV-06 的守衛，一小時內就把自己的陽性對照吞掉了。

- 測試：`tests/python/test_chaos_invariants_method.py`，**27 cases, OK**，
  直譯器 `test_env/bin/python`（3.12），無 lab、無 build。
- 三個判定確實可分辨：`test_the_three_verdicts_are_actually_distinct` 用三種真的不同的輸入
  取得 `{FAIL, PASS, SKIPPED}`——任何常數都會在這裡紅。
- 閘門守自己的 baseline：mutation 全部套在 `/tmp` 的**副本**上（`NDT_CHAOS_HARNESS` 指過去），
  `doc/audit/2026-08-28_chaos-harness/harness/` 一個 byte 都沒被寫；anchor 的唯一性從**真檔**數，
  跑完再比三個檔的 sha256。
- `NDT_KERNEL_REPO` 把路由表釘在**真的** `HttpSession.cpp` 上 ⇒ 變異 harness 不會連
  「用來檢查 harness 的權威」一起變異。
- `tests/shell/check_gate_anchors.py HEAD --gates mutate_chaos_invariants_method.sh`
  → `ok(11)`，`1/1 cells ok (0 not ok, of which 0 were NOT CHECKED AT ALL)`
  ⇒ 這個閘門是機器讀得到的，不是 L-3 那種沒人檢查的 applier。

### 沒有打破的既有閘門

| | 前 | 後 |
|---|---|---|
| `tests/python/test_chaos_c07_control.py` | 20 OK | **20 OK** |
| `tests/shell/mutate_chaos_c07_control.sh` | 6 mutations, 0 survived | **6 mutations, 0 survived** |
| `harness/test_probes.py`（harness 自己的 parser self-test） | all passed | **all passed** |

c07 那支中間紅過，而且是**我改的東西造成的**，記在這裡：它有兩個 case
（`test_404_raises_and_carries_the_status`、`test_the_lenient_probes_still_answer_none_…`）
拿 `/ndt/whatever`、`/ndt/get_historical_data` 這種幻影路徑當「隨便一個 URL」來測**狀態處理**，
而路由守衛現在會在狀態處理之前就把它們擋掉。fixture 改成已註冊的路由，**測試意圖一字未改**
（主題本來就是狀態不是路由），並在第二個 case 的 docstring 裡把新的分界寫清楚：
**已註冊路由回 404（流不在）仍然被吃成 `None`；未註冊路由或錯方法則拋 `HarnessBug`**。
另外加一行 `os.environ.setdefault("NDT_KERNEL_REPO", REPO)`——沒有它，該檔自己的 mutation gate
把 harness 複製到 `/tmp` 之後 `probes.py` 走不到 repo，43 條路由一條都查不到，baseline 全紅。

---

## 4. 合併順序與衝突

- base：`eeda3cba`（分支時的 trunk 頭）。目前 trunk 已前進到 `50defbbe`
  （"Coverage: third dispatch batch (71, 17)…"，只動 `FINDINGS-COVERAGE.md`，
  而且那個 commit 就是把本分支登記成派工中的那一筆）。
- `git merge-tree --write-tree --name-only trunk HEAD` → **exit 0，樹 `ca556e43`，零衝突**。
- 交集為空：trunk 自 base 以來動過的檔案與本分支動過的檔案沒有任何一個相同。
- **順序無所謂**，可以直接併。唯一需要留意的是**未來**：任何同時動
  `doc/audit/2026-08-28_chaos-harness/harness/{probes,invariants,actions}.py` 或
  `tests/python/test_chaos_c07_control.py` 的分支要先併誰後併誰；目前 `refs/heads/` 底下沒有。
- 併完建議重跑兩支 chaos 閘門（各 <5 秒，不需要 lab）：
  ```
  PY=test_env/bin/python bash tests/shell/mutate_chaos_invariants_method.sh
  PY=test_env/bin/python bash tests/shell/mutate_chaos_c07_control.sh
  ```

---

## 5. 回退

單一 commit，`git revert 84997c45` 即可，沒有 migration、沒有落地狀態、沒有生成物。

回退之後會回到的狀態，講清楚免得有人以為只是少了一個檢查：

- INV-01 的 `inv01_powercycle_latency()` 回到**每一輪回報同一句 A-1 early return**；
- `_c01_undo` 的 helper power-on 回到**永遠 404 而且沒有人知道**；
- `_h5_apply` 的 raw curl 回到沒有路由檢查；
- `test_chaos_c07_control.py` 的兩個 fixture 回到幻影路徑（那時它們能跑，因為守衛不在了）。

**部分回退**：只想拿掉結構守衛、留下兩個呼叫點的修正，就把 `probes.py` 的 `assert_route`
從 `_request` 拿掉（`probes.py` 一行）；但這樣 `TheWholeHarnessConforms` 與
`ItMustRefuse` 會紅，而那正是它們該做的事——**別把測試一起刪掉**，那等於把第六例的偵測一起關掉。

---

## 6. 未處理

1. 🔴 **`tools/contract_test/components.py` 的 `KERNEL_ENDPOINTS` 現在是舊的，
   而 `tests/python/test_l3_dispatch_drift.py` 在 trunk 上就是紅的。** 我沒有修。
   - 實測（`eeda3cba` 與 `50defbbe` 都一樣）：
     `test_no_drift_against_the_hand_transcribed_table` FAIL，
     `['kernel registers GET /ndt/get_sflow_stats but KERNEL_ENDPOINTS omits it']`；
     其餘 11 個 case 綠。
   - 來源：telemetry-health 那支（#53／#56，`b466407b` 整進 trunk）在 `HttpSession.cpp` 加了
     `GET /ndt/get_sflow_stats`，沒有同步手抄表。**是一行的修法**，但它屬於 #53 的分支主人，
     而且把它塞進一個標題寫「chaos harness method」的 commit，正好是 CLAUDE.md 說的
     「commit message 沒有描述它的內容」。**建議另開一張單。**
   - 對本工單無影響：守衛讀的是 `scan_kernel_dispatch()`（源碼），不是手抄表。
2. **proxy（Ryu）那一面完全沒有守衛。** 兩個呼叫點（`/p4/readopt/1`、`/stats/flow/{dpid}`）
   的方法與路徑**沒有任何東西在檢查**，因為這個 repo 不擁有 proxy 的 dispatch 表、
   `scan_kernel_dispatch()` 也只認 `/ndt/*`。要蓋到它需要一份 `p4_proxy` 的路由掃描器，
   那是另一份工作。**現況是：那兩個呼叫我親自讀過並認為正確，但沒有機器在驗。**
3. **`inv01_powercycle_latency()` 沒有被 runner 接線。** `chaos.py:123` 只呼叫
   `inv01_power_state_agreement`；這個函式在整個 repo 裡**零呼叫點**。修好了，但要有人接上去
   才會跑到。（這也是為什麼改它的簽章 `dpid` → `ip` 沒有連鎖影響。）
4. **「只靠延遲」本來就是弱判準，這次沒動。** `probes.api_post_timed` 的 docstring 早就寫了
   （`_c01_verify` 為此重寫過）：快只代表「回得快」，不代表「跳過工作回得快」，
   第二個讀數需要旁邊一個狀態檢查。本工單把「refusal 不准算成 finding」修好了，
   但真 2xx 的 `dt < 0.1` 仍然是單一來源的判定。要補的話是在旁邊加 process count／graph 對照，
   跟 `_c01_verify` 現在做的一樣。
5. **沒有 live 驗證。** 全部離線。守衛擋下的兩個呼叫點是**靜態證明**（源碼 + 掃描器 + 測試），
   不是「我打過那個 endpoint 看到 404」。要 live 對帳的話，最短路徑是在有 lab 的時候
   對 `/ndt/set_switches_power_state` 各發一次 GET 與 POST，記 raw 進 audit-raw。
6. **`actions.py:507` 該讀哪條路由，仍然沒有答案。** 允許清單裡寫了原因：
   kernel 根本沒有 all_destination_paths 的讀取端點，proxy 的
   `/ryu_server/all_destination_paths` 是**不同的母體**，不是替代品。
   `efd2fe10` 就把它記成另一張單，本工單維持原判——**拒絕，不指控**。

[Co-developed with claude code -- Adam]
