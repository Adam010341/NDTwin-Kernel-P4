# src_ip 整數位元組序覆核(2026-08-16)——甲類題「維持整數」的前提補全

> DeepSeek 於驗收審計抓到「src_ip 是 LE 重讀整數」,判官建議併入甲類 src_ip 題覆核
> (`doc/audit/2026-08-15_acceptance-judgments.md` 可行動輸出 #5)。Adam 表單核准本輪。
> 純源碼考證,零程式修改;兄弟 repo 只讀不改。

## 結論先講

**「維持整數」的裁決成立,但前提要升級**:維持的不是「整數」,而是
「**IPv4 網路序位元組重讀為 host-LE 整數**」這個**已被三個消費端雙向依賴的既成契約**。
kernel 內部慣例刻意、有註解、自洽;API 文件(`doc/2026-01-02_ndt_api.md` §flow)早已
完整記載位元組序與轉換方法;消費端各自補償且行為正確。**改動它是零功能增益的
跨 repo 協調工程**(至少 kernel+Web-GUI+TE 三處同步改),維持現狀是正解。

## 生產端(kernel 內部,全部網路序,刻意為之)

| 來源 | 證據 |
|---|---|
| sFlow 樣本解析 → `FlowKey.srcIP/dstIP` | `include/common_types/SFlowType.hpp:30` 註解明寫 `// in network order` |
| 拓撲 JSON 載入 → graph edge `srcIp` | `ipStringVecToUint32Vec` 用 `inet_aton`(=網路序 `s_addr`) |
| 內部渲染 | `utils::ipToString` 用 `inet_ntop` 吃網路序 → 點分字串正確 |
| 內部跨慣例邊界 | `FlowLinkUsageCollector.cpp:2602` 給 Classifier 的鍵**有做 `ntohl`**——兩套內部慣例在邊界正確轉換 |

## API 面(三種形式並存——本輪新地圖)

| 端點 | 形式 | 位置 |
|---|---|---|
| `get_detected_flow_data` | **裸網路序整數**(`16777226`=10.0.0.1) | `FlowLinkUsageCollector.cpp:2128` |
| `get_graph_data` edges(`src_ip`/`dst_ip`/`flow_set` 內 FlowKey) | **裸網路序整數** | `HttpSession.cpp:558`、`SFlowType.hpp:539` |
| `get_static_topology_json` | **點分字串**(`ipToString`) | `TopologyAndFlowMonitor.cpp:2703` |
| `get_path_switch_count` | **點分字串**(query param 進出) | `HttpSession.cpp:1605+` |

同一 JSON 內的不對稱:port 欄位是 host 序十進位(5201 直讀正確)、IP 欄位是網路序
整數——文件已載,消費端已知。

## 消費端(三個,三種姿態,全部行為正確)

1. **Web-GUI 讀側補償**:`src/utils/formatters.ts` 以**最低位元組在前**渲染
   (`ip&0xff . ip>>>8&0xff . …`)——硬編了對本契約的反解。改 kernel 吐法=GUI 立即
   顯示垃圾。
2. **TE 寫回側補償**:`Traffic-engineering-App.py:333`
   `str(ipaddress.IPv4Address(socket.htonl(flow_key[1])))`——把 LE 整數轉回點分字串
   再組 `ipv4_dst` 迴寫;內部只當不透明 dict 鍵。改 kernel 吐法=TE 迴寫錯地址。
3. **NSR 透傳**:全 repo 零 `src_ip` 解讀點,純歸檔,無依賴。

## 兩個附帶警語(記錄,不屬本題)

- **可攜性**:契約只在 LE host 上穩定。BE 上 kernel 吐的整數值會變,GUI 的反轉與
  TE 的 htonl(BE 上是恆等)會同步失效。本生態全 x86/ARM-LE,理論風險,一行記錄即可。
- **相鄰觀察(非 src_ip 範圍)**:TE 迴寫帶 `priority` 與 `idle_timeout`;P4 proxy 的
  `route_flow` 兩者**靜默忽略**(unsupported_match_fields 只驗 match 欄位)。
  ⚠️ **2026-08-17 追查後本條的後半段已更正,見下節。原句寫的「TE 在 P4 模式下的
  遷移規則是永久的,不像 OVS 會 idle 老化」不成立。**

## 2026-08-17 追查:上面那條相鄰觀察的更正(Adam 裁決「只更正紀錄」)

本輪對 idle_timeout 全鏈重讀,**記載的不對稱不存在**。純源碼考證,無 live(環境當時
歸 Adam)。三處各自獨立推翻 idle_timeout 那半邊:

| # | 事實 | 出處 |
|---|---|---|
| 1 | TE 的**活路徑**是 `migrate_multiple_flows`(`migrate_only_one_flow_per_round = False`),它組的 body **沒有 `idle_timeout` 鍵**,而且打的是 modify 端點;kernel 的 `makeModifyJob` 連 idleTimeout 欄位都沒有 | `Traffic-engineering-App.py:40`/`:500`/`:572`、`HttpSession.cpp:865` |
| 2 | 唯一會送的那條送的是 **`te_flow_entry_idle_timeout = 0`**,而 kernel 明碼把 `0` 與 `-1` 都當「這個欄位不要送」 | `Traffic-engineering-App.py:39`、`HttpRoutingStrategyBase.cpp:181` |
| 3 | OVS 控制平面自己也從不設 timeout(全 repo 零 `idle_timeout` 生產點) | `intelligent_router.py`(零命中) |

→ **今天沒有任何生產者要求老化**,所以「P4 不老化、OVS 會老化」的不對稱是虛構的;
P4 側沒有可修的 idle_timeout 缺陷。要真做,代價是改資料面:編出的 bmv2 JSON **10 張
表全是 `"support_timeout": false`**、p4info 無 idle 欄位 → 得改 `ndtwin_switch.p4`、
重編、全 fabric 重推 pipeline,proxy 還要接 P4Runtime 的 IdleTimeoutNotification stream
自己刪(P4Runtime 是**通知控制器刪**,不像 OpenFlow 由 switch 自行移除)。

**`priority` 那半邊是真的,但形狀與原句不同**:`ipv4_lpm` 是單鍵 LPM、每個目的地
一個 entry,而 P4Runtime 的 LPM **沒有 priority 概念**(priority 只給 ternary/range),
所以忽略它是結構性的、不是疏漏。真正的不對稱是:OVS 下 TE 的 100 **疊在** default 的
10 之上,P4 下 TE 的寫入**取代**那個目的地唯一的 entry。而且 `install_initial_routes()`
在**每次鏈路 transition 與 link discovery** 重寫全部 (switch, host) entry
(呼叫點在 `topology_manager.py` 的 `run_watchdog_pass` 與 `handle_packet_in` 的 LLDP 發現分支;
兩處都用 `grep -n "self.install_initial_routes()"` 現查,**本檔初稿寫死的兩個行號在同一個
commit 內就被我自己新增的 docstring 推移而失效**——[[cited-line-numbers-are-not-evidence]]
的字面重演,agy post-commit review 抓到)——**TE 的遷移會被下一次 flap 靜默還原**,
只有在無 flap 的穩態下才是「永久」。與 replace-vs-add 族的關係因此也要修正:
它不是「只會加不會刪」,是「單槽取代 + 被無關事件覆寫」。

**附帶(別人的碼,只記不改、不回報——Adam 2026-08-17 裁決)**:TE 那條死路徑
`detect_imbalance_and_migrate_one_flow` **開啟即 TypeError**——`:546` 用三個引數呼叫
需要五個參數(`u, v, data, flow_data_dict, DG`)的函式。它被 `:40` 的旗標關著,所以
不影響現行行為,也解釋了為何那條路徑的 idle_timeout 從未被任何人驗證過。

[Co-developed with claude code -- Adam]
