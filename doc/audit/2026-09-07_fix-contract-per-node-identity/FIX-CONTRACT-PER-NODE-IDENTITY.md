# FIX — 契約測試的 `inv_graph_matches_topology` 加上 per-node 身分（W3b-3）

[Co-developed with claude code -- Adam]

分支 `fix/contract-per-node-identity`，base＝trunk `1536ff17`。2026-09-07。
裁決：`scratch/overnight-2026-09-05/DECISIONS.md`「grill §4D 第二輪」W3b-3 ⇒ **另開契約單**。
題目來源：`scratch/overnight-2026-09-05/fix/W3-3b-SUMMARY.md` §8 第 3 題、`W15-SUMMARY.md` §6。

## 1. 缺陷

trunk 的 `tools/contract_test/spec.py:382-406` 比對**三個基數＋dpid 集合**，句號。
它回答的是「這是不是**大小正確**的網路」，回答不了「這是不是**正確的**網路」。

而「被指到錯的模型檔」**是走得到的**，不是假設：
`tools/test_workflow/run_layers.sh:135` 的 `topo_for_mode` 用 **(mode, 活著的 host 數)** 挑檔，
**從來沒有問 kernel 它載入的是哪一份**；`setting/` 出貨了兩份「10 switch／4 host／40 edge／
同樣十個 dpid」的模型（OVS 與 P4）。⇒ 拿 A 的 fabric 去對 B 的模型驗，**全綠**。
這正是 KNOWN-ISSUES **L-1** 的科：把「跟另一個網路比」的差異當成產品的判決——這裡是當成「沒有判決」。

量化：R0b 的**六個壞模型檔**（`rounds/05-R0b-postmerge2.md` §2.1，與 R3 同一份），
每一個都只跟出貨的 `setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json` 差**一個欄位**。
把健康 fabric 的圖拿去對這六個檔驗，**修法前六個裡有四個一個字都不說**（`b`／`c`／`d`／`e`），
逐字紅在 `scratch/overnight-2026-09-05/fix/R2-PY-SUMMARY.md` §3：`AssertionError: False is not true : []`。

## 2. 修法

| 檔:行 | 內容 |
|---|---|
| `tools/contract_test/spec.py:382-406` | `dotted_ip`／`address_set`——位址正規化。兩邊的編碼不同（檔是點分字串、圖是 network order 的整數，**第一個 octet 在低位**），比之前必須先化成同一種 |
| 同上 `:409-437` | `inv_graph_matches_topology` 末尾多兩行：`_switch_identity` 與 `_host_identity` |
| 同上 `:439-480` | 為什麼基數不夠、比什麼、**刻意不比什麼**（整段設計說明） |
| 同上 `:482-508` | `_switch_identity`：key＝`dpid`，比 `brand_name` 與位址集合（**失敗**）、`device_name`（**ACCOUNTED-FOR**） |
| 同上 `:511-553` | `_host_identity`：key＝`mac`，比位址集合（失敗）、`device_name`（ACCOUNTED-FOR）；圖裡 mac 重複 ⇒ 失敗 |
| `tools/contract_test/run_contract_test.py:149-175` | `Context` 建兩張身分表 |
| 同上 `:210-224` | `_identity`：**key 在檔裡重複就整張表不建**，回一句 why ⇒ 不變量報 TOOL-PRECONDITION |
| 同上 `:226-236` | `_first_ip` 改呼叫 `spec.dotted_ip`（同一份真相，不是第二份） |

三個決定，都寫在碼裡：

1. **host 用 `mac` 當 key，不用 dpid、不用名字。** 每一台 host 的 `dpid` 都是 0
   （`probes.switch_flags` 就是為此把 128 台 host 數成一台 switch，`test_probes.py` 有紀錄）；
   而 `device_name` 是改名會動的欄位。出貨的十三份模型檔 host mac **全部唯一**（我掃過）。
   W10 的 nickname overlay 也是**用 mac 當 host 的 key**，同一個判斷。
2. 🔴 **`device_name` 只報 ACCOUNTED-FOR，不算失敗。**
   `modify_nickname`／`modify_device_name` 的改名**會持久化**——W10 之前寫回模型檔、W10 之後寫進
   `.test_run/nickname_overlay/` 並在載入時疊回圖上。⇒ **改過名的健康 fabric 上，圖與檔的名字本來就會不一樣。**
   在這裡判紅等於「有人改過名 ⇒ L2 每次都紅」，那支檢查一週內就會被繞過。
   `ACCOUNTED_FOR` 是這個 codebase 既有的第四種答案（`spec.py:48`）：印出來、不算失敗。
3. **key 在檔裡重複 ⇒ 不建表，改回 TOOL-PRECONDITION。**
   `{key: value for ...}` 遇到重複 key 會**默默丟掉一個節點**，然後拿圖去比一個不在那裡的節點。
   「安靜地做一個不可靠的比對」正是這整件事要移除的形狀。這是**關於手上這份模型檔的事實**，
   不是關於 kernel 的判決，所以走 TOOL-PRECONDITION 不走失敗。
   R0b 的檔 `a` 剛好就是這一種（R3 複製 h1 造 h9，連 `mac: 1` 一起複製）。

## 3. 修法後六個壞檔的成績（交叉配對：健康 fabric × 壞模型）

