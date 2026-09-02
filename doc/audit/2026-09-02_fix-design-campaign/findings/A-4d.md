# A-4d — P4「裝一條規則然後刪掉」把目的地打成黑洞

狀態：進行中（邊查邊寫）

## 1. Base 驗證

```
$ git log --oneline -1
4cbec52d Keep the one line that names the restore failure

$ sed -n '282p' doc/KNOWN-ISSUES.md
### A-4d 🔴 P4 上「裝一條規則然後刪掉」會把目的地打成黑洞
```

兩項都符合 brief 的要求。註：worktree 建立時的 HEAD 是 `f5db629b update sleeping time`（origin/main
的祖先，缺 `tests/` 與 `p4_proxy/`），已依 brief 第 0 節 `git checkout --detach` 修正。

## 2. 機制（file:line ＋ 逐一候選因）

### 2.0 事件鏈（實際發生的順序）

| # | 動作 | 碼 | 對 `ipv4_lpm` 的效果 |
|---|------|----|--------------------|
| 1 | bring-up：控制面為每個 (switch, host) 裝 `dst/32` | `topology_manager.py:1061` `insert_ipv4_route(ipv4_dst, 32, mac, out_port)` | 該目的地**唯一的一筆**被建立 |
| 2 | TE app `POST /stats/flowentry/add` | `topology_manager.py:897` 同一支 `insert_ipv4_route(ipv4_dst, **32**, ...)` | key 完全相同 ⇒ INSERT 撞 `ALREADY_EXISTS`／bmv2 的 `UNKNOWN` |
| 3 | INSERT 失敗 → **MODIFY 回退** | `p4_client.py:855-857` | **覆寫**了步驟 1 那一筆。控制面的路由**已經不存在了** |
| 4 | TE app `POST /stats/flowentry/delete` | `topology_manager.py:947` `delete_ipv4_route(ipv4_dst, 32)` | key 相同 ⇒ 刪掉**唯一的一筆**。該目的地在表上**歸零** |
| 5 | 封包抵達 | `ndtwin_switch.p4:350-363`，`default_action = send_to_cpu()`（:361） | LPM miss ⇒ 送 CPU |
| 6 | proxy 收到 packet-in | `topology_manager.py:1279 handle_packet_in` | `parse_lldp_packet` 回 None ⇒ **什麼都不做**，封包就此消失 |

⇒ 黑洞。而且不是靜靜地掉在 datapath，是**整條流被打到 CPU port**（bmv2 的 CPU 路徑本來就是
這個系統最脆弱的一段）。

### 2.1 逐一候選因

**(a) delete 除了裝上的規則，還刪掉了共用 match key 的既有 default/punt/forwarding entry**
— **半對，但描述錯了形狀。** 沒有「兩筆」被刪。`ipv4_lpm` 的 key 只有 `hdr.ipv4.dstAddr: lpm`
（`ndtwin_switch.p4:351-353`），而 install 與 bring-up **都用 `/32`**
（`topology_manager.py:897` 與 `:1061`，兩處硬寫 `32`）⇒ 兩者寫的是**同一個 key 的同一筆**。
delete 只發了一個 DELETE（`p4_client.py:891`），刪掉的就是那一筆。
✅ 「共用 match key」成立；❌ 「刪掉了額外的一筆」不成立。

**(b) install 覆寫（modify）了既有 entry 而不是新增，所以 delete 刪掉的是唯一的一筆**
— 🔴 **這就是真因，碼上直接看得到。**
```python
# p4_client.py:811     update.type = p4runtime_pb2.Update.INSERT
# p4_client.py:855-857
if e.code() in (grpc.StatusCode.ALREADY_EXISTS, grpc.StatusCode.UNKNOWN):
    if self.modify_ipv4_route(dst_ip, prefix_len, next_hop_mac, port):
        return True
```
這段回退是**刻意加的**，它自己的註解（`p4_client.py:848-853`）寫明了目的：
「the old code left the existing entry untouched, so a recalculated (better) path never
actually took effect」。也就是說 A-4d 的第一半（覆寫）是**修好另一個 bug 的直接後果**——
它讓 install 對既有目的地變成 in-place 取代，而**沒有人記下被取代掉的是什麼**。
這正是記憶裡 `should replace, can only add` 那一族的鏡像：那一族是「該取代卻只能新增」，
這裡是「取代成功了，但**取代是不可逆的**」。

