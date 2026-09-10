# FIX-DECLARED-LINK-FAILURE — KNOWN-ISSUES **B-6**（＝OV-4）／工單 **W8**

分支 `fix/w8-declared-link-failure-sticky`，基底 **trunk `1536ff17`**（2026-09-06）。**未併、未推。**
[Co-developed with claude code -- Adam]

裁決來源：DECISIONS 第四輪（2026-09-05 18:2x）逐字——
「**C（宣告黏住＋`down_reason:"declared"`）＋另開 `inject_link_failure/recovery` 端點
（MININET 下 kernel 對兩端下 tc netem，faults.sh 的 qdisc 快照邏輯要搬進去）；實體機房只有 C。
先查七個 app 有沒有對 down_reason 窮舉。**」

---

## 0. 證據等級（沿用 fixplan §0.1，不可混用）

- 🟢 **本 session 親自跑過**：第 0 步的七個 app grep、`sudo -n -l`、gtest、變異閘、
  `check_gate_anchors.py`、`contract_test --self-test`、`ctest`。逐字在 §3／§4。
- 🔵 **讀碼推的**：機制段的檔:行（全部開檔讀過）。
- 🟠 **別人跑出來的**：§1 的 5/5 與 30 s 上界，出自 09-04 夜巡 R2-B。**我沒有複驗**，
  也**沒有 live 驗這次的修法**（lab 不是我的；本單全部是離線證據）。

---

## 1. 一句話

**「被宣告的 link failure」現在有自己的旗標，拓樸輪詢不得覆蓋它，而且這個狀態是公開的**——
`updateLinks` 只在該邊沒有未撤銷的宣告時才寫 `isUp = true`；被宣告下去的邊在
`/ndt/get_graph_data` 回 `down_reason: "declared"`。另加一對 `inject_link_*` 端點，
在 MININET 下同時對兩端下 `tc netem loss 100%`，**掛在 htb 底下、不是掛 root**。

---

## 2. 行為變更前後對照

| # | 情境 | 修法前（trunk） | 修法後（本分支） |
|---|---|---|---|
| 1 | `POST /ndt/link_failure_detected` 後的第一次輪詢 | 邊被寫回 `isUp = true`（≈0.6 s 內），**且每 30 s 重複一次，永遠** | 輪詢拒絕改寫；`isUp` 維持 false |
| 2 | 🔴 **對外**：`/ndt/get_graph_data` 的邊 `is_up` | 宣告後 0–30 s 內回 **true**（宣告被靜默撤銷） | 回 **false**，直到有人撤回宣告 |
| 3 | 🔴 **對外**：邊的 `down_reason` | 恆為 `"none"`（宣告不留痕跡） | 被宣告的邊回 **`"declared"`**。**新值，不是新欄位**——`down_reason` 自 F-14 起就在 |
| 4 | 🔴 **對外**：`POST /ndt/link_failure_detected` 的回應 body | `{"status":"link failure processed"}` | 多兩個**加法**的 key：`"down_reason":"declared"`、`"until":"/ndt/link_recovery_detected"`。`status` 不變 |
| 5 | 宣告的壽命 | **上界 30 s**，自己消失，無 log | **永久**，直到 `/ndt/link_recovery_detected`（或 `/ndt/inject_link_recovery`）撤回。活過 Ryu 重新收斂與交換機重啟 |
| 6 | log | 覆蓋是**完全無聲的** | 每個「拒絕復活」episode 印一行 WARN（edge-triggered，一條邊一次，不是每輪一次）；宣告本身印一行 INFO |
| 7 | 邊的 `is_enabled` | — | **不變**。否決只擋 liveness 軸；admin 軸另有其人（`setEdgeEnable`／`setEdgeDisable`） |
| 8 | 衍生 liveness（`reconcileDerivedLiveness`）放下去的邊 | 交換機回來後被輪詢抬起 | **不變**——只有 `declaredDown` 會否決。這是本修法**最容易改壞的地方**，見 §3 的 M7／M8 |
| 9 | `/ndt/link_recovery_detected` | 只 `setEdgeUp` | 先 `clearEdgeDeclaredDown` 再 `setEdgeUp`。少了前者會publish `is_up:true, down_reason:"declared"` |
| 10 | 🆕 `POST /ndt/inject_link_failure`／`inject_link_recovery` | 404（路由不存在） | 宣告＋MININET 下兩端 `tc netem loss 100%`；非 MININET 回 `"tc":"skipped (not MININET)"` |
| 11 | 拓樸檔往返（`from_json`） | — | **不變**。`declaredDown` 刻意不讀回來，理由與 `down_reason` 同（沒有寫入端、loader 一律從 down 起跑） |