| 檔 | 壞法 | 修法前 | 修法後 |
|---|---|---|---|
| a | 多一台 `ip: []` 的 host | ❌ 抓到（host 數） | ❌ 抓到（host 數）＋ TOOL-PRECONDITION（檔裡 mac 重複） |
| **b** | s7 的 `ip` 清空 | ✅ **全綠** | ❌ **抓到**：`switch dpid 7 is served with addresses […], topology file says []` |
| **c** | s7 `brand_name` 打錯 | ✅ **全綠** | ❌ **抓到**：brand 不符，訊息說明 brand 決定電源與遙測派工 |
| d | 拿掉 `bridge_name` | ✅ 全綠 | ✅ **仍然全綠**——`get_graph_data` 不回這個欄位 |
| e | `ecmp_groups` 打壞 | ✅ 全綠 | ✅ **仍然全綠**——同上 |
| f | 多一條指向 dpid 4242 的 edge | ❌ 抓到（edge 數） | ❌ 抓到（edge 數） |

⇒ **淨增：2（b、c）。d／e 兩個結構上構不到，而且測試裡明講「構不到」而不是宣稱抓到。**

## 4. 🔴 這張單**沒有**關掉 #90／#91，也關不掉

W3-3b §8 第 3 題問的是「四扇門對契約測試全綠，要不要看 per-node 身分」。做完之後的誠實答案是：

> **per-node 身分擋的是「被指到錯的模型」，不是「模型本身是壞的」。**

#90（host `ip:[]` 被收下）與 #91（未知 brand 被收下）都是 **kernel 收下檔案然後忠實地照它服務**。
這支不變量比的是**圖 vs 它被交到手上的那份檔**——同一份檔的時候，兩邊**依定義**一致。
修法前綠，修法後還是綠。測試 `PerNodeIdentityDoesNotCloseTheLoaderDoorsTest` 就是把這件事釘死的
（其中 #90 那一支**刻意把 R3 的 mac 碰撞拿掉**，免得它「因為別的原因」變紅而看起來像抓到了）。

**關那兩扇門的是載入器的門 3a–3e**（`fix/w3-door3b-host-empty-ip`／`fix/w15-unknown-brand-rejected`），
不是契約測試。

## 5. 測試

`tests/python/test_contract_spec.py`：**141 → 164 支**（＋23）。
`run_contract_test.py --self-test`：**66 → 71 checks**（＋5，`selftest_fixtures.py` 的 `INVARIANT_CASES`）。

**fixture 是重建的，不是複製的**：六個壞檔用 `setting/` 那份出貨模型＋一個欄位的變更重建，
再用**當初真的餵進 kernel 的那個檔的 sha256** 釘住（`TheSixBrokenModelsTest`，六個全對）。
理由：那六個檔在 gitignore 的 `scratch/` 底下，而把 138 KB 幾乎一樣的 JSON 複製進 repo
是比較差的 fixture 不是比較好的——**sha 是比副本更強的宣稱**，它說「下面那一行變更就是全部的差異」。

`graph_as_served()`（把模型檔投影成 kernel 會服務的 `get_graph_data`）**本身是儀器**，
所以它拿**真實擷取的 payload** 對過：`doc/audit/2026-08-28_chaos-harness/harness/fixtures/graph_p4_138nodes.json`
（138 節點、288 邊）與它被擷取自的出貨模型 `StaticNetworkTopologyP4_10Switches_128Hosts.json`，
逐節點 `ip`／`mac`／`brand_name` 一致，而且**那一對真實資料餵進不變量必須靜默**——
沒有這個對照組，底下每一個紅都可能只是這支檢查對什麼都紅。

閘門 `tests/shell/mutate_contract_per_node_identity.sh`：W1–W9（拿掉一片 ⇒ 指名的 case 紅）、
X1–X3（合約允許的放寬 ⇒ 全綠）、U1（惰性編輯 ⇒ SURVIVED）。
變異寫進 `tools/contract_test/` 的**複本**（`NDT_CONTRACT_DIR`），正本一個 byte 都不寫；
模型檔與擷取的 payload 仍從真的 repo 讀——**被變異的工具，不可以連判它的權威一起變異**。

## 6. 沒做的

- **edge 的接線沒驗**（數量對但接錯仍然抓不到）。這是 `README.md`／`2026-07-28_test_coverage_gaps.md`
  兩份文件原本就記著的限制，本輪只更正了 node 那一半的敘述，**edge 那一半原封不動、仍然成立**。
- **`nickname` 沒比**（同 `device_name` 的理由，而且它在 schema 裡是 optional）。
- **`is_up`／`is_enabled` 沒進身分**：那是 `inv_all_switches_up` 的工作，混進來會讓一個 down 的
  switch 同時被兩支不變量報。
- **`GRAPH_NODE["ip"] = IP_LIST` 沒收緊**：那是**輸出**契約（允許空陣列），與拓樸**輸入檔**規則是兩件事
  （同 W3-3b §6）。
- **`run_layers.sh` 的挑檔邏輯沒改**。這張單讓「挑錯了」被看見，**沒有讓它挑對**；
  真正的修法是讓 kernel 告訴你它載入了哪一份（例如 `ndt status --check` 已經在比的那個 sha256）。
  見 SUMMARY §7。
- **沒有 live 驗**：本輪不碰 lab，一個 kernel 都沒跑。上面所有「kernel 會怎麼服務」的宣稱，
  來源是 R0b 的量測與那份真實擷取的 payload，不是這一輪量的。