**(c) P4 表的 default action 是 drop，而 bring-up 前的轉發 entry 從沒被重裝**
— ❌ **前半是錯的，後半是對的、而且是修法的關鍵。**
default action **不是 drop**，是 `send_to_cpu()`（`ndtwin_switch.p4:361`）。
`drop` 這個 action 有宣告（`:288`）也在 `actions` 清單裡（`:357`），但不是 default。
差別是實質的：黑洞的成因不是 datapath 丟包，是**punt 之後沒人接**
（`handle_packet_in` 只處理 LLDP，`topology_manager.py:1341-1346`）。
後半（「沒被重裝」）成立：`install_initial_routes` 只在**discovery 與 link transition** 時跑
（docstring `topology_manager.py:1010-1013`），`unroute_flow` 不觸發它，
`ipv4_lpm` 裡也**沒有任何較短 prefix 的 catch-all**——bring-up 只寫 host `/32`
（`topology_manager.py:1061`），沒有 /24、沒有 /0。所以 LPM 一路 miss 到 default。

**(d) delete 用了跟 install 不同的 match／priority，刪錯 entry**
— ❌ **對 A-4d 的主線不成立**，但存在一個**相鄰的真缺陷**（見 §2.3）。
主線上：install 走 `topology_manager.py:897`、delete 走 `:947`，
兩邊都是 `(ipv4_dst, 32)`，同一個 key，沒有 priority 參與（LPM 表沒有 priority——
`route_flow` docstring `topology_manager.py:806-810` 講了原因）。
delete 刪的**正是**它要刪的那一筆。問題不在刪錯，在於**那一筆不只是它的**。

### 2.2 為什麼 OVS 沒事（KNOWN-ISSUES 說「OVS 上同樣兩個呼叫是安全的」）

OVS 的 TE 規則是 priority 100 **疊在** router 的 priority 10 之上，兩筆並存；
刪掉 100 之後 10 還在，流量落回原路。P4 這邊 `ipv4_lpm` 是 LPM 單鍵表、
**每個 prefix 只有一筆**，「疊」這個動作不存在，只能取代。
`topology_manager.py:806-810` 的 docstring 已經把這個不對稱寫出來了
（"under OVS a TE migration at priority 100 *layers over* the default rule at 10, while
here it *replaces* the destination's only entry"）——**前提寫對了，後果沒寫。**

### 2.3 相鄰缺陷：install 走 5-tuple、delete 走 LPM（候選因 (d) 的真實版本）

分支條件是 `needs_five_tuple(match_dict)`（`topology_manager.py:331-341`），
**兩邊各自從自己的 match dict 算**：install 在 `:869`，delete 在 `:936`。
如果 app 用 5-tuple match 裝規則、但 delete 只送 `nw_dst`（OpenFlow 語意上是合法的
「刪掉符合這個目的地的規則」），delete 會落到 `else` 分支去
**刪掉 `ipv4_lpm` 那一筆它從來沒裝過的控制面路由**，而 5-tuple 規則原封不動留著。
這是「刪錯 entry」的真實形狀，而且它造成的黑洞**更難查**（表上還有一筆 5-tuple 規則在）。
📌 這是我在讀碼時發現的，**沒有實測證據**，不在 A-4d 的原始回報範圍內。

### 2.4 與 KNOWN-ISSUES 的對帳