### 2.1 🔴 新的失效方向（**這是這次修法製造出來的，要一起記住**）

舊的失效模式是「注入提早結束」；新的是**「注入不會結束」**。
一次被忘記的注入現在是永久的，而且活過 fabric 的重新收斂。
`down_reason` 進 wire 就是為了讓它**查得出來**——掃 `/ndt/get_graph_data` 的
`down_reason == "declared"` 是機械化的收尾檢查。
**「注入後必須斷言注入成功」那條紀律，兩個方向都要斷言：窗內成立、窗後解除。**

---

## 3. 機制（檔:行，全部開檔讀過）

### 3.1 為什麼是**第五個旗標**，不是把 `downReason` 加一個值

這是本次修法唯一一個非機械的設計決定，也是**選項 C 唯一可能被實作錯的地方**。

`downReason` 由 `reconcileDerivedLiveness` **擁有**，而它**每一輪都重寫那個欄位**
（`TopologyAndFlowMonitor.cpp` pass 2：被切斷就寫 `SwitchUnreachable`，沒被切斷且值是
`SwitchUnreachable` 就清成 `None`）。把宣告存在那個欄位裡 ⇒
**第一次碰到這條邊的交換機故障就會把宣告吃掉**，而且吃掉之後不會有人知道。

所以 `EdgeProperties` 多一個 `declaredDown` bool（`include/common_types/GraphTypes.hpp`），
語意分工照頂點那三個旗標的先例逐字對應：

| 欄位 | 回答什麼 | 誰寫 |
|---|---|---|
| `isUp` | 這條邊在載流量嗎 | liveness 推導 **與** discovery。**一個觀測** |
| `downReason` | **推導**為什麼把它放下去 | `reconcileDerivedLiveness`，每輪重寫 |
| `declaredDown` | 有人宣告這條 link 壞了嗎 | **只有**推播路徑（宣告／撤回）。discovery 與推導都不准碰 |

wire 上只有一個 `down_reason`，兩者同時成立時由 `effectiveDownReason()` 決定公布哪一個：
**公布 `declared`**，因為 `switch-unreachable` 會自己好、`declared` 不會，
把會自己好的那個蓋在上面等於把要人處理的那個藏起來。

### 3.2 三處改動（＝工單 §3）

