<!-- opus-judge a8ed6d7da8b264752 round-2 scoped review of feat/p4-roles-first-cut-0924 @ 3ff87a10; extracted verbatim by orchestrator-0924 2026-09-24 -->

**Verdict：MERGE AFTER FIXES（只有一項小修：F1）**

①–⑨ 都照裁決做了，證據屬實：舊碼上的行為測試確實紅，每顆具名變異都讓點名的測試變紅，C1、C2 控制組綠，log 都在 `3ff87a10` 上。總表的 RED 就是你說的那兩列、沒有別的。F1 是 ① 同一類的缺口，走的是另一個入口，第二輪改了 `install_initial_routes` 卻沒改它的鏡像函式；修法很小。其餘幾項記進報告就好。

路徑縮寫：`WT`＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-roles-0924`，`LOG`＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910`。

## 發現（依嚴重度）

**F1［中低｜需修］刪除規則時的「還原」仍會寫穿過其他交換機的路由。**
- readopt 的補路由受限時，`topology_manager.py:1248` 照樣把全路徑算進 `dest_paths`，`:1270` 只擋寫入。
- `_control_plane_port`（`:1053-1085`）的 docstring 承諾它回的是「`install_initial_routes` 此刻會寫的 port」，但它不看 `routes_to_attached_hosts_only`；`unroute_flow` 的 A-4d 還原（`:1142-1155`）用的就是它。
- 失敗情境：
  1. 混合 fabric：s1 跑 NDTwin pipeline，s2 跑 basic、沒有 roles。
  2. s1 power-cycle → readopt，只寫 h1 的路由，但 `dest_paths` 已經有 s1→s2→h2。
  3. app 在 s1 裝一條到 h2 的規則，之後刪掉。
  4. proxy 把 s1 往 s2 到 h2 的路由「還原」回去，回 success，還記進 `_installed_routes`。這就是 ① 要擋的半裝路徑。
- `:659-662` 註解說「readopt's refill is the one writer left there」，不成立。
- 修法：旗標為真且下一跳不是目的主機時，`_control_plane_port` 回 None；補一顆紅先測試和一顆具名變異。若不開第三輪，至少改掉那句註解，並把 F1 列為 known gap。

**F2［低｜已揭露，列 known gap］混合 fabric 上沒有直連主機的 NDTwin 交換機 readopt，回應裡兩句話互相矛盾。**
- `topology_manager.py:1501-1505` 仍附 `routes_pending` 和「watchdog 會補」，而這種 fabric 沒有 watchdog；`main.py:1414-1422` 同時又加 `routes_scope` / `routes_note`。
- 這是刀前就有的問題，不是 R 造成的。
- R 說沒修是因為那一行是 M-B29 的錨點。其實可以在 `main.readopt_switch`（R 自己的檔）依 `_fabric["watchdog"]` 把那兩個鍵拿掉，不必動錨點。應該寫進報告。

**F3［低］外來 owned 交換機的補路由被跳過時，回應寫的原因是舊的。**
- 被跳過的情況有兩種：fabric 啟動時就跳過了 routes，或 startup 還沒記錄。
- 這時回應仍帶舊的 `routes_note`（`main.py:1427-1433`「the refill names NDTwin's own tables」），沒說真正的原因。
- 「startup 前不補」本身是安全的：它是 fail-closed，而且 uvicorn 在 lifespan startup 完成後才開始服務，實際上碰不到。判準已在 SUMMARY ① 和 `main.py:1235-1239` 揭露。

**F4［低｜證據鏈］錄製腳本的 sha `89e35766…` 只出現在 base 錄製的 log（`LOG/record_stats_flow_http_body_at_base.p4r-57aae1bf.log:3`）。**
- `3ff87a10` 上沒有任何閘門重算這個 sha；跑錄製的 wrapper 也沒放進 `scripts-p4r-3ff87a10/`。
- 實際風險低：常數的 sha 由 `test_the_constant_is_the_recording` 綁到錄製值，HEAD 碼上的 body 位元組測試是綠的。

**F5［低｜已揭露］**
- ① 只有離線證據，readopt 沒有 live 步驟。
- 依 ⑧ 改完之後，all-NDTwin fabric 的 LLDP 啟動失敗只剩 `reroute:false` 和 log，沒有 fabric 層的揭露。
- 兩者都寫進報告即可。

**小問題（不擋）：**
- L5 經 kernel 打作者 /32 那一判（`07_roles_basic.sh:703-711`），`recent_failures` 的命中可能來自前一筆 10.0.9.9 的失敗。不過直打 proxy 的 501 加上 `:715` 的「仍走 port 1」已經直接證明同一 /32 沒被改。
- 字面常數閘門的例外從行號改成常數名，比第一輪略寬（`self.IPV4_LPM_TABLE = "…"` 也會被放行）；閘門只掃 `proxy_agent/`。都可以接受。

## ①–⑨ 逐項