KNOWN-ISSUES `doc/KNOWN-ISSUES.md:282-306` 的機制敘述：
> `ipv4_lpm` 每個 prefix 只有一筆，所以 install **覆寫**了控制面的路由，delete 又把它撤掉

**✅ 正確，而且是四個候選因裡的 (b)。** 對帳結果：

| KNOWN-ISSUES 的說法 | 判定 |
|---|---|
| 「每個 prefix 只有一筆」 | ✅ 成立（`ndtwin_switch.p4:351-353` 單鍵 LPM；install/delete 都用 `/32`） |
| 「install 覆寫了控制面的路由」 | ✅ 成立，但**它沒說覆寫是怎麼發生的**——是 `p4_client.py:855-857` 的 MODIFY 回退，不是 P4Runtime 自動取代（P4Runtime 的 INSERT 對既有 key 是**失敗**，不是覆寫） |
| 「原本的路由沒有回來」 | ✅ 成立（`unroute_flow` 只 `pop` 記錄，`topology_manager.py:954`，沒有任何還原） |
| 行號更正（`api_routes.py:253-255`、`topology_manager.py:813-821`、`683-685`） | ⚠️ **又漂了**。目前正確位置：前提註解在 `topology_manager.py:806-810`（`route_flow` docstring）、`api_routes.py:249-257`（`delete_flow_entry` docstring）；delete 路徑在 `topology_manager.py:910-955`，`pop` 在 `:954` |
| 「失效方向：災難性但**吵**（看得出來）」 | ⚠️ **只有資料面吵，控制面是啞的。** ping 100% loss 確實看得見，但 proxy 這邊 `unroute_flow` 回 `True`、REST 回 `{"status":"success"}`，而 `_installed_routes` 被 `pop` 掉之後 twin 也**不再宣稱**有這條路由——所以 twin 不會說謊，但**也不會有任何警告**。「吵」是網路吵，不是系統吵 |

**一項 KNOWN-ISSUES 漏掉的後果**：default action 是 `send_to_cpu()` 不是 `drop()`，
所以黑洞掉的流量**全部灌進 CPU port**。這對 bmv2 是有代價的——同一份 KNOWN-ISSUES
別處記的取樣天花板／CPU 路徑脆弱都在這條路上。KNOWN-ISSUES 沒提。

## 3. 修法設計

### 3.1 「原本的狀態」是什麼？

這題必須先答，因為 P4 這邊**沒有一個「原本那筆」可以還原**——它被 MODIFY 蓋掉了，內容不存在任何地方。
三個候選定義：

| 定義 | 是什麼 | 判定 |
|---|---|---|
| D1 被覆寫掉的那筆的**字面內容** | install 之前該 slot 的 out_port | ❌ 見 §3.3 |
| D2 **控制面現在**會寫的那筆 | `install_initial_routes` 此刻算出來的最短路 | ✅ **採用** |
| D3 表上**沒有**那筆（現況） | delete 就是 delete | ❌ 就是這個 bug |

採 **D2**，理由：A-4d 要恢復的是**可達性**，不是位元組。而 D2 是唯一**保證現在可達**的候選——
它是從 `calculate_all_paths(reroutable_down_endpoints())` 算出來的、已經排除掉判定為 down 的鏈路。
D2 也正好是 OVS 那邊「priority 10 的 router 規則」的語意等價物：OVS 上它之所以會回來，
是因為它一直都在、由控制面維護；P4 只有一個 slot，能做到的等價就是**把 slot 交還給控制面**。

### 3.2 採用的修法（只動 `unroute_flow` 的 LPM 分支）

一句話：**當控制面對這個目的地仍有路徑時，`delete` 的實作從「刪掉那一筆」改成
「把那一筆還原成控制面的路由」；沒有路徑時才真的刪。**

