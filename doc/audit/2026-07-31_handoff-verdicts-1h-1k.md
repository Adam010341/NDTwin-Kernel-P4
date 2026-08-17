# HANDOFF §1h/§1k:兩輪舊審查的逐項歷史判定(2026-07-31)

> 2026-08-15 自 `doc/2026-07-29_HANDOFF.md` 原文搬出(Adam 裁決),內容一字未改。
> 這兩節是**歷史判定**(對 `2026-07-30_audit-be3c242/` 與 `audit/2026-08-03_scoped/`
> 兩輪審查的逐項查證結果),不是待辦;混在交接筆記的「目前狀態」裡是那份文件難讀的
> 主因,故歸檔至此。文內「第 1h 節/第 1i 節」等章節互指沿用原文,1i/1j 仍在 HANDOFF。

### 1h. audit（`doc/audit/2026-07-30_audit-be3c242/`）的逐項判定（2026-07-31）

10 份摘要我逐項查證過。**不是每一條都成立**，而錯的那幾條錯得很具體，值得記下來。

**🔴 已修**

| 發現 | 查證結果 | commit |
|---|---|---|
| `setAllPaths` / `m_allPathMap` 完全無鎖 | ✅ **比 audit 說的更廣** —— 六處存取全無鎖，而 `m_allPathMapMutex` **宣告了從來沒用過**。`shared_lock` 只擋得住讀者之間。**而且是我讓它變嚴重的**：`refreshDestinationPathsPeriodically`（我加的）把「啟動時一次」變成「每 5–60 秒一次」 | `0596dd1` |
| `Controller.cpp` 丟掉所有 `OpResult` | ✅ 真的。這才是 `install_flow_entry` 回 200 的根因；我原本歸因「dispatcher 非同步」只對一半 | `8c25dbc` |
| `FlowDispatcher::stop()` data race | ✅ 真的，**外加兩個 audit 沒提到的**：`running_` 在鎖外寫入造成 **lost wakeup 死鎖**；`enqueue()` 不檢查 `running_`，`stop()` 後生出的 worker 沒人 join → `std::terminate` | `d5f5bfa` |
| `HttpSession` 輸入驗證讓例外變 500 | ✅ 真的 | `832d75c` |
| `route_flow` 靜默丟棄 5-tuple | ✅ 真的（我自己實測抓到的） | `c964946` |
| allowlist 沒有次數/時間上限 | ✅ **當天就被印證** —— 我 allowlist 掉的 `switch not found` 在 proxy 掛掉時噴 75,853 次 | `f5281a8` |

**🟠 已查證成立、未修**

| 發現 | 備註 |
|---|---|
| `setSwitchPowerState` **不論 curl 成敗都更新圖** | 比 audit 說的更嚴重：沒 `--fail`／`-w http_code`／`--max-time`，抓 HTML 第 2 個 `>` 到 `<` 之間的字，然後**無條件** `setVertexUp/Down`。TESTBED-only |
| `/ndt/disable_switch` 不存在，Energy-Saving-App 吞掉 404 | 我的 L3 確實印 `MISSING`。若 app 真的吞掉，**節能功能從來沒關掉過任何交換機** |
| `fencePerBurst_` 只有一行註解 | 真的，但恆為 `false` 所以無害 |
| `bytes.fromhex(f"...{dpid:02x}")` dpid ≥ 256 會崩 | 邏輯正確（和 LLDP beacon 待辦同一區） |
| `getAllPathsBetweenTwoHosts` 指數複雜度 DFS 且持鎖 | 未查證 |
| `/etc/exports` 無檔案鎖競爭（`ofstream` vs `sed -i`） | 未查證 |

**⚪ 判定 audit 錯了**