| 項 | 判定 | 查過的證據 |
|---|---|---|
| ① | DONE（F1–F3 是裁決字面之外的殘留） | 碼：`topology_manager.py:667, :1270`；`main.py:1235, :1414-1422, :1457-1460, :1929`。紅先：`round2_red_first…:10-18`，裁決點名那顆在舊碼上是真的寫了 H2 而 FAIL。變異 R2-1a…j 全抓（`mutate_roles_binding.p4r-3ff87a10.log:482-504`）。基線：all-NDTwin fabric 旗標恆為 False、不加 `routes_scope`；R2-1b 會讓 base 的 WriteRequest 位元組測試變紅（`:485`），HEAD 上它是綠的；`baseline_chain` (b) 綠。 |
| ② | DONE | `ryu_flow_stats.py:54` 改由 BASELINE 導出；閘門 `test_route_binding.py:240-270`：四個名字、四個具名例外、外加「例外必須有命中」的 guard。我 grep 過，碼級字面只剩 BASELINE 和那四個具名常數。紅先 `:19`；R2-2a/b/c、FS4 都抓到。 |
| ③ | DONE | `ryu_flow_stats.py:320-334`：NDTwin 路徑 `foreign=False`，列出邏輯與 base 相同。殺手改用 fixture 的真實列（`test_ryu_flow_stats.py:584`，`:497` 改成 `hdr.ip4.proto`）。M-R11/11b、FS3/3b/3c 都抓到；FS3c 證明 NDTwin pipeline 不計數、`/stats/flow` body 不變。 |
| ④ | DONE（F4 小缺口） | `baseline_chain…:8-12`：五個常數區塊的值和原文都相同。`:20-31`：d492a346 的測試在 HEAD 碼上綠。錄製 log `:2-9`：樹是 d492a346、api_routes 的 sha 等於 trunk、輸出 sha `aca1a88a` 等於 `test_flow_stats_route.py:164`。R2-4a 只讓 HTTP 那兩顆變紅，第一輪 sort_keys 的 fixture 沒紅（`:543-544`）。 |
| ⑤ | DONE | `test_route_binding.py:630, :633`：斷言 501、outcome、reason，而且 stub 沒收到任何請求。舊碼上是綠的 guard，靠 R2-5a/5b 變紅（`:546-547`）。 |
| ⑥ | DONE | 13 個判定函式每個至少一顆變異，另加 reason、`"unbound"`、`is_enabled`、outcome 四個子條件；L7-1…17 全由點名的 case 變紅（`:564-581`），未變異的副本 PASS。新自測 case 見 `live07_selftest…:11,17,36,37,41`。作者 /32 探針在 `07_roles_basic.sh:66, :688, :703, :715`，只在 live 路徑、沒跑過，已揭露。 |
| ⑦ | DONE | `mutate_a7_dispatch_status_python_only…`：5/0，兩個負控制綠，五個檔還原後逐位元相同；標 PARTIAL（沒跑 cpp lane），照裁決。 |
| ⑧ | DONE | `main.py:1130-1135`：external→`none`、有宣告→`declared`、其他→`lldp`。`:1919`：`declared_links` 一律是模式旗標。`:1225-1232`、`api_routes.py:773-774`：seed 的結果放在頂層。紅先 10 顆；R2-8a…i 都抓到。 |
| ⑨ | DONE | SUMMARY R2-9 勘誤表逐條對上裁決 ⑨ 的十點，包括 D12 行號 `:20`，以及 fail-open 記名 `p4_client.py:260,429` / `main.py:245`。 |

## 其他查核
- **FINAL-GATES RED**：只有兩支和預期不符，佔三行。
  - `p4_exercise_suite`：rc 0，預期 1；緊跟著的「reds not exactly FixtureProvenance:」那行後面是空清單。
  - `fixture_provenance_at_base`：rc 1，也就是 base 上不再紅。
  - 兩份 log 裡 FixtureProvenance 兩顆都是 ok，`advanced_tunnel.json` 的 mtime 是 21:16:14（你做的還原）。
  - 其餘 27 列的 rc 都等於預期，包括兩支預期 rc 2 的。
- **⑧ 只加不改**：
  - 新增的是頂層 `declared_links`：宣告鏈路的 fabric 給 `{directions, error}`，其他 fabric 給 null；reporter 沒注入時不加這個鍵。
  - 它和既有頂層鍵不衝突；base 的鍵一個都沒動。
  - 值有變的只有第一輪自己加的 `capabilities.link_discovery`，而且只在兩個邊界情況，照裁決。
- **R2-10**：
  - 列出的六項都是 R 第一輪自己寫的測試或 helper。
  - r2 diff 裡測試檔的刪除行，全部落在第一輪新增的行；沒有任何 base 測試被改。
  - 兩處改斷言是 ③、⑧ 要求的語意翻轉；舊的字面常數測試被範圍更大的四名字測試取代。沒有削弱契約斷言。
- **範圍**：diff 共 13 個檔＝12 個第一輪動過的檔＋④ 要求的新檔 `record_stats_flow_http_body.py`，沒有範圍外的檔。