實作上還原就是**再呼叫一次 `insert_ipv4_route`**——`install_initial_routes` 用的同一支
（`p4_client.py:804`）。因為 entry 還在，它的 INSERT 會撞 ALREADY_EXISTS/UNKNOWN，
落到 `p4_client.py:855` 的 MODIFY 回退，**原地換成控制面的 port**。

這帶來三個附帶好處，而且都不是巧合：
1. **沒有空窗。** DELETE 再 INSERT 中間那段時間 entry 不存在，封包會被 punt 到 CPU；
   單一 MODIFY 是原地換，一個封包都不會漏。
2. **一次 RPC 不是兩次。**
3. **走的是控制面本來就走的那條碼路**，不是為了修這個 bug 另外開一條。

新增一個純讀的輔助 `_control_plane_port(dpid, ipv4_dst)`：從 `self.dest_paths` 取路徑、
取下一跳、查 `net.edges[...]['port']`——與 `install_initial_routes`（`topology_manager.py:1049-1055`）
**逐行相同的算法**，回傳 `None` 表示「控制面現在對這個目的地沒有路由」。

`_installed_routes` 的簿記跟著分岔：還原成功 ⇒ **寫入還原後的 port**（switch 上確實有路由）；
真的刪掉 ⇒ 維持現行的 `pop`。

**不重算 `dest_paths`。** `calculate_all_paths` 會改動 `self.dest_paths` 這個全域狀態，
在一個 delete 路徑上做這件事是把副作用塞進不該有副作用的地方。現成的 `dest_paths` 在
每次 discovery 與每次 link transition 都會刷新，**而 link transition 本來就會重寫這一筆**
（`install_initial_routes`），所以「陳舊到有害」的窗口不存在。

**5-tuple 分支不動。** 刪掉一條 5-tuple 規則之後封包**落回 `ipv4_lpm`**，那一筆還在——
這正是 OVS 有的疊層語意，P4 在這張表上本來就有。A-4d 不涉及它。

### 3.3 被否決的替代方案

**(A) install 時快照被覆寫的內容，delete 時還原（brief 提到的那個）**
— ❌ 否決。快照本身是**免費**的（`route_flow:897` 寫入前，`_installed_routes[(dpid, ipv4_dst)]`
就是控制面上一次寫的 port），所以否決的理由不是成本，是**正確性**：
- **會陳舊。** install 與 delete 之間若有鏈路故障，快照指向的可能是已經死掉的鏈路。
  還原到那裡＝把一個**吵的**黑洞（ping 100% loss，看得見）換成一個**啞的**黑洞
  （表上有規則、twin 宣稱有路徑、封包進死鏈路）。以這個專案的標準，那是換到更糟的那一邊。
- **需要一組容易寫錯的簿記**：連續兩次 add（遷到 port 3、再遷到 port 4）必須「第一次寫入為準」，
  否則 delete 會還原成 TE 自己撤掉的第一條規則；而且 `install_initial_routes` 重寫該筆時
  必須讓快照失效。三個狀態轉換，每個都是新的錯誤面。
- D2 不需要任何一項——它每次都重新問控制面。

**(B) `unroute_flow` 直接呼叫 `install_initial_routes(only_dpid=dpid)`**
— ❌ 否決，而且**危險**。它會 (i) 重算全部路徑（副作用改 `self.dest_paths`）、
(ii) 重寫**那台 switch 上所有目的地**的 entry（最多 10 次 gRPC）——
其中包含**其他 app 還在用的 TE 規則**。修一個黑洞的代價是砸掉別人的遷移。

**(C) 在 P4 程式裡把 `ipv4_lpm` 的 default_action 改成轉發／加一條 /0 catch-all**
— ❌ 否決。要 recompile ＋ re-push pipeline（brief 明文禁止 build），而且 /0 catch-all
在一個沒有預設閘道概念的實驗拓撲上要指向哪個 port 沒有答案。**這是換掉失效模式，不是修好它。**