| 發現 | 為什麼錯 |
|---|---|
| 「`inet_ntoa` 造成全域資料競爭甚至 segfault」 | **在這個平台上不成立**。glibc 2.39 的緩衝區是 **thread-local**（我寫 C 程式證明主執行緒和子執行緒指標不同），而我 8 執行緒／16 萬次的併發測試**對 `inet_ntoa` 原版也通過**。也沒有 segfault 風險。我還是換成 `inet_ntop`，但那是**可攜性**不是修 bug（`95c7690`） |
| 「`syntheticPowerMilliwattsFor` 是 AI 幻覺、假裝功能完成」 | 框架不對 —— Mininet/bmv2 沒有 PSU，合成值是唯一選項，header 寫了整段說明，而且**原本**是 [0, 2⁶⁰) 亂數（1.9×10¹⁴ 瓦），是我改成合理的。**但底下有站得住的點**：API 沒告訴消費者這是合成的，Energy-Saving-App 分不出真假 —— 那是真的設計缺口 |
| 「`ryu_topology` / `kernel_notifier` 完全沒測試」 | **事實錯誤** —— 24 + 13 個測試早就在 |
| 「`topology_manager` 完全沒測試」 | ⚠️ **audit 當時是對的，是我判斷錯了。** 我引用的那 9 個測試（`test_unsupported_match.py`）是**我自己在 `c964946` 加的**，不是既有的 —— audit 的基準 `be3c242` 當時確實沒有。**這是我過度更正別人的一個實例**，由第二輪 scoped review 抓出來 |
| 「`Host: 127.0.0.1` 是 SSRF 技巧／繞過 Gateway 權限」 | gateway 設定不在這個 repo 裡，**從程式碼無法判定意圖**。可確定的是寫死且無註解，該解釋或移除；但「後門」的推論證據不足 |

### 1k. scoped review（`doc/audit/2026-08-03_scoped/`）的逐項判定（2026-07-31）

範圍是 `be3c242..576dd2a`（24 commit、+4566/−216，其中約 1900 行是新測試）。**這一輪的品質明顯
高於第一輪**：22 條發現裡我查證過的**只有 1 條是錯的**，而第一輪是 4 條。它也做了第一輪沒做的事
—— 主動列出「我檢查過而且認為沒問題的」，所以「沒出現在發現清單裡」可以解讀成「查過了」。

#### 🔴 4 條 high，全部成立，全部已修（commit `e188136`）

| 發現 | 我的獨立查證 |
|---|---|
| **`ctest` 是紅的，而我報告綠的** | ✅ 跑 `ctest` 立刻重現 3 個 SEGFAULT，全是我新加的 `test_OvsPowerStrategy.cpp`。原因：沒有 `Logger::init`，而 `Logger::instance()` 在 init 前是 null shared_ptr。**只有 3 個中招**是因為 `powerOn` 的 port 迴圈裡有 `SPDLOG_LOGGER_DEBUG`，沒有 saved port 的測試不進迴圈。⚠️ **這個要求早就逐字寫在 `test_ClassifierDropRule.cpp` 裡了，我沒照做** |
| **`KeyedFailureLog` 對間歇性故障永遠不報** | ✅ 自己寫探針編譯真 header 驗證：**99% 的 pass 都在失敗、十分鐘 → 報告 0 次**；10 秒 burst → 0 次。hold-off 量的是「連續」不是「累積」，未報告的 key 缺席一個 pass 就被 erase |
| **route-reinstall debounce 丟掉 walk 期間的變更** | ✅ 讀程式碼確認：worker 在 `install_all_pair_paths`（~60 秒）**之前**就離開監看 seq 的迴圈，而 `reinstall_worker_running` 整段都是 True → 早退丟掉 |
| **`wait_for_port` 的守衛是死碼** | ✅ 內層檢查和外層**逐字相同**。它從來沒偵測過註解宣稱的事 |

#### ⚪ 1 條判定它錯了

| 發現 | 為什麼錯 |
|---|---|
| 「`test_unsupported_match.py` 無法 import —— 三個 interpreter 都沒有 networkx」 | **L1 用的那個有。** `l1_unit_tests.sh` 的候選順序是 `$P4_PROXY_PY` 優先，也就是 `p4_proxy/venv/bin/python`，實測 `Ran 9 tests OK`。它測了三個 interpreter 但漏了 L1 實際選的第一個 |