| 位置 | 做了什麼 |
|---|---|
| `include/common_types/GraphTypes.hpp` | `DownReason` 加 `Declared`＋`downReasonToString` 的 `"declared"`；`EdgeProperties` 加 `declaredDown`；新增 `effectiveDownReason(const EdgeProperties&)`；`from_json` 加註解說明為何不讀回 |
| `include/ndt_core/collection/TopologyAndFlowMonitor.hpp` | 宣告 `setEdgeDownByDeclaration`／`clearEdgeDeclaredDown`／`getEdgeDeclaredDown`，doc block 照 `setVertexPoweredOffByCommand` 那段的形狀；新增 `m_linkResurrectionDeclined` |
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp` | 實作那三個；`updateLinks` 的無條件 `isUp = true` 前加否決分支＋edge-triggered WARN；`run()` 的 header 註解補上「不變式的前提現在被檢查了」 |
| `src/ndt_core/http/HttpSession.cpp` | `handleLinkFailure` 兩處改叫宣告版；`handleLinkRecovery` 兩處先撤回再抬起；`get_graph_data` 的邊改用 `effectiveDownReason`；新增兩個 inject handler 與路由 |
| `include/utils/NetemLinkFault.hpp`（新） | netem 掛載點的純函式＋`tc` 的 runner seam |

### 3.3 為什麼 `updateLinks` 只否決 `isUp`

`isEnabled` 是 admin 軸（「控制面驅動得動這條邊嗎」），discovery 對它報到的每一樣東西
無條件寫 true。連它一起否決 ⇒ `/ndt/link_failure_detected` 變成一個隱形的 `DisableSwitch`：
邊會從「不通」變成「不可路由」，而 API 沒有任何地方這樣說。閘門的 M6 就是這一顆。

### 3.4 netem 那一半：**唯一真正要小心的事不是「跑 tc」**

`tc qdisc add dev X root netem loss 100%` 在 TCLink 介面上**不是加一層，是取代 htb**——
頻寬整形靜默消失，而 `tc qdisc del dev X root` 還原的是 kernel 預設、不是 htb。
兩個指令都回成功、慣用的「netem 殘留＝0」檢查看不見。2026-08-13 整夜的 OVS 輪就是這樣沒的。

`include/utils/NetemLinkFault.hpp` 是 `tools/test_workflow/faults.sh` 的 `netem_attach_point`
搬進 kernel，**刻意照抄而不是重寫**：

- 讀 `tc qdisc show dev X` 的**活的**樹；root 是 `htb` ⇒ 掛 `parent <handle><default>`
- 沒有整形 ⇒ 掛 `root`（P4 runbook 的配方在這裡才是對的）
- **已經有 netem ⇒ 拒絕**（疊上去之後還原就分不清是誰的）
- 還原時**再讀一次樹**、刪在 netem 實際掛的位置，**不靠記憶**——
  kernel 可能在注入與復原之間重啟過，靠記憶的還原在那種情況下會把故障永久留在機器上
- 還原後再讀一次，**netem 還在就報 `error` 不報成功**（faults.sh 用整樹 diff 做的那個斷言，
  在這裡縮到這一個介面上）

sudo 權限（🟢 2026-09-06 我自己跑 `sudo -n -l` 確認四條都在）：
`tc qdisc {add,del} dev s[0-9]*-eth[0-9]* {root,parent *} netem *` 與 `tc qdisc show dev ...`。
**沒有改 sudoers。** 介面名由 `<bridge_name>-eth<port>` 推出、且必須符合 `s<N>-eth<M>`，
否則拒絕——不是為了跳脫（`utils::execArgv` 走 argv、不經 shell，名字永遠不是 shell 輸入），
是因為 grant 之外的名字會撞到 kernel 答不了的密碼提示，那個錯誤訊息幫不了呼叫端。

---

## 4. 第 0 步：七個 app 有沒有對 `down_reason` 窮舉（🟢 本 session 跑的）

裁決要求「先查」。**沒有任何一個 app 讀 `down_reason`**，所以加 `"declared"` 不會踩到窮舉。

```
$ grep -rn "down_reason|downReason|down-reason" /home/adam/{Energy-Saving-App,Web-GUI,
    Traffic-Engineering-App,Network-Traffic-Visualizer,Network-State-Recorder,
    Simulation-Platform-Manager,Network-Traffic-Generator}