**(D) 讓 `route_flow` 改用 5-tuple 表（把 TE 規則疊在 LPM 上，複製 OVS 的語意）**
— ❌ 否決為**本次**修法。它其實是更根本的解（真正把「疊層」帶進 P4），但它改的是
**install 的語意**：一個只送 `nw_dst` 的 add 從此不再進 `ipv4_lpm`，`_installed_routes`、
`render_destination_paths`、`readopt_switch` 的假設全部要重審。那是一個設計決策，不是一個 bug fix。
📌 **列為給 Adam 的選項**（§7 第 1 題）。

### 3.4 C++ 這一側

**不需要碼的修改。** A-4d 完全是 proxy 端的語意：C++ 這一側只是把 OpenFlow JSON POST 出去
（`HttpRoutingStrategyBase.cpp:150-164`），`P4RoutingStrategy` **沒有 override `deleteAnEntry`**
（`P4RoutingStrategy.hpp:34-60` 只 override group/meter 與 `strictModifyPath`）。
kernel 送的東西是對的；壞掉的是 proxy 對它的解讀。
⇒ 我**不**在 C++ 端造一個沒有缺陷的修改來湊「有動 C++」。

有一處**文件失真**值得記，但我不改（改註解無法用測試守住，且會擴大 diff）：
`FlowRoutingManager.hpp:70-84` 的 doxygen 只用 OpenFlow 語意描述 delete
（"may remove multiple entries that match"）。在 P4 模式下非 strict delete 移除的是
**該目的地唯一的一筆**，語意相反。列在 §6。

### 3.5 install／delete 的完整呼叫者清單

**C++（kernel 內）**
| 位置 | 動詞 | 觸發 |
|---|---|---|
| `src/ndt_core/intent_translator/IntentTranslator.cpp:364` | install | LLM `INSTALL_FLOW_ENTRY` task |
| `src/ndt_core/intent_translator/IntentTranslator.cpp:417` | **delete** | LLM `DELETE_FLOW_ENTRY` task（**唯一不帶 priority ⇒ 走非 strict `/delete`**） |
| `src/ndt_core/intent_translator/IntentTranslator.cpp:733` | install | `BLOCK_HOST`（priority 50000、**actions 空陣列**） |
| `src/ndt_core/routing_management/Controller.cpp:32` | install | flow batch 的非同步 sender |
| `src/ndt_core/routing_management/Controller.cpp:47` | **delete** | 同上 |

**kernel 的北向 REST 入口**（`src/ndt_core/http/HttpSession.cpp`）
`/ndt/install_flow_entry`（:186）、`/ndt/delete_flow_entry`（:190）、
`/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries`（:223）→
`processFlowBatch`（:952）→ `makeDeleteJob`（:940，**priority 預設 -1**）→ Controller → 上表。
⇒ TE app 與 Energy-Saving app 都從這裡進來。

**proxy 端（P4）**
| 位置 | 動詞 |
|---|---|
| `p4_proxy/proxy_agent/api_routes.py:242-244` `/stats/flowentry/{delete,delete_strict}` | → `unroute_flow` |
| `p4_proxy/proxy_agent/topology_manager.py:897` `route_flow` | → `insert_ipv4_route` |
| `p4_proxy/proxy_agent/topology_manager.py:947` `unroute_flow` | → `delete_ipv4_route` ← **本次修改處** |
| `p4_proxy/proxy_agent/topology_manager.py:1061` `install_initial_routes` | → `insert_ipv4_route`（控制面，唯一的「正版」寫入者） |
| `p4_proxy/proxy_agent/topology_manager.py:999` `modify_flow` | → `modify_ipv4_route` |

`install_initial_routes` 自己的呼叫者：`handle_packet_in`（:1348，discovery）、
link transition 的 watchdog、`readopt_switch`（`only_dpid=`）。

## 4. Patch

分支 `fix/a-4d-delete-restores-p4-route`（從 `4cbec52d` detach 後建立）。**沒有 push。**