#### ⚠️ 它抓到我一個「過度更正別人」的實例

「HANDOFF 把 `topology_manager` 的 9 個測試記成既有的」—— **成立**。那 9 個是
`test_unsupported_match.py`，**我自己在 `c964946` 加的**，audit 的基準 `be3c242` 當時確實沒有。
而我還用那個數字在第 1h 節宣告第一輪 audit「事實錯誤」。**就 `topology_manager` 而言，第一輪
audit 當時是對的。** 已更正第 1h 和 1i 節。

教訓：**否證別人的發現時，要查證的是「在他的基準上成立嗎」，不是「在我現在的樹上成立嗎」。**

#### 🟠 已查證成立、已修的 medium

| 發現 | 處置 |
|---|---|
| `AFailedPortCommandFailsTheWholeOperation` 檢查的是失敗那個 port **之前**的 port | ✅ 已修（`6731b56`）。改成失敗第一個、斷言後兩個仍然裝上並 up。mutation 確認現在殺得掉 |
| `SomethingTooBigForIntIsRejectedNotWrapped` 斷言的是兩個常數的算術 | ✅ 已修（`6731b56`）—— 刪掉那個斷言而不是改寫措辭，因為那個界限在 handler 裡、這裡碰不到 |
| `endPass()` 「呼叫兩次」的註解描述錯了後果 | ✅ 已修（`e188136`）。它說會重複報同一個 recovery —— 不可能，因為 recovered 的 key 在報告的同一次呼叫裡就被 erase。真正的後果**更糟**：把所有還開著的故障報成已恢復 |

#### 🟠 已查證成立、**未修**（下一批）

| # | 發現 | 為什麼還沒修 |
|---|---|---|
| 1 | **`app_id` 的修正完全沒測到** —— 把 `std::stoi` 放回去，207 個測試照樣綠 | 要能驅動 handler，而 `HttpSession` 沒有接縫（從 live socket + 11 個協作者建構）。**為這一個端點發明捷徑會讓另外 40 個看起來測過了** —— 這是要設計的接縫，見待辦 |
| 2 | **FlowDispatcher 的 lost-wakeup 修正沒有測試抓得到** —— 跑 300 次都存活 | 要真的重現 lost wakeup 需要控制排程時序。它說得對，我的測試只覆蓋了另外兩個 lifecycle 缺陷 |
| 3 | ~~`test_unsupported_match.py` 從來沒呼叫 `route_flow` —— 三個 `raise` 全改 `pass`，9/9 綠~~ ✅ **2026-08-13 已修**：`RefusalReachesTheEntryPointsTest` 直接驅動三個入口，斷言「拒絕先於任何 client 呼叫」；三個 raise→pass mutant 逐一驗證會紅 | 同 medium 1 的性質：只測了兩個 module-level helper |
| 4 | static 模式啟動允許第二個並行的 `install_all_pair_paths` | 需要 OVS + Ryu 驗證 |
| 5 | `describeCommandStatus` 把 `curl`／`snmpget` 的 exit 1／127 歸咎給 `ovs-vsctl`／sudo | **我搬到 `utils::` 時造成的** —— 它現在被 13 個 SNMP 呼叫點用到 |
| 6 | `_is_routable_unicast` 讓 `inv_flow_paths_non_empty` 檢查零筆 flow 也算 PASS | tooling 的假 PASS |
| 7 | `kernel_owns_log` 看不到 root 起的 kernel → 對手冊的啟動方式假 FAIL | 和第 5 項同一類：手冊教 `sudo -E` |
| 8 | 兩條 allowlist pattern 比它們寫的理由寬得多 | `field missing in P4: \[\]\.flows` 是未錨定的 `re.search` |
| 9 | `handleGetNickname` 把壞 dpid 記在 `inform_switch_entered` 的名下 | 一行 |
| 10 | `on_link_delete` 把圖的更新 gate 在一個沒有 timeout 的 `requests.post` 上 | 需要 Ryu 驗證 |