（七個目錄全部 0 命中；目錄非空：27／87／4／108／1343／27／20364 個檔）
```

兩個最可能出事的地方也開檔看過：

- `~/Energy-Saving-App/include/common/GraphTypes.hpp` — 有自己的一份 `EdgeProperties`，
  但 `from_json` 只讀 `is_up`／`is_enabled`／頻寬等既有 key（`:87`），**沒有 `DownReason` 這個型別**，
  未知 key 由 nlohmann 忽略。
- `~/Web-GUI/src/types/graph.ts` — `GraphEdge` 介面**沒有 `down_reason`**；TS 介面對多出來的
  欄位在 runtime 不做任何事。

repo 這一側：`tools/contract_test/spec.py` 原本**根本沒有列 `down_reason`**（`Obj` 非嚴格，
多出來的 key 本來就過）。本次順手把它列進 `GRAPH_NODE`／`GRAPH_EDGE` 的 optional 並釘住
`("none","switch-unreachable","declared")` 三個值——**列出來才擋得住第四個憑空出現的值**，
形狀照 `left_link_bandwidth_source` 的先例。`--self-test` 66 checks 綠（§6）。

---

## 4.1 對帳（工單 §6.1）：**沒有任何既有量測是用這條路徑注入的** 🟢 grep 過、逐檔開過

`grep -rln link_failure_detected doc/` 的命中分兩類，**兩類都不受 B-6 影響**：

1. **Ryu 的通知，不是操作者的注入**：`doc/2026-08-10_ovs_manual_test_runbook.md:1038-1045`
   （OVS 事件驅動，`ifconfig down` 之後 31 ms 就 POST）、
   `doc/2026-08-10_p4_manual_test_runbook.md:582-592`（P4 的 LLDP beacon timeout，15–20 s）、
   `doc/audit/2026-08-15_fresh-acceptance-report.md:246`。
   斷線是**真的** ⇒ Ryu 把該 link 從 `/v1.0/topology/links` 拿掉 ⇒ **輪詢沒有東西可以復活**。
   這正是 09-04 那一輪 netem 對照臂量到的行為。
2. **API 冒煙測試，窗只有幾秒**：
   `doc/audit/2026-09-02_manual-usertest/run-03-opus/tester-files/tester-scripts/30_more_api.sh:15-18`
   是 `POST 失效 → sleep 2 → 讀邊 → POST 復原 → sleep 2 → 讀邊`。2 秒遠在 0–30 s 之內，
   而且它斷言的是「呼叫有效果」，不是「效果持續」。

⇒ **沒有結果需要被推翻或重跑。** 分界是「斷線是真的還是宣告的」——只有宣告的那一類會踩到 B-6，
而 `doc/` 裡沒有一份量測屬於那一類。

## 5. 閘門與測試

見同目錄的 `RED-GREEN.md`（逐字紅、逐字綠、變異閘全文輸出）。摘要：

- **新閘門** `tests/shell/mutate_declared_link_failure_survives_poll.sh`，
  **只 mutate `TopologyAndFlowMonitor.cpp`**（`GraphTypes.hpp` 是 header，動它＝全樹重編）。
  8 個變異 ＋ 3 個對照。兩個方向：把缺陷放回去要被抓（M1–M4），**修過頭也要被抓（M5–M8）**。
  🟢 **2026-09-06 跑完，exit 0：`8 mutations, 0 survived` / `3 widenings, 0 wrongly caught`**，
  還原後 `all 1 file(s) byte-identical`、`test binary sha unchanged: d226ec6c744fb23e`。
- **測試**：`tests/test_PollDoesNotResurrect.cpp` 的 `DeclaredLinkFailureTest`（9 個，
  跑真的 shipped 拓樸 `StaticNetworkTopologyMininet_10Switches.json`）、
  `tests/test_HttpSessionRouting.cpp` 的 `DeclaredLinkFailureWireTest`（6 個，
  **走真的 HTTP 端點**：POST → poll → `GET /ndt/get_graph_data`）、
  `tests/test_NetemLinkFault.cpp`（17 個，餵真的 `tc qdisc show` 輸出給假 runner，**不跑 tc**）。

🔴 **本單沒有 live 驗**。lab 不是我的，`ndt status` 開工時 `measuring nothing`／`claim none`，
我沒有 claim、沒有 `ndt up`。§2 的「修法後」欄全部是離線證據。

> 🆕 **2026-09-07 後續（W8b，分支 `fix/w8b-withdrawal-needs-observed-failure`）**：
> §7-2／§7-4／§7-7 三題被 Adam 裁完並修掉，**而 §7-2 先被 live 證實了**——lw8b 臂
> （09-07 00:08，OVS4，kernel `37d641fa9fd6fc14` 建自本分支 `017c060f`）重啟 Ryu，
> **本分支的宣告在 10 秒內被撤，9/9**。詳見
> `doc/audit/2026-09-07_fix-w8b-withdrawal-pairing/FIX-W8B.md`。
> **本單的閘門在那張單裡被改過兩處**：`declared-clear` 的 anchor 加了下一行註解才唯一
> （W8b 之後 `eprop.declaredDown = false;` 出現兩次），而 M3 的期望紅名單裡的 wire 案子
> 換成 `InjectRecoveryOutsideMininetWithdrawsTheDeclaration`——`clearEdgeDeclaredDown`
> 現在只有 `/ndt/inject_link_recovery` 走得到。

---

## 6. 回退方式

一個 commit 一件事，回退順序與相依：

1. 只回退 netem／inject（保留 C）：revert `include/utils/NetemLinkFault.hpp`、
   `tests/test_NetemLinkFault.cpp`、`tests/CMakeLists.txt` 的那一行，
   與 `HttpSession.cpp` 的兩個 handler＋兩條路由＋`components.py` 的兩筆。C 本體不受影響。
2. 回退整個 C：`declaredDown`、三個 API、`updateLinks` 的否決分支、`HttpSession` 的四處呼叫、
   `effectiveDownReason` 的使用點。**`DownReason::Declared` 這個列舉值可以留著**
   （不會有人產生它），但 `spec.py` 的 `DOWN_REASONS` 要一起拿掉那個值，否則契約說謊。
3. 文件：`doc/2026-01-02_ndt_api.md` §1／§2 的 🔧 段與 §2b／§2c、`doc/KNOWN-ISSUES.md` B-6 的
   〈修法（分支）〉段。

---

## 7. 未處理 / 明講不做

- **沒有 live 驗**（見 §5）。
- **沒有做選項 B 的到期**（`expires_after_s`）。工單 §4 說 C 與 B 可以疊，但那要一個沒有人量過的
  預設值，而那個預設值會決定一整批實驗的注入窗。裁決是先把語意修對。
  ⇒ **一次被忘記的注入仍然是永久的**，只是現在**看得見**。
- **`inject_link_*` 的 MININET 路徑沒有端到端測試**：那需要真的跑 tc。純邏輯（掛載點、還原、
  拒絕條件）在 `test_NetemLinkFault.cpp` 用假 runner 全覆蓋，HttpSession 那一層只測了
  非 MININET 的 `skipped`、400、404 三條——**因為那三條保證不會碰到機器**。
  「HttpSession 在 MININET 下真的會把兩個介面名算對」這件事**沒有被自動測試**，
  它靠 `mininetIfaceFor` 的讀碼與 `test_NetemLinkFault` 的名字檢查。列在這裡而不是假裝有。
- **`declaredDown` 不進 `from_json`** ⇒ kernel 重啟會忘記所有未撤回的宣告，
  **而機器上的 netem 不會跟著忘記**。這是刻意的（見 §2 表格 #11），但它意味著
  「重啟後 `down_reason` 乾淨」**不代表** fabric 乾淨；要用 `tc qdisc show` 或
  `tools/test_workflow/qdisc_snapshot.sh` 對帳。
- **`/ndt/link_recovery_detected` 仍然可以對一條沒有真的回來的 link 宣告 UP**，
  而輪詢只會抬不會放 ⇒ 那個樂觀狀態沒有東西會自動修正。這是 B-6 之外的舊事實，本單不動它，
  但 API 文件 §2 現在有寫。
- 🔴 **第二扇門沒有堵：`dst_dpid: 0` 可以把宣告打在 host 邊上，而 `updateHosts` 會把它抬回來。**
  `findEdgeBySrcAndDstDpidNoLock`（`TopologyAndFlowMonitor.cpp:2865-2881`）只比對兩個 dpid，而 host
  邊的一端 dpid 就是 0，所以那個 degenerate 呼叫會挑到該交換機的第一條 host 邊。否決只加在
  `updateLinks`，`updateHosts` 的兩處 `isUp = true` 沒有加。**刻意的**：工單 §3 指定的是
  `updateLinks`，F-16 的既有立場是 host 邊不該被這個端點定址，而把否決撒進 `updateHosts` 是把一個
  輸入驗證問題當成狀態機問題修——正是本閘門方向 2 在防的那種「修過頭」。兩條候選（端點拒收 dpid 0／
  否決也加進 `updateHosts`）留給 Adam。🔵 讀碼推的，沒有實跑這個呼叫。
- 🔴 **不屬於本單、但查證過的鄰居缺陷：chaos harness 的 `link_blackhole` 用不安全的 `root netem`。**
  `doc/audit/2026-08-28_chaos-harness/harness/actions.py:516-551`：apply 是
  `sudo tc qdisc add dev <iface> root netem loss 100%`（無條件 `root`，不讀 qdisc 樹），
  undo 是 `del ... root`，verify 只看 `"netem" in out and "loss 100%" in out`——**這正是
  faults.sh 說看不見那種破壞的檢查**，而 docstring 寫著「reversible」。
  同時：harness **不走** `/ndt/link_failure_detected`（0 命中）⇒ 工單 §6.2 對 B-6 的顧慮在今天的
  harness 上不成立，但上面這一條成立。**本單沒有改它。** 正確形狀在 `faults.sh` 的
  `netem_attach_point` 與本單的 `NetemLinkFault.hpp::planAttach`。