```
$ git log --oneline -1
a1a4a295 Hand the LPM slot back to the control plane instead of emptying it

$ git show --stat HEAD
 p4_proxy/proxy_agent/topology_manager.py     |  76 ++++++++++
 p4_proxy/tests/test_delete_restores_route.py | 218 +++++++++++++++++++++++++++
 p4_proxy/tests/test_five_tuple_match.py      |   6 +
 3 files changed, 300 insertions(+)
```

**純新增，零刪除。** 三處改動：
1. `topology_manager.py` 新增 `_control_plane_port()`（純讀，`dest_paths` → next hop → edge port）
2. `topology_manager.py` `unroute_flow` 的 LPM 分支：有控制面路由就還原、沒有才真刪
3. `test_five_tuple_match.py` 的 `manager_with` 補上 `dest_paths = {}`——見 §5 的迴歸

⚠️ **NOT COMPILED**：全程沒有跑任何 C++／P4 build，沒碰 Mininet／bmv2／`ndt`／lab claim／sudo。

## 5. 測試證據（變異閘）

直譯器：`/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python3`
（worktree 自己沒有 venv；venv 只差在 site-packages，binary 是共用的 symlink）。
每次都**不接 pipe**、單獨取 `$?`。

### 5.1 紅→綠

| 階段 | rc | 結果 |
|---|---|---|
| **未修改的碼** | **1** | `Ran 6`，**3 紅**：`install_then_delete_leaves_the_destination_forwarding`（`'lpm_delete' != 'lpm_insert'`）、`the_restore_never_empties_the_entry_first`、`the_bookkeeping_names_the_restored_port`（`None != 2`）。**另外 3 個控制組是綠的** |
| **修改後** | **0** | `Ran 6 ... OK`，skipped=0 |

紅的訊息本身就是 A-4d 的敘述：`the destination's last ipv4_lpm write was lpm_delete:
nothing is left to forward it and the table misses to send_to_cpu()`。

### 5.2 額外變異（確認測試沒有過度貼合、且控制組有鑑別力）

| 變異 | rc | 被誰殺 |
|---|---|---|
| M1：還原改成 DELETE 再 INSERT（終態相同、中間有空窗） | 1 | `the_restore_never_empties_the_entry_first`（1 個） |
| M2：還原成 `_installed_routes` 記的 port（＝§3.3 被否決的快照方案的失效形狀） | 1 | 3 個 |
| M3：拿掉「沒有控制面路由就真刪」的守衛（無條件還原） | 1 | **負控制組** `a_destination_the_control_plane_cannot_route_is_really_deleted` |

M3 是重點：它證明那個負控制組**會失敗**——不是一個永遠會過的裝飾。
三個變異全部回復後重跑，rc=0。`grep 'MUTATION M'` 對整個 `p4_proxy/` 回 none。

### 5.3 全套件迴歸

20 個檔案逐檔跑、逐檔取 rc：**全部 rc=0**，共 **522 tests**、3 skip
（`test_p4_client` 的 live 測試 1、`test_sflow_emitter` 2）。

🔴 **中途抓到一個我自己造成的迴歸，值得記**：`test_five_tuple_match` 一開始 **rc=1**——
`AttributeError: 'TopologyManager' object has no attribute 'dest_paths'`。
原因是該檔的 `manager_with` 用 `TopologyManager.__new__` 造物件、手動塞欄位，
**沒塞 `dest_paths`**（`__init__` 一定會設，`topology_manager.py:531`）。
這正是 `python-tests-need-the-venv-interpreter` 記的那條：**比它替身的介面還窄的 test double，
會把一個正確的產品修改變成測試失敗**。修法是補上 double 缺的欄位，
**不是**在產品碼寫 `getattr(self, "dest_paths", {})`——那會把未來真正的初始化缺陷藏起來。
依同一則記憶的「去 grep 其他實例」：`grep -rn 'TopologyManager.__new__'` 只有三處，
另一處（`test_flowentry_endpoints.py:223`）走不到新碼，因為 `if not ipv4_dst: return False`
在 `_control_plane_port` 之前就回了。

## 6. 沒有驗到的 / 人要接手的

### 6.1 這次的證據級別

**全部是讀碼 ＋ 用假 P4Runtime client 的單元測試。** 沒有任何一行是在真交換機上跑的。
具體地說，以下三件事**只是從碼推論的，沒有實測**：
1. bmv2 對重複 key 的 INSERT 回 `UNKNOWN`（碼裡的註解說是 2026-08-16 live 觀測到的，
   **我轉述，沒有親自驗**）——修法的還原路徑依賴這個回退變成 MODIFY
2. `insert_ipv4_route` 對**已存在**的 entry 會成功落到 MODIFY 並**原地換 port**（P4Runtime 語意如此，未實測）
3. LPM miss 之後封包確實走 `send_to_cpu` 而非被丟棄

### 6.2 人要跑的 live 測試（含負控制組）

**前置**：這需要 lab claim ＋ bmv2 ＋ Mininet，我全部被禁止。
不要看 kernel 快取，**直接讀真表**（`p4_proxy/reference/dump_table.py`）。

```
# 0. bring-up 之後，記下控制面裝的那一筆
python3 p4_proxy/reference/dump_table.py --dpid 1 | grep 10.0.0.1   # 期望：/32 -> port P0

# 1. 裝一條規則把它遷到另一個 port
curl -X POST http://localhost:8081/stats/flowentry/add \
     -d '{"dpid":1,"match":{"dl_type":2048,"nw_dst":"10.0.0.1"},
          "actions":[{"type":"OUTPUT","port":P1}]}'
python3 p4_proxy/reference/dump_table.py --dpid 1 | grep 10.0.0.1   # 期望：/32 -> port P1（一筆，不是兩筆）
                                                                    # ← 這一步就證明了「覆寫」

# 2. 刪掉它
curl -X POST http://localhost:8081/stats/flowentry/delete \
     -d '{"dpid":1,"match":{"dl_type":2048,"nw_dst":"10.0.0.1"}}'

# 3. 🔑 主要判準：表上還在，而且回到 P0
python3 p4_proxy/reference/dump_table.py --dpid 1 | grep 10.0.0.1   # 期望：/32 -> port P0
ping -c 20 10.0.0.1                                                 # 期望：0% loss（修前是 100%）
```

**負控制組 A（證明「刪」還是會刪，不是變成 no-op）**：
對一個**拓撲外的位址**做同一組 add＋delete，例如 `192.168.99.9`。
`dest_paths` 沒有它 ⇒ 期望第 3 步 `dump_table` **grep 不到**、該 entry 真的消失。
🔴 **沒有這一組，整個修法無法與「delete 壞掉了、什麼都不刪」區分開。**

**負控制組 B（證明還原沒有空窗）**：第 2 步期間持續 `ping -f`（或固定速率 UDP）。
期望**遺失 0 個封包**。若改成 DELETE+INSERT 會看到一小撮遺失——這是單元測試
（M1）擋住的東西，但只有 live 能量到真實空窗寬度。

**負控制組 C（證明修法沒有把 TE 的遷移弄壞）**：第 1 步之後、第 2 步之前量 tx 計數器，
期望 100% 流量在新 port 上——與 round 6 原始實測同口徑。

### 6.3 已知但這次沒修的

| 項目 | 位置 | 為什麼沒修 |
|---|---|---|
| **install 走 5-tuple、delete 只送 `nw_dst`** ⇒ 刪到它從沒裝過的 LPM 控制面路由（§2.3） | `topology_manager.py:869` vs `:936` | 不同缺陷。**副作用上被這次修法降級了**：現在那個 delete 變成「把 LPM 還原成控制面路由」（實質 no-op），黑洞消失——但 5-tuple 規則**仍然留著**，呼叫端以為刪掉了。**這仍是一個要單獨處理的缺陷，我只是拿掉了它最嚴重的後果。** |
| `FlowRoutingManager.hpp:70-84` doxygen 用 OpenFlow 語意描述 delete（"may remove multiple entries"），在 P4 下語意相反 | C++ header | 改註解無法用測試守住，且我判斷不該在這個 commit 擴大 diff |
| `IntentTranslator.cpp:733` 的 `BLOCK_HOST` 送**空 actions**，`route_flow` 因 `out_port is None` 回 False ⇒ **P4 模式下封鎖主機根本不生效** | `IntentTranslator.cpp:733` ＋ `topology_manager.py:884-887` | 讀碼時撞到的，不在 A-4d 範圍。**未實測。** |
| KNOWN-ISSUES A-4d 的行號第二次漂掉 | `doc/KNOWN-ISSUES.md:295-299` | 我沒改 doc——那是 auditor／Adam 的檔，且我不確定該由誰維護 |

## 7. 給 Adam 的裁決題（每題附後果）

**Q1. TE 規則要不要改走 `flow_5tuple`，真正把「疊層」帶進 P4？**
- **(a) 不改，維持這次的還原修法**（建議）。後果：黑洞沒了；但 P4 上「TE 規則」與「控制面路由」
  仍然共用一個 slot ⇒ 任何一次 link transition 仍會靜默蓋掉 TE 的遷移
  （這是記憶裡已判定「不屬於 replace-vs-add 家族」的那個既有行為，本次不變）。
- (b) 改：`route_flow` 對帶 priority 的 add 一律送 `flow_5tuple`。後果：P4 語意終於與 OVS 對齊、
  遷移不再被 transition 蓋掉；代價是 `_installed_routes`／`render_destination_paths`／
  `readopt_switch` 三處的假設全部要重審，而且 `_installed_routes` 對 5-tuple 規則
  **本來就刻意不記**（`topology_manager.py:860-868` 有寫理由）⇒ twin 的路徑渲染會少一塊。
  **這是設計變更，不是 bug fix。**

**Q2. 「真的把某目的地打成黑洞」要不要留一個出口？**
修法之後，只要控制面還有路徑，**沒有任何 API 能讓 P4 上某個目的地變成無 entry**。
- **(a) 不留**（建議）。後果：與 OVS 行為一致（那邊 priority 10 的規則本來也刪不掉）；
  真的要阻擋流量應該用 drop action，不是靠移除 entry。
- (b) 留：在 body 加一個非標準欄位（如 `"force": true`）。後果：那是**自創協定**，
  kernel 端沒有產生者，而且它會變成下一個「沒有測試輪呼叫過的動詞」（A-4e 就是這樣來的）。

**Q3. `dest_paths` 陳舊要不要在 delete 時重算？**
- **(a) 不重算**（建議，現行實作）。後果：省一次 BFS、不在 delete 路徑製造全域副作用；
  代價是若 delete 恰好落在「鏈路剛斷、watchdog 還沒跑」的窗口，還原的 port 可能指向死鏈路
  ——但那個窗口裡**控制面自己也會裝同一個 port**，所以不比現況差。
- (b) 重算：`unroute_flow` 先呼叫 `calculate_all_paths(reroutable_down_endpoints())`。
  後果：還原永遠最新；代價是 delete 變成一個會改動 `self.dest_paths` 的操作，
  而 `push_destination_paths` 等讀者沒有預期它會被一個 delete 改掉。

**Q4. §6.3 那三個順手撞到的缺陷要不要開單？**
特別是 **`BLOCK_HOST` 在 P4 模式下完全不生效**——那是一個安全動作靜默失敗。
建議至少替它開一張，並註明**我沒有實測、只是讀碼推論**。

